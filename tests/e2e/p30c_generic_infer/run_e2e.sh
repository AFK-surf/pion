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

echo "p30c_generic_infer: ALL PASSED"
