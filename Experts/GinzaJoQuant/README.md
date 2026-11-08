# GinzaJoQuant — Multi-Layer AI Trading System (XAUUSD, M5)

โครงสร้าง 7 layer ตามที่ออกแบบ โดยตัดส่วน "ยำ" ออก: ใช้ **LightGBM ตัวเดียว** (ไม่โหวตหลายโมเดลที่ข้อมูลซ้ำกัน)
และเน้น walk-forward + หัก spread ตั้งแต่ตอนสร้าง label

| Layer | ทำอะไร | ไฟล์ |
|---|---|---|
| 1 Market Data | export แท่ง M5 + spread | `ExportData.mq5`, `research/data.py` |
| 2 Features | 14 features (EMA dist, wick/body, consec, range pos, vol regime, momentum, pullback, hour, spread/ATR) | `Features.mqh`, `research/features.py` |
| 3 Pattern Research | ทดสอบ trend/pullback/mean-rev/breakout/vol-expansion/session ว่ามี edge ไหม | `research/research_patterns.py` |
| 4 Statistical Model | LightGBM, walk-forward + purge, export ONNX | `research/train.py` |
| 5 Signal | prob ≥ threshold และนำทิศตรงข้ามอย่างน้อย margin | `Signal.mqh` |
| 6 Risk & Execution | lot จาก %risk, SL/TP ตาม ATR (บังคับทุกไม้), spread filter, max orders, max DD, daily loss, แพ้ติดกัน→พัก | `RiskManager.mqh`, `GinzaJoQuant.mq5` |
| 7 Continuous Research | journal CSV ทุกออเดอร์ → วิเคราะห์ตาม session/ความมั่นใจ/ตรวจโมเดลเสื่อม | `Journal.mqh`, `research/analyze_journal.py` |

## ขั้นตอนใช้งาน
1. **Export ข้อมูล**: ใส่ `ExportData.mq5` บนกราฟ XAUUSD → ได้ `MQL5\Files\XAUUSD_M5.csv` (ยิ่งนานยิ่งดี อย่างน้อย 2–3 ปี)
2. **วิจัย pattern**: `cd research && pip install -r requirements.txt && python research_patterns.py --csv XAUUSD_M5.csv`
3. **เทรน**: `python train.py --csv XAUUSD_M5.csv --out ../model`
   - ดูบรรทัด `HOLD-OUT half` — ถ้า expectancy ≤ 0 แปลว่ายังไม่มี edge หลังหัก spread **อย่าเอาไปเทรด**
   - `--point 0.001` ถ้าโบรกเกอร์ XAUUSD ใช้ 3 หลัก
4. **ติดตั้งโมเดล**: คัดลอก `model/ginza_model.onnx` ไป `MQL5\Files\` และตั้ง input ของ EA (`Threshold`, `Margin`, `TpAtr`, `SlAtr`) ให้ตรง `model_meta.json`
5. **คอมไพล์ + Strategy Tester** บนกราฟ M5 (ใช้ "Every tick based on real ticks")
   ทดสอบ **ช่วงเวลาที่ไม่ได้ใช้เทรน** เท่านั้น
6. **Demo ก่อน live** อย่างน้อยหลายสัปดาห์ แล้วใช้ `python analyze_journal.py GinzaJo_journal.csv` ทบทวน

`python research/check_parity.py` ยืนยันว่าสูตร feature ฝั่ง Python ตรงกับตรรกะใน EA (ผ่านแล้วบนข้อมูลจำลอง)

## สถานะ / ข้อจำกัด — อ่านก่อนใช้
- **ยังไม่ได้คอมไพล์ใน MetaEditor และยังไม่มีโมเดลที่เทรนจากข้อมูลจริง** (ไม่มีข้อมูล XAUUSD ในสภาพแวดล้อมนี้) ฝั่ง Python รันผ่านบนข้อมูลจำลอง; ฝั่ง MQL5 ต้องคอมไพล์/ทดสอบเอง — API ONNX (`OnnxCreate` path, shape ของ output) ควรเช็กตอนคอมไพล์ครั้งแรก
- ข้อมูลจำลองใช้ทดสอบว่าท่อทำงานเท่านั้น ผลบนข้อมูลจำลองไม่มีความหมาย
- เวอร์ชันแรกใช้ M5 เดียว (ยังไม่รวม M1/M15/H1/tick ตาม Layer 1 เต็ม) — เพิ่มได้เมื่อพิสูจน์ว่า feature เดิมมี edge จริงแล้ว
- ไม่มีโมเดลใดรับประกันกำไร; edge บน XAUUSD M5 บางมากเมื่อหัก spread/slippage
- ชั่วโมง session (`research_patterns.py`, `InpStartHour/EndHour`) เป็นเวลาเซิร์ฟเวอร์ — ปรับตามโบรกเกอร์
- ถือไม้ไม่เกิน `InpHorizonBars` แท่ง (ตรงกับ label) ; SL/TP บังคับทุกไม้ ; max DD → halt ถาวรจนกว่าตั้ง `InpResetHalt`
