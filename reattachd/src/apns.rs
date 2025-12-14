use a2::{
    Client, ClientConfig, DefaultNotificationBuilder, Endpoint, NotificationBuilder,
    NotificationOptions,
};
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

pub struct ApnsConfig {
    pub key: String,
    pub key_id: String,
    pub team_id: String,
    pub bundle_id: String,
    pub sandbox: bool,
    pub data_dir: PathBuf,
}

pub struct ApnsService {
    client: Client,
    bundle_id: String,
    device_tokens: Arc<RwLock<Vec<String>>>,
    tokens_file: PathBuf,
}

impl ApnsService {
    pub async fn new(config: ApnsConfig) -> Result<Self, ApnsError> {
        let mut key_cursor = Cursor::new(config.key.as_bytes());
        let endpoint = if config.sandbox {
            Endpoint::Sandbox
        } else {
            Endpoint::Production
        };
        let client_config = ClientConfig::new(endpoint);
        let client = Client::token(
            &mut key_cursor,
            &config.key_id,
            &config.team_id,
            client_config,
        )
        .map_err(|e| ApnsError::Client(e.to_string()))?;

        tracing::info!("APNs endpoint: {:?}", if config.sandbox { "Sandbox" } else { "Production" });

        std::fs::create_dir_all(&config.data_dir)?;
        let tokens_file = config.data_dir.join("device_tokens.json");

        let device_tokens = Self::load_tokens(&tokens_file).unwrap_or_default();
        tracing::info!("Loaded {} device tokens from {:?}", device_tokens.len(), tokens_file);

        Ok(Self {
            client,
            bundle_id: config.bundle_id,
            device_tokens: Arc::new(RwLock::new(device_tokens)),
            tokens_file,
        })
    }

    fn load_tokens(path: &PathBuf) -> Option<Vec<String>> {
        let file = File::open(path).ok()?;
        let reader = BufReader::new(file);
        serde_json::from_reader(reader).ok()
    }

    fn save_tokens(path: &PathBuf, tokens: &[String]) -> std::io::Result<()> {
        let file = File::create(path)?;
        let writer = BufWriter::new(file);
        serde_json::to_writer_pretty(writer, tokens)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))
    }

    pub async fn register_device(&self, token: String) {
        let mut tokens = self.device_tokens.write().await;
        if !tokens.contains(&token) {
            tracing::info!("Registered device token: {}...", &token[..20.min(token.len())]);
            tokens.push(token);
            if let Err(e) = Self::save_tokens(&self.tokens_file, &tokens) {
                tracing::error!("Failed to save device tokens: {}", e);
            }
        }
    }

    pub async fn send_notification(
        &self,
        title: &str,
        body: &str,
        cwd: Option<&str>,
    ) -> Result<(), ApnsError> {
        let tokens = self.device_tokens.read().await;
        if tokens.is_empty() {
            return Err(ApnsError::NoDeviceToken);
        }

        let dir_name: Option<String> = cwd.and_then(|c| {
            std::path::Path::new(c)
                .file_name()
                .and_then(|n| n.to_str())
                .map(|s| s.to_string())
        });

        if let Some(ref name) = dir_name {
            tracing::info!("Notification dirName: {}", name);
        }

        let options = NotificationOptions {
            apns_topic: Some(&self.bundle_id),
            ..Default::default()
        };

        let builder = DefaultNotificationBuilder::new()
            .set_title(title)
            .set_body(body)
            .set_sound("default");

        for token in tokens.iter() {
            let mut payload = builder.clone().build(token, options.clone());

            if let Some(ref name) = dir_name {
                payload.data.insert("dirName", Value::String(name.clone()));
            }

            match self.client.send(payload).await {
                Ok(response) => {
                    tracing::info!("APNs notification sent: {:?}", response);
                }
                Err(e) => {
                    tracing::error!("APNs error for token {}: {:?}", token, e);
                }
            }
        }

        Ok(())
    }
}
