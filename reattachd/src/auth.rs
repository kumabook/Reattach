use chrono::{DateTime, Utc};
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub token: String,
    pub registered_at: DateTime<Utc>,
    pub last_seen_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetupToken {
    pub token: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AuthStore {
    pub devices: Vec<Device>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub setup_token: Option<SetupToken>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SetupTokenValidation {
    Valid,
    Invalid,
    Expired,
}

pub struct AuthService {
    store: RwLock<AuthStore>,
    data_path: PathBuf,
}

impl AuthService {
    pub async fn new(data_dir: PathBuf) -> Result<Self, std::io::Error> {
        std::fs::create_dir_all(&data_dir)?;
        let data_path = data_dir.join("auth.json");

        let store = if data_path.exists() {
            let content = std::fs::read_to_string(&data_path)?;
            serde_json::from_str(&content).unwrap_or_default()
        } else {
            AuthStore::default()
        };

        Ok(Self {
            store: RwLock::new(store),
            data_path,
        })
    }

    async fn save(&self) -> Result<(), std::io::Error> {
        let store = self.store.read().await;
        let content = serde_json::to_string_pretty(&*store)?;
        std::fs::write(&self.data_path, content)?;
        Ok(())
    }

    pub async fn generate_setup_token(&self) -> String {
        let token = generate_token();
        let now = Utc::now();

        let setup_token = SetupToken {
            token: token.clone(),
            created_at: now,
            expires_at: now + chrono::Duration::minutes(10),
        };

        {
            let mut store = self.store.write().await;
            store.setup_token = Some(setup_token);
        }

        let _ = self.save().await;
        token
    }

    pub async fn validate_setup_token(&self, token: &str) -> SetupTokenValidation {
        // Reload from disk to pick up setup tokens created by `reattachd setup`
        self.reload().await;

        let store = self.store.read().await;
        if let Some(setup_token) = &store.setup_token {
            if setup_token.token != token {
                SetupTokenValidation::Invalid
            } else if Utc::now() >= setup_token.expires_at {
                SetupTokenValidation::Expired
            } else {
                SetupTokenValidation::Valid
            }
        } else {
            SetupTokenValidation::Invalid
        }
    }

    async fn reload(&self) {
        if self.data_path.exists() {
            if let Ok(content) = std::fs::read_to_string(&self.data_path) {
                if let Ok(new_store) = serde_json::from_str::<AuthStore>(&content) {
                    let mut store = self.store.write().await;
                    *store = new_store;
                }
            }
        }
    }

    pub async fn register_device(
        &self,
        setup_token: &str,
        device_name: &str,
    ) -> Result<Device, SetupTokenValidation> {
        match self.validate_setup_token(setup_token).await {
            SetupTokenValidation::Valid => {}
            other => return Err(other),
        }

        let device = Device {
            id: uuid::Uuid::new_v4().to_string(),
            name: device_name.to_string(),
            token: generate_token(),
            registered_at: Utc::now(),
            last_seen_at: None,
        };

        {
            let mut store = self.store.write().await;
            store.devices.push(device.clone());
            store.setup_token = None; // Invalidate setup token after use
        }

        let _ = self.save().await;
        Ok(device)
    }

    pub async fn validate_device_token(&self, token: &str) -> Option<Device> {
        let store = self.store.read().await;
        store.devices.iter().find(|d| d.token == token).cloned()
    }

    pub async fn update_last_seen(&self, device_id: &str) {
        {
            let mut store = self.store.write().await;
            if let Some(device) = store.devices.iter_mut().find(|d| d.id == device_id) {
                device.last_seen_at = Some(Utc::now());
            }
        }
        let _ = self.save().await;
    }

    pub async fn list_devices(&self) -> Vec<Device> {
        let store = self.store.read().await;
        store.devices.clone()
    }

    pub async fn revoke_device(&self, device_id: &str) -> bool {
        let removed = {
            let mut store = self.store.write().await;
            let len_before = store.devices.len();
            store.devices.retain(|d| d.id != device_id);
            store.devices.len() < len_before
        };

        if removed {
            let _ = self.save().await;
        }
        removed
    }

    pub async fn has_devices(&self) -> bool {
        let store = self.store.read().await;
        !store.devices.is_empty()
    }
}

fn generate_token() -> String {
    let mut rng = rand::thread_rng();
    let bytes: [u8; 32] = rng.gen();
    base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, bytes)
}

pub type SharedAuthService = Arc<AuthService>;
