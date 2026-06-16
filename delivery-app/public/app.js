/* ── Global State ── */
let settings = {};
let historyYear = new Date().getFullYear();
let historyMonth = new Date().getMonth(); // 0-based
let pendingPhotos = []; // {file, url} new photos not yet uploaded
let existingPhotos = []; // {id, file_path} from server

/* ── NITORI Rate Table ── */
const NITORI_TABLE = [
  {min:0,   max:20,  r0:2535,r1:3195,r2:3195,r3:3365,r4:3466,r5:3570},
  {min:21,  max:40,  r0:2545,r1:3195,r2:3195,r3:3365,r4:3466,r5:3570},
  {min:41,  max:60,  r0:2555,r1:3195,r2:3195,r3:3365,r4:3466,r5:3570},
  {min:61,  max:80,  r0:2565,r1:3195,r2:3195,r3:3365,r4:3466,r5:3570},
  {min:81,  max:100, r0:2585,r1:3195,r2:3195,r3:3365,r4:3466,r5:3570},
  {min:101, max:120, r0:2675,r1:3195,r2:3195,r3:3365,r4:3466,r5:3570},
  {min:121, max:140, r0:2755,r1:3195,r2:3195,r3:3365,r4:3466,r5:3570},
  {min:141, max:160, r0:2865,r1:3195,r2:3195,r3:3365,r4:3466,r5:3570},
  {min:161, max:180, r0:2965,r1:3305,r2:3305,r3:3365,r4:3466,r5:3570},
  {min:181, max:200, r0:3065,r1:3382,r2:3382,r3:3485,r4:3541,r5:3645},
  {min:201, max:220, r0:3165,r1:3482,r2:3482,r3:3560,r4:3641,r5:3745},
  {min:221, max:240, r0:3275,r1:3582,r2:3582,r3:3660,r4:3741,r5:3845},
  {min:241, max:260, r0:3395,r1:3682,r2:3682,r3:3760,r4:3841,r5:3945},
  {min:261, max:280, r0:3505,r1:3782,r2:3782,r3:3860,r4:3941,r5:4045},
  {min:281, max:300, r0:3615,r1:3882,r2:3882,r3:3960,r4:4041,r5:4145},
  {min:301, max:320, r0:3745,r1:3982,r2:3982,r3:4060,r4:4141,r5:4245},
  {min:321, max:340, r0:3865,r1:4082,r2:4082,r3:4160,r4:4241,r5:4345},
  {min:341, max:360, r0:3955,r1:4182,r2:4182,r3:4260,r4:4341,r5:4445},
  {min:361, max:380, r0:4095,r1:4282,r2:4282,r3:4360,r4:4441,r5:4545},
  {min:381, max:400, r0:4225,r1:4382,r2:4382,r3:4460,r4:4541,r5:4645},
  {min:401, max:420, r0:4325,r1:4482,r2:4482,r3:4560,r4:4641,r5:4745},
  {min:421, max:440, r0:4465,r1:4582,r2:4582,r3:4660,r4:4741,r5:4845},
  {min:441, max:460, r0:4565,r1:4682,r2:4682,r3:4760,r4:4841,r5:4945},
  {min:461, max:480, r0:4645,r1:4782,r2:4782,r3:4860,r4:4941,r5:5045},
  {min:481, max:500, r0:4735,r1:4882,r2:4882,r3:4960,r4:5041,r5:5145},
  {min:501, max:520, r0:4805,r1:4982,r2:4982,r3:5060,r4:5141,r5:5245}
];

function getKmRate(distance, fuelCol) {
  const col = fuelCol || settings.current_fuel_col || 'r5';
  const row = NITORI_TABLE.find(r => distance >= r.min && distance <= r.max);
  return row ? row[col] : 0;
}

function calcFloorIncome(floorDeliveries) {
  return (floorDeliveries || []).reduce((sum, fd) => {
    const fl = parseInt(fd.floor) || 0;
    const cnt = parseInt(fd.count) || 1;
    return fl >= 3 ? sum + (fl - 2) * 100 * cnt : sum;
  }, 0);
}

function calcIncome(delivery) {
  if (delivery.is_holiday) return { km: 0, floor: 0, toll: 0, total: 0 };
  const km = getKmRate(parseFloat(delivery.distance) || 0);
  const floor = calcFloorIncome(delivery.floor_deliveries);
  const toll = parseFloat(delivery.toll_fee) || 0;
  return { km, floor, toll, total: km + floor + toll };
}

/* ── Toast ── */
function showToast(msg, type='') {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'show ' + type;
  clearTimeout(t._tid);
  t._tid = setTimeout(() => { t.className = ''; }, 3000);
}

/* ── Page navigation ── */
function showPage(name) {
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
  document.getElementById('page-' + name).classList.add('active');
  document.getElementById('nav-' + name).classList.add('active');

  if (name === 'home') loadHome();
  if (name === 'history') loadHistory();
  if (name === 'reports') initReports();
  if (name === 'settings') loadSettings();
  if (name === 'entry') initEntryForm();
}

/* ── Date helpers ── */
function todayStr() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}
function formatTH(dateStr) {
  const d = new Date(dateStr + 'T00:00:00');
  const days = ['อาทิตย์','จันทร์','อังคาร','พุธ','พฤหัส','ศุกร์','เสาร์'];
  const months = ['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.','ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'];
  return `${days[d.getDay()]}ที่ ${d.getDate()} ${months[d.getMonth()]} ${d.getFullYear()+543}`;
}

/* ── Home page ── */
async function loadHome() {
  const today = todayStr();
  document.getElementById('home-date').textContent = formatTH(today);

  // Today's data
  try {
    const res = await fetch(`/api/reports/daily/${today}`);
    if (res.ok) {
      const data = await res.json();
      renderTodaySummary(data);
    } else {
      renderTodaySummary(null);
    }
  } catch { renderTodaySummary(null); }

  // Month stats
  loadMonthStats();

  // Recent list
  loadRecent();
}

function renderTodaySummary(data) {
  const el = document.getElementById('today-summary');
  const actEl = document.getElementById('today-actions');

  if (!data) {
    el.innerHTML = `<div class="empty"><div class="icon">📋</div><p>ยังไม่มีข้อมูลวันนี้<br>กด "บันทึก" เพื่อเพิ่มข้อมูล</p></div>`;
    actEl.innerHTML = '';
    return;
  }

  const d = data.delivery;
  const inc = data.income;

  if (d.is_holiday) {
    el.innerHTML = `<div style="text-align:center;padding:20px"><span style="font-size:36px">🏖️</span><p style="margin-top:8px;font-weight:600">วันหยุด</p></div>`;
    actEl.innerHTML = '';
    return;
  }

  el.innerHTML = `
    <div class="income-row"><span class="label">เขต</span><span class="value">${d.zone || '-'} ${d.province ? '/ '+d.province : ''}</span></div>
    <div class="income-row"><span class="label">จำนวนจุด</span><span class="value">${d.point_count || 0} จุด</span></div>
    <div class="income-row"><span class="label">ระยะทาง</span><span class="value">${d.distance || 0} กม.</span></div>
    <div class="income-row income-total"><span class="label">รายได้วันนี้</span><span class="value" style="color:var(--success);font-size:18px">${(inc.total||0).toLocaleString()} ฿</span></div>
  `;

  actEl.innerHTML = `
    <button class="btn btn-outline btn-sm" onclick="editDelivery(${d.id})">✏️ แก้ไข</button>
    <button class="btn btn-primary btn-sm" onclick="sendDailyReport('${todayStr()}')">📧 ส่งรายงาน</button>
  `;
}

async function loadMonthStats() {
  const now = new Date();
  const start = `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-01`;
  const end = todayStr();
  try {
    const res = await fetch(`/api/reports/summary?start=${start}&end=${end}`);
    if (!res.ok) return;
    const data = await res.json();
    document.getElementById('stat-month-days').textContent = data.totalDays;
    document.getElementById('stat-month-income').textContent = (data.totalIncome||0).toLocaleString() + '฿';
    document.getElementById('stat-month-km').textContent = (data.totalDistance||0).toLocaleString();
    document.getElementById('stat-month-points').textContent = data.totalPoints;
  } catch {}
}

async function loadRecent() {
  try {
    const res = await fetch('/api/deliveries');
    const items = await res.json();
    const el = document.getElementById('recent-list');
    if (!items.length) {
      el.innerHTML = '<div class="empty"><p>ยังไม่มีข้อมูล</p></div>';
      return;
    }
    el.innerHTML = items.slice(0, 7).map(d => renderDeliveryItem(d)).join('');
  } catch { document.getElementById('recent-list').innerHTML = '<div class="empty"><p>โหลดข้อมูลไม่ได้</p></div>'; }
}

function renderDeliveryItem(d) {
  const dateObj = new Date(d.date + 'T00:00:00');
  const dateLabel = `${String(dateObj.getDate()).padStart(2,'0')}/${String(dateObj.getMonth()+1).padStart(2,'0')}`;
  if (d.is_holiday) {
    return `<div class="delivery-item" onclick="showDetailModal(${d.id})">
      <div class="delivery-date">${dateLabel}</div>
      <div class="delivery-holiday">🏖️ วันหยุด</div>
    </div>`;
  }
  const inc = calcIncome(d);
  return `<div class="delivery-item" onclick="showDetailModal(${d.id})">
    <div class="delivery-date">${dateLabel}</div>
    <div class="delivery-info">
      <div class="delivery-zone">${d.zone || '-'}${d.province ? ' / '+d.province : ''}</div>
      <div class="delivery-meta">${d.point_count||0} จุด · ${d.distance||0} กม.</div>
    </div>
    <div class="delivery-income">${inc.total.toLocaleString()}฿</div>
  </div>`;
}

/* ── Entry Form ── */
function initEntryForm(deliveryToEdit) {
  pendingPhotos = [];
  existingPhotos = [];

  if (deliveryToEdit) {
    document.getElementById('entry-title').textContent = '✏️ แก้ไขงาน';
    document.getElementById('entry-id').value = deliveryToEdit.id;
    document.getElementById('field-date').value = deliveryToEdit.date;
    document.getElementById('field-holiday').checked = !!deliveryToEdit.is_holiday;
    document.getElementById('field-zone').value = deliveryToEdit.zone || '';
    document.getElementById('field-province').value = deliveryToEdit.province || '';
    document.getElementById('field-points').value = deliveryToEdit.point_count || '';
    document.getElementById('field-distance').value = deliveryToEdit.distance || '';
    document.getElementById('field-toll').value = deliveryToEdit.toll_fee || '';
    document.getElementById('field-notes').value = deliveryToEdit.notes || '';
    existingPhotos = deliveryToEdit.photos || [];
    renderFloorList(deliveryToEdit.floor_deliveries || []);
    toggleHolidayFields();
    renderPhotoGrid();
    updateIncomePreview();
  } else {
    document.getElementById('entry-title').textContent = '📝 บันทึกงานวันนี้';
    document.getElementById('entry-id').value = '';
    document.getElementById('entry-form').reset();
    document.getElementById('field-date').value = todayStr();
    document.getElementById('field-holiday').checked = false;
    renderFloorList([]);
    renderPhotoGrid();
    toggleHolidayFields();
    document.getElementById('income-preview').style.display = 'none';
  }
}

function toggleHolidayFields() {
  const isHoliday = document.getElementById('field-holiday').checked;
  document.getElementById('work-fields').style.display = isHoliday ? 'none' : 'block';
}

/* ── Floor entries ── */
function renderFloorList(floors) {
  const el = document.getElementById('floor-list');
  el.innerHTML = floors.map((fd, i) => floorEntryHTML(fd.floor, fd.count, i)).join('');
}

function floorEntryHTML(floor, count, i) {
  return `<div class="floor-entry" id="fe-${i}">
    <span class="label">ชั้นที่</span>
    <input type="number" min="3" value="${floor||3}" style="width:70px" onchange="updateIncomePreview()" placeholder="3">
    <span class="label">จำนวน</span>
    <input type="number" min="1" value="${count||1}" style="width:60px" onchange="updateIncomePreview()" placeholder="1">
    <span class="label">ครั้ง</span>
    <button type="button" class="btn btn-danger btn-icon" onclick="removeFloor(${i})">✕</button>
  </div>`;
}

function addFloorEntry() {
  const list = document.getElementById('floor-list');
  const i = list.children.length;
  list.insertAdjacentHTML('beforeend', floorEntryHTML(3, 1, i));
  updateIncomePreview();
}

function removeFloor(i) {
  const el = document.getElementById('fe-' + i);
  if (el) el.remove();
  reindexFloors();
  updateIncomePreview();
}

function reindexFloors() {
  document.querySelectorAll('.floor-entry').forEach((el, i) => { el.id = 'fe-' + i; });
}

function getFloorDeliveries() {
  return Array.from(document.querySelectorAll('.floor-entry')).map(el => {
    const inputs = el.querySelectorAll('input');
    return { floor: parseInt(inputs[0].value) || 3, count: parseInt(inputs[1].value) || 1 };
  });
}

/* ── Income preview ── */
function updateIncomePreview() {
  const dist = parseFloat(document.getElementById('field-distance').value) || 0;
  const toll = parseFloat(document.getElementById('field-toll').value) || 0;
  const floors = getFloorDeliveries();
  const kmIncome = getKmRate(dist);
  const floorIncome = calcFloorIncome(floors);
  const total = kmIncome + floorIncome + toll;

  const preview = document.getElementById('income-preview');
  const rows = document.getElementById('income-rows');

  if (!dist && !toll && !floors.length) { preview.style.display = 'none'; return; }
  preview.style.display = 'block';

  const fuelLabel = document.getElementById('s-fuel-col')?.options[document.getElementById('s-fuel-col')?.selectedIndex]?.text || '';

  rows.innerHTML = `
    <div class="income-row"><span class="label">เหมาจ่าย (${dist} กม.)</span><span class="value">${kmIncome.toLocaleString()} ฿</span></div>
    ${floorIncome ? `<div class="income-row"><span class="label">ยกของขึ้นชั้น</span><span class="value">${floorIncome.toLocaleString()} ฿</span></div>` : ''}
    ${toll ? `<div class="income-row"><span class="label">ค่าทางด่วน</span><span class="value">${toll.toLocaleString()} ฿</span></div>` : ''}
    <div class="income-net"><span>รวมวันนี้</span><span>${total.toLocaleString()} ฿</span></div>
  `;
}

/* ── Photos ── */
function triggerCamera() {
  document.getElementById('photo-input').click();
}

function handlePhotos(input) {
  const files = Array.from(input.files);
  files.forEach(f => {
    pendingPhotos.push({ file: f, url: URL.createObjectURL(f) });
  });
  renderPhotoGrid();
  input.value = '';
}

function renderPhotoGrid() {
  const grid = document.getElementById('photo-grid');
  const existingHTML = existingPhotos.map((p, i) => `
    <div class="photo-item">
      <img src="${p.file_path}" loading="lazy">
      <button type="button" class="photo-delete" onclick="deleteExistingPhoto(${p.id}, ${i})">✕</button>
    </div>
  `).join('');
  const pendingHTML = pendingPhotos.map((p, i) => `
    <div class="photo-item">
      <img src="${p.url}">
      <button type="button" class="photo-delete" onclick="deletePendingPhoto(${i})">✕</button>
    </div>
  `).join('');
  grid.innerHTML = existingHTML + pendingHTML + `
    <div class="add-photo-btn" onclick="triggerCamera()">
      <div class="add-photo-icon">📷</div>
      <span>ถ่ายรูป</span>
    </div>`;
}

async function deleteExistingPhoto(photoId, idx) {
  await fetch(`/api/photos/${photoId}`, { method: 'DELETE' });
  existingPhotos.splice(idx, 1);
  renderPhotoGrid();
}

function deletePendingPhoto(idx) {
  pendingPhotos.splice(idx, 1);
  renderPhotoGrid();
}

/* ── Form submit ── */
document.getElementById('entry-form').addEventListener('submit', async (e) => {
  e.preventDefault();

  const id = document.getElementById('entry-id').value;
  const formData = new FormData();
  formData.append('date', document.getElementById('field-date').value);
  formData.append('is_holiday', document.getElementById('field-holiday').checked ? 'true' : 'false');
  formData.append('zone', document.getElementById('field-zone').value);
  formData.append('province', document.getElementById('field-province').value);
  formData.append('point_count', document.getElementById('field-points').value || 0);
  formData.append('distance', document.getElementById('field-distance').value || 0);
  formData.append('toll_fee', document.getElementById('field-toll').value || 0);
  formData.append('notes', document.getElementById('field-notes').value);
  formData.append('floor_deliveries', JSON.stringify(getFloorDeliveries()));
  pendingPhotos.forEach(p => formData.append('photos', p.file));

  const url = id ? `/api/deliveries/${id}` : '/api/deliveries';
  const method = id ? 'PUT' : 'POST';

  try {
    const res = await fetch(url, { method, body: formData });
    const data = await res.json();
    if (data.success) {
      showToast('✅ บันทึกสำเร็จ', 'success');
      pendingPhotos = [];
      showPage('home');
    } else {
      showToast('❌ ' + (data.error || 'บันทึกไม่สำเร็จ'), 'error');
    }
  } catch (err) {
    showToast('❌ เชื่อมต่อ server ไม่ได้', 'error');
  }
});

/* ── History ── */
async function loadHistory() {
  const months = ['มกราคม','กุมภาพันธ์','มีนาคม','เมษายน','พฤษภาคม','มิถุนายน','กรกฎาคม','สิงหาคม','กันยายน','ตุลาคม','พฤศจิกายน','ธันวาคม'];
  document.getElementById('history-month-label').textContent = `${months[historyMonth]} ${historyYear + 543}`;

  const start = `${historyYear}-${String(historyMonth+1).padStart(2,'0')}-01`;
  const lastDay = new Date(historyYear, historyMonth + 1, 0).getDate();
  const end = `${historyYear}-${String(historyMonth+1).padStart(2,'0')}-${lastDay}`;

  try {
    const res = await fetch(`/api/deliveries?start=${start}&end=${end}`);
    const items = await res.json();
    const el = document.getElementById('history-list');
    if (!items.length) {
      el.innerHTML = '<div class="empty"><div class="icon">📭</div><p>ไม่มีข้อมูลในเดือนนี้</p></div>';
      return;
    }
    el.innerHTML = items.map(d => renderDeliveryItem(d)).join('');
  } catch {}
}

function prevMonth() {
  historyMonth--;
  if (historyMonth < 0) { historyMonth = 11; historyYear--; }
  loadHistory();
}

function nextMonth() {
  historyMonth++;
  if (historyMonth > 11) { historyMonth = 0; historyYear++; }
  loadHistory();
}

/* ── Detail Modal ── */
async function showDetailModal(id) {
  try {
    const res = await fetch(`/api/deliveries/${id}`);
    const d = await res.json();
    const inc = calcIncome(d);
    const floorDetails = (d.floor_deliveries || []).map(f =>
      `ชั้น ${f.floor} × ${f.count||1} ครั้ง = ${(f.floor-2)*100*(f.count||1)} ฿`
    ).join('<br>') || '-';

    const content = d.is_holiday ? `
      <div class="modal-title">${formatTH(d.date)}</div>
      <div style="text-align:center;padding:24px"><span style="font-size:48px">🏖️</span><p>วันหยุด</p></div>
      <div class="btn-row mt16">
        <button class="btn btn-outline" onclick="editDelivery(${d.id})">✏️ แก้ไข</button>
        <button class="btn btn-danger" onclick="deleteDelivery(${d.id})">🗑️ ลบ</button>
      </div>
    ` : `
      <div class="modal-title">${formatTH(d.date)}</div>
      <div class="income-row"><span class="label">เขต / จังหวัด</span><span class="value">${d.zone||'-'} ${d.province?'/'+d.province:''}</span></div>
      <div class="income-row"><span class="label">จำนวนจุด</span><span class="value">${d.point_count||0} จุด</span></div>
      <div class="income-row"><span class="label">ระยะทาง</span><span class="value">${d.distance||0} กม.</span></div>
      <div class="income-row"><span class="label">เหมาจ่าย</span><span class="value">${inc.km.toLocaleString()} ฿</span></div>
      <div class="income-row"><span class="label">ยกของขึ้นชั้น</span><span class="value">${inc.floor.toLocaleString()} ฿<br><small style="color:var(--muted)">${floorDetails}</small></span></div>
      <div class="income-row"><span class="label">ค่าทางด่วน</span><span class="value">${inc.toll.toLocaleString()} ฿</span></div>
      <div class="income-net" style="margin:12px 0"><span>รวมรายได้</span><span>${inc.total.toLocaleString()} ฿</span></div>
      ${d.notes ? `<p style="font-size:13px;color:var(--muted);margin-bottom:12px">📝 ${d.notes}</p>` : ''}
      ${d.photos?.length ? `<div class="photo-grid" style="padding:0;margin-bottom:12px">${d.photos.map(p => `<div class="photo-item" style="aspect-ratio:1"><img src="${p.file_path}" style="width:100%;height:100%;object-fit:cover;border-radius:8px" onclick="window.open('${p.file_path}')"></div>`).join('')}</div>` : ''}
      <div class="btn-row">
        <button class="btn btn-outline btn-sm" onclick="editDelivery(${d.id})">✏️ แก้ไข</button>
        <button class="btn btn-success btn-sm" onclick="sendDailyReport('${d.date}')">📧 ส่ง</button>
        <button class="btn btn-danger btn-sm" onclick="deleteDelivery(${d.id})">🗑️</button>
      </div>
    `;
    document.getElementById('modal-content').innerHTML = content;
    document.getElementById('detail-modal').classList.add('active');
  } catch {}
}

document.getElementById('detail-modal').addEventListener('click', function(e) {
  if (e.target === this) this.classList.remove('active');
});

function closeModal() {
  document.getElementById('detail-modal').classList.remove('active');
}

/* ── Edit delivery ── */
async function editDelivery(id) {
  closeModal();
  const res = await fetch(`/api/deliveries/${id}`);
  const d = await res.json();
  showPage('entry');
  initEntryForm(d);
}

async function deleteDelivery(id) {
  if (!confirm('ลบข้อมูลนี้?')) return;
  closeModal();
  await fetch(`/api/deliveries/${id}`, { method: 'DELETE' });
  showToast('🗑️ ลบแล้ว');
  loadHistory();
  loadHome();
}

/* ── Reports ── */
function initReports() {
  const today = todayStr();
  document.getElementById('report-date').value = today;

  // Default 15-day range (last 15 days)
  const end = new Date(); end.setDate(end.getDate() - 1);
  const start = new Date(end); start.setDate(start.getDate() - 14);
  document.getElementById('summary-start').value = start.toISOString().split('T')[0];
  document.getElementById('summary-end').value = end.toISOString().split('T')[0];
}

function switchReportTab(tab) {
  document.querySelectorAll('.tab-btn').forEach((b, i) => b.classList.toggle('active', (i===0) === (tab==='daily')));
  document.getElementById('tab-daily').style.display = tab === 'daily' ? 'block' : 'none';
  document.getElementById('tab-summary').style.display = tab === 'summary' ? 'block' : 'none';
}

async function loadDailyReport() {
  const date = document.getElementById('report-date').value;
  if (!date) return;
  const area = document.getElementById('daily-report-area');
  area.innerHTML = '<div class="loading">⏳ กำลังโหลด...</div>';

  try {
    const res = await fetch(`/api/reports/daily/${date}`);
    if (!res.ok) {
      area.innerHTML = '<div class="card p16 text-center text-muted">ไม่พบข้อมูลวันที่นี้</div>';
      return;
    }
    const data = await res.json();
    const inc = data.income;
    const d = data.delivery;

    area.innerHTML = `
      <div class="card" style="margin-top:8px">
        <iframe class="report-preview-frame" srcdoc="${encodeIframe(data.html)}" title="report"></iframe>
      </div>
      <div style="padding:0 16px 16px; display:flex; gap:8px">
        <button class="btn btn-success" onclick="sendDailyReport('${date}')">📧 ส่งรายงานทางอีเมล์</button>
      </div>`;
  } catch {
    area.innerHTML = '<div class="card p16 text-center text-muted">โหลดรายงานไม่ได้</div>';
  }
}

async function loadSummary() {
  const start = document.getElementById('summary-start').value;
  const end = document.getElementById('summary-end').value;
  if (!start || !end) return;
  const area = document.getElementById('summary-area');
  area.innerHTML = '<div class="loading">⏳ กำลังคำนวณ...</div>';

  try {
    const res = await fetch(`/api/reports/summary?start=${start}&end=${end}`);
    const data = await res.json();
    const taxRate = parseFloat(settings.tax_rate) || 0.01;

    area.innerHTML = `
      <div class="summary-highlight">
        <div class="label">รายได้รวม ${start} – ${end}</div>
        <div class="big">${(data.totalIncome||0).toLocaleString()} ฿</div>
        <div style="margin-top:8px;font-size:13px;opacity:0.85">
          ${data.totalDays} วันวิ่ง · ${(data.totalDistance||0).toLocaleString()} กม. · ${data.totalPoints} จุด
        </div>
      </div>
      <div class="card">
        <div class="income-row income-total"><span class="label">รายได้รวม</span><span class="value">${(data.totalIncome||0).toLocaleString()} ฿</span></div>
        <div class="income-row" style="color:var(--danger)"><span class="label">หัก ณ ที่จ่าย ${(taxRate*100).toFixed(0)}%</span><span class="value">- ${(data.tax||0).toLocaleString('th-TH',{minimumFractionDigits:2})} ฿</span></div>
        <div class="income-net"><span>รับสุทธิ</span><span>${(data.netIncome||0).toLocaleString('th-TH',{minimumFractionDigits:2})} ฿</span></div>
      </div>
      <div class="card" style="margin-top:8px">
        <iframe class="report-preview-frame" style="height:500px" srcdoc="${encodeIframe(data.html)}" title="summary"></iframe>
      </div>
      <div style="padding:0 16px 16px">
        <button class="btn btn-success" onclick="sendSummaryReport('${start}','${end}')">📧 ส่งสรุปทางอีเมล์</button>
      </div>`;
  } catch {
    area.innerHTML = '<div class="card p16 text-center text-muted">โหลดสรุปไม่ได้</div>';
  }
}

function encodeIframe(html) {
  return html.replace(/"/g, '&quot;');
}

async function sendDailyReport(date) {
  closeModal();
  try {
    const res = await fetch('/api/reports/send-daily', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ date })
    });
    const data = await res.json();
    if (data.success) showToast('📧 ' + data.message, 'success');
    else showToast('❌ ' + data.error, 'error');
  } catch { showToast('❌ ส่งอีเมล์ไม่ได้', 'error'); }
}

async function sendSummaryReport(start, end) {
  try {
    const res = await fetch('/api/reports/send-summary', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ start, end })
    });
    const data = await res.json();
    if (data.success) showToast('📧 ' + data.message, 'success');
    else showToast('❌ ' + data.error, 'error');
  } catch { showToast('❌ ส่งอีเมล์ไม่ได้', 'error'); }
}

/* ── Settings ── */
async function loadSettings() {
  try {
    const res = await fetch('/api/settings');
    settings = await res.json();

    document.getElementById('s-driver-name').value = settings.driver_name || '';
    document.getElementById('s-boss-email').value = settings.boss_email || '';
    document.getElementById('s-sender-email').value = settings.sender_email || '';
    document.getElementById('s-smtp-pass').value = settings.smtp_password || '';
    document.getElementById('s-fuel-col').value = settings.current_fuel_col || 'r5';
    document.getElementById('s-tax-rate').value = parseFloat(settings.tax_rate || 0.01) * 100;
    document.getElementById('s-auto-15day').checked = settings.auto_report_15day === 'true' || settings.auto_report_15day === true;
    document.getElementById('webhook-url').textContent = `${location.origin}/webhook`;
    updateFuelTierPreview();
  } catch {}
}

function updateFuelTiers() {
  const col = document.getElementById('s-fuel-col').value;
  // Update km_tiers in settings based on selected fuel column
  const tiers = NITORI_TABLE.map(row => ({ min: row.min, max: row.max, rate: row[col] }));
  settings.km_tiers = tiers;
  settings.current_fuel_col = col;
  updateFuelTierPreview();
  updateIncomePreview();
}

function updateFuelTierPreview() {
  const col = document.getElementById('s-fuel-col')?.value || 'r5';
  const preview = document.getElementById('fuel-tier-preview');
  if (!preview) return;
  const sample = [
    NITORI_TABLE[0],   // 0-20 km
    NITORI_TABLE[8],   // 161-180 km
    NITORI_TABLE[9],   // 181-200 km
    NITORI_TABLE[12],  // 241-260 km
  ];
  preview.innerHTML = sample.map(r =>
    `${r.min}-${r.max} กม. = <strong>${r[col].toLocaleString()} ฿</strong>`
  ).join(' · ');
}

async function saveSettings() {
  const col = document.getElementById('s-fuel-col').value;
  const tiers = NITORI_TABLE.map(row => ({ min: row.min, max: row.max, rate: row[col] }));
  const taxPct = parseFloat(document.getElementById('s-tax-rate').value) || 1;

  const data = {
    driver_name: document.getElementById('s-driver-name').value,
    boss_email: document.getElementById('s-boss-email').value,
    sender_email: document.getElementById('s-sender-email').value,
    smtp_password: document.getElementById('s-smtp-pass').value,
    current_fuel_col: col,
    km_tiers: JSON.stringify(tiers),
    tax_rate: (taxPct / 100).toString(),
    auto_report_15day: document.getElementById('s-auto-15day').checked ? 'true' : 'false'
  };

  try {
    const res = await fetch('/api/settings', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(data)
    });
    const result = await res.json();
    if (result.success) {
      settings = { ...settings, ...data };
      showToast('✅ บันทึกการตั้งค่าแล้ว', 'success');
    }
  } catch { showToast('❌ บันทึกไม่ได้', 'error'); }
}

/* ── Init ── */
async function init() {
  try {
    const res = await fetch('/api/settings');
    settings = await res.json();
  } catch {}
  loadHome();
}

init();
