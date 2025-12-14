use axum::{extract::Path, http::StatusCode, Json};
use serde::Serialize;

use crate::tmux;

#[derive(Serialize)]
pub struct ErrorResponse {
    pub error: String,
}

pub async fn delete_pane(
    Path(target): Path<String>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    match tmux::kill_pane(&target) {
        Ok(()) => Ok(StatusCode::NO_CONTENT),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: e.to_string(),
            }),
        )),
    }
}
