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
