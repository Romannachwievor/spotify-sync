#!/usr/bin/env python3
"""
seedbox.py — yt-dlp fallback for Spotify Sync.

For tracks not found on Soulseek, searches YouTube and downloads
the best available audio, converted to MP3 320kbps via ffmpeg.

Usage:
    python3 seedbox.py "Artist Name - Track Title"
    python3 seedbox.py --batch /path/to/not_found.txt

Required: brew install yt-dlp ffmpeg
"""

import argparse
import logging
import os
import subprocess
import sys
from pathlib import Path

LOG = logging.getLogger("seedbox")

_NOT_FOUND_MANUAL = Path.home() / "spotify-sync" / "not_found_manual.log"

YTDLP_BIN  = "/opt/homebrew/bin/yt-dlp"
FFMPEG_BIN = "/opt/homebrew/bin/ffmpeg"


def _ytdlp_cmd() -> str:
    """Return path to yt-dlp binary."""
    if os.path.exists(YTDLP_BIN):
        return YTDLP_BIN
    # fall back to PATH
    r = subprocess.run(["which", "yt-dlp"], capture_output=True, text=True)
    if r.returncode == 0:
        return r.stdout.strip()
    return "yt-dlp"


def _default_dest() -> str:
    """Return the sldl download path, or ~/Downloads/spotify-sync as fallback."""
    conf = Path.home() / ".config" / "sldl" / "sldl.conf"
    if conf.exists():
        for line in conf.read_text().splitlines():
            if line.strip().startswith("path "):
                return line.split("=", 1)[-1].strip()
    return str(Path.home() / "Downloads" / "spotify-sync")


def ytdlp_download(track: str, dest: str) -> bool:
    """
    Download a track from YouTube via yt-dlp.
    Converts to MP3 320kbps via ffmpeg.
    Returns True on success.
    """
    ytdlp = _ytdlp_cmd()
    try:
        subprocess.run([ytdlp, "--version"], capture_output=True, check=True)
    except FileNotFoundError:
        LOG.warning("yt-dlp not installed — skipping (brew install yt-dlp ffmpeg)")
        return False

    os.makedirs(dest, exist_ok=True)

    LOG.info("yt-dlp: searching for '%s'…", track)
    ffmpeg_dir = os.path.dirname(FFMPEG_BIN) if os.path.exists(FFMPEG_BIN) else ""
    args = [
        ytdlp,
        f"ytsearch1:{track}",
        "--extract-audio",
        "--audio-format", "mp3",
        "--audio-quality", "0",
        "--no-playlist",
        "--match-filters", "duration < 1200",
        "-o", os.path.join(dest, "%(artist)s - %(title)s.%(ext)s"),
        "--quiet", "--progress",
        "--no-warnings",
        "--no-part",
    ]
    if ffmpeg_dir:
        args += ["--ffmpeg-location", ffmpeg_dir]

    result = subprocess.run(args)
    if result.returncode == 0:
        LOG.info("yt-dlp: OK '%s'", track)
        return True
    LOG.warning("yt-dlp: FAILED '%s'", track)
    return False


def run_track(track: str, dest: str) -> bool:
    """Download one track. Logs to not_found_manual.log on failure."""
    LOG.info("━━━ %s ━━━", track)
    if ytdlp_download(track, dest):
        return True
    LOG.warning("yt-dlp exhausted for '%s' — logged to %s", track, _NOT_FOUND_MANUAL)
    _NOT_FOUND_MANUAL.parent.mkdir(parents=True, exist_ok=True)
    with open(_NOT_FOUND_MANUAL, "a") as fh:
        fh.write(track + "\n")
    return False


def main() -> None:
    parser = argparse.ArgumentParser(
        description="yt-dlp fallback for tracks not found on Soulseek.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("track", nargs="?", help='Track to search, e.g. "Artist - Title"')
    parser.add_argument("--batch",   metavar="FILE", help="File with one track per line")
    parser.add_argument("--dest",    metavar="DIR",  help="Output directory (default: sldl path)")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
    )

    dest = args.dest or _default_dest()

    if args.batch and args.track:
        parser.error("Specify either a track or --batch, not both.")

    tracks = []
    if args.batch:
        p = Path(args.batch)
        if not p.exists():
            LOG.error("Batch file not found: %s", p)
            sys.exit(1)
        tracks = [
            line.strip()
            for line in p.read_text().splitlines()
            if line.strip() and not line.startswith("#")
        ]
    elif args.track:
        tracks = [args.track]
    else:
        parser.print_help()
        sys.exit(0)

    if not tracks:
        LOG.info("No tracks to process.")
        sys.exit(0)

    LOG.info("Processing %d track(s) → %s", len(tracks), dest)
    successes = sum(1 for t in tracks if run_track(t, dest))
    LOG.info("Done: %d/%d succeeded.", successes, len(tracks))
    sys.exit(0 if successes == len(tracks) else 1)


if __name__ == "__main__":
    main()
