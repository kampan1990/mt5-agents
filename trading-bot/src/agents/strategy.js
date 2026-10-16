// Strategy/Signal Agent — รวมข้อมูลจาก Market Data + News แล้วสรุปเป็นสัญญาณพร้อมเหตุผล
// ถ้าไม่มี API key จะใช้ rule-based (EMA trend + RSI) แทน
// Agent นี้ "เสนอ" เท่านั้น — Risk Manager เป็นผู้ตัดสินขั้นสุดท้าย
const { z } = require('zod');
const llm = require('../llm');

const SignalSchema = z.object({
  action: z.enum(['BUY', 'SELL', 'HOLD']),
  confidence: z.number().describe('ความมั่นใจ 0.0-1.0 ใช้ค่าสูง (>0.7) เฉพาะเมื่อปัจจัยหลายอย่างสอดคล้องกันจริง'),
  sl_atr_multiple: z.number().describe('ระยะ StopLoss เป็นจำนวนเท่าของ ATR14 (1.0-4.0)'),
  risk_reward: z.number().describe('อัตราส่วน TP:SL (1.0-5.0)'),
  key_factors: z.array(z.string()).describe('ปัจจัยหลักที่ใช้ตัดสินใจ สูงสุด 4 ข้อ ภาษาไทย'),
  reasoning: z.string().describe('เหตุผลสั้น ๆ 2-4 ประโยค ภาษาไทย'),
});

const SYSTEM = `คุณคือ Strategy Agent ของระบบเทรดอัตโนมัติ หน้าที่คือวิเคราะห์ข้อมูลทางเทคนิคและข่าว แล้วเสนอสัญญาณ BUY / SELL / HOLD

หลักการ:
- การรักษาเงินทุนสำคัญกว่าการหากำไร ถ้าสัญญาณไม่ชัด ให้ HOLD
- เทรดตามเทรนด์หลัก (EMA50/EMA200) เป็นหลัก การสวนเทรนด์ต้องมีเหตุผลที่แข็งแรงมาก
- ระวัง RSI สุดขั้ว (>75 หรือ <25) เพราะอาจไล่ราคา
- ถ้ามีข่าวสำคัญกำลังจะออก หรือข่าวขัดแย้งกับเทคนิคอย่างแรง ให้ลด confidence
- ถ้ามี position ของสัญลักษณ์นี้เปิดอยู่แล้ว ให้ HOLD
- เลือก sl_atr_multiple ให้ SL อยู่นอก noise ปกติ และ risk_reward ที่สมจริงกับ swing high/low ล่าสุด
- confidence ต้องสะท้อนความน่าจะเป็นจริง ห้ามให้ค่าสูงเกินจริง`;

function ruleBased(md, news) {
  const s = news?.sentiment ?? 0;
  let action = 'HOLD', confidence = 0.4;
  const factors = [`เทรนด์ ${md.trend}`, `RSI ${md.rsi14}`];
  if (md.trend === 'UP' && md.rsi14 > 50 && md.rsi14 < 70 && md.price > md.ema20 && s >= -0.3) {
    action = 'BUY'; confidence = 0.66 + Math.max(0, s) * 0.1;
  } else if (md.trend === 'DOWN' && md.rsi14 < 50 && md.rsi14 > 30 && md.price < md.ema20 && s <= 0.3) {
    action = 'SELL'; confidence = 0.66 + Math.max(0, -s) * 0.1;
  }
  return {
    action, confidence: Number(confidence.toFixed(2)), sl_atr_multiple: 1.5, risk_reward: 2,
    key_factors: factors, reasoning: 'rule-based: EMA20/50/200 เรียงตัวตามเทรนด์ + RSI ยืนยันโมเมนตัม + ข่าวไม่ขัดแย้ง', engine: 'rules',
  };
}

async function run({ market, news, hasOpenPosition }) {
  const assetNews = news?.assets?.find(a => a.symbol === market.symbol);

  if (hasOpenPosition) {
    return { action: 'HOLD', confidence: 0, sl_atr_multiple: 0, risk_reward: 0, key_factors: ['มี position เปิดอยู่แล้ว'], reasoning: 'มี position ของสัญลักษณ์นี้อยู่แล้ว', engine: 'guard' };
  }
  if (!llm.isEnabled()) return ruleBased(market, assetNews);

  const { lastCandles, ...snapshot } = market;
  const prompt = [
    `## สัญลักษณ์: ${market.symbol} (timeframe ${market.timeframe})`,
    '### ข้อมูลทางเทคนิค',
    JSON.stringify(snapshot, null, 2),
    `### 12 แท่งล่าสุด [open, high, low, close] เก่า→ใหม่`,
    JSON.stringify(lastCandles),
    '### ข่าว/Sentiment',
    news?.available
      ? JSON.stringify({ market_summary: news.market_summary, high_impact_event_soon: news.high_impact_event_soon, asset: assetNews }, null, 2)
      : `ไม่มีข้อมูลข่าว (${news?.reason || 'unknown'}) — ใช้เทคนิคอย่างเดียวและลด confidence ลงเล็กน้อย`,
  ].join('\n');

  const { data, usage } = await llm.structured({ system: SYSTEM, prompt, schema: SignalSchema, effort: 'medium' });
  return { ...data, engine: 'claude', usage };
}

module.exports = { run, ruleBased };
