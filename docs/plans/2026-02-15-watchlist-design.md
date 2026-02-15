# Watchlist Feature Design for KLineX

**Date**: 2026-02-15
**Status**: Design Complete
**Author**: Design Agent

## Overview

Add TradingView-style watchlist functionality to KLineX, allowing users to track favorite trading pairs with real-time price updates, 24h change percentages, and volume data.

## Requirements

### Functional Requirements
- Add/remove symbols from watchlist (star button on toolbar and each item)
- Display watchlist in right-side panel (collapsible)
- Show: symbol, current price, 24h change %, 24h volume
- Real-time price updates (poll every 5s)
- Persistent storage (localStorage + optional backend sync)
- Click item to load chart
- Sort by symbol or price

### Non-Functional Requirements
- Fast UI response (<100ms for local operations)
- Offline-capable with localStorage
- Minimal API calls (debounced, batched)
- Responsive design (mobile: drawer, desktop: panel)

## Architecture

### Data Flow

```
User Action (Add/Remove)
    ↓
LocalStorage Update (immediate)
    ↓
API Call (async, fire-and-forget)
    ↓
Backend SQLite (persist)
    ↓
Return success/error
```

### Component Structure

```
static/js/
  ├── watchlist.js         (NEW) - Main watchlist module
  ├── app.js              (MODIFY) - Add watchlist initialization
  ├── api.js              (MODIFY) - Add watchlist API methods
  └── search.js           (MODIFY) - Add star button to results

static/css/
  └── style.css           (MODIFY) - Add watchlist panel styles

src/
  ├── db.jl               (MODIFY) - Add watchlist table/functions
  └── server.jl           (MODIFY) - Add watchlist API endpoints

static/index.html         (MODIFY) - Add watchlist button and panel
```

## Database Schema

### SQLite Table

```sql
CREATE TABLE IF NOT EXISTS watchlist (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT,
    symbol TEXT NOT NULL,
    added_at INTEGER NOT NULL,
    UNIQUE(user_id, symbol)
);

CREATE INDEX IF NOT EXISTS idx_watchlist_user ON watchlist(user_id);
```

### Storage Functions (src/db.jl)

```julia
function get_watchlist(user_id::String)
    df = DB.execute(:watchlist, "SELECT symbol FROM watchlist WHERE user_id = ? ORDER BY added_at", [user_id])
    return df.symbol
end

function add_to_watchlist(user_id::String, symbol::String)
    now = round(Int, time() * 1000)
    execute("INSERT OR IGNORE INTO watchlist (user_id, symbol, added_at) VALUES (?, ?, ?)", [user_id, symbol, now])
end

function remove_from_watchlist(user_id::String, symbol::String)
    execute("DELETE FROM watchlist WHERE user_id = ? AND symbol = ?", [user_id, symbol])
end
```

## API Endpoints

### Backend Routes (src/server.jl)

```julia
@get "/api/watchlist" function(req)
    user_id = get(req.headers, "X-User-ID", "default")
    symbols = DB.get_watchlist(user_id)
    return json(Dict("symbols" => symbols))
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
```

### Frontend API (static/js/api.js)

```javascript
const API = {
    // ... existing methods

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
        const pairs = symbols.map(s => `${s}USDT`).join(',');
        const res = await fetch(`https://api.binance.com/api/v3/ticker/24hr?symbols=${pairs}`);
        return await res.json();
    }
};
```

## Frontend Implementation

### Watchlist Module (static/js/watchlist.js)

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
        this.startPricePolling();

        document.getElementById('watchlist-toggle').addEventListener('click', () => {
            this.toggle();
        });
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

### UI Integration (static/index.html)

Add to toolbar after interval buttons:

```html
<div class="watchlist-container">
    <button id="watchlist-toggle" class="watchlist-btn">⭐</button>
    <div id="watchlist-panel" class="watchlist-panel hidden">
        <div class="watchlist-header">
            <h3>Watchlist</h3>
            <button id="watchlist-close" class="wl-close">×</button>
        </div>
        <div id="watchlist-items" class="watchlist-items"></div>
    </div>
</div>
```

### Styling (static/css/style.css)

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

## Implementation Plan

1. **Backend Changes** (src/)
   - [ ] Add watchlist table to db.jl
   - [ ] Add API endpoints to server.jl
   - [ ] Test API with curl

2. **Frontend Core** (static/js/)
   - [ ] Create watchlist.js
   - [ ] Add API methods to api.js
   - [ ] Initialize Watchlist in app.js

3. **UI Integration** (static/)
   - [ ] Add watchlist button/panel to index.html
   - [ ] Add CSS styles to style.css
   - [ ] Test basic add/remove

4. **Enhancements**
   - [ ] Add price polling (5s interval)
   - [ ] Add star button to current symbol in toolbar
   - [ ] Add star button to search results
   - [ ] Implement sort options

5. **Testing**
   - [ ] Test localStorage persistence
   - [ ] Test backend sync
   - [ ] Test price updates
   - [ ] Test mobile responsive

## Success Criteria

- ✓ Add/remove symbols works correctly
- ✓ Watchlist persists across browser sessions
- ✓ Real-time prices update every 5 seconds
- ✓ Click item loads chart
- ✓ UI matches TradingView style
- ✓ Works offline (localStorage)
- ✓ Backend sync available

## Future Enhancements

- Multiple watchlists (custom groups)
- Drag-and-drop reordering
- Export/import watchlist
- Price alerts
- WebSocket for real-time updates
- Column customization
