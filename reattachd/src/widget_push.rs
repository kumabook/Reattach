use crate::{
    apns::{ApnsConfig, ApnsService},
    auth::SharedAuthService,
};
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    Json,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use openssl::{
    ecdsa::EcdsaSig,
    hash::MessageDigest,
    pkey::{PKey, Private},
    sign::Signer,
};
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Arc, time::Duration};
use tokio::sync::Mutex;

const LEASE_SECONDS: i64 = 3 * 24 * 60 * 60;
#[derive(Clone, Serialize, Deserialize)]
struct Subscription {
    device_id: String,
    token: String,
    sandbox: bool,
    expires: i64,
}

pub struct Service {
    client: reqwest::Client,
    key: PKey<Private>,
    key_id: String,
    team_id: String,
    topic: String,
    file: PathBuf,
    subscriptions: Mutex<Vec<Subscription>>,
    jwt: Mutex<Option<(i64, String)>>,
}

#[derive(Deserialize)]
pub struct Registration {
    token: String,
    sandbox: bool,
    enabled: bool,
}
impl Registration {
    fn valid(&self) -> bool {
        (32..=512).contains(&self.token.len())
            && self.token.len() % 2 == 0
            && self.token.bytes().all(|b| b.is_ascii_hexdigit())
    }
}

impl Service {
    pub fn new(config: &ApnsConfig) -> Result<Self, String> {
        let file = config.data_dir.join("widget_tokens.json");
        let subscriptions = match std::fs::read(&file) {
            Ok(data) => {
                serde_json::from_slice(&data).map_err(|e| format!("Widget registrations: {e}"))?
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e.to_string()),
        };
        Ok(Self {
            client: reqwest::Client::builder()
                .https_only(true)
                .timeout(Duration::from_secs(15))
                .build()
                .map_err(|e| e.to_string())?,
            key: PKey::private_key_from_pem(config.key.as_bytes()).map_err(|e| e.to_string())?,
            key_id: config.key_id.clone(),
            team_id: config.team_id.clone(),
            topic: format!("{}.push-type.widgets", config.bundle_id),
            file,
            subscriptions: Mutex::new(subscriptions),
            jwt: Mutex::new(None),
        })
    }

    fn save(&self, subscriptions: &[Subscription]) -> Result<(), String> {
        use std::{io::Write, os::unix::fs::OpenOptionsExt};
        let temporary = self.file.with_extension("tmp");
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(|e| e.to_string())?;
        file.write_all(&serde_json::to_vec(subscriptions).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        std::fs::rename(temporary, &self.file).map_err(|e| e.to_string())
    }

    async fn register(&self, device_id: String, registration: Registration) -> Result<(), String> {
        let mut stored = self.subscriptions.lock().await;
        let mut next = stored.clone();
        update_subscription(
            &mut next,
            device_id,
            registration,
            chrono::Utc::now().timestamp(),
        );
        self.save(&next)?;
        *stored = next;
        Ok(())
    }

    pub async fn has_subscribers(&self) -> bool {
        let now = chrono::Utc::now().timestamp();
        self.subscriptions
            .lock()
            .await
            .iter()
            .any(|s| s.expires > now)
    }

    async fn bearer(&self) -> Result<String, String> {
        let now = chrono::Utc::now().timestamp();
        let mut cache = self.jwt.lock().await;
        if let Some((created, token)) = &*cache {
            if now - created < 50 * 60 {
                return Ok(token.clone());
            }
        }
        let header = URL_SAFE_NO_PAD
            .encode(serde_json::json!({"alg":"ES256","kid":self.key_id}).to_string());
        let claims =
            URL_SAFE_NO_PAD.encode(serde_json::json!({"iss":self.team_id,"iat":now}).to_string());
        let input = format!("{header}.{claims}");
        let mut signer =
            Signer::new(MessageDigest::sha256(), &self.key).map_err(|e| e.to_string())?;
        signer.update(input.as_bytes()).map_err(|e| e.to_string())?;
        let der = signer.sign_to_vec().map_err(|e| e.to_string())?;
        let sig = EcdsaSig::from_der(&der).map_err(|e| e.to_string())?;
        let mut raw = sig.r().to_vec_padded(32).map_err(|e| e.to_string())?;
        raw.extend(sig.s().to_vec_padded(32).map_err(|e| e.to_string())?);
        let token = format!("{input}.{}", URL_SAFE_NO_PAD.encode(raw));
        *cache = Some((now, token.clone()));
        Ok(token)
    }

    fn request(&self, subscription: &Subscription, bearer: &str) -> reqwest::RequestBuilder {
        let host = if subscription.sandbox {
            "api.sandbox.push.apple.com"
        } else {
            "api.push.apple.com"
        };
        self.client
            .post(format!("https://{host}/3/device/{}", subscription.token))
            .bearer_auth(bearer)
            .header("apns-push-type", "widgets")
            .header("apns-topic", &self.topic)
            .header("apns-priority", "5")
            .header("apns-collapse-id", "permission-widget")
            .header(
                "apns-expiration",
                (chrono::Utc::now().timestamp() + 3600).to_string(),
            )
            .json(&serde_json::json!({"aps":{"content-changed":true}}))
    }

    pub async fn send_updates(&self, auth: &SharedAuthService) -> Result<(), String> {
        let now = chrono::Utc::now().timestamp();
        let subscriptions = self.subscriptions.lock().await.clone();
        let bearer = self.bearer().await?;
        let mut invalid = Vec::new();
        let mut failed = false;
        let devices = auth.list_devices().await;
        for s in subscriptions {
            if s.expires <= now || !devices.iter().any(|d| d.id == s.device_id) {
                invalid.push(s);
                continue;
            }
            match self.request(&s, &bearer).send().await {
                Ok(response) if response.status().is_success() => {
                    tracing::info!("Widget update accepted by APNs")
                }
                Ok(response) => {
                    let status = response.status();
                    let body: serde_json::Value = response.json().await.unwrap_or_default();
                    let reason = body["reason"].as_str().unwrap_or("Unknown");
                    tracing::warn!(%status, reason, "Widget APNs update rejected");
                    if status.as_u16() == 410 || reason == "BadDeviceToken" {
                        invalid.push(s);
                    } else {
                        failed = true;
                    }
                }
                Err(_) => {
                    tracing::warn!("Widget APNs connection failed");
                    failed = true;
                }
            }
        }
        if !invalid.is_empty() {
            let mut stored = self.subscriptions.lock().await;
            // Do not erase a renewed subscription while a send was in flight.
            stored.retain(|s| {
                !invalid.iter().any(|i| {
                    i.device_id == s.device_id && i.token == s.token && i.expires == s.expires
                })
            });
            self.save(&stored)?;
        }
        if failed {
            Err("Some widget pushes failed".into())
        } else {
            Ok(())
        }
    }
}

fn update_subscription(
    stored: &mut Vec<Subscription>,
    device_id: String,
    r: Registration,
    now: i64,
) {
    stored.retain(|s| {
        s.expires > now
            && !(s.device_id == device_id
                && s.sandbox == r.sandbox
                && (r.enabled || s.token == r.token))
    });
    if r.enabled {
        stored.push(Subscription {
            device_id,
            token: r.token,
            sandbox: r.sandbox,
            expires: now + LEASE_SECONDS,
        });
    }
}

pub async fn register(
    State((apns, auth)): State<(Arc<ApnsService>, SharedAuthService)>,
    headers: HeaderMap,
    Json(r): Json<Registration>,
) -> StatusCode {
    let Some(token) = headers
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
    else {
        return StatusCode::UNAUTHORIZED;
    };
    let Some(device) = auth.validate_device_token(token).await else {
        return StatusCode::UNAUTHORIZED;
    };
    if !r.valid() {
        return StatusCode::BAD_REQUEST;
    }
    match apns.widget_push.register(device.id, r).await {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn config() -> ApnsConfig {
        use openssl::{
            ec::{EcGroup, EcKey},
            nid::Nid,
        };
        let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).unwrap();
        let key = PKey::from_ec_key(EcKey::generate(&group).unwrap()).unwrap();
        ApnsConfig {
            key: String::from_utf8(key.private_key_to_pem_pkcs8().unwrap()).unwrap(),
            key_id: "TESTKEY".into(),
            team_id: "TESTTEAM".into(),
            bundle_id: "test.app".into(),
            data_dir: std::env::temp_dir()
                .join(format!("widget-push-test-{}", uuid::Uuid::new_v4())),
        }
    }

    #[tokio::test]
    async fn signs_valid_es256_and_sends_only_widget_refresh_payload() {
        use openssl::{bn::BigNum, sign::Verifier};
        let config = config();
        let service = Service::new(&config).unwrap();
        let bearer = service.bearer().await.unwrap();
        assert_eq!(bearer, service.bearer().await.unwrap());
        let parts: Vec<_> = bearer.split('.').collect();
        let raw = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        assert_eq!(raw.len(), 64);
        let sig = EcdsaSig::from_private_components(
            BigNum::from_slice(&raw[..32]).unwrap(),
            BigNum::from_slice(&raw[32..]).unwrap(),
        )
        .unwrap();
        let mut verifier = Verifier::new(MessageDigest::sha256(), &service.key).unwrap();
        verifier
            .update(format!("{}.{}", parts[0], parts[1]).as_bytes())
            .unwrap();
        assert!(verifier.verify(&sig.to_der().unwrap()).unwrap());
        for sandbox in [true, false] {
            let sub = Subscription {
                device_id: "A".into(),
                token: "ab".repeat(32),
                sandbox,
                expires: i64::MAX,
            };
            let req = service.request(&sub, &bearer).build().unwrap();
            assert_eq!(req.headers()["apns-push-type"], "widgets");
            assert_eq!(req.headers()["apns-topic"], "test.app.push-type.widgets");
            assert_eq!(req.headers()["apns-priority"], "5");
            assert_eq!(
                req.url().host_str().unwrap(),
                if sandbox {
                    "api.sandbox.push.apple.com"
                } else {
                    "api.push.apple.com"
                }
            );
            let body: serde_json::Value =
                serde_json::from_slice(req.body().unwrap().as_bytes().unwrap()).unwrap();
            assert_eq!(body, serde_json::json!({"aps":{"content-changed":true}}));
        }
    }

    #[tokio::test]
    async fn registration_requires_device_auth_even_before_initial_pairing() {
        let config = config();
        let dir = config.data_dir.clone();
        let auth = Arc::new(crate::auth::AuthService::new(dir.clone()).await.unwrap());
        let apns = Arc::new(ApnsService::new(config).await.unwrap());
        let r = || Registration {
            token: "ab".repeat(32),
            sandbox: true,
            enabled: true,
        };
        let state = || State((apns.clone(), auth.clone()));
        assert_eq!(
            register(state(), HeaderMap::new(), Json(r())).await,
            StatusCode::UNAUTHORIZED
        );
        let setup = auth
            .generate_setup_token(false, chrono::Duration::minutes(1))
            .await;
        let device = auth.register_device(&setup, "test").await.unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            "authorization",
            format!("Bearer {}", device.token).parse().unwrap(),
        );
        assert_eq!(
            register(state(), headers, Json(r())).await,
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            apns.widget_push.subscriptions.lock().await[0].device_id,
            device.id
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn rejects_invalid_tokens() {
        for token in ["", "../other", "aa\n", &"a".repeat(513)] {
            assert!(!Registration {
                token: token.into(),
                sandbox: true,
                enabled: true
            }
            .valid());
        }
        assert!(Registration {
            token: "ab".repeat(32),
            sandbox: false,
            enabled: true
        }
        .valid());
    }
    #[test]
    fn rotations_and_removal_are_scoped_to_owner_and_token() {
        let mut stored = Vec::new();
        let reg = |token: &str, enabled| Registration {
            token: token.into(),
            sandbox: true,
            enabled,
        };
        update_subscription(&mut stored, "A".into(), reg("old", true), 0);
        update_subscription(&mut stored, "B".into(), reg("other", true), 0);
        update_subscription(&mut stored, "A".into(), reg("new", true), 10);
        update_subscription(&mut stored, "A".into(), reg("old", false), 20);
        assert_eq!(stored.len(), 2);
        update_subscription(&mut stored, "A".into(), reg("new", false), 30);
        assert_eq!(stored[0].device_id, "B");
        update_subscription(
            &mut stored,
            "C".into(),
            reg("latest", true),
            LEASE_SECONDS + 1,
        );
        assert_eq!(stored.len(), 1);
    }
}
