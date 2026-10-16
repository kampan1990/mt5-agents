# 🤖 AI Trading Bot

เว็บบอทเทรดอัตโนมัติ มี AI agents 4 ตัวแยกหน้าที่กัน และส่งคำสั่งไปเปิด order จริงบน MetaTrader 5 ผ่าน EA

```
              ┌──────────────────────── ทุก CYCLE_CRON ───────────────────────┐
              │                                                              │
 Yahoo/Binance ──▶ 📈 Market Data Agent ─┐                                    │
                   (OHLC, EMA, RSI, ATR) │                                    │
                                         ├─▶ 🧠 Strategy Agent ─▶ 🛡️ Risk Manager ─▶ PAPER: จำลองพอร์ต
 RSS ข่าว ──────▶ 📰 News Agent ─────────┘    (Claude: BUY/SELL/   (กฎตายตัว ไม่ใช่ AI)   LIVE : คิวคำสั่ง
                   (Claude: sentiment)         HOLD + เหตุผล)                              │
                                                                                         ▼
                                                              MT5 ◀── AIBridgeEA.mq5 (poll ทุก 10 วินาที)
```

| Agent | ใช้ AI? | หน้าที่ |
|---|---|---|
| Market Data | ❌ | ดึงราคา คำนวณ EMA20/50/200, RSI14, ATR14, เทรนด์, swing high/low |
| News/Sentiment | ✅ Claude | อ่านหัวข่าวจาก RSS แล้วประเมิน sentiment และข่าวสำคัญที่กำลังจะออก |
| Strategy/Signal | ✅ Claude | รวมข้อมูลเทคนิคกับข่าว แล้วเสนอ BUY/SELL/HOLD, confidence, SL (×ATR), R:R |
| Risk Manager | ❌ | ตรวจกฎทุกข้อ แล้วคำนวณ SL/TP และ lot เป็นผู้ตัดสินขั้นสุดท้าย AI override ไม่ได้ |

ถ้าไม่ใส่ `ANTHROPIC_API_KEY` ระบบยังทำงานได้ โดย Strategy จะใช้ rule-based (EMA trend + RSI) แทน

## กฎความเสี่ยง (บังคับในโค้ด)

- **SL/TP ทุก order**: SL = ATR × (1–4), TP = SL × R:R โดย R:R ต้อง ≥ `MIN_RISK_REWARD`
- **Lot จาก % balance**: ถ้า lot ที่คำนวณได้ต่ำกว่าขั้นต่ำจะ**ไม่เทรด** ไม่ปัดขึ้น
- **Max Drawdown**: ถ้าเกิน `MAX_DRAWDOWN_PCT` ระบบจะหยุดเทรดจนกว่าจะกดรีเซ็ตเอง
- **Daily loss limit**, จำนวน position สูงสุด, 1 position ต่อสัญลักษณ์
- confidence ต้องถึง `MIN_CONFIDENCE` และงดเปิด order ก่อนข่าวแรง
- ถ้า AI error หรือปฏิเสธคำขอ ระบบจะเลือก HOLD เสมอ
- โหมด LIVE: ถ้า EA ไม่ส่ง heartbeat เกิน 5 นาที ระบบจะไม่ออกคำสั่ง และคำสั่งที่ค้างเกิน 10 นาทีจะหมดอายุ
- **EA มีชั้นป้องกันของตัวเอง**: risk% สูงสุด, lot สูงสุด, Max DD, คำนวณ lot ใหม่จาก tick value จริงของ broker และตั้ง SL/TP จากราคา fill จริง

## รันบนเครื่อง

```bash
cd trading-bot
npm install
cp .env.example .env        # แก้ค่าตามต้องการ
MOCK_DATA=true ADMIN_TOKEN=test npm start
# เปิด http://localhost:3000 → กด 🔑 Token ใส่ "test" → กด ▶ รันรอบนี้
npm test                     # unit tests ของ Risk Manager + indicators
```

## Deploy บน Railway

1. New Project → Deploy from GitHub repo → ตั้ง **Root Directory** = `trading-bot`
2. ใส่ Variables: `ANTHROPIC_API_KEY`, `ADMIN_TOKEN`, `EA_TOKEN`, `TRADING_MODE=PAPER`
3. เพิ่ม **Volume** mount ที่ `/data` และตั้ง `DB_PATH=/data/trading.db` ไม่อย่างนั้นข้อมูลจะหายทุกครั้งที่ deploy

## เชื่อม MT5 (โหมด LIVE)

1. คัดลอก `mql5/AIBridgeEA.mq5` ไปที่ `MQL5/Experts/` แล้ว compile ใน MetaEditor
2. MT5 → Tools → Options → Expert Advisors → ✅ Allow WebRequest แล้วเพิ่ม URL ของ server
3. ลาก EA ลง chart ใดก็ได้ (1 ตัวพอ) ใส่ `InpServerURL`, `InpEAToken` และ `InpSymbolSuffix` ถ้า broker ใช้ชื่อเช่น `XAUUSD.m`
4. เปิด AutoTrading แล้วตั้ง `TRADING_MODE=LIVE` บน server
5. MT5 ต้องเปิดค้างไว้ตลอด (แนะนำใช้ VPS)

**แนะนำ:** รัน PAPER อย่างน้อย 2–4 สัปดาห์ แล้วทดสอบ LIVE บน **บัญชี demo** ก่อนใช้เงินจริง

## ค่าใช้จ่าย Claude API (ประมาณ)

หนึ่งรอบใช้ Claude 1 ครั้งต่อสัญลักษณ์ (Strategy) บวกข่าวอีก 1 ครั้ง (cache 30 นาที) ถ้าใช้ 3 สัญลักษณ์ทุก 30 นาที จะได้ราว 150–200 calls/วัน ถ้าต้องการลดค่าใช้จ่าย ให้ลดจำนวนสัญลักษณ์ ยืดรอบ หรือตั้ง `CLAUDE_MODEL=claude-sonnet-5-5`

## API

| Method | Path | Auth | ใช้ทำอะไร |
|---|---|---|---|
| GET | `/api/status`, `/api/signals`, `/api/positions`, `/api/equity`, `/api/logs` | – | dashboard |
| POST | `/api/control/run` | ADMIN | รันรอบเดี๋ยวนี้ |
| POST | `/api/control/trading` `{enabled}` | ADMIN | Kill switch |
| POST | `/api/control/reset-halt` | ADMIN | ปลดล็อกหลังโดน Max DD |
| POST | `/api/ea/heartbeat` | EA | EA ส่ง balance/equity/positions |
| GET | `/api/ea/orders` | EA | EA ดึงคำสั่งใหม่ |
| POST | `/api/ea/report` | EA | EA รายงานผล fill/fail |

> ⚠️ การเทรดมีความเสี่ยงสูง ระบบนี้ไม่รับประกันกำไร AI วิเคราะห์ผิดได้ และอาจขาดทุนจนหมดเงินทุน
