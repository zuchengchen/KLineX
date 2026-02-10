const API = {
    async _fetch(url) {
        const resp = await fetch(url);
        if (!resp.ok) {
            const text = await resp.text().catch(() => '');
            throw new Error(`HTTP ${resp.status}: ${text.slice(0, 200)}`);
        }
        return resp.json();
    },

    async searchSymbols(query) {
        return this._fetch(`/api/symbols?q=${encodeURIComponent(query)}`);
    },

    async syncSymbols() {
        return this._fetch('/api/symbols/sync');
    },

    async getKlines(symbol, interval, start, end_) {
        let url = `/api/klines?symbol=${symbol}&interval=${interval}`;
        if (start) url += `&start=${start}`;
        if (end_) url += `&end=${end_}`;
        return this._fetch(url);
    },

    async getIndicators(symbol, interval, indicators, start, end_) {
        let url = `/api/indicators?symbol=${symbol}&interval=${interval}&indicators=${encodeURIComponent(indicators)}`;
        if (start) url += `&start=${start}`;
        if (end_) url += `&end=${end_}`;
        return this._fetch(url);
    }
};
