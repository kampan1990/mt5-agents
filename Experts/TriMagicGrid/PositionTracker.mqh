//+------------------------------------------------------------------+
//| PositionTracker.mqh                                              |
//| TriMagicGrid EA                                                  |
//| Version: 1.0.0                                                   |
//| Created: 2026.06.07                                              |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"
#include "Logger.mqh"

//+------------------------------------------------------------------+
//| CPositionTracker — scans open positions and maintains records    |
//| per magic number, providing O(1) lookup of aggregated stats.     |
//+------------------------------------------------------------------+
class CPositionTracker
{
private:
   int    m_magicM1;                // Magic number for M1 (buy grid)
   int    m_magicM2;                // Magic number for M2 (assist)
   int    m_magicM3;                // Magic number for M3 (sell grid)

   PositionRecord m_records[];      // Dynamic array of all tracked positions
   MagicState     m_states[3];      // Aggregated state per magic index

   CLogger*       m_logger;         // Pointer to shared logger (not owned)

   //--- Map a magic number value to an ENUM_MAGIC_ID index (0/1/2)
   //    Returns -1 when the magic is not one of the three tracked values.
   int MagicToIndex(int magic)
   {
      if(magic == m_magicM1) return (int)MAGIC_M1;
      if(magic == m_magicM3) return (int)MAGIC_M3;
      if(magic == m_magicM2) return (int)MAGIC_M2;
      return -1;
   }

   //--- Reset aggregated MagicState to zero/default values
   void ResetStates()
   {
      for(int i = 0; i < 3; i++)
      {
         m_states[i].magicId        = i;
         m_states[i].totalPositions = 0;
         m_states[i].totalProfit    = 0.0;
         m_states[i].totalLots      = 0.0;
         // isLocked is intentionally preserved across refreshes
         m_states[i].worstProfit    =  DBL_MAX;
         m_states[i].worstTicket    = 0;
         m_states[i].bestProfit     = -DBL_MAX;
         m_states[i].bestTicket     = 0;
      }
   }

public:
   //+----------------------------------------------------------------+
   //| Constructor                                                     |
   //+----------------------------------------------------------------+
   CPositionTracker() : m_magicM1(0), m_magicM2(0), m_magicM3(0), m_logger(NULL)
   {
      ArrayResize(m_records, 0);
      ResetStates();
   }

   //+----------------------------------------------------------------+
   //| Init — store magic numbers and logger reference                |
   //| Parameters:                                                     |
   //|   magicM1 — magic number for buy grid                          |
   //|   magicM3 — magic number for sell grid                         |
   //|   magicM2 — magic number for assist/hedge                      |
   //|   logger  — shared logger instance (not owned)                 |
   //+----------------------------------------------------------------+
   void Init(int magicM1, int magicM3, int magicM2, CLogger* logger)
   {
      m_magicM1 = magicM1;
      m_magicM3 = magicM3;
      m_magicM2 = magicM2;
      m_logger  = logger;

      // Initialise magic ids in state array
      m_states[(int)MAGIC_M1].magicId = (int)MAGIC_M1;
      m_states[(int)MAGIC_M3].magicId = (int)MAGIC_M3;
      m_states[(int)MAGIC_M2].magicId = (int)MAGIC_M2;
   }

   //+----------------------------------------------------------------+
   //| Refresh — scan all open positions and rebuild records + states  |
   //| Call once per OnTick() before any other method.                |
   //+----------------------------------------------------------------+
   void Refresh()
   {
      // Preserve isLocked flags before reset
      bool locked[3];
      for(int i = 0; i < 3; i++) locked[i] = m_states[i].isLocked;

      ResetStates();

      // Restore locked flags
      for(int i = 0; i < 3; i++) m_states[i].isLocked = locked[i];

      int total = PositionsTotal();
      ArrayResize(m_records, total); // Upper-bound resize; shrink at end
      int count = 0;

      for(int i = 0; i < total; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;

         int magic = (int)PositionGetInteger(POSITION_MAGIC);
         int idx   = MagicToIndex(magic);
         if(idx < 0) continue; // Not our EA

         PositionRecord &rec = m_records[count];
         rec.ticket    = ticket;
         rec.magicId   = idx;
         rec.type      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         rec.openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         rec.lots      = PositionGetDouble(POSITION_VOLUME);
         rec.profit    = PositionGetDouble(POSITION_PROFIT)
                         + PositionGetDouble(POSITION_SWAP);
         rec.tp        = PositionGetDouble(POSITION_TP);
         rec.sl        = PositionGetDouble(POSITION_SL);
         rec.openTime  = (datetime)PositionGetInteger(POSITION_TIME);

         // Keeper flag: retrieve from state if previously set
         // We use a scan of existing records from last cycle — stored in
         // m_records, but since we just reset, we rely on a separate
         // m_keeperSet which we maintain below via MarkAsKeeper().
         // Default to false; MarkAsKeeper() is authoritative.
         rec.isKeeper  = false;

         // Derive grid level as the position's sequential index per magic
         rec.gridLevel = m_states[idx].totalPositions;

         // Update aggregates
         MagicState &st = m_states[idx];
         st.totalPositions++;
         st.totalProfit += rec.profit;
         st.totalLots   += rec.lots;

         if(rec.profit < st.worstProfit)
         {
            st.worstProfit  = rec.profit;
            st.worstTicket  = ticket;
         }
         if(rec.profit > st.bestProfit)
         {
            st.bestProfit   = rec.profit;
            st.bestTicket   = ticket;
         }

         count++;
      }

      ArrayResize(m_records, count);

      // Fix sentinel values for empty magic groups
      for(int i = 0; i < 3; i++)
      {
         if(m_states[i].totalPositions == 0)
         {
            m_states[i].worstProfit = 0.0;
            m_states[i].bestProfit  = 0.0;
         }
      }
   }

   //+----------------------------------------------------------------+
   //| GetMagicState — return a copy of the aggregated state          |
   //| Parameters: id — ENUM_MAGIC_ID index                           |
   //+----------------------------------------------------------------+
   MagicState GetMagicState(ENUM_MAGIC_ID id)
   {
      return m_states[(int)id];
   }

   //+----------------------------------------------------------------+
   //| GetWorstPosition — return the record with lowest profit        |
   //| Parameters: id — ENUM_MAGIC_ID index                           |
   //| Returns: PositionRecord with ticket=0 when no positions exist  |
   //+----------------------------------------------------------------+
   PositionRecord GetWorstPosition(ENUM_MAGIC_ID id)
   {
      PositionRecord empty = {};
      ulong wt = m_states[(int)id].worstTicket;
      if(wt == 0) return empty;

      int n = ArraySize(m_records);
      for(int i = 0; i < n; i++)
         if(m_records[i].ticket == wt) return m_records[i];
      return empty;
   }

   //+----------------------------------------------------------------+
   //| GetBestPosition — return the record with highest profit        |
   //| Parameters: id — ENUM_MAGIC_ID index                           |
   //| Returns: PositionRecord with ticket=0 when no positions exist  |
   //+----------------------------------------------------------------+
   PositionRecord GetBestPosition(ENUM_MAGIC_ID id)
   {
      PositionRecord empty = {};
      ulong bt = m_states[(int)id].bestTicket;
      if(bt == 0) return empty;

      int n = ArraySize(m_records);
      for(int i = 0; i < n; i++)
         if(m_records[i].ticket == bt) return m_records[i];
      return empty;
   }

   //+----------------------------------------------------------------+
   //| GetLastGridPrice — return the most recent openPrice for magic  |
   //| "Last" means the position opened most recently (highest time). |
   //| Parameters: id — ENUM_MAGIC_ID index                           |
   //| Returns: 0.0 when no positions exist for that magic            |
   //+----------------------------------------------------------------+
   double GetLastGridPrice(ENUM_MAGIC_ID id)
   {
      int      idx       = (int)id;
      datetime latestTime = 0;
      double   latestPrice = 0.0;

      int n = ArraySize(m_records);
      for(int i = 0; i < n; i++)
      {
         if(m_records[i].magicId != idx) continue;
         if(m_records[i].openTime >= latestTime)
         {
            latestTime  = m_records[i].openTime;
            latestPrice = m_records[i].openPrice;
         }
      }
      return latestPrice;
   }

   //+----------------------------------------------------------------+
   //| HasPositions — true if the magic has at least one open trade   |
   //| Parameters: id — ENUM_MAGIC_ID index                           |
   //+----------------------------------------------------------------+
   bool HasPositions(ENUM_MAGIC_ID id)
   {
      return m_states[(int)id].totalPositions > 0;
   }

   //+----------------------------------------------------------------+
   //| MarkAsKeeper — set/clear the keeper flag on a specific ticket  |
   //| Parameters:                                                     |
   //|   ticket — position ticket                                      |
   //|   flag   — true to mark as keeper, false to unmark             |
   //+----------------------------------------------------------------+
   void MarkAsKeeper(ulong ticket, bool flag)
   {
      int n = ArraySize(m_records);
      for(int i = 0; i < n; i++)
      {
         if(m_records[i].ticket == ticket)
         {
            m_records[i].isKeeper = flag;
            return;
         }
      }
   }

   //+----------------------------------------------------------------+
   //| SetLocked — set or clear the locked flag on a magic group      |
   //| Parameters:                                                     |
   //|   id     — ENUM_MAGIC_ID index                                 |
   //|   locked — new value                                            |
   //+----------------------------------------------------------------+
   void SetLocked(ENUM_MAGIC_ID id, bool locked)
   {
      m_states[(int)id].isLocked = locked;
   }

   //+----------------------------------------------------------------+
   //| GetAllRecords — copy matching records into the out array       |
   //| Parameters:                                                     |
   //|   out           — destination array (resized by this function) |
   //|   type          — filter by POSITION_TYPE; -1 = any            |
   //|   keeperOnly    — only include keeper positions                |
   //|   excludeKeeper — exclude keeper positions                     |
   //| Returns: count of records copied                               |
   //+----------------------------------------------------------------+
   int GetAllRecords(PositionRecord &out[],
                     int  type          = -1,
                     bool keeperOnly    = false,
                     bool excludeKeeper = false)
   {
      int n     = ArraySize(m_records);
      int count = 0;
      ArrayResize(out, n); // Upper-bound

      for(int i = 0; i < n; i++)
      {
         PositionRecord &rec = m_records[i];

         if(type != -1 && (int)rec.type != type) continue;
         if(keeperOnly    && !rec.isKeeper) continue;
         if(excludeKeeper &&  rec.isKeeper) continue;

         out[count++] = rec;
      }
      ArrayResize(out, count);
      return count;
   }

   //+----------------------------------------------------------------+
   //| GetRecordsByMagic — get all records for one magic group        |
   //| Parameters:                                                     |
   //|   id  — ENUM_MAGIC_ID index                                    |
   //|   out — destination array                                      |
   //| Returns: count of records copied                               |
   //+----------------------------------------------------------------+
   int GetRecordsByMagic(ENUM_MAGIC_ID id, PositionRecord &out[])
   {
      int idx = (int)id;
      int n   = ArraySize(m_records);
      ArrayResize(out, n);
      int count = 0;

      for(int i = 0; i < n; i++)
         if(m_records[i].magicId == idx)
            out[count++] = m_records[i];

      ArrayResize(out, count);
      return count;
   }
};
