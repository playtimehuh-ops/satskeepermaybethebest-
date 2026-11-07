(() => {
  const state = document.getElementById('api-state');
  const list = document.getElementById('feature-status');
  const checked = document.getElementById('checked-at');
  const year = document.getElementById('year');
  if (year) year.textContent = String(new Date().getFullYear());

  const labels = {
    accounts: 'Accounts',
    points_earning: 'Points earning',
    memberships_and_wheel: 'Memberships & wheel',
    gift_cards: 'Gift cards',
    network_sharing: 'Network sharing',
    buyer_traffic_api: 'Buyer traffic API'
  };

  function readable(value) {
    return String(value || 'unknown').replaceAll('_', ' ');
  }

  async function loadStatus() {
    if (!state || !list) return;
    try {
      const response = await fetch('/api/public-status', {
        method: 'GET',
        headers: { Accept: 'application/json' },
        cache: 'no-store',
        credentials: 'same-origin'
      });
      if (!response.ok) throw new Error('status_unavailable');
      const data = await response.json();
      state.textContent = data.api === 'reachable' ? 'API reachable' : 'Status limited';
      state.className = 'status-pill ' + (data.api === 'reachable' ? 'ok' : 'warn');
      list.replaceChildren();
      Object.entries(labels).forEach(([key, label]) => {
        const row = document.createElement('div');
        const term = document.createElement('dt');
        const value = document.createElement('dd');
        term.textContent = label;
        value.textContent = readable(data.features && data.features[key]);
        row.append(term, value);
        list.append(row);
      });
      if (checked) {
        const date = new Date(data.checked_at);
        checked.textContent = Number.isNaN(date.getTime())
          ? 'Status checked just now.'
          : 'Checked ' + date.toLocaleString();
      }
    } catch (_) {
      state.textContent = 'Status unavailable';
      state.className = 'status-pill warn';
      checked.textContent = 'The status endpoint could not be reached. This does not confirm that the app is offline.';
    }
  }

  loadStatus();
})();
