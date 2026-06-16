const { middleware, messagingApi } = require('@line/bot-sdk');
const express = require('express');
const { getDB } = require('./database');
const { calcDayIncome, generateDailyText, generate15DayText } = require('./report');

const router = express.Router();

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

async function handleMessage(event, client) {
  const db = getDB();
  const settings = getSettings();
  const text = (event.message?.text || '').trim();

  if (text === 'ช่วยเหลือ' || text === 'help' || text === '?') {
    return client.replyMessage({
      replyToken: event.replyToken,
      messages: [{ type: 'text', text: '📋 คำสั่งที่ใช้ได้:\n\nสรุปวันนี้ – ดูสรุปงานวันนี้\nสรุป 15 วัน – ดูรายงานรายได้ 15 วัน\nหยุด – บันทึกวันนี้เป็นวันหยุด' }]
    });
  }

  if (text === 'หยุด') {
    const today = todayStr();
    const existing = db.prepare('SELECT id FROM deliveries WHERE date = ?').get(today);
    if (existing) db.prepare('UPDATE deliveries SET is_holiday = 1 WHERE date = ?').run(today);
    else db.prepare('INSERT INTO deliveries (date, is_holiday) VALUES (?, 1)').run(today);
    return client.replyMessage({
      replyToken: event.replyToken,
      messages: [{ type: 'text', text: `✅ บันทึกวันที่ ${today} เป็น วันหยุด แล้ว` }]
    });
  }

  if (text === 'สรุปวันนี้' || text === 'สรุป') {
    const today = todayStr();
    const delivery = db.prepare('SELECT * FROM deliveries WHERE date = ?').get(today);
    if (!delivery) {
      return client.replyMessage({
        replyToken: event.replyToken,
        messages: [{ type: 'text', text: `❌ ยังไม่มีข้อมูลวันที่ ${today}` }]
      });
    }
    delivery.floor_deliveries = JSON.parse(delivery.floor_deliveries || '[]');
    return client.replyMessage({
      replyToken: event.replyToken,
      messages: [{ type: 'text', text: generateDailyText(delivery, settings) }]
    });
  }

  if (text === 'สรุป 15 วัน' || text === 'สรุป15วัน') {
    const { start, end } = getLast15DayRange();
    const deliveries = db.prepare('SELECT * FROM deliveries WHERE date BETWEEN ? AND ? ORDER BY date ASC').all(start, end);
    deliveries.forEach(d => { d.floor_deliveries = JSON.parse(d.floor_deliveries || '[]'); });
    return client.replyMessage({
      replyToken: event.replyToken,
      messages: [{ type: 'text', text: generate15DayText(deliveries, settings, start, end) }]
    });
  }

  return client.replyMessage({
    replyToken: event.replyToken,
    messages: [{ type: 'text', text: 'พิมพ์ "ช่วยเหลือ" เพื่อดูคำสั่งทั้งหมด 📋' }]
  });
}

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
} else {
  router.post('/', (req, res) => {
    res.json({ error: 'LINE Bot: ยังไม่ได้ตั้งค่า LINE_CHANNEL_ACCESS_TOKEN ใน .env' });
  });
  console.log('⚠️  LINE Bot: ยังไม่ได้ตั้งค่า');
}

module.exports = router;
