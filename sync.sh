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

# Check MIME type and FLAC integrity for audio files newer than the tracks CSV
check_integrity() {
    local dir="$1"
    local errors=0 checked=0
    while IFS= read -r -d '' f; do
        checked=$((checked + 1))
        mime=$(file --mime-type -b "$f" 2>/dev/null)
        case "$mime" in
            audio/*|application/ogg) ;;
            *)
                echo "[$(timestamp)] WARN: Unexpected MIME for $(basename "$f"): $mime" | tee -a "$LOG_FILE"
                errors=$((errors + 1))
                ;;
        esac
        if [[ "$f" == *.flac ]]; then
            if ! flac --test --silent "$f" 2>/dev/null; then
                echo "[$(timestamp)] WARN: Corrupt FLAC: $(basename "$f")" | tee -a "$LOG_FILE"
                errors=$((errors + 1))
            fi
        fi
    done < <(find "$dir" -type f \( -name "*.flac" -o -name "*.mp3" -o -name "*.ogg" \) \
        -newer "$TRACKS_FILE" -print0 2>/dev/null)

    if [ "$checked" -eq 0 ]; then
        echo "[$(timestamp)] Integrity: no new files to check." | tee -a "$LOG_FILE"
    elif [ "$errors" -eq 0 ]; then
        echo "[$(timestamp)] Integrity: $checked file(s) OK." | tee -a "$LOG_FILE"
    else
        echo "[$(timestamp)] Integrity: $errors/$checked file(s) failed — check $LOG_FILE." | tee -a "$LOG_FILE"
    fi
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

        # Capture sldl output to both the main log and a per-run log for not-found parsing
        SLDL_RUN_LOG="$SYNC_DIR/sldl_last_run.log"
        "$SLDL_BIN" "$TRACKS_FILE" \
            --index-path "$SYNC_DIR/spotify-sync-index.sldl" \
            --no-progress \
            2>&1 | tee -a "$LOG_FILE" "$SLDL_RUN_LOG"

        echo "[$(timestamp)] Sync complete." | tee -a "$LOG_FILE"

        # --- Integrity checks on newly downloaded files ---
        DOWNLOAD_DIR=$(grep '^path' "$CONF" | awk -F' = ' '{print $2}' | tr -d '[:space:]')
        if [ -n "$DOWNLOAD_DIR" ] && [ -d "$DOWNLOAD_DIR" ]; then
            echo "[$(timestamp)] Running integrity checks on new files..." | tee -a "$LOG_FILE"
            check_integrity "$DOWNLOAD_DIR"
        fi

        # --- yt-dlp fallback for tracks not found on Soulseek ---
        # sldl outputs "Not found: Artist - Title" for each missing track
        NOT_FOUND_LOG="$SYNC_DIR/not_found.log"

        NOT_FOUND=$(grep "^Not found: " "$SLDL_RUN_LOG" 2>/dev/null \
            | sed 's/^Not found: //' | sort -u || true)

        if [ -n "$NOT_FOUND" ]; then
            COUNT=$(printf "%s\n" "$NOT_FOUND" | wc -l | tr -d ' ')
            printf "%s\n" "$NOT_FOUND" > "$NOT_FOUND_LOG"
            echo "[$(timestamp)] $COUNT track(s) not found on Soulseek — running yt-dlp fallback..." | tee -a "$LOG_FILE"
            python3 "$SYNC_DIR/seedbox.py" --batch "$NOT_FOUND_LOG" 2>&1 | tee -a "$LOG_FILE"
        else
            echo "[$(timestamp)] All tracks found on Soulseek." | tee -a "$LOG_FILE"
        fi

        # --- FLAC → MP3 conversion (for devices without FLAC support) ---
        SYNC_CONFIG="$SYNC_DIR/.sync-config"
        CONVERT_FLAC=false
        [ -f "$SYNC_CONFIG" ] && source "$SYNC_CONFIG"

        if [ "$CONVERT_FLAC" = "true" ]; then
            DOWNLOAD_DIR_FLAC=$(grep '^path' "$CONF" | awk -F' = ' '{print $2}' | tr -d '[:space:]')
            DOWNLOAD_DIR_FLAC="${DOWNLOAD_DIR_FLAC:-$HOME/Downloads/spotify-sync}"
            FFMPEG_BIN="/opt/homebrew/bin/ffmpeg"
            FFMPEG_CMD="ffmpeg"
            [ -x "$FFMPEG_BIN" ] && FFMPEG_CMD="$FFMPEG_BIN"

            if command -v ffmpeg &>/dev/null || [ -x "$FFMPEG_BIN" ]; then
                echo "[$(timestamp)] Converting FLAC files to MP3 320kbps..." | tee -a "$LOG_FILE"
                converted=0
                while IFS= read -r -d '' flac_file; do
                    mp3_file="${flac_file%.flac}.mp3"
                    if [ ! -f "$mp3_file" ]; then
                        "$FFMPEG_CMD" -i "$flac_file" -ab 320k -map_metadata 0 -id3v2_version 3 \
                            -loglevel error "$mp3_file" \
                        && rm -f "$flac_file" \
                        && converted=$((converted + 1)) \
                        || echo "[$(timestamp)] WARN: conversion failed for $(basename "$flac_file")" | tee -a "$LOG_FILE"
                    fi
                done < <(find "$DOWNLOAD_DIR_FLAC" -type f -name "*.flac" -print0 2>/dev/null)
                echo "[$(timestamp)] Converted $converted FLAC file(s) to MP3." | tee -a "$LOG_FILE"
            else
                echo "[$(timestamp)] WARN: ffmpeg not found — skipping FLAC conversion." | tee -a "$LOG_FILE"
            fi
        fi
        ;;
esac
