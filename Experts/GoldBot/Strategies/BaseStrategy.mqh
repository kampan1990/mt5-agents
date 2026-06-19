//+------------------------------------------------------------------+
//| BaseStrategy.mqh                                                  |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Defines the StrategyScore struct and the CBaseStrategy abstract class.
// All 12 strategy modules inherit from CBaseStrategy and must implement
// Init(), Deinit(), and Evaluate().
//
#pragma once
#include "../Utils/ATRUtils.mqh"

//+------------------------------------------------------------------+
//| StrategyScore — result returned by every strategy Evaluate()      |
//+------------------------------------------------------------------+
struct StrategyScore
{
    string   name;    // Strategy identifier (e.g. "EMAcross")
    double   score;   // Normalized score 0.0 – 1.0 (0% – 100%)
    int      bias;    // +1 = bullish, -1 = bearish, 0 = neutral
    string   reason;  // Human-readable summary for Logger
};

//+------------------------------------------------------------------+
//| CBaseStrategy — abstract base class for all strategy modules      |
//+------------------------------------------------------------------+
class CBaseStrategy
{
protected:
    string           m_name;          // Strategy name used in logs
    int              m_magic_offset;  // Added to MagicBase (0-11)
    CATRUtils        m_atr;           // Shared ATR utility instance

public:
    //------------------------------------------------------------------
    // Constructor
    //------------------------------------------------------------------
    CBaseStrategy() : m_magic_offset(0) {}

    //------------------------------------------------------------------
    // Virtual destructor — ensures proper cleanup of derived classes
    //------------------------------------------------------------------
    virtual ~CBaseStrategy() {}

    //------------------------------------------------------------------
    // Init (pure virtual)
    // Must initialize indicator handles.
    // atr_period: period for ATR, tf: primary timeframe for ATR.
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) = 0;

    //------------------------------------------------------------------
    // Deinit (pure virtual)
    // Must release all indicator handles opened in Init().
    //------------------------------------------------------------------
    virtual void Deinit() = 0;

    //------------------------------------------------------------------
    // Evaluate (pure virtual)
    // Called on each new M15 bar.
    // Returns a StrategyScore with score, bias, and reason string.
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() = 0;

    //------------------------------------------------------------------
    // GetName — returns the strategy name
    //------------------------------------------------------------------
    string GetName() { return m_name; }

    //------------------------------------------------------------------
    // GetOffset — returns the magic number offset (0-11)
    //------------------------------------------------------------------
    int GetOffset() { return m_magic_offset; }

    //------------------------------------------------------------------
    // IsATRReady — returns true if the ATR buffer is populated
    //------------------------------------------------------------------
    bool IsATRReady() { return m_atr.IsReady(); }
};
