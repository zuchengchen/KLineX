const API = {
    async searchSymbols(query) {
        const resp = await fetch(`/api/symbols?q=${encodeURIComponent(query)}`);
        return resp.json();
    },

    async syncSymbols() {
        const resp = await fetch('/api/symbols/sync');
        return resp.json();
    },

    async getKlines(symbol, interval, start, end_) {
        let url = `/api/klines?symbol=${symbol}&interval=${interval}`;
        if (start) url += `&start=${start}`;
        if (end_) url += `&end=${end_}`;
        const resp = await fetch(url);
        return resp.json();
    },

    async getIndicators(symbol, interval, indicators, start, end_) {
        let url = `/api/indicators?symbol=${symbol}&interval=${interval}&indicators=${encodeURIComponent(indicators)}`;
        if (start) url += `&start=${start}`;
        if (end_) url += `&end=${end_}`;
        const resp = await fetch(url);
        return resp.json();
    }
};
