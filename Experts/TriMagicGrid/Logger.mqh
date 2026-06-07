//+------------------------------------------------------------------+
//| Logger.mqh                                                       |
//| TriMagicGrid EA                                                  |
//| Version: 1.0.0                                                   |
//| Created: 2026.06.07                                              |
//+------------------------------------------------------------------+
#pragma once

//+------------------------------------------------------------------+
//| CLogger — structured logging to Expert tab and/or file           |
//+------------------------------------------------------------------+
class CLogger
{
private:
   bool   m_printToExpert;   // Print messages to Expert Advisor log tab
   bool   m_writeToFile;     // Write messages to a log file
   string m_filename;        // Base log filename (without extension)
   int    m_fileHandle;      // File handle (-1 when closed)

   //--- Build a formatted timestamp prefix
   string GetTimestamp()
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      return StringFormat("[%04d.%02d.%02d %02d:%02d:%02d]",
                          dt.year, dt.mon, dt.day,
                          dt.hour, dt.min, dt.sec);
   }

   //--- Internal write to file helper
   void WriteToFile(const string &line)
   {
      if(m_fileHandle == INVALID_HANDLE) return;
      FileWriteString(m_fileHandle, line + "\n");
      FileFlush(m_fileHandle);
   }

   //--- Internal dispatcher for all log levels
   void Log(string level, string message)
   {
      string line = GetTimestamp() + " [" + level + "] " + message;
      if(m_printToExpert)
         Print(line);
      if(m_writeToFile)
         WriteToFile(line);
   }

public:
   //+----------------------------------------------------------------+
   //| Constructor — sets invalid defaults                             |
   //+----------------------------------------------------------------+
   CLogger() : m_printToExpert(true), m_writeToFile(false),
               m_filename("TMG_Log"), m_fileHandle(INVALID_HANDLE) {}

   //+----------------------------------------------------------------+
   //| Destructor — ensure file handle is closed                      |
   //+----------------------------------------------------------------+
   ~CLogger() { Close(); }

   //+----------------------------------------------------------------+
   //| Init — configure logging targets and open file if requested    |
   //| Parameters:                                                     |
   //|   printToExpert — log to Expert Advisor tab                    |
   //|   writeToFile   — log to a text file in the MQL5/Files folder  |
   //|   filename      — base filename without extension              |
   //+----------------------------------------------------------------+
   void Init(bool printToExpert, bool writeToFile, string filename)
   {
      m_printToExpert = printToExpert;
      m_writeToFile   = writeToFile;
      m_filename      = filename;

      if(m_writeToFile)
      {
         // Include date in filename to avoid unbounded growth
         MqlDateTime dt;
         TimeToStruct(TimeCurrent(), dt);
         string fullName = StringFormat("%s_%04d%02d%02d.log",
                                        m_filename, dt.year, dt.mon, dt.day);
         m_fileHandle = FileOpen(fullName, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
         if(m_fileHandle == INVALID_HANDLE)
            Print("CLogger::Init — cannot open log file: ", fullName,
                  " error=", GetLastError());
      }
   }

   //+----------------------------------------------------------------+
   //| Close — flush and close the log file handle                    |
   //+----------------------------------------------------------------+
   void Close()
   {
      if(m_fileHandle != INVALID_HANDLE)
      {
         FileClose(m_fileHandle);
         m_fileHandle = INVALID_HANDLE;
      }
   }

   //+----------------------------------------------------------------+
   //| LogTrade — record a trade lifecycle event                      |
   //| Parameters:                                                     |
   //|   event  — "OPEN", "CLOSE", "MODIFY", etc.                    |
   //|   ticket — position/order ticket                               |
   //|   price  — execution price                                     |
   //|   lots   — trade volume                                        |
   //|   profit — floating or realised profit                         |
   //|   extra  — optional additional context string                  |
   //+----------------------------------------------------------------+
   void LogTrade(string event, ulong ticket, double price,
                 double lots, double profit, string extra = "")
   {
      string msg = StringFormat("[TRADE] event=%s ticket=%I64u price=%.5f lots=%.2f profit=%.2f",
                                event, ticket, price, lots, profit);
      if(extra != "") msg += " " + extra;
      Log("INFO", msg);
   }

   //+----------------------------------------------------------------+
   //| LogState — record a component state transition                 |
   //| Parameters:                                                     |
   //|   component — name of the module/class                         |
   //|   stateDesc — human-readable description of the new state      |
   //+----------------------------------------------------------------+
   void LogState(string component, string stateDesc)
   {
      Log("INFO", "[STATE] [" + component + "] " + stateDesc);
   }

   //+----------------------------------------------------------------+
   //| LogError — record an error with context information            |
   //| Parameters:                                                     |
   //|   function  — function name where the error occurred           |
   //|   errorCode — error code from GetLastError() or retcode        |
   //|   context   — optional extra context string                    |
   //+----------------------------------------------------------------+
   void LogError(string function, int errorCode, string context = "")
   {
      string msg = StringFormat("[ERROR] func=%s code=%d", function, errorCode);
      if(context != "") msg += " ctx=" + context;
      Log("ERROR", msg);
   }

   //+----------------------------------------------------------------+
   //| LogInfo — general informational message                        |
   //+----------------------------------------------------------------+
   void LogInfo(string message)
   {
      Log("INFO", message);
   }

   //+----------------------------------------------------------------+
   //| LogWarn — warning message                                      |
   //+----------------------------------------------------------------+
   void LogWarn(string message)
   {
      Log("WARN", message);
   }
};
