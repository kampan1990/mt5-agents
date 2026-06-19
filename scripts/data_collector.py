"""Stage 1: Collect video metadata from a YouTube playlist."""

import json
import subprocess
import sys
from datetime import datetime, timezone

from config import MANIFEST_FILE, MAX_VIDEO_DURATION, CHECKPOINTS_DIR


def collect_playlist(playlist_url: str, resume: bool = False) -> dict:
    """Fetch all video metadata from a YouTube playlist URL."""
    CHECKPOINTS_DIR.mkdir(parents=True, exist_ok=True)

    existing = {}
    if resume and MANIFEST_FILE.exists():
        with open(MANIFEST_FILE) as f:
            existing = json.load(f)
        print(f"[Stage 1] Resuming — {len(existing.get('entries', []))} videos already collected")
        return existing

    print(f"[Stage 1] Fetching playlist: {playlist_url}")

    cmd = [
        "yt-dlp",
        "--flat-playlist",
        "--dump-single-json",
        "--no-warnings",
        playlist_url,
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except FileNotFoundError:
        print("ERROR: yt-dlp not found. Install with: pip install yt-dlp")
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print("ERROR: yt-dlp timed out fetching playlist")
        sys.exit(1)

    if result.returncode != 0:
        print(f"ERROR: yt-dlp failed:\n{result.stderr}")
        sys.exit(1)

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        print(f"ERROR: Could not parse yt-dlp output: {e}")
        sys.exit(1)

    entries = []
    raw_entries = data.get("entries", [data]) if data.get("_type") == "playlist" else [data]

    for item in raw_entries:
        if not item:
            continue
        video_id = item.get("id", "")
        duration = item.get("duration") or 0
        title = item.get("title", "Unknown")

        if not video_id:
            continue

        status = "PENDING"
        reason = ""
        if duration > MAX_VIDEO_DURATION:
            status = "SKIP"
            reason = f"duration {duration}s exceeds limit"

        entries.append({
            "video_id": video_id,
            "title": title,
            "duration_seconds": duration,
            "url": item.get("webpage_url", f"https://www.youtube.com/watch?v={video_id}"),
            "channel": item.get("channel", item.get("uploader", "")),
            "status": status,
            "reason": reason,
        })

    manifest = {
        "playlist_url": playlist_url,
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "total_videos": len(entries),
        "entries": entries,
    }

    with open(MANIFEST_FILE, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    skipped = sum(1 for e in entries if e["status"] == "SKIP")
    print(f"[Stage 1] Collected {len(entries)} videos ({skipped} skipped due to duration)")
    return manifest
