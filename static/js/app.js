const INTERVAL_MS = {
    '1m': 60000, '3m': 180000, '5m': 300000, '15m': 900000, '30m': 1800000,
    '1h': 3600000, '2h': 7200000, '4h': 14400000, '6h': 21600000, '8h': 28800000, '12h': 43200000,
    '1d': 86400000, '3d': 259200000, '1w': 604800000, '1M': 2592000000,
};

const App = {
    currentSymbol: 'BTCUSDT',
    currentInterval: '1h',
    _backfillTimer: null,
    _backfillSymbol: null,

    async init() {
        ChartManager.init(document.getElementById('chart-container'));
        ChartManager.setOnLoadMore(() => this._loadMore());

        Search.init((symbol) => {
            this.currentSymbol = symbol;
            document.getElementById('current-symbol').textContent = symbol;
            this.loadData();
            this._startBackfill(symbol);
        });

        document.querySelectorAll('.interval-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                document.querySelectorAll('.interval-btn').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                this.currentInterval = btn.dataset.interval;
                this.loadData();
                this._startBackfill(this.currentSymbol);
            });
        });

        IndicatorUI.init(() => this.loadIndicators());

        await this.loadData();
    },

    async _loadMore() {
        const earliest = ChartManager.getEarliestTime();
        if (!earliest) return;
        const endMs = earliest * 1000 - 1;
        const intervalMs = INTERVAL_MS[this.currentInterval] || 3600000;
        const startMs = endMs - 1500 * intervalMs;
        this.setStatus('Loading more...');
        try {
            const data = await API.getKlines(this.currentSymbol, this.currentInterval, startMs, endMs);
            if (data.klines && data.klines.length > 0) {
                ChartManager.prependKlineData(data.klines);
                if (IndicatorUI.activeIndicators.length > 0) {
                    await this.loadIndicators();
                }
            }
            const total = ChartManager._klineData.length;
            this.setStatus(`${this.currentSymbol} ${this.currentInterval} — ${total} candles`);
        } catch (e) {
            this.setStatus(`Load more error: ${e.message}`);
        }
    },

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
    },

    async loadIndicators() {
        const specs = IndicatorUI.getActiveSpecs();
        if (!specs) return;

        const earliest = ChartManager.getEarliestTime();
        const latest = ChartManager.getLatestTime();
        const startMs = earliest ? earliest * 1000 : undefined;
        const endMs = latest ? latest * 1000 + (INTERVAL_MS[this.currentInterval] || 3600000) : undefined;

        this.setStatus('Computing indicators...');
        try {
            const data = await API.getIndicators(this.currentSymbol, this.currentInterval, specs, startMs, endMs);
            ChartManager.clearAllIndicators();

            for (const ind of IndicatorUI.activeIndicators) {
                const result = data[ind.spec];
                if (!result || result.error) continue;
                this._renderIndicator(ind.spec, ind.name, result);
            }
            this.setStatus(`${this.currentSymbol} ${this.currentInterval} — indicators loaded`);
        } catch (e) {
            this.setStatus(`Indicator error: ${e.message}`);
        }
    },

    _renderIndicator(spec, name, result) {
        let entry;
        if (name === 'ema' || name === 'sma') {
            const series = ChartManager.addOverlaySeries(spec, result.data, INDICATOR_COLORS[name]);
            entry = { series: [series], paneIndex: 0 };
        } else if (name === 'boll') {
            const seriesList = ChartManager.addOverlayMulti(spec, {
                upper: result.upper, middle: result.middle, lower: result.lower
            }, INDICATOR_COLORS.boll);
            entry = { series: seriesList, paneIndex: 0 };
        } else if (name === 'macd') {
            entry = ChartManager.addMACDSeries(spec, result.macd, result.signal, result.histogram);
        } else if (name === 'rsi' || name === 'cci') {
            entry = ChartManager.addOscillatorSeries(spec, result.data, INDICATOR_COLORS[name]);
        }
        if (entry) ChartManager.seriesMap.set(spec, entry);
    },

    setStatus(msg) {
        document.getElementById('status-bar').textContent = msg;
    },

    _startBackfill(symbol) {
        if (this._backfillTimer) {
            clearInterval(this._backfillTimer);
            this._backfillTimer = null;
        }
        this._backfillSymbol = symbol;

        API.startBackfill(symbol, this.currentInterval).catch(e => {
            console.warn('Backfill start failed:', e);
        });

        this._backfillTimer = setInterval(async () => {
            if (this._backfillSymbol !== symbol) {
                clearInterval(this._backfillTimer);
                return;
            }
            try {
                const status = await API.getBackfillStatus(symbol);
                if (!status.running && status.done) {
                    clearInterval(this._backfillTimer);
                    this._backfillTimer = null;
                    return;
                }
                if (status.running) {
                    const progress = `Backfill ${symbol}: ${status.current_interval} ${status.current_month || ''}... (${status.completed_intervals}/${status.total_intervals} intervals)`;
                    document.getElementById('status-bar').textContent = progress;
                }
            } catch (e) {
            }
        }, 2000);
    }
};

document.addEventListener('DOMContentLoaded', () => {
    App.init().catch(e => {
        console.error('App init failed:', e);
        const status = document.getElementById('status-bar');
        if (status) status.textContent = `Init error: ${e.message}`;
    });
});
