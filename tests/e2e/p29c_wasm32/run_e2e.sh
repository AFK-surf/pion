#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if ! command -v node >/dev/null 2>&1; then
  echo "NOTE: node not found; skipping p29c_wasm32 E2E"
  exit 0
fi

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"
export PION_WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"

echo "=== P29-C [1/5] pionc build --target wasm32 + WebAssembly.validate() ==="
HELLO_WASM="$TMP_DIR/hello.wasm"
T0=$(now_ms)
"$PIONC" build --target wasm32 -o "$HELLO_WASM" "$ROOT_DIR/tests/e2e/hello.pion"
T1=$(now_ms)
HELLO_BYTES=$(wc -c < "$HELLO_WASM" | tr -d ' ')
node -e '
const fs = require("node:fs");
const bytes = fs.readFileSync(process.argv[1]);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL: WebAssembly.validate() returned false");
  process.exit(1);
}
console.log("  WebAssembly.validate(hello.wasm): OK (" + bytes.length + " bytes)");
' "$HELLO_WASM"
echo "  hello.wasm: compile=$((T1 - T0))ms size=${HELLO_BYTES}B"

echo "=== P29-C [2/5] pionc run --target wasm32 hello.pion ==="
HELLO_OUT=$("$PIONC" run --target wasm32 "$ROOT_DIR/tests/e2e/hello.pion")
echo "  hello (wasm32) -> $HELLO_OUT"
if [ "$HELLO_OUT" != "hello pion" ]; then
  echo "FAIL: hello.pion wasm32 output mismatch: '$HELLO_OUT'" >&2
  exit 1
fi

echo "=== P29-C [3/5] pionc run --target wasm32 p27a_ergonomics_bug4.pion ==="
T0=$(now_ms)
P27A_WASM="$TMP_DIR/p27a.wasm"
"$PIONC" build --target wasm32 -o "$P27A_WASM" "$ROOT_DIR/tests/e2e/p27a_ergonomics_bug4.pion"
T1=$(now_ms)
P27A_OUT=$(node "$PION_WASM_RT" "$P27A_WASM")
T2=$(now_ms)
P27A_BYTES=$(wc -c < "$P27A_WASM" | tr -d ' ')
echo "  p27a (wasm32): compile=$((T1 - T0))ms run=$((T2 - T1))ms size=${P27A_BYTES}B out='$P27A_OUT'"
if [ "$P27A_OUT" != "p27a_ergonomics_bug4 ok" ]; then
  echo "FAIL: p27a_ergonomics_bug4 wasm32 output mismatch: '$P27A_OUT'" >&2
  exit 1
fi

echo "=== P29-C [4/5] Float + UInt/UInt64 + FixedArray + Map[Int/String, String] + #derive(Eq) + Generic Closure ==="
cat > "$TMP_DIR/full_features.pion" <<'EOF'
#derive(Eq)
struct Pixel {
  r : Float
  g : Float
  rgba : UInt
  tag : UInt64
}

fn make_adder[T](x : T, bonus : Int) -> (Int) -> Int {
  fn(v : Int) -> Int {
    let _keep = x
    v + bonus
  }
}

pub fn main(world : World) -> Int {
  // Float (f32)
  let a : Float = 1.5f
  let b : Float = 2.5f
  debug_assert(a + b == 4.0f, "f32 add")
  debug_assert((b - a) * 3.0f == 3.0f, "f32 sub mul")
  debug_assert(-a == -1.5f, "f32 neg")
  debug_assert((9.0f).sqrt() == 3.0f, "f32 sqrt")
  debug_assert((1.5f).to_bits() == 0x3FC00000, "f32 to_bits")
  debug_assert(Float::from_bits(0x3FC00000) == 1.5f, "f32 from_bits")
  debug_assert((1.5f).to_string() == "1.5", "f32 to_string")

  // UInt & UInt64
  let umax : UInt = 0xFFFF_FFFFU
  let uhi : UInt = 0x8000_0000U
  debug_assert(umax > uhi && uhi > 1U, "u32 cmp")
  debug_assert(umax / 2U == 0x7FFF_FFFFU, "u32 udiv")
  debug_assert(umax % 10U == 5U, "u32 urem")
  debug_assert(uhi >> 1 == 0x4000_0000U, "u32 shr")
  debug_assert(umax.to_string() == "4294967295", "u32 to_string")

  let u64max : UInt64 = 0xFFFF_FFFF_FFFF_FFFFUL
  let u64hi : UInt64 = 0x8000_0000_0000_0000UL
  debug_assert(u64max > u64hi && u64hi > 1UL, "u64 cmp")
  debug_assert(u64max / 2UL == 0x7FFF_FFFF_FFFF_FFFFUL, "u64 udiv")
  debug_assert(u64max % 10UL == 5UL, "u64 urem")
  debug_assert(u64hi >> 1 == 0x4000_0000_0000_0000UL, "u64 shr")
  debug_assert(u64max.to_string() == "18446744073709551615", "u64 to_string")

  // FixedArray
  let fa : FixedArray[Int] = FixedArray::make(5, 10)
  fa[2] = 99
  debug_assert(fa.length() == 5 && fa[0] == 10 && fa[2] == 99, "FixedArray")
  fa.fill(7)
  debug_assert(fa[4] == 7, "FixedArray::fill")

  // Map[Int, String] & Map[String, String]
  let mi : Map[Int, String] = Map::new()
  mi.set(0, "zero")
  mi.set(42, "answer")
  debug_assert(mi.length() == 2, "Map[Int, String] len")
  match mi.get(42) {
    Some(v) => debug_assert(v == "answer", "Map[Int, String] get")
    None => debug_assert(false, "Map[Int, String] missing")
  }
  let ms : Map[String, String] = Map::new()
  ms.set("lang", "pion")
  ms.set("target", "wasm32")
  debug_assert(ms.contains("target"), "Map[String, String] contains")
  ms.remove("lang")
  debug_assert(ms.length() == 1 && !ms.contains("lang"), "Map[String, String] remove")

  // #derive(Eq)
  let p1 = Pixel::{ r: 1.5f, g: 2.5f, rgba: 0x11223344U, tag: 99UL }
  let p2 = Pixel::{ r: 1.5f, g: 2.5f, rgba: 0x11223344U, tag: 99UL }
  let p3 = Pixel::{ r: 1.5f, g: 3.5f, rgba: 0x11223344U, tag: 99UL }
  debug_assert(p1 == p2 && p1 != p3, "derive Eq")

  // Generic closures (value & object captures)
  let f1 = make_adder(100, 5)
  let f2 = make_adder("captured-str", 7)
  debug_assert(f1(10) + f2(20) == 42, "generic closures")

  io_println(world, "p29c_full_features ok")
  0
}
EOF

T0=$(now_ms)
FULL_WASM="$TMP_DIR/full_features.wasm"
"$PIONC" build --target wasm32 -o "$FULL_WASM" "$TMP_DIR/full_features.pion"
T1=$(now_ms)
FULL_OUT=$(node "$PION_WASM_RT" "$FULL_WASM")
T2=$(now_ms)
FULL_BYTES=$(wc -c < "$FULL_WASM" | tr -d ' ')
echo "  full_features (wasm32): compile=$((T1 - T0))ms run=$((T2 - T1))ms size=${FULL_BYTES}B out='$FULL_OUT'"
if [ "$FULL_OUT" != "p29c_full_features ok" ]; then
  echo "FAIL: full_features wasm32 output mismatch: '$FULL_OUT'" >&2
  exit 1
fi

echo "=== P29-C [5/5] 4 V1 Benchmarks Checksum Verification (Wasm32 in Node.js) ==="
verify_wasm_bench() {
  name="$1"
  expected="$2"
  wasm_out="$TMP_DIR/${name}.wasm"
  tb0=$(now_ms)
  "$PIONC" build --release --target wasm32 -o "$wasm_out" "$ROOT_DIR/benchmarks/pion/${name}.pion"
  tb1=$(now_ms)
  got=$(node "$PION_WASM_RT" "$wasm_out")
  tb2=$(now_ms)
  sz=$(wc -c < "$wasm_out" | tr -d ' ')
  echo "  WASM32 ${name}: compile=$((tb1 - tb0))ms run=$((tb2 - tb1))ms size=${sz}B out='${got}'"
  if [ "$got" != "$expected" ]; then
    echo "FAIL: wasm32 ${name} checksum mismatch! expected='${expected}' got='${got}'" >&2
    exit 1
  fi
}

verify_wasm_bench nbody "-0.169075164 -0.169083134"
verify_wasm_bench binarytrees "stretch=262143 long=131071 total=14592688"
verify_wasm_bench fannkuchredux "73196 38"
verify_wasm_bench hashmap_str "200000 208681440 205599 815496841"

echo "=== P29-C [6/6] Multi-Package Closure call_indirect Isolation Regression ==="
MP_DIR="$TMP_DIR/mp_clo"
mkdir -p "$MP_DIR/pkg_a/src" "$MP_DIR/pkg_b/src" "$MP_DIR/app/src"
cat > "$MP_DIR/pkg_a/pion.toml" <<'EOF'
[package]
name = "pkg_a"
version = "0.1.0"
EOF
cat > "$MP_DIR/pkg_a/src/lib.pion" <<'EOF'
pub fn make_unary(k : Int) -> (Int) -> Int {
  fn(x : Int) -> Int { x + k }
}
pub fn label() -> String { "pkg_a_ok" }
EOF
cat > "$MP_DIR/pkg_b/pion.toml" <<'EOF'
[package]
name = "pkg_b"
version = "0.1.0"
EOF
cat > "$MP_DIR/pkg_b/src/lib.pion" <<'EOF'
pub fn make_binary(scale : Int) -> (Int, Int) -> Int {
  fn(a : Int, b : Int) -> Int { (a + b) * scale }
}
pub fn label() -> String { "pkg_b_ok" }
EOF
cat > "$MP_DIR/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
pkg_a = { path = "../pkg_a" }
pkg_b = { path = "../pkg_b" }
EOF
cat > "$MP_DIR/app/src/main.pion" <<'EOF'
import "pkg_a"
import "pkg_b"

pub fn main(world : World) -> Int {
  let f1 = pkg_a::make_unary(10)
  let f2 = pkg_b::make_binary(3)
  let r = f1(5) + f2(4, 5)
  io_println(world, pkg_a::label() + ":" + pkg_b::label() + ":" + r.to_string())
  0
}
EOF
MP_WASM="$TMP_DIR/mp_clo.wasm"
"$PIONC" build --release --target wasm32 -o "$MP_WASM" "$MP_DIR/app"
MP_OUT=$(node "$PION_WASM_RT" "$MP_WASM")
echo "  mp_clo (wasm32) -> '$MP_OUT'"
if [ "$MP_OUT" != "pkg_a_ok:pkg_b_ok:42" ]; then
  echo "FAIL: mp_clo wasm32 output mismatch: '$MP_OUT'" >&2
  exit 1
fi
# Verify zero leaked internal exports (no pion_pkg_* / pion_drop_* / pion_clo_* in export section)
# and verify auto wasm-opt -Oz shrinks --release output when wasm-opt is on PATH
MP_RAW="$TMP_DIR/mp_clo_noopt.wasm"
PION_NO_WASM_OPT=1 "$PIONC" build --release --target wasm32 -o "$MP_RAW" "$MP_DIR/app"
node -e '
const fs = require("node:fs");
const optBytes = fs.readFileSync(process.argv[1]);
const rawBytes = fs.readFileSync(process.argv[2]);
const hasWopt = process.argv[3] === "1";
const mod = new WebAssembly.Module(optBytes);
const exps = WebAssembly.Module.exports(mod).filter(e => e.kind === "function").map(e => e.name);
const leaked = exps.filter(n => n.startsWith("pion_pkg_") || n.startsWith("pion_drop_") || n.startsWith("pion_clo_") || n.startsWith("pion_init_"));
if (leaked.length > 0) {
  console.error("FAIL: leaked internal exports:", leaked);
  process.exit(1);
}
if (hasWopt && optBytes.length >= rawBytes.length) {
  console.error("FAIL: expected auto wasm-opt -Oz to shrink mp_clo:", optBytes.length, ">=", rawBytes.length);
  process.exit(1);
}
console.log("  mp_clo export check OK:", exps, "raw=" + rawBytes.length + "B opt=" + optBytes.length + "B");
' "$MP_WASM" "$MP_RAW" "$(command -v wasm-opt >/dev/null 2>&1 && echo 1 || echo 0)"

echo "=== P29-C [7/7] Large-Block Recycling (> 2048B) & Double-Free Guard Regression ==="
cat > "$TMP_DIR/large_recycle.pion" <<'EOF'
pub fn main(world : World) -> Int {
  let mut sum : Double = 0.0
  let mut i = 0
  while i < 4000 {
    let a : Array[Double] = Array::make(512, 1.5)
    sum = sum + a[0] + a[511]
    i = i + 1
  }
  let mut j = 0
  while j < 500 {
    let b : Array[Double] = Array::make(8192, 2.5)
    sum = sum + b[0] + b[8191]
    j = j + 1
  }
  let mut k = 0
  while k < 50 {
    let c : Array[Double] = Array::make(65536, 3.5)
    sum = sum + c[0] + c[65535]
    k = k + 1
  }
  io_println(world, sum.to_string())
  0
}
EOF
LARGE_WASM="$TMP_DIR/large_recycle.wasm"
"$PIONC" build --release --target wasm32 -o "$LARGE_WASM" "$TMP_DIR/large_recycle.pion"
PION_WASM_RT_WEB="$ROOT_DIR/runtime/pion_wasm_rt_web.mjs"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const outLines = [];
const rt = createPionRuntime({
  print: (s) => outLines.push(s),
  println: (s) => outLines.push(s + "\n"),
});
const bytes = fs.readFileSync(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
if ((rc | 0) !== 0) {
  console.error("FAIL (" + rtLabel + "): large_recycle exited with", rc);
  process.exit(1);
}
const out = outLines.join("").trim();
if (out !== "14850") {
  console.error("FAIL (" + rtLabel + "): large_recycle checksum mismatch: expected 14850, got", JSON.stringify(out));
  process.exit(1);
}
const memBytes = instance.exports.memory.buffer.byteLength;
const limitBytes = 16 * 1024 * 1024;
if (memBytes > limitBytes) {
  console.error("FAIL (" + rtLabel + "): large_recycle linear memory grew too large:", memBytes, ">", limitBytes);
  process.exit(1);
}

// Verify double-free guard does not duplicate free-list entries or corrupt subsequent reuse
const { pion_ptr_alloc, pion_ptr_free } = rt.imports.pion_rt;
const p1 = pion_ptr_alloc(4096n);
const p2 = pion_ptr_alloc(4096n);
pion_ptr_free(p1);
pion_ptr_free(p1); // double-free of free-listed block
const q1 = pion_ptr_alloc(4096n);
const q2 = pion_ptr_alloc(4096n);
if (q1 !== p1) {
  console.error("FAIL (" + rtLabel + "): expected q1 to reuse p1:", q1, "!==", p1);
  process.exit(1);
}
if (q2 === q1) {
  console.error("FAIL (" + rtLabel + "): double-free duplicated p1 in free-list:", q1, "===", q2);
  process.exit(1);
}
// Also double-free a heap-top LIFO block and confirm clean subsequent alloc
pion_ptr_free(q2);
pion_ptr_free(q2);
const q3 = pion_ptr_alloc(4096n);
if (q3 !== q2) {
  console.error("FAIL (" + rtLabel + "): expected q3 to reuse LIFO-shrunk q2:", q3, "!==", q2);
  process.exit(1);
}
pion_ptr_free(q3);
pion_ptr_free(q1);
pion_ptr_free(p2);

console.log("  large_recycle (" + rtLabel + "): out=" + out + " mem=" + (memBytes / (1024 * 1024)).toFixed(2) + "MiB (<=16MiB) double-free=OK");
' "$LARGE_WASM" "$rt_path"
done

echo "=== P29-C [8/8] Map/Array Read Zero RC Leak Regression (Node + Web Runtimes) ==="
cat > "$TMP_DIR/rc_read_leak.pion" <<'EOF'
struct Box {
  payload : Array[Int]
}

pub fn main(world : World) -> Int {
  let mut checksum : Int = 0
  let mut r = 0
  while r < 200 {
    let ms : Map[String, Box] = Map::new()
    let mi : Map[Int, Box] = Map::new()
    let arr : Array[Box] = Array::new()
    let mut i = 0
    while i < 16 {
      let key = "k" + i.to_string()
      ms.set(key, Box::{ payload: Array::make(512, r + i) })
      mi.set(i, Box::{ payload: Array::make(512, r + i + 1) })
      arr.push(Box::{ payload: Array::make(512, r + i + 2) })
      i = i + 1
    }
    let mut j = 0
    while j < 16 {
      let key = "k" + j.to_string()
      match ms.get(key) {
        Some(b) => { checksum = checksum + b.payload[0] }
        None => { checksum = checksum - 1000000 }
      }
      let bs = ms[key]
      checksum = checksum + bs.payload[511]
      match mi.get(j) {
        Some(b) => { checksum = checksum + b.payload[0] }
        None => { checksum = checksum - 1000000 }
      }
      let bi = mi[j]
      checksum = checksum + bi.payload[511]
      let ba = arr[j]
      checksum = checksum + ba.payload[0] + ba.payload[511]
      j = j + 1
    }
    ms.clear()
    mi.clear()
    arr.clear()
    r = r + 1
  }
  io_println(world, checksum.to_string())
  0
}
EOF
RC_LEAK_WASM="$TMP_DIR/rc_read_leak.wasm"
"$PIONC" build --release --target wasm32 -o "$RC_LEAK_WASM" "$TMP_DIR/rc_read_leak.pion"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const outLines = [];
const rt = createPionRuntime({
  print: (s) => outLines.push(s),
  println: (s) => outLines.push(s + "\n"),
});

let allocStructs = 0;
let freedStructs = 0;
let memRef = null;
const prt = rt.imports.pion_rt;
const origAlloc = prt.pion_alloc;
const origAllocUninit = prt.pion_alloc_uninit;
const origRcDecSlow = prt.pion_rc_dec_slow;

prt.pion_alloc = (sz, tag, dropFn) => {
  if ((tag & 0xffff) === 4) allocStructs++;
  return origAlloc(sz, tag, dropFn);
};
prt.pion_alloc_uninit = (sz, tag, dropFn) => {
  if ((tag & 0xffff) === 4) allocStructs++;
  return origAllocUninit(sz, tag, dropFn);
};
prt.pion_rc_dec_slow = (obj) => {
  const p = Number(obj);
  if (p !== 0 && memRef) {
    const tag = new DataView(memRef.buffer).getUint16(p - 24 + 12, true);
    if (tag === 4) freedStructs++;
  }
  return origRcDecSlow(obj);
};

const bytes = fs.readFileSync(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);
memRef = instance.exports.memory;

const rc = instance.exports.main(0, 0n);
if ((rc | 0) !== 0) {
  console.error("FAIL (" + rtLabel + "): rc_read_leak exited with", rc);
  process.exit(1);
}
const out = outLines.join("").trim();
if (out !== "2073600") {
  console.error("FAIL (" + rtLabel + "): rc_read_leak checksum mismatch: expected 2073600, got", JSON.stringify(out));
  process.exit(1);
}
const memBytes = memRef.buffer.byteLength;
const limitBytes = 16 * 1024 * 1024;
if (memBytes > limitBytes) {
  console.error("FAIL (" + rtLabel + "): rc_read_leak linear memory grew too large:", memBytes, ">", limitBytes);
  process.exit(1);
}
// Verify ZERO live TAG_STRUCT blocks remain in linear memory (pure-Wasm pion_arr_clear frees directly via slab without JS pion_rc_dec_slow)
const expectedStructs = 200 * 16 * 3;
if (!instance.exports.__pion_slab_ctl && freedStructs !== expectedStructs) {
  console.error("FAIL (" + rtLabel + "): expected freedStructs=" + expectedStructs + ", got " + freedStructs + " (jsAlloc=" + allocStructs + ")");
  process.exit(1);
}
let liveStructs = 0;
if (instance.exports.__pion_slab_ctl) {
  const dv = new DataView(memRef.buffer);
  const ctl = instance.exports.__pion_slab_ctl.value;
  const hp = dv.getUint32(ctl + 36, true);
  const hb = dv.getUint32(ctl + 44, true);
  for (let b = hb; b < hp; ) {
    const asz = dv.getUint32(b, true);
    const mg = dv.getUint32(b + 4, true);
    if (asz < 16 || b + asz > hp) {
      console.error("FAIL (" + rtLabel + "): corrupt heap block at " + b + " asz=" + asz + " hp=" + hp);
      process.exit(1);
    }
    if (mg === 0x50494f4e && dv.getUint16(b + 8 + 12, true) === 4) {
      liveStructs++;
    }
    b += asz;
  }
} else {
  liveStructs = allocStructs - freedStructs;
}
if (liveStructs !== 0) {
  console.error("FAIL (" + rtLabel + "): TAG_STRUCT RC leak detected: jsAlloc=" + allocStructs + " freed=" + freedStructs + " live=" + liveStructs);
  process.exit(1);
}

// Direct pion_arr_get check: must NOT increment element local_rc
const arrPtr = prt.pion_arr_new(1n, 1);
const elemPtr = origAlloc(16, 4, 0n);
prt.pion_arr_push(arrPtr, elemPtr);
const rcBefore = new DataView(memRef.buffer).getUint32(Number(elemPtr) - 24 + 4, true);
const gotPtr = prt.pion_arr_get(arrPtr, 0n);
const rcAfter = new DataView(memRef.buffer).getUint32(Number(elemPtr) - 24 + 4, true);
if (gotPtr !== elemPtr) {
  console.error("FAIL (" + rtLabel + "): pion_arr_get returned wrong ptr:", gotPtr, "!==", elemPtr);
  process.exit(1);
}
if (rcAfter !== rcBefore) {
  console.error("FAIL (" + rtLabel + "): pion_arr_get mutated element local_rc:", rcBefore, "->", rcAfter);
  process.exit(1);
}
prt.pion_rc_dec(elemPtr);
prt.pion_rc_dec(arrPtr);

console.log("  rc_read_leak (" + rtLabel + "): out=" + out + " mem=" + (memBytes / (1024 * 1024)).toFixed(2) + "MiB (<=16MiB) freedStructs=" + freedStructs + " liveStructs=" + liveStructs + " jsAlloc=" + allocStructs + " arr_get_rc=" + rcBefore + "->" + rcAfter + " OK");
' "$RC_LEAK_WASM" "$rt_path"
done

echo "=== P29-C [9/9] Library-Mode (No main, extern \"C\" exports) Export Hygiene & Built-in DCE Regression ==="
WL_DIR="$TMP_DIR/web_lib"
mkdir -p "$WL_DIR/lib_pkg/src" "$WL_DIR/web_app/src"
cat > "$WL_DIR/lib_pkg/pion.toml" <<'EOF'
[package]
name = "lib_pkg"
version = "0.1.0"
EOF
cat > "$WL_DIR/lib_pkg/src/lib.pion" <<'EOF'
pub fn live_calc(x : Int) -> Int {
  x * 3 + 7
}

pub fn dead_leaf(n : Int) -> String {
  let s = "P33A_DEAD_SENTINEL_STRING_DO_NOT_EMIT"
  s + ":" + n.to_string()
}

pub fn dead_big_helper(x : Int) -> String {
  let mut acc = dead_leaf(x)
  let mut i = 0
  while i < 8 {
    acc = acc + "|" + dead_leaf(x + i)
    i = i + 1
  }
  acc
}
EOF
cat > "$WL_DIR/web_app/pion.toml" <<'EOF'
[package]
name = "web_app"
version = "0.1.0"

[dependencies]
lib_pkg = { path = "../lib_pkg" }
EOF
cat > "$WL_DIR/web_app/src/main.pion" <<'EOF'
import "lib_pkg"

pub extern "C" fn web_calc(x : Int) -> Int {
  lib_pkg::live_calc(x)
}

pub extern "C" fn web_tag() -> Int {
  3301
}
EOF
WL_RAW="$TMP_DIR/web_app_raw.wasm"
WL_OPT="$TMP_DIR/web_app_opt.wasm"
PION_NO_WASM_OPT=1 "$PIONC" build --release --target wasm32 -o "$WL_RAW" "$WL_DIR/web_app"
"$PIONC" build --release --target wasm32 -o "$WL_OPT" "$WL_DIR/web_app"
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const rawPath = process.argv[1];
const optPath = process.argv[2];
const rtPaths = [process.argv[3], process.argv[4]];

const rawBytes = fs.readFileSync(rawPath);
const optBytes = fs.readFileSync(optPath);
if (!WebAssembly.validate(rawBytes)) {
  console.error("FAIL: web_app raw.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const mod = new WebAssembly.Module(rawBytes);
const fnExports = WebAssembly.Module.exports(mod)
  .filter(e => e.kind === "function")
  .map(e => e.name)
  .sort();
const expected = ["web_calc", "web_tag"];
if (JSON.stringify(fnExports) !== JSON.stringify(expected)) {
  console.error("FAIL: web_app raw.wasm function exports mismatch! expected=" + JSON.stringify(expected) + " got=" + JSON.stringify(fnExports));
  process.exit(1);
}
const sentinel = Buffer.from("P33A_DEAD_SENTINEL_STRING_DO_NOT_EMIT", "utf8");
if (rawBytes.includes(sentinel)) {
  console.error("FAIL: dead sentinel string survived in raw.wasm (built-in DCE failed for no-main library)");
  process.exit(1);
}

for (const rtPath of rtPaths) {
  const rtLabel = path.basename(rtPath);
  const { createPionRuntime } = await import(pathToFileURL(rtPath).href);
  const rt = createPionRuntime({});
  const { instance } = await WebAssembly.instantiate(rawBytes, rt.imports);
  rt.bindExports(instance.exports);
  const c = instance.exports.web_calc(20);
  const t = instance.exports.web_tag();
  if ((c | 0) !== 67 || (t | 0) !== 3301) {
    console.error("FAIL (" + rtLabel + "): web_app return mismatch: web_calc(20)=" + c + " web_tag()=" + t);
    process.exit(1);
  }
}
console.log("  web_app (no-main library): exports=" + JSON.stringify(fnExports) + " dead_sentinel=ELIMINATED raw=" + rawBytes.length + "B opt=" + optBytes.length + "B (Node+Web OK)");
' "$WL_RAW" "$WL_OPT" "$PION_WASM_RT" "$PION_WASM_RT_WEB"

echo "=== P29-C [10/10] mem2reg Stack-Slot Promotion + Dead Zero-Init + Const Copy Inlining Regression ==="
cat > "$TMP_DIR/mem2reg_pure.pion" <<'EOF'
pub extern "C" fn clamp_u8(x : Double) -> Int {
  let mut v = x * 255.0 + 0.5
  if v < 0.0 {
    v = 0.0
  } else if v > 255.0 {
    v = 255.0
  }
  v.to_int()
}

pub extern "C" fn signed_loop(n : Int, seed : Int) -> Int64 {
  let mut acc : Int64 = 0L
  let mut i = 0
  let mut neg = -seed
  while i < n {
    let step : Int = if i % 2 == 0 { neg + i } else { i * 3 - 7 }
    acc = acc + step.to_int64()
    neg = neg + 1
    i = i + 1
  }
  acc
}
EOF
M2R_PURE_RAW="$TMP_DIR/mem2reg_pure_raw.wasm"
PION_NO_WASM_OPT=1 "$PIONC" build --release --target wasm32 -o "$M2R_PURE_RAW" "$TMP_DIR/mem2reg_pure.pion"

cat > "$TMP_DIR/mem2reg_mix.pion" <<'EOF'
struct Pair {
  a : Int
  b : Float
}

fn make_mul(k : Int) -> (Int) -> Int {
  let bias = k * 2
  fn(x : Int) -> Int { x * k + bias }
}

pub fn main(world : World) -> Int {
  // 1. Float local (storel + loads mixed-type slot -> safely stays on shadow stack)
  let mut f : Float = 1.25f
  let mut i = 0
  while i < 4 {
    f = f + 0.5f
    i = i + 1
  }
  // f = 3.25f -> to_bits = 0x40500000
  let fbits = f.to_bits()

  // 2. Signed Int -> Int64 extension + loop mutation of promoted locals
  let mut acc : Int64 = 0L
  let mut j = -5
  while j < 5 {
    let v : Int = j * 3 - 2
    acc = acc + v.to_int64()
    j = j + 1
  }
  // sum_{j=-5..4} (3*j - 2) = 3*(-5) - 20 = -35

  // 3. Struct + Array + Closure mixed with promoted locals
  let arr : Array[Pair] = Array::new()
  arr.push(Pair::{ a: 10, b: f })
  arr.push(Pair::{ a: 20, b: 2.5f })
  let mul = make_mul(3)
  let total = mul(arr[0].a) + arr[1].a + (arr[0].b + arr[1].b).to_int()
  // mul(10)=36, +20=56, +(3.25+2.5=5.75).to_int()=5 => 61

  io_println(world, fbits.to_string() + ":" + acc.to_string() + ":" + total.to_string())
  0
}
EOF
M2R_MIX_RAW="$TMP_DIR/mem2reg_mix_raw.wasm"
PION_NO_WASM_OPT=1 "$PIONC" build --release --target wasm32 -o "$M2R_MIX_RAW" "$TMP_DIR/mem2reg_mix.pion"

node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const purePath = process.argv[1];
const mixPath = process.argv[2];
const rtPaths = [process.argv[3], process.argv[4]];

const pureBytes = fs.readFileSync(purePath);
const mixBytes = fs.readFileSync(mixPath);
if (!WebAssembly.validate(pureBytes)) {
  console.error("FAIL: mem2reg_pure_raw.wasm failed WebAssembly.validate()");
  process.exit(1);
}
if (!WebAssembly.validate(mixBytes)) {
  console.error("FAIL: mem2reg_mix_raw.wasm failed WebAssembly.validate()");
  process.exit(1);
}

// Parse Code Section (id=10) of pureBytes and assert ZERO shadow-stack prologue `global.get 0` (0x23 0x00)
let off = 8;
let codeSec = null;
while (off < pureBytes.length) {
  const id = pureBytes[off++];
  let sz = 0, shift = 0;
  while (true) {
    const b = pureBytes[off++];
    sz |= (b & 0x7f) << shift;
    if ((b & 0x80) === 0) break;
    shift += 7;
  }
  if (id === 10) {
    codeSec = pureBytes.subarray(off, off + sz);
    break;
  }
  off += sz;
}
if (!codeSec) {
  console.error("FAIL: Code section not found in mem2reg_pure_raw.wasm");
  process.exit(1);
}
const hasGlobalGet0 = codeSec.includes(Buffer.from([0x23, 0x00]));
if (hasGlobalGet0) {
  console.error("FAIL: mem2reg_pure_raw.wasm still emits shadow-stack global.get 0 (0x23 0x00)!");
  process.exit(1);
}

for (const rtPath of rtPaths) {
  const rtLabel = path.basename(rtPath);
  const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

  // Test pure promoted module
  const rt1 = createPionRuntime({});
  const { instance: inst1 } = await WebAssembly.instantiate(pureBytes, rt1.imports);
  rt1.bindExports(inst1.exports);
  const c0 = inst1.exports.clamp_u8(-0.2);
  const c1 = inst1.exports.clamp_u8(0.5);
  const c2 = inst1.exports.clamp_u8(1.5);
  const sl = inst1.exports.signed_loop(10, 5);
  // i=0,2,4,6,8: neg=-5,-3,-1,1,3 -> neg+i = -5,-1,3,7,11 -> sum=15
  // i=1,3,5,7,9: i*3-7 = -4,2,8,14,20 -> sum=40 => total=55n
  if ((c0 | 0) !== 0 || (c1 | 0) !== 128 || (c2 | 0) !== 255 || sl !== 55n) {
    console.error("FAIL (" + rtLabel + "): mem2reg_pure mismatch:", { c0, c1, c2, sl });
    process.exit(1);
  }

  // Test mixed Float + signed Int64 + Struct/Array/Closure module
  const lines = [];
  const rt2 = createPionRuntime({
    print: (s) => lines.push(s),
    println: (s) => lines.push(s + "\n"),
  });
  const { instance: inst2 } = await WebAssembly.instantiate(mixBytes, rt2.imports);
  rt2.bindExports(inst2.exports);
  const rc = inst2.exports.main(0, 0n);
  const out = lines.join("").trim();
  if ((rc | 0) !== 0 || out !== "1078984704:-35:61") {
    console.error("FAIL (" + rtLabel + "): mem2reg_mix mismatch: rc=" + rc + " out=" + JSON.stringify(out));
    process.exit(1);
  }
}
console.log("  mem2reg (pure+mix): zero_shadow_stack=OK pure_raw=" + pureBytes.length + "B mix_raw=" + mixBytes.length + "B (Node+Web OK)");
' "$M2R_PURE_RAW" "$M2R_MIX_RAW" "$PION_WASM_RT" "$PION_WASM_RT_WEB"

echo "=== P29-C [11/11] Pure-Wasm In-Memory Slab (<=512B) + Mixed Wasm/JS Alloc-Free & Tree Recycling ==="
cat > "$TMP_DIR/slab_mix.pion" <<'EOF'
enum Tree {
  Leaf
  Node(Tree, Tree)
}

fn make_tree(d : Int) -> Tree {
  if d == 0 {
    Tree::Leaf
  } else {
    Tree::Node(make_tree(d - 1), make_tree(d - 1))
  }
}

fn check_tree(t : Tree) -> Int {
  match t {
    Tree::Leaf => 1
    Tree::Node(l, r) => 1 + check_tree(l) + check_tree(r)
  }
}

pub fn main(world : World) -> Int {
  let mut total = 0
  let mut i = 0
  while i < 80 {
    let t = make_tree(10)
    total = total + check_tree(t)
    // Mix Wasm-allocated structs/closures with JS-allocated strings & maps
    let s = "iter:" + i.to_string()
    if i % 10 == 0 {
      total = total + s.length()
    }
    i = i + 1
  }
  io_println(world, total.to_string())
  0
}
EOF
SLAB_WASM="$TMP_DIR/slab_mix.wasm"
"$PIONC" build --release --target wasm32 -o "$SLAB_WASM" "$TMP_DIR/slab_mix.pion"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + rtLabel + "): slab_mix.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

if (!instance.exports.__pion_slab_ctl) {
  console.error("FAIL (" + rtLabel + "): missing __pion_slab_ctl export");
  process.exit(1);
}

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
// 80 * (2^11 - 1 = 2047) = 163760; i=0 -> len("iter:0")=6, i=10..70 (7 times) -> len=7 => 6+49=55 => 163815
if ((rc | 0) !== 0 || out !== "163815") {
  console.error("FAIL (" + rtLabel + "): slab_mix mismatch: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const memBytes = instance.exports.memory.buffer.byteLength;
const limitBytes = 4 * 1024 * 1024;
if (memBytes > limitBytes) {
  console.error("FAIL (" + rtLabel + "): slab_mix linear memory leaked:", memBytes, ">", limitBytes);
  process.exit(1);
}

// Cross-boundary check: JS pion_alloc_uninit + pion_rc_dec on small slab classes
const { pion_alloc_uninit, pion_rc_dec } = rt.imports.pion_rt;
const p1 = pion_alloc_uninit(16, 4, 0n);
const p2 = pion_alloc_uninit(16, 4, 0n);
pion_rc_dec(p1);
const p3 = pion_alloc_uninit(16, 4, 0n);
if (p3 !== p1) {
  console.error("FAIL (" + rtLabel + "): expected slab freelist reuse p3 === p1:", p3, "!==", p1);
  process.exit(1);
}
pion_rc_dec(p3);
pion_rc_dec(p2);

console.log("  slab_mix (" + rtLabel + "): out=" + out + " mem=" + (memBytes / (1024 * 1024)).toFixed(2) + "MiB (<=4MiB) slab_reuse=OK");
' "$SLAB_WASM" "$rt_path"
done

echo "=== P29-C [12/12] Pure-Wasm String & HashMap Hot Paths (INT64_MIN, str_eq, concat_n, Map grow + RC) ==="
cat > "$TMP_DIR/str_map_fast.pion" <<'EOF'
fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

pub fn main(world : World) -> Int {
  // 1. pion_int_to_str: 0, positive, negative, INT64_MIN, INT64_MAX
  let i64_min : Int64 = -9223372036854775807L - 1L
  let i64_max : Int64 = 9223372036854775807L
  must((0L).to_string() == "0", "0L")
  must((-1L).to_string() == "-1", "-1L")
  must((42L).to_string() == "42", "42L")
  must(i64_min.to_string() == "-9223372036854775808", "INT64_MIN")
  must(i64_max.to_string() == "9223372036854775807", "INT64_MAX")

  // 2. pion_str_eq: empty, short, 8B-aligned, long, mismatch
  must("" == "", "empty eq")
  must(("" + "x") == "x", "empty concat eq")
  must("a" != "b", "short ne")
  must("12345678" == "12345678", "8B eq")
  must("12345678" != "12345679", "8B ne")
  must("abcdefghijklmnop123" == "abcdefghijklmnop123", "long eq")
  must("abcdefghijklmnop123" != "abcdefghijklmnop124", "long tail ne")

  // 3. pion_str_concat + pion_str_concat_n
  let c2 = "hello" + "_world"
  let c4 = "k_" + (123).to_string() + "_" + (-45).to_string()
  must(c2 == "hello_world", "concat2")
  must(c4 == "k_123_-45", "concat4")

  // 4. Map[String, Int] across multiple mapGrow resizes
  let msi : Map[String, Int] = Map::new()
  let mut i = 0
  while i < 400 {
    let k = "key_" + i.to_string() + "_" + (i * 7).to_string()
    msi.set(k, i * 3 + 1)
    i = i + 1
  }
  // Overwrite subset
  let mut j = 0
  while j < 100 {
    let k = "key_" + j.to_string() + "_" + (j * 7).to_string()
    msi.set(k, j * 5 + 2)
    j = j + 1
  }
  let mut sum_si = 0
  let mut q = 0
  while q < 400 {
    let k = "key_" + q.to_string() + "_" + (q * 7).to_string()
    must(msi.contains(k), "msi contains")
    match msi.get(k) {
      Some(v) => { sum_si = sum_si + v }
      None => { must(false, "msi missing") }
    }
    must(!msi.contains("nope_" + q.to_string()), "msi miss")
    q = q + 1
  }
  msi.remove("key_10_70")
  must(!msi.contains("key_10_70") && msi.length() == 399, "msi remove")

  // 5. Map[String, String] (val_is_obj=1) with repeated overwrites, self-assignment + clear (RC leak check)
  let mss : Map[String, String] = Map::new()
  mss.set("a", "self_" + (99).to_string())
  match mss.get("a") {
    Some(same_v) => { mss.set("a", same_v) }
    None => { must(false, "mss self missing") }
  }
  must(mss["a"] == "self_99", "mss self-assign")
  mss.remove("a")
  let mut r = 0
  while r < 200 {
    let k = "s_" + (r % 32).to_string()
    let v = "val_" + r.to_string() + "_" + (r * 13).to_string()
    mss.set(k, v)
    r = r + 1
  }
  must(mss.length() == 32, "mss len")
  must(mss["s_0"] == "val_192_2496", "mss overwrite")
  mss.clear()

  // 6. Map[Int, String] (key_is_int=1) across mapGrow + negative keys + remove
  let mis : Map[Int, String] = Map::new()
  let mut t = -150
  while t < 150 {
    mis.set(t, "n" + t.to_string())
    t = t + 1
  }
  must(mis.length() == 300, "mis len")
  must(mis[-150] == "n-150" && mis[0] == "n0" && mis[149] == "n149", "mis get")
  mis.remove(0)
  must(!mis.contains(0) && mis.length() == 299, "mis remove")

  io_println(world, sum_si.to_string() + ":" + c4)
  0
}
EOF
STR_MAP_WASM="$TMP_DIR/str_map_fast.wasm"
STR_MAP_DEV_WASM="$TMP_DIR/str_map_fast_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$STR_MAP_WASM" "$TMP_DIR/str_map_fast.pion"
"$PIONC" build --target wasm32 -o "$STR_MAP_DEV_WASM" "$TMP_DIR/str_map_fast.pion"
for mode_wasm in "release:$STR_MAP_WASM" "dev:$STR_MAP_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): str_map_fast.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
// sum_{0..99}(5j+2) = 5*4950+200 = 24950; sum_{100..399}(3q+1) = 3*(79800-4950)+300 = 224850 => 249800
if ((rc | 0) !== 0 || out !== "249800:k_123_-45") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): str_map_fast mismatch: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const memBytes = instance.exports.memory.buffer.byteLength;
if (memBytes > 4 * 1024 * 1024) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): str_map_fast linear memory leaked:", memBytes);
  process.exit(1);
}
console.log("  str_map_fast (" + mode + "/" + rtLabel + "): out=" + out + " mem=" + (memBytes / (1024 * 1024)).toFixed(2) + "MiB OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "=== P29-C [13/13] Pure-Wasm Array / StringBuilder / String::slice+cmp+affix / Ptr Hot Paths ==="
cat > "$TMP_DIR/arr_sb_ptr_fast.pion" <<'EOF'
fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

pub fn main(world : World) -> Int {
  // 1. Array::new (cap=0, small slab cap<=60, large cap>60), push, pop, set (incl. self-assign & grow)
  let a0 : Array[Int] = Array::new()
  must(a0.length() == 0, "a0 len")
  let mut i = 0
  while i < 120 {
    a0.push(i * 3 + 1)
    i = i + 1
  }
  must(a0.length() == 120 && a0[0] == 1 && a0[119] == 358, "a0 grow")
  a0[10] = 999
  must(a0[10] == 999, "a0 set")
  match a0.pop() {
    Some(popped) => must(popped == 358 && a0.length() == 119, "a0 pop")
    None => must(false, "a0 pop none")
  }

  let a_small : Array[Int] = Array::make(12, 7)
  must(a_small.length() == 12 && a_small[0] == 7 && a_small[11] == 7, "a_small make")
  let a_big : Array[Int] = Array::make(80, 5)
  must(a_big.length() == 80 && a_big[79] == 5, "a_big make")

  // Object Array with self-assignment + repeated overwrite (RC zero leak)
  let ao : Array[String] = Array::new()
  let mut k = 0
  while k < 40 {
    ao.push("item_" + k.to_string())
    k = k + 1
  }
  ao[5] = ao[5]
  must(ao[5] == "item_5", "ao self-assign")
  ao[5] = "replaced_" + (55).to_string()
  must(ao[5] == "replaced_55", "ao overwrite")
  match ao.pop() {
    Some(pstr) => must(pstr == "item_39" && ao.length() == 39, "ao pop")
    None => must(false, "ao pop none")
  }

  // 2. StringBuilder: ASCII + CJK UTF-8 + long grow + reset + to_string
  let sb = StringBuilder::new()
  sb.write_string("hi:")
  sb.write_char('A')
  sb.write_char('中')
  sb.write_char('文')
  let mut n = 0
  while n < 40 {
    sb.write_string("0123456789")
    n = n + 1
  }
  let s1 = sb.to_string()
  must(s1.starts_with("hi:A中文0123456789"), "sb starts_with")
  must(s1.ends_with("0123456789"), "sb ends_with")
  must(s1.length() == 3 + 1 + 6 + 400, "sb len")
  sb.reset()
  sb.write_string("ok")
  must(sb.to_string() == "ok", "sb reset")

  // 3. String::slice (normal, negative, OOB, reversed) + cmp + starts_with + ends_with
  let base = "abcdef"
  must(base.slice(1, 4) == "bcd", "slice mid")
  must(base.slice(-5, 2) == "ab", "slice neg start")
  must(base.slice(4, 100) == "ef", "slice oob end")
  must(base.slice(5, 2) == "", "slice reversed")
  must(base.slice(10, 20) == "", "slice past end")
  must("abc" < "abd" && "abd" > "abc" && "ab" < "abc" && "abc" <= "abc", "str cmp")
  must(base.starts_with("abc") && !base.starts_with("abd") && base.starts_with(""), "starts_with")
  must(base.ends_with("def") && !base.ends_with("cef") && base.ends_with(""), "ends_with")
  must(!"ab".starts_with("abc") && !"ab".ends_with("abc"), "affix longer")

  // 4. Ptr offset + u8 / i32 / i64 / ptr read/write
  let buf = ptr_alloc(64L)
  let p1 = ptr_offset(buf, 8L)
  ptr_write_u8(buf, 0L, 0xAB)
  ptr_write_i32(buf, 4L, -123456)
  ptr_write_i64(p1, 0L, 0x1122334455667788L)
  ptr_write_ptr(buf, 16L, p1)
  must(ptr_read_u8(buf, 0L) == 0xAB, "ptr u8")
  must(ptr_read_i32(buf, 4L) == -123456, "ptr i32")
  must(ptr_read_i64(buf, 8L) == 0x1122334455667788L, "ptr i64")
  let rp = ptr_read_ptr(buf, 16L)
  must(ptr_read_i64(rp, 0L) == 0x1122334455667788L, "ptr read_ptr")
  ptr_free(buf)

  io_println(world, a0.length().to_string() + ":" + s1.length().to_string() + ":" + base.slice(1, 4))
  0
}
EOF
ASP_REL_WASM="$TMP_DIR/arr_sb_ptr_rel.wasm"
ASP_DEV_WASM="$TMP_DIR/arr_sb_ptr_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$ASP_REL_WASM" "$TMP_DIR/arr_sb_ptr_fast.pion"
"$PIONC" build --target wasm32 -o "$ASP_DEV_WASM" "$TMP_DIR/arr_sb_ptr_fast.pion"
for mode_wasm in "release:$ASP_REL_WASM" "dev:$ASP_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): arr_sb_ptr_fast.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || out !== "119:410:bcd") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): arr_sb_ptr_fast mismatch: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const memBytes = instance.exports.memory.buffer.byteLength;
if (memBytes > 4 * 1024 * 1024) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): arr_sb_ptr_fast linear memory leaked:", memBytes);
  process.exit(1);
}
console.log("  arr_sb_ptr_fast (" + mode + "/" + rtLabel + "): out=" + out + " mem=" + (memBytes / (1024 * 1024)).toFixed(2) + "MiB OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "=== P29-C [14/14] Pure-Wasm Bytes / arr.clear + TBytes & Immut-Field Loop BCE Regression ==="
cat > "$TMP_DIR/bytes_clear_fast.pion" <<'EOF'
fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

struct ImgBuf {
  rgba : Bytes
  lut : FixedArray[Int]
}

fn main(world : World) -> Int {
  // 1. Array::clear on Int and String arrays (verify zero RC leak over 500 cycles)
  let ai : Array[Int] = [1, 2, 3, 4]
  ai.clear()
  must(ai.length() == 0, "ai clear len")
  ai.push(42)
  must(ai.length() == 1 && ai[0] == 42, "ai reuse after clear")

  let as_arr : Array[String] = []
  let mut iter = 0
  while iter < 500 {
    let mut k = 0
    while k < 16 {
      as_arr.push("row_" + iter.to_string() + "_" + k.to_string())
      k = k + 1
    }
    must(as_arr.length() == 16, "as_arr len before clear")
    as_arr.clear()
    must(as_arr.length() == 0, "as_arr len after clear")
    iter = iter + 1
  }

  // 2. Bytes::new (0, 16, 496 slab max, 497 & 1024 JS slow path) + zero-init + slice + str conv
  let b0 = Bytes::new(0)
  must(b0.length() == 0, "b0 len")
  let b16 = Bytes::new(16)
  must(b16.length() == 16 && b16[0].to_int() == 0 && b16[15].to_int() == 0, "b16 zero")
  let b496 = Bytes::new(496)
  must(b496.length() == 496 && b496[0].to_int() == 0 && b496[495].to_int() == 0, "b496 slab")
  let mut i = 0
  while i < b496.length() {
    b496[i] = ((i * 13 + 7) & 255).to_byte()
    i = i + 1
  }
  let mut chk496 = 0
  i = 0
  while i < b496.length() {
    chk496 = chk496 + b496[i].to_int()
    i = i + 1
  }
  let b497 = Bytes::new(497)
  must(b497.length() == 497 && b497[496].to_int() == 0, "b497 slow")
  let b1024 = Bytes::new(1024)
  i = 0
  while i < b1024.length() {
    b1024[i] = (i & 255).to_byte()
    i = i + 1
  }
  let sl_mid = b496.slice(10, 26)
  must(sl_mid.length() == 16 && sl_mid[0] == b496[10] && sl_mid[15] == b496[25], "bytes slice mid")
  let sl_neg = b496.slice(-5, 4)
  must(sl_neg.length() == 4 && sl_neg[0] == b496[0] && sl_neg[3] == b496[3], "bytes slice neg")
  let sl_oob = b496.slice(490, 999)
  must(sl_oob.length() == 6 && sl_oob[5] == b496[495], "bytes slice oob")
  let sl_rev = b496.slice(20, 10)
  must(sl_rev.length() == 0, "bytes slice rev")
  let sl_big = b1024.slice(100, 700)
  must(sl_big.length() == 600 && sl_big[0].to_int() == 100 && sl_big[599].to_int() == (699 & 255), "bytes slice big")

  let s_orig = "hello:中文:123"
  let sb_bytes = s_orig.to_bytes()
  must(sb_bytes.length() == s_orig.length(), "str_to_bytes len")
  must(sb_bytes.to_string() == s_orig, "bytes_to_str roundtrip")
  must("".to_bytes().length() == 0 && Bytes::new(0).to_string() == "", "empty bytes/str roundtrip")

  // 3. Immutable struct Bytes + FixedArray field hoisting + BCE
  let img = ImgBuf::{ rgba: Bytes::new(64), lut: FixedArray::make(64, 0) }
  i = 0
  while i < img.rgba.length() {
    img.rgba[i] = ((i * 3 + 1) & 255).to_byte()
    i = i + 1
  }
  i = 0
  while i < img.lut.length() {
    img.lut[i] = i * 2
    i = i + 1
  }
  let mut img_sum = 0
  i = 0
  while i < img.lut.length() {
    img_sum = img_sum + img.lut[i] + img.rgba[i].to_int()
    i = i + 1
  }

  io_println(world, chk496.to_string() + ":" + img_sum.to_string() + ":" + sb_bytes.to_string())
  0
}
EOF
BC_REL_WASM="$TMP_DIR/bytes_clear_rel.wasm"
BC_DEV_WASM="$TMP_DIR/bytes_clear_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$BC_REL_WASM" "$TMP_DIR/bytes_clear_fast.pion"
"$PIONC" build --target wasm32 -o "$BC_DEV_WASM" "$TMP_DIR/bytes_clear_fast.pion"
for mode_wasm in "release:$BC_REL_WASM" "dev:$BC_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): bytes_clear_fast.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || out !== "62840:10144:hello:中文:123") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): bytes_clear_fast mismatch: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const memBytes = instance.exports.memory.buffer.byteLength;
if (memBytes > 4 * 1024 * 1024) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): bytes_clear_fast linear memory leaked:", memBytes);
  process.exit(1);
}
console.log("  bytes_clear_fast (" + mode + "/" + rtLabel + "): out=" + out + " mem=" + (memBytes / (1024 * 1024)).toFixed(2) + "MiB OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "=== P29-C [15/15] HOF Closure Inline Specialization + Pure-Wasm strbuf_push_int & Short-Lit Fast Path ==="
cat > "$TMP_DIR/hof_strbuf_fast.pion" <<'EOF'
fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

fn fold_items(
  items : Array[Int],
  m : (Int) -> Int,
  keep : (Int) -> Bool,
  step : (Int, Int) -> Int,
) -> Int {
  let mut acc = 0
  let len = items.length()
  let mut i = 0
  while i < len {
    let y = m(items[i])
    if keep(y) {
      acc = step(acc, y)
    }
    i = i + 1
  }
  acc
}

fn main(world : World) -> Int {
  let xs : Array[Int] = []
  let mut i = 0
  while i < 100 {
    xs.push(i)
    i = i + 1
  }
  let r = 3
  let total = fold_items(
    xs,
    fn(x : Int) -> Int { x * 2 + r },
    fn(y : Int) -> Bool {
      if y < 10 {
        return false
      }
      y % 3 == 0
    },
    fn(a : Int, y : Int) -> Int { a + y },
  )
  // Verify StringBuilder::write_string(int.to_string()) + 1..8B literal fast path + grow past 32B
  let sb = StringBuilder()
  sb.write_string("v=")
  sb.write_string((0).to_string())
  sb.write_string(",")
  sb.write_string((-42).to_string())
  sb.write_string(",")
  let min64 : Int64 = -9223372036854775807L - 1L
  sb.write_string(min64.to_string())
  sb.write_string(";")
  i = 0
  while i < 20 {
    sb.write_string("item-")
    sb.write_string(i.to_string())
    sb.write_string(";")
    i = i + 1
  }
  let s = sb.to_string()
  must(s.starts_with("v=0,-42,-9223372036854775808;item-0;item-1;"), "sb prefix")
  must(s.ends_with("item-19;"), "sb suffix")
  io_println(world, total.to_string() + ":" + s.length().to_string())
  0
}
EOF
HS_REL_WASM="$TMP_DIR/hof_strbuf_rel.wasm"
HS_DEV_WASM="$TMP_DIR/hof_strbuf_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$HS_REL_WASM" "$TMP_DIR/hof_strbuf_fast.pion"
"$PIONC" build --target wasm32 -o "$HS_DEV_WASM" "$TMP_DIR/hof_strbuf_fast.pion"
for mode_wasm in "release:$HS_REL_WASM" "dev:$HS_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): hof_strbuf_fast.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || out !== "3456:179") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): hof_strbuf_fast mismatch: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
console.log("  hof_strbuf_fast (" + mode + "/" + rtLabel + "): out=" + out + " OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "=== P29-C [16/16] Pure-Wasm Container Destructors (Array/Map/Bytes/StrBuf) & String::split Regression ==="
cat > "$TMP_DIR/container_drop_split.pion" <<'EOF'
fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

fn drop_containers_round(r : Int) -> Int {
  // Nested Array[Array[String]] (both small <=512B slab and large >512B backing buffer)
  let outer : Array[Array[String]] = []
  let mut i = 0
  while i < 8 {
    let inner : Array[String] = []
    let mut j = 0
    while j < 4 {
      inner.push("a_" + r.to_string() + "_" + i.to_string() + "_" + j.to_string())
      j = j + 1
    }
    outer.push(inner)
    i = i + 1
  }
  let big_arr : Array[String] = []
  i = 0
  while i < 80 {
    big_arr.push("b_" + i.to_string())
    i = i + 1
  }

  // Map[String, Array[String]] (small + large)
  let m : Map[String, Array[String]] = Map([])
  i = 0
  while i < 6 {
    let v : Array[String] = ["v0_" + i.to_string(), "v1_" + r.to_string()]
    m.set("k_" + i.to_string(), v)
    i = i + 1
  }

  // Bytes & StringBuilder (small slab + >512B large buffer)
  let bs_small = Bytes::new(64)
  bs_small[0] = (r & 255).to_byte()
  let bs_big = Bytes::new(1024)
  bs_big[1023] = ((r + 1) & 255).to_byte()

  let sb = StringBuilder::new()
  sb.write_string("hdr:")
  i = 0
  while i < 32 {
    sb.write_string("chunk_" + i.to_string() + ";")
    i = i + 1
  }
  let built = sb.to_string()

  outer.length() + big_arr.length() + m.length() + bs_small[0].to_int() + bs_big[1023].to_int() + built.length()
}

fn main(world : World) -> Int {
  // 1. 500 rounds of nested container allocation & drop (assert linear memory <= 4 MiB, zero leak)
  let mut acc = 0
  let mut r = 0
  while r < 500 {
    acc = acc + drop_containers_round(r)
    r = r + 1
  }

  // 2. String::split edge cases (1-byte, multi-byte, empty sep, UTF-8)
  let p1 = ",a,,b,".split(",")
  must(p1.length() == 5, "split ,a,,b, len")
  must(p1[0] == "" && p1[1] == "a" && p1[2] == "" && p1[3] == "b" && p1[4] == "", "split ,a,,b, vals")

  let p2 = "".split(",")
  must(p2.length() == 1 && p2[0] == "", "split empty str")

  let p3 = "abc".split(",")
  must(p3.length() == 1 && p3[0] == "abc", "split no match")

  let p4 = "a::b::::c".split("::")
  must(p4.length() == 4, "split :: len")
  must(p4[0] == "a" && p4[1] == "b" && p4[2] == "" && p4[3] == "c", "split :: vals")

  let p5 = "::".split("::")
  must(p5.length() == 2 && p5[0] == "" && p5[1] == "", "split exact multi-byte")

  let p6 = "hi".split("")
  must(p6.length() == 1 && p6[0] == "hi", "split empty sep")

  let p7 = "甲、乙、、丙".split("、")
  must(p7.length() == 4, "split utf8 len")
  must(p7[0] == "甲" && p7[1] == "乙" && p7[2] == "" && p7[3] == "丙", "split utf8 vals")

  // Larger 1-byte split (>60 parts -> JS slow arr_new, pure-Wasm 2-pass fill + pure-Wasm array drop)
  let sb_words = StringBuilder::new()
  let mut w = 0
  while w < 100 {
    if w > 0 {
      sb_words.write_string(" ")
    }
    sb_words.write_string("w" + w.to_string())
    w = w + 1
  }
  let words = sb_words.to_string().split(" ")
  must(words.length() == 100 && words[0] == "w0" && words[99] == "w99", "split 100 words")

  io_println(world, acc.to_string() + ":" + p1.length().to_string() + ":" + p4.length().to_string() + ":" + p7.length().to_string() + ":" + words.length().to_string())
  0
}
EOF
CDS_REL_WASM="$TMP_DIR/container_drop_split_rel.wasm"
CDS_DEV_WASM="$TMP_DIR/container_drop_split_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$CDS_REL_WASM" "$TMP_DIR/container_drop_split.pion"
"$PIONC" build --target wasm32 -o "$CDS_DEV_WASM" "$TMP_DIR/container_drop_split.pion"
for mode_wasm in "release:$CDS_REL_WASM" "dev:$CDS_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): container_drop_split.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || !out.endsWith(":5:4:4:100")) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): container_drop_split mismatch: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const memBytes = instance.exports.memory.buffer.byteLength;
if (memBytes > 4 * 1024 * 1024) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): container_drop_split linear memory leaked:", memBytes);
  process.exit(1);
}
console.log("  container_drop_split (" + mode + "/" + rtLabel + "): out=" + out + " mem=" + (memBytes / (1024 * 1024)).toFixed(2) + "MiB OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "[17/18] P38-B Compact 1-Byte Array/FixedArray[Bool|Byte] Regression (release+dev x Node+Web)"
cat > "$TMP_DIR/p38b_compact_u8.pion" <<'EOF'
fn id_arr[T](a : Array[T]) -> Array[T] {
  a
}

fn first_elem[T](a : Array[T]) -> T {
  a[0]
}

pub fn main(world : World) -> Int {
  let n = 10000
  let flags = Array::make(n, true)
  flags[0] = false
  flags[1] = false
  let mut i = 2
  while i * i < n {
    if flags[i] {
      let mut j = i * i
      while j < n {
        flags[j] = false
        j = j + i
      }
    }
    i = i + 1
  }
  let mut primes = 0
  let mut k = 0
  while k < n {
    if flags[k] {
      primes = primes + 1
    }
    k = k + 1
  }

  let bs : Array[Byte] = Array::new()
  let mut m = 0
  while m < 600 {
    bs.push(((m * 37 + 11) & 255).to_byte())
    m = m + 1
  }
  let popped = match bs.pop() {
    Some(v) => v.to_int()
    None => -1
  }
  let bs_cp = bs.copy()
  bs_cp[0] = (254).to_byte()
  let bs_lit : Array[Byte] = [(200).to_byte(), (5).to_byte(), (255).to_byte(), (42).to_byte()]
  bs_lit.reverse()
  let g0 = first_elem(id_arr(bs_lit)).to_int()

  let fb = FixedArray::make(32, false)
  fb.fill(true)
  fb[7] = false
  let fb2 = FixedArray::makei(16, fn(x : Int) -> Bool { x % 3 == 0 })
  let fby = FixedArray::makei(10, fn(x : Int) -> Byte { (x * 20 + 3).to_byte() })
  let fby2 = FixedArray::make(10, (0).to_byte())
  fby.blit_to(fby2, len=5, src_offset=1, dst_offset=2)
  fby.blit_to(fby, len=4, src_offset=0, dst_offset=3)
  let ok_b = if !flags[0] && flags[9973] && bs_cp.contains((254).to_byte()) && !fb[7] && fb2[6] && !fb2[7] { 1 } else { 0 }

  io_println(
    world,
    primes.to_string() + ":" + popped.to_string() + ":" + g0.to_string() + ":" + fby2[2].to_int().to_string() + ":" + fby[6].to_int().to_string() + ":" + ok_b.to_string(),
  )
  0
}
EOF
P38B_REL_WASM="$TMP_DIR/p38b_rel.wasm"
P38B_DEV_WASM="$TMP_DIR/p38b_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$P38B_REL_WASM" "$TMP_DIR/p38b_compact_u8.pion"
"$PIONC" build --target wasm32 -o "$P38B_DEV_WASM" "$TMP_DIR/p38b_compact_u8.pion"
for mode_wasm in "release:$P38B_REL_WASM" "dev:$P38B_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p38b_compact_u8.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || out !== "1229:158:42:23:63:1") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p38b_compact_u8 mismatch: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
console.log("  p38b_compact_u8 (" + mode + "/" + rtLabel + "): out=" + out + " OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "[18/18] P38-C Flat POD Struct Arrays & HOF Fusion Regression (release+dev x Node+Web)"
cat > "$TMP_DIR/flat_pod_arr.pion" <<'EOF'
#derive(Eq)
struct Pt2 { x : Int64, y : Int64 }
struct Vec3 { x : Double, y : Double, z : Double }
struct Rect4 { x : Int, y : Int, w : Int, h : Int }
struct MutBody { mut x : Int, mut y : Int }
struct Named { id : Int, label : String }

fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

fn esc_pt(a : Array[Pt2], i : Int) -> Pt2 { a[i] }

fn map_pts(pts : Array[Pt2], f : (Pt2) -> Pt2) -> Array[Pt2] {
  let len = pts.length()
  let out : Array[Pt2] = Array::with_capacity(len)
  let mut i = 0
  while i < len {
    out.push(f(pts[i]))
    i = i + 1
  }
  out
}

pub fn main(world : World) -> Int {
  let pts : Array[Pt2] = Array::new()
  let mut i = 0
  while i < 100 {
    pts.push(Pt2::{ x: i.to_int64(), y: (i * 3).to_int64() })
    i = i + 1
  }
  let mapped = map_pts(pts, fn(p : Pt2) -> Pt2 { Pt2::{ x: p.x + 1L, y: p.y + 2L } })
  must(mapped[0].x == 1L && mapped[99].y == 299L, "pt2 hof map")
  let cp = pts.copy()
  cp.reverse()
  must(cp[0].x == 99L && cp[99].x == 0L, "pt2 reverse")
  let popped = match cp.pop() {
    Some(p) => p.x + p.y
    None => -1L
  }
  must(popped == 0L && cp.length() == 99, "pt2 pop")
  let e = esc_pt(pts, 42)
  must(e.x == 42L && e.y == 126L, "pt2 escape")
  must(pts.contains(Pt2::{ x: 50L, y: 150L }), "pt2 contains")
  pts[10] = Pt2::{ x: 1000L, y: 2000L }
  let mut s2 = 0L
  i = 0
  while i < pts.length() {
    let p = pts[i]
    s2 = s2 + p.x + p.y
    i = i + 1
  }

  let v3 = FixedArray::makei(8, fn(k : Int) -> Vec3 {
    Vec3::{ x: k.to_double(), y: (k * 2).to_double(), z: (k * 4).to_double() }
  })
  let v3b = FixedArray::make(8, Vec3::{ x: 0.0, y: 0.0, z: 0.0 })
  v3.blit_to(v3b, len=4, src_offset=3, dst_offset=2)
  must(v3b[2].x.to_int() == 3 && v3b[5].z.to_int() == 24, "vec3 blit")
  v3b.fill(Vec3::{ x: 1.0, y: 2.0, z: 3.0 })
  let s3 = (v3b[0].x + v3b[7].z).to_int()

  let r4 : Array[Rect4] = Array::new()
  i = 0
  while i < 16 {
    r4.push(Rect4::{ x: i, y: i + 1, w: i + 2, h: i + 3 })
    i = i + 1
  }
  r4.reverse()
  let s4 = r4[0].x + r4[0].h + r4[15].h

  let mb : Array[MutBody] = [MutBody::{ x: 5, y: 6 }]
  let m0 = mb[0]
  m0.x = 77
  must(mb[0].x == 77, "mut alias")
  let nm : Array[Named] = [Named::{ id: 1, label: "ok" }]
  nm.push(Named::{ id: 2, label: "go" })
  nm.reverse()
  io_println(world, s2.to_string() + ":" + s3.to_string() + ":" + s4.to_string() + ":" + mb[0].x.to_string() + ":" + nm[0].label)
  0
}
EOF
FP_REL_WASM="$TMP_DIR/flat_pod_rel.wasm"
FP_DEV_WASM="$TMP_DIR/flat_pod_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$FP_REL_WASM" "$TMP_DIR/flat_pod_arr.pion"
"$PIONC" build --target wasm32 -o "$FP_DEV_WASM" "$TMP_DIR/flat_pod_arr.pion"
for mode_wasm in "release:$FP_REL_WASM" "dev:$FP_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): flat_pod_arr.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || out !== "22760:4:36:77:go") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): flat_pod_arr mismatch: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const memBytes = instance.exports.memory.buffer.byteLength;
if (memBytes > 4 * 1024 * 1024) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): flat_pod_arr linear memory leaked:", memBytes);
  process.exit(1);
}
console.log("  flat_pod_arr (" + mode + "/" + rtLabel + "): out=" + out + " mem=" + (memBytes / (1024 * 1024)).toFixed(2) + "MiB OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "[19/19] Web Runtime Single-Threaded Concurrency Primitives Regression (release+dev x Node+Web)"
cat > "$TMP_DIR/web_concurrency.pion" <<'EOF'
pub fn main(world : World) -> Int {
  let mx : Mutex[Int] = Mutex::new(10)
  let v0 = mx.lock()
  mx.set(v0 + 5)
  mx.unlock()
  let v1 = mx.lock()
  mx.unlock()

  let smx : Mutex[String] = Mutex::new("init")
  let s0 = smx.lock()
  smx.set(s0 + "_ok")
  smx.unlock()
  let s1 = smx.lock()
  smx.unlock()

  let at = AtomicInt::new(1)
  at.store(10)
  let prev = at.fetch_add(7)
  let cur = at.load()

  let ch : Channel[String] = Channel::new(4)
  scope(world, fn(sc : Scope) -> Unit {
    spawn(sc, fn() -> Unit {
      let _ = ch.send("alpha")
      let _ = ch.send("beta")
    })
  })
  let r1 = match ch.recv() {
    Some(s) => s
    None => "none"
  }
  let r2 = match ch.recv() {
    Some(s) => s
    None => "none"
  }
  ch.close()
  let closed_send = if ch.send("gamma") { 1 } else { 0 }
  let r3 = match ch.recv() {
    Some(s) => s
    None => "empty"
  }

  io_println(world, v1.to_string() + ":" + s1 + ":" + prev.to_string() + ":" + cur.to_string() + ":" + r1 + ":" + r2 + ":" + closed_send.to_string() + ":" + r3)
  0
}
EOF
WC_REL_WASM="$TMP_DIR/web_concurrency_rel.wasm"
WC_DEV_WASM="$TMP_DIR/web_concurrency_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$WC_REL_WASM" "$TMP_DIR/web_concurrency.pion"
"$PIONC" build --target wasm32 -o "$WC_DEV_WASM" "$TMP_DIR/web_concurrency.pion"
for mode_wasm in "release:$WC_REL_WASM" "dev:$WC_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): web_concurrency.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || out !== "15:init_ok:10:17:alpha:beta:0:empty") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): web_concurrency mismatch: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
console.log("  web_concurrency (" + mode + "/" + rtLabel + "): out=" + out + " OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "[20/20] P41-A flat RC struct arrays (release + dev x Node + Web, leaked=0)"
cat > "$TMP_DIR/flat_rc_arr.pion" <<'EOF'
struct Pair {
  key : String
  nums : Array[Int]
}

struct Rec {
  id : Int64
  name : String
  active : Bool
  score : Int64
  tags : Array[String]
}

pub fn main(world : World) -> Int {
  let mut checksum : Int64 = 0L
  let mut round = 0
  while round < 300 {
    let ps : Array[Pair] = Array::with_capacity(4)
    ps.push(Pair::{ key: "a" + round.to_string(), nums: [1, 2] })
    ps.push(Pair::{ key: "b" + round.to_string(), nums: [3, 4, 5] })
    ps[0] = ps[0]
    ps[1] = Pair::{ key: ps[1].key + "x", nums: [9] }
    let cp = ps.copy()
    cp.reverse()
    let pop_len = match cp.pop() {
      Some(v) => v.key.length().to_int64() + v.nums.length().to_int64()
      None => 0L
    }
    cp.clear()
    let rs : Array[Rec] = Array::with_capacity(2)
    rs.push(Rec::{ id: round.to_int64(), name: "u" + round.to_string(), active: round % 2 == 0, score: 10L, tags: ["t0", "t1"] })
    let r = rs[0]
    checksum = checksum + pop_len + r.score + r.tags.length().to_int64()
    round = round + 1
  }
  io_println(world, checksum.to_string())
  0
}
EOF
FRC_REL_WASM="$TMP_DIR/flat_rc_arr_rel.wasm"
FRC_DEV_WASM="$TMP_DIR/flat_rc_arr_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$FRC_REL_WASM" "$TMP_DIR/flat_rc_arr.pion"
"$PIONC" build --target wasm32 -o "$FRC_DEV_WASM" "$TMP_DIR/flat_rc_arr.pion"
for mode_wasm in "release:$FRC_REL_WASM" "dev:$FRC_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): flat_rc_arr.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
const memBytes = instance.exports.memory.buffer.byteLength;
if ((rc | 0) !== 0 || out !== "5290") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): flat_rc_arr mismatch: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
if (memBytes > 4 * 1024 * 1024) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): flat_rc_arr linear memory leaked:", memBytes);
  process.exit(1);
}
console.log("  flat_rc_arr (" + mode + "/" + rtLabel + "): out=" + out + " mem=" + memBytes + "B OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "[21/21] P42-C Wasm32 memarg.offset + jnz NaN/int cmp + const div/rem strength reduction (release+dev x Node+Web)"
cat > "$TMP_DIR/p42c_wasm_opts.pion" <<'EOF'
struct Box4 {
  mut a : Int
  mut b : Int64
  mut c : Double
  mut d : Int
}

fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

fn ref_div32(x : Int, d : Int) -> Int {
  let dd = d
  x / dd
}

fn ref_rem32(x : Int, d : Int) -> Int {
  let dd = d
  x % dd
}

fn ref_div64(x : Int64, d : Int64) -> Int64 {
  let dd = d
  x / dd
}

fn ref_rem64(x : Int64, d : Int64) -> Int64 {
  let dd = d
  x % dd
}

fn check_i32_divrem(x : Int) -> Unit {
  must(x / 2 == ref_div32(x, 2) && x % 2 == ref_rem32(x, 2), "i32 /2")
  must(x / 3 == ref_div32(x, 3) && x % 3 == ref_rem32(x, 3), "i32 /3")
  must(x / 4 == ref_div32(x, 4) && x % 4 == ref_rem32(x, 4), "i32 /4")
  must(x / 5 == ref_div32(x, 5) && x % 5 == ref_rem32(x, 5), "i32 /5")
  must(x / 7 == ref_div32(x, 7) && x % 7 == ref_rem32(x, 7), "i32 /7")
  must(x / 8 == ref_div32(x, 8) && x % 8 == ref_rem32(x, 8), "i32 /8")
  must(x / 10 == ref_div32(x, 10) && x % 10 == ref_rem32(x, 10), "i32 /10")
  must(x / 1000 == ref_div32(x, 1000) && x % 1000 == ref_rem32(x, 1000), "i32 /1000")
  must(x / 100003 == ref_div32(x, 100003) && x % 100003 == ref_rem32(x, 100003), "i32 /100003")
  must(x / 1000003 == ref_div32(x, 1000003) && x % 1000003 == ref_rem32(x, 1000003), "i32 /1000003")
}

fn check_i64_divrem(x : Int64) -> Unit {
  must(x / 2L == ref_div64(x, 2L) && x % 2L == ref_rem64(x, 2L), "i64 /2")
  must(x / 4L == ref_div64(x, 4L) && x % 4L == ref_rem64(x, 4L), "i64 /4")
  must(x / 8L == ref_div64(x, 8L) && x % 8L == ref_rem64(x, 8L), "i64 /8")
  must(x / 1024L == ref_div64(x, 1024L) && x % 1024L == ref_rem64(x, 1024L), "i64 /1024")
}

pub fn main(world : World) -> Int {
  // 1. Struct & Array memarg.offset read/write
  let bx = Box4::{ a: 11, b: 222L, c: 3.5, d: 44 }
  bx.a = bx.a + 1
  bx.b = bx.b + 10L
  bx.c = bx.c + 0.5
  bx.d = bx.d + 2
  must(bx.a == 12 && bx.b == 232L && bx.c == 4.0 && bx.d == 46, "struct offset")

  let arr : Array[Int] = [10, 20, 30, 40]
  arr[2] = arr[1] + arr[3]
  must(arr.length() == 4 && arr[2] == 60, "arr offset")

  // 2. jnz integer comparison + float NaN comparison semantics
  let zero_d : Double = 0.0
  let nan_d : Double = zero_d / zero_d
  let mut nan_flags = 0
  if nan_d < 1.0 { nan_flags = nan_flags + 1 }
  if nan_d > 1.0 { nan_flags = nan_flags + 2 }
  if nan_d <= 1.0 { nan_flags = nan_flags + 4 }
  if nan_d >= 1.0 { nan_flags = nan_flags + 8 }
  if nan_d == nan_d { nan_flags = nan_flags + 16 }
  if nan_d != nan_d { nan_flags = nan_flags + 32 }
  if !(nan_d < 1.0) { nan_flags = nan_flags + 64 }
  must(nan_flags == 96, "nan jnz")

  // 3. Signed i32 constant div/rem boundaries (incl. INT32_MIN / INT32_MAX)
  let imin32 : Int = -2147483647 - 1
  let imax32 : Int = 2147483647
  let cases32 : Array[Int] = [
    0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6, 7, -7, 8, -8, 9, -9, 10, -10, 11, -11,
    999, 1000, 1001, -999, -1000, -1001,
    100002, 100003, 100004, -100002, -100003, -100004,
    1000002, 1000003, 1000004, -1000002, -1000003, -1000004,
    imax32, imax32 - 1, imin32, imin32 + 1
  ]
  let mut i = 0
  while i < cases32.length() {
    check_i32_divrem(cases32[i])
    i = i + 1
  }

  // 4. Signed i64 power-of-2 div/rem boundaries (incl. INT64_MIN / INT64_MAX)
  let imin64 : Int64 = -9223372036854775807L - 1L
  let imax64 : Int64 = 9223372036854775807L
  let cases64 : Array[Int64] = [0L, 1L, -1L, 2L, -2L, 3L, -3L, 7L, -7L, 8L, -8L, 1023L, -1023L, 1024L, -1024L, imax64, imin64]
  i = 0
  while i < cases64.length() {
    check_i64_divrem(cases64[i])
    i = i + 1
  }

  // 5. Unsigned udiv/urem power-of-2
  let u32 : UInt = 0xFFFF_FFFDU
  must(u32 / 8U == 0x1FFF_FFFFU && u32 % 8U == 5U, "u32 pow2")
  let u64 : UInt64 = 0xFFFF_FFFF_FFFF_FFFDUL
  must(u64 / 16UL == 0x0FFF_FFFF_FFFF_FFFFUL && u64 % 16UL == 13UL, "u64 pow2")

  io_println(world, "p42c_wasm_opts ok:" + bx.b.to_string() + ":" + arr[2].to_string() + ":" + nan_flags.to_string())
  0
}
EOF
P42C_REL_WASM="$TMP_DIR/p42c_opts_rel.wasm"
P42C_DEV_WASM="$TMP_DIR/p42c_opts_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$P42C_REL_WASM" "$TMP_DIR/p42c_wasm_opts.pion"
"$PIONC" build --target wasm32 -o "$P42C_DEV_WASM" "$TMP_DIR/p42c_wasm_opts.pion"
for mode_wasm in "release:$P42C_REL_WASM" "dev:$P42C_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p42c_wasm_opts.wasm failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || out !== "p42c_wasm_opts ok:232:60:96") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p42c_wasm_opts mismatch: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
console.log("  p42c_wasm_opts (" + mode + "/" + rtLabel + "): out=" + out + " OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "=== P44-A: Inline FLAG_SLAB Free + Recursive drop_fn + Container Mix + >512B Fallback (Node + Web leaked=0) ==="
cat > "$TMP_DIR/p44a_slab_inline_free.pion" <<'EOF'
enum Tree {
  Leaf(Int)
  Branch(Tree, Tree, String)
}

struct Holder {
  tag : String
  tree : Tree
  nums : Array[Int]
}

fn build_tree(depth : Int, seed : Int) -> Tree {
  if depth <= 0 {
    Tree::Leaf(seed)
  } else {
    let l = build_tree(depth - 1, seed + 1)
    let r = build_tree(depth - 1, seed + 2)
    Tree::Branch(l, r, "n" + seed.to_string())
  }
}

fn sum_tree(t : Tree) -> Int {
  match t {
    Tree::Leaf(v) => v
    Tree::Branch(l, r, s) => sum_tree(l) + sum_tree(r) + s.length()
  }
}

pub fn main(world : World) -> Int {
  let mut acc = 0
  // 1. High-volume alloc/free/reuse of TAG_STRING, TAG_STRUCT, TAG_ENUM (with recursive drop_fn)
  let mut i = 0
  while i < 60 {
    let t = build_tree(8, i)
    let h = Holder::{ tag: "h:" + i.to_string(), tree: t, nums: [i, i + 1, i + 2, i + 3] }
    acc = acc + sum_tree(h.tree) + h.tag.length() + h.nums[3]
    i = i + 1
  }

  // 2. Container mix (Array[String] + Map[String, Holder]) exercising slab + container drop
  let m : Map[String, Holder] = Map::new()
  let arr : Array[String] = []
  let mut j = 0
  while j < 40 {
    let k = "k_" + j.to_string()
    arr.push(k)
    m.set(k, Holder::{ tag: k, tree: build_tree(4, j), nums: [j, j * 2] })
    j = j + 1
  }
  acc = acc + m.length() + arr.length()

  // 3. Large >512B String & Array objects falling back to JS slow path
  let mut k = 0
  while k < 30 {
    let sb = StringBuilder()
    let mut c = 0
    while c < 120 {
      sb.write_string("0123456789")
      c = c + 1
    }
    let big_s = sb.to_string() // 1200B (>512B)
    let big_a : Array[Int] = Array::make(256, k) // 2048B (>512B)
    acc = acc + big_s.length() + big_a[0]
    k = k + 1
  }

  io_println(world, "p44a_slab_ok:" + acc.to_string())
  0
}
EOF
P44A_REL_WASM="$TMP_DIR/p44a_slab_rel.wasm"
P44A_DEV_WASM="$TMP_DIR/p44a_slab_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$P44A_REL_WASM" "$TMP_DIR/p44a_slab_inline_free.pion"
"$PIONC" build --target wasm32 -o "$P44A_DEV_WASM" "$TMP_DIR/p44a_slab_inline_free.pion"
for mode_wasm in "release:$P44A_REL_WASM" "dev:$P44A_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p44a_slab failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || !out.startsWith("p44a_slab_ok:")) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p44a_slab bad output: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const memBytes = instance.exports.memory.buffer.byteLength;
if (memBytes > 4 * 1024 * 1024) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p44a_slab memory grew too large:", memBytes);
  process.exit(1);
}
// Walk linear memory heap from heap_base to heap_ptr and verify 0 leaked non-immortal blocks
const dv = new DataView(instance.exports.memory.buffer);
const ctl = instance.exports.__pion_slab_ctl.value >>> 0;
const hp = dv.getUint32(ctl + 36, true);
const hb = dv.getUint32(ctl + 44, true);
let cur = hb;
let leaked = 0;
let freed = 0;
while (cur + 8 <= hp) {
  const sz = dv.getUint32(cur, true);
  const magic = dv.getUint32(cur + 4, true);
  if (sz < 16 || cur + sz > hp) {
    console.error("FAIL (" + mode + "/" + rtLabel + "): corrupt heap block at", cur, "sz=", sz, "hp=", hp);
    process.exit(1);
  }
  if (magic === 0x50494f4e) {
    // Check FLAG_IMMORTAL (2) at hdr+14 (cur+22) if block holds a PionHeader
    const flags = cur + 24 <= hp ? dv.getUint16(cur + 22, true) : 0;
    if ((flags & 2) === 0) leaked++;
  } else if (magic === 0x46524545) {
    freed++;
  }
  cur += sz;
}
if (leaked !== 0) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p44a_slab leaked=" + leaked + " (freed=" + freed + ")");
  process.exit(1);
}
console.log("  p44a_slab (" + mode + "/" + rtLabel + "): " + out + " mem=" + (memBytes / (1024 * 1024)).toFixed(2) + "MiB freed=" + freed + " leaked=0 OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "=== P45-A: Nested Loop Outlining (0/1/3 live_out, break/continue, float+array) + strbuf_push_int Zero-Div Boundaries + Small Struct Inline Slab (Node + Web leaked=0) ==="
cat > "$TMP_DIR/p45a_wasm_turbo.pion" <<'EOF'
struct Pair {
  a : Int64
  b : Int64
}

fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

pub fn main(world : World) -> Int {
  // 1. Nested loop outlining with 0 live_out (array mutation only)
  let grid : Array[Int] = Array::make(128, 0)
  let mut r = 0
  while r < 8 {
    let mut c = 0
    while c < 16 {
      let idx = r * 16 + c
      grid[idx] = (r + 1) * (c + 2)
      c = c + 1
    }
    r = r + 1
  }
  must(grid[0] == 2 && grid[127] == 8 * 17, "0 live_out")

  // 2. Nested loop outlining with 1 live_out + float + continue + early break
  let mut fsum : Double = 0.0
  let mut y = 0
  while y < 12 {
    let mut x = 0
    while x < 20 {
      if x == 3 {
        x = x + 1
        continue
      }
      if x == 15 {
        break
      }
      fsum = fsum + (y.to_double() + 0.5) * (x.to_double() + 1.0)
      x = x + 1
    }
    y = y + 1
  }
  // y=0..11 => sum(y+0.5) = 66 + 6 = 72.0; x=0..14 except 3 => sum(x+1) = 120 - 4 = 116.0 => 72 * 116 = 8352.0
  must(fsum == 8352.0, "1 live_out float break/continue")

  // 3. Nested loop outlining with 3 live_out (s1, s2, s3) + outer variable update
  let mut s1 : Int64 = 0L
  let mut s2 : Int = 0
  let mut s3 : Double = 0.0
  let mut o = 0
  while o < 6 {
    let mut k = 0
    while k < 10 {
      let v = grid[o * 16 + k]
      s1 = s1 + v.to_int64()
      s2 = s2 + (v % 7)
      s3 = s3 + v.to_double() * 0.25
      k = k + 1
    }
    o = o + 1
  }
  must(s1 > 0L && s2 > 0 && s3 == s1.to_double() * 0.25, "3 live_out")

  // 4. StringBuilder::write_string(v.to_string()) zero-division boundary values
  let sb = StringBuilder()
  let imin32 : Int = -2147483647 - 1
  let imax64 : Int64 = 9223372036854775807L
  let imin64 : Int64 = -9223372036854775807L - 1L
  sb.write_string((0).to_string()); sb.write_string(",")
  sb.write_string((9).to_string()); sb.write_string(",")
  sb.write_string((10).to_string()); sb.write_string(",")
  sb.write_string((99999999).to_string()); sb.write_string(",")
  sb.write_string((4294967295L).to_string()); sb.write_string(",")
  sb.write_string((4294967296L).to_string()); sb.write_string(",")
  sb.write_string((-1).to_string()); sb.write_string(",")
  sb.write_string(imin32.to_string()); sb.write_string(",")
  sb.write_string(imax64.to_string()); sb.write_string(",")
  sb.write_string(imin64.to_string())
  let got_s = sb.to_string()
  let exp_s = "0,9,10,99999999,4294967295,4294967296,-1,-2147483648,9223372036854775807,-9223372036854775808"
  must(got_s == exp_s, "strbuf_push_int boundaries: " + got_s)

  // 5. High-frequency small struct (size=16 -> cls=1) inline slab alloc/free reuse
  let mut psum : Int64 = 0L
  let mut it = 0
  while it < 2000 {
    let p = Pair::{ a: it.to_int64(), b: (it * 3).to_int64() }
    psum = psum + p.a + p.b
    it = it + 1
  }
  // sum(4 * it for it in 0..1999) = 4 * 1999 * 2000 / 2 = 7996000
  must(psum == 7996000L, "small struct inline slab")

  io_println(world, "p45a_ok:" + s1.to_string() + ":" + psum.to_string())
  0
}
EOF
P45A_REL_WASM="$TMP_DIR/p45a_rel.wasm"
P45A_DEV_WASM="$TMP_DIR/p45a_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$P45A_REL_WASM" "$TMP_DIR/p45a_wasm_turbo.pion"
"$PIONC" build --target wasm32 -o "$P45A_DEV_WASM" "$TMP_DIR/p45a_wasm_turbo.pion"
for mode_wasm in "release:$P45A_REL_WASM" "dev:$P45A_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p45a failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || !out.startsWith("p45a_ok:") || !out.endsWith(":7996000")) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p45a bad output: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const dv = new DataView(instance.exports.memory.buffer);
const ctl = instance.exports.__pion_slab_ctl.value >>> 0;
const hp = dv.getUint32(ctl + 36, true);
const hb = dv.getUint32(ctl + 44, true);
let cur = hb, leaked = 0, freed = 0;
while (cur + 8 <= hp) {
  const sz = dv.getUint32(cur, true);
  const magic = dv.getUint32(cur + 4, true);
  if (sz < 16 || cur + sz > hp) {
    console.error("FAIL (" + mode + "/" + rtLabel + "): corrupt heap block at", cur, "sz=", sz);
    process.exit(1);
  }
  if (magic === 0x50494f4e) {
    const flags = cur + 24 <= hp ? dv.getUint16(cur + 22, true) : 0;
    if ((flags & 2) === 0) leaked++;
  } else if (magic === 0x46524545) {
    freed++;
  }
  cur += sz;
}
if (leaked !== 0) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p45a leaked=" + leaked + " (freed=" + freed + ")");
  process.exit(1);
}
console.log("  p45a (" + mode + "/" + rtLabel + "): " + out + " freed=" + freed + " leaked=0 OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "=== P46-A: map_hint ABA + str_split (0..20B) + str_eq (0..32B) + Zero-Drop Leaf Inline rc_dec (Node + Web leaked=0) ==="
cat > "$TMP_DIR/p46a_wasm_opt.pion" <<'EOF'
struct Leaf {
  x : Int64
  y : Int64
}

fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

fn drop_temp_map() -> Int {
  let tmp : Map[String, Int] = Map([])
  tmp.set("k1", 10)
  tmp.set("k2", 20)
  let v = tmp.get("k1")
  match v {
    Some(n) => n
    None => 0
  }
}

pub fn main(world : World) -> Int {
  // 1. map_hint ABA safety: get->set hit, remove, clear, grow, drop-and-reuse, String + Int keys
  let sm : Map[String, Int] = Map([])
  sm.set("alpha", 1)
  sm.set("beta", 2)
  must(sm.contains("alpha"), "contains alpha")
  sm.set("alpha", 11)
  match sm.get("alpha") {
    Some(v) => must(v == 11, "hint update after contains")
    None => must(false, "missing alpha")
  }
  sm.set("alpha", 111)
  match sm.get("alpha") {
    Some(v) => must(v == 111, "hint update after get")
    None => must(false, "missing alpha 2")
  }
  // Invalidate via remove, then re-set
  let _ = sm.get("beta")
  sm.remove("beta")
  sm.set("beta", 22)
  match sm.get("beta") {
    Some(v) => must(v == 22, "after remove")
    None => must(false, "missing beta")
  }
  // Invalidate via grow (>16 entries)
  let _ = sm.get("alpha")
  let mut gi = 0
  while gi < 40 {
    let k = "key_" + gi.to_string()
    sm.set(k, gi)
    gi = gi + 1
  }
  sm.set("alpha", 999)
  match sm.get("alpha") {
    Some(v) => must(v == 999, "after grow")
    None => must(false, "missing alpha after grow")
  }
  // Invalidate via clear
  let _ = sm.get("alpha")
  sm.clear()
  sm.set("alpha", 7)
  must(sm.length() == 1, "len after clear+set")
  match sm.get("alpha") {
    Some(v) => must(v == 7, "val after clear+set")
    None => must(false, "missing alpha after clear")
  }
  // Invalidate via TAG_MAP drop + new map at recycled address
  must(drop_temp_map() == 10, "drop_temp_map")
  let sm2 : Map[String, Int] = Map([])
  sm2.set("k1", 77)
  match sm2.get("k1") {
    Some(v) => must(v == 77, "new map after drop")
    None => must(false, "missing k1")
  }
  // Int-keyed map hint + remove + grow
  let im : Map[Int, Int] = Map([])
  let mut ii = 0
  while ii < 32 {
    im.set(ii, ii * 2)
    ii = ii + 1
  }
  ii = 0
  while ii < 32 {
    match im.get(ii) {
      Some(v) => im.set(ii, v + 1)
      None => must(false, "missing int key")
    }
    ii = ii + 1
  }
  im.remove(5)
  im.set(5, 555)
  match im.get(5) {
    Some(v) => must(v == 555, "int key after remove")
    None => must(false, "missing int key 5")
  }

  // 2. str_split covering seg_len = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 20 + high-freq short token reuse
  let sample = "|a|bc|def|ghij|klmno|pqrstu|vwxyz12|abcdefgh|123456789|0123456789abcdefghij|"
  let parts = sample.split("|")
  must(parts.length() == 12, "split len")
  must(parts[0] == "", "len 0 head")
  must(parts[1] == "a", "len 1")
  must(parts[2] == "bc", "len 2")
  must(parts[3] == "def", "len 3")
  must(parts[4] == "ghij", "len 4")
  must(parts[5] == "klmno", "len 5")
  must(parts[6] == "pqrstu", "len 6")
  must(parts[7] == "vwxyz12", "len 7")
  must(parts[8] == "abcdefgh", "len 8")
  must(parts[9] == "123456789", "len 9")
  must(parts[10] == "0123456789abcdefghij", "len 20")
  must(parts[11] == "", "len 0 tail")

  let mut tok_sum = 0
  let mut rep = 0
  while rep < 300 {
    let ws = "a bb ccc dddd eeeee ffffff ggggggg".split(" ")
    tok_sum = tok_sum + ws.length()
    rep = rep + 1
  }
  must(tok_sum == 2100, "short token reuse")

  // 3. str_eq covering 0..32 bytes equal and last-byte-diff
  let full32 = "0123456789abcdefghijklmnopqrstuv"
  let mut ln = 0
  while ln <= 32 {
    let a = full32.slice(0, ln)
    let b = full32.slice(0, ln)
    must(a == b, "str_eq equal len=" + ln.to_string())
    if ln > 0 {
      let c = full32.slice(0, ln - 1) + "Z"
      must(a != c, "str_eq last-byte diff len=" + ln.to_string())
    }
    ln = ln + 1
  }

  // 4. Zero-drop_fn leaf struct & short string inline rc_dec free
  let mut lsum : Int64 = 0L
  let mut li = 0
  while li < 2000 {
    let lf = Leaf::{ x: li.to_int64(), y: (li + 7).to_int64() }
    lsum = lsum + lf.x + lf.y
    li = li + 1
  }
  must(lsum == 4012000L, "leaf inline rc_dec")

  io_println(world, "p46a_ok:" + tok_sum.to_string() + ":" + lsum.to_string())
  0
}
EOF
P46A_REL_WASM="$TMP_DIR/p46a_rel.wasm"
P46A_DEV_WASM="$TMP_DIR/p46a_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$P46A_REL_WASM" "$TMP_DIR/p46a_wasm_opt.pion"
"$PIONC" build --target wasm32 -o "$P46A_DEV_WASM" "$TMP_DIR/p46a_wasm_opt.pion"
for mode_wasm in "release:$P46A_REL_WASM" "dev:$P46A_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p46a failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || out !== "p46a_ok:2100:4012000") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p46a bad output: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const dv = new DataView(instance.exports.memory.buffer);
const ctl = instance.exports.__pion_slab_ctl.value >>> 0;
const hp = dv.getUint32(ctl + 36, true);
const hb = dv.getUint32(ctl + 44, true);
let cur = hb, leaked = 0, freed = 0;
while (cur + 8 <= hp) {
  const sz = dv.getUint32(cur, true);
  const magic = dv.getUint32(cur + 4, true);
  if (sz < 16 || cur + sz > hp) {
    console.error("FAIL (" + mode + "/" + rtLabel + "): corrupt heap block at", cur, "sz=", sz);
    process.exit(1);
  }
  if (magic === 0x50494f4e) {
    const flags = cur + 24 <= hp ? dv.getUint16(cur + 22, true) : 0;
    if ((flags & 2) === 0) leaked++;
  } else if (magic === 0x46524545) {
    freed++;
  }
  cur += sz;
}
if (leaked !== 0) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p46a leaked=" + leaked + " (freed=" + freed + ")");
  process.exit(1);
}
console.log("  p46a (" + mode + "/" + rtLabel + "): " + out + " freed=" + freed + " leaked=0 OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "=== P47-A: Tagged Slot-Mask Zero-call_indirect Tail-Loop Destructor + Deep List + Tree + Multi-Slot (Node + Web leaked=0) ==="
cat > "$TMP_DIR/p47a_slot_mask_drop.pion" <<'EOF'
struct TreeNode {
  left : Option[TreeNode]
  right : Option[TreeNode]
}

struct ListNode {
  item_val : Int64
  next : Option[ListNode]
}

struct MultiSlot {
  a : Int64
  s1 : String
  b : Int64
  s2 : String
  next : Option[MultiSlot]
}

fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

fn make_tree(depth : Int) -> TreeNode {
  if depth == 0 {
    TreeNode::{ left: None, right: None }
  } else {
    TreeNode::{ left: Some(make_tree(depth - 1)), right: Some(make_tree(depth - 1)) }
  }
}

fn check_tree(n : TreeNode) -> Int {
  match n.left {
    Some(l) => match n.right {
      Some(r) => 1 + check_tree(l) + check_tree(r)
      None => 1 + check_tree(l)
    }
    None => 1
  }
}

fn build_deep_list(len : Int) -> Option[ListNode] {
  let mut cur : Option[ListNode] = None
  let mut i = 0
  while i < len {
    cur = Some(ListNode::{ item_val: i.to_int64(), next: cur })
    i = i + 1
  }
  cur
}

fn build_multi_chain(len : Int) -> Option[MultiSlot] {
  let mut cur : Option[MultiSlot] = None
  let mut i = 0
  while i < len {
    cur = Some(MultiSlot::{
      a: i.to_int64(),
      s1: "p_" + i.to_string(),
      b: (i * 3).to_int64(),
      s2: "q_" + i.to_string(),
      next: cur,
    })
    i = i + 1
  }
  cur
}

pub fn main(world : World) -> Int {
  // 1. Binary tree (depth=12 -> 8191 nodes, mixed internal + zero-drop leaf)
  let t = make_tree(12)
  let tc = check_tree(t)
  must(tc == 8191, "tree check")

  // 2. Deep singly-linked list (100_000 nodes -> would overflow Wasm call stack if not tail-looped!)
  let lst = build_deep_list(100000)
  let mut head_v : Int64 = -1L
  match lst {
    Some(n) => head_v = n.item_val
    None => ()
  }
  must(head_v == 99999L, "deep list head")

  // 3. Multi-slot struct chain (non-contiguous pointer slots + leaf strings + tail-loop)
  let mc = build_multi_chain(500)
  let mut mc_ok = false
  match mc {
    Some(m) => mc_ok = m.s1 == "p_499" && m.s2 == "q_499"
    None => ()
  }
  must(mc_ok, "multi-slot chain")

  io_println(world, "p47a_ok:" + tc.to_string() + ":" + head_v.to_string())
  0
}
EOF
P47A_REL_WASM="$TMP_DIR/p47a_rel.wasm"
P47A_DEV_WASM="$TMP_DIR/p47a_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$P47A_REL_WASM" "$TMP_DIR/p47a_slot_mask_drop.pion"
"$PIONC" build --target wasm32 -o "$P47A_DEV_WASM" "$TMP_DIR/p47a_slot_mask_drop.pion"
for mode_wasm in "release:$P47A_REL_WASM" "dev:$P47A_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p47a failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || out !== "p47a_ok:8191:99999") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p47a bad output: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const dv = new DataView(instance.exports.memory.buffer);
const ctl = instance.exports.__pion_slab_ctl.value >>> 0;
const hp = dv.getUint32(ctl + 36, true);
const hb = dv.getUint32(ctl + 44, true);
let cur = hb, leaked = 0, freed = 0;
while (cur + 8 <= hp) {
  const sz = dv.getUint32(cur, true);
  const magic = dv.getUint32(cur + 4, true);
  if (sz < 16 || cur + sz > hp) {
    console.error("FAIL (" + mode + "/" + rtLabel + "): corrupt heap block at", cur, "sz=", sz);
    process.exit(1);
  }
  if (magic === 0x50494f4e) {
    const flags = cur + 24 <= hp ? dv.getUint16(cur + 22, true) : 0;
    if ((flags & 2) === 0) leaked++;
  } else if (magic === 0x46524545) {
    freed++;
  }
  cur += sz;
}
if (leaked !== 0) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p47a leaked=" + leaked + " (freed=" + freed + ")");
  process.exit(1);
}
console.log("  p47a (" + mode + "/" + rtLabel + "): " + out + " freed=" + freed + " leaked=0 OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "=== P48-A Outlined Nested Loop with hlt Trap Block (Normal + OOB Trap) ==="
cat > "$TMP_DIR/p48a_outline_hlt_ok.pion" <<'EOF'
fn run_nested(limit : Int) -> Int {
  let a = Array::make(16, 0)
  let mut k = 0
  while k < 16 {
    a[k] = k + 1
    k = k + 1
  }
  let mut total = 0
  let mut outer = 0
  while outer < 6 {
    let mut mid = 0
    while mid < limit {
      let mut inner = 0
      let mut acc = 0
      while inner < 4 {
        let idx = (mid + inner) % 16
        acc = acc + a[idx]
        inner = inner + 1
      }
      // Dynamic index that passes when limit <= 16 and traps when limit > 16
      total = total + a[mid] + acc
      mid = mid + 1
    }
    outer = outer + 1
  }
  total
}

pub fn main(world : World) -> Int {
  let r = run_nested(12)
  io_println(world, "p48a_ok:" + r.to_string())
  0
}
EOF
cat > "$TMP_DIR/p48a_outline_hlt_trap.pion" <<'EOF'
fn run_nested(limit : Int) -> Int {
  let a = Array::make(16, 0)
  let mut k = 0
  while k < 16 {
    a[k] = k + 1
    k = k + 1
  }
  let mut total = 0
  let mut outer = 0
  while outer < 6 {
    let mut mid = 0
    while mid < limit {
      let mut inner = 0
      let mut acc = 0
      while inner < 4 {
        let idx = (mid + inner) % 16
        acc = acc + a[idx]
        inner = inner + 1
      }
      // Dynamic index that traps when mid == 16
      total = total + a[mid] + acc
      mid = mid + 1
    }
    outer = outer + 1
  }
  total
}

pub fn main(world : World) -> Int {
  let r = run_nested(20)
  io_println(world, "p48a_should_not_reach:" + r.to_string())
  0
}
EOF
P48A_OK_WASM="$TMP_DIR/p48a_ok.wasm"
P48A_TRAP_WASM="$TMP_DIR/p48a_trap.wasm"
"$PIONC" build --release --target wasm32 -o "$P48A_OK_WASM" "$TMP_DIR/p48a_outline_hlt_ok.pion"
"$PIONC" build --release --target wasm32 -o "$P48A_TRAP_WASM" "$TMP_DIR/p48a_outline_hlt_trap.pion"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const okPath = process.argv[1];
const trapPath = process.argv[2];
const rtPath = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

// 1. Normal path
const okBytes = fs.readFileSync(okPath);
if (!WebAssembly.validate(okBytes)) {
  console.error("FAIL (" + rtLabel + "): p48a_ok failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt1 = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance: inst1 } = await WebAssembly.instantiate(okBytes, rt1.imports);
rt1.bindExports(inst1.exports);
const rc1 = inst1.exports.main(0, 0n);
const out1 = lines.join("").trim();
// Expected: mid in 0..11, a[mid]=mid+1 (sum=78); acc(mid)=sum_{j=0..3} ((mid+j)%16 + 1) => total_acc=384 => (78+384)*6 = 2772
if ((rc1 | 0) !== 0 || out1 !== "p48a_ok:2772") {
  console.error("FAIL (" + rtLabel + "): p48a_ok bad output: rc=" + rc1 + " out=" + JSON.stringify(out1));
  process.exit(1);
}

// 2. OOB trap path inside outlined loop
const trapBytes = fs.readFileSync(trapPath);
if (!WebAssembly.validate(trapBytes)) {
  console.error("FAIL (" + rtLabel + "): p48a_trap failed WebAssembly.validate()");
  process.exit(1);
}
let trapped = false;
let trapMsg = "";
const rt2 = createPionRuntime({
  print: () => {},
  println: () => {},
});
const { instance: inst2 } = await WebAssembly.instantiate(trapBytes, rt2.imports);
rt2.bindExports(inst2.exports);
try {
  inst2.exports.main(0, 0n);
} catch (e) {
  trapped = true;
  trapMsg = String(e && e.message ? e.message : e);
}
if (!trapped) {
  console.error("FAIL (" + rtLabel + "): p48a_trap did NOT trap on OOB inside outlined loop!");
  process.exit(1);
}
console.log("  p48a (" + rtLabel + "): " + out1 + " + OOB trap OK (" + trapMsg.slice(0, 60) + ")");
' "$P48A_OK_WASM" "$P48A_TRAP_WASM" "$rt_path"
done

echo "=== P49-A Flat-Array, Cap0-Push, Short-Slice, StrBuf-Slice & 64-bit Seeded Hash Consistency ==="
cat > "$TMP_DIR/p49a_fast_paths.pion" <<'EOF'
struct FlatPair {
  label : String
  a : Int
  b : Int
}

fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

fn make_key(n : Int) -> String {
  let sb = StringBuilder::with_capacity(n + 4)
  let mut i = 0
  while i < n {
    let ch = 97 + ((i * 7 + n * 3) % 26)
    sb.write_byte(ch.to_byte())
    i = i + 1
  }
  sb.to_string()
}

pub fn main(world : World) -> Int {
  // 1. Array[FlatPair]::with_capacity(5) (flags > 2 pure-Wasm slab alloc + drop)
  let mut flat_sum = 0
  let mut iter = 0
  while iter < 100 {
    let fields : Array[FlatPair] = Array::with_capacity(5)
    fields.push(FlatPair::{ label: "k" + iter.to_string(), a: iter, b: iter * 2 })
    fields.push(FlatPair::{ label: "v" + iter.to_string(), a: iter + 1, b: iter * 3 })
    flat_sum = flat_sum + fields[0].a + fields[1].b + fields[0].label.length()
    iter = iter + 1
  }

  // 2. [].push(...) (cap == 0 pure-Wasm initial slab alloc for scalar, obj, compact byte)
  let mut empty_sum = 0
  let mut j = 0
  while j < 50 {
    let ai : Array[Int] = []
    let mut k = 0
    while k < 12 {
      ai.push(j + k)
      k = k + 1
    }
    let as_arr : Array[String] = []
    as_arr.push("s" + j.to_string())
    as_arr.push("t" + j.to_string())
    let ab : Array[Byte] = []
    ab.push((j % 251).to_byte())
    ab.push(((j + 7) % 251).to_byte())
    empty_sum = empty_sum + ai[0] + ai[11] + as_arr[1].length() + ab[0].to_int()
    j = j + 1
  }

  // 3. str.slice(a, b) for lengths 0..20 + clamping
  let src = "0123456789abcdefghijklmno"
  let expect_prefix = "23456789abcdefghijklmno"
  let mut slice_sum = 0
  let mut sl = 0
  while sl <= 20 {
    let sub = src.slice(2, 2 + sl)
    must(sub.length() == sl, "slice len")
    must(expect_prefix.starts_with(sub), "slice content")
    slice_sum = slice_sum + sub.length()
    sl = sl + 1
  }
  must(src.slice(-5, 3) == "012", "slice clamp neg")
  must(src.slice(22, 100) == "mno", "slice clamp end")
  must(src.slice(10, 5) == "", "slice empty")

  // 4. sb.write_substring + write_string + write_string(int.to_string()) (short 0..16B + >16B + grow)
  let sb = StringBuilder::with_capacity(8)
  sb.write_substring(src, 0, 0)
  sb.write_substring(src, 0, 1)
  sb.write_substring(src, 1, 3)
  sb.write_substring(src, 3, 6)
  sb.write_substring(src, 6, 10)
  sb.write_substring(src, 10, 18)
  sb.write_substring(src, 18, 25)
  sb.write_string(":")
  sb.write_string((-1234567890).to_string())
  let built = sb.to_string()
  must(built == "0123456789abcdefghijklmno:-1234567890", "sb build mismatch: " + built)

  // 5. Cross-Wasm/JS 64-bit seeded hash consistency over lengths 0,1,2,3,4,5,6,7,8,9,15,16,17,31,32,33,64 + mapGrow + remove
  let m : Map[String, Int] = Map::new()
  let lens : Array[Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 31, 32, 33, 64]
  let mut li = 0
  while li < lens.length() {
    let k = make_key(lens[li])
    m.set(k, lens[li] * 100 + 7)
    li = li + 1
  }
  // Force multiple JS mapGrow rehashes
  let mut g = 0
  while g < 60 {
    m.set("grow_key_" + g.to_string(), g * 13 + 1)
    g = g + 1
  }
  // Verify every length key survived JS mapGrow and matches Wasm map_find/map_get
  let mut map_sum = 0
  li = 0
  while li < lens.length() {
    let k = make_key(lens[li])
    must(m.contains(k), "m missing len key")
    match m.get(k) {
      Some(v) => {
        must(v == lens[li] * 100 + 7, "m val mismatch")
        map_sum = map_sum + v
      }
      None => { must(false, "m get none") }
    }
    li = li + 1
  }
  // Remove & re-insert via JS/Wasm
  let k7 = make_key(7)
  let k16 = make_key(16)
  m.remove(k7)
  m.remove(k16)
  must(!m.contains(k7) && !m.contains(k16), "m remove failed")
  m.set(k7, 777)
  must(m.contains(k7) && m[k7] == 777, "m reinsert failed")

  io_println(world, "p49a_ok:" + flat_sum.to_string() + ":" + empty_sum.to_string() + ":" + slice_sum.to_string() + ":" + map_sum.to_string())
  0
}
EOF
P49A_REL_WASM="$TMP_DIR/p49a_rel.wasm"
P49A_DEV_WASM="$TMP_DIR/p49a_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$P49A_REL_WASM" "$TMP_DIR/p49a_fast_paths.pion"
"$PIONC" build --target wasm32 -o "$P49A_DEV_WASM" "$TMP_DIR/p49a_fast_paths.pion"
for mode_wasm in "release:$P49A_REL_WASM" "dev:$P49A_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
PION_HASH_SEED=0x123456789abcdef0 node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p49a failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

// Verify slabCtl+64 seed was initialized (for Node rt, must equal PION_HASH_SEED)
const dv = new DataView(instance.exports.memory.buffer);
const ctl = instance.exports.__pion_slab_ctl.value >>> 0;
const seedVal = dv.getBigUint64(ctl + 64, true);
if (rtLabel === "pion_wasm_rt.mjs" && seedVal !== 0x123456789abcdef0n) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): PION_HASH_SEED mismatch:", seedVal.toString(16));
  process.exit(1);
}

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || !out.startsWith("p49a_ok:")) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p49a bad output: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
// Heap leak check (re-read buffer in case memory grew)
const dv2 = new DataView(instance.exports.memory.buffer);
const hp = dv2.getUint32(ctl + 36, true);
const hb = dv2.getUint32(ctl + 44, true);
let cur = hb, leaked = 0;
while (cur + 8 <= hp) {
  const sz = dv2.getUint32(cur, true);
  const magic = dv2.getUint32(cur + 4, true);
  if (sz < 16 || cur + sz > hp) {
    console.error("FAIL (" + mode + "/" + rtLabel + "): corrupt heap block at", cur, "sz=", sz);
    process.exit(1);
  }
  if (magic === 0x50494f4e) {
    const flags = cur + 24 <= hp ? dv2.getUint16(cur + 22, true) : 0;
    if ((flags & 2) === 0) leaked++;
  }
  cur += sz;
}
if (leaked !== 0) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p49a leaked=" + leaked);
  process.exit(1);
}
console.log("  p49a (" + mode + "/" + rtLabel + "): " + out + " seed=0x" + seedVal.toString(16) + " leaked=0 OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "=== P50-A 2-Slot Fast Tail-Loop (100k Left/Right Skewed Trees + Leaf Inline Recycle) + sz=40 Struct Slab ==="
cat > "$TMP_DIR/p50a_2slot_slab.pion" <<'EOF'
struct BinNode {
  left : Option[BinNode]
  right : Option[BinNode]
}

struct Rec40 {
  id : Int
  name : String
  active : Bool
  score : Int
  tag : String
}

fn make_tree(d : Int) -> BinNode {
  if d == 0 {
    BinNode::{ left: None, right: None }
  } else {
    BinNode::{ left: Some(make_tree(d - 1)), right: Some(make_tree(d - 1)) }
  }
}

fn count_tree(n : BinNode) -> Int {
  let l = match n.left {
    Some(x) => count_tree(x)
    None => 0
  }
  let r = match n.right {
    Some(x) => count_tree(x)
    None => 0
  }
  1 + l + r
}

fn test_skewed_left(n : Int) -> Int {
  let mut cur : Option[BinNode] = None
  let mut i = 0
  while i < n {
    cur = Some(BinNode::{ left: cur, right: None })
    i = i + 1
  }
  match cur {
    Some(_) => n
    None => 0
  }
}

fn test_skewed_right(n : Int) -> Int {
  let mut cur : Option[BinNode] = None
  let mut i = 0
  while i < n {
    cur = Some(BinNode::{ left: None, right: cur })
    i = i + 1
  }
  match cur {
    Some(_) => n
    None => 0
  }
}

fn test_rec40(n : Int) -> Int {
  let mut sum = 0
  let mut i = 0
  while i < n {
    let r = Rec40::{
      id: i,
      name: "r" + i.to_string(),
      active: (i % 2) == 0,
      score: i * 3,
      tag: "t" + (i % 10).to_string(),
    }
    sum = sum + r.id + r.score + r.name.length() + r.tag.length()
    i = i + 1
  }
  sum
}

pub fn main(world : World) -> Int {
  let t = make_tree(12)
  let tc = count_tree(t)
  let sl = test_skewed_left(100000)
  let sr = test_skewed_right(100000)
  let rs = test_rec40(2000)
  io_println(world, "p50a_ok:" + tc.to_string() + ":" + sl.to_string() + ":" + sr.to_string() + ":" + rs.to_string())
  0
}
EOF
P50A_REL_WASM="$TMP_DIR/p50a_rel.wasm"
P50A_DEV_WASM="$TMP_DIR/p50a_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$P50A_REL_WASM" "$TMP_DIR/p50a_2slot_slab.pion"
"$PIONC" build --target wasm32 -o "$P50A_DEV_WASM" "$TMP_DIR/p50a_2slot_slab.pion"
for mode_wasm in "release:$P50A_REL_WASM" "dev:$P50A_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p50a failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || !out.startsWith("p50a_ok:8191:100000:100000:")) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p50a bad output: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const dv = new DataView(instance.exports.memory.buffer);
const ctl = instance.exports.__pion_slab_ctl.value >>> 0;
const hp = dv.getUint32(ctl + 36, true);
const hb = dv.getUint32(ctl + 44, true);
let cur = hb, leaked = 0, freed = 0;
while (cur + 8 <= hp) {
  const sz = dv.getUint32(cur, true);
  const magic = dv.getUint32(cur + 4, true);
  if (sz < 16 || cur + sz > hp) {
    console.error("FAIL (" + mode + "/" + rtLabel + "): corrupt heap block at", cur, "sz=", sz);
    process.exit(1);
  }
  if (magic === 0x50494f4e) {
    const flags = cur + 24 <= hp ? dv.getUint16(cur + 22, true) : 0;
    if ((flags & 2) === 0) leaked++;
  } else if (magic === 0x46524545) {
    freed++;
  }
  cur += sz;
}
if (leaked !== 0) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p50a leaked=" + leaked + " (freed=" + freed + ")");
  process.exit(1);
}
console.log("  p50a (" + mode + "/" + rtLabel + "): " + out + " freed=" + freed + " leaked=0 OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "=== P51-A Regression: Chunked SWAR str.split + Inline map_hash/str_eq_fast + Inline Bump alloc_uninit + Entry non_promoted_allocs ==="
cat > "$TMP_DIR/p51a_wasm_opt.pion" <<'EOF'
struct P51Box {
  a : Int64
  b : Int64
  c : Int64
}

fn nested_entry_struct(n : Int) -> Int64 {
  let mut st = P51Box::{ a: 1L, b: 2L, c: 3L }
  let mut acc : Int64 = 0L
  let mut i = 0
  while i < n {
    let mut j = 0
    while j < 10 {
      acc = acc + st.a + st.b + st.c + (i + j).to_int64()
      j = j + 1
    }
    st = P51Box::{ a: st.a + 1L, b: st.b, c: st.c }
    i = i + 1
  }
  acc
}

pub fn main(world : World) -> Int {
  // 1. Multi-chunk (> 10KB, > 2x 4096B chunks) str.split(" ") with adjacent 0x01/0x20/0x21 bytes
  let sb = StringBuilder()
  let mut i = 0
  while i < 2000 {
    if i > 0 { sb.write_string(" ") }
    if i % 17 == 0 {
      sb.write_string("!") // 0x21 adjacent to space 0x20 (exercises borrow-free SWAR)
    } else if i % 13 == 0 {
      sb.write_string("") // consecutive spaces
    } else {
      sb.write_string("w" + (i % 97).to_string())
    }
    i = i + 1
  }
  let big = sb.to_string()
  let parts = big.split(" ")
  let mut empty_cnt = 0
  let mut bang_cnt = 0
  let mut pi = 0
  while pi < parts.length() {
    if parts[pi] == "" { empty_cnt = empty_cnt + 1 }
    if parts[pi] == "!" { bang_cnt = bang_cnt + 1 }
    pi = pi + 1
  }

  // 2. Map[String, Int64] across key lengths 0..16 with fresh-pointer get+set (map_hint + str_eq_fast)
  let m : Map[String, Int64] = Map([])
  let mut mi = 0
  while mi < parts.length() {
    let k = parts[mi]
    let cur = match m.get(k) { Some(v) => v; None => 0L }
    m.set(k, cur + 1L)
    mi = mi + 1
  }
  let long_keys = ["", "a", "ab", "abc", "abcd", "abcde", "abcdef", "abcdefg", "abcdefgh", "abcdefghijkl", "0123456789abcdef"]
  let mut li = 0
  while li < long_keys.length() {
    let lk = long_keys[li]
    m.set(lk, (li + 100).to_int64())
    li = li + 1
  }
  let mut long_sum : Int64 = 0L
  li = 0
  while li < long_keys.length() {
    let fresh = (long_keys[li] + "_").slice(0, long_keys[li].length())
    let v = match m.get(fresh) { Some(x) => x; None => -1L }
    m.set(fresh, v + 1L)
    long_sum = long_sum + (match m.get(fresh) { Some(x) => x; None => -1L })
    li = li + 1
  }

  // 3. Inline bump-pointer alloc_uninit (> 5000 live allocations across cls 0..3) + nested entry struct
  let boxes : Array[P51Box] = Array::with_capacity(5000)
  let mut bi = 0
  while bi < 5000 {
    boxes.push(P51Box::{ a: bi.to_int64(), b: (bi * 2).to_int64(), c: (bi * 3).to_int64() })
    bi = bi + 1
  }
  let bsum = boxes[4999].a + boxes[4999].b + boxes[4999].c
  let nsum = nested_entry_struct(50)

  io_println(world, "p51a_ok:" + parts.length().to_string() + ":" + empty_cnt.to_string() + ":" + bang_cnt.to_string() + ":" + long_sum.to_string() + ":" + bsum.to_string() + ":" + nsum.to_string())
  0
}
EOF
P51A_REL_WASM="$TMP_DIR/p51a_rel.wasm"
P51A_DEV_WASM="$TMP_DIR/p51a_dev.wasm"
"$PIONC" build --release --target wasm32 -o "$P51A_REL_WASM" "$TMP_DIR/p51a_wasm_opt.pion"
"$PIONC" build --target wasm32 -o "$P51A_DEV_WASM" "$TMP_DIR/p51a_wasm_opt.pion"
for mode_wasm in "release:$P51A_REL_WASM" "dev:$P51A_DEV_WASM"; do
mode="${mode_wasm%%:*}"
wasm_f="${mode_wasm#*:}"
for rt_path in "$PION_WASM_RT" "$PION_WASM_RT_WEB"; do
node --input-type=module -e '
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const wasmPath = process.argv[1];
const rtPath = process.argv[2];
const mode = process.argv[3];
const rtLabel = path.basename(rtPath);
const { createPionRuntime } = await import(pathToFileURL(rtPath).href);

const bytes = fs.readFileSync(wasmPath);
if (!WebAssembly.validate(bytes)) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p51a failed WebAssembly.validate()");
  process.exit(1);
}
const lines = [];
const rt = createPionRuntime({
  print: (s) => lines.push(s),
  println: (s) => lines.push(s + "\n"),
});
const { instance } = await WebAssembly.instantiate(bytes, rt.imports);
rt.bindExports(instance.exports);

const rc = instance.exports.main(0, 0n);
const out = lines.join("").trim();
if ((rc | 0) !== 0 || out !== "p51a_ok:2000:144:118:1166:29994:29750") {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p51a bad output: rc=" + rc + " out=" + JSON.stringify(out));
  process.exit(1);
}
const dv = new DataView(instance.exports.memory.buffer);
const ctl = instance.exports.__pion_slab_ctl.value >>> 0;
const hp = dv.getUint32(ctl + 36, true);
const hb = dv.getUint32(ctl + 44, true);
let cur = hb, leaked = 0, freed = 0;
while (cur + 8 <= hp) {
  const sz = dv.getUint32(cur, true);
  const magic = dv.getUint32(cur + 4, true);
  if (sz < 16 || cur + sz > hp) {
    console.error("FAIL (" + mode + "/" + rtLabel + "): corrupt heap block at", cur, "sz=", sz);
    process.exit(1);
  }
  if (magic === 0x50494f4e) {
    const flags = cur + 24 <= hp ? dv.getUint16(cur + 22, true) : 0;
    if ((flags & 2) === 0) leaked++;
  } else if (magic === 0x46524545) {
    freed++;
  }
  cur += sz;
}
if (leaked !== 0) {
  console.error("FAIL (" + mode + "/" + rtLabel + "): p51a leaked=" + leaked + " (freed=" + freed + ")");
  process.exit(1);
}
console.log("  p51a (" + mode + "/" + rtLabel + "): " + out + " freed=" + freed + " leaked=0 OK");
' "$wasm_f" "$rt_path" "$mode"
done
done

echo "p29c_wasm32 E2E: OK"
