"""
HybridPro V21 - Optimization for $500-1000/day target
Capital: $10,000 | Period: 2026.01.01 - 2026.05.18 (140 days)
Volume target: 30-50 lots/day
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
RESULTS_CSV  = r"C:\claude project\ea\opt_500_results.csv"

DEPOSIT      = 10000
FROM_DATE    = "2026.01.01"
TO_DATE      = "2026.05.18"
DAYS         = 140  # ประมาณ 5 เดือน

# Default parameters
BASE_SET = {
    "En1": "true", "En2": "true", "En3": "true",
    "Lot1": "0.01", "Lot2": "0.01", "Lot3": "0.01",
    "LotMult2": "1.0",
    "LotMultUp1": "1.1",
    "LotMultDown1": "1.5",
    "LotMultUp3": "1.5",
    "LotMultDown3": "1.1",
    "GS1": "100", "GS2": "100", "GS3": "100",
    "MaxGrid1": "3", "MaxGrid2": "3", "MaxGrid3": "3",
    "LossTrig1": "200.0", "LossTrig3": "200.0",
    "TrigCoolSec": "300",
    "UseADX": "true", "ADXTF": "16385", "ADXPer": "14", "ADXMin": "20.0",
    "UseSepTP": "true",  "TP1": "5.0", "TP2": "5.0", "TP3": "5.0",
    "UsePairTP": "true", "TPPair": "10.0",
    "UseTotTP": "true",  "TPTot": "15.0",
    "RecoveryRatio": "70.0", "TP2Assist": "0.0", "HardRecovery": "500.0",
    "BestBuyN": "2",  "TPBestBuy": "20.0",
    "BestSellN": "2", "TPBestSell": "20.0",
    "MaxSpread": "50", "MaxDailyLot": "0.0",
    "ShowPanel": "false", "ShowCal": "false",
}

PARAM_PATTERNS = {
    "GS1":          r'(input int\s+GS1\s+=\s+)\d+',
    "GS3":          r'(input int\s+GS3\s+=\s+)\d+',
    "MaxGrid1":     r'(input int\s+MaxGrid1\s+=\s+)\d+',
    "MaxGrid3":     r'(input int\s+MaxGrid3\s+=\s+)\d+',
    "MaxGrid2":     r'(input int\s+MaxGrid2\s+=\s+)\d+',
    "LotMultDown1": r'(input double\s+LotMultDown1\s+=\s+)[0-9.]+',
    "LotMultUp3":   r'(input double\s+LotMultUp3\s+=\s+)[0-9.]+',
    "TP1":          r'(input double\s+TP1\s+=\s+)[0-9.]+',
    "TP3":          r'(input double\s+TP3\s+=\s+)[0-9.]+',
    "TPPair":       r'(input double\s+TPPair\s+=\s+)[0-9.]+',
    "ShowPanel":    r'(input bool\s+ShowPanel\s+=\s+)\w+',
    "ShowCal":      r'(input bool\s+ShowCal\s+=\s+)\w+',
}


def scaled_params(lot):
    """Scale all dollar-amount params proportionally with lot (relative to 0.01 baseline)."""
    s = lot / 0.01
    return {
        "Lot1": lot, "Lot2": round(lot * 0.5, 2), "Lot3": lot,
        "TP1":  round(5.0 * s, 1),  "TP2":  round(2.5 * s, 1),  "TP3":  round(5.0 * s, 1),
        "TPPair": round(10.0 * s, 1), "TPTot": round(15.0 * s, 1),
        "LossTrig1": round(200.0 * s, 1), "LossTrig3": round(200.0 * s, 1),
        "HardRecovery": round(500.0 * s, 1),
        "TPBestBuy":  round(20.0 * s, 1),
        "TPBestSell": round(20.0 * s, 1),
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


def write_ini(deposit=10000, from_date="2026.01.01", to_date="2026.05.18"):
    content = f"""[Tester]
Expert=HybridPro_V21_FULL
ExpertParameters={SET_PATH}
Symbol=XAUUSD-VIP
Period=M1
Deposit={deposit}
Currency=USD
Leverage=100
Model=0
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
    print(f"  .ex5 {size}B (Advisors + root updated)", flush=True)
    return rc <= 1


def get_agent_log_path():
    today = time.strftime("%Y%m%d")
    return os.path.join(TESTER_DATA, "Agent-127.0.0.1-3000", "logs", f"{today}.log")


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


def wait_for_result(log_path, old_size, timeout=1800):
    deadline = time.time() + timeout
    start    = time.time()
    tick     = 0
    while time.time() < deadline:
        time.sleep(8)
        tick += 1
        if not os.path.exists(log_path):
            continue
        cur_size = os.path.getsize(log_path)
        if cur_size <= old_size:
            continue
        try:
            with open(log_path, 'rb') as f:
                f.seek(max(2, old_size))
                chunk = f.read(cur_size - max(2, old_size))
            text = chunk.decode('utf-16-le', errors='ignore')
            if 'final balance' in text:
                time.sleep(2)
                return cur_size
            if tick % 15 == 0:
                elapsed = int(time.time() - start)
                print(f"    ... still running {elapsed}s (+{cur_size-old_size}B log)", flush=True)
        except Exception:
            continue
    return None


def run_test(params, deposit=10000, from_date="2026.01.01", to_date="2026.05.18"):
    kill_mt5()
    patch_source(params)
    if not compile_ea():
        return {"balance": None, "stopout": False, "bars": 0, "error": "compile failed"}
    write_set_file(params)
    write_ini(deposit, from_date, to_date)
    log_path = get_agent_log_path()
    old_size = os.path.getsize(log_path) if os.path.exists(log_path) else 0
    subprocess.Popen([VT_TERMINAL, f'/config:{INI_PATH}'])
    final_size = wait_for_result(log_path, old_size, timeout=1800)
    kill_mt5()
    if final_size is None:
        return {"balance": None, "stopout": False, "bars": 0, "error": "timeout"}
    return parse_new_bytes(log_path, old_size)


def load_done_combos():
    """Return set of combo# that already have valid results (resume-safe)."""
    done = set()
    if not os.path.exists(RESULTS_CSV):
        return done
    with open(RESULTS_CSV, newline='', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            try:
                combo_num = int(row["combo#"])
                final_bal = row.get("FinalBalance", "")
                if final_bal not in ("", "-9999.00", "-9999"):
                    done.add(combo_num)
            except Exception:
                pass
    return done


def build_combos():
    """Build all parameter combinations for $500-1000/day target."""
    lot_vals  = [0.10, 0.15, 0.20, 0.25, 0.30]
    gs_vals   = [50, 75, 100]
    mg_vals   = [3, 4, 5]
    mult_vals = [1.5, 2.0]  # LotMultDown1 / LotMultUp3 (aggressive)

    combos = []
    num = 1
    for lot, gs, mg, mult in itertools.product(lot_vals, gs_vals, mg_vals, mult_vals):
        sp = scaled_params(lot)
        params = {**sp,
                  "GS1": gs, "GS3": gs,
                  "MaxGrid1": mg, "MaxGrid3": mg, "MaxGrid2": 3,
                  "LotMultDown1": mult, "LotMultUp3": mult,
                  "ShowPanel": "false", "ShowCal": "false"}
        tag = f"Lot={lot} GS={gs} MG={mg} Mult={mult}"
        combos.append((num, tag, params, lot, gs, mg, mult))
        num += 1
    return combos


def main():
    combos = build_combos()
    total  = len(combos)
    done   = load_done_combos()

    # Estimate time
    remaining = total - len(done)
    print(f"\n{'='*65}")
    print(f"HybridPro V21 - Optimization for $500-1000/day")
    print(f"  Deposit   : ${DEPOSIT:,}")
    print(f"  Period    : {FROM_DATE} - {TO_DATE} ({DAYS} days)")
    print(f"  Total combos : {total}  |  Already done: {len(done)}  |  Remaining: {remaining}")
    print(f"  Est. time    : ~{remaining*5/60:.1f} hr  (5 min/combo)")
    print(f"{'='*65}\n")

    # Create/append CSV
    file_exists = os.path.exists(RESULTS_CSV)
    with open(RESULTS_CSV, 'a' if file_exists else 'w', newline='', encoding='utf-8') as csvfile:
        writer = csv.writer(csvfile)
        if not file_exists or len(done) == 0:
            writer.writerow(["combo#", "Lot", "GS", "MaxGrid", "Mult",
                             "Deposit", "FinalBalance", "DailyProfit_Est",
                             "StopOut", "Bars"])

        for num, tag, params, lot, gs, mg, mult in combos:
            if num in done:
                print(f"  [{num:3d}/{total}] {tag}  SKIP (done)", flush=True)
                continue

            print(f"\n  [{num:3d}/{total}] {tag} ...", flush=True)
            t0 = time.time()
            r  = run_test(params, deposit=DEPOSIT, from_date=FROM_DATE, to_date=TO_DATE)
            elapsed = time.time() - t0

            bal  = r.get("balance") if r.get("balance") is not None else -9999.0
            stop = r.get("stopout", False)
            bars = r.get("bars", 0)
            err  = r.get("error", "")

            daily = (bal - DEPOSIT) / DAYS if bal > 0 else -9999.0

            line = (f"  bal={bal:+.2f}  daily_est={daily:+.2f}/day"
                    f"  stop={'YES' if stop else 'no '}"
                    f"  bars={bars:6d}  ({elapsed:.0f}s)")
            if err:
                line += f"  ERR:{err[:120]}"
            print(line, flush=True)

            writer.writerow([num, lot, gs, mg, mult,
                             DEPOSIT, f"{bal:.2f}", f"{daily:.2f}",
                             stop, bars])
            csvfile.flush()

    # ── Final analysis ─────────────────────────────────────────────────
    print(f"\n{'='*65}")
    print(f"OPTIMIZATION COMPLETE")
    print(f"{'='*65}\n")

    # Reload results for analysis
    results = []
    with open(RESULTS_CSV, newline='', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            try:
                num    = int(row["combo#"])
                lot    = float(row["Lot"])
                gs     = int(row["GS"])
                mg     = int(row["MaxGrid"])
                mult   = float(row["Mult"])
                bal    = float(row["FinalBalance"])
                daily  = float(row["DailyProfit_Est"])
                stop   = row["StopOut"].strip().lower() in ("true", "1", "yes")
                bars   = int(row["Bars"]) if row["Bars"].strip().isdigit() else 0
                results.append((num, lot, gs, mg, mult, bal, daily, stop, bars))
            except Exception:
                pass

    # Target: DailyProfit_Est between 500-1000, no stopout
    on_target  = [(n, l, g, m, mt, b, d, bars)
                  for n, l, g, m, mt, b, d, s, bars in results
                  if not s and 500 <= d <= 1000]
    no_stop    = [(n, l, g, m, mt, b, d, bars)
                  for n, l, g, m, mt, b, d, s, bars in results
                  if not s]
    all_sorted = sorted(results, key=lambda x: x[6], reverse=True)

    print(f"Total results   : {len(results)}")
    print(f"No stopout      : {len(no_stop)}")
    print(f"On-target ($500-1000/day, no stopout): {len(on_target)}\n")

    if on_target:
        on_target_sorted = sorted(on_target, key=lambda x: x[6], reverse=True)
        print("=== COMBOS HITTING TARGET ($500-1000/day, no stopout) ===")
        print(f"{'#':>4}  {'Lot':>5}  {'GS':>4}  {'MG':>3}  {'Mult':>5}  "
              f"{'FinalBal':>10}  {'$/day':>8}  {'Bars':>7}")
        print("-" * 65)
        for n, l, g, m, mt, b, d, bars in on_target_sorted:
            print(f"{n:>4}  {l:>5.2f}  {g:>4}  {m:>3}  {mt:>5.1f}  "
                  f"{b:>10.2f}  {d:>8.2f}  {bars:>7}")

        # Best on-target combo
        best = on_target_sorted[0]
        bn, bl, bg, bm, bmt, bb, bd, bbars = best
        sp = scaled_params(bl)
        print(f"\n=== RECOMMENDED PARAMETERS (best on-target combo #{bn}) ===")
        print(f"  Lot1 = Lot3       = {bl}")
        print(f"  Lot2              = {round(bl*0.5, 2)}")
        print(f"  GS1 = GS3         = {bg}")
        print(f"  MaxGrid1/3        = {bm}")
        print(f"  LotMultDown1      = {bmt}")
        print(f"  LotMultUp3        = {bmt}")
        print(f"  TP1 = TP3         = {sp['TP1']}")
        print(f"  TPPair / TPTot    = {sp['TPPair']} / {sp['TPTot']}")
        print(f"  LossTrig1/3       = {sp['LossTrig1']}")
        print(f"  HardRecovery      = {sp['HardRecovery']}")
        print(f"  --- Expected ---")
        print(f"  FinalBalance (5mo)= ${bb:,.2f}")
        print(f"  DailyProfit_Est   = ${bd:,.2f}/day")
        print(f"  TotalProfit (5mo) = ${bb - DEPOSIT:,.2f}")

    else:
        print("NOTE: No combo exactly hit $500-1000/day without stopout.")
        print("Showing closest alternatives:\n")

        if no_stop:
            no_stop_sorted = sorted(no_stop, key=lambda x: x[6], reverse=True)
            print("--- Best combos without stopout (sorted by daily profit) ---")
            print(f"{'#':>4}  {'Lot':>5}  {'GS':>4}  {'MG':>3}  {'Mult':>5}  "
                  f"{'FinalBal':>10}  {'$/day':>8}  {'Bars':>7}")
            print("-" * 65)
            for n, l, g, m, mt, b, d, bars in no_stop_sorted[:10]:
                print(f"{n:>4}  {l:>5.2f}  {g:>4}  {m:>3}  {mt:>5.1f}  "
                      f"{b:>10.2f}  {d:>8.2f}  {bars:>7}")

            best = no_stop_sorted[0]
            bn, bl, bg, bm, bmt, bb, bd, bbars = best
            sp = scaled_params(bl)
            print(f"\n=== RECOMMENDED (closest to target, no stopout, combo #{bn}) ===")
            print(f"  Lot1 = Lot3       = {bl}")
            print(f"  Lot2              = {round(bl*0.5, 2)}")
            print(f"  GS1 = GS3         = {bg}")
            print(f"  MaxGrid1/3        = {bm}")
            print(f"  LotMultDown1      = {bmt}")
            print(f"  LotMultUp3        = {bmt}")
            print(f"  TP1 = TP3         = {sp['TP1']}")
            print(f"  TPPair / TPTot    = {sp['TPPair']} / {sp['TPTot']}")
            print(f"  LossTrig1/3       = {sp['LossTrig1']}")
            print(f"  HardRecovery      = {sp['HardRecovery']}")
            print(f"  --- Expected ---")
            print(f"  FinalBalance (5mo)= ${bb:,.2f}")
            print(f"  DailyProfit_Est   = ${bd:,.2f}/day")
            print(f"  TotalProfit (5mo) = ${bb - DEPOSIT:,.2f}")
        else:
            print("WARNING: All combos resulted in stop-out.")
            print("Recommendation: reduce Lot size significantly (e.g. Lot=0.05)")
            print("or widen GS (grid spacing) to reduce drawdown risk.")

    print(f"\nFull results saved to: {RESULTS_CSV}")

    # Restore original EA source
    shutil.copy(EA_SRC_ORIG, EA_SRC)
    print("Original EA source restored.", flush=True)


if __name__ == "__main__":
    main()
