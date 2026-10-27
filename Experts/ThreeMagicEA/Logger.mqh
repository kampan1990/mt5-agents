//+------------------------------------------------------------------+
//|                                                       Logger.mqh |
//|                          ThreeMagicEA - Logging system module    |
//+------------------------------------------------------------------+
#ifndef THREEMAGIC_LOGGER_MQH
#define THREEMAGIC_LOGGER_MQH
#property strict

//+------------------------------------------------------------------+
//| Log levels                                                       |
//+------------------------------------------------------------------+
enum ENUM_LOG_LEVEL
  {
   LOG_DEBUG   = 0,
   LOG_INFO    = 1,
   LOG_WARN    = 2,
   LOG_ERROR   = 3
  };

//+------------------------------------------------------------------+
//| CLogger - central logging with optional file output             |
//+------------------------------------------------------------------+
class CLogger
  {
private:
   ENUM_LOG_LEVEL    m_minLevel;
   bool              m_toFile;
   int               m_fileHandle;
   string            m_prefix;

   string            LevelText(ENUM_LOG_LEVEL lvl)
     {
      switch(lvl)
        {
         case LOG_DEBUG: return "DEBUG";
         case LOG_INFO:  return "INFO ";
         case LOG_WARN:  return "WARN ";
         case LOG_ERROR: return "ERROR";
        }
      return "?????";
     }

   void              Write(ENUM_LOG_LEVEL lvl,const string tag,const string msg)
     {
      if(lvl<m_minLevel)
         return;
      string line=StringFormat("%s [%s] [%s] %s",
                               TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
                               LevelText(lvl),tag,msg);
      Print(m_prefix,line);
      if(m_toFile && m_fileHandle!=INVALID_HANDLE)
        {
         FileWrite(m_fileHandle,line);
         FileFlush(m_fileHandle);
        }
     }

public:
                     CLogger(void)
     {
      m_minLevel  = LOG_INFO;
      m_toFile    = false;
      m_fileHandle= INVALID_HANDLE;
      m_prefix    = "ThreeMagicEA | ";
     }

                    ~CLogger(void)
     {
      if(m_fileHandle!=INVALID_HANDLE)
         FileClose(m_fileHandle);
     }

   void              Init(ENUM_LOG_LEVEL minLevel,bool toFile,const string fileName="")
     {
      m_minLevel=minLevel;
      m_toFile  =toFile;
      if(m_toFile)
        {
         string fn=(fileName=="" ? "ThreeMagicEA.log" : fileName);
         m_fileHandle=FileOpen(fn,FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
         if(m_fileHandle!=INVALID_HANDLE)
            FileSeek(m_fileHandle,0,SEEK_END);
         else
            m_toFile=false;
        }
     }

   void              Debug(const string tag,const string msg){ Write(LOG_DEBUG,tag,msg); }
   void              Info (const string tag,const string msg){ Write(LOG_INFO ,tag,msg); }
   void              Warn (const string tag,const string msg){ Write(LOG_WARN ,tag,msg); }
   void              Error(const string tag,const string msg){ Write(LOG_ERROR,tag,msg); }

   //--- convenience: log a trade event with GetLastError context
   void              TradeEvent(const string tag,const string msg,uint retcode,int lastError)
     {
      Write(LOG_INFO,tag,StringFormat("%s | retcode=%u lastError=%d",msg,retcode,lastError));
     }
  };
//+------------------------------------------------------------------+
#endif // THREEMAGIC_LOGGER_MQH
