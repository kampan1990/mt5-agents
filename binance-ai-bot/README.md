# Binance AI Bot (Claude + USDT-M Futures)

บอทเทรด Binance USDT-M Futures ที่ให้ **Claude** เป็นผู้ตัดสินใจ (LONG / SHORT / CLOSE / HOLD)
ส่วน **ขนาด position, leverage, SL/TP และ drawdown ถูกบังคับด้วยโค้ด** Claude ไม่มีสิทธิ์กำหนดสิ่งเหล่านี้เอง

> ⚠️ Futures มี leverage และอาจถูก liquidate ได้ ให้รัน backtest แล้วทดสอบบน testnet อย่างน้อย 2–4 สัปดาห์ก่อนใช้เงินจริง
> ผลลัพธ์ในอดีตไม่ได้รับประกันกำไร

## การทำงาน

```
ทุกครั้งที่แท่งเทียนปิด (เช่น 1h) สำหรับแต่ละเหรียญ:
  ดึงข้อมูลบัญชี → เช็ค Max Drawdown / Daily Loss → ลบ SL/TP ที่ค้างอยู่
  → สร้าง snapshot (EMA, RSI, ATR, MACD, BB, volume, funding, TF ใหญ่)
  → Claude ตัดสินใจ (structured output) → RiskManager ตรวจสอบ
  → Market order → วาง SL (STOP_MARKET) + TP (TAKE_PROFIT_MARKET) บน exchange
     ถ้าวาง SL ไม่สำเร็จ จะปิด position ทันที
```

| ไฟล์ | หน้าที่ |
|------|---------|
| `bot/engines.py` | `ClaudeEngine` (Claude Opus 5.5 + structured output + disk cache) และ `RuleEngine` (EMA/RSI baseline) |
| `bot/risk.py` | ขนาด lot จาก % ของ equity, จำกัด leverage, SL/TP บังคับ, R:R ขั้นต่ำ, Max DD, Daily loss |
| `bot/market_data.py` | สร้าง feature snapshot (ใช้ร่วมกันทั้ง backtest และ live) |
| `bot/backtest.py` | Backtest ทีละแท่ง มีค่าธรรมเนียม + slippage และถ้าแตะ SL/TP ในแท่งเดียวกันจะนับเป็น SL |
| `bot/binance_client.py` | REST client (HMAC) ใช้ **Algo Order API** สำหรับ SL/TP |
| `bot/trader.py` | ลูปเทรดจริง/testnet |
| `bot/journal.py` | บันทึก log + `logs/trades.jsonl` ทุก trade event |

### กฎความเสี่ยง (ตั้งค่าใน `.env`)

- `RISK_PER_TRADE_PCT=1.0` ขาดทุนสูงสุดต่อไม้เมื่อโดน SL (% ของ equity)
- `LEVERAGE=3` จำกัด notional ไม่ให้เกิน equity × leverage
- `MAX_DRAWDOWN_PCT=15` ถ้า drawdown จาก equity สูงสุดเกินค่านี้ บอทจะ **ปิดทุก position และหยุดเทรด**
- `DAILY_LOSS_LIMIT_PCT=4` ถ้าขาดทุนในวันเกินค่านี้ จะไม่เปิดไม้ใหม่จนถึงวันถัดไป (UTC)
- `MIN_CONFIDENCE=0.6`, `MIN_REWARD_RISK=1.5`, SL ต้องอยู่ระหว่าง 0.5–4 ATR
- ใช้ One-way mode + Isolated margin เท่านั้น

## ติดตั้ง

```bash
cd binance-ai-bot
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env     # ใส่ ANTHROPIC_API_KEY และ Binance testnet key
```

Testnet key: สมัครที่ Binance Futures Demo Trading แล้วสร้าง API key
(ค่าเริ่มต้นของ URL คือ `https://demo-fapi.binance.com` ถ้าใช้ไม่ได้ให้ตั้ง `BINANCE_BASE_URL=https://testnet.binancefuture.com`)

## ใช้งาน

```bash
# 1) ดึงข้อมูลย้อนหลัง
python main.py fetch --days 180

# 2) Backtest baseline (ฟรี ไม่เรียก Claude)
python main.py backtest --engine rules

# 3) Backtest ด้วย Claude (เสียค่า API) ถามทุก 4 แท่ง และจำกัดไม่เกิน 200 calls
python main.py backtest --engine claude --symbols BTCUSDT --days 30 --decision-every 4 --max-calls 200

# 4) Testnet: ทดลองรัน 1 รอบแบบไม่ส่ง order
python main.py run --once --dry-run

# 5) Testnet: รันต่อเนื่อง (ตั้ง DRY_RUN=false ใน .env เพื่อส่ง order จริงบน testnet)
python main.py run

# 6) เงินจริง: ต้องตั้ง BINANCE_ENV=live และใส่ flag นี้
python main.py run --confirm-live
```

ผล backtest จะออกเป็น JSON (return, max DD, win rate, profit factor, avg R, Sharpe) และรายการเทรดอยู่ใน `logs/backtest_*.csv`

## ศึกษาเหรียญที่เพิ่งลิสต์ (Listing study)

ตรวจสอบสมมติฐาน "เหรียญใหม่พุ่งแล้วร่วง" ด้วยข้อมูลจริง ก่อนจะเขียนกลยุทธ์เทรดเหรียญใหม่

```bash
python main.py listing-study --years 2 --include-delisted
# ผลลัพธ์: reports/listing_study/report.md (+ milestones.csv, trades.csv, config_summary.csv, path_after_listing.png)
```

- ดึงแท่ง 1h แรก ~41 วันของทุก USDT perpetual ที่ลิสต์ในช่วง N ปี และเทียบกับ BTC
- `--include-delisted` ดึงเหรียญที่ถูกถอดแล้วจาก data.binance.vision เพื่อไม่ให้ผลดีเกินจริง (survivorship bias)
- จำลองการ short หลังลิสต์ 1–48 ชม. พร้อม SL ตายตัว หลายชุดพารามิเตอร์ และมีการตรวจ out-of-sample
- ข้อมูลดิบถูก cache ที่ `data/listings/` รันซ้ำได้ไม่ต้องดาวน์โหลดใหม่
- ไม่รวม funding และสภาพคล่องจริงของเหรียญใหม่ (slippage จริงมักแย่กว่าที่สมมติ)

## ข้อควรรู้เกี่ยวกับ Claude

- **ค่าใช้จ่าย:** ถ้าถามทุกชั่วโมง 4 เหรียญ จะเป็นประมาณ 96 calls/วัน ปรับ `LLM_EFFORT` (low/medium/high) เพื่อแลกระหว่างคุณภาพกับราคา
  การตัดสินใจทุกครั้งถูก cache ไว้ใน `data/llm_cache/` ถ้ารัน backtest ซ้ำด้วยข้อมูลเดิมจะไม่เสียเงินเพิ่ม
- **Backtest ด้วย LLM อาจลำเอียง:** Claude อาจจำราคาในอดีตได้ จึงซ่อน symbol/ราคา/วันที่ไว้ (`LLM_ANONYMIZE=true`)
  แต่ก็ยังมีความเสี่ยง ผลที่เชื่อถือได้ที่สุดคือ **forward test บน testnet**
- **Fail-safe:** ถ้า API error, rate limit หรือโมเดลปฏิเสธ บอทจะถือว่า HOLD เสมอ
- เปิดใช้ server-side fallback (`fallbacks: "default"`) ไว้: ถ้าโมเดลปฏิเสธ API จะส่งต่อให้โมเดลสำรองอัตโนมัติ ปิดได้ด้วย `LLM_FALLBACKS=false`
- ควรเทียบผลกับ `RuleEngine` ด้วย ถ้า Claude ไม่ชนะ baseline หลังหักค่า API ก็ยังไม่ควรใช้

## Tests

```bash
python -m pytest -q
```

ครอบคลุม indicators, risk rules, backtester (ไม่มี lookahead, หยุดเมื่อถึง max DD), Claude engine (mock), การเซ็น request และ Algo Order ของ Binance (mock)
