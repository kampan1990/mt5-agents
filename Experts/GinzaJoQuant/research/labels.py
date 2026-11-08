"""Label: triple-barrier ที่หัก spread แล้ว  (0 = ไม่ชนะ/กำกวม, 1 = BUY ชนะ, 2 = SELL ชนะ)

ถือว่าเข้าที่ close ของแท่งตัดสินใจ (chart เป็น Bid)
  BUY : เข้า Ask = close+spread, TP เมื่อ high >= entry+TP, SL เมื่อ low <= entry-SL
  SELL: เข้า Bid = close,        TP เมื่อ low+spread <= entry-TP, SL เมื่อ high+spread >= entry+SL
ถ้าแท่งเดียวชนทั้ง TP และ SL ถือว่า SL ก่อน (เข้าข้างร้าย)
"""
import numpy as np
import pandas as pd
import config as C


def triple_barrier(df: pd.DataFrame, atr: pd.Series, point: float) -> pd.DataFrame:
    n = len(df)
    c = df["close"].to_numpy()
    h = df["high"].to_numpy()
    l = df["low"].to_numpy()
    sp = df["spread"].to_numpy() * point
    a = atr.to_numpy()
    tp, sl = C.TP_ATR * a, C.SL_ATR * a

    # BUY
    b_entry = c + sp
    b_tp, b_sl = b_entry + tp, b_entry - sl
    # SELL
    s_entry = c
    s_tp, s_sl = s_entry - tp, s_entry + sl

    INF = C.HORIZON + 1
    b_win = np.full(n, INF); b_loss = np.full(n, INF)
    s_win = np.full(n, INF); s_loss = np.full(n, INF)
    for k in range(1, C.HORIZON + 1):
        hk = np.full(n, np.nan); lk = np.full(n, np.nan)
        hk[: n - k] = h[k:]; lk[: n - k] = l[k:]
        ok = ~np.isnan(hk)
        b_win = np.where(ok & (hk >= b_tp) & (b_win == INF), k, b_win)
        b_loss = np.where(ok & (lk <= b_sl) & (b_loss == INF), k, b_loss)
        s_win = np.where(ok & (lk + sp <= s_tp) & (s_win == INF), k, s_win)
        s_loss = np.where(ok & (hk + sp >= s_sl) & (s_loss == INF), k, s_loss)

    buy_ok = (b_win < INF) & (b_win < b_loss)      # เสมอ = SL ก่อน
    sell_ok = (s_win < INF) & (s_win < s_loss)
    y = np.zeros(n, dtype=int)
    y[buy_ok & ~sell_ok] = 1
    y[sell_ok & ~buy_ok] = 2
    y[np.isnan(a)] = -1
    y[n - C.HORIZON:] = -1  # ท้ายข้อมูลยังไม่รู้ผล
    return pd.DataFrame({"y": y, "buy_ok": buy_ok, "sell_ok": sell_ok}, index=df.index)
