const App = {
    currentSymbol: 'BTCUSDT',
    currentInterval: '1h',

    async init() {
        ChartManager.init(document.getElementById('chart-container'));

        Search.init((symbol) => {
            this.currentSymbol = symbol;
            document.getElementById('current-symbol').textContent = symbol;
            this.loadData();
        });

        document.querySelectorAll('.interval-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                document.querySelectorAll('.interval-btn').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                this.currentInterval = btn.dataset.interval;
                this.loadData();
            });
        });

        IndicatorUI.init(() => this.loadIndicators());

        this.setStatus('Syncing symbols from Binance...');
        try {
            await API.syncSymbols();
            this.setStatus('Symbols synced. Loading chart...');
        } catch (e) {
            this.setStatus('Failed to sync symbols (offline mode)');
        }

        await this.loadData();
    },

    async loadData() {
        this.setStatus(`Loading ${this.currentSymbol} ${this.currentInterval}...`);
        ChartManager.clearAllIndicators();
        IndicatorUI.activeIndicators = [];
        IndicatorUI._renderTags();

        try {
            const data = await API.getKlines(this.currentSymbol, this.currentInterval);
            if (data.klines && data.klines.length > 0) {
                ChartManager.setKlineData(data.klines);
                this.setStatus(`${this.currentSymbol} ${this.currentInterval} — ${data.count} candles`);
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

        this.setStatus('Computing indicators...');
        try {
            const data = await API.getIndicators(this.currentSymbol, this.currentInterval, specs);
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
    }
};

document.addEventListener('DOMContentLoaded', () => {
    App.init().catch(e => {
        console.error('App init failed:', e);
        const status = document.getElementById('status-bar');
        if (status) status.textContent = `Init error: ${e.message}`;
    });
});
