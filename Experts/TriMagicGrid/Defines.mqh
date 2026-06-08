//+------------------------------------------------------------------+
//| Defines.mqh                                                      |
//| TriMagicGrid EA                                                  |
//| Version: 1.0.0                                                   |
//| Created: 2026.06.07                                              |
//+------------------------------------------------------------------+
#pragma once

//--- M2 State Machine states
enum ENUM_M2_STATE
{
   M2_STATE_NORMAL      = 0,  // Normal operation, no lock
   M2_STATE_LOCKED_BUY  = 1,  // M2 is helping buy side (M1 locked)
   M2_STATE_LOCKED_SELL = 2   // M2 is helping sell side (M3 locked)
};

//--- TP Mode selection
enum ENUM_TP_MODE
{
   TP_MODE_1 = 0,  // Per-magic profit targets
   TP_MODE_2 = 1,  // Pair-based combined profit targets
   TP_MODE_3 = 2   // All-magic combined profit target
};

//--- Magic ID index (used for array indexing)
enum ENUM_MAGIC_ID
{
   MAGIC_M1 = 0,  // Buy grid magic
   MAGIC_M3 = 1,  // Sell grid magic
   MAGIC_M2 = 2   // Assist/hedge magic
};

//--- Record of a single open position
struct PositionRecord
{
   ulong                ticket;      // Position ticket
   int                  magicId;     // 0=M1, 1=M3, 2=M2
   ENUM_POSITION_TYPE   type;        // BUY or SELL
   double               openPrice;   // Entry price
   double               lots;        // Volume
   double               profit;      // Floating profit
   double               tp;          // Take-profit price
   double               sl;          // Stop-loss price
   bool                 isKeeper;    // Flagged as keeper position
   int                  gridLevel;   // Grid level index (0-based)
   datetime             openTime;    // Position open time
};

//--- Aggregated state for one magic number
struct MagicState
{
   int    magicId;          // Which magic (0=M1,1=M3,2=M2)
   int    totalPositions;   // Count of open positions
   double totalProfit;      // Sum of floating profit
   double totalLots;        // Sum of open lots
   bool   isLocked;         // Whether this magic is locked by M2 controller
   double worstProfit;      // Lowest individual position profit
   ulong  worstTicket;      // Ticket of worst position
   double bestProfit;       // Highest individual position profit
   ulong  bestTicket;       // Ticket of best position
};

//--- M2 state machine info snapshot
struct M2StateInfo
{
   ENUM_M2_STATE state;           // Current state
   int           helpingSide;     // POSITION_TYPE_BUY, POSITION_TYPE_SELL, or -1
   double        lockThreshold;   // Profit threshold that triggers a lock
   bool          waitingClear;    // True when waiting for locked side to close fully
};
