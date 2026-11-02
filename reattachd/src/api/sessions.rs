use axum::{http::StatusCode, Json};
use serde::{Deserialize, Serialize};

use crate::tmux;

#[derive(Serialize)]
pub struct PaneResponse {
    pub index: u32,
    pub active: bool,
    pub target: String,
    pub current_path: String,
}

#[derive(Serialize)]
pub struct WindowResponse {
    pub index: u32,
    pub name: String,
    pub active: bool,
    pub panes: Vec<PaneResponse>,
}

#[derive(Serialize)]
pub struct SessionResponse {
    pub name: String,
    pub attached: bool,
    pub windows: Vec<WindowResponse>,
}

#[derive(Deserialize)]
pub struct CreateSessionRequest {
    pub name: String,
    pub cwd: String,
}

#[derive(Serialize)]
pub struct ErrorResponse {
    pub error: String,
}

pub async fn list_sessions() -> Result<Json<Vec<SessionResponse>>, (StatusCode, Json<ErrorResponse>)>
{
    match tmux::list_sessions() {
        Ok(sessions) => {
            let response: Vec<SessionResponse> = sessions
                .into_iter()
                .map(|s| SessionResponse {
                    name: s.name,
                    attached: s.attached,
                    windows: s
                        .windows
                        .into_iter()
                        .map(|w| WindowResponse {
                            index: w.index,
                            name: w.name,
                            active: w.active,
                            panes: w
                                .panes
                                .into_iter()
                                .map(|p| PaneResponse {
                                    index: p.index,
                                    active: p.active,
                                    target: p.target,
                                    current_path: p.current_path,
                                })
                                .collect(),
                        })
                        .collect(),
                })
                .collect();
            Ok(Json(response))
        }
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: e.to_string(),
            }),
        )),
    }
}

#[derive(Serialize)]
pub struct CreatedTarget {
    pub target: String,
}

#[derive(Deserialize)]
pub struct CreateWindowRequest {
    pub target: String,
}

pub async fn create_session(
    Json(payload): Json<CreateSessionRequest>,
) -> Result<(StatusCode, Json<CreatedTarget>), (StatusCode, Json<ErrorResponse>)> {
    creation_result(
        tokio::task::spawn_blocking(move || tmux::create_session(&payload.name, &payload.cwd))
            .await,
    )
}

pub async fn create_window(
    Json(payload): Json<CreateWindowRequest>,
) -> Result<(StatusCode, Json<CreatedTarget>), (StatusCode, Json<ErrorResponse>)> {
    creation_result(tokio::task::spawn_blocking(move || tmux::create_window(&payload.target)).await)
}

fn creation_result(
    result: Result<Result<String, tmux::TmuxError>, tokio::task::JoinError>,
) -> Result<(StatusCode, Json<CreatedTarget>), (StatusCode, Json<ErrorResponse>)> {
    match result {
        Ok(Ok(target)) => Ok((StatusCode::CREATED, Json(CreatedTarget { target }))),
        other => {
            let error = match other {
                Ok(Err(error)) => error.to_string(),
                Err(error) => error.to_string(),
                _ => unreachable!(),
            };
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrorResponse { error }),
            ))
        }
    }
}
