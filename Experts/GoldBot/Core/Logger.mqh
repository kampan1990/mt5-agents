//+------------------------------------------------------------------+
//| Logger.mqh                                                        |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Provides structured logging to both MT5 Journal (Print) and CSV file.
// CSV file is named "GoldBot_YYYYMMDD.csv" and written to MQL5/Files/.
// Each log category has a dedicated method for consistent formatting.
//
#pragma once

//+------------------------------------------------------------------+
//| CLogger — handles all logging for GoldBot EA                      |
//+------------------------------------------------------------------+
class CLogger
{
private:
    int      m_file_handle;  // File handle for CSV output
    string   m_filename;     // "GoldBot_YYYYMMDD.csv"
    string   m_ea_name;      // EA identifier prefix in log lines
    bool     m_file_open;    // Guard flag for file operations

    //------------------------------------------------------------------
    // BuildTimestamp
    // Returns current server time formatted as "YYYY.MM.DD HH:MM:SS".
    //------------------------------------------------------------------
    string BuildTimestamp()
    {
        return TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
    }

    //------------------------------------------------------------------
    // WriteCSV
    // Appends a single line to the open CSV file.
    // Silently skips if file is not open.
    //------------------------------------------------------------------
    void WriteCSV(string line)
    {
        if(!m_file_open) return;
        FileWriteString(m_file_handle, line + "\n");
        FileFlush(m_file_handle);
    }

    //------------------------------------------------------------------
    // FormatLine
    // Produces "[timestamp] [category] message" string.
    //------------------------------------------------------------------
    string FormatLine(string category, string message)
    {
        return StringFormat("[%s] [%s] %s", BuildTimestamp(), category, message);
    }

public:
    //------------------------------------------------------------------
    // Constructor
    //------------------------------------------------------------------
    CLogger() : m_file_handle(INVALID_HANDLE), m_file_open(false) {}

    //------------------------------------------------------------------
    // Init
    // Opens the daily CSV log file in MQL5/Files/.
    // Creates header row if file is new.
    // Call from EA OnInit().
    //------------------------------------------------------------------
    void Init(string ea_name)
    {
        m_ea_name = ea_name;

        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);
        m_filename = StringFormat("%s_%04d%02d%02d.csv",
                                  ea_name, dt.year, dt.mon, dt.day);

        bool file_exists = FileIsExist(m_filename, FILE_COMMON);

        m_file_handle = FileOpen(m_filename,
                                  FILE_WRITE | FILE_READ | FILE_CSV | FILE_COMMON | FILE_ANSI,
                                  ',');

        if(m_file_handle == INVALID_HANDLE)
        {
            PrintFormat("[Logger] Cannot open log file %s, error %d",
                        m_filename, GetLastError());
            m_file_open = false;
            return;
        }

        m_file_open = true;

        // Seek to end so new entries are appended
        FileSeek(m_file_handle, 0, SEEK_END);

        // Write CSV header if this is a new file
        if(!file_exists)
        {
            FileWriteString(m_file_handle,
                "Timestamp,Category,Detail\n");
            FileFlush(m_file_handle);
        }

        PrintFormat("[Logger] Log file opened: %s", m_filename);
    }

    //------------------------------------------------------------------
    // Deinit
    // Closes the CSV file handle.
    // Call from EA OnDeinit().
    //------------------------------------------------------------------
    void Deinit()
    {
        if(m_file_open && m_file_handle != INVALID_HANDLE)
        {
            FileClose(m_file_handle);
            m_file_handle = INVALID_HANDLE;
            m_file_open   = false;
        }
    }

    //------------------------------------------------------------------
    // LogSignal
    // Records composite score evaluation result each bar.
    //------------------------------------------------------------------
    void LogSignal(datetime bar_time, string strategy_summary,
                   double bull_score, double bear_score, int bias)
    {
        string bias_str = (bias > 0) ? "BULL" : (bias < 0) ? "BEAR" : "NEUTRAL";
        string msg = StringFormat(
            "bar=%s strategies=%s bull=%.1f bear=%.1f bias=%s",
            TimeToString(bar_time, TIME_DATE | TIME_MINUTES),
            strategy_summary, bull_score, bear_score, bias_str);

        string line = FormatLine("SIGNAL", msg);
        Print(line);
        WriteCSV(StringFormat("%s,SIGNAL,%s", BuildTimestamp(), msg));
    }

    //------------------------------------------------------------------
    // LogOrderOpen
    // Records every new order sent by the EA.
    //------------------------------------------------------------------
    void LogOrderOpen(ulong ticket, int bias, double lot,
                      double entry, double sl, double tp1, double tp2)
    {
        string dir = (bias > 0) ? "BUY" : "SELL";
        string msg = StringFormat(
            "ticket=%llu dir=%s lot=%.2f entry=%.5f sl=%.5f tp1=%.5f tp2=%.5f",
            ticket, dir, lot, entry, sl, tp1, tp2);

        string line = FormatLine("ORDER_OPEN", msg);
        Print(line);
        WriteCSV(StringFormat("%s,ORDER_OPEN,%s", BuildTimestamp(), msg));
    }

    //------------------------------------------------------------------
    // LogOrderClose
    // Records position close events with profit and close reason.
    //------------------------------------------------------------------
    void LogOrderClose(ulong ticket, double profit, string reason)
    {
        string msg = StringFormat("ticket=%llu profit=%.2f reason=%s",
                                  ticket, profit, reason);
        string line = FormatLine("ORDER_CLOSE", msg);
        Print(line);
        WriteCSV(StringFormat("%s,ORDER_CLOSE,%s", BuildTimestamp(), msg));
    }

    //------------------------------------------------------------------
    // LogBreakeven
    // Records SL modification to breakeven level.
    //------------------------------------------------------------------
    void LogBreakeven(ulong ticket, double new_sl)
    {
        string msg = StringFormat("ticket=%llu new_sl=%.5f", ticket, new_sl);
        string line = FormatLine("BREAKEVEN", msg);
        Print(line);
        WriteCSV(StringFormat("%s,BREAKEVEN,%s", BuildTimestamp(), msg));
    }

    //------------------------------------------------------------------
    // LogProfitLock
    // Records equity-peak trailing SL modification.
    //------------------------------------------------------------------
    void LogProfitLock(ulong ticket, double new_sl, double equity_peak)
    {
        string msg = StringFormat("ticket=%llu new_sl=%.5f equity_peak=%.2f",
                                  ticket, new_sl, equity_peak);
        string line = FormatLine("PROFIT_LOCK", msg);
        Print(line);
        WriteCSV(StringFormat("%s,PROFIT_LOCK,%s", BuildTimestamp(), msg));
    }

    //------------------------------------------------------------------
    // LogDailyLimit
    // Records when a daily trading limit is reached.
    //------------------------------------------------------------------
    void LogDailyLimit(string reason, double value)
    {
        string msg = StringFormat("reason=%s value=%.2f", reason, value);
        string line = FormatLine("DAILY_LIMIT", msg);
        Print(line);
        WriteCSV(StringFormat("%s,DAILY_LIMIT,%s", BuildTimestamp(), msg));
    }

    //------------------------------------------------------------------
    // LogError
    // Records trading errors with context and MQL5 error code.
    //------------------------------------------------------------------
    void LogError(string context, int error_code)
    {
        string msg = StringFormat("context=%s error=%d", context, error_code);
        string line = FormatLine("ERROR", msg);
        Print(line);
        WriteCSV(StringFormat("%s,ERROR,%s", BuildTimestamp(), msg));
    }

    //------------------------------------------------------------------
    // LogInfo
    // General informational message.
    //------------------------------------------------------------------
    void LogInfo(string message)
    {
        string line = FormatLine("INFO", message);
        Print(line);
        WriteCSV(StringFormat("%s,INFO,%s", BuildTimestamp(), message));
    }

    //------------------------------------------------------------------
    // LogWarning
    // Warning message for non-critical anomalies.
    //------------------------------------------------------------------
    void LogWarning(string message)
    {
        string line = FormatLine("WARN", message);
        Print(line);
        WriteCSV(StringFormat("%s,WARN,%s", BuildTimestamp(), message));
    }
};
