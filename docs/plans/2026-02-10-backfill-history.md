# Backfill All Historical Data Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** When a symbol is selected, automatically download all Binance Vision historical data for every interval in the background, with progress shown in the status bar.

**Architecture:** New `Backfill` module manages background `@async` tasks and status tracking. Two new API endpoints expose start/status. Frontend polls status every 2s and updates the status bar. Uses `@async` (not Threads) to avoid SQLite thread-safety issues — cooperative multitasking yields during HTTP I/O.

**Tech Stack:** Julia (Oxygen.jl, HTTP.jl, Dates), Vanilla JS (fetch, setInterval)

---

### Task 1: Create `src/backfill.jl` — Background Download Module

**Files:**
- Create: `src/backfill.jl`

**Step 1: Create the Backfill module**

```julia
# src/backfill.jl
module Backfill

using Dates
using ..DB, ..Binance

# All intervals to download, in priority order (current_interval goes first at runtime)
const ALL_INTERVALS = ["1d", "4h", "1h", "15m", "5m", "30m", "3m", "2h", "6h", "8h", "12h", "3d", "1w", "1M", "1m"]

# Binance Futures launch date (2019-09-08)
const FUTURES_LAUNCH_MS = Int64(1567900800000)

# Status for each symbol: symbol => Dict with keys:
#   "running" => Bool
#   "current_interval" => String (which interval is downloading now)
#   "current_month" => String (e.g. "2023-05")
#   "completed_intervals" => Int
#   "total_intervals" => Int
#   "error" => Union{String,Nothing}
#   "done" => Bool
const BACKFILL_STATUS = Dict{String,Dict{String,Any}}()

# Track running tasks to prevent duplicates
const _RUNNING_TASKS = Dict{String,Task}()

function start(symbol::String, current_interval::String)
    # If already running for this symbol, skip
    if haskey(_RUNNING_TASKS, symbol)
        task = _RUNNING_TASKS[symbol]
        if !istaskdone(task)
            return false
        end
    end

    # Build interval list: current_interval first, then the rest in priority order
    intervals = [current_interval]
    for iv in ALL_INTERVALS
        iv != current_interval && push!(intervals, iv)
    end

    # Initialize status
    BACKFILL_STATUS[symbol] = Dict{String,Any}(
        "running" => true,
        "current_interval" => "",
        "current_month" => "",
        "completed_intervals" => 0,
        "total_intervals" => length(intervals),
        "error" => nothing,
        "done" => false
    )

    # Launch background task
    _RUNNING_TASKS[symbol] = @async _worker(symbol, intervals)
    return true
end

function get_status(symbol::String)
    if !haskey(BACKFILL_STATUS, symbol)
        return Dict{String,Any}("running" => false, "done" => false)
    end
    return BACKFILL_STATUS[symbol]
end

function _worker(symbol::String, intervals::Vector{String})
    status = BACKFILL_STATUS[symbol]
    now_ms = round(Int64, time() * 1000)

    for (i, interval) in enumerate(intervals)
        status["current_interval"] = interval
        status["completed_intervals"] = i - 1

        try
            _backfill_interval(symbol, interval, now_ms, status)
        catch e
            @warn "Backfill error for $symbol $interval: $e"
            status["error"] = "Error on $interval: $(sprint(showerror, e))"
            # Continue with next interval despite error
        end

        yield()  # Cooperative yield between intervals
    end

    status["running"] = false
    status["done"] = true
    status["completed_intervals"] = status["total_intervals"]
    status["current_interval"] = ""
    status["current_month"] = ""
    @info "Backfill complete for $symbol"
end

function _backfill_interval(symbol::String, interval::String, now_ms::Int64, status::Dict{String,Any})
    existing = DB.get_kline_range(symbol, interval)

    if !isnothing(existing)
        # Check if we already have data from near the launch date
        # If min_time is within 30 days of launch, consider it complete on the left side
        need_before = existing.min_time > FUTURES_LAUNCH_MS + 30 * 86_400_000
        need_after = now_ms - existing.max_time > 2 * _interval_to_ms(interval)

        if !need_before && !need_after
            @info "Backfill skip $symbol $interval — already complete"
            return
        end

        # Download missing earlier data
        if need_before
            _download_and_store(symbol, interval, FUTURES_LAUNCH_MS, existing.min_time - 1, status)
        end

        # Download missing recent data
        if need_after
            _download_and_store(symbol, interval, existing.max_time + 1, now_ms, status)
        end
    else
        # No data at all — download everything
        _download_and_store(symbol, interval, FUTURES_LAUNCH_MS, now_ms, status)
    end
end

function _download_and_store(symbol::String, interval::String, start_ms::Int64, end_ms::Int64, status::Dict{String,Any})
    # Use Vision for bulk download with month-by-month status updates
    start_dt = unix2datetime(start_ms / 1000)
    end_dt = unix2datetime(end_ms / 1000)
    now_dt = now(UTC)
    cutoff = now_dt - Month(1)

    ym_start = (year(start_dt), month(start_dt))
    ym_end = (year(end_dt), month(end_dt))
    ym = ym_start

    while ym <= ym_end
        y, m = ym
        status["current_month"] = "$(lpad(y,4,'0'))-$(lpad(m,2,'0'))"
        month_dt = DateTime(y, m, 1)

        klines = []

        if month_dt < cutoff
            # Try monthly zip
            url = "$(Binance.VISION_BASE)/monthly/klines/$symbol/$interval/$symbol-$interval-$(lpad(y,4,'0'))-$(lpad(m,2,'0')).zip"
            result = Binance._download_vision_zip(url)
            if !isnothing(result)
                klines = result
            end
        end

        if isempty(klines)
            # Fall back to daily zips
            days_in = Dates.daysinmonth(y, m)
            for d in 1:days_in
                day_dt = DateTime(y, m, d)
                day_dt >= now_dt && break
                url = "$(Binance.VISION_BASE)/daily/klines/$symbol/$interval/$symbol-$interval-$(lpad(y,4,'0'))-$(lpad(m,2,'0'))-$(lpad(d,2,'0')).zip"
                result = Binance._download_vision_zip(url)
                if !isnothing(result)
                    append!(klines, result)
                end
                yield()  # Yield between daily downloads
            end
        end

        # Filter to requested range and store
        if !isempty(klines)
            filter!(k -> k[1] >= start_ms && k[1] <= end_ms, klines)
            if !isempty(klines)
                DB.upsert_klines(symbol, interval, klines)
            end
        end

        ym = Binance._next_month(ym)
        yield()  # Yield between months
    end

    # Fill remaining gap with API (for very recent data)
    existing_after = DB.get_kline_range(symbol, interval)
    if !isnothing(existing_after)
        last_time = existing_after.max_time
        if last_time < end_ms
            status["current_month"] = "API (recent)"
            try
                api_klines = Binance.download_klines_range(symbol, interval, last_time + 1, end_ms)
                if !isempty(api_klines)
                    DB.upsert_klines(symbol, interval, api_klines)
                end
            catch e
                @warn "API backfill failed for $symbol $interval: $e"
            end
        end
    end
end

function _interval_to_ms(interval::String)
    unit = interval[end]
    val = parse(Int, interval[1:end-1])
    multipliers = Dict('m' => 60_000, 'h' => 3_600_000, 'd' => 86_400_000, 'w' => 604_800_000, 'M' => 2_592_000_000)
    return Int64(val * get(multipliers, unit, 60_000))
end

end # module
```

**Step 2: Commit**

```bash
git add src/backfill.jl
git commit -m "feat: add Backfill module for background historical data download"
```

---

### Task 2: Register Backfill module in `src/KLineX.jl`

**Files:**
- Modify: `src/KLineX.jl`

**Step 1: Add `include("backfill.jl")` after `indicators.jl` and before `server.jl`**

The line `include("backfill.jl")` must come after `db.jl` and `binance.jl` (since Backfill depends on DB and Binance), and before `server.jl` (since Server will use Backfill).

```julia
# src/KLineX.jl
module KLineX

using Oxygen, HTTP, JSON3, SQLite, DataFrames, DefaultApplication

include("types.jl")
include("db.jl")
include("binance.jl")
include("indicators.jl")
include("backfill.jl")
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

**Step 2: Commit**

```bash
git add src/KLineX.jl
git commit -m "feat: register Backfill module in KLineX"
```

---

### Task 3: Add backfill API routes in `src/server.jl`

**Files:**
- Modify: `src/server.jl`

**Step 1: Add `using ..Backfill` to the imports**

Change line 5 from:
```julia
using ..DB, ..Binance, ..Indicators
```
to:
```julia
using ..DB, ..Binance, ..Indicators, ..Backfill
```

**Step 2: Add two new routes before the `serve()` call (before line 95)**

Insert these routes after the `/api/indicators` route block and before `serve(...)`:

```julia
    @get "/api/backfill/start" function(req)
        params = queryparams(req)
        symbol = get(params, "symbol", "")
        current_interval = get(params, "current_interval", "1h")
        isempty(symbol) && return json(Dict("error" => "symbol required"), status=400)

        started = Backfill.start(symbol, current_interval)
        return json(Dict("status" => started ? "started" : "already_running"))
    end

    @get "/api/backfill/status" function(req)
        params = queryparams(req)
        symbol = get(params, "symbol", "")
        isempty(symbol) && return json(Dict("error" => "symbol required"), status=400)

        status = Backfill.get_status(symbol)
        return json(status)
    end
```

**Step 3: Commit**

```bash
git add src/server.jl
git commit -m "feat: add backfill start and status API endpoints"
```

---

### Task 4: Add backfill API methods in `static/js/api.js`

**Files:**
- Modify: `static/js/api.js`

**Step 1: Add two new methods to the API object, before the closing `};`**

```javascript
    async startBackfill(symbol, currentInterval) {
        return this._fetch(`/api/backfill/start?symbol=${encodeURIComponent(symbol)}&current_interval=${encodeURIComponent(currentInterval)}`);
    },

    async getBackfillStatus(symbol) {
        return this._fetch(`/api/backfill/status?symbol=${encodeURIComponent(symbol)}`);
    }
```

Note: The last existing method `getIndicators` needs a comma after its closing `}` since we're adding more methods. Actually, looking at the existing code, each method already ends with `},` — so just add the new methods before the closing `};`.

**Step 2: Commit**

```bash
git add static/js/api.js
git commit -m "feat: add backfill API client methods"
```

---

### Task 5: Update `static/js/app.js` — Trigger backfill and poll status

**Files:**
- Modify: `static/js/app.js`

**Step 1: Add backfill state and polling to the App object**

Add these properties after `currentInterval: '1h',`:

```javascript
    _backfillTimer: null,
    _backfillSymbol: null,
```

**Step 2: Add `_startBackfill` method**

Add this method to the App object:

```javascript
    _startBackfill(symbol) {
        // Stop previous polling
        if (this._backfillTimer) {
            clearInterval(this._backfillTimer);
            this._backfillTimer = null;
        }
        this._backfillSymbol = symbol;

        // Fire and forget — don't await
        API.startBackfill(symbol, this.currentInterval).catch(e => {
            console.warn('Backfill start failed:', e);
        });

        // Poll status every 2 seconds
        this._backfillTimer = setInterval(async () => {
            if (this._backfillSymbol !== symbol) {
                clearInterval(this._backfillTimer);
                return;
            }
            try {
                const status = await API.getBackfillStatus(symbol);
                if (!status.running && status.done) {
                    clearInterval(this._backfillTimer);
                    this._backfillTimer = null;
                    return;
                }
                if (status.running) {
                    const progress = `Backfill ${symbol}: ${status.current_interval} ${status.current_month || ''}... (${status.completed_intervals}/${status.total_intervals} intervals)`;
                    document.getElementById('status-bar').textContent = progress;
                }
            } catch (e) {
                // Silently ignore polling errors
            }
        }, 2000);
    },
```

**Step 3: Call `_startBackfill` in the symbol selection callback**

In the `init()` method, after `this.loadData();` inside the Search.init callback, add:

```javascript
            this._startBackfill(symbol);
```

So the callback becomes:
```javascript
        Search.init((symbol) => {
            this.currentSymbol = symbol;
            document.getElementById('current-symbol').textContent = symbol;
            this.loadData();
            this._startBackfill(symbol);
        });
```

**Step 4: Also trigger backfill on interval change**

In the interval button click handler, after `this.loadData();`, add:

```javascript
                this._startBackfill(this.currentSymbol);
```

This ensures switching intervals also triggers backfill (the backend will skip already-downloaded intervals).

**Step 5: Commit**

```bash
git add static/js/app.js
git commit -m "feat: trigger backfill on symbol select and poll progress in status bar"
```

---

### Task 6: Manual Verification

**Step 1: Verify module loads**

```bash
julia --project=. -e 'using KLineX; println("OK")'
```

Expected: `OK` (no errors)

**Step 2: Start server and test**

```bash
julia --project=. -e 'using KLineX; KLineX.start(port=8888, open_browser=false)'
```

Then in another terminal:
```bash
# Test backfill start
curl 'http://localhost:8888/api/backfill/start?symbol=BTCUSDT&current_interval=1h'
# Expected: {"status":"started"}

# Test backfill status (wait a few seconds)
curl 'http://localhost:8888/api/backfill/status?symbol=BTCUSDT'
# Expected: {"running":true,"current_interval":"1h","current_month":"2019-09",...}
```

**Step 3: Test in browser**

Open `http://localhost:8888`, search for a symbol, select it. Watch the status bar show backfill progress.
