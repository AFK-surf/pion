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

echo "p29c_wasm32 E2E: OK"
