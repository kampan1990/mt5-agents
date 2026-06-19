"""Stage 2: Extract transcripts from YouTube videos."""

import json
import time
from datetime import datetime, timezone

from youtube_transcript_api import (
    YouTubeTranscriptApi,
    TranscriptsDisabled,
    NoTranscriptFound,
)

from config import (
    MANIFEST_FILE,
    TRANSCRIPTS_DIR,
    STAGE2_CHECKPOINT,
    MIN_TRANSCRIPT_WORDS,
    CHECKPOINTS_DIR,
)

LANG_PRIORITY = ["th", "en", "en-US", "en-GB"]
CHECKPOINT_EVERY = 10


def _clean_text(segments: list) -> str:
    """Merge transcript segments and remove noise."""
    raw = " ".join(s.get("text", "") for s in segments)
    for artifact in ["[Music]", "[Applause]", "[Laughter]", "[music]", "[applause]"]:
        raw = raw.replace(artifact, "")
    return " ".join(raw.split())


def _load_checkpoint() -> set:
    if STAGE2_CHECKPOINT.exists():
        with open(STAGE2_CHECKPOINT) as f:
            data = json.load(f)
        return set(data.get("done", []) + data.get("skip", []) + data.get("error", []))
    return set()


def _save_checkpoint(done: list, skip: list, errors: list):
    CHECKPOINTS_DIR.mkdir(parents=True, exist_ok=True)
    with open(STAGE2_CHECKPOINT, "w") as f:
        json.dump({"done": done, "skip": skip, "error": errors}, f, indent=2)


def extract_transcripts(resume: bool = False) -> dict:
    """Process all PENDING videos in the manifest and extract transcripts."""
    TRANSCRIPTS_DIR.mkdir(parents=True, exist_ok=True)

    if not MANIFEST_FILE.exists():
        raise FileNotFoundError("Manifest not found. Run Stage 1 first.")

    with open(MANIFEST_FILE) as f:
        manifest = json.load(f)

    processed_ids = _load_checkpoint() if resume else set()
    done, skip, errors = [], [], []

    pending = [
        e for e in manifest["entries"]
        if e["status"] == "PENDING" and e["video_id"] not in processed_ids
    ]

    total = len(pending)
    print(f"[Stage 2] Transcript Extraction — {total} videos to process")

    for idx, entry in enumerate(pending, 1):
        video_id = entry["video_id"]
        title = entry["title"]
        out_file = TRANSCRIPTS_DIR / f"{video_id}.json"

        print(f"  [{idx}/{total}] {title[:60]}...", end=" ", flush=True)

        try:
            transcript_list = YouTubeTranscriptApi.list_transcripts(video_id)

            transcript = None
            lang_used = None
            for lang in LANG_PRIORITY:
                try:
                    transcript = transcript_list.find_transcript([lang])
                    lang_used = lang
                    break
                except Exception:
                    continue

            if transcript is None:
                try:
                    transcript = transcript_list.find_generated_transcript(LANG_PRIORITY)
                    lang_used = "auto"
                except Exception:
                    pass

            if transcript is None:
                all_transcripts = list(transcript_list)
                if all_transcripts:
                    transcript = all_transcripts[0]
                    lang_used = transcript.language_code

            if transcript is None:
                raise NoTranscriptFound(video_id, LANG_PRIORITY, {})

            segments = transcript.fetch()
            text = _clean_text(segments)
            word_count = len(text.split())

            if word_count < MIN_TRANSCRIPT_WORDS:
                entry["status"] = "SKIP"
                entry["reason"] = f"only {word_count} words"
                skip.append(video_id)
                print(f"SKIP (short: {word_count} words)")
                continue

            result = {
                "video_id": video_id,
                "title": title,
                "url": entry.get("url", ""),
                "language": lang_used,
                "word_count": word_count,
                "raw_text": text,
                "extracted_at": datetime.now(timezone.utc).isoformat(),
            }

            with open(out_file, "w", encoding="utf-8") as f:
                json.dump(result, f, ensure_ascii=False, indent=2)

            entry["status"] = "DONE"
            done.append(video_id)
            print(f"OK ({word_count} words, {lang_used})")

        except TranscriptsDisabled:
            entry["status"] = "SKIP"
            entry["reason"] = "transcripts disabled"
            skip.append(video_id)
            print("SKIP (disabled)")

        except NoTranscriptFound:
            entry["status"] = "SKIP"
            entry["reason"] = "no transcript available"
            skip.append(video_id)
            print("SKIP (no transcript)")

        except Exception as e:
            entry["status"] = "ERROR"
            entry["reason"] = str(e)
            errors.append(video_id)
            print(f"ERROR: {e}")

        if idx % CHECKPOINT_EVERY == 0:
            _save_checkpoint(done, skip, errors)
            with open(MANIFEST_FILE, "w", encoding="utf-8") as f:
                json.dump(manifest, f, ensure_ascii=False, indent=2)

    _save_checkpoint(done, skip, errors)
    with open(MANIFEST_FILE, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    print(f"\n[Stage 2] Done — {len(done)} transcripts, {len(skip)} skipped, {len(errors)} errors")
    return {"done": done, "skip": skip, "errors": errors}
