# Reattach

**Reattach** is a remote tmux client for iOS — control your Mac's terminal sessions from anywhere.

With optional coding agent integration, get push notifications when Claude Code or other AI assistants need your input.

## Concept

```
┌─────────────────┐
│   iOS App       │
│  (iPhone/iPad)  │
└────────┬────────┘
         │ HTTPS
         ▼
┌─────────────────┐
│ Cloudflare      │
│ Tunnel          │
└────────┬────────┘
         │ localhost:8787
         ▼
┌─────────────────┐
│ reattachd       │──────► tmux
│ (Rust daemon)   │
└─────────────────┘
      Your Mac
```

- **Remote tmux access**: View and control tmux sessions from your iPhone/iPad
- **Secure access**: Cloudflare Tunnel provides HTTPS without exposing ports
- **Coding agent friendly**: Optional hooks for Claude Code push notifications
- **Simple architecture**: reattachd is just a thin wrapper around tmux

## Components

| Component | Description |
|-----------|-------------|
| `reattachd` | Rust daemon that exposes tmux sessions via HTTP API |
| `ios/` | iOS app for remote session control |
| `hooks/` | Optional hooks for coding agent notifications |
| `launchd/` | macOS service configuration |

## Requirements

- macOS or Linux
- [tmux](https://github.com/tmux/tmux)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) (optional, for remote access)

## Installation

### 1. Install reattachd

```bash
curl -fsSL https://raw.githubusercontent.com/kumabook/Reattach/main/install.sh | sh
```

### 2. Setup daemon

#### macOS (launchd)

```bash
# Create log directory
mkdir -p ~/Library/Logs/Reattach

# Create plist file
cat > ~/Library/LaunchAgents/com.kumabook.reattachd.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.kumabook.reattachd</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/reattachd</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>~/Library/Logs/Reattach/reattachd.log</string>
    <key>StandardErrorPath</key>
    <string>~/Library/Logs/Reattach/reattachd.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>REATTACHD_PORT</key>
        <string>8787</string>
        <!-- Uncomment to allow local network access (default: 127.0.0.1) -->
        <!-- <key>REATTACHD_BIND_ADDR</key> -->
        <!-- <string>0.0.0.0</string> -->
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF

# Load and start
launchctl load ~/Library/LaunchAgents/com.kumabook.reattachd.plist
```

#### Linux (systemd)

```bash
# Create service file
sudo tee /etc/systemd/system/reattachd.service << 'EOF'
[Unit]
Description=Reattach Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/reattachd
Restart=always
Environment=REATTACHD_PORT=8787
# Uncomment to allow local network access (default: 127.0.0.1)
# Environment=REATTACHD_BIND_ADDR=0.0.0.0

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable reattachd
sudo systemctl start reattachd
```

### 3. Configure network access

Choose how your iOS device will connect to reattachd:

#### Local network

Use your machine's local IP address directly. No additional setup required.

```
URL: http://192.168.x.x:8787
```

#### VPN

If you have a VPN setup, use the machine's IP address on the VPN network.

```
URL: http://<vpn-ip>:8787
```

#### Cloudflare Tunnel

For secure remote access without exposing ports, set up [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/):

```bash
# Create tunnel
cloudflared tunnel create reattach

# Configure tunnel (edit ~/.cloudflared/config.yml)
tunnel: reattach
credentials-file: /path/to/credentials.json

ingress:
  - hostname: your-domain.example.com
    service: http://localhost:8787
  - service: http_status:404

# Start tunnel
cloudflared tunnel run reattach
```

```
URL: https://your-domain.example.com
```

> **Security**: Since Reattach allows remote command execution, you should configure authentication via [Cloudflare Zero Trust](https://developers.cloudflare.com/cloudflare-one/). Add an Access Application policy to restrict access to your tunnel hostname.

### 4. Install iOS app

Download from the App Store, or build from source (see [Development](#development)).

## Usage

### Start a tmux session

```bash
tmux
```

You can also name the session and set the working directory:

```bash
tmux new-session -s myproject -c ~/projects/myproject
```

### Register your device

Generate a QR code to register your iOS device. Use the URL from your network configuration above:

```bash
reattachd setup --url <your-url>
```

Scan the QR code with the Reattach iOS app to complete registration.

### Control from iOS

1. Open the Reattach app
2. Your tmux sessions appear in the list
3. Tap a session to view output and send input

## Development

### Requirements

- [Rust](https://rustup.rs/)
- Xcode (for iOS app)
- Apple Developer account (for push notifications)

### Build from source

```bash
git clone https://github.com/kumabook/Reattach.git
cd Reattach

# Copy sample configs
cp config.local.mk.sample config.local.mk
cp ios/Reattach/Config.xcconfig.sample ios/Reattach/Config.xcconfig

# Edit with your values
vim config.local.mk        # APNs credentials
vim ios/Reattach/Config.xcconfig  # Server URL

# Build and install daemon
make build
make install
make start
```

### Configuration

#### config.local.mk

```makefile
APNS_KEY_PATH = /path/to/AuthKey.p8
APNS_KEY_ID = XXXXXXXXXX
APNS_TEAM_ID = XXXXXXXXXX
APNS_BUNDLE_ID = tokyo.kumabook.tmux.reattach
```

#### ios/Reattach/Config.xcconfig

```
BASE_URL = https:/$()/your-domain.example.com
```

### Makefile Commands

```bash
make build          # Build reattachd
make install        # Install launchd services
make uninstall      # Remove launchd services
make start          # Start services
make stop           # Stop services
make restart        # Restart services
make reinstall      # Rebuild, reinstall, and restart
make logs           # View logs
make status         # Check service status
make install-hooks  # Install Claude Code notification hooks
```

### Build iOS app

Open `ios/Reattach.xcodeproj` in Xcode and build to your device.

## Security

⚠️ **Use at your own risk.** Reattach allows remote command execution on your machine. Please understand the security implications before using this software.

### Network Binding

reattachd binds to `127.0.0.1:8787` by default (localhost only). This is secure by default - only local processes and tunnels can access the API.

To change the port or bind address:

```bash
REATTACHD_PORT=9000 reattachd
REATTACHD_BIND_ADDR=0.0.0.0 reattachd  # Listen on all interfaces (use with caution)
```

For remote access, use Cloudflare Tunnel (connects to localhost) or explicitly set `REATTACHD_BIND_ADDR=0.0.0.0` with appropriate firewall rules.

### Authentication

reattachd includes device-based authentication:
- Devices must be registered via QR code (setup token)
- Each device receives a unique token for API access
- Unregistered devices cannot access the API

### Cloudflare Tunnel (Recommended for remote access)

When exposing reattachd to the internet via Cloudflare Tunnel, we strongly recommend adding an extra layer of security with [Cloudflare Zero Trust](https://developers.cloudflare.com/cloudflare-one/):

1. Create an Access Application for your tunnel hostname
2. Configure authentication policies (e.g., email OTP, SSO)
3. Enable the Cloudflare Access service token or identity verification

This provides defense-in-depth: even if someone obtains a device token, they still need to pass Cloudflare's authentication.

### Recommendations

- Use HTTPS (via Cloudflare Tunnel or your own certificates)
- Regularly review registered devices (`reattachd devices list`)
- Revoke unused devices (`reattachd devices revoke <id>`)
- Monitor reattachd logs for suspicious activity

## License

MIT
