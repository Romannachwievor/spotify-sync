#!/usr/bin/env python3
"""
Fetch all tracks from a Spotify playlist using the OAuth Refresh Token flow.
Bypasses sldl's broken Spotify extractor (which uses the removed /tracks endpoint).

Usage: python3 fetch_tracks.py <client_id> <client_secret> <refresh_token> <playlist_id> <output_file>
"""
import sys
import json
import urllib.request
import urllib.parse
import base64


def get_token(client_id, client_secret, refresh_token):
    credentials = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token
    }).encode()
    req = urllib.request.Request(
        "https://accounts.spotify.com/api/token",
        data=data,
        headers={
            "Authorization": f"Basic {credentials}",
            "Content-Type": "application/x-www-form-urlencoded"
        }
    )
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())["access_token"]


def fetch_all_tracks(playlist_id, token):
    tracks = []
    url = f"https://api.spotify.com/v1/playlists/{playlist_id}/items?limit=100"
    while url:
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req) as r:
            data = json.loads(r.read())
        for entry in data.get("items", []):
            # Feb 2026 API renamed 'track' field to 'item'; support both
            track = entry.get("item") or entry.get("track")
            if not track or not isinstance(track, dict) or not track.get("name"):
                continue
            artists = track.get("artists", [])
            artist = artists[0]["name"] if artists else ""
            name = track["name"]
            tracks.append((artist, name))
        url = data.get("next")
    return tracks


if __name__ == "__main__":
    if len(sys.argv) != 6:
        print(f"Usage: {sys.argv[0]} <client_id> <client_secret> <refresh_token> <playlist_id> <output_file>",
              file=sys.stderr)
        sys.exit(1)

    client_id, client_secret, refresh_token, playlist_id, output_file = sys.argv[1:]

    try:
        token = get_token(client_id, client_secret, refresh_token)
    except Exception as e:
        print(f"ERROR: Failed to get Spotify token: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        tracks = fetch_all_tracks(playlist_id, token)
    except Exception as e:
        print(f"ERROR: Failed to fetch playlist: {e}", file=sys.stderr)
        sys.exit(1)

    if not tracks:
        print("ERROR: No tracks found in playlist", file=sys.stderr)
        sys.exit(1)

    with open(output_file, "w") as f:
        f.write("Artist,Title\n")
        for artist, name in tracks:
            # Escape CSV fields that contain commas or quotes
            artist_csv = f'"{artist}"' if ',' in artist or '"' in artist else artist
            name_csv = f'"{name}"' if ',' in name or '"' in name else name
            f.write(f"{artist_csv},{name_csv}\n")

    print(f"Fetched {len(tracks)} tracks", file=sys.stderr)
