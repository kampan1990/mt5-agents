"""
utils/pnl_tracker.py — Real-time PNL computation helper.

Calculates unrealised and realised PNL for open positions.

Unrealised PNL formula (linear futures):
    BUY:  (current_price - entry_price) * amount
    SELL: (entry_price - current_price) * amount

All values are in USDT (quote currency).
"""

from __future__ import annotations


def calc_unrealised_pnl(
    side: str,
    entry_price: float,
    current_price: float,
    amount: float,
) -> float:
    """Calculate unrealised PNL for a single position.

    Parameters
    ----------
    side:
        'buy' or 'sell'.
    entry_price:
        Price at which the position was opened.
    current_price:
        Current mark price.
    amount:
        Contract quantity.

    Returns
    -------
    float
        Unrealised PNL in USDT.  Positive = profit, negative = loss.

    Raises
    ------
    ValueError
        If side is not 'buy' or 'sell'.
    """
    if side == "buy":
        return (current_price - entry_price) * amount
    elif side == "sell":
        return (entry_price - current_price) * amount
    else:
        raise ValueError(f"Unknown side: {side!r}")


def calc_total_pnl(positions: list[dict]) -> float:
    """Sum unrealised PNL across a list of position dicts.

    Parameters
    ----------
    positions:
        List of dicts with keys: 'side', 'entry_price', 'current_price',
        'amount'.  Each dict may also contain a precomputed 'unrealised_pnl'
        key — if present, it is used directly without recomputing.

    Returns
    -------
    float
        Total unrealised PNL (USDT).
    """
    total = 0.0
    for pos in positions:
        if "unrealised_pnl" in pos:
            total += pos["unrealised_pnl"]
        else:
            total += calc_unrealised_pnl(
                pos["side"],
                pos["entry_price"],
                pos["current_price"],
                pos["amount"],
            )
    return total


def group_pnl_by_magic(positions: list) -> dict[int, float]:
    """Aggregate unrealised PNL per magic number.

    Parameters
    ----------
    positions:
        List of Position dataclass instances (must have .magic and
        .unrealised_pnl attributes).

    Returns
    -------
    dict[int, float]
        {magic: total_unrealised_pnl}
    """
    result: dict[int, float] = {}
    for pos in positions:
        result[pos.magic] = result.get(pos.magic, 0.0) + pos.unrealised_pnl
    return result
