const ChartManager = {
    chart: null,
    candlestickSeries: null,
    volumeSeries: null,
    seriesMap: new Map(),
    nextPaneIndex: 1,
    _klineData: [],
    _volumeData: [],
    _indicatorData: new Map(),
    _onLoadMore: null,
    _loadingMore: false,
    _tooltipEl: null,
    _container: null,

    init(container) {
        this._container = container;
        this._tooltipEl = document.getElementById('candle-tooltip');
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
        this._setupTooltip();
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

    _setupTooltip() {
        this.chart.subscribeCrosshairMove(param => {
            if (!param.point || param.point.x < 0 || param.point.y < 0 || !param.time) {
                this._tooltipEl.style.display = 'none';
                return;
            }

            const data = param.seriesData.get(this.candlestickSeries);
            if (!data) {
                this._tooltipEl.style.display = 'none';
                return;
            }

            const { open, high, low, close } = data;
            const changePercent = ((close - open) / open * 100).toFixed(2);
            const amplitudePercent = ((high - low) / low * 100).toFixed(2);
            const isUp = close >= open;

            const kline = this._klineData.find(k => k.time === param.time);
            const volume = kline?.volume;

            let html = `<div class="tooltip-time">${this._formatTime(param.time)}</div>`;
            html += '<div class="tooltip-row"><span class="tooltip-label">O</span><span class="tooltip-value">' + this._formatPrice(open) + '</span></div>';
            html += '<div class="tooltip-row"><span class="tooltip-label">H</span><span class="tooltip-value up">' + this._formatPrice(high) + '</span></div>';
            html += '<div class="tooltip-row"><span class="tooltip-label">L</span><span class="tooltip-value down">' + this._formatPrice(low) + '</span></div>';
            html += '<div class="tooltip-row"><span class="tooltip-label">C</span><span class="tooltip-value ' + (isUp ? 'up' : 'down') + '">' + this._formatPrice(close) + '</span></div>';

            if (volume !== undefined) {
                html += '<div class="tooltip-row"><span class="tooltip-label">Vol</span><span class="tooltip-value">' + this._formatVolume(volume) + '</span></div>';
            }

            html += '<div class="tooltip-row"><span class="tooltip-label">Chg%</span><span class="tooltip-value ' + (changePercent >= 0 ? 'up' : 'down') + '">' + (changePercent >= 0 ? '+' : '') + changePercent + '%</span></div>';
            html += '<div class="tooltip-row"><span class="tooltip-label">Amp%</span><span class="tooltip-value">' + amplitudePercent + '%</span></div>';

            const indicatorRows = this._getIndicatorValuesAtTime(param.time);
            if (indicatorRows.length > 0) {
                html += '<div class="tooltip-divider"></div>';
                for (const row of indicatorRows) {
                    html += `<div class="indicator-row"><span class="indicator-label" style="color:${row.color}">${row.label}</span><span class="indicator-value">${row.value}</span></div>`;
                }
            }

            this._tooltipEl.innerHTML = html;
            this._tooltipEl.style.display = 'block';

            const containerRect = this._container.getBoundingClientRect();
            let left = param.point.x + 15;
            let top = param.point.y - 10;

            if (left + 180 > containerRect.width) {
                left = param.point.x - 180;
            }
            if (top + 150 > containerRect.height) {
                top = containerRect.height - 160;
            }
            if (top < 10) top = 10;

            this._tooltipEl.style.left = left + 'px';
            this._tooltipEl.style.top = top + 'px';
        });
    },

    _formatTime(time) {
        const date = new Date(time * 1000);
        const y = date.getFullYear();
        const m = String(date.getMonth() + 1).padStart(2, '0');
        const d = String(date.getDate()).padStart(2, '0');
        const h = String(date.getHours()).padStart(2, '0');
        const min = String(date.getMinutes()).padStart(2, '0');
        return `${y}-${m}-${d} ${h}:${min}`;
    },

    _formatPrice(price) {
        if (price >= 1000) return price.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        if (price >= 1) return price.toFixed(4);
        if (price >= 0.0001) return price.toFixed(6);
        return price.toFixed(8);
    },

    _formatVolume(vol) {
        if (vol >= 1e9) return (vol / 1e9).toFixed(2) + 'B';
        if (vol >= 1e6) return (vol / 1e6).toFixed(2) + 'M';
        if (vol >= 1e3) return (vol / 1e3).toFixed(2) + 'K';
        return vol.toFixed(2);
    },

    _getIndicatorValuesAtTime(time) {
        const rows = [];
        for (const [spec, data] of this._indicatorData) {
            const point = data.find(d => d.time === time);
            if (!point) continue;

            const parts = spec.split(':');
            const name = parts[0].toUpperCase();
            const color = INDICATOR_COLORS[parts[0]] || '#888';

            if (name === 'BOLL') {
                if (point.upper != null) rows.push({ label: 'BOLL Upper', value: this._formatPrice(point.upper), color });
                if (point.middle != null) rows.push({ label: 'BOLL Middle', value: this._formatPrice(point.middle), color });
                if (point.lower != null) rows.push({ label: 'BOLL Lower', value: this._formatPrice(point.lower), color });
            } else if (name === 'MACD') {
                if (point.macd != null) rows.push({ label: 'MACD', value: point.macd.toFixed(2), color: '#2962ff' });
                if (point.signal != null) rows.push({ label: 'Signal', value: point.signal.toFixed(2), color: '#ff6d00' });
                if (point.histogram != null) rows.push({ label: 'Hist', value: point.histogram.toFixed(2), color: point.histogram >= 0 ? '#26a69a' : '#ef5350' });
            } else {
                if (point.value != null) rows.push({ label: name, value: this._formatPrice(point.value), color });
            }
        }
        return rows;
    },

    setIndicatorData(spec, data) {
        this._indicatorData.set(spec, data);
    },

    clearIndicatorData() {
        this._indicatorData.clear();
    },

    setKlineData(klines) {
        this._klineData = klines;
        this._volumeData = klines.map(k => ({ time: k.time, value: k.volume || 0, color: k.close >= k.open ? 'rgba(38,166,154,0.5)' : 'rgba(239,83,80,0.5)' }));
        this.candlestickSeries.setData(klines);
        if (this.volumeSeries) {
            this.chart.removeSeries(this.volumeSeries);
        }
        this.volumeSeries = this.chart.addSeries(
            LightweightCharts.HistogramSeries,
            { priceFormat: { type: 'volume' }, priceScaleId: '' },
            0
        );
        this.volumeSeries.priceScale().applyOptions({ scaleMargins: { top: 0.8, bottom: 0 } });
        this.volumeSeries.setData(this._volumeData);
        this.chart.timeScale().fitContent();
    },

    prependKlineData(olderKlines) {
        if (!olderKlines.length) return;
        const existingTimes = new Set(this._klineData.map(k => k.time));
        const deduped = olderKlines.filter(k => !existingTimes.has(k.time));
        if (!deduped.length) return;
        this._klineData = [...deduped, ...this._klineData];
        const olderVolumes = deduped.map(k => ({ time: k.time, value: k.volume || 0, color: k.close >= k.open ? 'rgba(38,166,154,0.5)' : 'rgba(239,83,80,0.5)' }));
        this._volumeData = [...olderVolumes, ...this._volumeData];
        this.candlestickSeries.setData(this._klineData);
        this.volumeSeries.setData(this._volumeData);
    },

    getEarliestTime() {
        return this._klineData.length > 0 ? this._klineData[0].time : null;
    },

    getLatestTime() {
        return this._klineData.length > 0 ? this._klineData[this._klineData.length - 1].time : null;
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
        const updateSize = () => {
            const rect = container.getBoundingClientRect();
            const width = Math.floor(rect.width);
            const height = Math.floor(rect.height);
            if (width > 0 && height > 0) {
                this.chart.applyOptions({ width, height });
            }
        };

        updateSize();

        const observer = new ResizeObserver(updateSize);
        observer.observe(container);
    }
};
