# src/server.jl
module Server

using Oxygen, HTTP, JSON3, DataFrames
using ..DB, ..Binance, ..Indicators, ..Backfill

function setup(port::Int)
    staticfiles(joinpath(@__DIR__, "..", "static"), "/")

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
            @warn "Symbol sync failed: $e"
            return json(Dict("status" => "error", "message" => string(e)), status=500)
        end
    end

    @get "/api/klines" function(req)
        params = queryparams(req)
        symbol = get(params, "symbol", "")
        interval = get(params, "interval", "1h")
        isempty(symbol) && return json(Dict("error" => "symbol required"), status=400)

        now_ms = round(Int64, time() * 1000)
        interval_ms = interval_to_ms(interval)
        default_start = now_ms - 1500 * interval_ms
        start_time = parse(Int64, get(params, "start", string(default_start)))
        end_time = parse(Int64, get(params, "end", string(now_ms)))

        has_cache = has_cached_klines(symbol, interval, start_time, end_time)

        if has_cache
            # Have cached data — return immediately, download gaps in background
            ensure_klines_async(symbol, interval, start_time, end_time)
        else
            # No cache — must download synchronously
            try
                ensure_klines(symbol, interval, start_time, end_time)
            catch e
                @warn "Failed to download klines: $e"
            end
        end

        df = DB.get_klines(symbol, interval; start_time=start_time, end_time=end_time)
        expected_count = div(end_time - start_time, interval_ms) + 1
        is_complete = !has_cache || nrow(df) >= min(1400, round(Int, expected_count * 0.9))
        klines = [Dict(
            "time" => div(r.open_time, 1000),
            "open" => r.open, "high" => r.high, "low" => r.low, "close" => r.close,
            "volume" => r.volume
        ) for r in eachrow(df)]
        return json(Dict("klines" => klines, "count" => length(klines), "complete" => is_complete))
    end

    @get "/api/indicators" function(req)
        params = queryparams(req)
        symbol = get(params, "symbol", "")
        interval = get(params, "interval", "1h")
        indicators_str = get(params, "indicators", "")
        isempty(symbol) && return json(Dict("error" => "symbol required"), status=400)
        isempty(indicators_str) && return json(Dict("error" => "indicators required"), status=400)

        now_ms = round(Int64, time() * 1000)
        interval_ms = interval_to_ms(interval)
        default_start = now_ms - 1500 * interval_ms
        start_time = parse(Int64, get(params, "start", string(default_start)))
        end_time = parse(Int64, get(params, "end", string(now_ms)))

        df = DB.get_klines(symbol, interval; start_time=start_time, end_time=end_time)
        nrow(df) == 0 && return json(Dict("error" => "no data available"), status=404)

        close_prices = Float64.(df.close)
        high_prices = Float64.(df.high)
        low_prices = Float64.(df.low)
        times = Int64.(div.(df.open_time, 1000))

        results = Dict{String,Any}()
        for spec in split(indicators_str, ",")
            parts = split(strip(spec), ":")
            name = string(parts[1])
            pars = String[string(p) for p in parts[2:end]]
            try
                results[spec] = Indicators.compute(name, pars, close_prices; high=high_prices, low=low_prices, times=times)
            catch e
                results[spec] = Dict("error" => string(e))
            end
        end
        return json(results)
    end

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

    @get "/api/watchlist" function(req)
        user_id = get(req.headers, "X-User-ID", "default")
        symbols = DB.get_watchlist(user_id)
        return json(Dict("symbols" => collect(symbols)))
    end

    @post "/api/watchlist/add" function(req)
        user_id = get(req.headers, "X-User-ID", "default")
        body = JSON3.read(req.body)
        symbol = body["symbol"]
        DB.add_to_watchlist(user_id, symbol)
        return json(Dict("status" => "ok"))
    end

    @delete "/api/watchlist/remove/:symbol" function(req)
        user_id = get(req.headers, "X-User-ID", "default")
        symbol = req.params.symbol
        DB.remove_from_watchlist(user_id, symbol)
        return json(Dict("status" => "ok"))
    end

    serve(port=port, host="0.0.0.0", async=false)
end

function interval_to_ms(interval::String)
    unit = interval[end]
    val = parse(Int, interval[1:end-1])
    multipliers = Dict('m' => 60_000, 'h' => 3_600_000, 'd' => 86_400_000, 'w' => 604_800_000, 'M' => 2_592_000_000)
    return val * get(multipliers, unit, 60_000)
end

"""Check if we have ANY cached data overlapping with the requested range."""
function has_cached_klines(symbol::String, interval::String, start_ms::Int64, end_ms::Int64)::Bool
    existing = DB.get_kline_range(symbol, interval)
    isnothing(existing) && return false
    return existing.max_time >= start_ms && existing.min_time <= end_ms
end

"""Schedule kline download in background, return immediately."""
function ensure_klines_async(symbol::String, interval::String, start_ms::Int64, end_ms::Int64)
    @async try
        ensure_klines(symbol, interval, start_ms, end_ms)
    catch e
        @warn "Background kline download failed: $e"
    end
end

function ensure_klines(symbol::String, interval::String, start_ms::Int64, end_ms::Int64)
    existing = DB.get_kline_range(symbol, interval)
    if isnothing(existing)
        klines = _fetch_klines_with_vision(symbol, interval, start_ms, end_ms)
        !isempty(klines) && DB.upsert_klines(symbol, interval, klines)
        return
    end
    if start_ms < existing.min_time
        klines = _fetch_klines_with_vision(symbol, interval, start_ms, existing.min_time - 1)
        !isempty(klines) && DB.upsert_klines(symbol, interval, klines)
    end
    if end_ms > existing.max_time
        klines = _fetch_klines_with_vision(symbol, interval, existing.max_time + 1, end_ms)
        !isempty(klines) && DB.upsert_klines(symbol, interval, klines)
    end
end

function _fetch_klines_with_vision(symbol::String, interval::String, start_ms::Int64, end_ms::Int64)
    klines = try
        Binance.vision_download_range(symbol, interval, start_ms, end_ms)
    catch e
        @warn "Vision download failed, falling back to API: $e"
        []
    end
    if !isempty(klines)
        last_time = maximum(k[1] for k in klines)
        if last_time < end_ms
            api_klines = try
                Binance.download_klines_range(symbol, interval, last_time + 1, end_ms)
            catch; [] end
            append!(klines, api_klines)
        end
        return klines
    end
    return Binance.download_klines_range(symbol, interval, start_ms, end_ms)
end

end # module
