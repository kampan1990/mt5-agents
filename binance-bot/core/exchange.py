"""
core/exchange.py — Thin async wrapper around ccxt.pro for Binance Futures.

Responsibilities:
- Initialise ccxt exchange object (testnet / mainnet)
- Place / cancel / fetch orders
- Fetch account balance and positions
- WebSocket price feed (mark price + order updates)
- Enforce rate-limiting via asyncio-throttle
"""

from __future__ import annotations

import asyncio
from typing import Any

import ccxt.pro as ccxtpro
from loguru import logger

from config import Config


class ExchangeClient:
    """Async Binance Futures client.

    All order operations are async and return the raw ccxt response dict.
    Callers are responsible for interpreting the response and persisting state
    via the StateManager.
    """

    def __init__(self, config: Config) -> None:
        self.config = config
        self._exchange: ccxtpro.Exchange | None = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def connect(self) -> None:
        """Initialise ccxt exchange, set leverage, load markets."""
        exc_config = self.config.exchange
        sym_config = self.config.symbol

        options: dict[str, Any] = {
            "apiKey": exc_config.api_key,
            "secret": exc_config.api_secret,
            "options": {"defaultType": "future"},
        }
        if exc_config.testnet:
            options["urls"] = {"api": "https://testnet.binancefuture.com"}

        self._exchange = ccxtpro.binanceusdm(options)
        await self._exchange.load_markets()

        await self._exchange.set_leverage(
            sym_config.leverage,
            sym_config.symbol,
        )
        logger.info(
            "Exchange connected | symbol={} leverage={}x testnet={}",
            sym_config.symbol,
            sym_config.leverage,
            exc_config.testnet,
        )

    async def close(self) -> None:
        """Close WebSocket connections and HTTP session."""
        if self._exchange:
            await self._exchange.close()
            logger.info("Exchange connection closed")

    # ------------------------------------------------------------------
    # Market Data
    # ------------------------------------------------------------------

    async def get_mark_price(self) -> float:
        """Return current mark price for the configured symbol.

        Returns
        -------
        float
            Mark price in quote currency (USDT).
        """
        raise NotImplementedError

    async def get_ohlcv(self, timeframe: str, limit: int = 100) -> list[list]:
        """Fetch OHLCV candles.

        Parameters
        ----------
        timeframe:
            ccxt timeframe string e.g. '1m', '3m', '15m'.
        limit:
            Number of candles to return.

        Returns
        -------
        list[list]
            List of [timestamp, open, high, low, close, volume].
        """
        raise NotImplementedError

    async def watch_mark_price(self) -> asyncio.Queue:
        """Return an asyncio.Queue that receives mark price ticks.

        The queue yields float values each time a new mark price arrives
        over the WebSocket feed.  Reconnection is handled internally.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Account
    # ------------------------------------------------------------------

    async def get_balance(self) -> dict[str, Any]:
        """Fetch account balance.

        Returns
        -------
        dict
            ccxt balance dict with 'total', 'free', 'used' keys for USDT.
        """
        raise NotImplementedError

    async def get_positions(self) -> list[dict[str, Any]]:
        """Fetch all open positions for the configured symbol.

        Returns
        -------
        list[dict]
            Each dict contains 'side', 'contracts', 'entryPrice',
            'unrealizedPnl', 'info' (raw exchange data).
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Order Management
    # ------------------------------------------------------------------

    async def place_limit_order(
        self,
        side: str,
        amount: float,
        price: float,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Place a limit order.

        Parameters
        ----------
        side:
            'buy' or 'sell'.
        amount:
            Contract quantity (already rounded to qty_precision).
        price:
            Limit price (already rounded to price_precision).
        params:
            Extra ccxt params e.g. {'positionSide': 'LONG'} for hedge mode.

        Returns
        -------
        dict
            ccxt order object with at minimum 'id', 'status', 'price',
            'amount'.
        """
        raise NotImplementedError

    async def place_market_order(
        self,
        side: str,
        amount: float,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Place a market order.

        Parameters
        ----------
        side:
            'buy' or 'sell'.
        amount:
            Contract quantity.
        params:
            Extra ccxt params.

        Returns
        -------
        dict
            ccxt order object.
        """
        raise NotImplementedError

    async def cancel_order(self, order_id: str) -> dict[str, Any]:
        """Cancel a single open order by ID.

        Returns
        -------
        dict
            ccxt cancel response.
        """
        raise NotImplementedError

    async def cancel_all_orders(self) -> list[dict[str, Any]]:
        """Cancel all open orders for the configured symbol.

        Returns
        -------
        list[dict]
            List of ccxt cancel responses.
        """
        raise NotImplementedError

    async def close_position(
        self,
        side: str,
        amount: float,
    ) -> dict[str, Any]:
        """Market-close a position.

        Parameters
        ----------
        side:
            Position side to close ('buy' → send sell market order).
        amount:
            Exact contract quantity to close.

        Returns
        -------
        dict
            ccxt order object.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def round_price(self, price: float) -> float:
        """Round price to exchange precision."""
        prec = self.config.symbol.price_precision
        return round(price, prec)

    def round_qty(self, qty: float) -> float:
        """Round quantity to exchange precision."""
        prec = self.config.symbol.qty_precision
        return round(qty, prec)
