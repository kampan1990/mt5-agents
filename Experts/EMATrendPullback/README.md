# EMATrendPullback EA

EA สำหรับ MetaTrader 5 ที่แปลง logic จาก indicator `EMA_Trend_Pullback_Dashboard` (อยู่ที่ `Indicators/EMATrendPullback/`) มาเปิด order จริง พร้อมระบบ risk management ตามกฎของโปรเจกต์

> ⚠️ ยังไม่ได้ compile และยังไม่ได้ backtest ต้อง compile ใน MetaEditor และทดสอบบน Strategy Tester / บัญชี demo ก่อนใช้กับเงินจริงทุกครั้ง

## ไฟล์

| ไฟล์ | หน้าที่ |
|------|---------|
| `EMATrendPullback.mq5` | EA หลัก: OnTick, entry pipeline, ส่ง order, exit management, ข้อมูลบนกราฟ |
| `Strategy.mqh` | สัญญาณ EMA 20/50/200 + Pullback/Cross + filters (HTF, slope, ADX, sideways) |
| `RiskManager.mqh` | สร้าง SL/TP, คำนวณ lot จาก % balance, Max DD halt, Daily loss limit |
| `Logger.mqh` | Log ลง Experts journal และไฟล์ `MQL5/Files/EMATrendPullback_<symbol>_<magic>.log` |
| `Utils.mqh` | New bar, นับ position, ปัดราคา, ตรวจสิทธิ์การเทรด, session |

## การติดตั้ง

1. คัดลอกโฟลเดอร์ `Experts/EMATrendPullback/` ไปไว้ที่ `<Data Folder>/MQL5/Experts/`
2. (ถ้าต้องการดูลูกศรเทียบ) คัดลอก `Indicators/EMATrendPullback/` ไปไว้ที่ `MQL5/Indicators/`
3. เปิด `EMATrendPullback.mq5` ใน MetaEditor แล้วกด Compile (F7)
4. ลาก EA ลงกราฟ และเปิดปุ่ม Algo Trading

## Logic

**Entry** (ตรวจเฉพาะตอนแท่งปิด ไม่ repaint)
- Bias: Close และ EMA50 อยู่ฝั่งเดียวกันเมื่อเทียบกับ EMA200
- **PB**: ราคาแตะ EMA20 ภายใน N แท่ง, ยังยืนเหนือหรือใต้ EMA50 ได้, แท่งปิดกลับข้าม EMA20 (Reclaim) หรือทะลุ High/Low ของแท่งก่อน (Break prev) และห่าง EMA20 ไม่เกิน X×ATR
- **CROSS**: EMA20 ตัด EMA50 แล้วแท่งถัดไปยืนยัน โดยมีระยะห่าง ≥ X×ATR
- ต้องผ่าน filter: HTF EMA50/200, EMA50 slope, ADX, จำนวนครั้งที่ราคาตัด EMA50, session, spread, ATR range

**Risk (บังคับ)**
- ทุก order มี SL และ TP เสมอ ถ้าคำนวณไม่ได้ EA จะไม่ส่ง order
- SL เลือกได้ 3 แบบ: `ATR`, `Swing + buffer`, `Wider` (เลือกตัวที่ไกลกว่า) และ TP = RR × ระยะ SL จริง
- Lot คิดจาก `Risk %` ของ balance ผ่าน `OrderCalcProfit` ถ้า lot ที่คำนวณได้ต่ำกว่า min lot จะ **ข้าม** order นั้น (ไม่ปัดขึ้นจนเสี่ยงเกินที่ตั้งไว้)
- **Max DD**: ถ้า equity ลดลงจาก peak เกิน % ที่ตั้ง EA จะหยุดถาวรและปิด position (ถ้าเปิด `Close all on halt`) สถานะ halt เก็บใน Global Variable ถ้าจะให้เทรดต่อต้องตั้ง `Reset DD state on start = true`
- **Daily loss**: ถ้าขาดทุนจาก balance ต้นวันเกิน % ที่ตั้ง จะหยุดเปิด order ใหม่จนถึงวันถัดไป
- ตรวจ retcode และ `GetLastError()` ทุกครั้งที่ส่ง order / ปิด / แก้ไข และ retry เมื่อเจอ requote หรือราคาเปลี่ยน

**Exit**
- `SL/TP only` (ค่าเริ่มต้น) หรือ `EMA close` (ปิดเมื่อแท่งปิดเลย EMA20/50 สวนทาง)
- Break-even เมื่อกำไรถึง X×R (R = |TP − open| / RR)
- Trailing ตาม EMA20 ± buffer (ทำตอนแท่งปิด)
- ปิด position ฝั่งตรงข้ามเมื่อมีสัญญาณกลับทิศ (ตั้งค่าได้)

## ค่าที่แนะนำสำหรับเริ่ม backtest

| Symbol | TF | HTF | หมายเหตุ |
|--------|----|-----|---------|
| XAUUSD | M15 / H1 | H4 | ตั้ง `Max spread` ประมาณ 30–50 pts |
| EURUSD / GBPUSD | H1 | H4 / D1 | เปิด Session filter ช่วง London–NY |
| NAS100 / US30 | M15 / H1 | H4 | ตั้ง `Max SL pts` กันช่วงข่าว |

ใช้ Strategy Tester โหมด "Every tick based on real ticks" ทดสอบอย่างน้อย 2–3 ปี และแยกช่วง in-sample / out-of-sample

## ข้อจำกัดที่รู้อยู่แล้ว

- Max DD คิดจาก equity ของ **ทั้งบัญชี** ถ้ารันหลาย EA ในบัญชีเดียวกัน DD ของ EA อื่นจะถูกนับรวมด้วย
- ถ้าแก้ค่า `RR` ระหว่างที่มี position เปิดอยู่ การคำนวณ R สำหรับ break-even ของ position นั้นจะเพี้ยน
- สัญญาณ CROSS ไม่ใช้ distance filter โดย default เพื่อให้ตรงกับ indicator ต้นฉบับ (เปิดได้ที่ `InpCrossNeedDist`)
- Session / spread / ATR filter ใน EA ใช้ค่า ณ ตอนจะเข้า order จริง ไม่ได้ใช้ค่าของแท่งที่ปิดไปแล้วแบบ indicator จึงอาจมีลูกศรบางจุดที่ EA ไม่เข้า order
