//! Persist output revisions and per-authenticated-device read receipts, independently of alerts.
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
    target: String,
    revision: String,
    unread: bool,
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
                target: p.target.clone(),
                revision: p.revision.clone(),
                unread: seen.get(id) != Some(&p.revision),
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
async fn collect() -> Result<Vec<(String, String, String)>, &'static str> {
    let result = tokio::time::timeout(
        Duration::from_secs(3),
        tokio::process::Command::new("tmux")
            .args([
                "list-panes",
                "-a",
                "-F",
                "#{pid}|#{pane_id}|#{session_name}:#{window_index}.#{pane_index}",
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
        let fields: Vec<_> = line.splitn(3, '|').collect();
        if fields.len() != 3 || !fields[1].starts_with('%') {
            return Err("invalid pane list format");
        }
        // Join wrapped lines and exclude styling/cursor movement from unread detection.
        let output = command(&["capture-pane", "-p", "-J", "-S", "-80", "-t", fields[1]]).await?;
        samples.push((
            format!("{}:{}", fields[0], fields[1]),
            fields[2].into(),
            output,
        ));
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
    let entries = next.entries(&device);
    if !ledger.readers.contains_key(&device) {
        service
            .save(&next)
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        *ledger = next;
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
