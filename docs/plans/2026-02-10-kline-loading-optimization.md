# K 线加载性能优化 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 切换周期时 K 线秒开 — 先返回已有缓存，后台异步补数据；近期数据用 REST API 替代逐日 Vision zip；Backfill 延迟启动避免资源竞争；前端显示下载进度。

**Architecture:** 将 `ensure_klines()` 拆为"快速返回缓存 + 异步补数据"两阶段。近期数据（最近 2 个月）跳过 Vision daily 直接走 REST API。Backfill 在主请求完成后延迟触发。前端在等待下载时显示进度条。

**Tech Stack:** Julia (Oxygen.jl, HTTP, SQLite), Vanilla JS (fetch API)

---

## Task 1: REST API 优先于 Vision daily（近期数据）

**问题：** `vision_download_range()` 对最近 1-2 个月的数据逐日下载 zip（30-60 次 HTTP），而 REST API 一次请求就能拿 1500 根 K 线。

**Files:**
- Modify: `src/binance.jl:175-212` (`vision_download_range` 函数)

**Step 1: 修改 `vision_download_range` — 跳过近期月份的逐日下载**

当月份在 cutoff 之后（即最近 1 个月），不再逐日下载 zip，直接跳过让调用方用 REST API 补。

```julia
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
            # Try monthly zip (only for months older than cutoff)
            url = "$VISION_BASE/monthly/klines/$symbol/$interval/$symbol-$interval-$(lpad(y,4,'0'))-$(lpad(m,2,'0')).zip"
            @info "Vision monthly: $url"
            klines = _download_vision_zip(url)
            if !isnothing(klines)
                append!(all_klines, klines)
                ym = _next_month(ym)
                continue
            end
            # Monthly zip failed for old month — try daily for this month only
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
        end
        # Recent months (>= cutoff): SKIP entirely — caller uses REST API to fill gap
        ym = _next_month(ym)
    end
    filter!(k -> k[1] >= start_ms && k[1] <= end_ms, all_klines)
    return all_klines
end
```

**关键变化：** `month_dt >= cutoff` 时不再逐日下载，直接跳过。`_fetch_klines_with_vision()` 已有逻辑：Vision 返回后检查 `last_time < end_ms` 则用 REST API 补尾部。这样近期数据自动走 REST API。

**Step 2: 验证**

```bash
julia --project=. -e 'include("src/binance.jl"); println("OK")'
```

**Step 3: Commit**

```bash
git add src/binance.jl
git commit -m "perf: skip Vision daily downloads for recent months, let REST API handle them"
```

---

## Task 2: 先返回缓存，后台异步补数据

**问题：** `ensure_klines()` 同步下载完所有缺失数据后才返回，即使 DB 里已有部分缓存。

**Files:**
- Modify: `src/server.jl:32-57` (`/api/klines` handler)
- Modify: `src/server.jl:124-139` (`ensure_klines` 函数)

**Step 1: 将 `ensure_klines` 拆为同步检查 + 异步下载**

```julia
"""Check if we have ANY cached data for this range. Returns true if cache exists (even partial)."""
function has_cached_klines(symbol::String, interval::String, start_ms::Int64, end_ms::Int64)::Bool
    existing = DB.get_kline_range(symbol, interval)
    isnothing(existing) && return false
    # Has data that overlaps with requested range
    return existing.max_time >= start_ms && existing.min_time <= end_ms
end

"""Async version: schedule download in background, return immediately."""
function ensure_klines_async(symbol::String, interval::String, start_ms::Int64, end_ms::Int64)
    @async try
        ensure_klines(symbol, interval, start_ms, end_ms)
    catch e
        @warn "Background kline download failed: $e"
    end
end
```

**Step 2: 修改 `/api/klines` handler — 有缓存时先返回，无缓存时同步等待**

```julia
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
        # Have cached data — return it immediately, download gaps in background
        ensure_klines_async(symbol, interval, start_time, end_time)
    else
        # No cache at all — must download synchronously (nothing to show otherwise)
        try
            ensure_klines(symbol, interval, start_time, end_time)
        catch e
            @warn "Failed to download klines: $e"
        end
    end

    df = DB.get_klines(symbol, interval; start_time=start_time, end_time=end_time)
    klines = [Dict(
        "time" => div(r.open_time, 1000),
        "open" => r.open, "high" => r.high, "low" => r.low, "close" => r.close,
        "volume" => r.volume
    ) for r in eachrow(df)]
    return json(Dict("klines" => klines, "count" => length(klines), "complete" => !has_cache || nrow(df) >= 1400))
end
```

**关键变化：**
- 有缓存 → `ensure_klines_async` 后台补数据，立即返回已有数据
- 无缓存 → 同步下载（否则返回空数据没意义）
- 响应增加 `complete` 字段，前端可据此判断是否需要刷新

**Step 3: 验证**

```bash
julia --project=. -e 'include("src/KLineX.jl"); println("OK")'
```

**Step 4: Commit**

```bash
git add src/server.jl
git commit -m "perf: return cached klines immediately, download gaps asynchronously"
```

---

## Task 3: Backfill 延迟启动

**问题：** `loadData()` 和 `_startBackfill()` 几乎同时触发，Backfill 下载全量历史数据与主请求竞争 Binance API 速率限制和 SQLite 写锁。

**Files:**
- Modify: `static/js/app.js:24-31` (interval click handler)
- Modify: `static/js/app.js:61-79` (`loadData` 函数)

**Step 1: 将 backfill 移到 loadData 完成之后**

修改 interval click handler，不再并行触发 backfill：

```javascript
document.querySelectorAll('.interval-btn').forEach(btn => {
    btn.addEventListener('click', () => {
        document.querySelectorAll('.interval-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        this.currentInterval = btn.dataset.interval;
        this.loadData();
        // Removed: this._startBackfill(this.currentSymbol);
        // Backfill now triggered after loadData completes (see loadData)
    });
});
```

同样修改 Search callback（`app.js:17-22`）：

```javascript
Search.init((symbol) => {
    this.currentSymbol = symbol;
    document.getElementById('current-symbol').textContent = symbol;
    this.loadData();
    // Removed: this._startBackfill(symbol);
});
```

修改 `loadData()` — 在数据加载完成后延迟启动 backfill：

```javascript
async loadData() {
    this.setStatus(`Loading ${this.currentSymbol} ${this.currentInterval}...`);
    ChartManager.clearAllIndicators();

    try {
        const data = await API.getKlines(this.currentSymbol, this.currentInterval);
        if (data.klines && data.klines.length > 0) {
            ChartManager.setKlineData(data.klines);
            this.setStatus(`${this.currentSymbol} ${this.currentInterval} — ${data.count} candles`);
            if (IndicatorUI.activeIndicators.length > 0) {
                await this.loadIndicators();
            }
        } else {
            this.setStatus('No data available');
        }
    } catch (e) {
        this.setStatus(`Error: ${e.message}`);
    }

    // Start backfill AFTER main data is loaded (2s delay to avoid resource contention)
    setTimeout(() => {
        this._startBackfill(this.currentSymbol);
    }, 2000);
},
```

**Step 2: 验证**

在浏览器中打开应用，切换周期，确认：
1. K 线数据先加载显示
2. 2 秒后状态栏显示 Backfill 进度

**Step 3: Commit**

```bash
git add static/js/app.js
git commit -m "perf: delay backfill start until after main kline data loads"
```

---

## Task 4: 前端显示下载进度

**问题：** 无缓存时同步下载可能需要数秒，用户只看到 "Loading..." 没有进度反馈。

**Files:**
- Modify: `src/server.jl` (新增下载状态 API 或在 klines 响应中加 metadata)
- Modify: `static/js/app.js` (`loadData` 函数)

**Step 1: 在 klines 响应中增加 `partial` 标记**

Task 2 已在响应中加了 `complete` 字段。前端利用它：当 `complete === false` 时，几秒后自动刷新。

**Step 2: 修改前端 `loadData` — 不完整数据时自动刷新**

```javascript
async loadData() {
    this.setStatus(`Loading ${this.currentSymbol} ${this.currentInterval}...`);
    ChartManager.clearAllIndicators();

    try {
        const data = await API.getKlines(this.currentSymbol, this.currentInterval);
        if (data.klines && data.klines.length > 0) {
            ChartManager.setKlineData(data.klines);
            const status = data.complete
                ? `${this.currentSymbol} ${this.currentInterval} — ${data.count} candles`
                : `${this.currentSymbol} ${this.currentInterval} — ${data.count} candles (loading more...)`;
            this.setStatus(status);
            if (IndicatorUI.activeIndicators.length > 0) {
                await this.loadIndicators();
            }
            // If data is partial, schedule a refresh to pick up newly downloaded data
            if (!data.complete) {
                this._scheduleRefresh();
            }
        } else {
            this.setStatus('No data available');
        }
    } catch (e) {
        this.setStatus(`Error: ${e.message}`);
    }

    setTimeout(() => {
        this._startBackfill(this.currentSymbol);
    }, 2000);
},
```

**Step 3: 新增 `_scheduleRefresh` 方法**

```javascript
_refreshTimer: null,
_refreshCount: 0,

_scheduleRefresh() {
    if (this._refreshTimer) clearTimeout(this._refreshTimer);
    this._refreshCount = 0;
    this._doRefresh();
},

async _doRefresh() {
    if (this._refreshCount >= 10) return; // Max 10 retries
    this._refreshTimer = setTimeout(async () => {
        try {
            const data = await API.getKlines(this.currentSymbol, this.currentInterval);
            if (data.klines && data.klines.length > 0) {
                ChartManager.setKlineData(data.klines);
                if (data.complete) {
                    this.setStatus(`${this.currentSymbol} ${this.currentInterval} — ${data.count} candles`);
                    if (IndicatorUI.activeIndicators.length > 0) {
                        await this.loadIndicators();
                    }
                    return; // Done
                }
                this.setStatus(`${this.currentSymbol} ${this.currentInterval} — ${data.count} candles (loading more...)`);
            }
        } catch (e) {
            // Ignore refresh errors
        }
        this._refreshCount++;
        this._doRefresh(); // Schedule next refresh
    }, 3000); // Refresh every 3 seconds
},
```

**Step 4: 验证**

在浏览器中切换到未缓存的周期，确认：
1. 有缓存时秒开，状态栏显示 candle 数量
2. 无缓存时显示 "Loading..."，数据到达后显示 "(loading more...)"
3. 后台补数据完成后自动刷新，状态栏不再显示 "(loading more...)"

**Step 5: Commit**

```bash
git add src/server.jl static/js/app.js
git commit -m "feat: auto-refresh chart when background download completes partial data"
```

---

## 执行顺序

Task 1 → Task 2 → Task 3 → Task 4（有依赖关系，必须顺序执行）

## 预期效果

| 场景 | 优化前 | 优化后 |
|------|--------|--------|
| 切换到已缓存周期 | 1-3s（检查+补尾部） | **<200ms**（直接返回缓存） |
| 切换到未缓存周期 | 5-30s（Vision daily + REST） | **3-8s**（跳过 Vision daily） |
| Backfill 与主请求竞争 | 速率限制/超时 | **无竞争**（延迟 2s） |
| 等待时用户体验 | 白屏 "Loading..." | **进度提示 + 自动刷新** |
