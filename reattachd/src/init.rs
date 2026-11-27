use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use crate::auth::AuthService;

const SERVICE_LABEL: &str = "tokyo.kumabook.reattachd";
const SETUP_GUIDE: &str = "https://reattach.tmux.kumabook.tokyo/setup.html";
const CLOUDFLARE_GUIDE: &str = "https://reattach.tmux.kumabook.tokyo/cloudflare.html";

const SERVER_URL_FILE: &str = "server_url";

/// The URL `reattachd init` chose, so `reattachd setup` can pair more devices without flags.
pub fn saved_server_url(data_dir: &Path) -> Option<String> {
    std::fs::read_to_string(data_dir.join(SERVER_URL_FILE))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

pub struct InitOptions {
    pub url: Option<String>,
    pub service: bool,
    pub hooks: bool,
    pub yes: bool,
}

enum Connection {
    Tailscale { hostname: String, ipv4: String },
    Url(String),
}

impl Connection {
    fn server_url(&self, port: u16) -> String {
        match self {
            Connection::Tailscale { hostname, .. } => format!("https://{}:{}", hostname, port),
            Connection::Url(url) => url.trim_end_matches('/').to_string(),
        }
    }

    fn daemon_args(&self) -> Vec<String> {
        match self {
            Connection::Tailscale { .. } => vec!["--tailscale".into()],
            Connection::Url(_) => vec![],
        }
    }

    fn local_addr(&self, port: u16) -> String {
        match self {
            Connection::Tailscale { ipv4, .. } => format!("{}:{}", ipv4, port),
            Connection::Url(_) => format!("{}:{}", crate::DEFAULT_BIND_ADDR, port),
        }
    }
}

pub async fn run(data_dir: PathBuf, options: InitOptions) {
    let port = crate::configured_port();
    println!("Setting up reattachd\n");

    step("tmux");
    match Command::new("tmux").arg("-V").output() {
        Ok(out) if out.status.success() => {
            done(String::from_utf8_lossy(&out.stdout).trim());
        }
        _ => warn("tmux was not found. Install it before using Reattach (e.g. brew install tmux)."),
    }

    step("Connection");
    let connection = match detect_connection(options.url, &data_dir) {
        Ok(connection) => connection,
        Err(message) => {
            eprintln!("\n{}", message);
            std::process::exit(1);
        }
    };
    let server_url = connection.server_url(port);
    done(&server_url);
    if let Err(e) = std::fs::create_dir_all(&data_dir)
        .and_then(|_| std::fs::write(data_dir.join(SERVER_URL_FILE), &server_url))
    {
        warn(&format!("Could not save the server URL: {}", e));
    }

    step("Background service");
    if !options.service {
        done("skipped (--no-service)");
        let command = std::iter::once(current_exe().display().to_string())
            .chain(connection.daemon_args())
            .collect::<Vec<_>>()
            .join(" ");
        println!("    Start it yourself with: {}", command);
    } else if is_listening(&connection.local_addr(port)) {
        done("reattachd is already running");
    } else {
        match install_service(&connection) {
            Ok(summary) => done(&summary),
            Err(e) => {
                eprintln!("\nCould not install the background service: {}", e);
                eprintln!("Run `reattachd init --no-service` and start reattachd yourself.");
                std::process::exit(1);
            }
        }
    }

    step("Coding agent notifications");
    if !options.hooks {
        done("skipped (--no-hooks)");
    } else if options.yes
        || confirm(
            "Install notification hooks for Claude Code and Codex?",
            true,
        )
    {
        crate::install_claude_hooks();
        crate::install_codex_hooks();
    } else {
        done("skipped. Run `reattachd hooks install` later to enable them.");
    }

    if options.service && !wait_until_listening(&connection.local_addr(port)).await {
        warn("reattachd has not started yet. Check its log if pairing fails.");
    }

    if let Some(app) = mac_app() {
        step("Reattach for Mac");
        if options.yes || confirm("Connect Reattach for Mac on this computer too?", true) {
            let local_url = match &connection {
                Connection::Tailscale { .. } => server_url.clone(),
                Connection::Url(_) => format!("http://127.0.0.1:{}", port),
            };
            match pair_mac_app(&data_dir, &app, &local_url).await {
                Ok(()) => done("connected"),
                Err(e) => warn(&format!(
                    "{} Paste the URL below into Reattach for Mac's settings instead.",
                    e
                )),
            }
        } else {
            done("skipped. Paste the URL below into Reattach for Mac's settings to connect it later.");
        }
    }

    let auth = AuthService::new(data_dir)
        .await
        .expect("Failed to initialize auth service");
    let token = auth
        .generate_setup_token(false, chrono::Duration::minutes(10))
        .await;
    crate::print_setup_qr(
        &format!("{}?setup_token={}", server_url, token),
        &crate::token_note_from_expires("10m", false),
    );
    println!("\n  Open Reattach on your iPhone and tap \"Scan QR Code to Connect\".");
    println!("  To pair another device later, run `reattachd setup`.\n");
}

fn mac_app() -> Option<PathBuf> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let home = dirs::home_dir().map(|h| h.join("Applications/Reattach.app"));
    [Some(PathBuf::from("/Applications/Reattach.app")), home]
        .into_iter()
        .flatten()
        // The iPad app on Apple silicon also installs as Reattach.app, but has no Contents/MacOS.
        .filter(|app| app.join("Contents/MacOS").is_dir())
        .find(|app| supports_pairing_links(&app.join("Contents/Info.plist")))
}

// Versions before 2.1 do not handle reattach-mac:// links. Info.plist may be binary,
// but the scheme name is stored as plain bytes either way.
fn supports_pairing_links(info_plist: &Path) -> bool {
    std::fs::read(info_plist)
        .map(|bytes| bytes.windows(12).any(|w| w == b"reattach-mac"))
        .unwrap_or(false)
}

/// Hands a setup token to Reattach for Mac and waits for it to register, so the
/// next token (for the iPhone QR code) does not replace one it still needs.
async fn pair_mac_app(data_dir: &Path, app: &Path, server_url: &str) -> Result<(), String> {
    let devices = || async {
        AuthService::new(data_dir.to_path_buf())
            .await
            .map_err(|e| e.to_string())
    };
    let before = devices().await?.list_devices().await.len();
    let token = devices()
        .await?
        .generate_setup_token(false, chrono::Duration::minutes(10))
        .await;
    let link = format!(
        "reattach-mac://pair?server={}&setup_token={}",
        percent_encode(server_url),
        token
    );
    run_command(Command::new("open").arg("-a").arg(app).arg(&link))?;
    println!("    Choose \"Connect\" in Reattach for Mac.");
    for _ in 0..120 {
        tokio::time::sleep(Duration::from_secs(1)).await;
        if devices().await?.list_devices().await.len() > before {
            return Ok(());
        }
    }
    Err("Reattach for Mac did not finish connecting.".into())
}

fn percent_encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{:02X}", b),
        })
        .collect()
}

fn detect_connection(url: Option<String>, data_dir: &Path) -> Result<Connection, String> {
    if let Some(url) = url {
        if !url.starts_with("https://") {
            return Err("--url must start with https:// so the app can connect securely.".into());
        }
        return Ok(Connection::Url(url));
    }
    let info = crate::get_tailscale_info().map_err(|e| {
        format!(
            "Reattach needs a way for your phone to reach this computer ({}).\n\n\
             • Tailscale (recommended): install Tailscale on this computer and your phone,\n  \
               sign in to both, enable HTTPS certificates in the admin console,\n  \
               then run `reattachd init` again.\n\
             • Cloudflare Tunnel or another HTTPS proxy: run\n  \
               `reattachd init --url https://your-host.example.com`\n  \
               Guide: {}\n\n\
             Setup guide: {}",
            e, CLOUDFLARE_GUIDE, SETUP_GUIDE
        )
    })?;
    crate::generate_tailscale_certs(&info.hostname, data_dir).map_err(|e| {
        format!(
            "{}\n\nOn Linux, allow your user to request certificates with\n  \
             sudo tailscale set --operator=$USER\nthen run `reattachd init` again.",
            e
        )
    })?;
    Ok(Connection::Tailscale {
        hostname: info.hostname,
        ipv4: info.ipv4,
    })
}

fn install_service(connection: &Connection) -> Result<String, String> {
    let exe = current_exe();
    let path_env = std::env::var("PATH").unwrap_or_default();
    let home = dirs::home_dir().ok_or("home directory not found")?;
    if cfg!(target_os = "macos") {
        let log_dir = home.join("Library/Logs/Reattach");
        std::fs::create_dir_all(&log_dir).map_err(|e| e.to_string())?;
        let plist = home.join(format!("Library/LaunchAgents/{}.plist", SERVICE_LABEL));
        if let Some(dir) = plist.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        std::fs::write(
            &plist,
            launchd_plist(&exe, &connection.daemon_args(), &path_env, &log_dir),
        )
        .map_err(|e| e.to_string())?;
        let domain = format!("gui/{}", uid()?);
        let _ = Command::new("launchctl")
            .args(["bootout", &format!("{}/{}", domain, SERVICE_LABEL)])
            .output();
        run_command(
            Command::new("launchctl")
                .args(["bootstrap", &domain])
                .arg(&plist),
        )?;
        Ok(format!(
            "started at login ({}), log: {}",
            plist.display(),
            log_dir.join("reattachd.log").display()
        ))
    } else if cfg!(target_os = "linux") {
        let unit = home.join(".config/systemd/user/reattachd.service");
        if let Some(dir) = unit.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        std::fs::write(
            &unit,
            systemd_unit(&exe, &connection.daemon_args(), &path_env),
        )
        .map_err(|e| e.to_string())?;
        run_command(Command::new("systemctl").args(["--user", "daemon-reload"]))?;
        run_command(Command::new("systemctl").args(["--user", "enable", "--now", "reattachd"]))?;
        Ok(format!(
            "systemd user service ({}). To keep it running after logout: loginctl enable-linger $USER",
            unit.display()
        ))
    } else {
        Err("only macOS and Linux are supported".into())
    }
}

fn launchd_plist(exe: &Path, args: &[String], path_env: &str, log_dir: &Path) -> String {
    let arguments: String = std::iter::once(exe.display().to_string())
        .chain(args.iter().cloned())
        .map(|a| format!("        <string>{}</string>\n", xml_escape(&a)))
        .collect();
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
{arguments}    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{log}/reattachd.log</string>
    <key>StandardErrorPath</key>
    <string>{log}/reattachd.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>{path}</string>
    </dict>
</dict>
</plist>
"#,
        label = SERVICE_LABEL,
        arguments = arguments,
        log = xml_escape(&log_dir.display().to_string()),
        path = xml_escape(path_env),
    )
}

fn systemd_unit(exe: &Path, args: &[String], path_env: &str) -> String {
    let command = std::iter::once(exe.display().to_string())
        .chain(args.iter().cloned())
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "[Unit]\nDescription=Reattach daemon\nAfter=network-online.target\n\n\
         [Service]\nExecStart={}\nEnvironment=\"PATH={}\"\nRestart=on-failure\n\n\
         [Install]\nWantedBy=default.target\n",
        command, path_env
    )
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

// Prefer the PATH entry (e.g. Homebrew's /opt/homebrew/bin symlink) so the service
// survives upgrades that move the versioned binary.
fn current_exe() -> PathBuf {
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("reattachd"));
    let resolved = exe.canonicalize().ok();
    std::env::var_os("PATH")
        .and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|dir| dir.join("reattachd"))
                .find(|candidate| candidate.canonicalize().ok() == resolved && resolved.is_some())
        })
        .unwrap_or(exe)
}

fn uid() -> Result<String, String> {
    let out = Command::new("id")
        .arg("-u")
        .output()
        .map_err(|e| e.to_string())?;
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn run_command(command: &mut Command) -> Result<(), String> {
    let out = command.output().map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

fn is_listening(addr: &str) -> bool {
    addr.parse()
        .ok()
        .and_then(|a| std::net::TcpStream::connect_timeout(&a, Duration::from_millis(300)).ok())
        .is_some()
}

async fn wait_until_listening(addr: &str) -> bool {
    for _ in 0..40 {
        if is_listening(addr) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    false
}

fn confirm(question: &str, default: bool) -> bool {
    if !std::io::stdin().is_terminal() {
        return default;
    }
    print!(
        "    {} [{}] ",
        question,
        if default { "Y/n" } else { "y/N" }
    );
    let _ = std::io::stdout().flush();
    let mut answer = String::new();
    if std::io::stdin().lock().read_line(&mut answer).is_err() {
        return default;
    }
    match answer.trim().to_lowercase().as_str() {
        "" => default,
        a => a.starts_with('y'),
    }
}

fn step(name: &str) {
    println!("• {}", name);
}

fn done(message: &str) {
    println!("    {}", message);
}

fn warn(message: &str) {
    println!("    ! {}", message);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launchd_plist_runs_the_daemon_with_its_arguments() {
        let plist = launchd_plist(
            Path::new("/opt/homebrew/bin/reattachd"),
            &["--tailscale".into()],
            "/usr/bin:/bin",
            Path::new("/Users/me/Library/Logs/Reattach"),
        );
        assert!(plist.contains(
            "<string>/opt/homebrew/bin/reattachd</string>\n        <string>--tailscale</string>"
        ));
        assert!(plist.contains("<string>/usr/bin:/bin</string>"));
        assert!(plist.contains(SERVICE_LABEL));
    }

    #[test]
    fn systemd_unit_runs_the_daemon_with_its_arguments() {
        let unit = systemd_unit(Path::new("/usr/local/bin/reattachd"), &[], "/usr/bin");
        assert!(unit.contains("ExecStart=/usr/local/bin/reattachd\n"));
        assert!(unit.contains("Environment=\"PATH=/usr/bin\""));
    }

    #[test]
    fn mac_apps_without_the_pairing_scheme_are_skipped() {
        let dir = std::env::temp_dir().join(format!("reattach-plist-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let old = dir.join("old.plist");
        let new = dir.join("new.plist");
        std::fs::write(
            &old,
            "<plist><dict><key>LSUIElement</key><true/></dict></plist>",
        )
        .unwrap();
        std::fs::write(&new, "<array><string>reattach-mac</string></array>").unwrap();
        assert!(!supports_pairing_links(&old));
        assert!(supports_pairing_links(&new));
        assert!(!supports_pairing_links(&dir.join("missing.plist")));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn mac_pairing_links_encode_the_server_url() {
        assert_eq!(
            percent_encode("https://mac.tail.ts.net:8787"),
            "https%3A%2F%2Fmac.tail.ts.net%3A8787"
        );
    }

    #[test]
    fn urls_must_use_https() {
        let dir = std::env::temp_dir();
        assert!(detect_connection(Some("http://host".into()), &dir).is_err());
        let connection = detect_connection(Some("https://host/".into()), &dir).unwrap();
        assert_eq!(connection.server_url(8787), "https://host");
        assert!(connection.daemon_args().is_empty());
    }
}
