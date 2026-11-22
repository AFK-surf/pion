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

echo "p29c_wasm32 E2E: OK"
