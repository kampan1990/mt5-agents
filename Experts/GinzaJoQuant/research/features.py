"""Layer 2: Feature Engineering — ต้องให้ผลตรงกับ Features.mqh"""
import numpy as np
import pandas as pd
import config as C

POINT = 0.01  # XAUUSD: 1 point = 0.01 (โบรกเกอร์ 2 หลัก) — ปรับได้ถ้าโบรกเกอร์ 3 หลัก


def _atr(df: pd.DataFrame, n: int) -> pd.Series:
    pc = df["close"].shift(1)
    tr = pd.concat([df["high"] - df["low"], (df["high"] - pc).abs(), (df["low"] - pc).abs()], axis=1).max(axis=1)
    # MT5 iATR = SMA ของ TR ; แท่งแรกใช้ high-low
    tr.iloc[0] = df["high"].iloc[0] - df["low"].iloc[0]
    return tr.rolling(n).mean()


def _consec(green: np.ndarray, red: np.ndarray, cap: int) -> np.ndarray:
    out = np.zeros(len(green))
    run = 0
    for i in range(len(green)):
        if green[i]:
            run = run + 1 if run > 0 else 1
        elif red[i]:
            run = run - 1 if run < 0 else -1
        else:
            run = 0
        out[i] = max(-cap, min(cap, run))
    return out


def build_features(df: pd.DataFrame, point: float = POINT) -> pd.DataFrame:
    o, h, l, c = df["open"], df["high"], df["low"], df["close"]
    atr = _atr(df, C.ATR_FAST)
    atr_slow = _atr(df, C.ATR_SLOW)
    ema_f = c.ewm(span=C.EMA_FAST, adjust=False).mean()
    ema_s = c.ewm(span=C.EMA_SLOW, adjust=False).mean()
    rng = (h - l).replace(0, np.nan)

    f = pd.DataFrame(index=df.index)
    f["ema_fast_dist"] = (c - ema_f) / atr
    f["ema_slow_dist"] = (c - ema_s) / atr
    f["ema_slope"] = (ema_f - ema_f.shift(C.SLOPE_N)) / atr
    f["body_ratio"] = ((c - o) / rng).fillna(0)
    f["upper_wick"] = ((h - np.maximum(o, c)) / rng).fillna(0)
    f["lower_wick"] = ((np.minimum(o, c) - l) / rng).fillna(0)
    f["consec"] = _consec((c > o).to_numpy(), (c < o).to_numpy(), C.CONSEC_MAX)
    hh = h.rolling(C.RANGE_N).max()
    ll = l.rolling(C.RANGE_N).min()
    f["range_pos"] = ((c - ll) / (hh - ll).replace(0, np.nan)).fillna(0.5)
    f["pullback_depth"] = (hh - c) / atr
    f["vol_regime"] = atr / atr_slow
    f["momentum"] = (c - c.shift(C.MOM_N)) / atr
    hour = df["time"].dt.hour + df["time"].dt.minute / 60.0
    f["hour_sin"] = np.sin(2 * np.pi * hour / 24)
    f["hour_cos"] = np.cos(2 * np.pi * hour / 24)
    f["spread_atr"] = df["spread"] * point / atr
    f["atr"] = atr  # ไม่ใช่ feature ของโมเดล — ใช้คำนวณ label/รายงาน
    f.iloc[: C.WARMUP] = np.nan  # ให้ EMA ลู่เข้าเหมือนฝั่ง EA
    return f
