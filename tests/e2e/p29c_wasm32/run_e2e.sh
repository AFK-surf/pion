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
const liveStructs = allocStructs - freedStructs;
if (allocStructs <= 0 || liveStructs !== 0) {
  console.error("FAIL (" + rtLabel + "): TAG_STRUCT RC leak detected: alloc=" + allocStructs + " freed=" + freedStructs + " live=" + liveStructs);
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

console.log("  rc_read_leak (" + rtLabel + "): out=" + out + " mem=" + (memBytes / (1024 * 1024)).toFixed(2) + "MiB (<=16MiB) allocStructs=" + allocStructs + " liveStructs=" + liveStructs + " arr_get_rc=" + rcBefore + "->" + rcAfter + " OK");
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

echo "p29c_wasm32 E2E: OK"
