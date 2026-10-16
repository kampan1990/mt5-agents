// Orchestrator — สั่งงาน agents ทีละรอบ (cycle)
// Market Data (ทุกสัญลักษณ์ขนานกัน) + News → Strategy → Risk Manager → Broker
const config = require('./config');
const { getDB, getState, setState } = require('./db');
const log = require('./logger');
const broker = require('./broker');
const marketAgent = require('./agents/marketData');
const newsAgent = require('./agents/news');
const strategyAgent = require('./agents/strategy');
const riskAgent = require('./agents/riskManager');

let running = false;

async function track(cycleId, agent, symbol, fn) {
  const db = getDB();
  const startedAt = new Date().toISOString();
  const { lastInsertRowid: id } = db.prepare('INSERT INTO agent_runs (cycle_id, agent, symbol, status, started_at) VALUES (?, ?, ?, ?, ?)')
    .run(cycleId, agent, symbol, 'running', startedAt);
  try {
    const out = await fn();
    db.prepare("UPDATE agent_runs SET status='ok', output=?, finished_at=? WHERE id=?").run(JSON.stringify(out), new Date().toISOString(), id);
    return out;
  } catch (err) {
    db.prepare("UPDATE agent_runs SET status='error', output=?, finished_at=? WHERE id=?").run(JSON.stringify({ error: err.message }), new Date().toISOString(), id);
    log.error(agent, `${symbol || ''} ล้มเหลว: ${err.message}`);
    throw err;
  }
}

function control() {
  return { tradingEnabled: getState('trading_enabled', true), halted: getState('halted', null) };
}

async function runCycle() {
  if (running) { log.warn('orchestrator', 'รอบก่อนยังไม่เสร็จ — ข้าม'); return { skipped: true }; }
  running = true;
  const cycleId = new Date().toISOString();
  const summary = [];
  try {
    log.info('orchestrator', `เริ่ม cycle ${cycleId} (${config.mode}) สัญลักษณ์: ${config.symbols.join(', ')}`);

    // 1) Market Data + News ทำงานขนานกัน
    const [marketResults, news] = await Promise.all([
      Promise.allSettled(config.symbols.map(s => track(cycleId, 'market-data', s, () => marketAgent.run(s)))),
      track(cycleId, 'news', null, () => newsAgent.run()).catch(err => newsAgent.neutral(`News agent error: ${err.message}`)),
    ]);

    const markets = {};
    marketResults.forEach((r, i) => { if (r.status === 'fulfilled') markets[config.symbols[i]] = r.value; });

    // 2) อัพเดท paper positions (SL/TP) ก่อนตัดสินใจรอบใหม่
    broker.updatePaperPositions(markets);
    const prices = Object.fromEntries(Object.values(markets).map(m => [m.symbol, m.price]));
    const account = broker.getAccount(prices);
    broker.recordEquity(account);

    // 3) Strategy → Risk → Execute ทีละสัญลักษณ์ (ตามลำดับ เพื่อให้ Risk เห็น position ที่เพิ่งเปิด)
    for (const symbol of config.symbols) {
      const market = markets[symbol];
      if (!market) { summary.push({ symbol, result: 'ไม่มีข้อมูลราคา' }); continue; }

      let signal;
      try {
        signal = await track(cycleId, 'strategy', symbol, () => strategyAgent.run({
          market, news, hasOpenPosition: account.openPositions.some(p => p.symbol === symbol),
        }));
      } catch (err) {
        signal = { action: 'HOLD', confidence: 0, reasoning: `Strategy error → HOLD เพื่อความปลอดภัย: ${err.message}`, engine: 'error' };
      }

      const decision = await track(cycleId, 'risk-manager', symbol, async () =>
        riskAgent.evaluate({ signal, market, news, account, control: control() }));

      if (decision.halt) {
        setState('halted', decision.halt);
        log.error('risk-manager', `หยุดเทรดอัตโนมัติ: ${decision.halt}`);
      }

      const o = decision.order || {};
      const { lastInsertRowid: signalId } = getDB().prepare(`
        INSERT INTO signals (cycle_id, symbol, action, confidence, entry_ref, sl_distance, tp_distance, sl, tp, lot, risk_pct, reasoning, decision, reject_reason)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
        cycleId, symbol, signal.action, signal.confidence ?? null, market.price,
        o.slDistance ?? null, o.tpDistance ?? null, o.sl ?? null, o.tp ?? null, o.lot ?? null, o.riskPct ?? null,
        JSON.stringify({ engine: signal.engine, reasoning: signal.reasoning, key_factors: signal.key_factors }),
        decision.approved ? 'approved' : 'rejected', decision.reason || null);

      if (decision.approved) {
        broker.execute(signalId, decision.order);
        account.openPositions.push({ symbol }); // กันเปิดเกิน maxOpenPositions ในรอบเดียวกัน
        summary.push({ symbol, result: `${o.side} ${o.lot} lot` });
      } else {
        summary.push({ symbol, result: `${signal.action} → ไม่เทรด: ${decision.reason}` });
      }
    }

    setState('last_cycle', { id: cycleId, finishedAt: new Date().toISOString(), summary });
    log.info('orchestrator', `จบ cycle ${cycleId}`, summary);
    return { cycleId, summary };
  } finally {
    running = false;
  }
}

module.exports = { runCycle, isRunning: () => running };
