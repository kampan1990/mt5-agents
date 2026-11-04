# QTheory EA — Design (v0.1 draft)

บอทเทรดจากตัวเลขล้วน ๆ ไม่ใช้อินดิเคเตอร์/กราฟ อ้างอิงโน้ต "Q theory" (Raw base / Hidden base / Q Buy / Q Sell)
สัญลักษณ์เป้าหมายแรก: **XAUUSD** (1.00 = 1 ดอลลาร์ราคา)

> สถานะ: ออกแบบจากโน้ตลายมือ 2 หน้า ส่วนที่โน้ตไม่ได้บอก (exit, SL) เป็น **ค่า default ที่ผมเสนอ** ดูหัวข้อ 8

---

## 1. สรุปทฤษฎีจากโน้ต

### 1.1 Base (ระดับราคาจากเลขท้าย 2 หลัก)

| ตำแหน่งใน block 100 | Raw base | Hidden base | ความหมาย |
|---|---|---|---|
| Top | 00 | 80 | **over base** → ฝั่ง **Sell** |
| | 75 | 55 | |
| Middle | 50 | 30 | เส้นกลาง |
| | 25 | 05 | |
| Low | 00 | 80 | **under base** → ฝั่ง **Buy** |

- Hidden base = Raw base **ลบ 20** (00→80, 75→55, 50→30, 25→05)
- ทั้ง 2 ชุดเป็นตัวเลขจากราคาล้วน ไม่ต้องใช้กราฟ

### 1.2 Q ladder (ระยะห่างจากราคาตั้งต้น)

| ฝั่ง | Q (ระยะ $) | ทิศ |
|---|---|---|
| Q Sell | 5, 10, 15, 18, 21 | **+** (ขึ้นไปเปิด Sell) |
| Q Buy | 4, 10, 15, 18, 21 | **−** (ลงมาเปิด Buy) |

ตัวอย่างในโน้ต ราคา 4460:
- Sell: 4465 / 4470 / 4475 / 4478 / 4481
- Buy: 4456 / 4450 / 4445 / 4442 / 4439

### 1.3 หลักการเทรดในโน้ต

1. ดู **L และ H** ของ XAU (ตัวอย่าง L=4440, H=4495)
2. หา base จากราคาปัจจุบัน (4460 → อยู่เหนือ middle 4450 = over base)
3. Sell ต้อง **over base และเข้าใกล้ 50 (middle)**; Buy ต้อง under base
4. "Buy ต้อง base 25,00 / Sell ต้อง base 75,00" (ใช้เป็นระดับเป้า/ตัวกรอง ดูข้อ 8)

---

## 2. Algorithm (ตีความเป็นกฎที่โค้ดได้)

```
ทุกแท่งใหม่ (หรือทุก N วินาที) — ใช้แค่ Bid/Ask และ High/Low ของวัน:

1. block   = floor(price/100)*100
2. RAW     : mid = block+50   → side_raw    = price>mid ? SELL : BUY
   HIDDEN  : mid = block+30 (ปรับ block ให้ครอบราคา, 80→80) → side_hidden
3. ถ้า side_raw == side_hidden และ |price - mid_raw| <= MidTolerance
      และ price อยู่ในช่วง [DayLow, DayHigh] → SIGNAL(side)
4. anchor P0 = ราคาตอนเกิด signal
5. วาง ladder: Sell Limit ที่ P0+{5,10,15,18,21} หรือ Buy Limit ที่ P0-{4,10,15,18,21}
6. จัดการ basket ร่วมกัน (TP/SL/หมดอายุ) จนปิด แล้ว COOLDOWN
```

State machine: `IDLE → ARMED (วาง pending) → ACTIVE (มีไม้ถูกเติม) → CLOSED → COOLDOWN → IDLE`
เปิดได้ครั้งละ 1 ladder ต่อ symbol/magic

---

## 3. โครงสร้างไฟล์ (ตาม CLAUDE.md)

```
Experts/QTheory/
├── QTheory.mq5       ← OnInit/OnTick/OnTradeTransaction, state machine
├── Strategy.mqh      ← BaseCalc (raw/hidden), ZoneClassifier, LadderBuilder
├── RiskManager.mqh   ← lot จาก %risk, basket SL/TP, max DD, daily limit
├── Logger.mqh        ← log ทุก event (signal, place, fill, close, error)
└── Utils.mqh         ← NormalizePrice, stops-level check, DayHighLow
```

`Logger.mqh`/`Utils.mqh` น่า reuse จาก `Experts/GridAI/` ได้ (ต้องอ่านโค้ดก่อนตอน implement)

### คลาสหลัก

- `CBaseGrid` — `Mid(price, set)`, `Side(price, set)`, `NearestBase(price, set)`
- `CQLadder` — `Build(side, P0) → levels[5]` ใช้ array offset เป็น input
- `CQSignal` — รวม raw+hidden+day range → `SIGNAL_NONE/BUY/SELL`
- `CBasketManager` — เฝ้าตะกร้า: avg price, basket TP/SL, expire, ลบ pending ที่เหลือ

---

## 4. Risk (กฎบังคับ)

| กฎ | การทำใน EA |
|---|---|
| SL/TP ทุก order | ตั้งตอนส่ง order ทุกไม้ (SL ร่วมทั้ง ladder, TP ราย level) |
| Position sizing | lot ต่อ level คำนวณให้ **ถ้าเต็ม 5 ไม้แล้วชน SL = RiskPercent ของ balance** |
| Max Drawdown | equity DD จาก peak ≥ `MaxDDPercent` → ปิดทั้งหมด + หยุดเทรด |
| Daily loss limit | ขาดทุนวันนี้ ≥ `DailyLossPercent` → หยุดถึงวันถัดไป |
| GetLastError | ตรวจทุก `OrderSend` + log retcode |
| Logging | ทุก signal / place / fill / modify / close |

สูตร lot ต่อ level (Sell, SL ร่วมที่ `SL`):
`risk$ = Balance × Risk% ;  lot = risk$ / Σ_i (SL − Entry_i) × TickValue/TickSize`
ปัดตาม `SYMBOL_VOLUME_STEP`, จำกัด min/max lot, เช็ค margin ก่อนวาง

⚠️ ladder 5 ชั้นเป็นการ **ถัวเฉลี่ยเข้าหาทิศที่ราคาวิ่งสวน** (ลักษณะเดียวกับ grid) ถ้าไม่มี SL ร่วมและ lot cap จะเสี่ยงสูง จึงบังคับ SL ร่วมเสมอ

---

## 5. Inputs

| กลุ่ม | Input | Default |
|---|---|---|
| Q | `InpSellOffsets` | `5,10,15,18,21` |
| | `InpBuyOffsets` | `4,10,15,18,21` |
| Base | `InpUseRaw` / `InpUseHidden` | true / true |
| | `InpHiddenShift` | 20 |
| | `InpMidTolerance` ($) | 12 |
| | `InpRequireBothSets` | true |
| Day range | `InpUseDayRange` | true |
| Exit | `InpTPMode` | 0 = กลับ P0, 1 = fixed $, 2 = base ถัดไป |
| | `InpSLBufferBeyondQ21` ($) | 10 |
| | `InpPendingExpireMin` | 240 |
| Risk | `InpRiskPercent` | 1.0 |
| | `InpMaxDDPercent` | 10 |
| | `InpDailyLossPercent` | 3 |
| | `InpMaxSpread` ($) | 0.5 |
| Misc | `InpMagic`, `InpSession`, `InpCooldownMin` | — |

---

## 6. Edge cases

- Broker digits ต่างกัน (2/3) → แปลง $ → price ด้วย `_Point` ไม่ hardcode
- Stops level / freeze level: ถ้า offset ใกล้เกิน `SYMBOL_TRADE_STOPS_LEVEL` ให้ข้ามระดับนั้นและ log
- ราคาข้ามหลาย level ในแท่งเดียว (gap) → พึ่ง pending order ไม่ใช่ market เพื่อไม่ slippage
- รีสตาร์ท EA กลางทาง → สแกน magic เดิมเพื่อกู้ state
- Spread กว้างช่วงข่าว/rollover → ไม่วาง ladder
- ราคาข้าม block (4499→4501) → คำนวณ block ใหม่ ยกเลิก ladder เก่าที่ยังเป็น pending

---

## 7. Test plan

1. Unit: `BaseCalc` / `Ladder` ด้วย vector จากโน้ต (4460 → ตรงตาราง 1.2)
2. Strategy Tester XAUUSD, **Every tick based on real ticks**, อย่างน้อย 2 ปี
3. เทียบ 4 โหมด: Raw อย่างเดียว / Hidden อย่างเดียว / ต้องตรงกัน / ไม่ใช้ day range
4. Sensitivity: `MidTolerance`, `SLBuffer`, `TPMode`
5. ตรวจ Max consecutive loss, Max DD, ตะกร้าเต็ม 5 ไม้กี่ %

---

## 8. จุดที่โน้ตยังไม่ชัด (ต้องยืนยัน)

1. **Exit**: โน้ตไม่มี TP/SL — default ที่เสนอคือ TP ราย level = กลับมาที่ P0, SL ร่วม = Q21 + $10
2. **ตัวเลขในโน้ตหน้า 2 คำนวณไม่ตรง**: `4460−18` โน้ตเขียน 4443 (ควร **4442**), `4460−21` เขียน 4429 (ควร **4439**) — ผมใช้ค่าคำนวณถูกต้อง
3. **Sell เริ่ม +5 แต่ Buy เริ่ม −4** — ตั้งใจหรือพิมพ์ผิด? (ทำเป็น input แยกกันไว้แล้ว)
4. **L/H ใช้ทำอะไร**: เสนอให้ใช้ H/L ของวัน (D1) เป็นตัวกรองว่าราคาอยู่ในกรอบ — หรือใช้เลือก block/base?
5. **"Buy ต้อง base 25,00 / Sell ต้อง base 75,00"**: เป็น **ตัวกรองบังคับ** (ladder ต้องชน base นั้น) หรือแค่ตัวอย่างเป้าหมาย?
6. ใช้ **Raw, Hidden หรือทั้งสองชุดต้องตรงกัน**? (ตัวอย่าง 4460: ทั้งคู่ชี้ Sell)
7. ปิดตะกร้าอย่างไรเมื่อราคาไม่ไปไหน: หมดเวลา / ปิดสิ้นวัน?

---

## 9. การตัดสินใจจากผู้ใช้ (รอบที่ 2)

- **TP:** ตามที่ผู้ใช้/โน้ตกำหนด → ใช้ `InpTPMode=0` (TP แต่ละไม้ = กลับมาที่ P0) เป็นค่าเริ่มต้น และเปิดให้ปรับ mode ได้ ข้อ 1–6 ใช้ default ตามเอกสารนี้จนกว่าจะแก้
- **Runner:** ทุกรอบ TP ต้อง **เก็บไม้รันไว้ 1 ไม้** ทั้งฝั่ง Buy และ Sell พร้อม **ตั้ง SL กันหน้าทุน (breakeven)**

### กฎ Runner
1. ไม้ Runner = ไม้ที่ถูกเติมก่อนสุดในรอบนั้น (ใกล้ P0 ที่สุด) — ไม่ปิดที่ TP ปกติ แต่ย้าย TP ไปเป้าไกล (`InpRunnerTPDist` $ หรือ base ถัดไปในทิศกำไร)
   เพื่อให้ยังมี TP ครบตามกฎ CLAUDE.md (ห้ามไม่มี TP)
2. เมื่อไม้อื่นในรอบเดียวกันชน TP (หรือกำไร Runner ≥ `InpBEActivation` $) → เลื่อน SL ของ Runner ไป entry ± `InpBELockBuffer` (ค่าธรรมเนียม/สเปรด)
3. จำกัด **Runner 1 ไม้ต่อฝั่ง** ถ้าฝั่งนั้นมี Runner อยู่แล้ว รอบใหม่ปิดทุกไม้ที่ TP ตามปกติ
4. Runner ไม่บล็อกรอบใหม่ แต่ถูกนับรวมใน max DD / daily loss / margin check
5. ถ้ารอบนั้นถูกเติมแค่ไม้เดียว ไม้นั้นเป็น Runner ทันที (ไม่ปิดที่ TP แรก)
6. Runner ปิดเมื่อชน TP ไกล, SL หน้าทุน, หรือ DD guard

Inputs ใหม่: `InpKeepRunner`(true), `InpRunnerTPDist`(30), `InpBEActivation`(8), `InpBELockBuffer`(0.3)

---

## 10. การตัดสินใจรอบที่ 3 (implement แล้ว)

### 10.1 ระยะ tolerance สมมาตร BUY/SELL
- วัดระยะจาก **mid ของชุดที่ตัดสินทิศ** ไม่ใช่ Raw mid อย่างเดียว
- โหมด Raw+Hidden ต้องตรงกัน: ทิศตรงกันเฉพาะ SELL = block+50..+80 และ BUY = block+0..+30 (ช่วง +30..+50 Raw/Hidden ขัดกัน -> ไม่เทรด) ระยะที่ใช้ = **mid ที่ใกล้ราคากว่า** (SELL วัดจาก Raw block+50, BUY วัดจาก Hidden block+30)
- default `InpMidTolerance=12`: SELL เปิดที่ block+50..+62, BUY เปิดที่ block+18..+30 (สมมาตร) — เดิม BUY เกิดไม่ได้เลย
- โหมดไม่บังคับตรงกัน/ใช้ชุดเดียว: วัดจาก mid ของชุดที่ให้ทิศนั้นเอง
- tolerance > 30 (= block/2 - shift) ไม่ขยายโซนเพิ่ม เพราะถูกจำกัดด้วยเงื่อนไข Raw/Hidden ตรงกัน (OnInit เตือน)
- Self-test: 4460 -> SELL, **4420 -> BUY**, 4440 -> NONE (ขัดกัน)

### 10.2 ตัวกรอง H/L ของวัน (`InpDayEdgeBuffer` default 5 $)
- ราคาต้องอยู่ใน [DayLow, DayHigh]
- **SELL ห้ามเมื่อราคาห่างจาก Low วัน < 5 $; BUY ห้ามเมื่อห่างจาก High วัน < 5 $** (ตัดสินหลังรู้ทิศ ไม่ใช่บล็อกทั้งสองขอบเหมือนเดิม)
- default เดิม 0 ทำให้ตัวกรองไม่ทำงานจริง -> เปลี่ยนเป็น 5 และ OnInit เตือนถ้าตั้ง 0
- ผลข้างเคียง: ต้นวันที่ range ของวัน < 5 $ ทั้งสองทิศจะถูกบล็อกจนกว่า range จะขยาย
- Self-test ครอบคลุมทั้งบล็อกและผ่าน

### 10.3 `InpMaxHoldMin` default 1440 (24 ชม.)
- เมื่อรอบ (นับจากวาง ladder) ถือครบเวลา: ลบ pending, ปิด non-runner ทั้งหมดของรอบ, ปิด Runner ที่ **ยังไม่ BE** ด้วย
- **เก็บเฉพาะ Runner ที่ SL ย้ายไป breakeven แล้ว** (BUY: SL >= entry, SELL: SL <= entry)

### 10.4 TP ของ Runner = base ถัดไป (`InpRunnerUseNextBase=true`)
- BUY runner: TP ที่ base **..75** ถัดไปเหนือ entry | SELL runner: TP ที่ base **..25** ถัดไปใต้ entry (ตัวอย่าง 4460: BUY 4475, SELL 4425) ใช้ lattice Raw ตามโน้ต "Buy ต้อง base 75 / Sell ต้อง base 25"
- ถ้า base นั้นใกล้ entry กว่า stops level -> fallback เป็น `InpRunnerTPDist` (30 $) พร้อม log
- ผลคือ Runner มี TP ใกล้ได้ถึงไม่กี่ $ (ถ้า entry อยู่ใกล้ base) ซึ่งอาจน้อยกว่า `InpBEActivation` — Runner จะปิดด้วย TP ก่อนถึงจุด BE

### 10.5 หมายเหตุที่เหลือ
- ต้องใช้บัญชี **Hedging** (OnInit ปฏิเสธบัญชี netting)
- **ยังไม่ได้ compile / ยังไม่ได้ backtest** (เขียนโดยไม่มี MetaEditor) ต้อง compile และดู error ก่อนใช้
- รอบที่จบด้วย basket TP (มีไม้ non-runner ชน TP) จะหยุดถูกนับ max hold; ไม้ non-runner ที่เหลือถือด้วย TP/SL ของตัวเอง
- ทดสอบด้วย real ticks ตาม test plan ข้อ 7

