const ChartManager = {
    chart: null,
    candlestickSeries: null,
    volumeSeries: null,
    seriesMap: new Map(),
    nextPaneIndex: 1,
    _klineData: [],
    _onLoadMore: null,
    _loadingMore: false,

    init(container) {
        this.chart = LightweightCharts.createChart(container, {
            layout: {
                textColor: '#d1d4dc',
                background: { type: 'solid', color: '#1e222d' },
            },
            grid: {
                vertLines: { color: 'rgba(42, 46, 57, 0.5)' },
                horzLines: { color: 'rgba(42, 46, 57, 0.5)' },
            },
            crosshair: { mode: LightweightCharts.CrosshairMode.Normal },
            rightPriceScale: { borderColor: '#2a2e39' },
            timeScale: {
                borderColor: '#2a2e39',
                timeVisible: true,
                secondsVisible: false,
            },
        });

        this.candlestickSeries = this.chart.addSeries(
            LightweightCharts.CandlestickSeries,
            {
                upColor: '#26a69a',
                downColor: '#ef5350',
                borderVisible: false,
                wickUpColor: '#26a69a',
                wickDownColor: '#ef5350',
            }
        );

        this._setupInfiniteScroll();
        this._handleResize(container);
    },

    setOnLoadMore(fn) {
        this._onLoadMore = fn;
    },

    _setupInfiniteScroll() {
        this.chart.timeScale().subscribeVisibleLogicalRangeChange(logicalRange => {
            if (!logicalRange || this._loadingMore || !this._onLoadMore) return;
            if (logicalRange.from < 10) {
                this._loadingMore = true;
                this._onLoadMore().finally(() => { this._loadingMore = false; });
            }
        });
    },

    setKlineData(klines) {
        this._klineData = klines;
        this.candlestickSeries.setData(klines);
        this.chart.timeScale().fitContent();
    },

    prependKlineData(olderKlines) {
        if (!olderKlines.length) return;
        const existingTimes = new Set(this._klineData.map(k => k.time));
        const deduped = olderKlines.filter(k => !existingTimes.has(k.time));
        if (!deduped.length) return;
        this._klineData = [...deduped, ...this._klineData];
        this.candlestickSeries.setData(this._klineData);
    },

    getEarliestTime() {
        return this._klineData.length > 0 ? this._klineData[0].time : null;
    },

    addOverlaySeries(spec, data, color) {
        const series = this.chart.addSeries(
            LightweightCharts.LineSeries,
            { color: color, lineWidth: 2, title: spec },
            0
        );
        series.setData(data);
        return series;
    },

    addOverlayMulti(spec, dataMap, colors) {
        const seriesList = [];
        for (const [key, data] of Object.entries(dataMap)) {
            const s = this.chart.addSeries(
                LightweightCharts.LineSeries,
                { color: colors[key] || '#888', lineWidth: 1, title: `${spec} ${key}` },
                0
            );
            s.setData(data);
            seriesList.push(s);
        }
        return seriesList;
    },

    addOscillatorSeries(spec, data, color) {
        const paneIndex = this.nextPaneIndex++;
        const series = this.chart.addSeries(
            LightweightCharts.LineSeries,
            { color: color, lineWidth: 2, title: spec },
            paneIndex
        );
        series.setData(data);
        return { series: [series], paneIndex };
    },

    addMACDSeries(spec, macdData, signalData, histogramData) {
        const paneIndex = this.nextPaneIndex++;
        const histSeries = this.chart.addSeries(
            LightweightCharts.HistogramSeries,
            { title: 'MACD Hist' },
            paneIndex
        );
        const coloredHist = histogramData.map(d => ({
            ...d,
            color: d.value >= 0 ? 'rgba(38,166,154,0.6)' : 'rgba(239,83,80,0.6)'
        }));
        histSeries.setData(coloredHist);

        const macdSeries = this.chart.addSeries(
            LightweightCharts.LineSeries,
            { color: '#2962ff', lineWidth: 2, title: 'MACD' },
            paneIndex
        );
        macdSeries.setData(macdData);

        const signalSeries = this.chart.addSeries(
            LightweightCharts.LineSeries,
            { color: '#ff6d00', lineWidth: 2, title: 'Signal' },
            paneIndex
        );
        signalSeries.setData(signalData);

        return { series: [histSeries, macdSeries, signalSeries], paneIndex };
    },

    removeIndicator(spec) {
        const entry = this.seriesMap.get(spec);
        if (!entry) return;
        for (const s of entry.series) {
            this.chart.removeSeries(s);
        }
        this.seriesMap.delete(spec);
        this._recalcPanes();
    },

    clearAllIndicators() {
        for (const [spec, entry] of this.seriesMap) {
            for (const s of entry.series) {
                this.chart.removeSeries(s);
            }
        }
        this.seriesMap.clear();
        this.nextPaneIndex = 1;
    },

    _recalcPanes() {
        let maxPane = 0;
        for (const entry of this.seriesMap.values()) {
            if (entry.paneIndex > maxPane) maxPane = entry.paneIndex;
        }
        this.nextPaneIndex = maxPane + 1;
    },

    _handleResize(container) {
        const observer = new ResizeObserver(entries => {
            for (const entry of entries) {
                const { width, height } = entry.contentRect;
                this.chart.applyOptions({ width, height });
            }
        });
        observer.observe(container);
    }
};
