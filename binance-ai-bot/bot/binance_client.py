"""Minimal Binance USDT-M Futures REST client (signed HMAC-SHA256).

Conditional orders (STOP_MARKET / TAKE_PROFIT_MARKET) go through the Algo Order
API (POST /fapi/v1/algoOrder) - since 2025-12-09 /fapi/v1/order rejects them
with error -4120.
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import time
from decimal import ROUND_DOWN, ROUND_HALF_UP, Decimal
from typing import Any, Optional
from urllib.parse import urlencode

import httpx

from .config import BinanceConfig

log = logging.getLogger(__name__)
PUBLIC_DATA_URL = "https://fapi.binance.com"   # klines for backtests (no key needed)


class BinanceAPIError(Exception):
    def __init__(self, status: int, code: Optional[int], msg: str):
        super().__init__(f"HTTP {status} code={code} {msg}")
        self.status, self.code, self.msg = status, code, msg


class SymbolRules:
    def __init__(self, info: dict):
        self.symbol = info["symbol"]
        f = {x["filterType"]: x for x in info["filters"]}
        self.tick = Decimal(f["PRICE_FILTER"]["tickSize"])
        self.step = Decimal(f["MARKET_LOT_SIZE"]["stepSize"] if "MARKET_LOT_SIZE" in f else f["LOT_SIZE"]["stepSize"])
        self.min_qty = Decimal(f["LOT_SIZE"]["minQty"])
        self.min_notional = Decimal(f.get("MIN_NOTIONAL", {}).get("notional", "0"))

    def round_qty(self, qty: float) -> Decimal:
        return (Decimal(str(qty)) / self.step).to_integral_value(ROUND_DOWN) * self.step

    def round_price(self, price: float) -> Decimal:
        return (Decimal(str(price)) / self.tick).to_integral_value(ROUND_HALF_UP) * self.tick


def _fmt(d: Decimal) -> str:
    return format(d.normalize(), "f")


class BinanceFutures:
    def __init__(self, cfg: BinanceConfig, http: Optional[httpx.Client] = None):
        self.cfg = cfg
        self.http = http or httpx.Client(base_url=cfg.base_url, timeout=15.0)
        self._rules: dict[str, SymbolRules] = {}
        self._time_offset_ms = 0

    # ---- transport ---------------------------------------------------------
    def _request(self, method: str, path: str, params: Optional[dict] = None, signed: bool = False) -> Any:
        params = {k: v for k, v in (params or {}).items() if v is not None}
        headers = {}
        if signed:
            if not self.cfg.api_key or not self.cfg.api_secret:
                raise RuntimeError("BINANCE_API_KEY / BINANCE_API_SECRET are not set")
            params["timestamp"] = int(time.time() * 1000) + self._time_offset_ms
            params["recvWindow"] = self.cfg.recv_window
            query = urlencode(params)
            sig = hmac.new(self.cfg.api_secret.encode(), query.encode(), hashlib.sha256).hexdigest()
            query += f"&signature={sig}"
            headers["X-MBX-APIKEY"] = self.cfg.api_key
        else:
            query = urlencode(params)
        url = f"{path}?{query}" if query else path
        resp = self.http.request(method, url, headers=headers)
        try:
            data = resp.json()
        except ValueError:
            data = None
        if resp.status_code >= 400 or (isinstance(data, dict) and data.get("code", 0) < 0):
            code = data.get("code") if isinstance(data, dict) else None
            msg = data.get("msg", resp.text) if isinstance(data, dict) else resp.text
            raise BinanceAPIError(resp.status_code, code, msg)
        return data

    def sync_time(self) -> None:
        server = self._request("GET", "/fapi/v1/time")["serverTime"]
        self._time_offset_ms = server - int(time.time() * 1000)

    # ---- market data -------------------------------------------------------
    def klines(self, symbol: str, interval: str, limit: int = 500,
               start_ms: Optional[int] = None, end_ms: Optional[int] = None) -> list[list]:
        return self._request("GET", "/fapi/v1/klines", {
            "symbol": symbol, "interval": interval, "limit": limit, "startTime": start_ms, "endTime": end_ms,
        })

    def funding_rate(self, symbol: str) -> float:
        return float(self._request("GET", "/fapi/v1/premiumIndex", {"symbol": symbol})["lastFundingRate"])

    def rules(self, symbol: str) -> SymbolRules:
        if not self._rules:
            info = self._request("GET", "/fapi/v1/exchangeInfo")
            self._rules = {s["symbol"]: SymbolRules(s) for s in info["symbols"]}
        return self._rules[symbol]

    # ---- account -----------------------------------------------------------
    def account(self) -> dict:
        return self._request("GET", "/fapi/v3/account", signed=True)

    def equity(self) -> float:
        """Margin balance (wallet + unrealized PnL) in USDT terms."""
        return float(self.account()["totalMarginBalance"])

    def positions(self) -> dict[str, dict]:
        rows = self._request("GET", "/fapi/v3/positionRisk", signed=True)
        return {r["symbol"]: r for r in rows if float(r["positionAmt"]) != 0}

    def is_hedge_mode(self) -> bool:
        return bool(self._request("GET", "/fapi/v1/positionSide/dual", signed=True)["dualSidePosition"])

    def set_leverage(self, symbol: str, leverage: int) -> None:
        self._request("POST", "/fapi/v1/leverage", {"symbol": symbol, "leverage": leverage}, signed=True)

    def set_isolated(self, symbol: str) -> None:
        try:
            self._request("POST", "/fapi/v1/marginType", {"symbol": symbol, "marginType": "ISOLATED"}, signed=True)
        except BinanceAPIError as e:
            if e.code != -4046:  # "No need to change margin type."
                raise

    # ---- orders ------------------------------------------------------------
    def market_order(self, symbol: str, side: str, qty: Decimal, reduce_only: bool = False) -> dict:
        return self._request("POST", "/fapi/v1/order", {
            "symbol": symbol, "side": side, "type": "MARKET", "quantity": _fmt(qty),
            "reduceOnly": "true" if reduce_only else None, "newOrderRespType": "RESULT",
        }, signed=True)

    def conditional_order(self, symbol: str, side: str, order_type: str, trigger_price: Decimal,
                          qty: Decimal, client_id: Optional[str] = None) -> dict:
        """Reduce-only STOP_MARKET / TAKE_PROFIT_MARKET via the Algo Order API."""
        return self._request("POST", "/fapi/v1/algoOrder", {
            "algoType": "CONDITIONAL", "symbol": symbol, "side": side, "type": order_type,
            "triggerPrice": _fmt(trigger_price), "quantity": _fmt(qty), "reduceOnly": "true",
            "workingType": "MARK_PRICE", "priceProtect": "true", "clientAlgoId": client_id,
        }, signed=True)

    def open_algo_orders(self, symbol: Optional[str] = None) -> list[dict]:
        data = self._request("GET", "/fapi/v1/openAlgoOrders", {"symbol": symbol}, signed=True)
        return data.get("orders", []) if isinstance(data, dict) else data

    def cancel_algo_order(self, symbol: str, algo_id: int) -> dict:
        return self._request("DELETE", "/fapi/v1/algoOrder", {"symbol": symbol, "algoId": algo_id}, signed=True)

    def cancel_all_algo_orders(self, symbol: str) -> int:
        n = 0
        for o in self.open_algo_orders(symbol):
            try:
                self.cancel_algo_order(symbol, o["algoId"])
                n += 1
            except BinanceAPIError as e:
                log.warning("cancel algo %s %s failed: %s", symbol, o.get("algoId"), e)
        return n


def fetch_history(symbol: str, interval: str, days: int, http: Optional[httpx.Client] = None) -> list[list]:
    """Download closed klines for the last ``days`` days from the public production API."""
    client = BinanceFutures(BinanceConfig(env="live", base_url=PUBLIC_DATA_URL), http=http)
    end = int(time.time() * 1000)
    start = end - days * 86_400_000
    rows: list[list] = []
    while start < end:
        batch = client.klines(symbol, interval, limit=1500, start_ms=start, end_ms=end)
        if not batch:
            break
        rows.extend(batch)
        start = batch[-1][0] + 1
        if len(batch) < 1500:
            break
    now = int(time.time() * 1000)
    return [r for r in rows if r[6] < now]  # closed candles only
