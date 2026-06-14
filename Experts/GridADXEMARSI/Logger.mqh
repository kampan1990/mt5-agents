//+------------------------------------------------------------------+
//| Logger.mqh                                                        |
//| GridADXEMARSI EA                                                  |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-14                                               |
//+------------------------------------------------------------------+
#ifndef LOGGER_MQH
#define LOGGER_MQH

#property strict

//+------------------------------------------------------------------+
//| CLogger — centralized logging for all EA events                  |
//| Prints timestamped messages to the Experts log tab               |
//+------------------------------------------------------------------+
class CLogger
{
private:
    string m_ea_name;   // EA name prefix shown in every log line
    bool   m_verbose;   // when false, Debug-level messages are suppressed

    //--- Internal formatter: [YYYY.MM.DD HH:MM:SS] [LEVEL] ea_name: msg
    string Format(string level, string msg)
    {
        datetime now = TimeCurrent();
        MqlDateTime dt;
        TimeToStruct(now, dt);
        string ts = StringFormat("%04d.%02d.%02d %02d:%02d:%02d",
                                 dt.year, dt.mon, dt.day,
                                 dt.hour, dt.min, dt.sec);
        return StringFormat("[%s] [%s] %s: %s", ts, level, m_ea_name, msg);
    }

public:
    //+------------------------------------------------------------------+
    //| Init — must be called in OnInit before any logging              |
    //| ea_name : short label appended to every line                    |
    //| verbose  : true = log everything; false = skip INFO/DEBUG       |
    //+------------------------------------------------------------------+
    void Init(string ea_name, bool verbose)
    {
        m_ea_name = ea_name;
        m_verbose = verbose;
    }

    //+------------------------------------------------------------------+
    //| Info — informational messages (suppressed when verbose=false)   |
    //+------------------------------------------------------------------+
    void Info(string msg)
    {
        if(m_verbose)
            Print(Format("INFO ", msg));
    }

    //+------------------------------------------------------------------+
    //| Warn — warnings always printed regardless of verbose flag       |
    //+------------------------------------------------------------------+
    void Warn(string msg)
    {
        Print(Format("WARN ", msg));
    }

    //+------------------------------------------------------------------+
    //| Error — errors always printed, shown in red in Experts log      |
    //+------------------------------------------------------------------+
    void Error(string msg)
    {
        Print(Format("ERROR", msg));
    }

    //+------------------------------------------------------------------+
    //| TradeOpen — log a newly opened position                         |
    //| ticket : server ticket number                                    |
    //| type   : ORDER_TYPE_BUY or ORDER_TYPE_SELL                      |
    //| lot    : volume opened                                           |
    //| price  : execution price                                         |
    //| reason : short string describing why the order was placed       |
    //+------------------------------------------------------------------+
    void TradeOpen(ulong ticket, ENUM_ORDER_TYPE type, double lot,
                   double price, string reason)
    {
        string dir = (type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
        Print(Format("TRADE",
              StringFormat("OPEN  #%I64u %s lot=%.2f @ %.5f | %s",
                           ticket, dir, lot, price, reason)));
    }

    //+------------------------------------------------------------------+
    //| TradeClose — log a closed/removed position                      |
    //| ticket : server ticket number                                    |
    //| profit : realized P&L in account currency                       |
    //| reason : short string describing why the position was closed    |
    //+------------------------------------------------------------------+
    void TradeClose(ulong ticket, double profit, string reason)
    {
        Print(Format("TRADE",
              StringFormat("CLOSE #%I64u profit=%.2f | %s",
                           ticket, profit, reason)));
    }

    //+------------------------------------------------------------------+
    //| StateChange — log EA state-machine transitions                  |
    //+------------------------------------------------------------------+
    void StateChange(string old_state, string new_state)
    {
        Print(Format("STATE",
              StringFormat("%s → %s", old_state, new_state)));
    }

    //+------------------------------------------------------------------+
    //| PrintDashboard — one-line status printed every tick (verbose)   |
    //| state           : current EA state integer                      |
    //| grid_count      : number of active grid positions               |
    //| recovery_count  : number of recovery orders placed this cycle   |
    //| total_profit    : floating P&L of all EA positions              |
    //| drawdown_pct    : current drawdown from peak equity in percent  |
    //+------------------------------------------------------------------+
    void PrintDashboard(int state, int grid_count, int recovery_count,
                        double total_profit, double drawdown_pct)
    {
        if(!m_verbose)
            return;

        string state_str;
        switch(state)
        {
            case 0:  state_str = "IDLE";         break;
            case 1:  state_str = "GRID_RUNNING"; break;
            case 2:  state_str = "RECOVERY";     break;
            case 3:  state_str = "TRAILING";     break;
            case 4:  state_str = "EMERGENCY";    break;
            default: state_str = "UNKNOWN";      break;
        }

        Comment(StringFormat(
            "=== GridADXEMARSI Dashboard ===\n"
            "State     : %s\n"
            "Grid ord  : %d\n"
            "Recovery  : %d\n"
            "Float P&L : %.2f\n"
            "Drawdown  : %.2f%%\n"
            "Time      : %s",
            state_str, grid_count, recovery_count,
            total_profit, drawdown_pct,
            TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS)));
    }
};

#endif // LOGGER_MQH
