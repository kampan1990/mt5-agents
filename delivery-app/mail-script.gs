// Google Apps Script สำหรับส่งอีเมล์รายงานให้หัวหน้าอัตโนมัติ (รองรับแนบหลายไฟล์ PDF)
// วิธีตั้งค่า (ทำครั้งเดียว):
// 1) เปิด script.google.com ด้วย Gmail ของคุณ -> New project -> วางโค้ดนี้แทนของเดิม
// 2) แก้ BOSS (อีเมล์หัวหน้า) และ TOKEN (รหัสลับที่คุณตั้งเอง) ด้านล่าง
// 3) เลือกฟังก์ชัน authorize แล้วกด Run -> อนุญาตสิทธิ์ส่งอีเมล์
// 4) Deploy -> New deployment -> Web app -> Execute as: Me, Who has access: Anyone -> Deploy
// 5) คัดลอก Web app URL ไปวางในหน้า "ตั้งค่า" ของแอป พร้อมรหัสลับเดียวกัน
// ถ้าแก้โค้ดภายหลัง: Deploy -> Manage deployments -> ไอคอนดินสอ -> Version: New version -> Deploy
const BOSS  = 'boss@example.com';
const TOKEN = 'ตั้งรหัสลับของคุณ';

function authorize() { MailApp.getRemainingDailyQuota(); }

function doPost(e) {
  try {
    const d = JSON.parse(e.postData.contents);
    if (d.token !== TOKEN) return out({ ok: false, error: 'token' });
    const list = Array.isArray(d.files) && d.files.length ? d.files : [{ filename: d.filename, pdf: d.pdf }];
    const attachments = list.map(function (f) {
      return Utilities.newBlob(Utilities.base64Decode(f.pdf), f.mime || 'application/pdf', f.filename);
    });
    MailApp.sendEmail({ to: BOSS, subject: d.subject, body: d.body, attachments: attachments });
    return out({ ok: true, n: attachments.length });
  } catch (err) {
    return out({ ok: false, error: String(err) });
  }
}

function out(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
