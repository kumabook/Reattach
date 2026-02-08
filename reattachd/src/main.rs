mod api;
mod apns;
mod auth;
mod tmux;

use std::sync::Arc;

use apns::{ApnsConfig, ApnsService};
use auth::{AuthService, SharedAuthService};
use axum::{
    extract::{Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::Response,
    routing::{delete, get, post},
    Router,
};
use clap::{Parser, Subcommand};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

const DEFAULT_PORT: u16 = 8787;
const DEFAULT_BIND_ADDR: &str = "127.0.0.1";

#[derive(Parser)]
#[command(name = "reattachd")]
#[command(version)]
#[command(about = "Remote control daemon for tmux sessions")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Start setup mode to register a new device
    Setup {
        /// External URL for the server (e.g., https://your-server.example.com)
        #[arg(long)]
        url: String,
        /// Create a reusable token that can be used multiple times
        #[arg(long)]
        reusable: bool,
        /// Token expiration time (e.g., 10m, 1h, 1d, never). Default: 10m
        #[arg(long, default_value = "10m")]
        expires: String,
    },
    /// Manage registered devices
    Devices {
        #[command(subcommand)]
        action: Option<DeviceAction>,
    },
    /// Send a push notification to registered devices
    Notify {
        /// Agent event JSON payload. If omitted, JSON is read from stdin.
        #[arg(long)]
        from_agent_json: Option<String>,
        /// Agent event JSON payload (positional compatibility)
        agent_json: Option<String>,
        /// Manual notification body (debug override)
        #[arg(long)]
        body: Option<String>,
        /// Manual notification title (debug override)
        #[arg(short, long)]
        title: Option<String>,
        /// Tmux pane target (e.g., "dev:0.0"). Auto-detected if running inside tmux.
        #[arg(long)]
        target: Option<String>,
        /// Server port (default: 8787)
        #[arg(short, long, default_value = "8787")]
        port: u16,
    },
    /// Manage coding agent notification hooks
    Hooks {
        #[command(subcommand)]
        action: Option<HookAction>,
    },
}

#[derive(Subcommand)]
enum DeviceAction {
    /// List all registered devices
    List,
    /// Revoke a device by ID
    Revoke {
        /// Device ID to revoke
        id: String,
    },
}

#[derive(Subcommand)]
enum HookAction {
    /// Install Claude Code + Codex hooks
    Install,
    /// Uninstall Claude Code + Codex hooks
    Uninstall,
}

fn get_data_dir() -> std::path::PathBuf {
    std::env::var("REATTACHD_DATA_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| {
            dirs::data_local_dir()
                .unwrap_or_else(|| std::path::PathBuf::from("."))
                .join("reattachd")
        })
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "reattachd=debug".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let data_dir = get_data_dir();

    match cli.command {
        Some(Commands::Setup { url, reusable, expires }) => {
            run_setup_mode(data_dir, url, reusable, expires).await;
        }
        Some(Commands::Devices { action }) => {
            run_device_command(data_dir, action).await;
        }
        Some(Commands::Notify {
            from_agent_json,
            agent_json,
            body,
            title,
            target,
            port,
        }) => {
            run_notify_command(
                from_agent_json.or(agent_json),
                body,
                title,
                target,
                port,
            )
            .await;
        }
        Some(Commands::Hooks { action }) => {
            run_hooks_command(action);
        }
        None => {
            run_daemon(data_dir).await;
        }
    }
}

fn parse_duration(s: &str) -> Option<chrono::Duration> {
    if s == "never" {
        return Some(chrono::Duration::days(365 * 100));
    }

    let s = s.trim();
    if s.is_empty() {
        return None;
    }

    let (num_str, unit) = s.split_at(s.len() - 1);
    let num: i64 = num_str.parse().ok()?;

    match unit {
        "m" => Some(chrono::Duration::minutes(num)),
        "h" => Some(chrono::Duration::hours(num)),
        "d" => Some(chrono::Duration::days(num)),
        _ => None,
    }
}

async fn run_setup_mode(data_dir: std::path::PathBuf, url: String, reusable: bool, expires: String) {
    let duration = parse_duration(&expires).unwrap_or_else(|| {
        eprintln!("Invalid expiration format: {}. Using default 10m.", expires);
        chrono::Duration::minutes(10)
    });

    let auth_service = AuthService::new(data_dir.clone())
        .await
        .expect("Failed to initialize auth service");

    let setup_token = auth_service.generate_setup_token(reusable, duration).await;

    // Create setup URL with token
    let setup_url = format!("{}?setup_token={}", url, setup_token);

    // Generate QR code
    use qrcode::QrCode;
    let code = QrCode::new(&setup_url).expect("Failed to generate QR code");
    let qr_string = code
        .render::<char>()
        .quiet_zone(false)
        .module_dimensions(2, 1)
        .build();

    println!("\n  Scan this QR code with the Reattach iOS app:\n");
    println!("{}", qr_string);
    println!("\n  URL: {}", setup_url);

    let mut notes = vec![];
    if reusable {
        notes.push("reusable".to_string());
    }
    if expires == "never" {
        notes.push("no expiration".to_string());
    } else {
        notes.push(format!("expires in {}", expires));
    }
    println!("\n  Token: {}", notes.join(", "));
    println!("  Make sure reattachd daemon is running.\n");
}

async fn run_device_command(data_dir: std::path::PathBuf, action: Option<DeviceAction>) {
    let auth_service = AuthService::new(data_dir)
        .await
        .expect("Failed to initialize auth service");

    match action {
        Some(DeviceAction::Revoke { id }) => {
            if auth_service.revoke_device(&id).await {
                println!("Device {} revoked successfully", id);
            } else {
                println!("Device {} not found", id);
            }
        }
        Some(DeviceAction::List) | None => {
            let devices = auth_service.list_devices().await;
            if devices.is_empty() {
                println!("No registered devices");
                println!("\nRun 'reattachd setup --url <URL>' to register a device");
            } else {
                println!("Registered devices:\n");
                for device in devices {
                    println!("  ID:          {}", device.id);
                    println!("  Name:        {}", device.name);
                    println!("  Registered:  {}", device.registered_at);
                    if let Some(last_seen) = device.last_seen_at {
                        println!("  Last seen:   {}", last_seen);
                    }
                    println!();
                }
            }
        }
    }
}

struct NotifyPayload {
    title: String,
    body: String,
    cwd: Option<String>,
    pane_target: Option<String>,
}

fn extract_last_assistant_message(transcript_path: &str) -> Option<String> {
    let content = std::fs::read_to_string(transcript_path).ok()?;
    for line in content.lines().rev() {
        let value: serde_json::Value = serde_json::from_str(line).ok()?;
        let role = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if role != "assistant" {
            continue;
        }

        let texts = value
            .pointer("/message/content")
            .and_then(|v| v.as_array())
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        let t = item.get("type").and_then(|v| v.as_str())?;
                        if t != "text" {
                            return None;
                        }
                        item.get("text").and_then(|v| v.as_str()).map(str::to_string)
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        if !texts.is_empty() {
            return Some(texts.join("\n"));
        }
    }
    None
}

fn parse_agent_notify_payload(input: &str) -> Result<Option<NotifyPayload>, String> {
    let value: serde_json::Value =
        serde_json::from_str(input).map_err(|e| format!("Invalid JSON input: {}", e))?;

    let event_type = value.get("type").and_then(|v| v.as_str());
    if let Some(t) = event_type {
        if t != "agent-turn-complete" {
            return Ok(None);
        }
    }

    let cwd = value
        .get("cwd")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty());

    let mut title = if let Some(agent) = value.get("agent").and_then(|v| v.as_str()) {
        if !agent.is_empty() {
            agent.to_string()
        } else if event_type.is_some() {
            "Codex".to_string()
        } else {
            "Coding Agent".to_string()
        }
    } else if event_type.is_some() {
        "Codex".to_string()
    } else {
        "Coding Agent".to_string()
    };

    let mut body = value
        .get("last-assistant-message")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Waiting for input".to_string());

    if body == "Waiting for input" {
        if let Some(path) = value.get("transcript_path").and_then(|v| v.as_str()) {
            if !path.is_empty() {
                if let Some(last) = extract_last_assistant_message(path) {
                    body = last;
                }
            }
        }
    }

    if let Some(ref c) = cwd {
        if let Some(dir_name) = std::path::Path::new(c).file_name().and_then(|v| v.to_str()) {
            title = dir_name.to_string();
        }
    }

    Ok(Some(NotifyPayload {
        title,
        body,
        cwd,
        pane_target: None,
    }))
}

fn auto_detect_tmux_target_from_env() -> Option<String> {
    let tmux_pane = std::env::var("TMUX_PANE").ok()?;
    let output = std::process::Command::new("tmux")
        .args([
            "display-message",
            "-p",
            "-t",
            &tmux_pane,
            "#{session_name}:#{window_index}.#{pane_index}",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn auto_detect_tmux_target_from_cwd(cwd: &str) -> Option<String> {
    let output = std::process::Command::new("tmux")
        .args([
            "list-panes",
            "-a",
            "-F",
            "#{session_name}:#{window_index}.#{pane_index}:#{pane_current_path}",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let out = String::from_utf8(output.stdout).ok()?;
    out.lines().find_map(|line| {
        line.rfind(':').and_then(|idx| {
            let (target, path_part) = line.split_at(idx);
            let path = path_part.strip_prefix(':').unwrap_or(path_part);
            if path == cwd {
                Some(target.to_string())
            } else {
                None
            }
        })
    })
}

fn title_for_target_and_cwd(target: &str, cwd: Option<&str>) -> String {
    if let Some(c) = cwd {
        if let Some(dir_name) = std::path::Path::new(c).file_name().and_then(|v| v.to_str()) {
            let session_window = target.split('.').next().unwrap_or(target);
            return format!("{} · {}", session_window, dir_name);
        }
    }
    target.to_string()
}

fn read_stdin_if_available() -> Option<String> {
    use std::io::IsTerminal;
    use std::io::Read;

    if std::io::stdin().is_terminal() {
        return None;
    }

    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_ok() {
        let trimmed = input.trim().to_string();
        if !trimmed.is_empty() {
            return Some(trimmed);
        }
    }
    None
}

fn run_hooks_command(action: Option<HookAction>) {
    match action.unwrap_or(HookAction::Install) {
        HookAction::Install => {
            install_claude_hooks();
            install_codex_hooks();
        }
        HookAction::Uninstall => {
            uninstall_claude_hooks();
            uninstall_codex_hooks();
        }
    }
}

fn home_file(path: &str) -> Option<std::path::PathBuf> {
    let mut home = dirs::home_dir()?;
    home.push(path);
    Some(home)
}

fn ensure_claude_event_hook(
    hooks_obj: &mut serde_json::Map<String, serde_json::Value>,
    event_name: &str,
    matcher: &str,
) {
    let event = hooks_obj
        .entry(event_name.to_string())
        .or_insert_with(|| serde_json::json!([]));
    if !event.is_array() {
        *event = serde_json::json!([]);
    }
    let event_arr = event.as_array_mut().expect("array expected");

    let has_entry = event_arr.iter().any(|entry| {
        entry.get("matcher").and_then(|v| v.as_str()) == Some(matcher)
            && entry
                .get("hooks")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter().any(|h| {
                        h.get("type").and_then(|v| v.as_str()) == Some("command")
                            && h.get("command").and_then(|v| v.as_str()) == Some("reattachd notify")
                    })
                })
                .unwrap_or(false)
    });

    if !has_entry {
        event_arr.push(serde_json::json!({
            "matcher": matcher,
            "hooks": [{
                "type": "command",
                "command": "reattachd notify",
                "timeout": 10
            }]
        }));
    }
}

fn prune_claude_event_hook(
    hooks_obj: &mut serde_json::Map<String, serde_json::Value>,
    event_name: &str,
) {
    let Some(event) = hooks_obj.get_mut(event_name) else {
        return;
    };
    let Some(event_arr) = event.as_array_mut() else {
        return;
    };

    event_arr.retain(|entry| {
        let has_reattach = entry
            .get("hooks")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter().any(|h| {
                    h.get("type").and_then(|v| v.as_str()) == Some("command")
                        && h.get("command").and_then(|v| v.as_str()) == Some("reattachd notify")
                })
            })
            .unwrap_or(false);
        !has_reattach
    });
}

fn install_claude_hooks() {
    let claude_file = match home_file(".claude/settings.json") {
        Some(p) => p,
        None => {
            eprintln!("Failed to resolve home directory for Claude settings");
            return;
        }
    };
    if let Some(dir) = claude_file.parent() {
        if let Err(e) = std::fs::create_dir_all(dir) {
            eprintln!("Failed to create {}: {}", dir.display(), e);
            return;
        }
    }

    let mut root: serde_json::Value = if claude_file.exists() {
        match std::fs::read_to_string(&claude_file)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
        {
            Some(v) => v,
            None => serde_json::json!({}),
        }
    } else {
        serde_json::json!({})
    };

    if !root.is_object() {
        root = serde_json::json!({});
    }
    let root_obj = root.as_object_mut().expect("object expected");
    let hooks = root_obj
        .entry("hooks")
        .or_insert_with(|| serde_json::json!({}));
    if !hooks.is_object() {
        *hooks = serde_json::json!({});
    }
    let hooks_obj = hooks.as_object_mut().expect("object expected");
    ensure_claude_event_hook(hooks_obj, "Stop", "");
    ensure_claude_event_hook(hooks_obj, "Notification", "permission_prompt");

    match serde_json::to_string_pretty(&root)
        .ok()
        .and_then(|s| std::fs::write(&claude_file, format!("{}\n", s)).ok())
    {
        Some(_) => println!("Updated {}", claude_file.display()),
        None => eprintln!("Failed to write {}", claude_file.display()),
    }
}

fn uninstall_claude_hooks() {
    let claude_file = match home_file(".claude/settings.json") {
        Some(p) => p,
        None => {
            eprintln!("Failed to resolve home directory for Claude settings");
            return;
        }
    };
    if !claude_file.exists() {
        println!("No Claude settings file found");
        return;
    }

    let mut root: serde_json::Value = match std::fs::read_to_string(&claude_file)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
    {
        Some(v) => v,
        None => {
            eprintln!("Failed to parse {}", claude_file.display());
            return;
        }
    };
    if let Some(hooks) = root.get_mut("hooks").and_then(|v| v.as_object_mut()) {
        prune_claude_event_hook(hooks, "Stop");
        prune_claude_event_hook(hooks, "Notification");
    }

    match serde_json::to_string_pretty(&root)
        .ok()
        .and_then(|s| std::fs::write(&claude_file, format!("{}\n", s)).ok())
    {
        Some(_) => println!("Updated {}", claude_file.display()),
        None => eprintln!("Failed to write {}", claude_file.display()),
    }
}

fn install_codex_hooks() {
    let codex_file = match home_file(".codex/config.toml") {
        Some(p) => p,
        None => {
            eprintln!("Failed to resolve home directory for Codex config");
            return;
        }
    };
    if let Some(dir) = codex_file.parent() {
        if let Err(e) = std::fs::create_dir_all(dir) {
            eprintln!("Failed to create {}: {}", dir.display(), e);
            return;
        }
    }
    let existing = std::fs::read_to_string(&codex_file).unwrap_or_default();
    let has_other_notify = existing.lines().any(|line| {
        let t = line.trim();
        t.starts_with("notify =") && t != "notify = [\"reattachd\", \"notify\"]"
    });
    if has_other_notify {
        println!(
            "Skipped Codex update: notify is already configured in {}",
            codex_file.display()
        );
        println!("Add Reattach manually if needed: notify = [\"reattachd\", \"notify\"]");
        return;
    }

    let filtered: Vec<&str> = existing
        .lines()
        .filter(|line| {
            let t = line.trim();
            t != "# Reattach push notification hook" && t != "notify = [\"reattachd\", \"notify\"]"
        })
        .collect();
    let mut out = String::from("# Reattach push notification hook\nnotify = [\"reattachd\", \"notify\"]\n");
    if !filtered.is_empty() {
        out.push('\n');
        out.push_str(&filtered.join("\n"));
        out.push('\n');
    }
    match std::fs::write(&codex_file, out) {
        Ok(_) => println!("Updated {}", codex_file.display()),
        Err(e) => eprintln!("Failed to write {}: {}", codex_file.display(), e),
    }
}

fn uninstall_codex_hooks() {
    let codex_file = match home_file(".codex/config.toml") {
        Some(p) => p,
        None => {
            eprintln!("Failed to resolve home directory for Codex config");
            return;
        }
    };
    if !codex_file.exists() {
        println!("No Codex config file found");
        return;
    }
    let existing = std::fs::read_to_string(&codex_file).unwrap_or_default();
    let filtered: Vec<&str> = existing
        .lines()
        .filter(|line| {
            let t = line.trim();
            t != "# Reattach push notification hook" && t != "notify = [\"reattachd\", \"notify\"]"
        })
        .collect();
    let mut out = filtered.join("\n");
    if !out.is_empty() {
        out.push('\n');
    }
    match std::fs::write(&codex_file, out) {
        Ok(_) => println!("Updated {}", codex_file.display()),
        Err(e) => eprintln!("Failed to write {}: {}", codex_file.display(), e),
    }
}

async fn run_notify_command(
    from_agent_json: Option<String>,
    body: Option<String>,
    title: Option<String>,
    target: Option<String>,
    port: u16,
) {
    use serde_json::json;

    let mut payload = if body.is_some() || title.is_some() {
        NotifyPayload {
            title: title.unwrap_or_else(|| "Reattach".to_string()),
            body: body.unwrap_or_else(|| "Notification".to_string()),
            cwd: None,
            pane_target: None,
        }
    } else {
        let input = from_agent_json.or_else(read_stdin_if_available).unwrap_or_else(|| {
            eprintln!("No input provided.");
            eprintln!(
                "Use --from-agent-json '<json>' or pipe JSON via stdin, or pass --body/--title for debug."
            );
            std::process::exit(2);
        });

        match parse_agent_notify_payload(&input) {
            Ok(Some(p)) => p,
            Ok(None) => {
                // Non-target event type; skip as success.
                return;
            }
            Err(e) => {
                eprintln!("{}", e);
                std::process::exit(2);
            }
        }
    };

    let pane_target = target
        .or(payload.pane_target.clone())
        .or_else(auto_detect_tmux_target_from_env)
        .or_else(|| payload.cwd.as_deref().and_then(auto_detect_tmux_target_from_cwd));

    if let Some(ref t) = pane_target {
        payload.title = title_for_target_and_cwd(t, payload.cwd.as_deref());
    }

    let url = format!("http://localhost:{}/notify", port);
    let body = json!({
        "title": payload.title,
        "body": payload.body,
        "pane_target": pane_target,
    });

    let client = reqwest::Client::new();
    match client
        .post(&url)
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
    {
        Ok(response) => {
            if response.status().is_success() {
                if let Some(ref t) = pane_target {
                    println!("Notification sent successfully (target: {})", t);
                } else {
                    println!("Notification sent successfully");
                }
            } else {
                eprintln!("Failed to send notification: HTTP {}", response.status());
                std::process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("Failed to connect to reattachd: {}", e);
            eprintln!("Make sure reattachd daemon is running on port {}", port);
            std::process::exit(1);
        }
    }
}

async fn run_daemon(data_dir: std::path::PathBuf) {
    let auth_service = AuthService::new(data_dir.clone())
        .await
        .expect("Failed to initialize auth service");
    let auth_service = Arc::new(auth_service);

    // Check if any devices are registered
    if !auth_service.has_devices().await {
        tracing::warn!("No devices registered. Run 'reattachd setup --url <URL>' to register a device.");
        tracing::info!("Starting in open mode (no authentication required)");
    }

    let apns_service = init_apns_service(data_dir).await;

    let auth_for_middleware = auth_service.clone();

    // Base routes with authentication
    let base_routes = Router::new()
        .route("/sessions", get(api::list_sessions))
        .route("/sessions", post(api::create_session))
        .route("/panes/{target}", delete(api::delete_pane))
        .route("/panes/{target}/input", post(api::send_input))
        .route("/panes/{target}/escape", post(api::send_escape))
        .route("/panes/{target}/output", get(api::get_output))
        .layer(middleware::from_fn_with_state(
            auth_for_middleware,
            auth_middleware,
        ));

    // Registration endpoint (no auth required)
    let register_routes = Router::new()
        .route("/register", post(api::register_with_setup_token))
        .with_state(auth_service.clone());

    let app = if let Some(apns) = apns_service {
        let devices_route = Router::new()
            .route("/devices", post(api::register_apns_device))
            .with_state(Arc::clone(&apns))
            .layer(middleware::from_fn_with_state(
                auth_service.clone(),
                auth_middleware,
            ));
        let notify_route = Router::new()
            .route("/notify", post(api::send_notification))
            .with_state(apns);
        base_routes
            .merge(devices_route)
            .merge(notify_route)
            .merge(register_routes)
    } else {
        base_routes.merge(register_routes)
    };

    let port = std::env::var("REATTACHD_PORT")
        .or_else(|_| std::env::var("PORT"))
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(DEFAULT_PORT);

    let bind_addr = std::env::var("REATTACHD_BIND_ADDR")
        .unwrap_or_else(|_| DEFAULT_BIND_ADDR.to_string());
    let addr = format!("{}:{}", bind_addr, port);
    tracing::info!("Starting reattachd on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn auth_middleware(
    State(auth_service): State<SharedAuthService>,
    request: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    // If no devices registered, allow all requests
    if !auth_service.has_devices().await {
        return Ok(next.run(request).await);
    }

    // Check Authorization header
    let auth_header = request
        .headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok());

    let token = match auth_header {
        Some(header) if header.starts_with("Bearer ") => &header[7..],
        _ => return Err(StatusCode::UNAUTHORIZED),
    };

    match auth_service.validate_device_token(token).await {
        Some(device) => {
            auth_service.update_last_seen(&device.id).await;
            Ok(next.run(request).await)
        }
        None => Err(StatusCode::UNAUTHORIZED),
    }
}

include!(concat!(env!("OUT_DIR"), "/apns_config.rs"));

const XOR_KEY: &[u8] = b"reattachd_obfuscation_key_2026";

fn xor_decode(hex_input: &str) -> Option<String> {
    let bytes: Vec<u8> = (0..hex_input.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex_input[i..i + 2], 16))
        .collect::<Result<Vec<u8>, _>>()
        .ok()?;

    let decoded: Vec<u8> = bytes
        .iter()
        .enumerate()
        .map(|(i, b)| b ^ XOR_KEY[i % XOR_KEY.len()])
        .collect();

    String::from_utf8(decoded).ok()
}

fn get_apns_config() -> Option<(String, String, String, String)> {
    let key_base64 = APNS_KEY_BASE64_OBFUSCATED
        .and_then(xor_decode)
        .or_else(|| std::env::var("APNS_KEY_BASE64").ok())?;
    let key_id = APNS_KEY_ID_OBFUSCATED
        .and_then(xor_decode)
        .or_else(|| std::env::var("APNS_KEY_ID").ok())?;
    let team_id = APNS_TEAM_ID_OBFUSCATED
        .and_then(xor_decode)
        .or_else(|| std::env::var("APNS_TEAM_ID").ok())?;
    let bundle_id = APNS_BUNDLE_ID_OBFUSCATED
        .and_then(xor_decode)
        .or_else(|| std::env::var("APNS_BUNDLE_ID").ok())?;

    Some((key_base64, key_id, team_id, bundle_id))
}

async fn init_apns_service(data_dir: std::path::PathBuf) -> Option<Arc<ApnsService>> {
    let (key_base64, key_id, team_id, bundle_id) = match get_apns_config() {
        Some(config) => config,
        None => {
            tracing::info!("APNs not configured");
            return None;
        }
    };

    use base64::{engine::general_purpose::STANDARD, Engine as _};
    let key = match STANDARD.decode(&key_base64) {
        Ok(bytes) => match String::from_utf8(bytes) {
            Ok(s) => s,
            Err(e) => {
                tracing::error!("Invalid UTF-8 in APNS key: {}", e);
                return None;
            }
        },
        Err(e) => {
            tracing::error!("Invalid base64 in APNS key: {}", e);
            return None;
        }
    };

    let apns_config = ApnsConfig {
        key,
        key_id,
        team_id,
        bundle_id,
        data_dir,
    };

    match ApnsService::new(apns_config).await {
        Ok(service) => {
            tracing::info!("APNs service initialized");
            Some(Arc::new(service))
        }
        Err(e) => {
            tracing::warn!("Failed to initialize APNs service: {:?}", e);
            None
        }
    }
}
