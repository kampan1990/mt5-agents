//+------------------------------------------------------------------+
//| Signal.mqh - Layer 4-5: โมเดล ONNX + เกณฑ์ตัดสินใจ                |
//| ONNX output: label(int64), probabilities[1,3] = {HOLD, BUY, SELL} |
//+------------------------------------------------------------------+
#property strict
#include "Features.mqh"

#define SIG_NONE 0
#define SIG_BUY  1
#define SIG_SELL -1

class CSignal
{
private:
   long   m_h;
   double m_thr;
   double m_margin;

public:
   CSignal() : m_h(INVALID_HANDLE), m_thr(0.6), m_margin(0.1) {}
   ~CSignal() { if(m_h != INVALID_HANDLE) OnnxRelease(m_h); }

   bool Init(const string file, const double thr, const double margin)
   {
      m_thr = thr; m_margin = margin;
      m_h = OnnxCreate(file, ONNX_DEFAULT);
      if(m_h == INVALID_HANDLE) { LogError("OnnxCreate(" + file + ")"); return false; }
      long in_shape[]  = {1, FEATURE_COUNT};
      long lab_shape[] = {1};
      long prb_shape[] = {1, 3};
      if(!OnnxSetInputShape(m_h, 0, in_shape) ||
         !OnnxSetOutputShape(m_h, 0, lab_shape) ||
         !OnnxSetOutputShape(m_h, 1, prb_shape))
      { LogError("OnnxSetShape"); return false; }
      return true;
   }

   // คืน SIG_BUY / SIG_SELL / SIG_NONE พร้อมความน่าจะเป็น
   int Evaluate(const SFeatureSet &f, double &pBuy, double &pSell)
   {
      pBuy = 0; pSell = 0;
      matrixf x(1, FEATURE_COUNT);
      for(int i = 0; i < FEATURE_COUNT; i++) x[0][i] = f.v[i];
      long label[1];
      matrixf prob;
      if(!OnnxRun(m_h, ONNX_NO_CONVERSION, x, label, prob)) { LogError("OnnxRun"); return SIG_NONE; }
      pBuy = prob[0][1]; pSell = prob[0][2];
      if(pBuy  >= m_thr && pBuy  - pSell >= m_margin) return SIG_BUY;
      if(pSell >= m_thr && pSell - pBuy  >= m_margin) return SIG_SELL;
      return SIG_NONE;
   }
};
