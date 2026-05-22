# MT5 Agents — Claude Code Sub Agents for MT5 Development

Claude Code Sub Agents สำหรับพัฒนา Expert Advisor (EA) บน MetaTrader 5

## Sub Agents

| Agent | หน้าที่ |
|-------|---------|
| 🏗️ **mt5-architect** | ออกแบบโครงสร้าง EA, เลือกกลยุทธ์, วาง modules |
| 💻 **mt5-coder** | เขียน MQL5 code จริง production-ready |
| 📊 **mt5-backtester** | วิเคราะห์ผล backtest, optimize parameters |
| 🔍 **mt5-reviewer** | Code review, ตรวจ risk management, หา bugs |
| 🔧 **git-manager** | จัดการ Git, commit, push, release |
| 📝 **doc-writer** | เขียน README, CHANGELOG, inline comments |

## Workflow

```
mt5-architect → mt5-coder → mt5-reviewer → mt5-backtester → doc-writer → git-manager
```

## วิธีใช้งาน

ใช้ Claude Code แล้วเรียก agent ตามงาน:

```
# ออกแบบ EA ใหม่
@mt5-architect ออกแบบ scalping EA สำหรับ XAUUSD M15

# เขียน code
@mt5-coder เขียน RiskManager.mqh ตาม architecture ที่ได้

# Review ก่อน deploy
@mt5-reviewer ตรวจสอบ code ทั้งหมดก่อน live

# วิเคราะห์ backtest
@mt5-backtester วิเคราะห์ผล backtest นี้ [paste results]

# Push ขึ้น GitHub
@git-manager commit และ push ทุกไฟล์
```

## กฎบังคับ

- ✅ SL/TP ทุก order
- ✅ Max Drawdown check
- ✅ Position sizing จาก % balance
- ✅ Error handling ทุก OrderSend
- ✅ Logging ทุก trade event
