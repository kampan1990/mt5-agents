"""ค่าคงที่ที่ต้องตรงกับ Features.mqh / Signal.mqh (เปลี่ยนที่นี่ = ต้องแก้ฝั่ง MQL5 ด้วย)"""

FEATURE_VERSION = 1

# ลำดับ feature ต้องตรงกับ CFeatures::Compute() ใน Features.mqh เป๊ะ
FEATURES = [
    "ema_fast_dist",   # (close - EMA20) / ATR
    "ema_slow_dist",   # (close - EMA50) / ATR
    "ema_slope",       # (EMA20 - EMA20[5]) / ATR
    "body_ratio",      # (close - open) / (high - low)
    "upper_wick",      # (high - max(o,c)) / (high - low)
    "lower_wick",      # (min(o,c) - low) / (high - low)
    "consec",          # แท่งเขียวติดกัน(+) / แดงติดกัน(-) สูงสุด 6
    "range_pos",       # ตำแหน่งในกรอบ 20 แท่ง 0..1
    "pullback_depth",  # (HH20 - close) / ATR
    "vol_regime",      # ATR14 / ATR50
    "momentum",        # (close - close[10]) / ATR
    "hour_sin",
    "hour_cos",
    "spread_atr",      # spread / ATR
]

# พารามิเตอร์ indicator (ต้องตรงกับ Features.mqh)
EMA_FAST = 20
EMA_SLOW = 50
ATR_FAST = 14
ATR_SLOW = 50
RANGE_N = 20
SLOPE_N = 5
MOM_N = 10
CONSEC_MAX = 6
WARMUP = 300  # จำนวนแท่งที่ EA ดึงมาคำนวณ (EMA ลู่เข้าแล้ว)

# Label: triple barrier (หน่วย = ATR14 ของแท่งตัดสินใจ)
TP_ATR = 1.5
SL_ATR = 1.0
HORIZON = 24  # แท่ง M5 (= 2 ชั่วโมง)

# classes: 0 = ไม่มีใครชนก่อน/กำกวม, 1 = BUY ชนะ, 2 = SELL ชนะ
