const { middleware, messagingApi } = require('@line/bot-sdk');
const express = require('express');
const Anthropic = require('@anthropic-ai/sdk');
const { getDB } = require('./database');
const { calcDayIncome, generateDailyText, generate15DayText } = require('./report');

const router = express.Router();

// ── Helpers ──────────────────────────────────────────────────────────────────

function getSettings() {
  const db = getDB();
  const rows = db.prepare('SELECT * FROM settings').all();
  const s = {};
  rows.forEach(r => { try { s[r.key] = JSON.parse(r.value); } catch { s[r.key] = r.value; } });
  return s;
}

function todayStr() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}

function getLast15DayRange() {
  const end = new Date(); end.setDate(end.getDate() - 1);
  const start = new Date(end); start.setDate(start.getDate() - 14);
  return {
    start: start.toISOString().split('T')[0],
    end: end.toISOString().split('T')[0]
  };
}

// Format income summary text
function incomeText(inc) {
  return `💰 เหมาจ่าย: ${inc.km.toLocaleString()} ฿${inc.fl ? '\n🏢 ยกชั้น: ' + inc.fl.toLocaleString() + ' ฿' : ''}${inc.tl ? '\n🛣️ ด่วน: ' + inc.tl.toLocaleString() + ' ฿' : ''}\n✅ รวม: ${inc.tot.toLocaleString()} ฿`;
}

// ── Claude AI Parser ─────────────────────────────────────────────────────────

const anthropic = process.env.ANTHROPIC_API_KEY
  ? new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY })
  : null;

async function parseDeliveryMessage(text) {
  if (!anthropic) return null;

  const today = todayStr();
  const prompt = `วิเคราะห์ข้อความรายงานงานส่งของ NITORI นี้และแปลงเป็น JSON:

ข้อความ: "${text}"

ดึงข้อมูลต่อไปนี้:
- date: วันที่ (YYYY-MM-DD, ถ้าไม่ระบุให้ใช้ ${today})
- zone: เขตหรืออำเภอที่วิ่งงาน (string)
- province: จังหวัดที่วิ่งงาน (string)
- point_count: จำนวนจุดส่ง (number 1-8)
- distance: ระยะกิโล (number)
- floor_deliveries: ชั้นที่ยกขึ้น array เช่น [{"floor":3,"count":2},{"floor":4,"count":1}]
  - "ยกชั้น3 บ้านที่2กับ4" = floor 3, count 2
  - "ยกชั้น4 1บ้าน" = floor 4, count 1
  - "ไม่มียก" หรือ "0" = []
- toll_fee: ค่าทางด่วนรวม (number, 0 ถ้าไม่มี)
- is_holiday: วันหยุด (boolean)
- notes: หมายเหตุอื่นๆ (string)

ตัวอย่างข้อความ:
- "บางรัก/กทม 5จุด ยกชั้น3 บ้านที่2กับ4 ค่าด่วน90"
- "วิ่งลาดพร้าว กทม 8จุด 120กม ไม่มียก ด่วน60"
- "สมุทรปราการ 6จุด ชั้น3×2บ้าน ชั้น4×1บ้าน ด่วน0"
- "หยุด" หรือ "วันนี้หยุด"

ตอบเฉพาะ JSON เท่านั้น ไม่ต้องอธิบาย หากข้อความไม่เกี่ยวกับงานส่งให้ตอบ {"not_delivery": true}`;

  try {
    const response = await anthropic.messages.create({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 500,
      messages: [{ role: 'user', content: prompt }]
    });
    const raw = response.content[0].text.trim();
    const json = raw.replace(/```json\n?|\n?```/g, '').trim();
    return JSON.parse(json);
  } catch (err) {
    console.error('Claude parse error:', err.message);
    return null;
  }
}

// Fallback: simple regex parser (no Claude needed)
function regexParseDelivery(text) {
  const t = text.toLowerCase();

  // Check holiday
  if (/หยุด|วันหยุด/.test(t)) return { is_holiday: true, date: todayStr() };

  // Check if delivery-related
  const deliveryKeywords = /วิ่ง|ส่งงาน|จุด|กิโล|กม|ด่วน|ยกชั้น|เขต|อำเภอ/;
  if (!deliveryKeywords.test(t)) return null;

  const result = { date: todayStr(), floor_deliveries: [] };

  // Zone/Province - pattern: "xxx/yyy" or "เขตxxx จังหวัดyyy"
  const zoneProv = text.match(/([ก-๙a-zA-Z]+)\s*[\/,]\s*([ก-๙a-zA-Z]+)/);
  if (zoneProv) { result.zone = zoneProv[1]; result.province = zoneProv[2]; }

  // Points
  const pts = text.match(/(\d+)\s*จุด/);
  if (pts) result.point_count = parseInt(pts[1]);

  // Distance
  const dist = text.match(/(\d+(?:\.\d+)?)\s*(?:กิโล|กม\.?|km)/i);
  if (dist) result.distance = parseFloat(dist[1]);

  // Toll fee
  const toll = text.match(/(?:ด่วน|ทางด่วน|toll)\s*[:=]?\s*(\d+)/i);
  if (toll) result.toll_fee = parseInt(toll[1]);

  // Floor deliveries - "ยกชั้น3 2บ้าน" or "ชั้น3×2" or "ชั้น3 บ้านที่1กับ2"
  const floorMatches = [...text.matchAll(/(?:ยก)?ชั้น\s*(\d+)[×x\s]*(\d+)?(?:\s*บ้าน)?/g)];
  floorMatches.forEach(m => {
    const floor = parseInt(m[1]);
    const count = m[2] ? parseInt(m[2]) : 1;
    if (floor >= 3) result.floor_deliveries.push({ floor, count });
  });

  // "บ้านที่2กับ4" style with a floor mentioned before
  const houseWith = text.match(/ชั้น\s*(\d+)\s*บ้านที่(.+?)(?:\s|$)/);
  if (houseWith && result.floor_deliveries.length === 0) {
    const floor = parseInt(houseWith[1]);
    const houses = houseWith[2].split(/กับ|และ|,/).length;
    result.floor_deliveries.push({ floor, count: houses });
  }

  return Object.keys(result).length > 2 ? result : null;
}

// ── Pending confirmations (in-memory) ────────────────────────────────────────
// Key: userId, Value: { parsed, timestamp }
const pendingConfirm = new Map();

function buildConfirmText(parsed) {
  if (parsed.is_holiday) return `📋 บันทึกวันหยุดวันที่ ${parsed.date} ใช่ไหม?\n\nตอบ "ใช่" เพื่อยืนยัน หรือ "ไม่" เพื่อยกเลิก`;

  const flTxt = (parsed.floor_deliveries || []).length
    ? (parsed.floor_deliveries || []).map(f => `ชั้น${f.floor}×${f.count||1}บ้าน`).join(', ')
    : 'ไม่มี';

  return `📦 บันทึกงานวันที่ ${parsed.date} ใช่ไหม?\n` +
    `──────────────────\n` +
    `🗺️ เขต: ${parsed.zone || '-'}${parsed.province ? ' / ' + parsed.province : ''}\n` +
    `📍 จุด: ${parsed.point_count || '-'} จุด\n` +
    `🛣️ กม.: ${parsed.distance || '-'} กม.\n` +
    `🏢 ยกชั้น: ${flTxt}\n` +
    `🧾 ด่วน: ${(parsed.toll_fee || 0).toLocaleString()} ฿\n` +
    `──────────────────\n` +
    `ตอบ "ใช่" เพื่อบันทึก | "ไม่" เพื่อยกเลิก`;
}

function saveDelivery(parsed) {
  const db = getDB();
  const floorJson = JSON.stringify(parsed.floor_deliveries || []);
  const holiday = parsed.is_holiday ? 1 : 0;
  const date = parsed.date || todayStr();

  const existing = db.prepare('SELECT id FROM deliveries WHERE date = ?').get(date);
  if (existing) {
    db.prepare(`UPDATE deliveries SET zone=?,province=?,point_count=?,distance=?,floor_deliveries=?,toll_fee=?,notes=?,is_holiday=? WHERE id=?`)
      .run(parsed.zone||'', parsed.province||'', parseInt(parsed.point_count)||0,
        parseFloat(parsed.distance)||0, floorJson, parseFloat(parsed.toll_fee)||0,
        parsed.notes||'', holiday, existing.id);
    return existing.id;
  } else {
    const r = db.prepare(`INSERT INTO deliveries (date,zone,province,point_count,distance,floor_deliveries,toll_fee,notes,is_holiday) VALUES (?,?,?,?,?,?,?,?,?)`)
      .run(date, parsed.zone||'', parsed.province||'', parseInt(parsed.point_count)||0,
        parseFloat(parsed.distance)||0, floorJson, parseFloat(parsed.toll_fee)||0,
        parsed.notes||'', holiday);
    return r.lastInsertRowid;
  }
}

// ── Message handler ───────────────────────────────────────────────────────────

async function handleMessage(event, client) {
  const db = getDB();
  const settings = getSettings();
  const userId = event.source.userId;
  const text = (event.message?.text || '').trim();
  const lower = text.toLowerCase();

  // ── Commands ──────────────────────────────────────────────────────────────

  if (lower === 'ช่วยเหลือ' || lower === 'help') {
    return client.replyMessage({
      replyToken: event.replyToken,
      messages: [{ type: 'text', text: `📋 คำสั่งบอท NITORI\n\n🔹 ส่งข้อมูลงาน:\nพิมพ์รายงานในกลุ่มเลย เช่น\n"บางรัก/กทม 5จุด 120กม ยกชั้น3 2บ้าน ด่วน90"\nบอทจะถามยืนยันก่อนบันทึก\n\n🔹 คำสั่งอื่น:\nสรุปวันนี้ – ดูสรุปงานวันนี้\nสรุป 15 วัน – ดูรายได้\nหยุด – บันทึกวันหยุด\n\n⚙️ บอทอ่านข้อความอัตโนมัติเฉพาะที่เกี่ยวกับงาน` }]
    });
  }

  // ── Check for pending confirmation ───────────────────────────────────────

  const pending = pendingConfirm.get(userId);
  if (pending && (Date.now() - pending.timestamp < 5 * 60 * 1000)) { // 5 min timeout
    if (lower === 'ใช่' || lower === 'yes' || lower === 'ยืนยัน' || lower === 'ok' || lower === 'ตกลง') {
      const id = saveDelivery(pending.parsed);
      pendingConfirm.delete(userId);

      let replyText = `✅ บันทึกแล้ว! วันที่ ${pending.parsed.date}`;
      if (!pending.parsed.is_holiday) {
        const savedDel = db.prepare('SELECT * FROM deliveries WHERE id = ?').get(id);
        if (savedDel) {
          savedDel.floor_deliveries = JSON.parse(savedDel.floor_deliveries || '[]');
          const inc = calcDayIncome(savedDel, settings);
          const fuelLabel = { r0:'24-27',r1:'27-30',r2:'30-33',r3:'33-36',r4:'36-39',r5:'39-42' }[settings.current_fuel_col || 'r5'];
          replyText += `\n\n${incomeText(inc)}\n\n⛽ เรท ${fuelLabel} บาท/ลิตร`;
        }
      }

      return client.replyMessage({ replyToken: event.replyToken, messages: [{ type: 'text', text: replyText }] });
    }

    if (lower === 'ไม่' || lower === 'no' || lower === 'ยกเลิก' || lower === 'cancel') {
      pendingConfirm.delete(userId);
      return client.replyMessage({ replyToken: event.replyToken, messages: [{ type: 'text', text: '❌ ยกเลิกแล้ว ไม่ได้บันทึก' }] });
    }
  }

  // ── Commands ──────────────────────────────────────────────────────────────

  if (lower === 'สรุปวันนี้' || lower === 'สรุป') {
    const today = todayStr();
    const delivery = db.prepare('SELECT * FROM deliveries WHERE date = ?').get(today);
    if (!delivery) {
      return client.replyMessage({ replyToken: event.replyToken, messages: [{ type: 'text', text: `❌ ยังไม่มีข้อมูลวันที่ ${today}` }] });
    }
    delivery.floor_deliveries = JSON.parse(delivery.floor_deliveries || '[]');
    return client.replyMessage({ replyToken: event.replyToken, messages: [{ type: 'text', text: generateDailyText(delivery, settings) }] });
  }

  if (lower === 'สรุป 15 วัน' || lower === 'สรุป15วัน') {
    const { start, end } = getLast15DayRange();
    const deliveries = db.prepare('SELECT * FROM deliveries WHERE date BETWEEN ? AND ? ORDER BY date ASC').all(start, end);
    deliveries.forEach(d => { d.floor_deliveries = JSON.parse(d.floor_deliveries || '[]'); });
    return client.replyMessage({ replyToken: event.replyToken, messages: [{ type: 'text', text: generate15DayText(deliveries, settings, start, end) }] });
  }

  if (lower === 'หยุด') {
    const today = todayStr();
    pendingConfirm.set(userId, { parsed: { is_holiday: true, date: today }, timestamp: Date.now() });
    return client.replyMessage({
      replyToken: event.replyToken,
      messages: [{ type: 'text', text: buildConfirmText({ is_holiday: true, date: today }) }]
    });
  }

  // ── Auto-parse delivery message ───────────────────────────────────────────

  // Try Claude first, fallback to regex
  let parsed = anthropic ? await parseDeliveryMessage(text) : regexParseDelivery(text);

  // If Claude says not delivery, try regex as fallback
  if (parsed?.not_delivery) parsed = null;
  if (!parsed) parsed = regexParseDelivery(text);

  if (parsed && !parsed.not_delivery) {
    // Store pending confirmation
    pendingConfirm.set(userId, { parsed, timestamp: Date.now() });
    return client.replyMessage({
      replyToken: event.replyToken,
      messages: [{ type: 'text', text: buildConfirmText(parsed) }]
    });
  }

  // Not recognized — only reply if direct message (not group), to avoid spam
  if (event.source.type === 'user') {
    return client.replyMessage({
      replyToken: event.replyToken,
      messages: [{ type: 'text', text: 'พิมพ์ "ช่วยเหลือ" เพื่อดูคำสั่ง 📋\n\nหรือส่งข้อมูลงาน เช่น\n"บางรัก/กทม 5จุด 120กม ด่วน90"' }]
    });
  }
}

// ── Setup LINE Bot ────────────────────────────────────────────────────────────

if (process.env.LINE_CHANNEL_ACCESS_TOKEN && process.env.LINE_CHANNEL_SECRET) {
  const lineConfig = {
    channelAccessToken: process.env.LINE_CHANNEL_ACCESS_TOKEN,
    channelSecret: process.env.LINE_CHANNEL_SECRET
  };
  const client = new messagingApi.MessagingApiClient(lineConfig);
  const mw = middleware(lineConfig);

  router.post('/', mw, (req, res) => {
    Promise.all(
      req.body.events
        .filter(e => e.type === 'message' && e.message?.type === 'text')
        .map(e => handleMessage(e, client))
    )
      .then(() => res.json({ ok: true }))
      .catch(err => { console.error('LINE error:', err.message); res.status(500).end(); });
  });

  console.log('✅ LINE Bot webhook ready at /webhook');
  if (anthropic) console.log('✅ Claude AI parser active');
  else console.log('⚠️  Claude AI: ไม่ได้ตั้งค่า ANTHROPIC_API_KEY (จะใช้ regex parser แทน)');

} else {
  router.post('/', (req, res) => {
    res.json({ error: 'LINE Bot: ยังไม่ได้ตั้งค่า LINE_CHANNEL_ACCESS_TOKEN ใน .env' });
  });
  console.log('⚠️  LINE Bot: ยังไม่ได้ตั้งค่า');
}

module.exports = router;
