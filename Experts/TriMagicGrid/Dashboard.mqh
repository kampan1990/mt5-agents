//+------------------------------------------------------------------+
//| Dashboard.mqh                                                    |
//| TriMagicGrid EA                                                  |
//| Version: 1.0.0                                                   |
//| Created: 2026.06.08                                              |
//+------------------------------------------------------------------+
//| Two-panel on-chart dashboard for TriMagicGrid.                   |
//| Left  panel: HYBRID PRO — live account + module status.          |
//| Right panel: MONTHLY P&L — calendar grid for the current month.  |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"

//+------------------------------------------------------------------+
//| DashboardData — snapshot passed to CDashboard::Update() each tick |
//+------------------------------------------------------------------+
struct DashboardData
{
   // ---- Account ----
   double balance;          // Current account balance
   double equity;           // Current account equity
   double pnl;              // Floating P&L (equity - balance)
   double lotPerDay;        // Total lots traded today
   double drawdownPct;      // Current drawdown % (negative value)
   double maxDrawdownPct;   // Session maximum drawdown % (negative value)

   // ---- M1 (buy grid) ----
   bool   m1Locked;         // True when M1 is locked by M2 controller
   int    m1Stars;          // Current star count (consecutive wins or score)
   int    m1MaxStars;       // Maximum stars possible (default 10)
   int    m1Trades;         // Open position count
   int    m1MaxTrades;      // Maximum allowed positions (default 50)
   double m1PNL;            // Floating profit for M1
   double m1OpenLot;        // Total open lots for M1
   double m1COP;            // Closed-order profit today (M1)
   int    m1LosePos;        // Count of losing positions in M1

   // ---- M2 (assist/hedge) ----
   bool   m2AssistMode;     // True when M2 is in assist mode (not free)
   int    m2AssistTarget;   // Which module M2 is assisting: 1=M1, 3=M3
   ENUM_POSITION_TYPE m2Direction; // Current M2 trade direction
   int    m2Trades;         // Open position count
   int    m2MaxTrades;      // Maximum allowed positions
   double m2PNL;            // Floating profit for M2
   double m2COP;            // Closed-order profit today (M2)
   double m2TriggerPrice;   // Price that triggered the M2 lock

   // ---- M3 (sell grid) ----
   bool   m3Locked;         // True when M3 is locked by M2 controller
   int    m3Stars;          // Current star count
   int    m3MaxStars;       // Maximum stars possible (default 10)
   int    m3Trades;         // Open position count
   int    m3MaxTrades;      // Maximum allowed positions (default 50)
   double m3PNL;            // Floating profit for M3
   double m3OpenLot;        // Total open lots for M3
   double m3COP;            // Closed-order profit today (M3)
   int    m3LosePos;        // Count of losing positions in M3

   // ---- TOT + PAIR progress bars ----
   double totCurrent;       // Combined current profit (all modules)
   double totMax;           // Target profit for TOT bar
   double pairM1M2Current;  // Combined M1+M2 current profit
   double pairM1M2Max;      // Target profit for PAIR bar

   // ---- ADX footer ----
   bool   adxTrending;      // True when ADX confirms a trend
   bool   adxDirectionUp;   // True = uptrend, false = downtrend (valid when adxTrending)
   int    spread;           // Current spread in points

   // ---- Monthly calendar ----
   double monthlyPNL[31];   // Daily P&L indexed by day-1 (index 0 = day 1)
   double monthlyLots[31];  // Daily lots indexed by day-1
   int    calYear;          // Calendar year to display
   int    calMonth;         // Calendar month to display (1-12)
};

//+------------------------------------------------------------------+
//| CDashboard — renders and updates both dashboard panels on chart   |
//+------------------------------------------------------------------+
class CDashboard
{
private:
   //--- Panel anchor positions
   int      m_panelX;       // Left panel origin X (chart pixels from left)
   int      m_panelY;       // Left panel origin Y (chart pixels from top)
   int      m_rightPanelX;  // Right panel origin X (computed in Init)
   string   m_prefix;       // Object name prefix, e.g. "TMG_"
   string   m_symbol;       // Trading symbol shown in header
   string   m_eaName;       // EA name shown in header (e.g. "HYBRID PRO")
   string   m_eaVersion;    // EA version string (e.g. "V20.00")

   //--- Layout constants
   int      LEFT_W;         // Left panel width  (330 px)
   int      RIGHT_W;        // Right panel width (340 px)
   int      ROW_H;          // Standard row height (18 px)

   //--- Colour palette
   color    C_BG;           // Panel background       clrBlack
   color    C_HEADER;       // Header bar background  dark blue
   color    C_TEXT;         // Normal text            clrWhite
   color    C_POS;          // Positive value         clrLime
   color    C_NEG;          // Negative value         clrTomato
   color    C_WARN;         // Warning value          clrOrange
   color    C_ALERT;        // Alert bar background   clrDarkOrange
   color    C_BAR_M1;       // M1 progress bar fill   clrRoyalBlue
   color    C_BAR_M3;       // M3 progress bar fill   clrOrange
   color    C_GRAY;         // Subdued text / lots    clrGray
   color    C_BORDER;       // Panel border           dark gray

   //--- Y-offset bookmarks used during Create() and Update()
   //    Stored so Update() can write to exact same coordinates.
   int      m_yAccRow;      // Y of account row
   int      m_yRiskRow;     // Y of risk/drawdown row
   int      m_yAlertRow;    // Y of alert bar row
   int      m_yM1;          // Y start of M1 block
   int      m_yM2;          // Y start of M2 block
   int      m_yM3;          // Y start of M3 block
   int      m_yTOT;         // Y of TOT progress bar
   int      m_yPAIR;        // Y of PAIR progress bar
   int      m_yADX;         // Y of ADX footer row

   //--- Right panel geometry
   int      m_calBaseX;     // Calendar grid left edge
   int      m_calBaseY;     // Calendar grid top edge
   int      CELL_W;         // Cell width  (44 px)
   int      CELL_H;         // Cell height (36 px)

public:
   //+----------------------------------------------------------------+
   //| Constructor — set safe defaults                                 |
   //+----------------------------------------------------------------+
   CDashboard()
      : m_panelX(10), m_panelY(30), m_rightPanelX(0),
        m_prefix("TMG_"), m_symbol(""), m_eaName("HYBRID PRO"),
        m_eaVersion("V20.00"),
        LEFT_W(330), RIGHT_W(340), ROW_H(18),
        C_BG(clrBlack),
        C_HEADER(C'0,0,80'),
        C_TEXT(clrWhite),
        C_POS(clrLime),
        C_NEG(clrTomato),
        C_WARN(clrOrange),
        C_ALERT(clrDarkOrange),
        C_BAR_M1(clrRoyalBlue),
        C_BAR_M3(clrOrange),
        C_GRAY(clrGray),
        C_BORDER(C'40,40,40'),
        m_yAccRow(0), m_yRiskRow(0), m_yAlertRow(0),
        m_yM1(0), m_yM2(0), m_yM3(0),
        m_yTOT(0), m_yPAIR(0), m_yADX(0),
        m_calBaseX(0), m_calBaseY(0),
        CELL_W(44), CELL_H(36)
   {}

   //+----------------------------------------------------------------+
   //| Init — store configuration before Create() is called           |
   //| Parameters:                                                     |
   //|   symbol    — trading symbol shown in the header               |
   //|   eaName    — EA short name (e.g. "HYBRID PRO")                |
   //|   eaVersion — version string (e.g. "V20.00")                   |
   //|   panelX    — left edge of left panel in chart pixels          |
   //|   panelY    — top edge of left panel in chart pixels           |
   //|   prefix    — object-name prefix (unique per EA instance)      |
   //+----------------------------------------------------------------+
   void Init(string symbol, string eaName, string eaVersion,
             int panelX = 10, int panelY = 30, string prefix = "TMG_")
   {
      m_symbol      = symbol;
      m_eaName      = eaName;
      m_eaVersion   = eaVersion;
      m_panelX      = panelX;
      m_panelY      = panelY;
      m_prefix      = prefix;
      m_rightPanelX = panelX + LEFT_W + 5;
   }

   //+----------------------------------------------------------------+
   //| Create — build all static chart objects; call once in OnInit() |
   //+----------------------------------------------------------------+
   void Create()
   {
      CreateLeftPanel();
      CreateRightPanel();
      ChartRedraw();
   }

   //+----------------------------------------------------------------+
   //| Update — refresh dynamic values every tick                     |
   //| Parameters: data — latest snapshot of EA state                 |
   //+----------------------------------------------------------------+
   void Update(const DashboardData &data)
   {
      UpdateLeftPanel(data);
      UpdateRightPanel(data);
      ChartRedraw();
   }

   //+----------------------------------------------------------------+
   //| Destroy — delete every chart object created by this dashboard  |
   //| Call from OnDeinit()                                           |
   //+----------------------------------------------------------------+
   void Destroy()
   {
      ObjectsDeleteAll(0, m_prefix);
      ChartRedraw();
   }

   //+----------------------------------------------------------------+
   //| OnResize — re-anchor objects after the chart window is resized |
   //| Call from OnChartEvent() when id == CHARTEVENT_CHART_CHANGE    |
   //+----------------------------------------------------------------+
   void OnResize()
   {
      // Objects are anchored to CORNER_LEFT_UPPER with pixel offsets,
      // so no recalculation is needed — just force a redraw.
      ChartRedraw();
   }

private:
   //=================================================================+
   //  LEFT PANEL                                                      |
   //=================================================================+

   //+----------------------------------------------------------------+
   //| CreateLeftPanel — build background + all static label objects  |
   //+----------------------------------------------------------------+
   void CreateLeftPanel()
   {
      int x  = m_panelX;
      int y  = m_panelY;
      int w  = LEFT_W;
      int yc = y;   // running cursor

      // ---- Panel background ----
      SetRect(ObjName("LP_BG"), x, yc, w, 320, C_BG, C_BORDER);

      // ---- Section 1: Header bar ----
      SetRect(ObjName("LP_HDR_BG"), x, yc, w, ROW_H + 2, C_HEADER, C_HEADER);
      SetLabel(ObjName("LP_HDR_NAME"), x + 4, yc + 3,
               m_eaName + " " + m_eaVersion, C_TEXT, 9);
      SetLabel(ObjName("LP_HDR_SYM"), x + 160, yc + 3, m_symbol, C_TEXT, 9);
      SetLabel(ObjName("LP_HDR_TF"),  x + 230, yc + 3,
               "M1: " + SymbolInfoString(m_symbol, SYMBOL_DESCRIPTION), C_GRAY, 8);
      yc += ROW_H + 4;

      // ---- Section 2: Account row ----
      m_yAccRow = yc;
      SetLabel(ObjName("LP_BAL_LBL"),  x + 4,   yc, "BAL",     C_GRAY, 8);
      SetLabel(ObjName("LP_BAL_VAL"),  x + 24,  yc, "$0.00",   C_TEXT, 8);
      SetLabel(ObjName("LP_EQ_LBL"),   x + 110, yc, "EQ",      C_GRAY, 8);
      SetLabel(ObjName("LP_EQ_VAL"),   x + 125, yc, "$0.00",   C_TEXT, 8);
      SetLabel(ObjName("LP_PNL_LBL"),  x + 210, yc, "P&L",     C_GRAY, 8);
      SetLabel(ObjName("LP_PNL_VAL"),  x + 230, yc, "0.00$",   C_TEXT, 8);
      SetLabel(ObjName("LP_LOT_LBL"),  x + 278, yc, "Lot/D",   C_GRAY, 8);
      SetLabel(ObjName("LP_LOT_VAL"),  x + 308, yc, "0.00",    C_TEXT, 8);
      yc += ROW_H;

      // ---- Section 3: Risk / drawdown row ----
      m_yRiskRow = yc;
      SetLabel(ObjName("LP_DD_LBL"),    x + 4,   yc, "DD",      C_GRAY, 8);
      SetLabel(ObjName("LP_DD_VAL"),    x + 22,  yc, "0.00%",   C_WARN, 8);
      SetLabel(ObjName("LP_MDD_LBL"),   x + 90,  yc, "MaxDD",   C_GRAY, 8);
      SetLabel(ObjName("LP_MDD_VAL"),   x + 120, yc, "0.00%",   C_NEG,  8);
      yc += ROW_H;

      // ---- Section 4: Alert bar (always created, shown/hidden via text) ----
      m_yAlertRow = yc;
      SetRect(ObjName("LP_ALERT_BG"), x, yc, w, ROW_H, C_ALERT, C_ALERT);
      SetLabel(ObjName("LP_ALERT_TXT"), x + 4, yc + 2,
               "", C_TEXT, 8);
      SetLabel(ObjName("LP_ALERT_TRIG"), x + 200, yc + 2,
               "", C_TEXT, 8);
      // Hide the alert bar until needed
      ObjectSetInteger(0, ObjName("LP_ALERT_BG"),  OBJPROP_BGCOLOR, C_BG);
      yc += ROW_H + 2;

      // ---- Section 5: Module M1 block ----
      m_yM1 = yc;
      // Row 5a: status badge + stars + progress bar + trade count
      SetLabel(ObjName("LP_M1_BADGE"),  x + 4,   yc, "[M1]",   C_POS,  8);
      SetLabel(ObjName("LP_M1_STARS"),  x + 50,  yc, "★0/10",  C_TEXT, 8);
      // Progress bar background + fill
      SetRect(ObjName("LP_M1_PBAR_BG"), x + 120, yc, 120, ROW_H - 4, C_BORDER, C_BORDER);
      SetRect(ObjName("LP_M1_PBAR_FL"), x + 120, yc,   1, ROW_H - 4, C_BAR_M1, C_BAR_M1);
      SetLabel(ObjName("LP_M1_CNT"),   x + 248, yc, "0/50",    C_TEXT, 8);
      yc += ROW_H;

      // Row 5b: PNL + OpenLot
      SetLabel(ObjName("LP_M1_PNL_L"),  x + 4,   yc, "PNL",    C_GRAY, 8);
      SetLabel(ObjName("LP_M1_PNL_V"),  x + 24,  yc, "0.00$",  C_TEXT, 8);
      SetLabel(ObjName("LP_M1_OL_L"),   x + 120, yc, "Open",   C_GRAY, 8);
      SetLabel(ObjName("LP_M1_OL_V"),   x + 144, yc, "0.00 lot", C_TEXT, 8);
      yc += ROW_H;

      // Row 5c: COP + LosePos
      SetLabel(ObjName("LP_M1_COP_L"),  x + 4,   yc, "COP",    C_GRAY, 8);
      SetLabel(ObjName("LP_M1_COP_V"),  x + 24,  yc, "+0.00",  C_POS,  8);
      SetLabel(ObjName("LP_M1_LP_L"),   x + 120, yc, "Lose",   C_GRAY, 8);
      SetLabel(ObjName("LP_M1_LP_V"),   x + 144, yc, "0 pos",  C_TEXT, 8);
      yc += ROW_H + 3;

      // ---- Section 6: Module M2 block ----
      m_yM2 = yc;
      // Row 6a: status badge + assist label + trade count
      SetLabel(ObjName("LP_M2_BADGE"),  x + 4,   yc, "[M2]",   C_TEXT, 8);
      SetLabel(ObjName("LP_M2_ASSIST"), x + 50,  yc, "",        C_WARN, 8);
      SetLabel(ObjName("LP_M2_CNT"),    x + 248, yc, "0/50",   C_TEXT, 8);
      yc += ROW_H;

      // Row 6b: PNL + COP
      SetLabel(ObjName("LP_M2_PNL_L"),  x + 4,   yc, "PNL",    C_GRAY, 8);
      SetLabel(ObjName("LP_M2_PNL_V"),  x + 24,  yc, "0.00$",  C_TEXT, 8);
      SetLabel(ObjName("LP_M2_COP_L"),  x + 120, yc, "COP",    C_GRAY, 8);
      SetLabel(ObjName("LP_M2_COP_V"),  x + 144, yc, "+0.00",  C_POS,  8);
      yc += ROW_H + 3;

      // ---- Section 7: Module M3 block ----
      m_yM3 = yc;
      // Row 7a: status badge + stars + progress bar + trade count
      SetLabel(ObjName("LP_M3_BADGE"),  x + 4,   yc, "[M3]",   C_POS,  8);
      SetLabel(ObjName("LP_M3_STARS"),  x + 50,  yc, "★0/10",  C_TEXT, 8);
      SetRect(ObjName("LP_M3_PBAR_BG"), x + 120, yc, 120, ROW_H - 4, C_BORDER, C_BORDER);
      SetRect(ObjName("LP_M3_PBAR_FL"), x + 120, yc,   1, ROW_H - 4, C_BAR_M3, C_BAR_M3);
      SetLabel(ObjName("LP_M3_CNT"),    x + 248, yc, "0/50",   C_TEXT, 8);
      yc += ROW_H;

      // Row 7b: PNL + OpenLot
      SetLabel(ObjName("LP_M3_PNL_L"),  x + 4,   yc, "PNL",    C_GRAY, 8);
      SetLabel(ObjName("LP_M3_PNL_V"),  x + 24,  yc, "0.00$",  C_TEXT, 8);
      SetLabel(ObjName("LP_M3_OL_L"),   x + 120, yc, "Open",   C_GRAY, 8);
      SetLabel(ObjName("LP_M3_OL_V"),   x + 144, yc, "0.00 lot", C_TEXT, 8);
      yc += ROW_H;

      // Row 7c: COP + LosePos
      SetLabel(ObjName("LP_M3_COP_L"),  x + 4,   yc, "COP",    C_GRAY, 8);
      SetLabel(ObjName("LP_M3_COP_V"),  x + 24,  yc, "+0.00",  C_POS,  8);
      SetLabel(ObjName("LP_M3_LP_L"),   x + 120, yc, "Lose",   C_GRAY, 8);
      SetLabel(ObjName("LP_M3_LP_V"),   x + 144, yc, "0 pos",  C_TEXT, 8);
      yc += ROW_H + 3;

      // ---- Section 8: TOT + PAIR progress bars ----
      m_yTOT  = yc;
      SetLabel(ObjName("LP_TOT_LBL"),   x + 4,   yc, "TOT",    C_GRAY, 8);
      SetRect(ObjName("LP_TOT_BG"),     x + 40,  yc, 200, ROW_H - 4, C_BORDER, C_BORDER);
      SetRect(ObjName("LP_TOT_FL"),     x + 40,  yc,   1, ROW_H - 4, C_POS,    C_POS);
      SetLabel(ObjName("LP_TOT_VAL"),   x + 248, yc, "0.00 / 0.00", C_TEXT, 8);
      yc += ROW_H;

      m_yPAIR = yc;
      SetLabel(ObjName("LP_PAIR_LBL"),  x + 4,   yc, "PAIR M1+M2", C_GRAY, 8);
      SetRect(ObjName("LP_PAIR_BG"),    x + 80,  yc, 160, ROW_H - 4, C_BORDER, C_BORDER);
      SetRect(ObjName("LP_PAIR_FL"),    x + 80,  yc,   1, ROW_H - 4, C_BAR_M1, C_BAR_M1);
      SetLabel(ObjName("LP_PAIR_VAL"),  x + 248, yc, "0.00 / 0.00", C_TEXT, 8);
      yc += ROW_H + 2;

      // ---- Section 9: ADX footer ----
      m_yADX = yc;
      SetRect(ObjName("LP_ADX_BG"),     x, yc, w, ROW_H, C_HEADER, C_HEADER);
      SetLabel(ObjName("LP_ADX_LBL"),   x + 4,   yc + 2, "ADX",     C_GRAY, 8);
      SetLabel(ObjName("LP_ADX_VAL"),   x + 28,  yc + 2, "--",       C_TEXT, 8);
      SetLabel(ObjName("LP_SPR_LBL"),   x + 160, yc + 2, "Spread",  C_GRAY, 8);
      SetLabel(ObjName("LP_SPR_VAL"),   x + 198, yc + 2, "0 pt",    C_TEXT, 8);

      // Adjust the panel background height to fit all rows
      int totalH = (yc + ROW_H) - y + 2;
      ObjectSetInteger(0, ObjName("LP_BG"), OBJPROP_YSIZE, totalH);
   }

   //+----------------------------------------------------------------+
   //| UpdateLeftPanel — refresh all dynamic labels in the left panel |
   //| Parameters: data — current DashboardData snapshot              |
   //+----------------------------------------------------------------+
   void UpdateLeftPanel(const DashboardData &data)
   {
      // ---- Section 2: Account row ----
      ObjectSetString(0, ObjName("LP_BAL_VAL"),  OBJPROP_TEXT,
                      "$" + FormatMoney(data.balance));
      ObjectSetString(0, ObjName("LP_EQ_VAL"),   OBJPROP_TEXT,
                      "$" + FormatMoney(data.equity));
      ObjectSetString(0, ObjName("LP_PNL_VAL"),  OBJPROP_TEXT,
                      FormatMoney(data.pnl, true) + "$");
      ObjectSetInteger(0, ObjName("LP_PNL_VAL"), OBJPROP_COLOR, PnlColor(data.pnl));
      ObjectSetString(0, ObjName("LP_LOT_VAL"),  OBJPROP_TEXT,
                      DoubleToString(data.lotPerDay, 2));

      // ---- Section 3: Risk row ----
      string ddStr  = FormatPct(data.drawdownPct);
      string mddStr = FormatPct(data.maxDrawdownPct);
      color  ddClr  = (data.drawdownPct < -10.0) ? C_NEG : C_WARN;
      ObjectSetString(0,  ObjName("LP_DD_VAL"),  OBJPROP_TEXT,  ddStr);
      ObjectSetInteger(0, ObjName("LP_DD_VAL"),  OBJPROP_COLOR, ddClr);
      ObjectSetString(0,  ObjName("LP_MDD_VAL"), OBJPROP_TEXT,  mddStr);

      // ---- Section 4: Alert bar ----
      bool showAlert = data.m1Locked || data.m3Locked;
      color alertBg  = showAlert ? C_ALERT : C_BG;
      ObjectSetInteger(0, ObjName("LP_ALERT_BG"), OBJPROP_BGCOLOR, alertBg);

      if(showAlert)
      {
         string lockedMod = data.m1Locked ? "M1" : "M3";
         string dirStr    = (data.m2Direction == POSITION_TYPE_BUY) ? "BUY" : "SELL";
         int    target    = data.m2AssistTarget;
         string alertTxt  = StringFormat("O %s STOPPED | M2 -> %s assist",
                                         lockedMod, dirStr);
         string trigTxt   = StringFormat("Trigger price: %.2f", data.m2TriggerPrice);
         ObjectSetString(0, ObjName("LP_ALERT_TXT"),  OBJPROP_TEXT, alertTxt);
         ObjectSetString(0, ObjName("LP_ALERT_TRIG"), OBJPROP_TEXT, trigTxt);
      }
      else
      {
         ObjectSetString(0, ObjName("LP_ALERT_TXT"),  OBJPROP_TEXT, "");
         ObjectSetString(0, ObjName("LP_ALERT_TRIG"), OBJPROP_TEXT, "");
      }

      // ---- Sections 5/6/7: Module blocks ----
      UpdateModuleM1(data, m_yM1);
      UpdateModuleM2(data, m_yM2);
      UpdateModuleM3(data, m_yM3);

      // ---- Section 8: TOT + PAIR bars ----
      DrawProgressBar(ObjName("LP_TOT_FL"),  m_panelX + 40,  m_yTOT,
                      200, ROW_H - 4, data.totCurrent, data.totMax, C_POS);
      ObjectSetString(0, ObjName("LP_TOT_VAL"),  OBJPROP_TEXT,
                      FormatMoney(data.totCurrent) + " / " + FormatMoney(data.totMax));

      DrawProgressBar(ObjName("LP_PAIR_FL"), m_panelX + 80, m_yPAIR,
                      160, ROW_H - 4, data.pairM1M2Current, data.pairM1M2Max, C_BAR_M1);
      ObjectSetString(0, ObjName("LP_PAIR_VAL"), OBJPROP_TEXT,
                      FormatMoney(data.pairM1M2Current) + " / " + FormatMoney(data.pairM1M2Max));

      // ---- Section 9: ADX footer ----
      string adxStr;
      color  adxClr;
      if(!data.adxTrending)
      {
         adxStr = "-- FLAT";
         adxClr = C_GRAY;
      }
      else if(data.adxDirectionUp)
      {
         adxStr = "^ UP";
         adxClr = C_POS;
      }
      else
      {
         adxStr = "v DOWN";
         adxClr = C_NEG;
      }
      ObjectSetString(0,  ObjName("LP_ADX_VAL"), OBJPROP_TEXT,  adxStr);
      ObjectSetInteger(0, ObjName("LP_ADX_VAL"), OBJPROP_COLOR, adxClr);
      ObjectSetString(0,  ObjName("LP_SPR_VAL"), OBJPROP_TEXT,
                      IntegerToString(data.spread) + " pt");
   }

   //+----------------------------------------------------------------+
   //| UpdateModuleM1 — refresh the M1 module block labels            |
   //| Parameters:                                                     |
   //|   data — current snapshot                                       |
   //|   y    — top Y pixel of the M1 block                           |
   //+----------------------------------------------------------------+
   void UpdateModuleM1(const DashboardData &data, int y)
   {
      // Badge
      string badge = data.m1Locked ? "[** STOP **]" : "[BUY]";
      color  bClr  = data.m1Locked ? C_NEG : C_POS;
      ObjectSetString(0,  ObjName("LP_M1_BADGE"), OBJPROP_TEXT,  badge);
      ObjectSetInteger(0, ObjName("LP_M1_BADGE"), OBJPROP_COLOR, bClr);

      // Stars
      DrawStars(ObjName("LP_M1_STARS"), m_panelX + 50, y, data.m1Stars, data.m1MaxStars);

      // Progress bar
      DrawProgressBar(ObjName("LP_M1_PBAR_FL"), m_panelX + 120, y,
                      120, ROW_H - 4, (double)data.m1Trades, (double)data.m1MaxTrades, C_BAR_M1);
      ObjectSetString(0, ObjName("LP_M1_CNT"), OBJPROP_TEXT,
                      IntegerToString(data.m1Trades) + "/" + IntegerToString(data.m1MaxTrades));

      // PNL + OpenLot
      ObjectSetString(0,  ObjName("LP_M1_PNL_V"), OBJPROP_TEXT,
                      FormatMoney(data.m1PNL, true) + "$");
      ObjectSetInteger(0, ObjName("LP_M1_PNL_V"), OBJPROP_COLOR, PnlColor(data.m1PNL));
      ObjectSetString(0,  ObjName("LP_M1_OL_V"),  OBJPROP_TEXT,
                      DoubleToString(data.m1OpenLot, 2) + " lot");

      // COP + LosePos
      string copStr  = (data.m1COP >= 0.0 ? "+" : "") + FormatMoney(data.m1COP);
      ObjectSetString(0,  ObjName("LP_M1_COP_V"), OBJPROP_TEXT,  copStr);
      ObjectSetInteger(0, ObjName("LP_M1_COP_V"), OBJPROP_COLOR, PnlColor(data.m1COP));
      ObjectSetString(0,  ObjName("LP_M1_LP_V"),  OBJPROP_TEXT,
                      IntegerToString(data.m1LosePos) + " pos");
   }

   //+----------------------------------------------------------------+
   //| UpdateModuleM2 — refresh the M2 module block labels            |
   //| Parameters:                                                     |
   //|   data — current snapshot                                       |
   //|   y    — top Y pixel of the M2 block                           |
   //+----------------------------------------------------------------+
   void UpdateModuleM2(const DashboardData &data, int y)
   {
      // Badge — direction text
      string dirStr  = (data.m2Direction == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      color  bClr    = (data.m2Direction == POSITION_TYPE_BUY) ? C_POS : C_NEG;
      ObjectSetString(0,  ObjName("LP_M2_BADGE"), OBJPROP_TEXT,
                      "[" + dirStr + "]");
      ObjectSetInteger(0, ObjName("LP_M2_BADGE"), OBJPROP_COLOR, bClr);

      // Assist label
      string assistTxt = "";
      if(data.m2AssistMode)
         assistTxt = "<- assist M" + IntegerToString(data.m2AssistTarget);
      ObjectSetString(0, ObjName("LP_M2_ASSIST"), OBJPROP_TEXT, assistTxt);

      // Trade count
      ObjectSetString(0, ObjName("LP_M2_CNT"), OBJPROP_TEXT,
                      IntegerToString(data.m2Trades) + "/" + IntegerToString(data.m2MaxTrades));

      // PNL
      ObjectSetString(0,  ObjName("LP_M2_PNL_V"), OBJPROP_TEXT,
                      FormatMoney(data.m2PNL, true) + "$");
      ObjectSetInteger(0, ObjName("LP_M2_PNL_V"), OBJPROP_COLOR, PnlColor(data.m2PNL));

      // COP
      string copStr = (data.m2COP >= 0.0 ? "+" : "") + FormatMoney(data.m2COP);
      ObjectSetString(0,  ObjName("LP_M2_COP_V"), OBJPROP_TEXT,  copStr);
      ObjectSetInteger(0, ObjName("LP_M2_COP_V"), OBJPROP_COLOR, PnlColor(data.m2COP));
   }

   //+----------------------------------------------------------------+
   //| UpdateModuleM3 — refresh the M3 module block labels            |
   //| Parameters:                                                     |
   //|   data — current snapshot                                       |
   //|   y    — top Y pixel of the M3 block                           |
   //+----------------------------------------------------------------+
   void UpdateModuleM3(const DashboardData &data, int y)
   {
      // Badge
      string badge = data.m3Locked ? "[** STOP **]" : "[SELL]";
      color  bClr  = data.m3Locked ? C_NEG : C_WARN;
      ObjectSetString(0,  ObjName("LP_M3_BADGE"), OBJPROP_TEXT,  badge);
      ObjectSetInteger(0, ObjName("LP_M3_BADGE"), OBJPROP_COLOR, bClr);

      // Stars
      DrawStars(ObjName("LP_M3_STARS"), m_panelX + 50, m_yM3, data.m3Stars, data.m3MaxStars);

      // Progress bar
      DrawProgressBar(ObjName("LP_M3_PBAR_FL"), m_panelX + 120, m_yM3,
                      120, ROW_H - 4, (double)data.m3Trades, (double)data.m3MaxTrades, C_BAR_M3);
      ObjectSetString(0, ObjName("LP_M3_CNT"), OBJPROP_TEXT,
                      IntegerToString(data.m3Trades) + "/" + IntegerToString(data.m3MaxTrades));

      // PNL + OpenLot
      ObjectSetString(0,  ObjName("LP_M3_PNL_V"), OBJPROP_TEXT,
                      FormatMoney(data.m3PNL, true) + "$");
      ObjectSetInteger(0, ObjName("LP_M3_PNL_V"), OBJPROP_COLOR, PnlColor(data.m3PNL));
      ObjectSetString(0,  ObjName("LP_M3_OL_V"),  OBJPROP_TEXT,
                      DoubleToString(data.m3OpenLot, 2) + " lot");

      // COP + LosePos
      string copStr = (data.m3COP >= 0.0 ? "+" : "") + FormatMoney(data.m3COP);
      ObjectSetString(0,  ObjName("LP_M3_COP_V"), OBJPROP_TEXT,  copStr);
      ObjectSetInteger(0, ObjName("LP_M3_COP_V"), OBJPROP_COLOR, PnlColor(data.m3COP));
      ObjectSetString(0,  ObjName("LP_M3_LP_V"),  OBJPROP_TEXT,
                      IntegerToString(data.m3LosePos) + " pos");
   }

   //+----------------------------------------------------------------+
   //| DrawProgressBar — resize the fill rectangle to reflect ratio   |
   //| Parameters:                                                     |
   //|   name     — object name of the fill rectangle                 |
   //|   x, y     — top-left anchor of the entire bar                 |
   //|   w        — total width of the bar in pixels                  |
   //|   h        — height of the bar in pixels                       |
   //|   current  — current value                                     |
   //|   maxVal   — maximum value (full bar)                          |
   //|   barColor — fill colour                                        |
   //+----------------------------------------------------------------+
   void DrawProgressBar(string name, int x, int y, int w, int h,
                        double current, double maxVal, color barColor)
   {
      int fillW = 1; // minimum 1 px so the object stays visible
      if(maxVal > 0.0 && current > 0.0)
      {
         double ratio = current / maxVal;
         if(ratio > 1.0) ratio = 1.0;
         fillW = (int)MathRound(ratio * w);
         if(fillW < 1) fillW = 1;
      }
      ObjectSetInteger(0, name, OBJPROP_XSIZE,   fillW);
      ObjectSetInteger(0, name, OBJPROP_YSIZE,   h);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR,  barColor);
      ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, barColor);
   }

   //+----------------------------------------------------------------+
   //| DrawStars — update a label to show filled/empty star glyphs    |
   //| Parameters:                                                     |
   //|   name     — label object name                                 |
   //|   x, y     — pixel position                                    |
   //|   current  — number of filled stars                            |
   //|   maxStars — total stars to show                               |
   //+----------------------------------------------------------------+
   void DrawStars(string name, int x, int y, int current, int maxStars)
   {
      if(maxStars <= 0) maxStars = 1;
      if(current < 0)   current  = 0;
      if(current > maxStars) current = maxStars;

      string s = "";
      for(int i = 0; i < current;  i++) s += CharToString(0x2605); // filled star UTF-8 fallback
      for(int i = current; i < maxStars; i++) s += CharToString(0x2606); // empty star

      // Append numeric annotation
      s += " " + IntegerToString(current) + "/" + IntegerToString(maxStars);

      ObjectSetString(0, name, OBJPROP_TEXT, s);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   }

   //=================================================================+
   //  RIGHT PANEL                                                     |
   //=================================================================+

   //+----------------------------------------------------------------+
   //| CreateRightPanel — build background + calendar header + cells  |
   //+----------------------------------------------------------------+
   void CreateRightPanel()
   {
      int rx = m_rightPanelX;
      int ry = m_panelY;
      int rw = RIGHT_W;

      // Total height: header (2 rows) + day-name row + 6 calendar rows + footer
      int totalH = ROW_H * 2 + ROW_H + CELL_H * 6 + ROW_H + 8;

      // ---- Panel background ----
      SetRect(ObjName("RP_BG"), rx, ry, rw, totalH, C_BG, C_BORDER);

      // ---- Header row 1: title ----
      int yc = ry;
      SetRect(ObjName("RP_HDR_BG"), rx, yc, rw, ROW_H + 2, C_HEADER, C_HEADER);
      SetLabel(ObjName("RP_HDR_TIT"), rx + 4,  yc + 2, "MONTHLY P&L", C_TEXT, 9);
      SetLabel(ObjName("RP_HDR_MON"), rx + 160, yc + 2, "",            C_WARN, 9);
      yc += ROW_H + 4;

      // ---- Day-name header row (Mon..Sun) ----
      string dayNames[7] = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"};
      for(int d = 0; d < 7; d++)
      {
         int cx = rx + 4 + d * CELL_W;
         SetLabel(ObjName("RP_DN_" + IntegerToString(d)), cx, yc, dayNames[d], C_GRAY, 8);
      }
      yc += ROW_H + 2;

      // Store calendar grid origin
      m_calBaseX = rx + 4;
      m_calBaseY = yc;

      // Pre-create all possible cell objects (up to 6 rows x 7 cols = 42 cells)
      // Cells for days 1-31 are placed during Update via UpdateCalendarCell.
      // We create placeholder background rects for all 42 slots here.
      for(int row = 0; row < 6; row++)
      {
         for(int col = 0; col < 7; col++)
         {
            int idx = row * 7 + col;
            int cx  = m_calBaseX + col * CELL_W;
            int cy  = m_calBaseY + row * CELL_H;
            string sfx = "CAL_" + IntegerToString(idx);

            // Cell background
            SetRect(ObjName(sfx + "_BG"), cx, cy, CELL_W - 2, CELL_H - 2,
                    C_BORDER, C_BORDER);
            // Day number label
            SetLabel(ObjName(sfx + "_DAY"), cx + 2, cy + 2,  "",  C_GRAY, 8);
            // PNL label
            SetLabel(ObjName(sfx + "_PNL"), cx + 2, cy + 11, "",  C_TEXT, 8);
            // Lot label
            SetLabel(ObjName(sfx + "_LOT"), cx + 2, cy + 22, "",  C_GRAY, 7);
         }
      }

      // ---- Footer row ----
      int footerY = m_calBaseY + 6 * CELL_H + 4;
      SetRect(ObjName("RP_FTR_BG"), rx, footerY, rw, ROW_H, C_HEADER, C_HEADER);
      SetLabel(ObjName("RP_FTR_MTH"), rx + 4,   footerY + 2, "MTH",   C_GRAY, 8);
      SetLabel(ObjName("RP_FTR_VAL"), rx + 24,  footerY + 2, "+0.00", C_POS,  8);
      SetLabel(ObjName("RP_FTR_LOT"), rx + 180, footerY + 2, "Lot",   C_GRAY, 8);
      SetLabel(ObjName("RP_FTR_LVL"), rx + 200, footerY + 2, "0.00",  C_TEXT, 8);
   }

   //+----------------------------------------------------------------+
   //| UpdateRightPanel — refresh calendar cells and footer           |
   //| Parameters: data — current snapshot                            |
   //+----------------------------------------------------------------+
   void UpdateRightPanel(const DashboardData &data)
   {
      // Update month label in header
      string monthNames[12] = {"Jan","Feb","Mar","Apr","May","Jun",
                                "Jul","Aug","Sep","Oct","Nov","Dec"};
      int mIdx = data.calMonth - 1;
      if(mIdx < 0) mIdx = 0;
      if(mIdx > 11) mIdx = 11;
      ObjectSetString(0, ObjName("RP_HDR_MON"), OBJPROP_TEXT,
                      monthNames[mIdx] + " " + IntegerToString(data.calYear));

      // Determine how many days in this month
      int daysInMonth = DaysInMonth(data.calYear, data.calMonth);

      // Determine which column (0=Mon) the 1st falls on
      int firstDow = GetFirstDayOfWeek(data.calYear, data.calMonth);

      // Clear all 42 slots
      for(int idx = 0; idx < 42; idx++)
      {
         string sfx = "CAL_" + IntegerToString(idx);
         ObjectSetString(0,  ObjName(sfx + "_DAY"), OBJPROP_TEXT, "");
         ObjectSetString(0,  ObjName(sfx + "_PNL"), OBJPROP_TEXT, "");
         ObjectSetString(0,  ObjName(sfx + "_LOT"), OBJPROP_TEXT, "");
         ObjectSetInteger(0, ObjName(sfx + "_BG"),  OBJPROP_BGCOLOR, C_BORDER);
      }

      // Fill day cells
      double monthTotal = 0.0;
      double monthLots  = 0.0;

      for(int day = 1; day <= daysInMonth; day++)
      {
         int slotIdx = firstDow + (day - 1);
         if(slotIdx < 0 || slotIdx >= 42) continue;

         double pnl  = data.monthlyPNL[day - 1];
         double lots = data.monthlyLots[day - 1];
         monthTotal += pnl;
         monthLots  += lots;

         UpdateCalendarCell(day, slotIdx, pnl, lots, m_calBaseX, m_calBaseY);
      }

      // Footer
      string mthStr = (monthTotal >= 0.0 ? "+" : "") + FormatMoney(monthTotal);
      ObjectSetString(0,  ObjName("RP_FTR_VAL"), OBJPROP_TEXT,  mthStr);
      ObjectSetInteger(0, ObjName("RP_FTR_VAL"), OBJPROP_COLOR, PnlColor(monthTotal));
      ObjectSetString(0,  ObjName("RP_FTR_LVL"), OBJPROP_TEXT,
                      FormatMoney(monthLots));
   }

   //+----------------------------------------------------------------+
   //| UpdateCalendarCell — write values into one pre-created cell    |
   //| Parameters:                                                     |
   //|   day      — day number (1-31)                                 |
   //|   slotIdx  — flat index 0-41 in the 6x7 grid                  |
   //|   pnl      — daily P&L                                         |
   //|   lots     — daily lot count                                   |
   //|   baseX    — grid left edge                                    |
   //|   baseY    — grid top edge                                     |
   //+----------------------------------------------------------------+
   void UpdateCalendarCell(int day, int slotIdx, double pnl, double lots,
                           int baseX, int baseY)
   {
      string sfx = "CAL_" + IntegerToString(slotIdx);

      // Background colour — subtle tint for non-zero P&L days
      color bgClr = C_BORDER;
      if(pnl > 0.0)       bgClr = C'0,30,0';
      else if(pnl < 0.0)  bgClr = C'30,0,0';
      ObjectSetInteger(0, ObjName(sfx + "_BG"), OBJPROP_BGCOLOR, bgClr);

      // Day number
      ObjectSetString(0, ObjName(sfx + "_DAY"), OBJPROP_TEXT,
                      IntegerToString(day));

      // P&L value
      string pnlStr = (pnl == 0.0) ? "0.00"
                                    : ((pnl > 0 ? "+" : "") + FormatMoney(pnl));
      ObjectSetString(0,  ObjName(sfx + "_PNL"), OBJPROP_TEXT,  pnlStr);
      ObjectSetInteger(0, ObjName(sfx + "_PNL"), OBJPROP_COLOR, PnlColor(pnl));

      // Lot count
      ObjectSetString(0, ObjName(sfx + "_LOT"), OBJPROP_TEXT,
                      DoubleToString(lots, 2));
   }

   //=================================================================+
   //  OBJECT CREATION HELPERS                                         |
   //=================================================================+

   //+----------------------------------------------------------------+
   //| SetLabel — create or update an OBJ_LABEL chart object          |
   //| Parameters:                                                     |
   //|   name     — unique object name                                |
   //|   x, y     — pixel position from CORNER_LEFT_UPPER            |
   //|   text     — display text                                      |
   //|   clr      — text colour                                       |
   //|   fontSize — font size in points                               |
   //|   font     — font name                                         |
   //+----------------------------------------------------------------+
   void SetLabel(string name, int x, int y, string text, color clr,
                 int fontSize = 9, string font = "Consolas")
   {
      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      }
      ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetString(0,  name, OBJPROP_TEXT,      text);
      ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  fontSize);
      ObjectSetString(0,  name, OBJPROP_FONT,      font);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
   }

   //+----------------------------------------------------------------+
   //| SetRect — create or update an OBJ_RECTANGLE_LABEL chart object |
   //| Parameters:                                                     |
   //|   name        — unique object name                             |
   //|   x, y        — pixel position from CORNER_LEFT_UPPER         |
   //|   w, h        — width and height in pixels                     |
   //|   bgColor     — background fill colour                         |
   //|   borderColor — border colour (clrNONE = no border)            |
   //+----------------------------------------------------------------+
   void SetRect(string name, int x, int y, int w, int h,
                color bgColor, color borderColor = clrNONE)
   {
      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      }
      ObjectSetInteger(0, name, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,    x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,    y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE,        w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE,        h);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR,      bgColor);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE,  BORDER_FLAT);
      if(borderColor != clrNONE)
         ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, borderColor);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,   false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,       true);
   }

   //+----------------------------------------------------------------+
   //| ObjName — return the full prefixed name for a chart object     |
   //| Parameters: suffix — unique suffix for this object             |
   //| Returns: m_prefix + suffix                                     |
   //+----------------------------------------------------------------+
   string ObjName(string suffix)
   {
      return m_prefix + suffix;
   }

   //=================================================================+
   //  UTILITY HELPERS                                                 |
   //=================================================================+

   //+----------------------------------------------------------------+
   //| FormatMoney — format a monetary value with comma separators    |
   //| Parameters:                                                     |
   //|   val      — numeric value to format                           |
   //|   showSign — prepend "+" for positive values when true         |
   //| Returns: formatted string, e.g. "129,565.07"                  |
   //+----------------------------------------------------------------+
   string FormatMoney(double val, bool showSign = false)
   {
      string sign  = "";
      double aval  = MathAbs(val);

      if(val < 0.0)       sign = "-";
      else if(showSign)   sign = "+";

      // Format with 2 decimal places first
      string raw = DoubleToString(aval, 2);

      // Insert thousands separators
      int dotPos = StringFind(raw, ".");
      if(dotPos < 0) dotPos = StringLen(raw);
      string intPart = StringSubstr(raw, 0, dotPos);
      string decPart = StringSubstr(raw, dotPos);   // includes "."

      string result = "";
      int len = StringLen(intPart);
      for(int i = 0; i < len; i++)
      {
         if(i > 0 && (len - i) % 3 == 0) result += ",";
         result += StringSubstr(intPart, i, 1);
      }

      return sign + result + decPart;
   }

   //+----------------------------------------------------------------+
   //| FormatPct — format a percentage value                          |
   //| Parameters: val — percentage (negative for drawdown)           |
   //| Returns: string like "-9.54%"                                  |
   //+----------------------------------------------------------------+
   string FormatPct(double val)
   {
      return DoubleToString(val, 2) + "%";
   }

   //+----------------------------------------------------------------+
   //| PnlColor — choose display colour based on sign of a P&L value  |
   //| Parameters: val — P&L value                                    |
   //| Returns: C_POS for positive, C_NEG for negative, C_GRAY for 0 |
   //+----------------------------------------------------------------+
   color PnlColor(double val)
   {
      if(val > 0.0)  return C_POS;
      if(val < 0.0)  return C_NEG;
      return C_GRAY;
   }

   //+----------------------------------------------------------------+
   //| GetFirstDayOfWeek — Tomohiko Sakamoto's algorithm              |
   //| Returns 0 = Monday ... 6 = Sunday for the 1st of the month.   |
   //| Parameters:                                                     |
   //|   year  — full year (e.g. 2026)                                |
   //|   month — month number 1-12                                    |
   //+----------------------------------------------------------------+
   int GetFirstDayOfWeek(int year, int month)
   {
      // Use Zeller's congruence adapted to return Mon=0 ... Sun=6
      int y = year;
      int m = month;
      if(m < 3) { m += 12; y--; }

      int k = y % 100;
      int j = y / 100;

      // Zeller gives: 0=Sat, 1=Sun, 2=Mon, ... 6=Fri
      int h = (1 + (13 * (m + 1)) / 5 + k + k / 4 + j / 4 + 5 * j) % 7;

      // Convert to Mon=0 ... Sun=6
      int dow = (h + 5) % 7;
      return dow;
   }

   //+----------------------------------------------------------------+
   //| DaysInMonth — number of days in a given month                  |
   //| Parameters:                                                     |
   //|   year  — full year                                            |
   //|   month — month 1-12                                           |
   //+----------------------------------------------------------------+
   int DaysInMonth(int year, int month)
   {
      int days[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
      int idx = month - 1;
      if(idx < 0 || idx > 11) return 30;

      // Leap year check for February
      if(month == 2)
      {
         bool leap = ((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0));
         if(leap) return 29;
      }
      return days[idx];
   }
};
