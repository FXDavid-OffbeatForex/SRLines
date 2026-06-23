# SRLines — Swing-Pivot Support & Resistance Zones for MetaTrader 5

**SRLines** is a MetaTrader 5 indicator that automatically detects, scores, and draws support and resistance zones on any symbol and timeframe. It uses swing-pivot detection, chronological lifespan tracking, and a multi-factor strength score to keep only the most relevant levels visible.

## How It Works

1. **Pivot detection** — Candidate prices come from swing highs and lows (a bar whose high is the highest, or low is the lowest, across a configurable number of bars on each side). This focuses the indicator on structurally significant prices rather than every candle extreme.

2. **Clustering** — Nearby candidates within a tolerance window are merged into a single zone. The zone spans the lowest to highest wick in the cluster; the centroid becomes the level's reference price.

3. **Chronological lifespan** — Each level is evaluated oldest-to-newest:
   - The level **starts** at the first candle that touches it (wick enters the zone).
   - The level **breaks** only when a candle body closes beyond it *and* a configurable number of subsequent closes confirm the move — single wicky pokes do not kill a level.
   - A touch only counts as a *new* test if price pulled away by a minimum separation distance since the last touch, preventing a long consolidation from inflating the count.

4. **Role flips** — If a broken level re-forms with the opposite role (support becomes resistance or vice versa), its strength score receives a configurable boost. Flipped-and-held levels are high-confidence zones.

5. **Strength scoring** — Every distinct touch contributes a weighted score:
   - **Recency weight** — recent touches count more (exponential decay by half-life).
   - **Rejection weight** — the size of the rejection wick at each touch.
   - **Volume weight** — relative volume at each touch.

6. **Filtering** — Levels are sorted by score, then filtered:
   - *Relevance* — optionally drop levels too far from the current price.
   - *Proximity* — drop levels too close to a stronger one.
   - *Shared-candle merge* — drop a weaker level whose touch candles overlap a stronger one's.

7. **Drawing** — The strongest levels are drawn as **zones** (rectangles spanning the wick cluster) or plain horizontal lines. Line width and fill opacity scale with strength when `ScaleByStrength` is on.

---

## Installation

1. Copy `SRLines.mq5` into `<MT5 data folder>\MQL5\Indicators\`.
2. Open MetaEditor, open the file, and compile — or simply place the pre-compiled `SRLines.ex5` directly into the same folder.
3. Restart MetaTrader 5 (or press F5 in the Navigator panel to refresh).
4. Drag **SRLines** from Navigator → Indicators onto any chart.

---

## Parameters

### Core

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Lookback Bars to Analyze` | 200 | Number of closed bars scanned for S/R levels. |
| `Max Lines to Draw` | 10 | Maximum number of zones shown simultaneously. |
| `Min Touches Required` | 3 | A level must have at least this many distinct touches to qualify. |

### Candidate Detection

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Use Swing Pivots` | true | When on, only pivot highs/lows are used as candidates. When off, every bar's high and low is used. |
| `Pivot Strength (bars each side)` | 3 | Number of bars on each side required for a bar to qualify as a swing pivot. Higher values find larger, more significant swings. |

### Strength Scoring

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Rank by Strength Score` | true | When on, levels are ranked by the weighted strength score. When off, ranking is by raw touch count. |
| `Recency Half-Life (bars)` | 100 | Exponential decay rate for recency weighting — a touch this many bars ago counts half as much as the most recent touch. |
| `Rejection-Wick Weight` | 1.0 | Relative contribution of the rejection wick size to the strength score. Set to 0 to ignore wicks. |
| `Volume Weight` | 1.0 | Relative contribution of volume at each touch. Set to 0 to ignore volume. |

### Break Confirmation & Role Flips

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Closes Beyond to Confirm a Break` | 2 | Number of consecutive closes required beyond the level before it is considered broken. Reduces false breaks from wicky candles. |
| `Score Boost for Flipped Levels` | 1.50 | Multiplier applied to the strength score of a level that has flipped roles (support ↔ resistance). |

### Zones & Merging

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Draw Zones` | true | Draw levels as filled rectangles (zone width = wick cluster range). When off, draws a single horizontal line at the centroid price. |
| `Merge Levels Sharing the Same Candles` | true | Drop weaker levels whose touch candles significantly overlap a stronger level's touch candles. |
| `Shared-Candle Overlap Threshold (%)` | 60.0 | Minimum overlap percentage before a weaker level is merged into a stronger one. |

### Relevance Filter

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Only Show Levels Near Price` | true | When on, levels farther than `Max Distance From Price` are hidden. |
| `Max Distance From Price (x ATR)` | 20.0 | Maximum allowed distance from the current price, expressed as a multiple of ATR. |

### Tolerances — ATR-Scaled (default)

When `Scale Distances by ATR` is on, all distance parameters adapt automatically to the symbol's volatility and timeframe.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Scale Distances by ATR` | true | Master switch. When on, cluster/separation/gap distances are multiples of ATR. When off, fixed Points values are used instead. |
| `ATR Period` | 14 | Lookback period for the ATR calculation. |
| `Cluster Tolerance (x ATR)` | 0.25 | Candidates within this distance are grouped into the same zone. |
| `Min Move-Away Between Touches (x ATR)` | 0.50 | Price must move away by at least this distance before a return visit counts as a new touch. |
| `Min Distance Between Lines (x ATR)` | 1.00 | Proximity filter — a weaker level closer than this to a stronger one is dropped. |

### Tolerances — Fixed Points (used when ATR scaling is off)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Min Move-Away Between Touches (Points)` | 50.0 | Fixed-point version of the touch separation distance. |
| `Min Distance Between Lines (Points)` | 100.0 | Fixed-point minimum gap between drawn levels. |
| `Cluster Tolerance (Points)` | 10.0 | Fixed-point cluster merge distance. |

### Appearance

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Scale Width/Shade by Strength` | true | When on, stronger levels are drawn with a wider line and a more opaque zone fill. |
| `Support Color` | DeepSkyBlue | Color for support zones/lines. |
| `Resistance Color` | Tomato | Color for resistance zones/lines. |
| `Line Style` | Solid | Line style (Solid, Dash, Dot, etc.). |
| `Line Width` | 2 | Base line width in pixels (scaled up for stronger levels when `ScaleByStrength` is on). |

---

## Files

| File | Description |
|------|-------------|
| `SRLines.mq5` | Full MQL5 source code. |
| `SRLines.ex5` | Pre-compiled MT5 binary — drag-and-drop install, no compilation required. |

---

## License

MIT License — free to use, modify, and distribute.
