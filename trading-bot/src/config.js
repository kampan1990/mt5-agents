require('dotenv').config();

const num = (v, d) => (v === undefined || v === '' || isNaN(Number(v)) ? d : Number(v));
const bool = (v, d) => (v === undefined || v === '' ? d : ['1', 'true', 'yes', 'on'].includes(String(v).toLowerCase()));

// ข้อมูลสัญลักษณ์ที่รองรับ
// source: แหล่งราคาฟรี, ticker: รหัสในแหล่งนั้น
// valuePerUnit: มูลค่า (USD) ต่อราคาขยับ 1.0 ต่อ 1 lot — ใช้คำนวณ lot ในโหมด PAPER เท่านั้น
// (โหมด LIVE ให้ EA คำนวณ lot เองจาก tick value จริงของ broker)
const SYMBOLS = {
  XAUUSD: { source: 'yahoo', ticker: 'GC=F', valuePerUnit: 100, digits: 2 },
  EURUSD: { source: 'yahoo', ticker: 'EURUSD=X', valuePerUnit: 100000, digits: 5 },
  GBPUSD: { source: 'yahoo', ticker: 'GBPUSD=X', valuePerUnit: 100000, digits: 5 },
  USDJPY: { source: 'yahoo', ticker: 'JPY=X', valuePerUnit: 100000, quoteIsJPY: true, digits: 3 },
  US30: { source: 'yahoo', ticker: '^DJI', valuePerUnit: 1, digits: 1 },
  NAS100: { source: 'yahoo', ticker: '^NDX', valuePerUnit: 1, digits: 1 },
  SP500: { source: 'yahoo', ticker: '^GSPC', valuePerUnit: 1, digits: 1 },
  BTCUSD: { source: 'binance', ticker: 'BTCUSDT', valuePerUnit: 1, digits: 2 },
  ETHUSD: { source: 'binance', ticker: 'ETHUSDT', valuePerUnit: 1, digits: 2 },
};

const symbols = (process.env.SYMBOLS || 'XAUUSD,EURUSD,BTCUSD')
  .split(',')
  .map(s => s.trim().toUpperCase())
  .filter(Boolean);

const unknown = symbols.filter(s => !SYMBOLS[s]);
if (unknown.length) throw new Error(`SYMBOLS ไม่รองรับ: ${unknown.join(', ')} (รองรับ: ${Object.keys(SYMBOLS).join(', ')})`);

const config = {
  port: num(process.env.PORT, 3000),
  dbPath: process.env.DB_PATH || 'trading.db',

  // PAPER = จำลองพอร์ต, LIVE = ส่งคำสั่งให้ EA บน MT5
  mode: (process.env.TRADING_MODE || 'PAPER').toUpperCase() === 'LIVE' ? 'LIVE' : 'PAPER',
  symbols,
  symbolSpecs: SYMBOLS,
  timeframe: process.env.TIMEFRAME || '1h', // 15m | 30m | 1h | 4h | 1d
  schedule: process.env.CYCLE_CRON || '*/30 * * * *',
  mockData: bool(process.env.MOCK_DATA, false),

  anthropicApiKey: process.env.ANTHROPIC_API_KEY || '',
  model: process.env.CLAUDE_MODEL || 'claude-opus-5-5',
  newsFeeds: (process.env.NEWS_FEEDS ||
    'https://www.fxstreet.com/rss/news,https://feeds.content.dowjones.io/public/rss/mw_topstories')
    .split(',').map(s => s.trim()).filter(Boolean),
  newsCacheMinutes: num(process.env.NEWS_CACHE_MINUTES, 30),

  risk: {
    riskPerTradePct: Math.min(num(process.env.RISK_PER_TRADE_PCT, 1), 2), // บังคับเพดาน 2%
    maxDrawdownPct: num(process.env.MAX_DRAWDOWN_PCT, 15),
    dailyLossLimitPct: num(process.env.DAILY_LOSS_LIMIT_PCT, 4),
    maxOpenPositions: num(process.env.MAX_OPEN_POSITIONS, 3),
    minConfidence: num(process.env.MIN_CONFIDENCE, 0.65),
    minRiskReward: num(process.env.MIN_RISK_REWARD, 1.2),
    slAtrMin: 1,
    slAtrMax: 4,
    minLot: 0.01,
    lotStep: 0.01,
    maxLot: num(process.env.MAX_LOT, 5),
  },

  paperStartBalance: num(process.env.PAPER_START_BALANCE, 10000),

  adminToken: process.env.ADMIN_TOKEN || '',
  eaToken: process.env.EA_TOKEN || '',
  eaHeartbeatStaleSec: num(process.env.EA_HEARTBEAT_STALE_SEC, 300),
};

module.exports = config;
