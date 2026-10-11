#!/usr/bin/env node
"use strict";

function readGLB(file) {
  const fs = require("fs");
  const b = fs.readFileSync(file);
  if (b.readUInt32LE(0) !== 0x46546c67)
    throw new Error(file + ": bad GLB magic");
  const jsonLen = b.readUInt32LE(12);
  const json = JSON.parse(b.toString("utf8", 20, 20 + jsonLen));
  let binStart = 20 + jsonLen;
  if (binStart % 4 !== 0) binStart += 4 - (binStart % 4);
  let bin = null;
  if (binStart + 8 <= b.length && b.readUInt32LE(binStart + 4) === 0x004e4942) {
    const binLen = b.readUInt32LE(binStart);
    bin = b.subarray(binStart + 8, binStart + 8 + binLen);
  }
  return { json, bin };
}
function writeGLB(file, json, bin) {
  const fs = require("fs");
  const jsonBuf = Buffer.from(JSON.stringify(json), "utf8");
  const pad4 = (n) => (4 - (n % 4)) % 4;
  const jp = Buffer.alloc(pad4(jsonBuf.length)); jp.fill(0x20);
  const bp = bin && Buffer.alloc(pad4(bin.length));
  // Godot reads the next chunk header SEQUENTIALLY after the JSON payload
  // (no re-alignment), so each chunk's declared length must INCLUDE its
  // padding — otherwise the pad bytes get read as the next chunk header.
  const jsonLen = jsonBuf.length + jp.length;
  const binLen = bin ? bin.length + bp.length : 0;
  const total = 12 + 8 + jsonLen + (bin ? 8 + binLen : 0);
  const out = Buffer.alloc(total);
  let o = 0;
  out.writeUInt32LE(0x46546c67, o); o += 4;
  out.writeUInt32LE(2, o); o += 4;
  out.writeUInt32LE(total, o); o += 4;
  out.writeUInt32LE(jsonLen, o); o += 4;
  out.writeUInt32LE(0x4e4f534a, o); o += 4;
  jsonBuf.copy(out, o); o += jsonBuf.length; jp.copy(out, o); o += jp.length;
  if (bin) {
    out.writeUInt32LE(binLen, o); o += 4;
    out.writeUInt32LE(0x004e4942, o); o += 4;
    bin.copy(out, o); o += bin.length; bp.copy(out, o); o += bp.length;
  }
  fs.writeFileSync(file, out);
}

const COMPSIZE = { 5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4 };
const TYPECOUNT = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT4: 16 };

function readFloat32(bin, json, accIdx) {
  const acc = json.accessors[accIdx];
  const bv = json.bufferViews[acc.bufferView];
  const off = (bv.byteOffset || 0) + (acc.byteOffset || 0);
  const n = acc.count;
  const out = new Float32Array(n * 3);
  for (let i = 0; i < n * 3; i++) out[i] = bin.readFloatLE(off + i * 4);
  return out;
}
function readIndices(bin, json, accIdx) {
  const acc = json.accessors[accIdx];
  const bv = json.bufferViews[acc.bufferView];
  const off = (bv.byteOffset || 0) + (acc.byteOffset || 0);
  const n = acc.count;
  const out = new Uint32Array(n);
  if (acc.componentType === 5123) {
    for (let i = 0; i < n; i++) out[i] = bin.readUInt16LE(off + i * 2);
  } else if (acc.componentType === 5125) {
    for (let i = 0; i < n; i++) out[i] = bin.readUInt32LE(off + i * 4);
  } else if (acc.componentType === 5121) {
    for (let i = 0; i < n; i++) out[i] = bin.readUInt8(off + i);
  } else throw new Error("index type " + acc.componentType);
  return out;
}

module.exports = { readGLB, writeGLB, COMPSIZE, TYPECOUNT, readFloat32, readIndices };
