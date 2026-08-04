// Thin wrapper over WebView2 postMessage. Host posts JSON strings back.
const handlers = new Set();
if (window.chrome?.webview) {
  window.chrome.webview.addEventListener('message', e => {
    let m; try { m = typeof e.data === 'string' ? JSON.parse(e.data) : e.data; } catch { return; }
    for (const [rid, resolve] of pending) {
      if (m && m.rid === rid) { pending.delete(rid); resolve(m); return; }
    }
    handlers.forEach(h => h(m));
  });
}
export function send(obj) { window.chrome?.webview?.postMessage(obj); }
export function onMessage(fn) { handlers.add(fn); return () => handlers.delete(fn); }

// True when we're running inside the Studio window. Outside it (unit probes,
// a plain browser) there is no host to answer, so callers can skip the round
// trip instead of waiting for a timeout.
export function hasHost() { return !!window.chrome?.webview; }

// Request/response over the same channel, correlated by a request id.
const pending = new Map();
let _rid = 0;
const REQUEST_TIMEOUT_MS = 4000;
export function request(type, payload = {}) {
  if (!hasHost()) return Promise.resolve(null);
  const rid = 'r' + (++_rid);
  return new Promise((resolve) => {
    pending.set(rid, resolve);
    setTimeout(() => { if (pending.delete(rid)) resolve(null); }, REQUEST_TIMEOUT_MS);
    send({ ...payload, type, rid });
  });
}
