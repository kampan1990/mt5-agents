# คู่มือ Backtest — ThreeMagicEA

แนวทางทดสอบ EA ใน **Strategy Tester** ของ MT5 ก่อนใช้เงินจริง
หลักสำคัญ: **ทดสอบทีละ magic ก่อน แล้วค่อยรวมทั้ง 3** เพื่อรู้ว่าตัวไหนสร้าง/กินกำไร

---

## 0) เตรียมพร้อม
- [ ] Compile `ThreeMagicEA.mq5` ใน MetaEditor (F7) — ต้อง **0 errors**
- [ ] ใช้ข้อมูล tick คุณภาพสูง: Model = **Every tick based on real ticks**
- [ ] ตั้ง Deposit / Leverage ให้ตรงกับบัญชีจริง
- [ ] เลือกช่วงเวลาที่มีทั้งตลาดเทรนด์และ sideway (อย่างน้อย 1–2 ปี)
- [ ] โหลด preset จากโฟลเดอร์ `presets/` (ปุ่ม Load ในแท็บ Inputs)

---

## 1) ทดสอบทีละ Magic (เปิดทีละตัว)

ปิดอีก 2 ตัวด้วย `InpMx_Enable=false` แล้ววัดผลแยก

### Magic 1 — Engulfing (`M1=on, M2=off, M3=off`)
- [ ] เช็คว่า engulfing detection ยิงถูกจุด (ดู log `ARMED` / `GRID placed`)
- [ ] ปรับ `RetracePercent` — ค่าน้อยเข้าไว/ถี่ ค่ามากเข้าช้า/แม่นขึ้น
- [ ] ปรับ `GridStepPoints` ให้เหมาะกับ ATR ของสัญลักษณ์
- [ ] **จับตา recovery**: ดูว่า `RecoveryLotMult` × `RecoveryMaxAdds` ทำให้ lot บานแค่ไหนตอนกราฟสวนยาว → ปรับ `BasketSL` ให้ตัดก่อนพอร์ตเจ็บ
- [ ] ตรวจ flip: log `FLIP` ควรเกิดเฉพาะตอน P/L ยังไม่ติดลบเกิน `FlipMaxLoss`

### Magic 2 — Sideway (`M2=on` เท่านั้น)
- [ ] ยืนยันว่าเข้าเฉพาะตอน ranging (ดู log `RANGE grid`) ไม่เข้าตอนเทรนด์แรง
- [ ] ปรับ `ADXSidewayMax` / `BBWidthMaxPct` ให้กรอง sideway ได้จริง
- [ ] ทดสอบ **Breakout Guard**: หาช่วงตลาด breakout → ต้องเห็น log `BREAKOUT guard` แล้วปิด basket + พัก
- [ ] ปรับ `CooldownBars` ไม่ให้รีบกลับเข้าเร็วเกิน

### Magic 3 — Trend (`M3=on` เท่านั้น)
- [ ] ยืนยันเข้าเฉพาะตอนมีเทรนด์ (ADX > `ADXTrendMin`) และเป็น pullback จริง
- [ ] ตรวจ **Partial TP**: log `PARTIAL TP: closed X, kept N` — เก็บไม้ราคาดีสุดถูกตัวไหม
- [ ] ตรวจ **Trailing**: SL ของ runner ขยับตามกำไรจริง
- [ ] ปรับ `RunnerTP` / `TrailAtrMult` หา balance ระหว่าง "กินยาว" กับ "คายกำไรคืน"
- [ ] เช็ค `MaxPositions` คุม pyramiding ไม่ให้ไม้บานเกิน

---

## 2) เมตริกที่ต้องดู (ต่อ magic และรวม)
| เมตริก | เป้าหมายคร่าวๆ |
|--------|----------------|
| Profit Factor | > 1.3 |
| Max Drawdown % | < `MaxAccountDDPct` ที่ตั้งไว้ |
| Recovery Factor | ยิ่งสูงยิ่งดี |
| Expected Payoff | เป็นบวก |
| จำนวนไม้ | มากพอจะมีนัยสำคัญ (100+) |

> ⚠️ ระวัง equity curve ที่สวยแต่มี **spike drawdown** จาก recovery ของ Magic 1 — ดู "Balance vs Equity" ให้ห่างกันไม่มาก

---

## 3) รวมทั้ง 3 Magic
- [ ] เปิดทั้ง 3 (`M1/M2/M3 = on`) รันช่วงเวลาเดียวกัน
- [ ] ตรวจว่า **magic ไม่ตีกันเอง** (แต่ละตัวจัดการเฉพาะ magic ตัวเอง — โค้ดกรองด้วย magic + symbol แล้ว)
- [ ] ดูว่า drawdown รวมไม่ทะลุเพดาน และ `CheckAccountDrawdown` halt ทำงาน (log `trading HALTED`)
- [ ] เทียบผลรวม vs ผลแยก — การกระจายความเสี่ยงช่วยให้ equity เรียบขึ้นไหม

---

## 4) Forward Test
- [ ] รันบน **demo** อย่างน้อย 2–4 สัปดาห์ก่อนเงินจริง
- [ ] เทียบพฤติกรรมจริงกับ backtest (spread/slippage จริงต่างจาก tester)
- [ ] เริ่มเงินจริงด้วย lot ต่ำสุดเสมอ

---

## Optimization (แนะนำพารามิเตอร์ที่ควร optimize ก่อน)
| Magic | พารามิเตอร์สำคัญ |
|-------|------------------|
| M1 | `RetracePercent`, `GridStepPoints`, `BasketTP`, `BasketSL`, `RecoveryLotMult` |
| M2 | `ADXSidewayMax`, `BBWidthMaxPct`, `GridStepPoints`, `BasketTP` |
| M3 | `EMAFast/EMASlow`, `ADXTrendMin`, `RunnerTP`, `TrailAtrMult`, `PartialTrigPts` |

> อย่า over-optimize — เลือกช่วงค่าที่ให้ผลดี **สม่ำเสมอ** (plateau) ไม่ใช่จุดพีคจุดเดียว
