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
const VERSION = "2026-09-22.2"; // engine-set purge on activate + pinned revalidate

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
    // Purge engine files + covers but KEEP pack chunks: the engine set must
    // always move as one generation (a new index.js next to an old cached
    // index.wasm/side.wasm is a frankenbuild that boots nothing and then
    // blocks its own repair — every doomed boot killed the background
    // revalidation mid-download). Chunks are size-keyed and re-verified by
    // the loader every visit, so they are always safe to keep.
    try {
      const cache = await caches.open(CACHE);
      const keys = await cache.keys();
      await Promise.all(keys.filter(function (k) {
        return ENGINE.test(new URL(k.url).pathname) ||
          /\/site-shell-cover(-small)?\.jpg$/.test(new URL(k.url).pathname);
      }).map(function (k) { return cache.delete(k); }));
    } catch (e) { /* best effort */ }
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

  // pack requests: a chunk fetch carries ?s=<size>&c=<n> and is served by
  // exact URL; the engine's bare "index.pck" fetch is assembled from chunks
  if (PACK_FILE.test(url.pathname)) {
    if (url.search) event.respondWith(cacheFirst(req, true));
    else event.respondWith(servePack(req));
    return;
  }

  // engine files: cache-first + background size revalidate. The revalidate
  // is pinned with waitUntil so a page that dies mid-boot cannot kill it —
  // an unpinned revalidation is how stale engine binaries survived here.
  if (url.origin === self.location.origin && ENGINE.test(url.pathname)) {
    event.respondWith(cacheFirstEngine(req, event));
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
  return cacheFirstEngine(req, null, isPack);
}

async function cacheFirstEngine(req, event, isPack) {
  const cache = await caches.open(CACHE);
  let cached = null;
  try { cached = await cache.match(req, { ignoreSearch: false }); } catch (e) { }

  if (cached) {
    if (isPack === false || isPack === undefined) {
      const p = revalidateEngine(req, cache);
      if (event) event.waitUntil(p); // outlive the page that triggered us
    }
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

/* Pack assembly. The shell caches every 8 MB chunk under size-keyed URLs
   BEFORE the engine starts; when the engine's stock loader then fetches
   same-origin "index.pck", this streams the cached chunks out as one big
   response — the pack is never materialized twice in memory. If the chunk
   set is incomplete (quota eviction, a racing first visit), fall back to
   streaming straight from the game-repo CDN instead of stranding the
   engine. */
const PACK_ORIGIN = "https://artistesoundbox.github.io";
const CHUNK_SIZE = 8 * 1024 * 1024;

function packUrl(size, idx) {
  return PACK_ORIGIN + "/seblerskers/index.pck?s=" + size + "&c=" + idx;
}

async function servePack(req) {
  const cache = await caches.open(CACHE);
  const keys = await cache.keys();
  // group chunk keys by pack size — a CI rebuild can briefly leave two
  // sizes cached, and we must serve whichever set is COMPLETE
  const bySize = {};
  keys.forEach(function (k) {
    const m = k.url.match(/\?s=(\d+)&c=(\d+)$/);
    if (!m) return;
    const s = Number(m[1]);
    (bySize[s] = bySize[s] || {})[Number(m[2])] = true;
  });

  const cdn = PACK_ORIGIN + "/seblerskers/index.pck";
  let size = 0;
  for (const s in bySize) {
    const sz = Number(s);
    const chunks = Math.ceil(sz / CHUNK_SIZE);
    let complete = true;
    for (let i = 0; i < chunks; i++) {
      if (!bySize[sz][i]) { complete = false; break; }
    }
    if (complete) { size = sz; break; }
    if (!size || Object.keys(bySize[sz]).length > Object.keys(bySize[size]).length) {
      size = sz; // remember the best partial in case none is complete
    }
  }

  if (!size) {
    return fetch(cdn, { mode: "cors", cache: "no-store" });
  }

  const chunks = Math.ceil(size / CHUNK_SIZE);
  let complete = true;
  for (let i = 0; i < chunks; i++) {
    if (!bySize[size][i]) { complete = false; break; }
  }
  if (!complete) {
    return fetch(cdn, { mode: "cors", cache: "no-store" });
  }

  const stream = new ReadableStream({
    async start(controller) {
      try {
        for (let i = 0; i < chunks; i++) {
          const resp = await cache.match(packUrl(size, i));
          if (!resp) throw new Error("chunk " + i + " vanished mid-stream");
          controller.enqueue(new Uint8Array(await resp.arrayBuffer()));
        }
        controller.close();
      } catch (e) {
        controller.error(e);
      }
    },
  });
  return new Response(stream, {
    status: 200,
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Length": String(size),
    },
  });
}
