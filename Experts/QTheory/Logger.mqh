//+------------------------------------------------------------------+
//| Logger.mqh                                                        |
//| QTheory EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026.11.03                                               |
//+------------------------------------------------------------------+
#ifndef QT_LOGGER_MQH
#define QT_LOGGER_MQH

enum ENUM_LOG_LEVEL { LOG_DEBUG, LOG_INFO, LOG_WARN, LOG_ERROR, LOG_TRADE };

namespace Logger
{
   string s_name   = "QTheory";
   string s_file   = "QTheory_log.txt";
   bool   s_toFile = true;
   bool   s_debug  = false;

   //--- ตั้งค่า logger | name = ชื่อ EA/ไฟล์ | toFile = เขียนไฟล์ | debug = แสดง Debug
   void Init(const string name, const bool toFile, const bool debug)
   {
      s_name   = name;
      s_file   = name + "_log.txt";
      s_toFile = toFile;
      s_debug  = debug;
   }

   //--- ชื่อระดับ log
   string LevelName(const ENUM_LOG_LEVEL level)
   {
      switch(level)
      {
         case LOG_DEBUG: return "DEBUG";
         case LOG_INFO:  return "INFO";
         case LOG_WARN:  return "WARN";
         case LOG_ERROR: return "ERROR";
         case LOG_TRADE: return "TRADE";
      }
      return "INFO";
   }

   //--- เขียน log หนึ่งบรรทัด: [2024.01.15 09:30:00] [TRADE] ...
   void Write(const ENUM_LOG_LEVEL level, const string msg)
   {
      if(level == LOG_DEBUG && !s_debug) return;
      string line = "[" + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "] ["
                    + LevelName(level) + "] " + msg;
      Print(s_name, " ", line);
      if(!s_toFile) return;
      int h = FileOpen(s_file, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(h == INVALID_HANDLE) return;
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, line + "\r\n");
      FileClose(h);
   }

   void Debug(const string msg) { Write(LOG_DEBUG, msg); }
   void Info(const string msg)  { Write(LOG_INFO, msg); }
   void Warn(const string msg)  { Write(LOG_WARN, msg); }
   void Error(const string msg) { Write(LOG_ERROR, msg); }
   void Trade(const string msg) { Write(LOG_TRADE, msg); }
}

#endif
