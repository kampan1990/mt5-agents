"""Layer 3: ทดสอบสมมติฐาน pattern แต่ละแบบ ว่ามี edge หลังหัก spread ไหม (ก่อนเอาไปป้อนโมเดล)

ใช้: python research_patterns.py --csv XAUUSD_M5.csv
แต่ละ pattern ให้ทิศทาง (+1 BUY / -1 SELL / 0 ไม่เข้า) แล้ววัด expectancy (R) แยกตาม session
เกณฑ์อ่านผล: ดูว่า expectancy > 0 ทั้งช่วงต้น และช่วงหลัง (ข้อมูลแบ่งครึ่ง) ไม่ใช่แค่ครึ่งเดียว
"""
import argparse
import numpy as np
import pandas as pd
import config as C
from data import load_rates, synthetic_rates
from features import build_features, POINT
from labels import triple_barrier

PATTERNS = {
    "trend_following": lambda f: np.where((f.ema_fast_dist > 0) & (f.ema_slow_dist > 0) & (f.ema_slope > 0.3), 1,
                                   np.where((f.ema_fast_dist < 0) & (f.ema_slow_dist < 0) & (f.ema_slope < -0.3), -1, 0)),
    "pullback": lambda f: np.where((f.ema_slow_dist > 0.5) & (f.ema_fast_dist < 0.2) & (f.consec <= -2), 1,
                            np.where((f.ema_slow_dist < -0.5) & (f.ema_fast_dist > -0.2) & (f.consec >= 2), -1, 0)),
    "mean_reversion": lambda f: np.where((f.range_pos < 0.05) & (f.vol_regime < 1.0), 1,
                                  np.where((f.range_pos > 0.95) & (f.vol_regime < 1.0), -1, 0)),
    "breakout": lambda f: np.where((f.range_pos > 0.98) & (f.body_ratio > 0.6), 1,
                            np.where((f.range_pos < 0.02) & (f.body_ratio < -0.6), -1, 0)),
    "vol_expansion": lambda f: np.where((f.vol_regime > 1.3) & (f.momentum > 1.0), 1,
                                 np.where((f.vol_regime > 1.3) & (f.momentum < -1.0), -1, 0)),
}
SESSIONS = {"asia(0-7)": (0, 7), "london(7-13)": (7, 13), "newyork(13-21)": (13, 21)}  # เวลาเซิร์ฟเวอร์ ปรับตามโบรกเกอร์


def report(name, d, rr):
    n = len(d)
    if n < 100:
        return f"{name:<28} n={n:<6} (น้อยเกินไป)"
    win = d["win"].mean()
    return f"{name:<28} n={n:<6} win={win:5.1%}  expectancy={win * rr - (1 - win):+.3f}R"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv"); ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--point", type=float, default=POINT)
    a = ap.parse_args()
    df = synthetic_rates() if a.synthetic else load_rates(a.csv)
    f = build_features(df, a.point)
    lab = triple_barrier(df, f["atr"], a.point)
    ok = (lab["y"] >= 0) & f[C.FEATURES].notna().all(axis=1)
    f, lab, hour = f[ok], lab[ok], df.loc[ok, "time"].dt.hour
    rr = C.TP_ATR / C.SL_ATR
    half = len(f) // 2
    for name, fn in PATTERNS.items():
        sig = fn(f)
        win = np.where(sig == 1, lab["buy_ok"], np.where(sig == -1, lab["sell_ok"], False))
        d = pd.DataFrame({"sig": sig, "win": win, "hour": hour.values, "half": np.arange(len(f)) >= half})
        d = d[d.sig != 0]
        print(f"\n== {name}")
        print("  ทั้งหมด :", report("all", d, rr))
        print("  ครึ่งแรก:", report("first half", d[~d.half], rr))
        print("  ครึ่งหลัง:", report("second half", d[d.half], rr))
        for s, (h0, h1) in SESSIONS.items():
            print("  ", report(s, d[(d.hour >= h0) & (d.hour < h1)], rr))
    print(f"\nbreak-even win rate ที่ TP/SL={rr:.2f}R คือ {1 / (1 + rr):.1%}")


if __name__ == "__main__":
    main()
