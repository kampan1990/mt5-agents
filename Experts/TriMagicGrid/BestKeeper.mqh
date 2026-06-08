//+------------------------------------------------------------------+
//| BestKeeper.mqh                                                   |
//| TriMagicGrid EA                                                  |
//| Version: 1.0.0                                                   |
//| Created: 2026.06.07                                              |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"
#include "Logger.mqh"
#include "PositionTracker.mqh"

//+------------------------------------------------------------------+
//| CBestKeeper — maintains a set of "keeper" positions for each     |
//| direction. Keepers are the top-N most profitable open positions  |
//| and are excluded from loss-pull / forced-close operations.       |
//+------------------------------------------------------------------+
class CBestKeeper
{
private:
   int               m_keeperCountBuy;   // How many buy keepers to maintain
   int               m_keeperCountSell;  // How many sell keepers to maintain

   CPositionTracker* m_tracker;          // Shared tracker (not owned)
   CLogger*          m_logger;           // Shared logger (not owned)

   //--- Simple insertion-sort: sort records descending by profit
   void SortByProfitDesc(PositionRecord &arr[], int count)
   {
      for(int i = 1; i < count; i++)
      {
         PositionRecord key = arr[i];
         int j = i - 1;
         while(j >= 0 && arr[j].profit < key.profit)
         {
            arr[j + 1] = arr[j];
            j--;
         }
         arr[j + 1] = key;
      }
   }

   //--- Update keeper flags for one direction (BUY or SELL)
   //    Promotes the top keeperCount positions and demotes the rest.
   void UpdateSide(ENUM_POSITION_TYPE side, int keeperCount)
   {
      if(keeperCount <= 0) return;

      // Collect all positions for this direction
      PositionRecord all[];
      int total = m_tracker.GetAllRecords(all, (int)side);
      if(total == 0) return;

      SortByProfitDesc(all, total);

      for(int i = 0; i < total; i++)
      {
         bool shouldBeKeeper = (i < keeperCount);
         bool wasKeeper      = all[i].isKeeper;

         if(shouldBeKeeper != wasKeeper)
         {
            m_tracker.MarkAsKeeper(all[i].ticket, shouldBeKeeper);

            if(m_logger != NULL)
               m_logger.LogState("BestKeeper",
                  StringFormat("%s ticket=%I64u profit=%.2f → keeper=%s",
                     (side == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                     all[i].ticket, all[i].profit,
                     shouldBeKeeper ? "YES" : "NO"));
         }
      }
   }

public:
   //+----------------------------------------------------------------+
   //| Constructor — safe defaults                                     |
   //+----------------------------------------------------------------+
   CBestKeeper()
      : m_keeperCountBuy(1), m_keeperCountSell(1),
        m_tracker(NULL), m_logger(NULL) {}

   //+----------------------------------------------------------------+
   //| Init — configure keeper counts and inject dependencies         |
   //| Parameters:                                                     |
   //|   keeperCountBuy  — number of buy positions to protect         |
   //|   keeperCountSell — number of sell positions to protect        |
   //|   tracker         — shared position tracker                    |
   //|   logger          — shared logger                              |
   //+----------------------------------------------------------------+
   void Init(int keeperCountBuy, int keeperCountSell,
             CPositionTracker* tracker, CLogger* logger)
   {
      m_keeperCountBuy  = keeperCountBuy;
      m_keeperCountSell = keeperCountSell;
      m_tracker         = tracker;
      m_logger          = logger;

      if(m_logger != NULL)
         m_logger.LogInfo(StringFormat(
            "CBestKeeper::Init — keeperCountBuy=%d keeperCountSell=%d",
            m_keeperCountBuy, m_keeperCountSell));
   }

   //+----------------------------------------------------------------+
   //| Update — re-evaluate keeper flags for both directions          |
   //| Call once per tick after CPositionTracker::Refresh().          |
   //+----------------------------------------------------------------+
   void Update()
   {
      UpdateSide(POSITION_TYPE_BUY,  m_keeperCountBuy);
      UpdateSide(POSITION_TYPE_SELL, m_keeperCountSell);
   }

   //+----------------------------------------------------------------+
   //| IsKeeper — return true when the given ticket is a keeper       |
   //| Parameters: ticket — position ticket to check                  |
   //+----------------------------------------------------------------+
   bool IsKeeper(ulong ticket)
   {
      // Ask the tracker for all records and search for the ticket
      PositionRecord all[];
      int total = m_tracker.GetAllRecords(all, -1, true);  // keeperOnly=true
      for(int i = 0; i < total; i++)
         if(all[i].ticket == ticket) return true;
      return false;
   }
};
