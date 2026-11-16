use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::Deserialize;
use std::sync::Arc;

use crate::apns::ApnsService;

pub type SharedApnsService = Arc<ApnsService>;

#[derive(Deserialize)]
pub struct RegisterDeviceRequest {
    pub token: String,
    #[serde(default)]
    pub sandbox: bool,
    #[serde(default)]
    pub device_id: String,
    #[serde(default)]
    pub server_name: String,
    pub notification_mode: Option<crate::apns::NotificationMode>,
}

#[derive(Deserialize)]
pub struct SendNotificationRequest {
    pub title: String,
    pub body: String,
    pub pane_target: Option<String>,
    #[serde(default)]
    pub kind: crate::apns::NotificationKind,
}

pub async fn register_apns_device(
    State((apns, auth)): State<(SharedApnsService, crate::auth::SharedAuthService)>,
    headers: HeaderMap,
    Json(mut payload): Json<RegisterDeviceRequest>,
) -> Result<(StatusCode, Json<serde_json::Value>), StatusCode> {
    let Some(token) = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
    else {
        return Err(StatusCode::UNAUTHORIZED);
    };
    let Some(device) = auth.validate_device_token(token).await else {
        return Err(StatusCode::UNAUTHORIZED);
    };
    payload.device_id = device.id;
    let mode = apns
        .register_device(
            payload.token,
            payload.sandbox,
            payload.device_id,
            payload.server_name,
            payload.notification_mode,
        )
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({"notification_mode": mode})),
    ))
}

pub async fn send_notification(
    State(apns): State<SharedApnsService>,
    Json(payload): Json<SendNotificationRequest>,
) -> StatusCode {
    // Older installed CLI hooks also submit here; filter before contacting APNs.
    if crate::notification_content::is_background_generation(&payload.body) {
        return StatusCode::OK;
    }
    match apns
        .send_notification(
            &payload.title,
            &payload.body,
            payload.pane_target.as_deref(),
            payload.kind,
        )
        .await
    {
        Ok(()) => StatusCode::OK,
        Err(e) => {
            tracing::error!("Failed to send notification: {:?}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}
