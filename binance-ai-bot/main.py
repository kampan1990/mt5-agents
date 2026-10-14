"""CLI entry point.

  python main.py fetch    --symbols BTCUSDT --days 180
  python main.py backtest --engine rules
  python main.py backtest --engine claude --days 30 --decision-every 4 --max-calls 200
  python main.py run                      # testnet / dry-run per .env
  python main.py run --confirm-live       # required when BINANCE_ENV=live
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

import pandas as pd

from bot.backtest import Backtester
from bot.binance_client import BinanceFutures, fetch_history
from bot.config import load_config
from bot.engines import ClaudeEngine, RuleEngine
from bot.journal import Journal, setup_logging
from bot.market_data import klines_to_df
from bot.trader import Trader

log = logging.getLogger("main")
DATA_DIR = Path("data")


def history_path(symbol: str, interval: str, days: int) -> Path:
    return DATA_DIR / f"{symbol}_{interval}_{days}d.csv"


def load_history(symbol: str, interval: str, days: int, refresh: bool = False) -> pd.DataFrame:
    path = history_path(symbol, interval, days)
    if path.exists() and not refresh:
        return pd.read_csv(path, index_col=0, parse_dates=True)
    rows = fetch_history(symbol, interval, days)
    df = klines_to_df(rows)[["open", "high", "low", "close", "volume"]]
    DATA_DIR.mkdir(exist_ok=True)
    df.to_csv(path)
    log.info("saved %d candles -> %s", len(df), path)
    return df


def make_engine(name: str, cfg, max_calls=None):
    if name == "rules":
        return RuleEngine()
    if name == "claude":
        return ClaudeEngine(cfg.llm, max_calls=max_calls)
    raise SystemExit(f"unknown engine {name}")


def cmd_fetch(args, cfg) -> None:
    for sym in args.symbols or cfg.symbols:
        load_history(sym, args.interval or cfg.interval, args.days, refresh=True)


def cmd_backtest(args, cfg) -> None:
    interval = args.interval or cfg.interval
    engine = make_engine(args.engine, cfg, max_calls=args.max_calls)
    results = []
    for sym in args.symbols or cfg.symbols:
        df = pd.read_csv(args.csv, index_col=0, parse_dates=True) if args.csv else load_history(sym, interval, args.days)
        bt = Backtester(engine, cfg.risk, interval=interval, initial_equity=args.equity,
                        decision_every=args.decision_every, anonymize=cfg.llm.anonymize)
        res = bt.run(df, sym)
        m = res.metrics(interval)
        m["rejections"] = res.rejections
        results.append(m)
        print(json.dumps(m, ensure_ascii=False))
        out = Path(cfg.log_dir) / f"backtest_{sym}_{engine.name}.csv"
        pd.DataFrame([t.__dict__ for t in res.trades]).to_csv(out, index=False)
    if isinstance(engine, ClaudeEngine):
        print(json.dumps({"llm_calls": engine.calls, "llm_cache_hits": engine.cache_hits, "usage": engine.usage}))


def cmd_run(args, cfg) -> None:
    if cfg.binance.env == "live" and not args.confirm_live:
        raise SystemExit("BINANCE_ENV=live trades real money. Re-run with --confirm-live if you really mean it.")
    if args.dry_run:
        cfg.dry_run = True
    engine = make_engine(args.engine, cfg)
    trader = Trader(cfg, engine, BinanceFutures(cfg.binance), Journal(cfg.log_dir))
    if args.once:
        trader.prepare()
        trader.run_cycle()
    else:
        trader.run_forever()


def main(argv=None) -> None:
    cfg = load_config()
    p = argparse.ArgumentParser(description="Claude-powered Binance USDT-M futures bot")
    sub = p.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("fetch", help="download historical candles")
    f.add_argument("--symbols", nargs="*")
    f.add_argument("--interval")
    f.add_argument("--days", type=int, default=180)

    b = sub.add_parser("backtest", help="backtest an engine on historical candles")
    b.add_argument("--engine", choices=["rules", "claude"], default="rules")
    b.add_argument("--symbols", nargs="*")
    b.add_argument("--interval")
    b.add_argument("--days", type=int, default=180)
    b.add_argument("--csv", help="use this OHLCV CSV instead of downloading")
    b.add_argument("--equity", type=float, default=10_000)
    b.add_argument("--decision-every", type=int, default=1, help="ask the engine every N bars")
    b.add_argument("--max-calls", type=int, default=None, help="cap on paid LLM calls (cache hits are free)")

    r = sub.add_parser("run", help="trade on testnet/live")
    r.add_argument("--engine", choices=["rules", "claude"], default="claude")
    r.add_argument("--dry-run", action="store_true", help="never send orders")
    r.add_argument("--once", action="store_true", help="run a single cycle and exit")
    r.add_argument("--confirm-live", action="store_true")

    args = p.parse_args(argv)
    setup_logging(cfg.log_dir)
    {"fetch": cmd_fetch, "backtest": cmd_backtest, "run": cmd_run}[args.cmd](args, cfg)


if __name__ == "__main__":
    sys.exit(main())
