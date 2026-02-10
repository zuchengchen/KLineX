# src/binance.jl
module Binance

using HTTP, JSON3, ZipFile, Dates

const FAPI_BASE = "https://fapi.binance.com"
const KLINE_URL = "$FAPI_BASE/fapi/v1/klines"
const EXCHANGE_INFO_URL = "$FAPI_BASE/fapi/v1/exchangeInfo"
const VISION_BASE = "https://data.binance.vision/data/futures/um"

"""Custom exception for Binance rate limit (HTTP 418/429)."""
struct RateLimitError <: Exception
    retry_after::Int  # seconds to wait
    msg::String
end

"""
Extract retry-after seconds from an HTTP response or StatusError.
Falls back to 60s if header is missing.
"""
function _parse_retry_after(resp)
    for h in resp.headers
        if lowercase(first(h)) == "retry-after"
            val = tryparse(Int, last(h))
            return isnothing(val) ? 60 : val
        end
    end
    return 60
end

"""
Perform an HTTP GET with rate-limit awareness.
On 418/429: throws RateLimitError instead of blindly retrying.
Other errors: retries up to `retries` times with backoff.
"""
function _rate_limited_get(url::String; query=nothing, retries::Int=2)
    for attempt in 1:retries+1
        resp = HTTP.get(url; query=query, retry=false, status_exception=false,
                        connect_timeout=15, readtimeout=30)
        if resp.status == 418 || resp.status == 429
            retry_after = _parse_retry_after(resp)
            body_str = String(resp.body)
            throw(RateLimitError(retry_after, "Rate limited (HTTP $(resp.status)): $body_str"))
        end
        if resp.status >= 200 && resp.status < 300
            return resp
        end
        # Server error — retry with backoff
        if resp.status >= 500 && attempt <= retries
            sleep(1.0 * attempt)
            continue
        end
        # Client error (4xx) other than rate limit — don't retry
        error("Binance API error (HTTP $(resp.status)): $(String(resp.body))")
    end
end

function fetch_exchange_info()
    resp = _rate_limited_get(EXCHANGE_INFO_URL)
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
    resp = _rate_limited_get(KLINE_URL; query=params)
    return JSON3.read(String(resp.body))
end

const BATCH_SLEEP_SEC = 0.5  # delay between consecutive API calls
const MAX_RATE_LIMIT_RETRIES = 2  # max times to wait-and-retry on rate limit per batch

function download_klines_range(symbol::String, interval::String, start_ms::Int64, end_ms::Int64; on_batch=nothing)
    all_klines = []
    current_start = start_ms
    while current_start < end_ms
        batch = nothing
        for rl_attempt in 1:MAX_RATE_LIMIT_RETRIES+1
            try
                batch = fetch_klines(symbol, interval; start_time=current_start, end_time=end_ms)
                break
            catch e
                if e isa RateLimitError
                    if rl_attempt > MAX_RATE_LIMIT_RETRIES
                        @warn "Rate limited after $MAX_RATE_LIMIT_RETRIES retries, aborting batch download" retry_after=e.retry_after
                        rethrow(e)
                    end
                    wait_sec = e.retry_after + 5  # add buffer
                    @warn "Rate limited by Binance, waiting $(wait_sec)s before retry (attempt $rl_attempt/$MAX_RATE_LIMIT_RETRIES)" retry_after=e.retry_after
                    sleep(wait_sec)
                else
                    rethrow(e)
                end
            end
        end
        isnothing(batch) && break
        isempty(batch) && break
        append!(all_klines, batch)
        if !isnothing(on_batch)
            on_batch(length(all_klines))
        end
        current_start = batch[end][7] + 1
        length(batch) < 1500 && break
        sleep(BATCH_SLEEP_SEC)
    end
    return all_klines
end

function _parse_vision_csv(csv_text::String)
    klines = []
    for line in split(csv_text, '\n')
        stripped = strip(line)
        isempty(stripped) && continue
        startswith(stripped, "open_time") && continue
        cols = split(stripped, ',')
        length(cols) < 11 && continue
        try
            push!(klines, (
                parse(Int64, cols[1]),       # open_time
                parse(Float64, cols[2]),     # open
                parse(Float64, cols[3]),     # high
                parse(Float64, cols[4]),     # low
                parse(Float64, cols[5]),     # close
                parse(Float64, cols[6]),     # volume
                parse(Int64, cols[7]),       # close_time
                parse(Float64, cols[8]),     # quote_volume
                parse(Int, cols[9]),         # trades
            ))
        catch
            continue
        end
    end
    return klines
end

function _download_vision_zip(url::String)
    resp = try
        HTTP.get(url; retry=false, status_exception=false, connect_timeout=10, readtimeout=30)
    catch
        return nothing
    end
    resp.status != 200 && return nothing
    reader = ZipFile.Reader(IOBuffer(resp.body))
    csv_text = ""
    for f in reader.files
        if endswith(f.name, ".csv")
            csv_text = read(f, String)
            break
        end
    end
    close(reader)
    isempty(csv_text) ? nothing : _parse_vision_csv(csv_text)
end

function vision_download_range(symbol::String, interval::String, start_ms::Int64, end_ms::Int64)
    all_klines = []
    start_dt = unix2datetime(start_ms / 1000)
    end_dt = unix2datetime(end_ms / 1000)
    now_dt = now(UTC)
    cutoff = now_dt - Month(1)

    ym_start = (year(start_dt), month(start_dt))
    ym_end = (year(end_dt), month(end_dt))
    ym = ym_start
    while ym <= ym_end
        y, m = ym
        month_dt = DateTime(y, m, 1)
        if month_dt < cutoff
            url = "$VISION_BASE/monthly/klines/$symbol/$interval/$symbol-$interval-$(lpad(y,4,'0'))-$(lpad(m,2,'0')).zip"
            @info "Vision monthly: $url"
            klines = _download_vision_zip(url)
            if !isnothing(klines)
                append!(all_klines, klines)
                ym = _next_month(ym)
                continue
            end
        end
        days_in = Dates.daysinmonth(y, m)
        for d in 1:days_in
            day_dt = DateTime(y, m, d)
            day_dt >= now_dt && break
            url = "$VISION_BASE/daily/klines/$symbol/$interval/$symbol-$interval-$(lpad(y,4,'0'))-$(lpad(m,2,'0'))-$(lpad(d,2,'0')).zip"
            klines = _download_vision_zip(url)
            if !isnothing(klines)
                append!(all_klines, klines)
            end
        end
        ym = _next_month(ym)
    end
    filter!(k -> k[1] >= start_ms && k[1] <= end_ms, all_klines)
    return all_klines
end

function _next_month(ym::Tuple{Int,Int})
    y, m = ym
    m == 12 ? (y + 1, 1) : (y, m + 1)
end

end # module
