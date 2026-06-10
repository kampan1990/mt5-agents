"""tests/test_recovery.py — Unit tests for SmartRecoveryEngine logic."""

import pytest
import asyncio
from unittest.mock import AsyncMock, MagicMock

from config import Config
from strategies.recovery import RecoveryEngine
from core.state_manager import Position


def make_position(order_id: str, side: str, entry: float, amount: float, pnl: float) -> Position:
    return Position(
        id=1,
        magic=1001,
        side=side,
        entry_price=entry,
        amount=amount,
        order_id=order_id,
        unrealised_pnl=pnl,
        in_best_pool=False,
    )


@pytest.fixture
def config():
    cfg = Config()
    cfg.recovery.recovery_ratio = 0.30
    cfg.recovery.min_net_to_close = 0.0
    return cfg


@pytest.fixture
def mock_exchange():
    exc = AsyncMock()
    exc.close_position = AsyncMock(return_value={"id": "closed"})
    return exc


@pytest.fixture
def mock_state():
    state = AsyncMock()
    state.delete_position = AsyncMock()
    state.add_realised_pnl = AsyncMock()
    state.log_recovery_attempt = AsyncMock()
    return state


@pytest.fixture
def engine(config, mock_exchange, mock_state):
    return RecoveryEngine(config, mock_exchange, mock_state)


class TestRecoveryBudget:
    def test_zero_win_sum_skips(self, engine):
        engine._get_sorted_losers = AsyncMock(return_value=[])
        asyncio.get_event_loop().run_until_complete(engine.run(win_sum=0.0))
        engine._get_sorted_losers.assert_not_called()

    def test_negative_win_sum_skips(self, engine):
        engine._get_sorted_losers = AsyncMock(return_value=[])
        asyncio.get_event_loop().run_until_complete(engine.run(win_sum=-10.0))
        engine._get_sorted_losers.assert_not_called()


class TestAttemptRecovery:
    def test_closes_when_budget_sufficient(self, engine, mock_exchange, mock_state):
        pos = make_position("ord1", "buy", 100.0, 1.0, pnl=-5.0)
        remaining, closed = asyncio.get_event_loop().run_until_complete(
            engine._attempt_recovery(pos, remaining_budget=10.0)
        )
        assert closed is True
        assert remaining == pytest.approx(5.0)  # 10 - 5 used

    def test_skips_when_budget_insufficient(self, engine):
        pos = make_position("ord2", "sell", 100.0, 1.0, pnl=-20.0)
        remaining, closed = asyncio.get_event_loop().run_until_complete(
            engine._attempt_recovery(pos, remaining_budget=5.0)
        )
        # net = -20 + 5 = -15 < 0 → skip
        assert closed is False
        assert remaining == pytest.approx(5.0)  # unchanged
