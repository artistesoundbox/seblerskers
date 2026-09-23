/* SEBLERSKERS asset cache.
 *
 * GitHub Pages only promises a ~10 minute HTTP cache, so without this
 * service worker every visit re-downloaded the whole 500 MB+ pack. This
 * worker stores the big game files in the browser's Cache Storage
 * (cache-first, effectively permanent) and swaps caches on every new
 * deploy: the build stamps a fresh __CACHE_VERSION__ into this file,
 * the byte-diff triggers a reinstall, and the activate step deletes
 * the previous generation.
 */
/* eslint-disable no-restricted-globals */
"use strict";

const VERSION = "__CACHE_VERSION__";
const CACHE = "seblerskers-" + VERSION;
const ASSET_NAMES = [
  "index.js",
  "index.wasm",
  "index.side.wasm",
  "libterrain.web.release.wasm32.wasm",
  "index.pck",
];

self.addEventListener("install", () => {
  // Nothing is pre-fetched here: the engine downloads after the player
  // clicks "Set sail", and this worker simply keeps whatever flows by.
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter((k) => k.startsWith("seblerskers-") && k !== CACHE)
          .map((k) => caches.delete(k))
      );
      await self.clients.claim();
    })()
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (!ASSET_NAMES.includes(url.pathname.split("/").pop())) return;

  event.respondWith(
    (async () => {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(req);
      if (hit) return hit;
      const res = await fetch(req);
      if (res && res.ok) cache.put(req, res.clone());
      return res;
    })()
  );
});
