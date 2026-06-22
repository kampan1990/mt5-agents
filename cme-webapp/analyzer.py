"""
analyzer.py — Claude AI analyzer for Gold CME data
Sends scraped data to Claude claude-sonnet-4-6 and returns structured trading analysis.
"""

import json
import re
import anthropic
from config import ANTHROPIC_API_KEY


def analyze_gold_data(data: dict) -> dict:
    """
    Send Gold CME data to Claude for analysis.

    Args:
        data: dict with date, range_high, range_low, current_price, implied_volatility

    Returns:
        dict with keys: signal, confidence, analysis, range_high, range_low
    Raises:
        ValueError: if API key not set
        RuntimeError: if Claude API call fails
    """
    if not ANTHROPIC_API_KEY:
        raise ValueError("ANTHROPIC_API_KEY is not set in environment")

    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

    iv_text = f"{data['implied_volatility']:.2f}%" if data.get(
        'implied_volatility') else "N/A"

    prompt = f"""You are a professional Gold (XAUUSD) trading analyst. Analyze the following CME Vol2Vol Expected Range data for Gold futures (GC) and provide a trading recommendation.

CME Vol2Vol Expected Range Data:
- Date: {data.get('date', 'N/A')}
- Expected Range High: {data.get('range_high', 'N/A')}
- Expected Range Low: {data.get('range_low', 'N/A')}
- Current Price: {data.get('current_price', 'N/A')}
- Implied Volatility: {iv_text}

Based on this data, analyze:
1. Where is the current price relative to the expected range? (near high, near low, or middle)
2. What does the implied volatility suggest about market uncertainty?
3. What is the likely price direction based on the expected range boundaries?
4. What is your trading recommendation?

Respond ONLY with valid JSON in this exact format (no markdown, no extra text):
{{
  "signal": "BUY" or "SELL" or "HOLD",
  "confidence": <integer 0-100>,
  "analysis": "<2-3 sentence analysis explaining the reasoning>",
  "range_high": <number>,
  "range_low": <number>
}}"""

    response = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=512,
        messages=[
            {"role": "user", "content": prompt}
        ]
    )

    raw_text = response.content[0].text.strip()

    # Strip markdown code block if present
    if raw_text.startswith("```"):
        raw_text = re.sub(r'^```(?:json)?\n?', '', raw_text)
        raw_text = re.sub(r'\n?```$', '', raw_text)

    try:
        result = json.loads(raw_text)
    except json.JSONDecodeError:
        # Try to extract JSON object from text
        json_match = re.search(r'\{.*\}', raw_text, re.DOTALL)
        if json_match:
            result = json.loads(json_match.group())
        else:
            raise RuntimeError(
                f"Claude returned non-JSON response: {raw_text[:200]}")

    # Ensure required fields are present
    result.setdefault("signal", "HOLD")
    result.setdefault("confidence", 50)
    result.setdefault("analysis", "Analysis unavailable.")
    result.setdefault("range_high", data.get("range_high", 0))
    result.setdefault("range_low", data.get("range_low", 0))

    # Normalize signal
    result["signal"] = str(result["signal"]).upper()
    if result["signal"] not in ("BUY", "SELL", "HOLD"):
        result["signal"] = "HOLD"

    # Clamp confidence
    result["confidence"] = max(0, min(100, int(result["confidence"])))

    return result
