// Pion WebAssembly (wasm32) Minimal Browser Runtime (Zero Node.js Dependencies)
export const PION_WASM_RT_ABI = 2;
const TAG_STRING = 1, TAG_BYTES = 2, TAG_ARRAY = 3, TAG_MAP = 7, TAG_CHANNEL = 8, TAG_MUTEX = 9, TAG_ATOMIC = 10, TAG_STRBUF = 11, TAG_SCOPE = 12, TAG_WORLD = 13;
const FLAG_FROZEN = 1, FLAG_IMMORTAL = 2, HDR = 24, PAGE = 65536;
const FREE_CLASSES = (() => {
  const s = new Set([32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048]);
  for (let p = 2048; p <= 268435456; p *= 2) {
    s.add(p + 16);
    if (p < 268435456) s.add(((p * 3) / 2) + 16);
  }
  return Array.from(s).sort((a, b) => a - b);
})();
const FREE_CLASS_IDX = new Map(FREE_CLASSES.map((sz, i) => [sz, i]));
const ALLOC_MAGIC = 0x50494f4e, FREE_MAGIC = 0x46524545;
const dec = new TextDecoder("utf-8", { fatal: false });
const enc = new TextEncoder();

const _f64Buf = new ArrayBuffer(8);
const _f64Arr = new Float64Array(_f64Buf);
const _u64Arr = new BigUint64Array(_f64Buf);

function c99Pow(x, y) {
  if (y === 0) return 1.0;
  if (x === 1) return 1.0;
  if (x === -1 && (y === Infinity || y === -Infinity)) return 1.0;
  return Math.pow(x, y);
}

function c99Round(x) {
  if (!Number.isFinite(x) || x === 0) return x;
  const ax = Math.abs(x);
  const fl = Math.floor(ax);
  const res = (ax - fl >= 0.5) ? (fl + 1) : fl;
  return x < 0 ? -res : res;
}

export function fmtG(v, d) {
  if (Number.isNaN(v)) return "nan";
  if (v === Infinity) return "inf";
  if (v === -Infinity) return "-inf";
  if (v === 0) return Object.is(v, -0) ? "-0" : "0";
  _f64Arr[0] = v;
  const bits = _u64Arr[0];
  const sign = (bits >> 63n) !== 0n;
  const rawExp = Number((bits >> 52n) & 0x7ffn);
  const frac = bits & 0xfffffffffffffn;
  const mant = rawExp === 0 ? frac : ((1n << 52n) | frac);
  const e2 = rawExp === 0 ? -1074 : (rawExp - 1075);
  const p = d > 0 ? d : 1;
  let e10 = Math.floor(Math.log10(Math.abs(v)));
  const num = e2 >= 0 ? (mant << BigInt(e2)) : mant;
  const den = e2 >= 0 ? 1n : (1n << BigInt(-e2));
  const shift = (p - 1) - e10;
  let sNum = shift >= 0 ? (num * (10n ** BigInt(shift))) : num;
  let sDen = shift >= 0 ? den : (den * (10n ** BigInt(-shift)));
  const low = 10n ** BigInt(p - 1);
  const high = low * 10n;
  while (sNum < low * sDen) {
    e10 -= 1;
    sNum *= 10n;
  }
  while (sNum >= high * sDen) {
    e10 += 1;
    sDen *= 10n;
  }
  let q = sNum / sDen;
  const rem = sNum % sDen;
  const twiceRem = rem << 1n;
  if (twiceRem > sDen || (twiceRem === sDen && (q & 1n) === 1n)) {
    q += 1n;
  }
  if (q === high) {
    q = low;
    e10 += 1;
  }
  const digits = q.toString();
  const pfx = sign ? "-" : "";
  if (e10 < -4 || e10 >= p) {
    const trimmed = digits.replace(/0+$/, "");
    const mantStr = trimmed.length === 1 ? trimmed : (trimmed[0] + "." + trimmed.slice(1));
    const expSign = e10 >= 0 ? "+" : "-";
    const expAbs = Math.abs(e10).toString().padStart(2, "0");
    return pfx + mantStr + "e" + expSign + expAbs;
  }
  if (e10 < 0) {
    const trimmed = digits.replace(/0+$/, "");
    return pfx + "0." + "0".repeat(-e10 - 1) + trimmed;
  }
  const intPart = digits.slice(0, e10 + 1);
  const fracPart = digits.slice(e10 + 1).replace(/0+$/, "");
  return fracPart.length > 0 ? (pfx + intPart + "." + fracPart) : (pfx + intPart);
}
export { fmtG as formatG };

function splitmix64(x) {
  let z = BigInt.asUintN(64, x + 0x9e3779b97f4a7c15n);
  z = BigInt.asUintN(64, (z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n);
  z = BigInt.asUintN(64, (z ^ (z >> 27n)) * 0x94d049bb133111ebn);
  return BigInt.asUintN(64, z ^ (z >> 31n));
}
function wymix64(a, b) {
  const r = BigInt.asUintN(64, a) * BigInt.asUintN(64, b);
  return BigInt.asUintN(64, r ^ (r >> 64n));
}
function hashBytes(u8, dv, off, len, seed1, seed2) {
  const K = 0x9e3779b97f4a7c15n;
  const s1 = BigInt.asUintN(64, seed1 ^ 0x517cc1b727220a95n);
  const s2 = BigInt.asUintN(64, seed2 ^ K);
  const origLen = BigInt(len);
  let h = BigInt.asUintN(64, s1 ^ BigInt.asUintN(64, origLen * K));
  let p = off, rem = len;
  while (rem > 8) {
    h = wymix64(dv.getBigUint64(p, true) ^ s1, h ^ s2);
    p += 8; rem -= 8;
  }
  let tail = 0n;
  if (rem >= 4) {
    tail = BigInt(dv.getUint32(p, true)) | (BigInt(dv.getUint32(p + rem - 4, true)) << 32n);
  } else if (rem >= 2) {
    tail = BigInt(dv.getUint16(p, true)) | (BigInt(u8[p + rem - 1]) << 16n);
  } else if (rem === 1) {
    tail = BigInt(u8[p]);
  }
  h = wymix64(tail ^ s1, h ^ s2);
  h = wymix64(h ^ origLen, s2 ^ 0x94d049bb133111ebn);
  return h === 0n ? 1n : h;
}

function hashI64(k, seed1, seed2) {
  const s1 = BigInt.asUintN(64, seed1 ^ 0x517cc1b727220a95n);
  const s2 = BigInt.asUintN(64, seed2 ^ 0x9e3779b97f4a7c15n);
  const h = wymix64(BigInt.asUintN(64, k) ^ s1, s2);
  return h === 0n ? 1n : h;
}

export function createPionRuntime(opts = {}) {
  let memory = opts.memory || null, exp = opts.exports || null, buf = null, dv = null, u8 = null;
  let heapBase = 0, heapPtr = 0, heapEnd = 0, slabCtl = 0, hashSeed = 0n, hashSeed2 = 0n;
  const free = FREE_CLASSES.map(() => []);
  const largeFree = new Map();
  const channels = new Map();
  const rcDeferQueue = [];
  let jsDropDepth = 0;
  const out = [], err = [];
  const printFn = opts.print || ((s) => out.push(s));
  const printlnFn = opts.println || ((s) => out.push(s + "\n"));
  const eprintlnFn = opts.eprintln || ((s) => err.push(s + "\n"));

  const sync = () => {
    if (buf !== memory.buffer) {
      buf = memory.buffer; dv = new DataView(buf); u8 = new Uint8Array(buf); heapEnd = buf.byteLength;
      if (slabCtl > 0) dv.setUint32(slabCtl + 40, heapEnd >>> 0, true);
    }
  };
  const pNum = (v) => (typeof v === "bigint" ? Number(v) : (v | 0));
  const pBig = (n) => BigInt(n >>> 0);
  const g64 = (p) => dv.getBigInt64(p, true);
  const s64 = (p, v) => dv.setBigInt64(p, BigInt(v), true);
  const g32 = (p) => dv.getInt32(p, true);
  const s32 = (p, v) => dv.setInt32(p, v | 0, true);
  const gu32 = (p) => dv.getUint32(p, true);
  const su32 = (p, v) => dv.setUint32(p, v >>> 0, true);
  const getHp = () => (slabCtl > 0 ? gu32(slabCtl + 36) : heapPtr);
  const setHp = (v) => { heapPtr = v >>> 0; if (slabCtl > 0) su32(slabCtl + 36, heapPtr); };

  function bindExports(e) {
    exp = e; if (e.memory) memory = e.memory; slabCtl = 0; sync();
    const hb = e.__heap_base;
    const base = typeof hb === "number" ? hb : (hb && typeof hb.value === "number" ? hb.value : 0x30000);
    heapBase = (base + 15) & ~15; heapPtr = heapBase; heapEnd = memory.buffer.byteLength;
    const sc = e.__pion_slab_ctl;
    slabCtl = typeof sc === "number" ? sc : (sc && typeof sc.value === "number" ? sc.value : 0);
    const ra = e.__pion_wasm_rt_abi;
    const modAbi = typeof ra === "number" ? ra : (ra && typeof ra.value === "number" ? ra.value : 0);
    if ((slabCtl > 0 || ra !== undefined) && modAbi !== PION_WASM_RT_ABI) {
      throw new Error(
        `Pion Wasm runtime ABI mismatch: runtime expects v${PION_WASM_RT_ABI}, module exports v${modAbi}. ` +
        `Sync runtime/pion_wasm_rt*.mjs with the pionc version that built this .wasm.`
      );
    }
    if (typeof globalThis.crypto !== "undefined" && typeof globalThis.crypto.getRandomValues === "function") {
      const sb = new BigUint64Array(2); globalThis.crypto.getRandomValues(sb); hashSeed = sb[0]; hashSeed2 = sb[1];
    } else {
      hashSeed = BigInt.asUintN(64, (BigInt(Math.floor(Math.random() * 0xffffffff)) << 32n) ^ BigInt(Date.now()));
      hashSeed2 = splitmix64(hashSeed ^ 0x9e3779b97f4a7c15n);
    }
    if (slabCtl > 0) {
      u8.fill(0, slabCtl, slabCtl + 96);
      su32(slabCtl + 36, heapPtr); su32(slabCtl + 40, heapEnd); su32(slabCtl + 44, heapBase);
      dv.setBigUint64(slabCtl + 64, hashSeed, true);
      dv.setBigUint64(slabCtl + 72, hashSeed2, true);
    }
    for (let i = 0; i < free.length; i++) free[i].length = 0;
    largeFree.clear();
    channels.clear();
    rcDeferQueue.length = 0;
    jsDropDepth = 0;
  }

  function clsIdx(n) {
    let lo = 0, hi = FREE_CLASSES.length - 1, ans = -1;
    while (lo <= hi) {
      const m = (lo + hi) >>> 1;
      if (FREE_CLASSES[m] >= n) { ans = m; hi = m - 1; } else lo = m + 1;
    }
    return ans;
  }
  function roundLarge(need) {
    let p = 32768; while (p < need) p *= 2;
    const tq = (p / 2) + (p / 4);
    return need <= tq ? tq : p;
  }
  function rawAlloc(sz) {
    if (!Number.isFinite(sz) || sz < 0 || sz > 0x7FFFFFE8) pionDie("allocation size exceeds wasm32 limit");
    sync();
    const need = Math.ceil(sz / 8) * 8 + 8, c = clsIdx(need);
    if (c >= 0) {
      if (slabCtl > 0 && c < 9) {
        const so = slabCtl + c * 4, h = gu32(so);
        if (h !== 0) { su32(so, gu32(h + 8)); su32(h, FREE_CLASSES[c]); su32(h + 4, ALLOC_MAGIC); return h + 8; }
      } else if (free[c].length) {
        const b = free[c].pop(); su32(b, FREE_CLASSES[c]); su32(b + 4, ALLOC_MAGIC); return b + 8;
      }
    }
    const asz = c >= 0 ? FREE_CLASSES[c] : roundLarge(need);
    if (c < 0) {
      const bk = largeFree.get(asz);
      if (bk && bk.length) { const b = bk.pop(); su32(b, asz); su32(b + 4, ALLOC_MAGIC); return b + 8; }
    }
    const hp = getHp();
    if (hp + asz > 0xFFFF0000) pionDie("wasm32 out of memory");
    if (hp + asz > heapEnd) {
      const missing = hp + asz - heapEnd;
      const curPages = heapEnd >>> 16;
      const minGrow = Math.ceil(missing / PAGE);
      const expGrow = Math.min(curPages >>> 1, 512);
      const maxAllowed = Math.max(0, 65535 - curPages);
      const targetGrow = Math.max(16, minGrow, expGrow);
      const growPages = minGrow > maxAllowed ? minGrow : Math.min(maxAllowed, targetGrow);
      memory.grow(growPages); sync();
    }
    const b = hp; setHp(hp + asz); su32(b, asz); su32(b + 4, ALLOC_MAGIC); return b + 8;
  }
  const rawZero = (sz) => { const p = rawAlloc(sz); u8.fill(0, p, p + sz); return p; };
  function rawFree(ptr) {
    if (!ptr) return; sync();
    const hp = getHp(), b = ptr - 8;
    if (b < heapBase || b + 8 > hp || (b & 7) !== 0) return;
    const mg = gu32(b + 4);
    if (mg === FREE_MAGIC || mg !== ALLOC_MAGIC) return;
    const asz = gu32(b);
    if (asz < 16 || b + asz > hp) return;
    su32(b + 4, FREE_MAGIC);
    if (b + asz === hp) { setHp(b); return; }
    const c = FREE_CLASS_IDX.get(asz);
    if (c !== undefined) {
      if (slabCtl > 0 && c < 9) { const so = slabCtl + c * 4; su32(b + 8, gu32(so)); su32(so, b); }
      else free[c].push(b);
    } else { let bk = largeFree.get(asz); if (!bk) { bk = []; largeFree.set(asz, bk); } bk.push(b); }
  }

  function allocObj(sz, tag, drop, zero) {
    const hdr = zero ? rawZero(HDR + (sz >>> 0)) : rawAlloc(HDR + (sz >>> 0));
    su32(hdr, 1); su32(hdr + 4, 1); su32(hdr + 8, 0);
    dv.setUint16(hdr + 12, tag & 0xffff, true); dv.setUint16(hdr + 14, 0, true);
    s64(hdr + 16, drop || 0n);
    return pBig(hdr + HDR);
  }
  const pion_alloc = (sz, tag, drop) => allocObj(sz, tag, drop, true);
  const pion_alloc_uninit = (sz, tag, drop) => allocObj(sz, tag, drop, false);

  function pion_rc_inc(obj) {
    const p = pNum(obj); if (!p) return; sync();
    const h = p - HDR; if (dv.getUint16(h + 14, true) & FLAG_IMMORTAL) return;
    const off = gu32(h) === 0 ? 8 : 4; su32(h + off, gu32(h + off) + 1);
  }

  const getDropDepth = () => (slabCtl > 0 ? gu32(slabCtl + 80) : jsDropDepth);
  const setDropDepth = (d) => { jsDropDepth = d >>> 0; if (slabCtl > 0) su32(slabCtl + 80, jsDropDepth); };

  function pion_rc_dec_slow_one(obj) {
    const p = pNum(obj); if (!p) return; sync();
    const h = p - HDR;
    const dropIdx = Number(g64(h + 16)), tag = dv.getUint16(h + 12, true);
    if (dropIdx) {
      s64(h + 16, 0);
      if ((dropIdx & 0x80000000) !== 0) {
        let m = dropIdx & 0x7fffffff;
        for (let b = 0; m !== 0; b++, m >>>= 1) {
          if (m & 1) { const ev = g64(p + b * 8); if (ev) { pion_rc_dec(ev); sync(); } }
        }
      } else if (exp && exp.__indirect_function_table) {
        const fn = exp.__indirect_function_table.get(dropIdx);
        if (fn) fn(pBig(p)); sync();
      }
    }
    if (tag === TAG_ARRAY) {
      const len = Number(g64(p)), isObj = g32(p + 16), st = g32(p + 20), dp = Number(g64(p + 24));
      arrRcAll(dp, len, isObj, st, false);
      if (dp) rawFree(dp);
    } else if (tag === TAG_MAP) {
      if (slabCtl > 0) su32(slabCtl + 48, 0);
      const cap = Number(g64(p + 8)), vObj = g32(p + 16), kInt = g32(p + 20), es = Number(g64(p + 24));
      if (es) {
        for (let i = 0; i < cap; i++) {
          const e = es + i * 32;
          if (u8[e + 24] === 1) {
            if (!kInt) { const k = g64(e); if (k) pion_rc_dec(k); sync(); }
            if (vObj) { const v = g64(e + 16); if (v) pion_rc_dec(v); sync(); }
          }
        }
        rawFree(es);
      }
    } else if (tag === TAG_BYTES || tag === TAG_STRBUF) {
      const dp = Number(g64(p + 16)); if (dp) rawFree(dp);
    } else if (tag === TAG_MUTEX) {
      if (g32(p + 8)) { const v = g64(p); if (v !== 0n) pion_rc_dec(v); }
    } else if (tag === TAG_CHANNEL) {
      const ch = channels.get(p);
      if (ch) {
        if (ch.elemIsObj) for (const v of ch.queue) pion_rc_dec(v);
        channels.delete(p);
      }
    }
    rawFree(h);
  }

  function pion_rc_dec_drain() {
    const prev = getDropDepth();
    setDropDepth(prev + 1);
    try {
      while (rcDeferQueue.length > 0) {
        if (slabCtl > 0) su32(slabCtl + 84, 0);
        const next = rcDeferQueue.pop();
        pion_rc_dec_slow_one(next);
        sync();
      }
      if (slabCtl > 0) su32(slabCtl + 84, 0);
    } finally {
      sync();
      setDropDepth(prev);
    }
  }

  function pion_rc_dec_slow(obj) {
    sync();
    const p = pNum(obj);
    if (!p) {
      if (rcDeferQueue.length > 0) pion_rc_dec_drain();
      return;
    }
    const curDepth = getDropDepth();
    if (curDepth >= 64) {
      rcDeferQueue.push(obj);
      if (slabCtl > 0) su32(slabCtl + 84, 1);
      return;
    }
    setDropDepth(curDepth + 1);
    try {
      pion_rc_dec_slow_one(obj);
    } finally {
      sync();
      setDropDepth(curDepth);
    }
    if (curDepth === 0 && rcDeferQueue.length > 0) {
      pion_rc_dec_drain();
    }
  }

  function pion_rc_dec(obj) {
    const p = pNum(obj); if (!p) return; sync();
    const h = p - HDR; if (dv.getUint16(h + 14, true) & FLAG_IMMORTAL) return;
    const off = gu32(h) === 0 ? 8 : 4, rc = (gu32(h + off) - 1) >>> 0;
    su32(h + off, rc); if (rc !== 0) return;
    imports.pion_rt.pion_rc_dec_slow(obj);
  }

  function pion_rc_freeze(obj) {
    const p = pNum(obj); if (!p) return; sync();
    const h = p - HDR, f = dv.getUint16(h + 14, true);
    if (f & (FLAG_IMMORTAL | FLAG_FROZEN)) return;
    su32(h + 8, gu32(h + 4) + gu32(h + 8)); su32(h, 0); su32(h + 4, 0);
    dv.setUint16(h + 14, f | FLAG_FROZEN, true);
  }
  function pion_rc_immortalize(obj) {
    const p = pNum(obj); if (!p) return; sync();
    dv.setUint16(p - HDR + 14, dv.getUint16(p - HDR + 14, true) | FLAG_IMMORTAL, true);
  }

  function readCStr(ptr) { const p = pNum(ptr); if (!p) return ""; sync(); let e = p; while (u8[e]) e++; return dec.decode(u8.subarray(p, e)); }
  function readStr(ptr) { const p = pNum(ptr); if (!p) return ""; sync(); return dec.decode(u8.subarray(p + 8, p + 8 + Number(g64(p)))); }
  function mkStrBytes(bs) {
    const n = bs.length, o = pion_alloc_uninit(9 + n, TAG_STRING, 0n), p = pNum(o); sync();
    s64(p, n); u8.set(bs, p + 8); u8[p + 8 + n] = 0; return o;
  }
  const mkStr = (s) => mkStrBytes(enc.encode(s));
  const fail = (m) => { eprintlnFn(m); throw new Error(m); };
  const pion_panic = (m, f, l) => fail(`pion panic at ${readCStr(f)}:${l}: ${readCStr(m)}`);
  const pion_panic_oob = (i, n) => fail(`pion panic: oob idx=${i} len=${n}`);
  const pion_debug_assert = (c, m, f, l) => { if ((c | 0) === 0) fail(`assert failed at ${readCStr(f)}:${l}: ${readStr(m)}`); };

  function pion_str_from_cstr(cp, len) {
    const n = Number(len), src = pNum(cp), o = pion_alloc_uninit(9 + n, TAG_STRING, 0n), d = pNum(o); sync();
    s64(d, n); if (n > 0 && src) u8.copyWithin(d + 8, src, src + n); u8[d + 8 + n] = 0; return o;
  }
  const pion_str_len = (s) => { const p = pNum(s); if (!p) return 0n; sync(); return g64(p); };
  function pion_str_byte_at(s, idx) {
    const p = pNum(s); sync(); const n = g64(p);
    if (idx < 0n || idx >= n) pion_panic_oob(idx, n); return u8[p + 8 + Number(idx)];
  }
  function pion_str_concat(a, b) {
    const pa = pNum(a), pb = pNum(b); sync();
    const la = pa ? Number(g64(pa)) : 0, lb = pb ? Number(g64(pb)) : 0, tot = la + lb;
    const o = pion_alloc_uninit(9 + tot, TAG_STRING, 0n), d = pNum(o); sync();
    s64(d, tot); if (la) u8.copyWithin(d + 8, pa + 8, pa + 8 + la);
    if (lb) u8.copyWithin(d + 8 + la, pb + 8, pb + 8 + lb); u8[d + 8 + tot] = 0; return o;
  }
  function pion_str_concat_n(n, pp0) {
    const cnt = Number(n), pp = pNum(pp0); sync();
    let tot = 0; const ps = new Array(cnt), ls = new Array(cnt);
    for (let i = 0; i < cnt; i++) { const sp = Number(g64(pp + i * 8)); ps[i] = sp; tot += (ls[i] = sp ? Number(g64(sp)) : 0); }
    const o = pion_alloc_uninit(9 + tot, TAG_STRING, 0n), d = pNum(o); sync(); s64(d, tot);
    let off = 0;
    for (let i = 0; i < cnt; i++) if (ls[i]) { u8.copyWithin(d + 8 + off, ps[i] + 8, ps[i] + 8 + ls[i]); off += ls[i]; }
    u8[d + 8 + tot] = 0; return o;
  }
  function pion_str_eq(a, b) {
    const pa = pNum(a), pb = pNum(b); if (pa === pb) return 1; if (!pa || !pb) return 0; sync();
    const la = Number(g64(pa)); if (la !== Number(g64(pb))) return 0;
    for (let i = 0; i < la; i++) if (u8[pa + 8 + i] !== u8[pb + 8 + i]) return 0;
    return 1;
  }
  function pion_str_cmp(a, b) {
    const pa = pNum(a), pb = pNum(b); if (pa === pb) return 0; sync();
    const la = pa ? Number(g64(pa)) : 0, lb = pb ? Number(g64(pb)) : 0, m = Math.min(la, lb);
    for (let i = 0; i < m; i++) { const x = u8[pa + 8 + i], y = u8[pb + 8 + i]; if (x !== y) return x < y ? -1 : 1; }
    return la < lb ? -1 : (la > lb ? 1 : 0);
  }
  function pion_str_slice(s, st, en) {
    const ps = pNum(s); sync(); const len = Number(g64(ps));
    let a = Math.max(0, Number(st)), b = Math.min(len, Number(en)); if (b < a) b = a;
    const n = b - a, o = pion_alloc_uninit(9 + n, TAG_STRING, 0n), d = pNum(o); sync();
    s64(d, n); if (n) u8.copyWithin(d + 8, ps + 8 + a, ps + 8 + b); u8[d + 8 + n] = 0; return o;
  }
  const pion_int_to_str = (v) => mkStr(BigInt(v).toString(10));
  const pion_uint64_to_str = (v) => mkStr(BigInt.asUintN(64, BigInt(v)).toString(10));
  function pion_double_to_str(v) {
    let s = fmtG(v, 15);
    if (Number.isFinite(v) && Number(s) !== v) { s = fmtG(v, 16); if (Number(s) !== v) s = fmtG(v, 17); }
    return mkStr(s);
  }
  const pion_float_to_str = (v) => mkStr(fmtG(Math.fround(v), 7));
  function pion_str_to_int(s, ok) {
    const t = readStr(s).trim(), op = pNum(ok); sync();
    if (/^[+-]?\d+$/.test(t)) {
      try { const v = BigInt(t); if (v >= -9223372036854775808n && v <= 9223372036854775807n) { if (op) s32(op, 1); return v; } } catch {}
    }
    if (op) s32(op, 0); return 0n;
  }
  function pion_str_to_double(s, ok) {
    const t = readStr(s).trim(), op = pNum(ok); sync();
    if (t.length) { const v = Number(t); if (!Number.isNaN(v)) { if (op) s32(op, 1); return v; } }
    if (op) s32(op, 0); return 0.0;
  }
  function pion_str_starts_with(s, pre) {
    const ps = pNum(s), pp = pNum(pre); sync(); const ls = Number(g64(ps)), lp = Number(g64(pp));
    if (lp > ls) return 0; for (let i = 0; i < lp; i++) if (u8[ps + 8 + i] !== u8[pp + 8 + i]) return 0; return 1;
  }
  function pion_str_ends_with(s, suf) {
    const ps = pNum(s), pp = pNum(suf); sync(); const ls = Number(g64(ps)), lp = Number(g64(pp));
    if (lp > ls) return 0; const o = ls - lp;
    for (let i = 0; i < lp; i++) if (u8[ps + 8 + o + i] !== u8[pp + 8 + i]) return 0; return 1;
  }
  function pion_str_index_of(s, nd) {
    const ps = pNum(s), pn = pNum(nd); sync(); const ls = Number(g64(ps)), ln = Number(g64(pn));
    if (!ln) return 0n; if (ln > ls) return -1n;
    outer: for (let i = 0; i <= ls - ln; i++) {
      for (let j = 0; j < ln; j++) if (u8[ps + 8 + i + j] !== u8[pn + 8 + j]) continue outer;
      return BigInt(i);
    }
    return -1n;
  }
  const pion_str_contains = (s, n) => (pion_str_index_of(s, n) >= 0n ? 1 : 0);
  function pion_str_trim(s) {
    const ps = pNum(s); sync(); let a = 0, b = Number(g64(ps));
    const ws = (c) => c === 32 || c === 9 || c === 10 || c === 13;
    while (a < b && ws(u8[ps + 8 + a])) a++;
    while (b > a && ws(u8[ps + 8 + b - 1])) b--;
    return pion_str_slice(s, BigInt(a), BigInt(b));
  }
  function pion_str_split(s, sep) {
    const str = readStr(s), sp = readStr(sep), ps = sp.length ? str.split(sp) : [str];
    const arr = pion_arr_new(BigInt(ps.length), 1);
    for (let i = 0; i < ps.length; i++) pion_arr_push_owned(arr, mkStr(ps[i]));
    return arr;
  }
  function pion_str_replace(s, f, t) {
    const fs = readStr(f); return mkStr(fs.length ? readStr(s).split(fs).join(readStr(t)) : readStr(s));
  }
  function pion_str_to_bytes(s) {
    const ps = pNum(s); sync(); const n = Number(g64(ps)), b = pion_bytes_new(BigInt(n)); sync();
    if (n) u8.copyWithin(Number(g64(pNum(b) + 16)), ps + 8, ps + 8 + n); return b;
  }
  function pion_bytes_to_str(b) {
    const pb = pNum(b); sync(); const n = Number(g64(pb)), dp = Number(g64(pb + 16));
    const o = pion_alloc_uninit(9 + n, TAG_STRING, 0n), d = pNum(o); sync();
    s64(d, n); if (n && dp) u8.copyWithin(d + 8, dp, dp + n); u8[d + 8 + n] = 0; return o;
  }

  const pionDie = (msg) => { const err = `pion panic: ${msg}`; eprintlnFn(err); throw new Error(err); };
  function pion_bytes_new(len) {
    const lb = BigInt(len);
    if (lb < 0n) pionDie("negative bytes length");
    if (lb > 0x7FFFFFEFn) pionDie("container length exceeds maximum");
    const n = Number(lb), cap = Math.max(n, 16), o = pion_alloc_uninit(24, TAG_BYTES, 0n);
    const dp = rawZero(cap), p = pNum(o); sync(); s64(p, n); s64(p + 8, cap); s64(p + 16, pBig(dp)); return o;
  }
  const pion_bytes_len = (b) => { sync(); return g64(pNum(b)); };
  function pion_bytes_get(b, i) { const p = pNum(b); sync(); const n = g64(p); if (i < 0n || i >= n) pion_panic_oob(i, n); return u8[Number(g64(p + 16)) + Number(i)]; }
  function pion_bytes_set(b, i, v) { const p = pNum(b); sync(); const n = g64(p); if (i < 0n || i >= n) pion_panic_oob(i, n); if (g64(p + 8) < 0n) pionDie("cannot mutate read-only mmap Bytes"); u8[Number(g64(p + 16)) + Number(i)] = v & 0xff; }
  function pion_bytes_slice(b, st, en) {
    const pb = pNum(b); sync(); const len = Number(g64(pb));
    let a = Math.max(0, Number(st)), e = Math.min(len, Number(en)); if (e < a) e = a;
    const n = e - a, o = pion_bytes_new(BigInt(n)); sync();
    if (n) u8.copyWithin(Number(g64(pNum(o) + 16)), Number(g64(pb + 16)) + a, Number(g64(pb + 16)) + e); return o;
  }
  function pion_bytes_concat(a, b) {
    const pa = pNum(a), pb = pNum(b); sync(); const la = Number(g64(pa)), lb = Number(g64(pb));
    const o = pion_bytes_new(BigInt(la + lb)); sync(); const dst = Number(g64(pNum(o) + 16));
    if (la) u8.copyWithin(dst, Number(g64(pa + 16)), Number(g64(pa + 16)) + la);
    if (lb) u8.copyWithin(dst + la, Number(g64(pb + 16)), Number(g64(pb + 16)) + lb); return o;
  }
  function pion_bytes_from_ptr(ptr, len) {
    const lb = BigInt(len);
    if (lb < 0n) pionDie("negative bytes length");
    if (lb > 0x7FFFFFEFn) pionDie("container length exceeds maximum");
    const n = Number(lb), o = pion_bytes_new(lb), src = pNum(ptr); sync();
    if (n && src) u8.copyWithin(Number(g64(pNum(o) + 16)), src, src + n); return o;
  }
  function pion_bytes_copy_to_ptr(b, off, dp0, len) {
    const pb = pNum(b), dst = pNum(dp0), n = Math.max(0, Number(len)), o = Math.max(0, Number(off)); sync();
    const src = Number(g64(pb + 16)); if (n && dst && src) u8.copyWithin(dst, src + o, src + o + n);
  }
  function pion_bytes_blit(srcData, srcLen, srcOff, dstObj, dstOff, len) {
    const sl = BigInt(srcLen), so = BigInt(srcOff), doff = BigInt(dstOff), n = BigInt(len);
    if (n < 0n || so < 0n || so > sl || n > sl - so) pion_panic_oob(so < 0n ? so : (n < 0n ? n : so + n), sl);
    const pd = pNum(dstObj); sync();
    const dl = pd ? g64(pd) : 0n;
    if (!pd || doff < 0n || doff > dl || n > dl - doff) pion_panic_oob(doff < 0n ? doff : doff + n, dl);
    if (g64(pd + 8) < 0n) pionDie("cannot mutate read-only mmap Bytes");
    const ni = Number(n);
    if (ni > 0) u8.copyWithin(Number(g64(pd + 16)) + Number(doff), pNum(srcData) + Number(so), pNum(srcData) + Number(so) + ni);
  }

  function pion_strbuf_new(cap) {
    const c = Math.max(Number(cap), 32), o = pion_alloc_uninit(24, TAG_STRBUF, 0n), dp = rawAlloc(c), p = pNum(o);
    sync(); s64(p, 0); s64(p + 8, c); s64(p + 16, pBig(dp)); return o;
  }
  function sbEnsure(p, ex) {
    sync(); const len = Number(g64(p)), cap = Number(g64(p + 8)); if (len + ex <= cap) return;
    const nc = Math.max(cap * 2, len + ex + 32), old = Number(g64(p + 16)), nd = rawAlloc(nc); sync();
    if (len && old) u8.copyWithin(nd, old, old + len); if (old) rawFree(old);
    s64(p + 8, nc); s64(p + 16, pBig(nd));
  }
  function pion_strbuf_push_str(sb, s) {
    const p = pNum(sb), ps = pNum(s); if (!ps) return; sync(); const sl = Number(g64(ps)); if (!sl) return;
    sbEnsure(p, sl); sync(); const l = Number(g64(p));
    u8.copyWithin(Number(g64(p + 16)) + l, ps + 8, ps + 8 + sl); s64(p, l + sl);
  }
  function pion_strbuf_push_slice(sb, s, st, en) {
    const p = pNum(sb), ps = pNum(s); if (!p || !ps) return; sync(); const sl = Number(g64(ps));
    let a = Math.max(0, Number(st)), b = Math.min(sl, Number(en)); if (a >= b) return;
    const n = b - a; sbEnsure(p, n); sync(); const l = Number(g64(p));
    u8.copyWithin(Number(g64(p + 16)) + l, ps + 8 + a, ps + 8 + b); s64(p, l + n);
  }
  function pion_strbuf_push_byte(sb, b) {
    const p = pNum(sb); sbEnsure(p, 1); sync(); const l = Number(g64(p));
    u8[Number(g64(p + 16)) + l] = b & 0xff; s64(p, l + 1);
  }
  function pion_strbuf_push_char(sb, cp) {
    const c = cp >>> 0; if (c < 0x80) { pion_strbuf_push_byte(sb, c); return; }
    const bs = enc.encode(String.fromCodePoint(c)), p = pNum(sb); sbEnsure(p, bs.length); sync();
    const l = Number(g64(p)); u8.set(bs, Number(g64(p + 16)) + l); s64(p, l + bs.length);
  }
  function pion_strbuf_push_int(sb, v) {
    const bs = enc.encode(BigInt(v).toString(10)), p = pNum(sb); sbEnsure(p, bs.length); sync();
    const l = Number(g64(p)); u8.set(bs, Number(g64(p + 16)) + l); s64(p, l + bs.length);
  }
  const pion_strbuf_reset = (sb) => { sync(); s64(pNum(sb), 0); };
  function pion_strbuf_to_str(sb) {
    const p = pNum(sb); sync(); const l = Number(g64(p)), dp = Number(g64(p + 16));
    const o = pion_alloc_uninit(9 + l, TAG_STRING, 0n), d = pNum(o); sync();
    s64(d, l); if (l && dp) u8.copyWithin(d + 8, dp, dp + l); u8[d + 8 + l] = 0; return o;
  }

  const arrStride = (p) => { const s = g32(p + 20); return s > 0 ? s : 8; };
  function arrRcAll(dp, len, isObj, st, isInc) {
    if (!isObj || !dp || len <= 0) return;
    if (st <= 8) {
      for (let i = 0; i < len; i++) { const v = g64(dp + i * 8); if (v) { if (isInc) pion_rc_inc(v); else pion_rc_dec(v); sync(); } }
    } else {
      const mask = isObj >>> 0;
      for (let i = 0; i < len; i++) {
        const base = dp + i * st;
        for (let m = mask, k = 0; m !== 0; m >>>= 1, k++) {
          if (m & 1) { const v = g64(base + k * 8); if (v) { if (isInc) pion_rc_inc(v); else pion_rc_dec(v); sync(); } }
        }
      }
    }
  }
  function pion_arr_new(cap, flags) {
    const cb = BigInt(cap);
    if (cb > 0x7FFFFFEFn) pionDie("container length exceeds maximum");
    const c = Math.max(Number(cb), 0), f = flags | 0;
    const isObj = f > 2 ? (f >>> 8) : (f === 1 ? 1 : 0), st = f === 2 ? 1 : (f > 2 ? (f & 0xFF) : 0), esz = st || 8;
    if (cb * BigInt(esz) > 0x7FFFFFE8n) pionDie("container byte size exceeds wasm32 limit");
    const o = pion_alloc_uninit(32, TAG_ARRAY, 0n);
    const dp = c ? rawAlloc(c * esz) : 0, p = pNum(o); sync();
    s64(p, 0); s64(p + 8, c); s32(p + 16, isObj); s32(p + 20, st); s64(p + 24, pBig(dp)); return o;
  }
  const pion_arr_len = (a) => { sync(); return g64(pNum(a)); };
  function arrEnsure(p, need) {
    sync(); const cap = Number(g64(p + 8)); if (need <= cap) return;
    let nc = cap < 8 ? 8 : cap * 2; while (nc < need) nc *= 2;
    const len = Number(g64(p)), esz = arrStride(p), old = Number(g64(p + 24)), nd = rawAlloc(nc * esz); sync();
    if (len && old) u8.copyWithin(nd, old, old + len * esz); if (old) rawFree(old);
    s64(p + 8, nc); s64(p + 24, pBig(nd));
  }
  function pion_arr_push_flat_grow(a) {
    const p = pNum(a); sync(); const l = Number(g64(p)); arrEnsure(p, l + 1); sync();
    return pBig(Number(g64(p + 24)) + l * arrStride(p));
  }
  function pion_arr_push(a, v) {
    const p = pNum(a); sync(); const l = Number(g64(p)), isObj = g32(p + 16), st = g32(p + 20);
    arrEnsure(p, l + 1);
    if (st === 1) { sync(); u8[Number(g64(p + 24)) + l] = Number(v) & 0xff; s64(p, l + 1); return; }
    if (st === 4) { sync(); dv.setUint32(Number(g64(p + 24)) + l * 4, Number(BigInt(v) & 0xffffffffn), true); s64(p, l + 1); return; }
    if (isObj && v) pion_rc_inc(v); sync();
    s64(Number(g64(p + 24)) + l * 8, v); s64(p, l + 1);
  }
  function pion_arr_push_owned(a, v) {
    const p = pNum(a); sync(); const l = Number(g64(p)), st = g32(p + 20); arrEnsure(p, l + 1); sync();
    const dp = Number(g64(p + 24));
    if (st === 1) u8[dp + l] = Number(v) & 0xff;
    else if (st === 4) dv.setUint32(dp + l * 4, Number(BigInt(v) & 0xffffffffn), true);
    else s64(dp + l * 8, v);
    s64(p, l + 1);
  }
  function pion_arr_get(a, i) {
    const p = pNum(a); sync(); const n = g64(p); if (i < 0n || i >= n) pion_panic_oob(i, n);
    const dp = Number(g64(p + 24)), st = g32(p + 20);
    return st === 1 ? BigInt(u8[dp + Number(i)]) : st === 4 ? BigInt(dv.getUint32(dp + Number(i) * 4, true)) : g64(dp + Number(i) * 8);
  }
  function pion_arr_set(a, i, v) {
    const p = pNum(a); sync(); const n = g64(p); if (i < 0n || i >= n) pion_panic_oob(i, n);
    const dp = Number(g64(p + 24)), st = g32(p + 20);
    if (st === 1) { u8[dp + Number(i)] = Number(v) & 0xff; return; }
    if (st === 4) { dv.setUint32(dp + Number(i) * 4, Number(BigInt(v) & 0xffffffffn), true); return; }
    const isObj = g32(p + 16), off = dp + Number(i) * 8, old = g64(off);
    if (isObj && v) pion_rc_inc(v); sync(); s64(off, v); if (isObj && old) pion_rc_dec(old);
  }
  function pion_arr_pop(a) {
    const p = pNum(a); sync(); const l = Number(g64(p)); if (l <= 0) pion_panic_oob(-1n, 0n);
    const dp = Number(g64(p + 24)), st = g32(p + 20);
    const v = st === 1 ? BigInt(u8[dp + (l - 1)]) : st === 4 ? BigInt(dv.getUint32(dp + (l - 1) * 4, true)) : g64(dp + (l - 1) * 8);
    s64(p, l - 1); return v;
  }
  function pion_arr_copy(a) {
    const p = pNum(a); sync(); const l = Number(g64(p)), isObj = g32(p + 16), st = g32(p + 20);
    const fl = st > 1 ? (st | (isObj << 8)) : (st === 1 ? 2 : isObj), esz = st || 8, o = pion_arr_new(BigInt(l), fl);
    const po = pNum(o); sync(); const src = Number(g64(p + 24)), dst = Number(g64(po + 24));
    if (l) { u8.copyWithin(dst, src, src + l * esz); arrRcAll(dst, l, isObj, st, true); }
    s64(po, l); return o;
  }
  function pion_arr_truncate(a, newLen) {
    const p = pNum(a); sync(); const l = Number(g64(p));
    let n = Number(newLen); if (n < 0) n = 0;
    if (n >= l) return;
    const isObj = g32(p + 16), st = g32(p + 20), dp = Number(g64(p + 24));
    if (isObj) arrRcAll(dp + n * arrStride(p), l - n, isObj, st, false);
    s64(p, n);
  }
  function pion_arr_clear(a) {
    pion_arr_truncate(a, 0);
  }
  function pion_arr_reverse(a) {
    const p = pNum(a); sync(); const l = Number(g64(p)), dp = Number(g64(p + 24)), st = arrStride(p);
    if (st === 8) {
      for (let i = 0, j = l - 1; i < j; i++, j--) { const x = g64(dp + i * 8); s64(dp + i * 8, g64(dp + j * 8)); s64(dp + j * 8, x); }
    } else {
      const tmp = new Uint8Array(st);
      for (let i = 0, j = l - 1; i < j; i++, j--) {
        const oi = dp + i * st, oj = dp + j * st;
        tmp.set(u8.subarray(oi, oi + st)); u8.copyWithin(oi, oj, oj + st); u8.set(tmp, oj);
      }
    }
  }
  function pion_arr_join(a, sep) {
    const p = pNum(a); sync(); const l = Number(g64(p)), dp = Number(g64(p + 24)), ps = new Array(l);
    for (let i = 0; i < l; i++) ps[i] = readStr(g64(dp + i * 8));
    return mkStr(ps.join(readStr(sep)));
  }
  function arrSort(a, cmp) {
    const p = pNum(a); sync(); const l = Number(g64(p)); if (l <= 1) return;
    const dp = Number(g64(p + 24)), vs = new Array(l);
    for (let i = 0; i < l; i++) vs[i] = g64(dp + i * 8);
    vs.sort(cmp); sync(); for (let i = 0; i < l; i++) s64(dp + i * 8, vs[i]);
  }
  const pion_arr_sort_int = (a) => {
    const p = pNum(a); sync(); const l = Number(g64(p)); if (l <= 1) return;
    const st = g32(p + 20);
    if (st === 1) { const dp = Number(g64(p + 24)); u8.subarray(dp, dp + l).sort(); return; }
    if (st === 4) { const dp = Number(g64(p + 24)); new Int32Array(u8.buffer, dp, l).sort(); return; }
    arrSort(a, (x, y) => (x < y ? -1 : x > y ? 1 : 0));
  };
  const pion_arr_sort_str = (a) => arrSort(a, pion_str_cmp);

  function mapNew(vObj, kInt) {
    const o = pion_alloc_uninit(32, TAG_MAP, 0n), es = rawZero(16 * 32), p = pNum(o); sync();
    s64(p, 0); s64(p + 8, 16); s32(p + 16, vObj); s32(p + 20, kInt); s64(p + 24, pBig(es)); return o;
  }
  const pion_map_new = (v) => mapNew(v, 0), pion_map_new_int = (v) => mapNew(v, 1);
  const pion_map_len = (m) => { sync(); return g64(pNum(m)); };
  const mHash = (k, kInt) => (kInt ? hashI64(k, hashSeed, hashSeed2) : (sync(), hashBytes(u8, dv, pNum(k) + 8, Number(g64(pNum(k))), hashSeed, hashSeed2)));
  const mEq = (a, b, kInt) => (kInt ? a === b : pion_str_eq(a, b) !== 0);
  function mapGrow(p) {
    sync(); const oc = Number(g64(p + 8)), oe = Number(g64(p + 24)), nc = oc < 16 ? 16 : oc * 2;
    const ne = rawZero(nc * 32), mask = nc - 1; sync();
    for (let i = 0; i < oc; i++) {
      const s = oe + i * 32;
      if (u8[s + 24] === 1) {
        const hLo = gu32(s + 8); let idx = (hLo & mask) >>> 0;
        while (u8[ne + idx * 32 + 24] === 1) idx = (idx + 1) & mask;
        const d = ne + idx * 32;
        su32(d, gu32(s)); su32(d + 4, gu32(s + 4)); su32(d + 8, hLo); su32(d + 12, gu32(s + 12));
        su32(d + 16, gu32(s + 16)); su32(d + 20, gu32(s + 20)); u8[d + 24] = 1;
      }
    }
    if (oe) rawFree(oe); if (slabCtl > 0) su32(slabCtl + 48, 0); s64(p + 8, nc); s64(p + 24, pBig(ne));
  }
  function pion_map_set(m, k, v) {
    const p = pNum(m); sync(); const len = Number(g64(p)); let cap = Number(g64(p + 8));
    if ((len + 1) * 10 >= cap * 7) { mapGrow(p); sync(); cap = Number(g64(p + 8)); }
    const vObj = g32(p + 16), kInt = g32(p + 20), es = Number(g64(p + 24)), h = mHash(k, kInt), mask = cap - 1;
    let idx = Number(h & BigInt(mask));
    while (true) {
      const e = es + idx * 32;
      if (u8[e + 24] === 0) {
        if (!kInt && k) pion_rc_inc(k); if (vObj && v) pion_rc_inc(v); sync();
        s64(e, k); dv.setBigUint64(e + 8, h, true); s64(e + 16, v); u8[e + 24] = 1; s64(p, len + 1); return;
      }
      if (dv.getBigUint64(e + 8, true) === h && mEq(g64(e), k, kInt)) {
        const old = g64(e + 16); if (vObj && v) pion_rc_inc(v); sync();
        s64(e + 16, v); if (vObj && old) pion_rc_dec(old); return;
      }
      idx = (idx + 1) & mask;
    }
  }
  function mapSlot(p, k) {
    sync(); const cap = Number(g64(p + 8)); if (!cap) return -1;
    const kInt = g32(p + 20), es = Number(g64(p + 24)), h = mHash(k, kInt), mask = cap - 1;
    let idx = Number(h & BigInt(mask));
    for (let s = 0; s < cap; s++) {
      const e = es + idx * 32; if (u8[e + 24] === 0) return -1;
      if (dv.getBigUint64(e + 8, true) === h && mEq(g64(e), k, kInt)) return idx;
      idx = (idx + 1) & mask;
    }
    return -1;
  }
  const pion_map_has = (m, k) => (mapSlot(pNum(m), k) >= 0 ? 1 : 0);
  function pion_map_get(m, k) {
    const p = pNum(m), sl = mapSlot(p, k); if (sl < 0) return 0n; sync();
    return g64(Number(g64(p + 24)) + sl * 32 + 16);
  }
  function pion_map_try_get(m, k, outP) {
    const p = pNum(m), sl = mapSlot(p, k), op = pNum(outP);
    if (sl < 0) { if (op) { sync(); s64(op, 0); } return 0; }
    sync(); const v = g64(Number(g64(p + 24)) + sl * 32 + 16);
    if (op) s64(op, v); return 1;
  }
  function pion_map_remove(m, k) {
    const p = pNum(m), sl = mapSlot(p, k); if (sl < 0) return; sync();
    if (slabCtl > 0) su32(slabCtl + 48, 0);
    const cap = Number(g64(p + 8)), vObj = g32(p + 16), kInt = g32(p + 20), es = Number(g64(p + 24)), mask = cap - 1;
    const e0 = es + sl * 32, ok = g64(e0), ov = g64(e0 + 16); u8[e0 + 24] = 0;
    let hole = sl, cur = (sl + 1) & mask;
    while (u8[es + cur * 32 + 24] === 1) {
      const nat = Number(dv.getBigUint64(es + cur * 32 + 8, true) & BigInt(mask));
      if (((hole - nat) & mask) < ((cur - nat) & mask)) {
        u8.copyWithin(es + hole * 32, es + cur * 32, es + cur * 32 + 32); u8[es + cur * 32 + 24] = 0; hole = cur;
      }
      cur = (cur + 1) & mask;
    }
    s64(p, Number(g64(p)) - 1); if (!kInt && ok) pion_rc_dec(ok); if (vObj && ov) pion_rc_dec(ov);
  }
  function pion_map_clear(m) {
    const p = pNum(m); sync(); if (slabCtl > 0) su32(slabCtl + 48, 0); const cap = Number(g64(p + 8)), vObj = g32(p + 16), kInt = g32(p + 20), es = Number(g64(p + 24));
    if (es) for (let i = 0; i < cap; i++) {
      const e = es + i * 32;
      if (u8[e + 24] === 1) {
        const k = g64(e), v = g64(e + 16); u8[e + 24] = 0;
        if (!kInt && k) pion_rc_dec(k); if (vObj && v) pion_rc_dec(v); sync();
      }
    }
    s64(p, 0);
  }
  function pion_map_copy(m) {
    const p = pNum(m); sync(); const cap = Number(g64(p + 8)), es = Number(g64(p + 24)), o = mapNew(g32(p + 16), g32(p + 20));
    for (let i = 0; i < cap; i++) { sync(); const e = es + i * 32; if (u8[e + 24] === 1) pion_map_set(o, g64(e), g64(e + 16)); }
    return o;
  }
  function pion_map_keys(m) {
    const p = pNum(m); sync(); const cap = Number(g64(p + 8)), kInt = g32(p + 20), es = Number(g64(p + 24));
    const arr = pion_arr_new(g64(p), kInt ? 0 : 1);
    for (let i = 0; i < cap; i++) { sync(); const e = es + i * 32; if (u8[e + 24] === 1) pion_arr_push(arr, g64(e)); }
    return arr;
  }

  function pion_scope_begin() { return pion_alloc(8, TAG_SCOPE, 0n); }
  function pion_scope_spawn(_s, fnIdx, env) {
    const idx = Number(fnIdx);
    if (idx && exp && exp.__indirect_function_table) { const fn = exp.__indirect_function_table.get(idx); if (fn) fn(BigInt(env)); }
  }
  const pion_scope_end = (s) => pion_rc_dec(s);
  function pion_chan_new(cap, elemIsObj) {
    const o = pion_alloc(16, TAG_CHANNEL, 0n);
    channels.set(pNum(o), { cap: Number(cap), elemIsObj: elemIsObj | 0, queue: [], closed: false });
    return o;
  }
  function pion_chan_send(ch, val) {
    const c = channels.get(pNum(ch)); if (!c || c.closed) return 0;
    if (c.elemIsObj && val !== 0n) pion_rc_inc(val);
    c.queue.push(BigInt(val)); return 1;
  }
  function pion_chan_recv(ch, outP) {
    const c = channels.get(pNum(ch)), op = pNum(outP);
    if (!c || !c.queue.length) { if (op) { sync(); s64(op, 0n); } return 0; }
    const v = c.queue.shift(); if (op) { sync(); s64(op, v); } return 1;
  }
  function pion_chan_close(ch) { const c = channels.get(pNum(ch)); if (c) c.closed = true; }
  function pion_mutex_new(initVal, valIsObj) {
    const o = pion_alloc(16, TAG_MUTEX, 0n), p = pNum(o);
    if (valIsObj && initVal !== 0n) pion_rc_inc(initVal); sync();
    s64(p, initVal); s32(p + 8, valIsObj | 0); return o;
  }
  const pion_mutex_lock = (m) => (sync(), g64(pNum(m)));
  function pion_mutex_set(m, newVal) {
    const p = pNum(m); sync(); const isObj = g32(p + 8), old = g64(p);
    if (isObj && newVal !== 0n) pion_rc_inc(newVal); sync();
    s64(p, newVal); if (isObj && old !== 0n) pion_rc_dec(old);
  }
  const pion_mutex_set_and_unlock = (m, v) => pion_mutex_set(m, v);
  const pion_mutex_unlock = (_m) => {};
  function pion_atomic_new(initVal) { const o = pion_alloc(8, TAG_ATOMIC, 0n); sync(); s64(pNum(o), initVal); return o; }
  const pion_atomic_load = (a) => (sync(), g64(pNum(a)));
  const pion_atomic_store = (a, v) => { sync(); s64(pNum(a), v); };
  function pion_atomic_fetch_add(a, d) {
    const p = pNum(a); sync(); const old = g64(p);
    s64(p, BigInt.asIntN(64, old + BigInt(d))); return old;
  }


  // Portable SIMD Vector & INT8 Matvec Primitives (P75-B)
  function simdSlice(obj, isBytes, stride, off, need) {
    sync();
    const p = pNum(obj);
    if (!p) pion_panic_oob(BigInt(off) + BigInt(need), 0n);
    const len = dv.getBigInt64(p, true);
    let dp;
    if (isBytes) {
      dp = Number(dv.getBigInt64(p + 16, true));
    } else {
      if (dv.getInt32(p + 20, true) !== stride) pion_panic_oob(-1n, len);
      dp = Number(dv.getBigInt64(p + 24, true));
    }
    const offB = BigInt(off), needB = BigInt(need);
    if (offB < 0n || needB < 0n || offB > len || needB > len - offB) {
      pion_panic_oob(offB + needB, len);
    }
    return needB === 0n ? 0 : dp + off * stride;
  }
  function pion_simd_i8_dot(a, isBytes, aOff, b, bOff, len) {
    const pa = simdSlice(a, isBytes, 1, aOff, len);
    const pb = simdSlice(b, 0, 1, bOff, len);
    let sum = 0;
    for (let k = 0; k < len; k++) {
      const va = (u8[pa + k] << 24) >> 24;
      const vb = (u8[pb + k] << 24) >> 24;
      sum = (sum + Math.imul(va, vb)) | 0;
    }
    return sum;
  }
  function pion_simd_i8_mv(out, outOff, w, isBytes, wOff, x, xOff, sc, sOff, xScale, rows, cols) {
    const po = simdSlice(out, 0, 4, outOff, rows);
    const px = simdSlice(x, 0, 1, xOff, cols);
    const pw = simdSlice(w, isBytes, 1, wOff, BigInt(rows) * BigInt(cols));
    const ps = simdSlice(sc, 0, 4, sOff, rows);
    for (let r = 0; r < rows; r++) {
      let sum = 0;
      const wr = pw + r * cols;
      for (let k = 0; k < cols; k++) {
        const vw = (u8[wr + k] << 24) >> 24;
        const vx = (u8[px + k] << 24) >> 24;
        sum = (sum + Math.imul(vw, vx)) | 0;
      }
      const s = Math.fround(dv.getFloat32(ps + r * 4, true) * xScale);
      dv.setFloat32(po + r * 4, Math.fround(Math.fround(sum) * s), true);
    }
  }
  function pion_simd_f32(op, dst, dOff, a, aOff, b, bOff, alpha, len) {
    const pd = simdSlice(dst, 0, 4, dOff, len);
    const pa = simdSlice(a, 0, 4, aOff, len);
    const pb = (op === 2 || op === 3 || op >= 5) ? simdSlice(b, 0, 4, bOff, len) : 0;
    let sum = 0;
    for (let i = 0; i < len; i++) {
      const o = pd + i * 4, oa = pa + i * 4, ob = pb + i * 4;
      if (op === 0) sum = Math.fround(sum + Math.fround(dv.getFloat32(o, true) * dv.getFloat32(oa, true)));
      else if (op === 1) dv.setFloat32(o, Math.fround(dv.getFloat32(o, true) + Math.fround(alpha * dv.getFloat32(oa, true))), true);
      else if (op === 2) dv.setFloat32(o, Math.fround(dv.getFloat32(oa, true) * dv.getFloat32(ob, true)), true);
      else if (op === 3) dv.setFloat32(o, Math.fround(dv.getFloat32(oa, true) + dv.getFloat32(ob, true)), true);
      else if (op === 4) dv.setFloat32(o, Math.fround(dv.getFloat32(oa, true) * alpha), true);
      else {
        const v = op === 5
          ? Math.fround(dv.getFloat32(o, true) * dv.getFloat32(oa, true))
          : Math.fround(dv.getFloat32(o, true) + Math.fround(alpha * dv.getFloat32(oa, true)));
        dv.setFloat32(o, v, true);
        sum = Math.fround(sum + Math.fround(v * dv.getFloat32(ob, true)));
      }
    }
    return Math.fround(sum);
  }

  const imports = {
    pion_rt: {
      __pion_rt_abi_v2: () => {},
      pion_cur_tid: () => 1n, pion_alloc, pion_alloc_uninit,
      pion_rc_inc, pion_rc_dec, pion_rc_dec_slow, pion_rc_freeze, pion_rc_immortalize,
      pion_panic, pion_panic_oob, pion_debug_assert,
      pion_math_sqrt: Math.sqrt, pion_math_abs: Math.abs, pion_math_floor: Math.floor,
      pion_math_ceil: Math.ceil, pion_math_sin: Math.sin, pion_math_cos: Math.cos, pion_math_pow: c99Pow,
      sqrt: Math.sqrt, cbrt: Math.cbrt, fabs: Math.abs, floor: Math.floor, ceil: Math.ceil,
      round: c99Round,
      trunc: Math.trunc, sin: Math.sin, cos: Math.cos, tan: Math.tan,
      asin: Math.asin, acos: Math.acos, atan: Math.atan, pow: c99Pow,
      atan2: Math.atan2, log: Math.log, log1p: Math.log1p, exp: Math.exp, fmod: (a, b) => a % b,
      roundf: (x) => Math.fround(c99Round(Math.fround(x))),
      truncf: (x) => Math.fround(Math.trunc(x)), floorf: (x) => Math.fround(Math.floor(x)),
      ceilf: (x) => Math.fround(Math.ceil(x)), fabsf: (x) => Math.fround(Math.abs(x)),
      sqrtf: (x) => Math.fround(Math.sqrt(x)), cbrtf: (x) => Math.fround(Math.cbrt(x)),
      powf: (x, y) => Math.fround(c99Pow(x, y)), expf: (x) => Math.fround(Math.exp(x)),
      logf: (x) => Math.fround(Math.log(x)), sinf: (x) => Math.fround(Math.sin(x)),
      cosf: (x) => Math.fround(Math.cos(x)), tanf: (x) => Math.fround(Math.tan(x)),
      atan2f: (y, x) => Math.fround(Math.atan2(y, x)), asinf: (x) => Math.fround(Math.asin(x)),
      acosf: (x) => Math.fround(Math.acos(x)), atanf: (x) => Math.fround(Math.atan(x)),
      pion_str_from_cstr, pion_str_len, pion_str_byte_at, pion_str_concat, pion_str_concat_n,
      pion_str_eq, pion_str_cmp, pion_str_slice, pion_int_to_str, pion_uint64_to_str,
      pion_double_to_str, pion_float_to_str, pion_str_to_int, pion_str_to_double,
      pion_str_starts_with, pion_str_ends_with, pion_str_contains, pion_str_index_of,
      pion_str_trim, pion_str_split, pion_str_replace, pion_str_to_bytes, pion_bytes_to_str,
      pion_bytes_new, pion_bytes_len, pion_bytes_get, pion_bytes_set,
      pion_bytes_slice, pion_bytes_concat, pion_bytes_from_ptr, pion_bytes_copy_to_ptr, pion_bytes_blit,
      pion_strbuf_new, pion_strbuf_push_str, pion_strbuf_push_slice, pion_strbuf_push_byte, pion_strbuf_push_char,
      pion_strbuf_push_int, pion_strbuf_reset, pion_strbuf_to_str,
      pion_arr_new, pion_arr_len, pion_arr_push, pion_arr_push_owned, pion_arr_push_flat_grow, pion_arr_get,
      pion_arr_set, pion_arr_pop, pion_arr_copy, pion_arr_clear, pion_arr_truncate, pion_arr_reverse,
      pion_arr_join, pion_arr_sort_int, pion_arr_sort_str,
      pion_simd_i8_dot, pion_simd_i8_mv, pion_simd_f32,
      pion_map_new, pion_map_new_int, pion_map_len, pion_map_set, pion_map_has,
      pion_map_get, pion_map_try_get, pion_map_remove, pion_map_clear, pion_map_copy, pion_map_keys,
      pion_scope_begin, pion_scope_spawn, pion_scope_end,
      pion_chan_new, pion_chan_send, pion_chan_recv, pion_chan_close,
      pion_mutex_new, pion_mutex_lock, pion_mutex_set, pion_mutex_set_and_unlock, pion_mutex_unlock,
      pion_atomic_new, pion_atomic_load, pion_atomic_store, pion_atomic_fetch_add,
      pion_world_init: () => pion_alloc(16, TAG_WORLD, 0n),
      pion_world_print: (_w, s) => printFn(readStr(s)),
      pion_world_println: (_w, s) => printlnFn(readStr(s)),
      pion_world_eprintln: (_w, s) => eprintlnFn(readStr(s)),
      pion_world_clock_ms: () => BigInt(Math.floor(performance.now())),
      pion_clock_monotonic_us: () => BigInt(Math.round(performance.now() * 1000)),
      pion_fs_mmap_ro: (_p, okOut) => { const op = pNum(okOut); if (op) { sync(); dv.setInt32(op, 0, true); } return mkStr("fs_mmap_ro unavailable in web runtime"); },
      pion_fs_write_atomic_bytes: () => 0,
      pion_ptr_alloc: (b) => pBig(rawZero(Number(b))),
      pion_ptr_free: (p) => rawFree(pNum(p)),
      pion_ptr_offset: (p, o) => BigInt.asIntN(64, BigInt(p) + BigInt(o)),
      pion_ptr_read_ptr: (p, o) => (sync(), g64(pNum(p) + Number(o))),
      pion_ptr_write_ptr: (p, o, v) => { sync(); s64(pNum(p) + Number(o), v); },
      pion_ptr_read_u8: (p, o) => (sync(), u8[pNum(p) + Number(o)]),
      pion_ptr_write_u8: (p, o, v) => { sync(); u8[pNum(p) + Number(o)] = v & 0xff; },
      pion_ptr_read_i32: (p, o) => (sync(), g32(pNum(p) + Number(o))),
      pion_ptr_write_i32: (p, o, v) => { sync(); s32(pNum(p) + Number(o), v); },
      pion_ptr_read_i64: (p, o) => (sync(), g64(pNum(p) + Number(o))),
      pion_ptr_write_i64: (p, o, v) => { sync(); s64(pNum(p) + Number(o), v); },
      pion_cstr_to_str: (c) => mkStr(readCStr(c)),
    },
  };
  if (opts.extraImports !== undefined && opts.extraImports !== null) {
    if (typeof opts.extraImports !== "object") {
      throw new Error("createPionRuntime: extraImports must be an object");
    }
    for (const ns of Object.keys(opts.extraImports)) {
      if (ns === "pion_rt") {
        throw new Error("createPionRuntime: extraImports cannot override reserved 'pion_rt' namespace");
      }
      const mod = opts.extraImports[ns];
      if (mod && typeof mod === "object") {
        imports[ns] = { ...mod };
      }
    }
  }
  if (opts.hostFns !== undefined && opts.hostFns !== null) {
    if (typeof opts.hostFns !== "object") {
      throw new TypeError("createPionRuntime: hostFns must be an object");
    }
    for (const k of Object.keys(opts.hostFns)) {
      if (Object.prototype.hasOwnProperty.call(imports.pion_rt, k)) {
        throw new Error(`createPionRuntime: hostFns cannot override built-in pion_rt symbol '${k}'`);
      }
      const fn = opts.hostFns[k];
      if (typeof fn !== "function") {
        throw new TypeError(`createPionRuntime: hostFns['${k}'] must be a function`);
      }
      imports.pion_rt[k] = fn;
    }
  }

  function mkCStr(jsStr) {
    const bs = enc.encode(String(jsStr));
    const p = rawAlloc(bs.length + 1);
    sync();
    u8.set(bs, p);
    u8[p + bs.length] = 0;
    return pBig(p);
  }
  function readBytes(obj) {
    const p = pNum(obj);
    if (!p) return new Uint8Array(0);
    sync();
    const len = Number(g64(p));
    if (len <= 0) return new Uint8Array(0);
    const dp = Number(g64(p + 16));
    return u8.slice(dp, dp + len);
  }
  function mkBytes(data) {
    const src = data instanceof Uint8Array
      ? data
      : (ArrayBuffer.isView(data)
        ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
        : (data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data || 0)));
    const safeSrc = (memory && src.byteLength > 0 && src.buffer === memory.buffer)
      ? new Uint8Array(src)
      : src;
    const o = pion_bytes_new(BigInt(safeSrc.length));
    if (safeSrc.length > 0) {
      sync();
      const dp = Number(g64(pNum(o) + 16));
      u8.set(safeSrc, dp);
    }
    return o;
  }

  if (exp) bindExports(exp);
  return {
    imports,
    bindExports,
    getStdout: () => out.join(""),
    getStderr: () => err.join(""),
    readStr,
    readUtf8: readStr,
    mkStr,
    mkCStr,
    readBytes,
    mkBytes,
    freePtr: (ptr) => rawFree(pNum(ptr)),
    rcDec: pion_rc_dec,
    rcInc: pion_rc_inc,
    syncMemory: sync,
  };
}

export async function runWasmBytes(wasmBytes, opts = {}) {
  const rt = createPionRuntime(opts);
  const { instance } = await WebAssembly.instantiate(wasmBytes, rt.imports);
  rt.bindExports(instance.exports);
  const rc = (instance.exports.main || instance.exports._start)(0, 0n);
  return { exitCode: typeof rc === "number" ? rc : 0, runtime: rt, instance };
}
