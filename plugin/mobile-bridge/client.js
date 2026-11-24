window.__ModuleLoader__.load({
  id: '@local/mobile-bridge',
  factory(require) {
    const React = require('react');
    const h = React.createElement;

    const CHANNEL = '/api/mobile-bridge';
    const STYLE_ID = 'mobile-bridge-styles';

    async function rpc(method, args) {
      const response = await fetch(`${CHANNEL}/${method}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ args: args ?? {} }),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      if (data.ok !== true) throw new Error(data.error || 'Request failed');
      return data.value;
    }

    function BridgeIcon({ size = 20 }) {
      return h('svg', {
        viewBox: '0 0 36 36', width: size, height: size, 'aria-hidden': true,
        style: { display: 'block' },
      },
        h('rect', { x: 11, y: 6, width: 14, height: 24, rx: 3, fill: 'none', stroke: 'currentColor', strokeWidth: 2 }),
        h('line', { x1: 16, y1: 26, x2: 20, y2: 26, stroke: 'currentColor', strokeWidth: 2, strokeLinecap: 'round' }),
        h('path', { d: 'M 6 12 A 8 8 0 0 1 6 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.8, strokeLinecap: 'round' }),
        h('path', { d: 'M 30 12 A 8 8 0 0 0 30 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.8, strokeLinecap: 'round' })
      );
    }

    const CSS = `
.mb-root {
  --mb-bg: var(--dsw-alias-bg-base, #0d1322);
  --mb-surface: var(--dsw-alias-bg-layer-1, #131a2c);
  --mb-surface-2: var(--dsw-alias-bg-layer-2, #1a2237);
  --mb-line: var(--dsw-alias-border-l2, rgba(255,255,255,.09));
  --mb-line-soft: var(--dsw-alias-border-l1, rgba(255,255,255,.05));
  --mb-text: var(--dsw-alias-label-primary, #e9edf7);
  --mb-muted: var(--dsw-alias-label-secondary, #9aa5bf);
  --mb-faint: var(--dsw-alias-label-tertiary, #6b7691);
  --mb-accent: var(--dsw-alias-brand-primary, #8b7bff);
  --mb-accent-soft: color-mix(in srgb, var(--mb-accent) 16%, transparent);
  --mb-accent-line: color-mix(in srgb, var(--mb-accent) 42%, transparent);
  --mb-success: var(--dsw-alias-state-success-primary, #4ade80);
  --mb-error: var(--dsw-alias-state-error-primary, #f87171);
  display: flex; flex-direction: column; height: 100%; min-height: 0;
  color: var(--mb-text); font-size: 13.5px; background: var(--mb-bg); overflow: hidden;
}
.mb-head {
  display: flex; align-items: center; justify-content: space-between;
  padding: 14px 22px; border-bottom: 1px solid var(--mb-line-soft); flex: 0 0 auto;
}
.mb-title { font-size: 16px; font-weight: 650; margin: 0; }
.mb-sub { font-size: 12px; color: var(--mb-faint); margin-top: 2px; }
.mb-body { flex: 1 1 auto; min-height: 0; overflow-y: auto; padding: 22px; display: flex; flex-direction: column; gap: 18px; }
.mb-card { background: var(--mb-surface); border: 1px solid var(--mb-line); border-radius: 12px; padding: 16px; display: flex; flex-direction: column; gap: 10px; }
.mb-card-title { font-size: 13px; font-weight: 600; display: flex; align-items: center; justify-content: space-between; }
.mb-badge {
  display: inline-flex; align-items: center; gap: 6px; font-size: 11.5px; padding: 4px 10px; border-radius: 999px;
  color: var(--mb-success); background: color-mix(in srgb, var(--mb-success) 12%, transparent);
}
.mb-badge.down { color: var(--mb-error); background: color-mix(in srgb, var(--mb-error) 12%, transparent); }
.mb-url {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; color: var(--mb-accent);
  background: var(--mb-surface-2); border: 1px solid var(--mb-line); border-radius: 6px;
  padding: 5px 9px; cursor: pointer; display: inline-block; width: fit-content;
}
.mb-url:hover { border-color: var(--mb-accent-line); }
.mb-device { display: flex; justify-content: space-between; gap: 12px; padding: 8px 0; border-bottom: 1px solid var(--mb-line-soft); font-size: 12.5px; }
.mb-device:last-child { border-bottom: none; }
.mb-device-ip { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--mb-text); }
.mb-device-meta { color: var(--mb-faint); font-size: 11.5px; text-align: right; }
.mb-console {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11.5px; line-height: 1.7;
  background: var(--mb-surface-2); border: 1px solid var(--mb-line); border-radius: 8px;
  padding: 12px; height: 260px; overflow-y: auto; white-space: pre-wrap; color: var(--mb-muted);
}
.mb-console .err { color: var(--mb-error); }
.mb-empty { color: var(--mb-faint); font-size: 12.5px; }
`;

    function ensureStyles() {
      if (typeof document === 'undefined') return;
      if (document.getElementById(STYLE_ID) !== null) return;
      const el = document.createElement('style');
      el.id = STYLE_ID;
      el.textContent = CSS;
      document.head.appendChild(el);
    }

    function timeAgo(iso) {
      const seconds = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
      if (seconds < 60) return `${seconds}s ago`;
      if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`;
      return `${Math.round(seconds / 3600)}h ago`;
    }

    function BridgePanel() {
      const [status, setStatus] = React.useState(null);
      const [logs, setLogs] = React.useState([]);
      const consoleRef = React.useRef(null);

      React.useEffect(() => {
        let alive = true;
        const tick = async () => {
          try {
            const [s, l] = await Promise.all([rpc('status'), rpc('logs')]);
            if (!alive) return;
            setStatus(s);
            setLogs(l.lines ?? []);
          } catch { /* host not up yet */ }
        };
        tick();
        const timer = setInterval(tick, 2500);
        return () => { alive = false; clearInterval(timer); };
      }, []);

      React.useEffect(() => {
        const el = consoleRef.current;
        if (el) el.scrollTop = el.scrollHeight;
      }, [logs]);

      const copyUrl = (url) => navigator.clipboard?.writeText(url);

      return h('div', { className: 'mb-root' },
        h('div', { className: 'mb-head' },
          h('div', null,
            h('h2', { className: 'mb-title' }, 'Mobile Bridge'),
            h('div', { className: 'mb-sub' }, 'LAN port for DSH Mobile')
          ),
          status
            ? h('span', { className: `mb-badge ${status.listening ? '' : 'down'}` },
                status.listening ? `● port ${status.port} open` : '● down')
            : h('span', { className: 'mb-badge down' }, '● contacting host…')
        ),
        h('div', { className: 'mb-body' },
          h('div', { className: 'mb-card' },
            h('div', { className: 'mb-card-title' }, 'Connection URLs',
              h('span', { style: { fontSize: '11px', color: 'var(--mb-faint)' }, title: 'Paste into the Connect screen in DSH Mobile' }, 'tap to copy')
            ),
            status?.urls?.length
              ? status.urls.map((url) => h('span', { key: url, className: 'mb-url', onClick: () => copyUrl(url) }, url))
              : h('div', { className: 'mb-empty' }, status?.lastError ?? 'No LAN address detected yet.')
          ),
          h('div', { className: 'mb-card' },
            h('div', { className: 'mb-card-title' }, 'Connected devices',
              h('span', { style: { fontSize: '11px', color: 'var(--mb-faint)' } }, `${status?.devices?.length ?? 0} seen`)
            ),
            status?.devices?.length
              ? h('div', null, status.devices.map((d) =>
                  h('div', { className: 'mb-device', key: d.address },
                    h('span', { className: 'mb-device-ip' }, d.address),
                    h('span', { className: 'mb-device-meta' }, `${d.requests} requests • seen ${timeAgo(d.lastSeen)}`)
                  )
                ))
              : h('div', { className: 'mb-empty' }, 'Waiting for a first connection from the phone.')
          ),
          h('div', { className: 'mb-card' },
            h('div', { className: 'mb-card-title' }, 'Console'),
            h('div', { className: 'mb-console', ref: consoleRef },
              logs.length
                ? logs.map((line, i) => h('div', {
                    key: i, className: line.includes('error') || line.includes('404') ? 'err' : undefined,
                  }, line))
                : h('div', { className: 'mb-empty' }, 'No log lines yet.')
            )
          )
        )
      );
    }

    return {
      inject: ['slots'],
      apply(ctx) {
        ensureStyles();

        ctx.slots.inject('sidebar.panellist', () => ctx.slots.register({
          name: 'sidebar.panellist',
          id: 'mobile-bridge',
          order: 12,
          label: () => 'Mobile',
        }, BridgeIcon));

        ctx.slots.inject('main', () => ctx.slots.register({
          name: 'main',
          key: 'mobile-bridge',
        }, BridgePanel));
      },
    };
  },
});
