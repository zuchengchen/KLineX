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
