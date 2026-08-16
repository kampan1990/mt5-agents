//+------------------------------------------------------------------+
//| Logger.mqh                                                       |
//| XAUGLM EA — Logging (depends on: Utils.mqh)                      |
//| Version: 1.0.0                                                   |
//| Created: 2026-08-16                                              |
//+------------------------------------------------------------------+
#pragma once
#include "Utils.mqh"

//--- Log severity / message category. LOG_TRADE is always written regardless of the
//--- configured minimum level because trade events are the audit trail this whole EA
//--- exists to produce.
enum ENUM_LOG_LEVEL
  {
   LOG_DEBUG = 0,
   LOG_INFO  = 1,
   LOG_WARN  = 2,
   LOG_ERROR = 3,
   LOG_TRADE = 4
  };

namespace Logger
  {
   int             g_fileHandle    = INVALID_HANDLE;
   ENUM_LOG_LEVEL  g_minLevel      = LOG_INFO;
   bool            g_initialized   = false;

   //--- Internal: human-readable tag for a level, used in both Print() and CSV rows.
   string LevelTag(const ENUM_LOG_LEVEL level)
     {
      switch(level)
        {
         case LOG_DEBUG: return "DEBUG";
         case LOG_INFO:  return "INFO";
         case LOG_WARN:  return "WARN";
         case LOG_ERROR: return "ERROR";
         case LOG_TRADE: return "TRADE";
        }
      return "UNKNOWN";
     }

   //--- Internal: create the log file's parent folder(s) under Common\Files if missing.
   //--- Purpose: InpLogFilePath is "XAUGLM\\logs\\trade_log.csv" — both "XAUGLM" and
   //--- "XAUGLM\\logs" must exist before FileOpen can create the CSV inside them.
   void EnsureDirectoryFor(const string filePath)
     {
      int lastSlash = -1;
      for(int i = StringLen(filePath) - 1; i >= 0; i--)
        {
         ushort ch = StringGetCharacter(filePath, i);
         if(ch == '\\' || ch == '/')
           {
            lastSlash = i;
            break;
           }
        }
      if(lastSlash < 0)
         return;

      string dir = StringSubstr(filePath, 0, lastSlash);

      // Create each path segment progressively (FolderCreate is not guaranteed to
      // create multi-level paths in one call on every build).
      string parts[];
      int n = StringSplit(dir, '\\', parts);
      string accum = "";
      for(int i = 0; i < n; i++)
        {
         accum = (i == 0) ? parts[i] : accum + "\\" + parts[i];
         FolderCreate(accum, FILE_COMMON);
        }
     }

   //--- Initialize the logger: sets the minimum level that will be printed/written and
   //--- opens (append mode) the CSV trade/audit log under Common\Files. Must be called
   //--- once from OnInit before any other Logger:: function.
   bool Init(const ENUM_LOG_LEVEL minLevel, const string csvPathRelative)
     {
      g_minLevel = minLevel;

      EnsureDirectoryFor(csvPathRelative);

      bool isNewFile = !FileIsExist(csvPathRelative, FILE_COMMON);

      g_fileHandle = FileOpen(csvPathRelative,
                               FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_READ,
                               ',');
      if(g_fileHandle == INVALID_HANDLE)
        {
         Print("[XAUGLM][ERROR] Logger::Init failed to open log file '", csvPathRelative,
               "' err=", GetLastError());
         g_initialized = false;
         return false;
        }

      if(isNewFile)
         FileWrite(g_fileHandle, "timestamp_utc", "level", "signal_id", "message");
      else
         FileSeek(g_fileHandle, 0, SEEK_END);

      g_initialized = true;
      Info("Logger initialized. minLevel=" + LevelTag(minLevel));
      return true;
     }

   //--- Internal: write one row to the CSV log and mirror it to the terminal Experts log.
   void WriteLine(const ENUM_LOG_LEVEL level, const string msg, const string signalId)
     {
      string ts  = TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS);
      string tag = LevelTag(level);

      // Always mirror to terminal so the operator sees it live even if file logging fails.
      PrintFormat("[%s] [%s] %s%s", ts, tag, (signalId == "" ? "" : "(" + signalId + ") "), msg);

      if(g_fileHandle != INVALID_HANDLE)
        {
         FileWrite(g_fileHandle, ts, tag, signalId, msg);
         FileFlush(g_fileHandle);
        }
     }

   //--- Internal: gate a message by the configured minimum level (LOG_TRADE always passes).
   void Emit(const ENUM_LOG_LEVEL level, const string msg, const string signalId = "")
     {
      if(level != LOG_TRADE && level < g_minLevel)
         return;
      WriteLine(level, msg, signalId);
     }

   void Debug(const string msg, const string signalId = "") { Emit(LOG_DEBUG, msg, signalId); }
   void Info(const string msg, const string signalId = "")  { Emit(LOG_INFO,  msg, signalId); }
   void Warn(const string msg, const string signalId = "")  { Emit(LOG_WARN,  msg, signalId); }
   void Error(const string msg, const string signalId = "") { Emit(LOG_ERROR, msg, signalId); }

   //--- Dedicated trade-event logger. Every order attempt (success or failure) and every
   //--- risk-gate rejection that would have led to an order MUST go through this so the
   //--- CSV audit trail is complete and correlated to the GLM signal_id that caused it.
   void Trade(const string msg, const string signalId = "") { Emit(LOG_TRADE, msg, signalId); }

   //--- Safely close the log file handle. Must be called from OnDeinit.
   void Close()
     {
      if(g_fileHandle != INVALID_HANDLE)
        {
         Info("Logger closing.");
         FileClose(g_fileHandle);
         g_fileHandle = INVALID_HANDLE;
        }
      g_initialized = false;
     }
  }
