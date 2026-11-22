#!/bin/sh
set -eu

# P31-A permanent E2E regression:
#   1. -> Unit implicit tail discard (fn, closure, if, match) with RC release + E_UNHANDLED_RESULT negative
#   2. Struct TFn field direct call (d.refresh(), d.set_dpi(v, lod), cross-pkg generic struct, method precedence)
#   3. Local non-spawn closure `let mut` auto-boxing (Int, Double, String, Option[Struct], 2 closures, 2-level nesting, loop closures, RC overwrite) + spawn E_NOT_SEND negative
#   4. Array::with_capacity & Map::with_capacity (unannotated inference, negative cap clamp)
# Verified on: Native Release + ASan/LSan (0 UAF, 0 leaks) + Wasm32 Node.js (identical checksum).

PIONC="${1:-}"
if [ -z "$PIONC" ] || [ ! -x "$PIONC" ]; then
  echo "usage: $0 <path-to-pionc>" >&2
  exit 1
fi

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

# Multi-package project for cross-pkg generic struct TFn field direct call
PKG_DIR="$TMP_DIR/proj"
mkdir -p "$PKG_DIR/devpkg/src" "$PKG_DIR/app/src"

cat > "$PKG_DIR/devpkg/pion.toml" <<'EOF'
[package]
name = "devpkg"
version = "0.1.0"
EOF

cat > "$PKG_DIR/devpkg/src/lib.pion" <<'EOF'
pub struct Device[T] {
  pub name : String
  pub refresh : () -> T
  pub set_dpi : (Int, Int) -> String
  pub transform : ((Int) -> Int) -> Int
}

pub fn make_device[T](name : String, r : () -> T, s : (Int, Int) -> String, t : ((Int) -> Int) -> Int) -> Device[T] {
  Device::{ name: name, refresh: r, set_dpi: s, transform: t }
}
EOF

cat > "$PKG_DIR/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
devpkg = { path = "../devpkg" }
EOF

cat > "$PKG_DIR/app/src/main.pion" <<'EOF'
import "devpkg"

struct Builder {
  items : Array[String]
}

fn Builder::push_item(self : Builder, s : String) -> Builder {
  self.items.push(s)
  self
}

struct Node {
  tag : String
  num : Int
}

struct Precedence {
  f : () -> Int
}

fn Precedence::f(self : Precedence) -> Int {
  let _ = self
  100
}

fn run_u(cb : () -> Unit) -> Unit {
  cb()
}

fn unit_tail_fn(b : Builder, flag : Bool, k : Int) -> Unit {
  // Tail expression returns Builder (heap RC object) -> implicitly discarded with RC dec
  b.push_item("fn_tail")
}

fn unit_tail_if(b : Builder, flag : Bool) -> Unit {
  if flag {
    b.push_item("if_then")
  } else {
    b.push_item("if_else")
  }
}

fn unit_tail_match(b : Builder, k : Int) -> Unit {
  match k {
    0 => b.push_item("m0")
    1 => b.push_item("m1")
    _ => b.push_item("m_other")
  }
}

fn test_unit_discard() -> Int {
  let b = Builder::{ items: Array::with_capacity(8) }
  unit_tail_fn(b, true, 0)
  unit_tail_if(b, true)
  unit_tail_if(b, false)
  unit_tail_match(b, 0)
  unit_tail_match(b, 1)
  unit_tail_match(b, 99)
  run_u(fn() -> Unit {
    // Discard freshly allocated String in closure tail
    let s = "clo_" + "tail"
    let _ = b.push_item(s)
    "ephemeral_" + "discarded"
  })
  debug_assert(b.items.length() == 7, "unit discard count")
  debug_assert(b.items[0] == "fn_tail" && b.items[6] == "clo_tail", "unit discard items")
  b.items.length()
}

fn test_fn_field_calls() -> Int {
  let mut refresh_count = 0
  let mut last_dpi = 0
  let d = devpkg::make_device(
    "mx-master",
    fn() -> Int {
      refresh_count += 1
      refresh_count * 10
    },
    fn(v : Int, lod : Int) -> String {
      last_dpi = v + lod
      "dpi=" + v.to_string() + ":" + lod.to_string()
    },
    fn(g : (Int) -> Int) -> Int {
      g(21)
    },
  )
  let r1 = d.refresh()
  let r2 = d.refresh()
  let s = d.set_dpi(1600, 2)
  let t = d.transform(fn(x) { x * 2 })
  debug_assert(r1 == 10 && r2 == 20 && refresh_count == 2, "d.refresh()")
  debug_assert(s == "dpi=1600:2" && last_dpi == 1602, "d.set_dpi(v, lod)")
  debug_assert(t == 42, "d.transform(unannotated closure)")

  // Method takes precedence over same-named TFn field
  let p = Precedence::{ f: fn() -> Int { 7 } }
  debug_assert(p.f() == 100, "method precedence")
  debug_assert((p.f)() == 7, "explicit field call still works")
  r2 + last_dpi + t + p.f()
}

fn test_mut_capture_boxing() -> Int {
  // 1. Int, Double, String, Option[Node] bidirectional read/write + 2 closures sharing + 2-level nesting
  let mut count = 1
  let mut acc_d = 1.5
  let mut log = "start"
  let mut cur : Option[Node] = Some(Node::{ tag: "init", num: 5 })

  let inc = fn(delta : Int) -> Unit {
    count += delta
    acc_d += 0.5
    log += ":" + count.to_string()
    // Repeatedly overwrite RC Option[Node] inside closure
    cur = Some(Node::{ tag: "n" + count.to_string(), num: count * 3 })
  }
  let read_both = fn() -> Int {
    let inner = fn() -> Int {
      count += 10
      let cur_v = match cur {
        Some(n) => n.num
        None => -1
      }
      count + cur_v
    }
    inner()
  }

  // Outer write, inner read/write, outer read
  count = 2
  inc(3) // count=5, acc_d=2.0, log="start:5", cur=Some(n5, 15)
  debug_assert(count == 5, "after inc(3)")
  debug_assert(acc_d == 2.0, "acc_d after inc")
  debug_assert(log == "start:5", "log after inc")

  let nested_res = read_both() // count=15, cur_v=15 -> 30
  debug_assert(count == 15 && nested_res == 30, "nested 2-level closure")

  cur = None
  inc(5) // count=20, acc_d=2.5, log="start:5:20", cur=Some(n20, 60)
  debug_assert(log == "start:5:20", "log after second inc")
  let final_node_val = match cur {
    Some(n) => {
      debug_assert(n.tag == "n20", "node tag")
      n.num
    }
    None => 0
  }
  debug_assert(final_node_val == 60, "final node val")

  // 2. Closures created in a loop: each iteration gets its own boxed `let mut` cell
  let fns : Array[() -> Int] = Array::with_capacity(4)
  for i in 0..4 {
    let mut cell = i * 10
    fns.push(fn() -> Int {
      cell += 1
      cell
    })
  }
  let mut loop_sum = 0
  for i in 0..4 {
    let a = fns[i]()
    let b = fns[i]()
    loop_sum += a + b
  }
  // i=0: 1+2=3, i=1: 11+12=23, i=2: 21+22=43, i=3: 31+32=63 -> total = 132
  debug_assert(loop_sum == 132, "loop distinct mut cells")

  // 3. Mutable closure variable captured and reassigned
  let mut cb : () -> Int = fn() -> Int { 11 }
  let swap_cb = fn() -> Unit {
    cb = fn() -> Int { 22 }
  }
  let c1 = cb()
  swap_cb()
  let c2 = cb()
  debug_assert(c1 == 11 && c2 == 22, "mut closure cell")

  count + final_node_val + loop_sum + c1 + c2
}

fn test_with_capacity() -> Int {
  // Unannotated inference via push/set
  let a = Array::with_capacity(64)
  let mut i = 0
  while i < 50 {
    a.push("item_" + i.to_string())
    i += 1
  }
  debug_assert(a.length() == 50 && a[0] == "item_0" && a[49] == "item_49", "Array::with_capacity infer")

  let m = Map::with_capacity(32)
  m.set("alpha", 10)
  m.set("beta", 20)
  debug_assert(m.length() == 2 && m.get("alpha").unwrap_or(0) == 10 && m.get("beta").unwrap_or(0) == 20, "Map::with_capacity infer")

  // Negative capacity clamping (must not OOM or crash)
  let neg_a : Array[Int] = Array::with_capacity(-100)
  neg_a.push(7)
  let neg_m : Map[Int, String] = Map::with_capacity(-50)
  neg_m.set(3, "three")
  debug_assert(neg_a.length() == 1 && neg_a[0] == 7, "neg Array::with_capacity clamp")
  debug_assert(neg_m.length() == 1 && neg_m.get(3).unwrap_or("") == "three", "neg Map::with_capacity clamp")

  a.length() + m.length() + neg_a[0]
}

pub fn main(world : World) -> Int {
  let s1 = test_unit_discard()
  let s2 = test_fn_field_calls()
  let s3 = test_mut_capture_boxing()
  let s4 = test_with_capacity()
  let total = s1 + s2 + s3 + s4
  io_println(world, "p31a_ergonomics ok sum=" + total.to_string())
  0
}
EOF

# 1. Native Release run
"$PIONC" build --release -o "$TMP_DIR/p31a_rel" "$PKG_DIR/app"
REL_OUT=$("$TMP_DIR/p31a_rel")
echo "p31a_ergonomics native release -> $REL_OUT"
EXPECTED="p31a_ergonomics ok sum=2075"
if [ "$REL_OUT" != "$EXPECTED" ]; then
  echo "FAIL: p31a_ergonomics native release expected '$EXPECTED', got '$REL_OUT'" >&2
  exit 1
fi

# 2. Negative compile-time checks:
#    - -> Unit tail Result must still be E_UNHANDLED_RESULT
#    - spawn capturing outer let mut (even via nested closure) must be E_NOT_SEND
cat > "$TMP_DIR/bad_unit_res.pion" <<'EOF'
fn may_fail() -> Result[Int, String] { Err("err") }
pub fn f() -> Unit {
  may_fail()
}
pub fn main(world : World) -> Int {
  let _ = world
  f()
  0
}
EOF
BAD_RES=$("$PIONC" check --json "$TMP_DIR/bad_unit_res.pion" || true)
if ! printf '%s' "$BAD_RES" | grep -q '"code":"E_UNHANDLED_RESULT"'; then
  echo "FAIL: expected E_UNHANDLED_RESULT for -> Unit tail Result, got: $BAD_RES" >&2
  exit 1
fi

cat > "$TMP_DIR/bad_spawn_nested_mut.pion" <<'EOF'
pub fn main(world : World) -> Int {
  let mut x = 0
  scope(world, fn(s : Scope) -> Unit {
    spawn(s, fn() -> Unit {
      let inner = fn() -> Unit { x += 1 }
      inner()
    })
  })
  x
}
EOF
BAD_SP=$("$PIONC" check --json "$TMP_DIR/bad_spawn_nested_mut.pion" || true)
if ! printf '%s' "$BAD_SP" | grep -q '"code":"E_NOT_SEND"'; then
  echo "FAIL: expected E_NOT_SEND for spawn nested closure mut capture, got: $BAD_SP" >&2
  exit 1
fi
echo "p31a_ergonomics negative checks (Unit tail Result, spawn nested mut): OK"

# 3. ASan/LSan check (single-file standalone mirror of all 4 features, 0 UAF, 0 leaks)
cat > "$TMP_DIR/p31a_single.pion" <<'EOF'
struct Builder {
  items : Array[String]
}
fn Builder::push_item(self : Builder, s : String) -> Builder {
  self.items.push(s)
  self
}
struct Node {
  tag : String
  num : Int
}
struct Device[T] {
  name : String
  refresh : () -> T
  set_dpi : (Int, Int) -> String
  transform : ((Int) -> Int) -> Int
}
struct Precedence {
  f : () -> Int
}
fn Precedence::f(self : Precedence) -> Int {
  let _ = self
  100
}
fn run_u(cb : () -> Unit) -> Unit { cb() }
fn unit_tail_fn(b : Builder) -> Unit { b.push_item("fn_tail") }
fn unit_tail_if(b : Builder, flag : Bool) -> Unit {
  if flag { b.push_item("if_then") } else { b.push_item("if_else") }
}
fn unit_tail_match(b : Builder, k : Int) -> Unit {
  match k {
    0 => b.push_item("m0")
    1 => b.push_item("m1")
    _ => b.push_item("m_other")
  }
}
pub fn main(world : World) -> Int {
  let b = Builder::{ items: Array::with_capacity(8) }
  unit_tail_fn(b)
  unit_tail_if(b, true)
  unit_tail_if(b, false)
  unit_tail_match(b, 0)
  unit_tail_match(b, 1)
  unit_tail_match(b, 99)
  run_u(fn() -> Unit {
    let s = "clo_" + "tail"
    let _ = b.push_item(s)
    "ephemeral_" + "discarded"
  })
  let s1 = b.items.length()

  let mut refresh_count = 0
  let mut last_dpi = 0
  let d = Device::{
    name: "mx-master",
    refresh: fn() -> Int {
      refresh_count += 1
      refresh_count * 10
    },
    set_dpi: fn(v : Int, lod : Int) -> String {
      last_dpi = v + lod
      "dpi=" + v.to_string() + ":" + lod.to_string()
    },
    transform: fn(g : (Int) -> Int) -> Int { g(21) },
  }
  let _ = d.refresh()
  let r2 = d.refresh()
  let _ = d.set_dpi(1600, 2)
  let t = d.transform(fn(x) { x * 2 })
  let p = Precedence::{ f: fn() -> Int { 7 } }
  let s2 = r2 + last_dpi + t + p.f()

  let mut count = 2
  let mut acc_d = 1.5
  let mut log = "start"
  let mut cur : Option[Node] = Some(Node::{ tag: "init", num: 5 })
  let inc = fn(delta : Int) -> Unit {
    count += delta
    acc_d += 0.5
    log += ":" + count.to_string()
    cur = Some(Node::{ tag: "n" + count.to_string(), num: count * 3 })
  }
  let read_both = fn() -> Int {
    let inner = fn() -> Int {
      count += 10
      let cur_v = match cur {
        Some(n) => n.num
        None => -1
      }
      count + cur_v
    }
    inner()
  }
  inc(3)
  let _ = read_both()
  cur = None
  inc(5)
  let final_node_val = match cur {
    Some(n) => n.num
    None => 0
  }
  let fns : Array[() -> Int] = Array::with_capacity(4)
  for i in 0..4 {
    let mut cell = i * 10
    fns.push(fn() -> Int {
      cell += 1
      cell
    })
  }
  let mut loop_sum = 0
  for i in 0..4 {
    loop_sum += fns[i]() + fns[i]()
  }
  let mut cb : () -> Int = fn() -> Int { 11 }
  let swap_cb = fn() -> Unit { cb = fn() -> Int { 22 } }
  let c1 = cb()
  swap_cb()
  let c2 = cb()
  let s3 = count + final_node_val + loop_sum + c1 + c2

  let a = Array::with_capacity(64)
  let mut i = 0
  while i < 50 {
    a.push("item_" + i.to_string())
    i += 1
  }
  let m = Map::with_capacity(32)
  m.set("alpha", 10)
  m.set("beta", 20)
  let neg_a : Array[Int] = Array::with_capacity(-100)
  neg_a.push(7)
  let neg_m : Map[Int, String] = Map::with_capacity(-50)
  neg_m.set(3, "three")
  let s4 = a.length() + m.length() + neg_a[0]

  let total = s1 + s2 + s3 + s4
  io_println(world, "p31a_ergonomics ok sum=" + total.to_string())
  0
}
EOF

CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --emit-obj "$TMP_DIR/p31a_single.o" "$TMP_DIR/p31a_single.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p31a_single.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p31a_asan"
  ASAN_OUT=$("$TMP_DIR/p31a_asan")
  echo "p31a_ergonomics ASan/LSan -> $ASAN_OUT"
  if [ "$ASAN_OUT" != "$EXPECTED" ]; then
    echo "FAIL: p31a_ergonomics ASan/LSan mismatch or leak: '$ASAN_OUT'" >&2
    exit 1
  fi
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p31a ASan check"
fi

# 4. Wasm32 Node.js check (exact same checksum)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/p31a_single.wasm" "$TMP_DIR/p31a_single.pion"
  WASM_OUT=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p31a_single.wasm")
  echo "p31a_ergonomics wasm32 -> $WASM_OUT"
  if [ "$WASM_OUT" != "$EXPECTED" ]; then
    echo "FAIL: p31a_ergonomics wasm32 mismatch: expected '$EXPECTED', got '$WASM_OUT'" >&2
    exit 1
  fi
else
  echo "NOTE: node unavailable; skipping p31a wasm32 check"
fi

echo "PASS: p31a_ergonomics"
