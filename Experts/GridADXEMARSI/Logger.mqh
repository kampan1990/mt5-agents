//+------------------------------------------------------------------+
//| Logger.mqh                                                        |
//| GridADXEMARSI EA                                                  |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-14                                               |
//+------------------------------------------------------------------+
#ifndef LOGGER_MQH
#define LOGGER_MQH

//+------------------------------------------------------------------+
//| CLogger — unified logging with level filtering and dashboard      |
//+------------------------------------------------------------------+
class CLogger
{
private:
   string m_ea_name;
   bool   m_verbose;

   //--- Internal helper: build timestamp prefix
   string Timestamp()
   {
      return "[" + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "]";
   }

   //--- Internal helper: write a tagged line to the Experts log
   void Write(string tag, string msg)
   {
      Print(Timestamp() + " [" + m_ea_name + "] [" + tag + "] " + msg);
   }

public:
   //--- Initialise logger
   //  @param ea_name   EA identifier shown in every log line
   //  @param verbose   when false, DEBUG lines are suppressed
   void Init(string ea_name, bool verbose)
   {
      m_ea_name = ea_name;
      m_verbose = verbose;
   }

   //--- General-purpose informational message
   void Info(string msg)
   {
      Write("INFO", msg);
   }

   //--- Debug-level detail, only emitted when verbose = true
   void Debug(string msg)
   {
      if(m_verbose)
         Write("DEBUG", msg);
   }

   //--- Non-fatal warning
   void Warn(string msg)
   {
      Write("WARN", msg);
   }

   //--- Fatal or unexpected error
   void Error(string msg)
   {
      Write("ERROR", msg);
   }

   //--- Log the opening of a trade position
   //  @param ticket   server ticket number
   //  @param type     ORDER_TYPE_BUY or ORDER_TYPE_SELL
   //  @param lot      volume opened
   //  @param price    execution price
   //  @param reason   human-readable reason string
   void TradeOpen(ulong ticket, ENUM_ORDER_TYPE type, double lot, double price, string reason)
   {
      Write("TRADE",
            StringFormat("OPEN  #%I64u  %s  lot=%.2f  price=%.5f  reason=[%s]",
                         ticket,
                         EnumToString(type),
                         lot,
                         price,
                         reason));
   }

   //--- Log the closing of a trade position
   //  @param ticket   server ticket number
   //  @param profit   realised P&L in account currency
   //  @param reason   human-readable reason string
   void TradeClose(ulong ticket, double profit, string reason)
   {
      Write("TRADE",
            StringFormat("CLOSE #%I64u  profit=%.2f  reason=[%s]",
                         ticket,
                         profit,
                         reason));
   }

   //--- Log a state-machine transition
   void StateChange(string old_state, string new_state)
   {
      Write("STATE",
            StringFormat("%s  ->  %s", old_state, new_state));
   }

   //--- Print a one-line dashboard to the Experts tab on every tick
   //  @param state            current numeric state value
   //  @param grid_count       number of open grid orders
   //  @param recovery_count   number of recovery orders placed so far
   //  @param total_profit     running P&L of all managed positions
   //  @param drawdown_pct     current drawdown from peak equity (%)
   void PrintDashboard(int    state,
                       int    grid_count,
                       int    recovery_count,
                       double total_profit,
                       double drawdown_pct)
   {
      string state_name;
      switch(state)
      {
         case 0:  state_name = "IDLE";          break;
         case 1:  state_name = "GRID_RUNNING";  break;
         case 2:  state_name = "RECOVERY";      break;
         case 3:  state_name = "TRAILING";      break;
         case 4:  state_name = "EMERGENCY";     break;
         default: state_name = "UNKNOWN";       break;
      }

      Write("DASH",
            StringFormat("State=%-12s  Grid=%d  Rec=%d  Profit=%.2f  DD=%.2f%%",
                         state_name,
                         grid_count,
                         recovery_count,
                         total_profit,
                         drawdown_pct));
   }
};

#endif // LOGGER_MQH
