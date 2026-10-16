//+------------------------------------------------------------------+
//|                                                       Logger.mqh |
//|  Simple leveled logger: Experts journal + text file in MQL5/Files |
//+------------------------------------------------------------------+
#ifndef EMATP_LOGGER_MQH
#define EMATP_LOGGER_MQH

enum ENUM_LOGLV
  {
   LOGLV_DEBUG = 0,   // Debug (everything)
   LOGLV_INFO  = 1,   // Info
   LOGLV_WARN  = 2,   // Warning
   LOGLV_ERROR = 3    // Error only
  };

class CLogger
  {
private:
   int        m_handle;
   ENUM_LOGLV m_min;
   bool       m_toFile;
   string     m_file;

   string     LevelText(const ENUM_LOGLV lv) const
     {
      switch(lv)
        {
         case LOGLV_DEBUG: return "DEBUG";
         case LOGLV_INFO:  return "INFO ";
         case LOGLV_WARN:  return "WARN ";
         default:          return "ERROR";
        }
     }

public:
                     CLogger() : m_handle(INVALID_HANDLE), m_min(LOGLV_INFO), m_toFile(false), m_file("") {}
                    ~CLogger() { Close(); }

   bool              Init(const string fileName, const ENUM_LOGLV minLevel, const bool toFile)
     {
      m_min    = minLevel;
      m_toFile = toFile;
      m_file   = fileName;
      if(!m_toFile)
         return true;
      ResetLastError();
      m_handle = FileOpen(m_file, FILE_READ | FILE_WRITE | FILE_TXT | FILE_SHARE_READ | FILE_ANSI);
      if(m_handle == INVALID_HANDLE)
        {
         PrintFormat("[Logger] cannot open %s, error %d - file logging disabled", m_file, GetLastError());
         m_toFile = false;
         return false;
        }
      FileSeek(m_handle, 0, SEEK_END);
      return true;
     }

   void              Close()
     {
      if(m_handle != INVALID_HANDLE)
        {
         FileClose(m_handle);
         m_handle = INVALID_HANDLE;
        }
     }

   void              Write(const ENUM_LOGLV lv, const string msg)
     {
      if(lv < m_min)
         return;
      string line = StringFormat("%s [%s] %s", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                                 LevelText(lv), msg);
      Print(line);
      if(m_toFile && m_handle != INVALID_HANDLE)
        {
         FileWriteString(m_handle, line + "\r\n");
         FileFlush(m_handle);
        }
     }

   void              Debug(const string msg) { Write(LOGLV_DEBUG, msg); }
   void              Info(const string msg)  { Write(LOGLV_INFO,  msg); }
   void              Warn(const string msg)  { Write(LOGLV_WARN,  msg); }
   void              Error(const string msg) { Write(LOGLV_ERROR, msg); }
   //--- trade events are always written at INFO level with a [TRADE] tag
   void              Trade(const string msg) { Write(LOGLV_INFO, "[TRADE] " + msg); }
  };

#endif
//+------------------------------------------------------------------+
