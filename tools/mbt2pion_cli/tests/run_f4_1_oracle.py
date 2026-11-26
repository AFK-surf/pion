#!/usr/bin/env python3
r"""Wave M2-F4 Track F4-1 4-Target Differential Oracle:
MoonBit native == MoonBit wasm-gc == Pion native == Pion wasm32.

Verifies:
  1. Positive parity (all 4 targets byte-for-byte identical stdout):
     - In-place write only during `iter()` and `search_by()` (`[1,9,3]` / `Some(1)`)
     - `push` without realloc (spare cap) and `push` with realloc (append-only, no write)
     - Zero-element, last-element, short-circuit (`search_by`, `iter().any`, `iter().find_first`)
     - `map`/`filter` laziness (exact evaluation trace up to short-circuit)
     - `for i, e in xs { if e == 2 { xs.remove(i); break } }` (immediate exit)
     - Package-confined private field `shrink_to_fit()` inside `pub fn`
     - Pure `search_by` with built-in methods & private struct closure field `(e.off)()`
  2. Real MoonBit native & wasm-gc counterexample assertions + Pion fail-closed publish gates:
     - Full-capacity single-op `xs.insert(0, 9)` in `search_by`: Moon native & wasm-gc visit `[1,2]` -> `Some(1)`;
       Pion blocks with `MBT2PION_ARRAY_ITER_MUTATION` (never returns wrong `Some(2)`!)
     - Full-capacity `push` realloc + write in `search_by` & `iter()`: Moon visits `[1,2,3]` -> `None`; Pion blocks!
     - `pop`, `remove(0)`, `remove(1)`, `clear`, `splice`, `resize` in `search_by` & `iter()`: Pion blocks!
     - Spare-cap `shrink_to_fit` + write vs full-cap `shrink_to_fit` + write: Pion blocks!
     - `for x in f2 { if x == 1 { f2.clear() }; s += x }`: Moon native & wasm-gc output `6`; Pion blocks!
     - Lazy `map`/`filter` escape: Pion blocks!
     - `combobox`-style external callback alias capture: Pion blocks!
"""
import argparse
import os
import shutil
import subprocess
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

POS_MBT = r'''
fn ints(xs : Array[Int]) -> String {
  xs.map(fn(x) { x.to_string() }).join(",")
}

fn opt(o : Int?) -> String {
  match o {
    Some(v) => "Some(" + v.to_string() + ")"
    None => "None"
  }
}

let confined_pool : Array[Int] = []

pub fn reset_pool() -> Unit {
  confined_pool.clear()
  confined_pool.shrink_to_fit()
}

priv struct Rule {
  off : () -> Bool
}

fn mk_rules() -> Array[Rule] {
  [
    { off: fn() { true } },
    { off: fn() { false } },
    { off: fn() { false } },
  ]
}

pub fn run_1_inplace_write() -> String {
  let a = [1, 2, 3]
  let visited : Array[Int] = []
  let idx = a.search_by(fn(x) {
    visited.push(x)
    if x == 1 { a[1] = 9 }
    x == 9
  })
  let b = [1, 2, 3]
  let it = b.iter()
  b[1] = 9
  ints(visited) + "|" + opt(idx) + "|" + ints(it.to_array())
}

pub fn run_2_push_only() -> String {
  // Spare capacity push (no realloc)
  let a : Array[Int] = Array(capacity=8)
  a.push(1)
  a.push(2)
  a.push(3)
  let r1 = a.search_by(fn(x) {
    if x == 1 { a.push(99) }
    x == 3
  })
  // Full capacity push (reallocates, no in-place write)
  let b = [1, 2, 3]
  let it = b.iter()
  b.push(4)
  b.push(5)
  let c = [1, 2, 3]
  let mut sum = 0
  for x in c {
    if x == 1 { c.push(100) }
    sum = sum + x
  }
  opt(r1) + "|" + a.length().to_string() + "|" + ints(it.to_array()) + "|" + sum.to_string() + "|" + c.length().to_string()
}

pub fn run_3_edge_and_laziness() -> String {
  let empty : Array[Int] = []
  let r_empty = empty.search_by(fn(x) { x == 1 })
  let xs = [10, 20, 30, 40]
  let r_last = xs.search_by(fn(x) { x == 40 })
  let trace : Array[Int] = []
  let found = xs.iter().map(fn(x) {
    trace.push(x)
    x * 2
  }).filter(fn(y) { y >= 40 }).find_first(fn(y) { y == 40 })
  opt(r_empty) + "|" + opt(r_last) + "|" + opt(found) + "|" + ints(trace)
}

pub fn run_4_for_remove_break_and_confined() -> String {
  let xs = [10, 20, 30]
  for i, x in xs {
    if x == 20 {
      xs.remove(i) |> ignore
      break
    }
  }
  confined_pool.push(1)
  confined_pool.push(2)
  reset_pool()
  let rules = mk_rules()
  let active = rules.search_by(fn(r) { !(r.off)() })
  let cmds = ["help", "quit", "run"]
  let typed = "please quit"
  let matched = cmds.search_by(fn(w) { typed.has_suffix(w) })
  ints(xs) + "|" + confined_pool.length().to_string() + "|" + opt(active) + "|" + opt(matched)
}

pub fn run_all() -> String {
  "P1:" + run_1_inplace_write() + "\n" +
  "P2:" + run_2_push_only() + "\n" +
  "P3:" + run_3_edge_and_laziness() + "\n" +
  "P4:" + run_4_for_remove_break_and_confined()
}
'''

# Real MoonBit reference program verifying Moon native & Moon wasm-gc exact counterexample outputs!
MOON_REF_MBT = r'''
fn ints(xs : Array[Int]) -> String {
  xs.map(fn(x) { x.to_string() }).join(",")
}

fn opt(o : Int?) -> String {
  match o {
    Some(v) => "Some(" + v.to_string() + ")"
    None => "None"
  }
}

pub fn run_counterexamples() -> String {
  // 1. Full-cap single-op `xs.insert(0, 9)` in `search_by`: Moon visits [1, 2] -> Some(1)!
  let a = [1, 2, 3]
  let vis_ins : Array[Int] = []
  let r_ins = a.search_by(fn(x) {
    vis_ins.push(x)
    if x == 1 { a.insert(0, 9) }
    x == 2
  })
  // 2. Full-cap `push` realloc + write in `search_by`: Moon visits [1, 2, 3] -> None!
  let b = [1, 2, 3]
  let vis_pw : Array[Int] = []
  let r_pw = b.search_by(fn(x) {
    vis_pw.push(x)
    if x == 1 {
      b.push(4)
      b[1] = 9
    }
    x == 9
  })
  // 3. `for x in f2 { if x == 1 { f2.clear() }; s += x }` -> 6!
  let f2 = [1, 2, 3]
  let mut s2 = 0
  for x in f2 {
    if x == 1 { f2.clear() }
    s2 = s2 + x
  }
  // 4. Spare-cap shrink_to_fit + write vs full-cap shrink_to_fit + write
  let sp : Array[Int] = Array(capacity=8)
  sp.push(1)
  sp.push(2)
  sp.push(3)
  let vis_sp : Array[Int] = []
  for x in sp {
    vis_sp.push(x)
    if x == 1 {
      sp.shrink_to_fit()
      sp[1] = 9
    }
  }
  let fl = [1, 2, 3]
  let vis_fl : Array[Int] = []
  for x in fl {
    vis_fl.push(x)
    if x == 1 {
      fl.shrink_to_fit()
      fl[1] = 9
    }
  }
  "INS:" + ints(vis_ins) + "|" + opt(r_ins) + "\n" +
  "PW:" + ints(vis_pw) + "|" + opt(r_pw) + "\n" +
  "F2:" + s2.to_string() + "\n" +
  "SHRINK:" + ints(vis_sp) + "|" + ints(vis_fl)
}
'''

NEGATIVES = {
    "insert_single_op": (r'''
pub fn f(xs : Array[Int]) -> Int? {
  xs.search_by(fn(x) {
    if x == 1 { xs.insert(0, 9) }
    x == 2
  })
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".insert(..)"),
    "push_write_search_by": (r'''
pub fn f(xs : Array[Int]) -> Int? {
  xs.search_by(fn(x) {
    if x == 1 {
      xs.push(4)
      xs[1] = 9
    }
    x == 9
  })
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "pop_search_by": (r'''
pub fn f(xs : Array[Int]) -> Int? {
  xs.search_by(fn(x) {
    if x == 1 { ignore(xs.pop()) }
    x == 2
  })
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".pop(..)"),
    "remove0_search_by": (r'''
pub fn f(xs : Array[Int]) -> Int? {
  xs.search_by(fn(x) {
    if x == 1 { ignore(xs.remove(0)) }
    x == 2
  })
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".remove(..)"),
    "remove1_iter": (r'''
pub fn f(xs : Array[Int]) -> Int {
  let it = xs.iter()
  ignore(xs.remove(1))
  it.count()
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".remove(..)"),
    "clear_iter": (r'''
pub fn f(xs : Array[Int]) -> Int {
  let it = xs.iter()
  xs.clear()
  it.count()
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "for_in_clear_snapshot": (r'''
pub fn f() -> Int {
  let f2 = [1, 2, 3]
  let mut s = 0
  for x in f2 {
    if x == 1 { f2.clear() }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "shrink_in_for_spare": (r'''
pub fn f() -> Int {
  let sp : Array[Int] = Array(capacity=8)
  sp.push(1)
  sp.push(2)
  let mut s = 0
  for x in sp {
    if x == 1 {
      sp.shrink_to_fit()
      sp[1] = 9
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_SHRINK_ITER", "for .. in"),
    "shrink_in_for_full": (r'''
pub fn f() -> Int {
  let fl = [1, 2, 3]
  let mut s = 0
  for x in fl {
    if x == 1 {
      fl.shrink_to_fit()
      fl[1] = 9
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_SHRINK_ITER", "for .. in"),
    "lazy_map_escape": (r'''
pub fn f(xs : Array[Int]) -> Int {
  let it = xs.iter().map(fn(x) { x + 1 })
  ignore(xs.pop())
  it.count()
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".pop(..)"),
    "combobox_opaque_cb": (r'''
fn active_of(keys : Array[Int], off : (Int) -> Bool) -> Int? {
  keys.iter().find_first(fn(k) { !off(k) })
}

pub fn f(keys : Array[Int], off : (Int) -> Bool) -> Int? {
  active_of(keys, off)
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "a call to `off(..)`"),
    "for_in_inner_break_remove": (r'''
pub fn f(xs : Array[Int], ys : Array[Int]) -> Int {
  let mut s = 0
  for x in xs {
    for y in ys {
      if y == 1 {
        let _ = xs.remove(0)
        break
      }
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "arr_remove(..)"),
    "for_in_closure_return_clear": (r'''
pub fn f(xs : Array[Int]) -> Int {
  let mut s = 0
  for x in xs {
    let g = fn() -> Int { xs.clear(); return 0 }
    s = s + g() + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "for_in_opaque_cb_with_arr": (r'''
pub fn f(xs : Array[Int], cb : (Array[Int]) -> Unit) -> Int {
  let mut s = 0
  for x in xs {
    cb(xs)
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "cb(..)"),
    "for_in_global_clear_pool": (r'''
let pool : Array[Int] = [1, 2, 3]
fn clear_pool() -> Unit { pool.clear() }
pub fn f() -> Int {
  let mut s = 0
  for x in pool {
    clear_pool()
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "clear_pool(..)"),
    "for_in_reset_self": (r'''
struct Box { items : Array[Int] }
fn reset(b : Box) -> Unit { b.items.clear() }
pub fn run(b : Box) -> Int {
  let mut s = 0
  for x in b.items {
    reset(b)
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "reset(..)"),
    "for_in_cross_fn_grow_write": (r'''
fn g(xs : Array[Int]) -> Unit { xs.push(4) }
pub fn f(xs : Array[Int]) -> Int {
  let mut s = 0
  for x in xs {
    g(xs)
    xs[1] = 9
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "search_by_iter_any_opaque_cb": (r'''
pub fn f(xs : Array[Int], cb : (Int) -> Bool) -> Int? {
  xs.search_by(fn(x) { [x].iter().any(cb) })
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".any(..)"),
    "confined_for_in_reenter_shrink": (r'''
struct S { items : Array[Int] }
pub fn iter_cb(s : S, cb : (S) -> Unit) -> Unit {
  for x in s.items {
    let _ = x
    cb(s)
  }
}
pub fn reset(s : S) -> Unit {
  s.items.shrink_to_fit()
}
''', "MBT2PION_ARRAY_SHRINK_ITER", "iterates an array named `items`"),
    "hook_push_search_by": (r'''
struct Hook { xs : Array[Int] }
fn Hook::push(self : Hook, v : Int) -> Unit {
  let _ = v
  self.xs.clear()
}
pub fn f(xs : Array[Int], h : Hook) -> Int? {
  xs.search_by(fn(x) { h.push(x); x == 2 })
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "search_by"),
    "hook_push_kept_iter": (r'''
struct Hook { xs : Array[Int] }
fn Hook::push(self : Hook, v : Int) -> Unit {
  let _ = v
  self.xs.clear()
}
pub fn f(xs : Array[Int], h : Hook) -> Int {
  let it = xs.iter()
  h.push(1)
  it.count()
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".push(..)"),
    "for_in_parens_clear": (r'''
pub fn f(xs : Array[Int]) -> Int {
  let mut s = 0
  for x in (xs) {
    xs.clear()
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "for_in_field_insert": (r'''
struct Box { items : Array[Int] }
pub fn f(b : Box) -> Int {
  let mut s = 0
  for x in b.items {
    b.items.insert(0, 9)
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "arr_insert(..)"),
    "for_in_field_alias_grow_write": (r'''
struct Box { items : Array[Int] }
pub fn f(b : Box) -> Int {
  let ys = b.items
  let mut s = 0
  for x in b.items {
    ys.push(4)
    ys[1] = 9
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_param_field_alias_grow_write": (r'''
struct Box { items : Array[Int] }
pub fn f(xs : Array[Int], b : Box) -> Int {
  let mut s = 0
  for x in xs {
    b.items.push(4)
    b.items[1] = 9
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_continue_in_let_before_break": (r'''
pub fn f(xs : Array[Int]) -> Int {
  let mut s = 0
  for x in xs {
    if x == 1 {
      xs.insert(0, 9)
      let _ = if x == 1 { continue } else { 0 }
      break
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "arr_insert(..)"),
    "for_in_tab_clear": (
        "pub fn f(xs : Array[Int]) -> Int {\n  let mut s = 0\n  for\tx in xs {\n    xs.clear()\n    s = s + x\n  }\n  s\n}\n",
        "MBT2PION_ARRAY_ITER_MUTATION",
        ".clear(..)",
    ),
    "hook_push_local_kept_iter": (r'''
struct Hook { a : Array[Int] }
fn Hook::push(self : Hook, v : Int) -> Unit {
  let _ = v
  self.a.clear()
}
pub fn f() -> Int {
  let xs = [1, 2, 3]
  let h : Hook = { a: xs }
  let it = xs.iter()
  h.push(4)
  it.to_array()[1]
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".push(..)"),
    "for_in_self_field_alias_grow_write": (r'''
struct Box { items : Array[Int] }
pub fn Box::run(self : Box, xs : Array[Int]) -> Int {
  let mut s = 0
  for x in xs {
    self.items.push(4)
    self.items[1] = 9
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_field_iter_param_clear": (r'''
struct Box { items : Array[Int] }
pub fn danger(b : Box, xs : Array[Int]) -> Int {
  let mut s = 0
  for x in b.items {
    xs.clear()
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "for_in_tuple_bad_eq": (r'''
struct BadEq { same : (BadEq) -> Bool }
impl Eq for BadEq with equal(self, other) { (self.same)(other) }
pub fn f(xs : Array[Int], bad : BadEq, pair : (Int, BadEq)) -> Int {
  let mut s = 0
  for x in xs {
    if (1, bad) == pair { s = s + x }
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "impl Eq"),
    "for_in_option_bad_eq": (r'''
struct BadEq { same : (BadEq) -> Bool }
impl Eq for BadEq with equal(self, other) { (self.same)(other) }
pub fn f(xs : Array[Int], a : BadEq, b : BadEq) -> Int {
  let mut s = 0
  for x in xs {
    if Some(a) == Some(b) { s = s + x }
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "impl Eq"),
    "for_in_dead_block_shadow_bad_eq": (r'''
struct BadEq { same : (BadEq) -> Bool }
impl Eq for BadEq with equal(self, other) { (self.same)(other) }
pub fn f(xs : Array[Int], bad : BadEq, target : BadEq) -> Int {
  if false { let target : Int = 0; let _ = target }
  let mut s = 0
  for x in xs {
    if bad == target { s = s + x }
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "impl Eq"),
    "for_in_sneaky_eq_split_grow_write": (r'''
struct SneakyEq { xs : Array[Int] }
impl Eq for SneakyEq with equal(self, other) {
  let _ = other
  self.xs.push(4)
  true
}
pub fn f(xs : Array[Int], a : SneakyEq, b : SneakyEq) -> Int {
  let mut s = 0
  for x in xs {
    if a == b { xs[1] = 99 }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "impl Eq"),
    "for_in_indirect_call_bad_eq": (r'''
struct BadEq { same : (BadEq) -> Bool }
impl Eq for BadEq with equal(self, other) { (self.same)(other) }
struct Holder { mk_bad : () -> BadEq }
pub fn f(xs : Array[Int], h : Holder, target : BadEq) -> Int {
  let mut s = 0
  for x in xs {
    if (h.mk_bad)() == target { s = s + x }
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "impl Eq"),
    "for_in_local_alias_box_clear": (r'''
struct Box { items : Array[Int] }
pub fn f(b : Box) -> Int {
  let xs = b.items
  let mut s = 0
  for x in xs {
    b.items.clear()
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "for_in_pub_field_wrapper_bad_eq": (r'''
pub(all) struct BadInner { same : (BadInner) -> Bool }
pub impl Eq for BadInner with equal(self, other) { (self.same)(other) }
pub(all) struct WrapPub { i : BadInner } derive(Eq)
pub fn f(xs : Array[Int], a : WrapPub, b : WrapPub) -> Int {
  let mut s = 0
  for x in xs {
    if a == b { s = s + x }
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "impl Eq"),
    "for_in_typed_field_alias_grow_write": (r'''
struct Box { items : Array[Int] }
pub fn f(b : Box) -> Int {
  let ys : Array[Int] = b.items
  let mut s = 0
  for x in b.items {
    ys.push(4)
    ys[1] = 9
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_paren_field_alias_grow_write": (r'''
struct Box { items : Array[Int] }
pub fn f(b : Box) -> Int {
  let ys = (b.items)
  let mut s = 0
  for x in b.items {
    ys.push(4)
    ys[1] = 9
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_sibling_field_grow_write": (r'''
struct Two { a : Array[Int]; b : Array[Int] }
pub fn f(v : Two) -> Int {
  let mut s = 0
  for x in v.a {
    v.b.push(4)
    v.b[1] = 9
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_computed_call_grow_write": (r'''
fn ident(xs : Array[Int]) -> Array[Int] { xs }
pub fn f(xs : Array[Int]) -> Int {
  let mut s = 0
  for x in ident(xs) {
    xs.push(4)
    xs[1] = 9
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_computed_index_grow_write": (r'''
pub fn f(bag : Array[Array[Int]], xs : Array[Int]) -> Int {
  let mut s = 0
  for x in bag[0] {
    xs.push(4)
    xs[1] = 9
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_local_closure_wipe": (r'''
pub fn f() -> Int {
  let xs = [1, 2, 3]
  let wipe = fn() { xs.clear() }
  let mut s = 0
  for x in xs {
    if x == 1 { wipe() }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "for_in_let_shadow_bad_eq": (r'''
struct BadEq { same : (BadEq) -> Bool }
impl Eq for BadEq with equal(self, other) { (self.same)(other) }
struct Holder { xs : Array[Int]; bad : BadEq }
pub fn f(t : Holder) -> Int {
  let mut s = 0
  for k in t.xs {
    let k = t.bad
    if k == k { s = s + 1 }
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "impl Eq"),
    "for_in_tuple_shadow_bad_eq": (r'''
struct BadEq { same : (BadEq) -> Bool }
impl Eq for BadEq with equal(self, other) { (self.same)(other) }
struct Holder { xs : Array[Int]; bad : BadEq }
pub fn f(t : Holder, pair : (BadEq, Int)) -> Int {
  let mut s = 0
  for k in t.xs {
    let (k, _) = pair
    if k == t.bad { s = s + 1 }
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "impl Eq"),
    "for_in_match_shadow_bad_eq": (r'''
struct BadEq { same : (BadEq) -> Bool }
impl Eq for BadEq with equal(self, other) { (self.same)(other) }
struct Holder { xs : Array[Int]; bad : BadEq }
pub fn f(t : Holder, opt : BadEq?) -> Int {
  let mut s = 0
  for k in t.xs {
    match opt {
      Some(k) => if k == t.bad { s = s + 1 }
      None => ()
    }
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "impl Eq"),
    "for_in_ret_field_direct_clear": (r'''
struct Box { items : Array[Int] }
fn get_items(b : Box) -> Array[Int] { b.items }
pub fn f(b : Box) -> Int {
  let mut s = 0
  for x in get_items(b) {
    b.items.clear()
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "for_in_ret_field_helper_wipe": (r'''
struct Box { items : Array[Int] }
fn get_items(b : Box) -> Array[Int] { b.items }
fn wipe_items(b : Box) -> Unit { b.items.clear() }
pub fn f(b : Box) -> Int {
  let mut s = 0
  for x in get_items(b) {
    wipe_items(b)
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "wipe_items"),
    "for_in_nested_field_direct_clear": (r'''
struct Grid { grid : Array[Array[Int]] }
pub fn f(g : Grid) -> Int {
  let mut s = 0
  for x in g.grid[0] {
    g.grid[0].clear()
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "for_in_nested_field_helper_wipe": (r'''
struct Grid { grid : Array[Array[Int]] }
fn wipe_grid(g : Grid) -> Unit { g.grid[0].clear() }
pub fn f(g : Grid) -> Int {
  let mut s = 0
  for x in g.grid[0] {
    wipe_grid(g)
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "wipe_grid"),
    "for_in_pub_pair_sibling_clear": (r'''
pub(all) struct Pair { a : Array[Int]; b : Array[Int] }
fn mk_pair() -> Pair { { a: [], b: [] } }
pub fn f(p : Pair) -> Int {
  let mut s = 0
  for x in p.a {
    p.b.clear()
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "for_in_priv_nonfresh_sibling_clear": (r'''
priv struct Pair2 { a : Array[Int]; b : Array[Int] }
fn mk_pair2(shared : Array[Int]) -> Pair2 { { a: shared, b: shared } }
pub fn f(p : Pair2) -> Int {
  let mut s = 0
  for x in p.a {
    p.b.clear()
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "for_in_flow_items_same_elem_param": (r'''
struct Box { items : Array[Int] }
fn get_items(b : Box) -> Array[Int] { b.items }
fn mutate_other(ys : Array[Int]) -> Unit { ys.clear() }
pub fn f(b : Box, ys : Array[Int]) -> Int {
  let mut s = 0
  for x in get_items(b) {
    mutate_other(ys)
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "mutate_other"),
    "for_in_nested_stage_same_elem_param": (r'''
struct Grid { grid : Array[Array[Int]] }
fn mutate_other(ys : Array[Int]) -> Unit { ys.clear() }
pub fn f(g : Grid, ti : Int, ys : Array[Int]) -> Int {
  let mut s = 0
  for x in g.grid[ti] {
    mutate_other(ys)
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "mutate_other"),
    "for_in_field_alias_passed_to_helper": (r'''
struct Box { items : Array[Int] }
fn mutate_other(ys : Array[Int]) -> Unit { ys.clear() }
pub fn f(b : Box) -> Int {
  let alias = b.items
  let mut s = 0
  for x in b.items {
    mutate_other(alias)
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "mutate_other"),
    "for_in_param_same_elem_passed_to_helper": (r'''
fn mutate_other(ys : Array[Int]) -> Unit { ys.clear() }
pub fn f(xs : Array[Int], ys : Array[Int]) -> Int {
  let mut s = 0
  for x in xs {
    mutate_other(ys)
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "mutate_other"),
    "for_in_ret_field_second_owner_param_wipe": (r'''
struct Box { items : Array[Int] }
fn get_items_2(dummy : Int, b : Box) -> Array[Int] { let _ = dummy; b.items }
fn wipe_items(b : Box) -> Unit { b.items.clear() }
pub fn f(b : Box) -> Int {
  let mut s = 0
  for x in get_items_2(0, b) {
    wipe_items(b)
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "wipe_items"),
    "for_in_nested_field_poisoned_by_non_nested": (r'''
struct NestMix { mixed : Array[Array[Int]] }
struct FlatMix { mixed : Array[Int] }
fn mutate_str(ys : Array[String]) -> Unit { ys.clear() }
pub fn f(nm : NestMix, ys : Array[String]) -> Int {
  let mut s = 0
  for x in nm.mixed[0] {
    mutate_str(ys)
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "mutate_str"),
    "for_in_generic_param_alias": (r'''
pub fn[T] f(xs : Array[Int], ys : Array[T], a : T, b : T) -> Int {
  let mut s = 0
  for x in xs {
    if x == 1 {
      ys.push(a)
      ys[1] = b
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_generic_struct_field_alias": (r'''
priv struct GenBox[T] { xs : Array[Int]; ys : Array[T] }
fn mk_gb[T](xs : Array[Int], ys : Array[T]) -> GenBox[T] { { xs, ys } }
pub fn[T] f(v : GenBox[T], a : T, b : T) -> Int {
  let _ = mk_gb
  let mut s = 0
  for x in v.xs {
    if x == 1 {
      v.ys.push(a)
      v.ys[1] = b
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_param_shadows_fresh_fn": (r'''
fn hp(xs : Array[Int]) -> Array[Int] { let _ = xs; [9] }
pub fn f(xs : Array[Int], hp : (Array[Int]) -> Array[Int]) -> Int {
  let mut s = 0
  for x in hp(xs) {
    if x == 1 {
      xs.push(4)
      xs[1] = 9
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_local_closure_shadows_fresh_fn": (r'''
fn produce(xs : Array[Int]) -> Array[Int] { let _ = xs; [9] }
pub fn f(xs : Array[Int]) -> Int {
  let produce = fn(a : Array[Int]) -> Array[Int] { a }
  let mut s = 0
  for x in produce(xs) {
    if x == 1 {
      xs.push(4)
      xs[1] = 9
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_deep_if_else_return_truncation": (r'''
fn deep_ret(b : Bool, xs : Array[Int]) -> Array[Int] {
  if b { [9] } else { if b { [9] } else { if b { [9] } else { if b { [9] } else { if b { [9] } else { if b { [9] } else { if b { [9] } else { if b { [9] } else { xs } } } } } } } }
}
pub fn f(xs : Array[Int]) -> Int {
  let mut s = 0
  for x in deep_ret(false, xs) {
    if x == 1 {
      xs.push(4)
      xs[1] = 9
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_priv_nested_inner_alias_write": (r'''
priv struct NestBox { grid : Array[Array[Int]]; other : Array[Int] }
fn mk_nb(xs : Array[Int]) -> NestBox { { grid: [xs], other: xs } }
pub fn f(v : NestBox) -> Int {
  let _ = mk_nb
  let mut s = 0
  for x in v.other {
    if x == 1 {
      v.grid[0].push(4)
      v.grid[0][1] = 9
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_priv_nested_iter_sibling_write": (r'''
priv struct NestBox { grid : Array[Array[Int]]; other : Array[Int] }
fn mk_nb(xs : Array[Int]) -> NestBox { { grid: [xs], other: xs } }
pub fn f(v : NestBox) -> Int {
  let _ = mk_nb
  let mut s = 0
  for x in v.grid[0] {
    if x == 1 {
      v.other.push(4)
      v.other[1] = 9
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "for_in_pub_nested_inner_alias_write": (r'''
pub(all) struct NestPub { grid : Array[Array[Int]]; other : Array[Int] }
pub fn f(v : NestPub) -> Int {
  let mut s = 0
  for x in v.other {
    if x == 1 {
      v.grid[0].push(4)
      v.grid[0][1] = 9
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
}


def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=600)
    if p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
    return p.stdout.strip()


def run_rc(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=600)
    return p.returncode, p.stdout + p.stderr


def write(path, txt):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(txt)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", default=os.environ.get("PIONC", shutil.which("pionc") or os.path.expanduser("~/.pion/bin/pionc")))
    ap.add_argument("--moon", default=os.environ.get("MOON", shutil.which("moon") or os.path.expanduser("~/.moon/bin/moon")))
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="mbt2pion-f4-1-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])

        md = os.path.join(work, "moon_proj")
        files = [
            ("moon.mod", 'name = "f41/oracle"\n'),
            ("pos/moon.pkg", "\n"),
            ("pos/pos.mbt", POS_MBT),
            ("ref/moon.pkg", "\n"),
            ("ref/ref.mbt", MOON_REF_MBT),
            ("cmd_pos/moon.pkg", 'import { "f41/oracle/pos" }\npkgtype(kind: "executable")\n'),
            ("cmd_pos/main.mbt", "fn main { println(@pos.run_all()) }\n"),
            ("cmd_ref/moon.pkg", 'import { "f41/oracle/ref" }\npkgtype(kind: "executable")\n'),
            ("cmd_ref/main.mbt", "fn main { println(@ref.run_counterexamples()) }\n"),
        ]
        for rel, txt in files:
            write(os.path.join(md, rel), txt)

        # 1. Run MoonBit on BOTH native AND wasm-gc!
        moon_pos_native = run_cmd([args.moon, "run", "--target", "native", "cmd_pos"], cwd=md)
        moon_pos_wasmgc = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd_pos"], cwd=md)
        assert moon_pos_native == moon_pos_wasmgc, f"Moon native != wasm-gc:\n{moon_pos_native}\nvs\n{moon_pos_wasmgc}"

        moon_ref_native = run_cmd([args.moon, "run", "--target", "native", "cmd_ref"], cwd=md)
        moon_ref_wasmgc = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd_ref"], cwd=md)
        expected_ref = (
            "INS:1,2|Some(1)\n"
            "PW:1,2,3|None\n"
            "F2:6\n"
            "SHRINK:1,2,3|1,9,3"
        )
        assert moon_ref_native == expected_ref, f"Moon native ref mismatch:\n{moon_ref_native}\nvs\n{expected_ref}"
        assert moon_ref_wasmgc == expected_ref, f"Moon wasm-gc ref mismatch:\n{moon_ref_wasmgc}\nvs\n{expected_ref}"

        # 2. Transpile positive package with mbt2pion and run on BOTH Pion native AND Pion wasm32!
        pl = os.path.join(work, "p_pos")
        write(os.path.join(pl, "pion.toml"),
              f'[package]\nname = "pos"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        os.makedirs(os.path.join(pl, "src"))
        run_cmd([bin_path, "--src", os.path.join(md, "pos"), "--out", os.path.join(pl, "src"), "--target", "native",
                 "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        write(os.path.join(pl, "src", "main.pion"), "pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n")
        pion_native = run_cmd([args.pionc, "run", pl])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", pl])

        assert pion_native == moon_pos_native and pion_wasm == moon_pos_native, (
            f"4-TARGET MISMATCH:\nMOON_NATIVE:\n{moon_pos_native}\nMOON_WASMGC:\n{moon_pos_wasmgc}\n"
            f"PION_NATIVE:\n{pion_native}\nPION_WASM32:\n{pion_wasm}"
        )

        # 3. Verify all negative counterexamples fail closed with no --out written!
        for name, (src, code, needle) in NEGATIVES.items():
            d = os.path.join(work, "neg_" + name)
            write(os.path.join(d, "moon.pkg"), "\n")
            write(os.path.join(d, "neg.mbt"), src)
            out = os.path.join(work, "p_neg_" + name, "src")
            os.makedirs(out)
            rc, log = run_rc([bin_path, "--src", d, "--out", out, "--target", "native", "--mode", "publish",
                              "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
            assert rc != 0 and code in log and needle in log, (
                f"{name} must block publish with {code} containing `{needle}`:\n{log}"
            )
            assert not os.listdir(out), f"{name}: blocked publish must not write --out"

        # 3b. Cross-package negative: unrelated local `struct Local { items : Array[String] }` must NOT
        #     pollute foreign `@dep.Holder { items : Array[Int] }` field type or distinctness!
        dep_src = os.path.join(work, "dep_shadow_src")
        dep_pkg = os.path.join(work, "dep_shadow_pkg")
        write(os.path.join(dep_src, "moon.pkg"), "\n")
        write(os.path.join(dep_src, "dep.mbt"), "pub(all) struct Holder { items : Array[Int] }\n")
        write(os.path.join(dep_pkg, "pion.toml"),
              f'[package]\nname = "dep"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        os.makedirs(os.path.join(dep_pkg, "src"))
        run_cmd([bin_path, "--src", dep_src, "--out", os.path.join(dep_pkg, "src"), "--target", "native",
                 "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        cons_src = os.path.join(work, "cons_shadow_src")
        cons_out = os.path.join(work, "cons_shadow_pkg", "src")
        write(os.path.join(cons_src, "moon.pkg"), 'import { "f41/oracle/dep" }\n')
        write(os.path.join(cons_src, "cons.mbt"), r'''
priv struct Local { items : Array[String] }
fn mk_local() -> Local { { items: [] } }
pub fn f(v : @dep.Holder, xs : Array[Int]) -> Int {
  let _ = mk_local
  let mut s = 0
  for x in v.items {
    if x == 1 {
      xs.push(4)
      xs[1] = 9
    }
    s = s + x
  }
  s
}
''')
        os.makedirs(cons_out)
        rc_dep, log_dep = run_rc([bin_path, "--src", cons_src, "--out", cons_out, "--target", "native",
                                  "--mode", "publish", "--dep", f"dep={dep_pkg}",
                                  "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        assert rc_dep != 0 and "MBT2PION_ARRAY_ITER_MUTATION" in log_dep and "appended to and written" in log_dep, (
            f"dep_local_field_shadow must block publish with MBT2PION_ARRAY_ITER_MUTATION:\n{log_dep}"
        )
        assert not os.listdir(cons_out), "dep_local_field_shadow: blocked publish must not write --out"

        print("[f4-1-oracle] PASS: 4-target parity (Moon native == Moon wasm-gc == Pion native == Pion wasm32)!")
        print(moon_pos_native)
        print(f"[f4-1-oracle] PASS: Moon dual-backend counterexamples verified ({expected_ref.replace(chr(10), ' ; ')})")
        print(f"[f4-1-oracle] PASS: All {len(NEGATIVES) + 1} fail-closed negatives (incl. cross-package dep field shadow) blocked with exact diagnostics!")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
