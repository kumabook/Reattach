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

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum NotificationMode {
    #[default]
    All,
    PermissionOnly,
    Off,
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum NotificationKind {
    #[default]
    Activity,
    Permission,
}
impl NotificationMode {
    fn allows(self, kind: NotificationKind) -> bool {
        self == Self::All || (self == Self::PermissionOnly && kind == NotificationKind::Permission)
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq)]
pub struct DeviceToken {
    pub token: String,
    pub sandbox: bool,
    #[serde(default)]
    pub device_id: String,
    #[serde(default)]
    pub server_name: String,
    #[serde(default)]
    pub notification_mode: NotificationMode,
    /// Whether permission pushes may carry the prompt text and reply buttons.
    #[serde(default = "default_permission_content")]
    pub permission_content: bool,
}

fn default_permission_content() -> bool {
    true
}

/// Identifies the exact prompt a notification showed, so a reply from the
/// notification can be rejected once the screen no longer matches.
pub struct PermissionPush<'a> {
    pub prompt: Option<&'a crate::permission_prompt::Prompt>,
    pub received_at: i64,
}

pub struct ApnsConfig {
    pub key: String,
    pub key_id: String,
    pub team_id: String,
    pub bundle_id: String,
    pub data_dir: PathBuf,
}

pub struct ApnsService {
    pub widget_push: crate::widget_push::Service,
    sandbox_client: Client,
    production_client: Client,
    bundle_id: String,
    device_tokens: Arc<RwLock<Vec<DeviceToken>>>,
    tokens_file: PathBuf,
}

impl ApnsService {
    pub async fn new(config: ApnsConfig) -> Result<Self, ApnsError> {
        let sandbox_client =
            Self::create_client(&config.key, &config.key_id, &config.team_id, true)?;
        let production_client =
            Self::create_client(&config.key, &config.key_id, &config.team_id, false)?;

        tracing::info!("APNs clients initialized (sandbox + production)");

        std::fs::create_dir_all(&config.data_dir)?;
        let tokens_file = config.data_dir.join("device_tokens.json");

        let device_tokens = Self::load_tokens(&tokens_file).unwrap_or_default();
        tracing::info!(
            "Loaded {} device tokens from {:?}",
            device_tokens.len(),
            tokens_file
        );

        let widget_push = crate::widget_push::Service::new(&config).map_err(ApnsError::Client)?;
        Ok(Self {
            widget_push,
            sandbox_client,
            production_client,
            bundle_id: config.bundle_id,
            device_tokens: Arc::new(RwLock::new(device_tokens)),
            tokens_file,
        })
    }

    fn create_client(
        key: &str,
        key_id: &str,
        team_id: &str,
        sandbox: bool,
    ) -> Result<Client, ApnsError> {
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

    pub async fn register_device(
        &self,
        token: String,
        sandbox: bool,
        device_id: String,
        server_name: String,
        mode: Option<NotificationMode>,
        permission_content: Option<bool>,
    ) -> Result<(NotificationMode, bool), ApnsError> {
        let mut tokens = self.device_tokens.write().await;
        let previous = tokens
            .iter()
            .find(|t| t.device_id == device_id && !device_id.is_empty());
        let notification_mode = mode
            .or_else(|| previous.map(|t| t.notification_mode))
            .unwrap_or_default();
        let permission_content = permission_content
            .or_else(|| previous.map(|t| t.permission_content))
            .unwrap_or_else(default_permission_content);
        // A device's preference applies to its development and production registrations.
        if !device_id.is_empty() {
            for existing in tokens.iter_mut().filter(|t| t.device_id == device_id) {
                existing.notification_mode = notification_mode;
                existing.permission_content = permission_content;
            }
        }
        let record = DeviceToken {
            token: token.clone(),
            sandbox,
            device_id,
            server_name,
            notification_mode,
            permission_content,
        };
        if let Some(existing) = tokens
            .iter_mut()
            .find(|t| t.token == token && t.sandbox == sandbox)
        {
            *existing = record;
        } else {
            tokens.push(record);
        }
        Self::save_tokens(&self.tokens_file, &tokens)?;
        Ok((notification_mode, permission_content))
    }

    pub async fn send_notification(
        &self,
        title: &str,
        body: &str,
        pane_target: Option<&str>,
        kind: NotificationKind,
    ) -> Result<(), ApnsError> {
        self.send(title, body, pane_target, kind, None).await
    }

    pub async fn send_permission(
        &self,
        title: &str,
        fallback_body: &str,
        pane_target: &str,
        push: PermissionPush<'_>,
    ) -> Result<(), ApnsError> {
        self.send(
            title,
            fallback_body,
            Some(pane_target),
            NotificationKind::Permission,
            Some(push),
        )
        .await
    }

    async fn send(
        &self,
        title: &str,
        body: &str,
        pane_target: Option<&str>,
        kind: NotificationKind,
        permission: Option<PermissionPush<'_>>,
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

        for device_token in tokens.iter().filter(|t| t.notification_mode.allows(kind)) {
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

            let prompt = permission
                .as_ref()
                .and_then(|p| p.prompt)
                .filter(|_| device_token.permission_content);
            let prompt_body = prompt.map(|p| p.body());
            let builder = DefaultNotificationBuilder::new()
                .set_title(&notification_title)
                .set_body(prompt_body.as_deref().unwrap_or(body))
                .set_sound("default");

            let mut payload = builder.build(&device_token.token, options.clone());
            if let (Some(push), Some(_)) = (&permission, prompt) {
                payload
                    .data
                    .insert("receivedAt", Value::from(push.received_at));
            }

            if let Some(target) = pane_target {
                payload
                    .data
                    .insert("paneTarget", Value::String(target.to_string()));
            }

            if !device_token.device_id.is_empty() {
                payload
                    .data
                    .insert("deviceId", Value::String(device_token.device_id.clone()));
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
                        if device_token.sandbox {
                            "sandbox"
                        } else {
                            "production"
                        },
                        response
                    );
                }
                Err(a2::Error::ResponseError(ref response)) => {
                    if let Some(ref error_body) = response.error {
                        if is_invalid_token(&error_body.reason) {
                            tracing::warn!(
                                "Removing invalid token: {}... (sandbox: {})",
                                &device_token.token[..20.min(device_token.token.len())],
                                device_token.sandbox
                            );
                            invalid_tokens.push(device_token.token.clone());
                            continue;
                        }
                    }
                    tracing::error!(
                        "APNs error for token {}: {:?}",
                        device_token.token,
                        response
                    );
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

    /// Drops tokens of devices revoked with `reattachd devices revoke`, which runs in another process.
    pub async fn forget_revoked_devices(&self, devices: &[crate::auth::Device]) {
        let mut tokens = self.device_tokens.write().await;
        let before = tokens.len();
        tokens.retain(|t| t.device_id.is_empty() || devices.iter().any(|d| d.id == t.device_id));
        if tokens.len() == before {
            return;
        }
        if let Err(e) = Self::save_tokens(&self.tokens_file, &tokens) {
            tracing::error!("Failed to save device tokens: {}", e);
        }
        tracing::info!(
            "Removed {} tokens of revoked devices",
            before - tokens.len()
        );
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

/// Unregistered (410) means the app was removed or the token expired; the
/// token will never become valid again, matching the widget push handling.
fn is_invalid_token(reason: &a2::ErrorReason) -> bool {
    matches!(
        reason,
        a2::ErrorReason::BadDeviceToken | a2::ErrorReason::Unregistered
    )
}

#[cfg(test)]
mod invalid_token_tests {
    use super::*;
    #[test]
    fn removes_only_permanently_invalid_tokens() {
        assert!(is_invalid_token(&a2::ErrorReason::BadDeviceToken));
        assert!(is_invalid_token(&a2::ErrorReason::Unregistered));
        assert!(!is_invalid_token(&a2::ErrorReason::TooManyRequests));
        assert!(!is_invalid_token(&a2::ErrorReason::InternalServerError));
    }
}

#[cfg(test)]
mod preference_tests {
    use super::*;
    #[test]
    fn notification_modes_filter_without_affecting_widget_subscriptions() {
        for (mode, activity, permission) in [
            (NotificationMode::All, true, true),
            (NotificationMode::PermissionOnly, false, true),
            (NotificationMode::Off, false, false),
        ] {
            assert_eq!(mode.allows(NotificationKind::Activity), activity);
            assert_eq!(mode.allows(NotificationKind::Permission), permission);
        }
    }
    #[test]
    fn legacy_tokens_keep_all_notifications() {
        let token: DeviceToken = serde_json::from_str(r#"{"token":"ab","sandbox":true}"#).unwrap();
        assert_eq!(token.notification_mode, NotificationMode::All);
        assert!(token.permission_content);
    }
}

#[cfg(test)]
mod registration_tests {
    use super::*;
    use axum::{
        extract::State,
        http::{HeaderMap, StatusCode},
        Json,
    };
    #[tokio::test]
    async fn preferences_are_authenticated_and_apply_to_both_environments_only_for_the_caller() {
        use openssl::{
            ec::{EcGroup, EcKey},
            nid::Nid,
            pkey::PKey,
        };
        let dir = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        let key = PKey::from_ec_key(
            EcKey::generate(&EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).unwrap()).unwrap(),
        )
        .unwrap();
        let apns = Arc::new(
            ApnsService::new(ApnsConfig {
                key: String::from_utf8(key.private_key_to_pem_pkcs8().unwrap()).unwrap(),
                key_id: "TEST".into(),
                team_id: "TEAM".into(),
                bundle_id: "test.app".into(),
                data_dir: dir.clone(),
            })
            .await
            .unwrap(),
        );
        let auth = Arc::new(crate::auth::AuthService::new(dir.clone()).await.unwrap());
        let setup = auth
            .generate_setup_token(false, chrono::Duration::minutes(1))
            .await;
        let device = auth.register_device(&setup, "A").await.unwrap();
        apns.register_device(
            "prod".into(),
            false,
            device.id.clone(),
            "server".into(),
            None,
            None,
        )
        .await
        .unwrap();
        apns.register_device(
            "other".into(),
            true,
            "other-device".into(),
            "server".into(),
            None,
            None,
        )
        .await
        .unwrap();
        let request = || crate::api::notifications::RegisterDeviceRequest {
            token: "dev".into(),
            sandbox: true,
            device_id: "other-device".into(),
            server_name: "server".into(),
            notification_mode: Some(NotificationMode::PermissionOnly),
            permission_content: Some(false),
        };
        assert!(matches!(
            crate::api::notifications::register_apns_device(
                State((apns.clone(), auth.clone())),
                HeaderMap::new(),
                Json(request())
            )
            .await,
            Err(StatusCode::UNAUTHORIZED)
        ));
        let mut headers = HeaderMap::new();
        headers.insert(
            "authorization",
            format!("Bearer {}", device.token).parse().unwrap(),
        );
        let result = crate::api::notifications::register_apns_device(
            State((apns.clone(), auth)),
            headers,
            Json(request()),
        )
        .await
        .unwrap();
        assert_eq!(result.1 .0["notification_mode"], "permission_only");
        assert_eq!(result.1 .0["permission_content"], "off");
        let tokens = apns.device_tokens.read().await;
        assert!(tokens
            .iter()
            .filter(|t| t.device_id == device.id)
            .all(|t| t.notification_mode == NotificationMode::PermissionOnly));
        assert_eq!(
            tokens
                .iter()
                .find(|t| t.token == "other")
                .unwrap()
                .notification_mode,
            NotificationMode::All
        );
        let saved = ApnsService::load_tokens(&apns.tokens_file).unwrap();
        assert_eq!(
            saved
                .iter()
                .find(|t| t.token == "prod")
                .unwrap()
                .notification_mode,
            NotificationMode::PermissionOnly
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn tokens_of_revoked_devices_are_forgotten() {
        use openssl::{
            ec::{EcGroup, EcKey},
            nid::Nid,
            pkey::PKey,
        };
        let dir = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        let key = PKey::from_ec_key(
            EcKey::generate(&EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).unwrap()).unwrap(),
        )
        .unwrap();
        let apns = ApnsService::new(ApnsConfig {
            key: String::from_utf8(key.private_key_to_pem_pkcs8().unwrap()).unwrap(),
            key_id: "TEST".into(),
            team_id: "TEAM".into(),
            bundle_id: "test.app".into(),
            data_dir: dir.clone(),
        })
        .await
        .unwrap();
        let auth = crate::auth::AuthService::new(dir.clone()).await.unwrap();
        let setup = auth
            .generate_setup_token(true, chrono::Duration::minutes(1))
            .await;
        let kept = auth.register_device(&setup, "kept").await.unwrap();
        let revoked = auth.register_device(&setup, "revoked").await.unwrap();
        for (token, device_id) in [
            ("a", kept.id.clone()),
            ("b", revoked.id.clone()),
            ("legacy", String::new()),
        ] {
            apns.register_device(token.into(), false, device_id, "s".into(), None, None)
                .await
                .unwrap();
        }
        auth.revoke_device(&revoked.id).await;
        apns.forget_revoked_devices(&auth.list_devices().await)
            .await;
        let mut left: Vec<String> = ApnsService::load_tokens(&apns.tokens_file)
            .unwrap()
            .into_iter()
            .map(|t| t.token)
            .collect();
        left.sort();
        assert_eq!(left, ["a", "legacy"]);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
