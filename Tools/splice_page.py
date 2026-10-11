#!/usr/bin/env python3
"""Stamp the SEBLERSKERS landing page onto a fresh Godot web export.

Godot's exporter writes index.html with its default shell. This script
replaces it with web/page.template.html (progress bar, Set Sail gate,
rotate-to-landscape hint) and injects the exporter's exact GODOT_CONFIG
(real file sizes, gdextension libs) so the loader shows truthful
progress. Run from the project root AFTER `godot --export-release Web`:

    python3 tools/splice_page.py
"""
import hashlib
import os
import re
import sys

BUILD = os.path.join("build", "web")
TEMPLATE = os.path.join("web", "page.template.html")
SW = os.path.join("web", "sw.js")


def asset_fingerprint() -> str:
    """Stable hash of the big asset files (size + mtime), so the service
    worker cache generation changes exactly when the assets do."""
    h = hashlib.sha1()
    for name in ("index.pck", "index.wasm", "index.side.wasm",
                 "libterrain.web.release.wasm32.wasm", "index.js"):
        p = os.path.join(BUILD, name)
        if os.path.isfile(p):
            st = os.stat(p)
            h.update(name.encode())
            h.update(str(st.st_size).encode())
            h.update(str(int(st.st_mtime)).encode())
    return h.hexdigest()[:16]


def main() -> int:
    src_html = os.path.join(BUILD, "index.html")
    if not os.path.isfile(src_html):
        print("error: %s not found - run the Godot web export first" % src_html)
        return 1
    pck = os.path.join(BUILD, "index.pck")
    wasm = os.path.join(BUILD, "index.wasm")
    if not (os.path.isfile(pck) and os.path.isfile(wasm)):
        print("error: export output incomplete (missing .pck/.wasm)")
        return 1

    src = open(src_html, encoding="utf-8").read()
    page = open(TEMPLATE, encoding="utf-8").read()

    # Pull the exporter's own loader config so sizes/libs stay truthful.
    # Path A: a fresh Godot export (CI). Path B: an already-stamped page
    # from an earlier run, so local re-runs work without re-exporting.
    consts = None
    m = re.search(
        r'<script src="\.?/?index\.js"></script>\s*<script>(.*)</script>',
        src, re.S)
    if m:
        loader = m.group(1)
        i = loader.find("const GODOT_CONFIG")
        j = loader.find("const GODOT_THREADS_ENABLED")
        k = loader.find("\n", j)
        if i >= 0 and 0 < i < j and k > j:
            cand = loader[i:k].strip()
            if "new Engine" not in cand and cand.endswith(";"):
                consts = cand
    if consts is None:
        m2 = re.search(
            r"(const GODOT_CONFIG[\s\S]*?const GODOT_THREADS_ENABLED[^\n]*;)",
            src)
        if m2 and "new Engine" not in m2.group(1):
            consts = m2.group(1).strip()
    if consts is None:
        print("error: could not find the loader script in the export")
        return 1

    pck_size = os.path.getsize(pck)
    wasm_size = os.path.getsize(wasm)
    page = page.replace("PCK_SIZE", str(pck_size))
    page = page.replace("WASM_SIZE", str(wasm_size))

    marker = "<script>\n(function () {"
    if marker not in page or page.count("new Engine(") != 1:
        print("error: template marker missing or engine already wired")
        return 1
    page = page.replace(marker, "<script>\n" + consts + "\n\n(function () {")

    # Versioned service worker: cache-first for the big assets so repeat
    # visits skip the 500 MB+ download. Fingerprinted per build.
    sw = open(SW, encoding="utf-8").read()
    sw = sw.replace("__CACHE_VERSION__", asset_fingerprint())
    open(os.path.join(BUILD, "sw.js"), "w", encoding="utf-8").write(sw)

    open(src_html, "w", encoding="utf-8").write(page)
    print("stamped %s (pck=%d, wasm=%d, sw=%s)" % (
        src_html, pck_size, wasm_size, asset_fingerprint()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
