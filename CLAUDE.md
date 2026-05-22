# MT5 Trading Bot — Claude Code Project

## ภาพรวมโปรเจกต์

โปรเจกต์นี้ใช้ Claude Code Sub Agents ในการพัฒนา Expert Advisor (EA) สำหรับ MetaTrader 5
แต่ละ Agent มีความเชี่ยวชาญเฉพาะด้าน ทำงานร่วมกันเป็นทีม

## Sub Agents ที่มี

| Agent | ไฟล์ | หน้าที่ |
|-------|------|---------|
| mt5-architect | `.claude/agents/mt5-architect.md` | ออกแบบโครงสร้าง EA และ modules |
| mt5-coder | `.claude/agents/mt5-coder.md` | เขียน MQL5 code จริง |
| mt5-backtester | `.claude/agents/mt5-backtester.md` | วิเคราะห์และ optimize backtest |
| mt5-reviewer | `.claude/agents/mt5-reviewer.md` | Code review และตรวจ risk management |
| git-manager | `.claude/agents/git-manager.md` | จัดการ Git และ GitHub |
| doc-writer | `.claude/agents/doc-writer.md` | เขียน documentation |

## Workflow มาตรฐาน

```
1. mt5-architect  → ออกแบบโครงสร้าง
2. mt5-coder      → เขียน code
3. mt5-reviewer   → review + แก้ bug
4. mt5-backtester → test + optimize
5. doc-writer     → เขียน docs
6. git-manager    → commit + push
```

## กฎบังคับทุก Agent

- **SL/TP บังคับทุก order** — ห้าม trade โดยไม่มี StopLoss/TakeProfit
- **Max Drawdown** — หยุดเทรดเมื่อ drawdown เกิน threshold
- **Position Sizing** — คำนวณ lot จาก % of balance เสมอ
- **Error Handling** — ใช้ `GetLastError()` ทุกครั้งที่ส่ง order
- **Logging** — บันทึก log ทุก trade event

## โครงสร้างไฟล์ EA

```
Experts/
└── ProjectName/
    ├── ProjectName.mq5   ← EA หลัก
    ├── Strategy.mqh      ← Signal logic
    ├── RiskManager.mqh   ← SL/TP, Drawdown, Lot sizing
    ├── Logger.mqh        ← Logging system
    └── Utils.mqh         ← Helper functions
```

## สัญลักษณ์ที่รองรับ

- XAUUSD (Gold)
- EURUSD, GBPUSD, USDJPY
- US30, NAS100, SP500
- BTCUSD, ETHUSD
