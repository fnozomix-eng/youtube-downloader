//+------------------------------------------------------------------+
//|                                     HarmonicPatternScanner.mq5    |
//|  ハーモニックパターンを自動で探して描画するインジケーター          |
//|                                                                  |
//|  ・独自の ZigZag でスイング (高値/安値) を検出                     |
//|  ・連続する 5点 X-A-B-C-D をフィボナッチ比率で判定                 |
//|    Gartley / Bat / Alt Bat / Butterfly / Crab / Deep Crab / Cypher |
//|  ・形成中のパターン、次の D 点の予測ゾーン (PRZ) も表示            |
//|  ・パターン完成 / PRZ 到達でアラート・プッシュ通知                 |
//+------------------------------------------------------------------+
#property copyright   "HarmonicPatternScanner"
#property version     "1.00"
#property description "Harmonic pattern scanner (Gartley, Bat, Butterfly, Crab, Cypher...)"
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   3

//--- プロット0: ZigZag
#property indicator_label1  "ZigZag"
#property indicator_type1   DRAW_SECTION
#property indicator_color1  clrSilver
#property indicator_style1  STYLE_DOT
#property indicator_width1  1

//--- プロット1: 買いパターンの D 点 (EA から iCustom で読める)
#property indicator_label2  "Bullish D"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrDodgerBlue
#property indicator_width2  2

//--- プロット2: 売りパターンの D 点
#property indicator_label3  "Bearish D"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrTomato
#property indicator_width3  2

//--- 入力パラメーター
input group "スイング検出 (ZigZag)"
input int    InpDepth          = 8;      // スイング判定の本数 (左右それぞれ)
input int    InpMinSwingPoints = 0;      // 最小スイング幅 (ポイント, 0=制限なし)
input int    InpLookback       = 1500;   // 検索する本数
input bool   InpShowZigZag     = true;   // ZigZag を表示

input group "パターン"
input bool   InpGartley        = true;   // Gartley
input bool   InpBat            = true;   // Bat
input bool   InpAltBat         = true;   // Alt Bat
input bool   InpButterfly      = true;   // Butterfly
input bool   InpCrab           = true;   // Crab
input bool   InpDeepCrab       = true;   // Deep Crab
input bool   InpCypher         = true;   // Cypher
input double InpTolerance      = 0.05;   // 比率の許容誤差 (0.05 = ±5%)
input int    InpMaxPatterns    = 10;     // 表示する完成パターン数 (新しい順)
input bool   InpShowDeveloping = true;   // 形成中のパターンを表示
input bool   InpShowProjection = true;   // 次の D 点の予測ゾーン (PRZ) を表示

input group "表示"
input color  InpBullColor      = clrDodgerBlue; // 買いパターンの色
input color  InpBearColor      = clrTomato;     // 売りパターンの色
input color  InpProjColor      = clrGold;       // 予測ゾーンの色
input bool   InpFill           = true;          // 三角形を塗りつぶす
input bool   InpShowRatios     = true;          // 比率ラインを表示
input bool   InpShowTargets    = true;          // 利確目安 (AD の 38.2% / 61.8%) を表示
input int    InpFontSize       = 8;             // 文字サイズ

input group "アラート"
input bool   InpAlertComplete  = false;  // パターン完成でアラート
input bool   InpAlertPRZ       = false;  // 予測ゾーン (PRZ) 到達でアラート
input bool   InpAlertPush      = false;  // プッシュ通知も送る

//--- 定数
#define PFX "HPS_"

//--- バッファ
double ZigZagBuf[];
double BullBuf[];
double BearBuf[];

//--- スイング
struct Pivot
  {
   int    bar;
   double price;
   bool   isHigh;
   bool   confirmed;
  };
Pivot g_piv[];
int   g_pivCount = 0;

//--- パターン定義 (比率は名目値。判定時に許容誤差を加える)
struct HPattern
  {
   string name;
   bool   enabled;
   double abMin, abMax;   // AB / XA
   double bcMin, bcMax;   // BC / AB
   double cdMin, cdMax;   // CD / BC
   double adMin, adMax;   // AD / XA  (Cypher は CD / XC)
   bool   cypher;
  };
HPattern g_pat[];

//--- 見つかったパターン
struct Match
  {
   int    pat;        // g_pat の番号
   int    x;          // X 点の g_piv 番号
   double acc;        // 精度 (%)
   bool   developing; // D 点が未確定
  };

//--- 予測ゾーン
struct Zone
  {
   string name;
   double lo, hi;
   bool   bull;
   string key;
  };
Zone g_zone[];
int  g_zoneCount = 0;

//--- 状態
datetime g_lastBarTime     = 0;
double   g_lastHi          = 0;
double   g_lastLo          = 0;
datetime g_lastCompleteAt  = 0;
string   g_lastPrzKey      = "";
bool     g_firstScan       = true;

//+------------------------------------------------------------------+
void AddPattern(string name, bool en, double ab1, double ab2, double bc1, double bc2,
                double cd1, double cd2, double ad1, double ad2, bool cy)
  {
   int n = ArraySize(g_pat);
   ArrayResize(g_pat, n + 1);
   g_pat[n].name    = name;
   g_pat[n].enabled = en;
   g_pat[n].abMin = ab1; g_pat[n].abMax = ab2;
   g_pat[n].bcMin = bc1; g_pat[n].bcMax = bc2;
   g_pat[n].cdMin = cd1; g_pat[n].cdMax = cd2;
   g_pat[n].adMin = ad1; g_pat[n].adMax = ad2;
   g_pat[n].cypher  = cy;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpDepth < 1 || InpLookback < 50 || InpTolerance <= 0.0 || InpTolerance >= 0.5)
     {
      Print("パラメーターが不正です (Depth>=1, Lookback>=50, 0<許容誤差<0.5)");
      return(INIT_PARAMETERS_INCORRECT);
     }

   SetIndexBuffer(0, ZigZagBuf, INDICATOR_DATA);
   SetIndexBuffer(1, BullBuf,   INDICATOR_DATA);
   SetIndexBuffer(2, BearBuf,   INDICATOR_DATA);
   for(int i = 0; i < 3; i++)
      PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetInteger(1, PLOT_ARROW, 233);   // 上向き矢印
   PlotIndexSetInteger(2, PLOT_ARROW, 234);   // 下向き矢印
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT, 12);
   PlotIndexSetInteger(2, PLOT_ARROW_SHIFT, -12);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, InpBullColor);
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, InpBearColor);
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, InpShowZigZag ? DRAW_SECTION : DRAW_NONE);

   //            名前         有効          AB/XA         BC/AB         CD/BC         AD/XA
   ArrayResize(g_pat, 0);
   AddPattern("Gartley",   InpGartley,   0.618, 0.618, 0.382, 0.886, 1.130, 1.618, 0.786, 0.786, false);
   AddPattern("Bat",       InpBat,       0.382, 0.500, 0.382, 0.886, 1.618, 2.618, 0.886, 0.886, false);
   AddPattern("Alt Bat",   InpAltBat,    0.300, 0.382, 0.382, 0.886, 2.000, 3.618, 1.130, 1.130, false);
   AddPattern("Butterfly", InpButterfly, 0.786, 0.786, 0.382, 0.886, 1.618, 2.618, 1.270, 1.618, false);
   AddPattern("Crab",      InpCrab,      0.382, 0.618, 0.382, 0.886, 2.240, 3.618, 1.618, 1.618, false);
   AddPattern("Deep Crab", InpDeepCrab,  0.886, 0.886, 0.382, 0.886, 2.000, 3.618, 1.618, 1.618, false);
   //  Cypher: C は A を超える (BC/AB 1.272-1.414)、D は XC の 78.6% 押し
   AddPattern("Cypher",    InpCypher,    0.382, 0.618, 1.272, 1.414, 0.000, 99.00, 0.786, 0.786, true);

   IndicatorSetString(INDICATOR_SHORTNAME, "HarmonicPatternScanner");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| スイング検出                                                      |
//+------------------------------------------------------------------+
void PushPivot(int bar, double price, bool isHigh, bool confirmed)
  {
   if(g_pivCount > 0)
     {
      Pivot last = g_piv[g_pivCount - 1];
      if(last.isHigh == isHigh)
        {
         // 同じ向きが続いたら、より極端な方を残す
         if((isHigh && price > last.price) || (!isHigh && price < last.price))
           {
            g_piv[g_pivCount - 1].bar       = bar;
            g_piv[g_pivCount - 1].price     = price;
            g_piv[g_pivCount - 1].confirmed = confirmed;
           }
         return;
        }
      if(InpMinSwingPoints > 0 && MathAbs(price - last.price) < InpMinSwingPoints * _Point)
         return;
     }
   ArrayResize(g_piv, g_pivCount + 1, 256);
   g_piv[g_pivCount].bar       = bar;
   g_piv[g_pivCount].price     = price;
   g_piv[g_pivCount].isHigh    = isHigh;
   g_piv[g_pivCount].confirmed = confirmed;
   g_pivCount++;
  }

//+------------------------------------------------------------------+
void BuildPivots(const int rates_total, const double &high[], const double &low[])
  {
   g_pivCount = 0;
   ArrayResize(g_piv, 0, 256);

   int start = MathMax(InpDepth, rates_total - InpLookback);
   int end   = rates_total - 1 - InpDepth;   // 右側 Depth 本がそろった最後の足

   for(int i = start; i <= end; i++)
     {
      bool isH = true, isL = true;
      for(int k = 1; k <= InpDepth && (isH || isL); k++)
        {
         if(high[i - k] >= high[i] || high[i + k] > high[i]) isH = false;
         if(low[i - k]  <= low[i]  || low[i + k]  < low[i])  isL = false;
        }
      if(isH && isL)
        {
         // 包み足: 直前のスイングと逆向きを先に入れる
         bool lastHigh = (g_pivCount > 0 && g_piv[g_pivCount - 1].isHigh);
         if(lastHigh) { PushPivot(i, low[i], false, true);  PushPivot(i, high[i], true, true); }
         else         { PushPivot(i, high[i], true, true);  PushPivot(i, low[i], false, true); }
        }
      else if(isH) PushPivot(i, high[i], true, true);
      else if(isL) PushPivot(i, low[i], false, true);
     }

   //--- 最後の確定スイング以降の極値を「未確定スイング」として追加
   if(g_pivCount == 0)
      return;
   Pivot last = g_piv[g_pivCount - 1];
   int    hiBar = -1, loBar = -1;
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = last.bar + 1; i < rates_total; i++)
     {
      if(high[i] > hi) { hi = high[i]; hiBar = i; }
      if(low[i]  < lo) { lo = low[i];  loBar = i; }
     }
   if(hiBar < 0)
      return;
   if(last.isHigh)
     {
      if(hi > last.price) PushPivot(hiBar, hi, true, false);    // 高値更新中
      else                PushPivot(loBar, lo, false, false);   // 押し目形成中
     }
   else
     {
      if(lo < last.price) PushPivot(loBar, lo, false, false);
      else                PushPivot(hiBar, hi, true, false);
     }
  }

//+------------------------------------------------------------------+
//| 比率判定                                                          |
//+------------------------------------------------------------------+
bool InRange(double v, double lo, double hi)
  {
   return(v >= lo * (1.0 - InpTolerance) && v <= hi * (1.0 + InpTolerance));
  }

double Dev(double v, double lo, double hi)
  {
   if(v < lo && lo > 0) return((lo - v) / lo);
   if(v > hi && hi > 0) return((v - hi) / hi);
   return(0.0);
  }

//--- X 点の番号 x から 5点を判定。最も精度の高いパターンを返す (-1 = なし)
int CheckXABCD(int x, double &bestAcc)
  {
   double X = g_piv[x].price,     A = g_piv[x + 1].price, B = g_piv[x + 2].price;
   double C = g_piv[x + 3].price, D = g_piv[x + 4].price;
   double s  = (A > X) ? 1.0 : -1.0;   // +1 = 買いパターン (D が安値)
   double XA = (A - X) * s, AB = (A - B) * s, BC = (C - B) * s, CD = (C - D) * s;
   if(XA <= 0 || AB <= 0 || BC <= 0 || CD <= 0)
      return(-1);

   double ab = AB / XA, bc = BC / AB, cd = CD / BC;
   double ad = (A - D) * s / XA;
   double xc = (C - X) * s;

   int best = -1;
   bestAcc = 0;
   for(int p = 0; p < ArraySize(g_pat); p++)
     {
      if(!g_pat[p].enabled) continue;
      double last;
      if(g_pat[p].cypher)
        {
         if(xc <= 0) continue;
         last = CD / xc;
        }
      else
         last = ad;
      if(!InRange(ab, g_pat[p].abMin, g_pat[p].abMax)) continue;
      if(!InRange(bc, g_pat[p].bcMin, g_pat[p].bcMax)) continue;
      if(!InRange(cd, g_pat[p].cdMin, g_pat[p].cdMax)) continue;
      if(!InRange(last, g_pat[p].adMin, g_pat[p].adMax)) continue;

      double dev = (Dev(ab, g_pat[p].abMin, g_pat[p].abMax) +
                    Dev(bc, g_pat[p].bcMin, g_pat[p].bcMax) +
                    Dev(cd, g_pat[p].cdMin, g_pat[p].cdMax) +
                    Dev(last, g_pat[p].adMin, g_pat[p].adMax) * 2.0) / 5.0;  // D 点を重視
      double acc = 100.0 * (1.0 - dev);
      if(acc > bestAcc) { bestAcc = acc; best = p; }
     }
   return(best);
  }

//+------------------------------------------------------------------+
//| 描画ヘルパー                                                      |
//+------------------------------------------------------------------+
datetime BarTime(const datetime &time[], int rates_total, int bar)
  {
   if(bar < rates_total) return(time[bar]);
   return(time[rates_total - 1] + (datetime)((bar - (rates_total - 1)) * PeriodSeconds()));
  }

void DrawLine(string name, datetime t1, double p1, datetime t2, double p2,
              color clr, int width, ENUM_LINE_STYLE style)
  {
   ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawText(string name, datetime t, double p, string text, color clr, ENUM_ANCHOR_POINT anchor)
  {
   ObjectCreate(0, name, OBJ_TEXT, 0, t, p);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawTriangle(string name, datetime t1, double p1, datetime t2, double p2,
                  datetime t3, double p3, color clr)
  {
   ObjectCreate(0, name, OBJ_TRIANGLE, 0, t1, p1, t2, p2, t3, p3);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawRect(string name, datetime t1, double p1, datetime t2, double p2, color clr, bool fill)
  {
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, fill);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//--- 背景色と混ぜて淡い塗り色を作る (MT5 オブジェクトは半透明にできないため)
color Blend(color c, double k)
  {
   color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   int r = (int)((c & 0xFF) * k + (bg & 0xFF) * (1 - k));
   int g = (int)(((c >> 8) & 0xFF) * k + ((bg >> 8) & 0xFF) * (1 - k));
   int b = (int)(((c >> 16) & 0xFF) * k + ((bg >> 16) & 0xFF) * (1 - k));
   return((color)(r | (g << 8) | (b << 16)));
  }

string R3(double v) { return(DoubleToString(v, 3)); }

//+------------------------------------------------------------------+
//| パターン描画                                                      |
//+------------------------------------------------------------------+
void DrawPattern(int id, const Match &m, const datetime &time[], const int rates_total)
  {
   HPattern pt = g_pat[m.pat];
   Pivot pX = g_piv[m.x], pA = g_piv[m.x + 1], pB = g_piv[m.x + 2];
   Pivot pC = g_piv[m.x + 3], pD = g_piv[m.x + 4];
   bool  bull = (pA.price > pX.price);
   double s   = bull ? 1.0 : -1.0;
   color clr  = bull ? InpBullColor : InpBearColor;
   ENUM_LINE_STYLE legStyle = m.developing ? STYLE_DASH : STYLE_SOLID;
   string n = PFX + "P" + IntegerToString(id) + "_";

   datetime tX = time[pX.bar], tA = time[pA.bar], tB = time[pB.bar];
   datetime tC = time[pC.bar], tD = time[pD.bar];

   if(InpFill)
     {
      color fc = Blend(clr, m.developing ? 0.12 : 0.22);
      DrawTriangle(n + "T1", tX, pX.price, tA, pA.price, tB, pB.price, fc);
      DrawTriangle(n + "T2", tB, pB.price, tC, pC.price, tD, pD.price, fc);
     }

   DrawLine(n + "XA", tX, pX.price, tA, pA.price, clr, 2, legStyle);
   DrawLine(n + "AB", tA, pA.price, tB, pB.price, clr, 2, legStyle);
   DrawLine(n + "BC", tB, pB.price, tC, pC.price, clr, 2, legStyle);
   DrawLine(n + "CD", tC, pC.price, tD, pD.price, clr, 2, legStyle);

   double XA = MathAbs(pA.price - pX.price), AB = MathAbs(pA.price - pB.price);
   double BC = MathAbs(pC.price - pB.price), CD = MathAbs(pC.price - pD.price);

   if(InpShowRatios)
     {
      color rc = Blend(clr, 0.7);
      DrawLine(n + "XB", tX, pX.price, tB, pB.price, rc, 1, STYLE_DOT);
      DrawLine(n + "AC", tA, pA.price, tC, pC.price, rc, 1, STYLE_DOT);
      DrawLine(n + "BD", tB, pB.price, tD, pD.price, rc, 1, STYLE_DOT);
      DrawText(n + "rXB", time[(pX.bar + pB.bar) / 2], (pX.price + pB.price) / 2, R3(AB / XA), rc, ANCHOR_CENTER);
      DrawText(n + "rAC", time[(pA.bar + pC.bar) / 2], (pA.price + pC.price) / 2, R3(BC / AB), rc, ANCHOR_CENTER);
      DrawText(n + "rBD", time[(pB.bar + pD.bar) / 2], (pB.price + pD.price) / 2, R3(CD / BC), rc, ANCHOR_CENTER);
      if(pt.cypher)
        {
         double XC = MathAbs(pC.price - pX.price);
         DrawLine(n + "XD", tX, pX.price, tD, pD.price, rc, 1, STYLE_DOT);
         DrawText(n + "rXD", time[(pX.bar + pD.bar) / 2], (pX.price + pD.price) / 2,
                  "XC " + R3(CD / XC), rc, ANCHOR_CENTER);
        }
      else
        {
         DrawLine(n + "XD", tX, pX.price, tD, pD.price, rc, 1, STYLE_DOT);
         DrawText(n + "rXD", time[(pX.bar + pD.bar) / 2], (pX.price + pD.price) / 2,
                  R3(MathAbs(pA.price - pD.price) / XA), rc, ANCHOR_CENTER);
        }
     }

   //--- 点ラベル
   string lbl[5] = {"X", "A", "B", "C", "D"};
   for(int k = 0; k < 5; k++)
     {
      Pivot p = g_piv[m.x + k];
      DrawText(n + "L" + lbl[k], time[p.bar], p.price, lbl[k], clr,
               p.isHigh ? ANCHOR_LOWER : ANCHOR_UPPER);
     }

   //--- パターン名
   string title = (bull ? "Bullish " : "Bearish ") + pt.name + " " + DoubleToString(m.acc, 0) + "%";
   if(m.developing) title += " (形成中)";
   double off = (bull ? -1 : 1) * XA * 0.05;
   DrawText(n + "NAME", tD, pD.price + off, title, clr, bull ? ANCHOR_UPPER : ANCHOR_LOWER);

   //--- D 点の PRZ (AD 比率の範囲 ± 許容誤差)
   double lvl1, lvl2;
   if(pt.cypher)
     {
      double XC = MathAbs(pC.price - pX.price);
      lvl1 = pC.price - s * XC * pt.adMin * (1.0 - InpTolerance);
      lvl2 = pC.price - s * XC * pt.adMax * (1.0 + InpTolerance);
     }
   else
     {
      lvl1 = pA.price - s * XA * pt.adMin * (1.0 - InpTolerance);
      lvl2 = pA.price - s * XA * pt.adMax * (1.0 + InpTolerance);
     }
   int span = MathMax(5, (pD.bar - pC.bar) / 2);
   DrawRect(n + "PRZ", BarTime(time, rates_total, pD.bar - span), lvl1,
            BarTime(time, rates_total, pD.bar + span), lvl2, Blend(clr, 0.35), false);

   //--- 利確目安 (AD の 38.2% / 61.8% 戻し)
   if(InpShowTargets)
     {
      double AD = pA.price - pD.price;
      double tps[2] = {0.382, 0.618};
      for(int k = 0; k < 2; k++)
        {
         double tp = pD.price + AD * tps[k];
         datetime t2 = BarTime(time, rates_total, pD.bar + MathMax(10, pD.bar - pC.bar));
         DrawLine(n + "TP" + IntegerToString(k), tD, tp, t2, tp, clr, 1, STYLE_DASHDOT);
         DrawText(n + "TPL" + IntegerToString(k), t2, tp, " TP" + IntegerToString(k + 1) +
                  " " + DoubleToString(tp, _Digits), clr, ANCHOR_LEFT);
        }
     }
  }

//+------------------------------------------------------------------+
//| 次の D 点の予測ゾーン                                              |
//+------------------------------------------------------------------+
void DrawProjection(const datetime &time[], const int rates_total)
  {
   g_zoneCount = 0;
   ArrayResize(g_zone, 0);

   // 最新スイングが未確定なら、それを D 候補とみなし直前の 4点を X-A-B-C にする
   bool lastTentative = (g_pivCount > 0 && !g_piv[g_pivCount - 1].confirmed);
   int  x = g_pivCount - (lastTentative ? 5 : 4);
   if(x < 0) return;

   Pivot pX = g_piv[x], pA = g_piv[x + 1], pB = g_piv[x + 2], pC = g_piv[x + 3];
   double s  = (pA.price > pX.price) ? 1.0 : -1.0;
   bool bull = (s > 0);
   double XA = (pA.price - pX.price) * s, AB = (pA.price - pB.price) * s, BC = (pC.price - pB.price) * s;
   double XC = (pC.price - pX.price) * s;
   if(XA <= 0 || AB <= 0 || BC <= 0) return;
   double ab = AB / XA, bc = BC / AB;
   double dNow = lastTentative ? g_piv[g_pivCount - 1].price : pC.price;

   int rightBar = rates_total - 1 + MathMax(10, pC.bar - pB.bar);
   datetime tL = time[pC.bar], tR = BarTime(time, rates_total, rightBar);
   int drawn = 0;

   for(int p = 0; p < ArraySize(g_pat); p++)
     {
      HPattern pt = g_pat[p];
      if(!pt.enabled) continue;
      if(!InRange(ab, pt.abMin, pt.abMax) || !InRange(bc, pt.bcMin, pt.bcMax)) continue;

      // D の価格範囲 = (AD 比率の範囲) ∩ (CD/BC の範囲)
      double d1, d2;
      if(pt.cypher)
        {
         if(XC <= 0) continue;
         d1 = pC.price - s * XC * pt.adMin * (1.0 - InpTolerance);
         d2 = pC.price - s * XC * pt.adMax * (1.0 + InpTolerance);
        }
      else
        {
         d1 = pA.price - s * XA * pt.adMin * (1.0 - InpTolerance);
         d2 = pA.price - s * XA * pt.adMax * (1.0 + InpTolerance);
         double c1 = pC.price - s * BC * pt.cdMin * (1.0 - InpTolerance);
         double c2 = pC.price - s * BC * pt.cdMax * (1.0 + InpTolerance);
         double lo = MathMax(MathMin(d1, d2), MathMin(c1, c2));
         double hi = MathMin(MathMax(d1, d2), MathMax(c1, c2));
         if(lo > hi) continue;
         d1 = lo; d2 = hi;
        }
      double zLo = MathMin(d1, d2), zHi = MathMax(d1, d2);

      // 価格がゾーンを突き抜けて反対側へ行っていたら無効
      if(bull && dNow < zLo) continue;
      if(!bull && dNow > zHi) continue;

      int zi = g_zoneCount++;
      ArrayResize(g_zone, g_zoneCount);
      g_zone[zi].name = pt.name;
      g_zone[zi].lo   = zLo;
      g_zone[zi].hi   = zHi;
      g_zone[zi].bull = bull;
      g_zone[zi].key  = pt.name + "_" + IntegerToString((long)tL);

      string n = PFX + "Z" + IntegerToString(zi) + "_";
      DrawRect(n + "R", tL, zLo, tR, zHi, Blend(InpProjColor, 0.25), true);
      DrawRect(n + "B", tL, zLo, tR, zHi, InpProjColor, false);
      DrawText(n + "T", tR, bull ? zLo : zHi,
               (bull ? "Bullish " : "Bearish ") + pt.name + " PRZ " +
               DoubleToString(zLo, _Digits) + " - " + DoubleToString(zHi, _Digits) + " ",
               InpProjColor, bull ? ANCHOR_RIGHT_UPPER : ANCHOR_RIGHT_LOWER);
      drawn++;
     }

   if(drawn > 0)
     {
      // X-A-B-C の脚を細線で表示
      string n = PFX + "ZL_";
      color c = InpProjColor;
      DrawLine(n + "XA", time[pX.bar], pX.price, time[pA.bar], pA.price, c, 1, STYLE_DOT);
      DrawLine(n + "AB", time[pA.bar], pA.price, time[pB.bar], pB.price, c, 1, STYLE_DOT);
      DrawLine(n + "BC", time[pB.bar], pB.price, time[pC.bar], pC.price, c, 1, STYLE_DOT);
      string lbl[4] = {"X", "A", "B", "C"};
      for(int k = 0; k < 4; k++)
        {
         Pivot p = g_piv[x + k];
         DrawText(n + "L" + lbl[k], time[p.bar], p.price, lbl[k], c,
                  p.isHigh ? ANCHOR_LOWER : ANCHOR_UPPER);
        }
     }
  }

//+------------------------------------------------------------------+
void Notify(string msg)
  {
   string text = _Symbol + " " + EnumToString((ENUM_TIMEFRAMES)_Period) + ": " + msg;
   Alert(text);
   if(InpAlertPush) SendNotification(text);
  }

//+------------------------------------------------------------------+
//| 全体スキャン                                                      |
//+------------------------------------------------------------------+
void Scan(const int rates_total, const datetime &time[], const double &high[], const double &low[])
  {
   ObjectsDeleteAll(0, PFX);
   ArrayInitialize(ZigZagBuf, 0.0);
   ArrayInitialize(BullBuf, 0.0);
   ArrayInitialize(BearBuf, 0.0);

   BuildPivots(rates_total, high, low);

   for(int i = 0; i < g_pivCount; i++)
      ZigZagBuf[g_piv[i].bar] = g_piv[i].price;

   //--- パターン検出
   Match found[];
   int nf = 0;
   for(int x = 0; x + 4 < g_pivCount; x++)
     {
      double acc;
      int p = CheckXABCD(x, acc);
      if(p < 0) continue;
      ArrayResize(found, nf + 1, 64);
      found[nf].pat        = p;
      found[nf].x          = x;
      found[nf].acc        = acc;
      found[nf].developing = !g_piv[x + 4].confirmed;
      nf++;
     }

   //--- 新しい順に描画
   int shown = 0;
   datetime newestComplete = 0;
   string   newestMsg = "";
   for(int k = nf - 1; k >= 0; k--)
     {
      Match m = found[k];
      Pivot pD = g_piv[m.x + 4];
      bool bull = (g_piv[m.x + 1].price > g_piv[m.x].price);
      if(m.developing)
        {
         if(InpShowDeveloping) DrawPattern(k, m, time, rates_total);
         continue;
        }
      if(shown >= InpMaxPatterns) continue;
      DrawPattern(k, m, time, rates_total);
      if(bull) BullBuf[pD.bar] = pD.price;
      else     BearBuf[pD.bar] = pD.price;
      if(time[pD.bar] > newestComplete)
        {
         newestComplete = time[pD.bar];
         newestMsg = (bull ? "Bullish " : "Bearish ") + g_pat[m.pat].name + " 完成 D=" +
                     DoubleToString(pD.price, _Digits);
        }
      shown++;
     }

   if(InpShowProjection)
      DrawProjection(time, rates_total);
   else
      g_zoneCount = 0;

   //--- 完成アラート (起動直後の既存パターンでは鳴らさない)
   if(newestComplete > g_lastCompleteAt)
     {
      if(!g_firstScan && InpAlertComplete) Notify(newestMsg);
      g_lastCompleteAt = newestComplete;
     }
   g_firstScan = false;
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < InpDepth * 2 + 10)
      return(0);

   ArraySetAsSeries(time, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);

   int last = rates_total - 1;
   // 新しい足、または現在足の高値/安値更新時だけ再計算 (負荷軽減)
   bool need = (prev_calculated == 0 || time[last] != g_lastBarTime ||
                high[last] > g_lastHi || low[last] < g_lastLo);
   if(need)
     {
      g_lastBarTime = time[last];
      g_lastHi      = high[last];
      g_lastLo      = low[last];
      Scan(rates_total, time, high, low);
     }

   //--- PRZ 到達アラート
   if(InpAlertPRZ && g_zoneCount > 0)
     {
      double price = close[last];
      for(int i = 0; i < g_zoneCount; i++)
        {
         if(price >= g_zone[i].lo && price <= g_zone[i].hi && g_zone[i].key != g_lastPrzKey)
           {
            g_lastPrzKey = g_zone[i].key;
            Notify((g_zone[i].bull ? "Bullish " : "Bearish ") + g_zone[i].name +
                   " PRZ 到達 " + DoubleToString(price, _Digits));
            break;
           }
        }
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
