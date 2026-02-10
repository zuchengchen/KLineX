# KLineX Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a local TradingView-like charting app with Julia backend + browser frontend for Binance futures data.

**Architecture:** Julia (Oxygen.jl) serves REST API + static files. Frontend uses TradingView Lightweight Charts v5. SQLite stores kline data locally. Indicators computed in pure Julia.

**Tech Stack:** Julia (Oxygen.jl, HTTP.jl, JSON3.jl, SQLite.jl, DataFrames.jl), Vanilla JS, TradingView Lightweight Charts v5, SQLite

---

## Task 1: Julia Project Scaffold

**Files:**
- Create: `Project.toml`
- Create: `src/KLineX.jl`
- Create: `src/types.jl`

**Step 1: Initialize Julia project**

Run:
```bash
cd /home/czc/projects/working/stock/KLineX
julia -e 'using Pkg; Pkg.activate("."); Pkg.add(["Oxygen", "HTTP", "JSON3", "SQLite", "DataFrames", "DefaultApplication"])'
```
Expected: Project.toml and Manifest.toml created with all deps.

**Step 2: Create types.jl**

```julia
# src/types.jl
module Types

using StructTypes

struct SymbolInfo
    symbol::String
    base_asset::String
    quote_asset::String
    contract_type::String
    status::String
end
StructTypes.StructType(::Type{SymbolInfo}) = StructTypes.Struct()

struct Kline
    open_time::Int64
    open::Float64
    high::Float64
    low::Float64
    close::Float64
    volume::Float64
    close_time::Int64
    quote_volume::Float64
    trades::Int64
end

struct IndicatorPoint
    time::Int64
    value::Union{Float64,Nothing}
end

end # module
```

**Step 3: Create main module KLineX.jl**

```julia
# src/KLineX.jl
module KLineX

using Oxygen, HTTP, JSON3, SQLite, DataFrames, DefaultApplication

include("types.jl")
include("db.jl")
include("binance.jl")
include("indicators.jl")
include("server.jl")

function start(; port::Int=8888, open_browser::Bool=true)
    DB.init()
    println("KLineX server starting on http://localhost:$port")
    if open_browser
        @async begin
            sleep(1)
            DefaultApplication.open("http://localhost:$port")
        end
    end
    Server.setup(port)
end

end # module
```

**Step 4: Verify project loads**

Run:
```bash
julia --project=. -e "using Pkg; Pkg.instantiate(); println(\"OK\")"
```
Expected: "OK" printed, no errors.

**Step 5: Commit**

```bash
git add Project.toml Manifest.toml src/KLineX.jl src/types.jl
git commit -m "feat: initialize Julia project with dependencies and type definitions"
```

---

## Task 2: SQLite Data Layer

**Files:**
- Create: `src/db.jl`

**Step 1: Create db.jl**

```julia
# src/db.jl
module DB

using SQLite, DataFrames

const DB_PATH = joinpath(@__DIR__, "..", "data", "klinex.db")
const _db = Ref{SQLite.DB}()

function get_db()
    if !isassigned(_db)
        mkpath(dirname(DB_PATH))
        _db[] = SQLite.DB(DB_PATH)
    end
    return _db[]
end

function init()
    db = get_db()
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS symbols (
            symbol        TEXT PRIMARY KEY,
            base_asset    TEXT NOT NULL,
            quote_asset   TEXT NOT NULL,
            contract_type TEXT DEFAULT '',
            status        TEXT DEFAULT '',
            updated_at    INTEGER DEFAULT 0
        )
    """)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS klines (
            symbol       TEXT    NOT NULL,
            interval     TEXT    NOT NULL,
            open_time    INTEGER NOT NULL,
            open         REAL    NOT NULL,
            high         REAL    NOT NULL,
            low          REAL    NOT NULL,
            close        REAL    NOT NULL,
            volume       REAL    NOT NULL,
            close_time   INTEGER NOT NULL,
            quote_volume REAL    DEFAULT 0,
            trades       INTEGER DEFAULT 0,
            PRIMARY KEY (symbol, interval, open_time)
        )
    """)
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_klines_lookup
        ON klines(symbol, interval, open_time)
    """)
    println("Database initialized at $DB_PATH")
end

function upsert_symbols(symbols::Vector)
    db = get_db()
    stmt = DBInterface.prepare(db, """
        INSERT OR REPLACE INTO symbols (symbol, base_asset, quote_asset, contract_type, status, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
    """)
    for s in symbols
        DBInterface.execute(stmt, (s.symbol, s.base_asset, s.quote_asset, s.contract_type, s.status, round(Int64, time() * 1000)))
    end
end

function search_symbols(query::String; limit::Int=20)
    db = get_db()
    q = "%$(uppercase(query))%"
    result = DBInterface.execute(db, """
        SELECT symbol, base_asset, quote_asset, contract_type, status
        FROM symbols WHERE symbol LIKE ? AND status = 'TRADING'
        ORDER BY symbol LIMIT ?
    """, (q, limit))
    return DataFrame(result)
end

function get_kline_range(symbol::String, interval::String)
    db = get_db()
    result = DBInterface.execute(db, """
        SELECT MIN(open_time) as min_time, MAX(open_time) as max_time
        FROM klines WHERE symbol = ? AND interval = ?
    """, (symbol, interval)) |> DataFrame
    if nrow(result) == 0 || ismissing(result[1, :min_time])
        return nothing
    end
    return (min_time=result[1, :min_time], max_time=result[1, :max_time])
end

function upsert_klines(symbol::String, interval::String, klines::Vector)
    db = get_db()
    stmt = DBInterface.prepare(db, """
        INSERT OR REPLACE INTO klines
        (symbol, interval, open_time, open, high, low, close, volume, close_time, quote_volume, trades)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """)
    for k in klines
        DBInterface.execute(stmt, (
            symbol, interval,
            k[1],                          # open_time
            parse(Float64, string(k[2])),  # open
            parse(Float64, string(k[3])),  # high
            parse(Float64, string(k[4])),  # low
            parse(Float64, string(k[5])),  # close
            parse(Float64, string(k[6])),  # volume
            k[7],                          # close_time
            parse(Float64, string(k[8])),  # quote_volume
            k[9]                           # trades
        ))
    end
end

function get_klines(symbol::String, interval::String; start_time::Union{Int64,Nothing}=nothing, end_time::Union{Int64,Nothing}=nothing)
    db = get_db()
    query = "SELECT open_time, open, high, low, close, volume, close_time, quote_volume, trades FROM klines WHERE symbol = ? AND interval = ?"
    params = Any[symbol, interval]
    if !isnothing(start_time)
        query *= " AND open_time >= ?"
        push!(params, start_time)
    end
    if !isnothing(end_time)
        query *= " AND open_time <= ?"
        push!(params, end_time)
    end
    query *= " ORDER BY open_time ASC"
    return DBInterface.execute(db, query, params) |> DataFrame
end

end # module
```

**Step 2: Verify db module compiles**

Run:
```bash
julia --project=. -e "include(\"src/types.jl\"); include(\"src/db.jl\"); DB.init(); println(\"DB OK\")"
```
Expected: "Database initialized" + "DB OK"

**Step 3: Commit**

```bash
git add src/db.jl
git commit -m "feat: add SQLite data layer with kline and symbol storage"
```

---

## Task 3: Binance API Client

**Files:**
- Create: `src/binance.jl`

**Step 1: Create binance.jl**

```julia
# src/binance.jl
module Binance

using HTTP, JSON3

const FAPI_BASE = "https://fapi.binance.com"
const KLINE_URL = "$FAPI_BASE/fapi/v1/klines"
const EXCHANGE_INFO_URL = "$FAPI_BASE/fapi/v1/exchangeInfo"

function fetch_exchange_info()
    resp = HTTP.get(EXCHANGE_INFO_URL; retry=true, retries=3)
    data = JSON3.read(String(resp.body))
    symbols = []
    for s in data.symbols
        push!(symbols, (
            symbol=string(s.symbol),
            base_asset=string(s.baseAsset),
            quote_asset=string(s.quoteAsset),
            contract_type=string(get(s, :contractType, "")),
            status=string(s.status)
        ))
    end
    return symbols
end

function fetch_klines(symbol::String, interval::String; start_time::Union{Int64,Nothing}=nothing, end_time::Union{Int64,Nothing}=nothing, limit::Int=1500)
    params = Dict{String,String}(
        "symbol" => symbol,
        "interval" => interval,
        "limit" => string(limit)
    )
    if !isnothing(start_time)
        params["startTime"] = string(start_time)
    end
    if !isnothing(end_time)
        params["endTime"] = string(end_time)
    end
    resp = HTTP.get(KLINE_URL; query=params, retry=true, retries=3)
    return JSON3.read(String(resp.body))
end

function download_klines_range(symbol::String, interval::String, start_ms::Int64, end_ms::Int64; on_batch=nothing)
    all_klines = []
    current_start = start_ms
    while current_start < end_ms
        batch = fetch_klines(symbol, interval; start_time=current_start, end_time=end_ms)
        isempty(batch) && break
        append!(all_klines, batch)
        if !isnothing(on_batch)
            on_batch(length(all_klines))
        end
        # Next batch starts after last candle's close_time
        current_start = batch[end][7] + 1
        length(batch) < 1500 && break
        sleep(0.1)  # Rate limit respect
    end
    return all_klines
end

end # module
```

**Step 2: Verify binance module compiles**

Run:
```bash
julia --project=. -e "include(\"src/binance.jl\"); println(\"Binance module OK\")"
```
Expected: "Binance module OK"

**Step 3: Commit**

```bash
git add src/binance.jl
git commit -m "feat: add Binance API client for kline and symbol data"
```

---

## Task 4: Indicator Engine

**Files:**
- Create: `src/indicators.jl`

**Step 1: Create indicators.jl with all 6 indicators**

```julia
# src/indicators.jl
module Indicators

"""EMA - Exponential Moving Average"""
function ema(close::Vector{Float64}, period::Int)
    n = length(close)
    result = Vector{Union{Float64,Nothing}}(nothing, n)
    period > n && return result
    # First EMA value = SMA of first `period` values
    result[period] = sum(close[1:period]) / period
    multiplier = 2.0 / (period + 1)
    for i in (period+1):n
        result[i] = close[i] * multiplier + result[i-1] * (1 - multiplier)
    end
    return result
end

"""SMA - Simple Moving Average"""
function sma(close::Vector{Float64}, period::Int)
    n = length(close)
    result = Vector{Union{Float64,Nothing}}(nothing, n)
    period > n && return result
    # Running sum for efficiency
    s = sum(close[1:period])
    result[period] = s / period
    for i in (period+1):n
        s += close[i] - close[i-period]
        result[i] = s / period
    end
    return result
end

"""MACD - Moving Average Convergence Divergence"""
function macd(close::Vector{Float64}, fast::Int=12, slow::Int=26, signal_period::Int=9)
    ema_fast = ema(close, fast)
    ema_slow = ema(close, slow)
    n = length(close)
    macd_line = Vector{Union{Float64,Nothing}}(nothing, n)
    for i in 1:n
        if !isnothing(ema_fast[i]) && !isnothing(ema_slow[i])
            macd_line[i] = ema_fast[i] - ema_slow[i]
        end
    end
    # Compute signal line as EMA of MACD line
    # Find first non-nothing index
    first_valid = findfirst(!isnothing, macd_line)
    isnothing(first_valid) && return (macd=macd_line, signal=macd_line, histogram=macd_line)
    valid_macd = Float64[v for v in macd_line[first_valid:end] if !isnothing(v)]
    signal_raw = ema(valid_macd, signal_period)
    signal_line = Vector{Union{Float64,Nothing}}(nothing, n)
    histogram = Vector{Union{Float64,Nothing}}(nothing, n)
    j = 1
    for i in first_valid:n
        if !isnothing(macd_line[i])
            signal_line[i] = signal_raw[j]
            if !isnothing(signal_raw[j])
                histogram[i] = macd_line[i] - signal_raw[j]
            end
            j += 1
        end
    end
    return (macd=macd_line, signal=signal_line, histogram=histogram)
end

"""RSI - Relative Strength Index"""
function rsi(close::Vector{Float64}, period::Int=14)
    n = length(close)
    result = Vector{Union{Float64,Nothing}}(nothing, n)
    period >= n && return result
    gains = 0.0
    losses = 0.0
    for i in 2:(period+1)
        diff = close[i] - close[i-1]
        if diff >= 0
            gains += diff
        else
            losses -= diff
        end
    end
    avg_gain = gains / period
    avg_loss = losses / period
    if avg_loss == 0
        result[period+1] = 100.0
    else
        rs = avg_gain / avg_loss
        result[period+1] = 100.0 - 100.0 / (1.0 + rs)
    end
    for i in (period+2):n
        diff = close[i] - close[i-1]
        gain = diff >= 0 ? diff : 0.0
        loss = diff < 0 ? -diff : 0.0
        avg_gain = (avg_gain * (period - 1) + gain) / period
        avg_loss = (avg_loss * (period - 1) + loss) / period
        if avg_loss == 0
            result[i] = 100.0
        else
            rs = avg_gain / avg_loss
            result[i] = 100.0 - 100.0 / (1.0 + rs)
        end
    end
    return result
end

"""CCI - Commodity Channel Index"""
function cci(high::Vector{Float64}, low::Vector{Float64}, close::Vector{Float64}, period::Int=20)
    n = length(close)
    result = Vector{Union{Float64,Nothing}}(nothing, n)
    period > n && return result
    tp = (high .+ low .+ close) ./ 3.0
    for i in period:n
        window = tp[(i-period+1):i]
        mean_tp = sum(window) / period
        mean_dev = sum(abs.(window .- mean_tp)) / period
        if mean_dev == 0
            result[i] = 0.0
        else
            result[i] = (tp[i] - mean_tp) / (0.015 * mean_dev)
        end
    end
    return result
end

"""BOLL - Bollinger Bands"""
function boll(close::Vector{Float64}, period::Int=20, mult::Float64=2.0)
    n = length(close)
    middle = sma(close, period)
    upper = Vector{Union{Float64,Nothing}}(nothing, n)
    lower = Vector{Union{Float64,Nothing}}(nothing, n)
    for i in period:n
        if !isnothing(middle[i])
            window = close[(i-period+1):i]
            std_dev = sqrt(sum((window .- middle[i]).^2) / period)
            upper[i] = middle[i] + mult * std_dev
            lower[i] = middle[i] - mult * std_dev
        end
    end
    return (upper=upper, middle=middle, lower=lower)
end

"""Parse indicator spec string like 'ema:20' or 'macd:12:26:9'"""
function compute(name::String, params::Vector{String}, close::Vector{Float64};
                 high::Vector{Float64}=Float64[], low::Vector{Float64}=Float64[],
                 times::Vector{Int64}=Int64[])
    n = length(close)
    to_points(vals) = [(time=times[i], value=vals[i]) for i in 1:n if !isnothing(vals[i])]

    if name == "ema"
        period = parse(Int, params[1])
        return Dict("type" => "overlay", "data" => to_points(ema(close, period)))
    elseif name == "sma"
        period = parse(Int, params[1])
        return Dict("type" => "overlay", "data" => to_points(sma(close, period)))
    elseif name == "macd"
        fast = parse(Int, params[1])
        slow = parse(Int, params[2])
        sig = parse(Int, params[3])
        m = macd(close, fast, slow, sig)
        return Dict("type" => "oscillator", "macd" => to_points(m.macd), "signal" => to_points(m.signal), "histogram" => to_points(m.histogram))
    elseif name == "rsi"
        period = parse(Int, params[1])
        return Dict("type" => "oscillator", "data" => to_points(rsi(close, period)))
    elseif name == "cci"
        period = parse(Int, params[1])
        return Dict("type" => "oscillator", "data" => to_points(cci(high, low, close, period)))
    elseif name == "boll"
        period = parse(Int, params[1])
        mult = parse(Float64, params[2])
        b = boll(close, period, mult)
        return Dict("type" => "overlay", "upper" => to_points(b.upper), "middle" => to_points(b.middle), "lower" => to_points(b.lower))
    else
        error("Unknown indicator: $name")
    end
end

end # module
```

**Step 2: Verify indicators compile and compute correctly**

Run:
```bash
julia --project=. -e "
include(\"src/indicators.jl\")
close = Float64[i + sin(i/10)*5 for i in 1:100]
e = Indicators.ema(close, 20)
println(\"EMA[20]: \", e[20])
m = Indicators.macd(close, 12, 26, 9)
println(\"MACD computed: \", !isnothing(m.macd[26]))
r = Indicators.rsi(close, 14)
println(\"RSI[15]: \", r[15])
println(\"All indicators OK\")
"
```
Expected: Values printed, "All indicators OK"

**Step 3: Commit**

```bash
git add src/indicators.jl
git commit -m "feat: add pure Julia indicator engine (EMA, SMA, MACD, RSI, CCI, BOLL)"
```

---

## Task 5: HTTP Server & API Routes

**Files:**
- Create: `src/server.jl`

**Step 1: Create server.jl**

```julia
# src/server.jl
module Server

using Oxygen, HTTP, JSON3, DataFrames
using ..DB, ..Binance, ..Indicators

function setup(port::Int)
    # Serve static files
    staticfiles(joinpath(@__DIR__, "..", "static"), "/")

    # --- Symbol endpoints ---

    @get "/api/symbols" function(req)
        params = queryparams(req)
        q = get(params, "q", "")
        if isempty(q)
            return json(Dict("symbols" => []))
        end
        df = DB.search_symbols(q)
        symbols = [Dict("symbol" => r.symbol, "base_asset" => r.base_asset, "quote_asset" => r.quote_asset) for r in eachrow(df)]
        return json(Dict("symbols" => symbols))
    end

    @get "/api/symbols/sync" function(req)
        try
            symbols = Binance.fetch_exchange_info()
            DB.upsert_symbols(symbols)
            return json(Dict("status" => "ok", "count" => length(symbols)))
        catch e
            return json(Dict("status" => "error", "message" => string(e)), status=500)
        end
    end

    # --- Kline endpoint ---

    @get "/api/klines" function(req)
        params = queryparams(req)
        symbol = get(params, "symbol", "")
        interval = get(params, "interval", "1h")
        isempty(symbol) && return json(Dict("error" => "symbol required"), status=400)

        # Default: last 500 candles worth of time
        now_ms = round(Int64, time() * 1000)
        interval_ms = interval_to_ms(interval)
        default_start = now_ms - 500 * interval_ms
        start_time = parse(Int64, get(params, "start", string(default_start)))
        end_time = parse(Int64, get(params, "end", string(now_ms)))

        # Check local cache and download missing ranges
        try
            ensure_klines(symbol, interval, start_time, end_time)
        catch e
            # If download fails, still try to return cached data
            @warn "Failed to download klines: $e"
        end

        df = DB.get_klines(symbol, interval; start_time=start_time, end_time=end_time)
        klines = [Dict(
            "time" => div(r.open_time, 1000),  # lightweight-charts expects seconds
            "open" => r.open, "high" => r.high, "low" => r.low, "close" => r.close,
            "volume" => r.volume
        ) for r in eachrow(df)]
        return json(Dict("klines" => klines, "count" => length(klines)))
    end

    # --- Indicator endpoint ---

    @get "/api/indicators" function(req)
        params = queryparams(req)
        symbol = get(params, "symbol", "")
        interval = get(params, "interval", "1h")
        indicators_str = get(params, "indicators", "")
        isempty(symbol) && return json(Dict("error" => "symbol required"), status=400)
        isempty(indicators_str) && return json(Dict("error" => "indicators required"), status=400)

        now_ms = round(Int64, time() * 1000)
        interval_ms = interval_to_ms(interval)
        default_start = now_ms - 500 * interval_ms
        start_time = parse(Int64, get(params, "start", string(default_start)))
        end_time = parse(Int64, get(params, "end", string(now_ms)))

        df = DB.get_klines(symbol, interval; start_time=start_time, end_time=end_time)
        nrow(df) == 0 && return json(Dict("error" => "no data available"), status=404)

        close = Float64.(df.close)
        high = Float64.(df.high)
        low = Float64.(df.low)
        times = Int64.(df.open_time)

        results = Dict{String,Any}()
        for spec in split(indicators_str, ",")
            parts = split(strip(spec), ":")
            name = string(parts[1])
            pars = String[string(p) for p in parts[2:end]]
            try
                results[spec] = Indicators.compute(name, pars, close; high=high, low=low, times=times)
            catch e
                results[spec] = Dict("error" => string(e))
            end
        end
        return json(results)
    end

    serve(port=port, host="0.0.0.0", async=false)
end

# --- Helper functions ---

function interval_to_ms(interval::String)
    unit = interval[end]
    val = parse(Int, interval[1:end-1])
    multipliers = Dict('m' => 60_000, 'h' => 3_600_000, 'd' => 86_400_000, 'w' => 604_800_000, 'M' => 2_592_000_000)
    return val * get(multipliers, unit, 60_000)
end

function ensure_klines(symbol::String, interval::String, start_ms::Int64, end_ms::Int64)
    existing = DB.get_kline_range(symbol, interval)
    if isnothing(existing)
        # No data at all, download everything
        klines = Binance.download_klines_range(symbol, interval, start_ms, end_ms)
        !isempty(klines) && DB.upsert_klines(symbol, interval, klines)
        return
    end
    # Download left gap
    if start_ms < existing.min_time
        klines = Binance.download_klines_range(symbol, interval, start_ms, existing.min_time - 1)
        !isempty(klines) && DB.upsert_klines(symbol, interval, klines)
    end
    # Download right gap
    if end_ms > existing.max_time
        klines = Binance.download_klines_range(symbol, interval, existing.max_time + 1, end_ms)
        !isempty(klines) && DB.upsert_klines(symbol, interval, klines)
    end
end

end # module
```

**Step 2: Verify server module compiles**

Run:
```bash
julia --project=. -e "
include(\"src/types.jl\")
include(\"src/db.jl\")
include(\"src/binance.jl\")
include(\"src/indicators.jl\")
include(\"src/server.jl\")
println(\"Server module OK\")
"
```
Expected: "Server module OK"

**Step 3: Commit**

```bash
git add src/server.jl
git commit -m "feat: add Oxygen.jl HTTP server with kline, symbol, and indicator API routes"
```

---

## Task 6: Frontend — HTML Shell & Dark Theme CSS

**Files:**
- Create: `static/index.html`
- Create: `static/css/style.css`

**Step 1: Create index.html**

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>KLineX</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
    <div id="app">
        <!-- Top bar -->
        <div class="toolbar">
            <div class="search-container">
                <input type="text" id="symbol-search" placeholder="Search symbol..." autocomplete="off">
                <div id="search-dropdown" class="dropdown hidden"></div>
            </div>
            <div class="current-symbol" id="current-symbol">BTCUSDT</div>
            <div class="interval-bar" id="interval-bar">
                <button class="interval-btn" data-interval="1m">1m</button>
                <button class="interval-btn" data-interval="5m">5m</button>
                <button class="interval-btn" data-interval="15m">15m</button>
                <button class="interval-btn active" data-interval="1h">1h</button>
                <button class="interval-btn" data-interval="4h">4h</button>
                <button class="interval-btn" data-interval="1d">1d</button>
            </div>
        </div>

        <!-- Chart container -->
        <div id="chart-container"></div>

        <!-- Bottom bar: indicators -->
        <div class="indicator-bar">
            <button id="add-indicator-btn" class="add-btn">+ Add Indicator</button>
            <div id="active-indicators" class="active-indicators"></div>
        </div>

        <!-- Indicator selection modal -->
        <div id="indicator-modal" class="modal hidden">
            <div class="modal-content">
                <div class="modal-header">
                    <h3>Add Indicator</h3>
                    <button class="modal-close" id="modal-close">&times;</button>
                </div>
                <div class="modal-body">
                    <h4>Trend (Overlay)</h4>
                    <div class="indicator-list">
                        <button class="indicator-option" data-indicator="ema" data-defaults="20">EMA</button>
                        <button class="indicator-option" data-indicator="sma" data-defaults="50">SMA</button>
                        <button class="indicator-option" data-indicator="boll" data-defaults="20:2">BOLL</button>
                    </div>
                    <h4>Oscillator (Sub-pane)</h4>
                    <div class="indicator-list">
                        <button class="indicator-option" data-indicator="macd" data-defaults="12:26:9">MACD</button>
                        <button class="indicator-option" data-indicator="rsi" data-defaults="14">RSI</button>
                        <button class="indicator-option" data-indicator="cci" data-defaults="20">CCI</button>
                    </div>
                </div>
            </div>
        </div>

        <!-- Parameter edit modal -->
        <div id="param-modal" class="modal hidden">
            <div class="modal-content">
                <div class="modal-header">
                    <h3 id="param-modal-title">Parameters</h3>
                    <button class="modal-close" id="param-modal-close">&times;</button>
                </div>
                <div class="modal-body" id="param-modal-body"></div>
                <div class="modal-footer">
                    <button id="param-modal-ok" class="btn-primary">OK</button>
                </div>
            </div>
        </div>

        <!-- Status bar -->
        <div class="status-bar" id="status-bar">Ready</div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/lightweight-charts@5.1.0/dist/lightweight-charts.standalone.production.js"></script>
    <script src="/js/api.js"></script>
    <script src="/js/chart.js"></script>
    <script src="/js/search.js"></script>
    <script src="/js/indicators.js"></script>
    <script src="/js/app.js"></script>
</body>
</html>
```

**Step 2: Create style.css (dark theme)**

```css
/* static/css/style.css */
* { margin: 0; padding: 0; box-sizing: border-box; }

:root {
    --bg-primary: #1e222d;
    --bg-secondary: #2a2e39;
    --bg-tertiary: #363a45;
    --text-primary: #d1d4dc;
    --text-secondary: #787b86;
    --accent: #2962ff;
    --accent-hover: #1e53e5;
    --green: #26a69a;
    --red: #ef5350;
    --border: #434651;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg-primary);
    color: var(--text-primary);
    height: 100vh;
    overflow: hidden;
}

#app {
    display: flex;
    flex-direction: column;
    height: 100vh;
}

/* Toolbar */
.toolbar {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px 16px;
    background: var(--bg-secondary);
    border-bottom: 1px solid var(--border);
    z-index: 10;
}

.search-container { position: relative; }

#symbol-search {
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    color: var(--text-primary);
    padding: 6px 12px;
    border-radius: 4px;
    width: 180px;
    font-size: 13px;
    outline: none;
}
#symbol-search:focus { border-color: var(--accent); }

.dropdown {
    position: absolute;
    top: 100%;
    left: 0;
    width: 240px;
    max-height: 300px;
    overflow-y: auto;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: 4px;
    z-index: 100;
}
.dropdown.hidden { display: none; }
.dropdown-item {
    padding: 8px 12px;
    cursor: pointer;
    font-size: 13px;
}
.dropdown-item:hover { background: var(--bg-tertiary); }

.current-symbol {
    font-weight: 600;
    font-size: 15px;
    color: var(--text-primary);
    padding: 0 8px;
}

.interval-bar { display: flex; gap: 4px; }
.interval-btn {
    background: transparent;
    border: none;
    color: var(--text-secondary);
    padding: 6px 10px;
    border-radius: 4px;
    cursor: pointer;
    font-size: 13px;
}
.interval-btn:hover { background: var(--bg-tertiary); color: var(--text-primary); }
.interval-btn.active { background: var(--accent); color: #fff; }

/* Chart */
#chart-container { flex: 1; min-height: 0; }

/* Indicator bar */
.indicator-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 16px;
    background: var(--bg-secondary);
    border-top: 1px solid var(--border);
}
.add-btn {
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    color: var(--accent);
    padding: 4px 12px;
    border-radius: 4px;
    cursor: pointer;
    font-size: 12px;
}
.add-btn:hover { background: var(--border); }

.active-indicators { display: flex; gap: 6px; flex-wrap: wrap; }
.indicator-tag {
    display: flex;
    align-items: center;
    gap: 4px;
    background: var(--bg-tertiary);
    padding: 3px 8px;
    border-radius: 3px;
    font-size: 12px;
    cursor: pointer;
}
.indicator-tag:hover { background: var(--border); }
.indicator-tag .remove {
    color: var(--text-secondary);
    cursor: pointer;
    font-size: 14px;
    line-height: 1;
}
.indicator-tag .remove:hover { color: var(--red); }

/* Modal */
.modal {
    position: fixed;
    top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0,0,0,0.6);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
}
.modal.hidden { display: none; }
.modal-content {
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: 8px;
    min-width: 320px;
    max-width: 400px;
}
.modal-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border);
}
.modal-header h3 { font-size: 15px; }
.modal-close {
    background: none;
    border: none;
    color: var(--text-secondary);
    font-size: 20px;
    cursor: pointer;
}
.modal-body { padding: 16px; }
.modal-body h4 { font-size: 12px; color: var(--text-secondary); margin-bottom: 8px; margin-top: 12px; }
.modal-body h4:first-child { margin-top: 0; }
.modal-footer { padding: 12px 16px; border-top: 1px solid var(--border); text-align: right; }

.indicator-list { display: flex; gap: 8px; flex-wrap: wrap; }
.indicator-option {
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    color: var(--text-primary);
    padding: 8px 16px;
    border-radius: 4px;
    cursor: pointer;
    font-size: 13px;
}
.indicator-option:hover { border-color: var(--accent); color: var(--accent); }

.param-input {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 8px;
}
.param-input label { font-size: 13px; min-width: 80px; }
.param-input input {
    background: var(--bg-tertiary);
    border: 1px solid var(--border);
    color: var(--text-primary);
    padding: 6px 10px;
    border-radius: 4px;
    width: 80px;
    font-size: 13px;
    outline: none;
}
.btn-primary {
    background: var(--accent);
    border: none;
    color: #fff;
    padding: 6px 20px;
    border-radius: 4px;
    cursor: pointer;
    font-size: 13px;
}
.btn-primary:hover { background: var(--accent-hover); }

/* Status bar */
.status-bar {
    padding: 4px 16px;
    font-size: 11px;
    color: var(--text-secondary);
    background: var(--bg-secondary);
    border-top: 1px solid var(--border);
}
```

**Step 3: Verify files exist**

Run:
```bash
ls -la static/index.html static/css/style.css
```
Expected: Both files listed.

**Step 4: Commit**

```bash
git add static/
git commit -m "feat: add HTML shell and dark theme CSS for frontend"
```

---

## Task 7: Frontend — API Client & Chart Manager

**Files:**
- Create: `static/js/api.js`
- Create: `static/js/chart.js`

**Step 1: Create api.js**

```javascript
// static/js/api.js
const API = {
    async searchSymbols(query) {
        const resp = await fetch(`/api/symbols?q=${encodeURIComponent(query)}`);
        return resp.json();
    },

    async syncSymbols() {
        const resp = await fetch('/api/symbols/sync');
        return resp.json();
    },

    async getKlines(symbol, interval, start, end_) {
        let url = `/api/klines?symbol=${symbol}&interval=${interval}`;
        if (start) url += `&start=${start}`;
        if (end_) url += `&end=${end_}`;
        const resp = await fetch(url);
        return resp.json();
    },

    async getIndicators(symbol, interval, indicators, start, end_) {
        let url = `/api/indicators?symbol=${symbol}&interval=${interval}&indicators=${encodeURIComponent(indicators)}`;
        if (start) url += `&start=${start}`;
        if (end_) url += `&end=${end_}`;
        const resp = await fetch(url);
        return resp.json();
    }
};
```

**Step 2: Create chart.js**

```javascript
// static/js/chart.js
const ChartManager = {
    chart: null,
    candlestickSeries: null,
    volumeSeries: null,
    seriesMap: new Map(), // key: indicator spec, value: { series: [], paneIndex: number }
    nextPaneIndex: 1,

    init(container) {
        this.chart = LightweightCharts.createChart(container, {
            layout: {
                textColor: '#d1d4dc',
                background: { type: 'solid', color: '#1e222d' },
            },
            grid: {
                vertLines: { color: 'rgba(42, 46, 57, 0.5)' },
                horzLines: { color: 'rgba(42, 46, 57, 0.5)' },
            },
            crosshair: { mode: LightweightCharts.CrosshairMode.Normal },
            rightPriceScale: { borderColor: '#2a2e39' },
            timeScale: {
                borderColor: '#2a2e39',
                timeVisible: true,
                secondsVisible: false,
            },
        });

        this.candlestickSeries = this.chart.addSeries(
            LightweightCharts.CandlestickSeries,
            {
                upColor: '#26a69a',
                downColor: '#ef5350',
                borderVisible: false,
                wickUpColor: '#26a69a',
                wickDownColor: '#ef5350',
            }
        );

        this._handleResize(container);
    },

    setKlineData(klines) {
        this.candlestickSeries.setData(klines);
        this.chart.timeScale().fitContent();
    },

    addOverlaySeries(spec, data, color) {
        // Overlay: line series on main pane (pane 0)
        const series = this.chart.addSeries(
            LightweightCharts.LineSeries,
            { color: color, lineWidth: 2, title: spec },
            0
        );
        series.setData(data);
        return series;
    },

    addOverlayMulti(spec, dataMap, colors) {
        // For BOLL: upper, middle, lower on main pane
        const seriesList = [];
        for (const [key, data] of Object.entries(dataMap)) {
            const s = this.chart.addSeries(
                LightweightCharts.LineSeries,
                { color: colors[key] || '#888', lineWidth: 1, title: `${spec} ${key}` },
                0
            );
            s.setData(data);
            seriesList.push(s);
        }
        return seriesList;
    },

    addOscillatorSeries(spec, data, color) {
        const paneIndex = this.nextPaneIndex++;
        const series = this.chart.addSeries(
            LightweightCharts.LineSeries,
            { color: color, lineWidth: 2, title: spec },
            paneIndex
        );
        series.setData(data);
        return { series: [series], paneIndex };
    },

    addMACDSeries(spec, macdData, signalData, histogramData) {
        const paneIndex = this.nextPaneIndex++;
        const histSeries = this.chart.addSeries(
            LightweightCharts.HistogramSeries,
            { title: 'MACD Hist' },
            paneIndex
        );
        // Color histogram bars based on value
        const coloredHist = histogramData.map(d => ({
            ...d,
            color: d.value >= 0 ? 'rgba(38,166,154,0.6)' : 'rgba(239,83,80,0.6)'
        }));
        histSeries.setData(coloredHist);

        const macdSeries = this.chart.addSeries(
            LightweightCharts.LineSeries,
            { color: '#2962ff', lineWidth: 2, title: 'MACD' },
            paneIndex
        );
        macdSeries.setData(macdData);

        const signalSeries = this.chart.addSeries(
            LightweightCharts.LineSeries,
            { color: '#ff6d00', lineWidth: 2, title: 'Signal' },
            paneIndex
        );
        signalSeries.setData(signalData);

        return { series: [histSeries, macdSeries, signalSeries], paneIndex };
    },

    removeIndicator(spec) {
        const entry = this.seriesMap.get(spec);
        if (!entry) return;
        for (const s of entry.series) {
            this.chart.removeSeries(s);
        }
        this.seriesMap.delete(spec);
        // Recalculate pane indices
        this._recalcPanes();
    },

    clearAllIndicators() {
        for (const [spec, entry] of this.seriesMap) {
            for (const s of entry.series) {
                this.chart.removeSeries(s);
            }
        }
        this.seriesMap.clear();
        this.nextPaneIndex = 1;
    },

    _recalcPanes() {
        // After removing, reset nextPaneIndex to max used + 1
        let maxPane = 0;
        for (const entry of this.seriesMap.values()) {
            if (entry.paneIndex > maxPane) maxPane = entry.paneIndex;
        }
        this.nextPaneIndex = maxPane + 1;
    },

    _handleResize(container) {
        const observer = new ResizeObserver(entries => {
            for (const entry of entries) {
                const { width, height } = entry.contentRect;
                this.chart.applyOptions({ width, height });
            }
        });
        observer.observe(container);
    }
};
```

**Step 3: Commit**

```bash
git add static/js/api.js static/js/chart.js
git commit -m "feat: add frontend API client and chart manager with multi-pane support"
```

---

## Task 8: Frontend — Search, Indicators UI & App Entry

**Files:**
- Create: `static/js/search.js`
- Create: `static/js/indicators.js`
- Create: `static/js/app.js`

**Step 1: Create search.js**

```javascript
// static/js/search.js
const Search = {
    input: null,
    dropdown: null,
    debounceTimer: null,
    onSelect: null, // callback(symbol)

    init(onSelect) {
        this.input = document.getElementById('symbol-search');
        this.dropdown = document.getElementById('search-dropdown');
        this.onSelect = onSelect;

        this.input.addEventListener('input', () => {
            clearTimeout(this.debounceTimer);
            this.debounceTimer = setTimeout(() => this._search(), 300);
        });

        this.input.addEventListener('focus', () => {
            if (this.dropdown.children.length > 0) {
                this.dropdown.classList.remove('hidden');
            }
        });

        document.addEventListener('click', (e) => {
            if (!this.input.contains(e.target) && !this.dropdown.contains(e.target)) {
                this.dropdown.classList.add('hidden');
            }
        });
    },

    async _search() {
        const q = this.input.value.trim();
        if (q.length < 1) {
            this.dropdown.classList.add('hidden');
            return;
        }
        const data = await API.searchSymbols(q);
        this.dropdown.innerHTML = '';
        if (data.symbols && data.symbols.length > 0) {
            for (const s of data.symbols) {
                const div = document.createElement('div');
                div.className = 'dropdown-item';
                div.textContent = `${s.symbol} (${s.base_asset}/${s.quote_asset})`;
                div.addEventListener('click', () => {
                    this.input.value = '';
                    this.dropdown.classList.add('hidden');
                    if (this.onSelect) this.onSelect(s.symbol);
                });
                this.dropdown.appendChild(div);
            }
            this.dropdown.classList.remove('hidden');
        } else {
            this.dropdown.classList.add('hidden');
        }
    }
};
```

**Step 2: Create indicators.js**

```javascript
// static/js/indicators.js
const INDICATOR_COLORS = {
    ema: '#2962ff',
    sma: '#ff9800',
    boll: { upper: '#787b86', middle: '#ff9800', lower: '#787b86' },
    macd: '#2962ff',
    rsi: '#7b1fa2',
    cci: '#00897b',
};

const INDICATOR_PARAMS = {
    ema: [{ name: 'Period', key: 'period', default: 20 }],
    sma: [{ name: 'Period', key: 'period', default: 50 }],
    boll: [{ name: 'Period', key: 'period', default: 20 }, { name: 'StdDev', key: 'mult', default: 2 }],
    macd: [{ name: 'Fast', key: 'fast', default: 12 }, { name: 'Slow', key: 'slow', default: 26 }, { name: 'Signal', key: 'signal', default: 9 }],
    rsi: [{ name: 'Period', key: 'period', default: 14 }],
    cci: [{ name: 'Period', key: 'period', default: 20 }],
};

const IndicatorUI = {
    activeIndicators: [], // [{spec: "ema:20", name: "ema", params: "20"}]
    onChanged: null, // callback()

    init(onChanged) {
        this.onChanged = onChanged;
        document.getElementById('add-indicator-btn').addEventListener('click', () => this._showModal());
        document.getElementById('modal-close').addEventListener('click', () => this._hideModal());
        document.getElementById('param-modal-close').addEventListener('click', () => this._hideParamModal());
        document.getElementById('indicator-modal').addEventListener('click', (e) => {
            if (e.target.id === 'indicator-modal') this._hideModal();
        });
        document.getElementById('param-modal').addEventListener('click', (e) => {
            if (e.target.id === 'param-modal') this._hideParamModal();
        });

        // Indicator option buttons
        document.querySelectorAll('.indicator-option').forEach(btn => {
            btn.addEventListener('click', () => {
                const name = btn.dataset.indicator;
                const defaults = btn.dataset.defaults;
                this._hideModal();
                this._showParamModal(name, defaults);
            });
        });
    },

    _showModal() { document.getElementById('indicator-modal').classList.remove('hidden'); },
    _hideModal() { document.getElementById('indicator-modal').classList.add('hidden'); },
    _hideParamModal() { document.getElementById('param-modal').classList.remove('hidden'); document.getElementById('param-modal').classList.add('hidden'); },

    _showParamModal(name, defaults) {
        const modal = document.getElementById('param-modal');
        const title = document.getElementById('param-modal-title');
        const body = document.getElementById('param-modal-body');
        title.textContent = name.toUpperCase() + ' Parameters';
        body.innerHTML = '';

        const paramDefs = INDICATOR_PARAMS[name];
        const defaultVals = defaults.split(':');
        paramDefs.forEach((p, i) => {
            const div = document.createElement('div');
            div.className = 'param-input';
            div.innerHTML = `<label>${p.name}</label><input type="number" id="param-${p.key}" value="${defaultVals[i] || p.default}">`;
            body.appendChild(div);
        });

        const okBtn = document.getElementById('param-modal-ok');
        const newOk = okBtn.cloneNode(true);
        okBtn.parentNode.replaceChild(newOk, okBtn);
        newOk.addEventListener('click', () => {
            const values = paramDefs.map(p => document.getElementById(`param-${p.key}`).value);
            const spec = `${name}:${values.join(':')}`;
            this._addIndicator(name, spec);
            modal.classList.add('hidden');
        });
        modal.classList.remove('hidden');
    },

    _addIndicator(name, spec) {
        // Prevent duplicates
        if (this.activeIndicators.find(i => i.spec === spec)) return;
        this.activeIndicators.push({ spec, name });
        this._renderTags();
        if (this.onChanged) this.onChanged();
    },

    removeIndicator(spec) {
        this.activeIndicators = this.activeIndicators.filter(i => i.spec !== spec);
        ChartManager.removeIndicator(spec);
        this._renderTags();
    },

    _renderTags() {
        const container = document.getElementById('active-indicators');
        container.innerHTML = '';
        for (const ind of this.activeIndicators) {
            const tag = document.createElement('div');
            tag.className = 'indicator-tag';
            tag.innerHTML = `<span class="label">${ind.spec}</span><span class="remove">&times;</span>`;
            tag.querySelector('.remove').addEventListener('click', (e) => {
                e.stopPropagation();
                this.removeIndicator(ind.spec);
            });
            // Double-click to edit params
            tag.querySelector('.label').addEventListener('dblclick', () => {
                const parts = ind.spec.split(':');
                const name = parts[0];
                const params = parts.slice(1).join(':');
                this.removeIndicator(ind.spec);
                this._showParamModal(name, params);
            });
            container.appendChild(tag);
        }
    },

    getActiveSpecs() {
        return this.activeIndicators.map(i => i.spec).join(',');
    }
};
```

**Step 3: Create app.js**

```javascript
// static/js/app.js
const App = {
    currentSymbol: 'BTCUSDT',
    currentInterval: '1h',

    async init() {
        // Init chart
        ChartManager.init(document.getElementById('chart-container'));

        // Init search
        Search.init((symbol) => {
            this.currentSymbol = symbol;
            document.getElementById('current-symbol').textContent = symbol;
            this.loadData();
        });

        // Init interval buttons
        document.querySelectorAll('.interval-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                document.querySelectorAll('.interval-btn').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                this.currentInterval = btn.dataset.interval;
                this.loadData();
            });
        });

        // Init indicators
        IndicatorUI.init(() => this.loadIndicators());

        // Sync symbols on first load
        this.setStatus('Syncing symbols from Binance...');
        try {
            await API.syncSymbols();
            this.setStatus('Symbols synced. Loading chart...');
        } catch (e) {
            this.setStatus('Failed to sync symbols (offline mode)');
        }

        // Load default chart
        await this.loadData();
    },

    async loadData() {
        this.setStatus(`Loading ${this.currentSymbol} ${this.currentInterval}...`);
        ChartManager.clearAllIndicators();
        IndicatorUI.activeIndicators = [];
        IndicatorUI._renderTags();

        try {
            const data = await API.getKlines(this.currentSymbol, this.currentInterval);
            if (data.klines && data.klines.length > 0) {
                ChartManager.setKlineData(data.klines);
                this.setStatus(`${this.currentSymbol} ${this.currentInterval} — ${data.count} candles`);
            } else {
                this.setStatus('No data available');
            }
        } catch (e) {
            this.setStatus(`Error: ${e.message}`);
        }
    },

    async loadIndicators() {
        const specs = IndicatorUI.getActiveSpecs();
        if (!specs) return;

        this.setStatus('Computing indicators...');
        try {
            const data = await API.getIndicators(this.currentSymbol, this.currentInterval, specs);
            // Clear existing indicator series and re-add all
            ChartManager.clearAllIndicators();

            for (const ind of IndicatorUI.activeIndicators) {
                const result = data[ind.spec];
                if (!result || result.error) continue;
                this._renderIndicator(ind.spec, ind.name, result);
            }
            this.setStatus(`${this.currentSymbol} ${this.currentInterval} — indicators loaded`);
        } catch (e) {
            this.setStatus(`Indicator error: ${e.message}`);
        }
    },

    _renderIndicator(spec, name, result) {
        let entry;
        if (name === 'ema' || name === 'sma') {
            const series = ChartManager.addOverlaySeries(spec, result.data, INDICATOR_COLORS[name]);
            entry = { series: [series], paneIndex: 0 };
        } else if (name === 'boll') {
            const seriesList = ChartManager.addOverlayMulti(spec, {
                upper: result.upper, middle: result.middle, lower: result.lower
            }, INDICATOR_COLORS.boll);
            entry = { series: seriesList, paneIndex: 0 };
        } else if (name === 'macd') {
            entry = ChartManager.addMACDSeries(spec, result.macd, result.signal, result.histogram);
        } else if (name === 'rsi' || name === 'cci') {
            entry = ChartManager.addOscillatorSeries(spec, result.data, INDICATOR_COLORS[name]);
        }
        if (entry) ChartManager.seriesMap.set(spec, entry);
    },

    setStatus(msg) {
        document.getElementById('status-bar').textContent = msg;
    }
};

// Boot
document.addEventListener('DOMContentLoaded', () => App.init());
```

**Step 4: Commit**

```bash
git add static/js/
git commit -m "feat: add search, indicator UI, and app entry point for frontend"
```

---

## Task 9: Integration Test & Polish

**Step 1: Update KLineX.jl to properly include modules**

Verify `src/KLineX.jl` includes all modules in correct order and the `start()` function works.

Run:
```bash
julia --project=. -e "
using KLineX
println(\"Module loaded successfully\")
"
```
Expected: "Module loaded successfully"

**Step 2: Start server and test manually**

Run:
```bash
julia --project=. -e "using KLineX; KLineX.start(port=8888, open_browser=false)" &
sleep 5
# Test API endpoints
curl -s http://localhost:8888/api/symbols/sync | head -c 200
curl -s "http://localhost:8888/api/symbols?q=BTC" | head -c 200
curl -s "http://localhost:8888/api/klines?symbol=BTCUSDT&interval=1h" | head -c 200
```
Expected: JSON responses from all endpoints.

**Step 3: Fix any issues found during testing**

**Step 4: Final commit**

```bash
git add -A
git commit -m "feat: KLineX v1 complete - local TradingView-like charting for Binance futures"
```

---

## Execution Order Summary

| Task | Description | Dependencies |
|------|-------------|-------------|
| 1 | Julia project scaffold + types | None |
| 2 | SQLite data layer | Task 1 |
| 3 | Binance API client | Task 1 |
| 4 | Indicator engine | Task 1 |
| 5 | HTTP server + API routes | Tasks 2, 3, 4 |
| 6 | Frontend HTML + CSS | None (parallel with 2-4) |
| 7 | Frontend API client + chart manager | Task 6 |
| 8 | Frontend search + indicators + app | Task 7 |
| 9 | Integration test + polish | All above |

**Parallelizable**: Tasks 2, 3, 4, 6 can run in parallel after Task 1.
