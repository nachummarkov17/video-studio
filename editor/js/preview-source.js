// preview-source.js — which file the EDITOR plays.
//
// Not necessarily the one it renders. The masters are full-size (1080x1920 at
// ~16 Mbit/s here), and seeking one of those costs hundreds of milliseconds -
// which is what "moving the playhead lags for a second or two" was. The host
// keeps a small, densely-keyframed proxy of every clip in work\proxy-cache\;
// this module asks for it, remembers it, and hands it out in place of the
// master for PREVIEW ONLY. Export, burn, music and finish all still read the
// master, so nothing that leaves the app is ever the proxy.
//
// Everything degrades safely: no proxy yet simply means the master is used.

import { onMessage, request } from './bridge.js';
import { mediaUrl } from './assets.js';

const proxies = new Map();     // relative path -> proxy URL
const asked = new Set();
const readyListeners = new Set();

export function onProxyReady(fn) { readyListeners.add(fn); return () => readyListeners.delete(fn); }

function announce(path) { for (const fn of readyListeners) fn(path); }

onMessage((m) => {
  if (m.type !== 'proxyReady' || !m.path || !m.url) return;
  proxies.set(m.path, m.url);
  announce(m.path);
});

// The URL to play for this file, right now. Asking also STARTS a proxy build if
// there isn't one yet - the answer improves by itself a little later.
export function previewUrl(relpath) {
  if (!relpath) return '';
  requestProxy(relpath);
  return proxies.get(relpath) || mediaUrl(relpath);
}

export function requestProxy(relpath) {
  if (!relpath || proxies.has(relpath) || asked.has(relpath)) return;
  asked.add(relpath);
  request('proxyGet', { path: relpath }).then((r) => {
    if (r && r.url) { proxies.set(relpath, r.url); announce(relpath); }
  });
}

export function hasProxy(relpath) { return proxies.has(relpath); }
