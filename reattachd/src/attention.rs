use crate::apns::ApnsService;
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    hash::{Hash, Hasher},
    path::Path,
    sync::{Arc, Mutex},
};

#[derive(Clone, Deserialize, Serialize)]
pub struct Event {
    pane_id: String,
    server_pid: String,
    session_id: String,
    turn_id: Option<String>,
    event: String,
    tool: String,
    request: String,
}

#[derive(Clone)]
struct Pending {
    event: Event,
    received_at: i64,
    generation: uuid::Uuid,
}

#[derive(Clone, Serialize)]
pub struct Attention {
    pub(crate) target: String,
    pub(crate) tool: String,
    pub(crate) received_at: i64,
}

pub struct Service {
    token: String,
    pending: Mutex<HashMap<String, Pending>>,
    visible_codex: tokio::sync::Mutex<crate::codex_attention::Detector>,
    apns: Option<Arc<ApnsService>>,
}

impl Service {
    pub fn new(data_dir: &Path, apns: Option<Arc<ApnsService>>) -> std::io::Result<Arc<Self>> {
        use std::io::Write;
        std::fs::create_dir_all(data_dir)?;
        let token = uuid::Uuid::new_v4().to_string();
        let path = data_dir.join("agent-hook.token");
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let temporary = data_dir.join(format!("agent-hook-{}.tmp", uuid::Uuid::new_v4()));
        options.open(&temporary)?.write_all(token.as_bytes())?;
        std::fs::rename(temporary, path)?;
        Ok(Arc::new(Self {
            token,
            pending: Mutex::new(HashMap::new()),
            visible_codex: tokio::sync::Mutex::new(crate::codex_attention::Detector::default()),
            apns,
        }))
    }
}

fn key(e: &Event) -> String {
    format!(
        "{}|{}|{}|{}|{}",
        e.server_pid,
        e.pane_id,
        e.session_id,
        e.turn_id.as_deref().unwrap_or(""),
        e.request
    )
}

fn update(pending: &mut HashMap<String, Pending>, event: Event) -> bool {
    if event.event == "PermissionRequest" || event.event == "permission_prompt" {
        let duplicate_prompt = pending.values().any(|p| {
            p.event.server_pid == event.server_pid
                && p.event.pane_id == event.pane_id
                && p.event.session_id == event.session_id
                && p.event.turn_id == event.turn_id
                && (event.event == "permission_prompt" || p.event.event == "permission_prompt")
        });
        if event.event == "permission_prompt" && duplicate_prompt {
            return false;
        }
        if event.event == "PermissionRequest" && duplicate_prompt {
            pending.retain(|_, p| {
                !(p.event.server_pid == event.server_pid
                    && p.event.pane_id == event.pane_id
                    && p.event.session_id == event.session_id
                    && p.event.turn_id == event.turn_id
                    && p.event.event == "permission_prompt")
            });
        }
        let id = key(&event);
        let new = !pending.contains_key(&id);
        pending.insert(
            id,
            Pending {
                event,
                received_at: chrono::Utc::now().timestamp(),
                generation: uuid::Uuid::new_v4(),
            },
        );
        return new && !duplicate_prompt;
    }
    pending.retain(|_, p| {
        let same_session = p.event.server_pid == event.server_pid
            && p.event.pane_id == event.pane_id
            && p.event.session_id == event.session_id;
        let same_turn = event.turn_id.is_none() || p.event.turn_id == event.turn_id;
        let finished = match event.event.as_str() {
            "PostToolUse" | "PostToolUseFailure" => {
                same_turn
                    && (p.event.request == event.request || p.event.event == "permission_prompt")
            }
            "Stop" | "Interrupt" => same_turn,
            "SessionEnd" | "UserPromptSubmit" => true,
            _ => false,
        };
        !(same_session && finished)
    });
    false
}

// Only the locally installed hook can update status. Mobile device credentials
// can read status but cannot forge an agent event or approve an operation.
pub async fn record(
    State(service): State<Arc<Service>>,
    headers: HeaderMap,
    Json(event): Json<Event>,
) -> StatusCode {
    if headers.get("authorization").and_then(|v| v.to_str().ok())
        != Some(format!("Bearer {}", service.token).as_str())
    {
        return StatusCode::UNAUTHORIZED;
    }
    if !valid_pane(&event.pane_id)
        || event.session_id.is_empty()
        || event.session_id.len() > 256
        || event.tool.len() > 256
    {
        return StatusCode::BAD_REQUEST;
    }
    update(&mut service.pending.lock().unwrap(), event);
    StatusCode::NO_CONTENT
}

pub async fn list(State(service): State<Arc<Service>>) -> Json<Vec<Attention>> {
    let pending = service
        .pending
        .lock()
        .unwrap()
        .iter()
        .map(|(id, p)| (id.clone(), p.clone()))
        .collect::<Vec<_>>();
    let now = chrono::Utc::now().timestamp();
    let mut result = Vec::new();
    let mut resolved = Vec::new();
    for (id, p) in pending {
        let Some(target) = resolve_target(&p.event).await else {
            continue;
        };
        // Agents send no hook when a prompt is denied or interrupted, and none until an
        // approved tool finishes, so a prompt that left the screen is no longer pending.
        if now - p.received_at >= PROMPT_RENDER_GRACE_SECS
            && shows_choice_menu(&p.event.pane_id).await == Some(false)
        {
            resolved.push((id, p.generation));
            continue;
        }
        result.push(Attention {
            target,
            tool: p.event.tool,
            received_at: p.received_at,
        });
    }
    if !resolved.is_empty() {
        let mut pending = service.pending.lock().unwrap();
        remove_resolved(&mut pending, resolved);
    }
    // Recover currently visible Codex prompts even when a hook was missed.
    // This is read-only detection; approval still requires explicit terminal input.
    let visible = service.visible_codex.lock().await.scan().await;
    for entry in visible {
        if !result.iter().any(|p| p.target == entry.target) {
            result.push(entry);
        }
    }
    result.sort_by_key(|p| p.received_at);
    let mut seen = std::collections::HashSet::new();
    result.retain(|entry| seen.insert(entry.target.clone()));
    Json(result)
}

// Keep watching even when the mobile app is suspended. Changes detected from
// hooks and visible Codex prompts use the same canonical list as the widget.
pub fn start_widget_monitor(
    service: Arc<Service>,
    auth: crate::auth::SharedAuthService,
    activity: Arc<crate::activity::Service>,
) {
    tokio::spawn(async move {
        let mut previous = None;
        let mut observed_requests: Vec<(String, String, i64)> = Vec::new();
        let mut widget_retry_at = tokio::time::Instant::now();
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            let Some(apns) = &service.apns else {
                return;
            };
            let Json(entries) = list(State(service.clone())).await;
            let request_fingerprint = widget_fingerprint(&entries);
            let now = chrono::Utc::now().timestamp();
            let mut deferred = Vec::new();
            for request in request_fingerprint
                .iter()
                .filter(|request| !observed_requests.contains(*request))
            {
                let (target, _, received_at) = request;
                let prompt = match crate::permission_prompt::capture(target).await {
                    Some(screen) => crate::permission_prompt::parse(&screen),
                    None => None,
                };
                // The hook fires before the menu is drawn; wait briefly for it.
                if prompt.is_none() && now - received_at < PROMPT_RENDER_GRACE_SECS {
                    deferred.push(request.clone());
                    continue;
                }
                match &prompt {
                    Some(p) => tracing::info!(
                        "Permission push for {target}: {} choices, digest {}",
                        p.choices.len(),
                        p.digest
                    ),
                    None => tracing::info!("Permission push for {target}: no choices on screen"),
                }
                let _ = apns
                    .send_permission(
                        &format!("許可待ち · {target}"),
                        "操作の許可が求められています。ペインを開いて確認してください。",
                        target,
                        crate::apns::PermissionPush {
                            prompt: prompt.as_ref(),
                            received_at: *received_at,
                        },
                    )
                    .await;
            }
            observed_requests = request_fingerprint
                .iter()
                .filter(|request| !deferred.contains(*request))
                .cloned()
                .collect();
            if !apns.widget_push.has_subscribers().await {
                previous = None;
                continue;
            }
            let fingerprint = (
                request_fingerprint,
                activity
                    .generation
                    .load(std::sync::atomic::Ordering::Relaxed),
            );
            if previous.as_ref() != Some(&fingerprint)
                && tokio::time::Instant::now() >= widget_retry_at
            {
                match apns.widget_push.send_updates(&auth).await {
                    Ok(()) => previous = Some(fingerprint),
                    Err(_) => {
                        // Retry widget delivery without pausing permission monitoring.
                        widget_retry_at =
                            tokio::time::Instant::now() + std::time::Duration::from_secs(30);
                    }
                }
            }
        }
    });
}

#[derive(Serialize)]
pub struct PromptAttention {
    #[serde(flatten)]
    attention: Attention,
    prompt: Option<crate::permission_prompt::Prompt>,
}

/// Pending requests with the menu currently on screen, for clients that answer
/// without showing the terminal.
pub async fn prompts(State(service): State<Arc<Service>>) -> Json<Vec<PromptAttention>> {
    let Json(entries) = list(State(service)).await;
    let mut result = Vec::with_capacity(entries.len());
    for attention in entries {
        let prompt = match crate::permission_prompt::capture(&attention.target).await {
            Some(screen) => crate::permission_prompt::parse(&screen),
            None => None,
        };
        result.push(PromptAttention { attention, prompt });
    }
    Json(result)
}

#[derive(Deserialize)]
pub struct Reply {
    target: String,
    received_at: i64,
    digest: String,
    choice: String,
}

/// Replies from a notification action. The request must still be pending and
/// the screen must show exactly the prompt the notification displayed.
pub async fn respond(
    State(service): State<Arc<Service>>,
    Json(reply): Json<Reply>,
) -> (StatusCode, Json<Value>) {
    let target = reply.target.clone();
    let choice = reply.choice.clone();
    let result = check_and_send(service, reply).await;
    match &result {
        Ok(()) => tracing::info!("Permission reply sent to {target}: choice {choice}"),
        Err((_, reason)) => {
            tracing::warn!("Permission reply to {target} rejected: {reason} (choice {choice})")
        }
    }
    match result {
        Ok(()) => (StatusCode::OK, Json(serde_json::json!({}))),
        Err((status, reason)) => (status, Json(serde_json::json!({ "error": reason }))),
    }
}

async fn check_and_send(
    service: Arc<Service>,
    reply: Reply,
) -> Result<(), (StatusCode, &'static str)> {
    let Json(entries) = list(State(service)).await;
    if !entries
        .iter()
        .any(|e| e.target == reply.target && e.received_at == reply.received_at)
    {
        return Err((StatusCode::CONFLICT, "no_longer_pending"));
    }
    let screen = crate::permission_prompt::capture(&reply.target)
        .await
        .ok_or((StatusCode::CONFLICT, "unavailable"))?;
    let prompt = crate::permission_prompt::parse(&screen)
        .filter(|p| p.digest == reply.digest)
        .ok_or((StatusCode::CONFLICT, "changed"))?;
    if !prompt.choices.iter().any(|c| c.number == reply.choice) {
        return Err((StatusCode::BAD_REQUEST, "invalid_choice"));
    }
    match tokio::task::spawn_blocking(move || crate::tmux::send_keys(&reply.target, &reply.choice))
        .await
    {
        Ok(Ok(())) => Ok(()),
        _ => Err((StatusCode::INTERNAL_SERVER_ERROR, "send_failed")),
    }
}

fn widget_fingerprint(entries: &[Attention]) -> Vec<(String, String, i64)> {
    let mut values: Vec<_> = entries
        .iter()
        .map(|e| (e.target.clone(), e.tool.clone(), e.received_at))
        .collect();
    values.sort();
    values
}

const PROMPT_RENDER_GRACE_SECS: i64 = 3;

fn remove_resolved(pending: &mut HashMap<String, Pending>, resolved: Vec<(String, uuid::Uuid)>) {
    for (id, generation) in resolved {
        // Screen capture awaits outside the lock. A hook may have replaced this
        // entry meanwhile, even with identical contents and in the same second.
        if pending.get(&id).is_some_and(|p| p.generation == generation) {
            pending.remove(&id);
        }
    }
}

async fn shows_choice_menu(pane_id: &str) -> Option<bool> {
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        tokio::process::Command::new("tmux")
            .args(["capture-pane", "-p", "-t", pane_id, "-S", "0", "-E", "-"])
            .kill_on_drop(true)
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    output
        .status
        .success()
        .then(|| has_selected_choice(&String::from_utf8_lossy(&output.stdout)))
}

fn has_selected_choice(screen: &str) -> bool {
    screen.lines().any(|line| {
        let line = line.trim().trim_matches(['│', '|']).trim();
        let Some(rest) = line.strip_prefix(['❯', '›', '>', '▶', '▸']) else {
            return false;
        };
        let Some((number, _)) = rest.trim_start().split_once(['.', ')']) else {
            return false;
        };
        !number.is_empty() && number.chars().all(|c| c.is_ascii_digit())
    })
}

fn valid_pane(id: &str) -> bool {
    id.strip_prefix('%')
        .is_some_and(|v| !v.is_empty() && v.chars().all(|c| c.is_ascii_digit()))
}

async fn resolve_target(event: &Event) -> Option<String> {
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        tokio::process::Command::new("tmux")
            .args([
                "list-panes",
                "-a",
                "-f",
                &format!(
                    "#{{&&:#{{==:#{{pane_id}},{}}},#{{!=:#{{@reattach_private}},1}}}}",
                    event.pane_id
                ),
                "-F",
                "#{pid}|#{session_name}:#{window_index}.#{pane_index}",
            ])
            .kill_on_drop(true)
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    let (pid, target) = text.lines().next()?.split_once('|')?;
    (pid == event.server_pid).then(|| target.to_owned())
}

pub fn from_hook(value: &Value, pane_id: String, server_pid: String) -> Option<Event> {
    let mut event = value.get("hook_event_name")?.as_str()?;
    if event == "Notification" {
        if value.get("notification_type")?.as_str()? != "permission_prompt" {
            return None;
        }
        event = "permission_prompt";
    }
    if !matches!(
        event,
        "PermissionRequest"
            | "permission_prompt"
            | "PostToolUse"
            | "PostToolUseFailure"
            | "Stop"
            | "Interrupt"
            | "SessionEnd"
            | "UserPromptSubmit"
    ) {
        return None;
    }
    let tool = value
        .get("tool_name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    tool.hash(&mut hash);
    value
        .get("tool_input")
        .map(Value::to_string)
        .hash(&mut hash);
    Some(Event {
        pane_id,
        server_pid,
        session_id: value.get("session_id")?.as_str()?.to_owned(),
        turn_id: value
            .get("turn_id")
            .and_then(Value::as_str)
            .map(str::to_owned),
        event: event.to_owned(),
        tool,
        request: format!("{:x}", hash.finish()),
    })
}

pub async fn run_hook(data_dir: &Path, port: u16) {
    // No output/decisions: the normal permission prompt must remain in control.
    let Some(input) = crate::read_stdin_if_available() else {
        return;
    };
    let Ok(value) = serde_json::from_str::<Value>(&input) else {
        return;
    };
    let Ok(pane) = std::env::var("TMUX_PANE") else {
        return;
    };
    if !valid_pane(&pane) {
        return;
    }
    let Ok(tmux) = std::env::var("TMUX") else {
        return;
    };
    let Some(pid) = tmux.rsplit(',').nth(1) else {
        return;
    };
    let Some(event) = from_hook(&value, pane, pid.to_owned()) else {
        return;
    };
    let Ok(token) = std::fs::read_to_string(data_dir.join("agent-hook.token")) else {
        return;
    };
    let _ = reqwest::Client::new()
        .post(format!("http://127.0.0.1:{port}/agent-events"))
        .bearer_auth(token.trim())
        .json(&event)
        .timeout(std::time::Duration::from_secs(2))
        .send()
        .await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_attention_keeps_list_fields_at_the_top_level() {
        let entry = PromptAttention {
            attention: Attention {
                target: "s:0.0".into(),
                tool: "Bash".into(),
                received_at: 7,
            },
            prompt: crate::permission_prompt::parse("Run?\n❯ 1. Yes\n  2. No"),
        };
        let value = serde_json::to_value(entry).unwrap();
        assert_eq!(value["target"], "s:0.0");
        assert_eq!(value["received_at"], 7);
        assert_eq!(value["prompt"]["context"], "Run?");
        assert_eq!(value["prompt"]["choices"][1]["label"], "No");
        assert!(value["prompt"]["digest"].is_string());
    }
    fn event(name: &str, command: &str, turn: &str) -> Event {
        from_hook(&serde_json::json!({"hook_event_name":name,"session_id":"s","turn_id":turn,"tool_name":"Bash","tool_input":{"command":command}}), "%1".into(), "100".into()).unwrap()
    }
    #[test]
    fn widget_changes_include_resolution_but_ignore_reordering() {
        let entry = |target: &str, received_at| Attention {
            target: target.into(),
            tool: "Codex".into(),
            received_at,
        };
        let first = widget_fingerprint(&[entry("a", 1), entry("b", 2)]);
        assert_eq!(first, widget_fingerprint(&[entry("b", 2), entry("a", 1)]));
        assert_ne!(first, widget_fingerprint(&[entry("a", 1)]));
        assert_ne!(first, widget_fingerprint(&[]));
        assert_ne!(first, widget_fingerprint(&[entry("a", 3), entry("b", 2)]));
    }
    #[test]
    fn tracks_other_panes_and_only_clears_matching_tool_or_turn() {
        let mut pending = HashMap::new();
        assert!(update(&mut pending, event("PermissionRequest", "one", "1")));
        assert!(!update(
            &mut pending,
            event("PermissionRequest", "one", "1")
        ));
        update(&mut pending, event("PermissionRequest", "two", "1"));
        update(&mut pending, event("PostToolUse", "one", "1"));
        assert_eq!(pending.len(), 1);
        update(&mut pending, event("Stop", "", "old"));
        assert_eq!(pending.len(), 1);
        let mut other = event("PermissionRequest", "other", "1");
        other.pane_id = "%2".into();
        update(&mut pending, other);
        update(&mut pending, event("Stop", "", "1"));
        assert_eq!(pending.len(), 1);
        assert_eq!(pending.values().next().unwrap().event.pane_id, "%2");
    }
    #[test]
    fn late_completion_cannot_clear_identical_request_in_new_turn() {
        let mut pending = HashMap::new();
        update(&mut pending, event("PermissionRequest", "same", "old"));
        assert!(update(
            &mut pending,
            event("PermissionRequest", "same", "new")
        ));
        update(&mut pending, event("PostToolUse", "same", "old"));
        assert_eq!(pending.len(), 1);
        assert_eq!(
            pending.values().next().unwrap().event.turn_id.as_deref(),
            Some("new")
        );
    }

    #[test]
    fn stale_screen_check_preserves_reregistered_request_in_same_second() {
        for remove_before_registering in [false, true] {
            let mut pending = HashMap::new();
            let request = event("PermissionRequest", "same", "1");
            let id = key(&request);
            update(&mut pending, request.clone());
            let checked = pending[&id].clone();
            if remove_before_registering {
                pending.remove(&id);
            }
            update(&mut pending, request);
            // Deliberately use identical timestamps: timestamp equality alone
            // must not allow an old scan to remove the replacement.
            pending.get_mut(&id).unwrap().received_at = checked.received_at;
            let replacement = pending[&id].generation;
            assert_ne!(replacement, checked.generation);
            remove_resolved(&mut pending, vec![(id.clone(), checked.generation)]);
            assert_eq!(pending[&id].generation, replacement);
        }
    }

    #[test]
    fn screen_check_removes_only_unchanged_requests() {
        let mut pending = HashMap::new();
        let request = event("PermissionRequest", "finished", "1");
        let id = key(&request);
        update(&mut pending, request);
        let generation = pending[&id].generation;
        let other = event("PermissionRequest", "still waiting", "1");
        let other_id = key(&other);
        update(&mut pending, other);
        remove_resolved(&mut pending, vec![(id.clone(), generation)]);
        assert!(!pending.contains_key(&id));
        assert!(pending.contains_key(&other_id));
        // A simultaneous completion hook may already have removed the entry.
        remove_resolved(&mut pending, vec![(id, generation)]);
        assert_eq!(pending.len(), 1);
    }

    #[test]
    fn delayed_permission_notification_does_not_duplicate_prompt() {
        let mut pending = HashMap::new();
        assert!(update(&mut pending, event("PermissionRequest", "cmd", "1")));
        let mut notification = event("PermissionRequest", "", "1");
        notification.event = "permission_prompt".into();
        assert!(!update(&mut pending, notification));
        assert_eq!(pending.len(), 1);
        update(&mut pending, event("PostToolUseFailure", "cmd", "1"));
        assert!(pending.is_empty());
    }

    #[test]
    fn detects_visible_choice_menus_only() {
        let claude = "Bash command\n\n  npm test\n\nDo you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again\n  3. No, and tell Claude what to do differently (esc)\n";
        assert!(has_selected_choice(claude));
        assert!(has_selected_choice(
            "│ ❯ 1. Yes                │\n│   2. No                 │"
        ));
        assert!(has_selected_choice("› 1. Yes, proceed (y)\n  2. No (esc)"));
        assert!(!has_selected_choice(
            "⏺ Bash(npm test)\n  ⎿  Running…\n> \n"
        ));
        assert!(!has_selected_choice("> 2026 plans\n"));
        assert!(!has_selected_choice("  1. Yes\n  2. No\n"));
    }

    #[test]
    fn ignores_idle_and_completion_notifications() {
        let value = serde_json::json!({"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"s"});
        assert!(from_hook(&value, "%1".into(), "100".into()).is_none());
        assert!(!valid_pane("; kill-server"));
    }
}
