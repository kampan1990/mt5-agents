//+------------------------------------------------------------------+
//|                              EMA_Trend_Pullback_Dashboard.mq5    |
//|  EMA 20/50/200 trend + pullback / crossover signals + dashboard  |
//|  Signals are evaluated on CLOSED bars only (shift 1) -> no repaint|
//+------------------------------------------------------------------+
#property copyright   "EMA Trend Pullback Dashboard"
#property version     "1.00"
#property description "EMA200 trend filter, EMA50 strength/slope, EMA20 pullback entry."
#property description "Filters: HTF trend, slope vs ATR, ADX, sideways (EMA50 crosses), session, spread, ATR range."
#property description "Dashboard shows every condition, final signal, exit warning, SL/TP and last signal."
#property indicator_chart_window
#property indicator_buffers 10
#property indicator_plots   5

#property indicator_label1  "EMA Fast"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_width1  1

#property indicator_label2  "EMA Mid"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrange
#property indicator_width2  2

#property indicator_label3  "EMA Slow"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrRed
#property indicator_width3  2

#property indicator_label4  "Buy"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrLime
#property indicator_width4  2

#property indicator_label5  "Sell"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrMagenta
#property indicator_width5  2

//--- enums
enum ENUM_SIG_MODE   { SIG_PULLBACK = 0, SIG_CROSS = 1, SIG_BOTH = 2 };
enum ENUM_ENTRY_MODE { ENTRY_RECLAIM = 0, ENTRY_BREAK_PREV = 1 };
enum ENUM_EXIT_REF   { EXIT_EMA20 = 0, EXIT_EMA50 = 1 };

//--- inputs
input group "=== EMA / Indicators ==="
input int              InpEmaFast       = 20;          // EMA fast (pullback zone / trail)
input int              InpEmaMid        = 50;          // EMA mid (strength / dynamic S-R)
input int              InpEmaSlow       = 200;         // EMA slow (main trend filter)
input int              InpAtrPeriod     = 14;          // ATR period
input int              InpAdxPeriod     = 14;          // ADX period

input group "=== Signal type ==="
input ENUM_SIG_MODE    InpSigMode       = SIG_BOTH;    // Signal mode
input ENUM_ENTRY_MODE  InpEntryMode     = ENTRY_RECLAIM; // Pullback trigger
input int              InpPullbackBars  = 5;           // Look-back bars for EMA20 touch
input double           InpMaxDist       = 1.5;         // Max distance from EMA20 (x ATR) - no chasing
input double           InpCrossGap      = 0.15;        // Crossover min gap EMA20-EMA50 (x ATR)

input group "=== Trend filters ==="
input bool             InpUseHTF        = true;        // Use higher-timeframe trend
input ENUM_TIMEFRAMES  InpHTF           = PERIOD_H4;   // Higher timeframe (should be > chart TF)
input int              InpHtfFast       = 50;          // HTF EMA fast
input int              InpHtfSlow       = 200;         // HTF EMA slow
input bool             InpUseSlope      = true;        // Use EMA50 slope filter
input int              InpSlopeBars     = 5;           // Slope look-back bars
input double           InpSlopeMult     = 0.3;         // Min slope (x ATR)
input bool             InpUseAdx        = true;        // Use ADX filter
input double           InpAdxMin        = 20.0;        // Min ADX
input bool             InpUseCross      = true;        // Use sideways filter (EMA50 crosses)
input int              InpCrossLookback = 20;          // Cross look-back bars
input int              InpMaxCrosses    = 3;           // Block when crosses >= this

input group "=== Market filters ==="
input bool             InpUseSession    = false;       // Use session filter (server hour)
input int              InpSessStart     = 7;           // Session start hour
input int              InpSessEnd       = 21;          // Session end hour
input int              InpMaxSpread     = 0;           // Max spread in points (0 = off)
input double           InpMinAtrPts     = 0;           // Min ATR in points (0 = off)
input double           InpMaxAtrPts     = 0;           // Max ATR in points (0 = off)

input group "=== Risk display / Exit ==="
input double           InpSlAtr         = 1.5;         // SL distance (x ATR)
input double           InpRR            = 2.0;         // Take-profit risk:reward
input int              InpSwingBars     = 10;          // Swing SL look-back bars
input ENUM_EXIT_REF    InpExitRef       = EXIT_EMA50;  // Exit when close crosses this EMA

input group "=== Display / Alerts ==="
input int              InpMaxBars       = 3000;        // Max history bars to calculate
input bool             InpShowDash      = true;        // Show dashboard
input int              InpDashX         = 10;          // Dashboard X
input int              InpDashY         = 20;          // Dashboard Y
input int              InpFontSize      = 9;           // Dashboard font size
input bool             InpAlertPopup    = true;        // Alert: popup
input bool             InpAlertPush     = false;       // Alert: push notification

//--- buffers
double bEmaF[], bEmaM[], bEmaS[];
double bBuy[], bSell[];
double bAtr[], bAdx[], bHtfF[], bHtfS[];
double bSigType[];   // signed: +type = buy, -type = sell ; type 1=PB 2=CROSS 3=both

//--- handles
int hF = INVALID_HANDLE, hM = INVALID_HANDLE, hS = INVALID_HANDLE;
int hAtr = INVALID_HANDLE, hAdx = INVALID_HANDLE;
int hHF = INVALID_HANDLE, hHS = INVALID_HANDLE;

datetime g_lastBar = 0;
int      g_row     = 0;

#define PFX    "ETP_"
#define ROW_H  (InpFontSize + 9)

//--- evaluation result
struct SEval
  {
   int    trend;      // +1 / -1 / 0
   int    htf;        // +1 / -1 / 0 (0 = n/a)
   double atr, atrPts, adx, slope, dist;
   int    crosses;
   int    crossSig;   // crossover signal +1/-1/0
   int    spreadPts;
   bool   htfOk, slopeOk, adxOk, crossOk, distOk;
   bool   touch, pbTrig;
   bool   sessionOk, spreadOk, atrOk;
   int    sig;        // final +1/-1/0
   int    sigType;    // 1 PB, 2 CROSS, 3 both
  };

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, bEmaF,    INDICATOR_DATA);
   SetIndexBuffer(1, bEmaM,    INDICATOR_DATA);
   SetIndexBuffer(2, bEmaS,    INDICATOR_DATA);
   SetIndexBuffer(3, bBuy,     INDICATOR_DATA);
   SetIndexBuffer(4, bSell,    INDICATOR_DATA);
   SetIndexBuffer(5, bAtr,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, bAdx,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, bHtfF,    INDICATOR_CALCULATIONS);
   SetIndexBuffer(8, bHtfS,    INDICATOR_CALCULATIONS);
   SetIndexBuffer(9, bSigType, INDICATOR_CALCULATIONS);

   PlotIndexSetInteger(3, PLOT_ARROW, 233);
   PlotIndexSetInteger(4, PLOT_ARROW, 234);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(4, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, InpEmaFast);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, InpEmaMid);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, InpEmaSlow);

   hF   = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hM   = iMA(_Symbol, _Period, InpEmaMid,  0, MODE_EMA, PRICE_CLOSE);
   hS   = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hAtr = iATR(_Symbol, _Period, InpAtrPeriod);
   hAdx = iADX(_Symbol, _Period, InpAdxPeriod);
   if(InpUseHTF)
     {
      hHF = iMA(_Symbol, InpHTF, InpHtfFast, 0, MODE_EMA, PRICE_CLOSE);
      hHS = iMA(_Symbol, InpHTF, InpHtfSlow, 0, MODE_EMA, PRICE_CLOSE);
      if(hHF == INVALID_HANDLE || hHS == INVALID_HANDLE)
         return INIT_FAILED;
     }
   if(hF == INVALID_HANDLE || hM == INVALID_HANDLE || hS == INVALID_HANDLE ||
      hAtr == INVALID_HANDLE || hAdx == INVALID_HANDLE)
      return INIT_FAILED;

   IndicatorSetString(INDICATOR_SHORTNAME, "EMA Trend Pullback");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PFX);
   int hs[] = {hF, hM, hS, hAtr, hAdx, hHF, hHS};
   for(int k = 0; k < ArraySize(hs); k++)
      if(hs[k] != INVALID_HANDLE)
         IndicatorRelease(hs[k]);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Evaluate every condition on CLOSED bar i                         |
//+------------------------------------------------------------------+
void Evaluate(const int i, const datetime &time[], const double &high[], const double &low[],
              const double &close[], const int &spread[], SEval &r)
  {
   ZeroMemory(r);
   const double c = close[i];
   r.atr = bAtr[i];
   r.adx = bAdx[i];

   //--- trend bias (EMA200 + EMA50 vs EMA200)
   if(c > bEmaS[i] && bEmaM[i] > bEmaS[i])
      r.trend = 1;
   else
      if(c < bEmaS[i] && bEmaM[i] < bEmaS[i])
         r.trend = -1;

   //--- HTF
   if(InpUseHTF && bHtfF[i] != 0.0 && bHtfS[i] != 0.0)
      r.htf = (bHtfF[i] > bHtfS[i]) ? 1 : (bHtfF[i] < bHtfS[i] ? -1 : 0);

   //--- slope (EMA50 change over N bars in ATR units)
   if(r.atr > 0 && i >= InpSlopeBars)
      r.slope = (bEmaM[i] - bEmaM[i - InpSlopeBars]) / r.atr;

   //--- sideways: count close crossing EMA50
   int cnt = 0;
   for(int j = i - InpCrossLookback + 1; j <= i; j++)
     {
      if(j < 1)
         continue;
      double a = close[j - 1] - bEmaM[j - 1];
      double b = close[j]     - bEmaM[j];
      if(a * b < 0)
         cnt++;
     }
   r.crosses = cnt;

   //--- distance from EMA20 (signed, in ATR)
   if(r.atr > 0)
      r.dist = (c - bEmaF[i]) / r.atr;

   //--- crossover EMA20/EMA50 (cross on bar i-1, confirmed on bar i, gap > x ATR)
   if(i >= 2 && r.atr > 0)
     {
      bool up = bEmaF[i - 2] <= bEmaM[i - 2] && bEmaF[i - 1] > bEmaM[i - 1] && bEmaF[i] > bEmaM[i];
      bool dn = bEmaF[i - 2] >= bEmaM[i - 2] && bEmaF[i - 1] < bEmaM[i - 1] && bEmaF[i] < bEmaM[i];
      if(MathAbs(bEmaF[i] - bEmaM[i]) >= InpCrossGap * r.atr)
        {
         if(up)
            r.crossSig = 1;
         else
            if(dn)
               r.crossSig = -1;
        }
     }

   //--- market filters
   MqlDateTime dt;
   TimeToStruct(time[i], dt);
   r.sessionOk = !InpUseSession ||
                 (InpSessStart <= InpSessEnd ? (dt.hour >= InpSessStart && dt.hour < InpSessEnd)
                  : (dt.hour >= InpSessStart || dt.hour < InpSessEnd));
   r.spreadPts = spread[i];
   r.spreadOk  = (InpMaxSpread <= 0) || spread[i] <= InpMaxSpread;
   r.atrPts    = r.atr / _Point;
   r.atrOk     = (InpMinAtrPts <= 0 || r.atrPts >= InpMinAtrPts) &&
                 (InpMaxAtrPts <= 0 || r.atrPts <= InpMaxAtrPts);

   //--- direction dependent checks
   const int d = r.trend;
   if(d == 0)
      return;

   r.htfOk   = !InpUseHTF || r.htf == d;
   r.slopeOk = !InpUseSlope || (d == 1 ? r.slope >= InpSlopeMult : r.slope <= -InpSlopeMult);
   r.adxOk   = !InpUseAdx || r.adx >= InpAdxMin;
   r.crossOk = !InpUseCross || r.crosses < InpMaxCrosses;
   r.distOk  = d * r.dist <= InpMaxDist;

   //--- pullback touch of EMA20 within last N bars
   for(int j = i - InpPullbackBars; j <= i - 1; j++)
     {
      if(j < 0)
         continue;
      if(d == 1 ? low[j] <= bEmaF[j] : high[j] >= bEmaF[j])
        {
         r.touch = true;
         break;
        }
     }

   //--- pullback trigger
   bool holdZone = (d == 1) ? c > bEmaM[i] : c < bEmaM[i];     // pullback must hold above/below EMA50
   bool trig;
   if(InpEntryMode == ENTRY_RECLAIM)
      trig = (d == 1) ? (close[i - 1] <= bEmaF[i - 1] && c > bEmaF[i])
             : (close[i - 1] >= bEmaF[i - 1] && c < bEmaF[i]);
   else
      trig = (d == 1) ? (c > high[i - 1] && c > bEmaF[i])
             : (c < low[i - 1]  && c < bEmaF[i]);
   r.pbTrig = r.touch && holdZone && trig;

   //--- final signal
   bool base = r.htfOk && r.slopeOk && r.adxOk && r.crossOk && r.sessionOk && r.spreadOk && r.atrOk;
   bool pb   = (InpSigMode != SIG_CROSS) && r.pbTrig && r.distOk;
   bool cx   = (InpSigMode != SIG_PULLBACK) && r.crossSig == d;
   if(base && (pb || cx))
     {
      r.sig     = d;
      r.sigType = (pb ? 1 : 0) + (cx ? 2 : 0);
     }
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
  {
   const int minBars = InpEmaSlow + InpCrossLookback + InpSlopeBars + InpPullbackBars + 10;
   if(rates_total < minBars)
      return 0;

   if(BarsCalculated(hF) < rates_total || BarsCalculated(hM) < rates_total ||
      BarsCalculated(hS) < rates_total || BarsCalculated(hAtr) < rates_total ||
      BarsCalculated(hAdx) < rates_total)
      return 0;
   if(InpUseHTF && (BarsCalculated(hHF) <= 0 || BarsCalculated(hHS) <= 0))
      return 0;

   int to_copy = (prev_calculated <= 0 || prev_calculated > rates_total) ? rates_total
                 : rates_total - prev_calculated + 1;
   if(CopyBuffer(hF,   0, 0, to_copy, bEmaF) <= 0) return 0;
   if(CopyBuffer(hM,   0, 0, to_copy, bEmaM) <= 0) return 0;
   if(CopyBuffer(hS,   0, 0, to_copy, bEmaS) <= 0) return 0;
   if(CopyBuffer(hAtr, 0, 0, to_copy, bAtr)  <= 0) return 0;
   if(CopyBuffer(hAdx, 0, 0, to_copy, bAdx)  <= 0) return 0;

   int start;
   if(prev_calculated <= 0 || prev_calculated > rates_total)
     {
      ArrayInitialize(bBuy, 0.0);
      ArrayInitialize(bSell, 0.0);
      ArrayInitialize(bHtfF, 0.0);
      ArrayInitialize(bHtfS, 0.0);
      ArrayInitialize(bSigType, 0.0);
      start = MathMax(minBars, rates_total - InpMaxBars);
     }
   else
      start = prev_calculated - 1;

   const int ei = rates_total - 2;   // last CLOSED bar

   for(int i = start; i <= rates_total - 1; i++)
     {
      bBuy[i] = 0.0;
      bSell[i] = 0.0;
      bSigType[i] = 0.0;
      if(i > ei)
         continue;                    // forming bar: no signal

      //--- HTF values from the last CLOSED higher-TF bar (no look-ahead)
      bHtfF[i] = 0.0;
      bHtfS[i] = 0.0;
      if(InpUseHTF)
        {
         int sh = iBarShift(_Symbol, InpHTF, time[i], false);
         double f[1], s[1];
         if(sh >= 0 && CopyBuffer(hHF, 0, sh + 1, 1, f) == 1 && CopyBuffer(hHS, 0, sh + 1, 1, s) == 1 &&
            f[0] != EMPTY_VALUE && s[0] != EMPTY_VALUE)
           {
            bHtfF[i] = f[0];
            bHtfS[i] = s[0];
           }
        }

      SEval r;
      Evaluate(i, time, high, low, close, spread, r);
      if(r.sig == 1)
        {
         bBuy[i] = low[i] - 0.6 * r.atr;
         bSigType[i] = r.sigType;
        }
      else
         if(r.sig == -1)
           {
            bSell[i] = high[i] + 0.6 * r.atr;
            bSigType[i] = -r.sigType;
           }
     }

   //--- current state for dashboard / alerts
   SEval ev;
   Evaluate(ei, time, high, low, close, spread, ev);

   if(time[ei] != g_lastBar)
     {
      if(g_lastBar != 0 && ev.sig != 0)
         SendAlerts(ev, time[ei], close[ei]);
      g_lastBar = time[ei];
     }

   if(InpShowDash)
      DrawDashboard(ei, time, high, low, close, ev);

   return rates_total;
  }

//+------------------------------------------------------------------+
string TypeText(const int t)
  {
   if(t == 1) return "PB";
   if(t == 2) return "CROSS";
   if(t == 3) return "PB+CROSS";
   return "-";
  }

string TfText(const ENUM_TIMEFRAMES tf)
  {
   return StringSubstr(EnumToString(tf), 7);
  }

void SendAlerts(const SEval &ev, const datetime t, const double price)
  {
   string msg = StringFormat("%s %s: %s signal (%s) @ %s  closed bar %s",
                             _Symbol, TfText((ENUM_TIMEFRAMES)_Period),
                             ev.sig == 1 ? "BUY" : "SELL", TypeText(ev.sigType),
                             DoubleToString(price, _Digits), TimeToString(t, TIME_DATE | TIME_MINUTES));
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
  }

//+------------------------------------------------------------------+
//| Dashboard helpers                                                |
//+------------------------------------------------------------------+
void PutLabel(const string name, const int x, const int y, const string text, const color clr)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
     }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

void Row(const string label, const string value, const color vc)
  {
   int y = InpDashY + 28 + g_row * ROW_H;
   PutLabel(PFX + "L" + IntegerToString(g_row), InpDashX + 10,  y, label, clrSilver);
   PutLabel(PFX + "V" + IntegerToString(g_row), InpDashX + 175, y, value, vc);
   g_row++;
  }

color PassColor(const bool hasDir, const bool ok)
  {
   if(!hasDir) return clrGray;
   return ok ? clrLime : clrTomato;
  }

string YesNo(const bool b) { return b ? "YES" : "NO"; }

//+------------------------------------------------------------------+
void DrawDashboard(const int ei, const datetime &time[], const double &high[], const double &low[],
                   const double &close[], const SEval &ev)
  {
   const string bg = PFX + "BG";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'18,22,30');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpDashX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpDashY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, 370);

   PutLabel(PFX + "T", InpDashX + 10, InpDashY + 6,
            "EMA TREND PULLBACK | " + _Symbol + " " + TfText((ENUM_TIMEFRAMES)_Period), clrWhite);

   g_row = 0;
   const int  d      = ev.trend;
   const bool hasDir = (d != 0);

   Row("Closed bar", TimeToString(time[ei], TIME_DATE | TIME_MINUTES), clrSilver);

   //--- final signal
   string sigTxt = "WAIT";
   color  sigCol = clrGray;
   if(ev.sig == 1)       { sigTxt = "BUY  (" + TypeText(ev.sigType) + ")";  sigCol = clrLime; }
   else if(ev.sig == -1) { sigTxt = "SELL (" + TypeText(ev.sigType) + ")";  sigCol = clrMagenta; }
   Row("SIGNAL", sigTxt, sigCol);

   Row("Bias EMA" + IntegerToString(InpEmaSlow) + "/" + IntegerToString(InpEmaMid),
       d == 1 ? "BULLISH" : (d == -1 ? "BEARISH" : "NEUTRAL"),
       d == 1 ? clrLime : (d == -1 ? clrTomato : clrGray));

   //--- HTF
   string htfTxt = !InpUseHTF ? "OFF" : (ev.htf == 1 ? "BULL" : (ev.htf == -1 ? "BEAR" : "N/A"));
   Row("HTF " + TfText(InpHTF) + " EMA" + IntegerToString(InpHtfFast) + "/" + IntegerToString(InpHtfSlow),
       htfTxt, !InpUseHTF ? clrGray : PassColor(hasDir, ev.htfOk));

   Row("EMA" + IntegerToString(InpEmaMid) + " slope (xATR)",
       StringFormat("%.2f  need %s%.2f", ev.slope, d == -1 ? "<-" : ">", InpSlopeMult),
       !InpUseSlope ? clrGray : PassColor(hasDir, ev.slopeOk));

   Row("ADX(" + IntegerToString(InpAdxPeriod) + ")",
       StringFormat("%.1f  need >%.0f", ev.adx, InpAdxMin),
       !InpUseAdx ? clrGray : PassColor(hasDir, ev.adxOk));

   Row("EMA" + IntegerToString(InpEmaMid) + " crosses/" + IntegerToString(InpCrossLookback),
       StringFormat("%d  block >=%d", ev.crosses, InpMaxCrosses),
       !InpUseCross ? clrGray : PassColor(hasDir, ev.crossOk));

   Row("Touch EMA" + IntegerToString(InpEmaFast) + " (" + IntegerToString(InpPullbackBars) + " bars)",
       YesNo(ev.touch), hasDir ? (ev.touch ? clrLime : clrSilver) : clrGray);

   Row(InpEntryMode == ENTRY_RECLAIM ? "Trigger: reclaim EMA" + IntegerToString(InpEmaFast)
       : "Trigger: break prev H/L",
       YesNo(ev.pbTrig), hasDir ? (ev.pbTrig ? clrLime : clrSilver) : clrGray);

   Row("Dist EMA" + IntegerToString(InpEmaFast) + " (xATR)",
       StringFormat("%.2f  max %.1f", hasDir ? d * ev.dist : ev.dist, InpMaxDist),
       PassColor(hasDir, ev.distOk));

   Row("Cross EMA" + IntegerToString(InpEmaFast) + "/" + IntegerToString(InpEmaMid),
       ev.crossSig == 1 ? "BUY" : (ev.crossSig == -1 ? "SELL" : "NONE"),
       ev.crossSig == 1 ? clrLime : (ev.crossSig == -1 ? clrMagenta : clrGray));

   Row("Session (server hr)",
       !InpUseSession ? "OFF" : (ev.sessionOk ? "OK" : "BLOCKED"),
       !InpUseSession ? clrGray : (ev.sessionOk ? clrLime : clrTomato));

   Row("Spread (pts)",
       InpMaxSpread <= 0 ? IntegerToString(ev.spreadPts) + "  (no limit)"
       : IntegerToString(ev.spreadPts) + "  max " + IntegerToString(InpMaxSpread),
       InpMaxSpread <= 0 ? clrGray : (ev.spreadOk ? clrLime : clrTomato));

   Row("ATR (pts)",
       StringFormat("%.0f", ev.atrPts),
       (InpMinAtrPts <= 0 && InpMaxAtrPts <= 0) ? clrGray : (ev.atrOk ? clrLime : clrTomato));

   //--- exit warnings
   double exitRef = (InpExitRef == EXIT_EMA20) ? bEmaF[ei] : bEmaM[ei];
   string exitNm  = (InpExitRef == EXIT_EMA20) ? IntegerToString(InpEmaFast) : IntegerToString(InpEmaMid);
   bool exLong  = close[ei] < exitRef;
   bool exShort = close[ei] > exitRef;
   Row("Exit LONG  (close<EMA" + exitNm + ")",  exLong  ? "TRIGGERED" : "hold", exLong  ? clrTomato : clrSilver);
   Row("Exit SHORT (close>EMA" + exitNm + ")",  exShort ? "TRIGGERED" : "hold", exShort ? clrTomato : clrSilver);

   //--- SL / TP suggestion
   int sd = (ev.sig != 0) ? ev.sig : ev.trend;
   if(sd != 0 && ev.atr > 0)
     {
      double entry = close[ei];
      double slA   = entry - sd * InpSlAtr * ev.atr;
      double swing = (sd == 1) ? low[ei] : high[ei];
      for(int k = ei - InpSwingBars + 1; k <= ei; k++)
        {
         if(k < 0) continue;
         if(sd == 1) swing = MathMin(swing, low[k]);
         else        swing = MathMax(swing, high[k]);
        }
      double tp = entry + sd * InpRR * InpSlAtr * ev.atr;
      string who = (ev.sig != 0) ? (sd == 1 ? "BUY" : "SELL") : (sd == 1 ? "bias long" : "bias short");
      Row("Entry ref (" + who + ")", DoubleToString(entry, _Digits), clrSilver);
      Row("SL ATR x" + DoubleToString(InpSlAtr, 1), DoubleToString(slA, _Digits), clrTomato);
      Row("SL swing " + IntegerToString(InpSwingBars) + " bars", DoubleToString(swing, _Digits), clrTomato);
      Row("TP RR " + DoubleToString(InpRR, 1), DoubleToString(tp, _Digits), clrLime);
     }
   else
     {
      Row("Entry ref", "-", clrGray);
      Row("SL ATR", "-", clrGray);
      Row("SL swing", "-", clrGray);
      Row("TP", "-", clrGray);
     }

   //--- last signal in history
   int ls = -1;
   for(int k = ei; k >= 0 && k > ei - InpMaxBars; k--)
      if(bSigType[k] != 0.0)
        {
         ls = k;
         break;
        }
   if(ls >= 0)
     {
      int  t   = (int)MathAbs(bSigType[ls]);
      bool buy = bSigType[ls] > 0;
      Row("Last signal", StringFormat("%s (%s) %d bars ago", buy ? "BUY" : "SELL", TypeText(t), ei - ls),
          buy ? clrLime : clrMagenta);
      Row("  at", TimeToString(time[ls], TIME_DATE | TIME_MINUTES), clrSilver);
     }
   else
     {
      Row("Last signal", "none", clrGray);
      Row("  at", "-", clrGray);
     }

   ObjectSetInteger(0, bg, OBJPROP_YSIZE, 40 + g_row * ROW_H);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
