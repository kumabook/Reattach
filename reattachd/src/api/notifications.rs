use axum::{extract::State, http::StatusCode, Json};
use serde::Deserialize;
use std::sync::Arc;

use crate::apns::ApnsService;

pub type SharedApnsService = Arc<ApnsService>;

#[derive(Deserialize)]
pub struct RegisterDeviceRequest {
    pub token: String,
    #[serde(default)]
    pub sandbox: bool,
}

#[derive(Deserialize)]
pub struct SendNotificationRequest {
    pub title: String,
    pub body: String,
    pub pane_target: Option<String>,
}

pub async fn register_apns_device(
    State(apns): State<SharedApnsService>,
    Json(payload): Json<RegisterDeviceRequest>,
) -> StatusCode {
    apns.register_device(payload.token, payload.sandbox).await;
    StatusCode::CREATED
}

pub async fn send_notification(
    State(apns): State<SharedApnsService>,
    Json(payload): Json<SendNotificationRequest>,
) -> StatusCode {
    match apns
        .send_notification(&payload.title, &payload.body, payload.pane_target.as_deref())
        .await
    {
        Ok(()) => StatusCode::OK,
        Err(e) => {
            tracing::error!("Failed to send notification: {:?}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}
