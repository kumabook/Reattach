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
        /// Create a reusable token that doesn't expire (for demo servers)
        #[arg(long)]
        reusable: bool,
    },
    /// Manage registered devices
    Devices {
        #[command(subcommand)]
        action: Option<DeviceAction>,
    },
    /// Send a push notification to registered devices
    Notify {
        /// Notification message body
        message: String,
        /// Notification title (default: "Reattach")
        #[arg(short, long, default_value = "Reattach")]
        title: String,
        /// Tmux pane target (e.g., "dev:0.0"). Auto-detected if running inside tmux.
        #[arg(long)]
        target: Option<String>,
        /// Server port (default: 8787)
        #[arg(short, long, default_value = "8787")]
        port: u16,
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
        Some(Commands::Setup { url, reusable }) => {
            run_setup_mode(data_dir, url, reusable).await;
        }
        Some(Commands::Devices { action }) => {
            run_device_command(data_dir, action).await;
        }
        Some(Commands::Notify { message, title, target, port }) => {
            run_notify_command(message, title, target, port);
        }
        None => {
            run_daemon(data_dir).await;
        }
    }
}

async fn run_setup_mode(data_dir: std::path::PathBuf, url: String, reusable: bool) {
    let auth_service = AuthService::new(data_dir.clone())
        .await
        .expect("Failed to initialize auth service");

    let setup_token = auth_service.generate_setup_token(reusable).await;

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
    println!("\n  Setup token expires in 10 minutes.");
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

fn run_notify_command(message: String, title: String, target: Option<String>, port: u16) {
    use serde_json::json;
    use std::process::Command;

    // Auto-detect tmux pane target if not provided
    let pane_target = target.or_else(|| {
        // Try to get current tmux pane target
        Command::new("tmux")
            .args(["display-message", "-p", "#{session_name}:#{window_index}.#{pane_index}"])
            .output()
            .ok()
            .and_then(|output| {
                if output.status.success() {
                    String::from_utf8(output.stdout)
                        .ok()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                } else {
                    None
                }
            })
    });

    let url = format!("http://localhost:{}/notify", port);
    let body = json!({
        "title": title,
        "body": message,
        "pane_target": pane_target,
    });

    let client = reqwest::blocking::Client::new();
    match client
        .post(&url)
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
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
