"""ตรวจว่าสูตรใน Features.mqh (จำลองซ้ำที่นี่แบบเดียวกับที่ EA ทำ: หน้าต่าง 400 แท่ง, EMA เริ่มจากแท่งแรก)
ให้ค่าเท่ากับ features.py ที่ใช้เทรน.  ใช้: python check_parity.py [--csv file]
ตรวจฝั่ง MQL5 จริง: เทียบ log/journal ของ EA กับ build_features ที่แท่งเวลาเดียวกัน"""
import argparse, math
import numpy as np
import config as C
from data import load_rates, synthetic_rates
from features import build_features, POINT


def ea_features(w, point):
    """w = DataFrame 400 แท่ง เก่า->ใหม่ ; ทำซ้ำ CFeatures::Compute ทีละบรรทัด"""
    o, h, l, c = (w[k].to_numpy() for k in ("open", "high", "low", "close"))
    L = len(w) - 1
    kf, ks = 2 / (C.EMA_FAST + 1), 2 / (C.EMA_SLOW + 1)
    ef = es = c[0]; ef_prev = 0
    for i in range(1, L + 1):
        ef = kf * c[i] + (1 - kf) * ef; es = ks * c[i] + (1 - ks) * es
        if i == L - C.SLOPE_N: ef_prev = ef
    def tr(i):
        return h[0] - l[0] if i == 0 else max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1]))
    atr = np.mean([tr(i) for i in range(L - C.ATR_FAST + 1, L + 1)])
    atr_s = np.mean([tr(i) for i in range(L - C.ATR_SLOW + 1, L + 1)])
    rng = h[L] - l[L]
    body = (c[L] - o[L]) / rng if rng > 0 else 0
    up = (h[L] - max(o[L], c[L])) / rng if rng > 0 else 0
    lo = (min(o[L], c[L]) - l[L]) / rng if rng > 0 else 0
    consec = 0
    if c[L] != o[L]:
        green = c[L] > o[L]
        for i in range(L, -1, -1):
            if abs(consec) >= C.CONSEC_MAX: break
            if (c[i] > o[i]) == green and c[i] != o[i]: consec += 1 if green else -1
            else: break
    hh, ll = h[L - C.RANGE_N + 1:].max(), l[L - C.RANGE_N + 1:].min()
    rpos = (c[L] - ll) / (hh - ll) if hh > ll else 0.5
    t = w["time"].iloc[-1]; hr = t.hour + t.minute / 60
    return [(c[L] - ef) / atr, (c[L] - es) / atr, (ef - ef_prev) / atr, body, up, lo, consec, rpos,
            (hh - c[L]) / atr, atr / atr_s, (c[L] - c[L - C.MOM_N]) / atr,
            math.sin(2 * math.pi * hr / 24), math.cos(2 * math.pi * hr / 24),
            w["spread"].iloc[-1] * point / atr]


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--csv"); a = ap.parse_args()
    df = load_rates(a.csv) if a.csv else synthetic_rates(5000)
    f = build_features(df, POINT)
    worst = 0
    for end in range(1000, len(df), 397):
        w = df.iloc[end - 399:end + 1]
        mine = np.array(ea_features(w, POINT))
        ref = f.loc[end, C.FEATURES].to_numpy(float)
        d = np.abs(mine - ref).max(); worst = max(worst, d)
    print(f"max |EA-logic - features.py| = {worst:.2e}")
    assert worst < 1e-4, "feature ไม่ตรงกัน!"
    print("PARITY OK")


if __name__ == "__main__":
    main()
