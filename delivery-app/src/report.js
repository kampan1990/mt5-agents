// Income calculation utilities

function calcKmIncome(distance, kmTiers) {
  if (!distance || distance <= 0) return 0;
  const tiers = Array.isArray(kmTiers) ? kmTiers : JSON.parse(kmTiers || '[]');
  for (const tier of tiers) {
    if (distance >= tier.min && distance <= tier.max) return tier.rate;
  }
  return 0;
}

// floor 3+ = (floor - 2) × 100 per trip
function calcFloorIncome(floorDeliveries) {
  if (!Array.isArray(floorDeliveries)) return 0;
  return floorDeliveries.reduce((sum, fd) => {
    const floor = parseInt(fd.floor) || 0;
    const count = parseInt(fd.count) || 1;
    if (floor < 3) return sum;
    return sum + (floor - 2) * 100 * count;
  }, 0);
}

function calcDayIncome(delivery, settings) {
  if (delivery.is_holiday) return { kmIncome: 0, floorIncome: 0, tollFee: 0, total: 0 };
  const kmTiers = typeof settings.km_tiers === 'string'
    ? JSON.parse(settings.km_tiers)
    : settings.km_tiers || [];
  const kmIncome = calcKmIncome(delivery.distance, kmTiers);
  const floorIncome = calcFloorIncome(delivery.floor_deliveries);
  const tollFee = parseFloat(delivery.toll_fee) || 0;
  return { kmIncome, floorIncome, tollFee, total: kmIncome + floorIncome + tollFee };
}

function findKmTierLabel(distance, kmTiers) {
  const tiers = Array.isArray(kmTiers) ? kmTiers : JSON.parse(kmTiers || '[]');
  for (const tier of tiers) {
    if (distance >= tier.min && distance <= tier.max) {
      return `${tier.min}-${tier.max === 999 ? '∞' : tier.max} กม. = ${tier.rate.toLocaleString()} บาท`;
    }
  }
  return '-';
}

function formatDate(dateStr) {
  const d = new Date(dateStr);
  const days = ['อาทิตย์','จันทร์','อังคาร','พุธ','พฤหัส','ศุกร์','เสาร์'];
  const months = ['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.','ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'];
  return `${days[d.getDay()]}ที่ ${d.getDate()} ${months[d.getMonth()]} ${d.getFullYear() + 543}`;
}

function generateDailyReportHTML(delivery, settings) {
  const { kmIncome, floorIncome, tollFee, total } = calcDayIncome(delivery, settings);
  const kmTiers = typeof settings.km_tiers === 'string' ? JSON.parse(settings.km_tiers) : settings.km_tiers || [];
  const driverName = settings.driver_name || 'คนขับ';

  if (delivery.is_holiday) {
    return `
<html><head><meta charset="UTF-8">
<style>
  body { font-family: 'Sarabun', sans-serif; margin: 0; background: #f5f5f5; }
  .card { background: white; max-width: 600px; margin: 20px auto; border-radius: 12px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
  .header { background: #6c757d; color: white; padding: 20px; text-align: center; }
  .body { padding: 24px; text-align: center; font-size: 18px; color: #555; }
</style></head><body>
<div class="card">
  <div class="header">
    <h2 style="margin:0">📋 รายงานประจำวัน</h2>
    <p style="margin:4px 0 0">${formatDate(delivery.date)}</p>
  </div>
  <div class="body">
    <p style="font-size:48px; margin:20px 0">🏖️</p>
    <p><strong>วันหยุด</strong></p>
    <p style="color:#888">ไม่มีการจัดส่งในวันนี้</p>
  </div>
</div></body></html>`;
  }

  const floorRows = (delivery.floor_deliveries || []).map(fd => {
    const income = (fd.floor - 2) * 100 * (fd.count || 1);
    return `<tr><td>ชั้น ${fd.floor} × ${fd.count || 1} ครั้ง</td><td style="text-align:right">${income.toLocaleString()} บาท</td></tr>`;
  }).join('');

  return `
<html><head><meta charset="UTF-8">
<style>
  body { font-family: 'Sarabun', Arial, sans-serif; margin: 0; background: #f0f4f8; }
  .card { background: white; max-width: 600px; margin: 20px auto; border-radius: 12px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.12); }
  .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 24px 20px; }
  .header h2 { margin: 0; font-size: 20px; }
  .header p { margin: 4px 0 0; opacity: 0.85; font-size: 14px; }
  .section { padding: 16px 24px; border-bottom: 1px solid #f0f0f0; }
  .section:last-child { border-bottom: none; }
  .section-title { font-size: 13px; color: #888; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 12px; }
  .info-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .info-item { }
  .info-label { font-size: 12px; color: #aaa; }
  .info-value { font-size: 16px; font-weight: 600; color: #333; margin-top: 2px; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  td { padding: 6px 0; }
  td:last-child { text-align: right; }
  .total-row { font-weight: 700; font-size: 16px; border-top: 2px solid #eee; padding-top: 10px; }
  .total-row td { padding-top: 12px; }
  .badge { display: inline-block; background: #e8f4fd; color: #0073b1; font-size: 12px; padding: 2px 8px; border-radius: 10px; }
  .total-amount { font-size: 24px; font-weight: 800; color: #2d7d46; }
</style></head><body>
<div class="card">
  <div class="header">
    <h2>📦 รายงานการจัดส่ง</h2>
    <p>${formatDate(delivery.date)} · ${driverName}</p>
  </div>

  <div class="section">
    <div class="section-title">สรุปงานวันนี้</div>
    <div class="info-grid">
      <div class="info-item">
        <div class="info-label">เขต / จังหวัด</div>
        <div class="info-value">${delivery.zone || '-'}${delivery.province ? ' / ' + delivery.province : ''}</div>
      </div>
      <div class="info-item">
        <div class="info-label">จำนวนจุดส่ง</div>
        <div class="info-value">${delivery.point_count || 0} จุด</div>
      </div>
      <div class="info-item">
        <div class="info-label">ระยะทาง</div>
        <div class="info-value">${delivery.distance || 0} กม.</div>
      </div>
      <div class="info-item">
        <div class="info-label">ค่าทางด่วน</div>
        <div class="info-value">${(tollFee || 0).toLocaleString()} บาท</div>
      </div>
    </div>
    ${delivery.notes ? `<p style="margin:12px 0 0; font-size:13px; color:#666">📝 ${delivery.notes}</p>` : ''}
  </div>

  <div class="section">
    <div class="section-title">รายละเอียดรายได้</div>
    <table>
      <tr>
        <td>เหมาจ่ายระยะทาง <span class="badge">${findKmTierLabel(delivery.distance, kmTiers)}</span></td>
        <td>${kmIncome.toLocaleString()} บาท</td>
      </tr>
      ${floorRows}
      <tr>
        <td>ค่าทางด่วน</td>
        <td>${tollFee.toLocaleString()} บาท</td>
      </tr>
      <tr class="total-row">
        <td>รวมรายได้วันนี้</td>
        <td class="total-amount">${total.toLocaleString()} ฿</td>
      </tr>
    </table>
  </div>
</div></body></html>`;
}

function generate15DaySummaryHTML(deliveries, settings, startDate, endDate) {
  const kmTiers = typeof settings.km_tiers === 'string' ? JSON.parse(settings.km_tiers) : settings.km_tiers || [];
  const taxRate = parseFloat(settings.tax_rate) || 0.01;
  const driverName = settings.driver_name || 'คนขับ';

  let totalKmIncome = 0, totalFloorIncome = 0, totalToll = 0, totalDays = 0, totalDistance = 0, totalPoints = 0;
  let holidayCount = 0;

  const rows = deliveries.map(d => {
    if (d.is_holiday) {
      holidayCount++;
      return `<tr style="background:#f8f8f8">
        <td>${formatDate(d.date).replace(/อาทิตย์ที่|จันทร์ที่|อังคาร์ที่|พุธที่|พฤหัสที่|ศุกร์ที่|เสาร์ที่/, '')}</td>
        <td colspan="5" style="text-align:center; color:#999">🏖️ วันหยุด</td>
        <td style="text-align:right; color:#999">-</td>
      </tr>`;
    }

    const { kmIncome, floorIncome, tollFee, total } = calcDayIncome(d, settings);
    totalKmIncome += kmIncome;
    totalFloorIncome += floorIncome;
    totalToll += tollFee;
    totalDays++;
    totalDistance += d.distance || 0;
    totalPoints += d.point_count || 0;

    const floorText = (d.floor_deliveries || []).map(f => `ชั้น${f.floor}×${f.count||1}`).join(', ') || '-';

    return `<tr>
      <td>${new Date(d.date).toLocaleDateString('th-TH', {day:'2-digit', month:'2-digit'})}</td>
      <td>${d.zone || '-'}${d.province ? '<br><small style="color:#888">' + d.province + '</small>' : ''}</td>
      <td style="text-align:center">${d.point_count || 0}</td>
      <td style="text-align:center">${d.distance || 0}</td>
      <td style="text-align:center; font-size:12px">${floorText}</td>
      <td style="text-align:right">${(tollFee).toLocaleString()}</td>
      <td style="text-align:right; font-weight:600; color:#2d7d46">${total.toLocaleString()}</td>
    </tr>`;
  }).join('');

  const totalIncome = totalKmIncome + totalFloorIncome + totalToll;
  const tax = totalIncome * taxRate;
  const netIncome = totalIncome - tax;

  const start = new Date(startDate);
  const end = new Date(endDate);
  const startTH = `${start.getDate()}/${start.getMonth()+1}/${start.getFullYear()+543}`;
  const endTH = `${end.getDate()}/${end.getMonth()+1}/${end.getFullYear()+543}`;

  return `
<html><head><meta charset="UTF-8">
<style>
  body { font-family: 'Sarabun', Arial, sans-serif; margin: 0; background: #f0f4f8; }
  .card { background: white; max-width: 720px; margin: 20px auto; border-radius: 12px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.12); }
  .header { background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%); color: white; padding: 24px 20px; }
  .header h2 { margin: 0; font-size: 20px; }
  .header p { margin: 4px 0 0; opacity: 0.85; font-size: 14px; }
  .stats { display: flex; gap: 0; border-bottom: 1px solid #eee; }
  .stat { flex: 1; padding: 16px; text-align: center; border-right: 1px solid #eee; }
  .stat:last-child { border-right: none; }
  .stat-value { font-size: 22px; font-weight: 800; color: #333; }
  .stat-label { font-size: 11px; color: #999; margin-top: 2px; }
  .table-wrap { overflow-x: auto; padding: 16px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { background: #f8f9fa; padding: 10px 8px; text-align: left; font-size: 12px; color: #666; font-weight: 600; border-bottom: 2px solid #eee; }
  td { padding: 9px 8px; border-bottom: 1px solid #f5f5f5; }
  .income-section { padding: 20px 24px; background: #f8f9fa; }
  .income-row { display: flex; justify-content: space-between; padding: 6px 0; font-size: 14px; color: #555; }
  .income-total { display: flex; justify-content: space-between; padding: 12px 0 6px; font-size: 18px; font-weight: 800; color: #333; border-top: 2px solid #ddd; margin-top: 6px; }
  .income-tax { display: flex; justify-content: space-between; padding: 4px 0; font-size: 14px; color: #e74c3c; }
  .income-net { display: flex; justify-content: space-between; padding: 10px 16px; font-size: 20px; font-weight: 800; color: white; background: linear-gradient(135deg, #2d7d46, #34a85a); border-radius: 8px; margin-top: 10px; }
</style></head><body>
<div class="card">
  <div class="header">
    <h2>💰 สรุปรายได้ 15 วัน</h2>
    <p>${startTH} – ${endTH} · ${driverName}</p>
  </div>

  <div class="stats">
    <div class="stat">
      <div class="stat-value">${totalDays}</div>
      <div class="stat-label">วันที่วิ่ง</div>
    </div>
    <div class="stat">
      <div class="stat-value">${totalDistance.toLocaleString()}</div>
      <div class="stat-label">กม. รวม</div>
    </div>
    <div class="stat">
      <div class="stat-value">${totalPoints}</div>
      <div class="stat-label">จุดส่งรวม</div>
    </div>
    <div class="stat">
      <div class="stat-value">${holidayCount}</div>
      <div class="stat-label">วันหยุด</div>
    </div>
  </div>

  <div class="table-wrap">
    <table>
      <thead>
        <tr>
          <th>วันที่</th>
          <th>เขต/จังหวัด</th>
          <th style="text-align:center">จุด</th>
          <th style="text-align:center">กม.</th>
          <th style="text-align:center">ยกชั้น</th>
          <th style="text-align:right">ด่วน</th>
          <th style="text-align:right">รายได้</th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
    </table>
  </div>

  <div class="income-section">
    <div class="income-row"><span>เหมาจ่ายระยะทาง</span><span>${totalKmIncome.toLocaleString()} บาท</span></div>
    <div class="income-row"><span>ยกของขึ้นชั้น</span><span>${totalFloorIncome.toLocaleString()} บาท</span></div>
    <div class="income-row"><span>ค่าทางด่วนรวม</span><span>${totalToll.toLocaleString()} บาท</span></div>
    <div class="income-total"><span>รวมรายได้</span><span>${totalIncome.toLocaleString()} บาท</span></div>
    <div class="income-tax"><span>หัก ณ ที่จ่าย ${(taxRate * 100).toFixed(0)}%</span><span>- ${tax.toLocaleString('th-TH', {minimumFractionDigits:2})} บาท</span></div>
    <div class="income-net"><span>รับสุทธิ</span><span>${netIncome.toLocaleString('th-TH', {minimumFractionDigits:2})} ฿</span></div>
  </div>
</div></body></html>`;
}

// Plain text for LINE message
function generateDailyText(delivery, settings) {
  if (delivery.is_holiday) {
    return `📋 รายงานวันที่ ${delivery.date}\n🏖️ วันหยุด`;
  }
  const { kmIncome, floorIncome, tollFee, total } = calcDayIncome(delivery, settings);
  const floorText = (delivery.floor_deliveries || []).map(f => `ชั้น${f.floor}×${f.count||1}ครั้ง`).join(', ') || 'ไม่มี';

  return `📦 รายงานจัดส่ง ${delivery.date}
──────────────────
🗺️ เขต: ${delivery.zone || '-'} ${delivery.province ? '/ ' + delivery.province : ''}
📍 จำนวนจุด: ${delivery.point_count || 0} จุด
🛣️ ระยะทาง: ${delivery.distance || 0} กม.
🏢 ยกของขึ้นชั้น: ${floorText}
🛣️ ค่าทางด่วน: ${tollFee.toLocaleString()} บาท
──────────────────
💰 เหมาจ่าย: ${kmIncome.toLocaleString()} บาท
💪 ยกชั้น: ${floorIncome.toLocaleString()} บาท
🛣️ ด่วน: ${tollFee.toLocaleString()} บาท
✅ รวม: ${total.toLocaleString()} บาท`;
}

function generate15DayText(deliveries, settings, startDate, endDate) {
  let totalIncome = 0;
  let lines = deliveries.map(d => {
    if (d.is_holiday) return `${d.date}: 🏖️ หยุด`;
    const { total } = calcDayIncome(d, settings);
    totalIncome += total;
    return `${d.date}: ${d.zone || '-'} ${d.point_count}จุด ${d.distance}กม. = ${total.toLocaleString()}฿`;
  });

  const tax = totalIncome * (parseFloat(settings.tax_rate) || 0.01);
  return `💰 สรุปรายได้ ${startDate} – ${endDate}\n──────────────────\n${lines.join('\n')}\n──────────────────\nรวม: ${totalIncome.toLocaleString()} บาท\nหัก 1%: ${tax.toLocaleString('th-TH', {minimumFractionDigits:2})} บาท\nรับสุทธิ: ${(totalIncome - tax).toLocaleString('th-TH', {minimumFractionDigits:2})} บาท`;
}

module.exports = {
  calcDayIncome,
  calcKmIncome,
  calcFloorIncome,
  generateDailyReportHTML,
  generate15DaySummaryHTML,
  generateDailyText,
  generate15DayText,
  formatDate
};
