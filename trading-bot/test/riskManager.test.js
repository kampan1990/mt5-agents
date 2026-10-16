const test = require('node:test');
const assert = require('node:assert');
const { evaluate } = require('../src/agents/riskManager');

const limits = {
  riskPerTradePct: 1, maxDrawdownPct: 15, dailyLossLimitPct: 4, maxOpenPositions: 3,
  minConfidence: 0.65, minRiskReward: 1.2, slAtrMin: 1, slAtrMax: 4, minLot: 0.01, lotStep: 0.01, maxLot: 5,
};
const market = { symbol: 'XAUUSD', price: 2400, atr14: 10 };
const account = { connected: true, balance: 10000, equity: 10000, peakEquity: 10000, dayStartEquity: 10000, openPositions: [] };
const control = { tradingEnabled: true, halted: null };
const signal = { action: 'BUY', confidence: 0.8, sl_atr_multiple: 1.5, risk_reward: 2 };
const run = over => evaluate({ signal, market, news: null, account, control, limits, ...over });

test('approves a valid BUY with SL/TP and lot from % balance', () => {
  const r = run({});
  assert.equal(r.approved, true);
  assert.equal(r.order.sl, 2385);          // 2400 - 1.5*10
  assert.equal(r.order.tp, 2430);          // 2400 + 15*2
  assert.equal(r.order.lot, 0.06);         // 100 / (15 * 100) = 0.0667 → floor 0.06
  assert.ok(r.order.riskMoney <= 100);
});

test('SELL puts SL above and TP below price', () => {
  const r = run({ signal: { ...signal, action: 'SELL' } });
  assert.ok(r.order.sl > market.price && r.order.tp < market.price);
});

test('rejects HOLD, low confidence, bad RR', () => {
  assert.equal(run({ signal: { ...signal, action: 'HOLD' } }).approved, false);
  assert.equal(run({ signal: { ...signal, confidence: 0.5 } }).approved, false);
  assert.equal(run({ signal: { ...signal, risk_reward: 1 } }).approved, false);
});

test('halts on max drawdown', () => {
  const r = run({ account: { ...account, equity: 8400 } });
  assert.equal(r.approved, false);
  assert.ok(r.halt);
});

test('rejects on daily loss, kill switch, disconnected EA, exposure', () => {
  assert.equal(run({ account: { ...account, equity: 9550 } }).approved, false);
  assert.equal(run({ control: { tradingEnabled: false } }).approved, false);
  assert.equal(run({ account: { ...account, connected: false } }).approved, false);
  assert.equal(run({ account: { ...account, openPositions: [{ symbol: 'XAUUSD' }] } }).approved, false);
  assert.equal(run({ account: { ...account, openPositions: [{ symbol: 'A' }, { symbol: 'B' }, { symbol: 'C' }] } }).approved, false);
});

test('does not round lot up to minimum (would exceed risk)', () => {
  const r = run({ account: { ...account, balance: 100, equity: 100, peakEquity: 100, dayStartEquity: 100 } });
  assert.equal(r.approved, false);
  assert.match(r.reason, /ขั้นต่ำ/);
});

test('clamps an extreme SL multiple from the AI', () => {
  const r = run({ signal: { ...signal, sl_atr_multiple: 50 } });
  assert.equal(r.order.slDistance, 40); // clamp to 4 * ATR
});

test('blocks trading before high-impact news', () => {
  const news = { high_impact_event_soon: true, assets: [{ symbol: 'XAUUSD', impact: 'high' }] };
  assert.equal(run({ news }).approved, false);
});
