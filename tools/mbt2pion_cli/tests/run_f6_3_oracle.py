#!/usr/bin/env python3
r"""Wave F6-3a 4-Target Differential Oracle & Adversarial Soundness Suite:
MoonBit native == MoonBit wasm-gc == Pion native == Pion wasm32.

Positive 4-target parity cases:
  1. Gate A: non-escaping local array `for v in faded { ... }; faded.clear(); faded.shrink_to_fit()`.
  2. Gate B: pure `Array::search_by` penetrating method body `View::same`.
  3. Gate C: pure immediate `.iter().any` / `.all` / `.find_first` penetrating `View::alive -> live`,
     including an uncalled sibling closure containing `clear()` / `remove(0)`.
  4. Gate D: `for x in recv()[lo():hi()]` where `hi()` appends `3` to `[1, 2]` and returns `3`
     (exact trace `recv -> lo -> hi`, yields `2,3`), `[1,2,3][-2:99]` -> `1,2,3`, `[2:1]` -> empty,
     empty array `arr[1:]`, and `for k in visible[1:]` with multiple `break`s.

Negative fail-closed soundness cases (ALL 7 mutation_summary classes + Gate A/B/C/D adversaries):
  1. Class 1: trait dispatch (`dyn Checker` / generic trait bound) inside callback -> fail-closed.
  2. Class 2: operator `impl Add` mutating array inside callback -> fail-closed.
  3. Class 3: re-entrant stored closure in array/struct called inside `.iter().any` -> fail-closed.
  4. Class 3b: public API `KeyWhen::All(ws)` + `has : (String) -> Bool` callback -> fail-closed.
  5. Class 4: unknown external / opaque callback mutating array -> fail-closed.
  6. Class 5: generic `fn[T]` writing `Array[T]` called inside `.search_by` -> fail-closed.
  7. Class 6: field reassignment `self.items = []` inside `.iter().any` -> fail-closed.
  8. Class 7: mutating `Array` method / index write `ws[1] = ...` inside `for k in ws[1:]` -> fail-closed.
  9. Gate A adversary: capacity 8, `[1]`, kept `let it = a.iter()`, `a.shrink_to_fit()`, `a[0] = 9` -> fail-closed.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

POSITIVE_MBT = r'''
pub struct View {
  id : Int
  alive_flag : Bool
}

fn View::same(self : View, other : View) -> Bool {
  self.id == other.id
}

fn live(v : View) -> Bool {
  v.alive_flag && v.id > 0
}

fn View::alive(self : View) -> Bool {
  live(self)
}

fn score(v : Int) -> Int {
  v * 2 + 1
}

// Gate A: non-escaping local array allocated via `Array::make` iterated then cleared and shrunk
// (unlocks `mutation_summary_allow_a` in drift_ledger)
pub fn run_gate_a() -> String {
  let faded : Array[Int] = Array::make(3, 10)
  let mut total = 0
  for v in faded {
    total = total + score(v)
  }
  faded.clear()
  faded.shrink_to_fit()
  total.to_string() + ":" + faded.length().to_string()
}

// Gate B: pure `search_by` penetrating `View::same`
pub fn run_gate_b() -> String {
  let v1 = View::{ id: 1, alive_flag: true }
  let v2 = View::{ id: 2, alive_flag: false }
  let v3 = View::{ id: 3, alive_flag: true }
  let entries : Array[(View, Int)] = [(v1, 100), (v2, 200), (v3, 300)]
  let r1 = match entries.search_by(fn(e) { e.0.same(v2) }) {
    Some(i) => i.to_string()
    None => "none"
  }
  let missing = View::{ id: 99, alive_flag: true }
  let r2 = match entries.search_by(fn(e) { e.0.same(missing) }) {
    Some(i) => i.to_string()
    None => "none"
  }
  r1 + "|" + r2
}

// Gate C: pure immediate `.iter().any` / `.all` / `.find_first` penetrating `View::alive -> live`,
// with an uncalled sibling closure that contains `clear()` and `remove(0)`.
pub fn run_gate_c() -> String {
  let xs : Array[View] = [
    View::{ id: 1, alive_flag: false },
    View::{ id: 2, alive_flag: true },
    View::{ id: 3, alive_flag: true },
  ]
  let sibling_mut = fn() {
    if xs.length() > 0 {
      let _ = xs.remove(0)
    }
    xs.clear()
  }
  let _ = sibling_mut
  let has_any = xs.iter().any(fn(o) { o.alive() })
  let all_alive = xs.iter().all(fn(o) { o.alive() })
  let first_id = match xs.iter().find_first(fn(o) { o.alive() }) {
    Some(v) => v.id
    None => -1
  }
  has_any.to_string() + "|" + all_alive.to_string() + "|" + first_id.to_string() + "|" + xs.length().to_string()
}

fn run_slice_len_rebind(init : Array[Int]) -> Int {
  let mut xs : Array[Int] = init
  let get_lo = fn() -> Int {
    xs = [8]
    0
  }
  xs[get_lo():].length()
}

// Gate D: borrowed slice loops with exact eval order, clamping, empty array, and multiple breaks
pub fn run_gate_d() -> String {
  let trace : Array[String] = []
  let arr : Array[Int] = [1, 2]
  let get_recv = fn() -> Array[Int] {
    trace.push("recv")
    arr
  }
  let get_lo = fn() -> Int {
    trace.push("lo")
    1
  }
  let get_hi = fn() -> Int {
    trace.push("hi")
    arr.push(3)
    3
  }
  let seen1 : Array[String] = []
  for x in get_recv()[get_lo():get_hi()] {
    seen1.push(x.to_string())
  }

  let base : Array[Int] = [1, 2, 3]
  let seen2 : Array[String] = []
  for x in base[-2:99] {
    seen2.push(x.to_string())
  }
  let seen3 : Array[String] = []
  for x in base[2:1] {
    seen3.push(x.to_string())
  }
  let empty_a : Array[Int] = []
  let seen4 : Array[String] = []
  for x in empty_a[1:] {
    seen4.push(x.to_string())
  }

  let visible : Array[View] = [
    View::{ id: 10, alive_flag: true },
    View::{ id: 20, alive_flag: true },
    View::{ id: 30, alive_flag: false },
    View::{ id: 40, alive_flag: true },
  ]
  let mut stop_id = -1
  let seen5 : Array[String] = []
  for k in visible[1:] {
    if !k.alive() {
      stop_id = k.id
      break
    }
    seen5.push(k.id.to_string())
    if k.id == 99 {
      stop_id = 99
      break
    }
  }

  let mut xs_rebind : Array[Int] = [1, 2, 3]
  let get_lo_rebind = fn() -> Int {
    xs_rebind = [8]
    0
  }
  let seen6 : Array[String] = []
  for x in xs_rebind[get_lo_rebind():] {
    seen6.push(x.to_string())
  }

  let mut xs_rebind2 : Array[Int] = [1, 2, 3]
  let get_lo_rebind2 = fn() -> Int {
    xs_rebind2 = [8]
    0
  }
  let seen7 : Array[String] = []
  for x in xs_rebind2[get_lo_rebind2():xs_rebind2.length()] {
    seen7.push(x.to_string())
  }

  let mut xs_rebind3 : Array[Int] = [1, 2, 3]
  let get_lo_rebind3 = fn() -> Int {
    xs_rebind3 = [8]
    0
  }
  let seen8 : Array[String] = []
  for x in xs_rebind3[get_lo_rebind3():].to_array() {
    seen8.push(x.to_string())
  }

  let len_rebind4 = run_slice_len_rebind([1, 2, 3])

  let lo_paren = fn(s : String) -> Int {
    s.length()
  }
  let seen9 : Array[String] = []
  for x in base[lo_paren(")"):3] {
    seen9.push(x.to_string())
  }
  let seen10 : Array[String] = []
  for x in base[0:lo_paren(")")] {
    seen10.push(x.to_string())
  }

  trace.join(">") + ":" + seen1.join(",") + "|" +
    seen2.join(",") + "|" + seen3.join(",") + "|" + seen4.join(",") + "|" +
    seen5.join(",") + ":" + stop_id.to_string() + "|" +
    seen6.join(",") + "|" + seen7.join(",") + "|" +
    seen8.join(",") + "|" + len_rebind4.to_string() + "|" +
    seen9.join(",") + "|" + seen10.join(",")
}

// Wave F6-3b positive cases: physical_equal, pure derive(Eq) struct/enum,
// recursive .iter().any + pure String methods, Buffer(capacity=...), and sibling enum ctors
enum NodeKind {
  XElement
  XText(String)
} derive(Eq)

struct CellStyle {
  color : Int
  bold : Bool
  kind : NodeKind
} derive(Eq)

struct DomNode {
  style : CellStyle
  kind : NodeKind
}

struct DepGraph {
  heads : Array[Array[Int]]
  labels : Array[String]
}

fn DepGraph::reads_under(self : DepGraph, id : Int, depth : Int) -> Bool {
  if depth > 4 || id < 0 || id >= self.heads.length() {
    return false
  }
  let lbl = self.labels[id]
  if lbl.trim().to_lower().contains("hit") && lbl.starts_with("x") {
    return true
  }
  let hs = self.heads[id]
  hs.iter().any(fn(g) { self.reads_under(g, depth + 1) })
}

enum AnchorSide {
  Above
  Below
  Left
  Right
} derive(Eq)

enum AlignDir {
  Left
  Right
  Center
} derive(Eq)

enum HoldRead {
  Ready
  Cancelled
} derive(Eq)

enum JobState {
  Pending
  Cancelled
} derive(Eq)

fn flip_anchor(asked : AnchorSide) -> (Int, Int, Int, AnchorSide) {
  let out = match asked {
    Below => {
      let t = 1
      (t, 2, 3, Above)
    }
    Above => (2, 1, 3, Below)
    Right => (4, 5, 6, Left)
    Left => (5, 4, 6, Right)
  }
  out
}

fn pick_hold(cond : Bool) -> HoldRead {
  let res = if cond {
    let _ = 1
    Ready
  } else {
    Cancelled
  }
  res
}

pub fn run_f63b() -> String {
  let target : Array[Int] = [7]
  let views : Array[Array[Int]] = [[1], target]
  let pe_ok = views.iter().any(fn(v) { physical_equal(v, target) })

  let st_a = CellStyle::{ color: 3, bold: true, kind: XElement }
  let st_b = CellStyle::{ color: 4, bold: false, kind: XText("hi") }
  let nodes : Array[DomNode] = [
    DomNode::{ style: st_b, kind: XText("hi") },
    DomNode::{ style: st_a, kind: XElement },
  ]
  let eq_ok = nodes.iter().any(fn(n) { n.style == st_a && n.kind == XElement })

  let dg = DepGraph::{
    heads: [[1], [2], []],
    labels: ["a", "b", "xHIT "],
  }
  let rec_ok = [0].iter().any(fn(root) { dg.reads_under(root, 0) })

  let whole = Buffer(capacity=16)
  whole.write_bytesview(b"ab"[:])
  whole.write_byte(b'!')
  let buf_len = whole.to_bytes().length()

  let (_, _, _, s1) = flip_anchor(Right)
  let h1 = pick_hold(false)
  let sib_ok = s1 == AnchorSide::Left && h1 == HoldRead::Cancelled

  let _ = AlignDir::Center
  let _ = JobState::Pending
  pe_ok.to_string() + "|" + eq_ok.to_string() + "|" + rec_ok.to_string() + "|" +
    buf_len.to_string() + "|" + sib_ok.to_string()
}

fn pos_f6_4a_scalar_sort_nan_signed_zero() -> String {
  let nan = 0.0 / 0.0
  let inf = 1.0 / 0.0
  let ninf = -1.0 / 0.0
  let xs : Array[Double] = [2.5, -0.0, nan, 0.0, -1.5, inf, ninf, -0.0, 0.0]
  xs.sort()
  let out : Array[String] = []
  for x in xs {
    if x.is_nan() {
      out.push("nan")
    } else if x == 0.0 {
      if 1.0 / x < 0.0 {
        out.push("-0")
      } else {
        out.push("+0")
      }
    } else if x == inf {
      out.push("+inf")
    } else if x == ninf {
      out.push("-inf")
    } else {
      out.push(x.to_int().to_string())
    }
  }
  out.join(",")
}

fn pos_f6_4a_newline_paren_bracket_stmt() -> String {
  let xs : Array[Int] = [0, 1, 2]
  let r1 = xs.search_by(fn(x) {
    let m : Map[Int, Int] = { 1: 2 }
    (m.contains(x))
  })
  let r2 = xs.search_by(fn(x) {
    let m : Map[Int, Int] = { 1: 2 }
    [m.contains(x)][0]
  })
  let s1 = match r1 { Some(i) => i.to_string(); None => "none" }
  let s2 = match r2 { Some(i) => i.to_string(); None => "none" }
  s1 + "|" + s2
}

fn pos_f6_4a_mid_closure_local_map() -> String {
  let xs : Array[Int] = [0, 1, 2]
  let ext : Map[Int, Int] = { 2: 9 }
  let mid_local = fn() -> Int? {
    let m : Map[Int, Int] = { 1: 2 }
    xs.search_by(fn(x) { m.contains(x) })
  }
  let m_outer : Map[Int, Int] = { 1: 2 }
  let mid_post = fn() -> Int? {
    let found = xs.search_by(fn(x) { m_outer.contains(x) })
    let m_outer : Map[Int, Int] = ext
    let _ = m_outer.size()
    found
  }
  let mid_closed_blk = fn(cond : Bool) -> Int? {
    if cond {
      let m_outer : Map[Int, Int] = ext
      let _ = m_outer.size()
    }
    xs.search_by(fn(x) { m_outer.contains(x) })
  }
  let mid_expr_blk_sb = fn() -> Int? {
    let tmp = {
      let m_outer : Map[Int, Int] = ext
      m_outer
    }
    let _ = tmp.size()
    xs.search_by(fn(x) { m_outer.contains(x) })
  }
  let mid_expr_blk_sb_other = fn() -> Int? {
    let tmp = {
      let other : Map[Int, Int] = ext
      other
    }
    let _ = tmp.size()
    xs.search_by(fn(x) { m_outer.contains(x) })
  }
  let xs_one : Array[Int] = [1]
  let mid_expr_blk_any = fn() -> Int {
    let tmp = {
      let m_outer : Map[Int, Int] = ext
      m_outer
    }
    let _ = tmp.size()
    if xs_one.iter().any(fn(x) { m_outer.contains(x) }) { 1 } else { 0 }
  }
  let mid_expr_blk_any_other = fn() -> Int {
    let tmp = {
      let other : Map[Int, Int] = ext
      other
    }
    let _ = tmp.size()
    if xs_one.iter().any(fn(x) { m_outer.contains(x) }) { 1 } else { 0 }
  }
  let s1 = match mid_local() { Some(i) => i.to_string(); None => "none" }
  let s2 = match mid_post() { Some(i) => i.to_string(); None => "none" }
  let s3 = match mid_closed_blk(true) { Some(i) => i.to_string(); None => "none" }
  let s4 = match mid_expr_blk_sb() { Some(i) => i.to_string(); None => "none" }
  let s5 = match mid_expr_blk_sb_other() { Some(i) => i.to_string(); None => "none" }
  let s6 = mid_expr_blk_any().to_string()
  let s7 = mid_expr_blk_any_other().to_string()
  s1 + "|" + s2 + "|" + s3 + "|" + s4 + "|" + s5 + "|" + s6 + "|" + s7
}

struct PureMapBox {
  group_reads : Map[Int, (Bool, Array[Int])]
}

fn PureMapBox::new() -> PureMapBox {
  PureMapBox::{ group_reads: Map::new() }
}

fn PureMapBox::set_group(self : PureMapBox, id : Int, g : Bool, hs : Array[Int]) -> Unit {
  self.group_reads[id] = (g, hs)
}

fn PureMapBox::reads_under(self : PureMapBox, id : Int, depth : Int) -> Bool {
  match self.group_reads.get(id) {
    Some((glass, heads)) =>
      glass || depth > 8 || heads.iter().any(fn(g) { self.reads_under(g, depth + 1) })
    None => false
  }
}

let top_pure_set : Set[String] = Set::from_array(["alpha", "beta"])

fn make_pure_key_map(keys : Array[Int]) -> Map[Int, Bool] {
  let out : Map[Int, Bool] = Map::new()
  for k in keys {
    out[k] = true
  }
  out
}

enum CtxTag {
  UseNode
  PathNode
} derive(Eq)

struct Word {
  raw : String
}

fn Word::get() -> String {
  "  hello:world  "
}

fn pos_precision_and_compat() -> String {
  let box = PureMapBox::new()
  box.set_group(1, false, [2])
  box.set_group(2, true, [])
  let map_field_ok = box.reads_under(1, 0)
  let ro_interp = "ro=\{box.reads_under(1, 0)}"

  let words : Array[String] = ["gamma", "beta"]
  let top_set_ok = words.iter().any(fn(w) { top_pure_set.contains(w) })

  let km = make_pure_key_map([10, 20])
  let ret_map_ok = [5, 20].iter().any(fn(k) { km.contains(k) })

  let check_ctx = fn(ce : CtxTag?) -> Bool { ce == Some(UseNode) }
  let ctx_ok = [None, Some(PathNode), Some(UseNode)].iter().any(fn(c) { check_ctx(c) })

  let split_first = match "a::b::c".split("::").next() {
    Some(v) => v.to_owned()
    None => "none"
  }
  let split_empty = match "".split(":").next() {
    Some(v) => v.to_owned()
    None => "none"
  }
  let split_static = match Word::get().split(":").next() {
    Some(v) => v.to_owned()
    None => "none"
  }
  let split_chain = match Word::get().trim().split(":").next() {
    Some(v) => v.to_owned()
    None => "none"
  }
  let base_s = "left"
  let split_paren = match (base_s + ":z").split(":").next() {
    Some(v) => v.to_owned()
    None => "none"
  }
  let arr_s = ["k0:v0", "k1:v1"]
  let split_idx = match arr_s[0].split(":").next() {
    Some(v) => v.to_owned()
    None => "none"
  }
  let split_any = "foo bar baz".split(" ").any(fn(v) { v.to_owned() == "bar" })

  let j = Json::string("k:\{match true { true => "yes"; false => "no" }}")
  let j_str = j.stringify()

  let wide_obj : Map[String, Json] = Map::new()
  wide_obj["short_arr"] = Json::array([Json::null(), Json::boolean(true)])
  wide_obj["long_val"] = Json::string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  let wide_repr = Repr(Json::object(wide_obj)).to_string()

  let mut deep_j = Json::null()
  for i = 0; i < 20; i = i + 1 {
    deep_j = Json::array([deep_j])
  }
  let deep_repr = Repr(deep_j).to_string()

  map_field_ok.to_string() + "|" + ro_interp + "|" + top_set_ok.to_string() + "|" + ret_map_ok.to_string() + "|" +
    ctx_ok.to_string() + "|" + split_first + "|" + split_empty + "|" + split_static + "|" + split_chain + "|" +
    split_paren + "|" + split_idx + "|" + split_any.to_string() + "|" + j_str + "|" + wide_repr + "|" + deep_repr
}

// Wave F6-4c-2 positive cases: MbtJson::Object pure-map provenance, Gate D2 read-only slice arg,
// and multiline match arm if-guard.
struct JsonEv {
  out : Bool
  msg : Json
}

fn json_id_of(m : Map[String, Json]) -> Int? {
  match m.get("id") {
    Some(Number(d, ..)) => Some(d.to_int())
    _ => None
  }
}

fn scan_ro_slice_sum(run : ArrayView[Int]) -> Int {
  let mut s = 0
  for x in run {
    s = s + x
  }
  s
}

fn pos_f6_4c_2_view_core_unblock() -> String {
  let o1 : Map[String, Json] = Map::new()
  o1["id"] = Json::number(7.0)
  o1["ok"] = Json::boolean(true)
  let evs : Array[JsonEv] = [
    JsonEv::{ out: true, msg: Json::object(o1) },
    JsonEv::{ out: false, msg: Json::object(o1) },
  ]
  let has_ans = evs.iter().any(fn(e) {
    !e.out && e.msg is Object(m) && (m.contains("ok") || m.contains("error")) && json_id_of(m) == Some(7)
  })
  let nums : Array[Int] = [10, 20, 30, 40]
  let sl_sum = scan_ro_slice_sum(nums[1:3])
  let km : Map[Int, Int] = Map::new()
  km[2] = 20
  km[4] = 40
  let guard_ok = match Some(2) {
    Some(v) if km.contains(v) &&
      physical_equal(nums, nums) => true
    _ => false
  }
  let guard_any = [1, 2, 3].iter().any(fn(x) { km.contains(x) })
  has_ans.to_string() + "|" + sl_sum.to_string() + "|" + guard_ok.to_string() + "|" + guard_any.to_string()
}

pub fn run_all() -> String {
  run_gate_a() + " :: " + run_gate_b() + " :: " + run_gate_c() + " :: " + run_gate_d() + " :: " + run_f63b() + " :: " + pos_f6_4a_scalar_sort_nan_signed_zero() + " :: " + pos_f6_4a_newline_paren_bracket_stmt() + " :: " + pos_f6_4a_mid_closure_local_map() + " :: " + pos_precision_and_compat() + " :: " + pos_f6_4c_2_view_core_unblock()
}
'''

NEGATIVE_CASES = [
    (
        "neg_class1_trait_dispatch",
        r'''
trait Pred {
  test_it(Self) -> Bool
}
fn[T : Pred] run(xs : Array[T]) -> Bool {
  xs.iter().any(fn(x) { x.test_it() })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_class2_impl_add_mutates",
        r'''
struct BadNum {
  xs : Array[Int]
}
impl Add for BadNum with add(self, other) {
  self.xs.clear()
  other
}
fn run(xs : Array[Int], b : BadNum) -> Int? {
  xs.search_by(fn(_x) {
    let _ = b + b
    false
  })
}
''',
        "Array::search_by",
    ),
    (
        "neg_class3_reentrant_stored_closure",
        r'''
pub fn run(xs : Array[Int]) -> Bool {
  let killer = fn() { xs.clear() }
  let box_cb : Array[() -> Unit] = [killer]
  xs.iter().any(fn(x) {
    (box_cb[0])()
    x > 0
  })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_class3b_keywhen_param_cb",
        r'''
pub(all) enum KeyWhen {
  All(Array[String])
}
pub fn matches(kw : KeyWhen, has : (String) -> Bool) -> Bool {
  match kw {
    All(ws) => ws.iter().all(fn(k) { has(k) })
  }
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_class5_generic_array_write",
        r'''
fn[T] push_any(xs : Array[T], v : T) -> Unit {
  xs.push(v)
}
pub fn run(xs : Array[Int]) -> Int? {
  xs.search_by(fn(x) {
    push_any(xs, x)
    false
  })
}
''',
        "Array::search_by",
    ),
    (
        "neg_class6_field_reassign",
        r'''
struct Bag {
  mut items : Array[Int]
}
fn Bag::reset(self : Bag) -> Unit {
  self.items = []
}
pub fn run(b : Bag) -> Bool {
  b.items.iter().any(fn(x) {
    b.reset()
    x > 0
  })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_class7_slice_loop_index_write",
        r'''
pub fn run(ws : Array[Int]) -> Int {
  let mut acc = 0
  for k in ws[1:] {
    ws[0] = k
    acc = acc + k
  }
  acc
}
''',
        "MBT2PION_BORROWED_ARRAY_SLICE",
    ),
    (
        "neg_gate_a_cap8_kept_iter_shrink",
        r'''
pub fn run() -> Int {
  let a : Array[Int] = Array::new(capacity=8)
  a.push(1)
  let it = a.iter()
  a.shrink_to_fit()
  a[0] = 9
  match it.head() {
    Some(v) => v
    None => -1
  }
}
''',
        "MBT2PION_ARRAY_SHRINK_ITER",
    ),
    (
        "neg_class2_impl_eq_with_equal",
        r'''
struct EvilEq {
  xs : Array[Int]
}
impl Eq for EvilEq with equal(self, other) {
  self.xs.clear()
  let _ = other
  true
}
pub fn run(xs : Array[Int], a : EvilEq, b : EvilEq) -> Int? {
  xs.search_by(fn(_x) {
    a == b
  })
}
''',
        "Array::search_by",
    ),
    (
        "neg_class2_unary_neg_newline",
        r'''
struct EvilNeg {
  xs : Array[Int]
}
impl Neg for EvilNeg with neg(self) {
  self.xs.clear()
  self
}
pub fn run(xs : Array[Int], b : EvilNeg) -> Int? {
  xs.search_by(fn(_x) {
    let y = 1
    let _ = y
    let _ =
    -(b)
    false
  })
}
''',
        "Array::search_by",
    ),
    (
        "neg_iter_next_lazy_mut",
        r'''
pub fn run(xs : Array[Int]) -> Bool {
  let it = xs.iter().map(fn(x) {
    xs.clear()
    x
  })
  xs.iter().any(fn(_x) {
    let _ = it.next()
    true
  })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_static_hof_fixed_array_makei",
        r'''
pub fn run(xs : Array[Int]) -> Bool {
  xs.iter().any(fn(_x) {
    let _ = FixedArray::makei(1, fn(_) {
      xs.clear()
      0
    })
    true
  })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_static_hof_option_map",
        r'''
pub fn run(xs : Array[Int]) -> Bool {
  xs.iter().any(fn(_x) {
    let _ = Option::map(Some(1), fn(_) {
      xs.clear()
      0
    })
    true
  })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_pattern_shadow_pure_fn",
        r'''
fn helper() -> Unit {
  ()
}
pub fn run(xs : Array[Int], opt : (() -> Unit)?) -> Bool {
  xs.iter().any(fn(_x) {
    match opt {
      Some(helper) => helper()
      None => ()
    }
    true
  })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_gate_c_fresh_local_reentrant",
        r'''
pub fn run() -> Bool {
  let xs : Array[Int] = [1, 2, 3]
  let k = fn() { xs.clear() }
  let bs : Array[() -> Unit] = [k]
  xs.iter().any(fn(_) {
    (bs[0])()
    true
  })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_gate_d_opaque_cb_slice",
        r'''
pub fn run(xs : Array[Int], cb : (Int) -> Int) -> Int {
  let mut acc = 0
  for x in xs[1:] {
    acc = acc + cb(x)
  }
  acc
}
''',
        "MBT2PION_BORROWED_ARRAY_SLICE",
    ),
    (
        "neg_gate_d_labeled_for_slice",
        r'''
pub fn run(xs : Array[Int]) -> Int {
  let mut acc = 0
  outer~: for x in xs[1:] {
    acc = acc + x
    if x > 10 {
      break outer~
    }
  }
  acc
}
pub fn probe(x : Int) -> Int {
  x + 1
}
''',
        "MBT2PION_UNSUPPORTED_SYNTAX",
    ),
    (
        "neg_r7_top_let_labeled_loop",
        r'''
let value : Int = outer~: for x in [3] { break outer~ x } nobreak { 4 }
pub fn get_value() -> Int {
  value
}
''',
        "MBT2PION_UNSUPPORTED_SYNTAX",
    ),
    (
        "neg_r7_interp_labeled_loop",
        r'''
pub fn run() -> Int {
  "\{outer~: for x in [3] { break outer~ x } nobreak { 4 }}".length()
}
''',
        "MBT2PION_UNSUPPORTED_SYNTAX",
    ),
    (
        "neg_r8_nested_interp_rbrace_labeled_loop",
        r'''fn pick(_s : String, x : Int) -> Int { x }
pub fn probe() -> Int {
  "\{pick("\{"}"}", outer~: for x in [3] { break outer~ x } nobreak { 4 })}".length()
}
''',
        "MBT2PION_UNSUPPORTED_SYNTAX",
    ),
    (
        "neg_r8_nested_interp_lbrace_labeled_loop",
        r'''fn pick(_s : String, x : Int) -> Int { x }
pub fn probe() -> Int {
  "\{pick("\{"{"}", outer~: for x in [3] { break outer~ x } nobreak { 4 })}".length()
}
''',
        "MBT2PION_UNSUPPORTED_SYNTAX",
    ),
    (
        "neg_r8_keyword_label_loop",
        r'''pub fn probe() -> Int {
  not~: loop 3 { v => break not~ v }
}
''',
        "MBT2PION_UNSUPPORTED_SYNTAX",
    ),
    (
        "neg_gate_a_kept_iter2_shrink",
        r'''
pub fn run() -> Int {
  let a : Array[Int] = Array::make(3, 1)
  let it = a.iter2()
  a.shrink_to_fit()
  a[0] = 9
  let _ = it
  a.length()
}
''',
        "MBT2PION_ARRAY_SHRINK_ITER",
    ),
    (
        "neg_r3_bare_iife_gate_b",
        r'''
pub fn run(xs : Array[Int]) -> Int? {
  let mut n = 0
  xs.search_by(fn(_x) {
    n = n + 1
    fn() { xs.clear() }()
    false
  })
}
''',
        "Array::search_by",
    ),
    (
        "neg_r3_bare_iife_gate_c",
        r'''
pub fn run(xs : Array[Int]) -> Bool {
  xs.iter().any(fn(_x) {
    fn() { xs.clear() }()
    false
  })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r3_shadow_for_outer_array_type",
        r'''
struct Item {
  id : Int
}
pub fn run(a : Array[Int], items : Array[Item], groups : Array[Array[Item]]) -> Bool {
  let _ = a
  items.iter().any(fn(it) {
    for a in groups {
      a.push(it)
    }
    false
  })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r3_shadow_unknown_let_gate_d",
        r'''
struct Item {
  id : Int
}
pub fn run(a : Array[Int], cond : Bool, items : Array[Item]) -> Int {
  let _ = a
  let mut acc = 0
  for it in items[0:1] {
    let a = if cond { items } else { items }
    a.push(it)
    acc = acc + it.id
  }
  acc
}
''',
        "MBT2PION_BORROWED_ARRAY_SLICE",
    ),
    (
        "neg_r3_struct_pat_shadow_pure_fn",
        r'''
struct Box {
  cb : () -> Unit
}
fn helper() -> Unit {
  ()
}
pub fn run(xs : Array[Int], b : Box) -> Bool {
  xs.iter().any(fn(_x) {
    match b {
      { cb: helper } => helper()
    }
    true
  })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r3_qualified_pipe_gate_d",
        r'''
struct W {
  n : Int
}
fn W::grow(xs : Array[Int]) -> Unit {
  xs.push(9)
}
pub fn run(xs : Array[Int]) -> Int {
  let mut acc = 0
  for v in xs[0:2] {
    xs |> W::grow
    acc = acc + v
  }
  acc
}
''',
        "MBT2PION_BORROWED_ARRAY_SLICE",
    ),
    (
        "neg_r9_generic_pipe_shadow_ordered_set",
        r'''
struct OrderedSet {
  tag : Int
}
fn OrderedSet::new(_xs : Array[Int]) -> OrderedSet {
  OrderedSet::{ tag: 1 }
}
trait Maker {
  new(Array[Int]) -> Self
}
struct Node {
  n : Int
}
impl Maker for Node with new(xs) {
  xs.push(9)
  Node::{ n: 1 }
}
fn[OrderedSet : Maker] touch_pipe(xs : Array[Int], _v : OrderedSet) -> Unit {
  let _ : OrderedSet = xs |> OrderedSet::new
}
pub fn run_pipe(xs : Array[Int]) -> Int? {
  let _ = OrderedSet::new([])
  xs.search_by(fn(x) {
    touch_pipe(xs, Node::{ n: 0 })
    x == 1
  })
}
''',
        "Array::search_by",
    ),
    (
        "neg_f6_4a_block_iterable_shadow_param",
        r'''
struct Item {
  xs : Array[Int]
}
impl Eq for Item with equal(self, _other) {
  self.xs.clear()
  true
}
fn bad_cmp(x : Int, items : Array[Item]) -> Bool {
  for x in { let ys = items; ys } {
    if x == x {
      return true
    }
  }
  false
}
pub fn run(xs : Array[Int], items : Array[Item]) -> Bool {
  xs.iter().any(fn(x) { bad_cmp(x, items) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_f6_4a_for_map_param_new_by_callback",
        r'''
pub fn run(xs : Array[Int], ms : Array[Map[Int, Int]]) -> Bool {
  xs.iter().any(fn(x) {
    for m in ms {
      if m.contains(x) {
        return true
      }
    }
    false
  })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_f6_4a_multiline_pipe_map_init",
        r'''
fn wrap_ext(_m : Map[Int, Int], ext : Map[Int, Int]) -> Map[Int, Int] {
  ext
}
pub fn run(xs : Array[Int], ext : Map[Int, Int]) -> Bool {
  let v : Map[Int, Int] = { 1: 2 }
    |> wrap_ext(ext)
  xs.iter().any(fn(x) { v.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_f6_4a_ordered_set_copy_callback",
        r'''
pub fn run(xs : Array[Int], s : Set[Int]) -> Int? {
  xs.search_by(fn(x) {
    let _ = s.copy()
    x == 1
  })
}
''',
        "Array::search_by",
    ),
    (
        "neg_f6_4a_mid_closure_shadow_map",
        r'''
pub fn run(xs : Array[Int], ext : Map[Int, Int]) -> Int? {
  let m : Map[Int, Int] = { 1: 2 }
  let _ = m.size()
  let mid = fn() -> Int? {
    let m : Map[Int, Int] = ext
    xs.search_by(fn(x) { m.contains(x) })
  }
  mid()
}
''',
        "Array::search_by",
    ),
    (
        "neg_pub_all_struct_map_field",
        r'''
pub(all) struct ExtMapBox {
  m : Map[Int, Int]
}
pub fn run(b : ExtMapBox, xs : Array[Int]) -> Bool {
  xs.iter().any(fn(x) { b.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_pub_all_mut_field_map",
        r'''
pub(all) struct PubAllMutMapBox {
  mut m : Map[Int, Int]
}
pub fn PubAllMutMapBox::new() -> PubAllMutMapBox {
  PubAllMutMapBox::{ m: Map::new() }
}
pub fn PubAllMutMapBox::clear_ref(self : PubAllMutMapBox) -> Unit {
  self.m = Map::new()
}
pub fn run(b : PubAllMutMapBox, xs : Array[Int]) -> Bool {
  xs.iter().any(fn(x) { b.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_field_assigned_from_param",
        r'''
struct ParamFieldBox {
  mut m : Map[Int, Int]
}
fn ParamFieldBox::set_m(self : ParamFieldBox, ext : Map[Int, Int]) -> Unit {
  self.m = ext
}
pub fn run(xs : Array[Int], ext : Map[Int, Int]) -> Bool {
  let b = ParamFieldBox::{ m: Map::new() }
  b.set_m(ext)
  xs.iter().any(fn(x) { b.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_struct_spread_external_override",
        r'''
struct SpreadBox {
  x : Int
  m : Map[Int, Int]
}
fn SpreadBox::replace(self : SpreadBox, ext : Map[Int, Int]) -> SpreadBox {
  { ..self, m: ext }
}
pub fn run(xs : Array[Int], ext : Map[Int, Int]) -> Bool {
  let b = SpreadBox::{ x: 0, m: Map::new() }.replace(ext)
  xs.iter().any(fn(x) { b.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_top_level_ref_map_param",
        r'''
let g_map : Ref[Map[Int, Int]] = Ref::new(Map::new())
pub fn set_g(ext : Map[Int, Int]) -> Unit {
  g_map.val = ext
}
pub fn run(xs : Array[Int]) -> Bool {
  xs.iter().any(fn(x) { g_map.val.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r2_pub_struct_non_priv_map_field",
        r'''
pub struct PubDefaultFieldMap {
  mut m : Map[Int, Int]
}
pub fn PubDefaultFieldMap::new() -> PubDefaultFieldMap {
  PubDefaultFieldMap::{ m: Map::new() }
}
pub fn PubDefaultFieldMap::reset(self : PubDefaultFieldMap) -> Unit {
  self.m = Map::new()
}
pub fn run(b : PubDefaultFieldMap, xs : Array[Int]) -> Bool {
  xs.iter().any(fn(x) { b.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r2_untyped_struct_if_field",
        r'''
struct CondMapBox {
  m : Map[Int, Int]
}
fn make_box(flag : Bool, ext : Map[Int, Int]) -> CondMapBox {
  let s : CondMapBox = { m: if flag { ext } else { Map::new() } }
  s
}
pub fn run(flag : Bool, xs : Array[Int], ext : Map[Int, Int]) -> Bool {
  let b = make_box(flag, ext)
  xs.iter().any(fn(x) { b.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r2_custom_eq_rhs_add_bypass",
        r'''
struct BadEq {
  xs : Array[Int]
  n : Int
}
impl Eq for BadEq with equal(self, other) {
  self.xs.clear()
  self.n == other.n
}
fn pick_bad(xs : Array[Int], n : Int) -> BadEq {
  BadEq::{ xs, n }
}
pub fn run(xs : Array[Int]) -> Bool {
  let a = BadEq::{ xs, n: 1 }
  xs.iter().any(fn(x) { a == pick_bad(xs, x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r2_local_hop_tainted_field",
        r'''
struct BadHop {
  mut m : Map[Int, Int]
}
struct GoodHop {
  m : Map[Int, Int]
}
fn BadHop::taint(self : BadHop, ext : Map[Int, Int]) -> Unit {
  self.m = ext
}
fn copy_via_local(b : BadHop) -> GoodHop {
  let tmp = b.m
  GoodHop::{ m: tmp }
}
pub fn run(xs : Array[Int], ext : Map[Int, Int]) -> Bool {
  let b = BadHop::{ m: Map::new() }
  b.taint(ext)
  let g = copy_via_local(b)
  xs.iter().any(fn(x) { g.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r2_shorthand_untyped_struct_lit",
        r'''
struct PairSh {
  m : Map[Int, Int]
  x : Int
}
fn make_bad(m : Map[Int, Int], x : Int) -> PairSh {
  { m, x }
}
pub fn run(xs : Array[Int], ext : Map[Int, Int]) -> Bool {
  let p = make_bad(ext, 1)
  let _ = p.x
  xs.iter().any(fn(x) { p.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r3_interp_field_write",
        r'''
struct InterpTaintBox {
  mut m : Map[Int, Int]
}
fn taint_in_interp(b : InterpTaintBox, ext : Map[Int, Int]) -> Unit {
  let _ = "\{{ b.m = ext; 1 }}"
}
pub fn run(xs : Array[Int], ext : Map[Int, Int]) -> Bool {
  let b = InterpTaintBox::{ m: Map::new() }
  taint_in_interp(b, ext)
  xs.iter().any(fn(x) { b.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r5_interp_shadow_outer_pure_map",
        r'''
struct InterpShadowBox {
  mut m : Map[Int, Int]
}
fn taint_shadow_interp(b : InterpShadowBox, ext : Map[Int, Int]) -> Unit {
  let m : Map[Int, Int] = Map::new()
  let _ = "\{{ let m = ext; b.m = m; 0 }}"
  let _ = m
}
pub fn run(xs : Array[Int], ext : Map[Int, Int]) -> Bool {
  let b = InterpShadowBox::{ m: Map::new() }
  taint_shadow_interp(b, ext)
  xs.iter().any(fn(x) { b.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r6_interp_shadow_global_pure_map",
        r'''
let g_pure : Map[Int, Int] = Map::new()
struct InterpGlobShadowBox {
  mut m : Map[Int, Int]
}
fn taint_glob_shadow(b : InterpGlobShadowBox, ext : Map[Int, Int]) -> Unit {
  let _ = g_pure.size()
  let _ = "\{{ let g_pure = ext; b.m = g_pure; 0 }}"
}
pub fn run(xs : Array[Int], ext : Map[Int, Int]) -> Bool {
  let b = InterpGlobShadowBox::{ m: Map::new() }
  taint_glob_shadow(b, ext)
  xs.iter().any(fn(x) { b.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_r6_interp_for_shadow_local_pure_map",
        r'''
struct InterpForShadowBox {
  mut m : Map[Int, Int]
}
fn taint_for_shadow(b : InterpForShadowBox, ext : Map[Int, Int]) -> Unit {
  let m : Map[Int, Int] = Map::new()
  let _ = "\{{ for m in [ext] { b.m = m }; 0 }}"
  let _ = m
}
pub fn run(xs : Array[Int], ext : Map[Int, Int]) -> Bool {
  let b = InterpForShadowBox::{ m: Map::new() }
  taint_for_shadow(b, ext)
  xs.iter().any(fn(x) { b.m.contains(x) })
}
''',
        "MBT2PION_ARRAY_ITER_MUTATION",
    ),
    (
        "neg_f6_4c_2_gate_d2_mut_slice_callee",
        r'''
fn mut_backing_and_read(ops : Array[Int], run : ArrayView[Int]) -> Int {
  ops[0] = 99
  run[0]
}
pub fn run(ops : Array[Int]) -> Int {
  mut_backing_and_read(ops, ops[0:1])
}
''',
        "MBT2PION_BORROWED_ARRAY_SLICE",
    ),
    (
        "neg_f6_4c_2_gate_d2_pub_slice_callee",
        r'''
pub fn pub_slice_cb(run : ArrayView[Int], cb : () -> Unit) -> Int {
  cb()
  run[0]
}
pub fn run(ops : Array[Int], cb : () -> Unit) -> Int {
  pub_slice_cb(ops[0:1], cb)
}
''',
        "MBT2PION_BORROWED_ARRAY_SLICE",
    ),
    (
        "neg_f6_4c_2_aliased_filter_map_mut_cb",
        r'''
pub fn run(ats : Array[Int]) -> Array[Int] {
  ats.filter_map(fn(at) {
    ats.push(at)
    Some(at)
  })
}
''',
        "MBT2PION_UNSUPPORTED_SYNTAX",
    ),
]


def run_cmd(cmd, cwd=None, check=True, env=None):
    p = subprocess.run(cmd, cwd=cwd, env=env, text=True, capture_output=True)
    if check and p.returncode != 0:
        raise RuntimeError(
            f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}"
        )
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", required=True)
    args = ap.parse_args()
    pionc = os.path.abspath(args.pionc)

    moon = shutil.which("moon")
    if not moon:
        cand = os.path.expanduser("~/.moon/bin/moon")
        if os.path.isfile(cand):
            moon = cand
    node = shutil.which("node")
    if not moon or not node:
        print(f"FAIL: missing required tools: moon={moon} node={node}", file=sys.stderr)
        sys.exit(2)

    with tempfile.TemporaryDirectory(prefix="f6_3_oracle_") as tmp:
        # 1. Build mbt2pion CLI
        cli_bin = os.path.join(tmp, "mbt2pion_cli")
        run_cmd([pionc, "build", "-o", cli_bin, CLI_DIR], cwd=REPO_ROOT)

        # 2. Run MoonBit native & wasm-gc reference oracle
        mbt_dir = os.path.join(tmp, "mbt_ref")
        os.makedirs(os.path.join(mbt_dir, "src"), exist_ok=True)
        with open(os.path.join(mbt_dir, "moon.mod"), "w") as f:
            f.write('name = "oracle/f63"\n')
        with open(os.path.join(mbt_dir, "src", "moon.pkg"), "w") as f:
            f.write('options("is-main": true)\n')
        with open(os.path.join(mbt_dir, "src", "main.mbt"), "w") as f:
            f.write(POSITIVE_MBT + "\nfn main {\n  println(run_all())\n}\n")

        moon_native_out = run_cmd([moon, "run", "--target", "native", "src"], cwd=mbt_dir).stdout.strip()
        moon_wasm_out = run_cmd([moon, "run", "--target", "wasm-gc", "src"], cwd=mbt_dir).stdout.strip()
        if moon_native_out != moon_wasm_out:
            raise RuntimeError(f"MoonBit native vs wasm-gc mismatch:\n  native: {moon_native_out}\n  wasm-gc: {moon_wasm_out}")
        print(f"[MOONBIT] native == wasm-gc: {moon_native_out}")

        # 3. Transpile positive package with mbt2pion
        src_dir = os.path.join(tmp, "pos_src")
        out_dir = os.path.join(tmp, "pos_out")
        ledger_path = os.path.join(tmp, "pos_ledger.json")
        os.makedirs(src_dir, exist_ok=True)
        os.makedirs(out_dir, exist_ok=True)
        with open(os.path.join(src_dir, "lib.mbt"), "w") as f:
            f.write(POSITIVE_MBT)
        with open(os.path.join(src_dir, "moon.pkg.json"), "w") as f:
            f.write("{}\n")
        run_cmd([
            cli_bin,
            "--src", src_dir,
            "--out", out_dir,
            "--drift-ledger", ledger_path,
            "--pionc", pionc,
            "--mbt-compat", COMPAT_DIR,
            "--no-fmt",
            "--mode", "publish",
        ], cwd=REPO_ROOT)

        # Verify drift_ledger records allow entries for B, C, D (and A where applicable)
        with open(ledger_path) as f:
            ledger = json.load(f)
        cats = set(e.get("category", "") for e in ledger.get("entries", []))
        print(f"[LEDGER] categories: {sorted(cats)} unresolved={ledger.get('unresolved_entries')}")
        if ledger.get("unresolved_entries", 1) != 0:
            raise RuntimeError(f"Unexpected unresolved ledger entries: {ledger}")
        for req_cat in ("mutation_summary_allow_a", "mutation_summary_allow_b", "mutation_summary_allow_c", "mutation_summary_allow_d"):
            if req_cat not in cats:
                raise RuntimeError(f"Missing expected allow ledger category `{req_cat}` in {sorted(cats)}")

        # 4. Build & run Pion native and wasm32
        with open(os.path.join(out_dir, "pion.toml"), "w") as f:
            f.write(
                '[package]\nname = "f63_app"\nversion = "0.1.0"\n\n'
                '[dependencies]\n'
                f'mbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
            )
        with open(os.path.join(out_dir, "main.pion"), "w") as f:
            f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_all())\n  0\n}\n")

        pion_native_bin = os.path.join(tmp, "f63_native")
        run_cmd([pionc, "build", "-o", pion_native_bin, out_dir], cwd=REPO_ROOT)
        pion_native_out = run_cmd([pion_native_bin]).stdout.strip()

        pion_wasm_bin = os.path.join(tmp, "f63_wasm.wasm")
        run_cmd([pionc, "build", "--target", "wasm32", "-o", pion_wasm_bin, out_dir], cwd=REPO_ROOT)
        pion_wasm_out = run_cmd([node, os.path.join(REPO_ROOT, "runtime", "pion_wasm_rt.mjs"), pion_wasm_bin]).stdout.strip()

        if pion_native_out != moon_native_out:
            raise RuntimeError(f"Pion native mismatch!\n  expected: {moon_native_out}\n  got:      {pion_native_out}")
        if pion_wasm_out != moon_native_out:
            raise RuntimeError(f"Pion wasm32 mismatch!\n  expected: {moon_native_out}\n  got:      {pion_wasm_out}")
        print(f"[PION] native == wasm32 == MoonBit: {pion_native_out}")

        # 5. Negative adversarial fail-closed cases:
        #    (a) Verify EVERY negative case is valid MoonBit via `moon check`
        #    (b) Verify `mbt2pion --mode publish` exits non-zero, emits no `--out`,
        #        does not fail via accidental `E_PARSE`, emits expected gate diagnostic,
        #        and records NO `mutation_summary_allow_*` in ledger.
        for name, mbt_code, expected_diag in NEGATIVE_CASES:
            nmod = os.path.join(tmp, f"{name}_mod")
            nsrc = os.path.join(nmod, "src")
            nout = os.path.join(tmp, f"{name}_out")
            nrep = os.path.join(tmp, f"{name}_rep.json")
            nreport = os.path.join(tmp, f"{name}_report.json")
            os.makedirs(nsrc, exist_ok=True)
            with open(os.path.join(nmod, "moon.mod"), "w") as f:
                f.write(f'name = "neg/{name}"\n')
            with open(os.path.join(nsrc, "moon.pkg"), "w") as f:
                f.write("")
            with open(os.path.join(nsrc, "bad.mbt"), "w") as f:
                f.write(mbt_code)
            mc = run_cmd([moon, "check"], cwd=nmod, check=False)
            if mc.returncode != 0:
                raise RuntimeError(
                    f"NEGATIVE CASE `{name}` IS NOT VALID MOONBIT (`moon check` failed rc={mc.returncode}):\n{mc.stdout}\n{mc.stderr}"
                )
            with open(os.path.join(nsrc, "moon.pkg.json"), "w") as f:
                f.write("{}\n")
            p = run_cmd([
                cli_bin,
                "--src", nsrc,
                "--out", nout,
                "--drift-ledger", nrep,
                "--report", nreport,
                "--pionc", pionc,
                "--mbt-compat", COMPAT_DIR,
                "--no-fmt",
                "--mode", "publish",
            ], cwd=REPO_ROOT, check=False)
            combined_err = p.stdout + "\n" + p.stderr
            if p.returncode == 0 or os.path.exists(nout):
                raise RuntimeError(
                    f"SOUNDNESS FAILURE: negative case `{name}` was NOT fail-closed! rc={p.returncode}, out_exists={os.path.exists(nout)}\n{combined_err}"
                )
            if "E_PARSE" in combined_err:
                raise RuntimeError(
                    f"NEGATIVE CASE `{name}` failed with accidental E_PARSE instead of gate `{expected_diag}`:\n{combined_err}"
                )
            if expected_diag and expected_diag not in combined_err:
                raise RuntimeError(
                    f"NEGATIVE CASE `{name}` did not emit expected diagnostic `{expected_diag}`:\n{combined_err}"
                )
            if os.path.exists(nrep):
                with open(nrep) as rf:
                    nledger = json.load(rf)
                ncats = [e.get("category", "") for e in nledger.get("entries", [])]
                allow_hits = [c for c in ncats if c.startswith("mutation_summary_allow_")]
                if allow_hits:
                    raise RuntimeError(
                        f"SOUNDNESS FAILURE: negative case `{name}` unexpectedly logged allow categories {allow_hits}"
                    )
            if name == "neg_gate_d_labeled_for_slice":
                with open(nreport) as rf:
                    rep_json = json.load(rf)
                disps = {d.get("decl"): d.get("disposition") for d in rep_json.get("dispositions", [])}
                if disps.get("fn:run") != "unsupported" or disps.get("fn:probe") != "transpiled":
                    raise RuntimeError(
                        f"REPORT DISPOSITION MISMATCH for `{name}`: expected fn:run=unsupported, fn:probe=transpiled; got {disps}"
                    )
            elif name in ("neg_r8_nested_interp_rbrace_labeled_loop", "neg_r8_nested_interp_lbrace_labeled_loop"):
                with open(nreport) as rf:
                    rep_json = json.load(rf)
                disps = {d.get("decl"): d.get("disposition") for d in rep_json.get("dispositions", [])}
                if disps.get("fn:probe") != "unsupported" or "bad.mbt:3:21" not in combined_err:
                    raise RuntimeError(
                        f"REPORT/LOC MISMATCH for `{name}`: expected bad.mbt:3:21 and fn:probe=unsupported; got disps={disps}\n{combined_err}"
                    )
            elif name == "neg_r8_keyword_label_loop":
                with open(nreport) as rf:
                    rep_json = json.load(rf)
                disps = {d.get("decl"): d.get("disposition") for d in rep_json.get("dispositions", [])}
                if disps.get("fn:probe") != "unsupported" or "bad.mbt:2:3" not in combined_err:
                    raise RuntimeError(
                        f"REPORT/LOC MISMATCH for `{name}`: expected bad.mbt:2:3 and fn:probe=unsupported; got disps={disps}\n{combined_err}"
                    )
            print(f"[NEG PASS] {name}: moon check OK, fail-closed with {expected_diag} (rc={p.returncode})")

        # 6. Cross-package dependency mutation negative case (Class 4):
        #    `dep::mutate(xs)` clears `xs`; consumer calls `@dep.mutate(xs)` inside `.iter().any(...)`.
        xp_mod = os.path.join(tmp, "xp_mod")
        xp_dep = os.path.join(xp_mod, "dep")
        xp_app = os.path.join(xp_mod, "app")
        xp_dep_pkg = os.path.join(tmp, "xp_dep_pkg")
        xp_dep_out = os.path.join(xp_dep_pkg, "src")
        xp_app_out = os.path.join(tmp, "xp_app_out")
        xp_app_rep = os.path.join(tmp, "xp_app_rep.json")
        os.makedirs(xp_dep, exist_ok=True)
        os.makedirs(xp_app, exist_ok=True)
        os.makedirs(xp_dep_out, exist_ok=True)
        with open(os.path.join(xp_dep_pkg, "pion.toml"), "w") as f:
            f.write(
                '[package]\nname = "dep"\nversion = "0.1.0"\n\n'
                '[dependencies]\n'
                f'mbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
            )
        with open(os.path.join(xp_mod, "moon.mod"), "w") as f:
            f.write('name = "neg/xp"\n')
        with open(os.path.join(xp_dep, "moon.pkg"), "w") as f:
            f.write("")
        with open(os.path.join(xp_dep, "lib.mbt"), "w") as f:
            f.write("pub fn mutate(xs : Array[Int]) -> Unit {\n  xs.clear()\n}\n")
        with open(os.path.join(xp_app, "moon.pkg"), "w") as f:
            f.write('import {\n  "neg/xp/dep" @dep,\n}\n')
        with open(os.path.join(xp_app, "lib.mbt"), "w") as f:
            f.write("pub fn run(xs : Array[Int]) -> Bool {\n  xs.iter().any(fn(_x) {\n    @dep.mutate(xs)\n    true\n  })\n}\n")
        mc_xp = run_cmd([moon, "check"], cwd=xp_mod, check=False)
        if mc_xp.returncode != 0:
            raise RuntimeError(f"Cross-pkg negative case failed `moon check`:\n{mc_xp.stdout}\n{mc_xp.stderr}")
        with open(os.path.join(xp_dep, "moon.pkg.json"), "w") as f:
            f.write("{}\n")
        with open(os.path.join(xp_app, "moon.pkg.json"), "w") as f:
            f.write('{"import": [{"path": "neg/xp/dep", "alias": "dep"}]}\n')
        run_cmd([
            cli_bin,
            "--src", xp_dep,
            "--out", xp_dep_out,
            "--pionc", pionc,
            "--mbt-compat", COMPAT_DIR,
            "--no-fmt",
            "--mode", "publish",
        ], cwd=REPO_ROOT)
        p_xp = run_cmd([
            cli_bin,
            "--src", xp_app,
            "--out", xp_app_out,
            "--dep", f"dep={xp_dep_pkg}",
            "--drift-ledger", xp_app_rep,
            "--pionc", pionc,
            "--mbt-compat", COMPAT_DIR,
            "--no-fmt",
            "--mode", "publish",
        ], cwd=REPO_ROOT, check=False)
        xp_err = p_xp.stdout + "\n" + p_xp.stderr
        if p_xp.returncode == 0 or os.path.exists(xp_app_out) or "E_PARSE" in xp_err or "MBT2PION_ARRAY_ITER_MUTATION" not in xp_err:
            raise RuntimeError(
                f"SOUNDNESS FAILURE: cross-package dep mutation was NOT fail-closed with MBT2PION_ARRAY_ITER_MUTATION! rc={p_xp.returncode}\n{xp_err}"
            )
        if os.path.exists(xp_app_rep):
            with open(xp_app_rep) as rf:
                xp_ledger = json.load(rf)
            xp_cats = [e.get("category", "") for e in xp_ledger.get("entries", [])]
            xp_allow = [c for c in xp_cats if c.startswith("mutation_summary_allow_")]
            if xp_allow:
                raise RuntimeError(
                    f"SOUNDNESS FAILURE: cross-package dep mutation unexpectedly logged allow categories {xp_allow}"
                )
        print(f"[NEG PASS] neg_class4_cross_pkg_dep_mut: moon check OK, fail-closed with MBT2PION_ARRAY_ITER_MUTATION (rc={p_xp.returncode})")

        # 7. Wave F6-3b E2E: target-filtered empty dep package (`--mode publish` -> downstream `--dep`)
        et_mod = os.path.join(tmp, "et_mod")
        et_dep = os.path.join(et_mod, "wasm_dep")
        et_app = os.path.join(et_mod, "app")
        et_dep_pkg = os.path.join(tmp, "et_dep_pkg")
        et_dep_out = os.path.join(et_dep_pkg, "src")
        et_app_pkg = os.path.join(tmp, "et_app_pkg")
        et_app_out = os.path.join(et_app_pkg, "src")
        os.makedirs(et_dep, exist_ok=True)
        os.makedirs(et_app, exist_ok=True)
        os.makedirs(et_dep_out, exist_ok=True)
        os.makedirs(et_app_out, exist_ok=True)
        with open(os.path.join(et_dep_pkg, "pion.toml"), "w") as f:
            f.write(
                '[package]\nname = "wasm_dep"\nversion = "0.1.0"\n\n'
                '[dependencies]\n'
                f'mbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
            )
        with open(os.path.join(et_app_pkg, "pion.toml"), "w") as f:
            f.write(
                '[package]\nname = "et_app"\nversion = "0.1.0"\n\n'
                '[dependencies]\n'
                f'mbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
                f'wasm_dep = {{ path = "{et_dep_pkg}" }}\n'
            )
        with open(os.path.join(et_mod, "moon.mod"), "w") as f:
            f.write('name = "test/et"\n')
        with open(os.path.join(et_dep, "moon.pkg"), "w") as f:
            f.write('options(targets: { "wasm_only.mbt": ["wasm"] })\n')
        with open(os.path.join(et_dep, "wasm_only.mbt"), "w") as f:
            f.write("pub fn wasm_helper() -> Int { 42 }\n")
        with open(os.path.join(et_app, "moon.pkg"), "w") as f:
            f.write('import {\n  "test/et/wasm_dep" @wasm_dep,\n}\n')
        with open(os.path.join(et_app, "lib.mbt"), "w") as f:
            f.write("pub fn native_ok() -> Int { 7 }\n")
        run_cmd([
            cli_bin,
            "--src", et_dep,
            "--out", et_dep_out,
            "--target", "native",
            "--pionc", pionc,
            "--mbt-compat", COMPAT_DIR,
            "--no-fmt",
            "--mode", "publish",
        ], cwd=REPO_ROOT)
        with open(os.path.join(et_dep_out, "mbt2pion_abi.json")) as af:
            et_abi = json.load(af)
        if et_abi.get("payload", {}).get("empty_target_pkg") is not True:
            raise RuntimeError(f"Expected empty_target_pkg=true in ABI, got: {et_abi}")
        run_cmd([
            cli_bin,
            "--src", et_app,
            "--out", et_app_out,
            "--target", "native",
            "--dep", f"wasm_dep={et_dep_pkg}",
            "--pionc", pionc,
            "--mbt-compat", COMPAT_DIR,
            "--no-fmt",
            "--mode", "publish",
        ], cwd=REPO_ROOT)
        run_cmd([pionc, "check", et_dep_pkg], cwd=REPO_ROOT)
        run_cmd([pionc, "check", et_app_pkg], cwd=REPO_ROOT)
        print("[E2E PASS] empty_target_pkg publish + downstream --dep + pionc check OK")

        # 8. E2E: `--with-tests --mode publish` + `pionc test` for `debug_inspect` on
        #    30-Null wide `Json::Array` and 20-deep nested `Json::Array` (cross-checked with `moon test`)
        di_mod = os.path.join(tmp, "di_mod")
        di_src = os.path.join(di_mod, "src")
        di_pkg = os.path.join(tmp, "di_pkg")
        di_out = os.path.join(di_pkg, "src")
        os.makedirs(di_src, exist_ok=True)
        os.makedirs(di_out, exist_ok=True)
        with open(os.path.join(di_mod, "moon.mod"), "w") as f:
            f.write('name = "test/di"\n')
        with open(os.path.join(di_src, "moon.pkg"), "w") as f:
            f.write("")
        with open(os.path.join(di_src, "moon.pkg.json"), "w") as f:
            f.write("{}\n")
        with open(os.path.join(di_src, "lib.mbt"), "w") as f:
            f.write(
                "pub fn make_wide_nulls() -> Json {\n"
                "  let xs : Array[Json] = []\n"
                "  let mut i : Int = 0\n"
                "  while i < 30 {\n"
                "    xs.push(Json::null())\n"
                "    i = i + 1\n"
                "  }\n"
                "  Json::array(xs)\n"
                "}\n"
                "pub fn make_deep_arr() -> Json {\n"
                "  let mut v = Json::null()\n"
                "  let mut i : Int = 0\n"
                "  while i < 20 {\n"
                "    v = Json::array([v])\n"
                "    i = i + 1\n"
                "  }\n"
                "  v\n"
                "}\n"
                "pub fn make_arr_json_1() -> Array[Json] {\n"
                "  [Json::null()]\n"
                "}\n"
                "pub fn make_arr_json_30() -> Array[Json] {\n"
                "  let xs : Array[Json] = []\n"
                "  let mut i : Int = 0\n"
                "  while i < 30 {\n"
                "    xs.push(Json::null())\n"
                "    i = i + 1\n"
                "  }\n"
                "  xs\n"
                "}\n"
                "pub fn make_small_json_5() -> Array[Json] {\n"
                "  let xs : Array[Json] = []\n"
                "  let mut i : Int = 0\n"
                "  while i < 5 {\n"
                "    xs.push(Json::string(\"item_0123456789\"))\n"
                "    i = i + 1\n"
                "  }\n"
                "  xs\n"
                "}\n"
                "pub fn make_ints_30() -> Array[Int] {\n"
                "  let xs : Array[Int] = []\n"
                "  let mut i : Int = 0\n"
                "  while i < 30 {\n"
                "    xs.push(i)\n"
                "    i = i + 1\n"
                "  }\n"
                "  xs\n"
                "}\n"
            )
        wide_expected = "Array(\n  [\n" + ("    Null,\n" * 30) + "  ],\n)"
        deep_expected = ("Array([" * 20) + "Null" + ("])" * 20)
        arr_json_1_expected = "[Null]"
        arr_json_30_expected = "[\n" + ("  Null,\n" * 30) + "]"
        some_wide_expected = "Some(\n  Array(\n    [\n" + ("      Null,\n" * 30) + "    ],\n  ),\n)"
        arr_wide_expected = "[\n  Array(\n    [\n" + ("      Null,\n" * 30) + "    ],\n  ),\n]"
        small_json_5_expected = "[\n" + ('  String("item_0123456789"),\n' * 5) + "]"
        ints_30_expected = "[\n" + "".join(f"  {i},\n" for i in range(30)) + "]"
        tuple_wide_expected = "(\n  Array(\n    [\n" + ("      Null,\n" * 30) + "    ],\n  ),\n  1,\n)"
        def mbt_multiline_str(s: str) -> str:
            return "\n".join("    #|" + line for line in s.split("\n"))
        with open(os.path.join(di_src, "lib_test.mbt"), "w") as f:
            f.write(
                'test "debug_inspect wide, deep, and container json" {\n'
                '  debug_inspect(\n'
                '    make_wide_nulls(),\n'
                '    content=(\n'
                + mbt_multiline_str(wide_expected) + "\n"
                '    ),\n'
                '  )\n'
                '  debug_inspect(\n'
                '    make_deep_arr(),\n'
                '    content=(\n'
                + mbt_multiline_str(deep_expected) + "\n"
                '    ),\n'
                '  )\n'
                '  debug_inspect(\n'
                '    make_arr_json_1(),\n'
                '    content=(\n'
                + mbt_multiline_str(arr_json_1_expected) + "\n"
                '    ),\n'
                '  )\n'
                '  debug_inspect(\n'
                '    make_arr_json_30(),\n'
                '    content=(\n'
                + mbt_multiline_str(arr_json_30_expected) + "\n"
                '    ),\n'
                '  )\n'
                '  debug_inspect(\n'
                '    Some(make_wide_nulls()),\n'
                '    content=(\n'
                + mbt_multiline_str(some_wide_expected) + "\n"
                '    ),\n'
                '  )\n'
                '  debug_inspect(\n'
                '    [make_wide_nulls()],\n'
                '    content=(\n'
                + mbt_multiline_str(arr_wide_expected) + "\n"
                '    ),\n'
                '  )\n'
                '  debug_inspect(\n'
                '    make_small_json_5(),\n'
                '    content=(\n'
                + mbt_multiline_str(small_json_5_expected) + "\n"
                '    ),\n'
                '  )\n'
                '  debug_inspect(\n'
                '    make_ints_30(),\n'
                '    content=(\n'
                + mbt_multiline_str(ints_30_expected) + "\n"
                '    ),\n'
                '  )\n'
                '  debug_inspect(\n'
                '    (make_wide_nulls(), 1),\n'
                '    content=(\n'
                + mbt_multiline_str(tuple_wide_expected) + "\n"
                '    ),\n'
                '  )\n'
                '}\n'
            )
        run_cmd([moon, "test"], cwd=di_mod)
        with open(os.path.join(di_pkg, "pion.toml"), "w") as f:
            f.write(
                '[package]\nname = "di_pkg"\nversion = "0.1.0"\n\n'
                '[dependencies]\n'
                f'mbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
            )
        run_cmd([
            cli_bin,
            "--src", di_src,
            "--out", di_out,
            "--with-tests",
            "--pionc", pionc,
            "--mbt-compat", COMPAT_DIR,
            "--no-fmt",
            "--mode", "publish",
        ], cwd=REPO_ROOT)
        run_cmd([pionc, "test", di_pkg], cwd=REPO_ROOT)
        print("[E2E PASS] debug_inspect wide 30-Null + 20-deep Json::Array: moon test == pionc test OK")

    print(f"[PASS] Wave F6-3a/3b 4-target oracle + {len(NEGATIVE_CASES) + 1} adversarial fail-closed cases + empty_target_pkg E2E: ALL OK")


if __name__ == "__main__":
    main()
