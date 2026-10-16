const path = require('path');
const crypto = require('crypto');
const express = require('express');
const cron = require('node-cron');

const config = require('./src/config');
const { initDB, getDB, getState, setState } = require('./src/db');
const log = require('./src/logger');
const broker = require('./src/broker');
const orchestrator = require('./src/orchestrator');

initDB();

const app = express();
app.use(express.json({ limit: '100kb' }));
app.use(express.static(path.join(__dirname, 'public')));

const safeEqual = (a, b) => {
  const x = Buffer.from(String(a || '')), y = Buffer.from(String(b || ''));
  return x.length === y.length && x.length > 0 && crypto.timingSafeEqual(x, y);
};
const tokenFrom = req => (req.get('authorization') || '').replace(/^Bearer\s+/i, '') || req.get('x-token');

function requireAdmin(req, res, next) {
  if (!config.adminToken) return res.status(503).json({ error: 'ยังไม่ได้ตั้ง ADMIN_TOKEN' });
  if (!safeEqual(tokenFrom(req), config.adminToken)) return res.status(401).json({ error: 'unauthorized' });
  next();
}
function requireEA(req, res, next) {
  if (!config.eaToken) return res.status(503).json({ error: 'ยังไม่ได้ตั้ง EA_TOKEN' });
  if (!safeEqual(tokenFrom(req), config.eaToken)) return res.status(401).json({ error: 'unauthorized' });
  next();
}

const parseJSON = s => { try { return JSON.parse(s); } catch { return s; } };

// ── Dashboard API (อ่านอย่างเดียว) ─────────────────────────
app.get('/api/status', (req, res) => {
  const db = getDB();
  const latestRuns = db.prepare(`
    SELECT a.* FROM agent_runs a
    JOIN (SELECT agent, MAX(id) id FROM agent_runs GROUP BY agent) m ON a.id = m.id`).all()
    .map(r => ({ ...r, output: parseJSON(r.output) }));
  res.json({
    mode: config.mode,
    model: config.model,
    llmEnabled: Boolean(config.anthropicApiKey),
    mockData: config.mockData,
    symbols: config.symbols,
    timeframe: config.timeframe,
    schedule: config.schedule,
    risk: config.risk,
    tradingEnabled: getState('trading_enabled', true),
    halted: getState('halted', null),
    running: orchestrator.isRunning(),
    lastCycle: getState('last_cycle', null),
    eaHeartbeat: getState('ea_heartbeat', null),
    account: broker.getAccount(),
    agents: latestRuns,
  });
});

app.get('/api/signals', (req, res) => {
  const rows = getDB().prepare('SELECT * FROM signals ORDER BY id DESC LIMIT ?').all(Math.min(Number(req.query.limit) || 50, 500));
  res.json(rows.map(r => ({ ...r, reasoning: parseJSON(r.reasoning) })));
});

app.get('/api/positions', (req, res) => {
  const db = getDB();
  res.json({
    open: db.prepare('SELECT * FROM positions WHERE closed_at IS NULL ORDER BY id DESC').all(),
    closed: db.prepare('SELECT * FROM positions WHERE closed_at IS NOT NULL ORDER BY id DESC LIMIT 100').all(),
  });
});

app.get('/api/equity', (req, res) => {
  res.json(getDB().prepare('SELECT ts, balance, equity FROM equity ORDER BY id DESC LIMIT 500').all().reverse());
});

app.get('/api/logs', (req, res) => {
  res.json(getDB().prepare('SELECT * FROM logs ORDER BY id DESC LIMIT 200').all());
});

// ── Admin controls ─────────────────────────────────────────
app.post('/api/control/run', requireAdmin, async (req, res) => {
  if (orchestrator.isRunning()) return res.status(409).json({ error: 'cycle กำลังทำงานอยู่' });
  try { res.json(await orchestrator.runCycle()); }
  catch (err) { res.status(500).json({ error: err.message }); }
});

app.post('/api/control/trading', requireAdmin, (req, res) => {
  const enabled = Boolean(req.body?.enabled);
  setState('trading_enabled', enabled);
  log.warn('control', `Kill switch: ${enabled ? 'เปิด' : 'ปิด'}การเทรด`);
  res.json({ tradingEnabled: enabled });
});

app.post('/api/control/reset-halt', requireAdmin, (req, res) => {
  setState('halted', null);
  // เริ่มนับ drawdown ใหม่จาก equity ปัจจุบัน
  setState('peak_equity', 0);
  log.warn('control', 'รีเซ็ตสถานะหยุดเทรด (halt) และ peak equity');
  res.json({ ok: true });
});

// ── MT5 EA bridge ─────────────────────────────────────────
app.post('/api/ea/heartbeat', requireEA, (req, res) => {
  broker.heartbeatFromEA(req.body || {});
  res.json({ ok: true, tradingEnabled: getState('trading_enabled', true) && !getState('halted', null) });
});

app.get('/api/ea/orders', requireEA, (req, res) => {
  if (config.mode !== 'LIVE' || !getState('trading_enabled', true) || getState('halted', null)) return res.json({ orders: [] });
  res.json({ orders: broker.nextOrdersForEA() });
});

app.post('/api/ea/report', requireEA, (req, res) => {
  const { id, status } = req.body || {};
  if (!Number.isInteger(id) || !['filled', 'failed'].includes(status)) return res.status(400).json({ error: 'ต้องมี id (int) และ status (filled|failed)' });
  broker.reportFromEA(req.body);
  res.json({ ok: true });
});

app.get('/healthz', (req, res) => res.json({ ok: true }));

// ── Scheduler ─────────────────────────────────────────────
if (!cron.validate(config.schedule)) throw new Error(`CYCLE_CRON ไม่ถูกต้อง: ${config.schedule}`);
cron.schedule(config.schedule, () => orchestrator.runCycle().catch(err => log.error('orchestrator', err.message)));

app.listen(config.port, () => {
  log.info('server', `AI Trading Bot พร้อมที่ http://localhost:${config.port} | mode=${config.mode} | LLM=${config.anthropicApiKey ? config.model : 'ปิด (ใช้ rule-based)'} | cron="${config.schedule}"`);
  if (!config.adminToken) log.warn('server', 'ยังไม่ได้ตั้ง ADMIN_TOKEN — ปุ่มควบคุมบน dashboard จะใช้ไม่ได้');
  if (config.mode === 'LIVE' && !config.eaToken) log.warn('server', 'โหมด LIVE แต่ยังไม่ได้ตั้ง EA_TOKEN — EA จะเชื่อมต่อไม่ได้');
});
