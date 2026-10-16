// Market Data Agent — ดึงราคา OHLC จากแหล่งฟรี แล้วคำนวณ indicators
// ไม่ใช้ LLM: ตัวเลขต้องแม่นยำและตรวจสอบได้
const config = require('../config');
const { ema, rsi, atr, last } = require('../indicators');

const YAHOO_INTERVAL = { '15m': ['15m', '30d'], '30m': ['30m', '30d'], '1h': ['60m', '60d'], '4h': ['60m', '60d'], '1d': ['1d', '2y'] };
const CANDLES_NEEDED = 250;

async function fetchJSON(url) {
  const res = await fetch(url, {
    headers: { 'User-Agent': 'Mozilla/5.0 (ai-trading-bot)' },
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} จาก ${new URL(url).host}`);
  return res.json();
}

async function fromYahoo(ticker, tf) {
  const [interval, range] = YAHOO_INTERVAL[tf] || YAHOO_INTERVAL['1h'];
  const json = await fetchJSON(`https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(ticker)}?interval=${interval}&range=${range}`);
  const r = json?.chart?.result?.[0];
  if (!r?.timestamp) throw new Error(`Yahoo ไม่มีข้อมูลของ ${ticker}`);
  const q = r.indicators.quote[0];
  let candles = r.timestamp.map((t, i) => ({ t: t * 1000, o: q.open[i], h: q.high[i], l: q.low[i], c: q.close[i] }))
    .filter(c => [c.o, c.h, c.l, c.c].every(v => typeof v === 'number'));
  if (tf === '4h') candles = aggregate(candles, 4 * 3600 * 1000);
  return candles;
}

async function fromBinance(ticker, tf) {
  const json = await fetchJSON(`https://api.binance.com/api/v3/klines?symbol=${ticker}&interval=${tf}&limit=${CANDLES_NEEDED + 50}`);
  return json.map(k => ({ t: k[0], o: +k[1], h: +k[2], l: +k[3], c: +k[4] }));
}

function aggregate(candles, bucketMs) {
  const out = [];
  for (const c of candles) {
    const b = Math.floor(c.t / bucketMs) * bucketMs;
    const cur = out[out.length - 1];
    if (cur && cur.t === b) { cur.h = Math.max(cur.h, c.h); cur.l = Math.min(cur.l, c.l); cur.c = c.c; }
    else out.push({ t: b, o: c.o, h: c.h, l: c.l, c: c.c });
  }
  return out;
}

// ข้อมูลจำลอง (random walk) สำหรับทดสอบโดยไม่ต้องต่อเน็ต
const MOCK_BASE = { XAUUSD: 2400, EURUSD: 1.08, GBPUSD: 1.27, USDJPY: 150, US30: 42000, NAS100: 20000, SP500: 5600, BTCUSD: 65000, ETHUSD: 3200 };
function mockCandles(symbol) {
  let p = MOCK_BASE[symbol] || 100;
  const vol = p * 0.003;
  const now = Date.now();
  const drift = (Math.random() - 0.5) * vol * 0.3;
  return Array.from({ length: CANDLES_NEEDED }, (_, i) => {
    const o = p;
    const c = o + drift + (Math.random() - 0.5) * vol;
    const h = Math.max(o, c) + Math.random() * vol * 0.5;
    const l = Math.min(o, c) - Math.random() * vol * 0.5;
    p = c;
    return { t: now - (CANDLES_NEEDED - i) * 3600e3, o, h, l, c };
  });
}

async function getCandles(symbol) {
  if (config.mockData) return mockCandles(symbol);
  const spec = config.symbolSpecs[symbol];
  const candles = spec.source === 'binance'
    ? await fromBinance(spec.ticker, config.timeframe)
    : await fromYahoo(spec.ticker, config.timeframe);
  return candles.slice(-CANDLES_NEEDED);
}

const round = (v, d = 5) => (v == null ? null : Number(v.toFixed(d)));

async function run(symbol) {
  const candles = await getCandles(symbol);
  if (candles.length < 210) throw new Error(`ข้อมูล ${symbol} ไม่พอ (${candles.length} แท่ง ต้องการ ≥ 210)`);

  const closes = candles.map(c => c.c);
  const e20 = last(ema(closes, 20)), e50 = last(ema(closes, 50)), e200 = last(ema(closes, 200));
  const rsiArr = rsi(closes, 14);
  const atrVal = last(atr(candles, 14));
  const price = last(closes);
  const d = config.symbolSpecs[symbol].digits;

  const trend = e20 > e50 && e50 > e200 ? 'UP' : e20 < e50 && e50 < e200 ? 'DOWN' : 'MIXED';
  const recent = candles.slice(-20);

  return {
    symbol,
    timeframe: config.timeframe,
    source: config.mockData ? 'mock' : config.symbolSpecs[symbol].source,
    asOf: new Date(last(candles).t).toISOString(),
    price: round(price, d),
    lastHigh: last(candles).h,
    lastLow: last(candles).l,
    ema20: round(e20, d), ema50: round(e50, d), ema200: round(e200, d),
    rsi14: round(last(rsiArr), 1),
    rsi14Prev: round(rsiArr[rsiArr.length - 2], 1),
    atr14: round(atrVal, d),
    atrPct: round((atrVal / price) * 100, 3),
    trend,
    swingHigh20: round(Math.max(...recent.map(c => c.h)), d),
    swingLow20: round(Math.min(...recent.map(c => c.l)), d),
    change20Pct: round(((price - recent[0].o) / recent[0].o) * 100, 2),
    // ส่ง 12 แท่งล่าสุดแบบย่อให้ Strategy Agent เห็น price action
    lastCandles: candles.slice(-12).map(c => [round(c.o, d), round(c.h, d), round(c.l, d), round(c.c, d)]),
  };
}

module.exports = { run, aggregate };
