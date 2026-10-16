const Database = require('better-sqlite3');
const config = require('./config');

let db;

function initDB(path = config.dbPath) {
  db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.exec(`
    CREATE TABLE IF NOT EXISTS logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL DEFAULT (datetime('now')),
      level TEXT NOT NULL,
      source TEXT NOT NULL,
      message TEXT NOT NULL,
      data TEXT
    );

    CREATE TABLE IF NOT EXISTS agent_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      cycle_id TEXT NOT NULL,
      agent TEXT NOT NULL,
      symbol TEXT,
      status TEXT NOT NULL,
      output TEXT,
      started_at TEXT NOT NULL,
      finished_at TEXT
    );

    -- สัญญาณที่ผ่าน Risk Manager แล้ว (approved) หรือถูกปฏิเสธ (rejected)
    CREATE TABLE IF NOT EXISTS signals (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      cycle_id TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      symbol TEXT NOT NULL,
      action TEXT NOT NULL,
      confidence REAL,
      entry_ref REAL,
      sl_distance REAL,
      tp_distance REAL,
      sl REAL,
      tp REAL,
      lot REAL,
      risk_pct REAL,
      reasoning TEXT,
      decision TEXT NOT NULL,
      reject_reason TEXT,
      exec_status TEXT,          -- PAPER: filled | LIVE: pending → sent → filled/failed/expired
      exec_ticket TEXT,
      exec_price REAL,
      exec_error TEXT,
      updated_at TEXT
    );

    CREATE TABLE IF NOT EXISTS positions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      signal_id INTEGER,
      symbol TEXT NOT NULL,
      side TEXT NOT NULL,
      lot REAL NOT NULL,
      entry REAL NOT NULL,
      sl REAL NOT NULL,
      tp REAL NOT NULL,
      opened_at TEXT NOT NULL DEFAULT (datetime('now')),
      closed_at TEXT,
      exit REAL,
      pnl REAL,
      close_reason TEXT
    );

    CREATE TABLE IF NOT EXISTS equity (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL DEFAULT (datetime('now')),
      source TEXT NOT NULL,
      balance REAL NOT NULL,
      equity REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS state (
      key TEXT PRIMARY KEY,
      value TEXT
    );
  `);
  return db;
}

function getDB() {
  if (!db) throw new Error('DB ยังไม่ได้ init');
  return db;
}

function getState(key, fallback = null) {
  const row = getDB().prepare('SELECT value FROM state WHERE key = ?').get(key);
  if (!row) return fallback;
  try { return JSON.parse(row.value); } catch { return row.value; }
}

function setState(key, value) {
  getDB().prepare('INSERT INTO state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
    .run(key, JSON.stringify(value));
}

module.exports = { initDB, getDB, getState, setState };
