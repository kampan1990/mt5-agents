"""Stage 3: Extract structured trading logic from transcripts using Claude API."""

import json
import time
from datetime import datetime, timezone

import anthropic

from config import (
    ANTHROPIC_API_KEY,
    TRANSCRIPTS_DIR,
    EXTRACTED_DIR,
    STAGE3_CHECKPOINT,
    LOW_CONFIDENCE_DIR,
    CHECKPOINTS_DIR,
    BATCH_SIZE,
    MAX_RETRIES,
    RETRY_BACKOFF_BASE,
    MIN_CONFIDENCE,
    CLAUDE_MODEL,
    CLAUDE_TEMPERATURE,
)

EXTRACTION_SCHEMA = {
    "strategy_type": "string: scalping|swing|day-trading|position|unknown",
    "indicators": "list of strings, e.g. ['RSI(14)', 'EMA(20)', 'ATR(14)']",
    "timeframes": "list of strings, e.g. ['M15', 'H1']",
    "symbols": "list of strings, e.g. ['XAUUSD', 'EURUSD']",
    "entry_conditions": {
        "long": "list of explicit entry rules for long positions",
        "short": "list of explicit entry rules for short positions",
    },
    "exit_conditions": {
        "tp_method": "string describing take profit method (REQUIRED)",
        "sl_method": "string describing stop loss method (REQUIRED)",
        "trailing_stop": "string or null",
    },
    "risk_rules": {
        "max_risk_pct": "float, default 1.0 if not stated",
        "rr_ratio": "float, default 2.0 if not stated",
        "filters": "list of trading filters mentioned",
    },
    "confidence_score": "float 0.0-1.0 indicating how complete and explicit the strategy rules are",
    "raw_notes": "string with any additional context that did not fit the schema",
}

SYSTEM_PROMPT = """You are a trading strategy analyst. Your job is to extract ONLY explicitly stated trading rules from video transcripts.

Rules:
- Extract ONLY what is explicitly mentioned. Do NOT infer or add rules that are not stated.
- If entry conditions are missing, set them to empty lists.
- If sl_method or tp_method are unclear, write exactly what was said, even if vague.
- sl_method and tp_method fields are ALWAYS required — never omit them.
- confidence_score: 1.0 = fully complete strategy with all rules. 0.0 = no tradeable strategy found.
- Respond with a JSON array, one object per video in the same order as input."""


def _build_extraction_prompt(batch: list) -> str:
    videos_text = ""
    for i, item in enumerate(batch, 1):
        truncated = item["text"][:4000]  # limit per video to control token usage
        videos_text += f"\n\n--- VIDEO {i}: {item['title']} ---\n{truncated}"

    schema_str = json.dumps(EXTRACTION_SCHEMA, indent=2)
    return f"""Extract trading strategies from these {len(batch)} video transcripts.

Return a JSON array with {len(batch)} objects, one per video, matching this schema:
{schema_str}

TRANSCRIPTS:{videos_text}

Return ONLY valid JSON array, no explanation."""


def _load_checkpoint() -> set:
    if STAGE3_CHECKPOINT.exists():
        with open(STAGE3_CHECKPOINT) as f:
            data = json.load(f)
        return set(data.get("done", []) + data.get("error", []))
    return set()


def _save_checkpoint(done: list, errors: list):
    CHECKPOINTS_DIR.mkdir(parents=True, exist_ok=True)
    with open(STAGE3_CHECKPOINT, "w") as f:
        json.dump({"done": done, "error": errors}, f, indent=2)


def _call_claude_with_retry(client: anthropic.Anthropic, prompt: str) -> str:
    for attempt in range(MAX_RETRIES):
        try:
            response = client.messages.create(
                model=CLAUDE_MODEL,
                max_tokens=4096,
                temperature=CLAUDE_TEMPERATURE,
                system=SYSTEM_PROMPT,
                messages=[{"role": "user", "content": prompt}],
            )
            return response.content[0].text
        except anthropic.RateLimitError:
            wait = RETRY_BACKOFF_BASE ** (attempt + 1)
            print(f"    Rate limited, waiting {wait}s...")
            time.sleep(wait)
        except anthropic.APIError as e:
            if attempt == MAX_RETRIES - 1:
                raise
            wait = RETRY_BACKOFF_BASE ** (attempt + 1)
            print(f"    API error ({e}), retry in {wait}s...")
            time.sleep(wait)
    raise RuntimeError("Max retries exceeded")


def _validate_logic(logic: dict) -> tuple[bool, str]:
    """Return (is_valid, reason)."""
    if not isinstance(logic, dict):
        return False, "not a dict"
    exit_cond = logic.get("exit_conditions", {})
    if not exit_cond.get("sl_method"):
        return False, "missing sl_method"
    if not exit_cond.get("tp_method"):
        return False, "missing tp_method"
    score = logic.get("confidence_score")
    if not isinstance(score, (int, float)):
        return False, "invalid confidence_score"
    return True, ""


def extract_logic(resume: bool = False) -> dict:
    """Process transcript files and extract trading logic via Claude."""
    EXTRACTED_DIR.mkdir(parents=True, exist_ok=True)
    LOW_CONFIDENCE_DIR.mkdir(parents=True, exist_ok=True)

    if not ANTHROPIC_API_KEY:
        raise ValueError("ANTHROPIC_API_KEY not set in environment")

    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

    processed_ids = _load_checkpoint() if resume else set()

    transcript_files = [
        f for f in TRANSCRIPTS_DIR.glob("*.json")
        if f.stem not in processed_ids
    ]

    if not transcript_files:
        print("[Stage 3] No new transcripts to process")
        return {"done": [], "errors": []}

    items = []
    for tf in transcript_files:
        with open(tf, encoding="utf-8") as f:
            data = json.load(f)
        items.append({
            "video_id": data["video_id"],
            "title": data.get("title", ""),
            "text": data.get("raw_text", ""),
        })

    batches = [items[i:i + BATCH_SIZE] for i in range(0, len(items), BATCH_SIZE)]
    total = len(items)
    done, errors = [], []

    print(f"[Stage 3] Logic Extraction — {total} transcripts in {len(batches)} batches")

    for b_idx, batch in enumerate(batches, 1):
        print(f"  Batch {b_idx}/{len(batches)} ({len(batch)} videos)...", end=" ", flush=True)

        try:
            prompt = _build_extraction_prompt(batch)
            raw_response = _call_claude_with_retry(client, prompt)

            # Strip markdown code fences if present
            text = raw_response.strip()
            if text.startswith("```"):
                text = text.split("```", 2)[1]
                if text.startswith("json"):
                    text = text[4:]
                text = text.rsplit("```", 1)[0]

            results = json.loads(text.strip())

            if not isinstance(results, list):
                results = [results]

            for item, logic in zip(batch, results):
                video_id = item["video_id"]
                logic["video_id"] = video_id
                logic["source_title"] = item["title"]
                logic["extracted_at"] = datetime.now(timezone.utc).isoformat()

                valid, reason = _validate_logic(logic)
                if not valid:
                    errors.append(video_id)
                    print(f"\n    INVALID {video_id}: {reason}", end="")
                    continue

                score = float(logic.get("confidence_score", 0))
                out_dir = EXTRACTED_DIR if score >= MIN_CONFIDENCE else LOW_CONFIDENCE_DIR
                out_file = out_dir / f"{video_id}_logic.json"

                with open(out_file, "w", encoding="utf-8") as f:
                    json.dump(logic, f, ensure_ascii=False, indent=2)

                done.append(video_id)

            print("OK")

        except json.JSONDecodeError as e:
            for item in batch:
                errors.append(item["video_id"])
            print(f"PARSE ERROR: {e}")

        except Exception as e:
            for item in batch:
                errors.append(item["video_id"])
            print(f"ERROR: {e}")

        _save_checkpoint(done, errors)

    print(f"\n[Stage 3] Done — {len(done)} extracted, {len(errors)} errors")
    return {"done": done, "errors": errors}
