"""Shared data types."""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Optional

from pydantic import BaseModel, Field


class Action(str, Enum):
    LONG = "LONG"
    SHORT = "SHORT"
    CLOSE = "CLOSE"
    HOLD = "HOLD"


class Decision(BaseModel):
    """What a decision engine (Claude or rule-based) wants to do.

    SL/TP are expressed as ATR multiples from the entry price, so the model never
    needs absolute prices and the risk manager can bound them easily.
    """

    action: Action = Field(description="LONG/SHORT to open, CLOSE to exit the current position, HOLD to do nothing")
    confidence: float = Field(description="0.0-1.0 confidence in this action")
    stop_loss_atr: Optional[float] = Field(
        default=None, description="Stop-loss distance from entry in ATR multiples (required for LONG/SHORT)"
    )
    take_profit_atr: Optional[float] = Field(
        default=None, description="Take-profit distance from entry in ATR multiples (required for LONG/SHORT)"
    )
    reasoning: str = Field(description="Short explanation (1-3 sentences)")

    @classmethod
    def hold(cls, reason: str) -> "Decision":
        return cls(action=Action.HOLD, confidence=0.0, reasoning=reason)


@dataclass
class PositionInfo:
    side: str            # "LONG" | "SHORT"
    qty: float
    entry_price: float
    unrealized_pnl: float = 0.0
    bars_held: int = 0


@dataclass
class MarketSnapshot:
    symbol: str
    price: float                    # last closed price (internal, not sent when anonymized)
    atr: float                      # ATR(14) on the primary interval
    features: dict[str, Any]        # what the decision engine sees
    position: Optional[PositionInfo] = None


@dataclass
class OrderPlan:
    symbol: str
    side: str           # "LONG" | "SHORT"
    qty: float
    entry_price: float  # reference price used for sizing
    stop_loss: float
    take_profit: float
    risk_amount: float  # account currency lost if SL hit
    decision: Decision
    meta: dict[str, Any] = field(default_factory=dict)
