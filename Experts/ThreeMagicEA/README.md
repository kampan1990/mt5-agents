# ThreeMagicEA — บอทเทรด 3 Magic 3 กลยุทธ์

Expert Advisor สำหรับ MetaTrader 5 ที่รัน **3 magic number แยกกลยุทธ์อิสระ** ในตัวเดียว
แต่ละ magic บริหารไม้และ P/L ของตัวเองแยกขาดจากกัน

| Magic | สภาพตลาดเป้าหมาย | กลยุทธ์ |
|-------|-----------------|---------|
| **1111** | ตลาดมีทิศจากสัญญาณ engulfing | Engulfing 3 แท่ง + Grid straddle + Flip/Recovery |
| **2222** | Sideway / ตลาดออกข้าง | Bollinger + RSI grid + Breakout Guard |
| **3333** | Trending / ตลาดมีเทรนด์ | EMA Pullback ladder + Runner + ATR trailing |

---

## โครงสร้างไฟล์

```
Experts/ThreeMagicEA/
├── ThreeMagicEA.mq5        ← EA หลัก + input parameters ทั้งหมด
├── Logger.mqh              ← ระบบ log (console + file)
├── Utils.mqh               ← helper: ราคา, point, lot, new-bar detector
├── RiskManager.mqh         ← lot sizing, basket P/L, account drawdown stop
├── TradeManager.mqh        ← ส่ง/ปิด order + pending พร้อม error handling
├── Strategy_Engulfing.mqh  ← Magic 1
├── Strategy_Sideway.mqh    ← Magic 2
└── Strategy_Trend.mqh      ← Magic 3
```

### วิธีติดตั้ง
1. ก็อปโฟลเดอร์ `ThreeMagicEA` ไปไว้ใน `MQL5/Experts/` ของ MetaTrader 5
2. เปิด MetaEditor → เปิด `ThreeMagicEA.mq5` → กด **Compile (F7)**
3. ลาก EA ลงกราฟสัญลักษณ์ที่ต้องการ (XAUUSD, EURUSD ฯลฯ) แล้วตั้งค่าพารามิเตอร์
4. เปิด **AutoTrading** — EA เทรดบนสัญลักษณ์ของกราฟที่รันอยู่

---

## Magic 1 (1111) — Engulfing + Grid + Flip/Recovery

**เข้า:** เช็ค engulfing 3 แท่งบน TF ที่ตั้ง — แท่งที่ 2 กลืนกินแท่งที่ 1
- แท่ง 2 แดงกลืนเขียว → เตรียม **Sell**
- แท่ง 2 เขียวกลืนแดง → เตรียม **Buy**
- รอราคาเด้งสวน `RetracePercent` % ของช่วงแท่ง 2 ก่อนยิงเข้า

**วางไม้:** pending straddle ฝั่งเทรด — Limit `OrdersPerSide` ไม้ + Stop `OrdersPerSide` ไม้

**ออก:** **Basket TP** (ปิดทั้งกลุ่มเมื่อกำไรรวมถึงเป้า) — ไม่มี SL รายไม้ ใช้ **Basket Stop** เท่านั้น

**Flip:** เจอ engulfing ตรงข้าม *และกลุ่มยังขาดทุนไม่เกิน* `FlipMaxLoss` → ปิดกลุ่มแล้วกลับข้าง

**Recovery:** ถ้ากลุ่มขาดทุนเกิน `RecoveryTrigger` → เติมไม้ทางเดิม (คูณ lot ด้วย `RecoveryLotMult`) แม้สัญญาณจะให้ฝั่งตรงข้าม จนถึง `RecoveryMaxAdds` ไม้

---

## Magic 2 (2222) — Sideway BB+RSI Grid

**ตัวกรอง sideway:** `ADX < ADXSidewayMax` **และ** BB width < `BBWidthMaxPct`

**เข้า:**
- ราคาแตะ BB บน + `RSI >= RSIOverbought` → grid **Sell limit** ไล่ขึ้น
- ราคาแตะ BB ล่าง + `RSI <= RSIOversold` → grid **Buy limit** ไล่ลง

**ออก:** Basket TP / Basket Stop

**Breakout Guard:** `ADX >= ADXBreakout` หรือราคาหลุดกรอบเกิน `BreakoutBufferPts` → **ปิด basket ทันที** แล้วพัก `CooldownBars` แท่ง จนกลับเข้าโหมด sideway

---

## Magic 3 (3333) — Trend EMA Pullback

**เข้า:** `EMAFast > EMASlow` + `ADX >= ADXTrendMin` แล้วราคาย่อมาแตะ EMA เร็วและปิดกลับตามเทรนด์
- วาง ladder ฝั่งเทรนด์: **Limit `OrdersPerSide` ไม้ใต้ราคา** (เก็บราคาดี = runner) + **Stop `OrdersPerSide` ไม้เหนือราคา** (pyramiding ตามโมเมนตัม)
- ทุกไม้มี **SL รายไม้ = ATR × `SLAtrMult`** และ TP = `RunnerTP` points

**Partial TP + Runner:** เมื่อกำไรรวมถึง `PartialTrigPts` → ปิดไม้ทั้งหมด **ยกเว้นไม้ราคาดีที่สุด `KeepRunnerCount` ไม้** ที่เก็บไว้รันยาว

**Runner exit:** TP แยกของ runner (`RunnerTP`) + **ATR Trailing Stop** (`TrailAtrMult`)

**Pyramiding cap:** ไม้เปิดพร้อมกันไม่เกิน `MaxPositions`

---

## Risk / Global

- `MaxAccountDDPct` — เมื่อ account drawdown ถึงเพดาน → หยุดเทรดทุก magic (และปิดทุกไม้ถ้า `CloseAllOnHalt=true`)
- Position sizing: ตั้ง lot ต่อไม้ได้ต่อ magic; `RiskManager` มีฟังก์ชันคำนวณ lot จาก % balance ให้ต่อยอดได้
- Logging: ทุก trade event ผ่าน `GetLastError()` / retcode — เปิด log ไฟล์ได้ด้วย `LogToFile`

---

## ⚠️ ข้อควรระวัง

- Magic 1 มีระบบ **recovery/martingale** (คูณ lot) — ควร backtest และตั้ง `BasketSL` / `MaxAccountDDPct` ให้รัดกุมก่อนใช้เงินจริง
- ค่า default (`GridStep`, `RunnerTP` เป็น points, `Basket TP/SL` เป็นเงินบัญชี) ตั้งไว้แบบกลางๆ — **ต้องปรับตามสัญลักษณ์และ volatility จริง** (เช่น XAUUSD ต่างจาก EURUSD มาก)
- ยังไม่ได้ผ่านการ compile บน MetaEditor ในสภาพแวดล้อมนี้ — กรุณา compile และ backtest ใน Strategy Tester ก่อนใช้งาน
