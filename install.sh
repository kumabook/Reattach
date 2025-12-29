#!/bin/sh
set -e

REPO="kumabook/Reattach"
BINARY="reattachd"

# Detect OS
OS="$(uname -s)"
case "$OS" in
    Linux*)  OS_NAME="linux";;
    Darwin*) OS_NAME="darwin";;
    *)       echo "Unsupported OS: $OS"; exit 1;;
esac

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  ARCH_NAME="x86_64";;
    aarch64) ARCH_NAME="aarch64";;
    arm64)   ARCH_NAME="aarch64";;
    *)       echo "Unsupported architecture: $ARCH"; exit 1;;
esac

PLATFORM="${OS_NAME}-${ARCH_NAME}"
echo "Detected platform: $PLATFORM"

# Get latest release version
if command -v curl > /dev/null 2>&1; then
    LATEST=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
elif command -v wget > /dev/null 2>&1; then
    LATEST=$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
else
    echo "Error: curl or wget is required"
    exit 1
fi

if [ -z "$LATEST" ]; then
    echo "Error: Could not determine latest version"
    exit 1
fi

echo "Latest version: $LATEST"

# Download URL
URL="https://github.com/$REPO/releases/download/$LATEST/reattachd-$PLATFORM.tar.gz"
echo "Downloading from: $URL"

# Create temp directory
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Download and extract
if command -v curl > /dev/null 2>&1; then
    curl -sL "$URL" | tar xz -C "$TMP_DIR"
else
    wget -qO- "$URL" | tar xz -C "$TMP_DIR"
fi

# Install
INSTALL_DIR="/usr/local/bin"
if [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

mv "$TMP_DIR/$BINARY" "$INSTALL_DIR/$BINARY"
chmod +x "$INSTALL_DIR/$BINARY"

echo ""
echo "Installed $BINARY to $INSTALL_DIR/$BINARY"
echo ""

# Check if in PATH
if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
    echo "Add $INSTALL_DIR to your PATH:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
fi

echo "Run 'reattachd --help' to get started"
