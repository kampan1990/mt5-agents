// Execution layer
// PAPER: จำลองพอร์ตใน DB (เปิด/ปิด position ตาม SL/TP)
// LIVE : สร้างคำสั่ง pending ให้ EA บน MT5 ดึงไปเปิด order จริง แล้วรายงานผลกลับมา
const config = require('./config');
const { getDB, getState, setState } = require('./db');
const log = require('./logger');

const today = () => new Date().toISOString().slice(0, 10);

function valuePerUnit(symbol, price) {
  const spec = config.symbolSpecs[symbol];
  return spec.quoteIsJPY ? spec.valuePerUnit / price : spec.valuePerUnit;
}

// ---------- Account snapshot (ใช้โดย Risk Manager) ----------

function openPaperPositions() {
  return getDB().prepare('SELECT * FROM positions WHERE closed_at IS NULL').all();
}

function getAccount(lastPrices = {}) {
  if (config.mode === 'LIVE') {
    const hb = getState('ea_heartbeat');
    const fresh = hb && (Date.now() - hb.receivedAt) / 1000 < config.eaHeartbeatStaleSec;
    const acc = {
      connected: Boolean(fresh),
      balance: hb?.balance || 0,
      equity: hb?.equity || 0,
      openPositions: hb?.positions || [],
    };
    // นับคำสั่งที่ส่งไปแล้วแต่ EA ยังไม่ยืนยัน เป็น position ด้วย กันเปิดซ้ำ
    const inflight = getDB().prepare("SELECT symbol FROM signals WHERE decision='approved' AND exec_status IN ('pending','sent')").all();
    acc.openPositions = [...acc.openPositions, ...inflight];
    return withPeaks(acc);
  }

  const balance = getState('paper_balance', config.paperStartBalance);
  const positions = openPaperPositions();
  const unrealized = positions.reduce((sum, p) => {
    const px = lastPrices[p.symbol];
    if (px == null) return sum;
    const dir = p.side === 'BUY' ? 1 : -1;
    return sum + dir * (px - p.entry) * p.lot * valuePerUnit(p.symbol, px);
  }, 0);
  return withPeaks({ connected: true, balance, equity: balance + unrealized, openPositions: positions });
}

function withPeaks(acc) {
  if (acc.equity > 0) {
    const peak = Math.max(getState('peak_equity', 0), acc.equity);
    setState('peak_equity', peak);
    let day = getState('day_start');
    if (!day || day.date !== today()) { day = { date: today(), equity: acc.equity }; setState('day_start', day); }
    acc.peakEquity = peak;
    acc.dayStartEquity = day.equity;
  } else {
    acc.peakEquity = 0; acc.dayStartEquity = 0;
  }
  return acc;
}

function recordEquity(acc) {
  if (acc.equity > 0) getDB().prepare('INSERT INTO equity (source, balance, equity) VALUES (?, ?, ?)').run(config.mode, acc.balance, acc.equity);
}

// ---------- Execute ----------

function execute(signalId, order) {
  const db = getDB();
  if (config.mode === 'LIVE') {
    db.prepare("UPDATE signals SET exec_status='pending', updated_at=datetime('now') WHERE id=?").run(signalId);
    log.trade('broker', `LIVE: คิวคำสั่ง #${signalId} ${order.side} ${order.symbol} รอ EA ดึงไปเปิด`, order);
    return;
  }
  const info = db.prepare('INSERT INTO positions (signal_id, symbol, side, lot, entry, sl, tp) VALUES (?, ?, ?, ?, ?, ?, ?)')
    .run(signalId, order.symbol, order.side, order.lot, order.entryRef, order.sl, order.tp);
  db.prepare("UPDATE signals SET exec_status='filled', exec_ticket=?, exec_price=?, updated_at=datetime('now') WHERE id=?")
    .run(`PAPER-${info.lastInsertRowid}`, order.entryRef, signalId);
  log.trade('broker', `PAPER: เปิด ${order.side} ${order.symbol} ${order.lot} lot @ ${order.entryRef} SL ${order.sl} TP ${order.tp}`, { signalId });
}

// PAPER: ตรวจ SL/TP ด้วย high/low ของแท่งล่าสุด (ถ้าแตะทั้งคู่ในแท่งเดียว ถือว่าโดน SL ก่อน — มองแง่ร้ายไว้ก่อน)
function updatePaperPositions(marketBySymbol) {
  if (config.mode !== 'PAPER') return;
  const db = getDB();
  for (const p of openPaperPositions()) {
    const m = marketBySymbol[p.symbol];
    if (!m) continue;
    const buy = p.side === 'BUY';
    const hitSL = buy ? m.lastLow <= p.sl : m.lastHigh >= p.sl;
    const hitTP = buy ? m.lastHigh >= p.tp : m.lastLow <= p.tp;
    if (!hitSL && !hitTP) continue;
    const exit = hitSL ? p.sl : p.tp;
    const pnl = (buy ? exit - p.entry : p.entry - exit) * p.lot * valuePerUnit(p.symbol, exit);
    db.prepare("UPDATE positions SET closed_at=datetime('now'), exit=?, pnl=?, close_reason=? WHERE id=?")
      .run(exit, pnl, hitSL ? 'SL' : 'TP', p.id);
    setState('paper_balance', getState('paper_balance', config.paperStartBalance) + pnl);
    log.trade('broker', `PAPER: ปิด ${p.side} ${p.symbol} ด้วย ${hitSL ? 'SL' : 'TP'} @ ${exit} PnL ${pnl.toFixed(2)}`, { positionId: p.id });
  }
}

// ---------- LIVE bridge (เรียกจาก EA) ----------

function nextOrdersForEA() {
  const db = getDB();
  // คำสั่งที่ค้างเกิน 10 นาทีถือว่าหมดอายุ — ราคาอาจเปลี่ยนไปมากแล้ว
  db.prepare("UPDATE signals SET exec_status='expired', updated_at=datetime('now') WHERE exec_status='pending' AND created_at < datetime('now', '-10 minutes')").run();
  const rows = db.prepare("SELECT * FROM signals WHERE exec_status='pending' ORDER BY id").all();
  const mark = db.prepare("UPDATE signals SET exec_status='sent', updated_at=datetime('now') WHERE id=?");
  rows.forEach(r => mark.run(r.id));
  return rows.map(r => ({
    id: r.id, symbol: r.symbol, side: r.action,
    sl_distance: r.sl_distance, tp_distance: r.tp_distance,
    risk_pct: r.risk_pct, lot_hint: r.lot, comment: `AI#${r.id}`,
  }));
}

function reportFromEA({ id, status, ticket, price, error }) {
  const ok = status === 'filled';
  getDB().prepare("UPDATE signals SET exec_status=?, exec_ticket=?, exec_price=?, exec_error=?, updated_at=datetime('now') WHERE id=? AND exec_status='sent'")
    .run(ok ? 'filled' : 'failed', ticket ? String(ticket) : null, price || null, error || null, id);
  (ok ? log.trade : log.error)('ea', `EA รายงานคำสั่ง #${id}: ${status}${error ? ` (${error})` : ''}`, { ticket, price });
}

function heartbeatFromEA({ balance, equity, positions }) {
  setState('ea_heartbeat', {
    balance: Number(balance), equity: Number(equity),
    positions: Array.isArray(positions) ? positions.map(p => ({ symbol: String(p.symbol), side: p.side, lot: p.lot, profit: p.profit })) : [],
    receivedAt: Date.now(),
  });
  // คำสั่งที่ EA ได้รับแล้วแต่ไม่รายงานภายใน 5 นาที → failed
  getDB().prepare("UPDATE signals SET exec_status='failed', exec_error='EA ไม่ยืนยันผล', updated_at=datetime('now') WHERE exec_status='sent' AND updated_at < datetime('now', '-5 minutes')").run();
}

module.exports = { getAccount, recordEquity, execute, updatePaperPositions, nextOrdersForEA, reportFromEA, heartbeatFromEA };
