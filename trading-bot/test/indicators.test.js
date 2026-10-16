const test = require('node:test');
const assert = require('node:assert');
const { ema, rsi, atr, last } = require('../src/indicators');

test('EMA of a constant series equals the constant', () => {
  assert.equal(last(ema(Array(50).fill(5), 20)), 5);
});

test('RSI is 100 on a strictly rising series and ~0 on a falling one', () => {
  const up = Array.from({ length: 30 }, (_, i) => i);
  assert.equal(last(rsi(up, 14)), 100);
  assert.ok(last(rsi(up.slice().reverse(), 14)) < 1);
});

test('ATR of fixed-range candles equals the range', () => {
  const c = Array.from({ length: 30 }, () => ({ o: 10, h: 11, l: 9, c: 10 }));
  assert.ok(Math.abs(last(atr(c, 14)) - 2) < 1e-9);
});
