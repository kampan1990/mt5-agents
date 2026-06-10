"""tests/test_pnl_tracker.py — Unit tests for PNL calculation helpers."""

import pytest
from utils.pnl_tracker import calc_unrealised_pnl, calc_total_pnl, group_pnl_by_magic


class TestCalcUnrealisedPnl:
    def test_buy_profit(self):
        pnl = calc_unrealised_pnl("buy", entry_price=100.0, current_price=110.0, amount=1.0)
        assert pnl == pytest.approx(10.0)

    def test_buy_loss(self):
        pnl = calc_unrealised_pnl("buy", entry_price=100.0, current_price=90.0, amount=1.0)
        assert pnl == pytest.approx(-10.0)

    def test_sell_profit(self):
        pnl = calc_unrealised_pnl("sell", entry_price=100.0, current_price=90.0, amount=1.0)
        assert pnl == pytest.approx(10.0)

    def test_sell_loss(self):
        pnl = calc_unrealised_pnl("sell", entry_price=100.0, current_price=110.0, amount=1.0)
        assert pnl == pytest.approx(-10.0)

    def test_invalid_side(self):
        with pytest.raises(ValueError):
            calc_unrealised_pnl("long", 100.0, 110.0, 1.0)

    def test_amount_scaling(self):
        pnl = calc_unrealised_pnl("buy", 50000.0, 51000.0, 0.01)
        assert pnl == pytest.approx(10.0)


class TestCalcTotalPnl:
    def test_precomputed_pnl(self):
        positions = [
            {"unrealised_pnl": 5.0},
            {"unrealised_pnl": -3.0},
        ]
        assert calc_total_pnl(positions) == pytest.approx(2.0)

    def test_computed_pnl(self):
        positions = [
            {"side": "buy", "entry_price": 100.0, "current_price": 105.0, "amount": 1.0},
            {"side": "sell", "entry_price": 100.0, "current_price": 95.0, "amount": 1.0},
        ]
        assert calc_total_pnl(positions) == pytest.approx(10.0)

    def test_empty(self):
        assert calc_total_pnl([]) == pytest.approx(0.0)


class TestGroupPnlByMagic:
    def test_grouping(self):
        class FakePos:
            def __init__(self, magic, pnl):
                self.magic = magic
                self.unrealised_pnl = pnl

        positions = [
            FakePos(1001, 10.0),
            FakePos(1001, -5.0),
            FakePos(1003, 20.0),
        ]
        result = group_pnl_by_magic(positions)
        assert result[1001] == pytest.approx(5.0)
        assert result[1003] == pytest.approx(20.0)

    def test_empty(self):
        assert group_pnl_by_magic([]) == {}
