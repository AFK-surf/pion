#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

cat > "$TMP_DIR/p30b_main.pion" <<'EOF'
struct Attr {
  prefix : String
  name : String
  value : String
}

struct MutAttr {
  mut prefix : String
  mut name : String
  mut value : String
}

struct Node {
  attrs : Array[Attr]
}

struct MutNode {
  mut attrs : Array[Attr]
}

struct BoxMut {
  mut cur : Attr
}

struct Outer {
  inner : Attr
}

struct Item {
  id : Int
  t : Double
}

fn find_attr(attrs : Array[Attr], target : String) -> Option[String] {
  let mut i = 0
  while i < attrs.length() {
    let a = attrs[i]
    if a.prefix == "" && a.name == target {
      return Some(a.value)
    }
    i += 1
  }
  None
}

fn Node::attr(self : Node, target : String) -> Option[String] {
  let mut i = 0
  while i < self.attrs.length() {
    let a = self.attrs[i]
    if a.prefix == "" && a.name == target {
      return Some(a.value)
    }
    i += 1
  }
  None
}

fn MutNode::attr(self : MutNode, target : String) -> Option[String] {
  let mut i = 0
  while i < self.attrs.length() {
    let a = self.attrs[i]
    if a.prefix == "" && a.name == target {
      return Some(a.value)
    }
    i += 1
  }
  None
}

fn find_mut_attr(attrs : Array[MutAttr], target : String) -> Option[String] {
  let mut i = 0
  while i < attrs.length() {
    let a = attrs[i]
    if a.prefix == "" && a.name == target {
      return Some(a.value)
    }
    i += 1
  }
  None
}

fn read_chained(o : Outer) -> Int {
  let nm = o.inner.name
  let vl = o.inner.value
  nm.length() + vl.length()
}

// Adversarial 1: container cleared while local holds element
fn adv_arr_clear() -> Int {
  let arr : Array[Attr] = [
    Attr::{ prefix: "", name: "alpha" + "1", value: "v1" + "x" },
  ]
  let a = arr[0]
  arr.clear()
  a.name.length() + a.value.length()
}

// Adversarial 2: struct.attrs cleared while local holds element
fn adv_field_arr_clear() -> Int {
  let node = Node::{
    attrs: [Attr::{ prefix: "", name: "beta" + "2", value: "v2" + "yy" }],
  }
  let a = node.attrs[0]
  node.attrs.clear()
  a.name.length() + a.value.length()
}

// Adversarial 3: aliased array cleared while local holds element from struct.attrs
fn adv_alias_arr_clear() -> Int {
  let node = Node::{
    attrs: [Attr::{ prefix: "", name: "gamma" + "3", value: "v3" + "zzz" }],
  }
  let other = node.attrs
  let a = node.attrs[0]
  other.clear()
  a.name.length() + a.value.length()
}

// Adversarial 4: element escapes via return
fn adv_return_elem() -> Attr {
  let arr : Array[Attr] = [
    Attr::{ prefix: "", name: "delta" + "4", value: "v4" + "w" },
  ]
  let a = arr[0]
  return a
}

// Adversarial 5: mutable struct field overwritten while local holds old value
fn adv_mut_field_overwrite() -> Int {
  let b = BoxMut::{
    cur: Attr::{ prefix: "", name: "old" + "5", value: "ov5" + "!" },
  }
  let a = b.cur
  b.cur = Attr::{ prefix: "", name: "new" + "6", value: "nv6" + "?" }
  a.name.length() + a.value.length() + b.cur.name.length()
}

// Adversarial 6: EPath assoc fn call clears aliased array while local holds `node.attrs[0]`
struct Holder {
  x : Int
}

fn Holder::clear_alias(arr : Array[Attr]) -> Unit {
  arr.clear()
}

fn adv_epath_alias_clear() -> Int {
  let node = Node::{
    attrs: [Attr::{ prefix: "", name: "epath" + "8", value: "ev8" + "!" }],
  }
  let alias = node.attrs
  let a = node.attrs[0]
  Holder::clear_alias(alias)
  a.name.length() + a.value.length()
}

// Adversarial 7: closure captures `a` and container is cleared before invoking closure
fn run_str_cb(f : () -> String) -> String {
  f()
}

fn adv_closure_escape() -> Int {
  let arr : Array[Attr] = [
    Attr::{ prefix: "", name: "clo" + "7", value: "cv7" + "!" },
  ]
  let a = arr[0]
  let f = fn() -> String { a.name + ":" + a.value }
  arr.clear()
  run_str_cb(f).length()
}

// Bug #15: unannotated closure param inferred from generic function call
fn my_any[T](xs : Array[T], pred : (T) -> Bool) -> Bool {
  let mut i = 0
  while i < xs.length() {
    if pred(xs[i]) {
      return true
    }
    i += 1
  }
  false
}

pub fn main(world : World) -> Int {
  let attrs : Array[Attr] = [
    Attr::{ prefix: "", name: "id", value: "root" },
    Attr::{ prefix: "xml", name: "lang", value: "en" },
    Attr::{ prefix: "", name: "href", value: "https://pion.dev" },
  ]
  let node = Node::{ attrs: attrs }
  let mnode = MutNode::{ attrs: attrs }

  match find_attr(attrs, "href") {
    Some(v) => debug_assert(v == "https://pion.dev", "find_attr hit")
    None => debug_assert(false, "find_attr expected hit")
  }
  match find_attr(attrs, "lang") {
    Some(_) => debug_assert(false, "find_attr prefix mismatch")
    None => ()
  }
  match node.attr("href") {
    Some(v) => debug_assert(v == "https://pion.dev", "Node::attr hit")
    None => debug_assert(false, "Node::attr expected hit")
  }
  match mnode.attr("id") {
    Some(v) => debug_assert(v == "root", "MutNode::attr hit")
    None => debug_assert(false, "MutNode::attr expected hit")
  }

  let mattrs : Array[MutAttr] = [
    MutAttr::{ prefix: "", name: "k", value: "val" },
  ]
  match find_mut_attr(mattrs, "k") {
    Some(v) => debug_assert(v == "val", "find_mut_attr hit")
    None => debug_assert(false, "find_mut_attr expected hit")
  }

  let o = Outer::{ inner: Attr::{ prefix: "", name: "ab", value: "cde" } }
  debug_assert(read_chained(o) == 5, "read_chained")

  // Adversarial checks (ASan/LSan 0 UAF / 0 leaks)
  debug_assert(adv_arr_clear() == 9, "adv_arr_clear")
  debug_assert(adv_field_arr_clear() == 9, "adv_field_arr_clear")
  debug_assert(adv_alias_arr_clear() == 11, "adv_alias_arr_clear")
  let esc = adv_return_elem()
  debug_assert(esc.name == "delta4" && esc.value == "v4w", "adv_return_elem")
  debug_assert(adv_mut_field_overwrite() == 12, "adv_mut_field_overwrite")
  debug_assert(adv_epath_alias_clear() == 10, "adv_epath_alias_clear")
  debug_assert(adv_closure_escape() == 9, "adv_closure_escape")

  // Bug #15: unannotated closure param type inference
  let items : Array[Item] = [
    Item::{ id: 1, t: 0.5 },
    Item::{ id: 2, t: 3.5 },
    Item::{ id: 3, t: 1.2 },
  ]
  let cap_int = 2
  let cap_double = 3.0
  debug_assert(
    my_any(items, fn(e) { e.id == cap_int && e.t > cap_double }),
    "bug15 my_any true",
  )
  debug_assert(
    !my_any(items, fn(e) { e.id == cap_int && e.t > 4.0 }),
    "bug15 my_any false",
  )

  io_println(world, "p30b_rc_borrow_perf ok")
  0
}
EOF

OUT=$("$PIONC" run "$TMP_DIR/p30b_main.pion")
echo "p30b_rc_borrow_perf native -> $OUT"
if [ "$OUT" != "p30b_rc_borrow_perf ok" ]; then
  echo "FAIL: p30b_rc_borrow_perf native output mismatch" >&2
  exit 1
fi

# ASan/LSan check (0 UAF / 0 leaks)
CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --emit-obj "$TMP_DIR/p30b_main.o" "$TMP_DIR/p30b_main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p30b_main.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p30b_asan"
  ASAN_OUT=$("$TMP_DIR/p30b_asan")
  echo "p30b_rc_borrow_perf ASan -> $ASAN_OUT"
  if [ "$ASAN_OUT" != "p30b_rc_borrow_perf ok" ]; then
    echo "FAIL: p30b_rc_borrow_perf ASan mismatch or leak" >&2
    exit 1
  fi
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p30b ASan check"
fi

# Wasm32 check (when node is available)
if command -v node >/dev/null 2>&1; then
  WASM="$TMP_DIR/p30b_main.wasm"
  "$PIONC" build --target wasm32 -o "$WASM" "$TMP_DIR/p30b_main.pion"
  WASM_OUT=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$WASM")
  echo "p30b_rc_borrow_perf wasm32 -> $WASM_OUT"
  if [ "$WASM_OUT" != "p30b_rc_borrow_perf ok" ]; then
    echo "FAIL: p30b_rc_borrow_perf wasm32 output mismatch" >&2
    exit 1
  fi
fi

echo "p30b_rc_borrow_perf: ALL PASSED"
