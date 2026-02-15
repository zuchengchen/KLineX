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
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS watchlist (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT,
            symbol TEXT NOT NULL,
            added_at INTEGER NOT NULL,
            UNIQUE(user_id, symbol)
        )
    """)
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_watchlist_user
        ON watchlist(user_id)
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
    DBInterface.execute(db, "BEGIN TRANSACTION")
    stmt = DBInterface.prepare(db, """
        INSERT OR REPLACE INTO klines
        (symbol, interval, open_time, open, high, low, close, volume, close_time, quote_volume, trades)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """)
    try
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
        DBInterface.execute(db, "COMMIT")
    catch e
        DBInterface.execute(db, "ROLLBACK")
        rethrow(e)
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

function get_watchlist(user_id::String)
    db = get_db()
    result = DBInterface.execute(db, """
        SELECT symbol FROM watchlist
        WHERE user_id = ?
        ORDER BY added_at
    """, [user_id])
    df = DataFrame(result)
    return df.symbol
end

function add_to_watchlist(user_id::String, symbol::String)
    db = get_db()
    now = round(Int64, time() * 1000)
    DBInterface.execute(db, """
        INSERT OR IGNORE INTO watchlist (user_id, symbol, added_at)
        VALUES (?, ?, ?)
    """, [user_id, symbol, now])
end

function remove_from_watchlist(user_id::String, symbol::String)
    db = get_db()
    DBInterface.execute(db, """
        DELETE FROM watchlist
        WHERE user_id = ? AND symbol = ?
    """, [user_id, symbol])
end

end # module
