"""
HybridPro V21 - Backtest Optimization
Target: $10,000 capital → $1,000/day profit

Margin math (XAUUSD 100:1, ~$4,400/lot, hedging, stop-out @ 50%):
  MG=3 mult=1.5: max safe Lot ≈ 0.09  (11.875×Lot×$4,400 ≤ $5,000)
  MG=5 mult=1.5: max safe Lot ≈ 0.04  (28.75×Lot×$4,400 ≤ $5,000)

Phase 1: Baseline  (Deposit=1000,  Lot=0.01, 2-month)
Phase 2: Optimize  (Deposit=10000, 3-month window, 36 combos)
Phase 3: Validate  (Deposit=10000, 5-month full, top-5 no-stopout)
"""
import subprocess, time, os, re, itertools, csv, shutil

VT_TERMINAL  = r"C:\Program Files\VT Markets (Pty) MT5 Terminal\terminal64.exe"
METAEDITOR   = r"C:\Program Files\VT Markets (Pty) MT5 Terminal\metaeditor64.exe"
VT_DATA      = r"C:\Users\Admin\AppData\Roaming\MetaQuotes\Terminal\9BB124B7D418C7FB69DF2865535BA9BF"
TESTER_DATA  = r"C:\Users\Admin\AppData\Roaming\MetaQuotes\Tester\9BB124B7D418C7FB69DF2865535BA9BF"
EA_SRC       = rf"{VT_DATA}\MQL5\Experts\Advisors\HybridPro_V21_FULL.mq5"
EA_EX5       = rf"{VT_DATA}\MQL5\Experts\Advisors\HybridPro_V21_FULL.ex5"
EA_EX5_ROOT  = rf"{VT_DATA}\MQL5\Experts\HybridPro_V21_FULL.ex5"
EA_SRC_ORIG  = r"C:\claude project\ea\HybridPro_V21_FULL.mq5"
SET_PATH     = rf"{VT_DATA}\Tester\HybridPro_V21_FULL.set"
INI_PATH     = rf"{VT_DATA}\config\tester_batch.ini"
RESULTS_CSV  = r"C:\claude project\ea\optimization_results.csv"

# ── BASE_SET: ค่า default ทุก input ──────────────────────────────────────────
BASE_SET = {
    "En1": "true", "En2": "true", "En3": "true",

    "Lot1": "0.01", "Lot2": "0.01", "Lot3": "0.01",
    "LotMult2": "1.0",

    "LotMultDown1": "1.5",
    "LotMultUp1":   "1.1",
    "LotMultUp3":   "1.5",
    "LotMultDown3": "1.1",

    "MultStart1": "0",
    "MultStart2": "0",
    "MultStart3": "0",

    "GS1": "100", "GS2": "100", "GS3": "100",

    "MaxGrid1": "5", "MaxGrid2": "3", "MaxGrid3": "5",

    "LossTrig1": "200.0", "LossTrig2": "200.0", "LossTrig3": "200.0",
    "TrigCoolSec": "300",

    "UseADX": "true", "ADXTF": "16385", "ADXPer": "14", "ADXMin": "20.0",

    # M1 Entry Filter (RSI) — BUY เมื่อ RSI < RSI1Lvl, SELL เมื่อ RSI > RSI1SellLvl
    "UseRSI1": "true", "RSI1TF": "16385", "RSI1Per": "14",
    "RSI1Lvl": "40.0", "RSI1SellLvl": "60.0",

    # M3 Entry Filter (EMA) — ไม้แรก SELL ต้อง price < EMA(EMA3Per)
    "UseEMA3": "true", "EMA3TF": "16385", "EMA3Per": "50",

    "UseSepTP":  "true",  "TP1": "5.0",  "TP2": "5.0",  "TP3": "5.0",
    "UsePairTP": "true",  "TPPair": "10.0",
    "UseTotTP":  "true",  "TPTot": "15.0",

    "RecoveryRatio": "70.0", "TP2Assist": "0.0", "HardRecovery": "500.0",
    "HeavyLossThreshold": "100.0",   # NEW: บังคับรอสะสมถ้ามีไม้เสียหนัก

    "BestBuyN":  "2", "TPBestBuy":  "20.0",
    "BestSellN": "2", "TPBestSell": "20.0",

    "MaxSpread": "50", "MaxDailyLot": "0.0",

    # Daily Cash Flow — ปิดในการ backtest (ทดสอบระบบ full)
    "DailyProfitTarget": "0.0",
    "CloseAllAtTarget":  "false",

    "ShowPanel": "false", "ShowCal": "false",
}

PARAM_PATTERNS = {
    "Lot1":                 r'(input double\s+Lot1\s+=\s+)[0-9.]+',
    "Lot2":                 r'(input double\s+Lot2\s+=\s+)[0-9.]+',
    "Lot3":                 r'(input double\s+Lot3\s+=\s+)[0-9.]+',
    "GS1":                  r'(input int\s+GS1\s+=\s+)\d+',
    "GS3":                  r'(input int\s+GS3\s+=\s+)\d+',
    "MaxGrid1":             r'(input int\s+MaxGrid1\s+=\s+)\d+',
    "MaxGrid3":             r'(input int\s+MaxGrid3\s+=\s+)\d+',
    "MaxGrid2":             r'(input int\s+MaxGrid2\s+=\s+)\d+',
    "LotMultDown1":         r'(input double\s+LotMultDown1\s+=\s+)[0-9.]+',
    "LotMultUp3":           r'(input double\s+LotMultUp3\s+=\s+)[0-9.]+',
    "TP1":                  r'(input double\s+TP1\s+=\s+)[0-9.]+',
    "TP2":                  r'(input double\s+TP2\s+=\s+)[0-9.]+',
    "TP3":                  r'(input double\s+TP3\s+=\s+)[0-9.]+',
    "TPPair":               r'(input double\s+TPPair\s+=\s+)[0-9.]+',
    "TPTot":                r'(input double\s+TPTot\s+=\s+)[0-9.]+',
    "TPBestBuy":            r'(input double\s+TPBestBuy\s+=\s+)[0-9.]+',
    "TPBestSell":           r'(input double\s+TPBestSell\s+=\s+)[0-9.]+',
    "LossTrig1":            r'(input double\s+LossTrig1\s+=\s+)[0-9.]+',
    "LossTrig2":            r'(input double\s+LossTrig2\s+=\s+)[0-9.]+',
    "LossTrig3":            r'(input double\s+LossTrig3\s+=\s+)[0-9.]+',
    "HardRecovery":         r'(input double\s+HardRecovery\s+=\s+)[0-9.]+',
    "HeavyLossThreshold":   r'(input double\s+HeavyLossThreshold\s+=\s+)[0-9.]+',  # NEW
    "ShowPanel":            r'(input bool\s+ShowPanel\s+=\s+)\w+',
    "ShowCal":              r'(input bool\s+ShowCal\s+=\s+)\w+',
}


def scaled_params(lot):
    """Scale dollar-amount params proportionally with lot (baseline = 0.01)."""
    s = lot / 0.01
    return {
        "Lot1": lot,  "Lot2": round(lot * 0.5, 3),  "Lot3": lot,
        "TP1":                round(5.0   * s, 1),
        "TP2":                round(2.5   * s, 1),
        "TP3":                round(5.0   * s, 1),
        "TP2Assist":          0.0,
        "TPPair":             round(10.0  * s, 1),
        "TPTot":              round(15.0  * s, 1),
        "LossTrig1":          round(200.0 * s, 1),
        "LossTrig2":          round(200.0 * s, 1),
        "LossTrig3":          round(200.0 * s, 1),
        "HardRecovery":       round(500.0 * s, 1),
        "HeavyLossThreshold": round(100.0 * s, 1),   # NEW: scale กับ lot
        "TPBestBuy":          round(20.0  * s, 1),
        "TPBestSell":         round(20.0  * s, 1),
    }


def patch_source(params):
    with open(EA_SRC_ORIG, encoding='utf-8', errors='replace') as f:
        src = f.read()
    patched = []
    for key, val in params.items():
        if key not in PARAM_PATTERNS:
            continue
        src, n = re.subn(PARAM_PATTERNS[key], rf'\g<1>{val}', src)
        if n == 0:
            print(f"  WARN: pattern not found for {key}", flush=True)
        else:
            patched.append(f"{key}={val}")
    print(f"  patched: {', '.join(patched)}", flush=True)
    with open(EA_SRC, 'w', encoding='utf-8') as f:
        f.write(src)


def write_set_file(params):
    merged = dict(BASE_SET)
    merged.update({k: str(v) for k, v in params.items()})
    with open(SET_PATH, 'w', encoding='ascii') as f:
        for k, v in merged.items():
            f.write(f"{k}={v}\n")


def write_ini(deposit=1000, from_date="2026.01.01", to_date="2026.04.01"):
    content = f"""[Tester]
Expert=HybridPro_V21_FULL
ExpertParameters={SET_PATH}
Symbol=XAUUSD-VIP
Period=M1
Deposit={deposit}
Currency=USD
Leverage=100
Model=2
ExecutionMode=0
Optimization=0
FromDate={from_date}
ToDate={to_date}
ForwardMode=0
Report=C:\\claude project\\ea\\bt_report
ReplaceReport=1
ShutdownTerminal=1
UseLocal=1
UseRemote=0
UseCloud=0
MQLLogs=0
"""
    with open(INI_PATH, 'w', encoding='ascii') as f:
        f.write(content)


def compile_ea():
    for f in [EA_EX5, EA_EX5_ROOT]:
        if os.path.exists(f):
            os.remove(f)
    try:
        r = subprocess.run([METAEDITOR, f'/compile:{EA_SRC}'],
                           capture_output=True, timeout=180)
        rc = r.returncode
    except subprocess.TimeoutExpired:
        print("  WARN: MetaEditor timeout (180s)", flush=True)
        rc = 1
    if not os.path.exists(EA_EX5):
        print("  ERROR: .ex5 not created!", flush=True)
        return False
    shutil.copy2(EA_EX5, EA_EX5_ROOT)
    size = os.path.getsize(EA_EX5)
    print(f"  .ex5 {size}B", flush=True)
    return rc <= 1


def get_all_log_snapshots():
    today = time.strftime("%Y%m%d")
    snapshots = {}
    if not os.path.exists(TESTER_DATA):
        return snapshots
    for entry in os.listdir(TESTER_DATA):
        if entry.startswith("Agent-"):
            log_path = os.path.join(TESTER_DATA, entry, "logs", f"{today}.log")
            snapshots[log_path] = os.path.getsize(log_path) if os.path.exists(log_path) else 0
    return snapshots


def parse_new_bytes(log_path, old_size):
    result = {"balance": None, "stopout": False, "bars": 0}
    try:
        with open(log_path, 'rb') as f:
            bom = f.read(2)
            is_utf16 = (bom == b'\xff\xfe')
            current = f.seek(0, 2)
            if current <= old_size:
                result["error"] = f"no new data ({current} <= {old_size})"
                return result
            read_from = max(2, old_size) if is_utf16 else old_size
            if is_utf16 and read_from % 2 != 0:
                read_from -= 1
            f.seek(read_from)
            data = f.read()
        content = data.decode('utf-16-le' if is_utf16 else 'utf-8', errors='ignore')
        bal_m = list(re.finditer(r'final balance ([0-9\-\.]+) USD', content))
        if bal_m:
            result["balance"] = float(bal_m[-1].group(1))
        result["stopout"] = "stop out occurred" in content
        bar_m = list(re.finditer(r'(\d+) ticks, (\d+) bars generated', content))
        if bar_m:
            result["bars"] = int(bar_m[-1].group(2))
        if result["balance"] is None:
            tail = content[-300:].replace('\n', ' | ')
            result["error"] = f"no balance in {len(data)}B. tail:{tail}"
    except Exception as e:
        result["error"] = str(e)
    return result


def kill_mt5():
    subprocess.run(['taskkill', '/F', '/IM', 'terminal64.exe'], capture_output=True)
    time.sleep(3)


def discover_new_agents(snapshots):
    today = time.strftime("%Y%m%d")
    if not os.path.exists(TESTER_DATA):
        return
    for entry in os.listdir(TESTER_DATA):
        if not entry.startswith("Agent-"):
            continue
        log_path = os.path.join(TESTER_DATA, entry, "logs", f"{today}.log")
        if log_path not in snapshots:
            snapshots[log_path] = 0


def wait_for_result(snapshots, timeout=2400):
    deadline = time.time() + timeout
    start    = time.time()
    tick     = 0
    while time.time() < deadline:
        time.sleep(8)
        tick += 1
        discover_new_agents(snapshots)
        for log_path, old_size in list(snapshots.items()):
            if not os.path.exists(log_path):
                continue
            cur_size = os.path.getsize(log_path)
            if cur_size <= old_size:
                continue
            try:
                with open(log_path, 'rb') as f:
                    bom = f.read(2)
                    is_utf16 = (bom == b'\xff\xfe')
                    read_from = max(2, old_size) if is_utf16 else old_size
                    if is_utf16 and read_from % 2 != 0:
                        read_from -= 1
                    f.seek(read_from)
                    chunk = f.read(cur_size - read_from)
                text = chunk.decode('utf-16-le' if is_utf16 else 'utf-8', errors='ignore')
                if 'final balance' in text:
                    agent = os.path.basename(os.path.dirname(os.path.dirname(log_path)))
                    print(f"  [{agent}] 'final balance' found", flush=True)
                    time.sleep(2)
                    return log_path, cur_size
            except Exception:
                continue
        if tick % 15 == 0:
            elapsed = int(time.time() - start)
            parts = []
            for lp, init_sz in list(snapshots.items()):
                agent = os.path.basename(os.path.dirname(os.path.dirname(lp)))
                delta = (os.path.getsize(lp) - init_sz) if os.path.exists(lp) else 0
                if delta > 0:
                    parts.append(f"{agent}:+{delta}B")
            print(f"    ... still running {elapsed}s  {' '.join(parts) or 'no log activity'}", flush=True)
    return None, 0


def run_test(params, deposit=1000, from_date="2026.01.01", to_date="2026.04.01"):
    kill_mt5()
    patch_source(params)
    if not compile_ea():
        return {"balance": None, "stopout": False, "bars": 0, "error": "compile failed"}
    write_set_file(params)
    write_ini(deposit, from_date, to_date)
    snapshots = get_all_log_snapshots()
    agents = [os.path.basename(os.path.dirname(os.path.dirname(p))) for p in snapshots]
    print(f"  watching {len(snapshots)} agent(s): {', '.join(agents)}", flush=True)
    subprocess.Popen([VT_TERMINAL, f'/config:{INI_PATH}'])
    result_path, final_size = wait_for_result(snapshots, timeout=1800)
    kill_mt5()
    if result_path is None:
        return {"balance": None, "stopout": False, "bars": 0, "error": "timeout"}
    return parse_new_bytes(result_path, snapshots[result_path])


def load_phase_results_from_csv(csv_path, phase_name):
    results = []
    if not os.path.exists(csv_path):
        return results
    with open(csv_path, newline='') as f:
        for row in csv.DictReader(f):
            if row.get("Phase", "") != phase_name:
                continue
            try:
                bal = float(row["Balance"])
                if bal == -9999.0:
                    continue
                stop    = row["StopOut"].lower() in ("true", "1", "yes")
                lot     = float(row["Lot"])
                gs      = int(row["GS"])
                mg      = int(row["MaxGrid"])
                mult    = float(row.get("Mult", 1.5))
                deposit = float(row["Deposit"])
                score   = bal if not stop else (bal - deposit)
                results.append((score, bal, stop, lot, gs, mg, mult))
            except Exception:
                pass
    return results


def load_done_set(phase=None):
    done = set()
    if not os.path.exists(RESULTS_CSV):
        return done
    with open(RESULTS_CSV, newline='') as f:
        for row in csv.DictReader(f):
            try:
                if phase is not None and row.get("Phase", "") != phase:
                    continue
                if row.get("Balance", "") not in ("", "-9999.00"):
                    done.add(int(row["#"]))
            except:
                pass
    return done


def run_phase(writer, csvfile, phase, combos, deposit, done,
              from_date="2026.01.01", to_date="2026.04.01"):
    best = {"score": -99999}
    results = []
    total = len(combos)
    for idx, (num, tag, params) in enumerate(combos):
        if num in done:
            print(f"  [{num:3d}] {tag}  SKIP", flush=True)
            continue
        print(f"  [{num:3d}/{total}] {tag} ...", end=" ", flush=True)
        t0 = time.time()
        r  = run_test(params, deposit=deposit, from_date=from_date, to_date=to_date)
        elapsed = time.time() - t0
        bal   = r.get("balance") if r.get("balance") is not None else -9999.0
        stop  = r.get("stopout", False)
        bars  = r.get("bars", 0)
        err   = r.get("error", "")
        score = bal if not stop else (bal - deposit)
        line  = f"bal={bal:+.2f} stop={'YES' if stop else 'no '} bars={bars:5d} ({elapsed:.0f}s)"
        if err:
            line += f"  ERR:{err[:80]}"
        print(line, flush=True)
        lot  = params.get("Lot1", 0.01)
        gs   = params.get("GS1", 100)
        mg   = params.get("MaxGrid1", 5)
        mult = params.get("LotMultDown1", 1.5)
        writer.writerow([num, phase, f"{lot}", gs, mg, mult, deposit,
                         f"{bal:.2f}", stop, bars, f"{score:.2f}"])
        csvfile.flush()
        results.append((score, bal, stop, lot, gs, mg, mult))
        if not stop and score > best.get("score", -99999):
            best = {"score": score, "bal": bal, "lot": lot, "gs": gs, "mg": mg, "mult": mult}
            print(f"    *** New best: {tag} -> balance={bal:.2f}", flush=True)
    return results


def make_p2_params(lot, gs, mg, mult_down):
    sp = scaled_params(lot)
    return {
        **sp,
        "GS1": gs, "GS3": gs, "GS2": gs,
        "MaxGrid1": mg, "MaxGrid3": mg, "MaxGrid2": 3,
        "LotMultDown1": mult_down,
        "LotMultUp3":   mult_down,
        "LotMultUp1":   1.1,
        "LotMultDown3": 1.1,
        "MultStart1": 0, "MultStart2": 0, "MultStart3": 0,
        "ShowPanel": "false", "ShowCal": "false",
    }


def print_daily_analysis(results, deposit, days, label=""):
    """Print daily profit projection for each combo."""
    if not results:
        return
    print(f"\n{'─'*80}")
    print(f"{'Rank':>4} {'Lot':>5} {'GS':>4} {'MG':>3} {'Mult':>5}  "
          f"{'Balance':>10} {'Profit':>9} {'$/day':>8} {'Stop':>5}")
    print(f"{'─'*80}")
    sorted_r = sorted(results, key=lambda x: x[0], reverse=True)
    for rank, (sc, bal, stop, lot, gs, mg, mult) in enumerate(sorted_r[:20], 1):
        profit   = bal - deposit
        per_day  = profit / days
        flag     = "STOP" if stop else "  ok"
        if stop:              hit = ""
        elif per_day >= 1000: hit = " ✓ $1k/d"
        elif per_day >= 500:  hit = " ✓ $500/d"
        else:                 hit = ""
        print(f"{rank:>4} {lot:>5} {gs:>4} {mg:>3} {mult:>5}  "
              f"{bal:>10.2f} {profit:>+9.2f} {per_day:>+8.2f}  {flag}{hit}")


def main():
    deposit = 10000

    # ── Phase 1: Baseline ────────────────────────────────────────────
    base_params = {
        "GS1": 100, "GS3": 100, "GS2": 100,
        "MaxGrid1": 5, "MaxGrid3": 5, "MaxGrid2": 3,
        **scaled_params(0.01),
        "ShowPanel": "false", "ShowCal": "false",
    }
    p1_combos = [(0, "Baseline Deposit=1000 Lot=0.01 GS=100 MG=5", base_params)]

    # ── Phase 2: Optimization — เป้า $500–$1,000/วัน จาก $10,000 ──────
    #
    # EA ใหม่: M1 bidirectional (RSI), M3 bidirectional (EMA50), M2 ADX (unchanged)
    # ทั้งสามเปิดได้ทั้ง BUY และ SELL → โอกาสมากขึ้น แต่ margin ต้องระวัง
    #
    # Margin safety (XAUUSD 100:1, hedging, stop-out @50%):
    #   MG=3, mult=1.5 → max safe Lot ≈ 0.09
    #   MG=5, mult=1.5 → max safe Lot ≈ 0.04
    #
    # ช่วง lot ครอบ $500/day (Lot≈0.04–0.05) ถึง $1,000/day (Lot≈0.07–0.09)

    p2_combos = []
    num = 1

    # Group A: MG=3 (faster TP cycles) — 18 combos
    # Lot=0.04 → ~$500/day estimate | Lot=0.07 → ~$700/day | Lot=0.09 → ~$900/day
    for lot in [0.04, 0.07, 0.09]:
        for gs in [50, 75, 100]:
            for mult in [1.3, 1.5]:
                params = make_p2_params(lot, gs, 3, mult)
                tag    = f"Lot={lot} GS={gs} MG=3 Mult={mult}"
                p2_combos.append((num, tag, params))
                num += 1

    # Group B: MG=5 (deeper grid, better recovery) — 18 combos
    # Lot=0.02 → ~$300/day | Lot=0.03 → ~$500/day | Lot=0.04 → ~$700/day
    for lot in [0.02, 0.03, 0.04]:
        for gs in [50, 75, 100]:
            for mult in [1.3, 1.5]:
                params = make_p2_params(lot, gs, 5, mult)
                tag    = f"Lot={lot} GS={gs} MG=5 Mult={mult}"
                p2_combos.append((num, tag, params))
                num += 1

    total_p2 = len(p2_combos)
    file_exists = os.path.exists(RESULTS_CSV)
    done_p1 = load_done_set("baseline")
    done_p2 = load_done_set("optim3mo")
    done_p3 = load_done_set("validate5mo")

    try:
        with open(RESULTS_CSV, 'a' if file_exists else 'w', newline='') as csvfile:
            writer = csv.writer(csvfile)
            if not file_exists:
                writer.writerow(["#", "Phase", "Lot", "GS", "MaxGrid", "Mult",
                                 "Deposit", "Balance", "StopOut", "Bars", "Score"])

            # Phase 1: Baseline 2-month
            print("\n=== PHASE 1: BASELINE (Deposit=1000, Lot=0.01) ===\n", flush=True)
            p1_results = run_phase(writer, csvfile, "baseline", p1_combos,
                                   deposit=1000, done=done_p1,
                                   from_date="2026.01.01", to_date="2026.03.01")
            if p1_results:
                bal, stop = p1_results[0][1], p1_results[0][2]
                print(f"\nBaseline: {'STOP-OUT' if stop else 'OK'}  balance={bal:.2f}\n", flush=True)

            # Phase 2: 3-month optimization
            est_hr = total_p2 * 15 / 60
            print(f"\n=== PHASE 2: OPTIMIZATION (Deposit={deposit:,}, 3mo) — "
                  f"{total_p2} combos ~{est_hr:.1f}hr ===\n", flush=True)
            print(f"  Target: $500–$1,000/day  →  $45k–$90k profit over 90 days\n", flush=True)
            p2_results = run_phase(writer, csvfile, "optim3mo", p2_combos,
                                   deposit=deposit, done=done_p2,
                                   from_date="2026.01.01", to_date="2026.04.01")

            if not p2_results:
                p2_results = load_phase_results_from_csv(RESULTS_CSV, "optim3mo")
                if p2_results:
                    print(f"  (loaded {len(p2_results)} Phase 2 results from CSV)", flush=True)

            # Phase 3: 5-month validation — top 5 no-stopout
            p2_sorted = sorted(p2_results, key=lambda x: x[0], reverse=True)
            top5 = [(s, b, stop, l, gs, mg, mu)
                    for s, b, stop, l, gs, mg, mu in p2_sorted if not stop][:5]

            if top5:
                print(f"\n=== PHASE 3: VALIDATE 5-MONTH — top {len(top5)} combos ===\n", flush=True)
                p3_start = 100
                p3_combos = []
                for i, (_, _, _, lot, gs, mg, mult) in enumerate(top5):
                    params = make_p2_params(lot, gs, mg, mult)
                    tag    = f"[VALIDATE] Lot={lot} GS={gs} MG={mg} Mult={mult}"
                    p3_combos.append((p3_start + i, tag, params))
                p3_results = run_phase(writer, csvfile, "validate5mo", p3_combos,
                                       deposit=deposit, done=done_p3,
                                       from_date="2026.01.01", to_date="2026.06.01")
                if p3_results:
                    print("\n── Phase 3 Daily Analysis (150 trading days) ──")
                    print_daily_analysis(p3_results, deposit, days=150)

    finally:
        shutil.copy(EA_SRC_ORIG, EA_SRC)
        print("\nOriginal EA source restored.", flush=True)

    if not p2_results:
        print("No Phase 2 results.", flush=True)
        return

    # ── Final Report ────────────────────────────────────────────────
    days_p2 = 90  # 3-month window
    print(f"\n{'='*80}")
    print(f"OPTIMIZATION COMPLETE  ({len(p2_results)} combos)  |  Target: $500–$1,000/day")
    print(f"{'='*80}")
    print_daily_analysis(p2_results, deposit, days=days_p2, label="3-month")

    no_stop = [(s, b, l, gs, mg, mu)
               for s, b, stop, l, gs, mg, mu in p2_results if not stop]

    if no_stop:
        _, best_bal, bl, bgs, bmg, bmu = no_stop[0]
        sp = scaled_params(bl)
        profit_90d   = best_bal - deposit
        daily_profit = profit_90d / days_p2
        if   daily_profit >= 1000: hit = "✓ >= $1,000/day"
        elif daily_profit >= 500:  hit = "✓ >= $500/day"
        else:                      hit = f"({daily_profit/500*100:.0f}% of $500 target)"
        print(f"\n{'─'*80}")
        print(f"RECOMMENDED (best 3-month, no stop-out):")
        print(f"  Lot1 = Lot3          = {bl}")
        print(f"  Lot2                 = {round(bl*0.5, 3)}")
        print(f"  GS                   = {bgs}")
        print(f"  MaxGrid1/3 | MaxGrid2= {bmg} | 3")
        print(f"  LotMultDown1/Up3     = {bmu}")
        print(f"  HeavyLossThreshold   = {sp['HeavyLossThreshold']}")
        print(f"  TP1=TP3 | TPPair | TPTot = {sp['TP1']} | {sp['TPPair']} | {sp['TPTot']}")
        print(f"  LossTrig             = {sp['LossTrig1']}")
        print(f"  Balance (3mo)        = {best_bal:.2f} USD")
        print(f"  Profit (3mo)         = {profit_90d:+.2f} USD")
        print(f"  ~Daily profit        = {daily_profit:+.2f} USD/day  {hit}")
        print(f"{'─'*80}")
        if daily_profit < 500:
            needed_lot = bl * (500 / daily_profit) if daily_profit > 0 else float('inf')
            print(f"\n  ⚠ ต้องการ Lot ≈ {needed_lot:.2f} เพื่อให้ได้ $500/วัน")
            print(f"  ⚠ ตรวจสอบ margin safety ก่อน deploy จริง")
        elif daily_profit < 1000:
            needed_lot = bl * (1000 / daily_profit)
            print(f"\n  ℹ หากต้องการ $1,000/วัน → Lot ≈ {needed_lot:.2f} (ตรวจ margin ก่อน)")
    else:
        print("\n⚠ All combos stopped out → ลด lot หรือ MaxGrid ก่อน deploy จริง")

    print(f"\nFull results: {RESULTS_CSV}")


if __name__ == "__main__":
    main()
