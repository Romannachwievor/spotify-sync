#!/bin/bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════╗
# ║          Spotify Sync — Automatic Playlist Downloader       ║
# ║                        for macOS                            ║
# ╚══════════════════════════════════════════════════════════════╝
#
#  HOW TO RUN:
#    1. Open Terminal (Cmd+Space, type "Terminal", press Enter)
#    2. Drag this file into Terminal and press Enter
#       — OR type: bash ~/Downloads/spotify-sync-install.sh
#
#  WHAT YOU'LL NEED:
#    • A free Soulseek account (the installer will show you where)
#    • Your Spotify playlist link
#

# ── Colors & helpers ──────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}${BOLD}    Spotify Sync — Automatic Playlist Downloader    ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

step() { echo -e "\n${BLUE}[$1/$TOTAL_STEPS]${NC} ${BOLD}$2${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${DIM}$1${NC}"; }

press_enter() {
    echo ""
    read -rp "  Press Enter to continue..."
}

TOTAL_STEPS=4

# ── Paths ─────────────────────────────────────────────────────

SYNC_DIR="$HOME/spotify-sync"
SLDL_BIN="$SYNC_DIR/sldl"
CONFIG_DIR="$HOME/.config/sldl"
PLIST_NAME="com.spotify-sync.plist"
PLIST_DIR="$HOME/Library/LaunchAgents"
SLDL_VERSION="v2.7.0-dev"

# ── Start ─────────────────────────────────────────────────────

clear
banner

echo -e "  Welcome! This installs automatic Spotify playlist syncing."
echo -e "  Songs are downloaded from Soulseek in the quality you choose."
echo ""
echo -e "  ${DIM}Takes about 2 minutes. Here's what happens:${NC}"
echo -e "  ${DIM}  1. Downloads the sldl music tool${NC}"
echo -e "  ${DIM}  2. Asks for your accounts + preferences${NC}"
echo -e "  ${DIM}  3. Sets up automatic background syncing${NC}"
echo ""
echo -e "  Songs will be saved to: ${BOLD}~/Downloads/spotify-sync/${NC}"

press_enter

# ══════════════════════════════════════════════════════════════
# STEP 1: Download sldl binary from GitHub
# ══════════════════════════════════════════════════════════════

step 1 "Installing sldl (Soulseek download engine)..."

mkdir -p "$SYNC_DIR"

if [ -x "$SLDL_BIN" ] && "$SLDL_BIN" --help &>/dev/null 2>&1; then
    ok "sldl already installed and working"
else
    # ── Detect OS ──────────────────────────────────────────────
    OS="$(uname -s)"
    if [ "$OS" != "Darwin" ]; then
        fail "This installer only supports macOS (detected: $OS)."
        exit 1
    fi

    # ── Detect CPU architecture ────────────────────────────────
    # Use sysctl to get the real hardware architecture, because
    # uname -m returns x86_64 when running under Rosetta 2.
    HW_ARCH="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
    if [ "$HW_ARCH" = "1" ]; then
        ARCH="arm64"
        SLDL_ZIP="sldl_osx-arm64.zip"   # Apple Silicon (M1/M2/M3/M4)
    else
        # Genuine Intel Mac
        ARCH="x86_64"
        SLDL_ZIP="sldl_osx-x64.zip"
    fi

    DOWNLOAD_URL="https://github.com/fiso64/sldl/releases/download/${SLDL_VERSION}/${SLDL_ZIP}"

    info "Detected: macOS $ARCH — downloading $SLDL_ZIP..."
    curl -fsSL --progress-bar "$DOWNLOAD_URL" -o "/tmp/sldl.zip"

    info "Extracting..."
    unzip -q -o "/tmp/sldl.zip" -d "$SYNC_DIR/"
    rm "/tmp/sldl.zip"

    # The zip may extract to a subfolder — find the binary
    FOUND_BIN="$(find "$SYNC_DIR" -maxdepth 3 -type f -name "sldl" | grep -v '\.zip' | head -1)"
    if [ -z "$FOUND_BIN" ]; then
        fail "Could not find sldl binary after extraction. Check your internet connection and try again."
        exit 1
    fi
    [ "$FOUND_BIN" != "$SLDL_BIN" ] && mv "$FOUND_BIN" "$SLDL_BIN"
    chmod +x "$SLDL_BIN"

    # Remove macOS quarantine flag
    xattr -cr "$SLDL_BIN" 2>/dev/null || true

    # Ad-hoc code-sign the binary — required on Apple Silicon for unsigned binaries
    codesign --sign - --force "$SLDL_BIN" 2>/dev/null || true

    # Verify it runs — if not, .NET runtime is likely missing
    if ! "$SLDL_BIN" --help &>/dev/null 2>&1; then
        echo ""
        warn "sldl needs the .NET runtime. Installing via Homebrew..."
        echo ""

        if ! command -v brew &>/dev/null; then
            info "Installing Homebrew first (safe, standard Mac package manager)..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            if [ -f /opt/homebrew/bin/brew ]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [ -f /usr/local/bin/brew ]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
        fi

        brew install --cask dotnet-sdk

        # Re-sign after .NET install (PATH may have changed)
        codesign --sign - --force "$SLDL_BIN" 2>/dev/null || true

        if ! "$SLDL_BIN" --help &>/dev/null 2>&1; then
            fail "sldl still won't run after installing .NET."
            echo ""
            echo -e "  Try this manual fix and then re-run the installer:"
            echo -e "    codesign --sign - --force ~/spotify-sync/sldl"
            echo -e "    ~/spotify-sync/sldl --help"
            exit 1
        fi
    fi

    ok "sldl installed and working"
fi

# ══════════════════════════════════════════════════════════════
# STEP 2: Get your account info
# ══════════════════════════════════════════════════════════════

step 2 "Setting up your accounts..."

mkdir -p "$CONFIG_DIR"

# ── Soulseek account ──

echo ""
echo -e "  ${BOLD}Soulseek Account${NC}"
echo -e "  ────────────────"
echo -e "  Soulseek is a free peer-to-peer music sharing network."
echo -e "  You need a free account to download music."
echo ""
echo -e "  ${YELLOW}Don't have an account yet?${NC}"
echo -e "   1. Go to ${BOLD}https://www.slsknet.org/news/node/1${NC}"
echo -e "   2. Download the app for your OS"
echo -e "   3. Open it and register a username + password"
echo -e "   4. Come back here — ${DIM}you only need the credentials, not the app${NC}"

press_enter

SKIP_CONFIG=false
if [ -f "$CONFIG_DIR/sldl.conf" ]; then
    echo ""
    echo -e "  ${YELLOW}Existing config found at ~/.config/sldl/sldl.conf${NC}"
    read -rp "  Overwrite with new settings? (y/n): " OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
        ok "Keeping existing config"
        PLAYLIST_URL=""
        read -rp "  Enter your Spotify playlist URL: " PLAYLIST_URL
        SKIP_CONFIG=true
    fi
fi

if [ "$SKIP_CONFIG" = false ]; then
    echo ""
    read -rp "  Soulseek username: " SLSK_USER
    while [ -z "$SLSK_USER" ]; do
        warn "Username cannot be empty."
        read -rp "  Soulseek username: " SLSK_USER
    done

    read -rsp "  Soulseek password: " SLSK_PASS
    echo ""
    while [ -z "$SLSK_PASS" ]; do
        warn "Password cannot be empty."
        read -rsp "  Soulseek password: " SLSK_PASS
        echo ""
    done

    ok "Soulseek credentials entered"

    # ── Spotify playlist ──

    echo ""
    echo -e "  ${BOLD}Spotify Playlist${NC}"
    echo -e "  ────────────────"
    echo -e "  In Spotify: right-click your playlist → Share → Copy link to playlist"
    echo -e "  It looks like: ${DIM}https://open.spotify.com/playlist/XXXXXXXXXXXX${NC}"
    echo ""

    read -rp "  Paste your Spotify playlist URL: " PLAYLIST_URL
    while [[ ! "$PLAYLIST_URL" =~ ^https://open\.spotify\.com/playlist/ ]]; do
        warn "That doesn't look right. It should start with: https://open.spotify.com/playlist/"
        read -rp "  Paste your Spotify playlist URL: " PLAYLIST_URL
    done
    PLAYLIST_URL="${PLAYLIST_URL%%\?*}"  # Strip ?si=... tracking param
    ok "Playlist: $PLAYLIST_URL"

    # ── Spotify API credentials ──

    echo ""
    echo -e "  ${BOLD}Spotify API Credentials${NC}"
    echo -e "  ───────────────────────"
    echo -e "  Spotify requires a free developer app to access playlists."
    echo -e "  This takes about 2 minutes to set up:"
    echo ""
    echo -e "   1. Go to ${BOLD}https://developer.spotify.com/dashboard${NC}"
    echo -e "   2. Log in with your Spotify account"
    echo -e "   3. Click ${BOLD}Create app${NC}"
    echo -e "   4. Fill in any name/description, set Redirect URI to:"
    echo -e "      ${BOLD}http://127.0.0.1:48721/callback${NC}"
    echo -e "      (Spotify no longer accepts 'localhost' — use the IP)"
    echo -e "      then tick ${BOLD}Web API${NC} and click Save"
    echo -e "   5. Click ${BOLD}Settings${NC} — copy the ${BOLD}Client ID${NC} and ${BOLD}Client Secret${NC}"

    press_enter

    read -rp "  Spotify Client ID:     " SPOTIFY_ID
    while [ -z "$SPOTIFY_ID" ]; do
        warn "Client ID cannot be empty."
        read -rp "  Spotify Client ID:     " SPOTIFY_ID
    done

    read -rsp "  Spotify Client Secret: " SPOTIFY_SECRET
    echo ""
    while [ -z "$SPOTIFY_SECRET" ]; do
        warn "Client Secret cannot be empty."
        read -rsp "  Spotify Client Secret: " SPOTIFY_SECRET
        echo ""
    done
    ok "Spotify API credentials saved"

    # ── Audio format ──

    echo ""
    echo -e "  ${BOLD}Audio Format${NC}"
    echo -e "  ────────────"
    echo -e "  1) ${BOLD}FLAC${NC} — Lossless, best quality, larger files (~30-50 MB/song)"
    echo -e "  2) ${BOLD}MP3${NC}  — Great quality, smaller files (~5-10 MB/song)"
    echo ""
    read -rp "  Choose [1/2] (default: 1 = FLAC): " FORMAT_CHOICE
    case "${FORMAT_CHOICE:-1}" in
        2) PREF_FORMAT="mp3" ;;
        *) PREF_FORMAT="flac" ;;
    esac
    ok "Format: $PREF_FORMAT"

    # ── Download folder ──

    DOWNLOAD_DIR="$HOME/Downloads/spotify-sync"
    echo ""
    echo -e "  ${BOLD}Download Folder${NC}"
    echo -e "  ───────────────"
    echo -e "  Default: ${BOLD}~/Downloads/spotify-sync/${NC}"
    read -rp "  Press Enter to use default, or type a custom path: " CUSTOM_PATH
    if [ -n "$CUSTOM_PATH" ]; then
        DOWNLOAD_DIR="${CUSTOM_PATH/#\~/$HOME}"
    fi
    mkdir -p "$DOWNLOAD_DIR"
    ok "Download folder: $DOWNLOAD_DIR"

    # ── Write sldl config ──

    cat > "$CONFIG_DIR/sldl.conf" <<SLDL_CONF
# sldl configuration — Spotify Sync
username = ${SLSK_USER}
password = ${SLSK_PASS}

# Spotify API credentials (required even for public playlists)
spotify-id = ${SPOTIFY_ID}
spotify-secret = ${SPOTIFY_SECRET}

path = ${DOWNLOAD_DIR}
pref-format = ${PREF_FORMAT}
fast-search = true
name-format = {artist( - )title|slsk-filename}
index-path = ${SYNC_DIR}/spotify-sync-index.sldl

# Rate limiting (prevents 30-min Soulseek bans)
searches-per-time = 34
searches-renew-time = 220
concurrent-downloads = 2
SLDL_CONF

    ok "Config saved (~/.config/sldl/sldl.conf)"
fi

# Save playlist URL for the sync script
echo "$PLAYLIST_URL" > "$SYNC_DIR/.playlist_url"

# ══════════════════════════════════════════════════════════════
# STEP 3: Create the sync script
# ══════════════════════════════════════════════════════════════

step 3 "Creating sync script..."

cat > "$SYNC_DIR/sync.sh" <<'SYNC_SCRIPT'
#!/bin/bash
set -euo pipefail

SYNC_DIR="$HOME/spotify-sync"
SLDL_BIN="$HOME/spotify-sync/sldl"
LOG_FILE="$SYNC_DIR/sync.log"
TRACKS_FILE="$SYNC_DIR/playlist_tracks.csv"
CONF="$HOME/.config/sldl/sldl.conf"

if [ ! -f "$SYNC_DIR/.playlist_url" ]; then
    echo "ERROR: No playlist URL found. Re-run the installer."
    exit 1
fi
PLAYLIST_URL="$(cat "$SYNC_DIR/.playlist_url")"

# Ensure .NET is findable if installed
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

# Read Spotify credentials from sldl config
SPOTIFY_ID=$(grep '^spotify-id' "$CONF" | awk -F' = ' '{print $2}' | tr -d '[:space:]')
SPOTIFY_SECRET=$(grep '^spotify-secret' "$CONF" | awk -F' = ' '{print $2}' | tr -d '[:space:]')
SPOTIFY_REFRESH=$(grep '^spotify-refresh' "$CONF" | awk -F' = ' '{print $2}' | tr -d '[:space:]')

# Extract playlist ID from URL (e.g. https://open.spotify.com/playlist/XXXXXX)
PLAYLIST_ID=$(echo "$PLAYLIST_URL" | sed 's|.*/playlist/||' | cut -d'?' -f1)

# Fetch current track list from Spotify API (bypasses sldl's broken extractor)
fetch_tracks() {
    python3 "$SYNC_DIR/fetch_tracks.py" \
        "$SPOTIFY_ID" "$SPOTIFY_SECRET" "$SPOTIFY_REFRESH" "$PLAYLIST_ID" "$TRACKS_FILE" 1>&2
}

case "${1:-}" in
    --dry|--preview)
        echo "[$(timestamp)] Fetching playlist tracks..." | tee -a "$LOG_FILE"
        fetch_tracks
        echo "[$(timestamp)] DRY RUN — tracks that would be downloaded:" | tee -a "$LOG_FILE"
        "$SLDL_BIN" "$TRACKS_FILE" \
            --print tracks \
            --index-path "$SYNC_DIR/spotify-sync-index.sldl" \
            2>&1 | tee -a "$LOG_FILE"
        ;;
    --status)
        echo ""
        echo "Spotify Sync — Status"
        echo "━━━━━━━━━━━━━━━━━━━━━"
        echo "Playlist : $PLAYLIST_URL"
        [ -f "$TRACKS_FILE" ] && \
            echo "Tracks   : $(wc -l < "$TRACKS_FILE" | tr -d ' ') in last fetched list"
        [ -f "$SYNC_DIR/spotify-sync-index.sldl" ] && \
            echo "Indexed  : $(wc -l < "$SYNC_DIR/spotify-sync-index.sldl") entries"
        [ -f "$LOG_FILE" ] && \
            echo "Last run : $(tail -1 "$LOG_FILE")"
        echo ""
        ;;
    --help|-h)
        echo ""
        echo "Commands:"
        echo "  ~/spotify-sync/sync.sh            — sync now"
        echo "  ~/spotify-sync/sync.sh --dry       — preview without downloading"
        echo "  ~/spotify-sync/sync.sh --status    — show last sync info"
        echo ""
        echo "Stop auto-sync:"
        echo "  launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.spotify-sync.plist"
        echo "Restart auto-sync:"
        echo "  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spotify-sync.plist"
        echo ""
        ;;
    *)
        echo "[$(timestamp)] Starting sync..." | tee -a "$LOG_FILE"
        echo "[$(timestamp)] Fetching playlist tracks from Spotify..." | tee -a "$LOG_FILE"
        fetch_tracks
        echo "[$(timestamp)] Starting download..." | tee -a "$LOG_FILE"
        "$SLDL_BIN" "$TRACKS_FILE" \
            --index-path "$SYNC_DIR/spotify-sync-index.sldl" \
            --no-progress \
            2>&1 | tee -a "$LOG_FILE"
        echo "[$(timestamp)] Sync complete." | tee -a "$LOG_FILE"
        ;;
esac
SYNC_SCRIPT

chmod +x "$SYNC_DIR/sync.sh"

# Copy the track-fetching helper (needed by sync.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/fetch_tracks.py" ]; then
    cp "$SCRIPT_DIR/fetch_tracks.py" "$SYNC_DIR/fetch_tracks.py"
elif [ ! -f "$SYNC_DIR/fetch_tracks.py" ]; then
    fail "fetch_tracks.py not found. Make sure it's in the same folder as this installer."
    exit 1
fi

ok "Sync script ready at ~/spotify-sync/sync.sh"

# ══════════════════════════════════════════════════════════════
# STEP 4: Schedule automatic sync
# ══════════════════════════════════════════════════════════════

step 4 "Setting up automatic sync schedule..."

echo ""
echo -e "  How often should your playlist sync automatically?"
echo ""
echo -e "  1) Every hour"
echo -e "  2) Every 6 hours"
echo -e "  3) Every 12 hours"
echo -e "  4) Once a day"
echo -e "  5) Manual only (I'll run it myself)"
echo ""
read -rp "  Choose [1-5] (default: 1): " FREQ_CHOICE

case "${FREQ_CHOICE:-1}" in
    2) INTERVAL=21600; FREQ_DESC="every 6 hours" ;;
    3) INTERVAL=43200; FREQ_DESC="every 12 hours" ;;
    4) INTERVAL=86400; FREQ_DESC="once a day" ;;
    5) INTERVAL=0;     FREQ_DESC="manual only" ;;
    *) INTERVAL=3600;  FREQ_DESC="every hour" ;;
esac

if [ "$INTERVAL" -gt 0 ]; then
    mkdir -p "$PLIST_DIR"

    cat > "$PLIST_DIR/$PLIST_NAME" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.spotify-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-l</string>
        <string>${SYNC_DIR}/sync.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>${INTERVAL}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SYNC_DIR}/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${SYNC_DIR}/launchd-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
</dict>
</plist>
PLIST

    launchctl bootout "gui/$(id -u)" "$PLIST_DIR/$PLIST_NAME" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DIR/$PLIST_NAME"
    ok "Auto-sync scheduled: $FREQ_DESC (also runs at login)"
else
    ok "Manual only — run: ~/spotify-sync/sync.sh"
fi

# ══════════════════════════════════════════════════════════════
# Done!
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}${GREEN}${BOLD}              Setup Complete!                         ${NC}${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Songs download to:${NC} ${DOWNLOAD_DIR:-$HOME/Downloads/spotify-sync}"
echo ""
echo -e "  ${BOLD}Commands:${NC}"
echo -e "    ${GREEN}~/spotify-sync/sync.sh${NC}            Sync now"
echo -e "    ${GREEN}~/spotify-sync/sync.sh --dry${NC}      Preview without downloading"
echo -e "    ${GREEN}~/spotify-sync/sync.sh --status${NC}   Last sync info"
echo ""
if [ "$INTERVAL" -gt 0 ]; then
    echo -e "  ${BOLD}Auto-sync:${NC} ${GREEN}ON${NC} — $FREQ_DESC"
else
    echo -e "  ${BOLD}Auto-sync:${NC} OFF — run manually when you want to sync"
fi
echo ""
echo -e "  ${DIM}Edit settings: ~/.config/sldl/sldl.conf${NC}"
echo -e "  ${DIM}Logs: ~/spotify-sync/sync.log${NC}"
echo ""

read -rp "  Run a test sync now? (y/n): " TEST_NOW
if [[ "$TEST_NOW" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "  ${BOLD}Running first sync...${NC} ${DIM}(Ctrl+C to cancel)${NC}"
    echo ""
    "$SYNC_DIR/sync.sh"
fi

echo ""
echo -e "  ${GREEN}All done! Enjoy your music.${NC}"
echo ""
