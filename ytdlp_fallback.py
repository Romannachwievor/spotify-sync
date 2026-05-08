#!/usr/bin/env python3
"""
ytdlp_fallback.py — yt-dlp fallback for Spotify Sync.

For tracks not found on Soulseek, searches SoundCloud first,
then YouTube, and downloads the best available audio converted
to MP3 320kbps via ffmpeg.

Usage:
    python3 ytdlp_fallback.py "Artist Name - Track Title"
    python3 ytdlp_fallback.py --batch /path/to/not_found.txt

Required: brew install yt-dlp ffmpeg
"""

import argparse
import json
import logging
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Literal

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


def _spotify_query(track: str) -> str:
    # Bias toward the canonical track version.
    return f"{track} official audio"


def _extended_query(track: str) -> str:
    # Bias toward DJ/record-pool style versions such as intros and extended mixes.
    return f"{track} extended intro dj intro extended mix clean intro"


def _preview_result(query: str, source: str = "youtube") -> str:
    ytdlp = _ytdlp_cmd()
    prefix = "scsearch1:" if source == "soundcloud" else "ytsearch1:"
    cmd = [
        ytdlp,
        f"{prefix}{query}",
        "--skip-download",
        "--no-playlist",
        "--no-warnings",
        "--quiet",
        "--print",
        "%(title)s | %(channel)s | %(duration_string)s",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or not result.stdout.strip():
        return "(no preview found)"
    return result.stdout.strip().splitlines()[0]


def _soundcloud_free_dl_url(search_query: str, max_candidates: int = 8) -> str | None:
    """Return a SoundCloud URL with downloadable=True when available."""
    ytdlp = _ytdlp_cmd()
    cmd = [
        ytdlp,
        f"scsearch{max_candidates}:{search_query}",
        "--skip-download",
        "--dump-single-json",
        "--no-warnings",
        "--quiet",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or not result.stdout.strip():
        return None

    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None

    entries = payload.get("entries") or []
    for entry in entries:
        if entry.get("downloadable") is True and entry.get("webpage_url"):
            return str(entry["webpage_url"])
    return None


# ---------------------------------------------------------------------------
# Pre-download candidate verification
# ---------------------------------------------------------------------------

def _candidate_matches(expected_track: str, candidate_meta: dict) -> bool:
    """
    Return True if the yt-dlp candidate metadata plausibly matches the
    expected 'Artist - Title' string.

    We split expected_track on the first ' - ' to get artist and title, then
    check that the candidate's uploader/channel/artist and title fields each
    share at least one significant token with what we expect.
    """
    stop = {"feat", "ft", "vs", "and", "the", "a", "an", "official", "audio",
            "video", "remix", "edit", "mix", "version", "original", "extended",
            "instrumental", "vip", "bootleg", "type", "beat"}

    def norm(s: str) -> str:
        s = (s or "").lower()
        s = re.sub(r"[\(\[\{][^\)\]\}]*[\)\]\}]", " ", s)
        s = re.sub(r"[^a-z0-9]+", " ", s)
        return s.strip()

    def tok(s: str) -> set[str]:
        return {w for w in norm(s).split() if w and w not in stop and len(w) > 1}

    # Parse expected into artist + title halves
    if " - " in expected_track:
        exp_artist, exp_title = expected_track.split(" - ", 1)
    else:
        exp_artist, exp_title = "", expected_track

    exp_artist_tok = tok(exp_artist)
    exp_title_tok  = tok(exp_title)

    # Gather candidate field values
    cand_artist = (
        candidate_meta.get("artist") or
        candidate_meta.get("uploader") or
        candidate_meta.get("channel") or ""
    )
    cand_title = candidate_meta.get("title") or ""
    cand_full  = norm(cand_artist + " " + cand_title)
    cand_tok   = tok(cand_artist + " " + cand_title)

    # Artist check: at least one expected artist token must appear in candidate
    if exp_artist_tok and not (exp_artist_tok & cand_tok):
        return False

    # Title check: at least half of expected title tokens must appear
    if exp_title_tok:
        common = exp_title_tok & cand_tok
        if len(common) / len(exp_title_tok) < 0.5:
            return False

    return True


def _fetch_candidate_meta(search_target: str) -> dict | None:
    """Return yt-dlp metadata dict for the first result, without downloading."""
    ytdlp = _ytdlp_cmd()
    cmd = [
        ytdlp, search_target,
        "--skip-download",
        "--dump-single-json",
        "--no-warnings",
        "--quiet",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        payload = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    # scsearch returns a playlist wrapper; unwrap first entry
    if "entries" in payload:
        entries = payload.get("entries") or []
        return entries[0] if entries else None
    return payload


def _choose_mode_for_track(track: str, non_interactive_mode: str, choose_version: bool) -> Literal["spotify", "extended"]:
    if non_interactive_mode in {"spotify", "extended"}:
        return non_interactive_mode  # type: ignore[return-value]

    if not choose_version:
        return "spotify"

    if not sys.stdin.isatty():
        LOG.info("No TTY available; defaulting to spotify-version for '%s'.", track)
        return "spotify"

    spotify_preview = _preview_result(_spotify_query(track), source="soundcloud")
    extended_preview = _preview_result(_extended_query(track), source="soundcloud")

    print("\n" + "=" * 72)
    print(f"Track: {track}")
    print("Choose version:")
    print(f"  [1] Spotify-version       -> {spotify_preview}")
    print(f"  [2] Record-pool extended  -> {extended_preview}")
    print("  [S] Skip this track")

    while True:
        choice = input("Select [1/2/S] (default 1): ").strip().lower()
        if choice in {"", "1"}:
            return "spotify"
        if choice == "2":
            return "extended"
        if choice == "s":
            raise RuntimeError("skip")
        print("Invalid choice. Use 1, 2, or S.")


def ytdlp_download_with_source(
    track: str,
    dest: str,
    mode: Literal["spotify", "extended"],
    source: str,
) -> bool:
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

    search_query = _extended_query(track) if mode == "extended" else _spotify_query(track)
    prefix = "scsearch1:" if source == "soundcloud" else "ytsearch1:"
    free_dl_url = None
    target = f"{prefix}{search_query}"
    if source == "soundcloud":
        free_dl_url = _soundcloud_free_dl_url(search_query)
        if free_dl_url:
            target = free_dl_url
            LOG.info("SoundCloud: Free Download match found; prioritizing source URL.")
        else:
            LOG.info("SoundCloud: no Free Download match in top results; using normal SoundCloud search.")

    LOG.info("yt-dlp: searching for '%s' (%s mode, %s)…", track, mode, source)
    ffmpeg_dir = os.path.dirname(FFMPEG_BIN) if os.path.exists(FFMPEG_BIN) else ""
    args = [
        ytdlp,
        target,
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

    # Pre-download verification: fetch candidate metadata and reject obvious mismatches.
    # Skip the check when we already have a confirmed Free Download URL (we trust it).
    if not free_dl_url:
        candidate = _fetch_candidate_meta(target)
        if candidate and not _candidate_matches(track, candidate):
            cand_uploader = candidate.get("uploader") or candidate.get("channel") or "?"
            cand_title    = candidate.get("title") or "?"
            LOG.warning(
                "Pre-download check REJECTED candidate from %s: '%s - %s' "
                "doesn't match expected '%s'",
                source, cand_uploader, cand_title, track,
            )
            return False

    result = subprocess.run(args)
    if result.returncode == 0:
        LOG.info("yt-dlp: OK '%s'", track)
        return True
    LOG.warning("yt-dlp: FAILED '%s' on %s", track, source)
    return False


def run_track(
    track: str,
    dest: str,
    choose_version: bool,
    non_interactive_mode: str,
    source_order: list[str],
) -> bool:
    """Download one track. Logs to not_found_manual.log on failure."""
    LOG.info("━━━ %s ━━━", track)
    try:
        mode = _choose_mode_for_track(track, non_interactive_mode, choose_version)
    except RuntimeError:
        LOG.info("Skipped '%s' by user choice.", track)
        return True

    for source in source_order:
        if ytdlp_download_with_source(track, dest, mode=mode, source=source):
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
    parser.add_argument("--choose-version", action="store_true",
                        help="Ask per track: spotify-version or record-pool extended version")
    parser.add_argument("--mode", choices=["spotify", "extended", "ask"], default="spotify",
                        help="Default version mode (ask requires TTY or --choose-version)")
    parser.add_argument("--source-order", default="soundcloud,youtube",
                        help="Fallback source order as CSV (default: soundcloud,youtube)")
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

    choose_version = args.choose_version or args.mode == "ask"
    non_interactive_mode = "spotify" if args.mode == "ask" else args.mode
    source_order = [s.strip().lower() for s in args.source_order.split(",") if s.strip()]
    allowed_sources = {"soundcloud", "youtube"}
    source_order = [s for s in source_order if s in allowed_sources]
    if not source_order:
        source_order = ["soundcloud", "youtube"]

    LOG.info("Processing %d track(s) → %s", len(tracks), dest)
    LOG.info("Source priority: %s", " -> ".join(source_order))
    successes = sum(
        1
        for t in tracks
        if run_track(t, dest, choose_version, non_interactive_mode, source_order)
    )
    LOG.info("Done: %d/%d succeeded.", successes, len(tracks))
    sys.exit(0 if successes == len(tracks) else 1)


if __name__ == "__main__":
    main()
