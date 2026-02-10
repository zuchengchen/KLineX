const Search = {
    input: null,
    dropdown: null,
    debounceTimer: null,
    onSelect: null,
    synced: false,

    init(onSelect) {
        this.input = document.getElementById('symbol-search');
        this.dropdown = document.getElementById('search-dropdown');
        this.onSelect = onSelect;

        this.input.addEventListener('input', () => {
            clearTimeout(this.debounceTimer);
            this.debounceTimer = setTimeout(() => this._search(), 300);
        });

        this.input.addEventListener('focus', () => {
            if (this.dropdown.children.length > 0) {
                this.dropdown.classList.remove('hidden');
            }
        });

        document.addEventListener('click', (e) => {
            if (!this.input.contains(e.target) && !this.dropdown.contains(e.target)) {
                this.dropdown.classList.add('hidden');
            }
        });
    },

    async _syncOnce() {
        if (this.synced) return;
        this.synced = true;
        try {
            await API.syncSymbols();
        } catch (e) {
            this.synced = false;
        }
    },

    async _search() {
        const q = this.input.value.trim();
        if (q.length < 1) {
            this.dropdown.classList.add('hidden');
            return;
        }
        let data = await API.searchSymbols(q);
        if (!data.symbols || data.symbols.length === 0) {
            await this._syncOnce();
            data = await API.searchSymbols(q);
        }
        this.dropdown.innerHTML = '';
        if (data.symbols && data.symbols.length > 0) {
            for (const s of data.symbols) {
                const div = document.createElement('div');
                div.className = 'dropdown-item';
                div.textContent = `${s.symbol} (${s.base_asset}/${s.quote_asset})`;
                div.addEventListener('click', () => {
                    this.input.value = '';
                    this.dropdown.classList.add('hidden');
                    if (this.onSelect) this.onSelect(s.symbol);
                });
                this.dropdown.appendChild(div);
            }
            this.dropdown.classList.remove('hidden');
        } else {
            this.dropdown.classList.add('hidden');
        }
    }
};
