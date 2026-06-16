require('dotenv').config();
const express = require('express');
const multer = require('multer');
const cors = require('cors');
const path = require('path');
const fs = require('fs');
const cron = require('node-cron');

const { initDB, getDB } = require('./src/database');
const { sendDailyReport, send15DayReport } = require('./src/email');
const { generateDailyReportHTML, generate15DaySummaryHTML, calcDayIncome } = require('./src/report');
const lineBotRouter = require('./src/lineBot');

const app = express();
const PORT = process.env.PORT || 3000;

// Ensure uploads dir
if (!fs.existsSync('uploads')) fs.mkdirSync('uploads');

// Multer storage
const storage = multer.diskStorage({
  destination: (_, __, cb) => cb(null, 'uploads/'),
  filename: (_, file, cb) => {
    cb(null, `${Date.now()}-${Math.random().toString(36).slice(2)}${path.extname(file.originalname)}`);
  }
});
const upload = multer({ storage, limits: { fileSize: 15 * 1024 * 1024 } });

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));
app.use('/uploads', express.static(path.join(__dirname, 'uploads')));

initDB();

// ── Helpers ──────────────────────────────────────────────
function getSettings() {
  const db = getDB();
  const rows = db.prepare('SELECT * FROM settings').all();
  const s = {};
  rows.forEach(r => { try { s[r.key] = JSON.parse(r.value); } catch { s[r.key] = r.value; } });
  return s;
}

function enrichDelivery(d) {
  if (!d) return null;
  const db = getDB();
  d.floor_deliveries = JSON.parse(d.floor_deliveries || '[]');
  d.photos = db.prepare('SELECT * FROM photos WHERE delivery_id = ?').all(d.id);
  return d;
}

// ── Deliveries API ────────────────────────────────────────

app.get('/api/deliveries', (req, res) => {
  const db = getDB();
  const { start, end } = req.query;
  let rows;
  if (start && end) {
    rows = db.prepare('SELECT * FROM deliveries WHERE date BETWEEN ? AND ? ORDER BY date DESC').all(start, end);
  } else {
    rows = db.prepare('SELECT * FROM deliveries ORDER BY date DESC LIMIT 60').all();
  }
  res.json(rows.map(enrichDelivery));
});

app.get('/api/deliveries/:id', (req, res) => {
  const db = getDB();
  const d = db.prepare('SELECT * FROM deliveries WHERE id = ?').get(req.params.id);
  if (!d) return res.status(404).json({ error: 'ไม่พบข้อมูล' });
  res.json(enrichDelivery(d));
});

app.post('/api/deliveries', upload.array('photos', 30), (req, res) => {
  const db = getDB();
  const { date, zone, province, point_count, distance, floor_deliveries, toll_fee, notes, is_holiday } = req.body;

  const floorJson = typeof floor_deliveries === 'string' ? floor_deliveries : JSON.stringify(floor_deliveries || []);
  const holiday = is_holiday === 'true' || is_holiday === true || is_holiday === '1' ? 1 : 0;

  // Upsert by date
  const existing = db.prepare('SELECT id FROM deliveries WHERE date = ?').get(date);
  let deliveryId;

  if (existing) {
    db.prepare(`UPDATE deliveries SET zone=?,province=?,point_count=?,distance=?,floor_deliveries=?,toll_fee=?,notes=?,is_holiday=? WHERE id=?`)
      .run(zone||'', province||'', parseInt(point_count)||0, parseFloat(distance)||0, floorJson, parseFloat(toll_fee)||0, notes||'', holiday, existing.id);
    deliveryId = existing.id;
  } else {
    const r = db.prepare(`INSERT INTO deliveries (date,zone,province,point_count,distance,floor_deliveries,toll_fee,notes,is_holiday) VALUES (?,?,?,?,?,?,?,?,?)`)
      .run(date, zone||'', province||'', parseInt(point_count)||0, parseFloat(distance)||0, floorJson, parseFloat(toll_fee)||0, notes||'', holiday);
    deliveryId = r.lastInsertRowid;
  }

  if (req.files?.length) {
    const ps = db.prepare('INSERT INTO photos (delivery_id, point_name, file_path) VALUES (?,?,?)');
    req.files.forEach((f, i) => ps.run(deliveryId, `จุดที่ ${i+1}`, `/uploads/${f.filename}`));
  }

  res.json({ success: true, delivery: enrichDelivery(db.prepare('SELECT * FROM deliveries WHERE id=?').get(deliveryId)) });
});

app.put('/api/deliveries/:id', upload.array('photos', 30), (req, res) => {
  const db = getDB();
  const { date, zone, province, point_count, distance, floor_deliveries, toll_fee, notes, is_holiday } = req.body;
  const floorJson = typeof floor_deliveries === 'string' ? floor_deliveries : JSON.stringify(floor_deliveries || []);
  const holiday = is_holiday === 'true' || is_holiday === true ? 1 : 0;

  db.prepare(`UPDATE deliveries SET date=?,zone=?,province=?,point_count=?,distance=?,floor_deliveries=?,toll_fee=?,notes=?,is_holiday=? WHERE id=?`)
    .run(date, zone||'', province||'', parseInt(point_count)||0, parseFloat(distance)||0, floorJson, parseFloat(toll_fee)||0, notes||'', holiday, req.params.id);

  if (req.files?.length) {
    const ps = db.prepare('INSERT INTO photos (delivery_id, point_name, file_path) VALUES (?,?,?)');
    req.files.forEach((f, i) => ps.run(req.params.id, `จุดที่ ${i+1}`, `/uploads/${f.filename}`));
  }

  res.json({ success: true });
});

app.delete('/api/deliveries/:id', (req, res) => {
  const db = getDB();
  const photos = db.prepare('SELECT file_path FROM photos WHERE delivery_id=?').all(req.params.id);
  photos.forEach(p => {
    const fp = path.join(__dirname, p.file_path.replace(/^\//, ''));
    if (fs.existsSync(fp)) fs.unlinkSync(fp);
  });
  db.prepare('DELETE FROM photos WHERE delivery_id=?').run(req.params.id);
  db.prepare('DELETE FROM deliveries WHERE id=?').run(req.params.id);
  res.json({ success: true });
});

app.delete('/api/photos/:id', (req, res) => {
  const db = getDB();
  const photo = db.prepare('SELECT * FROM photos WHERE id=?').get(req.params.id);
  if (photo) {
    const fp = path.join(__dirname, photo.file_path.replace(/^\//, ''));
    if (fs.existsSync(fp)) fs.unlinkSync(fp);
    db.prepare('DELETE FROM photos WHERE id=?').run(req.params.id);
  }
  res.json({ success: true });
});

// ── Settings API ──────────────────────────────────────────

app.get('/api/settings', (req, res) => res.json(getSettings()));

app.post('/api/settings', (req, res) => {
  const db = getDB();
  const stmt = db.prepare('INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)');
  Object.entries(req.body).forEach(([k, v]) => stmt.run(k, typeof v === 'string' ? v : JSON.stringify(v)));
  res.json({ success: true });
});

// ── Report API ────────────────────────────────────────────

app.get('/api/reports/daily/:date', (req, res) => {
  const db = getDB();
  const d = db.prepare('SELECT * FROM deliveries WHERE date=?').get(req.params.date);
  if (!d) return res.status(404).json({ error: 'ไม่พบข้อมูล' });
  enrichDelivery(d);
  const settings = getSettings();
  res.json({ html: generateDailyReportHTML(d, settings), income: calcDayIncome(d, settings), delivery: d });
});

app.post('/api/reports/send-daily', async (req, res) => {
  const db = getDB();
  const { date } = req.body;
  const d = db.prepare('SELECT * FROM deliveries WHERE date=?').get(date);
  if (!d) return res.status(404).json({ error: 'ไม่พบข้อมูล' });
  enrichDelivery(d);
  try {
    await sendDailyReport(d, getSettings());
    db.prepare('UPDATE deliveries SET report_sent=1 WHERE date=?').run(date);
    res.json({ success: true, message: `ส่งรายงานวันที่ ${date} สำเร็จ ✅` });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/reports/summary', (req, res) => {
  const db = getDB();
  const { start, end } = req.query;
  const settings = getSettings();
  const deliveries = db.prepare('SELECT * FROM deliveries WHERE date BETWEEN ? AND ? ORDER BY date ASC').all(start, end);
  deliveries.forEach(enrichDelivery);

  let totalIncome = 0, totalDays = 0, totalDistance = 0, totalPoints = 0;
  const days = deliveries.map(d => {
    const inc = calcDayIncome(d, settings);
    if (!d.is_holiday) {
      totalIncome += inc.total;
      totalDays++;
      totalDistance += d.distance || 0;
      totalPoints += d.point_count || 0;
    }
    return { ...d, income: inc };
  });

  const taxRate = parseFloat(settings.tax_rate) || 0.01;
  const tax = totalIncome * taxRate;
  res.json({
    days,
    totalIncome,
    totalDays,
    totalDistance,
    totalPoints,
    tax,
    netIncome: totalIncome - tax,
    html: generate15DaySummaryHTML(deliveries, settings, start, end)
  });
});

app.post('/api/reports/send-summary', async (req, res) => {
  const db = getDB();
  const { start, end } = req.body;
  const settings = getSettings();
  const deliveries = db.prepare('SELECT * FROM deliveries WHERE date BETWEEN ? AND ? ORDER BY date ASC').all(start, end);
  deliveries.forEach(enrichDelivery);
  try {
    await send15DayReport(deliveries, settings, start, end);
    res.json({ success: true, message: `ส่งสรุปรายได้ ${start} – ${end} สำเร็จ ✅` });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── LINE Webhook ──────────────────────────────────────────
app.use('/webhook', lineBotRouter);

// ── Scheduled Jobs ────────────────────────────────────────
// Auto send 15-day report on day 16 and day 1 at 10 PM
cron.schedule('0 22 1,16 * *', async () => {
  const settings = getSettings();
  if (!settings.auto_report_15day || settings.auto_report_15day === 'false') return;
  const db = getDB();
  const end = new Date();
  end.setDate(end.getDate() - 1);
  const start = new Date(end);
  start.setDate(start.getDate() - 14);
  const s = start.toISOString().split('T')[0];
  const e = end.toISOString().split('T')[0];
  const deliveries = db.prepare('SELECT * FROM deliveries WHERE date BETWEEN ? AND ? ORDER BY date ASC').all(s, e);
  deliveries.forEach(enrichDelivery);
  try {
    await send15DayReport(deliveries, settings, s, e);
    console.log(`✅ Auto 15-day report sent: ${s} – ${e}`);
  } catch (err) {
    console.error('❌ Auto 15-day report failed:', err.message);
  }
});

app.listen(PORT, () => {
  console.log(`\n🚀 Delivery Report App`);
  console.log(`   เปิดแอพ: http://localhost:${PORT}`);
  console.log(`   LINE webhook: http://localhost:${PORT}/webhook\n`);
});
