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
    # Use Vision for bulk download with month-by-month status update
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
