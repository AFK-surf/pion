#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

IMAP_DIR="$TMP_DIR/intmap"
APP_DIR="$TMP_DIR/app"
CAS_DIR="$TMP_DIR/cas"
mkdir -p "$IMAP_DIR/src" "$APP_DIR/src" "$CAS_DIR"

# Upstream package: Bug #6 (private enum Slot[V], private IntMap::grow[V], private const STATE_EMPTY)
# plus cross-pkg #derive(Eq) NodeId and generic eq_test[T]
cat > "$IMAP_DIR/pion.toml" <<'EOF'
[package]
name = "intmap"
version = "0.1.0"
EOF

cat > "$IMAP_DIR/src/lib.pion" <<'EOF'
let STATE_EMPTY : Int = 0
let STATE_USED : Int = 1

enum Slot[V] {
  Vacant
  Filled(V)
}

pub struct IntMap[V] {
  mut keys : Array[Int]
  mut states : Array[Int]
  mut slots : Array[Slot[V]]
  mut len : Int
  mut cap : Int
}

#derive(Eq)
pub struct NodeId {
  pkg : String
  id : Int
}

pub fn IntMap::new[V]() -> IntMap[V] {
  let cap = 8
  let keys : Array[Int] = []
  let states : Array[Int] = []
  let slots : Array[Slot[V]] = []
  let mut i = 0
  while i < cap {
    keys.push(0)
    states.push(STATE_EMPTY)
    slots.push(Vacant)
    i = i + 1
  }
  IntMap::{ keys: keys, states: states, slots: slots, len: 0, cap: cap }
}

fn IntMap::grow[V](self : IntMap[V]) -> Unit {
  let old_cap = self.cap
  let old_keys = self.keys
  let old_states = self.states
  let old_slots = self.slots
  let new_cap = old_cap * 2
  let nk : Array[Int] = []
  let ns : Array[Int] = []
  let nv : Array[Slot[V]] = []
  let mut i = 0
  while i < new_cap {
    nk.push(0)
    ns.push(STATE_EMPTY)
    nv.push(Vacant)
    i = i + 1
  }
  self.keys = nk
  self.states = ns
  self.slots = nv
  self.cap = new_cap
  self.len = 0
  i = 0
  while i < old_cap {
    if old_states[i] == STATE_USED {
      match old_slots[i] {
        Filled(v) => self.set(old_keys[i], v)
        Vacant => ()
      }
    }
    i = i + 1
  }
}

pub fn IntMap::set[V](self : IntMap[V], key : Int, value : V) -> Unit {
  if (self.len + 1) * 10 >= self.cap * 7 {
    self.grow()
  }
  let mask = self.cap - 1
  let mut idx = key & mask
  while true {
    let st = self.states[idx]
    if st == STATE_EMPTY {
      self.keys[idx] = key
      self.states[idx] = STATE_USED
      self.slots[idx] = Filled(value)
      self.len = self.len + 1
      return
    }
    if self.keys[idx] == key {
      self.slots[idx] = Filled(value)
      return
    }
    idx = (idx + 1) & mask
  }
}

pub fn IntMap::get[V](self : IntMap[V], key : Int) -> Option[V] {
  let mask = self.cap - 1
  let mut idx = key & mask
  while true {
    let st = self.states[idx]
    if st == STATE_EMPTY {
      return None
    }
    if self.keys[idx] == key {
      return match self.slots[idx] {
        Filled(v) => Some(v)
        Vacant => None
      }
    }
    idx = (idx + 1) & mask
  }
  None
}

pub fn IntMap::length[V](self : IntMap[V]) -> Int {
  self.len
}
EOF

# Downstream app: Bug #6 + Bug #7 + Map[Int, V] / Map[Int64, V] + #derive(Eq)
cat > "$APP_DIR/pion.toml" <<EOF
[package]
name = "p27c1_app"
version = "0.1.0"

[dependencies]
intmap = { path = "$IMAP_DIR" }
EOF

cat > "$APP_DIR/src/main.pion" <<'EOF'
import "intmap" as im

#derive(Eq)
struct Point {
  x : Int
  y : Double
  label : String
}

#[derive(Eq, Hash, Debug)]
struct Rect {
  origin : Point
  nid : im::NodeId
}

#derive(Eq)
enum Shape {
  Empty
  Dot(Point)
  Pair(Int, String)
}

fn eq_test[T](a : T, b : T) -> Bool {
  a == b
}

fn id_helper[T](v : T) -> T {
  v
}

fn make_fn[T](x : T) -> () -> Int {
  fn() -> Int {
    let y = id_helper(x)
    let _ = y
    17
  }
}

fn make_nested_fn[T](x : T) -> () -> () -> Int {
  fn() -> () -> Int {
    let a = x
    fn() -> Int {
      let b = id_helper(a)
      let _ = b
      25
    }
  }
}

fn main(world : World) -> Unit {
  // 1. Bug #6: cross-pkg IntMap[String] & IntMap[Map[String, String]] with 100 inserts (multiple grows)
  let ms : im::IntMap[String] = im::IntMap::new()
  let mut i = 0
  while i < 100 {
    ms.set(i, "val_" + i.to_string())
    i = i + 1
  }
  debug_assert(ms.length() == 100, "bug6 IntMap[String] len")
  i = 0
  while i < 100 {
    match ms.get(i) {
      Some(s) => debug_assert(s == "val_" + i.to_string(), "bug6 IntMap[String] val")
      None => debug_assert(false, "bug6 IntMap[String] missing")
    }
    i = i + 1
  }
  debug_assert(ms.get(999).is_none(), "bug6 IntMap[String] miss")

  let mm : im::IntMap[Map[String, String]] = im::IntMap::new()
  i = 0
  while i < 100 {
    let inner : Map[String, String] = Map::new()
    inner.set("k", "m_" + i.to_string())
    mm.set(i * 3 - 50, inner)
    i = i + 1
  }
  debug_assert(mm.length() == 100, "bug6 IntMap[Map] len")
  match mm.get(40) {
    Some(got_m) => debug_assert(got_m["k"] == "m_30", "bug6 IntMap[Map] val")
    None => debug_assert(false, "bug6 IntMap[Map] missing")
  }

  // 2. Bug #7: generic closure capturing %tp_T (Int + heap String + nested + helper call)
  let fi = make_fn(123)
  let fs = make_fn("heap_str_" + 42.to_string())
  let fnest_i = make_nested_fn(99)
  let fnest_s = make_nested_fn("nested_heap_" + 7.to_string())
  let inner_i = fnest_i()
  let inner_s = fnest_s()
  debug_assert(fi() == 17 && fs() == 17, "bug7 make_fn")
  debug_assert(inner_i() == 25 && inner_s() == 25, "bug7 nested")

  // 3. Native Map[Int, V] and Map[Int64, V]
  let mi : Map[Int, String] = Map::new()
  mi.set(0, "zero")
  mi.set(-42, "neg42")
  mi[7] = "seven"
  debug_assert(mi.length() == 3, "map int len")
  debug_assert(mi.contains(0) && mi.contains(-42) && mi.contains(7) && !mi.contains(1), "map int contains")
  debug_assert(mi[0] == "zero" && mi[-42] == "neg42" && mi[7] == "seven", "map int index")
  match mi.get(-42) {
    Some(s) => debug_assert(s == "neg42", "map int get")
    None => debug_assert(false, "map int get missing")
  }
  let mi_cp = mi.copy()
  mi.remove(0)
  debug_assert(mi.length() == 2 && !mi.contains(0) && mi_cp.contains(0), "map int copy/remove")
  let ks : Array[Int] = mi.keys()
  debug_assert(ks.length() == 2, "map int keys len")
  let mut ksum = 0
  let mut ki = 0
  while ki < ks.length() {
    ksum = ksum + ks[ki]
    ki = ki + 1
  }
  debug_assert(ksum == -35, "map int keys sum")
  mi.clear()
  debug_assert(mi.length() == 0, "map int clear")

  let ma : Map[Int, Array[Int]] = Map([])
  ma.set(0, [1, 2, 3])
  ma.set(-1, [4, 5])
  debug_assert(ma[0].length() == 3 && ma[-1][1] == 5, "map int array val")

  let m64 : Map[Int64, String] = Map::new()
  m64.set(0L, "z64")
  m64.set(-9000000000L, "big_neg")
  m64[9000000000L] = "big_pos"
  debug_assert(m64.length() == 3 && m64[0L] == "z64" && m64[-9000000000L] == "big_neg", "map i64")
  let k64 : Array[Int64] = m64.keys()
  debug_assert(k64.length() == 3, "map i64 keys")

  // Mutex[Map[Int, String]] cross-thread safety
  let shared_m : Map[Int, String] = Map::new()
  shared_m.set(0, "init")
  let mx : Mutex[Map[Int, String]] = Mutex::new(shared_m)
  scope(world, fn(s) -> Unit {
    spawn(s, fn() -> Unit {
      let locked = mx.lock()
      locked.set(1, "worker")
      mx.unlock(locked)
    })
  })
  let locked2 = mx.lock()
  debug_assert(locked2[0] == "init" && locked2[1] == "worker", "mutex map int")
  mx.unlock(locked2)

  // 4. #derive(Eq) (struct, nested struct, cross-pkg NodeId, payload enum, generic eq_test[T])
  let n1 = im::NodeId::{ pkg: "ui", id: 7 }
  let n2 = im::NodeId::{ pkg: "ui", id: 7 }
  let n3 = im::NodeId::{ pkg: "ui", id: 8 }
  debug_assert(n1 == n2 && n1 != n3, "xpkg derive Eq NodeId")
  debug_assert(eq_test(n1, n2) && !eq_test(n1, n3), "generic eq_test NodeId")

  let p1 = Point::{ x: 3, y: 1.5, label: "a" + "b" }
  let p2 = Point::{ x: 3, y: 1.5, label: "ab" }
  let p3 = Point::{ x: 3, y: 2.5, label: "ab" }
  debug_assert(p1 == p2 && p1 != p3, "struct derive Eq")
  let r1 = Rect::{ origin: p1, nid: n1 }
  let r2 = Rect::{ origin: p2, nid: n2 }
  let r3 = Rect::{ origin: p3, nid: n2 }
  debug_assert(r1 == r2 && r1 != r3, "nested struct derive Eq")

  let s0 = Empty
  let s1 = Dot(p1)
  let s2 = Dot(p2)
  let s3 = Dot(p3)
  let s4 = Pair(10, "hi")
  let s5 = Pair(10, "h" + "i")
  let s6 = Pair(10, "no")
  debug_assert(s0 == Empty && s0 != s1, "enum derive Eq unit")
  debug_assert(s1 == s2 && s1 != s3, "enum derive Eq nested struct")
  debug_assert(s4 == s5 && s4 != s6, "enum derive Eq multi payload")
  debug_assert(eq_test(s4, s5) && !eq_test(s4, s6), "generic eq_test enum")

  io_println(world, "p27c1_crosspkg_clo_intmap_eq ok")
}
EOF

OUT=$(PION_CACHE_DIR="$CAS_DIR" "$PIONC" run "$APP_DIR")
echo "p27c1_crosspkg_clo_intmap_eq -> $OUT"
if [ "$OUT" != "p27c1_crosspkg_clo_intmap_eq ok" ]; then
  echo "FAIL: p27c1_crosspkg_clo_intmap_eq output mismatch: $OUT" >&2
  exit 1
fi

# ASan/LSan 0-leak check on the compiled E2E binary (links ASan runtime against emitted object)
CC_BIN="${CC:-cc}"
# Probe an ASan link first: MSYS2 UCRT64 GCC compiles -fsanitize=address but ships no -lasan.
if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"; then
  PION_CACHE_DIR="$CAS_DIR/asan" PION_RT_LIB="$TMP_DIR/libpionrt_asan.a" \
    "$PIONC" build --emit-obj "$TMP_DIR/app_asan.o" "$APP_DIR" 2>/dev/null || true
  if [ -f "$TMP_DIR/app_asan.o" ]; then
    # Also compile upstream package object for link if needed, or link single-file ASan test
    :
  fi
fi

# Single-file ASan/LSan 0-leak verification for Bug #7 (generic closures) + Map[Int/Int64, V] + #derive(Eq)
cat > "$TMP_DIR/asan_check.pion" <<'EOF'
#derive(Eq)
struct Item {
  id : Int
  name : String
}

fn id_helper[T](v : T) -> T { v }

fn make_fn[T](x : T) -> () -> Int {
  fn() -> Int {
    let y = id_helper(x)
    let _ = y
    1
  }
}

fn make_nested[T](x : T) -> () -> () -> Int {
  fn() -> () -> Int {
    let a = x
    fn() -> Int {
      let b = id_helper(a)
      let _ = b
      2
    }
  }
}

fn main(world : World) -> Unit {
  let mut i = 0
  while i < 64 {
    let s = "str_" + i.to_string()
    let f1 = make_fn(i)
    let f2 = make_fn(s)
    let g1 = make_nested(s)()
    debug_assert(f1() + f2() + g1() == 4, "asan clo")
    i = i + 1
  }
  let m : Map[Int, String] = Map::new()
  let ma : Map[Int, Array[Int]] = Map::new()
  let m64 : Map[Int64, String] = Map::new()
  i = -20
  while i < 40 {
    m.set(i, "v" + i.to_string())
    ma.set(i, [i, i + 1])
    m64.set(i.to_int64() * 1000000L, "l" + i.to_string())
    i = i + 1
  }
  let cp = m.copy()
  let ks = m.keys()
  debug_assert(cp.length() == 60 && ks.length() == 60, "asan map")
  m.remove(0)
  m.clear()
  let a = Item::{ id: 1, name: "a" + "b" }
  let b = Item::{ id: 1, name: "ab" }
  debug_assert(a == b, "asan eq")
  io_println(world, "p27c1_asan ok")
}
EOF

if [ -f "$TMP_DIR/libpionrt_asan.a" ]; then
  PION_CACHE_DIR="$CAS_DIR/asan_single" "$PIONC" build --emit-obj "$TMP_DIR/asan_check.o" "$TMP_DIR/asan_check.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/asan_check.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/asan_check"
  ASAN_OUT=$("$TMP_DIR/asan_check")
  echo "p27c1_asan -> $ASAN_OUT"
  if [ "$ASAN_OUT" != "p27c1_asan ok" ]; then
    echo "FAIL: p27c1_asan output mismatch: $ASAN_OUT" >&2
    exit 1
  fi
fi

# Bug #7b: struct literal `Boxed::{ val_opt: None, getter }` inside a monomorphized
# generic fn whose closure calls `step(st)` must not emit an undefined %tp_T
# (Bool / Unit non-object and String heap-object type arguments).
cat > "$TMP_DIR/bug7b.pion" <<'EOF'
struct Boxed[T] {
  mut val_opt : Option[T]
  getter : (Option[T]) -> T
}

fn step[T](b : Boxed[T]) -> Bool {
  b.val_opt = Some((b.getter)(b.val_opt))
  true
}

fn make_updater[T](getter : (Option[T]) -> T) -> () -> Bool {
  let st = Boxed::{ val_opt: None, getter }
  fn() -> Bool {
    step(st)
  }
}

fn main(world : World) -> Unit {
  let mut i = 0
  let mut ok = 0
  while i < 64 {
    let tag = "s_" + i.to_string()
    let fb = make_updater(fn(p : Option[Bool]) -> Bool { p.is_none() })
    let fu = make_updater(fn(_p : Option[Unit]) -> Unit { () })
    let fs = make_updater(fn(p : Option[String]) -> String {
      match p {
        Some(s) => s + "!"
        None => tag
      }
    })
    if fb() && fb() && fu() && fu() && fs() && fs() {
      ok = ok + 1
    }
    i = i + 1
  }
  io_println(world, "p27c1b_bug7b ok " + ok.to_string())
}
EOF

B7_OUT=$(PION_CACHE_DIR="$CAS_DIR/bug7b" "$PIONC" run "$TMP_DIR/bug7b.pion")
echo "p27c1b_bug7b -> $B7_OUT"
if [ "$B7_OUT" != "p27c1b_bug7b ok 64" ]; then
  echo "FAIL: p27c1b_bug7b output mismatch: $B7_OUT" >&2
  exit 1
fi
if [ -f "$TMP_DIR/libpionrt_asan.a" ]; then
  PION_CACHE_DIR="$CAS_DIR/bug7b_asan" "$PIONC" build --emit-obj "$TMP_DIR/bug7b.o" "$TMP_DIR/bug7b.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/bug7b.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/bug7b_asan"
  B7_ASAN_OUT=$("$TMP_DIR/bug7b_asan")
  echo "p27c1b_bug7b_asan -> $B7_ASAN_OUT"
  if [ "$B7_ASAN_OUT" != "p27c1b_bug7b ok 64" ]; then
    echo "FAIL: p27c1b_bug7b_asan output mismatch: $B7_ASAN_OUT" >&2
    exit 1
  fi
fi

# Bug #8: unannotated `let out = []` / `Map([])` must take their element type from the
# first push/set (or the return type) so the array/map owns (rc) heap elements;
# before the fix it was `pion_arr_new(0, 0)` -> dangling strings / double free.
cat > "$TMP_DIR/bug8.pion" <<'EOF'
fn collect(n : Int) -> Array[String] {
  let out = []
  let mut i = 0
  while i < n {
    let s = "item-" + i.to_string()
    out.push(s)
    i += 1
  }
  out
}

fn nested(n : Int) -> Array[Array[String]] {
  let rows = []
  let mut i = 0
  while i < n {
    rows.push(collect(i % 4 + 1))
    i += 1
  }
  rows
}

fn index(n : Int) -> Map[String, Array[String]] {
  let m = Map([])
  let mut i = 0
  while i < n {
    m.set("k" + i.to_string(), collect(2))
    i += 1
  }
  m
}

fn main(world : World) -> Unit {
  let mut total = 0
  let mut round = 0
  while round < 8 {
    let xs = collect(64)
    let mut i = 0
    while i < xs.length() {
      total += xs[i].length()
      i += 1
    }
    let rows = nested(16)
    total += rows[15][3].length()
    let m = index(16)
    total += m["k15"][1].length()
    // No return witness: element type comes from the first push only.
    let tags = []
    let mut j = 0
    while j < 8 {
      tags.push("t" + j.to_string())
      j += 1
    }
    total += tags[7].length()
    round += 1
  }
  io_println(world, "p29b2_bug8 ok " + total.to_string() + " " + collect(64)[63])
}
EOF

B8_EXPECT="p29b2_bug8 ok 3616 item-63"
B8_OUT=$(PION_CACHE_DIR="$CAS_DIR/bug8" "$PIONC" run "$TMP_DIR/bug8.pion")
echo "p29b2_bug8 -> $B8_OUT"
if [ "$B8_OUT" != "$B8_EXPECT" ]; then
  echo "FAIL: p29b2_bug8 output mismatch: $B8_OUT" >&2
  exit 1
fi
if [ -f "$TMP_DIR/libpionrt_asan.a" ]; then
  PION_CACHE_DIR="$CAS_DIR/bug8_asan" "$PIONC" build --emit-obj "$TMP_DIR/bug8.o" "$TMP_DIR/bug8.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/bug8.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/bug8_asan"
  B8_ASAN_OUT=$("$TMP_DIR/bug8_asan")
  echo "p29b2_bug8_asan -> $B8_ASAN_OUT"
  if [ "$B8_ASAN_OUT" != "$B8_EXPECT" ]; then
    echo "FAIL: p29b2_bug8_asan output mismatch: $B8_ASAN_OUT" >&2
    exit 1
  fi
fi

echo "[PASS] p27c1_crosspkg_clo_intmap_eq (Bug #6 + Bug #7 + Map[Int/Int64, V] + #derive(Eq) + Bug #7b + Bug #8 + ASan/LSan)"
