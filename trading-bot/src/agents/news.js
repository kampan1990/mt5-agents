// News/Sentiment Agent — อ่านหัวข่าวจาก RSS แล้วให้ Claude ประเมิน sentiment ต่อแต่ละสัญลักษณ์
const { z } = require('zod');
const config = require('../config');
const llm = require('../llm');
const log = require('../logger');

const NewsSchema = z.object({
  market_summary: z.string().describe('สรุปภาพรวมตลาดจากข่าว 2-3 ประโยค ภาษาไทย'),
  high_impact_event_soon: z.boolean().describe('มีข่าว/ประกาศเศรษฐกิจสำคัญ (เช่น NFP, CPI, FOMC) ที่จะออกเร็ว ๆ นี้หรือกำลังเกิดขึ้น'),
  assets: z.array(z.object({
    symbol: z.string(),
    sentiment: z.number().describe('-1 = bearish มาก, 0 = กลาง, 1 = bullish มาก'),
    impact: z.enum(['low', 'medium', 'high']),
    key_points: z.array(z.string()).describe('ประเด็นข่าวที่เกี่ยวข้อง สูงสุด 3 ข้อ ภาษาไทย'),
  })),
});

let cache = { at: 0, data: null };

function decode(s) {
  return s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/<[^>]+>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .trim();
}

async function fetchFeed(url) {
  const res = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0 (ai-trading-bot)' }, signal: AbortSignal.timeout(15000) });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const xml = await res.text();
  return [...xml.matchAll(/<item[\s>]([\s\S]*?)<\/item>/g)].slice(0, 25).map(m => {
    const tag = t => decode((m[1].match(new RegExp(`<${t}[^>]*>([\\s\\S]*?)</${t}>`)) || [])[1] || '');
    return { title: tag('title'), published: tag('pubDate'), summary: tag('description').slice(0, 280) };
  }).filter(i => i.title);
}

const MOCK_HEADLINES = [
  { title: 'Fed officials signal patience on rate cuts as inflation cools slowly', published: '', summary: '' },
  { title: 'Gold steadies near record as geopolitical tensions support safe-haven demand', published: '', summary: '' },
  { title: 'Bitcoin ETF inflows rebound after week of outflows', published: '', summary: '' },
  { title: 'US CPI data due Thursday; markets brace for volatility', published: '', summary: '' },
];

async function collectHeadlines() {
  if (config.mockData) return MOCK_HEADLINES;
  const results = await Promise.allSettled(config.newsFeeds.map(fetchFeed));
  const items = [];
  results.forEach((r, i) => {
    if (r.status === 'fulfilled') items.push(...r.value);
    else log.warn('news', `ดึง feed ไม่ได้: ${config.newsFeeds[i]}`, { error: r.reason.message });
  });
  return items.slice(0, 50);
}

function neutral(reason) {
  return {
    available: false,
    reason,
    market_summary: '',
    high_impact_event_soon: false,
    assets: config.symbols.map(symbol => ({ symbol, sentiment: 0, impact: 'low', key_points: [] })),
  };
}

async function run({ force = false } = {}) {
  if (!force && cache.data && Date.now() - cache.at < config.newsCacheMinutes * 60e3) {
    return { ...cache.data, cached: true };
  }

  const headlines = await collectHeadlines();
  if (!headlines.length) return neutral('ไม่มีหัวข่าว (feed ใช้งานไม่ได้)');
  if (!llm.isEnabled()) return neutral('ไม่มี ANTHROPIC_API_KEY — ข้ามการวิเคราะห์ข่าว');

  const { data, usage } = await llm.structured({
    effort: 'low',
    system: 'คุณคือนักวิเคราะห์ข่าวเศรษฐกิจมหภาคสำหรับเทรดเดอร์ ประเมินผลกระทบของข่าวต่อราคาสินทรัพย์อย่างเป็นกลาง ' +
      'ถ้าข่าวไม่เกี่ยวข้องกับสินทรัพย์ใด ให้ sentiment = 0 และ impact = low อย่าเดา',
    prompt: `สินทรัพย์ที่ต้องประเมิน: ${config.symbols.join(', ')}\n` +
      `เวลาปัจจุบัน (UTC): ${new Date().toISOString()}\n\n` +
      `หัวข่าวล่าสุด:\n${headlines.map((h, i) => `${i + 1}. ${h.title}${h.published ? ` (${h.published})` : ''}${h.summary ? ` — ${h.summary}` : ''}`).join('\n')}`,
    schema: NewsSchema,
  });

  // บังคับให้มีครบทุกสัญลักษณ์ และ clamp ค่า sentiment
  const assets = config.symbols.map(symbol => {
    const a = data.assets.find(x => x.symbol.toUpperCase() === symbol);
    return a ? { ...a, symbol, sentiment: Math.max(-1, Math.min(1, a.sentiment)) } : { symbol, sentiment: 0, impact: 'low', key_points: [] };
  });

  const result = { available: true, headlineCount: headlines.length, ...data, assets, usage };
  cache = { at: Date.now(), data: result };
  return result;
}

module.exports = { run, neutral, fetchFeed };
