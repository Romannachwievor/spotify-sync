# Spotify Sync

Automatically download and sync a Spotify playlist to your Mac using Soulseek. New songs added to the playlist are downloaded on a schedule — no manual work needed.

## What you need

- macOS (Apple Silicon or Intel)
- A free [Soulseek](https://www.slsknet.org) account
- A free [Spotify Developer](https://developer.spotify.com/dashboard) app (takes ~2 min to set up)
- A Spotify **Premium** account (required by Spotify's API since March 2026)

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/Romannachwievor/spotify-sync/main/spotify-sync-install.sh \
  -o ~/Downloads/spotify-sync-install.sh
bash ~/Downloads/spotify-sync-install.sh
```

The installer will guide you through every step interactively.

## What the installer does

1. Downloads the [sldl](https://github.com/fiso64/sldl) binary and code-signs it for macOS
2. Asks for your Soulseek credentials, Spotify playlist URL, and Spotify API credentials
3. Creates `~/spotify-sync/sync.sh` — the sync runner
4. Schedules automatic syncing via launchd (hourly by default)

## Manual usage

```bash
~/spotify-sync/sync.sh            # sync now
~/spotify-sync/sync.sh --dry      # preview tracks without downloading
~/spotify-sync/sync.sh --prune-preview  # preview local files not in playlist
~/spotify-sync/sync.sh --prune    # remove local files not in playlist
~/spotify-sync/sync.sh --status   # show last sync info
```

## How it works

sldl's built-in Spotify extractor uses a Spotify API endpoint removed in February 2026. This project works around that by fetching tracks directly via `fetch_tracks.py`, which uses your OAuth refresh token to call the correct `/v1/playlists/{id}/items` endpoint, then passes the results to sldl as a CSV.

## Files

| File | Purpose |
|---|---|
| `spotify-sync-install.sh` | Self-contained interactive installer |
| `sync.sh` | Generated sync runner (created by installer) |
| `fetch_tracks.py` | Fetches playlist tracks from Spotify API |

## Configuration

All credentials are stored in `~/.config/sldl/sldl.conf` — never committed to git.

Optional sync behavior can be set in `~/spotify-sync/.sync-config`:

```bash
# Remove local files not present in the current playlist after each sync
PRUNE_REMOVED=true

# Existing option: convert FLAC downloads to MP3
CONVERT_FLAC=false
```

## Stop / restart auto-sync

```bash
# Stop
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.spotify-sync.plist

# Restart
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spotify-sync.plist
```
