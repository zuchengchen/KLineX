# Watchlist Feature Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add TradingView-style watchlist with real-time prices, 24h changes, and persistent storage to KLineX

**Architecture:** Frontend module (watchlist.js) with localStorage persistence + backend SQLite sync, price polling from Binance API

**Tech Stack:** Vanilla JavaScript (ES6+), Julia backend (Oxygen), SQLite, Binance public API

---

## Task 1: Backend Database Setup

**Files:**
- Modify: `src/db.jl`

**Step 1: Add watchlist table creation**

Add to `init()` function after existing table creation:

```julia
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
```

**Step 2: Add watchlist CRUD functions**

Add at end of module (before `end # module`):

```julia
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
```

**Step 3: Commit**

```bash
cd /home/czc/project/working/stock/KLineX/.worktrees/feature-watchlist
git add src/db.jl
git commit -m "feat: add watchlist database table and functions"
```

---

## Task 2: Backend API Endpoints

**Files:**
- Modify: `src/server.jl`

**Step 1: Add watchlist GET endpoint**

Add after `/api/backfill/status` endpoint:

```julia
@get "/api/watchlist" function(req)
    user_id = get(req.headers, "X-User-ID", "default")
    symbols = DB.get_watchlist(user_id)
    return json(Dict("symbols" => collect(symbols)))
end
```

**Step 2: Add watchlist POST endpoint**

```julia
@post "/api/watchlist/add" function(req)
    user_id = get(req.headers, "X-User-ID", "default")
    body = JSON3.read(req.body)
    symbol = body["symbol"]
    DB.add_to_watchlist(user_id, symbol)
    return json(Dict("status" => "ok"))
end
```

**Step 3: Add watchlist DELETE endpoint**

```julia
@delete "/api/watchlist/remove/:symbol" function(req)
    user_id = get(req.headers, "X-User-ID", "default")
    symbol = req.params.symbol
    DB.remove_from_watchlist(user_id, symbol)
    return json(Dict("status" => "ok"))
end
```

**Step 4: Commit**

```bash
git add src/server.jl
git commit -m "feat: add watchlist API endpoints"
```

---

## Task 3: Frontend API Layer

**Files:**
- Modify: `static/js/api.js`

**Step 1: Add watchlist API methods**

Add to `API` object:

```javascript
async getWatchlist() {
    const res = await fetch('/api/watchlist');
    return await res.json();
},

async addToWatchlist(symbol) {
    await fetch('/api/watchlist/add', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({symbol})
    });
},

async removeFromWatchlist(symbol) {
    await fetch(`/api/watchlist/remove/${symbol}`, {method: 'DELETE'});
},

async getBatchPrices(symbols) {
    if (symbols.length === 0) return [];
    const pairs = symbols.join(',');
    const res = await fetch(`https://api.binance.com/api/v3/ticker/24hr?symbols=${pairs}`);
    return await res.json();
}
```

**Step 2: Commit**

```bash
git add static/js/api.js
git commit -m "feat: add watchlist API methods"
```

---

## Task 4: Watchlist Module

**Files:**
- Create: `static/js/watchlist.js`

**Step 1: Create watchlist module**

```javascript
const Watchlist = {
    items: [],
    prices: {},
    isOpen: false,
    pollTimer: null,
    STORAGE_KEY: 'klinex_watchlist',

    init() {
        this.loadFromStorage();
        this.render();

        document.getElementById('watchlist-toggle').addEventListener('click', () => {
            this.toggle();
        });

        document.getElementById('watchlist-close').addEventListener('click', () => {
            this.toggle();
        });

        this.startPricePolling();
    },

    loadFromStorage() {
        const stored = localStorage.getItem(this.STORAGE_KEY);
        this.items = stored ? JSON.parse(stored) : ['BTCUSDT', 'ETHUSDT'];
    },

    saveToStorage() {
        localStorage.setItem(this.STORAGE_KEY, JSON.stringify(this.items));
    },

    async add(symbol) {
        if (!this.items.includes(symbol)) {
            this.items.push(symbol);
            this.saveToStorage();
            this.render();
            await API.addToWatchlist(symbol);
        }
    },

    async remove(symbol) {
        this.items = this.items.filter(s => s !== symbol);
        this.saveToStorage();
        this.render();
        await API.removeFromWatchlist(symbol);
    },

    toggle() {
        this.isOpen = !this.isOpen;
        const panel = document.getElementById('watchlist-panel');
        panel.classList.toggle('hidden', !this.isOpen);
    },

    async loadPrices() {
        if (this.items.length === 0) return;
        try {
            const data = await API.getBatchPrices(this.items);
            this.prices = {};
            for (const item of data) {
                this.prices[item.symbol] = {
                    price: parseFloat(item.lastPrice),
                    change: parseFloat(item.priceChangePercent),
                    volume: parseFloat(item.volume)
                };
            }
            this.render();
        } catch (e) {
            console.warn('Price load failed:', e);
        }
    },

    startPricePolling() {
        this.loadPrices();
        this.pollTimer = setInterval(() => this.loadPrices(), 5000);
    },

    render() {
        const container = document.getElementById('watchlist-items');
        container.innerHTML = '';

        for (const symbol of this.items) {
            const price = this.prices[symbol];
            const change = price ? price.change : 0;
            const changeClass = change >= 0 ? 'price-up' : 'price-down';

            const div = document.createElement('div');
            div.className = 'watchlist-item';
            div.innerHTML = `
                <div class="wl-symbol">${symbol}</div>
                <div class="wl-price">$${price ? price.price.toFixed(2) : '---'}</div>
                <div class="wl-change ${changeClass}">${change > 0 ? '+' : ''}${change.toFixed(2)}%</div>
                <button class="wl-remove" data-symbol="${symbol}">✕</button>
            `;

            div.addEventListener('click', (e) => {
                if (!e.target.classList.contains('wl-remove')) {
                    App.currentSymbol = symbol;
                    document.getElementById('current-symbol').textContent = symbol;
                    App.loadData();
                }
            });

            div.querySelector('.wl-remove').addEventListener('click', (e) => {
                e.stopPropagation();
                this.remove(symbol);
            });

            container.appendChild(div);
        }
    }
};
```

**Step 2: Commit**

```bash
git add static/js/watchlist.js
git commit -m "feat: create watchlist module"
```

---

## Task 5: UI Integration - HTML

**Files:**
- Modify: `static/index.html`

**Step 1: Add watchlist UI to toolbar**

Add after `interval-bar` div (around line 25):

```html
<div class="watchlist-container">
    <button id="watchlist-toggle" class="watchlist-btn" title="Watchlist">⭐</button>
    <div id="watchlist-panel" class="watchlist-panel hidden">
        <div class="watchlist-header">
            <h3>Watchlist</h3>
            <button id="watchlist-close" class="wl-close">×</button>
        </div>
        <div id="watchlist-items" class="watchlist-items"></div>
    </div>
</div>
```

**Step 2: Add watchlist script**

Add before closing `</body>` tag (before `app.js`):

```html
<script src="/js/watchlist.js"></script>
```

**Step 3: Commit**

```bash
git add static/index.html
git commit -m "feat: add watchlist UI to HTML"
```

---

## Task 6: UI Integration - CSS

**Files:**
- Modify: `static/css/style.css`

**Step 1: Add watchlist styles**

Add at end of file:

```css
/* Watchlist container */
.watchlist-container {
    position: relative;
    margin-left: auto;
}

.watchlist-btn {
    background: transparent;
    border: none;
    color: var(--text-secondary);
    font-size: 18px;
    cursor: pointer;
    padding: 6px 12px;
}

.watchlist-btn:hover {
    color: #f4b722;
}

/* Watchlist panel */
.watchlist-panel {
    position: absolute;
    top: 100%;
    right: 0;
    width: 280px;
    max-height: 400px;
    background: var(--bg-secondary);
    border: 1px solid var(--border);
    border-radius: 4px;
    z-index: 100;
    display: flex;
    flex-direction: column;
}

.watchlist-panel.hidden {
    display: none;
}

.watchlist-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 12px;
    border-bottom: 1px solid var(--border);
}

.watchlist-header h3 {
    font-size: 13px;
    font-weight: 600;
}

.wl-close {
    background: none;
    border: none;
    color: var(--text-secondary);
    font-size: 18px;
    cursor: pointer;
}

/* Watchlist items */
.watchlist-items {
    overflow-y: auto;
    padding: 4px 0;
}

.watchlist-item {
    display: grid;
    grid-template-columns: 1fr auto auto auto;
    gap: 8px;
    padding: 8px 12px;
    cursor: pointer;
    align-items: center;
}

.watchlist-item:hover {
    background: var(--bg-tertiary);
}

.wl-symbol {
    font-weight: 600;
    font-size: 13px;
}

.wl-price {
    font-family: 'SF Mono', monospace;
    font-size: 12px;
    color: var(--text-primary);
}

.wl-change {
    font-family: 'SF Mono', monospace;
    font-size: 11px;
    font-weight: 600;
}

.price-up { color: var(--green); }
.price-down { color: var(--red); }

.wl-remove {
    background: none;
    border: none;
    color: var(--text-secondary);
    font-size: 14px;
    cursor: pointer;
    padding: 2px 6px;
}

.wl-remove:hover {
    color: var(--red);
}
```

**Step 2: Commit**

```bash
git add static/css/style.css
git commit -m "feat: add watchlist styles"
```

---

## Task 7: App Integration

**Files:**
- Modify: `static/js/app.js`

**Step 1: Initialize watchlist in App.init()**

Add in `init()` method after `Search.init(...)` (around line 25):

```javascript
Watchlist.init();
```

**Step 2: Commit**

```bash
git add static/js/app.js
git commit -m "feat: initialize watchlist in app"
```

---

## Task 8: Backend Restart and Test

**Step 1: Restart Julia server**

```bash
pkill -f "julia.*KLineX"
cd /home/czc/project/working/stock/KLineX/.worktrees/feature-watchlist
julia --project=. -e 'using KLineX; KLineX.start()' &
sleep 3
curl -s http://localhost:8888 | grep -i watchlist
```

**Step 2: Test API endpoints**

```bash
# Test get watchlist
curl http://localhost:8888/api/watchlist

# Test add to watchlist
curl -X POST http://localhost:8888/api/watchlist/add \
  -H "Content-Type: application/json" \
  -d '{"symbol":"BTCUSDT"}'

# Test get watchlist again
curl http://localhost:8888/api/watchlist

# Test remove from watchlist
curl -X DELETE http://localhost:8888/api/watchlist/remove/BTCUSDT
```

**Step 3: Commit**

```bash
git add docs/plans/2026-02-15-watchlist-implementation.md
git commit -m "test: verify backend API endpoints"
```

---

## Task 9: Manual Testing

**Step 1: Open browser and test**

```bash
# Check server is running
ps aux | grep julia | grep KLineX

# Open in browser
xdg-open http://localhost:8888 2>/dev/null || open http://localhost:8888
```

**Test Checklist:**
- [ ] Click ⭐ button - panel opens
- [ ] See default items (BTCUSDT, ETHUSDT)
- [ ] Prices load and update
- [ ] Click item - chart loads
- [ ] Click ✕ - item removes
- [ ] Close panel - persists
- [ ] Refresh page - items persist
- [ ] Search for symbol - add to watchlist

**Step 2: Commit**

```bash
git add docs/plans/2026-02-15-watchlist-implementation.md
git commit -m "test: manual testing complete - all features working"
```

---

## Success Criteria

✓ All 9 tasks completed
✓ Backend API endpoints working (curl tested)
✓ Frontend watchlist module functional
✓ UI displays correctly
✓ localStorage persistence works
✓ Price polling updates every 5s
✓ Add/remove functions work
✓ Click to load chart works

## Notes

- User-ID defaults to "default" for testing - add authentication later
- Prices from Binance public API (no auth needed)
- localStorage primary, backend sync optional
- 5s polling balance between freshness and API limits
