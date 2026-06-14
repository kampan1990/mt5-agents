//+------------------------------------------------------------------+
//| Gridindy.mq5                                                      |
//| Grid Trading EA — ADX + EMA + RSI + Hedge Recovery               |
//| Version: 1.2.0                                                    |
//+------------------------------------------------------------------+
#property strict
#property copyright "Gridindy EA"
#property description "ระบบกริด BUY/SELL พร้อม Trend Filter และ Hedge Recovery แบบ Martingale"
#property version "1.20"

#include "Logger.mqh"
#include "TrendFilter.mqh"
#include "RiskManager.mqh"
#include "GridManager.mqh"
#include "RecoveryManager.mqh"
#include "TrailingManager.mqh"

//+------------------------------------------------------------------+
//| พารามิเตอร์ (ภาษาไทย)                                            |
//+------------------------------------------------------------------+

input group "=== ตัวกรองเทรน (ADX + EMA + RSI) ==="
input int    InpAdxPeriod          = 14;     // คาบ ADX
input double InpAdxThreshold       = 25.0;   // ค่า ADX ขั้นต่ำที่ถือว่ามีเทรน
input int    InpEmaPeriod          = 200;    // คาบ EMA (เส้นแนวโน้ม)
input int    InpRsiPeriod          = 14;     // คาบ RSI

input group "=== ระยะกริด (ATR อัตโนมัติ) ==="
input int    InpAtrPeriod          = 14;     // คาบ ATR
input double InpAtrGridMultiplier  = 1.5;    // ตัวคูณ ATR สำหรับระยะกริด
input double InpAtrRecMultiplier   = 1.0;    // ตัวคูณ ATR สำหรับระยะ Recovery
input double InpMinGridPoints      = 30.0;   // ระยะกริดขั้นต่ำ (points)
input double InpMaxGridPoints      = 1000.0; // ระยะกริดสูงสุด (points)

input group "=== กริดหลัก ==="
input double InpBaseLot            = 0.01;   // ขนาด Lot เริ่มต้น
input double InpGridDistance       = 100.0;  // ระยะห่างกริด (points) — ใช้เมื่อ ATR ไม่พร้อม
input int    InpMaxGridOrders      = 5;      // จำนวนไม้กริดสูงสุด
input double InpProfitTarget       = 50.0;   // เป้ากำไรรวมเพื่อเปิด Trailing (USD)

input group "=== Recovery (Hedge Martingale) ==="
input double InpRecoveryDistance   = 100.0;  // ระยะย้อนเทรนก่อนเปิด Recovery (points)
input double InpRecoveryMultiplier = 2.0;    // ตัวคูณ Lot แต่ละชั้น Recovery
input int    InpMaxRecoveryOrders  = 5;      // จำนวนชั้น Recovery สูงสุด

input group "=== Trailing Stop ==="
input double InpTrailDistance      = 50.0;   // ระยะ Trailing ห่างจากราคา (points)
input double InpTrailStep          = 10.0;   // ระยะขยับ SL ขั้นต่ำ (points)

input group "=== ความเสี่ยง ==="
input double InpMaxDrawdownPct     = 20.0;   // DD สูงสุด % ก่อนหยุดฉุกเฉิน
input long   InpMagicNumber        = 20260614; // Magic Number
input int    InpMaxSpreadPoints    = 50;     // Spread สูงสุดที่ยอมรับ (points)
input bool   InpEmergencyStop      = false;  // หยุดฉุกเฉิน — ปิดทุกไม้ทันที
input bool   InpEmergencyReset     = false;  // รีเซ็ตจากสถานะฉุกเฉิน → รอสัญญาณ

input group "=== แดชบอร์ด ==="
input bool   InpShowDashboard      = true;   // แสดงแดชบอร์ดบนชาร์ต (มุมบนซ้าย)
input int    InpDashX              = 10;     // ตำแหน่ง X (pixels จากซ้าย)
input int    InpDashY              = 15;     // ตำแหน่ง Y (pixels จากบน)
input bool   InpVerboseLog         = false;  // Log รายละเอียดทุก tick (ช้า)

//+------------------------------------------------------------------+
//| State Machine                                                     |
//+------------------------------------------------------------------+
enum ENUM_EA_STATE
{
   STATE_IDLE         = 0,  // รอสัญญาณ
   STATE_GRID_RUNNING = 1,  // กริดทำงาน
   STATE_RECOVERY     = 2,  // Recovery ทำงาน
   STATE_TRAILING     = 3,  // Trailing Stop ทำงาน
   STATE_EMERGENCY    = 4   // หยุดฉุกเฉิน
};

//+------------------------------------------------------------------+
//| Global instances                                                  |
//+------------------------------------------------------------------+
CLogger          g_logger;
CTrendFilter     g_trend;
CRiskManager     g_risk;
CGridManager     g_grid;
CRecoveryManager g_recovery;
CTrailingManager g_trailer;

ENUM_EA_STATE    g_state            = STATE_IDLE;
double           g_dyn_grid_dist    = 0.0;
double           g_dyn_recovery_dist= 0.0;

// Dashboard prefix สำหรับ chart objects
#define DASH_PFX "GDY_"

//+------------------------------------------------------------------+
//| State helpers                                                     |
//+------------------------------------------------------------------+
string StateName(ENUM_EA_STATE s)
{
   switch(s)
   {
      case STATE_IDLE:         return "รอสัญญาณ";
      case STATE_GRID_RUNNING: return "กริดทำงาน";
      case STATE_RECOVERY:     return "Recovery";
      case STATE_TRAILING:     return "Trailing Stop";
      case STATE_EMERGENCY:    return "ฉุกเฉิน!";
      default:                 return "?";
   }
}

color StateColor(ENUM_EA_STATE s)
{
   switch(s)
   {
      case STATE_IDLE:         return clrSilver;
      case STATE_GRID_RUNNING: return clrDeepSkyBlue;
      case STATE_RECOVERY:     return clrOrange;
      case STATE_TRAILING:     return clrLimeGreen;
      case STATE_EMERGENCY:    return clrRed;
      default:                 return clrWhite;
   }
}

void ChangeState(ENUM_EA_STATE new_state)
{
   if(new_state == g_state) return;
   g_logger.StateChange(StateName(g_state), StateName(new_state));
   g_state = new_state;
}

void ResetAll()
{
   g_grid.Reset();
   g_recovery.Reset();
   g_trailer.Reset();
}

double GridSLPoints()
{
   double d = (g_dyn_grid_dist > 0.0) ? g_dyn_grid_dist : InpGridDistance;
   return d * InpMaxGridOrders;
}

double RecoverySLPoints()
{
   double d = (g_dyn_recovery_dist > 0.0) ? g_dyn_recovery_dist : InpRecoveryDistance;
   return d * InpMaxRecoveryOrders;
}

void UpdateATRDistances()
{
   double atr = g_trend.GetATR();
   if(atr <= 0.0) return;

   double atr_pts = atr / _Point;

   double new_grid = MathMax(InpMinGridPoints, MathMin(InpMaxGridPoints, atr_pts * InpAtrGridMultiplier));
   double new_rec  = MathMax(InpMinGridPoints, MathMin(InpMaxGridPoints, atr_pts * InpAtrRecMultiplier));

   if(MathAbs(new_grid - g_dyn_grid_dist) > 0.5 || MathAbs(new_rec - g_dyn_recovery_dist) > 0.5)
      g_logger.Info(StringFormat("ATR=%.2f pts  กริด=%.0f pts  Recovery=%.0f pts", atr_pts, new_grid, new_rec));

   g_dyn_grid_dist      = new_grid;
   g_dyn_recovery_dist  = new_rec;
   g_grid.SetGridDistance(new_grid);
   g_recovery.SetRecoveryDistance(new_rec);
}

//+------------------------------------------------------------------+
//| Dashboard helpers                                                 |
//+------------------------------------------------------------------+
void DashRect(string name, int x, int y, int w, int h, color bg, color border = clrNONE)
{
   string n = DASH_PFX + name;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,      w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,      h);
   ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,    bg);
   ObjectSetInteger(0, n, OBJPROP_COLOR,      border == clrNONE ? bg : border);
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_BACK,       false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void DashLabel(string name, int x, int y, string text, color clr, int font_size = 8, string font = "Consolas")
{
   string n = DASH_PFX + name;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetString (0, n, OBJPROP_TEXT,       text);
   ObjectSetInteger(0, n, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE,   font_size);
   ObjectSetString (0, n, OBJPROP_FONT,       font);
   ObjectSetInteger(0, n, OBJPROP_BACK,       false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void DashDeleteAll()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, DASH_PFX) == 0)
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| DrawDashboard — แดชบอร์ดแสดงสถานะทุกโมดูล                       |
//+------------------------------------------------------------------+
void DrawDashboard()
{
   if(!InpShowDashboard) return;

   int ox = InpDashX;   // offset จากซ้าย
   int oy = InpDashY;   // offset จากบน
   int W  = 230;        // ความกว้างแผง
   int lh = 16;         // ความสูงต่อบรรทัด
   int pad= 6;          // padding ซ้าย
   int vc = ox + 118;   // column ค่า (value column x)

   // ── สีพื้นหลัง ───────────────────────────────────────────────
   color cBg     = C'15,18,30';
   color cBorder = C'40,55,100';
   color cHdr    = C'22,30,58';
   color cSep    = C'35,45,80';

   // ── ข้อมูลแต่ละโมดูล ─────────────────────────────────────────
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd        = g_risk.GetCurrentDrawdownPct();
   long   spread    = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   bool   hasTrend  = g_trend.HasTrend();
   double adx       = g_trend.GetADX();
   double ema       = g_trend.GetEMA();
   double rsi       = g_trend.GetRSI();
   double atr_pts   = g_trend.GetATR() / _Point;
   string trendStr  = !hasTrend ? "ไม่มีเทรน" : (g_trend.IsTrendUp() ? "ขาขึ้น ▲" : "ขาลง ▼");
   color  trendClr  = !hasTrend ? clrSilver   : (g_trend.IsTrendUp() ? clrLimeGreen : clrTomato);

   int    gridCnt   = g_grid.GetOrderCount();
   double gridProfit= g_grid.GetTotalProfit();
   string gridDir   = (g_grid.GetGridDirection() == ORDER_TYPE_BUY) ? "BUY ▲" : "SELL ▼";
   color  gridDirClr= (g_grid.GetGridDirection() == ORDER_TYPE_BUY) ? clrDeepSkyBlue : clrOrangeRed;
   double gridDist  = (g_dyn_grid_dist > 0) ? g_dyn_grid_dist : InpGridDistance;

   int    recCnt    = g_recovery.GetRecoveryCount();
   bool   recActive = (g_state == STATE_RECOVERY);
   double recDist   = (g_dyn_recovery_dist > 0) ? g_dyn_recovery_dist : InpRecoveryDistance;

   bool   trailOn   = g_trailer.IsActive();

   color  profitClr = (gridProfit >= 0) ? clrLimeGreen : clrTomato;
   string profitStr = StringFormat("%+.2f USD", gridProfit);

   // ── คำนวณความสูงทั้งหมด ───────────────────────────────────────
   // Header(2) + กริด(5) + Recovery(4) + Trailing(3) + Trend(5) + บัญชี(4) + padding
   int totalH = 2*lh + 5*lh + 4*lh + 3*lh + 5*lh + 4*lh + 10;

   // ── พื้นหลังหลัก ─────────────────────────────────────────────
   DashRect("BG", ox, oy, W+4, totalH+4, cBg, cBorder);

   int y = oy + 4;

   // ══ Header ══
   DashRect("HDR", ox+2, y, W, 2*lh, cHdr);
   DashLabel("title",  ox + pad, y+2,  "[ GRIDINDY v1.2 ]", clrGold, 9);
   DashLabel("symbol", ox + pad, y+lh, StringFormat("%s  |  Magic:%I64d", _Symbol, InpMagicNumber), clrSilver, 7);
   y += 2*lh + 2;

   // ── สถานะ EA ──
   DashRect("state_bg", ox+2, y, W, lh+2, StateColor(g_state));
   DashLabel("state_lbl", vc, y+2, StateName(g_state), C'12,18,38', 8);
   DashLabel("state_ttl", ox + pad,   y+2, "สถานะ:", clrWhite, 8);
   y += lh + 4;

   // ══ กริดหลัก ══
   DashRect("sec_grid", ox+2, y, W, lh, cSep);
   DashLabel("sec_grid_t", ox + pad, y+1, "กริดหลัก", clrCyan, 8);
   y += lh + 1;

   DashLabel("gdir_l",  ox + pad,       y, "ทิศทาง :", clrSilver, 8);
   DashLabel("gdir_v",  vc,     y, gridCnt > 0 ? gridDir : "-", gridCnt > 0 ? gridDirClr : clrSilver, 8);
   y += lh;
   DashLabel("gcnt_l",  ox + pad,       y, "ไม้เปิด :", clrSilver, 8);
   DashLabel("gcnt_v",  vc,     y, StringFormat("%d / %d", gridCnt, InpMaxGridOrders), clrWhite, 8);
   y += lh;
   DashLabel("gdst_l",  ox + pad,       y, "ระยะกริด:", clrSilver, 8);
   DashLabel("gdst_v",  vc,     y, StringFormat("%.0f pts", gridDist), clrWhite, 8);
   y += lh;
   DashLabel("gpnl_l",  ox + pad,       y, "กำไร/ขาดทุน:", clrSilver, 8);
   DashLabel("gpnl_v",  vc,     y, profitStr, profitClr, 8);
   y += lh;
   DashLabel("gtgt_l",  ox + pad,       y, "เป้ากำไร :", clrSilver, 8);
   DashLabel("gtgt_v",  vc,     y, StringFormat("%.2f USD", InpProfitTarget), clrSilver, 8);
   y += lh + 3;

   // ══ Recovery ══
   color recHdrClr = recActive ? clrOrange : cSep;
   DashRect("sec_rec", ox+2, y, W, lh, recHdrClr);
   DashLabel("sec_rec_t", ox + pad, y+1, "Recovery (Hedge)", recActive ? cBg : clrCyan, 8);
   y += lh + 1;

   DashLabel("rst_l",  ox + pad,   y, "สถานะ   :", clrSilver, 8);
   DashLabel("rst_v",  vc,   y, recActive ? "ทำงาน" : "ปิด", recActive ? clrOrange : clrSilver, 8);
   y += lh;
   DashLabel("rcnt_l", ox + pad,   y, "ชั้น     :", clrSilver, 8);
   DashLabel("rcnt_v", vc,   y, StringFormat("%d / %d", recCnt, InpMaxRecoveryOrders), clrWhite, 8);
   y += lh;
   DashLabel("rdst_l", ox + pad,   y, "ระยะ Rec :", clrSilver, 8);
   DashLabel("rdst_v", vc,   y, StringFormat("%.0f pts  x%.1f", recDist, InpRecoveryMultiplier), clrSilver, 8);
   y += lh + 3;

   // ══ Trailing Stop ══
   color trailHdrClr = trailOn ? clrLimeGreen : cSep;
   DashRect("sec_trail", ox+2, y, W, lh, trailHdrClr);
   DashLabel("sec_trail_t", ox + pad, y+1, "Trailing Stop", trailOn ? cBg : clrCyan, 8);
   y += lh + 1;

   DashLabel("tst_l", ox + pad,  y, "สถานะ    :", clrSilver, 8);
   DashLabel("tst_v", vc,  y, trailOn ? "ใช้งาน" : "รอกำไร", trailOn ? clrLimeGreen : clrSilver, 8);
   y += lh;
   DashLabel("trd_l", ox + pad,  y, "ระยะ Trail:", clrSilver, 8);
   DashLabel("trd_v", vc,  y, StringFormat("%.0f pts / step %.0f", InpTrailDistance, InpTrailStep), clrSilver, 8);
   y += lh + 3;

   // ══ Trend Filter ══
   DashRect("sec_trend", ox+2, y, W, lh, cSep);
   DashLabel("sec_trend_t", ox + pad, y+1, "ตัวกรองเทรน", clrCyan, 8);
   y += lh + 1;

   color adxClr = (adx >= InpAdxThreshold) ? clrLimeGreen : clrTomato;
   DashLabel("adx_l",  ox + pad,  y, "ADX      :", clrSilver, 8);
   DashLabel("adx_v",  vc,  y, StringFormat("%.1f  (>%.0f)", adx, InpAdxThreshold), adxClr, 8);
   y += lh;
   DashLabel("ema_l",  ox + pad,  y, "EMA"+IntegerToString(InpEmaPeriod)+"  :", clrSilver, 8);
   DashLabel("ema_v",  vc,  y, StringFormat("%.2f", ema), clrSilver, 8);
   y += lh;
   color rsiClr = (rsi > 55) ? clrLimeGreen : (rsi < 45 ? clrTomato : clrSilver);
   DashLabel("rsi_l",  ox + pad,  y, "RSI      :", clrSilver, 8);
   DashLabel("rsi_v",  vc,  y, StringFormat("%.1f", rsi), rsiClr, 8);
   y += lh;
   DashLabel("atr_l",  ox + pad,  y, "ATR      :", clrSilver, 8);
   DashLabel("atr_v",  vc,  y, StringFormat("%.0f pts", atr_pts), clrSilver, 8);
   y += lh;
   DashLabel("trnd_l", ox + pad,  y, "เทรน     :", clrSilver, 8);
   DashLabel("trnd_v", vc,  y, trendStr, trendClr, 8);
   y += lh + 3;

   // ══ บัญชี ══
   DashRect("sec_acct", ox+2, y, W, lh, cSep);
   DashLabel("sec_acct_t", ox + pad, y+1, "บัญชี", clrCyan, 8);
   y += lh + 1;

   color ddClr = (dd < 5) ? clrLimeGreen : (dd < 15 ? clrOrange : clrRed);
   DashLabel("eq_l",  ox + pad,  y, "Equity   :", clrSilver, 8);
   DashLabel("eq_v",  vc,  y, StringFormat("%.2f", equity), clrWhite, 8);
   y += lh;
   DashLabel("bal_l", ox + pad,  y, "Balance  :", clrSilver, 8);
   DashLabel("bal_v", vc,  y, StringFormat("%.2f", balance), clrSilver, 8);
   y += lh;
   DashLabel("dd_l",  ox + pad,  y, "Drawdown :", clrSilver, 8);
   DashLabel("dd_v",  vc,  y, StringFormat("%.1f%% (max %.0f%%)", dd, InpMaxDrawdownPct), ddClr, 8);
   y += lh;
   color spClr = (spread <= InpMaxSpreadPoints) ? clrLimeGreen : clrRed;
   DashLabel("sp_l",  ox + pad,  y, "Spread   :", clrSilver, 8);
   DashLabel("sp_v",  vc,  y, StringFormat("%d pts (max %d)", (int)spread, InpMaxSpreadPoints), spClr, 8);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_logger.Init("GINDY", InpVerboseLog);
   g_logger.Info("OnInit: Gridindy v1.2 เริ่มทำงาน...");

   if(InpBaseLot <= 0.0)         { g_logger.Error("BaseLot ต้องมากกว่า 0");         return INIT_PARAMETERS_INCORRECT; }
   if(InpGridDistance <= 0.0)    { g_logger.Error("GridDistance ต้องมากกว่า 0");     return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxGridOrders < 1)      { g_logger.Error("MaxGridOrders ต้องอย่างน้อย 1");  return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxDrawdownPct <= 0.0 || InpMaxDrawdownPct > 100.0)
                                  { g_logger.Error("MaxDrawdownPct ต้องอยู่ใน 0–100"); return INIT_PARAMETERS_INCORRECT; }

   if(!g_trend.Init(InpAdxPeriod, InpAdxThreshold, InpEmaPeriod, InpRsiPeriod,
                    InpAtrPeriod, _Symbol, PERIOD_CURRENT))
   { g_logger.Error("TrendFilter.Init ล้มเหลว"); return INIT_FAILED; }

   if(!g_risk.Init(InpMaxDrawdownPct, _Symbol, InpMagicNumber))
   { g_logger.Error("RiskManager.Init ล้มเหลว"); return INIT_FAILED; }

   if(!g_grid.Init(InpGridDistance, InpMaxGridOrders, InpBaseLot, InpMagicNumber, _Symbol))
   { g_logger.Error("GridManager.Init ล้มเหลว"); return INIT_FAILED; }

   if(!g_recovery.Init(InpRecoveryDistance, InpRecoveryMultiplier,
                       InpMaxRecoveryOrders, InpMagicNumber, _Symbol, &g_grid))
   { g_logger.Error("RecoveryManager.Init ล้มเหลว"); return INIT_FAILED; }

   if(!g_trailer.Init(InpTrailDistance, InpTrailStep, InpMagicNumber, _Symbol))
   { g_logger.Error("TrailingManager.Init ล้มเหลว"); return INIT_FAILED; }

   g_state = STATE_IDLE;
   g_logger.Info(StringFormat("OnInit: OK  %s  magic=%I64d", _Symbol, InpMagicNumber));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   g_trend.Deinit();
   DashDeleteAll();
   g_logger.Info(StringFormat("OnDeinit: reason=%d", reason));
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // Step 1 — หยุดฉุกเฉิน
   if(InpEmergencyStop)
   {
      if(g_state != STATE_EMERGENCY)
      {
         g_logger.Warn("EmergencyStop=true — ปิดทุกไม้");
         g_grid.CloseAll("emergency stop");
         ResetAll();
         ChangeState(STATE_EMERGENCY);
      }
      DrawDashboard();
      return;
   }

   // Step 2 — อัพเดท peak equity
   g_risk.UpdatePeakEquity();

   // Step 3 — ตรวจ drawdown
   if(g_risk.IsDrawdownBreached())
   {
      if(g_state != STATE_EMERGENCY)
      {
         g_logger.Warn(StringFormat("Drawdown %.2f%% เกินขีด %.2f%% — หยุดฉุกเฉิน",
                                    g_risk.GetCurrentDrawdownPct(), InpMaxDrawdownPct));
         g_grid.CloseAll("drawdown breach");
         ResetAll();
         ChangeState(STATE_EMERGENCY);
      }
      DrawDashboard();
      return;
   }

   // Step 4 — จัดการ STATE_EMERGENCY
   if(g_state == STATE_EMERGENCY)
   {
      if(InpEmergencyReset)
      {
         g_logger.Info("EmergencyReset=true — กลับไปรอสัญญาณ");
         ResetAll();
         ChangeState(STATE_IDLE);
      }
      DrawDashboard();
      return;
   }

   // Step 5 — ตรวจการเชื่อมต่อ
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))        { DrawDashboard(); return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))    { DrawDashboard(); return; }

   // Step 6 — ตรวจ spread
   if(!g_risk.IsSymbolTradable(InpMaxSpreadPoints))    { DrawDashboard(); return; }

   // Step 7 — อัพเดท indicator cache
   if(!g_trend.Update())                               { DrawDashboard(); return; }

   // Step 7b — คำนวณระยะ ATR เฉพาะตอนรอสัญญาณ
   if(g_state == STATE_IDLE)
      UpdateATRDistances();

   // Step 8 — sync ไม้กับ server
   g_grid.SyncWithServer();

   // Step 9 — State Machine
   switch(g_state)
   {
      // ─────────────────────────────────────────────────────────────
      case STATE_IDLE:
      {
         if(g_trend.HasTrend() && !g_grid.HasActiveOrders())
         {
            ENUM_ORDER_TYPE dir = g_trend.GetTrendDirection();
            if(g_grid.OpenBaseOrder(dir, InpBaseLot, GridSLPoints()))
            {
               g_logger.Info(StringFormat("เปิดไม้แรก dir=%s  ADX=%.1f  RSI=%.1f",
                                          (dir == ORDER_TYPE_BUY) ? "BUY" : "SELL",
                                          g_trend.GetADX(), g_trend.GetRSI()));
               ChangeState(STATE_GRID_RUNNING);
            }
         }
         break;
      }

      // ─────────────────────────────────────────────────────────────
      case STATE_GRID_RUNNING:
      {
         // ถึงเป้ากำไร → เปิด Trailing
         if(g_grid.GetTotalProfit() >= InpProfitTarget)
         {
            g_logger.Info(StringFormat("ถึงเป้ากำไร %.2f >= %.2f → เปิด Trailing",
                                       g_grid.GetTotalProfit(), InpProfitTarget));
            g_trailer.Activate();
            ChangeState(STATE_TRAILING);
            break;
         }

         // เทรนกลับทิศ + ราคาเคลื่อนพอ → เปิด Recovery
         bool trend_reversed = g_trend.HasTrend() &&
                               (g_trend.GetTrendDirection() != g_grid.GetGridDirection());
         if(trend_reversed && g_recovery.IsRecoveryNeeded() && g_recovery.CanRecover())
         {
            g_logger.Info("เทรนกลับทิศ + ราคาเลยระยะ Recovery → เปิดไม้ hedge");
            g_recovery.OpenRecoveryOrder(InpBaseLot, RecoverySLPoints());
            ChangeState(STATE_RECOVERY);
            break;
         }

         // เทรนเดิม + ราคาเคลื่อนพอ → เพิ่มไม้กริด
         bool trend_same = g_trend.HasTrend() &&
                           (g_trend.GetTrendDirection() == g_grid.GetGridDirection());
         if(trend_same && g_grid.ShouldExpandGrid() && !g_grid.IsGridFull())
         {
            g_logger.Info(StringFormat("เพิ่มไม้กริด %d/%d", g_grid.GetOrderCount(), InpMaxGridOrders));
            g_grid.ExpandGrid(GridSLPoints());
         }
         break;
      }

      // ─────────────────────────────────────────────────────────────
      case STATE_RECOVERY:
      {
         // ถึงเป้ากำไร → Trailing
         if(g_grid.GetTotalProfit() >= InpProfitTarget)
         {
            g_logger.Info(StringFormat("Recovery: ถึงเป้ากำไร %.2f → Trailing", g_grid.GetTotalProfit()));
            g_trailer.Activate();
            ChangeState(STATE_TRAILING);
            break;
         }

         // ราคาวิ่งต่อทิศเดิม → เพิ่มชั้น Recovery
         if(g_recovery.ShouldContinueRecovery() && g_recovery.CanRecover())
         {
            g_logger.Info(StringFormat("Recovery ชั้น %d/%d", g_recovery.GetRecoveryCount(), InpMaxRecoveryOrders));
            g_recovery.OpenRecoveryOrder(InpBaseLot, RecoverySLPoints());
            break;
         }

         // Recovery เต็มและยังขาดทุน → ปิดทั้งหมด รีเซ็ต
         if(!g_recovery.CanRecover() && g_grid.GetTotalProfit() < 0.0)
         {
            g_logger.Warn(StringFormat("Recovery เต็ม %.2f < 0 → ปิดทั้งหมด รีเซ็ต", g_grid.GetTotalProfit()));
            g_grid.CloseAll("recovery exhausted");
            ResetAll();
            ChangeState(STATE_IDLE);
         }
         break;
      }

      // ─────────────────────────────────────────────────────────────
      case STATE_TRAILING:
      {
         g_trailer.UpdateTrails(&g_grid);
         if(!g_grid.HasActiveOrders())
         {
            g_logger.Info("Trailing: ปิดครบทุกไม้ → กลับรอสัญญาณ");
            ResetAll();
            ChangeState(STATE_IDLE);
         }
         break;
      }

      case STATE_EMERGENCY: break;
   }

   // Step 10 — แดชบอร์ด
   DrawDashboard();

   if(InpVerboseLog)
      g_logger.Info(StringFormat("ATR=%.0f  gDist=%.0f  rDist=%.0f  ADX=%.1f  RSI=%.1f",
                                 g_trend.GetATR()/_Point, g_dyn_grid_dist, g_dyn_recovery_dist,
                                 g_trend.GetADX(), g_trend.GetRSI()));
}
