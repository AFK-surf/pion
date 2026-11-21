#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

# 1. Main runtime E2E covering Bug #9, #10, #11 (allowed forms), #12, #13
cat > "$TMP_DIR/p30a_main.pion" <<'EOF'
#derive(Eq)
struct Pair {
  k : String
  v : Int
}

struct OptBox {
  d : Option[Double]
  s : Option[String]
}

fn OptBox::get_d(self : OptBox) -> Option[Double] {
  self.d
}

fn OptBox::get_s(self : OptBox) -> Option[String] {
  self.s
}

fn has_item[T](arr : Array[T], x : T) -> Bool {
  arr.contains(x)
}

fn pick_d(auto : Bool, a : Option[Double], b : Option[Double]) -> Double {
  match ((if auto { None } else { a }), b) {
    (Some(x), _) => x
    (None, Some(y)) => y
    _ => 0.0
  }
}

fn pick_s(auto : Bool, a : Option[String], b : Option[String]) -> String {
  match ((if auto { None } else { a }), b) {
    (Some(x), _) => x
    (None, Some(y)) => y
    _ => "none"
  }
}

fn pick_d_method(auto : Bool, box : OptBox, b : Option[Double]) -> Double {
  match ((if auto { None } else { box.get_d() }), b) {
    (Some(x), _) => x
    (None, Some(y)) => y
    _ => 0.0
  }
}

fn pick_s_method(auto : Bool, box : OptBox, b : Option[String]) -> String {
  match ((if auto { None } else { box.get_s() }), b) {
    (Some(x), _) => x
    (None, Some(y)) => y
    _ => "none"
  }
}

struct BoxF {
  v : Float
}

fn take_f(x : Float) -> Float {
  x
}

fn ret_f() -> Float {
  1.0
}

struct Counter {
  mut n : Int
}

fn run_cb(f : () -> Unit) -> Unit {
  f()
}

pub fn main(world : World) -> Int {
  // Bug #9: Array[T]::contains & FixedArray[T]::contains
  let ai : Array[Int] = [1, 2, 3]
  debug_assert(ai.contains(2) && !ai.contains(9), "arr int contains")
  debug_assert(ai.contains(2).to_string() == "true", "arr int contains to_string true")
  debug_assert(ai.contains(9).to_string() == "false", "arr int contains to_string false")

  let as_ : Array[String] = ["alpha", "beta"]
  let needle = "al" + "pha"
  debug_assert(as_.contains("alpha") && as_.contains(needle) && !as_.contains("gamma"), "arr str contains")
  debug_assert(["x", "y"].contains("y") && !["x", "y"].contains("z"), "temp arr str contains")

  let af : Array[Float] = [1.0, 2.5]
  debug_assert(af.contains(2.5) && !af.contains(3.0), "arr float contains")

  let ad : Array[Double] = [1.25, -4.5]
  debug_assert(ad.contains(-4.5) && !ad.contains(0.0), "arr double contains")

  let fi : FixedArray[Int] = [10, 20, 30]
  debug_assert(fi.contains(20) && !fi.contains(99), "fixed int contains")
  let fs : FixedArray[String] = ["red", "blue"]
  debug_assert(fs.contains("blue") && !fs.contains("green"), "fixed str contains")

  let ps : Array[Pair] = [Pair::{ k: "a", v: 1 }, Pair::{ k: "b", v: 2 }]
  debug_assert(ps.contains(Pair::{ k: "b", v: 2 }), "arr derive Eq contains true")
  debug_assert(!ps.contains(Pair::{ k: "b", v: 3 }), "arr derive Eq contains false")

  debug_assert(has_item(as_, "beta") && !has_item(as_, "nope"), "generic arr contains str")
  debug_assert(has_item(ps, Pair::{ k: "a", v: 1 }), "generic arr contains struct")

  let empty : Array[Int] = []
  debug_assert(!empty.contains(0), "empty arr contains")

  // Bug #10: tuple containing Option via if expression (boxed Option[Double] & niche Option[String])
  debug_assert(pick_d(false, Some(10.0), None) == 10.0, "pick_d false Some None")
  debug_assert(pick_d(true, Some(10.0), Some(20.0)) == 20.0, "pick_d true Some Some")
  debug_assert(pick_d(true, Some(10.0), None) == 0.0, "pick_d true Some None")
  debug_assert(pick_d(false, None, Some(5.5)) == 5.5, "pick_d false None Some")

  debug_assert(pick_s(false, Some("hi"), None) == "hi", "pick_s false Some None")
  debug_assert(pick_s(true, Some("hi"), Some("yo")) == "yo", "pick_s true Some Some")
  debug_assert(pick_s(true, Some("hi"), None) == "none", "pick_s true Some None")
  debug_assert(pick_s(false, None, Some("ok")) == "ok", "pick_s false None Some")

  let ob = OptBox::{ d: Some(42.5), s: Some("box") }
  debug_assert(pick_d_method(false, ob, None) == 42.5, "pick_d_method false")
  debug_assert(pick_d_method(true, ob, Some(7.5)) == 7.5, "pick_d_method true")
  debug_assert(pick_s_method(false, ob, None) == "box", "pick_s_method false")
  debug_assert(pick_s_method(true, ob, Some("alt")) == "alt", "pick_s_method true")

  // Feedback #11: shared mutable state via mut struct / single-element Array
  let c = Counter::{ n: 0 }
  let flag : Array[Bool] = [false]
  run_cb(fn() -> Unit {
    let mut step = 3
    step += 4
    c.n = step
    flag[0] = true
  })
  debug_assert(c.n == 7 && flag[0], "closure mut struct & array")

  // Bug #12: bare float literals in Float expected-type contexts + 2.0 * f
  let f1 : Float = 1.0
  let f2 : Float = -2.5
  let f3 = take_f(1.0)
  let bf = BoxF::{ v: 1.0 }
  let f4 = ret_f()
  let f5 : Float = 2.0 * f1
  debug_assert(f1 == 1.0f && f2 == -2.5f, "float bare lit let")
  debug_assert(f3 == 1.0f && bf.v == 1.0f && f4 == 1.0f, "float bare lit call/struct/ret")
  debug_assert(f5 == 2.0f, "float 2.0 * x")

  // Bug #13: \u{H...} Unicode escapes in string, interpolated string, and char literals
  let s_ff = "\u{0C}"
  let s_zh = "\u{4E2D}"
  let s_em = "\u{1F600}"
  debug_assert(s_ff.length() == 1 && s_ff.code_unit_at(0) == 12, "u0C string")
  debug_assert(s_zh == "中" && s_zh.length() == 3, "u4E2D string")
  debug_assert(s_em == "😀" && s_em.length() == 4, "u1F600 string")
  let n_val = 7
  let s_interp = "a\u{0C}\{n_val}\u{4E2D}"
  debug_assert(s_interp.length() == 6 && s_interp.code_unit_at(1) == 12, "u escape in interp")
  debug_assert('\u{0C}'.to_int() == 12, "char u0C")
  debug_assert('\u{4E2D}'.to_int() == 0x4E2D, "char u4E2D")
  debug_assert('\u{1F600}'.to_int() == 0x1F600, "char u1F600")

  io_println(world, "p30a_bugs9_to_13 ok")
  0
}
EOF

OUT=$("$PIONC" run "$TMP_DIR/p30a_main.pion")
echo "p30a_bugs9_to_13 native -> $OUT"
if [ "$OUT" != "p30a_bugs9_to_13 ok" ]; then
  echo "FAIL: p30a_bugs9_to_13 native output mismatch" >&2
  exit 1
fi

# 2. Negative compile-time checks (E_CAPTURE_MUT_ASSIGN, Double var -> Float)
cat > "$TMP_DIR/bad_mut_cap.pion" <<'EOF'
fn run_cb(f : () -> Unit) -> Unit {
  f()
}
pub fn main(world : World) -> Int {
  let _ = world
  let mut x = false
  run_cb(fn() -> Unit { x = true })
  if x { 1 } else { 0 }
}
EOF
BAD1=$("$PIONC" check --json "$TMP_DIR/bad_mut_cap.pion" || true)
if ! printf '%s' "$BAD1" | grep -q '"code":"E_CAPTURE_MUT_ASSIGN"'; then
  echo "FAIL: expected E_CAPTURE_MUT_ASSIGN, got: $BAD1" >&2
  exit 1
fi

cat > "$TMP_DIR/bad_double_to_float.pion" <<'EOF'
fn take_f(x : Float) -> Float { x }
pub fn main(world : World) -> Int {
  let _ = world
  let d : Double = 1.0
  let _ = take_f(d)
  0
}
EOF
BAD2=$("$PIONC" check --json "$TMP_DIR/bad_double_to_float.pion" || true)
if ! printf '%s' "$BAD2" | grep -q '"code":"E_TYPE_MISMATCH"'; then
  echo "FAIL: expected E_TYPE_MISMATCH for Double -> Float, got: $BAD2" >&2
  exit 1
fi
echo "p30a_bugs9_to_13 negative checks (E_CAPTURE_MUT_ASSIGN, Double->Float): OK"

# 3. ASan/LSan leak check (skip if host cc cannot link -fsanitize=address)
CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --emit-obj "$TMP_DIR/p30a_main.o" "$TMP_DIR/p30a_main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p30a_main.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p30a_asan"
  ASAN_OUT=$("$TMP_DIR/p30a_asan")
  echo "p30a_bugs9_to_13 ASan -> $ASAN_OUT"
  if [ "$ASAN_OUT" != "p30a_bugs9_to_13 ok" ]; then
    echo "FAIL: p30a_bugs9_to_13 ASan mismatch or leak" >&2
    exit 1
  fi
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p30a ASan check"
fi

# 4. Wasm32 check (when node is available)
if command -v node >/dev/null 2>&1; then
  WASM="$TMP_DIR/p30a_main.wasm"
  "$PIONC" build --target wasm32 -o "$WASM" "$TMP_DIR/p30a_main.pion"
  WASM_OUT=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$WASM")
  echo "p30a_bugs9_to_13 wasm32 -> $WASM_OUT"
  if [ "$WASM_OUT" != "p30a_bugs9_to_13 ok" ]; then
    echo "FAIL: p30a_bugs9_to_13 wasm32 output mismatch" >&2
    exit 1
  fi
fi

echo "p30a_bugs9_to_13: ALL PASSED"
