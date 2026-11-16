//! Persist output revisions and per-authenticated-device read receipts, independently of alerts.
//! Whether a coding agent is working is read from its screen on every sample.
//! Windows with tmux's `monitor-activity` use tmux's own activity flag as unread,
//! so the app matches the terminal's status line.
use crate::auth::SharedAuthService;
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::sync::Mutex;

#[derive(Clone, Serialize, Deserialize)]
struct Pane {
    target: String,
    digest: String,
    revision: String,
}
#[derive(Clone, Default, Serialize, Deserialize)]
struct Ledger {
    panes: BTreeMap<String, Pane>,
    readers: HashMap<String, BTreeMap<String, String>>,
}
#[derive(Clone, Serialize)]
pub struct Entry {
    #[serde(skip)]
    id: String,
    target: String,
    revision: String,
    unread: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent: Option<AgentStatus>,
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct AgentStatus {
    state: &'static str,
    since: i64,
}
struct Sample {
    id: String,
    target: String,
    output: String,
    running: bool,
    tmux_unread: Option<bool>,
}
const AGENT_WORKING: &str = "esc to interrupt";
/// Claude Code and Codex show "esc to interrupt" just above or in their footer
/// only while a turn is in progress. Claude Code's process title is its version.
fn agent_working(command: &str, output: &str) -> bool {
    let agent = command == "codex"
        || command == "claude"
        || (command.split('.').count() == 3
            && command
                .split('.')
                .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit())));
    agent
        && output
            .lines()
            .rev()
            .filter(|line| !line.trim().is_empty())
            .take(6)
            .any(|line| line.contains(AGENT_WORKING))
}
#[derive(Deserialize)]
pub struct Receipt {
    target: String,
    revision: String,
}
pub struct Service {
    ledger: Mutex<Ledger>,
    file: PathBuf,
    pub generation: AtomicU64,
    initialized: AtomicBool,
    running: std::sync::Mutex<BTreeMap<String, i64>>,
    tmux_unread: std::sync::Mutex<BTreeMap<String, bool>>,
}
impl Service {
    pub fn new(dir: &std::path::Path) -> std::io::Result<Arc<Self>> {
        let file = dir.join("pane_activity.json");
        let ledger = match std::fs::read(&file) {
            Ok(data) => serde_json::from_slice(&data).map_err(std::io::Error::other)?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ledger::default(),
            Err(e) => return Err(e),
        };
        Ok(Arc::new(Self {
            ledger: Mutex::new(ledger),
            file,
            generation: AtomicU64::new(0),
            initialized: AtomicBool::new(false),
            running: std::sync::Mutex::new(BTreeMap::new()),
            tmux_unread: std::sync::Mutex::new(BTreeMap::new()),
        }))
    }
    fn save(&self, ledger: &Ledger) -> std::io::Result<()> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let tmp = self.file.with_extension("tmp");
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(&serde_json::to_vec(ledger).map_err(std::io::Error::other)?)?;
        std::fs::rename(tmp, &self.file)
    }
    pub fn start(self: Arc<Self>) {
        tokio::spawn(async move {
            loop {
                let samples = collect().await;
                if let Err(error) = &samples {
                    tracing::warn!(error, "Failed to collect pane activity");
                }
                if let Ok(samples) = samples {
                    let flags_changed = self.observe_tmux_unread(&samples);
                    if self.observe_running(&samples, chrono::Utc::now().timestamp())
                        || flags_changed
                    {
                        self.generation.fetch_add(1, Ordering::Relaxed);
                    }
                    let samples = samples
                        .into_iter()
                        .map(|s| (s.id, s.target, s.output))
                        .collect();
                    let mut ledger = self.ledger.lock().await;
                    let mut next = ledger.clone();
                    if next.observe(samples) {
                        if let Err(error) = self.save(&next) {
                            tracing::warn!(%error, "Failed to save pane activity");
                        } else {
                            let badge_changed =
                                ledger.unread_signature() != next.unread_signature();
                            *ledger = next;
                            if badge_changed {
                                self.generation.fetch_add(1, Ordering::Relaxed);
                            }
                            self.initialized.store(true, Ordering::Relaxed);
                        }
                    } else {
                        self.initialized.store(true, Ordering::Relaxed);
                    }
                }
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
        });
    }
}
impl Service {
    fn observe_tmux_unread(&self, samples: &[Sample]) -> bool {
        let next: BTreeMap<String, bool> = samples
            .iter()
            .filter_map(|s| s.tmux_unread.map(|unread| (s.id.clone(), unread)))
            .collect();
        let mut current = self.tmux_unread.lock().unwrap();
        let changed = *current != next;
        *current = next;
        changed
    }
    fn observe_running(&self, samples: &[Sample], now: i64) -> bool {
        let mut running = self.running.lock().unwrap();
        let before: Vec<String> = running.keys().cloned().collect();
        running.retain(|id, _| samples.iter().any(|s| s.running && &s.id == id));
        for sample in samples.iter().filter(|s| s.running) {
            running.entry(sample.id.clone()).or_insert(now);
        }
        before != running.keys().cloned().collect::<Vec<_>>()
    }
}
impl Ledger {
    fn unread_signature(&self) -> Vec<(String, String)> {
        let mut values = Vec::new();
        for (device, seen) in &self.readers {
            for (id, pane) in &self.panes {
                if seen.get(id) != Some(&pane.revision) {
                    values.push((device.clone(), pane.target.clone()));
                }
            }
        }
        values.sort();
        values
    }
    fn observe(&mut self, samples: Vec<(String, String, String)>) -> bool {
        let mut changed = false;
        let ids: std::collections::HashSet<_> =
            samples.iter().map(|(id, _, _)| id.clone()).collect();
        let before = self.panes.len();
        self.panes.retain(|id, _| ids.contains(id));
        changed |= before != self.panes.len();
        for seen in self.readers.values_mut() {
            seen.retain(|id, _| ids.contains(id));
        }
        for (id, target, output) in samples {
            let digest = openssl::sha::sha256(output.as_bytes())
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>();
            match self.panes.get_mut(&id) {
                Some(pane) => {
                    if pane.digest != digest {
                        pane.digest = digest;
                        pane.revision = uuid::Uuid::new_v4().to_string();
                        changed = true;
                    }
                    if pane.target != target {
                        pane.target = target;
                        changed = true;
                    }
                }
                None => {
                    self.panes.insert(
                        id,
                        Pane {
                            target,
                            digest,
                            revision: uuid::Uuid::new_v4().to_string(),
                        },
                    );
                    changed = true;
                }
            }
        }
        changed
    }
    fn entries(&mut self, device: &str) -> Vec<Entry> {
        // Establish a baseline on first use instead of calling all historical output unread.
        let seen = self.readers.entry(device.into()).or_insert_with(|| {
            self.panes
                .iter()
                .map(|(id, p)| (id.clone(), p.revision.clone()))
                .collect()
        });
        self.panes
            .iter()
            .map(|(id, p)| Entry {
                id: id.clone(),
                target: p.target.clone(),
                revision: p.revision.clone(),
                unread: seen.get(id) != Some(&p.revision),
                agent: None,
            })
            .collect()
    }
    fn acknowledge(&mut self, device: &str, receipt: &Receipt) -> bool {
        let Some((id, pane)) = self
            .panes
            .iter()
            .find(|(_, p)| p.target == receipt.target && p.revision == receipt.revision)
        else {
            return false;
        };
        self.readers
            .entry(device.into())
            .or_default()
            .insert(id.clone(), pane.revision.clone());
        true
    }
}
async fn command(args: &[&str]) -> Result<String, &'static str> {
    let result = tokio::time::timeout(
        Duration::from_secs(3),
        tokio::process::Command::new("tmux")
            .args(args)
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| "tmux timed out")?
    .map_err(|_| "tmux launch failed")?;
    if !result.status.success() {
        return Err("tmux command failed");
    }
    Ok(String::from_utf8_lossy(&result.stdout).into_owned())
}
async fn collect() -> Result<Vec<Sample>, &'static str> {
    let result = tokio::time::timeout(
        Duration::from_secs(3),
        tokio::process::Command::new("tmux")
            .args([
                "list-panes",
                "-a",
                "-F",
                "#{pid}|#{pane_id}|#{pane_current_command}|#{monitor-activity}|#{window_activity_flag}|#{session_name}:#{window_index}.#{pane_index}",
            ])
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| "tmux timed out")?
    .map_err(|_| "tmux launch failed")?;
    if !result.status.success() {
        let error = String::from_utf8_lossy(&result.stderr);
        if error.contains("no server running") || error.contains("no sessions") {
            return Ok(Vec::new());
        }
        return Err("tmux command failed");
    }
    let list = String::from_utf8_lossy(&result.stdout);
    let mut samples = Vec::new();
    for line in list.lines() {
        let fields: Vec<_> = line.splitn(6, '|').collect();
        if fields.len() != 6 || !fields[1].starts_with('%') {
            return Err("invalid pane list format");
        }
        // Join wrapped lines and exclude styling/cursor movement from unread detection.
        let output = command(&["capture-pane", "-p", "-J", "-S", "-80", "-t", fields[1]]).await?;
        samples.push(Sample {
            id: format!("{}:{}", fields[0], fields[1]),
            target: fields[5].into(),
            running: agent_working(fields[2], &output),
            tmux_unread: (fields[3] == "1").then(|| fields[4] == "1"),
            output,
        });
    }
    Ok(samples)
}
async fn device(auth: &SharedAuthService, headers: &HeaderMap) -> Result<String, StatusCode> {
    let token = headers
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .ok_or(StatusCode::UNAUTHORIZED)?;
    auth.validate_device_token(token)
        .await
        .map(|d| d.id)
        .ok_or(StatusCode::UNAUTHORIZED)
}
pub async fn list(
    State((service, auth)): State<(Arc<Service>, SharedAuthService)>,
    headers: HeaderMap,
) -> Result<Json<Vec<Entry>>, StatusCode> {
    let device = device(&auth, &headers).await?;
    if !service.initialized.load(Ordering::Relaxed) {
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }
    let mut ledger = service.ledger.lock().await;
    let mut next = ledger.clone();
    let mut entries = next.entries(&device);
    if !ledger.readers.contains_key(&device) {
        service
            .save(&next)
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        *ledger = next;
    }
    let running = service.running.lock().unwrap();
    let tmux_unread = service.tmux_unread.lock().unwrap();
    for entry in &mut entries {
        if let Some(&unread) = tmux_unread.get(&entry.id) {
            entry.unread = unread;
        }
        entry.agent = running.get(&entry.id).map(|&since| AgentStatus {
            state: "running",
            since,
        });
    }
    Ok(Json(entries))
}
pub async fn read(
    State((service, auth)): State<(Arc<Service>, SharedAuthService)>,
    headers: HeaderMap,
    Json(receipt): Json<Receipt>,
) -> StatusCode {
    let device = match device(&auth, &headers).await {
        Ok(d) => d,
        Err(e) => return e,
    };
    let mut ledger = service.ledger.lock().await;
    let mut next = ledger.clone();
    if !next.acknowledge(&device, &receipt) {
        return StatusCode::CONFLICT;
    }
    if next.readers == ledger.readers {
        return StatusCode::NO_CONTENT;
    }
    if service.save(&next).is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR;
    }
    *ledger = next;
    service.generation.fetch_add(1, Ordering::Relaxed);
    StatusCode::NO_CONTENT
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample(text: &str) -> Vec<(String, String, String)> {
        vec![("pid:%1".into(), "s:0.0".into(), text.into())]
    }
    #[tokio::test]
    #[ignore = "requires a running tmux server; run with LC_ALL=C to match launchd"]
    async fn collects_live_panes_in_service_locale() {
        assert!(collect().await.is_ok());
    }

    #[test]
    fn unread_is_per_device_persistent_and_deduplicated() {
        let mut l = Ledger::default();
        l.observe(sample("old"));
        assert!(!l.entries("a")[0].unread);
        assert!(!l.entries("b")[0].unread);
        l.observe(sample("new"));
        l.observe(sample("newer"));
        assert_eq!(l.entries("a").iter().filter(|e| e.unread).count(), 1);
        let e = l.entries("a").remove(0);
        assert!(l.acknowledge(
            "a",
            &Receipt {
                target: e.target,
                revision: e.revision
            }
        ));
        let mut restored: Ledger =
            serde_json::from_slice(&serde_json::to_vec(&l).unwrap()).unwrap();
        assert!(!restored.entries("a")[0].unread);
        assert!(restored.entries("b")[0].unread);
    }
    #[test]
    fn widget_signature_changes_on_reads_and_removal_but_not_repeated_output() {
        let mut ledger = Ledger::default();
        ledger.observe(sample("initial"));
        ledger.entries("phone");
        let empty = ledger.unread_signature();
        ledger.observe(sample("new"));
        let unread = ledger.unread_signature();
        assert_ne!(empty, unread);
        ledger.observe(sample("more output"));
        assert_eq!(unread, ledger.unread_signature());
        let entry = ledger.entries("phone").remove(0);
        assert!(ledger.acknowledge(
            "phone",
            &Receipt {
                target: entry.target,
                revision: entry.revision,
            }
        ));
        assert_eq!(empty, ledger.unread_signature());
        ledger.observe(sample("another update"));
        assert_ne!(empty, ledger.unread_signature());
        ledger.observe(vec![]);
        assert_eq!(empty, ledger.unread_signature());
    }

    #[test]
    fn stale_receipt_cannot_clear_newer_output_and_deleted_panes_disappear() {
        let mut l = Ledger::default();
        l.observe(sample("first"));
        let old = l.entries("a").remove(0);
        l.observe(sample("second"));
        assert!(!l.acknowledge(
            "a",
            &Receipt {
                target: old.target,
                revision: old.revision
            }
        ));
        assert!(l.entries("a")[0].unread);
        l.observe(vec![]);
        assert!(l.entries("a").is_empty());
    }
    #[test]
    fn detects_working_agents_from_their_screen() {
        let claude = "⏺ Done\n✽ Symbioting… (11s)\n────\n❯ \n────\n  ⏵⏵ auto mode on · esc to interrupt · ← 1 agent\n\n";
        let claude_idle = "⏺ Done\n────\n❯ \n────\n  ⏵⏵ auto mode on (shift+tab to cycle)\n";
        let codex = "• Ran gh run view\n• Working (6m 23s • esc to interrupt)\n  └ Tip: Use /agents\n› Ask Codex to do anything\n  GPT medium · ~/src\n  ← for agents · ? for shortcuts\n";
        let codex_idle = "• lint passed\n› Ask Codex to do anything\n  GPT medium · ~/src\n  ← for agents · ? for shortcuts\n";
        assert!(agent_working("2.1.322", claude));
        assert!(!agent_working("2.1.322", claude_idle));
        assert!(agent_working("codex", codex));
        assert!(!agent_working("codex", codex_idle));
        // Old text scrolled above the input area, or other programs, do not count.
        let scrolled = format!("{codex}{}", "line\n".repeat(10));
        assert!(!agent_working("codex", &scrolled));
        assert!(!agent_working("zsh", codex));
        assert!(!agent_working("vim", "esc to interrupt"));
    }

    #[tokio::test]
    async fn running_since_is_kept_while_working_and_cleared_afterwards() {
        let dir = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        std::fs::create_dir_all(&dir).unwrap();
        let service = Service::new(&dir).unwrap();
        let sample = |running| Sample {
            id: "1:%1".into(),
            target: "s:0.0".into(),
            output: String::new(),
            running,
            tmux_unread: None,
        };
        assert!(service.observe_running(&[sample(true)], 10));
        assert!(!service.observe_running(&[sample(true)], 20));
        assert_eq!(service.running.lock().unwrap().get("1:%1"), Some(&10));
        assert!(service.observe_running(&[sample(false)], 30));
        assert!(service.running.lock().unwrap().is_empty());
        assert!(service.observe_running(&[sample(true)], 40));
        assert!(service.observe_running(&[], 50));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn monitored_windows_follow_tmux_activity_flag() {
        let dir = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        std::fs::create_dir_all(&dir).unwrap();
        let service = Service::new(&dir).unwrap();
        let sample = |id: &str, tmux_unread| Sample {
            id: id.into(),
            target: "s:0.0".into(),
            output: String::new(),
            running: false,
            tmux_unread,
        };
        assert!(service.observe_tmux_unread(&[sample("1:%1", Some(true)), sample("1:%2", None)]));
        assert!(!service.observe_tmux_unread(&[sample("1:%1", Some(true)), sample("1:%2", None)]));
        assert_eq!(
            *service.tmux_unread.lock().unwrap(),
            BTreeMap::from([("1:%1".to_string(), true)])
        );
        // Viewing the window in tmux clears the flag.
        assert!(service.observe_tmux_unread(&[sample("1:%1", Some(false))]));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn missing_or_invalid_credentials_cannot_read_or_acknowledge() {
        let dir = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        std::fs::create_dir_all(&dir).unwrap();
        let auth = Arc::new(crate::auth::AuthService::new(dir.clone()).await.unwrap());
        assert!(device(&auth, &HeaderMap::new()).await.is_err());
        let mut headers = HeaderMap::new();
        headers.insert("authorization", "Bearer invalid".parse().unwrap());
        assert!(device(&auth, &headers).await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
