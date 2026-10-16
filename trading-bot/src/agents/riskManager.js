// Risk Manager Agent — ด่านสุดท้ายก่อนส่งคำสั่ง
// เป็น rule-based ล้วน (ไม่ใช้ LLM) เพื่อให้กฎความเสี่ยงคาดเดาได้ 100% และ AI override ไม่ได้
const config = require('../config');

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/**
 * @param {object} p
 * @param {object} p.signal   ผลจาก Strategy Agent
 * @param {object} p.market   ผลจาก Market Data Agent
 * @param {object} p.news     ผลจาก News Agent
 * @param {object} p.account  { balance, equity, peakEquity, dayStartEquity, openPositions, connected }
 * @param {object} p.control  { tradingEnabled, halted }
 * @param {object} [p.limits] override config.risk (ใช้ใน test)
 * @returns {{approved: boolean, reason?: string, order?: object}}
 */
function evaluate({ signal, market, news, account, control, limits = config.risk }) {
  const reject = reason => ({ approved: false, reason });

  if (!control.tradingEnabled) return reject('Kill switch: ปิดการเทรดอยู่');
  if (control.halted) return reject(`ระบบหยุดเทรด: ${control.halted}`);
  if (!account.connected) return reject('ไม่มีข้อมูลบัญชีล่าสุดจาก MT5 (EA ไม่ได้ส่ง heartbeat)');
  if (signal.action === 'HOLD') return reject('Strategy เสนอ HOLD');
  if (!['BUY', 'SELL'].includes(signal.action)) return reject(`action ไม่ถูกต้อง: ${signal.action}`);

  // --- Drawdown / daily loss ---
  const dd = account.peakEquity > 0 ? ((account.peakEquity - account.equity) / account.peakEquity) * 100 : 0;
  if (dd >= limits.maxDrawdownPct) return { ...reject(`Drawdown ${dd.toFixed(2)}% ≥ ${limits.maxDrawdownPct}%`), halt: `Max drawdown ${dd.toFixed(2)}%` };
  const dayLoss = account.dayStartEquity > 0 ? ((account.dayStartEquity - account.equity) / account.dayStartEquity) * 100 : 0;
  if (dayLoss >= limits.dailyLossLimitPct) return reject(`ขาดทุนวันนี้ ${dayLoss.toFixed(2)}% ≥ ${limits.dailyLossLimitPct}%`);

  // --- Exposure ---
  if (account.openPositions.length >= limits.maxOpenPositions) return reject(`position เปิดครบ ${limits.maxOpenPositions} แล้ว`);
  if (account.openPositions.some(p => p.symbol === market.symbol)) return reject(`มี position ${market.symbol} เปิดอยู่แล้ว`);

  // --- Signal quality ---
  const confidence = Number(signal.confidence) || 0;
  if (confidence < limits.minConfidence) return reject(`confidence ${confidence.toFixed(2)} < ${limits.minConfidence}`);
  const assetNews = news?.assets?.find(a => a.symbol === market.symbol);
  if (news?.high_impact_event_soon && assetNews?.impact === 'high') return reject('มีข่าวผลกระทบสูงกำลังจะออก — งดเปิด order');

  // --- SL/TP (บังคับทุก order) ---
  if (!(market.atr14 > 0) || !(market.price > 0)) return reject('ATR/ราคาไม่ถูกต้อง คำนวณ SL ไม่ได้');
  const slMult = clamp(Number(signal.sl_atr_multiple) || 1.5, limits.slAtrMin, limits.slAtrMax);
  const rr = clamp(Number(signal.risk_reward) || 0, 0, 5);
  if (rr < limits.minRiskReward) return reject(`Risk:Reward 1:${rr.toFixed(2)} < 1:${limits.minRiskReward}`);

  const slDistance = market.atr14 * slMult;
  const tpDistance = slDistance * rr;
  const dir = signal.action === 'BUY' ? 1 : -1;
  const spec = config.symbolSpecs[market.symbol];
  const r = v => Number(v.toFixed(spec.digits));
  const sl = r(market.price - dir * slDistance);
  const tp = r(market.price + dir * tpDistance);
  if (sl <= 0 || tp <= 0) return reject('SL/TP คำนวณได้ค่าติดลบ');

  // --- Position sizing: lot จาก % ของ balance ---
  const valuePerUnit = spec.quoteIsJPY ? spec.valuePerUnit / market.price : spec.valuePerUnit;
  const riskMoney = account.balance * (limits.riskPerTradePct / 100);
  const rawLot = riskMoney / (slDistance * valuePerUnit);
  const lot = Math.floor(rawLot / limits.lotStep + 1e-9) * limits.lotStep;
  // ไม่ปัดขึ้นเป็น min lot — ถ้า lot ต่ำกว่าขั้นต่ำแปลว่าความเสี่ยงจริงจะเกิน % ที่ตั้งไว้
  if (lot < limits.minLot) return reject(`lot ที่คำนวณได้ ${rawLot.toFixed(4)} < ขั้นต่ำ ${limits.minLot} (SL กว้างเกินไปสำหรับ balance นี้)`);
  const finalLot = Number(Math.min(lot, limits.maxLot).toFixed(2));

  return {
    approved: true,
    order: {
      symbol: market.symbol,
      side: signal.action,
      confidence,
      entryRef: market.price,
      slDistance, tpDistance, sl, tp,
      lot: finalLot,
      riskPct: limits.riskPerTradePct,
      riskMoney: Number((finalLot * slDistance * valuePerUnit).toFixed(2)),
    },
  };
}

module.exports = { evaluate };
