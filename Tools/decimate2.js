#!/usr/bin/env node
/* Decimate the two warrior GLBs to ~400k triangles each and REPACK.

   Original files: ~1.62M triangles, 16 rigid parts, attributes scattered
   through 7 SHARED bufferViews spanning the whole buffer. Decimating
   indices alone would keep those views alive, so after simplify we
   rebuild every rewritten primitive as compact per-part views, drop
   every superseded view, and write one fresh buffer.

   Usage: node Tools/decimate2.js [--target 400000]  */
"use strict";

const fs = require("fs");
const path = require("path");
const { readGLB, writeGLB, COMPSIZE, TYPECOUNT,
        readFloat32, readIndices } = require("./glb_utils.js");

async function loadSimplifier() {
  // Pure-ESM npm package: a require() returns {} — dynamic import needed.
  const p = process.env.MO_PATH ||
    "C:/Users/Anthonitus/node_modules/meshoptimizer/meshopt_simplifier.js";
  const mod = await import(require("url").pathToFileURL(p).href);
  return mod.MeshoptSimplifier || mod.default;
}

const TARGET = (() => {
  const i = process.argv.indexOf("--target");
  return i >= 0 ? parseInt(process.argv[i + 1], 10) : 400000;
})();

const FILES = ["viking_warrior.glb", "warrior_of_the_north.glb"];
const ROOT = path.resolve(__dirname, "..");

async function main() {
  const log = (m) => process.stdout.write(m + "\n");
  const S = await loadSimplifier();
  await S.ready;                 // WASM must instantiate before simplify
  const targetError = 0.01;

  // Builder for the replacement buffer: everything lands in one growing
  // list of Buffer pieces with 4-byte alignment between them.
  const mkAppend = () => {
    const pieces = [];
    let len = 0;
    return {
      get length() { return len; },
      add(u8) {
        const pad = (4 - (len % 4)) % 4;
        if (pad) { pieces.push(Buffer.alloc(pad)); len += pad; }
        const buf = Buffer.isBuffer(u8) ? u8
          : Buffer.from(u8.buffer, u8.byteOffset, u8.byteLength);
        pieces.push(buf);
        len += buf.length;
        return len - buf.length;    // start offset within the new buffer
      },
      build() { return Buffer.concat(pieces); },
    };
  };

  for (const f of FILES) {
    const p = path.join(ROOT, f);
    const orig = p.replace(/\.glb$/, ".orig.glb");
    if (!fs.existsSync(orig)) { fs.copyFileSync(p, orig); log("backup: " + f); }
    const { json, bin } = readGLB(p);

    let grandTotal = 0;
    for (const m of json.meshes)
      for (const pr of m.primitives)
        grandTotal += json.accessors[pr.indices].count / 3;
    log(`${f}: srcTris=${Math.round(grandTotal)} srcSize=${(bin.length / 1048576).toFixed(1)}MB`);
    if (grandTotal <= TARGET) { log(f + ": already under target"); continue; }
    const scale = TARGET / grandTotal;

    const app = mkAppend();
    let totalAfter = 0, vertsKept = 0, vertsBefore = 0, prIdx = 0;
    // Fresh bufferViews are ALL new: old views 0..N-1 are dropped entirely,
    // so kept view indices come from newViews' own 0-based indexing.
    const newViewBase = json.bufferViews.length;
    const newViews = [];
    const addView = (payload) => {
      const off = app.add(payload);
      newViews.push({ buffer: 0, byteOffset: off, byteLength: payload.length });
      return newViews.length - 1;
    };
    const pushAcc = (acc) => {
      const i = json.accessors.length;
      json.accessors.push(acc);
      return i;
    };

    for (const m of json.meshes) {
      const target = Math.max(1000, Math.floor(
        m.primitives.reduce((t, pr) =>
          t + json.accessors[pr.indices].count / 3, 0) * scale));
      for (const pr of m.primitives) {
        const posIdx = pr.attributes.POSITION;
        const idxIdx = pr.indices;
        if (posIdx === undefined || idxIdx === undefined) continue;
        const positions = readFloat32(bin, json, posIdx);
        const indices = readIndices(bin, json, idxIdx);
        const srcTris = indices.length / 3;
        const vertexCount = json.accessors[posIdx].count;
        const wantIdxCount = Math.min(srcTris, Math.max(3, target)) * 3;
        const [idxNew, err] = S.simplify(
          indices, positions, 3, wantIdxCount, targetError, []);
        log(`  prim ${prIdx++}: src=${srcTris} want=${wantIdxCount / 3} got=${idxNew.length / 3} err=${err.toPrecision(3)}`);
        if (idxNew.length >= indices.length) {
          // Could not reduce: rebuild this primitive's accessors as plain
          // whole-buffer copies anyway — the originals carve byteOffsets
          // into the old giant shared views, which cannot ride the rebuild.
          const ia = json.accessors[idxIdx];
          pr.indices = pushAcc({
            bufferView: addView(Buffer.from(new Uint32Array(indices).buffer)),
            componentType: ia.componentType,
            count: ia.count,
            type: "SCALAR",
            min: [0], max: [vertexCount - 1],
          });
          for (const attrName of Object.keys(pr.attributes)) {
            const srcIdx = pr.attributes[attrName];
            const acc = json.accessors[srcIdx];
            const stride = COMPSIZE[acc.componentType] * TYPECOUNT[acc.type];
            const bv2 = json.bufferViews[acc.bufferView];
            const base = (bv2.byteOffset || 0) + (acc.byteOffset || 0);
            const payload = Buffer.alloc(vertexCount * stride);
            bin.copy(payload, 0, base, base + vertexCount * stride);
            pr.attributes[attrName] = pushAcc({
              bufferView: addView(payload),
              componentType: acc.componentType,
              count: vertexCount,
              type: acc.type,
            });
            if (acc.min !== undefined) {
              json.accessors[pr.attributes[attrName]].min = acc.min;
              json.accessors[pr.attributes[attrName]].max = acc.max;
            }
          }
          totalAfter += srcTris;
          vertsKept += vertexCount;
          vertsBefore += vertexCount;
          continue;
        }

        // --- vertex compaction: keep only the surviving vertices ---
        const remap = new Map();       // oldVert -> newVert
        const remapArr = [];           // old vert of each new vertex
        for (const v of idxNew) {
          let nv = remap.get(v);
          if (nv === undefined) { nv = remap.size; remap.set(v, nv); remapArr.push(v); }
        }
        const newIndices = idxNew.map((v) => remap.get(v));
        const idxBv = addView(Buffer.from(new Uint32Array(newIndices).buffer));
        pr.indices = pushAcc({
          bufferView: idxBv,
          componentType: 5125,
          count: newIndices.length,
          type: "SCALAR",
          min: [0], max: [remap.size - 1],
        });

        for (const attrName of Object.keys(pr.attributes)) {
          const srcIdx = pr.attributes[attrName];
          const acc = json.accessors[srcIdx];
          const stride = COMPSIZE[acc.componentType] * TYPECOUNT[acc.type];
          const bv2 = json.bufferViews[acc.bufferView];
          const base = (bv2.byteOffset || 0) + (acc.byteOffset || 0);
          const out = Buffer.alloc(remap.size * stride);
          for (let nv = 0; nv < remapArr.length; nv++) {
            const ov = remapArr[nv];
            bin.copy(out, nv * stride, base + ov * stride, base + ov * stride + stride);
          }
          const attrBv = addView(out);
          pr.attributes[attrName] = pushAcc({
            bufferView: attrBv,
            componentType: acc.componentType,
            count: remap.size,
            type: acc.type,
          });
          if (acc.min !== undefined) {
            json.accessors[pr.attributes[attrName]].min = acc.min;
            json.accessors[pr.attributes[attrName]].max = acc.max;
          }
        }
        totalAfter += newIndices.length / 3;
        vertsKept += remap.size;
        vertsBefore += vertexCount;
      }
    }

    // STILL-ORIGINAL accessors (skipped prims, morphs, bind matrices)
    // point into the old GIANT shared views. Copying whole views would
    // drag ~88 MB of dead attribute data along — instead give each old
    // accessor its own compact slice-of-its-range view.
    const oldUserAcc = [];
    json.accessors.forEach((a) => {
      if (a.bufferView !== undefined && a.bufferView < newViewBase)
        oldUserAcc.push(a);
    });
    for (const a of oldUserAcc) {
      const need = a.count *
        ({ 5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4 }[a.componentType]) *
        ({ SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT4: 16 }[a.type]);
      const bv = json.bufferViews[a.bufferView];
      const start = (bv.byteOffset || 0) + (a.byteOffset || 0);
      const slice = bin.subarray(start, Math.min(start + need, bin.length));
      const off = app.add(slice);
      delete a.byteOffset;
      a.bufferView = newViews.length;
      newViews.push({ buffer: 0, byteOffset: off, byteLength: need });
    }

    // The rewritten primitives no longer reference the old accessors 0..127
    // (they got fresh ones). Prune every accessor no mesh still touches,
    // then reindex accessors, then reindex bufferViews in use.
    const usedAcc = new Set();
    for (const m of json.meshes)
      for (const pr of m.primitives) {
        if (pr.indices !== undefined) usedAcc.add(pr.indices);
        for (const k of Object.keys(pr.attributes))
          usedAcc.add(pr.attributes[k]);
      }
    const accRemap = new Map();       // old acc idx -> new idx
    const prunedAccessors = [];
    json.accessors.forEach((a, i) => {
      if (!usedAcc.has(i)) return;
      accRemap.set(i, prunedAccessors.length);
      prunedAccessors.push(a);
    });
    json.accessors = prunedAccessors;
    for (const m of json.meshes)
      for (const pr of m.primitives) {
        pr.indices = accRemap.get(pr.indices);
        for (const k of Object.keys(pr.attributes))
          pr.attributes[k] = accRemap.get(pr.attributes[k]);
      }

    // Same pruning pass for bufferViews no accessor references.
    const usedView = new Set(
      json.accessors.filter((a) => a.bufferView !== undefined)
        .map((a) => a.bufferView));
    const viewRemap2 = new Map();
    const prunedViews = [];
    newViews.forEach((v, i) => {
      if (!usedView.has(i)) return;
      viewRemap2.set(i, prunedViews.length);
      prunedViews.push(v);
    });
    json.accessors.forEach((a) => {
      if (a.bufferView !== undefined) a.bufferView = viewRemap2.get(a.bufferView);
    });
    json.bufferViews = prunedViews;

    // Byte-trim: keep only the buffer span the pruned views need.
    // Views are laid out contiguously except padding gaps; a compact
    // repack is safest — rematerialize each view's payload in order.
    const fullBin = app.build();
    const app2 = mkAppend();
    for (const bv of json.bufferViews) {
      const slice = fullBin.subarray(bv.byteOffset,
        bv.byteOffset + bv.byteLength);
      bv.byteOffset = app2.add(slice);
    }
    const trimmed = app2.build();
    json.buffers = [{ byteLength: trimmed.length }];
    writeGLB(p, json, trimmed);
    log(`decimated ${f}: ${Math.round(grandTotal)} -> ${Math.round(totalAfter)} tris; verts ${vertsBefore} -> ${vertsKept}; ${path.basename(p)} -> ${(fs.statSync(p).size / 1048576).toFixed(1)} MB`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
