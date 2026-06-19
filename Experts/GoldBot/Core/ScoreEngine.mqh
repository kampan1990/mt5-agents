//+------------------------------------------------------------------+
//| ScoreEngine.mqh                                                   |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Aggregates scores from 12 independent strategy modules.
// Computes weighted bull and bear composite scores.
// Determines trade bias and whether conditions meet the threshold.
//
#pragma once
#include "../Strategies/BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| CompositeResult — output of ScoreEngine.Calculate()              |
//+------------------------------------------------------------------+
struct CompositeResult
{
    double   bull_score;         // 0.0 – 100.0 weighted bullish composite
    double   bear_score;         // 0.0 – 100.0 weighted bearish composite
    int      bias;               // +1 = BUY, -1 = SELL, 0 = NEUTRAL
    int      active_count;       // Number of strategies with score > 0
    string   top_contributors;   // Comma-separated names of top scorers for logging
    StrategyScore scores[12];    // Raw scores from each strategy module
};

//+------------------------------------------------------------------+
//| CScoreEngine                                                      |
//+------------------------------------------------------------------+
class CScoreEngine
{
private:
    CBaseStrategy*  m_strategies[12]; // Pointers to all 12 strategy objects
    double          m_weights[12];    // Per-strategy weight multipliers
    double          m_threshold;      // Minimum composite score % to trade
    int             m_min_active;     // Minimum strategies with score > 0

public:
    CScoreEngine()
    {
        for(int i = 0; i < 12; i++)
        {
            m_strategies[i] = NULL;
            m_weights[i]    = 1.0;
        }
        m_threshold  = 65.0;
        m_min_active = 3;
    }

    //------------------------------------------------------------------
    // Init
    // Stores references to strategy objects, weight array, threshold, and
    // minimum active strategy count.
    // strats[]: array of 12 CBaseStrategy pointers (must remain valid)
    // weights[]: weight multiplier for each strategy (index-matched)
    //------------------------------------------------------------------
    void Init(CBaseStrategy* strats[], double weights[],
              double threshold, int min_active)
    {
        for(int i = 0; i < 12; i++)
        {
            m_strategies[i] = strats[i];
            m_weights[i]    = weights[i];
        }
        m_threshold  = threshold;
        m_min_active = min_active;
    }

    //------------------------------------------------------------------
    // Calculate
    // Calls Evaluate() on each strategy and aggregates scores.
    // Score aggregation formula:
    //   For each strategy i:
    //     if bias == +1: bull_sum += score[i] * weight[i], bull_w_sum += weight[i]
    //     if bias == -1: bear_sum += score[i] * weight[i], bear_w_sum += weight[i]
    //   bull_score = (bull_w_sum > 0) ? (bull_sum / bull_w_sum) * 100 : 0
    //   bear_score = (bear_w_sum > 0) ? (bear_sum / bear_w_sum) * 100 : 0
    //------------------------------------------------------------------
    CompositeResult Calculate()
    {
        CompositeResult result;
        result.bull_score       = 0.0;
        result.bear_score       = 0.0;
        result.bias             = 0;
        result.active_count     = 0;
        result.top_contributors = "";

        double bull_sum     = 0.0;
        double bull_w_sum   = 0.0;
        double bear_sum     = 0.0;
        double bear_w_sum   = 0.0;

        string contributors = "";

        for(int i = 0; i < 12; i++)
        {
            if(m_strategies[i] == NULL) continue;

            StrategyScore s = m_strategies[i].Evaluate();
            result.scores[i] = s;

            if(s.score <= 0.0) continue;

            result.active_count++;

            double w = m_weights[i];
            if(s.bias > 0)
            {
                bull_sum   += s.score * w;
                bull_w_sum += w;
            }
            else if(s.bias < 0)
            {
                bear_sum   += s.score * w;
                bear_w_sum += w;
            }
            // bias == 0: strategy scored but is direction-neutral — exclude from composite

            // Track top contributors (score > 0.5)
            if(s.score >= 0.5)
            {
                if(StringLen(contributors) > 0) contributors += ",";
                contributors += StringFormat("%s(%.0f%%)", s.name, s.score * 100);
            }
        }

        result.bull_score = (bull_w_sum > 0.0) ? (bull_sum / bull_w_sum) * 100.0 : 0.0;
        result.bear_score = (bear_w_sum > 0.0) ? (bear_sum / bear_w_sum) * 100.0 : 0.0;
        result.top_contributors = contributors;

        // Determine bias: dominant side must also meet threshold
        if(result.bull_score > result.bear_score && result.bull_score >= m_threshold)
            result.bias = 1;
        else if(result.bear_score > result.bull_score && result.bear_score >= m_threshold)
            result.bias = -1;
        else
            result.bias = 0;

        return result;
    }

    //------------------------------------------------------------------
    // ShouldTrade
    // Returns true if composite result meets all gating conditions:
    //   - bias != 0 (one side exceeds threshold)
    //   - active_count >= min_active
    // out_bias: receives the determined bias (+1 or -1)
    //------------------------------------------------------------------
    bool ShouldTrade(CompositeResult &result, int &out_bias)
    {
        out_bias = 0;
        if(result.bias == 0) return false;
        if(result.active_count < m_min_active) return false;

        out_bias = result.bias;
        return true;
    }

    //------------------------------------------------------------------
    // GetThreshold — returns the configured score threshold
    //------------------------------------------------------------------
    double GetThreshold() { return m_threshold; }

    //------------------------------------------------------------------
    // GetMinActive — returns minimum active strategies required
    //------------------------------------------------------------------
    int GetMinActive() { return m_min_active; }
};
