const { getDB } = require('./db');

function write(level, source, message, data) {
  const line = `[${new Date().toISOString()}] ${level.toUpperCase()} [${source}] ${message}`;
  (level === 'error' ? console.error : console.log)(line, data !== undefined ? JSON.stringify(data) : '');
  try {
    getDB().prepare('INSERT INTO logs (level, source, message, data) VALUES (?, ?, ?, ?)')
      .run(level, source, message, data !== undefined ? JSON.stringify(data) : null);
  } catch { /* DB ยังไม่พร้อม — log ลง console อย่างเดียว */ }
}

module.exports = {
  info: (src, msg, data) => write('info', src, msg, data),
  warn: (src, msg, data) => write('warn', src, msg, data),
  error: (src, msg, data) => write('error', src, msg, data),
  trade: (src, msg, data) => write('trade', src, msg, data),
};
