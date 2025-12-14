use axum::{extract::Path, http::StatusCode, Json};
use serde::{Deserialize, Serialize};

use crate::tmux;

#[derive(Deserialize)]
pub struct SendInputRequest {
    pub text: String,
}

#[derive(Serialize)]
pub struct ErrorResponse {
    pub error: String,
}

pub async fn send_input(
    Path(target): Path<String>,
    Json(payload): Json<SendInputRequest>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    match tmux::send_keys(&target, &payload.text) {
        Ok(()) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: e.to_string(),
            }),
        )),
    }
}

pub async fn send_escape(
    Path(target): Path<String>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    match tmux::send_escape(&target) {
        Ok(()) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: e.to_string(),
            }),
        )),
    }
}
