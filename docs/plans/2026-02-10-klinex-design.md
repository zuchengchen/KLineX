# KLineX Design Document

> Local TradingView-like charting application for Binance futures data.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Browser (Frontend)                 │
│  ┌───────────┐ ┌──────────┐ ┌────────────────────┐  │
│  │ Symbol     │ │ Interval │ │ Indicator Panel    │  │
│  │ Search     │ │ Selector │ │ (add/remove/config)│  │
│  └───────────┘ └──────────┘ └────────────────────┘  │
│  ┌─────────────────────────────────────────────────┐ │
│  │   TradingView Lightweight Charts v5             │ │
│  │   Main pane: Candlestick + overlay indicators   │ │
│  │   Sub-pane 1: MACD                              │ │
│  │   Sub-pane 2: RSI / CCI / etc.                  │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────┬──────────────────────────────────┘
                   │ HTTP REST API (JSON)
┌──────────────────▼──────────────────────────────────┐
│              Julia Backend (Oxygen.jl)               │
│  ┌──────────┐ ┌───────────┐ ┌────────────────────┐  │
│  │ API      │ │ Indicator │ │ Binance Client     │  │
│  │ Routes   │ │ Engine    │ │ (HTTP.jl)          │  │
│  └──────────┘ └───────────┘ └────────────────────┘  │
│  ┌─────────────────────────────────────────────────┐ │
│  │           SQLite Data Layer (SQLite.jl)          │ │
│  └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

**Tech stack:**
- Backend: Julia (Oxygen.jl, HTTP.jl, JSON3.jl, SQLite.jl, DataFrames.jl)
- Frontend: Vanilla JS + TradingView Lightweight Charts v5
- Storage: SQLite (single file, `data/klinex.db`)
- Data source: Binance Futures public API (no auth required)

## Data Model

### SQLite Schema

```sql
CREATE TABLE symbols (
    symbol        TEXT PRIMARY KEY,
    base_asset    TEXT NOT NULL,
    quote_asset   TEXT NOT NULL,
    contract_type TEXT,
    status        TEXT,
    updated_at    INTEGER
);

CREATE TABLE klines (
    symbol       TEXT    NOT NULL,
    interval     TEXT    NOT NULL,
    open_time    INTEGER NOT NULL,
    open         REAL    NOT NULL,
    high         REAL    NOT NULL,
    low          REAL    NOT NULL,
    close        REAL    NOT NULL,
    volume       REAL    NOT NULL,
    close_time   INTEGER NOT NULL,
    quote_volume REAL,
    trades       INTEGER,
    PRIMARY KEY (symbol, interval, open_time)
);

CREATE INDEX idx_klines_lookup ON klines(symbol, interval, open_time);
```

## REST API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/symbols?q=BTC` | Fuzzy search symbols, returns matching list |
| `GET` | `/api/symbols/sync` | Sync symbol list from Binance exchangeInfo |
| `GET` | `/api/klines?symbol=BTCUSDT&interval=1h&start=...&end=...` | Get kline data (auto-downloads missing ranges) |
| `GET` | `/api/indicators?symbol=BTCUSDT&interval=1h&indicators=ema:20,macd:12:26:9,rsi:14` | Compute and return indicator data |

### Indicator Parameter Format

| Indicator | Format | Example |
|-----------|--------|---------|
| EMA | `ema:<period>` | `ema:20` |
| SMA | `sma:<period>` | `sma:50` |
| MACD | `macd:<fast>:<slow>:<signal>` | `macd:12:26:9` |
| RSI | `rsi:<period>` | `rsi:14` |
| CCI | `cci:<period>` | `cci:20` |
| BOLL | `boll:<period>:<mult>` | `boll:20:2` |

### Indicator Response Format

```json
{
  "ema:20": [{"time": 1704067200, "value": 42150.5}, ...],
  "macd:12:26:9": {
    "macd": [{"time": ..., "value": ...}, ...],
    "signal": [{"time": ..., "value": ...}, ...],
    "histogram": [{"time": ..., "value": ...}, ...]
  },
  "boll:20:2": {
    "upper": [{"time": ..., "value": ...}, ...],
    "middle": [{"time": ..., "value": ...}, ...],
    "lower": [{"time": ..., "value": ...}, ...]
  }
}
```

### Indicator Rendering Rules

| Type | Indicators | Render Location |
|------|-----------|-----------------|
| Overlay | EMA, SMA, BOLL | Main chart pane (Line Series on top of candles) |
| Oscillator | MACD, RSI, CCI | Separate sub-pane (new Pane per indicator) |

## Frontend

### Page Layout

```
┌─────────────────────────────────────────────────────┐
│ [Search symbol...]  [BTCUSDT v]  [1m|5m|15m|1h|4h|1d] │
├─────────────────────────────────────────────────────┤
│                                                     │
│         Main chart: Candlestick + overlays          │
│         (EMA / SMA / BOLL drawn on main chart)      │
│                                                     │
├─────────────────────────────────────────────────────┤
│         Sub-pane 1: MACD                            │
├─────────────────────────────────────────────────────┤
│         Sub-pane 2: RSI                             │
├─────────────────────────────────────────────────────┤
│ [+ Add Indicator]  EMA(20) x | MACD x | RSI(14) x  │
└─────────────────────────────────────────────────────┘
```

### Interactions

1. **Search**: Input debounce 300ms → `GET /api/symbols?q=xxx` → dropdown select
2. **Switch interval**: Click interval button → re-fetch klines + indicators → redraw
3. **Add indicator**: Click [+ Add Indicator] → indicator list popup (categorized: Trend / Oscillator) → select → parameter dialog → confirm → fetch data → add to chart
4. **Remove indicator**: Click x on indicator tag → remove series/pane
5. **Edit indicator params**: Double-click indicator tag → parameter dialog → re-compute

### File Structure

```
static/
├── index.html
├── css/
│   └── style.css        # Dark theme
└── js/
    ├── app.js           # Entry point, chart init
    ├── api.js           # Backend API calls
    ├── chart.js         # Lightweight-charts wrapper (create/update/manage panes)
    ├── indicators.js    # Indicator UI management (add/remove/param edit)
    └── search.js        # Symbol search component
```

## Julia Backend

### Project Structure

```
KLineX/
├── Project.toml
├── src/
│   ├── KLineX.jl        # Main module, entry point
│   ├── server.jl         # Oxygen.jl route definitions
│   ├── binance.jl        # Binance API client
│   ├── db.jl             # SQLite data layer
│   ├── indicators.jl     # Indicator computation engine
│   └── types.jl          # Data type definitions
├── static/               # Frontend static files
├── data/
│   └── klinex.db         # SQLite database (auto-created at runtime)
└── README.md
```

### Dependencies

| Package | Purpose |
|---------|---------|
| Oxygen.jl | HTTP server + routing |
| HTTP.jl | Binance API requests |
| JSON3.jl | JSON serialization |
| SQLite.jl | Local data storage |
| DataFrames.jl | Data manipulation |
| DefaultApplication.jl | Auto-open browser on startup |

### Indicator Engine (Pure Julia)

All indicators implemented from scratch in Julia. No external indicator libraries.

```julia
module Indicators
    ema(close, period)                    → Vector{Union{Float64,Nothing}}
    sma(close, period)                    → Vector{Union{Float64,Nothing}}
    macd(close, fast, slow, signal)       → (macd, signal, histogram)
    rsi(close, period)                    → Vector{Union{Float64,Nothing}}
    cci(high, low, close, period)         → Vector{Union{Float64,Nothing}}
    boll(close, period, mult)             → (upper, middle, lower)
end
```

### Smart Incremental Download

```
Request: BTCUSDT 1h, last 30 days

1. Query SQLite for existing data range of this symbol+interval
   → e.g., already have Jan 5 ~ Jan 25

2. Compute gaps:
   Gap 1: Jan 1 ~ Jan 4  (left of existing range)
   Gap 2: Jan 26 ~ Feb 10 (right of existing range)

3. Download only gaps from Binance (paginated, 1500 per request)
   → Store into SQLite

4. Read full range from SQLite → return to frontend
```

### Startup Flow

```
1. julia --project=. -e "using KLineX; KLineX.start()"
2. Check data/klinex.db → create + init tables if missing
3. Fetch Binance exchangeInfo → populate symbols table
4. Start Oxygen HTTP server (serve static files + API)
5. Open browser → http://localhost:8888
```

## Error Handling

| Scenario | Handling |
|----------|----------|
| Binance API unreachable | Return local cached data + frontend shows "Offline mode, data up to xxx" |
| Symbol not found | Return 404 + clear error message |
| Rate limit hit | Auto sleep + retry, max 3 attempts |
| SQLite write conflict | `INSERT OR REPLACE` for idempotency |
| Invalid indicator params (e.g., period <= 0) | Return 400 + validation error |

## Performance

- **Kline volume**: 1-min candles for 1 year ≈ 525,600 rows. SQLite handles this easily.
- **Indicator computation**: Julia computes EMA over 500k rows in milliseconds. No need to cache indicator results.
- **Frontend rendering**: Lightweight-charts data conflation handles 100k+ candles at 60 FPS.
- **Large initial download**: Frontend shows download progress (backend returns estimated total, frontend polls progress).

## V1 Scope — What We Build

- [x] Symbol search (fuzzy match from Binance futures list)
- [x] Kline data download + local SQLite caching with incremental updates
- [x] Candlestick chart with TradingView Lightweight Charts
- [x] Interval switching (1m, 5m, 15m, 1h, 4h, 1d)
- [x] 6 built-in indicators: EMA, SMA, MACD, RSI, CCI, BOLL
- [x] Add/remove indicators with parameter configuration
- [x] Overlay indicators on main chart, oscillators in sub-panes
- [x] Dark theme UI
- [x] Offline mode (use cached data when network unavailable)

## V1 Scope — What We Don't Build (YAGNI)

| Feature | Reason |
|---------|--------|
| WebSocket real-time streaming | Core use case is historical data review |
| Drawing tools | Plugin support exists, defer to V2 |
| Multi-chart layout | Single chart sufficient for V1 |
| Custom indicator formulas | 6 built-in indicators cover common needs |
| User config persistence | Use defaults for V1, add localStorage later |
| Spot market data | Futures only (fapi) for V1 |

## Binance API Reference

- **Klines**: `GET https://fapi.binance.com/fapi/v1/klines` (max 1500 per request, no auth)
- **Exchange Info**: `GET https://fapi.binance.com/fapi/v1/exchangeInfo` (no auth)
- **Rate limit**: 2400 request weight/minute per IP
- **Intervals**: 1m, 3m, 5m, 15m, 30m, 1h, 2h, 4h, 6h, 8h, 12h, 1d, 3d, 1w, 1M
- **Kline response**: Array of [open_time, open, high, low, close, volume, close_time, quote_volume, trades, taker_buy_base_vol, taker_buy_quote_vol, ignore]
