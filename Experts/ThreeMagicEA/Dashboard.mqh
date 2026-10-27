//+------------------------------------------------------------------+
//|                                                    Dashboard.mqh |
//|   ThreeMagicEA - on-chart control panel (full option).           |
//|   Live per-magic status + account risk + clickable buttons:      |
//|   per-magic Close / Pause-Resume, and global Close-All/Pause-All. |
//+------------------------------------------------------------------+
#ifndef THREEMAGIC_DASHBOARD_MQH
#define THREEMAGIC_DASHBOARD_MQH
#property strict

#include "Utils.mqh"
#include "RiskManager.mqh"
#include "Strategy_Engulfing.mqh"
#include "Strategy_Sideway.mqh"
#include "Strategy_Trend.mqh"

#define TMD_PFX "TMD_"

//+------------------------------------------------------------------+
//| CDashboard                                                      |
//+------------------------------------------------------------------+
class CDashboard
  {
private:
   CUtils             *m_utils;
   CRiskManager       *m_risk;
   CStrategyEngulfing *m_m1;
   CStrategySideway   *m_m2;
   CStrategyTrend     *m_m3;
   bool                m_en1,m_en2,m_en3;

   int                 m_corner;
   int                 m_x, m_y, m_w;
   int                 m_fs;

   //--- colours
   color               m_cPanel, m_cBorder, m_cTitle, m_cText, m_cDim;
   color               m_cProfit, m_cLoss, m_cOn, m_cOff, m_cBtn;

   //----- primitive object helpers -----------------------------------
   void  Label(const string name,int x,int y,int fs,color clr,const string text)
     {
      if(ObjectFind(0,name)<0)
         ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,m_corner);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fs);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
      ObjectSetString (0,name,OBJPROP_FONT,"Consolas");
      ObjectSetString (0,name,OBJPROP_TEXT,text);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
     }

   void  Rect(const string name,int x,int y,int w,int h,color bg,color border)
     {
      if(ObjectFind(0,name)<0)
         ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,m_corner);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
      ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,name,OBJPROP_COLOR,border);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
     }

   void  Button(const string name,int x,int y,int w,int h,const string text,color bg,color txt)
     {
      if(ObjectFind(0,name)<0)
         ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,m_corner);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
      ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
      ObjectSetInteger(0,name,OBJPROP_COLOR,txt);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,m_fs-1);
      ObjectSetString (0,name,OBJPROP_FONT,"Consolas");
      ObjectSetString (0,name,OBJPROP_TEXT,text);
      ObjectSetInteger(0,name,OBJPROP_STATE,false);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
     }

   color PLColor(double v){ return (v>=0.0 ? m_cProfit : m_cLoss); }

   int   CountEnabled(void){ return (m_en1?1:0)+(m_en2?1:0)+(m_en3?1:0); }

   //--- render one magic block (two text lines + two buttons)
   void  RenderMagic(int idx,MagicStatus &s,int y)
     {
      int lh=m_fs+7;
      string pfx=StringFormat("%sM%d_",TMD_PFX,idx);
      // line 1: name | state | side | pos/pend
      string l1=StringFormat("%-9s %-7s %-4s P:%d D:%d",
                             s.name,s.state,SideText(s.side),s.positions,s.pending);
      Label(pfx+"L1",m_x+8,y,m_fs,(s.enabled?m_cText:m_cDim),l1);
      // line 2: P/L + info
      string l2=StringFormat("  P/L $%.2f (%.0fpt)  %s",s.pl,s.plPts,s.info);
      Label(pfx+"L2",m_x+8,y+lh,m_fs,PLColor(s.pl),l2);

      // buttons on the right of line 1
      int bw=46,bh=lh+2;
      int bx2=m_x+m_w-bw-6;
      int bx1=bx2-bw-4;
      Button(pfx+"BCLOSE",bx1,y-1,bw,bh,"Close",m_cBtn,m_cText);
      Button(pfx+"BTOG",  bx2,y-1,bw,bh,(s.enabled?"ON":"OFF"),
             (s.enabled?m_cOn:m_cOff),clrWhite);
     }

public:
                     CDashboard(void)
     {
      m_utils=NULL; m_risk=NULL; m_m1=NULL; m_m2=NULL; m_m3=NULL;
      m_en1=m_en2=m_en3=false;
      m_corner=CORNER_LEFT_UPPER; m_x=12; m_y=20; m_w=340; m_fs=9;
      m_cPanel =(color)C'28,30,38';
      m_cBorder=(color)C'70,74,90';
      m_cTitle =clrGold;
      m_cText  =clrGainsboro;
      m_cDim   =(color)C'120,124,135';
      m_cProfit=(color)C'0,200,120';
      m_cLoss  =(color)C'235,95,95';
      m_cOn    =(color)C'0,140,80';
      m_cOff   =(color)C'150,60,60';
      m_cBtn   =(color)C'60,66,82';
     }

   void Init(CUtils *utils,CRiskManager *risk,
             CStrategyEngulfing *m1,CStrategySideway *m2,CStrategyTrend *m3,
             bool en1,bool en2,bool en3,
             int corner,int x,int y,int fontSize)
     {
      m_utils=utils; m_risk=risk; m_m1=m1; m_m2=m2; m_m3=m3;
      m_en1=en1; m_en2=en2; m_en3=en3;
      m_corner=corner; m_x=x; m_y=y; m_fs=fontSize;
      if(m_fs<7) m_fs=7;
     }

   void Create(void){ Update(); }

   //--- redraw everything (idempotent)
   void Update(void)
     {
      int lh=m_fs+7;
      int rowH=2*lh+8;
      int nRows=CountEnabled();
      int y=m_y;

      int headerH=6+lh+2*lh+8;              // title + 2 account lines + gap
      int footerH=lh+4+(lh+4)+8;            // footer buttons
      int H=headerH+nRows*rowH+footerH+6;

      Rect(TMD_PFX+"BG",m_x,m_y,m_w,H,m_cPanel,m_cBorder);

      // --- title
      string title=StringFormat("ThreeMagicEA  |  %s  %s",
                                m_utils.Symbol(),
                                (m_risk.IsHalted()?"[HALTED]":""));
      Label(TMD_PFX+"TITLE",m_x+8,y+4,m_fs+1,
            (m_risk.IsHalted()?m_cLoss:m_cTitle),title);
      y+=lh+6;

      // --- account rows
      double bal =AccountInfoDouble(ACCOUNT_BALANCE);
      double eq  =AccountInfoDouble(ACCOUNT_EQUITY);
      double mfree=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double flt =eq-bal;
      double dd  =m_risk.DrawdownPct();
      Label(TMD_PFX+"ACC1",m_x+8,y,m_fs,m_cText,
            StringFormat("Bal %.2f  Eq %.2f  Free %.0f",bal,eq,mfree));
      y+=lh;
      Label(TMD_PFX+"ACC2",m_x+8,y,m_fs,PLColor(flt),
            StringFormat("Float $%.2f     DD %.2f%%",flt,dd));
      y+=lh+6;

      // --- per-magic blocks
      if(m_en1){ MagicStatus s; m_m1.GetStatus(s); RenderMagic(1,s,y); y+=rowH; }
      if(m_en2){ MagicStatus s; m_m2.GetStatus(s); RenderMagic(2,s,y); y+=rowH; }
      if(m_en3){ MagicStatus s; m_m3.GetStatus(s); RenderMagic(3,s,y); y+=rowH; }

      // --- global footer buttons
      int bw=(m_w-8*2-8)/2;
      Button(TMD_PFX+"BCLOSEALL",m_x+8,        y,bw,lh+6,"CLOSE ALL",(color)C'160,55,55',clrWhite);
      Button(TMD_PFX+"BPAUSEALL",m_x+8+bw+8,   y,bw,lh+6,"PAUSE ALL",(color)C'150,120,40',clrWhite);

      ChartRedraw(0);
     }

   //--- handle button clicks
   void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
     {
      if(id!=CHARTEVENT_OBJECT_CLICK)
         return;
      if(StringFind(sparam,TMD_PFX)!=0)
         return;

      // reset the visual pressed state
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);

      if(sparam==TMD_PFX+"M1_BCLOSE" && m_en1) m_m1.CloseAllTrades();
      else if(sparam==TMD_PFX+"M1_BTOG" && m_en1) m_m1.SetEnabled(!m_m1.IsEnabled());
      else if(sparam==TMD_PFX+"M2_BCLOSE" && m_en2) m_m2.CloseAllTrades();
      else if(sparam==TMD_PFX+"M2_BTOG" && m_en2) m_m2.SetEnabled(!m_m2.IsEnabled());
      else if(sparam==TMD_PFX+"M3_BCLOSE" && m_en3) m_m3.CloseAllTrades();
      else if(sparam==TMD_PFX+"M3_BTOG" && m_en3) m_m3.SetEnabled(!m_m3.IsEnabled());
      else if(sparam==TMD_PFX+"BCLOSEALL")
        {
         if(m_en1) m_m1.CloseAllTrades();
         if(m_en2) m_m2.CloseAllTrades();
         if(m_en3) m_m3.CloseAllTrades();
        }
      else if(sparam==TMD_PFX+"BPAUSEALL")
        {
         bool anyOn=(m_en1 && m_m1.IsEnabled()) ||
                    (m_en2 && m_m2.IsEnabled()) ||
                    (m_en3 && m_m3.IsEnabled());
         bool target=!anyOn; // if any running -> pause all; else resume all
         if(m_en1) m_m1.SetEnabled(target);
         if(m_en2) m_m2.SetEnabled(target);
         if(m_en3) m_m3.SetEnabled(target);
        }

      Update();
     }

   void Destroy(void)
     {
      ObjectsDeleteAll(0,TMD_PFX);
      ChartRedraw(0);
     }
  };
//+------------------------------------------------------------------+
#endif // THREEMAGIC_DASHBOARD_MQH
