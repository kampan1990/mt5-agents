//+------------------------------------------------------------------+
//| Dashboard.mqh                                                     |
//| GridADXEMARSI EA — visual on-chart dashboard (top-left corner)   |
//| Uses OBJ_RECTANGLE_LABEL + OBJ_LABEL chart objects for color     |
//+------------------------------------------------------------------+
#ifndef DASHBOARD_MQH
#define DASHBOARD_MQH

// ── Layout ──────────────────────────────────────────────────────────
#define DASH_X          10          // left margin from corner
#define DASH_Y          15          // top margin from corner
#define DASH_ROW_H      18          // pixels per row
#define DASH_W          295         // panel total width
#define DASH_X_VAL      155         // x-offset where value column starts
#define DASH_FONT       "Consolas"
#define DASH_FS_TITLE   10
#define DASH_FS_BODY    9
#define DASH_CORNER     CORNER_LEFT_UPPER
#define DASH_SEP_LINE   "─────────────────────────────"

// ── Row indices ─────────────────────────────────────────────────────
#define DR_TITLE        0
#define DR_TIME         1
#define DR_STATE        2
#define DR_SEP1         3
#define DR_TREND_H      4
#define DR_ADX          5
#define DR_RSI          6
#define DR_EMA          7
#define DR_ATR          8
#define DR_SEP2         9
#define DR_GRID_H       10
#define DR_GRID_DIR     11
#define DR_GRID_CNT     12
#define DR_GRID_DST     13
#define DR_SEP3         14
#define DR_REC_H        15
#define DR_REC_CNT      16
#define DR_REC_DST      17
#define DR_SEP4         18
#define DR_PERF_H       19
#define DR_PNL          20
#define DR_TARGET       21
#define DR_DD           22
#define DR_ROW_TOTAL    23          // total rows → used for panel height

//+------------------------------------------------------------------+
//| CDashboard — creates and updates chart-object panel              |
//+------------------------------------------------------------------+
class CDashboard
{
private:
   long    m_chart;
   string  m_pfx;
   int     m_win;
   bool    m_ready;

   // ── Internal helpers ──────────────────────────────────────────
   string N(string id)   { return m_pfx + id; }
   int    RY(int row)    { return DASH_Y + row * DASH_ROW_H; }
   int    XV()           { return DASH_X + DASH_X_VAL; }

   void CreateBG()
   {
      string n = N("BG");
      if(ObjectFind(m_chart, n) >= 0) return;
      ObjectCreate(m_chart, n, OBJ_RECTANGLE_LABEL, m_win, 0, 0);
      ObjectSetInteger(m_chart, n, OBJPROP_CORNER,      DASH_CORNER);
      ObjectSetInteger(m_chart, n, OBJPROP_XDISTANCE,   DASH_X - 8);
      ObjectSetInteger(m_chart, n, OBJPROP_YDISTANCE,   DASH_Y - 8);
      ObjectSetInteger(m_chart, n, OBJPROP_XSIZE,       DASH_W);
      ObjectSetInteger(m_chart, n, OBJPROP_YSIZE,       DR_ROW_TOTAL * DASH_ROW_H + 12);
      ObjectSetInteger(m_chart, n, OBJPROP_BGCOLOR,     C'12,18,38');
      ObjectSetInteger(m_chart, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(m_chart, n, OBJPROP_COLOR,       clrSteelBlue);
      ObjectSetInteger(m_chart, n, OBJPROP_WIDTH,       1);
      ObjectSetInteger(m_chart, n, OBJPROP_BACK,        true);
      ObjectSetInteger(m_chart, n, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(m_chart, n, OBJPROP_HIDDEN,      true);
   }

   // Create a static text label (created once, never updated)
   void MkStatic(string id, int row, int x, string txt, color clr, int fsz = DASH_FS_BODY)
   {
      string n = N(id);
      if(ObjectFind(m_chart, n) >= 0) return;
      ObjectCreate(m_chart, n, OBJ_LABEL, m_win, 0, 0);
      ObjectSetInteger(m_chart, n, OBJPROP_CORNER,     DASH_CORNER);
      ObjectSetInteger(m_chart, n, OBJPROP_XDISTANCE,  x);
      ObjectSetInteger(m_chart, n, OBJPROP_YDISTANCE,  RY(row));
      ObjectSetString(m_chart,  n, OBJPROP_TEXT,       txt);
      ObjectSetString(m_chart,  n, OBJPROP_FONT,       DASH_FONT);
      ObjectSetInteger(m_chart, n, OBJPROP_FONTSIZE,   fsz);
      ObjectSetInteger(m_chart, n, OBJPROP_COLOR,      clr);
      ObjectSetInteger(m_chart, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chart, n, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(m_chart, n, OBJPROP_BACK,       false);
   }

   // Create-or-update a dynamic value label
   void SetVal(string id, int row, string txt, color clr)
   {
      string n = N(id);
      if(ObjectFind(m_chart, n) < 0)
      {
         ObjectCreate(m_chart, n, OBJ_LABEL, m_win, 0, 0);
         ObjectSetInteger(m_chart, n, OBJPROP_CORNER,     DASH_CORNER);
         ObjectSetInteger(m_chart, n, OBJPROP_XDISTANCE,  XV());
         ObjectSetInteger(m_chart, n, OBJPROP_YDISTANCE,  RY(row));
         ObjectSetString(m_chart,  n, OBJPROP_FONT,       DASH_FONT);
         ObjectSetInteger(m_chart, n, OBJPROP_FONTSIZE,   DASH_FS_BODY);
         ObjectSetInteger(m_chart, n, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(m_chart, n, OBJPROP_HIDDEN,     true);
         ObjectSetInteger(m_chart, n, OBJPROP_BACK,       false);
      }
      ObjectSetString(m_chart,  n, OBJPROP_TEXT,  txt);
      ObjectSetInteger(m_chart, n, OBJPROP_COLOR, clr);
   }

   // Build all static labels (labels that never change text)
   void BuildStatic()
   {
      CreateBG();

      // ── Title bar ───────────────────────────────────────────────
      MkStatic("T_NAME", DR_TITLE, DASH_X,       "◈  GridADXEMARSI EA",  clrGold,       DASH_FS_TITLE);
      MkStatic("T_VER",  DR_TITLE, DASH_X + 210, "v1.0",                  clrDimGray);

      // ── Time / State ────────────────────────────────────────────
      MkStatic("L_TIME",  DR_TIME,  DASH_X, "Time    :", clrSlateGray);
      MkStatic("L_STATE", DR_STATE, DASH_X, "State   :", clrSlateGray);

      // ── Separators ──────────────────────────────────────────────
      MkStatic("SEP1", DR_SEP1, DASH_X, DASH_SEP_LINE, C'30,50,90');
      MkStatic("SEP2", DR_SEP2, DASH_X, DASH_SEP_LINE, C'30,50,90');
      MkStatic("SEP3", DR_SEP3, DASH_X, DASH_SEP_LINE, C'30,50,90');
      MkStatic("SEP4", DR_SEP4, DASH_X, DASH_SEP_LINE, C'30,50,90');

      // ── Section headers ─────────────────────────────────────────
      MkStatic("H_TREND", DR_TREND_H, DASH_X, "▸ TREND FILTER",  clrSteelBlue);
      MkStatic("H_GRID",  DR_GRID_H,  DASH_X, "▸ GRID",           clrDodgerBlue);
      MkStatic("H_REC",   DR_REC_H,   DASH_X, "▸ RECOVERY",       C'255,120,0');
      MkStatic("H_PERF",  DR_PERF_H,  DASH_X, "▸ PERFORMANCE",    clrMediumPurple);

      // ── Field labels ────────────────────────────────────────────
      MkStatic("L_ADX",  DR_ADX,      DASH_X, "ADX     :", clrSlateGray);
      MkStatic("L_RSI",  DR_RSI,      DASH_X, "RSI     :", clrSlateGray);
      MkStatic("L_EMA",  DR_EMA,      DASH_X, "EMA     :", clrSlateGray);
      MkStatic("L_ATR",  DR_ATR,      DASH_X, "ATR     :", clrSlateGray);
      MkStatic("L_GDIR", DR_GRID_DIR, DASH_X, "Direction:", clrSlateGray);
      MkStatic("L_GCNT", DR_GRID_CNT, DASH_X, "Orders  :", clrSlateGray);
      MkStatic("L_GDST", DR_GRID_DST, DASH_X, "Dist    :", clrSlateGray);
      MkStatic("L_RCNT", DR_REC_CNT,  DASH_X, "Layers  :", clrSlateGray);
      MkStatic("L_RDST", DR_REC_DST,  DASH_X, "Dist    :", clrSlateGray);
      MkStatic("L_PNL",  DR_PNL,      DASH_X, "Float P&L:", clrSlateGray);
      MkStatic("L_TGT",  DR_TARGET,   DASH_X, "Target  :", clrSlateGray);
      MkStatic("L_DD",   DR_DD,       DASH_X, "Drawdown:", clrSlateGray);

      // ── Value placeholders ───────────────────────────────────────
      SetVal("V_TIME",  DR_TIME,     "──────────────", clrDimGray);
      SetVal("V_STATE", DR_STATE,    "──────────────", clrDimGray);
      SetVal("V_ADX",   DR_ADX,      "──────────────", clrDimGray);
      SetVal("V_RSI",   DR_RSI,      "──────────────", clrDimGray);
      SetVal("V_EMA",   DR_EMA,      "──────────────", clrDimGray);
      SetVal("V_ATR",   DR_ATR,      "──────────────", clrDimGray);
      SetVal("V_GDIR",  DR_GRID_DIR, "──────────────", clrDimGray);
      SetVal("V_GCNT",  DR_GRID_CNT, "──────────────", clrDimGray);
      SetVal("V_GDST",  DR_GRID_DST, "──────────────", clrDimGray);
      SetVal("V_RCNT",  DR_REC_CNT,  "──────────────", clrDimGray);
      SetVal("V_RDST",  DR_REC_DST,  "──────────────", clrDimGray);
      SetVal("V_PNL",   DR_PNL,      "──────────────", clrDimGray);
      SetVal("V_TGT",   DR_TARGET,   "──────────────", clrDimGray);
      SetVal("V_DD",    DR_DD,       "──────────────", clrDimGray);
   }

public:
   CDashboard() : m_chart(0), m_pfx("GADX_DB_"), m_win(0), m_ready(false) {}

   bool Init(string prefix = "GADX_DB_")
   {
      m_chart = ChartID();
      m_pfx   = prefix;
      m_win   = 0;
      BuildStatic();
      m_ready = true;
      ChartRedraw(m_chart);
      return true;
   }

   void Deinit()
   {
      for(int i = ObjectsTotal(m_chart, m_win) - 1; i >= 0; i--)
      {
         string nm = ObjectName(m_chart, i, m_win);
         if(StringFind(nm, m_pfx) == 0)
            ObjectDelete(m_chart, nm);
      }
      m_ready = false;
      ChartRedraw(m_chart);
   }

   //--- Call every tick to refresh all dynamic values
   void Update(int    ea_state,
               double adx,      double adx_thresh,
               double rsi,
               double ema,
               double atr,
               int    grid_dir,  // -1=none  0=BUY  1=SELL
               int    grid_cnt,  int max_grid,
               double grid_dist,
               int    rec_cnt,   int max_rec,
               double rec_dist,
               double pnl,
               double target,
               double dd_pct)
   {
      if(!m_ready) return;

      // ── Time ────────────────────────────────────────────────────
      SetVal("V_TIME", DR_TIME,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
             clrSilver);

      // ── State ───────────────────────────────────────────────────
      string sn; color sc;
      switch(ea_state)
      {
         case 0: sn = "● IDLE";          sc = clrSilver;        break;
         case 1: sn = "▶ GRID RUNNING";  sc = clrDodgerBlue;    break;
         case 2: sn = "↺ RECOVERY";      sc = C'255,120,0';     break;
         case 3: sn = "✦ TRAILING";      sc = clrGold;          break;
         case 4: sn = "✖ EMERGENCY";     sc = clrRed;           break;
         default: sn = "? UNKNOWN";      sc = clrWhite;         break;
      }
      SetVal("V_STATE", DR_STATE, sn, sc);

      // ── ADX ─────────────────────────────────────────────────────
      bool strong = (adx >= adx_thresh);
      SetVal("V_ADX", DR_ADX,
             StringFormat("%.2f  %s", adx, strong ? "▲ TREND" : "▬ WEAK"),
             strong ? clrLime : clrOrangeRed);

      // ── RSI ─────────────────────────────────────────────────────
      color rc; string rs;
      if(rsi >= 70.0)      { rc = clrRed;        rs = StringFormat("%.2f  ▲ OVERBOUGHT", rsi); }
      else if(rsi <= 30.0) { rc = clrLime;        rs = StringFormat("%.2f  ▼ OVERSOLD",   rsi); }
      else if(rsi >= 50.0) { rc = clrLimeGreen;   rs = StringFormat("%.2f  ▲",            rsi); }
      else                 { rc = clrOrangeRed;   rs = StringFormat("%.2f  ▼",            rsi); }
      SetVal("V_RSI", DR_RSI, rs, rc);

      // ── EMA ─────────────────────────────────────────────────────
      SetVal("V_EMA", DR_EMA, StringFormat("%.5f", ema), clrSilver);

      // ── ATR ─────────────────────────────────────────────────────
      double atr_pts = (_Point > 0) ? atr / _Point : 0;
      SetVal("V_ATR", DR_ATR,
             StringFormat("%.5f  (%.0f pts)", atr, atr_pts),
             clrCyan);

      // ── Grid direction ───────────────────────────────────────────
      if(grid_dir == 0)      SetVal("V_GDIR", DR_GRID_DIR, "▲  BUY",  clrLime);
      else if(grid_dir == 1) SetVal("V_GDIR", DR_GRID_DIR, "▼  SELL", clrRed);
      else                   SetVal("V_GDIR", DR_GRID_DIR, "─  None", clrDimGray);

      // ── Grid order count ─────────────────────────────────────────
      bool grid_full = (grid_cnt >= max_grid && max_grid > 0);
      SetVal("V_GCNT", DR_GRID_CNT,
             StringFormat("%d / %d", grid_cnt, max_grid),
             grid_full ? clrOrange : clrWhite);

      // ── Grid distance ────────────────────────────────────────────
      SetVal("V_GDST", DR_GRID_DST,
             StringFormat("%.1f pts", grid_dist),
             clrDeepSkyBlue);

      // ── Recovery layer count ─────────────────────────────────────
      bool rec_full = (rec_cnt >= max_rec && max_rec > 0);
      color rec_cnt_clr = rec_cnt == 0 ? clrDimGray : (rec_full ? clrRed : clrOrange);
      SetVal("V_RCNT", DR_REC_CNT,
             StringFormat("%d / %d", rec_cnt, max_rec),
             rec_cnt_clr);

      // ── Recovery distance ────────────────────────────────────────
      SetVal("V_RDST", DR_REC_DST,
             StringFormat("%.1f pts", rec_dist),
             clrDeepSkyBlue);

      // ── Floating P&L ─────────────────────────────────────────────
      double pct = (target > 0) ? MathMax(0.0, MathMin(100.0, pnl / target * 100.0)) : 0.0;
      SetVal("V_PNL", DR_PNL,
             StringFormat("%+.2f   [%.0f%%]", pnl, pct),
             pnl >= 0 ? clrLime : clrRed);

      // ── Profit target ─────────────────────────────────────────────
      SetVal("V_TGT", DR_TARGET,
             StringFormat("%.2f", target),
             clrGold);

      // ── Drawdown ─────────────────────────────────────────────────
      color dc;
      if(dd_pct < 5.0)        dc = clrLime;
      else if(dd_pct < 10.0)  dc = clrYellow;
      else if(dd_pct < 15.0)  dc = clrOrange;
      else                    dc = clrRed;
      SetVal("V_DD", DR_DD,
             StringFormat("%.2f%%", dd_pct),
             dc);

      ChartRedraw(m_chart);
   }
};

#endif // DASHBOARD_MQH
