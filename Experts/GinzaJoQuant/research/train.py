"""Layer 4-5: เทรน LightGBM ตัวเดียว แบบ walk-forward (purge + embargo) แล้ว export ONNX

ใช้:  python train.py --csv XAUUSD_M5.csv --out ../model
      python train.py --synthetic --out /tmp/m     (smoke test เท่านั้น)

ผลลัพธ์: ginza_model.onnx + model_meta.json (threshold ที่เลือกจาก out-of-sample)
"""
import argparse, json, os
import numpy as np
import pandas as pd
import lightgbm as lgb
import config as C
from data import load_rates, synthetic_rates
from features import build_features, POINT
from labels import triple_barrier

PARAMS = dict(objective="multiclass", num_class=3, learning_rate=0.03, num_leaves=15,
              min_child_samples=200, subsample=0.7, subsample_freq=1, colsample_bytree=0.7,
              reg_lambda=5.0, n_estimators=300, verbose=-1)


def expectancy_R(p, y_buy, y_sell, thr, margin):
    """กำไรเฉลี่ยต่อไม้ หน่วย R (SL=1R, TP=TP/SL R) จาก label ที่หัก spread แล้ว"""
    rr = C.TP_ATR / C.SL_ATR
    pb, ps = p[:, 1], p[:, 2]
    buy = (pb >= thr) & (pb - ps >= margin)
    sell = (ps >= thr) & (ps - pb >= margin)
    n = buy.sum() + sell.sum()
    if n == 0:
        return 0.0, 0
    wins = y_buy[buy].sum() + y_sell[sell].sum()
    return (wins * rr - (n - wins) * 1.0) / n, int(n)  # ไม้ที่ไม่ชนะนับเป็น -1R (เผื่อร้าย)


def walk_forward(X, y, ybuy, ysell, n_splits=5):
    n = len(X)
    fold = n // (n_splits + 1)
    oof = np.full((n, 3), np.nan)
    for k in range(1, n_splits + 1):
        tr_end = fold * k - C.HORIZON          # purge: ตัดแท่งที่ label ซ้อนกับช่วงทดสอบ
        te_start, te_end = fold * k, min(fold * (k + 1), n)
        tr = np.arange(0, tr_end)
        tr = tr[y[tr] >= 0]
        m = lgb.LGBMClassifier(**PARAMS).fit(X[tr], y[tr])
        oof[te_start:te_end] = m.predict_proba(X[te_start:te_end])
        print(f"  fold {k}: train={len(tr)} test={te_end - te_start}")
    return oof


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv"); ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--out", default="../model"); ap.add_argument("--point", type=float, default=POINT)
    a = ap.parse_args()
    df = synthetic_rates() if a.synthetic else load_rates(a.csv)
    f = build_features(df, a.point)
    lab = triple_barrier(df, f["atr"], a.point)
    ok = (lab["y"] >= 0) & f[C.FEATURES].notna().all(axis=1)
    X = f.loc[ok, C.FEATURES].to_numpy(np.float32)
    y = lab.loc[ok, "y"].to_numpy()
    yb = lab.loc[ok, "buy_ok"].to_numpy(); ys = lab.loc[ok, "sell_ok"].to_numpy()
    print(f"rows={len(X)}  class balance={np.bincount(y, minlength=3) / len(y)}")

    print("walk-forward:")
    oof = walk_forward(X, y, yb, ys)
    m = ~np.isnan(oof[:, 0])
    # เลือก threshold จาก OOS (เลือกเฉพาะครึ่งแรกของ OOS, รายงานครึ่งหลังที่ไม่ได้ใช้เลือก)
    idx = np.where(m)[0]; half = len(idx) // 2
    sel, hold = idx[:half], idx[half:]
    best = (-9, 0.5, 0.1)
    for thr in np.arange(0.40, 0.70, 0.025):
        for mar in (0.0, 0.1, 0.2):
            e, n = expectancy_R(oof[sel], yb[sel], ys[sel], thr, mar)
            if n >= 100 and e > best[0]:
                best = (e, thr, mar)
    e_sel, thr, mar = best
    if e_sel == -9:
        print("!! ไม่มี threshold ไหนให้ >=100 เทรดใน OOS — โมเดลไม่มั่นใจพอ ไม่ควรใช้")
        e_sel, thr, mar = float("nan"), 0.99, 0.0   # 0.99 = EA จะไม่เปิดออเดอร์
    e_hold, n_hold = expectancy_R(oof[hold], yb[hold], ys[hold], thr, mar)
    print(f"threshold={thr:.3f} margin={mar}  expectancy(select half)={e_sel:+.3f}R  "
          f"(HOLD-OUT half)={e_hold:+.3f}R over {n_hold} trades")
    if e_hold <= 0:
        print("!! hold-out expectancy <= 0 : ยังไม่มี edge หลังหัก spread — อย่านำไปใช้จริง")

    final = lgb.LGBMClassifier(**PARAMS).fit(X, y)
    os.makedirs(a.out, exist_ok=True)
    from onnxmltools import convert_lightgbm
    from onnxmltools.convert.common.data_types import FloatTensorType
    onx = convert_lightgbm(final, initial_types=[("input", FloatTensorType([None, len(C.FEATURES)]))],
                           zipmap=False, target_opset=13)
    with open(os.path.join(a.out, "ginza_model.onnx"), "wb") as fh:
        fh.write(onx.SerializeToString())
    meta = dict(feature_version=C.FEATURE_VERSION, features=C.FEATURES, threshold=round(float(thr), 3),
                margin=mar, tp_atr=C.TP_ATR, sl_atr=C.SL_ATR, horizon=C.HORIZON,
                oos_expectancy_selected=round(float(e_sel), 4), oos_expectancy_holdout=round(float(e_hold), 4),
                holdout_trades=n_hold, synthetic=bool(a.synthetic))
    json.dump(meta, open(os.path.join(a.out, "model_meta.json"), "w"), indent=2)
    print("saved:", a.out, meta)


if __name__ == "__main__":
    main()
