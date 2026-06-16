const Database = require('better-sqlite3');
const path = require('path');

let db;

function initDB() {
  db = new Database(path.join(__dirname, '..', 'delivery.db'));
  db.pragma('journal_mode = WAL');

  db.exec(`
    CREATE TABLE IF NOT EXISTS deliveries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      date TEXT NOT NULL UNIQUE,
      zone TEXT DEFAULT '',
      province TEXT DEFAULT '',
      point_count INTEGER DEFAULT 0,
      distance REAL DEFAULT 0,
      floor_deliveries TEXT DEFAULT '[]',
      toll_fee REAL DEFAULT 0,
      notes TEXT DEFAULT '',
      is_holiday INTEGER DEFAULT 0,
      report_sent INTEGER DEFAULT 0,
      created_at TEXT DEFAULT (datetime('now', 'localtime'))
    );

    CREATE TABLE IF NOT EXISTS photos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      delivery_id INTEGER NOT NULL,
      point_name TEXT DEFAULT '',
      file_path TEXT NOT NULL,
      created_at TEXT DEFAULT (datetime('now', 'localtime')),
      FOREIGN KEY (delivery_id) REFERENCES deliveries(id)
    );

    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
  `);

  // NITORI full rate table (all fuel price columns)
  const NITORI_TABLE = [
    { min:0,   max:20,  r0:2535, r1:3195, r2:3195, r3:3365, r4:3466, r5:3570 },
    { min:21,  max:40,  r0:2545, r1:3195, r2:3195, r3:3365, r4:3466, r5:3570 },
    { min:41,  max:60,  r0:2555, r1:3195, r2:3195, r3:3365, r4:3466, r5:3570 },
    { min:61,  max:80,  r0:2565, r1:3195, r2:3195, r3:3365, r4:3466, r5:3570 },
    { min:81,  max:100, r0:2585, r1:3195, r2:3195, r3:3365, r4:3466, r5:3570 },
    { min:101, max:120, r0:2675, r1:3195, r2:3195, r3:3365, r4:3466, r5:3570 },
    { min:121, max:140, r0:2755, r1:3195, r2:3195, r3:3365, r4:3466, r5:3570 },
    { min:141, max:160, r0:2865, r1:3195, r2:3195, r3:3365, r4:3466, r5:3570 },
    { min:161, max:180, r0:2965, r1:3305, r2:3305, r3:3365, r4:3466, r5:3570 },
    { min:181, max:200, r0:3065, r1:3382, r2:3382, r3:3485, r4:3541, r5:3645 },
    { min:201, max:220, r0:3165, r1:3482, r2:3482, r3:3560, r4:3641, r5:3745 },
    { min:221, max:240, r0:3275, r1:3582, r2:3582, r3:3660, r4:3741, r5:3845 },
    { min:241, max:260, r0:3395, r1:3682, r2:3682, r3:3760, r4:3841, r5:3945 },
    { min:261, max:280, r0:3505, r1:3782, r2:3782, r3:3860, r4:3941, r5:4045 },
    { min:281, max:300, r0:3615, r1:3882, r2:3882, r3:3960, r4:4041, r5:4145 },
    { min:301, max:320, r0:3745, r1:3982, r2:3982, r3:4060, r4:4141, r5:4245 },
    { min:321, max:340, r0:3865, r1:4082, r2:4082, r3:4160, r4:4241, r5:4345 },
    { min:341, max:360, r0:3955, r1:4182, r2:4182, r3:4260, r4:4341, r5:4445 },
    { min:361, max:380, r0:4095, r1:4282, r2:4282, r3:4360, r4:4441, r5:4545 },
    { min:381, max:400, r0:4225, r1:4382, r2:4382, r3:4460, r4:4541, r5:4645 },
    { min:401, max:420, r0:4325, r1:4482, r2:4482, r3:4560, r4:4641, r5:4745 },
    { min:421, max:440, r0:4465, r1:4582, r2:4582, r3:4660, r4:4741, r5:4845 },
    { min:441, max:460, r0:4565, r1:4682, r2:4682, r3:4760, r4:4841, r5:4945 },
    { min:461, max:480, r0:4645, r1:4782, r2:4782, r3:4860, r4:4941, r5:5045 },
    { min:481, max:500, r0:4735, r1:4882, r2:4882, r3:4960, r4:5041, r5:5145 },
    { min:501, max:520, r0:4805, r1:4982, r2:4982, r3:5060, r4:5141, r5:5245 }
  ];

  const FUEL_COLS = [
    { key:'r0', label:'24.01-27.00' },
    { key:'r1', label:'27.01-30.00' },
    { key:'r2', label:'30.01-33.00' },
    { key:'r3', label:'33.01-36.00' },
    { key:'r4', label:'36.01-39.00' },
    { key:'r5', label:'39.01-42.00' }
  ];

  // Build active km_tiers for default fuel range r5 (39.01-42.00)
  const defaultKmTiers = NITORI_TABLE.map(row => ({ min: row.min, max: row.max, rate: row.r5 }));

  // Default settings
  const defaults = {
    boss_email: '',
    sender_email: '',
    sender_name: 'ระบบรายงานการส่งงาน',
    km_tiers: JSON.stringify(defaultKmTiers),
    nitori_table: JSON.stringify(NITORI_TABLE),
    fuel_cols: JSON.stringify(FUEL_COLS),
    current_fuel_col: 'r5',
    tax_rate: '0.01',
    auto_daily_report: 'false',
    auto_report_15day: 'true',
    driver_name: ''
  };

  const insertDefault = db.prepare(
    'INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)'
  );
  Object.entries(defaults).forEach(([k, v]) => insertDefault.run(k, v));

  console.log('✅ Database initialized');
  return db;
}

function getDB() {
  if (!db) initDB();
  return db;
}

module.exports = { initDB, getDB };
