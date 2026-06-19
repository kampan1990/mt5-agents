import os
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

ROOT_DIR = Path(__file__).parent.parent

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
YOUTUBE_COOKIES_PATH = os.getenv("YOUTUBE_COOKIES_PATH", "")

BATCH_SIZE = int(os.getenv("BATCH_SIZE", "5"))
MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))
RETRY_BACKOFF_BASE = int(os.getenv("RETRY_BACKOFF_BASE", "2"))
MIN_CONFIDENCE = float(os.getenv("MIN_CONFIDENCE", "0.6"))
MIN_TRANSCRIPT_WORDS = int(os.getenv("MIN_TRANSCRIPT_WORDS", "200"))
MAX_VIDEO_DURATION = int(os.getenv("MAX_VIDEO_DURATION", "10800"))  # 3 hours

CLAUDE_MODEL = os.getenv("CLAUDE_MODEL", "claude-sonnet-4-6")
CLAUDE_TEMPERATURE = float(os.getenv("CLAUDE_TEMPERATURE", "0.1"))

DATA_DIR = ROOT_DIR / "data"
TRANSCRIPTS_DIR = DATA_DIR / "transcripts"
EXTRACTED_DIR = DATA_DIR / "extracted"
CHECKPOINTS_DIR = DATA_DIR / "checkpoints"
LOW_CONFIDENCE_DIR = DATA_DIR / "low_confidence"
KNOWLEDGE_BASE_DIR = ROOT_DIR / "knowledge_base" / "skills"
REPORTS_DIR = ROOT_DIR / "reports"

MANIFEST_FILE = CHECKPOINTS_DIR / "stage1_manifest.json"
STAGE2_CHECKPOINT = CHECKPOINTS_DIR / "stage2_progress.json"
STAGE3_CHECKPOINT = CHECKPOINTS_DIR / "stage3_progress.json"
CATALOG_FILE = ROOT_DIR / "knowledge_base" / "catalog.json"

SKILL_CATEGORIES = {
    "rsi": ["rsi", "relative strength index", "oversold", "overbought"],
    "wave-analysis": ["wave", "elliott", "harmonic", "fibonacci"],
    "trendline": ["trendline", "trend line", "channel", "breakout"],
    "price-action": ["price action", "candlestick", "support", "resistance", "order block", "supply", "demand"],
    "risk-management": ["risk management", "position sizing", "drawdown", "money management"],
    "scalping": ["scalp", "scalping", "m1", "m5", "quick"],
    "swing": ["swing", "swing trading", "multi-day", "weekly"],
    "moving-average": ["ema", "sma", "ma cross", "moving average", "golden cross", "death cross"],
    "grid-martingale": ["grid", "martingale", "averaging down"],
    "indicator-combo": [],
}

CATEGORY_DISPLAY = {
    "rsi": "RSI Strategies",
    "wave-analysis": "Wave Analysis",
    "trendline": "Trendline Trading",
    "price-action": "Price Action",
    "risk-management": "Risk Management",
    "scalping": "Scalping",
    "swing": "Swing Trading",
    "moving-average": "Moving Average",
    "grid-martingale": "Grid & Martingale (HIGH RISK)",
    "indicator-combo": "Multi-Indicator Combo",
}
