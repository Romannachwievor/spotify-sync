#!/bin/bash
set -euo pipefail

# ============================================================
# Spotify → Soulseek Auto Sync — One-Time Setup
# ============================================================

SYNC_DIR="$HOME/spotify-sync"
DOWNLOAD_DIR="$HOME/Downloads/spotify-sync"
CONFIG_DIR="$HOME/.config/sldl"
PLIST_NAME="com.spotify-sync.plist"
PLIST_DIR="$HOME/Library/LaunchAgents"

echo "=============================="
echo " Spotify Sync — Setup"
echo "=============================="

# --- 1. Install .NET runtime (required for sldl) ---
if ! command -v dotnet &>/dev/null; then
    echo ""
    echo "[1/5] Installing .NET runtime via Homebrew..."
    if ! command -v brew &>/dev/null; then
        echo "ERROR: Homebrew is not installed. Install it from https://brew.sh first."
        exit 1
    fi
    brew install --cask dotnet-sdk
else
    echo "[1/5] .NET runtime already installed ✓"
fi

# --- 2. Install sldl ---
if ! command -v sldl &>/dev/null; then
    echo ""
    echo "[2/6] Installing sldl..."
    dotnet tool install --global sldl
    # Make sure dotnet tools are on PATH
    export PATH="$HOME/.dotnet/tools:$PATH"
    if ! command -v sldl &>/dev/null; then
        echo "WARNING: sldl installed but not on PATH."
        echo "Add this to your ~/.zshrc:"
        echo '  export PATH="$HOME/.dotnet/tools:$PATH"'
    fi
else
    echo "[2/6] sldl already installed ✓"
fi

# --- 2b. Install yt-dlp + ffmpeg (Tier-3 fallback) ---
echo ""
if ! command -v yt-dlp &>/dev/null; then
    echo "[2b/6] Installing yt-dlp..."
    brew install yt-dlp
else
    echo "[2b/6] yt-dlp already installed ✓"
fi
if ! command -v ffmpeg &>/dev/null; then
    echo "[2b/6] Installing ffmpeg (required by yt-dlp)..."
    brew install ffmpeg
else
    echo "[2b/6] ffmpeg already installed ✓"
fi

# --- 3. Pioneer device FLAC support ---
echo ""
echo "[3/7] Pioneer device FLAC compatibility..."
echo ""
echo "  FLAC is supported in rekordbox/Serato on your Mac (all controllers)."
echo "  However, standalone Pioneer players playing from USB have varying support:"
echo "    ✓ FLAC supported : CDJ-3000, XDJ-XZ, XDJ-RX3, XDJ-RX2, CDJ-2000NXS2"
echo "    ✗ No FLAC support: CDJ-2000, CDJ-900, XDJ-700, XDJ-RX (1st gen), CDJ-400"
echo ""
read -rp "  Does your Pioneer device support FLAC? [y/n]: " FLAC_ANSWER
FLAC_ANSWER="${FLAC_ANSWER,,}"  # lowercase

SYNC_CONFIG="$SYNC_DIR/.sync-config"
if [[ "$FLAC_ANSWER" == "n" || "$FLAC_ANSWER" == "no" ]]; then
    echo "CONVERT_FLAC=true" > "$SYNC_CONFIG"
    echo "  → FLAC files will be auto-converted to MP3 320kbps after each sync. ✓"
else
    echo "CONVERT_FLAC=false" > "$SYNC_CONFIG"
    echo "  → FLAC files will be kept as-is. ✓"
fi

# --- 4. Configure sldl ---
echo ""
echo "[4/7] Configuring sldl..."
mkdir -p "$CONFIG_DIR"
mkdir -p "$DOWNLOAD_DIR"

if [ ! -f "$CONFIG_DIR/sldl.conf" ]; then
    echo ""
    echo "Enter your Soulseek credentials:"
    read -rp "  Username: " SLSK_USER
    read -rsp "  Password: " SLSK_PASS
    echo ""

    cat > "$CONFIG_DIR/sldl.conf" <<EOF
# sldl configuration
username = ${SLSK_USER}
password = ${SLSK_PASS}

# Download settings
path = ${DOWNLOAD_DIR}
pref-format = flac
fast-search = true
name-format = {artist( - )title|slsk-filename}

# Skip already downloaded
index-path = ${SYNC_DIR}/spotify-sync-index.sldl

# Rate limiting (avoid Soulseek bans)
searches-per-time = 34
searches-renew-time = 220
concurrent-downloads = 2

# Spotify sync profile
[spotify-sync]
input = https://open.spotify.com/playlist/4LOohrrkB5MTyYAAdnQg1x
profile-cond = input-type == "spotify"
EOF
    echo "Config written to $CONFIG_DIR/sldl.conf ✓"
else
    echo "Config already exists at $CONFIG_DIR/sldl.conf ✓"
    echo "Make sure your Soulseek credentials and Spotify playlist URL are set."
fi

# --- 4. Set up the sync script ---
echo ""
echo "[5/7] Setting up sync script..."
chmod +x "$SYNC_DIR/sync.sh"
echo "Sync script ready at $SYNC_DIR/sync.sh ✓"

# --- 5. Install launchd schedule (every hour) ---
echo ""
echo "[6/7] Setting up hourly schedule..."
cp "$SYNC_DIR/$PLIST_NAME" "$PLIST_DIR/$PLIST_NAME"

# Unload if already loaded, then load
launchctl bootout "gui/$(id -u)" "$PLIST_DIR/$PLIST_NAME" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DIR/$PLIST_NAME"

echo "Hourly sync scheduled ✓"

# --- 6. Verify yt-dlp fallback ---
echo ""
echo "[7/7] Verifying yt-dlp fallback..."
if command -v yt-dlp &>/dev/null && command -v ffmpeg &>/dev/null; then
    echo "yt-dlp $(yt-dlp --version) + ffmpeg ready ✓"
else
    echo "WARNING: yt-dlp or ffmpeg not found — Tier-3 fallback disabled."
fi

echo ""
echo "=============================="
echo " Setup Complete!"
echo "=============================="
echo ""
echo "Your songs will download to: $DOWNLOAD_DIR"
echo ""
echo "Commands:"
echo "  ~/spotify-sync/sync.sh          — Sync now"
echo "  ~/spotify-sync/sync.sh --dry    — Preview what would download"
echo ""
echo "To change settings, edit: $CONFIG_DIR/sldl.conf"
echo "To stop auto-sync:"
echo "  launchctl bootout gui/$(id -u) $PLIST_DIR/$PLIST_NAME"
echo ""
