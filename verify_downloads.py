#!/usr/bin/env python3
"""
verify_downloads.py — Post-download track verification for Spotify Sync.

Compares the Spotify playlist (playlist_tracks.csv) against every file
recorded in the sldl index.  For each file that exists on disk it reads the
actual ID3/Vorbis/APEv2 tags via ffprobe, then fuzzy-matches the embedded
artist & title against what the playlist expected.

A mismatch is flagged when the embedded tags AND the filename both fail to
match the expected artist/title from the playlist.

Results are written to  ~/spotify-sync/mismatch_report.log

Usage:
    python3 verify_downloads.py [--fix] [--quiet] [--verbose]

Options:
    --fix     Move flagged files to ~/spotify-sync/quarantine/ (NOT deleted —
              you can review and restore them).
    --quiet   Suppress per-track output; only print the summary.
    --verbose Show OK tracks as well as mismatches.
"""

import argparse
import csv
import json
import logging
import os
import re
import subprocess
import sys
from pathlib import Path
from datetime import datetime

LOG = logging.getLogger("verify")

SYNC_DIR      = Path.home() / "spotify-sync"
PLAYLIST_FILE = SYNC_DIR / "playlist_tracks.csv"
INDEX_FILE    = SYNC_DIR / "spotify-sync-index.sldl"
REPORT_FILE   = SYNC_DIR / "mismatch_report.log"
QUARANTINE    = SYNC_DIR / "quarantine"

# Words that contribute no useful signal to artist/title matching
_STOP = {"feat", "ft", "vs", "and", "the", "a", "an", "official", "audio",
         "video", "remix", "edit", "mix", "version", "original", "extended",
         "instrumental", "vip", "bootleg", "remaster", "remastered", "type",
         "beat"}


def ts() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def norm_artist(text: str) -> str:
    """Normalise an artist string: strip parenthetical content (removes 'feat. X')."""
    text = (text or "").lower()
    text = re.sub(r"[\(\[\{][^\)\]\}]*[\)\]\}]", " ", text)
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return text.strip()


def norm_raw(text: str) -> str:
    """Normalise without stripping parenthetical content.
    Preserves remix/edit credits that appear inside parentheses."""
    text = (text or "").lower()
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return text.strip()


def norm(text: str) -> str:
    """Alias used for building the playlist lookup key (artist-style)."""
    return norm_artist(text)


def tokens(text: str, raw: bool = False) -> set[str]:
    n = norm_raw(text) if raw else norm_artist(text)
    return {w for w in n.split() if w and w not in _STOP and len(w) > 1}


def artists_overlap(expected: str, actual: str, raw_actual: bool = False) -> bool:
    """Return True if the two artist strings share at least one significant token.

    Set raw_actual=True when checking against a filename stem so that an expected
    artist appearing inside parentheses (e.g. 'Track (Mr. Machine Edit).mp3')
    is not discarded by parenthesis-stripping.
    """
    e_tok = tokens(expected, raw=False)
    a_tok = tokens(actual, raw=raw_actual)
    if not e_tok or not a_tok:
        return True   # can't decide — give benefit of doubt
    return bool(e_tok & a_tok)


def titles_overlap(expected: str, actual: str) -> bool:
    """Title matching: preserve parenthetical content on the actual side.
    Remix/edit info in brackets is meaningful — don't discard it.
    At least half of the expected title's tokens must appear in the actual."""
    e_tok = tokens(expected, raw=False)
    a_tok = tokens(actual, raw=True)   # keep content inside (…) in actual
    if not e_tok or not a_tok:
        return True
    common = e_tok & a_tok
    return len(common) / len(e_tok) >= 0.5


def ffprobe_tags(filepath: str) -> dict[str, str]:
    """Return {'artist': ..., 'title': ...} from the file's embedded tags."""
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format_tags=artist,title,ARTIST,TITLE",
        "-of", "json",
        filepath,
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return {}
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return {}
    tags = data.get("format", {}).get("tags", {})
    return {
        "artist": tags.get("artist") or tags.get("ARTIST") or "",
        "title":  tags.get("title")  or tags.get("TITLE")  or "",
    }


def load_playlist() -> dict[tuple[str, str], tuple[str, str]]:
    """Return {(norm_artist, norm_title): (orig_artist, orig_title)}."""
    result: dict[tuple[str, str], tuple[str, str]] = {}
    if not PLAYLIST_FILE.exists():
        LOG.error("Playlist file not found: %s", PLAYLIST_FILE)
        return result
    with open(PLAYLIST_FILE, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            a = (row.get("Artist") or "").strip()
            t = (row.get("Title") or "").strip()
            result[(norm(a), norm(t))] = (a, t)
    return result


def load_index() -> list[dict]:
    """Return all rows from the sldl index that have a real filepath."""
    rows = []
    if not INDEX_FILE.exists():
        LOG.error("Index file not found: %s", INDEX_FILE)
        return rows
    with open(INDEX_FILE, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            fp = (row.get("filepath") or "").strip()
            if fp.startswith("/"):
                rows.append(row)
    return rows


def verify(fix: bool, quiet: bool) -> int:
    """Run verification.  Returns count of mismatches found."""
    playlist = load_playlist()
    if not playlist:
        LOG.error("No playlist entries loaded — aborting.")
        return 0

    index_rows = load_index()
    if not index_rows:
        LOG.info("No downloadable index entries found.")
        return 0

    if fix:
        QUARANTINE.mkdir(parents=True, exist_ok=True)

    mismatches: list[dict] = []
    ok_count = 0

    for row in index_rows:
        fp = row.get("filepath", "").strip()
        if not os.path.exists(fp):
            continue

        idx_artist = (row.get("artist") or "").strip()
        idx_title  = (row.get("title")  or "").strip()

        # Match index entry to playlist entry
        exp_artist = exp_title = ""
        key = (norm(idx_artist), norm(idx_title))
        if key in playlist:
            exp_artist, exp_title = playlist[key]
        else:
            # Title-only fallback (index artist may differ slightly)
            title_norm = norm(idx_title)
            for (pa, pt), (oa, ot) in playlist.items():
                if pt == title_norm:
                    exp_artist, exp_title = oa, ot
                    break

        if not exp_artist:
            # Not in playlist — handled by --prune; skip here
            continue

        # Read actual embedded tags from the file
        tags = ffprobe_tags(fp)
        actual_artist = tags.get("artist", "")
        actual_title  = tags.get("title",  "")
        filename_stem = Path(fp).stem

        # Artist check: try embedded tag first, then full filename.
        # raw_actual=True for filename so "(Mr. Machine Edit)" is not stripped.
        artist_ok = (
            artists_overlap(exp_artist, actual_artist, raw_actual=False)
            or artists_overlap(exp_artist, filename_stem, raw_actual=True)
        )

        # Title check: preserve parens content in actual tag & filename
        title_ok = (
            titles_overlap(exp_title, actual_title)
            or titles_overlap(exp_title, filename_stem)
        )

        if artist_ok and title_ok:
            ok_count += 1
            if not quiet:
                LOG.debug("OK  %s - %s", exp_artist, exp_title)
            continue

        issues = []
        if not artist_ok:
            issues.append(
                f"artist mismatch (expected={exp_artist!r}, got={actual_artist!r})"
            )
        if not title_ok:
            issues.append(
                f"title mismatch (expected={exp_title!r}, got={actual_title!r})"
            )

        mismatches.append({
            "expected_artist": exp_artist,
            "expected_title":  exp_title,
            "actual_artist":   actual_artist,
            "actual_title":    actual_title,
            "filepath":        fp,
            "issues":          "; ".join(issues),
        })

        if not quiet:
            LOG.warning(
                "MISMATCH: expected=%r - %r | actual=%r - %r | file=%s",
                exp_artist, exp_title, actual_artist, actual_title,
                Path(fp).name,
            )

    # Write report
    with open(REPORT_FILE, "w", encoding="utf-8") as rep:
        rep.write("# Spotify Sync — Download Verification Report\n")
        rep.write(f"# Generated: {ts()}\n")
        rep.write(
            f"# Checked: {ok_count + len(mismatches)} files  |  "
            f"OK: {ok_count}  |  Mismatches: {len(mismatches)}\n\n"
        )
        for m in mismatches:
            rep.write("[MISMATCH]\n")
            rep.write(f"  Expected : {m['expected_artist']} - {m['expected_title']}\n")
            rep.write(f"  Actual   : {m['actual_artist']} - {m['actual_title']}\n")
            rep.write(f"  File     : {m['filepath']}\n")
            rep.write(f"  Issues   : {m['issues']}\n\n")

    LOG.info(
        "Checked %d file(s) — %d OK, %d mismatch(es). Report: %s",
        ok_count + len(mismatches), ok_count, len(mismatches), REPORT_FILE,
    )

    if fix and mismatches:
        for m in mismatches:
            src = Path(m["filepath"])
            dst = QUARANTINE / src.name
            try:
                src.rename(dst)
                LOG.info("Quarantined: %s → %s", src.name, dst)
            except OSError as e:
                LOG.warning("Could not move %s: %s", src.name, e)
        LOG.info("Quarantined %d file(s) to %s", len(mismatches), QUARANTINE)

    return len(mismatches)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Verify downloaded tracks match the Spotify playlist.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--fix",     action="store_true",
                        help="Move mismatched files to quarantine/ (no deletion)")
    parser.add_argument("--quiet",   action="store_true",
                        help="Only print the summary, not per-track results")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
    )

    count = verify(fix=args.fix, quiet=args.quiet)
    sys.exit(1 if count else 0)


if __name__ == "__main__":
    main()
