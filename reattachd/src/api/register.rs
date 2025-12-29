use axum::{extract::State, http::StatusCode, response::IntoResponse, Json};
use serde::{Deserialize, Serialize};

use crate::auth::{SetupTokenValidation, SharedAuthService};

#[derive(Deserialize)]
pub struct RegisterRequest {
    pub setup_token: String,
    pub device_name: String,
}

#[derive(Serialize)]
pub struct RegisterResponse {
    pub device_id: String,
    pub device_token: String,
}

#[derive(Serialize)]
pub struct RegisterError {
    pub error: String,
    pub code: String,
}

pub async fn register_with_setup_token(
    State(auth): State<SharedAuthService>,
    Json(payload): Json<RegisterRequest>,
) -> Result<Json<RegisterResponse>, impl IntoResponse> {
    match auth
        .register_device(&payload.setup_token, &payload.device_name)
        .await
    {
        Ok(device) => Ok(Json(RegisterResponse {
            device_id: device.id,
            device_token: device.token,
        })),
        Err(SetupTokenValidation::Expired) => Err((
            StatusCode::UNAUTHORIZED,
            Json(RegisterError {
                error: "Setup token has expired. Please generate a new QR code.".to_string(),
                code: "TOKEN_EXPIRED".to_string(),
            }),
        )),
        Err(_) => Err((
            StatusCode::UNAUTHORIZED,
            Json(RegisterError {
                error: "Invalid setup token".to_string(),
                code: "TOKEN_INVALID".to_string(),
            }),
        )),
    }
}
