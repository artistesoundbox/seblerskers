/*
 * SEBLERSKERS pack cache — service worker for /seblerskers/.
 *
 * Returning players: the ~535 MB pack streams in 8 MB chunks from the game
 * repo's GitHub Pages CDN. Every completed chunk is stored in the Cache API
 * under a size-keyed URL; on the next visit the loader replays finished
 * chunks from cache (zero network) and fetches only the rest. After one
 * complete load the game boots fully offline.
 *
 * Freshness: cache keys embed the pack's total byte size
 * (.../index.pck?s=561704920&c=7). When a new build ships the size changes,
 * every key changes, and stale chunks can never be stitched into a new
 * pack. The loader discovers the current size with a no-store HEAD and
 * prunes foreign keys afterwards, so cache use stays bounded to one pack.
 *
 * Other assets: the engine files in this folder are cache-first with a
 * background size revalidate (they only change when a new engine build
 * ships). The HTML shell is network-first so shell fixes land immediately.
 * Any cache error falls back to plain network — this worker can only ever
 * make things faster, never broken.
 */

const CACHE = "seb-pack-v1";
const VERSION = "2026-09-22.1";

/* this folder's engine files */
const ENGINE = /\/seblerskers\/(index\.js|index\.wasm|index\.side\.wasm|index\.audio\.worklet\.js|index\.audio\.position\.worklet\.js|libterrain\.web\.release\.wasm32\.wasm|site-shell-cover(-small)?\.jpg)$/;
/* pack URLs carry ?s=<total>&c=<chunk>; the CDN origin is the game repo's Pages host */
const PACK_FILE = /\/index\.pck$/;

self.addEventListener("install", function () {
  self.skipWaiting();
});

self.addEventListener("activate", function (event) {
  event.waitUntil((async function () {
    const names = await caches.keys();
    await Promise.all(names.filter(function (n) { return n !== CACHE; })
      .map(function (n) { return caches.delete(n); }));
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", function (event) {
  const req = event.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);

  // HTML shell: network-first so shell updates land immediately
  if (req.mode === "navigate" ||
      (url.origin === self.location.origin &&
       /\/seblerskers\/index\.html$/.test(url.pathname))) {
    event.respondWith(networkFirst(req));
    return;
  }

  // pack chunks: cache-first by exact URL (keys already encode the size)
  if (PACK_FILE.test(url.pathname)) {
    event.respondWith(cacheFirst(req, true));
    return;
  }

  // engine files: cache-first + background size revalidate
  if (url.origin === self.location.origin && ENGINE.test(url.pathname)) {
    event.respondWith(cacheFirst(req, false));
    return;
  }
  // everything else (CDN HEAD requests, gtag, the portal itself): native
});

async function networkFirst(req) {
  try {
    const fresh = await fetch(req);
    const cache = await caches.open(CACHE);
    try { cache.put(req, fresh.clone()); } catch (e) { /* quota */ }
    return fresh;
  } catch (e) {
    const cached = await caches.match(req);
    if (cached) return cached;
    throw e;
  }
}

async function cacheFirst(req, isPack) {
  const cache = await caches.open(CACHE);
  let cached = null;
  try { cached = await cache.match(req, { ignoreSearch: false }); } catch (e) { }

  if (cached) {
    if (!isPack) revalidateEngine(req, cache); // background, non-blocking
    return cached;
  }

  const fresh = await fetch(req);
  try { await cache.put(req, fresh.clone()); } catch (e) { /* quota */ }
  return fresh;
}

/* Engine files only change with a new engine build; a Content-Length drift
   means exactly that, so refetch once and swap the cached copy. Pack
   chunks never revalidate — their size-keyed URLs are the version. */
async function revalidateEngine(req, cache) {
  try {
    const head = await fetch(req.url, {
      method: "HEAD", mode: "cors", cache: "no-store",
    });
    const len = head.headers.get("content-length");
    if (!len) return;
    const cachedLen = cachedLength(await cache.match(req));
    if (cachedLen === null || cachedLen === Number(len)) return;

    const fresh = await fetch(req.url, { mode: "cors", cache: "no-store" });
    if (!fresh.ok) return;
    await cache.put(req, fresh.clone());
    const clients = await self.clients.matchAll({ includeUncontrolled: true });
    clients.forEach(function (c) {
      c.postMessage({ type: "seb-engine-updated", file: new URL(req.url).pathname });
    });
  } catch (e) { /* offline, CORS hiccup, quota — stay on the cached copy */ }
}

function cachedLength(resp) {
  if (!resp) return null;
  const h = resp.headers.get("content-length");
  return h ? String(Number(h)) : null;
}
