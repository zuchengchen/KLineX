# AGENTS.md — KLineX

> Local TradingView-like charting app: Julia backend (Oxygen.jl) + Vanilla JS frontend + SQLite.

## Global Rules

- **Every file or code modification MUST be followed by a git commit** describing what was changed. Use conventional commit format (see Git Conventions below). Never batch unrelated changes into one commit.

## Build & Run Commands

```bash
# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Start the server (port 8888, opens browser)
julia --project=. -e 'using KLineX; KLineX.start()'

# Start without opening browser
julia --project=. -e 'using KLineX; KLineX.start(port=8888, open_browser=false)'

# Verify module loads
julia --project=. -e 'using KLineX; println("OK")'

# Verify a single submodule compiles
julia --project=. -e 'include("src/indicators.jl"); println("OK")'

# Test indicator computation manually
julia --project=. -e '
include("src/indicators.jl")
close = Float64[i + sin(i/10)*5 for i in 1:100]
println("EMA: ", Indicators.ema(close, 20)[20])
println("RSI: ", Indicators.rsi(close, 14)[15])
'
```

**No test framework is configured.** There are no automated tests. Verify changes by loading the module and testing manually.

**No linter or formatter is configured** for Julia or JavaScript.

## Project Structure

```
KLineX/
├── Project.toml              # Julia package manifest
├── Manifest.toml             # Locked dependency versions
├── src/
│   ├── KLineX.jl             # Main module — includes all submodules, exports start()
│   ├── types.jl              # Data types (SymbolInfo, Kline, IndicatorPoint)
│   ├── db.jl                 # SQLite data layer (DB module)
│   ├── binance.jl            # Binance Futures API client (Binance module)
│   ├── indicators.jl         # Pure Julia indicator engine (Indicators module)
│   └── server.jl             # Oxygen.jl HTTP server + API routes (Server module)
├── static/
│   ├── index.html            # Single-page HTML shell
│   ├── css/style.css         # Dark theme CSS (TradingView-inspired)
│   └── js/
│       ├── api.js            # Backend API client
│       ├── chart.js          # Lightweight Charts wrapper (ChartManager)
│       ├── search.js         # Symbol search with debounce (Search)
│       ├── indicators.js     # Indicator UI management (IndicatorUI)
│       ├── app.js            # App entry point, orchestrates everything
│       └── vendor/           # Vendored lightweight-charts v5
├── data/
│   └── klinex.db             # SQLite database (auto-created, gitignored)
└── docs/plans/               # Design and implementation plans
```

## Architecture

- **Backend**: Julia modules loaded via `include()` in `KLineX.jl`. Each file defines one module (`DB`, `Binance`, `Indicators`, `Server`). Modules reference each other with `using ..ModuleName`.
- **Frontend**: Vanilla JS with global objects (`API`, `ChartManager`, `Search`, `IndicatorUI`, `App`). No build step, no bundler. Scripts loaded in order via `<script>` tags in `index.html`.
- **Data flow**: Frontend → REST API (JSON) → Julia backend → SQLite cache + Binance API.

## Julia Code Style

### Module Pattern
Every `.jl` file in `src/` wraps its content in a module:
```julia
# src/example.jl
module Example
using SomeDep
# ... code ...
end # module
```

### Naming Conventions
- **Modules**: PascalCase (`DB`, `Binance`, `Indicators`, `Server`)
- **Functions**: snake_case (`fetch_klines`, `get_kline_range`, `upsert_symbols`)
- **Constants**: SCREAMING_SNAKE_CASE (`FAPI_BASE`, `KLINE_URL`, `DB_PATH`)
- **Types/Structs**: PascalCase (`SymbolInfo`, `Kline`, `IndicatorPoint`)
- **Variables**: snake_case (`all_klines`, `current_start`, `avg_gain`)
- **Private helpers**: prefixed with `_` (`_parse_vision_csv`, `_next_month`)

### Type Annotations
- Function arguments: always typed (`symbol::String`, `period::Int`)
- Return types: not annotated (Julia convention)
- Nullable values: `Union{Float64,Nothing}` or `Union{T,Nothing}`
- Use `Vector{Union{Float64,Nothing}}` for indicator result arrays

### Error Handling
- `try/catch` with `@warn` for non-fatal errors (network failures)
- `rethrow(e)` when cleanup is needed (DB transactions)
- Return graceful fallbacks when possible (empty arrays, cached data)
- API routes return JSON error responses with appropriate HTTP status codes

### Imports
- `using` for package imports at module top
- `using ..ModuleName` for sibling module references
- No `import` — always `using`

### Dependencies
Julia packages (in `Project.toml`): Oxygen, HTTP, JSON3, SQLite, DataFrames, DefaultApplication, StructTypes, ZipFile, Dates

## JavaScript Code Style

### Pattern
Global singleton objects with methods — no classes, no modules, no imports:
```javascript
const MyComponent = {
    state: null,
    init() { /* setup */ },
    _privateMethod() { /* internal */ },
    publicMethod() { /* external */ },
};
```

### Naming Conventions
- **Global objects**: PascalCase (`API`, `ChartManager`, `Search`, `IndicatorUI`, `App`)
- **Methods/functions**: camelCase (`loadData`, `setKlineData`, `getActiveSpecs`)
- **Private methods**: prefixed with `_` (`_search`, `_renderTags`, `_handleResize`)
- **Constants**: SCREAMING_SNAKE_CASE (`INDICATOR_COLORS`, `INDICATOR_PARAMS`, `INTERVAL_MS`)
- **DOM IDs**: kebab-case (`symbol-search`, `chart-container`, `add-indicator-btn`)
- **CSS classes**: kebab-case (`interval-btn`, `dropdown-item`, `indicator-tag`)

### Async Pattern
All API calls are `async/await`. Error handling with `try/catch`, status messages shown in the status bar.

### DOM Manipulation
Direct DOM API — `document.getElementById`, `document.createElement`, `classList.add/remove`. No jQuery, no framework.

## REST API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/symbols?q=BTC` | Search symbols (fuzzy match) |
| GET | `/api/symbols/sync` | Sync symbol list from Binance |
| GET | `/api/klines?symbol=X&interval=1h&start=...&end=...` | Get kline data (auto-downloads gaps) |
| GET | `/api/indicators?symbol=X&interval=1h&indicators=ema:20,rsi:14` | Compute indicators |

### Indicator Spec Format
`name:param1:param2:...` — e.g., `ema:20`, `macd:12:26:9`, `boll:20:2`

## Git Conventions

### Commit Format
Conventional commits. Every commit after a code change must describe what was modified:
```
<type>: <concise description of what changed>
```

### Types
- `feat:` — new feature or capability
- `fix:` — bug fix
- `refactor:` — code restructuring without behavior change
- `docs:` — documentation only
- `chore:` — maintenance, dependency updates

### Examples from History
```
feat: initialize Julia project with dependencies and type definitions
feat: add SQLite data layer with kline and symbol storage
feat: add Binance API client for kline and symbol data
feat: add pure Julia indicator engine (EMA, SMA, MACD, RSI, CCI, BOLL)
fix: bundle lightweight-charts locally, add error handling to API and init
```

### Commit Rule
**After every file or code modification, immediately create a git commit.** The commit message must clearly state what was changed and why. Do not accumulate uncommitted changes across multiple tasks.

## Key Implementation Details

- **Kline timestamps**: Binance returns milliseconds. Backend divides by 1000 for Lightweight Charts (expects seconds).
- **Incremental download**: `ensure_klines()` in `server.jl` checks SQLite for existing data range, only downloads gaps from Binance.
- **Vision data**: `binance.jl` tries Binance Vision (bulk CSV zips) first for historical data, falls back to REST API for recent data.
- **Indicator computation**: All indicators are pure Julia in `indicators.jl`. No external indicator libraries. Results use `Union{Float64,Nothing}` vectors where `nothing` = insufficient data.
- **Chart panes**: Overlay indicators (EMA, SMA, BOLL) render on pane 0 (main chart). Oscillators (MACD, RSI, CCI) each get a new sub-pane via `nextPaneIndex++`.
- **Infinite scroll**: `chart.js` subscribes to `visibleLogicalRangeChange` and triggers `_loadMore()` when user scrolls near the left edge.
