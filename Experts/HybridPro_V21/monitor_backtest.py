"""
HybridPro V21 — Backtest Monitor Agent
Real-time watcher สำหรับ optimization_results.csv

Usage:
  python ea/monitor_backtest.py           # watch ตลอดเวลา
  python ea/monitor_backtest.py --summary # แสดงผลสรุปแล้วออก
"""
import os, sys, time, csv, subprocess
from datetime import datetime

RESULTS_CSV  = r"C:\claude project\ea\optimization_results.csv"
TARGET_DAY   = 1000.0   # USD/day เป้าหมาย
DEPOSIT      = 10000.0
POLL_SEC     = 10       # ตรวจทุก 10 วินาที

PHASE_DAYS = {
    "baseline":    60,
    "optim3mo":    90,
    "validate5mo": 150,
}

# ── Windows toast notification (ต้องติดตั้ง win10toast หรือ winotify) ────────
def notify(title: str, msg: str):
    try:
        subprocess.run(
            ["powershell", "-WindowStyle", "Hidden", "-Command",
             f'[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null;'
             f'$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);'
             f'$xml.GetElementsByTagName("text")[0].AppendChild($xml.CreateTextNode("{title}")) | Out-Null;'
             f'$xml.GetElementsByTagName("text")[1].AppendChild($xml.CreateTextNode("{msg}")) | Out-Null;'
             f'$toast = [Windows.UI.Notifications.ToastNotification]::new($xml);'
             f'[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("HybridPro Monitor").Show($toast);'
            ],
            capture_output=True, timeout=5
        )
    except Exception:
        pass  # notification is best-effort


# ── CSV Reader ────────────────────────────────────────────────────────────────
def read_csv(path: str) -> list[dict]:
    rows = []
    if not os.path.exists(path):
        return rows
    try:
        with open(path, newline='', encoding='utf-8') as f:
            for row in csv.DictReader(f):
                try:
                    bal = float(row.get("Balance", "-9999"))
                    rows.append({
                        "num":     int(row.get("#", 0)),
                        "phase":   row.get("Phase", ""),
                        "lot":     float(row.get("Lot", 0)),
                        "gs":      int(row.get("GS", 0)),
                        "mg":      int(row.get("MaxGrid", 0)),
                        "mult":    float(row.get("Mult", 1.5)),
                        "deposit": float(row.get("Deposit", DEPOSIT)),
                        "balance": bal,
                        "stopout": row.get("StopOut", "False").lower() in ("true","1","yes"),
                        "bars":    int(row.get("Bars", 0)),
                        "score":   float(row.get("Score", bal)),
                    })
                except Exception:
                    pass
    except Exception as e:
        print(f"  [warn] CSV read error: {e}")
    return rows


def daily_profit(row: dict) -> float:
    days = PHASE_DAYS.get(row["phase"], 90)
    return (row["balance"] - row["deposit"]) / days if days > 0 else 0.0


# ── Display Helpers ───────────────────────────────────────────────────────────
def bar(val: float, target: float, width: int = 20) -> str:
    pct = min(val / target, 1.0) if target > 0 else 0
    filled = int(pct * width)
    return "[" + "█" * filled + "░" * (width - filled) + f"] {pct*100:.0f}%"


def print_summary(rows: list[dict], phase: str):
    phase_rows = [r for r in rows if r["phase"] == phase and r["balance"] != -9999.0]
    if not phase_rows:
        print(f"  (ยังไม่มีผล {phase})")
        return

    days     = PHASE_DAYS.get(phase, 90)
    total    = len(phase_rows)
    stopped  = sum(1 for r in phase_rows if r["stopout"])
    best_ok  = sorted([r for r in phase_rows if not r["stopout"]],
                      key=lambda r: r["score"], reverse=True)

    print(f"\n  Phase: {phase}  ({total} combos, {stopped} stop-out)")
    print(f"  {'#':>4} {'Lot':>5} {'GS':>4} {'MG':>3} {'Mult':>5}  "
          f"{'Balance':>10} {'$/day':>8} {'Stop':>5}")
    print(f"  {'─'*60}")
    for rank, r in enumerate(best_ok[:10], 1):
        dpf   = daily_profit(r)
        hit   = " ✓" if dpf >= TARGET_DAY else ""
        print(f"  {r['num']:>4} {r['lot']:>5} {r['gs']:>4} {r['mg']:>3} {r['mult']:>5}  "
              f"{r['balance']:>10.2f} {dpf:>+8.2f}{hit}")

    if best_ok:
        top = best_ok[0]
        dp  = daily_profit(top)
        print(f"\n  Best: Lot={top['lot']} GS={top['gs']} MG={top['mg']} Mult={top['mult']}")
        print(f"  Balance={top['balance']:.2f}  ~${dp:+.2f}/day  {bar(dp, TARGET_DAY)}")
        if dp < TARGET_DAY:
            needed = top['lot'] * (TARGET_DAY / dp) if dp > 0 else float('inf')
            print(f"  ต้องการ Lot≈{needed:.2f} เพื่อถึง ${TARGET_DAY:.0f}/day (ตรวจ margin ก่อน)")


def print_progress(rows: list[dict]):
    p2_total    = 36
    p2_done     = [r for r in rows if r["phase"] == "optim3mo"]
    p2_ok       = [r for r in p2_done if r["balance"] != -9999.0]
    p2_timeout  = [r for r in p2_done if r["balance"] == -9999.0]
    remaining   = p2_total - len(p2_ok) - len(p2_timeout)

    print(f"\n  Phase 2 progress: {len(p2_ok)}/{p2_total} done  "
          f"({len(p2_timeout)} timeout  {remaining} remaining)")
    if p2_ok:
        best = max(p2_ok, key=lambda r: r["score"] if not r["stopout"] else r["score"] - DEPOSIT)
        dp   = daily_profit(best)
        print(f"  Best so far: #{best['num']} Lot={best['lot']} GS={best['gs']} MG={best['mg']}  "
              f"bal={best['balance']:.2f}  ~${dp:+.2f}/day")


# ── Main Watch Loop ───────────────────────────────────────────────────────────
def watch():
    print(f"HybridPro V21 Backtest Monitor")
    print(f"Target: ${TARGET_DAY:,.0f}/day  |  Watching: {RESULTS_CSV}")
    print(f"Ctrl+C to stop\n{'─'*60}")

    last_mtime  = 0.0
    last_count  = 0
    known_done  = set()

    while True:
        try:
            if not os.path.exists(RESULTS_CSV):
                print(f"  [{_ts()}] ยังไม่มีไฟล์ผล — รอ backtest เริ่ม...", flush=True)
                time.sleep(POLL_SEC)
                continue

            mtime = os.path.getmtime(RESULTS_CSV)
            rows  = read_csv(RESULTS_CSV)
            count = len([r for r in rows if r["balance"] != -9999.0])

            if count != last_count:
                # มีผลใหม่
                new_rows = [r for r in rows
                            if r["balance"] != -9999.0
                            and (r["phase"], r["num"]) not in known_done]

                for r in new_rows:
                    dp   = daily_profit(r)
                    flag = "STOP" if r["stopout"] else "ok  "
                    hit  = " ★ TARGET!" if (not r["stopout"] and dp >= TARGET_DAY) else ""
                    msg  = (f"[{_ts()}] #{r['num']:>3} {r['phase']}  "
                            f"Lot={r['lot']} GS={r['gs']} MG={r['mg']} Mult={r['mult']}  "
                            f"bal={r['balance']:+.2f}  ${dp:+.2f}/day  [{flag}]{hit}")
                    print(msg, flush=True)
                    known_done.add((r["phase"], r["num"]))

                    if not r["stopout"] and dp >= TARGET_DAY:
                        notify("🎯 HybridPro: TARGET HIT!",
                               f"#{r['num']} Lot={r['lot']} GS={r['gs']} = ${dp:.0f}/day")
                    elif r["stopout"]:
                        notify("⚠ HybridPro: Stop-out",
                               f"#{r['num']} Lot={r['lot']} bal={r['balance']:.2f}")

                if count % 6 == 0 and count > 0:
                    print_progress(rows)

                last_count = count

            last_mtime = mtime
            time.sleep(POLL_SEC)

        except KeyboardInterrupt:
            print("\n\nStopped. Summary:")
            rows = read_csv(RESULTS_CSV)
            for ph in ("baseline", "optim3mo", "validate5mo"):
                print_summary(rows, ph)
            break
        except Exception as e:
            print(f"  [error] {e}", flush=True)
            time.sleep(POLL_SEC)


def _ts() -> str:
    return datetime.now().strftime("%H:%M:%S")


# ── Entry Point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if "--summary" in sys.argv:
        rows = read_csv(RESULTS_CSV)
        if not rows:
            print("ไม่มีข้อมูลใน CSV")
        else:
            for ph in ("baseline", "optim3mo", "validate5mo"):
                print_summary(rows, ph)
    else:
        watch()
