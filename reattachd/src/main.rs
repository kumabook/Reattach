mod api;
mod apns;
mod tmux;

use std::sync::Arc;

use apns::{ApnsConfig, ApnsService};
use axum::{
    routing::{delete, get, post},
    Router,
};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

const DEFAULT_PORT: u16 = 8787;

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "reattachd=debug".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let data_dir = std::env::var("REATTACHD_DATA_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| {
            dirs::data_local_dir()
                .unwrap_or_else(|| std::path::PathBuf::from("."))
                .join("reattachd")
        });

    let apns_service = match (
        std::env::var("APNS_KEY_BASE64"),
        std::env::var("APNS_KEY_ID"),
        std::env::var("APNS_TEAM_ID"),
        std::env::var("APNS_BUNDLE_ID"),
    ) {
        (Ok(key_base64), Ok(key_id), Ok(team_id), Ok(bundle_id)) => {
            use base64::{Engine as _, engine::general_purpose::STANDARD};
            let key = match STANDARD.decode(&key_base64) {
                Ok(bytes) => match String::from_utf8(bytes) {
                    Ok(s) => s,
                    Err(e) => {
                        tracing::error!("Invalid UTF-8 in APNS_KEY_BASE64: {}", e);
                        return;
                    }
                },
                Err(e) => {
                    tracing::error!("Invalid base64 in APNS_KEY_BASE64: {}", e);
                    return;
                }
            };
            let apns_config = ApnsConfig {
                key,
                key_id,
                team_id,
                bundle_id,
                sandbox: std::env::var("APNS_SANDBOX")
                    .map(|v| v == "1" || v.to_lowercase() == "true")
                    .unwrap_or(true),
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
        _ => {
            tracing::info!("APNs not configured (missing environment variables)");
            None
        }
    };

    let base_routes = Router::new()
        .route("/sessions", get(api::list_sessions))
        .route("/sessions", post(api::create_session))
        .route("/panes/{target}", delete(api::delete_pane))
        .route("/panes/{target}/input", post(api::send_input))
        .route("/panes/{target}/escape", post(api::send_escape))
        .route("/panes/{target}/output", get(api::get_output));

    let app = if let Some(apns) = apns_service {
        let apns_routes = Router::new()
            .route("/devices", post(api::register_device))
            .route("/notify", post(api::send_notification))
            .with_state(apns);
        base_routes.merge(apns_routes)
    } else {
        base_routes
    };

    let port = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(DEFAULT_PORT);

    let addr = format!("0.0.0.0:{}", port);
    tracing::info!("Starting reattachd on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
