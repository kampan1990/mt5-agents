const nodemailer = require('nodemailer');
const { generateDailyReportHTML, generate15DaySummaryHTML } = require('./report');

function createTransport(settings) {
  return nodemailer.createTransport({
    host: process.env.SMTP_HOST || 'smtp.gmail.com',
    port: parseInt(process.env.SMTP_PORT) || 587,
    secure: false,
    auth: {
      user: process.env.SMTP_USER || settings.sender_email,
      pass: process.env.SMTP_PASS || settings.smtp_password
    }
  });
}

async function sendDailyReport(delivery, settings) {
  const bossEmail = settings.boss_email;
  if (!bossEmail) throw new Error('ยังไม่ได้ตั้งค่าอีเมล์หัวหน้า');

  const transport = createTransport(settings);
  const html = generateDailyReportHTML(delivery, settings);
  const dateLabel = delivery.date;

  const subject = delivery.is_holiday
    ? `📋 รายงานวันหยุด ${dateLabel}`
    : `📦 รายงานจัดส่ง ${dateLabel} – ${delivery.zone || ''}`;

  await transport.sendMail({
    from: `"${settings.sender_name || 'ระบบรายงาน'}" <${process.env.SMTP_USER || settings.sender_email}>`,
    to: bossEmail,
    subject,
    html
  });

  return true;
}

async function send15DayReport(deliveries, settings, startDate, endDate) {
  const bossEmail = settings.boss_email;
  if (!bossEmail) throw new Error('ยังไม่ได้ตั้งค่าอีเมล์หัวหน้า');

  const transport = createTransport(settings);
  const html = generate15DaySummaryHTML(deliveries, settings, startDate, endDate);

  await transport.sendMail({
    from: `"${settings.sender_name || 'ระบบรายงาน'}" <${process.env.SMTP_USER || settings.sender_email}>`,
    to: bossEmail,
    subject: `💰 สรุปรายได้ ${startDate} – ${endDate}`,
    html
  });

  return true;
}

module.exports = { sendDailyReport, send15DayReport };
