# Reattach

**Reattach** lets you control your local **Claude Code / Codex CLI** sessions from your iPhone.

Run Claude Code in tmux on your Mac, then monitor and interact with it remotely — all while keeping execution entirely local.

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
│ reattachd       │──────► tmux ──────► Claude Code
│ (Rust daemon)   │
└─────────────────┘
      Your Mac
```

- **Local execution**: All code runs on your Mac, not in the cloud
- **Secure access**: Cloudflare Tunnel provides HTTPS without exposing ports
- **Push notifications**: Get notified when Claude Code needs your input
- **Simple architecture**: reattachd is just a thin wrapper around tmux

## Components

| Component | Description |
|-----------|-------------|
| `reattachd` | Rust daemon that exposes tmux sessions via HTTP API |
| `ios/` | iOS app for remote session control |
| `hooks/` | Claude Code hooks for push notifications |
| `launchd/` | macOS service configuration |

## Requirements

- macOS
- [Rust](https://rustup.rs/)
- [tmux](https://github.com/tmux/tmux)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) (cloudflared)
- Xcode (for iOS app)
- Apple Developer account (for push notifications)

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/kumabook/Reattach.git
cd Reattach

# Copy sample configs
cp config.local.mk.sample config.local.mk
cp ios/Reattach/Config.xcconfig.sample ios/Reattach/Config.xcconfig

# Edit with your values
vim config.local.mk        # APNs credentials
vim ios/Reattach/Config.xcconfig  # Server URL
```

### 2. Build and install daemon

```bash
make build
make install
make start
```

### 3. Configure Cloudflare Tunnel

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

> **Security**: Since Reattach allows remote command execution, you should configure authentication via [Cloudflare Zero Trust](https://developers.cloudflare.com/cloudflare-one/). Add an Access Application policy to restrict access to your tunnel hostname.

### 4. Build iOS app

Open `ios/Reattach.xcodeproj` in Xcode and build to your device.

### 5. Install Claude Code hooks (optional)

For push notifications when Claude Code stops:

```bash
make install-hooks
```

## Usage

### Start a Claude Code session in tmux

```bash
tmux new-session -s claude-myproject -c ~/projects/myproject
claude
```

### Control from iOS

1. Open the Reattach app
2. Your tmux sessions appear in the list
3. Tap a session to view output and send input

## Makefile Commands

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

## Configuration

### config.local.mk

```makefile
APNS_KEY_PATH = /path/to/AuthKey.p8
APNS_KEY_ID = XXXXXXXXXX
APNS_TEAM_ID = XXXXXXXXXX
APNS_BUNDLE_ID = tokyo.kumabook.tmux.reattach
```

### ios/Reattach/Config.xcconfig

```
BASE_URL = https:/$()/your-domain.example.com
```

## License

MIT
