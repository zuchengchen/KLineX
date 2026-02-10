const INDICATOR_COLORS = {
    ema: '#2962ff',
    sma: '#ff9800',
    boll: { upper: '#787b86', middle: '#ff9800', lower: '#787b86' },
    macd: '#2962ff',
    rsi: '#7b1fa2',
    cci: '#00897b',
};

const INDICATOR_PARAMS = {
    ema: [{ name: 'Period', key: 'period', default: 20 }],
    sma: [{ name: 'Period', key: 'period', default: 50 }],
    boll: [{ name: 'Period', key: 'period', default: 20 }, { name: 'StdDev', key: 'mult', default: 2 }],
    macd: [{ name: 'Fast', key: 'fast', default: 12 }, { name: 'Slow', key: 'slow', default: 26 }, { name: 'Signal', key: 'signal', default: 9 }],
    rsi: [{ name: 'Period', key: 'period', default: 14 }],
    cci: [{ name: 'Period', key: 'period', default: 20 }],
};

const IndicatorUI = {
    activeIndicators: [],
    onChanged: null,
    STORAGE_KEY: 'klinex_active_indicators',

    init(onChanged) {
        this.onChanged = onChanged;
        document.getElementById('add-indicator-btn').addEventListener('click', () => this._showModal());
        document.getElementById('modal-close').addEventListener('click', () => this._hideModal());
        document.getElementById('param-modal-close').addEventListener('click', () => this._hideParamModal());
        document.getElementById('indicator-modal').addEventListener('click', (e) => {
            if (e.target.id === 'indicator-modal') this._hideModal();
        });
        document.getElementById('param-modal').addEventListener('click', (e) => {
            if (e.target.id === 'param-modal') this._hideParamModal();
        });

        document.querySelectorAll('.indicator-option').forEach(btn => {
            btn.addEventListener('click', () => {
                const name = btn.dataset.indicator;
                const defaults = btn.dataset.defaults;
                this._hideModal();
                this._showParamModal(name, defaults);
            });
        });
    },

    _saveToStorage() {
        const specs = this.activeIndicators.map(i => i.spec);
        localStorage.setItem(this.STORAGE_KEY, JSON.stringify(specs));
    },

    restore() {
        try {
            const saved = localStorage.getItem(this.STORAGE_KEY);
            if (!saved) return;
            const specs = JSON.parse(saved);
            for (const spec of specs) {
                const name = spec.split(':')[0];
                if (INDICATOR_PARAMS[name]) {
                    this.activeIndicators.push({ spec, name });
                }
            }
            this._renderTags();
        } catch (e) {
            console.warn('Failed to restore indicators:', e);
        }
    },

    _showModal() { document.getElementById('indicator-modal').classList.remove('hidden'); },
    _hideModal() { document.getElementById('indicator-modal').classList.add('hidden'); },
    _hideParamModal() { document.getElementById('param-modal').classList.add('hidden'); },

    _showParamModal(name, defaults) {
        const modal = document.getElementById('param-modal');
        const title = document.getElementById('param-modal-title');
        const body = document.getElementById('param-modal-body');
        title.textContent = name.toUpperCase() + ' Parameters';
        body.innerHTML = '';

        const paramDefs = INDICATOR_PARAMS[name];
        const defaultVals = defaults.split(':');
        paramDefs.forEach((p, i) => {
            const div = document.createElement('div');
            div.className = 'param-input';
            div.innerHTML = `<label>${p.name}</label><input type="number" id="param-${p.key}" value="${defaultVals[i] || p.default}">`;
            body.appendChild(div);
        });

        const okBtn = document.getElementById('param-modal-ok');
        const newOk = okBtn.cloneNode(true);
        okBtn.parentNode.replaceChild(newOk, okBtn);
        newOk.addEventListener('click', () => {
            const values = paramDefs.map(p => document.getElementById(`param-${p.key}`).value);
            const spec = `${name}:${values.join(':')}`;
            this._addIndicator(name, spec);
            modal.classList.add('hidden');
        });
        modal.classList.remove('hidden');
    },

    _addIndicator(name, spec) {
        if (this.activeIndicators.find(i => i.spec === spec)) return;
        this.activeIndicators.push({ spec, name });
        this._renderTags();
        this._saveToStorage();
        if (this.onChanged) this.onChanged();
    },

    removeIndicator(spec) {
        this.activeIndicators = this.activeIndicators.filter(i => i.spec !== spec);
        ChartManager.removeIndicator(spec);
        this._renderTags();
        this._saveToStorage();
        if (this.onChanged) this.onChanged();
    },

    _renderTags() {
        const container = document.getElementById('active-indicators');
        container.innerHTML = '';
        for (const ind of this.activeIndicators) {
            const tag = document.createElement('div');
            tag.className = 'indicator-tag';
            tag.innerHTML = `<span class="label">${ind.spec}</span><span class="remove">&times;</span>`;
            tag.querySelector('.remove').addEventListener('click', (e) => {
                e.stopPropagation();
                this.removeIndicator(ind.spec);
            });
            tag.querySelector('.label').addEventListener('dblclick', () => {
                const parts = ind.spec.split(':');
                const name = parts[0];
                const params = parts.slice(1).join(':');
                this.removeIndicator(ind.spec);
                this._showParamModal(name, params);
            });
            container.appendChild(tag);
        }
    },

    getActiveSpecs() {
        return this.activeIndicators.map(i => i.spec).join(',');
    }
};
