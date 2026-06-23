//+------------------------------------------------------------------+
//|                                                      SRLines.mq5 |
//|                                                   Antigravity AI  |
//|               https://github.com/FXDavid-OffbeatForex/SRLines   |
//+------------------------------------------------------------------+
//
//  VERSION: 4.1
//
//  v4.1: adds MBT signal logging for two strategies (break-retest of a flipped
//  zone, or plain zone bounce) so the indicator can be backtested headlessly;
//  fixes the support/resistance role classification (it was inverted) and adds a
//  hidden buffer so the MBT host EA reliably drives OnCalculate in the tester.
//
//  ALGORITHM OVERVIEW:
//  -------------------
//  1. Collect candidate prices. With InpUsePivots (default) only SWING PIVOTS
//     are used: a high with InpPivotStrength lower highs on each side, or a low
//     with InpPivotStrength higher lows on each side.
//  2. Cluster candidates within the cluster tolerance. Each cluster yields a
//     centroid price plus a ZONE (the lowest..highest wick in the cluster).
//  3. For each candidate, scan CHRONOLOGICALLY (oldest -> newest):
//       - Line STARTS at the first candle that touches it (Low <= P <= High).
//       - Line BREAKS when a candle body crosses it AND the break is confirmed
//         by InpBreakConfirmCloses closes beyond the level (so a single wicky
//         poke through a body no longer falsely kills the level).
//       - A touch only counts as a NEW test if price pulled away by the
//         separation distance since the previous counted touch.
//  4. If a lifespan has >= InpMinTouches distinct touches it is a valid level.
//       - ROLE FLIP: if the same price re-forms after a break with the opposite
//         role (support<->resistance), its score is boosted by InpFlipBoost —
//         a flipped-and-held level is high-confidence.
//  5. Each level gets a STRENGTH SCORE: every touch contributes
//         recency weight  x  rejection weight  x  volume weight.
//  6. Levels are sorted by score. They are then filtered:
//       - RELEVANCE: optionally drop levels too far from current price.
//       - PROXIMITY: drop levels too close in price to a stronger one.
//       - SHARED-CANDLE MERGE: drop a weaker level whose touch candles overlap
//         a stronger one's (built from effectively the same candles).
//  7. The strongest InpMaxLines are drawn — as ZONES (rectangles) or lines.
//     Line width / shade scale with strength when InpScaleByStrength is on.
//     Support = blue, Resistance = red.
//
//  TOLERANCES: with InpUseATRScaling (default) cluster / separation / min-gap /
//  relevance distances are multiples of ATR, so the indicator auto-adapts to any
//  symbol or timeframe. Turn it off to use fixed Points.
//
//+------------------------------------------------------------------+
#property copyright "Antigravity AI"
#property link      "https://github.com/FXDavid-OffbeatForex/SRLines"
#property version   "4.10"
#property indicator_chart_window
#property indicator_buffers 1
#property indicator_plots   1

#include <SignalLogger.mqh>

//--- Strategy selector for logged signals
enum ENUM_SR_STRATEGY
{
   STRAT_BREAK_RETEST_FLIP = 0,   // Break-and-retest of a flipped zone (S<->R)
   STRAT_ZONE_BOUNCE       = 1,   // Bounce/rejection at any S/R zone
   STRAT_BREAKOUT_FRACTAL  = 2    // Breakout + wave pullback + fractal break entry
};

//--- Input parameters
input int             InpLookbackBars       = 200;            // Lookback Bars to Analyze
input int             InpMaxLines           = 10;             // Max Lines to Draw
input int             InpMinTouches         = 3;              // Min Touches Required

input group           "Candidate detection"
input bool            InpUsePivots          = true;           // Use Swing Pivots (off = every High/Low)
input int             InpPivotStrength      = 3;              // Pivot Strength (bars each side)

input group           "Strength scoring"
input bool            InpUseStrengthScore   = true;           // Rank by Strength Score (off = by touches)
input double          InpRecencyHalfLife    = 100.0;          // Recency Half-Life (bars; weight halves)
input double          InpRejectionWeight    = 1.0;            // Rejection-Wick Weight
input double          InpVolumeWeight       = 1.0;            // Volume Weight

input group           "Break confirmation & role flips"
input int             InpBreakConfirmCloses = 2;              // Closes Beyond to Confirm a Break
input double          InpFlipBoost          = 1.50;           // Score Boost for Flipped Levels (S<->R)

input group           "Zones & merging"
input bool            InpDrawZones          = true;           // Draw Zones (off = single lines)
input bool            InpMergeSharedCandles = true;           // Merge Levels Sharing the Same Candles
input double          InpSharedOverlapPct   = 60.0;           // Shared-Candle Overlap Threshold (%)

input group           "Relevance filter"
input bool            InpFilterByDistance   = true;           // Only Show Levels Near Price
input double          InpMaxDistanceATR     = 20.0;           // Max Distance From Price (x ATR)

input group           "Tolerances (ATR-scaled)"
input bool            InpUseATRScaling      = true;           // Scale Distances by ATR
input int             InpATRPeriod          = 14;             // ATR Period
input double          InpClusterATR         = 0.25;           // Cluster Tolerance (x ATR)
input double          InpSeparationATR      = 0.50;           // Min Move-Away Between Touches (x ATR)
input double          InpMinDistATR         = 1.00;           // Min Distance Between Lines (x ATR)

input group           "Tolerances (fixed Points; used when ATR scaling is off)"
input double          InpTouchSeparationPoints = 50.0;        // Min Move-Away Between Touches (Points)
input double          InpMinDistancePoints  = 100.0;          // Min Distance Between Lines (Points)
input double          InpClusterTolerance   = 10.0;           // Cluster Tolerance (Points)

input group           "Appearance"
input bool            InpScaleByStrength    = true;           // Scale Width/Shade by Strength
input color           InpSupportColor       = clrDeepSkyBlue; // Support Color
input color           InpResistanceColor    = clrTomato;      // Resistance Color
input ENUM_LINE_STYLE InpLineStyle          = STYLE_SOLID;    // Line Style
input int             InpLineWidth          = 2;              // Line Width

input group           "Strategy signals (for MBT backtesting)"
input bool            InpEnableSignals      = true;           // Log Strategy Signals
input ENUM_SR_STRATEGY InpStrategy          = STRAT_BREAKOUT_FRACTAL; // Strategy
input double          InpRiskReward         = 2.0;            // Reward : Risk
input double          InpStopATRBuffer      = 0.5;            // Stop Buffer Beyond Zone (x ATR)
input bool            InpUseScoreFilter     = false;          // Score Filter: Only Top Half of Flip Zones
input bool            InpUseNextZoneTP      = true;           // Next-Zone TP: TP at Next Opposing Zone
input double          InpMaxNextZoneRR      = 3.0;            // Next-Zone TP: Cap at This RR (flat RR if beyond)
input bool            InpUseSessionFilter   = false;          // Session Filter: Active Session Only
input int             InpSessionStartHour   = 7;              // Session Start Hour (UTC, inclusive)
input int             InpSessionEndHour     = 17;             // Session End Hour (UTC, exclusive)
input int             InpFractalBars        = 2;              // Fractal Bars Each Side (Williams fractal)
input int             InpBreakoutMaxAge     = 80;             // Breakout: Max Bars Since Break to Watch

//--- Structure to hold a detected S/R line
struct SRLevel
{
   double   price;         // Representative price of the level (cluster centroid)
   double   zoneLow;       // Lowest wick in the cluster (zone bottom)
   double   zoneHigh;      // Highest wick in the cluster (zone top)
   int      touches;       // Number of distinct touches within lifespan
   double   score;         // Strength score (ranking key)
   int      candlesBelow;  // Touching candles whose body was fully below P
   int      candlesAbove;  // Touching candles whose body was fully above P
   bool     isSupport;     // True if more bodies below the level than above
   bool     isFlip;        // True if this level flipped role from its prior life
   int      startIdx;      // Bar index of first touch
   int      endIdx;        // Bar index of last touch (before break)
   datetime startTime;     // Time of first touch
   datetime endTime;       // Time of last touch (before break)
   int      breakIdx;      // Bar index of confirmed break (last_bar+1 = still active)
   bool     brokeUp;       // True = broke upward through the level
};

//--- Global
datetime ExtLastBarTime = 0;
double   ExtBuf[];   // hidden buffer so the MBT host EA can drive OnCalculate

//+------------------------------------------------------------------+
//| Initialization                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, "SRLines v4");

   SetIndexBuffer(0, ExtBuf, INDICATOR_DATA);
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);
   PlotIndexSetString(0, PLOT_LABEL, "SR(host)");

   if(InpEnableSignals)
      ResetSignalLog();

   CleanUpObjects();
   ChartRedraw(0);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   CleanUpObjects();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Main calculation - only recalculates on a new bar                |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
   //--- Keep the hidden buffer populated so the host EA's CopyBuffer drives us
   for(int i = (prev_calculated > 0 ? prev_calculated - 1 : 0); i < rates_total; i++)
      ExtBuf[i] = close[i];

   if(rates_total < InpLookbackBars + 2)
      return(0);

   datetime currentBarTime = time[rates_total - 1];
   if(currentBarTime != ExtLastBarTime)
   {
      CalculateSRLines(rates_total, time, open, high, low, close, tick_volume);
      ExtLastBarTime = currentBarTime;
   }

   return(rates_total);
}

//+------------------------------------------------------------------+
//| Delete all SRLine_ objects from the chart                        |
//+------------------------------------------------------------------+
void CleanUpObjects()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringSubstr(name, 0, 7) == "SRLine_")
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| Average True Range over the last 'period' closed bars            |
//+------------------------------------------------------------------+
double ComputeATR(const double &high[], const double &low[], const double &close[],
                  int last_bar, int first_bar, int period)
{
   double sumTR = 0.0;
   int    n     = 0;
   for(int i = last_bar; i > last_bar - period && i > first_bar; i--)
   {
      double tr = high[i] - low[i];
      tr = MathMax(tr, MathAbs(high[i] - close[i - 1]));
      tr = MathMax(tr, MathAbs(low[i]  - close[i - 1]));
      sumTR += tr;
      n++;
   }
   return(n > 0 ? sumTR / n : 0.0);
}

//+------------------------------------------------------------------+
//| Is a body-cross at bar i a CONFIRMED break? (N closes beyond P)  |
//+------------------------------------------------------------------+
bool IsBreakConfirmed(const double &close[], int i, int last_bar, double P, int n)
{
   if(n <= 1) return true;
   bool up = (close[i] > P);          // direction of the break
   for(int k = i; k < i + n; k++)
   {
      if(k > last_bar) return false;  // not enough bars yet -> treat as unconfirmed
      if(up  && close[k] <= P) return false;
      if(!up && close[k] >= P) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Fraction of the smaller bar-range that two ranges share          |
//+------------------------------------------------------------------+
double BarOverlapFraction(int a0, int a1, int b0, int b1)
{
   int lo = MathMax(a0, b0);
   int hi = MathMin(a1, b1);
   int ov = hi - lo + 1;
   if(ov < 0) ov = 0;
   int sa = a1 - a0 + 1;
   int sb = b1 - b0 + 1;
   int sm = MathMin(sa, sb);
   return(sm > 0 ? (double)ov / sm : 0.0);
}

//+------------------------------------------------------------------+
//| Dim a color toward black by factor f (0=black, 1=full)           |
//+------------------------------------------------------------------+
color DimColor(color c, double f)
{
   f = MathMax(0.0, MathMin(1.0, f));
   int r = (int)((c & 0xFF) * f);
   int g = (int)(((c >> 8) & 0xFF) * f);
   int b = (int)(((c >> 16) & 0xFF) * f);
   return((color)((b << 16) | (g << 8) | r));
}

//+------------------------------------------------------------------+
//| Core S/R detection algorithm                                     |
//+------------------------------------------------------------------+
void CalculateSRLines(const int      rates_total,
                      const datetime &time[],
                      const double   &open[],
                      const double   &high[],
                      const double   &low[],
                      const double   &close[],
                      const long     &tick_volume[])
{
   //--- Define the closed-bar window (exclude current forming bar at rates_total-1)
   int last_bar  = rates_total - 2;
   int first_bar = last_bar - InpLookbackBars + 1;
   if(first_bar < 0) first_bar = 0;
   int num_bars = last_bar - first_bar + 1;
   if(num_bars <= 0) return;

   //--- ATR & average volume over the window (drive scoring + adaptive tolerances)
   double atr = ComputeATR(high, low, close, last_bar, first_bar, InpATRPeriod);

   double volSum = 0.0;
   for(int i = first_bar; i <= last_bar; i++)
      volSum += (double)tick_volume[i];
   double avgVol = (num_bars > 0) ? volSum / num_bars : 0.0;

   //--- Resolve distances (ATR-scaled when enabled & ATR is valid, else Points)
   double clusterTol, awayDist, minDist;
   if(InpUseATRScaling && atr > 0.0)
   {
      clusterTol = InpClusterATR    * atr;
      awayDist   = InpSeparationATR * atr;
      minDist    = InpMinDistATR    * atr;
   }
   else
   {
      clusterTol = InpClusterTolerance      * _Point;
      awayDist   = InpTouchSeparationPoints * _Point;
      minDist    = InpMinDistancePoints     * _Point;
   }

   //--- Step 1: Collect candidate prices.
   int maxCand = num_bars * 2;
   double rawCand[];
   ArrayResize(rawCand, maxCand);
   int rawCount = 0;

   if(InpUsePivots)
   {
      //--- Swing pivots only: turning points with InpPivotStrength bars each side
      int strength = MathMax(1, InpPivotStrength);
      for(int i = first_bar + strength; i <= last_bar - strength; i++)
      {
         bool isHigh = true;
         bool isLow  = true;
         for(int k = 1; k <= strength; k++)
         {
            if(high[i] <= high[i - k] || high[i] <= high[i + k]) isHigh = false;
            if(low[i]  >= low[i - k]  || low[i]  >= low[i + k])  isLow  = false;
            if(!isHigh && !isLow) break;
         }
         if(isHigh) rawCand[rawCount++] = high[i];
         if(isLow)  rawCand[rawCount++] = low[i];
      }
   }
   else
   {
      //--- Fallback: every bar's high and low
      for(int i = first_bar; i <= last_bar; i++)
      {
         rawCand[rawCount++] = high[i];
         rawCand[rawCount++] = low[i];
      }
   }

   if(rawCount == 0) { CleanUpObjects(); ChartRedraw(0); return; }
   ArrayResize(rawCand, rawCount);
   ArraySort(rawCand); // sort ascending so we can cluster

   //--- Step 2: Cluster candidates within clusterTol. Keep centroid + zone band.
   double candMid[], candLo[], candHi[];
   int    candCount = 0;
   ArrayResize(candMid, rawCount);
   ArrayResize(candLo,  rawCount);
   ArrayResize(candHi,  rawCount);

   int ci = 0;
   while(ci < rawCount)
   {
      double clusterSum  = rawCand[ci];
      double lo          = rawCand[ci];
      double hi          = rawCand[ci];
      int    clusterSize = 1;
      while(ci + clusterSize < rawCount &&
            rawCand[ci + clusterSize] - rawCand[ci] <= clusterTol)
      {
         double v = rawCand[ci + clusterSize];
         clusterSum += v;
         if(v < lo) lo = v;
         if(v > hi) hi = v;
         clusterSize++;
      }
      candMid[candCount] = clusterSum / clusterSize;
      candLo[candCount]  = lo;
      candHi[candCount]  = hi;
      candCount++;
      ci += clusterSize;
   }

   //--- Step 3: For each candidate, find all valid lifespans chronologically.
   SRLevel validLevels[];
   int validCount = 0;
   ArrayResize(validLevels, candCount * 4);

   for(int c = 0; c < candCount; c++)
   {
      double P        = candMid[c];
      int    scanFrom = first_bar;
      int    prevSide = -1;   // role of previous valid lifespan: 1=support, 0=resistance

      while(scanFrom <= last_bar)
      {
         // Find first touch of P at or after scanFrom
         int firstTouchIdx = -1;
         for(int i = scanFrom; i <= last_bar; i++)
         {
            if(low[i] <= P && P <= high[i])
            {
               firstTouchIdx = i;
               break;
            }
         }
         if(firstTouchIdx == -1) break; // no further touches for this candidate

         // Scan forward: accumulate distinct (separated) touches, stop at a
         // CONFIRMED body cross.
         int      breakIdx     = last_bar + 1;
         int      touches      = 0;
         int      candBelow    = 0;
         int      candAbove    = 0;
         int      lastTouchIdx = firstTouchIdx;
         bool     armed        = true;  // ready to count the next distinct touch
         double   scoreSum     = 0.0;   // composite strength score for this lifespan

         for(int i = firstTouchIdx; i <= last_bar; i++)
         {
            double bodyMin = MathMin(open[i], close[i]);
            double bodyMax = MathMax(open[i], close[i]);

            // Body crossing: only a real break if confirmed by N closes beyond.
            if(P > bodyMin && P < bodyMax)
            {
               if(IsBreakConfirmed(close, i, last_bar, P, InpBreakConfirmCloses))
               {
                  breakIdx = i;
                  break;
               }
               continue; // false poke: not a break and not a touch
            }

            bool touchesNow = (low[i] <= P && P <= high[i]);

            if(armed && touchesNow)
            {
               // A distinct rejection: wick reaches the level, body does not engulf it
               touches++;
               lastTouchIdx = i;
               if(bodyMax <= P) candBelow++;  // candle body entirely below level
               if(bodyMin >= P) candAbove++;  // candle body entirely above level
               armed = false;                 // wait for price to leave before re-counting

               //--- Strength contribution of this touch
               double rej;
               if(bodyMin >= P)      rej = bodyMin - low[i];                  // support test: lower wick
               else if(bodyMax <= P) rej = high[i] - bodyMax;                 // resistance test: upper wick
               else                  rej = MathMax(bodyMin - low[i], high[i] - bodyMax);

               double rnorm = (atr > 0.0) ? MathMin(rej / atr, 2.0) : 0.0;
               double rejW  = 1.0 + InpRejectionWeight * rnorm;              // 1 .. 1+2w

               double rrel  = (avgVol > 0.0) ? (double)tick_volume[i] / avgVol : 1.0;
               rrel = MathMax(0.5, MathMin(rrel, 2.0));
               double volW  = 1.0 + InpVolumeWeight * (rrel - 1.0);          // 1 +/- 0.5w

               double age   = (double)(last_bar - i);
               double recW  = MathPow(2.0, -age / MathMax(1.0, InpRecencyHalfLife));

               scoreSum += recW * rejW * volW;
            }
            else if(!armed && !touchesNow)
            {
               // Re-arm only once price has pulled clearly away from the level
               if(high[i] < P - awayDist || low[i] > P + awayDist)
                  armed = true;
            }
         }

         // Record this lifespan if it has enough touches
         if(touches >= InpMinTouches)
         {
            // Support is tested from ABOVE: the touching candle dips its wick to
            // the level and closes back up, leaving its body above it (candAbove).
            // Resistance is the mirror (body below, candBelow).
            bool isSupport = (candAbove >= candBelow);
            int  curSide   = isSupport ? 1 : 0;

            // Role flip: previous valid life of this price had the opposite role
            bool isFlip = (prevSide != -1 && curSide != prevSide);
            double finalScore = (InpUseStrengthScore ? scoreSum : (double)touches);
            if(isFlip) finalScore *= InpFlipBoost;
            prevSide = curSide;

            if(validCount >= ArraySize(validLevels))
               ArrayResize(validLevels, validCount + 64);

            validLevels[validCount].price        = P;
            validLevels[validCount].zoneLow       = candLo[c];
            validLevels[validCount].zoneHigh      = candHi[c];
            validLevels[validCount].touches       = touches;
            validLevels[validCount].score         = finalScore;
            validLevels[validCount].candlesBelow  = candBelow;
            validLevels[validCount].candlesAbove  = candAbove;
            validLevels[validCount].isSupport     = isSupport;
            validLevels[validCount].isFlip        = isFlip;
            validLevels[validCount].startIdx      = firstTouchIdx;
            validLevels[validCount].endIdx        = lastTouchIdx;
            validLevels[validCount].startTime     = time[firstTouchIdx];
            validLevels[validCount].endTime       = time[lastTouchIdx];
            validLevels[validCount].breakIdx      = breakIdx;
            validLevels[validCount].brokeUp       = (breakIdx <= last_bar) ? (close[breakIdx] > P) : false;
            validCount++;
         }

         // Continue searching past the break for another lifespan
         scanFrom = breakIdx + 1;
      }
   }
   ArrayResize(validLevels, validCount);

   //--- Step 4: Sort by strength score descending
   SortLevels(validLevels);

   //--- Step 5: Filter — relevance to price, then proximity + shared-candle merge
   double currentPrice = close[rates_total - 1];
   double maxRelDist   = InpMaxDistanceATR * atr;

   SRLevel selectedLevels[];
   int selectedCount = 0;
   ArrayResize(selectedLevels, InpMaxLines);

   for(int i = 0; i < validCount && selectedCount < InpMaxLines; i++)
   {
      // Relevance: drop levels too far from current price (by nearest zone edge)
      if(InpFilterByDistance && maxRelDist > 0.0)
      {
         double d;
         if(currentPrice < validLevels[i].zoneLow)       d = validLevels[i].zoneLow  - currentPrice;
         else if(currentPrice > validLevels[i].zoneHigh) d = currentPrice - validLevels[i].zoneHigh;
         else                                            d = 0.0;
         if(d > maxRelDist) continue;
      }

      bool reject = false;
      for(int j = 0; j < selectedCount; j++)
      {
         // Proximity: too close in price to an already-kept (stronger) level
         if(MathAbs(validLevels[i].price - selectedLevels[j].price) < minDist)
         {
            reject = true;
            break;
         }

         // Shared-candle merge: built from effectively the same candles
         if(InpMergeSharedCandles)
         {
            double ov = BarOverlapFraction(validLevels[i].startIdx, validLevels[i].endIdx,
                                           selectedLevels[j].startIdx, selectedLevels[j].endIdx);
            bool zonesIntersect = !(validLevels[i].zoneHigh < selectedLevels[j].zoneLow ||
                                    selectedLevels[j].zoneHigh < validLevels[i].zoneLow);
            if(ov * 100.0 >= InpSharedOverlapPct && zonesIntersect)
            {
               reject = true;
               break;
            }
         }
      }

      if(!reject)
      {
         selectedLevels[selectedCount] = validLevels[i];
         selectedCount++;
      }
   }
   ArrayResize(selectedLevels, selectedCount);

   //--- Step 6: Delete old objects and draw the selected ones
   CleanUpObjects();

   double maxScore  = (selectedCount > 0) ? selectedLevels[0].score : 1.0; // sorted desc
   if(maxScore <= 0.0) maxScore = 1.0;
   datetime rightT  = time[rates_total - 1];
   double   minZone = (atr > 0.0) ? 0.15 * atr : clusterTol;

   for(int i = 0; i < selectedCount; i++)
   {
      double ratio = MathMax(0.0, MathMin(1.0, selectedLevels[i].score / maxScore));
      color  base  = selectedLevels[i].isSupport ? InpSupportColor : InpResistanceColor;
      color  col   = InpScaleByStrength ? DimColor(base, 0.45 + 0.55 * ratio) : base;
      int    width = InpScaleByStrength
                     ? MathMax(1, (int)MathRound(InpLineWidth * (0.4 + 0.6 * ratio)))
                     : InpLineWidth;
      if(selectedLevels[i].isFlip) width += 1; // flipped levels drawn a touch bolder

      string tag  = (selectedLevels[i].isSupport ? "Support" : "Resistance") +
                    (selectedLevels[i].isFlip ? " (FLIP)" : "");
      string desc = tag +
                    " | Touches: " + IntegerToString(selectedLevels[i].touches) +
                    " | Score: "   + DoubleToString(selectedLevels[i].score, 2) +
                    " | " + TimeToString(selectedLevels[i].startTime, TIME_DATE) +
                    " to " + TimeToString(selectedLevels[i].endTime, TIME_DATE);

      string name = "SRLine_" + IntegerToString(i) + "_" +
                    DoubleToString(selectedLevels[i].price, _Digits);

      if(InpDrawZones)
      {
         // Pad a thin zone so single-wick clusters remain visible
         double zlo = selectedLevels[i].zoneLow;
         double zhi = selectedLevels[i].zoneHigh;
         if(zhi - zlo < minZone)
         {
            double mid = 0.5 * (zhi + zlo);
            zlo = mid - 0.5 * minZone;
            zhi = mid + 0.5 * minZone;
         }

         if(ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                         selectedLevels[i].startTime, zhi, rightT, zlo))
         {
            ObjectSetInteger(0, name, OBJPROP_COLOR, col);
            ObjectSetInteger(0, name, OBJPROP_STYLE, InpLineStyle);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
            ObjectSetInteger(0, name, OBJPROP_FILL,  true);
            ObjectSetInteger(0, name, OBJPROP_BACK,  true);
            ObjectSetString(0, name, OBJPROP_TEXT,    desc);
            ObjectSetString(0, name, OBJPROP_TOOLTIP, desc);
         }
      }
      else
      {
         if(ObjectCreate(0, name, OBJ_HLINE, 0, 0, selectedLevels[i].price))
         {
            ObjectSetInteger(0, name, OBJPROP_COLOR, col);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
            ObjectSetInteger(0, name, OBJPROP_STYLE, InpLineStyle);
            ObjectSetInteger(0, name, OBJPROP_BACK,  false);
            ObjectSetString(0, name, OBJPROP_TEXT,    desc);
            ObjectSetString(0, name, OBJPROP_TOOLTIP, desc);
         }
      }
   }

   //--- Step 7: Strategy signals for MBT backtesting.
   //    Evaluate the just-closed bar (last_bar) against the drawn zones.
   //    Three optional filters applied before the zone loop:
   //      - Session filter: bar must be within the London/NY overlap window (UTC).
   //      - Score filter  : for FLIP strategy, only zones scoring >= median flip score.
   //      - Next-zone TP  : TP placed at next opposing zone rather than flat RR.
   if(InpEnableSignals && atr > 0.0 && selectedCount > 0)
   {
      int    L   = last_bar;
      double oL  = open[L],  hL = high[L], lL = low[L], cL = close[L];
      double buf = InpStopATRBuffer * atr;
      string tag = (InpStrategy == STRAT_BREAK_RETEST_FLIP) ? "FLIP" : "BOUNCE";
      bool   doSignal = true;

      //--- Session filter: London/NY overlap (UTC hours, default 13-17)
      if(InpUseSessionFilter)
      {
         MqlDateTime dt;
         TimeToStruct(time[L], dt);
         if(dt.hour < InpSessionStartHour || dt.hour >= InpSessionEndHour)
            doSignal = false;
      }

      //--- Score filter: pre-compute median score of FLIP zones
      double medianFlipScore = 0.0;
      if(doSignal && InpUseScoreFilter && InpStrategy == STRAT_BREAK_RETEST_FLIP)
      {
         int flipCount = 0;
         for(int i = 0; i < selectedCount; i++)
            if(selectedLevels[i].isFlip) flipCount++;
         if(flipCount > 0)
         {
            int halfIdx = flipCount / 2;
            int seen    = 0;
            for(int i = 0; i < selectedCount; i++)
            {
               if(!selectedLevels[i].isFlip) continue;
               if(seen == halfIdx) { medianFlipScore = selectedLevels[i].score; break; }
               seen++;
            }
         }
      }

      if(doSignal)
      {
         if(InpStrategy == STRAT_BREAK_RETEST_FLIP || InpStrategy == STRAT_ZONE_BOUNCE)
         {
            for(int i = 0; i < selectedCount; i++)
            {
               if(InpStrategy == STRAT_BREAK_RETEST_FLIP && !selectedLevels[i].isFlip)
                  continue;
               if(InpUseScoreFilter && InpStrategy == STRAT_BREAK_RETEST_FLIP &&
                  selectedLevels[i].score < medianFlipScore)
                  continue;

               double zlo = selectedLevels[i].zoneLow;
               double zhi = selectedLevels[i].zoneHigh;
               if(zhi - zlo < minZone)
               {
                  double mid = 0.5 * (zhi + zlo);
                  zlo = mid - 0.5 * minZone;
                  zhi = mid + 0.5 * minZone;
               }

               if(selectedLevels[i].isSupport)
               {
                  if(lL <= zhi && cL >= zlo && cL > oL)
                  {
                     double entry = cL;
                     double sl    = zlo - buf;
                     if(entry > sl)
                     {
                        double riskR = entry - sl;
                        double tp    = entry + InpRiskReward * riskR;
                        if(InpUseNextZoneTP)
                        {
                           double nearest = 0.0;
                           for(int j = 0; j < selectedCount; j++)
                           {
                              if(selectedLevels[j].isSupport) continue;
                              double cand = selectedLevels[j].zoneLow;
                              if(cand > entry && (nearest == 0.0 || cand < nearest))
                                 nearest = cand;
                           }
                           double maxTP = entry + InpMaxNextZoneRR * riskR;
                           if(nearest > entry + riskR && nearest <= maxTP)
                              tp = nearest;
                        }
                        LogSignal(1, true, entry, sl, tp, tag);
                        break;
                     }
                  }
               }
               else
               {
                  if(hL >= zlo && cL <= zhi && cL < oL)
                  {
                     double entry = cL;
                     double sl    = zhi + buf;
                     if(sl > entry)
                     {
                        double riskR = sl - entry;
                        double tp    = entry - InpRiskReward * riskR;
                        if(InpUseNextZoneTP)
                        {
                           double nearest = 0.0;
                           for(int j = 0; j < selectedCount; j++)
                           {
                              if(!selectedLevels[j].isSupport) continue;
                              double cand = selectedLevels[j].zoneHigh;
                              if(cand < entry && (nearest == 0.0 || cand > nearest))
                                 nearest = cand;
                           }
                           double minTP = entry - InpMaxNextZoneRR * riskR;
                           if(nearest < entry - riskR && nearest >= minTP)
                              tp = nearest;
                        }
                        LogSignal(1, false, entry, sl, tp, tag);
                        break;
                     }
                  }
               }
            }
         }
         else if(InpStrategy == STRAT_BREAKOUT_FRACTAL && validCount > 0)
         {
            int fracN = MathMax(1, InpFractalBars);

            for(int i = 0; i < validCount; i++)
            {
               int  bIdx = validLevels[i].breakIdx;
               bool bUp  = validLevels[i].brokeUp;

               if(bIdx > last_bar)                         continue; // still active
               if(last_bar - bIdx > InpBreakoutMaxAge)     continue; // break too old
               if(bIdx + 1 >= last_bar)                    continue; // no bars in pullback

               // ── BULLISH: resistance (isSupport=false) broke upward ──────────────
               if(!validLevels[i].isSupport && bUp)
               {
                  // All pullback CLOSES must stay above the level centroid P
                  // (wicks may pierce the zone; closes must not re-enter below it)
                  double zFloor = validLevels[i].price;
                  bool pullbackClean = true;
                  for(int j = bIdx + 1; j < last_bar; j++)
                     if(close[j] < zFloor) { pullbackClean = false; break; }
                  if(!pullbackClean) continue;

                  // Step 1: find the spike peak (highest high after the break)
                  int h1_bar = bIdx + 1;
                  double h1 = high[bIdx + 1];
                  for(int j = bIdx + 2; j <= last_bar; j++)
                     if(high[j] > h1) { h1 = high[j]; h1_bar = j; }

                  // Step 2: find the first Williams fractal HIGH that forms AFTER
                  // the spike peak — this is the "lower high" in the pullback wave,
                  // NOT the spike peak itself.
                  int fh_bar = -1; double fh = 0.0;
                  for(int j = h1_bar + 1; j <= last_bar - fracN; j++)
                  {
                     bool isFH = true;
                     for(int k = 1; k <= fracN; k++)
                     {
                        if(j - k < 0) { isFH = false; break; }
                        if(high[j] <= high[j-k] || high[j] <= high[j+k]) { isFH = false; break; }
                     }
                     if(isFH) { fh_bar = j; fh = high[j]; break; }
                  }
                  if(fh_bar < 0 || cL <= fh) continue;

                  // Entry must be the FIRST bar to close above fh
                  bool firstClose = true;
                  for(int j = fh_bar + fracN + 1; j < last_bar; j++)
                     if(close[j] > fh) { firstClose = false; break; }
                  if(!firstClose) continue;

                  // SL: below the lowest low in the pullback wave (after spike peak)
                  double fl = (h1_bar + 1 <= last_bar - 1) ? low[h1_bar + 1] : low[bIdx + 1];
                  for(int j = h1_bar + 2; j < last_bar; j++) fl = MathMin(fl, low[j]);

                  double entry = cL;
                  double sl    = fl - buf;
                  if(entry <= sl) continue;
                  double riskR = entry - sl;
                  if(riskR <= 0.0) continue;
                  double tp = entry + InpRiskReward * riskR;

                  if(InpUseNextZoneTP)
                  {
                     double nearest = 0.0;
                     for(int j = 0; j < selectedCount; j++)
                     {
                        if(selectedLevels[j].isSupport) continue;
                        double cand = selectedLevels[j].zoneLow;
                        if(cand > entry && (nearest == 0.0 || cand < nearest)) nearest = cand;
                     }
                     double maxTP = entry + InpMaxNextZoneRR * riskR;
                     if(nearest > entry + riskR && nearest <= maxTP) tp = nearest;
                  }
                  LogSignal(1, true, entry, sl, tp, "BKT");
                  break;
               }

               // ── BEARISH: support (isSupport=true) broke downward ─────────────────
               if(validLevels[i].isSupport && !bUp)
               {
                  // All bounce CLOSES must stay below the level centroid P
                  // (wicks may pierce the zone; closes must not re-enter above it)
                  double zCeil = validLevels[i].price;
                  bool bounceClean = true;
                  for(int j = bIdx + 1; j < last_bar; j++)
                     if(close[j] > zCeil) { bounceClean = false; break; }
                  if(!bounceClean) continue;

                  // Step 1: find the spike low (lowest low after the break)
                  int l1_bar = bIdx + 1;
                  double l1 = low[bIdx + 1];
                  for(int j = bIdx + 2; j <= last_bar; j++)
                     if(low[j] < l1) { l1 = low[j]; l1_bar = j; }

                  // Step 2: find the first Williams fractal LOW that forms AFTER
                  // the spike low — the "higher low" in the bounce wave
                  int fl_bar = -1; double fl_val = 0.0;
                  for(int j = l1_bar + 1; j <= last_bar - fracN; j++)
                  {
                     bool isFL = true;
                     for(int k = 1; k <= fracN; k++)
                     {
                        if(j - k < 0) { isFL = false; break; }
                        if(low[j] >= low[j-k] || low[j] >= low[j+k]) { isFL = false; break; }
                     }
                     if(isFL) { fl_bar = j; fl_val = low[j]; break; }
                  }
                  if(fl_bar < 0 || cL >= fl_val) continue;

                  bool firstClose = true;
                  for(int j = fl_bar + fracN + 1; j < last_bar; j++)
                     if(close[j] < fl_val) { firstClose = false; break; }
                  if(!firstClose) continue;

                  // SL: above the highest high in the bounce (after spike low)
                  double fh_sl = (l1_bar + 1 <= last_bar - 1) ? high[l1_bar + 1] : high[bIdx + 1];
                  for(int j = l1_bar + 2; j < last_bar; j++) fh_sl = MathMax(fh_sl, high[j]);

                  double entry = cL;
                  double sl    = fh_sl + buf;
                  if(sl <= entry) continue;
                  double riskR = sl - entry;
                  if(riskR <= 0.0) continue;
                  double tp = entry - InpRiskReward * riskR;

                  if(InpUseNextZoneTP)
                  {
                     double nearest = 0.0;
                     for(int j = 0; j < selectedCount; j++)
                     {
                        if(!selectedLevels[j].isSupport) continue;
                        double cand = selectedLevels[j].zoneHigh;
                        if(cand < entry && (nearest == 0.0 || cand > nearest)) nearest = cand;
                     }
                     double minTP = entry - InpMaxNextZoneRR * riskR;
                     if(nearest < entry - riskR && nearest >= minTP) tp = nearest;
                  }
                  LogSignal(1, false, entry, sl, tp, "BKT");
                  break;
               }
            }
         }
      }
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Selection sort — descending by strength score                    |
//+------------------------------------------------------------------+
void SortLevels(SRLevel &arr[])
{
   int n = ArraySize(arr);
   for(int i = 0; i < n - 1; i++)
   {
      int best = i;
      for(int j = i + 1; j < n; j++)
         if(arr[j].score > arr[best].score)
            best = j;
      if(best != i)
      {
         SRLevel tmp = arr[i];
         arr[i]      = arr[best];
         arr[best]   = tmp;
      }
   }
}
