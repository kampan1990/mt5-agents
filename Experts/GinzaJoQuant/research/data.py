"""Layer 1: โหลดข้อมูลที่ export จาก ExportData.mq5 (หรือสร้างข้อมูลจำลองไว้ smoke-test ท่อเท่านั้น)"""
import numpy as np
import pandas as pd


def load_rates(path: str) -> pd.DataFrame:
    """CSV คอลัมน์: time,open,high,low,close,tick_volume,spread  (spread หน่วย point)"""
    df = pd.read_csv(path)
    df["time"] = pd.to_datetime(df["time"], format="mixed")
    df = df.sort_values("time").drop_duplicates("time").reset_index(drop=True)
    need = {"time", "open", "high", "low", "close", "spread"}
    miss = need - set(df.columns)
    if miss:
        raise ValueError(f"CSV ขาดคอลัมน์: {miss}")
    return df


def synthetic_rates(n: int = 60000, seed: int = 7) -> pd.DataFrame:
    """ข้อมูลสุ่ม (random walk + volatility clustering) — ใช้ทดสอบว่าโค้ดรันได้ ห้ามใช้ตัดสินกลยุทธ์"""
    rng = np.random.default_rng(seed)
    vol = 0.25 * np.exp(np.cumsum(rng.normal(0, 0.02, n)) * 0.2)
    ret = rng.normal(0, 1, n) * vol
    close = 2000 + np.cumsum(ret)
    open_ = np.r_[close[0], close[:-1]]
    wick = np.abs(rng.normal(0, 1, (2, n))) * vol * 0.5
    high = np.maximum(open_, close) + wick[0]
    low = np.minimum(open_, close) - wick[1]
    t = pd.date_range("2024-01-01", periods=n, freq="5min")
    return pd.DataFrame({"time": t, "open": open_, "high": high, "low": low, "close": close,
                         "tick_volume": 100, "spread": 25})
