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
