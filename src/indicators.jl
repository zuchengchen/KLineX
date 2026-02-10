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
