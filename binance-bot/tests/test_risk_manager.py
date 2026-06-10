"""tests/test_risk_manager.py — Unit tests for RiskManager guards."""

import pytest
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch
from pathlib import Path

from config import Config, MAGIC_M1_BUY_GRID
from core.risk_manager import RiskManager
from core.state_manager import MagicState


@pytest.fixture
def config():
    return Config()


@pytest.fixture
def mock_state():
    state = AsyncMock()
    state.get_daily_pnl = AsyncMock(return_value=0.0)
    state.get_all_positions = AsyncMock(return_value=[])
    state.get_magic_state = AsyncMock(
        return_value=MagicState(magic=MAGIC_M1_BUY_GRID, locked=False)
    )
    return state


@pytest.fixture
def mock_exchange():
    exc = AsyncMock()
    exc.get_balance = AsyncMock(
        return_value={"free": {"USDT": 1000.0}, "total": {"USDT": 1000.0}}
    )
    exc.round_qty = MagicMock(side_effect=lambda x: round(x, 3))
    return exc


@pytest.fixture
def risk(config, mock_state, mock_exchange):
    return RiskManager(config, mock_state, mock_exchange)


class TestEmergencyStop:
    def test_no_stop_file(self, risk):
        # Ensure stop file does not exist
        risk.config.risk.emergency_stop_file = Path("/tmp/bot_test_emergency_no_exist")
        result = asyncio.get_event_loop().run_until_complete(
            risk._check_emergency_stop()
        )
        assert result is True

    def test_stop_file_present(self, risk, tmp_path):
        stop_file = tmp_path / "stop"
        stop_file.touch()
        risk.config.risk.emergency_stop_file = stop_file
        result = asyncio.get_event_loop().run_until_complete(
            risk._check_emergency_stop()
        )
        assert result is False


class TestDailyLossLimit:
    def test_within_limit(self, risk, mock_state):
        mock_state.get_daily_pnl = AsyncMock(return_value=-50.0)
        result = asyncio.get_event_loop().run_until_complete(
            risk._check_daily_loss()
        )
        assert result is True

    def test_at_limit(self, risk, mock_state):
        mock_state.get_daily_pnl = AsyncMock(
            return_value=risk.config.risk.daily_loss_limit_usdt
        )
        result = asyncio.get_event_loop().run_until_complete(
            risk._check_daily_loss()
        )
        assert result is False


class TestMaxPositions:
    def test_under_limit(self, risk, mock_state):
        mock_state.get_all_positions = AsyncMock(return_value=[MagicMock()] * 5)
        result = asyncio.get_event_loop().run_until_complete(
            risk._check_max_positions()
        )
        assert result is True

    def test_at_limit(self, risk, mock_state):
        max_pos = risk.config.risk.max_total_positions
        mock_state.get_all_positions = AsyncMock(return_value=[MagicMock()] * max_pos)
        result = asyncio.get_event_loop().run_until_complete(
            risk._check_max_positions()
        )
        assert result is False


class TestMagicLocked:
    def test_unlocked(self, risk, mock_state):
        mock_state.get_magic_state = AsyncMock(
            return_value=MagicState(magic=MAGIC_M1_BUY_GRID, locked=False)
        )
        result = asyncio.get_event_loop().run_until_complete(
            risk._check_magic_locked(MAGIC_M1_BUY_GRID)
        )
        assert result is True

    def test_locked(self, risk, mock_state):
        mock_state.get_magic_state = AsyncMock(
            return_value=MagicState(magic=MAGIC_M1_BUY_GRID, locked=True)
        )
        result = asyncio.get_event_loop().run_until_complete(
            risk._check_magic_locked(MAGIC_M1_BUY_GRID)
        )
        assert result is False


class TestLotSizing:
    def test_counter_trend_multiplier(self, risk):
        lot = risk.calculate_lot(base_lot=0.001, is_counter_trend=True)
        expected = round(
            0.001 * risk.config.grid.counter_trend_multiplier, 3
        )
        assert lot == pytest.approx(expected)

    def test_with_trend_multiplier(self, risk):
        lot = risk.calculate_lot(base_lot=0.001, is_counter_trend=False)
        expected = round(
            0.001 * risk.config.grid.with_trend_multiplier, 3
        )
        assert lot == pytest.approx(expected)
