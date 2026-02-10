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
