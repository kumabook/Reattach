use a2::{
    Client, ClientConfig, DefaultNotificationBuilder, Endpoint, NotificationBuilder,
    NotificationOptions,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::File;
use std::io::{BufReader, BufWriter, Cursor};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Debug, thiserror::Error)]
pub enum ApnsError {
    #[error("APNs client error: {0}")]
    Client(String),
    #[error("No device token registered")]
    NoDeviceToken,
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Clone, Serialize, Deserialize, PartialEq)]
pub struct DeviceToken {
    pub token: String,
    pub sandbox: bool,
    #[serde(default)]
    pub device_id: String,
    #[serde(default)]
    pub server_name: String,
}

pub struct ApnsConfig {
    pub key: String,
    pub key_id: String,
    pub team_id: String,
    pub bundle_id: String,
    pub data_dir: PathBuf,
}

pub struct ApnsService {
    sandbox_client: Client,
    production_client: Client,
    bundle_id: String,
    device_tokens: Arc<RwLock<Vec<DeviceToken>>>,
    tokens_file: PathBuf,
}

impl ApnsService {
    pub async fn new(config: ApnsConfig) -> Result<Self, ApnsError> {
        let sandbox_client = Self::create_client(&config.key, &config.key_id, &config.team_id, true)?;
        let production_client = Self::create_client(&config.key, &config.key_id, &config.team_id, false)?;

        tracing::info!("APNs clients initialized (sandbox + production)");

        std::fs::create_dir_all(&config.data_dir)?;
        let tokens_file = config.data_dir.join("device_tokens.json");

        let device_tokens = Self::load_tokens(&tokens_file).unwrap_or_default();
        tracing::info!("Loaded {} device tokens from {:?}", device_tokens.len(), tokens_file);

        Ok(Self {
            sandbox_client,
            production_client,
            bundle_id: config.bundle_id,
            device_tokens: Arc::new(RwLock::new(device_tokens)),
            tokens_file,
        })
    }

    fn create_client(key: &str, key_id: &str, team_id: &str, sandbox: bool) -> Result<Client, ApnsError> {
        let mut key_cursor = Cursor::new(key.as_bytes());
        let endpoint = if sandbox {
            Endpoint::Sandbox
        } else {
            Endpoint::Production
        };
        let client_config = ClientConfig::new(endpoint);
        Client::token(&mut key_cursor, key_id, team_id, client_config)
            .map_err(|e| ApnsError::Client(e.to_string()))
    }

    fn load_tokens(path: &PathBuf) -> Option<Vec<DeviceToken>> {
        let file = File::open(path).ok()?;
        let reader = BufReader::new(file);
        serde_json::from_reader(reader).ok()
    }

    fn save_tokens(path: &PathBuf, tokens: &[DeviceToken]) -> std::io::Result<()> {
        let file = File::create(path)?;
        let writer = BufWriter::new(file);
        serde_json::to_writer_pretty(writer, tokens)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))
    }

    pub async fn register_device(&self, token: String, sandbox: bool, device_id: String, server_name: String) {
        let mut tokens = self.device_tokens.write().await;
        let device_token = DeviceToken { token: token.clone(), sandbox, device_id: device_id.clone(), server_name: server_name.clone() };

        if let Some(existing) = tokens.iter_mut().find(|t| t.token == token) {
            let mut updated = false;
            if existing.sandbox != sandbox {
                tracing::info!(
                    "Updated device token: {}... (sandbox: {} -> {})",
                    &token[..20.min(token.len())],
                    existing.sandbox,
                    sandbox
                );
                existing.sandbox = sandbox;
                updated = true;
            }
            if existing.device_id != device_id {
                tracing::info!(
                    "Updated device token: {}... (device_id: {} -> {})",
                    &token[..20.min(token.len())],
                    existing.device_id,
                    device_id
                );
                existing.device_id = device_id;
                updated = true;
            }
            if existing.server_name != server_name {
                tracing::info!(
                    "Updated device token: {}... (server_name: {} -> {})",
                    &token[..20.min(token.len())],
                    existing.server_name,
                    server_name
                );
                existing.server_name = server_name;
                updated = true;
            }
            if updated {
                if let Err(e) = Self::save_tokens(&self.tokens_file, &tokens) {
                    tracing::error!("Failed to save device tokens: {}", e);
                }
            }
        } else {
            tracing::info!(
                "Registered device token: {}... (sandbox: {}, device_id: {}, server_name: {})",
                &token[..20.min(token.len())],
                sandbox,
                device_id,
                server_name
            );
            tokens.push(device_token);
            if let Err(e) = Self::save_tokens(&self.tokens_file, &tokens) {
                tracing::error!("Failed to save device tokens: {}", e);
            }
        }
    }

    pub async fn send_notification(
        &self,
        title: &str,
        body: &str,
        pane_target: Option<&str>,
    ) -> Result<(), ApnsError> {
        let tokens = self.device_tokens.read().await.clone();
        if tokens.is_empty() {
            return Err(ApnsError::NoDeviceToken);
        }

        if let Some(target) = pane_target {
            tracing::info!("Notification paneTarget: {}", target);
        }

        let options = NotificationOptions {
            apns_topic: Some(&self.bundle_id),
            ..Default::default()
        };

        let mut invalid_tokens = Vec::new();

        for device_token in tokens.iter() {
            let notification_title = if device_token.server_name.is_empty() {
                title.to_string()
            } else {
                let full_title = format!("{}: {}", device_token.server_name, title);
                const MAX_TITLE_LEN: usize = 40;
                if full_title.chars().count() > MAX_TITLE_LEN {
                    let prefix = format!("{}: ...", device_token.server_name);
                    let prefix_len = prefix.chars().count();
                    let remaining = MAX_TITLE_LEN.saturating_sub(prefix_len);
                    let title_chars: Vec<char> = title.chars().collect();
                    let skip = title_chars.len().saturating_sub(remaining);
                    let truncated: String = title_chars.into_iter().skip(skip).collect();
                    format!("{}: ...{}", device_token.server_name, truncated)
                } else {
                    full_title
                }
            };

            let builder = DefaultNotificationBuilder::new()
                .set_title(&notification_title)
                .set_body(body)
                .set_sound("default");

            let mut payload = builder.build(&device_token.token, options.clone());

            if let Some(target) = pane_target {
                payload.data.insert("paneTarget", Value::String(target.to_string()));
            }

            if !device_token.device_id.is_empty() {
                payload.data.insert("deviceId", Value::String(device_token.device_id.clone()));
            }

            let client = if device_token.sandbox {
                &self.sandbox_client
            } else {
                &self.production_client
            };

            match client.send(payload).await {
                Ok(response) => {
                    tracing::info!(
                        "APNs notification sent ({}): {:?}",
                        if device_token.sandbox { "sandbox" } else { "production" },
                        response
                    );
                }
                Err(a2::Error::ResponseError(ref response)) => {
                    if let Some(ref error_body) = response.error {
                        if error_body.reason == a2::ErrorReason::BadDeviceToken {
                            tracing::warn!(
                                "Removing invalid token: {}... (sandbox: {})",
                                &device_token.token[..20.min(device_token.token.len())],
                                device_token.sandbox
                            );
                            invalid_tokens.push(device_token.token.clone());
                            continue;
                        }
                    }
                    tracing::error!("APNs error for token {}: {:?}", device_token.token, response);
                }
                Err(e) => {
                    tracing::error!("APNs error for token {}: {:?}", device_token.token, e);
                }
            }
        }

        if !invalid_tokens.is_empty() {
            self.remove_tokens(&invalid_tokens).await;
        }

        Ok(())
    }

    async fn remove_tokens(&self, tokens_to_remove: &[String]) {
        let mut tokens = self.device_tokens.write().await;
        tokens.retain(|t| !tokens_to_remove.contains(&t.token));
        if let Err(e) = Self::save_tokens(&self.tokens_file, &tokens) {
            tracing::error!("Failed to save device tokens: {}", e);
        }
        tracing::info!("Removed {} invalid tokens", tokens_to_remove.len());
    }
}
