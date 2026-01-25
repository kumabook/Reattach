use std::env;
use std::fs;
use std::path::Path;

const XOR_KEY: &[u8] = b"reattachd_obfuscation_key_2026";

fn xor_encode(input: &str) -> String {
    input
        .bytes()
        .enumerate()
        .map(|(i, b)| format!("{:02x}", b ^ XOR_KEY[i % XOR_KEY.len()]))
        .collect()
}

fn main() {
    let out_dir = env::var("OUT_DIR").unwrap();
    let dest_path = Path::new(&out_dir).join("apns_config.rs");

    let key_base64 = env::var("APNS_KEY_BASE64").ok();
    let key_id = env::var("APNS_KEY_ID").ok();
    let team_id = env::var("APNS_TEAM_ID").ok();
    let bundle_id = env::var("APNS_BUNDLE_ID").ok();

    let code = format!(
        r#"
const APNS_KEY_BASE64_OBFUSCATED: Option<&str> = {};
const APNS_KEY_ID_OBFUSCATED: Option<&str> = {};
const APNS_TEAM_ID_OBFUSCATED: Option<&str> = {};
const APNS_BUNDLE_ID_OBFUSCATED: Option<&str> = {};
"#,
        key_base64.map(|v| format!("Some(\"{}\")", xor_encode(&v))).unwrap_or_else(|| "None".to_string()),
        key_id.map(|v| format!("Some(\"{}\")", xor_encode(&v))).unwrap_or_else(|| "None".to_string()),
        team_id.map(|v| format!("Some(\"{}\")", xor_encode(&v))).unwrap_or_else(|| "None".to_string()),
        bundle_id.map(|v| format!("Some(\"{}\")", xor_encode(&v))).unwrap_or_else(|| "None".to_string()),
    );

    fs::write(&dest_path, code).unwrap();

    println!("cargo:rerun-if-env-changed=APNS_KEY_BASE64");
    println!("cargo:rerun-if-env-changed=APNS_KEY_ID");
    println!("cargo:rerun-if-env-changed=APNS_TEAM_ID");
    println!("cargo:rerun-if-env-changed=APNS_BUNDLE_ID");
}
