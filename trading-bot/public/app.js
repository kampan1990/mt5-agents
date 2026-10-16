const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmt = (n, d = 2) => (n == null ? '-' : Number(n).toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d }));

function getToken() { try { return localStorage.getItem('adminToken') || ''; } catch { return ''; } }
function setToken(t) { try { localStorage.setItem('adminToken', t); } catch { /* ignore */ } }

async function api(path, opts = {}) {
  const res = await fetch(path, { ...opts, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${getToken()}` } });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

let state = null;

function renderStatus(s) {
  state = s;
  $('meta').innerHTML = `โหมด <span class="pill ${s.mode === 'LIVE' ? 'bad' : 'ok'}">${s.mode}</span> · ` +
    `${s.llmEnabled ? esc(s.model) : 'rule-based (ไม่มี API key)'} · ${esc(s.symbols.join(', '))} · TF ${esc(s.timeframe)} · cron "${esc(s.schedule)}"` +
    (s.mockData ? ' · <span class="warn">MOCK DATA</span>' : '') +
    (s.halted ? ` · <span class="bad">HALTED: ${esc(s.halted)}</span>` : '') +
    (!s.tradingEnabled ? ' · <span class="bad">ปิดการเทรด</span>' : '');
  $('btnToggle').textContent = s.tradingEnabled ? '⏸ ปิดการเทรด' : '▶ เปิดการเทรด';

  const a = s.account;
  const dd = a.peakEquity > 0 ? ((a.peakEquity - a.equity) / a.peakEquity) * 100 : 0;
  $('account').innerHTML = [
    ['Balance', fmt(a.balance)], ['Equity', fmt(a.equity)],
    ['Drawdown', `<span class="${dd >= s.risk.maxDrawdownPct * 0.7 ? 'bad' : ''}">${fmt(dd)}%</span> / ${s.risk.maxDrawdownPct}%`],
    ['Positions', `${a.openPositions.length} / ${s.risk.maxOpenPositions}`],
    ['Risk/trade', `${s.risk.riskPerTradePct}%`],
    ['MT5', s.mode === 'LIVE' ? (a.connected ? '<span class="ok">เชื่อมต่อ</span>' : '<span class="bad">ขาดการเชื่อมต่อ</span>') : '<span class="muted">ไม่ใช้ (PAPER)</span>'],
  ].map(([k, v]) => `<div class="stat"><span class="muted">${k}</span><b>${v}</b></div>`).join('');

  const names = { 'market-data': '📈 Market Data', news: '📰 News/Sentiment', strategy: '🧠 Strategy', 'risk-manager': '🛡️ Risk Manager' };
  $('agents').innerHTML = Object.keys(names).map(k => {
    const r = s.agents.find(x => x.agent === k);
    const cls = !r ? 'muted' : r.status === 'ok' ? 'ok' : r.status === 'error' ? 'bad' : 'warn';
    const detail = !r ? 'ยังไม่เคยรัน' : r.status === 'error' ? esc(r.output?.error) : esc(`${r.symbol || ''} ${new Date(r.finished_at || r.started_at).toLocaleTimeString()}`);
    return `<div class="agent"><span>${names[k]}</span><span class="${cls}">${r ? r.status : '-'}</span></div><div class="reason">${detail}</div>`;
  }).join('') + (s.lastCycle ? `<p class="muted">รอบล่าสุด: ${new Date(s.lastCycle.finishedAt).toLocaleString()}</p>` : '');
}

function renderSignals(rows) {
  $('signals').innerHTML = rows.map(r => {
    const cls = r.action === 'BUY' ? 'ok' : r.action === 'SELL' ? 'bad' : 'muted';
    const result = r.decision === 'approved' ? `<span class="ok">✓ ${esc(r.exec_status)}</span>${r.exec_error ? `<div class="bad">${esc(r.exec_error)}</div>` : ''}` : `<span class="muted">✗ ${esc(r.reject_reason)}</span>`;
    const why = r.reasoning?.reasoning ? `<b>${esc(r.reasoning.engine)}</b>: ${esc(r.reasoning.reasoning)}` : '';
    return `<tr><td>${esc(new Date(r.created_at + 'Z').toLocaleString())}</td><td>${esc(r.symbol)}</td><td class="${cls}">${esc(r.action)}</td>
      <td>${fmt(r.confidence)}</td><td>${r.lot ?? '-'}</td><td>${r.sl ? `${fmt(r.sl, 5)} / ${fmt(r.tp, 5)}` : '-'}</td>
      <td>${result}</td><td class="reason">${why}</td></tr>`;
  }).join('') || '<tr><td colspan="8" class="muted">ยังไม่มีสัญญาณ</td></tr>';
}

function renderPositions({ open, closed }) {
  const row = p => `<tr><td>${esc(new Date(p.opened_at + 'Z').toLocaleString())}</td><td>${esc(p.symbol)}</td><td class="${p.side === 'BUY' ? 'ok' : 'bad'}">${p.side}</td>
    <td>${p.lot}</td><td>${fmt(p.entry, 5)}</td><td>${fmt(p.sl, 5)}</td><td>${fmt(p.tp, 5)}</td>
    <td>${p.closed_at ? esc(p.close_reason) : '<span class="warn">เปิดอยู่</span>'}</td><td class="${p.pnl > 0 ? 'ok' : p.pnl < 0 ? 'bad' : ''}">${p.pnl == null ? '-' : fmt(p.pnl)}</td></tr>`;
  $('positions').innerHTML = [...open, ...closed].map(row).join('') ||
    `<tr><td colspan="9" class="muted">${state?.mode === 'LIVE' ? 'โหมด LIVE: ดู position จริงใน MT5' : 'ยังไม่มี position'}</td></tr>`;
}

function renderEquity(points) {
  const c = $('chart'), ctx = c.getContext('2d');
  const w = c.width = c.clientWidth * devicePixelRatio, h = c.height = 160 * devicePixelRatio;
  ctx.clearRect(0, 0, w, h);
  if (points.length < 2) { ctx.fillStyle = '#8b98a5'; ctx.font = `${12 * devicePixelRatio}px system-ui`; ctx.fillText('ยังมีข้อมูลไม่พอ', 10, 20 * devicePixelRatio); return; }
  const vals = points.map(p => p.equity), min = Math.min(...vals), max = Math.max(...vals), pad = (max - min) * 0.1 || 1;
  ctx.strokeStyle = '#58a6ff'; ctx.lineWidth = 2 * devicePixelRatio; ctx.beginPath();
  vals.forEach((v, i) => {
    const x = (i / (vals.length - 1)) * w, y = h - ((v - min + pad) / (max - min + 2 * pad)) * h;
    i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
  });
  ctx.stroke();
}

function renderLogs(rows) {
  const cls = { error: 'bad', warn: 'warn', trade: 'ok' };
  $('logs').innerHTML = rows.slice(0, 60).map(l => `<tr><td class="muted">${esc(new Date(l.ts + 'Z').toLocaleTimeString())}</td>
    <td class="${cls[l.level] || ''}">${esc(l.level)}</td><td>${esc(l.source)}</td><td>${esc(l.message)}</td></tr>`).join('');
}

async function refresh() {
  try {
    const [s, sig, pos, eq, logs] = await Promise.all([api('/api/status'), api('/api/signals'), api('/api/positions'), api('/api/equity'), api('/api/logs')]);
    renderStatus(s); renderSignals(sig); renderPositions(pos); renderEquity(eq); renderLogs(logs);
  } catch (err) { $('meta').textContent = `โหลดข้อมูลไม่ได้: ${err.message}`; }
}

async function action(fn) {
  try { await fn(); } catch (err) { alert(err.message); }
  refresh();
}

$('btnToken').onclick = () => { const t = prompt('ADMIN_TOKEN', getToken()); if (t !== null) setToken(t.trim()); };
$('btnRun').onclick = () => action(async () => { $('btnRun').disabled = true; try { await api('/api/control/run', { method: 'POST' }); } finally { $('btnRun').disabled = false; } });
$('btnToggle').onclick = () => action(() => api('/api/control/trading', { method: 'POST', body: JSON.stringify({ enabled: !state?.tradingEnabled }) }));
$('btnReset').onclick = () => confirm('รีเซ็ต halt และเริ่มนับ drawdown ใหม่?') && action(() => api('/api/control/reset-halt', { method: 'POST' }));

refresh();
setInterval(refresh, 15000);
