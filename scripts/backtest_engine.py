"""Stage 5: Generate MQL5 pseudocode templates from skill.json files."""

import json
import random
from datetime import datetime, timezone

from config import KNOWLEDGE_BASE_DIR, CATALOG_FILE

MQL5_TEMPLATE = """\
//+------------------------------------------------------------------+
//| SKILL: {skill_name}
//| Category: {category}
//| Skill ID: {skill_id}
//| Confidence: {confidence_score:.0%}
//| Source Videos: {source_count} clips
//|
//| AUTO-GENERATED PSEUDOCODE — review and complete before live use
//| SL/TP are required by project rules and are stubbed below
//+------------------------------------------------------------------+
#property strict
#property description "AI-extracted: {skill_name}"

//--- Inputs
input double   RiskPercent   = {max_risk_pct};    // % balance per trade
input int      MagicNumber   = {magic};            // unique EA identifier
{indicator_inputs}

//--- Entry/Exit helpers (fill in exact MQL5 logic)
bool IsLongSignal()
{{
   // ENTRY CONDITIONS (LONG):
{long_comments}
   return false; // TODO: implement
}}

bool IsShortSignal()
{{
   // ENTRY CONDITIONS (SHORT):
{short_comments}
   return false; // TODO: implement
}}

double CalculateSL(bool isLong)
{{
   // SL METHOD: {sl_method}
   double atr = iATR(_Symbol, PERIOD_CURRENT, 14, 0);
   return isLong ? Bid - atr : Ask + atr; // TODO: adjust to sl_method above
}}

double CalculateTP(bool isLong)
{{
   // TP METHOD: {tp_method}
   double sl = MathAbs(Close[0] - CalculateSL(isLong));
   return isLong ? Ask + sl * {rr_ratio} : Bid - sl * {rr_ratio}; // RR = 1:{rr_ratio}
}}

double CalculateLotSize(double slPips)
{{
   // Risk {max_risk_pct}% of account balance
   double riskAmount = AccountBalance() * RiskPercent / 100.0;
   double tickValue = MarketInfo(_Symbol, MODE_TICKVALUE);
   if(tickValue <= 0 || slPips <= 0) return 0.01;
   double lots = riskAmount / (slPips * tickValue);
   lots = MathMax(MarketInfo(_Symbol, MODE_MINLOT),
          MathMin(MarketInfo(_Symbol, MODE_MAXLOT), lots));
   return NormalizeDouble(lots, 2);
}}

bool IsNewBar()
{{
   static datetime lastBar = 0;
   datetime current = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(current == lastBar) return false;
   lastBar = current;
   return true;
}}

void OpenBuy(double lots)
{{
   double sl = CalculateSL(true);
   double tp = CalculateTP(true);
   int ticket = OrderSend(_Symbol, OP_BUY, lots, Ask, 3,
                           sl, tp, "AI-{skill_id}", MagicNumber, 0, clrBlue);
   if(ticket < 0) Print("OrderSend BUY error: ", GetLastError());
}}

void OpenSell(double lots)
{{
   double sl = CalculateSL(false);
   double tp = CalculateTP(false);
   int ticket = OrderSend(_Symbol, OP_SELL, lots, Bid, 3,
                           sl, tp, "AI-{skill_id}", MagicNumber, 0, clrRed);
   if(ticket < 0) Print("OrderSend SELL error: ", GetLastError());
}}

void OnTick()
{{
   if(!IsNewBar()) return;

   // FILTERS:{filter_comments}

   double sl = CalculateSL(true);
   double slPips = MathAbs(Ask - sl) / Point;
   double lots = CalculateLotSize(slPips);
   if(lots <= 0) return;

   if(IsLongSignal())  OpenBuy(lots);
   if(IsShortSignal()) OpenSell(lots);
}}
//+------------------------------------------------------------------+
"""

INDICATOR_INPUT_MAP = {
    "rsi": "input int      RSI_Period   = 14;             // RSI period\n"
           "input int      RSI_OB       = 70;             // RSI overbought\n"
           "input int      RSI_OS       = 30;             // RSI oversold",
    "ema": "input int      EMA_Fast     = 20;             // EMA fast period\n"
           "input int      EMA_Slow     = 50;             // EMA slow period",
    "sma": "input int      SMA_Period   = 50;             // SMA period",
    "atr": "input int      ATR_Period   = 14;             // ATR period",
    "ma":  "input int      MA_Period    = 20;             // MA period",
    "macd":"input int      MACD_Fast    = 12;             // MACD fast\n"
           "input int      MACD_Slow    = 26;             // MACD slow\n"
           "input int      MACD_Signal  = 9;              // MACD signal",
}


def _build_indicator_inputs(indicators: list) -> str:
    added = set()
    lines = []
    for ind in indicators:
        ind_lower = ind.lower()
        for key, inp in INDICATOR_INPUT_MAP.items():
            if key in ind_lower and key not in added:
                lines.append(inp)
                added.add(key)
    return "\n".join(lines)


def _format_conditions_as_comments(conditions: list, prefix: str = "//   ") -> str:
    if not conditions:
        return f"{prefix}(no conditions stated)"
    return "\n".join(f"{prefix}{c}" for c in conditions)


def _format_filters(filters: list) -> str:
    if not filters:
        return "\n   // (no filters stated)"
    return "\n" + "\n".join(f"   // FILTER: {f}" for f in filters)


def generate_templates() -> int:
    """Generate MQL5 pseudocode templates for all valid skills."""
    if not CATALOG_FILE.exists():
        print("[Stage 5] No catalog found. Run Stage 4 first.")
        return 0

    with open(CATALOG_FILE) as f:
        catalog = json.load(f)

    eligible = [s for s in catalog.values() if s.get("has_valid_sltp")]
    generated = 0

    print(f"[Stage 5] MQL5 Template Generation — {len(eligible)} eligible skills")

    for skill in eligible:
        skill_id = skill["skill_id"]
        category = skill["category"]
        skill_dir = KNOWLEDGE_BASE_DIR / category / skill_id
        template_file = skill_dir / "template.mq5"

        if template_file.exists():
            continue

        skill_dir.mkdir(parents=True, exist_ok=True)

        entry = skill.get("entry_conditions", {})
        exit_cond = skill.get("exit_conditions", {})
        risk = skill.get("risk_rules", {})

        content = MQL5_TEMPLATE.format(
            skill_name=skill["name"],
            category=skill["category"],
            skill_id=skill_id,
            confidence_score=skill["confidence_score"],
            source_count=len(skill.get("source_videos", [])),
            max_risk_pct=risk.get("max_risk_pct", 1.0),
            magic=random.randint(100000, 999999),
            indicator_inputs=_build_indicator_inputs(skill.get("indicators", [])),
            long_comments=_format_conditions_as_comments(entry.get("long", []), "   // LONG: "),
            short_comments=_format_conditions_as_comments(entry.get("short", []), "   // SHORT: "),
            sl_method=exit_cond.get("sl_method", "not specified"),
            tp_method=exit_cond.get("tp_method", "not specified"),
            rr_ratio=risk.get("rr_ratio", 2.0),
            filter_comments=_format_filters(risk.get("filters", [])),
        )

        with open(template_file, "w", encoding="utf-8") as f:
            f.write(content)

        print(f"  [{category}] {skill['name'][:55]}")
        generated += 1

    print(f"\n[Stage 5] Done — {generated} templates generated")
    return generated
