use axum::{
    extract::{Path, Query},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::tmux;

#[derive(Deserialize)]
pub struct OutputQuery {
    #[serde(default = "default_lines")]
    pub lines: u32,
}

fn default_lines() -> u32 {
    200
}

#[derive(Serialize)]
pub struct OutputResponse {
    pub output: String,
}

#[derive(Serialize)]
pub struct ErrorResponse {
    pub error: String,
}

pub async fn get_output(
    Path(target): Path<String>,
    Query(query): Query<OutputQuery>,
) -> Result<Json<OutputResponse>, (StatusCode, Json<ErrorResponse>)> {
    match tmux::capture_pane(&target, query.lines) {
        Ok(output) => Ok(Json(OutputResponse { output })),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: e.to_string(),
            }),
        )),
    }
}
