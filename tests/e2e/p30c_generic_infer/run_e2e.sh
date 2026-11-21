#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

cat > "$TMP_DIR/p30c_main.pion" <<'EOF'
trait ViewEq {
  fn veq(self : Self, other : Self) -> Bool
}

impl ViewEq for Bool {
  fn veq(self : Bool, other : Bool) -> Bool {
    self == other
  }
}

enum HoldRead {
  Stay
  Go(Int)
}

impl ViewEq for HoldRead {
  fn veq(self : HoldRead, other : HoldRead) -> Bool {
    match self {
      Stay =>
        match other {
          Stay => true
          Go(_) => false
        }
      Go(a) =>
        match other {
          Stay => false
          Go(b) => a == b
        }
    }
  }
}

struct View {
  flag : Bool
}

fn View::leaving(self : View) -> Bool {
  self.flag
}

fn View::reacts[T : ViewEq](self : View, read : () -> T, f : (T) -> Unit) -> Unit {
  let v = read()
  if v.veq(v) {
    f(v)
  }
}

fn View::reacts_any[T](self : View, read : () -> T, f : (T) -> Unit) -> Unit {
  let v = read()
  f(v)
}

fn my_map[T, U](xs : Array[T], f : (T) -> U) -> Array[U] {
  let out : Array[U] = []
  let mut i = 0
  while i < xs.length() {
    out.push(f(xs[i]))
    i += 1
  }
  out
}

fn outer_same_tparam[T](v : View, x : T, sink : (T) -> Unit) -> Unit {
  v.reacts_any(fn() { x }, fn(y) { sink(y) })
}

struct Sight[T] {
  item : T
}

struct ListKeys[K] {
  keys : Array[K]
}

struct SliceIds {
  off : Int
}

fn Sight::keyed[K](self : Sight[Int], ids : ListKeys[K], sl : SliceIds) -> Sight[K] {
  Sight::{ item: ids.keys[self.item + sl.off] }
}

struct ListPlace[K] {
  ids : ListKeys[K]
}

fn apply_sight[K](s : Sight[Int], f : (Sight[Int]) -> Sight[K]) -> Sight[K] {
  f(s)
}

fn ListPlace::on_sight[K](self : ListPlace[K], s : Sight[Int], sl : SliceIds) -> Sight[K] {
  let ids = self.ids
  apply_sight(s, fn(cur) { cur.keyed(ids, sl) })
}

fn find_opt_int(xs : Array[Int], target : Int) -> Option[Int] {
  let mut i = 0
  while i < xs.length() {
    if xs[i] == target {
      return Some(i)
    }
    i += 1
  }
  None
}

fn find_opt_str(xs : Array[String], target : String) -> Option[String] {
  let mut i = 0
  while i < xs.length() {
    if xs[i] == target {
      return Some(xs[i] + "!")
    }
    i += 1
  }
  None
}

fn take_opt_str(x : Option[String]) -> Int {
  match x {
    Some(s) => s.length()
    None => 7
  }
}

// Bug #18b single-pkg check (also covered under ASan/LSan + Wasm32):
// struct literal with `value: None` before `getter: g` inferring T = Payload
struct LocalState[T] {
  mut value : Option[T]
  getter : () -> T
}

struct LocalBoxed[T] {
  state : LocalState[T]
}

fn make_local_boxed[T](g : () -> T) -> LocalBoxed[T] {
  let st = LocalState::{ value: None, getter: g }
  LocalBoxed::{ state: st }
}

fn LocalBoxed::get[T](self : LocalBoxed[T]) -> T {
  match self.state.value {
    Some(v) => v
    None => {
      let f = self.state.getter
      let v = f()
      self.state.value = Some(v)
      v
    }
  }
}

fn LocalBoxed::untracked[T](self : LocalBoxed[T]) -> T {
  self.get()
}

struct LocalPayload {
  id : Int
  tag : String
}

struct CellI {
  mut v : Int
}

struct CellS {
  mut v : String
}

pub fn main(world : World) -> Int {
  // Bug #16a: View::reacts with Bool, HoldRead (tail & early-return), Tuple (Option[Int], Int)
  let v1 = View::{ flag: true }
  let v2 = View::{ flag: false }
  let acc = CellI::{ v: 0 }

  v1.reacts(fn() { v1.leaving() }, fn(leaving) {
    if leaving {
      acc.v += 1
    }
  })
  v2.reacts(fn() { v2.leaving() }, fn(leaving) {
    if !leaving {
      acc.v += 2
    }
  })
  v1.reacts(fn() {
    if v1.leaving() {
      return HoldRead::Stay
    }
    HoldRead::Go(10)
  }, fn(h) {
    match h {
      Stay => acc.v += 4
      Go(n) => acc.v += n
    }
  })
  v2.reacts(fn() {
    if v2.leaving() {
      return HoldRead::Stay
    } else {
      return HoldRead::Go(8)
    }
  }, fn(h) {
    match h {
      Stay => acc.v += 100
      Go(n) => acc.v += n
    }
  })
  v1.reacts_any(fn() { (Some(16), 32) }, fn(pair) {
    let (opt, n) = pair
    match opt {
      Some(k) => acc.v += k + n
      None => ()
    }
  })
  debug_assert(acc.v == 63, "bug16a reacts acc == 63")

  // Bug #16a: nested generic higher-order map
  let flags = my_map(my_map([1, 2, 3], fn(x) { x * 2 }), fn(y) { y >= 4 })
  debug_assert(!flags[0] && flags[1] && flags[2], "bug16a nested map")

  // Bug #16a: outer generic fn with same type parameter name `T`
  let got_str = CellS::{ v: "" }
  outer_same_tparam(v1, "hello" + "_t", fn(s) { got_str.v = s })
  debug_assert(got_str.v == "hello_t", "bug16a outer same T string")
  let got_int = CellI::{ v: 0 }
  outer_same_tparam(v1, 77, fn(n) { got_int.v = n })
  debug_assert(got_int.v == 77, "bug16a outer same T int")

  // Bug #16b: Sight[T] method Sight::keyed[K](self : Sight[Int], ...) called from ListPlace::on_sight[K]
  let lp_str = ListPlace::{
    ids: ListKeys::{ keys: ["k" + "0", "k" + "1", "k" + "2"] },
  }
  let res_str = lp_str.on_sight(Sight::{ item: 1 }, SliceIds::{ off: 1 })
  debug_assert(res_str.item == "k2", "bug16b Sight::keyed String")

  let lp_int = ListPlace::{ ids: ListKeys::{ keys: [100, 200, 300] } }
  let res_int = lp_int.on_sight(Sight::{ item: 0 }, SliceIds::{ off: 2 })
  debug_assert(res_int.item == 300, "bug16b Sight::keyed Int")

  // Bug #17: unannotated `let mut x = None` inferred via later assignment / call arg
  let order : Array[Int] = [10, 20, 30, 40]
  let mut before = None
  let mut p = 2
  while p >= 0 && before.is_none() {
    before = find_opt_int(order, order[p])
    p = p - 1
  }
  let before_next = match before {
    Some(i) => i + 1
    None => 0
  }
  debug_assert(before_next == 3, "bug17 Option[Int] match i + 1")

  let mut found_s = None
  found_s = find_opt_str(["aa", "bb"], "bb")
  let got_bb = match found_s {
    Some(s) => s
    None => ""
  }
  debug_assert(got_bb == "bb!", "bug17 Option[String] assign")

  let pass_none = None
  debug_assert(take_opt_str(pass_none) == 7, "bug17 let x = None; take_opt(x)")

  // Bug #18a + #18b single-pkg (native + ASan/LSan + Wasm32)
  let lb1 = make_local_boxed(fn() { LocalPayload::{ id: 42, tag: "o" + "k" } })
  let lp1 = lb1.untracked()
  debug_assert(lp1.id == 42 && lp1.tag == "ok", "bug18 local untracked first")
  let lb2 = make_local_boxed(fn() { LocalPayload::{ id: 42, tag: "o" + "k" } })
  let lp2a = lb2.get()
  let lp2b = lb2.untracked()
  debug_assert(lp2a.id == 42 && lp2b.id == 42 && lp2b.tag == "ok", "bug18 local get then untracked")
  let lb3 = make_local_boxed(fn() { LocalPayload::{ id: 42, tag: "o" + "k" } })
  let lp3a = lb3.untracked()
  let lp3b = lb3.get()
  debug_assert(lp3a.id == 42 && lp3b.id == 42 && lp3b.tag == "ok", "bug18 local untracked then get")

  io_println(world, "p30c_generic_infer ok")
  0
}
EOF

OUT=$("$PIONC" run "$TMP_DIR/p30c_main.pion")
echo "p30c_generic_infer native -> $OUT"
if [ "$OUT" != "p30c_generic_infer ok" ]; then
  echo "FAIL: p30c_generic_infer native output mismatch" >&2
  exit 1
fi

# ASan/LSan check (0 UAF / 0 leaks)
CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --emit-obj "$TMP_DIR/p30c_main.o" "$TMP_DIR/p30c_main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p30c_main.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p30c_asan"
  ASAN_OUT=$("$TMP_DIR/p30c_asan")
  echo "p30c_generic_infer ASan -> $ASAN_OUT"
  if [ "$ASAN_OUT" != "p30c_generic_infer ok" ]; then
    echo "FAIL: p30c_generic_infer ASan mismatch or leak" >&2
    exit 1
  fi
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p30c ASan check"
fi

# Wasm32 check (when node is available)
if command -v node >/dev/null 2>&1; then
  WASM="$TMP_DIR/p30c_main.wasm"
  "$PIONC" build --target wasm32 -o "$WASM" "$TMP_DIR/p30c_main.pion"
  WASM_OUT=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$WASM")
  echo "p30c_generic_infer wasm32 -> $WASM_OUT"
  if [ "$WASM_OUT" != "p30c_generic_infer ok" ]; then
    echo "FAIL: p30c_generic_infer wasm32 output mismatch" >&2
    exit 1
  fi
fi

# Bug #18a + #18b cross-package workspace E2E (native + Wasm32)
WS_DIR="$TMP_DIR/b18_ws"
mkdir -p "$WS_DIR/pkg_a/src" "$WS_DIR/pkg_b/src"

cat > "$WS_DIR/pkg_a/pion.toml" <<'EOF'
[package]
name = "pkg_a"
version = "0.1.0"
EOF

cat > "$WS_DIR/pkg_a/src/lib.pion" <<'EOF'
pub struct BoxState[T] {
  pub mut value : Option[T]
  pub getter : () -> T
}

pub struct Boxed[T] {
  state : BoxState[T]
}

pub fn make_boxed[T](g : () -> T) -> Boxed[T] {
  let st = BoxState::{ value: None, getter: g }
  Boxed::{ state: st }
}

pub fn Boxed::get[T](self : Boxed[T]) -> T {
  match self.state.value {
    Some(v) => v
    None => {
      let f = self.state.getter
      let v = f()
      self.state.value = Some(v)
      v
    }
  }
}

pub fn Boxed::untracked[T](self : Boxed[T]) -> T {
  self.get()
}
EOF

cat > "$WS_DIR/pkg_b/pion.toml" <<'EOF'
[package]
name = "pkg_b"
version = "0.1.0"

[dependencies]
pkg_a = { path = "../pkg_a" }
EOF

cat > "$WS_DIR/pkg_b/src/main.pion" <<'EOF'
import "pkg_a"

struct Payload {
  id : Int
  tag : String
}

pub fn main(world : World) -> Int {
  let b1 = pkg_a::make_boxed(fn() { Payload::{ id: 42, tag: "o" + "k" } })
  let p1 = b1.untracked()
  debug_assert(p1.id == 42 && p1.tag == "ok", "bug18 cross-pkg untracked first")

  let b2 = pkg_a::make_boxed(fn() { Payload::{ id: 42, tag: "o" + "k" } })
  let p2a = b2.get()
  let p2b = b2.untracked()
  debug_assert(p2a.id == 42 && p2a.tag == "ok", "bug18 cross-pkg get first")
  debug_assert(p2b.id == 42 && p2b.tag == "ok", "bug18 cross-pkg untracked after get")

  let b3 = pkg_a::make_boxed(fn() { Payload::{ id: 42, tag: "o" + "k" } })
  let p3a = b3.untracked()
  let p3b = b3.get()
  debug_assert(p3a.id == 42 && p3a.tag == "ok", "bug18 cross-pkg untracked before get")
  debug_assert(p3b.id == 42 && p3b.tag == "ok", "bug18 cross-pkg get after untracked")

  io_println(world, "p30c_bug18_cross_pkg ok")
  0
}
EOF

B18_OUT=$("$PIONC" run "$WS_DIR/pkg_b")
echo "p30c_bug18_cross_pkg native -> $B18_OUT"
if [ "$B18_OUT" != "p30c_bug18_cross_pkg ok" ]; then
  echo "FAIL: p30c_bug18_cross_pkg native output mismatch" >&2
  exit 1
fi

if command -v node >/dev/null 2>&1; then
  B18_WASM="$TMP_DIR/b18_cross.wasm"
  "$PIONC" build --target wasm32 -o "$B18_WASM" "$WS_DIR/pkg_b"
  B18_WASM_OUT=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$B18_WASM")
  echo "p30c_bug18_cross_pkg wasm32 -> $B18_WASM_OUT"
  if [ "$B18_WASM_OUT" != "p30c_bug18_cross_pkg ok" ]; then
    echo "FAIL: p30c_bug18_cross_pkg wasm32 output mismatch" >&2
    exit 1
  fi
fi

# Bug #19: 3-package chain (pkg_c -> pkg_b -> pkg_a) with alias import and all 5 default arg forms
B19_DIR="$TMP_DIR/b19_ws"
mkdir -p "$B19_DIR/pkg_a/src" "$B19_DIR/pkg_b/src" "$B19_DIR/pkg_c/src"

cat > "$B19_DIR/pkg_a/pion.toml" <<'EOF'
[package]
name = "pkg_a"
version = "0.1.0"
EOF

cat > "$B19_DIR/pkg_a/src/lib.pion" <<'EOF'
pub fn base_val() -> Double {
  12.5
}
EOF

cat > "$B19_DIR/pkg_b/pion.toml" <<'EOF'
[package]
name = "pkg_b"
version = "0.1.0"

[dependencies]
pkg_a = { path = "../pkg_a" }
EOF

cat > "$B19_DIR/pkg_b/src/lib.pion" <<'EOF'
import "pkg_a"

pub enum Side {
  Top
  Bottom
}

pub enum Pivot {
  Center
  At(Double, Double)
}

pub enum Along {
  Start
  Middle
  End
}

let flag_a : Int = 1
let flag_b : Int = 4

pub struct Widget {
  pub id : Int
}

pub fn make_val(
  side~ : Side = Bottom,
  about~ : Pivot = At(0.5, 0.5),
  along~ : Along = Along::Middle,
  mask~ : Int = flag_a | flag_b,
  bound~ : () -> Double = fn() { pkg_a::base_val() },
) -> Double {
  let s = match side {
    Top => 1.0
    Bottom => 2.0
  }
  let p = match about {
    Center => 0.0
    At(x, y) => x + y
  }
  let a = match along {
    Start => 10.0
    Middle => 20.0
    End => 30.0
  }
  s + p + a + mask.to_double() + bound()
}

pub fn Widget::score(
  self : Widget,
  side~ : Side = Bottom,
  about~ : Pivot = At(0.5, 0.5),
  along~ : Along = Along::Middle,
  mask~ : Int = flag_a | flag_b,
  bound~ : () -> Double = fn() { pkg_a::base_val() },
) -> Double {
  self.id.to_double() +
  make_val(side=side, about=about, along=along, mask=mask, bound=bound)
}
EOF

cat > "$B19_DIR/pkg_c/pion.toml" <<'EOF'
[package]
name = "pkg_c"
version = "0.1.0"

[dependencies]
pkg_b = { path = "../pkg_b" }
EOF

cat > "$B19_DIR/pkg_c/src/main.pion" <<'EOF'
import "pkg_b" as b

pub fn main(world : World) -> Int {
  // Expected: make_val() = 2.0 + 1.0 + 20.0 + 5.0 + 12.5 = 40.5
  let v1 = b::make_val()
  debug_assert(v1 == 40.5, "bug19 make_val default args")
  let w = b::Widget::{ id: 3 }
  let v2 = w.score()
  debug_assert(v2 == 43.5, "bug19 Widget::score default args")
  io_println(world, "p30c_bug19_defaults ok")
  0
}
EOF

B19_OUT=$("$PIONC" run "$B19_DIR/pkg_c")
echo "p30c_bug19_defaults native -> $B19_OUT"
if [ "$B19_OUT" != "p30c_bug19_defaults ok" ]; then
  echo "FAIL: p30c_bug19_defaults native output mismatch" >&2
  exit 1
fi

if command -v node >/dev/null 2>&1; then
  B19_WASM="$TMP_DIR/b19_defaults.wasm"
  "$PIONC" build --target wasm32 -o "$B19_WASM" "$B19_DIR/pkg_c"
  B19_WASM_OUT=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$B19_WASM")
  echo "p30c_bug19_defaults wasm32 -> $B19_WASM_OUT"
  if [ "$B19_WASM_OUT" != "p30c_bug19_defaults ok" ]; then
    echo "FAIL: p30c_bug19_defaults wasm32 output mismatch" >&2
    exit 1
  fi
fi

echo "p30c_generic_infer: ALL PASSED"
