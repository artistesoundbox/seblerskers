#!/usr/bin/env python3
"""Stamp the SEBLERSKERS landing page onto a fresh Godot web export.

Godot's exporter writes index.html with its default shell. This script
replaces it with web/page.template.html (progress bar, Set Sail gate,
rotate-to-landscape hint) and injects the exporter's exact GODOT_CONFIG
(real file sizes, gdextension libs) so the loader shows truthful
progress. Run from the project root AFTER `godot --export-release Web`:

    python3 tools/splice_page.py
"""
import os
import re
import sys

BUILD = os.path.join("build", "web")
TEMPLATE = os.path.join("web", "page.template.html")


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
    m = re.search(
        r'<script src="index\.js"></script>\s*<script>(.*)</script>',
        src, re.S)
    if not m:
        print("error: could not find the loader script in the export")
        return 1
    loader = m.group(1)
    i = loader.find("const GODOT_CONFIG")
    j = loader.find("const GODOT_THREADS_ENABLED")
    k = loader.find("\n", j)
    consts = loader[i:k].strip()
    if "new Engine" in consts or not consts.endswith(";"):
        print("error: loader slice looks wrong, aborting")
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

    open(src_html, "w", encoding="utf-8").write(page)
    print("stamped %s (pck=%d, wasm=%d)" % (src_html, pck_size, wasm_size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
