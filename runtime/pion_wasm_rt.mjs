// Pion WebAssembly (wasm32) Zero-Dependency Universal Runtime (Browser + Node.js)
// Exact byte-for-byte linear memory layout parity with runtime/pion_rt.h (64-bit ABI):
//   PionHeader  (24B @ payload - 24): owner_tid:u32@0, local_rc:u32@4, shared_rc:u32@8,
//                                     type_tag:u16@12, flags:u16@14, drop_fn_idx:u64@16
//   PionString  (8B+len): len:i64@0, data:u8[]@8
//   PionBytes   (24B):    len:i64@0, cap:i64@8, data_ptr:i64@16
//   PionStrBuf  (24B):    len:i64@0, cap:i64@8, data_ptr:i64@16
//   PionArray   (32B):    len:i64@0, cap:i64@8, elem_is_obj:i32@16, pad:i32@20, data_ptr:i64@24
//   PionMap     (32B):    len:i64@0, cap:i64@8, val_is_obj:i32@16, key_is_int:i32@20, entries_ptr:i64@24
//   PionMapEntry(32B):    key:i64@0, hash:u64@8, val:i64@16, state:u8@24

export const PION_WASM_RT_ABI = 2;

const TAG_STRING  = 1;
const TAG_BYTES   = 2;
const TAG_ARRAY   = 3;
const TAG_STRUCT  = 4;
const TAG_ENUM    = 5;
const TAG_CLOSURE = 6;
const TAG_MAP     = 7;
const TAG_CHANNEL = 8;
const TAG_MUTEX   = 9;
const TAG_ATOMIC  = 10;
const TAG_STRBUF  = 11;
const TAG_SCOPE   = 12;
const TAG_WORLD   = 13;

const FLAG_FROZEN   = 1;
const FLAG_IMMORTAL = 2;

const HEADER_SIZE = 24;
const PAGE_SIZE = 65536;

// Size classes for O(1) free-list recycling (total block size incl. 8B block header for raw allocs).
// Small classes [32..2048] plus 16B-aligned p+16 and 1.5*p+16 tiers up to 256 MiB + 16.
const FREE_CLASSES = [
  32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048,
  2064, 3088, 4112, 6160, 8208, 12304, 16400, 24592, 32784, 49168,
  65552, 98320, 131088, 196624, 262160, 393232, 524304, 786448,
  1048592, 1572880, 2097168, 3145744, 4194320, 6291472, 8388624,
  12582928, 16777232, 25165840, 33554448, 50331664, 67108880,
  100663312, 134217744, 201326608, 268435472,
];
let _freeClassIdx = null;
function getFreeClassIdx(sz) {
  if (_freeClassIdx === null) {
    _freeClassIdx = new Map();
    for (let i = 0; i < FREE_CLASSES.length; i++) _freeClassIdx.set(FREE_CLASSES[i], i);
  }
  return _freeClassIdx.get(sz);
}
const ALLOC_MAGIC = 0x50494f4e; // "PION"
const FREE_MAGIC  = 0x46524545; // "FREE"

const IS_NODE_ENV = typeof process !== "undefined" && Boolean(process.versions && process.versions.node);
const HAS_GET_BUILTIN = IS_NODE_ENV && typeof process.getBuiltinModule === "function";
function getBuiltin(name) {
  return HAS_GET_BUILTIN ? process.getBuiltinModule(name) : null;
}

const textDecoder = new TextDecoder("utf-8", { fatal: false });
const textEncoder = new TextEncoder();

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

export function formatG(v, sigDigits) {
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
  const p = sigDigits > 0 ? sigDigits : 1;
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

function hashBytes64(u8, dv, off, len, seed1, seed2) {
  const K = 0x9e3779b97f4a7c15n;
  const s1 = BigInt.asUintN(64, seed1 ^ 0x517cc1b727220a95n);
  const s2 = BigInt.asUintN(64, seed2 ^ K);
  const origLen = BigInt(len);
  let h = BigInt.asUintN(64, s1 ^ BigInt.asUintN(64, origLen * K));
  let p = off;
  let rem = len;
  while (rem > 8) {
    const w = dv.getBigUint64(p, true);
    h = wymix64(w ^ s1, h ^ s2);
    p += 8;
    rem -= 8;
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

function hashInt64(k, seed1, seed2) {
  const s1 = BigInt.asUintN(64, seed1 ^ 0x517cc1b727220a95n);
  const s2 = BigInt.asUintN(64, seed2 ^ 0x9e3779b97f4a7c15n);
  const h = wymix64(BigInt.asUintN(64, k) ^ s1, s2);
  return h === 0n ? 1n : h;
}

export function createPionRuntime(options = {}) {
  let memory = options.memory || null;
  let exportsObj = options.exports || null;
  let cachedBuf = null;
  let dv = null;
  let u8 = null;

  let heapBase = 0;
  let heapPtr = 0;
  let heapEnd = 0;
  let slabCtl = 0;
  let hashSeed = 0n;
  let hashSeed2 = 0n;
  let freeLists = null;
  const largeFree = new Map();
  const rcDeferQueue = [];
  let jsDropDepth = 0;

  const stdoutChunks = [];
  const stderrChunks = [];
  const isNode = IS_NODE_ENV;
  const nodeFs = options.fs || null;
  let nodeCrypto = options.crypto || null;
  const nodeCp = options.child_process || null;
  const cliArgs = Array.isArray(options.args) ? options.args.map(String) : [];

  const printFn = options.print || (isNode
    ? (s) => process.stdout.write(s)
    : (s) => { stdoutChunks.push(s); if (typeof console !== "undefined") console.log(s); });
  const printlnFn = options.println || (isNode
    ? (s) => process.stdout.write(s + "\n")
    : (s) => { stdoutChunks.push(s + "\n"); if (typeof console !== "undefined") console.log(s); });
  const eprintlnFn = options.eprintln || (isNode
    ? (s) => process.stderr.write(s + "\n")
    : (s) => { stderrChunks.push(s + "\n"); if (typeof console !== "undefined") console.error(s); });

  function syncViews() {
    if (cachedBuf !== memory.buffer) {
      cachedBuf = memory.buffer;
      dv = new DataView(cachedBuf);
      u8 = new Uint8Array(cachedBuf);
      heapEnd = cachedBuf.byteLength;
      if (slabCtl > 0) {
        dv.setUint32(slabCtl + 40, heapEnd >>> 0, true);
      }
    }
  }

  function getHeapPtr() {
    return slabCtl > 0 ? dv.getUint32(slabCtl + 36, true) : heapPtr;
  }

  function setHeapPtr(v) {
    heapPtr = v >>> 0;
    if (slabCtl > 0) {
      dv.setUint32(slabCtl + 36, heapPtr, true);
    }
  }

  function bindExports(exp) {
    exportsObj = exp;
    if (exp.memory) memory = exp.memory;
    slabCtl = 0;
    syncViews();
    const hb = exp.__heap_base;
    const base = typeof hb === "number" ? hb : (hb && typeof hb.value === "number" ? hb.value : 0x220000);
    heapBase = (base + 15) & ~15;
    heapPtr = heapBase;
    heapEnd = memory.buffer.byteLength;
    const sc = exp.__pion_slab_ctl;
    slabCtl = typeof sc === "number" ? sc : (sc && typeof sc.value === "number" ? sc.value : 0);
    const ra = exp.__pion_wasm_rt_abi;
    const modAbi = typeof ra === "number" ? ra : (ra && typeof ra.value === "number" ? ra.value : 0);
    if ((slabCtl > 0 || ra !== undefined) && modAbi !== PION_WASM_RT_ABI) {
      throw new Error(
        `Pion Wasm runtime ABI mismatch: runtime expects v${PION_WASM_RT_ABI}, module exports v${modAbi}. ` +
        `Sync runtime/pion_wasm_rt*.mjs with the pionc version that built this .wasm.`
      );
    }
    if (isNode && typeof process !== "undefined" && process.env && process.env.PION_HASH_SEED !== undefined && process.env.PION_HASH_SEED !== "") {
      hashSeed = BigInt.asUintN(64, BigInt(process.env.PION_HASH_SEED));
      hashSeed2 = splitmix64(hashSeed ^ 0x9e3779b97f4a7c15n);
    } else if (typeof globalThis.crypto !== "undefined" && typeof globalThis.crypto.getRandomValues === "function") {
      const seedBuf = new BigUint64Array(2);
      globalThis.crypto.getRandomValues(seedBuf);
      hashSeed = seedBuf[0];
      hashSeed2 = seedBuf[1];
    } else {
      hashSeed = BigInt.asUintN(64, (BigInt(Date.now()) * 0x9e3779b97f4a7c15n) ^ 0xbf58476d1ce4e5b9n);
      hashSeed2 = splitmix64(hashSeed ^ 0x9e3779b97f4a7c15n);
    }
    if (slabCtl > 0) {
      u8.fill(0, slabCtl, slabCtl + 96);
      dv.setUint32(slabCtl + 36, heapPtr >>> 0, true);
      dv.setUint32(slabCtl + 40, heapEnd >>> 0, true);
      dv.setUint32(slabCtl + 44, heapBase >>> 0, true);
      dv.setBigUint64(slabCtl + 64, hashSeed, true);
      dv.setBigUint64(slabCtl + 72, hashSeed2, true);
    }
    if (freeLists) {
      for (let i = 0; i < freeLists.length; i++) {
        if (freeLists[i]) freeLists[i].length = 0;
      }
    }
    largeFree.clear();
    rcDeferQueue.length = 0;
    jsDropDepth = 0;
  }

  function sizeClassIndex(totalSize) {
    let lo = 0;
    let hi = FREE_CLASSES.length - 1;
    let ans = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >>> 1;
      if (FREE_CLASSES[mid] >= totalSize) {
        ans = mid;
        hi = mid - 1;
      } else {
        lo = mid + 1;
      }
    }
    return ans;
  }

  function roundLargeSize(need) {
    let p = 32768;
    while (p < need) p *= 2;
    const threeQuarter = (p / 2) + (p / 4);
    return need <= threeQuarter ? threeQuarter : p;
  }

  // Raw allocation: stores 8-byte block header (size:u32 @ base, magic:u32 @ base+4) at ptr - 8.
  function rawAlloc(size) {
    if (!Number.isFinite(size) || size < 0 || size > 0x7FFFFFE8) {
      pionDie("allocation size exceeds wasm32 limit");
    }
    syncViews();
    const need = Math.ceil(size / 8) * 8 + 8;
    const cls = sizeClassIndex(need);
    if (cls >= 0) {
      if (slabCtl > 0 && cls < 9) {
        const slotOff = slabCtl + cls * 4;
        const head = dv.getUint32(slotOff, true);
        if (head !== 0) {
          const next = dv.getUint32(head + 8, true);
          dv.setUint32(slotOff, next, true);
          const allocSz = FREE_CLASSES[cls];
          dv.setUint32(head, allocSz, true);
          dv.setUint32(head + 4, ALLOC_MAGIC, true);
          return head + 8;
        }
      } else if (freeLists && freeLists[cls] && freeLists[cls].length > 0) {
        const base = freeLists[cls].pop();
        const allocSz = FREE_CLASSES[cls];
        dv.setUint32(base, allocSz, true);
        dv.setUint32(base + 4, ALLOC_MAGIC, true);
        return base + 8;
      }
    }
    const allocSz = cls >= 0 ? FREE_CLASSES[cls] : roundLargeSize(need);
    if (cls < 0) {
      const bucket = largeFree.get(allocSz);
      if (bucket && bucket.length > 0) {
        const base = bucket.pop();
        dv.setUint32(base, allocSz, true);
        dv.setUint32(base + 4, ALLOC_MAGIC, true);
        return base + 8;
      }
    }
    const hp = getHeapPtr();
    if (hp + allocSz > 0xFFFF0000) pionDie("wasm32 out of memory");
    if (hp + allocSz > heapEnd) {
      const missing = hp + allocSz - heapEnd;
      const curPages = heapEnd >>> 16;
      const minGrow = Math.ceil(missing / PAGE_SIZE);
      const expGrow = Math.min(curPages >>> 1, 512);
      const maxAllowed = Math.max(0, 65535 - curPages);
      const targetGrow = Math.max(16, minGrow, expGrow);
      const growPages = minGrow > maxAllowed ? minGrow : Math.min(maxAllowed, targetGrow);
      memory.grow(growPages);
      syncViews();
    }
    const base = hp;
    setHeapPtr(hp + allocSz);
    dv.setUint32(base, allocSz, true);
    dv.setUint32(base + 4, ALLOC_MAGIC, true);
    return base + 8;
  }

  function rawAllocZero(size) {
    const p = rawAlloc(size);
    u8.fill(0, p, p + size);
    return p;
  }

  function rawFree(ptr) {
    if (!ptr) return;
    syncViews();
    const hp = getHeapPtr();
    const base = ptr - 8;
    if (base < heapBase || base + 8 > hp || (base & 7) !== 0) return;
    const magic = dv.getUint32(base + 4, true);
    if (magic === FREE_MAGIC) return;
    if (magic !== ALLOC_MAGIC) return;
    const allocSz = dv.getUint32(base, true);
    if (allocSz < 16 || base + allocSz > hp) return;
    dv.setUint32(base + 4, FREE_MAGIC, true);
    if (base + allocSz === hp) {
      setHeapPtr(base);
      return;
    }
    const cls = getFreeClassIdx(allocSz);
    if (cls !== undefined) {
      if (slabCtl > 0 && cls < 9) {
        const slotOff = slabCtl + cls * 4;
        const head = dv.getUint32(slotOff, true);
        dv.setUint32(base + 8, head, true);
        dv.setUint32(slotOff, base >>> 0, true);
      } else {
        if (!freeLists) freeLists = new Array(FREE_CLASSES.length);
        let fl = freeLists[cls];
        if (!fl) fl = freeLists[cls] = [];
        fl.push(base);
      }
    } else {
      let bucket = largeFree.get(allocSz);
      if (!bucket) {
        bucket = [];
        largeFree.set(allocSz, bucket);
      }
      bucket.push(base);
    }
  }

  function pNum(v) {
    return typeof v === "bigint" ? Number(v) : (v | 0);
  }

  function pBig(n) {
    return BigInt(n >>> 0);
  }

  // --- Object allocation & RC ---
  function pion_cur_tid() {
    return 1n;
  }

  function pion_alloc(payloadSize, typeTag, dropFn) {
    const sz = payloadSize >>> 0;
    const hdr = rawAllocZero(HEADER_SIZE + sz);
    dv.setUint32(hdr + 0, 1, true);          // owner_tid = 1
    dv.setUint32(hdr + 4, 1, true);          // local_rc = 1
    dv.setUint32(hdr + 8, 0, true);          // shared_rc = 0
    dv.setUint16(hdr + 12, typeTag & 0xffff, true);
    dv.setUint16(hdr + 14, 0, true);         // flags = 0
    dv.setBigInt64(hdr + 16, BigInt(dropFn || 0n), true);
    return pBig(hdr + HEADER_SIZE);
  }

  function pion_alloc_uninit(payloadSize, typeTag, dropFn) {
    const sz = payloadSize >>> 0;
    const hdr = rawAlloc(HEADER_SIZE + sz);
    dv.setUint32(hdr + 0, 1, true);
    dv.setUint32(hdr + 4, 1, true);
    dv.setUint32(hdr + 8, 0, true);
    dv.setUint16(hdr + 12, typeTag & 0xffff, true);
    dv.setUint16(hdr + 14, 0, true);
    dv.setBigInt64(hdr + 16, BigInt(dropFn || 0n), true);
    return pBig(hdr + HEADER_SIZE);
  }

  function pion_rc_inc(obj) {
    const p = pNum(obj);
    if (p === 0) return;
    syncViews();
    const hdr = p - HEADER_SIZE;
    const flags = dv.getUint16(hdr + 14, true);
    if ((flags & FLAG_IMMORTAL) !== 0) return;
    const tid = dv.getUint32(hdr + 0, true);
    if (tid === 0) {
      dv.setUint32(hdr + 8, (dv.getUint32(hdr + 8, true) + 1) >>> 0, true);
    } else {
      dv.setUint32(hdr + 4, (dv.getUint32(hdr + 4, true) + 1) >>> 0, true);
    }
  }

  function getDropDepth() {
    return slabCtl > 0 ? dv.getUint32(slabCtl + 80, true) : jsDropDepth;
  }

  function setDropDepth(d) {
    jsDropDepth = d >>> 0;
    if (slabCtl > 0) dv.setUint32(slabCtl + 80, jsDropDepth, true);
  }

  function pion_rc_dec_slow_one(obj) {
    const p = pNum(obj);
    if (p === 0) return;
    syncViews();
    const hdr = p - HEADER_SIZE;
    const dropIdx = Number(dv.getBigInt64(hdr + 16, true));
    const tag = dv.getUint16(hdr + 12, true);
    if (dropIdx !== 0) {
      dv.setBigInt64(hdr + 16, 0n, true);
      if ((dropIdx & 0x80000000) !== 0) {
        let m = dropIdx & 0x7fffffff;
        for (let b = 0; m !== 0; b++, m >>>= 1) {
          if (m & 1) {
            const ev = dv.getBigInt64(p + b * 8, true);
            if (ev !== 0n) {
              pion_rc_dec(ev);
              syncViews();
            }
          }
        }
      } else if (exportsObj && exportsObj.__indirect_function_table) {
        const fn = exportsObj.__indirect_function_table.get(dropIdx);
        if (fn) fn(pBig(p));
        syncViews();
      }
    }
    if (tag === TAG_ARRAY) {
      const len = Number(dv.getBigInt64(p + 0, true));
      const elemIsObj = dv.getInt32(p + 16, true);
      const stride = dv.getInt32(p + 20, true);
      const dataPtr = Number(dv.getBigInt64(p + 24, true));
      arrRcAll(dataPtr, len, elemIsObj, stride, false);
      if (dataPtr) rawFree(dataPtr);
    } else if (tag === TAG_MAP) {
      if (slabCtl > 0) dv.setUint32(slabCtl + 48, 0, true);
      const cap = Number(dv.getBigInt64(p + 8, true));
      const valIsObj = dv.getInt32(p + 16, true);
      const keyIsInt = dv.getInt32(p + 20, true);
      const entries = Number(dv.getBigInt64(p + 24, true));
      if (entries) {
        for (let i = 0; i < cap; i++) {
          const e = entries + i * 32;
          if (u8[e + 24] === 1) {
            if (!keyIsInt) {
              const k = dv.getBigInt64(e + 0, true);
              if (k !== 0n) pion_rc_dec(k);
              syncViews();
            }
            if (valIsObj) {
              const v = dv.getBigInt64(e + 16, true);
              if (v !== 0n) pion_rc_dec(v);
              syncViews();
            }
          }
        }
        rawFree(entries);
      }
    } else if (tag === TAG_BYTES || tag === TAG_STRBUF) {
      const dataPtr = Number(dv.getBigInt64(p + 16, true));
      if (dataPtr) rawFree(dataPtr);
    } else if (tag === TAG_MUTEX) {
      const valIsObj = dv.getInt32(p + 8, true);
      if (valIsObj) {
        const v = dv.getBigInt64(p + 0, true);
        if (v !== 0n) pion_rc_dec(v);
      }
    } else if (tag === TAG_CHANNEL) {
      const ch = channels.get(p);
      if (ch) {
        if (ch.elemIsObj) {
          for (const v of ch.queue) pion_rc_dec(v);
        }
        channels.delete(p);
      }
    }
    rawFree(hdr);
  }

  function pion_rc_dec_drain() {
    const prev = getDropDepth();
    setDropDepth(prev + 1);
    try {
      while (rcDeferQueue.length > 0) {
        if (slabCtl > 0) dv.setUint32(slabCtl + 84, 0, true);
        const next = rcDeferQueue.pop();
        pion_rc_dec_slow_one(next);
        syncViews();
      }
      if (slabCtl > 0) dv.setUint32(slabCtl + 84, 0, true);
    } finally {
      syncViews();
      setDropDepth(prev);
    }
  }

  function pion_rc_dec_slow(obj) {
    syncViews();
    const p = pNum(obj);
    if (p === 0) {
      if (rcDeferQueue.length > 0) pion_rc_dec_drain();
      return;
    }
    const curDepth = getDropDepth();
    if (curDepth >= 64) {
      rcDeferQueue.push(obj);
      if (slabCtl > 0) dv.setUint32(slabCtl + 84, 1, true);
      return;
    }
    setDropDepth(curDepth + 1);
    try {
      pion_rc_dec_slow_one(obj);
    } finally {
      syncViews();
      setDropDepth(curDepth);
    }
    if (curDepth === 0 && rcDeferQueue.length > 0) {
      pion_rc_dec_drain();
    }
  }

  function pion_rc_dec(obj) {
    const p = pNum(obj);
    if (p === 0) return;
    syncViews();
    const hdr = p - HEADER_SIZE;
    const flags = dv.getUint16(hdr + 14, true);
    if ((flags & FLAG_IMMORTAL) !== 0) return;
    const tid = dv.getUint32(hdr + 0, true);
    let rc;
    if (tid === 0) {
      rc = (dv.getUint32(hdr + 8, true) - 1) >>> 0;
      dv.setUint32(hdr + 8, rc, true);
    } else {
      rc = (dv.getUint32(hdr + 4, true) - 1) >>> 0;
      dv.setUint32(hdr + 4, rc, true);
    }
    if (rc !== 0) return;
    imports.pion_rt.pion_rc_dec_slow(obj);
  }

  function pion_rc_freeze(obj) {
    const p = pNum(obj);
    if (p === 0) return;
    syncViews();
    const hdr = p - HEADER_SIZE;
    const flags = dv.getUint16(hdr + 14, true);
    if ((flags & (FLAG_IMMORTAL | FLAG_FROZEN)) !== 0) return;
    const lrc = dv.getUint32(hdr + 4, true);
    const src = dv.getUint32(hdr + 8, true);
    dv.setUint32(hdr + 0, 0, true);
    dv.setUint32(hdr + 4, 0, true);
    dv.setUint32(hdr + 8, (lrc + src) >>> 0, true);
    dv.setUint16(hdr + 14, flags | FLAG_FROZEN, true);
  }

  function pion_rc_immortalize(obj) {
    const p = pNum(obj);
    if (p === 0) return;
    syncViews();
    const hdr = p - HEADER_SIZE;
    const flags = dv.getUint16(hdr + 14, true);
    dv.setUint16(hdr + 14, flags | FLAG_IMMORTAL, true);
  }

  // --- Helpers for reading/writing Pion strings & C strings ---
  function readCStr(ptr) {
    const p = pNum(ptr);
    if (p === 0) return "";
    syncViews();
    let end = p;
    while (u8[end] !== 0) end++;
    return textDecoder.decode(u8.subarray(p, end));
  }

  function readPionStr(ptr) {
    const p = pNum(ptr);
    if (p === 0) return "";
    syncViews();
    const len = Number(dv.getBigInt64(p + 0, true));
    return textDecoder.decode(u8.subarray(p + 8, p + 8 + len));
  }

  function makePionStrFromBytes(bytes) {
    const len = bytes.length;
    const obj = pion_alloc_uninit(8 + len + 1, TAG_STRING, 0n);
    const p = pNum(obj);
    syncViews();
    dv.setBigInt64(p + 0, BigInt(len), true);
    u8.set(bytes, p + 8);
    u8[p + 8 + len] = 0;
    return obj;
  }

  function makePionStr(jsStr) {
    return makePionStrFromBytes(textEncoder.encode(jsStr));
  }

  function pion_panic(msgPtr, filePtr, line) {
    const msg = readCStr(msgPtr);
    const file = readCStr(filePtr);
    const err = `pion panic at ${file}:${line}: ${msg}`;
    eprintlnFn(err);
    throw new Error(err);
  }

  function pion_panic_oob(idx, len) {
    const err = `pion panic: index out of bounds: idx=${idx}, len=${len}`;
    eprintlnFn(err);
    throw new Error(err);
  }

  function pion_debug_assert(cond, msgStr, filePtr, line) {
    if ((cond | 0) === 0) {
      const msg = readPionStr(msgStr);
      const file = readCStr(filePtr);
      const err = `pion debug_assert failed at ${file}:${line}: ${msg}`;
      eprintlnFn(err);
      throw new Error(err);
    }
  }

  // --- Math ---
  const pion_math_sqrt = (x) => Math.sqrt(x);
  const pion_math_abs = (x) => Math.abs(x);
  const pion_math_floor = (x) => Math.floor(x);
  const pion_math_ceil = (x) => Math.ceil(x);
  const pion_math_sin = (x) => Math.sin(x);
  const pion_math_cos = (x) => Math.cos(x);
  const pion_math_pow = (x, y) => c99Pow(x, y);

  // --- String ---
  function pion_str_from_cstr(cstrPtr, len) {
    const n = Number(len);
    const src = pNum(cstrPtr);
    const obj = pion_alloc_uninit(8 + n + 1, TAG_STRING, 0n);
    const dst = pNum(obj);
    syncViews();
    dv.setBigInt64(dst, BigInt(n), true);
    if (n > 0 && src !== 0) {
      u8.copyWithin(dst + 8, src, src + n);
    }
    u8[dst + 8 + n] = 0;
    return obj;
  }

  function pion_str_len(s) {
    const p = pNum(s);
    if (p === 0) return 0n;
    syncViews();
    return dv.getBigInt64(p, true);
  }

  function pion_str_byte_at(s, idx) {
    const p = pNum(s);
    syncViews();
    const len = dv.getBigInt64(p, true);
    if (idx < 0n || idx >= len) pion_panic_oob(idx, len);
    return u8[p + 8 + Number(idx)];
  }

  function pion_str_concat(a, b) {
    const pa = pNum(a), pb = pNum(b);
    syncViews();
    const la = pa ? Number(dv.getBigInt64(pa, true)) : 0;
    const lb = pb ? Number(dv.getBigInt64(pb, true)) : 0;
    const total = la + lb;
    const obj = pion_alloc_uninit(8 + total + 1, TAG_STRING, 0n);
    const dst = pNum(obj);
    syncViews();
    dv.setBigInt64(dst, BigInt(total), true);
    if (la > 0) u8.copyWithin(dst + 8, pa + 8, pa + 8 + la);
    if (lb > 0) u8.copyWithin(dst + 8 + la, pb + 8, pb + 8 + lb);
    u8[dst + 8 + total] = 0;
    return obj;
  }

  function pion_str_concat_n(n, partsPtr) {
    const count = Number(n);
    const pp = pNum(partsPtr);
    syncViews();
    let total = 0;
    const ptrs = new Array(count);
    const lens = new Array(count);
    for (let i = 0; i < count; i++) {
      const sp = Number(dv.getBigInt64(pp + i * 8, true));
      ptrs[i] = sp;
      const l = sp ? Number(dv.getBigInt64(sp, true)) : 0;
      lens[i] = l;
      total += l;
    }
    const obj = pion_alloc_uninit(8 + total + 1, TAG_STRING, 0n);
    const dst = pNum(obj);
    syncViews();
    dv.setBigInt64(dst, BigInt(total), true);
    let off = 0;
    for (let i = 0; i < count; i++) {
      const l = lens[i];
      if (l > 0) {
        u8.copyWithin(dst + 8 + off, ptrs[i] + 8, ptrs[i] + 8 + l);
        off += l;
      }
    }
    u8[dst + 8 + total] = 0;
    return obj;
  }

  function pion_str_eq(a, b) {
    const pa = pNum(a), pb = pNum(b);
    if (pa === pb) return 1;
    if (!pa || !pb) return 0;
    syncViews();
    const la = Number(dv.getBigInt64(pa, true));
    const lb = Number(dv.getBigInt64(pb, true));
    if (la !== lb) return 0;
    for (let i = 0; i < la; i++) {
      if (u8[pa + 8 + i] !== u8[pb + 8 + i]) return 0;
    }
    return 1;
  }

  function pion_str_cmp(a, b) {
    const pa = pNum(a), pb = pNum(b);
    if (pa === pb) return 0;
    syncViews();
    const la = pa ? Number(dv.getBigInt64(pa, true)) : 0;
    const lb = pb ? Number(dv.getBigInt64(pb, true)) : 0;
    const m = Math.min(la, lb);
    for (let i = 0; i < m; i++) {
      const ca = u8[pa + 8 + i], cb = u8[pb + 8 + i];
      if (ca !== cb) return ca < cb ? -1 : 1;
    }
    return la < lb ? -1 : (la > lb ? 1 : 0);
  }

  function pion_str_slice(s, start, end) {
    const ps = pNum(s);
    syncViews();
    const len = Number(dv.getBigInt64(ps, true));
    let a = Number(start), b = Number(end);
    if (a < 0) a = 0;
    if (b > len) b = len;
    if (b < a) b = a;
    const n = b - a;
    const obj = pion_alloc_uninit(8 + n + 1, TAG_STRING, 0n);
    const dst = pNum(obj);
    syncViews();
    dv.setBigInt64(dst, BigInt(n), true);
    if (n > 0) u8.copyWithin(dst + 8, ps + 8 + a, ps + 8 + b);
    u8[dst + 8 + n] = 0;
    return obj;
  }

  function pion_int_to_str(v) {
    return makePionStr(BigInt(v).toString(10));
  }

  function pion_uint64_to_str(v) {
    return makePionStr(BigInt.asUintN(64, BigInt(v)).toString(10));
  }

  function pion_double_to_str(v) {
    let s = formatG(v, 15);
    if (Number.isFinite(v) && Number(s) !== v) {
      s = formatG(v, 16);
      if (Number(s) !== v) s = formatG(v, 17);
    }
    return makePionStr(s);
  }

  function pion_float_to_str(v) {
    return makePionStr(formatG(Math.fround(v), 7));
  }

  function pion_str_to_int(s, okOut) {
    const txt = readPionStr(s).trim();
    const okP = pNum(okOut);
    syncViews();
    if (!/^[+-]?\d+$/.test(txt)) {
      if (okP) dv.setInt32(okP, 0, true);
      return 0n;
    }
    try {
      const v = BigInt(txt);
      if (v < -9223372036854775808n || v > 9223372036854775807n) {
        if (okP) dv.setInt32(okP, 0, true);
        return 0n;
      }
      if (okP) dv.setInt32(okP, 1, true);
      return v;
    } catch {
      if (okP) dv.setInt32(okP, 0, true);
      return 0n;
    }
  }

  function pion_str_to_double(s, okOut) {
    const txt = readPionStr(s).trim();
    const okP = pNum(okOut);
    syncViews();
    if (txt.length === 0) {
      if (okP) dv.setInt32(okP, 0, true);
      return 0.0;
    }
    const v = Number(txt);
    if (Number.isNaN(v)) {
      if (okP) dv.setInt32(okP, 0, true);
      return 0.0;
    }
    if (okP) dv.setInt32(okP, 1, true);
    return v;
  }

  function pion_str_starts_with(s, prefix) {
    const ps = pNum(s), pp = pNum(prefix);
    syncViews();
    const ls = Number(dv.getBigInt64(ps, true));
    const lp = Number(dv.getBigInt64(pp, true));
    if (lp > ls) return 0;
    for (let i = 0; i < lp; i++) {
      if (u8[ps + 8 + i] !== u8[pp + 8 + i]) return 0;
    }
    return 1;
  }

  function pion_str_ends_with(s, suffix) {
    const ps = pNum(s), pp = pNum(suffix);
    syncViews();
    const ls = Number(dv.getBigInt64(ps, true));
    const lp = Number(dv.getBigInt64(pp, true));
    if (lp > ls) return 0;
    const off = ls - lp;
    for (let i = 0; i < lp; i++) {
      if (u8[ps + 8 + off + i] !== u8[pp + 8 + i]) return 0;
    }
    return 1;
  }

  function pion_str_index_of(s, needle) {
    const ps = pNum(s), pn = pNum(needle);
    syncViews();
    const ls = Number(dv.getBigInt64(ps, true));
    const ln = Number(dv.getBigInt64(pn, true));
    if (ln === 0) return 0n;
    if (ln > ls) return -1n;
    const limit = ls - ln;
    outer: for (let i = 0; i <= limit; i++) {
      for (let j = 0; j < ln; j++) {
        if (u8[ps + 8 + i + j] !== u8[pn + 8 + j]) continue outer;
      }
      return BigInt(i);
    }
    return -1n;
  }

  function pion_str_contains(s, needle) {
    return pion_str_index_of(s, needle) >= 0n ? 1 : 0;
  }

  function pion_str_trim(s) {
    const ps = pNum(s);
    syncViews();
    const len = Number(dv.getBigInt64(ps, true));
    let a = 0, b = len;
    const isWs = (c) => c === 32 || c === 9 || c === 10 || c === 13;
    while (a < b && isWs(u8[ps + 8 + a])) a++;
    while (b > a && isWs(u8[ps + 8 + b - 1])) b--;
    return pion_str_slice(s, BigInt(a), BigInt(b));
  }

  function pion_str_split(s, sep) {
    const str = readPionStr(s);
    const sp = readPionStr(sep);
    const parts = sp.length === 0 ? [str] : str.split(sp);
    const arr = pion_arr_new(BigInt(parts.length), 1);
    for (let i = 0; i < parts.length; i++) {
      const partObj = makePionStr(parts[i]);
      pion_arr_push_owned(arr, partObj);
    }
    return arr;
  }

  function pion_str_replace(s, from, to) {
    const str = readPionStr(s);
    const f = readPionStr(from);
    const t = readPionStr(to);
    if (f.length === 0) return makePionStr(str);
    return makePionStr(str.split(f).join(t));
  }

  function pion_str_to_bytes(s) {
    const ps = pNum(s);
    syncViews();
    const len = Number(dv.getBigInt64(ps, true));
    const b = pion_bytes_new(BigInt(len));
    const pb = pNum(b);
    syncViews();
    const dp = Number(dv.getBigInt64(pb + 16, true));
    if (len > 0) u8.copyWithin(dp, ps + 8, ps + 8 + len);
    return b;
  }

  function pion_bytes_to_str(b) {
    const pb = pNum(b);
    syncViews();
    const len = Number(dv.getBigInt64(pb + 0, true));
    const dp = Number(dv.getBigInt64(pb + 16, true));
    const obj = pion_alloc_uninit(8 + len + 1, TAG_STRING, 0n);
    const dst = pNum(obj);
    syncViews();
    dv.setBigInt64(dst, BigInt(len), true);
    if (len > 0 && dp) u8.copyWithin(dst + 8, dp, dp + len);
    u8[dst + 8 + len] = 0;
    return obj;
  }

  function pionDie(msg) {
    const err = `pion panic: ${msg}`;
    eprintlnFn(err);
    throw new Error(err);
  }

  // --- Bytes ---
  function pion_bytes_new(len) {
    const lb = BigInt(len);
    if (lb < 0n) pionDie("negative bytes length");
    if (lb > 0x7FFFFFEFn) pionDie("container length exceeds maximum");
    const n = Number(lb);
    const cap = Math.max(n, 16);
    const obj = pion_alloc_uninit(24, TAG_BYTES, 0n);
    const dp = rawAllocZero(cap);
    const p = pNum(obj);
    syncViews();
    dv.setBigInt64(p + 0, BigInt(n), true);
    dv.setBigInt64(p + 8, BigInt(cap), true);
    dv.setBigInt64(p + 16, pBig(dp), true);
    return obj;
  }

  function pion_bytes_len(b) {
    syncViews();
    return dv.getBigInt64(pNum(b), true);
  }

  function pion_bytes_get(b, idx) {
    const pb = pNum(b);
    syncViews();
    const len = dv.getBigInt64(pb, true);
    if (idx < 0n || idx >= len) pion_panic_oob(idx, len);
    const dp = Number(dv.getBigInt64(pb + 16, true));
    return u8[dp + Number(idx)];
  }

  function pion_bytes_set(b, idx, val) {
    const pb = pNum(b);
    syncViews();
    const len = dv.getBigInt64(pb, true);
    if (idx < 0n || idx >= len) pion_panic_oob(idx, len);
    if (dv.getBigInt64(pb + 8, true) < 0n) pionDie("cannot mutate read-only mmap Bytes");
    const dp = Number(dv.getBigInt64(pb + 16, true));
    u8[dp + Number(idx)] = val & 0xff;
  }

  function pion_bytes_slice(b, start, end) {
    const pb = pNum(b);
    syncViews();
    const len = Number(dv.getBigInt64(pb, true));
    let a = Number(start), e = Number(end);
    if (a < 0) a = 0;
    if (e > len) e = len;
    if (e < a) e = a;
    const n = e - a;
    const out = pion_bytes_new(BigInt(n));
    const po = pNum(out);
    syncViews();
    const src = Number(dv.getBigInt64(pb + 16, true));
    const dst = Number(dv.getBigInt64(po + 16, true));
    if (n > 0) u8.copyWithin(dst, src + a, src + e);
    return out;
  }

  function pion_bytes_concat(a, b) {
    const pa = pNum(a), pb = pNum(b);
    syncViews();
    const la = Number(dv.getBigInt64(pa, true));
    const lb = Number(dv.getBigInt64(pb, true));
    const out = pion_bytes_new(BigInt(la + lb));
    const po = pNum(out);
    syncViews();
    const da = Number(dv.getBigInt64(pa + 16, true));
    const db = Number(dv.getBigInt64(pb + 16, true));
    const dst = Number(dv.getBigInt64(po + 16, true));
    if (la > 0) u8.copyWithin(dst, da, da + la);
    if (lb > 0) u8.copyWithin(dst + la, db, db + lb);
    return out;
  }

  function pion_bytes_from_ptr(ptr, len) {
    const lb = BigInt(len);
    if (lb < 0n) pionDie("negative bytes length");
    if (lb > 0x7FFFFFEFn) pionDie("container length exceeds maximum");
    const n = Number(lb);
    const out = pion_bytes_new(lb);
    const po = pNum(out);
    const src = pNum(ptr);
    syncViews();
    const dst = Number(dv.getBigInt64(po + 16, true));
    if (n > 0 && src) u8.copyWithin(dst, src, src + n);
    return out;
  }

  function pion_bytes_copy_to_ptr(b, srcOff, dstPtr, len) {
    const pb = pNum(b);
    const dst = pNum(dstPtr);
    const n = Math.max(0, Number(len));
    const off = Math.max(0, Number(srcOff));
    syncViews();
    const src = Number(dv.getBigInt64(pb + 16, true));
    if (n > 0 && dst && src) u8.copyWithin(dst, src + off, src + off + n);
  }

  // --- StringBuilder ---
  function pion_strbuf_new(cap) {
    const c = Math.max(Number(cap), 32);
    const obj = pion_alloc_uninit(24, TAG_STRBUF, 0n);
    const dp = rawAlloc(c);
    const p = pNum(obj);
    syncViews();
    dv.setBigInt64(p + 0, 0n, true);
    dv.setBigInt64(p + 8, BigInt(c), true);
    dv.setBigInt64(p + 16, pBig(dp), true);
    return obj;
  }

  function strbufEnsure(p, extra) {
    syncViews();
    const len = Number(dv.getBigInt64(p + 0, true));
    let cap = Number(dv.getBigInt64(p + 8, true));
    if (len + extra <= cap) return;
    let newCap = Math.max(cap * 2, len + extra + 32);
    const oldDp = Number(dv.getBigInt64(p + 16, true));
    const newDp = rawAlloc(newCap);
    syncViews();
    if (len > 0 && oldDp) u8.copyWithin(newDp, oldDp, oldDp + len);
    if (oldDp) rawFree(oldDp);
    dv.setBigInt64(p + 8, BigInt(newCap), true);
    dv.setBigInt64(p + 16, pBig(newDp), true);
  }

  function pion_strbuf_push_str(sb, s) {
    const p = pNum(sb), ps = pNum(s);
    if (!ps) return;
    syncViews();
    const slen = Number(dv.getBigInt64(ps, true));
    if (slen === 0) return;
    strbufEnsure(p, slen);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const dp = Number(dv.getBigInt64(p + 16, true));
    u8.copyWithin(dp + len, ps + 8, ps + 8 + slen);
    dv.setBigInt64(p, BigInt(len + slen), true);
  }

  function pion_strbuf_push_slice(sb, s, start, end) {
    const p = pNum(sb), ps = pNum(s);
    if (!p || !ps) return;
    syncViews();
    const slen = Number(dv.getBigInt64(ps, true));
    let a = Number(start);
    let b = Number(end);
    if (a < 0) a = 0;
    if (b > slen) b = slen;
    if (a >= b) return;
    const n = b - a;
    strbufEnsure(p, n);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const dp = Number(dv.getBigInt64(p + 16, true));
    u8.copyWithin(dp + len, ps + 8 + a, ps + 8 + b);
    dv.setBigInt64(p, BigInt(len + n), true);
  }

  function pion_strbuf_push_byte(sb, b) {
    const p = pNum(sb);
    strbufEnsure(p, 1);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const dp = Number(dv.getBigInt64(p + 16, true));
    u8[dp + len] = b & 0xff;
    dv.setBigInt64(p, BigInt(len + 1), true);
  }

  function pion_strbuf_push_char(sb, cp) {
    const p = pNum(sb);
    const c = cp >>> 0;
    if (c < 0x80) {
      pion_strbuf_push_byte(sb, c);
      return;
    }
    const encoded = textEncoder.encode(String.fromCodePoint(c));
    strbufEnsure(p, encoded.length);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const dp = Number(dv.getBigInt64(p + 16, true));
    u8.set(encoded, dp + len);
    dv.setBigInt64(p, BigInt(len + encoded.length), true);
  }

  function pion_strbuf_push_int(sb, v) {
    const p = pNum(sb);
    const bytes = textEncoder.encode(BigInt(v).toString(10));
    strbufEnsure(p, bytes.length);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const dp = Number(dv.getBigInt64(p + 16, true));
    u8.set(bytes, dp + len);
    dv.setBigInt64(p, BigInt(len + bytes.length), true);
  }

  function pion_strbuf_reset(sb) {
    syncViews();
    dv.setBigInt64(pNum(sb), 0n, true);
  }

  function pion_strbuf_to_str(sb) {
    const p = pNum(sb);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const dp = Number(dv.getBigInt64(p + 16, true));
    const obj = pion_alloc_uninit(8 + len + 1, TAG_STRING, 0n);
    const dst = pNum(obj);
    syncViews();
    dv.setBigInt64(dst, BigInt(len), true);
    if (len > 0 && dp) u8.copyWithin(dst + 8, dp, dp + len);
    u8[dst + 8 + len] = 0;
    return obj;
  }

  // --- Array ---
  function arrStride(p) {
    const s = dv.getInt32(p + 20, true);
    return s > 0 ? s : 8;
  }

  function arrRcAll(dp, len, elemIsObj, stride, isInc) {
    if (!elemIsObj || !dp || len <= 0) return;
    if (stride <= 8) {
      for (let i = 0; i < len; i++) {
        const ev = dv.getBigInt64(dp + i * 8, true);
        if (ev !== 0n) {
          if (isInc) pion_rc_inc(ev);
          else pion_rc_dec(ev);
          syncViews();
        }
      }
    } else {
      const mask = elemIsObj >>> 0;
      for (let i = 0; i < len; i++) {
        const base = dp + i * stride;
        for (let m = mask, k = 0; m !== 0; m >>>= 1, k++) {
          if (m & 1) {
            const ev = dv.getBigInt64(base + k * 8, true);
            if (ev !== 0n) {
              if (isInc) pion_rc_inc(ev);
              else pion_rc_dec(ev);
              syncViews();
            }
          }
        }
      }
    }
  }

  function pion_arr_new(cap, elemFlags) {
    const cb = BigInt(cap);
    if (cb > 0x7FFFFFEFn) pionDie("container length exceeds maximum");
    const c = Math.max(Number(cb), 0);
    const f = elemFlags | 0;
    const elemIsObj = f > 2 ? (f >>> 8) : (f === 1 ? 1 : 0);
    const elemStride = f === 2 ? 1 : (f > 2 ? (f & 0xFF) : 0);
    const esz = elemStride || 8;
    if (cb * BigInt(esz) > 0x7FFFFFE8n) pionDie("container byte size exceeds wasm32 limit");
    const obj = pion_alloc_uninit(32, TAG_ARRAY, 0n);
    const dp = c > 0 ? rawAlloc(c * esz) : 0;
    const p = pNum(obj);
    syncViews();
    dv.setBigInt64(p + 0, 0n, true);
    dv.setBigInt64(p + 8, BigInt(c), true);
    dv.setInt32(p + 16, elemIsObj, true);
    dv.setInt32(p + 20, elemStride, true);
    dv.setBigInt64(p + 24, pBig(dp), true);
    return obj;
  }

  function pion_arr_len(a) {
    syncViews();
    return dv.getBigInt64(pNum(a), true);
  }

  function arrEnsure(p, need) {
    syncViews();
    const cap = Number(dv.getBigInt64(p + 8, true));
    if (need <= cap) return;
    let newCap = cap < 8 ? 8 : cap * 2;
    while (newCap < need) newCap *= 2;
    const len = Number(dv.getBigInt64(p + 0, true));
    const esz = arrStride(p);
    const oldDp = Number(dv.getBigInt64(p + 24, true));
    const newDp = rawAlloc(newCap * esz);
    syncViews();
    if (len > 0 && oldDp) u8.copyWithin(newDp, oldDp, oldDp + len * esz);
    if (oldDp) rawFree(oldDp);
    dv.setBigInt64(p + 8, BigInt(newCap), true);
    dv.setBigInt64(p + 24, pBig(newDp), true);
  }

  function pion_arr_push_flat_grow(a) {
    const p = pNum(a);
    syncViews();
    const len = Number(dv.getBigInt64(p + 0, true));
    arrEnsure(p, len + 1);
    syncViews();
    const dp = Number(dv.getBigInt64(p + 24, true));
    const stride = arrStride(p);
    return pBig(dp + len * stride);
  }

  function pion_arr_push(a, val) {
    const p = pNum(a);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const elemIsObj = dv.getInt32(p + 16, true);
    const stride = dv.getInt32(p + 20, true);
    arrEnsure(p, len + 1);
    syncViews();
    if (stride === 1) {
      const dp = Number(dv.getBigInt64(p + 24, true));
      u8[dp + len] = Number(val) & 0xff;
      dv.setBigInt64(p, BigInt(len + 1), true);
      return;
    }
    if (stride === 4) {
      const dp = Number(dv.getBigInt64(p + 24, true));
      dv.setUint32(dp + len * 4, Number(BigInt(val) & 0xffffffffn), true);
      dv.setBigInt64(p, BigInt(len + 1), true);
      return;
    }
    if (elemIsObj && val !== 0n) pion_rc_inc(val);
    syncViews();
    const dp = Number(dv.getBigInt64(p + 24, true));
    dv.setBigInt64(dp + len * 8, BigInt(val), true);
    dv.setBigInt64(p, BigInt(len + 1), true);
  }

  function pion_arr_push_owned(a, val) {
    const p = pNum(a);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const stride = dv.getInt32(p + 20, true);
    arrEnsure(p, len + 1);
    syncViews();
    const dp = Number(dv.getBigInt64(p + 24, true));
    if (stride === 1) {
      u8[dp + len] = Number(val) & 0xff;
    } else if (stride === 4) {
      dv.setUint32(dp + len * 4, Number(BigInt(val) & 0xffffffffn), true);
    } else {
      dv.setBigInt64(dp + len * 8, BigInt(val), true);
    }
    dv.setBigInt64(p, BigInt(len + 1), true);
  }

  function pion_arr_get(a, idx) {
    const p = pNum(a);
    syncViews();
    const len = dv.getBigInt64(p, true);
    if (idx < 0n || idx >= len) pion_panic_oob(idx, len);
    const dp = Number(dv.getBigInt64(p + 24, true));
    const stride = dv.getInt32(p + 20, true);
    if (stride === 1) {
      return BigInt(u8[dp + Number(idx)]);
    }
    if (stride === 4) {
      return BigInt(dv.getUint32(dp + Number(idx) * 4, true));
    }
    return dv.getBigInt64(dp + Number(idx) * 8, true);
  }

  function pion_arr_set(a, idx, val) {
    const p = pNum(a);
    syncViews();
    const len = dv.getBigInt64(p, true);
    if (idx < 0n || idx >= len) pion_panic_oob(idx, len);
    const dp = Number(dv.getBigInt64(p + 24, true));
    const stride = dv.getInt32(p + 20, true);
    if (stride === 1) {
      u8[dp + Number(idx)] = Number(val) & 0xff;
      return;
    }
    if (stride === 4) {
      dv.setUint32(dp + Number(idx) * 4, Number(BigInt(val) & 0xffffffffn), true);
      return;
    }
    const elemIsObj = dv.getInt32(p + 16, true);
    const off = dp + Number(idx) * 8;
    const oldVal = dv.getBigInt64(off, true);
    if (elemIsObj && val !== 0n) pion_rc_inc(val);
    syncViews();
    dv.setBigInt64(off, BigInt(val), true);
    if (elemIsObj && oldVal !== 0n) pion_rc_dec(oldVal);
  }

  function pion_arr_pop(a) {
    const p = pNum(a);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    if (len <= 0) pion_panic_oob(-1n, 0n);
    const dp = Number(dv.getBigInt64(p + 24, true));
    const stride = dv.getInt32(p + 20, true);
    const val = stride === 1
      ? BigInt(u8[dp + (len - 1)])
      : stride === 4
      ? BigInt(dv.getUint32(dp + (len - 1) * 4, true))
      : dv.getBigInt64(dp + (len - 1) * 8, true);
    dv.setBigInt64(p, BigInt(len - 1), true);
    return val;
  }

  function pion_arr_copy(a) {
    const p = pNum(a);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const elemIsObj = dv.getInt32(p + 16, true);
    const stride = dv.getInt32(p + 20, true);
    const flags = stride > 1 ? (stride | (elemIsObj << 8)) : (stride === 1 ? 2 : elemIsObj);
    const esz = stride || 8;
    const out = pion_arr_new(BigInt(len), flags);
    const po = pNum(out);
    syncViews();
    const src = Number(dv.getBigInt64(p + 24, true));
    const dst = Number(dv.getBigInt64(po + 24, true));
    if (len > 0) {
      u8.copyWithin(dst, src, src + len * esz);
      arrRcAll(dst, len, elemIsObj, stride, true);
    }
    dv.setBigInt64(po, BigInt(len), true);
    return out;
  }

  function pion_arr_clear(a) {
    const p = pNum(a);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const elemIsObj = dv.getInt32(p + 16, true);
    const stride = dv.getInt32(p + 20, true);
    const dp = Number(dv.getBigInt64(p + 24, true));
    arrRcAll(dp, len, elemIsObj, stride, false);
    dv.setBigInt64(p, 0n, true);
  }

  function pion_arr_reverse(a) {
    const p = pNum(a);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const dp = Number(dv.getBigInt64(p + 24, true));
    const stride = arrStride(p);
    if (stride === 8) {
      for (let i = 0, j = len - 1; i < j; i++, j--) {
        const va = dv.getBigInt64(dp + i * 8, true);
        const vb = dv.getBigInt64(dp + j * 8, true);
        dv.setBigInt64(dp + i * 8, vb, true);
        dv.setBigInt64(dp + j * 8, va, true);
      }
    } else {
      const tmp = new Uint8Array(stride);
      for (let i = 0, j = len - 1; i < j; i++, j--) {
        const oi = dp + i * stride;
        const oj = dp + j * stride;
        tmp.set(u8.subarray(oi, oi + stride));
        u8.copyWithin(oi, oj, oj + stride);
        u8.set(tmp, oj);
      }
    }
  }

  function pion_arr_join(a, sep) {
    const p = pNum(a);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    const dp = Number(dv.getBigInt64(p + 24, true));
    const sp = readPionStr(sep);
    const parts = new Array(len);
    for (let i = 0; i < len; i++) {
      parts[i] = readPionStr(dv.getBigInt64(dp + i * 8, true));
    }
    return makePionStr(parts.join(sp));
  }

  function pion_arr_sort_int(a) {
    const p = pNum(a);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    if (len <= 1) return;
    const dp = Number(dv.getBigInt64(p + 24, true));
    const stride = dv.getInt32(p + 20, true);
    if (stride === 1) {
      u8.subarray(dp, dp + len).sort();
      return;
    }
    if (stride === 4) {
      new Int32Array(u8.buffer, dp, len).sort();
      return;
    }
    const vals = new Array(len);
    for (let i = 0; i < len; i++) vals[i] = dv.getBigInt64(dp + i * 8, true);
    vals.sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
    for (let i = 0; i < len; i++) dv.setBigInt64(dp + i * 8, vals[i], true);
  }

  function pion_arr_sort_str(a) {
    const p = pNum(a);
    syncViews();
    const len = Number(dv.getBigInt64(p, true));
    if (len <= 1) return;
    const dp = Number(dv.getBigInt64(p + 24, true));
    const vals = new Array(len);
    for (let i = 0; i < len; i++) vals[i] = dv.getBigInt64(dp + i * 8, true);
    vals.sort((x, y) => pion_str_cmp(x, y));
    for (let i = 0; i < len; i++) dv.setBigInt64(dp + i * 8, vals[i], true);
  }

  // --- Hash Map (32B PionMapEntry: key@0, hash@8, val@16, state@24) ---
  function mapAllocEntries(cap) {
    return rawAllocZero(cap * 32);
  }

  function pion_map_new_common(valIsObj, keyIsInt) {
    const initCap = 16;
    const obj = pion_alloc_uninit(32, TAG_MAP, 0n);
    const entries = mapAllocEntries(initCap);
    const p = pNum(obj);
    syncViews();
    dv.setBigInt64(p + 0, 0n, true);
    dv.setBigInt64(p + 8, BigInt(initCap), true);
    dv.setInt32(p + 16, valIsObj | 0, true);
    dv.setInt32(p + 20, keyIsInt | 0, true);
    dv.setBigInt64(p + 24, pBig(entries), true);
    return obj;
  }

  function pion_map_new(valIsObj) { return pion_map_new_common(valIsObj, 0); }
  function pion_map_new_int(valIsObj) { return pion_map_new_common(valIsObj, 1); }

  function pion_map_len(m) {
    syncViews();
    return dv.getBigInt64(pNum(m), true);
  }

  function mapKeyHash(key, keyIsInt) {
    if (keyIsInt) return hashInt64(key, hashSeed, hashSeed2);
    const pk = pNum(key);
    syncViews();
    const len = Number(dv.getBigInt64(pk, true));
    return hashBytes64(u8, dv, pk + 8, len, hashSeed, hashSeed2);
  }

  function mapKeyEq(a, b, keyIsInt) {
    if (keyIsInt) return a === b;
    return pion_str_eq(a, b) !== 0;
  }

  function mapGrow(p) {
    syncViews();
    const oldCap = Number(dv.getBigInt64(p + 8, true));
    const oldEntries = Number(dv.getBigInt64(p + 24, true));
    const newCap = oldCap < 16 ? 16 : oldCap * 2;
    const newEntries = mapAllocEntries(newCap);
    syncViews();
    const mask = newCap - 1;
    for (let i = 0; i < oldCap; i++) {
      const oe = oldEntries + i * 32;
      if (u8[oe + 24] === 1) {
        const hLo = dv.getUint32(oe + 8, true);
        let idx = (hLo & mask) >>> 0;
        while (u8[newEntries + idx * 32 + 24] === 1) {
          idx = (idx + 1) & mask;
        }
        const ne = newEntries + idx * 32;
        dv.setUint32(ne + 0, dv.getUint32(oe + 0, true), true);
        dv.setUint32(ne + 4, dv.getUint32(oe + 4, true), true);
        dv.setUint32(ne + 8, hLo, true);
        dv.setUint32(ne + 12, dv.getUint32(oe + 12, true), true);
        dv.setUint32(ne + 16, dv.getUint32(oe + 16, true), true);
        dv.setUint32(ne + 20, dv.getUint32(oe + 20, true), true);
        u8[ne + 24] = 1;
      }
    }
    if (oldEntries) rawFree(oldEntries);
    if (slabCtl > 0) dv.setUint32(slabCtl + 48, 0, true);
    dv.setBigInt64(p + 8, BigInt(newCap), true);
    dv.setBigInt64(p + 24, pBig(newEntries), true);
  }

  function pion_map_set(m, key, val) {
    const p = pNum(m);
    syncViews();
    let len = Number(dv.getBigInt64(p + 0, true));
    let cap = Number(dv.getBigInt64(p + 8, true));
    if ((len + 1) * 10 >= cap * 7) {
      mapGrow(p);
      syncViews();
      cap = Number(dv.getBigInt64(p + 8, true));
    }
    const valIsObj = dv.getInt32(p + 16, true);
    const keyIsInt = dv.getInt32(p + 20, true);
    const entries = Number(dv.getBigInt64(p + 24, true));
    const h = mapKeyHash(key, keyIsInt);
    const mask = cap - 1;
    let idx = Number(h & BigInt(mask));
    while (true) {
      const e = entries + idx * 32;
      const st = u8[e + 24];
      if (st === 0) {
        if (!keyIsInt && key !== 0n) pion_rc_inc(key);
        if (valIsObj && val !== 0n) pion_rc_inc(val);
        syncViews();
        dv.setBigInt64(e + 0, BigInt(key), true);
        dv.setBigUint64(e + 8, h, true);
        dv.setBigInt64(e + 16, BigInt(val), true);
        u8[e + 24] = 1;
        dv.setBigInt64(p + 0, BigInt(len + 1), true);
        return;
      }
      if (dv.getBigUint64(e + 8, true) === h && mapKeyEq(dv.getBigInt64(e + 0, true), key, keyIsInt)) {
        const oldVal = dv.getBigInt64(e + 16, true);
        if (valIsObj && val !== 0n) pion_rc_inc(val);
        syncViews();
        dv.setBigInt64(e + 16, BigInt(val), true);
        if (valIsObj && oldVal !== 0n) pion_rc_dec(oldVal);
        return;
      }
      idx = (idx + 1) & mask;
    }
  }

  function mapFindSlot(p, key) {
    syncViews();
    const cap = Number(dv.getBigInt64(p + 8, true));
    if (cap === 0) return -1;
    const keyIsInt = dv.getInt32(p + 20, true);
    const entries = Number(dv.getBigInt64(p + 24, true));
    const h = mapKeyHash(key, keyIsInt);
    const mask = cap - 1;
    let idx = Number(h & BigInt(mask));
    for (let step = 0; step < cap; step++) {
      const e = entries + idx * 32;
      if (u8[e + 24] === 0) return -1;
      if (dv.getBigUint64(e + 8, true) === h && mapKeyEq(dv.getBigInt64(e + 0, true), key, keyIsInt)) {
        return idx;
      }
      idx = (idx + 1) & mask;
    }
    return -1;
  }

  function pion_map_has(m, key) {
    return mapFindSlot(pNum(m), key) >= 0 ? 1 : 0;
  }

  function pion_map_get(m, key) {
    const p = pNum(m);
    const slot = mapFindSlot(p, key);
    if (slot < 0) return 0n;
    syncViews();
    const entries = Number(dv.getBigInt64(p + 24, true));
    return dv.getBigInt64(entries + slot * 32 + 16, true);
  }

  function pion_map_try_get(m, key, outValPtr) {
    const p = pNum(m);
    const slot = mapFindSlot(p, key);
    const op = pNum(outValPtr);
    if (slot < 0) {
      if (op) { syncViews(); dv.setBigInt64(op, 0n, true); }
      return 0;
    }
    syncViews();
    const entries = Number(dv.getBigInt64(p + 24, true));
    const val = dv.getBigInt64(entries + slot * 32 + 16, true);
    if (op) dv.setBigInt64(op, val, true);
    return 1;
  }

  function pion_map_remove(m, key) {
    const p = pNum(m);
    const slot = mapFindSlot(p, key);
    if (slot < 0) return;
    syncViews();
    if (slabCtl > 0) dv.setUint32(slabCtl + 48, 0, true);
    const cap = Number(dv.getBigInt64(p + 8, true));
    const valIsObj = dv.getInt32(p + 16, true);
    const keyIsInt = dv.getInt32(p + 20, true);
    const entries = Number(dv.getBigInt64(p + 24, true));
    const mask = cap - 1;

    const e0 = entries + slot * 32;
    const oldKey = dv.getBigInt64(e0 + 0, true);
    const oldVal = dv.getBigInt64(e0 + 16, true);
    u8[e0 + 24] = 0;

    // Backward-shift deletion to preserve linear probing invariant (state only 0 or 1)
    let hole = slot;
    let cur = (slot + 1) & mask;
    while (u8[entries + cur * 32 + 24] === 1) {
      const h = dv.getBigUint64(entries + cur * 32 + 8, true);
      const nat = Number(h & BigInt(mask));
      const distCur = (cur - nat) & mask;
      const distHole = (hole - nat) & mask;
      if (distHole < distCur) {
        u8.copyWithin(entries + hole * 32, entries + cur * 32, entries + cur * 32 + 32);
        u8[entries + cur * 32 + 24] = 0;
        hole = cur;
      }
      cur = (cur + 1) & mask;
    }

    const len = Number(dv.getBigInt64(p + 0, true));
    dv.setBigInt64(p + 0, BigInt(len - 1), true);
    if (!keyIsInt && oldKey !== 0n) pion_rc_dec(oldKey);
    if (valIsObj && oldVal !== 0n) pion_rc_dec(oldVal);
  }

  function pion_map_clear(m) {
    const p = pNum(m);
    syncViews();
    if (slabCtl > 0) dv.setUint32(slabCtl + 48, 0, true);
    const cap = Number(dv.getBigInt64(p + 8, true));
    const valIsObj = dv.getInt32(p + 16, true);
    const keyIsInt = dv.getInt32(p + 20, true);
    const entries = Number(dv.getBigInt64(p + 24, true));
    if (entries) {
      for (let i = 0; i < cap; i++) {
        const e = entries + i * 32;
        if (u8[e + 24] === 1) {
          const k = dv.getBigInt64(e + 0, true);
          const v = dv.getBigInt64(e + 16, true);
          u8[e + 24] = 0;
          if (!keyIsInt && k !== 0n) pion_rc_dec(k);
          if (valIsObj && v !== 0n) pion_rc_dec(v);
          syncViews();
        }
      }
    }
    dv.setBigInt64(p + 0, 0n, true);
  }

  function pion_map_copy(m) {
    const p = pNum(m);
    syncViews();
    const cap = Number(dv.getBigInt64(p + 8, true));
    const valIsObj = dv.getInt32(p + 16, true);
    const keyIsInt = dv.getInt32(p + 20, true);
    const entries = Number(dv.getBigInt64(p + 24, true));
    const out = pion_map_new_common(valIsObj, keyIsInt);
    for (let i = 0; i < cap; i++) {
      syncViews();
      const e = entries + i * 32;
      if (u8[e + 24] === 1) {
        const k = dv.getBigInt64(e + 0, true);
        const v = dv.getBigInt64(e + 16, true);
        pion_map_set(out, k, v);
      }
    }
    return out;
  }

  function pion_map_keys(m) {
    const p = pNum(m);
    syncViews();
    const len = Number(dv.getBigInt64(p + 0, true));
    const cap = Number(dv.getBigInt64(p + 8, true));
    const keyIsInt = dv.getInt32(p + 20, true);
    const entries = Number(dv.getBigInt64(p + 24, true));
    const arr = pion_arr_new(BigInt(len), keyIsInt ? 0 : 1);
    for (let i = 0; i < cap; i++) {
      syncViews();
      const e = entries + i * 32;
      if (u8[e + 24] === 1) {
        const k = dv.getBigInt64(e + 0, true);
        pion_arr_push(arr, k);
      }
    }
    return arr;
  }

  // --- Single-threaded Concurrency Stubs ---
  const channels = new Map();

  function pion_scope_begin() { return pion_alloc(8, TAG_SCOPE, 0n); }
  function pion_scope_spawn(_scope, fnIdx, env) {
    const idx = Number(fnIdx);
    if (idx !== 0 && exportsObj && exportsObj.__indirect_function_table) {
      const fn = exportsObj.__indirect_function_table.get(idx);
      if (fn) fn(BigInt(env));
    }
  }
  function pion_scope_end(scope) { pion_rc_dec(scope); }

  function pion_chan_new(cap, elemIsObj) {
    const obj = pion_alloc(16, TAG_CHANNEL, 0n);
    channels.set(pNum(obj), { cap: Number(cap), elemIsObj: elemIsObj | 0, queue: [], closed: false });
    return obj;
  }
  function pion_chan_send(ch, val) {
    const c = channels.get(pNum(ch));
    if (!c || c.closed) return 0;
    if (c.elemIsObj && val !== 0n) pion_rc_inc(val);
    c.queue.push(BigInt(val));
    return 1;
  }
  function pion_chan_recv(ch, outValPtr) {
    const c = channels.get(pNum(ch));
    const op = pNum(outValPtr);
    if (!c || c.queue.length === 0) {
      if (op) { syncViews(); dv.setBigInt64(op, 0n, true); }
      return 0;
    }
    const v = c.queue.shift();
    if (op) { syncViews(); dv.setBigInt64(op, v, true); }
    return 1;
  }
  function pion_chan_close(ch) {
    const c = channels.get(pNum(ch));
    if (c) c.closed = true;
  }

  function pion_mutex_new(initVal, valIsObj) {
    const obj = pion_alloc(16, TAG_MUTEX, 0n);
    const p = pNum(obj);
    if (valIsObj && initVal !== 0n) pion_rc_inc(initVal);
    syncViews();
    dv.setBigInt64(p + 0, BigInt(initVal), true);
    dv.setInt32(p + 8, valIsObj | 0, true);
    return obj;
  }
  function pion_mutex_lock(m) {
    syncViews();
    return dv.getBigInt64(pNum(m), true);
  }
  function pion_mutex_set(m, newVal) {
    const p = pNum(m);
    syncViews();
    const valIsObj = dv.getInt32(p + 8, true);
    const oldVal = dv.getBigInt64(p + 0, true);
    if (valIsObj && newVal !== 0n) pion_rc_inc(newVal);
    syncViews();
    dv.setBigInt64(p + 0, BigInt(newVal), true);
    if (valIsObj && oldVal !== 0n) pion_rc_dec(oldVal);
  }
  function pion_mutex_set_and_unlock(m, newVal) { pion_mutex_set(m, newVal); }
  function pion_mutex_unlock(_m) {}

  function pion_atomic_new(initVal) {
    const obj = pion_alloc(8, TAG_ATOMIC, 0n);
    syncViews();
    dv.setBigInt64(pNum(obj), BigInt(initVal), true);
    return obj;
  }
  function pion_atomic_load(a) {
    syncViews();
    return dv.getBigInt64(pNum(a), true);
  }
  function pion_atomic_store(a, val) {
    syncViews();
    dv.setBigInt64(pNum(a), BigInt(val), true);
  }
  function pion_atomic_fetch_add(a, delta) {
    const p = pNum(a);
    syncViews();
    const old = dv.getBigInt64(p, true);
    dv.setBigInt64(p, BigInt.asIntN(64, old + BigInt(delta)), true);
    return old;
  }

  // --- World Capabilities ---
  function pion_world_init(_argc, _argv) {
    return pion_alloc(16, TAG_WORLD, 0n);
  }
  function pion_world_argc(_w) { return BigInt(cliArgs.length); }
  function pion_world_argv(_w, idx) {
    const i = Number(idx);
    if (i < 0 || i >= cliArgs.length) pion_panic_oob(idx, BigInt(cliArgs.length));
    return makePionStr(cliArgs[i]);
  }
  function pion_world_args(_w) {
    const arr = pion_arr_new(BigInt(cliArgs.length), 1);
    for (let i = 0; i < cliArgs.length; i++) {
      pion_arr_push_owned(arr, makePionStr(cliArgs[i]));
    }
    return arr;
  }
  function pion_world_print(_w, s) { printFn(readPionStr(s)); }
  function pion_world_println(_w, s) { printlnFn(readPionStr(s)); }
  function pion_world_eprintln(_w, s) { eprintlnFn(readPionStr(s)); }
  function pion_world_clock_ms(_w) {
    return BigInt(Math.floor(typeof performance !== "undefined" ? performance.now() : Date.now()));
  }
  function pion_clock_monotonic_us() {
    return BigInt(Math.round((typeof performance !== "undefined" ? performance.now() : Date.now()) * 1000));
  }
  let atomicTmpSeq = 0;
  function pion_fs_mmap_ro(pathStr, okOut) {
    const op = pNum(okOut);
    if (!nodeFs) {
      if (op) { syncViews(); dv.setInt32(op, 0, true); }
      return makePionStr("fs_mmap_ro unavailable");
    }
    try {
      const p = readPionStr(pathStr);
      const st = nodeFs.statSync(p);
      if (!st.isFile()) {
        if (op) { syncViews(); dv.setInt32(op, 0, true); }
        return makePionStr("fs_mmap_ro: not a regular file");
      }
      const data = nodeFs.readFileSync(p);
      const b = pion_bytes_new(BigInt(data.length));
      const pb = pNum(b);
      syncViews();
      if (data.length > 0) {
        const dp = Number(dv.getBigInt64(pb + 16, true));
        u8.set(data, dp);
        dv.setBigInt64(pb + 8, -1n, true);
      }
      if (op) dv.setInt32(op, 1, true);
      return b;
    } catch (e) {
      if (op) { syncViews(); dv.setInt32(op, 0, true); }
      return makePionStr(String(e && e.message ? e.message : e));
    }
  }
  function pion_fs_write_atomic_bytes(pathStr, bytesObj) {
    if (!nodeFs) return 0;
    const p = readPionStr(pathStr);
    const tmp = `${p}.piontmp.${process.pid}.${++atomicTmpSeq}`;
    try {
      const pb = pNum(bytesObj);
      syncViews();
      const len = Number(dv.getBigInt64(pb, true));
      const dp = Number(dv.getBigInt64(pb + 16, true));
      nodeFs.writeFileSync(tmp, len > 0 ? u8.subarray(dp, dp + len) : new Uint8Array(0));
      nodeFs.renameSync(tmp, p);
      return 1;
    } catch {
      try { nodeFs.unlinkSync(tmp); } catch {}
      return 0;
    }
  }
  function pion_world_env_get(_w, nameStr, okOut) {
    const name = readPionStr(nameStr);
    const op = pNum(okOut);
    if (isNode && Object.prototype.hasOwnProperty.call(process.env, name)) {
      if (op) { syncViews(); dv.setInt32(op, 1, true); }
      return makePionStr(process.env[name] || "");
    }
    if (op) { syncViews(); dv.setInt32(op, 0, true); }
    return makePionStr("");
  }

  function pion_world_fs_read(_w, pathStr, okOut) {
    const op = pNum(okOut);
    if (!nodeFs) { if (op) { syncViews(); dv.setInt32(op, 0, true); } return makePionStr(""); }
    try {
      const data = nodeFs.readFileSync(readPionStr(pathStr));
      if (op) { syncViews(); dv.setInt32(op, 1, true); }
      return makePionStrFromBytes(data);
    } catch {
      if (op) { syncViews(); dv.setInt32(op, 0, true); }
      return makePionStr("");
    }
  }
  function pion_world_fs_write(_w, pathStr, contentStr) {
    if (!nodeFs) return 0;
    try {
      const ps = pNum(contentStr);
      syncViews();
      const len = Number(dv.getBigInt64(ps, true));
      nodeFs.writeFileSync(readPionStr(pathStr), u8.subarray(ps + 8, ps + 8 + len));
      return 1;
    } catch { return 0; }
  }
  function pion_world_fs_read_bytes(_w, pathStr, okOut) {
    const op = pNum(okOut);
    if (!nodeFs) { if (op) { syncViews(); dv.setInt32(op, 0, true); } return pion_bytes_new(0n); }
    try {
      const data = nodeFs.readFileSync(readPionStr(pathStr));
      const b = pion_bytes_new(BigInt(data.length));
      const pb = pNum(b);
      syncViews();
      const dp = Number(dv.getBigInt64(pb + 16, true));
      u8.set(data, dp);
      if (op) dv.setInt32(op, 1, true);
      return b;
    } catch {
      if (op) { syncViews(); dv.setInt32(op, 0, true); }
      return pion_bytes_new(0n);
    }
  }
  function pion_world_fs_write_bytes(_w, pathStr, bytesObj) {
    if (!nodeFs) return 0;
    try {
      const pb = pNum(bytesObj);
      syncViews();
      const len = Number(dv.getBigInt64(pb, true));
      const dp = Number(dv.getBigInt64(pb + 16, true));
      nodeFs.writeFileSync(readPionStr(pathStr), u8.subarray(dp, dp + len));
      return 1;
    } catch { return 0; }
  }
  function pion_world_fs_append(_w, pathStr, contentStr) {
    if (!nodeFs) return 0;
    try { nodeFs.appendFileSync(readPionStr(pathStr), readPionStr(contentStr)); return 1; } catch { return 0; }
  }
  function pion_world_fs_exists(_w, pathStr) {
    return nodeFs && nodeFs.existsSync(readPionStr(pathStr)) ? 1 : 0;
  }
  function pion_world_fs_is_dir(_w, pathStr) {
    if (!nodeFs) return 0;
    try { return nodeFs.statSync(readPionStr(pathStr)).isDirectory() ? 1 : 0; } catch { return 0; }
  }
  function pion_world_fs_mkdir_p(_w, pathStr) {
    if (!nodeFs) return 0;
    try { nodeFs.mkdirSync(readPionStr(pathStr), { recursive: true }); return 1; } catch { return 0; }
  }
  function pion_world_fs_list_dir(_w, pathStr) {
    const arr = pion_arr_new(0n, 1);
    if (!nodeFs) return arr;
    try {
      for (const name of nodeFs.readdirSync(readPionStr(pathStr))) {
        pion_arr_push_owned(arr, makePionStr(name));
      }
    } catch {}
    return arr;
  }
  function pion_world_fs_remove(_w, pathStr) {
    if (!nodeFs) return 0;
    try { nodeFs.rmSync(readPionStr(pathStr), { recursive: true, force: true }); return 1; } catch { return 0; }
  }
  function pion_world_fs_rename(_w, oldP, newP) {
    if (!nodeFs) return 0;
    try { nodeFs.renameSync(readPionStr(oldP), readPionStr(newP)); return 1; } catch { return 0; }
  }
  function pion_world_fs_size(_w, pathStr) {
    if (!nodeFs) return -1n;
    try { return BigInt(nodeFs.statSync(readPionStr(pathStr)).size); } catch { return -1n; }
  }
  function pion_world_fs_mtime_ms(_w, pathStr) {
    if (!nodeFs) return -1n;
    try { return BigInt(Math.floor(nodeFs.statSync(readPionStr(pathStr)).mtimeMs)); } catch { return -1n; }
  }
  function pion_world_read_line(_w, okOut) {
    const op = pNum(okOut);
    if (op) { syncViews(); dv.setInt32(op, 0, true); }
    return makePionStr("");
  }
  function pion_sha256_hex(s) {
    if (!nodeCrypto && isNode) {
      nodeCrypto = getBuiltin("node:crypto");
    }
    if (nodeCrypto) {
      const ps = pNum(s);
      syncViews();
      const len = Number(dv.getBigInt64(ps, true));
      const hex = nodeCrypto.createHash("sha256").update(u8.subarray(ps + 8, ps + 8 + len)).digest("hex");
      return makePionStr(hex);
    }
    return makePionStr("");
  }
  function pion_world_exec(_w, _argv) { return -1; }
  function pion_world_exec_capture(_w, _argv, ecOut) {
    const ep = pNum(ecOut);
    if (ep) { syncViews(); dv.setInt32(ep, -1, true); }
    return makePionStr("");
  }
  function pion_world_exec_capture_bytes(_w, _argv, ecOut) {
    const ep = pNum(ecOut);
    if (ep) { syncViews(); dv.setInt32(ep, -1, true); }
    return pion_bytes_new(0n);
  }
  function pion_world_fs_lstat(_w, _p, okOut) {
    const op = pNum(okOut);
    if (op) { syncViews(); dv.setInt32(op, 0, true); }
    return makePionStr("");
  }
  function pion_world_fs_readlink(_w, _p, okOut) {
    const op = pNum(okOut);
    if (op) { syncViews(); dv.setInt32(op, 0, true); }
    return makePionStr("");
  }
  function pion_world_fs_symlink(_w, _t, _l) { return 0; }
  function pion_world_fs_chmod(_w, _p, _m) { return 0; }
  function pion_world_fs_read_range_nofollow(_w, _p, _o, _l, _e, okOut) {
    const op = pNum(okOut);
    if (op) { syncViews(); dv.setInt32(op, 0, true); }
    return pion_bytes_new(0n);
  }

  // --- Raw Pointer FFI ---
  function pion_ptr_alloc(bytes) { return pBig(rawAllocZero(Number(bytes))); }
  function pion_ptr_free(p) { rawFree(pNum(p)); }
  function pion_ptr_offset(p, off) { return BigInt.asIntN(64, BigInt(p) + BigInt(off)); }
  function pion_ptr_read_ptr(p, off) { syncViews(); return dv.getBigInt64(pNum(p) + Number(off), true); }
  function pion_ptr_write_ptr(p, off, v) { syncViews(); dv.setBigInt64(pNum(p) + Number(off), BigInt(v), true); }
  function pion_ptr_read_u8(p, off) { syncViews(); return u8[pNum(p) + Number(off)]; }
  function pion_ptr_write_u8(p, off, v) { syncViews(); u8[pNum(p) + Number(off)] = v & 0xff; }
  function pion_ptr_read_i32(p, off) { syncViews(); return dv.getInt32(pNum(p) + Number(off), true); }
  function pion_ptr_write_i32(p, off, v) { syncViews(); dv.setInt32(pNum(p) + Number(off), v | 0, true); }
  function pion_ptr_read_i64(p, off) { syncViews(); return dv.getBigInt64(pNum(p) + Number(off), true); }
  function pion_ptr_write_i64(p, off, v) { syncViews(); dv.setBigInt64(pNum(p) + Number(off), BigInt(v), true); }
  function pion_cstr_to_str(cstr) { return makePionStr(readCStr(cstr)); }


  // Portable SIMD Vector & INT8 Matvec Primitives (P75-B)
  function simdSlice(obj, isBytes, stride, off, need) {
    syncViews();
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
      pion_cur_tid, pion_alloc, pion_alloc_uninit,
      pion_rc_inc, pion_rc_dec, pion_rc_dec_slow, pion_rc_freeze, pion_rc_immortalize,
      pion_panic, pion_panic_oob, pion_debug_assert,

      // Math & C libm functions emitted directly by qbe.pion
      pion_math_sqrt, pion_math_abs, pion_math_floor, pion_math_ceil,
      pion_math_sin, pion_math_cos, pion_math_pow,
      sqrt: Math.sqrt, cbrt: Math.cbrt, fabs: Math.abs, floor: Math.floor, ceil: Math.ceil,
      round: c99Round,
      trunc: Math.trunc, sin: Math.sin, cos: Math.cos, tan: Math.tan,
      asin: Math.asin, acos: Math.acos, atan: Math.atan, pow: c99Pow,
      atan2: Math.atan2, log: Math.log, log1p: Math.log1p, exp: Math.exp, fmod: (a, b) => a % b,
      roundf: (x) => Math.fround(c99Round(Math.fround(x))),
      truncf: (x) => Math.fround(Math.trunc(x)),
      floorf: (x) => Math.fround(Math.floor(x)),
      ceilf: (x) => Math.fround(Math.ceil(x)),
      fabsf: (x) => Math.fround(Math.abs(x)),
      sqrtf: (x) => Math.fround(Math.sqrt(x)),
      cbrtf: (x) => Math.fround(Math.cbrt(x)),
      powf: (x, y) => Math.fround(c99Pow(x, y)),
      expf: (x) => Math.fround(Math.exp(x)),
      logf: (x) => Math.fround(Math.log(x)),
      sinf: (x) => Math.fround(Math.sin(x)),
      cosf: (x) => Math.fround(Math.cos(x)),
      tanf: (x) => Math.fround(Math.tan(x)),
      atan2f: (y, x) => Math.fround(Math.atan2(y, x)),
      asinf: (x) => Math.fround(Math.asin(x)),
      acosf: (x) => Math.fround(Math.acos(x)),
      atanf: (x) => Math.fround(Math.atan(x)),

      // String
      pion_str_from_cstr, pion_str_len, pion_str_byte_at,
      pion_str_concat, pion_str_concat_n, pion_str_eq, pion_str_cmp,
      pion_str_slice, pion_int_to_str, pion_uint64_to_str,
      pion_double_to_str, pion_float_to_str,
      pion_str_to_int, pion_str_to_double,
      pion_str_starts_with, pion_str_ends_with, pion_str_contains,
      pion_str_index_of, pion_str_trim, pion_str_split, pion_str_replace,
      pion_str_to_bytes, pion_bytes_to_str,

      // Bytes
      pion_bytes_new, pion_bytes_len, pion_bytes_get, pion_bytes_set,
      pion_bytes_slice, pion_bytes_concat, pion_bytes_from_ptr, pion_bytes_copy_to_ptr,

      // StringBuilder
      pion_strbuf_new, pion_strbuf_push_str, pion_strbuf_push_slice, pion_strbuf_push_byte,
      pion_strbuf_push_char, pion_strbuf_push_int, pion_strbuf_reset, pion_strbuf_to_str,

      // Array
      pion_arr_new, pion_arr_len, pion_arr_push, pion_arr_push_owned, pion_arr_push_flat_grow,
      pion_arr_get, pion_arr_set, pion_arr_pop, pion_arr_copy,
      pion_arr_clear, pion_arr_reverse, pion_arr_join,
      pion_arr_sort_int, pion_arr_sort_str,
      pion_simd_i8_dot, pion_simd_i8_mv, pion_simd_f32,

      // Map
      pion_map_new, pion_map_new_int, pion_map_len, pion_map_set,
      pion_map_has, pion_map_get, pion_map_try_get, pion_map_remove,
      pion_map_clear, pion_map_copy, pion_map_keys,

      // Concurrency
      pion_scope_begin, pion_scope_spawn, pion_scope_end,
      pion_chan_new, pion_chan_send, pion_chan_recv, pion_chan_close,
      pion_mutex_new, pion_mutex_lock, pion_mutex_set, pion_mutex_set_and_unlock, pion_mutex_unlock,
      pion_atomic_new, pion_atomic_load, pion_atomic_store, pion_atomic_fetch_add,

      // World
      pion_world_init, pion_world_argc, pion_world_argv, pion_world_args,
      pion_world_print, pion_world_println, pion_world_eprintln,
      pion_world_read_line, pion_world_clock_ms, pion_world_env_get,
      pion_clock_monotonic_us, pion_fs_mmap_ro, pion_fs_write_atomic_bytes,
      pion_world_fs_read, pion_world_fs_write, pion_world_fs_read_bytes,
      pion_world_fs_write_bytes, pion_world_fs_append, pion_world_fs_mtime_ms,
      pion_world_fs_exists, pion_world_fs_is_dir, pion_world_fs_mkdir_p,
      pion_world_fs_list_dir, pion_world_fs_remove, pion_world_fs_rename,
      pion_world_fs_size, pion_world_fs_lstat, pion_world_fs_readlink,
      pion_world_fs_symlink, pion_world_fs_chmod, pion_world_fs_read_range_nofollow,
      pion_world_exec, pion_world_exec_capture, pion_world_exec_capture_bytes,
      pion_sha256_hex,

      // Raw pointers
      pion_ptr_alloc, pion_ptr_free, pion_ptr_offset,
      pion_ptr_read_ptr, pion_ptr_write_ptr,
      pion_ptr_read_u8, pion_ptr_write_u8,
      pion_ptr_read_i32, pion_ptr_write_i32,
      pion_ptr_read_i64, pion_ptr_write_i64,
      pion_cstr_to_str,
    },
  };

  if (exportsObj) bindExports(exportsObj);

  return {
    imports,
    bindExports,
    getStdout: () => stdoutChunks.join(""),
    getStderr: () => stderrChunks.join(""),
  };
}

const SYNC_INSTANTIATE_LIMIT = 8 * 1024 * 1024;

export function runWasmBytesSync(wasmBytes, args = [], options = {}) {
  const rt = createPionRuntime({ ...options, args });
  const mod = new WebAssembly.Module(wasmBytes);
  const instance = new WebAssembly.Instance(mod, rt.imports);
  rt.bindExports(instance.exports);
  const mainFn = instance.exports.main || instance.exports._start || instance.exports.pion_main;
  if (typeof mainFn !== "function") {
    throw new Error("Wasm module does not export main()");
  }
  const rc = mainFn(args.length | 0, 0n);
  return { exitCode: typeof rc === "number" ? rc : 0, runtime: rt, instance };
}

export async function runWasmBytes(wasmBytes, args = [], options = {}) {
  if (IS_NODE_ENV && wasmBytes && wasmBytes.byteLength <= SYNC_INSTANTIATE_LIMIT) {
    return runWasmBytesSync(wasmBytes, args, options);
  }
  const rt = createPionRuntime({ ...options, args });
  const { instance } = await WebAssembly.instantiate(wasmBytes, rt.imports);
  rt.bindExports(instance.exports);
  const mainFn = instance.exports.main || instance.exports._start || instance.exports.pion_main;
  if (typeof mainFn !== "function") {
    throw new Error("Wasm module does not export main()");
  }
  const rc = mainFn(args.length | 0, 0n);
  return { exitCode: typeof rc === "number" ? rc : 0, runtime: rt, instance };
}

export async function runWasmFile(wasmPath, args = [], options = {}) {
  const fs = options.fs || getBuiltin("node:fs") || (await import("node:fs"));
  const wasmBytes = fs.readFileSync(wasmPath);
  if (HAS_GET_BUILTIN) {
    return runWasmBytes(wasmBytes, args, { fs, ...options });
  }
  const crypto = options.crypto || (await import("node:crypto"));
  return runWasmBytes(wasmBytes, args, { fs, crypto, ...options });
}

// CLI Runner: `node runtime/pion_wasm_rt.mjs <app.wasm> [args...]`
if (IS_NODE_ENV && process.argv[1]) {
  const urlMod = getBuiltin("node:url");
  const pathMod = getBuiltin("node:path");
  const fsMod = getBuiltin("node:fs");
  const safeRealpath = (fsObj, pathObj, p) => {
    try {
      return fsObj ? fsObj.realpathSync(p) : pathObj.resolve(p);
    } catch {
      return pathObj.resolve(p);
    }
  };
  if (urlMod && pathMod) {
    if (safeRealpath(fsMod, pathMod, urlMod.fileURLToPath(import.meta.url)) === safeRealpath(fsMod, pathMod, process.argv[1])) {
      const wasmPath = process.argv[2];
      if (!wasmPath) {
        process.stderr.write("usage: node pion_wasm_rt.mjs <module.wasm> [args...]\n");
        process.exit(2);
      }
      const progArgs = process.argv.slice(2);
      try {
        const fs = fsMod || getBuiltin("node:fs");
        const wasmBytes = fs.readFileSync(wasmPath);
        if (wasmBytes.byteLength <= SYNC_INSTANTIATE_LIMIT) {
          const { exitCode } = runWasmBytesSync(wasmBytes, progArgs, { fs });
          process.exitCode = exitCode | 0;
        } else {
          runWasmBytes(wasmBytes, progArgs, { fs }).then(
            ({ exitCode }) => { process.exitCode = exitCode | 0; },
            (err) => {
              process.stderr.write((err && err.stack ? err.stack : String(err)) + "\n");
              process.exitCode = 1;
            },
          );
        }
      } catch (err) {
        process.stderr.write((err && err.stack ? err.stack : String(err)) + "\n");
        process.exit(1);
      }
    }
  } else {
    (async () => {
      const { fileURLToPath } = await import("node:url");
      const pathAsync = await import("node:path");
      const fsAsync = await import("node:fs");
      if (safeRealpath(fsAsync, pathAsync, fileURLToPath(import.meta.url)) !== safeRealpath(fsAsync, pathAsync, process.argv[1])) return;
      const wasmPath = process.argv[2];
      if (!wasmPath) {
        process.stderr.write("usage: node pion_wasm_rt.mjs <module.wasm> [args...]\n");
        process.exit(2);
      }
      const progArgs = process.argv.slice(2);
      const { exitCode } = await runWasmFile(wasmPath, progArgs);
      process.exitCode = exitCode | 0;
    })().catch((err) => {
      process.stderr.write((err && err.stack ? err.stack : String(err)) + "\n");
      process.exitCode = 1;
    });
  }
}
