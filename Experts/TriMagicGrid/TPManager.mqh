//+------------------------------------------------------------------+
//| TPManager.mqh                                                    |
//| TriMagicGrid EA                                                  |
//| Version: 1.0.0                                                   |
//| Created: 2026.06.07                                              |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"
#include "Logger.mqh"
#include "PositionTracker.mqh"
#include "BestKeeper.mqh"
#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| CTPManager — evaluates TP conditions and executes position close |
//| operations according to the selected mode and keeper rules.      |
//+------------------------------------------------------------------+
class CTPManager
{
private:
   ENUM_TP_MODE      m_mode;             // TP mode selector

   //--- Mode 1 parameters (per-magic profit target)
   double            m_tpM1;             // Profit target for M1 group
   double            m_tpM2;             // Profit target for M2 group
   double            m_tpM3;             // Profit target for M3 group

   //--- Mode 2 parameters (two magic-pair profit targets)
   int               m_pair1M1;          // Magic index A of pair 1
   int               m_pair1M2;          // Magic index B of pair 1
   double            m_pair1Profit;      // Combined profit target for pair 1
   int               m_pair2M1;          // Magic index A of pair 2
   int               m_pair2M2;          // Magic index B of pair 2
   double            m_pair2Profit;      // Combined profit target for pair 2

   //--- Mode 3 parameter (all-magic combined target)
   double            m_tpAll;

   //--- Loss pull parameters
   bool              m_lossPullEnabled;  // Whether loss-pull is active
   int               m_lossPullCount;    // How many worst positions to close per cycle

   //--- Keeper TP parameters
   double            m_keeperTPProfit;   // Sum-of-keeper-profit threshold to close keepers

   //--- Dependencies
   CPositionTracker* m_tracker;          // Shared tracker (not owned)
   CBestKeeper*      m_keeper;           // Shared keeper (not owned)
   CLogger*          m_logger;           // Shared logger (not owned)
   CTrade*           m_trade;            // Shared CTrade (not owned)

   //--- Close a single position by ticket; log result
   //    Returns true on success
   bool ClosePosition(ulong ticket, string reason)
   {
      if(!PositionSelectByTicket(ticket))
      {
         if(m_logger != NULL)
            m_logger.LogError("CTPManager::ClosePosition",
                              GetLastError(),
                              StringFormat("ticket=%I64u not found reason=%s",
                                           ticket, reason));
         return false;
      }

      double profit = PositionGetDouble(POSITION_PROFIT)
                      + PositionGetDouble(POSITION_SWAP);
      double price  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                      ? SymbolInfoDouble(PositionGetString(POSITION_SYMBOL), SYMBOL_BID)
                      : SymbolInfoDouble(PositionGetString(POSITION_SYMBOL), SYMBOL_ASK);

      bool ok = m_trade.PositionClose(ticket);

      if(!ok)
      {
         if(m_logger != NULL)
            m_logger.LogError("CTPManager::ClosePosition",
                              (int)m_trade.ResultRetcode(),
                              StringFormat("ticket=%I64u reason=%s retcode=%d",
                                           ticket, reason,
                                           (int)m_trade.ResultRetcode()));
         return false;
      }

      if(m_logger != NULL)
         m_logger.LogTrade("CLOSE", ticket, price,
                           PositionGetDouble(POSITION_VOLUME),
                           profit, "reason=" + reason);
      return true;
   }

   //--- Close all non-keeper positions for a given magic group
   void CloseGroupExKeepers(ENUM_MAGIC_ID id, string reason)
   {
      PositionRecord recs[];
      int n = m_tracker.GetRecordsByMagic(id, recs);
      for(int i = 0; i < n; i++)
      {
         if(recs[i].isKeeper) continue;
         ClosePosition(recs[i].ticket, reason);
      }
   }

   //--- Sum profit for a magic group (optionally only keepers)
   double SumProfit(ENUM_MAGIC_ID id, bool keeperOnly = false)
   {
      MagicState st = m_tracker.GetMagicState(id);
      if(!keeperOnly) return st.totalProfit;

      // Sum only keeper positions
      PositionRecord recs[];
      int n = m_tracker.GetRecordsByMagic(id, recs);
      double total = 0.0;
      for(int i = 0; i < n; i++)
         if(recs[i].isKeeper) total += recs[i].profit;
      return total;
   }

   //--- TP Mode 1: close each magic group independently when its target is hit
   void CheckTPMode1()
   {
      if(m_tracker.HasPositions(MAGIC_M1) && SumProfit(MAGIC_M1) >= m_tpM1)
      {
         if(m_logger != NULL)
            m_logger.LogState("TPManager",
               StringFormat("Mode1 M1 TP hit — profit=%.2f target=%.2f",
                            SumProfit(MAGIC_M1), m_tpM1));
         CloseGroupExKeepers(MAGIC_M1, "TP_MODE1_M1");
      }

      if(m_tracker.HasPositions(MAGIC_M2) && SumProfit(MAGIC_M2) >= m_tpM2)
      {
         if(m_logger != NULL)
            m_logger.LogState("TPManager",
               StringFormat("Mode1 M2 TP hit — profit=%.2f target=%.2f",
                            SumProfit(MAGIC_M2), m_tpM2));
         CloseGroupExKeepers(MAGIC_M2, "TP_MODE1_M2");
      }

      if(m_tracker.HasPositions(MAGIC_M3) && SumProfit(MAGIC_M3) >= m_tpM3)
      {
         if(m_logger != NULL)
            m_logger.LogState("TPManager",
               StringFormat("Mode1 M3 TP hit — profit=%.2f target=%.2f",
                            SumProfit(MAGIC_M3), m_tpM3));
         CloseGroupExKeepers(MAGIC_M3, "TP_MODE1_M3");
      }
   }

   //--- TP Mode 2: close paired magic groups when combined profit target is hit
   void CheckTPMode2()
   {
      // Resolve magic indices to ENUM_MAGIC_ID
      ENUM_MAGIC_ID p1a = (ENUM_MAGIC_ID)m_pair1M1;
      ENUM_MAGIC_ID p1b = (ENUM_MAGIC_ID)m_pair1M2;
      ENUM_MAGIC_ID p2a = (ENUM_MAGIC_ID)m_pair2M1;
      ENUM_MAGIC_ID p2b = (ENUM_MAGIC_ID)m_pair2M2;

      double profit1 = SumProfit(p1a) + SumProfit(p1b);
      double profit2 = SumProfit(p2a) + SumProfit(p2b);

      if(profit1 >= m_pair1Profit)
      {
         if(m_logger != NULL)
            m_logger.LogState("TPManager",
               StringFormat("Mode2 Pair1 TP hit — profit=%.2f target=%.2f",
                            profit1, m_pair1Profit));
         CloseGroupExKeepers(p1a, "TP_MODE2_PAIR1A");
         CloseGroupExKeepers(p1b, "TP_MODE2_PAIR1B");
      }

      if(profit2 >= m_pair2Profit)
      {
         if(m_logger != NULL)
            m_logger.LogState("TPManager",
               StringFormat("Mode2 Pair2 TP hit — profit=%.2f target=%.2f",
                            profit2, m_pair2Profit));
         CloseGroupExKeepers(p2a, "TP_MODE2_PAIR2A");
         CloseGroupExKeepers(p2b, "TP_MODE2_PAIR2B");
      }
   }

   //--- TP Mode 3: close all magic groups when combined total profit target is hit
   void CheckTPMode3()
   {
      double total = SumProfit(MAGIC_M1)
                   + SumProfit(MAGIC_M2)
                   + SumProfit(MAGIC_M3);

      if(total >= m_tpAll)
      {
         if(m_logger != NULL)
            m_logger.LogState("TPManager",
               StringFormat("Mode3 All TP hit — profit=%.2f target=%.2f",
                            total, m_tpAll));
         CloseGroupExKeepers(MAGIC_M1, "TP_MODE3_ALL");
         CloseGroupExKeepers(MAGIC_M2, "TP_MODE3_ALL");
         CloseGroupExKeepers(MAGIC_M3, "TP_MODE3_ALL");
      }
   }

   //--- Close keeper positions when their combined profit meets threshold
   void CheckKeeperTP()
   {
      if(m_keeperTPProfit <= 0.0) return;

      PositionRecord keepers[];
      int n = m_tracker.GetAllRecords(keepers, -1, true);  // keeperOnly=true
      if(n == 0) return;

      double keeperProfit = 0.0;
      for(int i = 0; i < n; i++) keeperProfit += keepers[i].profit;

      if(keeperProfit >= m_keeperTPProfit)
      {
         if(m_logger != NULL)
            m_logger.LogState("TPManager",
               StringFormat("Keeper TP hit — profit=%.2f target=%.2f",
                            keeperProfit, m_keeperTPProfit));
         for(int i = 0; i < n; i++)
            ClosePosition(keepers[i].ticket, "KEEPER_TP");
      }
   }

   //--- ExecuteLossPull — close the N worst-performing non-keeper positions
   //    Positions are sorted ascending by profit (most negative first).
   void ExecuteLossPull(int count)
   {
      if(count <= 0) return;

      // Gather all non-keeper positions
      PositionRecord losers[];
      int n = m_tracker.GetAllRecords(losers, -1, false, true);  // excludeKeeper=true
      if(n == 0) return;

      // Simple sort ascending by profit (worst first)
      for(int i = 1; i < n; i++)
      {
         PositionRecord key = losers[i];
         int j = i - 1;
         while(j >= 0 && losers[j].profit > key.profit)
         {
            losers[j + 1] = losers[j];
            j--;
         }
         losers[j + 1] = key;
      }

      int toClose = MathMin(count, n);
      for(int i = 0; i < toClose; i++)
      {
         // Only close if the position is actually losing
         if(losers[i].profit >= 0.0) break;
         ClosePosition(losers[i].ticket, "LOSS_PULL");
      }
   }

public:
   //+----------------------------------------------------------------+
   //| Constructor — safe defaults                                     |
   //+----------------------------------------------------------------+
   CTPManager()
      : m_mode(TP_MODE_1),
        m_tpM1(50.0), m_tpM2(50.0), m_tpM3(50.0),
        m_pair1M1(0), m_pair1M2(2), m_pair1Profit(100.0),
        m_pair2M1(2), m_pair2M2(1), m_pair2Profit(100.0),
        m_tpAll(150.0),
        m_lossPullEnabled(false), m_lossPullCount(1),
        m_keeperTPProfit(200.0),
        m_tracker(NULL), m_keeper(NULL), m_logger(NULL), m_trade(NULL) {}

   //+----------------------------------------------------------------+
   //| Init — configure dependencies and TP mode                      |
   //| Parameters:                                                     |
   //|   mode    — TP_MODE_1, TP_MODE_2, or TP_MODE_3                |
   //|   tracker — shared position tracker                            |
   //|   keeper  — shared best keeper                                 |
   //|   logger  — shared logger                                      |
   //|   trade   — shared CTrade instance                             |
   //+----------------------------------------------------------------+
   void Init(ENUM_TP_MODE mode, CPositionTracker* tracker,
             CBestKeeper* keeper, CLogger* logger, CTrade* trade)
   {
      m_mode    = mode;
      m_tracker = tracker;
      m_keeper  = keeper;
      m_logger  = logger;
      m_trade   = trade;

      if(m_logger != NULL)
         m_logger.LogInfo(StringFormat(
            "CTPManager::Init — mode=%s", EnumToString(mode)));
   }

   //+----------------------------------------------------------------+
   //| SetTPMode1Params — per-magic profit targets                    |
   //| Parameters: tpM1/tpM2/tpM3 — profit thresholds in currency    |
   //+----------------------------------------------------------------+
   void SetTPMode1Params(double tpM1, double tpM2, double tpM3)
   {
      m_tpM1 = tpM1;
      m_tpM2 = tpM2;
      m_tpM3 = tpM3;
   }

   //+----------------------------------------------------------------+
   //| SetTPMode2Params — two-pair combined profit targets            |
   //| Parameters:                                                     |
   //|   pair1M1/pair1M2 — ENUM_MAGIC_ID indices for pair 1          |
   //|   pair1Profit     — combined profit target for pair 1          |
   //|   pair2M1/pair2M2 — ENUM_MAGIC_ID indices for pair 2          |
   //|   pair2Profit     — combined profit target for pair 2          |
   //+----------------------------------------------------------------+
   void SetTPMode2Params(int pair1M1, int pair1M2, double pair1Profit,
                         int pair2M1, int pair2M2, double pair2Profit)
   {
      m_pair1M1     = pair1M1;
      m_pair1M2     = pair1M2;
      m_pair1Profit = pair1Profit;
      m_pair2M1     = pair2M1;
      m_pair2M2     = pair2M2;
      m_pair2Profit = pair2Profit;
   }

   //+----------------------------------------------------------------+
   //| SetTPMode3Params — all-magic combined profit target            |
   //| Parameters: tpAll — total profit threshold in account currency |
   //+----------------------------------------------------------------+
   void SetTPMode3Params(double tpAll)
   {
      m_tpAll = tpAll;
   }

   //+----------------------------------------------------------------+
   //| SetLossPullParams — configure the loss-pull close feature      |
   //| Parameters:                                                     |
   //|   enabled — enable/disable loss-pull                           |
   //|   count   — number of worst positions to close per cycle       |
   //+----------------------------------------------------------------+
   void SetLossPullParams(bool enabled, int count)
   {
      m_lossPullEnabled = enabled;
      m_lossPullCount   = count;
   }

   //+----------------------------------------------------------------+
   //| SetKeeperTP — profit threshold to close all keeper positions   |
   //| Parameters: keeperProfit — sum-of-keepers profit target        |
   //+----------------------------------------------------------------+
   void SetKeeperTP(double keeperProfit)
   {
      m_keeperTPProfit = keeperProfit;
   }

   //+----------------------------------------------------------------+
   //| CheckAndExecuteTP — main entry: evaluate all TP conditions     |
   //| Call once per OnTick() after BestKeeper::Update().             |
   //+----------------------------------------------------------------+
   void CheckAndExecuteTP()
   {
      // 1. Keeper TP (always checked regardless of mode)
      CheckKeeperTP();

      // 2. Mode-based TP
      switch(m_mode)
      {
         case TP_MODE_1: CheckTPMode1(); break;
         case TP_MODE_2: CheckTPMode2(); break;
         case TP_MODE_3: CheckTPMode3(); break;
      }

      // 3. Loss pull (applied after TP checks)
      if(m_lossPullEnabled)
         ExecuteLossPull(m_lossPullCount);
   }
};
