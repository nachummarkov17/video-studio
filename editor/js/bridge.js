// Thin wrapper over WebView2 postMessage. Host posts JSON strings back.
const handlers = new Set();
if (window.chrome?.webview) {
  window.chrome.webview.addEventListener('message', e => {
    let m; try { m = typeof e.data === 'string' ? JSON.parse(e.data) : e.data; } catch { return; }
    handlers.forEach(h => h(m));
  });
}
export function send(obj) { window.chrome?.webview?.postMessage(JSON.stringify(obj)); }
export function onMessage(fn) { handlers.add(fn); return () => handlers.delete(fn); }
