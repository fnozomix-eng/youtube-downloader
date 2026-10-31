//+------------------------------------------------------------------+
//|  MTF_SuperBollinger.mq5                                          |
//|  MTF スーパーボリンジャー（マーフィー式）+ アラート              |
//|   - 期間21 / ±1σ・±2σ・±3σ / 遅行スパン（終値を21本前に表示）    |
//|   - 移動平均 SMA / EMA 切り替え                                  |
//|   - 2系統のバンド（時間足を個別指定 = MTF）                      |
//|   - アラート: バンドタッチ / 実体ブレーク / 遅行スパンタッチ     |
//+------------------------------------------------------------------+
#property copyright   "MTF Super Bollinger (Murphy)"
#property version     "1.00"
#property description "MTF スーパーボリンジャー（マーフィー式）+ タッチ / 実体ブレーク / 遅行スパンタッチ アラート"
#property indicator_chart_window
#property indicator_buffers 19
#property indicator_plots   15

//--- 列挙
enum ENUM_MA_SEL
  {
   MA_SEL_SMA = 0, // SMA
   MA_SEL_EMA = 1  // EMA
  };
enum ENUM_BREAK_MODE
  {
   BREAK_CLOSE = 0, // 終値で抜け
   BREAK_BODY  = 1  // 実体が完全に外側
  };

//--- 入力
input group "■ スーパーボリンジャー設定（マーフィー式）"
input ENUM_MA_SEL     InpMAType    = MA_SEL_SMA;     // 移動平均タイプ
input int             InpPeriod    = 21;             // 期間
input double          InpMult1     = 1.0;            // σ1 倍率
input double          InpMult2     = 2.0;            // σ2 倍率
input double          InpMult3     = 3.0;            // σ3 倍率
input int             InpLag       = 21;             // 遅行スパン期間（当日を1本目として数える）
input bool            InpShowLag   = true;           // 遅行スパンを表示（チャート時間足）
input bool            InpNoRepaint = true;           // 上位足はリペイント防止（確定値を使用）
input int             InpMaxBars   = 5000;           // 計算する最大バー数（0 = 全て）

input group "■ バンド1"
input bool            InpShow1     = true;           // バンド1 表示
input ENUM_TIMEFRAMES InpTF1       = PERIOD_CURRENT; // バンド1 時間足

input group "■ バンド2（上位足）"
input bool            InpShow2     = true;           // バンド2 表示
input ENUM_TIMEFRAMES InpTF2       = PERIOD_H4;      // バンド2 時間足

input group "■ 色"
input color           InpColMid1   = clrOrange;      // バンド1 移動平均
input color           InpCol1_1    = clrLimeGreen;   // バンド1 ±1σ
input color           InpCol2_1    = clrDodgerBlue;  // バンド1 ±2σ
input color           InpCol3_1    = clrRed;         // バンド1 ±3σ
input color           InpColMid2   = clrSandyBrown;  // バンド2 移動平均
input color           InpCol1_2    = clrDarkSeaGreen;// バンド2 ±1σ
input color           InpCol2_2    = clrLightSkyBlue;// バンド2 ±2σ
input color           InpCol3_2    = clrLightCoral;  // バンド2 ±3σ
input int             InpWidth2    = 2;              // バンド2 線の太さ
input color           InpColLag    = clrMagenta;     // 遅行スパン

input group "■ アラート"
input bool            InpAlBB1     = true;           // バンド1 を対象
input bool            InpAlBB2     = true;           // バンド2 を対象
input bool            InpAlTouch   = true;           // バンドタッチ（ヒゲ含む）
input bool            InpAlBreak   = true;           // 実体ブレーク
input ENUM_BREAK_MODE InpBreakMode = BREAK_CLOSE;    // 実体ブレーク判定
input bool            InpAlLag     = true;           // 遅行スパンタッチ
input bool            InpLv3       = true;           // 対象: ±3σ
input bool            InpLv2       = true;           // 対象: ±2σ
input bool            InpLv1       = false;          // 対象: ±1σ
input bool            InpLvMid     = false;          // 対象: 移動平均
input bool            InpConfOnly  = true;           // 確定足のみで発報（チャート足）
input bool            InpPopup     = true;           // ポップアップ
input bool            InpPush      = false;          // プッシュ通知（スマホ）
input bool            InpMail      = false;          // メール

//--- 描画バッファ（バンド1: +3,+2,+1,MA,-1,-2,-3）
double B1_0[], B1_1[], B1_2[], B1_3[], B1_4[], B1_5[], B1_6[];
//--- 描画バッファ（バンド2）
double B2_0[], B2_1[], B2_2[], B2_3[], B2_4[], B2_5[], B2_6[];
//--- 遅行スパン
double LagBuf[];
//--- 計算用（移動平均・σ）
double Mid1[], SD1[], Mid2[], SD2[];

//--- 状態
ENUM_TIMEFRAMES g_tf[2];
bool            g_higher[2];
bool            g_show[2];
bool            g_alert[2];
int             g_hMA[2];
int             g_hSD[2];
datetime        g_lastHtf[2];
datetime        g_lastBarTime = 0;
string          g_sentThisBar = "";
bool            g_needRefresh = false;

//+------------------------------------------------------------------+
//| ヘルパー                                                         |
//+------------------------------------------------------------------+
double LvMult(const int lv)
  {
   switch(lv)
     {
      case 0: return  InpMult3;
      case 1: return  InpMult2;
      case 2: return  InpMult1;
      case 3: return  0.0;
      case 4: return -InpMult1;
      case 5: return -InpMult2;
     }
   return -InpMult3;
  }

string LvName(const int lv)
  {
   switch(lv)
     {
      case 0: return "+3σ";
      case 1: return "+2σ";
      case 2: return "+1σ";
      case 3: return "MA";
      case 4: return "-1σ";
      case 5: return "-2σ";
     }
   return "-3σ";
  }

bool LvOn(const int lv)
  {
   if(lv == 3)            return InpLvMid;
   if(lv == 2 || lv == 4) return InpLv1;
   if(lv == 1 || lv == 5) return InpLv2;
   return InpLv3;
  }

string TFName(const ENUM_TIMEFRAMES tf)
  {
   return StringSubstr(EnumToString(tf), 7); // "PERIOD_H4" -> "H4"
  }

double GetMid(const int s, const int i) { return (s == 0) ? Mid1[i] : Mid2[i]; }
double GetSD(const int s, const int i)  { return (s == 0) ? SD1[i]  : SD2[i];  }

void SetCalc(const int s, const int i, const double m, const double d)
  {
   if(s == 0) { Mid1[i] = m; SD1[i] = d; }
   else       { Mid2[i] = m; SD2[i] = d; }
  }

void SetPlots(const int s, const int i, const double m, const double d)
  {
   double v[7];
   for(int lv = 0; lv < 7; lv++)
      v[lv] = (g_show[s] && m != EMPTY_VALUE && d != EMPTY_VALUE) ? m + d * LvMult(lv) : EMPTY_VALUE;
   if(s == 0)
     {
      B1_0[i] = v[0]; B1_1[i] = v[1]; B1_2[i] = v[2]; B1_3[i] = v[3];
      B1_4[i] = v[4]; B1_5[i] = v[5]; B1_6[i] = v[6];
     }
   else
     {
      B2_0[i] = v[0]; B2_1[i] = v[1]; B2_2[i] = v[2]; B2_3[i] = v[3];
      B2_4[i] = v[4]; B2_5[i] = v[5]; B2_6[i] = v[6];
     }
  }

void SetupPlot(const int idx, const string label, const color clr, const int width)
  {
   PlotIndexSetInteger(idx, PLOT_DRAW_TYPE, DRAW_LINE);
   PlotIndexSetInteger(idx, PLOT_LINE_STYLE, STYLE_SOLID);
   PlotIndexSetInteger(idx, PLOT_LINE_COLOR, clr);
   PlotIndexSetInteger(idx, PLOT_LINE_WIDTH, width);
   PlotIndexSetDouble(idx, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetString(idx, PLOT_LABEL, label);
  }

//--- 重複送信を防ぎつつ1行追加
void AddLine(string &out, const string line)
  {
   if(StringFind(g_sentThisBar, line + "|") >= 0)
      return;
   g_sentThisBar += line + "|";
   out += line + "\n";
  }

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   for(int s = 0; s < 2; s++)
     {
      g_hMA[s] = INVALID_HANDLE;
      g_hSD[s] = INVALID_HANDLE;
     }
   if(InpPeriod < 2 || InpLag < 2)
      return INIT_PARAMETERS_INCORRECT;

   SetIndexBuffer(0,  B1_0, INDICATOR_DATA);
   SetIndexBuffer(1,  B1_1, INDICATOR_DATA);
   SetIndexBuffer(2,  B1_2, INDICATOR_DATA);
   SetIndexBuffer(3,  B1_3, INDICATOR_DATA);
   SetIndexBuffer(4,  B1_4, INDICATOR_DATA);
   SetIndexBuffer(5,  B1_5, INDICATOR_DATA);
   SetIndexBuffer(6,  B1_6, INDICATOR_DATA);
   SetIndexBuffer(7,  B2_0, INDICATOR_DATA);
   SetIndexBuffer(8,  B2_1, INDICATOR_DATA);
   SetIndexBuffer(9,  B2_2, INDICATOR_DATA);
   SetIndexBuffer(10, B2_3, INDICATOR_DATA);
   SetIndexBuffer(11, B2_4, INDICATOR_DATA);
   SetIndexBuffer(12, B2_5, INDICATOR_DATA);
   SetIndexBuffer(13, B2_6, INDICATOR_DATA);
   SetIndexBuffer(14, LagBuf, INDICATOR_DATA);
   SetIndexBuffer(15, Mid1, INDICATOR_CALCULATIONS);
   SetIndexBuffer(16, SD1,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(17, Mid2, INDICATOR_CALCULATIONS);
   SetIndexBuffer(18, SD2,  INDICATOR_CALCULATIONS);

   ArraySetAsSeries(B1_0, true); ArraySetAsSeries(B1_1, true); ArraySetAsSeries(B1_2, true);
   ArraySetAsSeries(B1_3, true); ArraySetAsSeries(B1_4, true); ArraySetAsSeries(B1_5, true);
   ArraySetAsSeries(B1_6, true);
   ArraySetAsSeries(B2_0, true); ArraySetAsSeries(B2_1, true); ArraySetAsSeries(B2_2, true);
   ArraySetAsSeries(B2_3, true); ArraySetAsSeries(B2_4, true); ArraySetAsSeries(B2_5, true);
   ArraySetAsSeries(B2_6, true);
   ArraySetAsSeries(LagBuf, true);
   ArraySetAsSeries(Mid1, true); ArraySetAsSeries(SD1, true);
   ArraySetAsSeries(Mid2, true); ArraySetAsSeries(SD2, true);

   g_tf[0] = (InpTF1 == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTF1;
   g_tf[1] = (InpTF2 == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTF2;
   g_show[0]  = InpShow1;
   g_show[1]  = InpShow2;
   g_alert[0] = InpAlBB1;
   g_alert[1] = InpAlBB2;

   string n1 = "B1[" + TFName(g_tf[0]) + "] ";
   string n2 = "B2[" + TFName(g_tf[1]) + "] ";
   color c1[7], c2[7];
   c1[0] = InpCol3_1; c1[1] = InpCol2_1; c1[2] = InpCol1_1; c1[3] = InpColMid1; c1[4] = InpCol1_1; c1[5] = InpCol2_1; c1[6] = InpCol3_1;
   c2[0] = InpCol3_2; c2[1] = InpCol2_2; c2[2] = InpCol1_2; c2[3] = InpColMid2; c2[4] = InpCol1_2; c2[5] = InpCol2_2; c2[6] = InpCol3_2;
   for(int lv = 0; lv < 7; lv++)
     {
      SetupPlot(lv,     n1 + LvName(lv), c1[lv], (lv == 3) ? 2 : 1);
      SetupPlot(7 + lv, n2 + LvName(lv), c2[lv], (lv == 3) ? InpWidth2 + 1 : InpWidth2);
     }
   SetupPlot(14, "遅行スパン", InpColLag, 2);
   PlotIndexSetInteger(14, PLOT_SHIFT, -(InpLag - 1));

   ENUM_MA_METHOD method = (InpMAType == MA_SEL_SMA) ? MODE_SMA : MODE_EMA;
   for(int s = 0; s < 2; s++)
     {
      g_higher[s]  = PeriodSeconds(g_tf[s]) > PeriodSeconds((ENUM_TIMEFRAMES)_Period);
      g_lastHtf[s] = 0;
      g_hMA[s] = iMA(_Symbol, g_tf[s], InpPeriod, 0, method, PRICE_CLOSE);
      // σ は SMA 基準の標準偏差（TradingView 版 ta.stdev と同じ）
      g_hSD[s] = iStdDev(_Symbol, g_tf[s], InpPeriod, 0, MODE_SMA, PRICE_CLOSE);
      if(g_hMA[s] == INVALID_HANDLE || g_hSD[s] == INVALID_HANDLE)
        {
         Print("インジケーターハンドルの作成に失敗しました: ", GetLastError());
         return INIT_FAILED;
        }
     }

   string ma = (InpMAType == MA_SEL_SMA) ? "SMA" : "EMA";
   IndicatorSetString(INDICATOR_SHORTNAME, "MTF SuperBB(" + ma + "," + (string)InpPeriod + ") " + TFName(g_tf[0]) + "/" + TFName(g_tf[1]));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_lastBarTime = 0;
   g_sentThisBar = "";
   EventSetTimer(2);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int s = 0; s < 2; s++)
     {
      if(g_hMA[s] != INVALID_HANDLE) IndicatorRelease(g_hMA[s]);
      if(g_hSD[s] != INVALID_HANDLE) IndicatorRelease(g_hSD[s]);
     }
  }

//--- 上位足データ未準備の場合に再計算を促す
void OnTimer()
  {
   if(g_needRefresh)
     {
      g_needRefresh = false;
      ChartSetSymbolPeriod(0, _Symbol, _Period);
     }
  }

//+------------------------------------------------------------------+
//| 1系統のバンドを計算                                              |
//+------------------------------------------------------------------+
bool CalcSet(const int s, const int limit, const int rates_total, const datetime &time[])
  {
   ENUM_TIMEFRAMES tf = g_tf[s];
   int off = (InpNoRepaint && g_higher[s]) ? 1 : 0;
   int lim = limit;

   // リアルタイム更新時は、形成中の上位足に属するチャート足をすべて再計算
   if(g_higher[s] && off == 0)
     {
      int sh0 = iBarShift(_Symbol, _Period, iTime(_Symbol, tf, 0), false);
      if(sh0 > lim) lim = sh0;
     }
   if(lim > rates_total - 2) lim = rates_total - 2;

   int maxSh = iBarShift(_Symbol, tf, time[lim], false);
   if(maxSh < 0)
      maxSh = Bars(_Symbol, tf) - 1;
   if(maxSh < 0)
      return false;

   int htfBars = Bars(_Symbol, tf);
   int need    = MathMin(maxSh + off + 1, htfBars);
   if(need <= 0)
      return false;
   if(BarsCalculated(g_hMA[s]) < need || BarsCalculated(g_hSD[s]) < need)
      return false;

   double ma[], sd[];
   ArraySetAsSeries(ma, true);
   ArraySetAsSeries(sd, true);
   if(CopyBuffer(g_hMA[s], 0, 0, need, ma) < need) return false;
   if(CopyBuffer(g_hSD[s], 0, 0, need, sd) < need) return false;

   for(int i = lim; i >= 0; i--)
     {
      double m = EMPTY_VALUE, d = EMPTY_VALUE;
      int sh = iBarShift(_Symbol, tf, time[i], false);
      if(sh >= 0)
        {
         sh += off;
         if(sh < need && sh <= htfBars - InpPeriod - 1 && ma[sh] != EMPTY_VALUE && sd[sh] != EMPTY_VALUE)
           {
            m = ma[sh];
            d = sd[sh];
           }
        }
      SetCalc(s, i, m, d);
      SetPlots(s, i, m, d);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| タッチ / 実体ブレーク判定（チャート足 j）                        |
//+------------------------------------------------------------------+
void CheckTouchBreak(const int s, const int j, string &out,
                     const double &open[], const double &high[], const double &low[], const double &close[])
  {
   string lbl = "[" + TFName(g_tf[s]) + "]";
   double m  = GetMid(s, j),     d  = GetSD(s, j);
   double mp = GetMid(s, j + 1), dp = GetSD(s, j + 1);
   if(m == EMPTY_VALUE || d == EMPTY_VALUE)
      return;
   bool   hasPrev = (mp != EMPTY_VALUE && dp != EMPTY_VALUE);
   double bodyHi  = MathMax(open[j], close[j]),         bodyLo  = MathMin(open[j], close[j]);
   double bodyHiP = MathMax(open[j + 1], close[j + 1]), bodyLoP = MathMin(open[j + 1], close[j + 1]);

   for(int lv = 0; lv < 7; lv++)
     {
      if(!LvOn(lv))
         continue;
      double L = m + d * LvMult(lv);
      if(InpAlTouch && high[j] >= L && low[j] <= L)
         AddLine(out, lbl + " " + LvName(lv) + " タッチ");
      if(InpAlBreak && hasPrev)
        {
         double LP = mp + dp * LvMult(lv);
         bool up, dn;
         if(InpBreakMode == BREAK_CLOSE)
           {
            up = close[j] > L && close[j + 1] <= LP;
            dn = close[j] < L && close[j + 1] >= LP;
           }
         else
           {
            up = bodyLo > L && bodyLoP <= LP;
            dn = bodyHi < L && bodyHiP >= LP;
           }
         if(up) AddLine(out, lbl + " " + LvName(lv) + " 実体ブレーク（上抜け）");
         if(dn) AddLine(out, lbl + " " + LvName(lv) + " 実体ブレーク（下抜け）");
        }
     }
  }

//--- 遅行スパンのクロス判定（共通）
void LagCross(const int s, const double c, const double cp,
              const double m, const double d, const double mp, const double dp, string &out)
  {
   string lbl = "[" + TFName(g_tf[s]) + "]";
   for(int lv = 0; lv < 7; lv++)
     {
      if(!LvOn(lv))
         continue;
      double L  = m  + d  * LvMult(lv);
      double LP = mp + dp * LvMult(lv);
      bool up = cp < LP && c >= L;
      bool dn = cp > LP && c <= L;
      if(up) AddLine(out, lbl + " 遅行スパン " + LvName(lv) + " タッチ（上抜け）");
      if(dn) AddLine(out, lbl + " 遅行スパン " + LvName(lv) + " タッチ（下抜け）");
     }
  }

//--- 遅行スパン判定: チャート時間足（確定足 1 を使用）
void CheckLagChart(const int s, const int rates_total, const double &close[], string &out)
  {
   int k = InpLag - 1;
   if(2 + k >= rates_total)
      return;
   double m = GetMid(s, 1 + k), d = GetSD(s, 1 + k);
   double mp = GetMid(s, 2 + k), dp = GetSD(s, 2 + k);
   if(m == EMPTY_VALUE || d == EMPTY_VALUE || mp == EMPTY_VALUE || dp == EMPTY_VALUE)
      return;
   LagCross(s, close[1], close[2], m, d, mp, dp, out);
  }

//--- 遅行スパン判定: 上位足（確定した上位足 1 を使用）
void CheckLagHtf(const int s, string &out)
  {
   int k   = InpLag - 1;
   int cnt = k + 3;
   double ma[], sd[], cl[];
   ArraySetAsSeries(ma, true);
   ArraySetAsSeries(sd, true);
   ArraySetAsSeries(cl, true);
   if(CopyBuffer(g_hMA[s], 0, 0, cnt, ma) < cnt) return;
   if(CopyBuffer(g_hSD[s], 0, 0, cnt, sd) < cnt) return;
   if(CopyClose(_Symbol, g_tf[s], 0, cnt, cl) < cnt) return;
   if(ma[1 + k] == EMPTY_VALUE || ma[2 + k] == EMPTY_VALUE)
      return;
   LagCross(s, cl[1], cl[2], ma[1 + k], sd[1 + k], ma[2 + k], sd[2 + k], out);
  }

//--- 通知
void Notify(const string body, const double price)
  {
   string head = _Symbol + " (" + TFName((ENUM_TIMEFRAMES)_Period) + ") 価格 " + DoubleToString(price, _Digits);
   string lines[];
   int n = StringSplit(body, '\n', lines);
   string joined = "";
   for(int i = 0; i < n; i++)
     {
      if(lines[i] == "")
         continue;
      if(InpPopup)
         Alert(head + " " + lines[i]);
      joined += (joined == "" ? "" : " / ") + lines[i];
     }
   if(InpPush)
      SendNotification(StringSubstr(head + " " + joined, 0, 255));
   if(InpMail)
      SendMail("MTF SuperBB " + _Symbol, head + "\n" + body);
  }

//+------------------------------------------------------------------+
//| メイン                                                           |
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
   ArraySetAsSeries(time, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   if(rates_total < InpPeriod + InpLag + 3)
      return 0;

   int limit;
   if(prev_calculated <= 0)
     {
      limit = rates_total - 2;
      if(InpMaxBars > 0 && limit > InpMaxBars - 1)
         limit = InpMaxBars - 1;
      ArrayInitialize(B1_0, EMPTY_VALUE); ArrayInitialize(B1_1, EMPTY_VALUE); ArrayInitialize(B1_2, EMPTY_VALUE);
      ArrayInitialize(B1_3, EMPTY_VALUE); ArrayInitialize(B1_4, EMPTY_VALUE); ArrayInitialize(B1_5, EMPTY_VALUE);
      ArrayInitialize(B1_6, EMPTY_VALUE);
      ArrayInitialize(B2_0, EMPTY_VALUE); ArrayInitialize(B2_1, EMPTY_VALUE); ArrayInitialize(B2_2, EMPTY_VALUE);
      ArrayInitialize(B2_3, EMPTY_VALUE); ArrayInitialize(B2_4, EMPTY_VALUE); ArrayInitialize(B2_5, EMPTY_VALUE);
      ArrayInitialize(B2_6, EMPTY_VALUE);
      ArrayInitialize(LagBuf, EMPTY_VALUE);
      ArrayInitialize(Mid1, EMPTY_VALUE); ArrayInitialize(SD1, EMPTY_VALUE);
      ArrayInitialize(Mid2, EMPTY_VALUE); ArrayInitialize(SD2, EMPTY_VALUE);
     }
   else
     {
      limit = rates_total - prev_calculated;
      if(limit < 1) limit = 1;
     }

   for(int s = 0; s < 2; s++)
     {
      if(!CalcSet(s, limit, rates_total, time))
        {
         g_needRefresh = true; // 上位足のデータ準備待ち
         return 0;
        }
     }

   for(int i = limit; i >= 0; i--)
      LagBuf[i] = InpShowLag ? close[i] : EMPTY_VALUE;

   //--- アラート
   bool newBar = (time[0] != g_lastBarTime);
   if(prev_calculated <= 0 || g_lastBarTime == 0)
     {
      // 初回は過去分を通知しない
      g_lastBarTime = time[0];
      for(int s = 0; s < 2; s++)
         g_lastHtf[s] = iTime(_Symbol, g_tf[s], 0);
      return rates_total;
     }
   if(newBar)
     {
      g_lastBarTime = time[0];
      g_sentThisBar = "";
     }

   string msg = "";
   bool evalChart = InpConfOnly ? newBar : true;
   int  j         = InpConfOnly ? 1 : 0;

   for(int s = 0; s < 2; s++)
     {
      if(!g_alert[s])
         continue;

      if((InpAlTouch || InpAlBreak) && evalChart)
         CheckTouchBreak(s, j, msg, open, high, low, close);

      if(InpAlLag)
        {
         if(g_higher[s])
           {
            datetime ht = iTime(_Symbol, g_tf[s], 0);
            if(ht != 0 && ht != g_lastHtf[s])
              {
               if(g_lastHtf[s] != 0)
                  CheckLagHtf(s, msg);
               g_lastHtf[s] = ht;
              }
           }
         else if(newBar)
            CheckLagChart(s, rates_total, close, msg);
        }
     }

   if(msg != "")
      Notify(msg, close[0]);

   return rates_total;
  }
//+------------------------------------------------------------------+
