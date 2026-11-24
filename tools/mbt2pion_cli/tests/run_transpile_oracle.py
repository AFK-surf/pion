#!/usr/bin/env python3
"""End-to-end 3-target Transpile Differential Oracle for `mbt2pion` + `mbt_compat`.

Takes ONE public-safe MoonBit source package (`oracle_lib.mbt`) covering:
  - value-returning `guard` + `guard x is Some(v)` + diverging `guard`
  - top-level forward indirect `let` + `fn init`
  - `relay(x?) -> tally(x?)` side-effect default & multi-arg evaluation order
  - UTF-16 `"A中😀B"` length, code unit access, slice, scalar iteration, `String::compare`
  - `OrderedMap` insertion order (literal + remove/reinsert)
  - `Double::to_string` (`1.5e-7`, `-0.0`, `1e20`, `NaN`, `Infinity`)
  - signed (`Int`, `Int64`) & unsigned (`UInt`, `UInt64`) `/` and `%`:
    non-zero, constant zero, and runtime zero
  - `..m()` chained cascade returning receiver
  - `ArrayView` clamped slice (`xs[a:b]`)
  - `pub fn[T]` leading generic function
  - `Ctor(_, ..)` constructor rest pattern
  - `#derive(Eq)` struct containing `Option[Int]` and `Array[Int]`
  - `SourceLoc` across two distinct call sites

Runs the SAME MoonBit source on 3 engines:
  1. `moon`        : `moon run --target wasm-gc` directly on `oracle_lib.mbt`
  2. `pion-native` : `mbt2pion --mode publish` -> real `tools/mbt_compat` -> `pionc run`
  3. `pion-wasm32` : `mbt2pion --mode publish` -> real `tools/mbt_compat` -> `pionc run --target wasm32`

Compares:
  (a) execution outcome class (`ok` vs expected language-level `panic`/trap);
  (b) normalized trace lines (`T key=value`) verbatim and in order;
  (c) executed assertion IDs (`A id`) in order + frozen per-case expectation.
Also runs negative self-tests proving mutations turn the oracle RED.
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")
TIMEOUT_S = 180

ENGINES = ["moon", "pion-native", "pion-wasm32"]

# Frozen per-case expectations: case -> (outcome_class, expected_assertion_count)
CASES = {
    "guard": ("ok", 6),
    "init_order": ("ok", 3),
    "optional_relay": ("ok", 5),
    "utf16": ("ok", 10),
    "ordered_map": ("ok", 3),
    "double_fmt": ("ok", 6),
    "div_nonzero": ("ok", 4),
    "div_i32_const_zero": ("panic:div_zero", 0),
    "mod_i32_const_zero": ("panic:rem_zero", 0),
    "div_u32_const_zero": ("panic:div_zero", 0),
    "mod_u32_const_zero": ("panic:rem_zero", 0),
    "div_i32_rt_zero": ("panic:div_zero", 0),
    "mod_i32_rt_zero": ("panic:rem_zero", 0),
    "div_i64_rt_zero": ("panic:div_zero", 0),
    "mod_i64_rt_zero": ("panic:rem_zero", 0),
    "div_u32_rt_zero": ("panic:div_zero", 0),
    "mod_u32_rt_zero": ("panic:rem_zero", 0),
    "div_u64_rt_zero": ("panic:div_zero", 0),
    "mod_u64_rt_zero": ("panic:rem_zero", 0),
    "cascade_generics": ("ok", 6),
    "source_loc": ("ok", 3),
    "mul_div_prec": ("ok", 8),
    "div_neg_zero": ("panic:div_zero", 0),
    "interp_probe": ("ok", 2),
    "arrayview_backing": ("ok", 5),
    "init_invoke_closure": ("ok", 1),
    "div_const_then_rt_zero": ("panic:div_zero", 0),
    "div_len_rt_zero": ("panic:div_zero", 0),
    "div_byte_zero": ("panic:div_zero", 0),
    "div_min_neg1": ("panic:div_overflow", 0),
    "init_wrap_invoke_closure": ("ok", 1),
    "array_slice_to_owned": ("ok", 2),
    "div_min_neg0x1": ("panic:div_overflow", 0),
    "div_deep_7": ("panic:div_zero", 0),
    "div_idx_paren": ("panic:div_zero", 0),
    "init_iife_helper": ("ok", 1),
    "utf16_arith_and_idx": ("ok", 7),
    "div_min_allones_i32": ("panic:div_overflow", 0),
    "div_min_allones_i64": ("panic:div_overflow", 0),
    "utf16_lit_struct_interp": ("ok", 5),
    "mbt_compat_chain_len": ("ok", 3),
    "const_upper_idx_and_generic": ("ok", 3),
    "cross_pkg_cap_noshadow": ("ok", 2),
    "cross_pkg_cap_shadow": ("ok", 3),
    "cross_pkg_no_apimap_box": ("ok", 3),
    "m12_val_probes": ("ok", 6),
    "m12_recursive_local_fn": ("ok", 5),
    "m12_per_site_enum": ("ok", 4),
    "m12_pipe_loops_compat": ("ok", 10),
    "q2_semantics_p0": ("ok", 13),
    "q2_mechanical_compat": ("ok", 10),
}

MOON_TRAPS = {
    "divide by zero": "div_zero",
    "remainder by zero": "rem_zero",
    "divide result unrepresentable": "div_overflow",
    "integer overflow": "div_overflow",
    "unreachable": "abort",
    "array element access out of bounds": "oob",
}

PION_PANICS = [
    ("divide by zero", "div_zero"),
    ("remainder by zero", "rem_zero"),
    ("divide result unrepresentable", "div_overflow"),
    ("index out of bounds", "oob"),
    ("abort:", "abort"),
    ("assertion failed", "abort"),
]

# Single shared MoonBit library transpiled by `mbt2pion` AND executed directly by `moon`.
ORACLE_LIB_MBT = r'''
pub enum Tri {
  Tri(Int, b~ : Int, c~ : Int)
  Empty
}

#derive(Eq)
pub(all) struct Rec {
  opt : Int?
  arr : Array[Int]
}

pub(all) struct Holder {
  text : String
  items : Array[Int]
}

pub fn[T] id_val(x : T) -> T {
  x
}

pub fn match_tri(t : Tri) -> Int {
  match t {
    Tri(a, ..) => a
    Empty => 0
  }
}

pub fn val_guard_demo(flag : Bool) -> Int {
  guard flag else { 17 }
  42
}

pub fn guard_is_demo(opt : Int?) -> Int {
  guard opt is Some(v) else { 17 }
  v + 1
}

pub fn div_guard_demo(flag : Bool) -> Int {
  guard flag else { return 0 }
  42
}

// Top-level forward indirect `let` + `fn init`
let init_log : Array[Int] = []
let first_val : Int = read_second() + 1

fn read_second() -> Int {
  second_val
}

let second_val : Int = 41

fn init {
  init_log.push(first_val)
}

pub fn get_first_val() -> Int {
  first_val
}

pub fn get_init_log_len() -> Int {
  init_log.length()
}

pub fn get_init_log_0() -> Int {
  init_log[0]
}

// Optional parameter forwarding with side-effect default & multi-arg order
let side_log : Array[Int] = []

fn record_step(tag : Int) -> Int {
  side_log.push(tag)
  tag
}

fn next_default() -> Int {
  let _ = record_step(100)
  17
}

pub fn tally(base : Int, x? : Int = next_default()) -> Int {
  base + x
}

pub fn relay(a : Int, x? : Int) -> Int {
  tally(a, x?)
}

pub fn multi_arg_sum(a : Int, b : Int, c : Int) -> Int {
  a * 100 + b * 10 + c
}

pub fn run_optional_order() -> Array[Int] {
  let r1 = relay(record_step(10))
  let r2 = relay(record_step(20), x=record_step(3))
  let r3 = multi_arg_sum(record_step(1), record_step(2), record_step(3))
  let out : Array[Int] = [r1, r2, r3, side_log.length()]
  for v in side_log {
    out.push(v)
  }
  out
}

// UTF-16 string operations + scalar iteration + String::compare
pub fn utf16_length(s : String) -> Int {
  s.length()
}

pub fn utf16_unit_int(s : String, i : Int) -> Int {
  s[i].to_int()
}

pub fn utf16_slice_str(s : String, a : Int, b : Int) -> String {
  s[a:b].to_owned()
}

pub fn utf16_scalar_codes(s : String) -> Array[Int] {
  let out : Array[Int] = []
  for i, ch in s {
    out.push(i * 1000000 + ch.to_int())
  }
  out
}

pub fn str_cmp(a : String, b : String) -> Int {
  a.compare(b)
}

// OrderedMap insertion order + remove/reinsert
pub fn ordered_map_keys_demo() -> Array[String] {
  let m : Map[String, Int] = { "zeta": 1, "alpha": 2, "mid": 3, "beta": 4, "k9": 5 }
  let before = m.keys()
  let _ = before
  let out : Array[String] = []
  for k, v in m {
    out.push(k + "=" + v.to_string())
  }
  m.remove("alpha")
  m.set("alpha", 6)
  for k, v in m {
    out.push("after:" + k + "=" + v.to_string())
  }
  out
}

// Double::to_string formatting
pub fn fmt_double(d : Double) -> String {
  d.to_string()
}

// Signed & unsigned division and modulo (non-zero, constant zero, runtime zero)
pub fn div_i32(a : Int, b : Int) -> Int { a / b }
pub fn mod_i32(a : Int, b : Int) -> Int { a % b }
pub fn div_i64(a : Int64, b : Int64) -> Int64 { a / b }
pub fn mod_i64(a : Int64, b : Int64) -> Int64 { a % b }
pub fn div_u32(a : UInt, b : UInt) -> UInt { a / b }
pub fn mod_u32(a : UInt, b : UInt) -> UInt { a % b }
pub fn div_u64(a : UInt64, b : UInt64) -> UInt64 { a / b }
pub fn mod_u64(a : UInt64, b : UInt64) -> UInt64 { a % b }

pub fn div_i32_const0(a : Int) -> Int { a / 0 }
pub fn mod_i32_const0(a : Int) -> Int { a % 0 }
pub fn div_u32_const0(a : UInt) -> UInt { a / 0U }
pub fn mod_u32_const0(a : UInt) -> UInt { a % 0U }

// Cascade `..m()` returning receiver + ArrayView slice
pub fn cascade_demo(h : Holder, delta : Int) -> Array[Int] {
  let inc = (n : Int) => n + delta
  h.items..push(inc(1))..push(inc(2))
}

pub fn array_slice_demo(xs : Array[Int], a : Int, b : Int) -> Array[Int] {
  xs[a:b].to_array()
}

// SourceLoc with two distinct call sites
#callsite(autofill(loc))
pub fn tag_loc(msg : String, loc~ : SourceLoc) -> String {
  msg + "@" + loc.to_string()
}

pub fn two_source_locs() -> (String, String) {
  let a = tag_loc("first")
  let b = tag_loc("second")
  (a, b)
}

// P0-1: mul/div/mod left-associativity, unary neg divisor, chained div/mod
pub fn mul_div_chain(a : Int, b : Int, c : Int) -> Int { a * b / c }
pub fn mul_mod_chain(a : Int, b : Int, c : Int) -> Int { a * b % c }
pub fn idx_mul_div(xs : Array[Int], i : Int, n : Int) -> Int { xs[i] * 2 / n }
pub fn mul_div_i64(a : Int64, b : Int64) -> Int64 { a * 3L / b }
pub fn mod_then_div(a : Int, b : Int, c : Int) -> Int { a % b / c }
pub fn div_then_div(a : Int, b : Int, c : Int) -> Int { a / b / c }
pub fn div_paren_sub(a : Int, b : Int, c : Int) -> Int { a / (b - c) }
pub fn div_unary_neg(a : Int, b : Int) -> Int { a / -b }

// P0-2: interpolation probing for arbitrary inner expressions
pub fn interp_probe_demo(a : Int, b : Int, s : String, d : Double) -> String {
  "r=\{a / b} len=\{s.length()} d=\{d}"
}

// P0-5: borrowed ArrayView shared backing before realloc + isolation after 256 pushes + nested view
pub fn arrayview_backing_demo() -> Array[Int] {
  let a = [1, 2, 3]
  let v = a[0:2]
  let w = v[1:2]
  a[0] = 2
  let pre_v0 = v[0]
  let pre_w0 = w[0]
  for i = 0; i < 256; i = i + 1 {
    a.push(i)
  }
  a[0] = 3
  let post_v0 = v[0]
  let post_a0 = a[0]
  let post_w0 = w[0]
  [pre_v0, pre_w0, post_v0, post_a0, post_w0]
}

// P1-1: top-level init calling a function that immediately invokes its closure argument
fn invoke_init(f : () -> Int) -> Int {
  f()
}

fn read_arr_0(xs : Array[Int]) -> Int {
  xs[0]
}

let inv_a : Int = invoke_init(fn() { inv_z })
let inv_z : Int = read_arr_0([42])

pub fn get_inv_a() -> Int {
  inv_a
}

// Round 2 Astra P0-3 / P1-1 / P1-4 cases
pub fn div_const_then_rt(a : Int, b : Int) -> Int { a / 2 / b }
pub fn div_len_rt(xs : Array[Int], b : Int) -> Int { xs.length() / b }
pub fn div_byte_const0(a : Byte) -> Byte { a / b'\x00' }
pub fn div_i32_neg1(a : Int) -> Int { a / -1 }

fn wrap_invoke() -> Int {
  invoke_init(fn() { wrap_z })
}
let wrap_a : Int = wrap_invoke()
let wrap_z : Int = read_arr_0([42])

pub fn get_wrap_a() -> Int {
  wrap_a
}

pub fn slice_owned_first(xs : Array[Int]) -> Int {
  let cp = xs[1:3].to_owned()
  cp[0] + cp[1]
}

// Round 3 Astra P0-3 & P1-1 cases
pub fn div_i32_neg0x1(a : Int) -> Int { a / -0x1 }
pub fn div_deep_7_fn(a : Int, b : Int, z : Int) -> Int { a / b / b / b / b / b / b / z }
pub fn div_idx_paren_fn(xs : Array[Int], b : Int) -> Int { (xs[0]) / b }

fn read_iife_z() -> Int { iife_z }
let iife_a : Int = (fn() { read_iife_z() })()
let iife_z : Int = read_arr_0([42])

pub fn get_iife_a() -> Int {
  iife_a
}

// Round 4 Opus P0 & Astra P0-3 cases
pub fn str_len_mod3(s : String) -> Int { s.length() % 3 }
pub fn str_len_div2(s : String) -> Int { s.length() / 2 }
pub fn str_len_mul3(s : String) -> Int { 1 + s.length() * 3 }
pub fn str_len_mul2_mod3(s : String) -> Int { s.length() * 2 % 3 }
pub fn str_len_div_plus_mod(s : String, n : Int) -> Int { s.length() / n + s.length() % 3 }
pub fn str_idx_mul2(s : String, i : Int) -> Int { s[i].to_int() * 2 }
pub fn arr_str_idx_len(xs : Array[String], i : Int) -> Int { xs[i].length() }

pub fn div_allones_i32(a : Int) -> Int { a / 0xffffffff }
pub fn div_allones_i64(a : Int64) -> Int64 { a / 0xffffffffffffffffL }

// Round 5 Astra P0-1 cases: string literals, struct field init after `:`, parenthesized lit, interp string length
pub struct LenBox {
  n : Int
}

pub fn str_lit_len_mul2() -> Int { "中A".length() * 2 }
pub fn str_lit_idx_1() -> Int { "中A"[1].to_int() }
pub fn str_paren_lit_len_mul2() -> Int { ("中A").length() * 2 }
pub fn str_struct_field_len(s : String) -> Int { LenBox::{ n: s.length() * 2 }.n }
pub fn str_interp_len(x : Int) -> Int { "中\{x}".length() }

// Round 6 Opus P1 & Astra P0-1 cases
pub fn filter_chain_len(xs : Array[Int]) -> Int {
  xs.filter(fn(x) { x > 1 }).length()
}

pub fn map_str_chain_len(xs : Array[String]) -> Int {
  xs.map(fn(t) { t.length() % 3 }).length()
}

pub fn slice_owned_str_len(s : String) -> Int {
  s[0:2].to_owned().length()
}

const CAP : String = "中A"

pub fn cap_idx_1() -> Int { CAP[1].to_int() }
pub fn cap_in_box() -> Int { LenBox::{ n: CAP[1].to_int() }.n }
pub fn[T] id_arr(xs : Array[T]) -> Option[Array[T]] { Some(xs) }

// Round 7 Astra P0: cross-package qualified `@acme.CAP[1]` & `@acme.Wrap[Int]` (no local `struct CAP`)
pub fn noshadow_acme_cap_idx() -> Int { @acme.CAP[1].to_int() }
pub fn noshadow_wrap_roundtrip(v : Int) -> Int {
  let opt : Option[@acme.Wrap[Int]] = Some(@acme.wrap_new(v))
  match opt {
    Some(w) => @acme.wrap_get(w)
    None => 0
  }
}
'''

ACME_MOON_MBT = r'''
pub const CAP : String = "中A"

pub struct Wrap[T] {
  v : T
}

pub fn[T] wrap_new(v : T) -> Wrap[T] {
  Wrap::{ v: v }
}

pub fn[T] wrap_get(w : Wrap[T]) -> T {
  w.v
}
'''

ACME_PION_SRC = r'''
pub let CAP : String = "中A"

pub struct Wrap[T] {
  v : T
}

pub fn wrap_new[T](v : T) -> Wrap[T] {
  Wrap::{ v: v }
}

pub fn wrap_get[T](w : Wrap[T]) -> T {
  w.v
}
'''

SHADOW_LIB_MBT = r'''
pub struct CAP {
  n : Int
}

pub fn shadow_acme_cap_idx() -> Int {
  @acme.CAP[1].to_int()
}

pub fn shadow_cap_box() -> Int {
  CAP::{ n: @acme.CAP[1].to_int() }.n
}

pub fn shadow_wrap_roundtrip(v : Int) -> Int {
  let opt : Option[@acme.Wrap[Int]] = Some(@acme.wrap_new(v))
  match opt {
    Some(w) => @acme.wrap_get(w)
    None => 0
  }
}
'''

ACME_API_MAP_JSON = '''{
  "symbols": [
    {"src_pkg": "acme", "src_name": "CAP", "kind": "const", "target_pkg": "acme", "target_name": "CAP"},
    {"src_pkg": "acme", "src_name": "Wrap", "kind": "struct", "target_pkg": "acme", "target_name": "Wrap"},
    {"src_pkg": "acme", "src_name": "wrap_new", "kind": "fn", "target_pkg": "acme", "target_name": "wrap_new"},
    {"src_pkg": "acme", "src_name": "wrap_get", "kind": "fn", "target_pkg": "acme", "target_name": "wrap_get"}
  ]
}
'''

# Round 8 Astra P0-1: NO api_map cross-package `@ext.CAP[INDEX]` inside struct literal `Box::{ n: ... }`
# alongside genuine type annotations `struct Holder { w : @ext.Wrap[Int] }` and `fn(w : @ext.Wrap[Int]) -> @ext.Wrap[Int]`.
NO_APIMAP_LIB_MBT = r'''
const INDEX : Int = 1

pub struct Box {
  n : Int
}

pub struct Holder {
  w : @ext.Wrap[Int]
}

pub fn box_const_idx() -> Int {
  Box::{ n: @ext.CAP[INDEX].to_int() }.n
}

pub fn box_lit_idx() -> Int {
  Box::{ n: @ext.CAP[1].to_int() }.n
}

pub fn holder_wrap(w : @ext.Wrap[Int]) -> @ext.Wrap[Int] {
  Holder::{ w: w }.w
}

pub fn holder_roundtrip(v : Int) -> Int {
  @ext.wrap_get(holder_wrap(@ext.wrap_new(v)))
}
'''

# Wave M1.2 Track A (A.1 - A.6) 3-engine Differential Oracle library
M12_RECIPES_TOML = '''[ref]
type_name = "mbt_compat::MbtCell"
field_name = "v"
ctor_call = "mbt_compat::mbt_cell"

[derives]
allow = ["Eq", "Hash"]
ignore = ["Show"]
'''

M12_LIB_MBT = r'''
// A.1: chained `.val.val`, side-effecting `get_ref().val += 1`, nested RHS `r.val = s.val + 1`,
//      collision-free `struct SVal { val; val_ }` (3, 8), and enum RHS `box.val = Blue`
pub enum Color {
  Red
  Blue
}

pub struct SVal {
  val : Int
  val_ : Int
}

pub fn m12_sval_pair() -> (Int, Int) {
  let s : SVal = { val: 3, val_: 8 }
  (s.val, s.val_)
}

pub fn m12_chained_val() -> Int {
  let inner : Ref[Int] = { val: 10 }
  let outer : Ref[Ref[Int]] = { val: inner }
  outer.val.val = outer.val.val + 5
  outer.val.val
}

pub fn m12_compound_single_eval() -> (Int, Int) {
  let calls : Ref[Int] = { val: 0 }
  let target : Ref[Int] = { val: 10 }
  fn get_ref() -> Ref[Int] {
    calls.val = calls.val + 1
    target
  }
  get_ref().val += 7
  (calls.val, target.val)
}

pub fn m12_nested_rhs_and_color() -> (Int, Bool) {
  let r : Ref[Int] = { val: 0 }
  let s : Ref[Int] = { val: 41 }
  r.val = s.val + 1
  let cbox : Ref[Color] = { val: Red }
  cbox.val = Blue
  let is_blue = match cbox.val {
    Blue => true
    Red => false
  }
  (r.val, is_blue)
}

// A.2: escaping recursive local `fn` with shared mutable capture (`14, 16`),
//      sibling block shadowing, mutual recursion, closure optional types, `if x is Some(v)`
pub fn m12_escaping_rec() -> (Int, Int) {
  let mut acc : Int = 10
  fn step(n : Int) -> Int {
    if n <= 0 {
      acc
    } else {
      acc = acc + n
      step(n - 1)
    }
  }
  let cb = fn(k : Int) -> Int { step(k) }
  let r1 = cb(2) + 1
  let r2 = cb(2)
  (r1, r2)
}

pub fn m12_sibling_shadow_and_mutual() -> (Int, Bool, Bool) {
  let a = {
    fn f(n : Int) -> Int { if n <= 0 { 0 } else { 1 + f(n - 1) } }
    f(3)
  }
  let b = {
    fn f(n : Int) -> Int { if n <= 0 { 0 } else { 2 + f(n - 1) } }
    f(3)
  }
  fn is_even(n : Int) -> Bool {
    if n == 0 { true } else if n == 1 { false } else { is_even(n - 2) }
  }
  fn is_odd(n : Int) -> Bool {
    if n == 0 { false } else { is_even(n - 1) }
  }
  (a * 10 + b, is_even(6), is_odd(5))
}

pub fn m12_closure_opt_and_is(cb : (() -> Unit)?, f : () -> Int64?) -> Int {
  let mut res = 0
  if cb is Some(g) {
    g()
    res = res + 10
  }
  if f() is Some(v) {
    res = res + v.to_int()
  }
  res
}

// A.5: same-file `enum Local { Some(Int); None }` + `let x = Some(17)` + `take_opt(Some(17))` -> (false, true)
//      plus dual-enum leading-dot positive control -> (11, 21)
enum Local {
  Some(Int)
  None
}

enum E1 {
  Tag(Int)
}

enum E2 {
  Tag(Int)
}

fn take_opt(o : Int?) -> Bool {
  match o {
    Some(_) => true
    None => false
  }
}

fn take_e1(e : E1) -> Int {
  match e {
    E1::Tag(v) => v + 10
  }
}

fn take_e2(e : E2) -> Int {
  match e {
    E2::Tag(v) => v + 20
  }
}

pub fn m12_per_site_enum_demo() -> (Bool, Bool, Int, Int) {
  let x = Some(17)
  let a = match x {
    Local::Some(v) => v == 0
    Local::None => false
  }
  let b = take_opt(Some(17))
  let c1 = take_e1(Tag(1))
  let c2 = take_e2(Tag(1))
  (a, b, c1, c2)
}

// A.6: single-param arrow closure, placeholder pipe (`5 |> take(2, _) == 25`, eval order `213` / `123`),
//      custom `7 |> ignore == 7`, live OrderedMap cursor mutation (`13`) + break/continue/return,
//      String cursor break/continue/return, and new `mbt_compat` helpers
fn ignore(x : Int) -> Int {
  x
}

fn take2(a : Int, b : Int) -> Int {
  a * 10 + b
}

fn combine3(a : Int, b : Int, c : Int) -> Int {
  a * 100 + b * 10 + c
}

pub fn m12_pipe_and_arrow_demo() -> (Int, Int, Int, Int) {
  let inc : (Int) -> Int = x => x + 1
  let p1 = inc(4) |> take2(2, _)
  let p2 = 7 |> ignore
  let trace : Ref[Int] = { val: 0 }
  fn step(n : Int) -> Int {
    trace.val = trace.val * 10 + n
    n
  }
  let p3 = step(1) |> combine3(step(2), _, step(3))
  (p1, p2, p3, trace.val)
}

pub fn m12_live_map_update() -> Int {
  let m : Map[String, Int] = { "a": 1, "b": 2 }
  let mut acc = 0
  for k, v in m {
    if k == "a" {
      m.set("b", 3)
    }
    acc = acc * 10 + v
  }
  acc
}

pub fn m12_map_and_str_control_flow() -> (Int, Int) {
  let m : Map[String, Int] = { "a": 1, "b": 2, "c": 3, "d": 4 }
  let mut msum = 0
  for k, v in m {
    if k == "b" {
      continue
    }
    if k == "d" {
      break
    }
    msum = msum + v
  }
  let mut scount = 0
  for ch in "A中😀B" {
    if ch == '中' {
      continue
    }
    if ch == 'B' {
      return (msum, scount)
    }
    scount = scount + 1
  }
  (msum, scount)
}

pub fn m12_compat_helpers_demo() -> (Int, String, Int, Bool, Bool, String, Bool) {
  let rf = match "a/b/c".rev_find("/") {
    Some(i) => i
    None => -1
  }
  let lo = "Hello WORLD".to_lower()
  let idx = match [10, 20, 30].search(20) {
    Some(i) => i
    None => -1
  }
  let has = [10, 20, 30].contains(30)
  let dig = '7'.is_ascii_digit() && 'Z'.to_ascii_lowercase() == 'z'
  let built = String::from_array(['A', (0x1F600).unsafe_to_char(), 'B'])
  let lex = "alpha".lexical_compare("k9") < 0 && "abc".lexical_compare("abcd") < 0 && "abc".lexical_compare("abc") == 0
  (rf, lo, idx, has, dig, built, lex)
}

// Quadrant 2 P0 semantics:
// 1. Anon struct literal `arr.push({ start: 0, count: 1 })` & `let s = { start: 0, count: 1 }`
//    + single-field `struct BoxVal { val: Int }; let b = { val: 3 }` (not misclassified as Ref!)
pub struct SpanRec {
  start : Int
  count : Int
}

pub struct BoxVal {
  val : Int
}

pub fn q2_anon_struct_and_boxval() -> (Int, Int, Int) {
  let arr : Array[SpanRec] = []
  arr.push({ start: 4, count: 9 })
  let s = { start: 2, count: 5 }
  let b : BoxVal = { val: 3 }
  (arr[0].start + arr[0].count, s.start * 10 + s.count, b.val)
}

// 2. Type ascriptions `(e : T)` never silently stripped
pub fn q2_type_ascriptions() -> (Int64, Double, Int64, Double, Bool) {
  let a = (3 : Int64) * 1000000000L
  let b = (7 : Double) / 2.0
  let c = (-3 : Int64)
  let d = (1.5 : Float).to_double()
  let e = match (None : Option[Int]) {
    Some(_) => false
    None => true
  }
  (a, b, c, d, e)
}

// 3. Constructor struct patterns `Ctor({ ... })`: non-binding guards, swapped order, dual binders, guard fallthrough
pub(all) struct NodeRec {
  ok : Bool
  tag : Int
  x : Option[Int]
  y : Option[Int]
}

pub(all) enum TreeRec {
  Leaf(NodeRec)
  EmptyTree
}

pub fn q2_ctor_struct_pat(t : TreeRec) -> Int {
  match t {
    Leaf({ ok: true, x: Some(a), y: Some(b), .. }) if a > 0 => a * 10 + b
    Leaf({ x: Some(v), ok: true, .. }) => v + 100
    Leaf({ ok: false, tag: 7, .. }) => 700
    Leaf({ tag: 1, .. }) => 111
    _ => -1
  }
}

// 4. Local fn declaration-order visibility + param shadowing outer `let` and `let mut`
fn outer_helper(x : Int) -> Int {
  x + 1000
}

pub fn q2_local_fn_order_and_shadow() -> (Int, Int) {
  let mut acc : Int = 5
  fn first_fn(n : Int) -> Int {
    outer_helper(n)
  }
  fn outer_helper(n : Int) -> Int {
    n + 1
  }
  fn shadow_rec(acc : Int) -> Int {
    if acc <= 0 { 0 } else { acc + shadow_rec(acc - 1) }
  }
  let r1 = first_fn(7) + outer_helper(7)
  let r2 = shadow_rec(3) + acc
  acc = acc + 1
  (r1, r2 + acc)
}

// 5. Placeholder pipe temp-name collision + named args `lbl=rhs`
fn sub_named(x : Int, scale~ : Int) -> Int {
  x * scale - 1
}

pub fn q2_pipe_collision_and_named() -> (Int, Int) {
  let __mbt_p_1 = 2
  let r1 = 5 |> take2(__mbt_p_1, _)
  let r2 = 6 |> sub_named(scale=3, _)
  (r1, r2)
}

// 6. Same-line two-type division + cascading probe + `for ch in s` with `'}'` char literal
pub fn q2_sameline_div_cascade_and_brace(a : Int, b : Int, x : Double, y : Double, n : Int) -> (Int, String, Int) {
  let s1 = (a / b) + (x / y).to_int()
  let part = n % 10
  let p_str = part.to_string()
  let mut braces = 0
  for ch in "a}b}c" {
    if ch == '}' {
      braces = braces + 1
    }
  }
  (s1, p_str, braces)
}

// 6b. Package-defined `fail` must NEVER be rewritten to `mbt_compat::fail` (P0)
//     and cross-line parenthesized receiver `let d = (7 : Double)\n(d / 2.0).to_string()` (P2)
pub fn fail(msg : String) -> String {
  "ok:" + msg
}

pub fn q2_crossline_paren_tail() -> String {
  let d = (7 : Double)
  (d / 2.0).to_string()
}

pub fn q2_shadowed_fail_and_crossline_paren() -> (String, String, Int) {
  let r1 = fail("x")
  let r2 = q2_crossline_paren_tail()
  let _ = ".mbt_len_probe("
  let s = "中😀"
  let arr = [1, 2]
  let r3 = s.length() * 10 + arr.length()
  (r1, r2, r3)
}

// 7. Quadrant 2 mechanical & compat:
//    Double +0.0/-0.0 hash, is_nan/compare/reinterpret_as_int64, Int::lnot,
//    Array unsafe_get/unsafe_set/is_empty/truncate, Map::new, self.arr[a:b],
//    trailing tuple newline, `(Double, (Double) -> Double)?`, fixed-length array patterns, `type Alias = T`
type NumPair = (Int, Int)

pub struct HolderArr {
  arr : Array[Int]
}

fn HolderArr::mid(self : HolderArr) -> Array[Int] {
  self.arr[1:3].to_owned()
}

pub fn q2_trailing_tuple_newline(x : Int) -> NumPair {
  let pieces = x + 1
  let _ = pieces
  (pieces, pieces * 2)
}

pub fn q2_tuple_opt_fn(opt : (Double, (Double) -> Double)?) -> Double {
  match opt {
    Some((v, f)) => f(v)
    None => 0.0
  }
}

pub fn q2_fixed_arr_match(xs : Array[Int]) -> Int {
  match xs {
    [] => 0
    [one] => one * 10
    [first, _] => first + 100
    _ => -1
  }
}

pub fn q2_double_and_collections() -> (Int, Bool, Int, Int, Int, Int) {
  let m : Map[Double, Int] = Map::new()
  m.set(0.0, 11)
  m.set(-0.0, 22)
  let mv = match m.get(0.0) {
    Some(v) => v
    None => -1
  }
  let nan_ok = (0.0 / 0.0).is_nan() && (1.0).compare(2.0) < 0 && (0.0).reinterpret_as_int64() == 0L
  let ln = (0).lnot()
  let xs = [10, 20, 30, 40]
  xs.unsafe_set(1, 25)
  let g = xs.unsafe_get(1)
  let h = HolderArr::{ arr: xs }
  let mid = h.mid()
  xs.truncate(2)
  let empty_ok = if xs.is_empty() { 0 } else { xs.length() }
  (mv, nan_ok, ln, g, mid[0] + mid[1], empty_ok)
}
'''

MOON_DRIVER_MBT = r'''
fn trace(k : String, v : String) -> Unit {
  println("T \{k}=\{v}")
}

fn check(id : String, cond : Bool) -> Unit {
  if cond {
    println("A \{id}")
  } else {
    println("FAILED \{id}")
    abort("assertion failed: \{id}")
  }
}

fn join_ints(xs : Array[Int]) -> String {
  let sb = StringBuilder::new()
  for i = 0; i < xs.length(); i = i + 1 {
    if i > 0 { sb.write_string(",") }
    sb.write_string(xs[i].to_string())
  }
  sb.to_string()
}

fn join_strs(xs : Array[String]) -> String {
  let sb = StringBuilder::new()
  for i = 0; i < xs.length(); i = i + 1 {
    if i > 0 { sb.write_string("|") }
    sb.write_string(xs[i])
  }
  sb.to_string()
}

fn main {
  let args = @env.args()
  let mut kase = ""
  for i = 1; i < args.length(); i = i + 1 {
    if args[i] != "--" {
      kase = args[i]
      break
    }
  }
  if kase == "guard" {
    let g1 = val_guard_demo(false)
    let g2 = val_guard_demo(true)
    let g3 = guard_is_demo(None)
    let g4 = guard_is_demo(Some(5))
    let g5 = div_guard_demo(false)
    let g6 = div_guard_demo(true)
    trace("val_false", g1.to_string())
    trace("val_true", g2.to_string())
    trace("is_none", g3.to_string())
    trace("is_some", g4.to_string())
    trace("div_false", g5.to_string())
    trace("div_true", g6.to_string())
    check("guard.val_false", g1 == 17)
    check("guard.val_true", g2 == 42)
    check("guard.is_none", g3 == 17)
    check("guard.is_some", g4 == 6)
    check("guard.div_false", g5 == 0)
    check("guard.div_true", g6 == 42)
  } else if kase == "init_order" {
    let fv = get_first_val()
    let ilen = get_init_log_len()
    let i0 = get_init_log_0()
    trace("first_val", fv.to_string())
    trace("init_len", ilen.to_string())
    trace("init_0", i0.to_string())
    check("init.first_val", fv == 42)
    check("init.log_len", ilen == 1)
    check("init.log_0", i0 == 42)
  } else if kase == "optional_relay" {
    let res = run_optional_order()
    trace("seq", join_ints(res))
    check("opt.r1", res[0] == 27)
    check("opt.r2", res[1] == 23)
    check("opt.r3", res[2] == 123)
    check("opt.side_count", res[3] == 7)
    check("opt.default_once", res[4] == 10 && res[5] == 100 && res[6] == 20 && res[7] == 3)
  } else if kase == "utf16" {
    let s = "A中😀B"
    let n = utf16_length(s)
    trace("len", n.to_string())
    check("utf16.len", n == 5)
    for i = 0; i < 5; i = i + 1 {
      trace("cu\{i}", utf16_unit_int(s, i).to_string())
    }
    check("utf16.cu0", utf16_unit_int(s, 0) == 65)
    check("utf16.cu1", utf16_unit_int(s, 1) == 20013)
    check("utf16.cu2", utf16_unit_int(s, 2) == 55357)
    check("utf16.cu3", utf16_unit_int(s, 3) == 56832)
    check("utf16.cu4", utf16_unit_int(s, 4) == 66)
    let sl = utf16_slice_str(s, 2, 4)
    trace("slice", sl)
    check("utf16.slice", sl == "😀")
    let sc = utf16_scalar_codes(s)
    trace("scalars", join_ints(sc))
    check("utf16.scalars", sc.length() == 4)
    let c1 = str_cmp("k9", "alpha")
    let c2 = str_cmp("😀", "\u{FF01}\u{FF01}")
    trace("cmp1", c1.to_string())
    trace("cmp2", c2.to_string())
    check("utf16.cmp1", c1 < 0)
    check("utf16.cmp2", c2 < 0)
  } else if kase == "ordered_map" {
    let out = ordered_map_keys_demo()
    trace("entries", join_strs(out))
    check("map.len", out.length() == 10)
    check("map.before_first", out[0] == "zeta=1" && out[1] == "alpha=2" && out[4] == "k9=5")
    check("map.reinsert_end", out[5] == "after:zeta=1" && out[9] == "after:alpha=6")
  } else if kase == "double_fmt" {
    let s1 = fmt_double(1.5e-7)
    let s2 = fmt_double(-0.0)
    let s3 = fmt_double(1.0e20)
    let s4 = fmt_double(0.0 / 0.0)
    let s5 = fmt_double(1.0 / 0.0)
    let s6 = fmt_double(42.0)
    trace("d1", s1)
    trace("d2", s2)
    trace("d3", s3)
    trace("d4", s4)
    trace("d5", s5)
    trace("d6", s6)
    check("dbl.small", s1 == "1.5e-7")
    check("dbl.neg0", s2 == "0")
    check("dbl.big", s3 == "100000000000000000000")
    check("dbl.nan", s4 == "NaN")
    check("dbl.inf", s5 == "Infinity")
    check("dbl.int", s6 == "42")
  } else if kase == "div_nonzero" {
    let a = div_i32(-7, 2)
    let b = mod_i32(-7, 2)
    let c = div_i64(-7L, 2L)
    let d = mod_i64(-7L, 2L)
    let e = div_u32(7U, 2U)
    let f = mod_u32(7U, 2U)
    let g = div_u64(7UL, 2UL)
    let h = mod_u64(7UL, 2UL)
    trace("i32", "\{a},\{b}")
    trace("i64", "\{c},\{d}")
    trace("u32", "\{e},\{f}")
    trace("u64", "\{g},\{h}")
    check("div.i32", a == -3 && b == -1)
    check("div.i64", c == -3L && d == -1L)
    check("div.u32", e == 3U && f == 1U)
    check("div.u64", g == 3UL && h == 1UL)
  } else if kase == "div_i32_const_zero" {
    trace("before", "ok")
    trace("after", div_i32_const0(7).to_string())
  } else if kase == "mod_i32_const_zero" {
    trace("before", "ok")
    trace("after", mod_i32_const0(7).to_string())
  } else if kase == "div_u32_const_zero" {
    trace("before", "ok")
    trace("after", div_u32_const0(7U).to_string())
  } else if kase == "mod_u32_const_zero" {
    trace("before", "ok")
    trace("after", mod_u32_const0(7U).to_string())
  } else if kase == "div_i32_rt_zero" {
    let z = [0][0]
    trace("before", "ok")
    trace("after", div_i32(7, z).to_string())
  } else if kase == "mod_i32_rt_zero" {
    let z = [0][0]
    trace("before", "ok")
    trace("after", mod_i32(7, z).to_string())
  } else if kase == "div_i64_rt_zero" {
    let z = [0L][0]
    trace("before", "ok")
    trace("after", div_i64(7L, z).to_string())
  } else if kase == "mod_i64_rt_zero" {
    let z = [0L][0]
    trace("before", "ok")
    trace("after", mod_i64(7L, z).to_string())
  } else if kase == "div_u32_rt_zero" {
    let z = [0U][0]
    trace("before", "ok")
    trace("after", div_u32(7U, z).to_string())
  } else if kase == "mod_u32_rt_zero" {
    let z = [0U][0]
    trace("before", "ok")
    trace("after", mod_u32(7U, z).to_string())
  } else if kase == "div_u64_rt_zero" {
    let z = [0UL][0]
    trace("before", "ok")
    trace("after", div_u64(7UL, z).to_string())
  } else if kase == "mod_u64_rt_zero" {
    let z = [0UL][0]
    trace("before", "ok")
    trace("after", mod_u64(7UL, z).to_string())
  } else if kase == "cascade_generics" {
    let h = Holder::{ text: "hi", items: [10] }
    let out = cascade_demo(h, 5)
    trace("cascade", join_ints(out))
    check("cas.len", out.length() == 3)
    check("cas.vals", out[0] == 10 && out[1] == 6 && out[2] == 7)
    let sl = array_slice_demo([10, 20, 30, 40], 1, 3)
    trace("arr_slice", join_ints(sl))
    check("slice.vals", sl.length() == 2 && sl[0] == 20 && sl[1] == 30)
    let g = id_val(99)
    let t = match_tri(Tri(7, b=8, c=9))
    let t0 = match_tri(Empty)
    trace("gen_tri", "\{g},\{t},\{t0}")
    check("gen.id", g == 99)
    check("ctor.rest", t == 7)
    let r1 = Rec::{ opt: Some(5), arr: [1, 2] }
    let r2 = Rec::{ opt: Some(5), arr: [1, 2] }
    let r3 = Rec::{ opt: Some(5), arr: [1, 3] }
    let eq12 = r1 == r2
    let eq13 = r1 == r3
    trace("eq", "\{eq12},\{eq13}")
    check("derive.eq", eq12 && !eq13)
  } else if kase == "source_loc" {
    let (a, b) = two_source_locs()
    let has_file_a = a.contains("oracle_lib.mbt:")
    let has_file_b = b.contains("oracle_lib.mbt:")
    let distinct = a != b
    trace("has_file_a", has_file_a.to_string())
    trace("has_file_b", has_file_b.to_string())
    trace("distinct", distinct.to_string())
    check("loc.file_a", has_file_a)
    check("loc.file_b", has_file_b)
    check("loc.distinct", distinct)
  } else if kase == "mul_div_prec" {
    let r1 = mul_div_chain(5, 3, 2)
    let r2 = mul_mod_chain(5, 3, 4)
    let r3 = idx_mul_div([7, 9], 1, 4)
    let r4 = mul_div_i64(5L, 2L)
    let r5 = mod_then_div(23, 10, 2)
    let r6 = div_then_div(24, 3, 2)
    let r7 = div_paren_sub(20, 9, 5)
    let r8 = div_unary_neg(20, 4)
    trace("r", "\{r1},\{r2},\{r3},\{r4},\{r5},\{r6},\{r7},\{r8}")
    check("prec.mul_div", r1 == 7)
    check("prec.mul_mod", r2 == 3)
    check("prec.idx_mul_div", r3 == 4)
    check("prec.i64", r4 == 7L)
    check("prec.mod_div", r5 == 1)
    check("prec.div_div", r6 == 4)
    check("prec.paren_sub", r7 == 5)
    check("prec.unary_neg", r8 == -5)
  } else if kase == "div_neg_zero" {
    let z = [0][0]
    trace("before", "ok")
    trace("after", div_unary_neg(7, z).to_string())
  } else if kase == "interp_probe" {
    let s = interp_probe_demo(15, 2, "A中😀B", 1.5e-7)
    trace("interp", s)
    check("interp.val", s == "r=7 len=5 d=1.5e-7")
    let s2 = interp_probe_demo(9, 4, "😀", -0.0)
    trace("interp2", s2)
    check("interp.val2", s2 == "r=2 len=2 d=0")
  } else if kase == "arrayview_backing" {
    let out = arrayview_backing_demo()
    trace("av", join_ints(out))
    check("av.pre_v0", out[0] == 2)
    check("av.pre_w0", out[1] == 2)
    check("av.post_v0", out[2] == 2)
    check("av.post_a0", out[3] == 3)
    check("av.post_w0", out[4] == 2)
  } else if kase == "init_invoke_closure" {
    let v = get_inv_a()
    trace("inv_a", v.to_string())
    check("init.inv_a", v == 42)
  } else if kase == "div_const_then_rt_zero" {
    let z = [0][0]
    trace("before", "ok")
    trace("after", div_const_then_rt(10, z).to_string())
  } else if kase == "div_len_rt_zero" {
    let z = [0][0]
    trace("before", "ok")
    trace("after", div_len_rt([1, 2, 3], z).to_string())
  } else if kase == "div_byte_zero" {
    trace("before", "ok")
    trace("after", div_byte_const0(b'\x07').to_int().to_string())
  } else if kase == "div_min_neg1" {
    let m = [-2147483648][0]
    trace("before", "ok")
    trace("after", div_i32_neg1(m).to_string())
  } else if kase == "init_wrap_invoke_closure" {
    let v = get_wrap_a()
    trace("wrap_a", v.to_string())
    check("init.wrap_a", v == 42)
  } else if kase == "array_slice_to_owned" {
    let xs = [10, 20, 30, 40]
    let sum = slice_owned_first(xs)
    trace("sum", sum.to_string())
    check("slice_owned.sum", sum == 50)
    check("slice_owned.orig", xs[1] == 20)
  } else if kase == "div_min_neg0x1" {
    let m = [-2147483648][0]
    trace("before", "ok")
    trace("after", div_i32_neg0x1(m).to_string())
  } else if kase == "div_deep_7" {
    let z = [0][0]
    trace("before", "ok")
    trace("after", div_deep_7_fn(12, 1, z).to_string())
  } else if kase == "div_idx_paren" {
    let z = [0][0]
    trace("before", "ok")
    trace("after", div_idx_paren_fn([5], z).to_string())
  } else if kase == "init_iife_helper" {
    let v = get_iife_a()
    trace("iife_a", v.to_string())
    check("init.iife_a", v == 42)
  } else if kase == "utf16_arith_and_idx" {
    let s = "A中😀Bxyz"
    let r1 = str_len_mod3(s)
    let r2 = str_len_div2(s)
    let r3 = str_len_mul3(s)
    let r4 = str_len_mul2_mod3(s)
    let r5 = str_len_div_plus_mod(s, 2)
    let r6 = str_idx_mul2(s, 4)
    let r7 = arr_str_idx_len([s, "中😀"], 1)
    trace("r", "\{r1},\{r2},\{r3},\{r4},\{r5},\{r6},\{r7}")
    check("u16.mod3", r1 == 2)
    check("u16.div2", r2 == 4)
    check("u16.mul3", r3 == 25)
    check("u16.mul2_mod3", r4 == 1)
    check("u16.div_plus_mod", r5 == 6)
    check("u16.idx_mul2", r6 == 132)
    check("u16.arr_idx_len", r7 == 3)
  } else if kase == "div_min_allones_i32" {
    let m = [-2147483648][0]
    trace("before", "ok")
    trace("after", div_allones_i32(m).to_string())
  } else if kase == "div_min_allones_i64" {
    let m = [-9223372036854775807L - 1L][0]
    trace("before", "ok")
    trace("after", div_allones_i64(m).to_string())
  } else if kase == "utf16_lit_struct_interp" {
    let r1 = str_lit_len_mul2()
    let r2 = str_lit_idx_1()
    let r3 = str_paren_lit_len_mul2()
    let r4 = str_struct_field_len("中A")
    let r5 = str_interp_len(7)
    trace("r", "\{r1},\{r2},\{r3},\{r4},\{r5}")
    check("r5.lit_len", r1 == 4)
    check("r5.lit_idx", r2 == 65)
    check("r5.paren_lit", r3 == 4)
    check("r5.struct_field", r4 == 4)
    check("r5.interp_len", r5 == 2)
  } else if kase == "mbt_compat_chain_len" {
    let a = filter_chain_len([1, 2, 3, 4])
    let b = map_str_chain_len(["A中😀", "xy"])
    let c = slice_owned_str_len("中A😀")
    trace("r", "\{a},\{b},\{c}")
    check("r6.filter_len", a == 3)
    check("r6.map_len", b == 2)
    check("r6.slice_str_len", c == 2)
  } else if kase == "const_upper_idx_and_generic" {
    let a = cap_idx_1()
    let b = cap_in_box()
    let c = match id_arr([10, 20, 30]) {
      Some(v) => v.length()
      None => 0
    }
    trace("r", "\{a},\{b},\{c}")
    check("r6.cap_idx", a == 65)
    check("r6.cap_box", b == 65)
    check("r6.id_arr", c == 3)
  } else if kase == "cross_pkg_cap_noshadow" {
    let a = noshadow_acme_cap_idx()
    let b = noshadow_wrap_roundtrip(42)
    trace("r", "\{a},\{b}")
    check("r7.noshadow_cap", a == 65)
    check("r7.noshadow_wrap", b == 42)
  } else if kase == "cross_pkg_cap_shadow" {
    let a = @shadow.shadow_acme_cap_idx()
    let b = @shadow.shadow_cap_box()
    let c = @shadow.shadow_wrap_roundtrip(42)
    trace("r", "\{a},\{b},\{c}")
    check("r7.shadow_cap", a == 65)
    check("r7.shadow_box", b == 65)
    check("r7.shadow_wrap", c == 42)
  } else if kase == "cross_pkg_no_apimap_box" {
    let a = @nomap.box_const_idx()
    let b = @nomap.box_lit_idx()
    let c = @nomap.holder_roundtrip(99)
    trace("r", "\{a},\{b},\{c}")
    check("r8.box_const_idx", a == 65)
    check("r8.box_lit_idx", b == 65)
    check("r8.holder_wrap", c == 99)
  } else if kase == "m12_val_probes" {
    let (s1, s2) = @m12.m12_sval_pair()
    let ch = @m12.m12_chained_val()
    let (calls, tv) = @m12.m12_compound_single_eval()
    let (nr, is_blue) = @m12.m12_nested_rhs_and_color()
    trace("r", "\{s1},\{s2},\{ch},\{calls},\{tv},\{nr},\{is_blue}")
    check("m12.sval_3", s1 == 3)
    check("m12.sval_8", s2 == 8)
    check("m12.chained_val", ch == 15)
    check("m12.compound_calls_1", calls == 1)
    check("m12.compound_val_17", tv == 17)
    check("m12.nested_and_blue", nr == 42 && is_blue)
  } else if kase == "m12_recursive_local_fn" {
    let (r1, r2) = @m12.m12_escaping_rec()
    let (sh, ev, od) = @m12.m12_sibling_shadow_and_mutual()
    let mut ping = 0
    let co = @m12.m12_closure_opt_and_is(Some(fn() { ping = ping + 1 }), fn() { Some(7L) })
    trace("r", "\{r1},\{r2},\{sh},\{ev},\{od},\{co},\{ping}")
    check("m12.esc_14", r1 == 14)
    check("m12.esc_16", r2 == 16)
    check("m12.sibling_shadow", sh == 36)
    check("m12.mutual_rec", ev && od)
    check("m12.closure_opt_is", co == 17 && ping == 1)
  } else if kase == "m12_per_site_enum" {
    let (a, b, c1, c2) = @m12.m12_per_site_enum_demo()
    trace("r", "\{a},\{b},\{c1},\{c2}")
    check("m12.local_some_false", !a)
    check("m12.opt_some_true", b)
    check("m12.dual_e1_11", c1 == 11)
    check("m12.dual_e2_21", c2 == 21)
  } else if kase == "m12_pipe_loops_compat" {
    let (p1, p2, p3, tr) = @m12.m12_pipe_and_arrow_demo()
    let lm = @m12.m12_live_map_update()
    let (ms, sc) = @m12.m12_map_and_str_control_flow()
    let (rf, lo, idx, has, dig, built, lex) = @m12.m12_compat_helpers_demo()
    trace("r", "\{p1},\{p2},\{p3},\{tr},\{lm},\{ms},\{sc},\{rf},\{lo},\{idx},\{has},\{dig},\{built},\{lex}")
    check("m12.pipe_25", p1 == 25)
    check("m12.pipe_ignore_7", p2 == 7)
    check("m12.pipe_order_213", p3 == 213)
    check("m12.pipe_trace_123", tr == 123)
    check("m12.live_map_13", lm == 13)
    check("m12.map_ctrl_4", ms == 4)
    check("m12.str_ctrl_2", sc == 2)
    check("m12.rev_find_3", rf == 3)
    check("m12.arr_search_contains", idx == 1 && has)
    check("m12.char_and_from_arr", dig && lo == "hello world" && built == "A😀B" && lex)
  } else if kase == "q2_semantics_p0" {
    let (a1, a2, a3) = @m12.q2_anon_struct_and_boxval()
    let (t1, t2, t3, t4, t5) = @m12.q2_type_ascriptions()
    let p1 = @m12.q2_ctor_struct_pat(@m12.TreeRec::Leaf(@m12.NodeRec::{ ok: true, tag: 1, x: Some(3), y: Some(4) }))
    let p2 = @m12.q2_ctor_struct_pat(@m12.TreeRec::Leaf(@m12.NodeRec::{ ok: true, tag: 1, x: Some(-2), y: Some(4) }))
    let p3 = @m12.q2_ctor_struct_pat(@m12.TreeRec::Leaf(@m12.NodeRec::{ ok: false, tag: 7, x: Some(3), y: Some(4) }))
    let p4 = @m12.q2_ctor_struct_pat(@m12.TreeRec::Leaf(@m12.NodeRec::{ ok: false, tag: 1, x: None, y: None }))
    let (l1, l2) = @m12.q2_local_fn_order_and_shadow()
    let (pp1, pp2) = @m12.q2_pipe_collision_and_named()
    let (sd1, sd2, sd3) = @m12.q2_sameline_div_cascade_and_brace(-7, 2, 7.0, 2.0, -23)
    let (sf1, cl1, sp1) = @m12.q2_shadowed_fail_and_crossline_paren()
    trace("r", "\{a1},\{a2},\{a3},\{t1},\{t2},\{t3},\{t4},\{t5},\{p1},\{p2},\{p3},\{p4},\{l1},\{l2},\{pp1},\{pp2},\{sd1},\{sd2},\{sd3},\{sf1},\{cl1},\{sp1}")
    check("q2.anon_struct", a1 == 13 && a2 == 25)
    check("q2.boxval_3", a3 == 3)
    check("q2.ascribe_i64_dbl", t1 == 3000000000L && t2 == 3.5 && t3 == -3L && t4 == 1.5 && t5)
    check("q2.ctor_pat_dual", p1 == 34)
    check("q2.ctor_pat_fallthrough", p2 == 98)
    check("q2.ctor_pat_guard_and_tag", p3 == 700 && p4 == 111)
    check("q2.local_fn_order", l1 == 1015)
    check("q2.local_fn_shadow", l2 == 17)
    check("q2.pipe_collision_named", pp1 == 25 && pp2 == 17)
    check("q2.sameline_div_cascade_brace", sd1 == 0 && sd2 == "-3" && sd3 == 2)
    check("q2.shadowed_fail", sf1 == "ok:x")
    check("q2.crossline_paren_recv", cl1 == "3.5")
    check("q2.str_lit_probe_32", sp1 == 32)
  } else if kase == "q2_mechanical_compat" {
    let (nt1, nt2) = @m12.q2_trailing_tuple_newline(9)
    let tf1 = @m12.q2_tuple_opt_fn(Some((3.0, fn(v) { v * 2.0 })))
    let tf2 = @m12.q2_tuple_opt_fn(None)
    let fm0 = @m12.q2_fixed_arr_match([])
    let fm1 = @m12.q2_fixed_arr_match([7])
    let fm2 = @m12.q2_fixed_arr_match([5, 9])
    let fm3 = @m12.q2_fixed_arr_match([1, 2, 3])
    let (mv, nan_ok, ln, g, mid_s, emp) = @m12.q2_double_and_collections()
    trace("r", "\{nt1},\{nt2},\{tf1},\{tf2},\{fm0},\{fm1},\{fm2},\{fm3},\{mv},\{nan_ok},\{ln},\{g},\{mid_s},\{emp}")
    check("q2.trailing_tuple", nt1 == 10 && nt2 == 20)
    check("q2.tuple_opt_fn", tf1 == 6.0 && tf2 == 0.0)
    check("q2.arr_pat_0", fm0 == 0)
    check("q2.arr_pat_1", fm1 == 70)
    check("q2.arr_pat_2_3", fm2 == 105 && fm3 == -1)
    check("q2.dbl_zero_hash", mv == 22)
    check("q2.dbl_nan_cmp", nan_ok)
    check("q2.int_lnot", ln == -1)
    check("q2.unsafe_get_set", g == 25)
    check("q2.self_arr_slice_trunc", mid_s == 55 && emp == 2)
  } else {
    abort("unknown case: \{kase}")
  }
}
'''

PION_DRIVER_PION = r'''
import "mbt_compat" as mbt_compat
import "shadow" as shadow
import "nomap" as nomap
import "m12" as m12

fn trace(w : World, k : String, v : String) -> Unit {
  io_println(w, "T " + k + "=" + v)
}

fn check(w : World, id : String, cond : Bool) -> Unit {
  if cond {
    io_println(w, "A " + id)
  } else {
    io_println(w, "FAILED " + id)
    panic("assertion failed: " + id)
  }
}

fn join_ints(xs : Array[Int]) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < xs.length() {
    if i > 0 { sb.write_string(",") }
    sb.write_string(xs[i].to_string())
    i = i + 1
  }
  sb.to_string()
}

fn join_strs(xs : Array[String]) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < xs.length() {
    if i > 0 { sb.write_string("|") }
    sb.write_string(xs[i])
    i = i + 1
  }
  sb.to_string()
}

pub fn main(w : World) -> Int {
  let args = world_args(w)
  let mut kase = ""
  let mut i = 1
  while i < args.length() {
    if args[i] != "--" {
      kase = args[i]
      break
    }
    i = i + 1
  }
  if kase == "guard" {
    let g1 = val_guard_demo(false)
    let g2 = val_guard_demo(true)
    let g3 = guard_is_demo(None)
    let g4 = guard_is_demo(Some(5))
    let g5 = div_guard_demo(false)
    let g6 = div_guard_demo(true)
    trace(w, "val_false", g1.to_string())
    trace(w, "val_true", g2.to_string())
    trace(w, "is_none", g3.to_string())
    trace(w, "is_some", g4.to_string())
    trace(w, "div_false", g5.to_string())
    trace(w, "div_true", g6.to_string())
    check(w, "guard.val_false", g1 == 17)
    check(w, "guard.val_true", g2 == 42)
    check(w, "guard.is_none", g3 == 17)
    check(w, "guard.is_some", g4 == 6)
    check(w, "guard.div_false", g5 == 0)
    check(w, "guard.div_true", g6 == 42)
  } else if kase == "init_order" {
    let fv = get_first_val()
    let ilen = get_init_log_len()
    let i0 = get_init_log_0()
    trace(w, "first_val", fv.to_string())
    trace(w, "init_len", ilen.to_string())
    trace(w, "init_0", i0.to_string())
    check(w, "init.first_val", fv == 42)
    check(w, "init.log_len", ilen == 1)
    check(w, "init.log_0", i0 == 42)
  } else if kase == "optional_relay" {
    let res = run_optional_order()
    trace(w, "seq", join_ints(res))
    check(w, "opt.r1", res[0] == 27)
    check(w, "opt.r2", res[1] == 23)
    check(w, "opt.r3", res[2] == 123)
    check(w, "opt.side_count", res[3] == 7)
    check(w, "opt.default_once", res[4] == 10 && res[5] == 100 && res[6] == 20 && res[7] == 3)
  } else if kase == "utf16" {
    let s = "A中😀B"
    let n = utf16_length(s)
    trace(w, "len", n.to_string())
    check(w, "utf16.len", n == 5)
    let mut k = 0
    while k < 5 {
      trace(w, "cu" + k.to_string(), utf16_unit_int(s, k).to_string())
      k = k + 1
    }
    check(w, "utf16.cu0", utf16_unit_int(s, 0) == 65)
    check(w, "utf16.cu1", utf16_unit_int(s, 1) == 20013)
    check(w, "utf16.cu2", utf16_unit_int(s, 2) == 55357)
    check(w, "utf16.cu3", utf16_unit_int(s, 3) == 56832)
    check(w, "utf16.cu4", utf16_unit_int(s, 4) == 66)
    let sl = utf16_slice_str(s, 2, 4)
    trace(w, "slice", sl)
    check(w, "utf16.slice", sl == "😀")
    let sc = utf16_scalar_codes(s)
    trace(w, "scalars", join_ints(sc))
    check(w, "utf16.scalars", sc.length() == 4)
    let c1 = str_cmp("k9", "alpha")
    let c2 = str_cmp("😀", "\u{FF01}\u{FF01}")
    trace(w, "cmp1", c1.to_string())
    trace(w, "cmp2", c2.to_string())
    check(w, "utf16.cmp1", c1 < 0)
    check(w, "utf16.cmp2", c2 < 0)
  } else if kase == "ordered_map" {
    let out = ordered_map_keys_demo()
    trace(w, "entries", join_strs(out))
    check(w, "map.len", out.length() == 10)
    check(w, "map.before_first", out[0] == "zeta=1" && out[1] == "alpha=2" && out[4] == "k9=5")
    check(w, "map.reinsert_end", out[5] == "after:zeta=1" && out[9] == "after:alpha=6")
  } else if kase == "double_fmt" {
    let s1 = fmt_double(1.5e-7)
    let s2 = fmt_double(-0.0)
    let s3 = fmt_double(1.0e20)
    let s4 = fmt_double(0.0 / 0.0)
    let s5 = fmt_double(1.0 / 0.0)
    let s6 = fmt_double(42.0)
    trace(w, "d1", s1)
    trace(w, "d2", s2)
    trace(w, "d3", s3)
    trace(w, "d4", s4)
    trace(w, "d5", s5)
    trace(w, "d6", s6)
    check(w, "dbl.small", s1 == "1.5e-7")
    check(w, "dbl.neg0", s2 == "0")
    check(w, "dbl.big", s3 == "100000000000000000000")
    check(w, "dbl.nan", s4 == "NaN")
    check(w, "dbl.inf", s5 == "Infinity")
    check(w, "dbl.int", s6 == "42")
  } else if kase == "div_nonzero" {
    let a = div_i32(-7, 2)
    let b = mod_i32(-7, 2)
    let c = div_i64(-7L, 2L)
    let d = mod_i64(-7L, 2L)
    let e = div_u32(7U, 2U)
    let f = mod_u32(7U, 2U)
    let g = div_u64(7UL, 2UL)
    let h = mod_u64(7UL, 2UL)
    trace(w, "i32", a.to_string() + "," + b.to_string())
    trace(w, "i64", c.to_string() + "," + d.to_string())
    trace(w, "u32", e.to_string() + "," + f.to_string())
    trace(w, "u64", g.to_string() + "," + h.to_string())
    check(w, "div.i32", a == -3 && b == -1)
    check(w, "div.i64", c == -3L && d == -1L)
    check(w, "div.u32", e == 3U && f == 1U)
    check(w, "div.u64", g == 3UL && h == 1UL)
  } else if kase == "div_i32_const_zero" {
    trace(w, "before", "ok")
    trace(w, "after", div_i32_const0(7).to_string())
  } else if kase == "mod_i32_const_zero" {
    trace(w, "before", "ok")
    trace(w, "after", mod_i32_const0(7).to_string())
  } else if kase == "div_u32_const_zero" {
    trace(w, "before", "ok")
    trace(w, "after", div_u32_const0(7U).to_string())
  } else if kase == "mod_u32_const_zero" {
    trace(w, "before", "ok")
    trace(w, "after", mod_u32_const0(7U).to_string())
  } else if kase == "div_i32_rt_zero" {
    let z = [0][0]
    trace(w, "before", "ok")
    trace(w, "after", div_i32(7, z).to_string())
  } else if kase == "mod_i32_rt_zero" {
    let z = [0][0]
    trace(w, "before", "ok")
    trace(w, "after", mod_i32(7, z).to_string())
  } else if kase == "div_i64_rt_zero" {
    let z = [0L][0]
    trace(w, "before", "ok")
    trace(w, "after", div_i64(7L, z).to_string())
  } else if kase == "mod_i64_rt_zero" {
    let z = [0L][0]
    trace(w, "before", "ok")
    trace(w, "after", mod_i64(7L, z).to_string())
  } else if kase == "div_u32_rt_zero" {
    let z = [0U][0]
    trace(w, "before", "ok")
    trace(w, "after", div_u32(7U, z).to_string())
  } else if kase == "mod_u32_rt_zero" {
    let z = [0U][0]
    trace(w, "before", "ok")
    trace(w, "after", mod_u32(7U, z).to_string())
  } else if kase == "div_u64_rt_zero" {
    let z = [0UL][0]
    trace(w, "before", "ok")
    trace(w, "after", div_u64(7UL, z).to_string())
  } else if kase == "mod_u64_rt_zero" {
    let z = [0UL][0]
    trace(w, "before", "ok")
    trace(w, "after", mod_u64(7UL, z).to_string())
  } else if kase == "cascade_generics" {
    let h = Holder::{ text: "hi", items: [10] }
    let out = cascade_demo(h, 5)
    trace(w, "cascade", join_ints(out))
    check(w, "cas.len", out.length() == 3)
    check(w, "cas.vals", out[0] == 10 && out[1] == 6 && out[2] == 7)
    let sl = array_slice_demo([10, 20, 30, 40], 1, 3)
    trace(w, "arr_slice", join_ints(sl))
    check(w, "slice.vals", sl.length() == 2 && sl[0] == 20 && sl[1] == 30)
    let g = id_val(99)
    let t = match_tri(Tri(7, 8, 9))
    let t0 = match_tri(Empty)
    trace(w, "gen_tri", g.to_string() + "," + t.to_string() + "," + t0.to_string())
    check(w, "gen.id", g == 99)
    check(w, "ctor.rest", t == 7)
    let r1 = Rec::{ opt: Some(5), arr: [1, 2] }
    let r2 = Rec::{ opt: Some(5), arr: [1, 2] }
    let r3 = Rec::{ opt: Some(5), arr: [1, 3] }
    let eq12 = __mbt_eq_rec(r1, r2)
    let eq13 = __mbt_eq_rec(r1, r3)
    trace(w, "eq", eq12.to_string() + "," + eq13.to_string())
    check(w, "derive.eq", eq12 && !eq13)
  } else if kase == "source_loc" {
    let (a, b) = two_source_locs()
    let has_file_a = a.index_of("oracle_lib.mbt:") >= 0
    let has_file_b = b.index_of("oracle_lib.mbt:") >= 0
    let distinct = a != b
    trace(w, "has_file_a", has_file_a.to_string())
    trace(w, "has_file_b", has_file_b.to_string())
    trace(w, "distinct", distinct.to_string())
    check(w, "loc.file_a", has_file_a)
    check(w, "loc.file_b", has_file_b)
    check(w, "loc.distinct", distinct)
  } else if kase == "mul_div_prec" {
    let r1 = mul_div_chain(5, 3, 2)
    let r2 = mul_mod_chain(5, 3, 4)
    let r3 = idx_mul_div([7, 9], 1, 4)
    let r4 = mul_div_i64(5L, 2L)
    let r5 = mod_then_div(23, 10, 2)
    let r6 = div_then_div(24, 3, 2)
    let r7 = div_paren_sub(20, 9, 5)
    let r8 = div_unary_neg(20, 4)
    trace(w, "r", r1.to_string() + "," + r2.to_string() + "," + r3.to_string() + "," + r4.to_string() + "," + r5.to_string() + "," + r6.to_string() + "," + r7.to_string() + "," + r8.to_string())
    check(w, "prec.mul_div", r1 == 7)
    check(w, "prec.mul_mod", r2 == 3)
    check(w, "prec.idx_mul_div", r3 == 4)
    check(w, "prec.i64", r4 == 7L)
    check(w, "prec.mod_div", r5 == 1)
    check(w, "prec.div_div", r6 == 4)
    check(w, "prec.paren_sub", r7 == 5)
    check(w, "prec.unary_neg", r8 == -5)
  } else if kase == "div_neg_zero" {
    let z = [0][0]
    trace(w, "before", "ok")
    trace(w, "after", div_unary_neg(7, z).to_string())
  } else if kase == "interp_probe" {
    let s = interp_probe_demo(15, 2, "A中😀B", 1.5e-7)
    trace(w, "interp", s)
    check(w, "interp.val", s == "r=7 len=5 d=1.5e-7")
    let s2 = interp_probe_demo(9, 4, "😀", -0.0)
    trace(w, "interp2", s2)
    check(w, "interp.val2", s2 == "r=2 len=2 d=0")
  } else if kase == "arrayview_backing" {
    let out = arrayview_backing_demo()
    trace(w, "av", join_ints(out))
    check(w, "av.pre_v0", out[0] == 2)
    check(w, "av.pre_w0", out[1] == 2)
    check(w, "av.post_v0", out[2] == 2)
    check(w, "av.post_a0", out[3] == 3)
    check(w, "av.post_w0", out[4] == 2)
  } else if kase == "init_invoke_closure" {
    let v = get_inv_a()
    trace(w, "inv_a", v.to_string())
    check(w, "init.inv_a", v == 42)
  } else if kase == "div_const_then_rt_zero" {
    let z = [0][0]
    trace(w, "before", "ok")
    trace(w, "after", div_const_then_rt(10, z).to_string())
  } else if kase == "div_len_rt_zero" {
    let z = [0][0]
    trace(w, "before", "ok")
    trace(w, "after", div_len_rt([1, 2, 3], z).to_string())
  } else if kase == "div_byte_zero" {
    trace(w, "before", "ok")
    trace(w, "after", div_byte_const0(7.to_byte()).to_int().to_string())
  } else if kase == "div_min_neg1" {
    let m = [-2147483647 - 1][0]
    trace(w, "before", "ok")
    trace(w, "after", div_i32_neg1(m).to_string())
  } else if kase == "init_wrap_invoke_closure" {
    let v = get_wrap_a()
    trace(w, "wrap_a", v.to_string())
    check(w, "init.wrap_a", v == 42)
  } else if kase == "array_slice_to_owned" {
    let xs = [10, 20, 30, 40]
    let sum = slice_owned_first(xs)
    trace(w, "sum", sum.to_string())
    check(w, "slice_owned.sum", sum == 50)
    check(w, "slice_owned.orig", xs[1] == 20)
  } else if kase == "div_min_neg0x1" {
    let m = [-2147483647 - 1][0]
    trace(w, "before", "ok")
    trace(w, "after", div_i32_neg0x1(m).to_string())
  } else if kase == "div_deep_7" {
    let z = [0][0]
    trace(w, "before", "ok")
    trace(w, "after", div_deep_7_fn(12, 1, z).to_string())
  } else if kase == "div_idx_paren" {
    let z = [0][0]
    trace(w, "before", "ok")
    trace(w, "after", div_idx_paren_fn([5], z).to_string())
  } else if kase == "init_iife_helper" {
    let v = get_iife_a()
    trace(w, "iife_a", v.to_string())
    check(w, "init.iife_a", v == 42)
  } else if kase == "utf16_arith_and_idx" {
    let s = "A中😀Bxyz"
    let r1 = str_len_mod3(s)
    let r2 = str_len_div2(s)
    let r3 = str_len_mul3(s)
    let r4 = str_len_mul2_mod3(s)
    let r5 = str_len_div_plus_mod(s, 2)
    let r6 = str_idx_mul2(s, 4)
    let r7 = arr_str_idx_len([s, "中😀"], 1)
    trace(w, "r", r1.to_string() + "," + r2.to_string() + "," + r3.to_string() + "," + r4.to_string() + "," + r5.to_string() + "," + r6.to_string() + "," + r7.to_string())
    check(w, "u16.mod3", r1 == 2)
    check(w, "u16.div2", r2 == 4)
    check(w, "u16.mul3", r3 == 25)
    check(w, "u16.mul2_mod3", r4 == 1)
    check(w, "u16.div_plus_mod", r5 == 6)
    check(w, "u16.idx_mul2", r6 == 132)
    check(w, "u16.arr_idx_len", r7 == 3)
  } else if kase == "div_min_allones_i32" {
    let m = [-2147483647 - 1][0]
    trace(w, "before", "ok")
    trace(w, "after", div_allones_i32(m).to_string())
  } else if kase == "div_min_allones_i64" {
    let m = [-9223372036854775807L - 1L][0]
    trace(w, "before", "ok")
    trace(w, "after", div_allones_i64(m).to_string())
  } else if kase == "utf16_lit_struct_interp" {
    let r1 = str_lit_len_mul2()
    let r2 = str_lit_idx_1()
    let r3 = str_paren_lit_len_mul2()
    let r4 = str_struct_field_len("中A")
    let r5 = str_interp_len(7)
    trace(w, "r", r1.to_string() + "," + r2.to_string() + "," + r3.to_string() + "," + r4.to_string() + "," + r5.to_string())
    check(w, "r5.lit_len", r1 == 4)
    check(w, "r5.lit_idx", r2 == 65)
    check(w, "r5.paren_lit", r3 == 4)
    check(w, "r5.struct_field", r4 == 4)
    check(w, "r5.interp_len", r5 == 2)
  } else if kase == "mbt_compat_chain_len" {
    let a = filter_chain_len([1, 2, 3, 4])
    let b = map_str_chain_len(["A中😀", "xy"])
    let c = slice_owned_str_len("中A😀")
    trace(w, "r", a.to_string() + "," + b.to_string() + "," + c.to_string())
    check(w, "r6.filter_len", a == 3)
    check(w, "r6.map_len", b == 2)
    check(w, "r6.slice_str_len", c == 2)
  } else if kase == "const_upper_idx_and_generic" {
    let a = cap_idx_1()
    let b = cap_in_box()
    let c = match id_arr([10, 20, 30]) {
      Some(v) => v.length()
      None => 0
    }
    trace(w, "r", a.to_string() + "," + b.to_string() + "," + c.to_string())
    check(w, "r6.cap_idx", a == 65)
    check(w, "r6.cap_box", b == 65)
    check(w, "r6.id_arr", c == 3)
  } else if kase == "cross_pkg_cap_noshadow" {
    let a = noshadow_acme_cap_idx()
    let b = noshadow_wrap_roundtrip(42)
    trace(w, "r", a.to_string() + "," + b.to_string())
    check(w, "r7.noshadow_cap", a == 65)
    check(w, "r7.noshadow_wrap", b == 42)
  } else if kase == "cross_pkg_cap_shadow" {
    let a = shadow::shadow_acme_cap_idx()
    let b = shadow::shadow_cap_box()
    let c = shadow::shadow_wrap_roundtrip(42)
    trace(w, "r", a.to_string() + "," + b.to_string() + "," + c.to_string())
    check(w, "r7.shadow_cap", a == 65)
    check(w, "r7.shadow_box", b == 65)
    check(w, "r7.shadow_wrap", c == 42)
  } else if kase == "cross_pkg_no_apimap_box" {
    let a = nomap::box_const_idx()
    let b = nomap::box_lit_idx()
    let c = nomap::holder_roundtrip(99)
    trace(w, "r", a.to_string() + "," + b.to_string() + "," + c.to_string())
    check(w, "r8.box_const_idx", a == 65)
    check(w, "r8.box_lit_idx", b == 65)
    check(w, "r8.holder_wrap", c == 99)
  } else if kase == "m12_val_probes" {
    let (s1, s2) = m12::m12_sval_pair()
    let ch = m12::m12_chained_val()
    let (calls, tv) = m12::m12_compound_single_eval()
    let (nr, is_blue) = m12::m12_nested_rhs_and_color()
    trace(w, "r", s1.to_string() + "," + s2.to_string() + "," + ch.to_string() + "," + calls.to_string() + "," + tv.to_string() + "," + nr.to_string() + "," + is_blue.to_string())
    check(w, "m12.sval_3", s1 == 3)
    check(w, "m12.sval_8", s2 == 8)
    check(w, "m12.chained_val", ch == 15)
    check(w, "m12.compound_calls_1", calls == 1)
    check(w, "m12.compound_val_17", tv == 17)
    check(w, "m12.nested_and_blue", nr == 42 && is_blue)
  } else if kase == "m12_recursive_local_fn" {
    let (r1, r2) = m12::m12_escaping_rec()
    let (sh, ev, od) = m12::m12_sibling_shadow_and_mutual()
    let mut ping = 0
    let co = m12::m12_closure_opt_and_is(Some(fn() { ping = ping + 1 }), fn() { Some(7L) })
    trace(w, "r", r1.to_string() + "," + r2.to_string() + "," + sh.to_string() + "," + ev.to_string() + "," + od.to_string() + "," + co.to_string() + "," + ping.to_string())
    check(w, "m12.esc_14", r1 == 14)
    check(w, "m12.esc_16", r2 == 16)
    check(w, "m12.sibling_shadow", sh == 36)
    check(w, "m12.mutual_rec", ev && od)
    check(w, "m12.closure_opt_is", co == 17 && ping == 1)
  } else if kase == "m12_per_site_enum" {
    let (a, b, c1, c2) = m12::m12_per_site_enum_demo()
    trace(w, "r", a.to_string() + "," + b.to_string() + "," + c1.to_string() + "," + c2.to_string())
    check(w, "m12.local_some_false", !a)
    check(w, "m12.opt_some_true", b)
    check(w, "m12.dual_e1_11", c1 == 11)
    check(w, "m12.dual_e2_21", c2 == 21)
  } else if kase == "m12_pipe_loops_compat" {
    let (p1, p2, p3, tr) = m12::m12_pipe_and_arrow_demo()
    let lm = m12::m12_live_map_update()
    let (ms, sc) = m12::m12_map_and_str_control_flow()
    let (rf, lo, idx, has, dig, built, lex) = m12::m12_compat_helpers_demo()
    trace(w, "r", p1.to_string() + "," + p2.to_string() + "," + p3.to_string() + "," + tr.to_string() + "," + lm.to_string() + "," + ms.to_string() + "," + sc.to_string() + "," + rf.to_string() + "," + lo + "," + idx.to_string() + "," + has.to_string() + "," + dig.to_string() + "," + built + "," + lex.to_string())
    check(w, "m12.pipe_25", p1 == 25)
    check(w, "m12.pipe_ignore_7", p2 == 7)
    check(w, "m12.pipe_order_213", p3 == 213)
    check(w, "m12.pipe_trace_123", tr == 123)
    check(w, "m12.live_map_13", lm == 13)
    check(w, "m12.map_ctrl_4", ms == 4)
    check(w, "m12.str_ctrl_2", sc == 2)
    check(w, "m12.rev_find_3", rf == 3)
    check(w, "m12.arr_search_contains", idx == 1 && has)
    check(w, "m12.char_and_from_arr", dig && lo == "hello world" && built == "A😀B" && lex)
  } else if kase == "q2_semantics_p0" {
    let (a1, a2, a3) = m12::q2_anon_struct_and_boxval()
    let (t1, t2, t3, t4, t5) = m12::q2_type_ascriptions()
    let p1 = m12::q2_ctor_struct_pat(m12::TreeRec::Leaf(m12::NodeRec::{ ok: true, tag: 1, x: Some(3), y: Some(4) }))
    let p2 = m12::q2_ctor_struct_pat(m12::TreeRec::Leaf(m12::NodeRec::{ ok: true, tag: 1, x: Some(-2), y: Some(4) }))
    let p3 = m12::q2_ctor_struct_pat(m12::TreeRec::Leaf(m12::NodeRec::{ ok: false, tag: 7, x: Some(3), y: Some(4) }))
    let p4 = m12::q2_ctor_struct_pat(m12::TreeRec::Leaf(m12::NodeRec::{ ok: false, tag: 1, x: None, y: None }))
    let (l1, l2) = m12::q2_local_fn_order_and_shadow()
    let (pp1, pp2) = m12::q2_pipe_collision_and_named()
    let (sd1, sd2, sd3) = m12::q2_sameline_div_cascade_and_brace(-7, 2, 7.0, 2.0, -23)
    let (sf1, cl1, sp1) = m12::q2_shadowed_fail_and_crossline_paren()
    trace(w, "r", a1.to_string() + "," + a2.to_string() + "," + a3.to_string() + "," + t1.to_string() + "," + mbt_compat::double_to_string(t2) + "," + t3.to_string() + "," + mbt_compat::double_to_string(t4) + "," + t5.to_string() + "," + p1.to_string() + "," + p2.to_string() + "," + p3.to_string() + "," + p4.to_string() + "," + l1.to_string() + "," + l2.to_string() + "," + pp1.to_string() + "," + pp2.to_string() + "," + sd1.to_string() + "," + sd2 + "," + sd3.to_string() + "," + sf1 + "," + cl1 + "," + sp1.to_string())
    check(w, "q2.anon_struct", a1 == 13 && a2 == 25)
    check(w, "q2.boxval_3", a3 == 3)
    check(w, "q2.ascribe_i64_dbl", t1 == 3000000000L && t2 == 3.5 && t3 == -3L && t4 == 1.5 && t5)
    check(w, "q2.ctor_pat_dual", p1 == 34)
    check(w, "q2.ctor_pat_fallthrough", p2 == 98)
    check(w, "q2.ctor_pat_guard_and_tag", p3 == 700 && p4 == 111)
    check(w, "q2.local_fn_order", l1 == 1015)
    check(w, "q2.local_fn_shadow", l2 == 17)
    check(w, "q2.pipe_collision_named", pp1 == 25 && pp2 == 17)
    check(w, "q2.sameline_div_cascade_brace", sd1 == 0 && sd2 == "-3" && sd3 == 2)
    check(w, "q2.shadowed_fail", sf1 == "ok:x")
    check(w, "q2.crossline_paren_recv", cl1 == "3.5")
    check(w, "q2.str_lit_probe_32", sp1 == 32)
  } else if kase == "q2_mechanical_compat" {
    let (nt1, nt2) = m12::q2_trailing_tuple_newline(9)
    let tf1 = m12::q2_tuple_opt_fn(Some((3.0, fn(v) { v * 2.0 })))
    let tf2 = m12::q2_tuple_opt_fn(None)
    let fm0 = m12::q2_fixed_arr_match([])
    let fm1 = m12::q2_fixed_arr_match([7])
    let fm2 = m12::q2_fixed_arr_match([5, 9])
    let fm3 = m12::q2_fixed_arr_match([1, 2, 3])
    let (mv, nan_ok, ln, g, mid_s, emp) = m12::q2_double_and_collections()
    trace(w, "r", nt1.to_string() + "," + nt2.to_string() + "," + mbt_compat::double_to_string(tf1) + "," + mbt_compat::double_to_string(tf2) + "," + fm0.to_string() + "," + fm1.to_string() + "," + fm2.to_string() + "," + fm3.to_string() + "," + mv.to_string() + "," + nan_ok.to_string() + "," + ln.to_string() + "," + g.to_string() + "," + mid_s.to_string() + "," + emp.to_string())
    check(w, "q2.trailing_tuple", nt1 == 10 && nt2 == 20)
    check(w, "q2.tuple_opt_fn", tf1 == 6.0 && tf2 == 0.0)
    check(w, "q2.arr_pat_0", fm0 == 0)
    check(w, "q2.arr_pat_1", fm1 == 70)
    check(w, "q2.arr_pat_2_3", fm2 == 105 && fm3 == -1)
    check(w, "q2.dbl_zero_hash", mv == 22)
    check(w, "q2.dbl_nan_cmp", nan_ok)
    check(w, "q2.int_lnot", ln == -1)
    check(w, "q2.unsafe_get_set", g == 25)
    check(w, "q2.self_arr_slice_trunc", mid_s == 55 && emp == 2)
  } else {
    panic("abort: unknown case " + kase)
  }
  0
}
'''


def find_tool(name, extra_dirs):
    p = shutil.which(name)
    if p:
        return p
    for d in extra_dirs:
        cand = os.path.join(os.path.expanduser(d), name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def run_cmd(cmd, cwd=None, env=None):
    t0 = time.time()
    try:
        p = subprocess.run(
            cmd,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=TIMEOUT_S,
        )
        return (
            p.returncode,
            p.stdout.decode("utf-8", "replace"),
            p.stderr.decode("utf-8", "replace"),
            False,
            time.time() - t0,
        )
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "replace")
        err = (e.stderr or b"").decode("utf-8", "replace")
        return (None, out, err, True, time.time() - t0)


def classify(engine, rc, out, err, timed_out):
    if timed_out:
        return "HARD:timeout"
    if rc == 0:
        return "ok"
    if engine == "moon":
        m = re.search(r"RuntimeError: ([^\n]+)", err + "\n" + out)
        if rc == 1 and m:
            msg = m.group(1).strip()
            kind = MOON_TRAPS.get(msg)
            if kind is None:
                return "HARD:unknown-moon-trap(%s)" % msg
            return "panic:" + kind
        return "HARD:moon-exit-%s" % rc
    m = re.search(r"pion panic at [^\n]*?:\d+: ([^\n]*)", err)
    native_panic_rc = rc in (134, -6)
    wasm_panic_rc = rc == 1
    if m and ((engine == "pion-native" and native_panic_rc) or
              (engine == "pion-wasm32" and wasm_panic_rc)):
        msg = m.group(1)
        for prefix, kind in PION_PANICS:
            if msg.startswith(prefix):
                return "panic:" + kind
        return "HARD:unclassified-pion-panic(%s)" % msg
    if engine == "pion-wasm32" and "RuntimeError:" in err:
        t = re.search(r"RuntimeError: ([^\n]+)", err).group(1).strip()
        return "HARD:raw-wasm-trap(%s)" % t
    if rc in (139, -11):
        return "HARD:SIGSEGV"
    if rc in (136, -8):
        return "HARD:SIGFPE"
    if rc is not None and rc < 0:
        return "HARD:signal-%d" % (-rc)
    return "HARD:exit-%s" % rc


def parse_lines(out):
    traces, asserts, junk = [], [], []
    for line in out.splitlines():
        if line.startswith("T "):
            traces.append(line[2:])
        elif line.startswith("A "):
            asserts.append(line[2:])
        elif line.strip():
            junk.append(line)
    return traces, asserts, junk


def evaluate(case, results):
    errors = []
    expect, n_asserts = CASES[case]
    parsed = {}
    for eng in ENGINES:
        rc, out, err, to = results[eng]
        cls = classify(eng, rc, out, err, to)
        traces, asserts, junk = parse_lines(out)
        parsed[eng] = (cls, traces, asserts)
        if cls.startswith("HARD:"):
            errors.append("%s: hard fail %s (rc=%s) stderr=%s" %
                          (eng, cls[5:], rc, err.strip()[-300:]))
        if not traces and not asserts:
            errors.append("%s: executed nothing (0 traces, 0 assertions)" % eng)
        if junk:
            errors.append("%s: unexpected output %r" % (eng, junk[:3]))
    for eng in ENGINES:
        if parsed[eng][0] != expect:
            errors.append("%s: outcome %s, expected %s" % (eng, parsed[eng][0], expect))
    ref_t, ref_a = parsed["moon"][1], parsed["moon"][2]
    for eng in ENGINES[1:]:
        t, a = parsed[eng][1], parsed[eng][2]
        if t != ref_t:
            diff = next((i for i in range(min(len(t), len(ref_t))) if t[i] != ref_t[i]),
                        min(len(t), len(ref_t)))
            errors.append("%s: trace differs from moon at line %d: moon=%r %s=%r" % (
                eng, diff,
                ref_t[diff] if diff < len(ref_t) else "<end>", eng,
                t[diff] if diff < len(t) else "<end>"))
        if a != ref_a:
            errors.append("%s: assertion ids differ: moon=%s %s=%s" % (eng, ref_a, eng, a))
    for eng in ENGINES:
        if len(parsed[eng][2]) != n_asserts:
            errors.append("%s: %d assertions executed, expected %d" %
                          (eng, len(parsed[eng][2]), n_asserts))
    return errors, parsed


def write_file(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


class Env:
    def __init__(self, moon, pionc, workdir):
        self.moon = moon
        self.pionc = pionc
        self.workdir = workdir
        self.mbt2pion_bin = os.path.join(workdir, "mbt2pion")
        self.mbt_src_dir = os.path.join(workdir, "shared_mbt_src")
        self.moon_dir = os.path.join(workdir, "moon_pkg")
        self.pion_dir = os.path.join(workdir, "pion_pkg")


def prepare(env):
    # 1. Write shared MoonBit sources (main oracle_lib + cross-package acme + shadow pkg with local `struct CAP`)
    write_file(os.path.join(env.mbt_src_dir, "oracle_lib.mbt"), ORACLE_LIB_MBT)
    shadow_mbt_dir = os.path.join(env.workdir, "shadow_mbt_src")
    write_file(os.path.join(shadow_mbt_dir, "shadow_lib.mbt"), SHADOW_LIB_MBT)
    api_map_path = os.path.join(env.workdir, "acme_api_map.json")
    write_file(api_map_path, ACME_API_MAP_JSON)

    # 1b. Write real Pion `acme` and `ext` dependency packages
    pion_acme_dir = os.path.join(env.workdir, "pion_acme")
    write_file(
        os.path.join(pion_acme_dir, "pion.toml"),
        '[package]\nname = "acme"\nversion = "0.1.0"\n',
    )
    write_file(os.path.join(pion_acme_dir, "src", "lib.pion"), ACME_PION_SRC)

    pion_ext_dir = os.path.join(env.workdir, "pion_ext")
    write_file(
        os.path.join(pion_ext_dir, "pion.toml"),
        '[package]\nname = "ext"\nversion = "0.1.0"\n',
    )
    write_file(os.path.join(pion_ext_dir, "src", "lib.pion"), ACME_PION_SRC)

    nomap_mbt_dir = os.path.join(env.workdir, "nomap_mbt_src")
    write_file(os.path.join(nomap_mbt_dir, "nomap_lib.mbt"), NO_APIMAP_LIB_MBT)

    m12_mbt_dir = os.path.join(env.workdir, "m12_mbt_src")
    write_file(os.path.join(m12_mbt_dir, "m12_lib.mbt"), M12_LIB_MBT)
    m12_recipes_path = os.path.join(env.workdir, "m12_recipes.toml")
    write_file(m12_recipes_path, M12_RECIPES_TOML)

    # 2. Build MoonBit packages (`acme`, `ext`, `shadow`, `nomap`, `main`) around the exact same `.mbt` files
    write_file(
        os.path.join(env.moon_dir, "moon.mod"),
        'name = "oracle/transpile"\n',
    )
    write_file(os.path.join(env.moon_dir, "acme", "moon.pkg"), "\n")
    write_file(os.path.join(env.moon_dir, "acme", "lib.mbt"), ACME_MOON_MBT)
    write_file(os.path.join(env.moon_dir, "ext", "moon.pkg"), "\n")
    write_file(os.path.join(env.moon_dir, "ext", "lib.mbt"), ACME_MOON_MBT)
    write_file(
        os.path.join(env.moon_dir, "shadow", "moon.pkg"),
        'import {\n  "oracle/transpile/acme",\n}\n',
    )
    shutil.copyfile(
        os.path.join(shadow_mbt_dir, "shadow_lib.mbt"),
        os.path.join(env.moon_dir, "shadow", "shadow_lib.mbt"),
    )
    write_file(
        os.path.join(env.moon_dir, "nomap", "moon.pkg"),
        'import {\n  "oracle/transpile/ext",\n}\n',
    )
    shutil.copyfile(
        os.path.join(nomap_mbt_dir, "nomap_lib.mbt"),
        os.path.join(env.moon_dir, "nomap", "nomap_lib.mbt"),
    )
    write_file(os.path.join(env.moon_dir, "m12", "moon.pkg"), "\n")
    shutil.copyfile(
        os.path.join(m12_mbt_dir, "m12_lib.mbt"),
        os.path.join(env.moon_dir, "m12", "m12_lib.mbt"),
    )
    write_file(
        os.path.join(env.moon_dir, "main", "moon.pkg"),
        'import {\n  "moonbitlang/core/env",\n  "oracle/transpile/acme",\n  "oracle/transpile/shadow",\n  "oracle/transpile/nomap",\n  "oracle/transpile/m12",\n}\n\npkgtype(kind: "executable")\n',
    )
    shutil.copyfile(
        os.path.join(env.mbt_src_dir, "oracle_lib.mbt"),
        os.path.join(env.moon_dir, "main", "oracle_lib.mbt"),
    )
    write_file(os.path.join(env.moon_dir, "main", "driver.mbt"), MOON_DRIVER_MBT)

    # 3. Build `mbt2pion` CLI
    rc, out, err, to, secs = run_cmd([env.pionc, "build", CLI_DIR, "-o", env.mbt2pion_bin])
    if rc != 0:
        print("SETUP FAILED: build mbt2pion (rc=%s)\n%s\n%s" % (rc, out[-2000:], err[-2000:]))
        return False
    print("setup ok   %-44s %.1fs" % ("pionc build tools/mbt2pion_cli", secs))

    # 4. Run `mbt2pion --mode publish` on `oracle_lib.mbt` and `shadow_lib.mbt` with real `tools/mbt_compat` + `acme`
    pion_shadow_dir = os.path.join(env.workdir, "pion_shadow")
    pion_shadow_src = os.path.join(pion_shadow_dir, "src")
    os.makedirs(pion_shadow_src, exist_ok=True)
    rc, out, err, to, secs = run_cmd([
        env.mbt2pion_bin,
        "--src", shadow_mbt_dir,
        "--out", pion_shadow_src,
        "--target", "native",
        "--mode", "publish",
        "--api-map", api_map_path,
        "--dep", "acme=" + pion_acme_dir,
        "--mbt-compat", COMPAT_DIR,
        "--pionc", env.pionc,
        "--mbt2pion-commit", "oracle-test",
        "--toolchain-lock", "oracle-lock",
        "--source-commit", "oracle-src",
    ])
    if rc != 0:
        print("SETUP FAILED: mbt2pion --mode publish shadow_lib.mbt (rc=%s)\n%s\n%s" % (rc, out[-2000:], err[-2000:]))
        return False
    write_file(
        os.path.join(pion_shadow_dir, "pion.toml"),
        '[package]\nname = "shadow"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = { path = "%s" }\nacme = { path = "%s" }\n' % (COMPAT_DIR, pion_acme_dir),
    )

    # Transpile `nomap_lib.mbt` WITHOUT `--api-map` (Round 8 Astra P0-1 regression)
    pion_nomap_dir = os.path.join(env.workdir, "pion_nomap")
    pion_nomap_src = os.path.join(pion_nomap_dir, "src")
    os.makedirs(pion_nomap_src, exist_ok=True)
    rc, out, err, to, secs = run_cmd([
        env.mbt2pion_bin,
        "--src", nomap_mbt_dir,
        "--out", pion_nomap_src,
        "--target", "native",
        "--mode", "publish",
        "--dep", "ext=" + pion_ext_dir,
        "--mbt-compat", COMPAT_DIR,
        "--pionc", env.pionc,
        "--mbt2pion-commit", "oracle-test",
        "--toolchain-lock", "oracle-lock",
        "--source-commit", "oracle-src",
    ])
    if rc != 0:
        print("SETUP FAILED: mbt2pion --mode publish nomap_lib.mbt (rc=%s)\n%s\n%s" % (rc, out[-2000:], err[-2000:]))
        return False
    write_file(
        os.path.join(pion_nomap_dir, "pion.toml"),
        '[package]\nname = "nomap"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = { path = "%s" }\next = { path = "%s" }\n' % (COMPAT_DIR, pion_ext_dir),
    )

    # Transpile `m12_lib.mbt` (Wave M1.2 Track A A.1-A.6 differential oracle)
    pion_m12_dir = os.path.join(env.workdir, "pion_m12")
    pion_m12_src = os.path.join(pion_m12_dir, "src")
    os.makedirs(pion_m12_src, exist_ok=True)
    rc, out, err, to, secs = run_cmd([
        env.mbt2pion_bin,
        "--src", m12_mbt_dir,
        "--out", pion_m12_src,
        "--target", "native",
        "--mode", "publish",
        "--recipes", m12_recipes_path,
        "--mbt-compat", COMPAT_DIR,
        "--pionc", env.pionc,
        "--mbt2pion-commit", "oracle-test",
        "--toolchain-lock", "oracle-lock",
        "--source-commit", "oracle-src",
    ])
    if rc != 0:
        print("SETUP FAILED: mbt2pion --mode publish m12_lib.mbt (rc=%s)\n%s\n%s" % (rc, out[-2000:], err[-2000:]))
        return False
    write_file(
        os.path.join(pion_m12_dir, "pion.toml"),
        '[package]\nname = "m12"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = { path = "%s" }\n' % (COMPAT_DIR,),
    )

    pion_src = os.path.join(env.pion_dir, "src")
    os.makedirs(pion_src, exist_ok=True)
    rc, out, err, to, secs = run_cmd([
        env.mbt2pion_bin,
        "--src", env.mbt_src_dir,
        "--out", pion_src,
        "--target", "native",
        "--mode", "publish",
        "--api-map", api_map_path,
        "--dep", "acme=" + pion_acme_dir,
        "--mbt-compat", COMPAT_DIR,
        "--pionc", env.pionc,
        "--mbt2pion-commit", "oracle-test",
        "--toolchain-lock", "oracle-lock",
        "--source-commit", "oracle-src",
        "--report", os.path.join(env.workdir, "migration_report.json"),
        "--drift-ledger", os.path.join(env.workdir, "drift_ledger.json"),
    ])
    if rc != 0:
        print("SETUP FAILED: mbt2pion --mode publish (rc=%s)\n%s\n%s" % (rc, out[-2000:], err[-2000:]))
        return False
    print("setup ok   %-44s %.1fs" % ("mbt2pion --mode publish oracle_lib.mbt", secs))

    # 5. Wire generated `.pion` files with real `tools/mbt_compat` + `acme` + `shadow` + `nomap` + thin driver
    write_file(
        os.path.join(env.pion_dir, "pion.toml"),
        '[package]\nname = "mbt2pion_transpile_oracle"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = { path = "%s" }\nacme = { path = "%s" }\nshadow = { path = "%s" }\nnomap = { path = "%s" }\nm12 = { path = "%s" }\n' % (COMPAT_DIR, pion_acme_dir, pion_shadow_dir, pion_nomap_dir, pion_m12_dir),
    )
    write_file(os.path.join(pion_src, "main.pion"), PION_DRIVER_PION)

    # 6. Pre-build MoonBit wasm-gc, Pion native, and Pion wasm32
    steps = [
        ([env.moon, "build", "--target", "wasm-gc"], env.moon_dir, "moon build --target wasm-gc"),
        ([env.pionc, "check", "--json", env.pion_dir], None, "pionc check transpiled pkg"),
        ([env.pionc, "build", env.pion_dir, "-o", os.path.join(env.workdir, "oracle_native")], None,
         "pionc build transpiled native"),
        ([env.pionc, "build", "--target", "wasm32", env.pion_dir, "-o",
          os.path.join(env.workdir, "oracle.wasm")], None, "pionc build transpiled wasm32"),
    ]
    for cmd, cwd, label in steps:
        rc, out, err, to, secs = run_cmd(cmd, cwd=cwd)
        if rc != 0:
            print("SETUP FAILED: %s (rc=%s)\n%s\n%s" % (label, rc, out[-2000:], err[-2000:]))
            return False
        print("setup ok   %-44s %.1fs" % (label, secs))
    return True


def run_moon(env, case):
    rc, out, err, to, _ = run_cmd([env.moon, "run", "--target", "wasm-gc", "main", "--", case],
                                  cwd=env.moon_dir)
    return (rc, out, err, to)


def run_pion(env, pkg_dir, target, case):
    cmd = [env.pionc, "run"]
    if target == "wasm32":
        cmd += ["--target", "wasm32"]
    cmd += [pkg_dir, "--", case]
    rc, out, err, to, _ = run_cmd(cmd)
    return (rc, out, err, to)


def run_suite(env, cases, jobs):
    results = {c: {} for c in cases}
    for target in ("native", "wasm32"):
        run_pion(env, env.pion_dir, target, cases[0])
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {}
        for c in cases:
            futs[ex.submit(run_pion, env, env.pion_dir, "native", c)] = (c, "pion-native")
            futs[ex.submit(run_pion, env, env.pion_dir, "wasm32", c)] = (c, "pion-wasm32")
        for c in cases:
            results[c]["moon"] = run_moon(env, c)
        for f in concurrent.futures.as_completed(futs):
            c, eng = futs[f]
            results[c][eng] = f.result()
    return results


# Negative self-tests: dual-set validation (Opus P2-R1 + Astra P2):
# Every observed error class must be in `allowed_classes` (rejecting unrelated infra errors like
# MODULE_NOT_FOUND or empty runs!), AND all `required_classes` must be observed!
MUTANTS = [
    ("drop-assertion", "guard", "main.pion",
     'check(w, "guard.val_false", g1 == 17)\n', "",
     {"assertion_id_mismatch", "assertion_count_mismatch"},
     {"assertion_id_mismatch", "assertion_count_mismatch"}),
    ("bypass-utf16-len", "utf16", "oracle_lib.pion",
     "mbt_compat::utf16_len(s)", "s.length()",
     {"unexpected_output", "trace_mismatch"},
     {"unexpected_output", "outcome_mismatch", "trace_mismatch", "assertion_id_mismatch", "assertion_count_mismatch"}),
    ("bypass-div-checked", "div_i32_rt_zero", "oracle_lib.pion",
     "mbt_compat::div_checked_i32(a, b)", "(a / b)",
     {"hard_fail:raw-wasm-trap", "outcome_mismatch"},
     {"hard_fail:raw-wasm-trap", "hard_fail:SIGFPE", "outcome_mismatch", "trace_mismatch"}),
    ("bypass-double-fmt", "double_fmt", "oracle_lib.pion",
     "mbt_compat::double_to_string(d)", "d.to_string()",
     {"unexpected_output", "trace_mismatch"},
     {"unexpected_output", "outcome_mismatch", "trace_mismatch", "assertion_id_mismatch", "assertion_count_mismatch"}),
]


def error_classes(errs):
    classes = set()
    for e in errs:
        if "MODULE_NOT_FOUND" in e:
            classes.add("infra:module_not_found")
        elif "hard fail raw-wasm-trap" in e:
            classes.add("hard_fail:raw-wasm-trap")
        elif "hard fail SIGFPE" in e:
            classes.add("hard_fail:SIGFPE")
        elif "hard fail " in e:
            classes.add("hard_fail:other")
        elif "executed nothing" in e:
            classes.add("empty_run")
        elif "unexpected output" in e:
            classes.add("unexpected_output")
        elif "outcome " in e:
            classes.add("outcome_mismatch")
        elif "trace differs" in e:
            classes.add("trace_mismatch")
        elif "assertion ids differ" in e:
            classes.add("assertion_id_mismatch")
        elif "assertions executed, expected" in e:
            classes.add("assertion_count_mismatch")
        else:
            classes.add("unknown")
    return classes


def mutant_detected(errs, required_classes, allowed_classes):
    got = error_classes(errs)
    if not got:
        return False, got
    if not got.issubset(allowed_classes):
        return False, got
    if not required_classes.issubset(got):
        return False, got
    return True, got


def make_mutant(env, name, rel_file, old, new):
    d = os.path.join(env.workdir, "mutant_" + name)
    shutil.copytree(env.pion_dir, d)
    p = os.path.join(d, "src", rel_file)
    with open(p, encoding="utf-8") as f:
        s = f.read()
    if s.count(old) < 1:
        raise RuntimeError("mutant %s: anchor %r not found in %s" % (name, old, rel_file))
    with open(p, "w", encoding="utf-8") as f:
        f.write(s.replace(old, new, 1))
    return d


def classifier_selftest():
    problems = []
    probes = [
        ("pion-native", 139, "", "", False, "HARD:SIGSEGV"),
        ("pion-native", 136, "", "", False, "HARD:SIGFPE"),
        ("pion-native", -8, "", "", False, "HARD:SIGFPE"),
        ("pion-native", None, "", "", True, "HARD:timeout"),
        ("pion-wasm32", 1, "", "RuntimeError: divide by zero\n", False,
         "HARD:raw-wasm-trap(divide by zero)"),
        ("pion-native", 134, "", "pion panic at ./x.pion:3: divide by zero\n", False,
         "panic:div_zero"),
        ("moon", 1, "", "RuntimeError: remainder by zero\n", False, "panic:rem_zero"),
    ]
    for eng, rc, out, err, to, want in probes:
        got = classify(eng, rc, out, err, to)
        if got != want:
            problems.append("classify(%s, rc=%s) = %s, want %s" % (eng, rc, got, want))
    empty = {e: (0, "", "", False) for e in ENGINES}
    errs, _ = evaluate("guard", empty)
    if not any("executed nothing" in e for e in errs):
        problems.append("empty run was not rejected")
    # Opus P2-R1 + Astra P2: MODULE_NOT_FOUND + empty output must NEVER count as a mutant detection!
    infra_res = {
        "moon": (0, "T val_false=17\nA guard.val_false\n", "", False),
        "pion-native": (1, "", "Error: MODULE_NOT_FOUND\n", False),
        "pion-wasm32": (1, "", "Error: MODULE_NOT_FOUND\n", False),
    }
    infra_errs, _ = evaluate("guard", infra_res)
    det, _ = mutant_detected(infra_errs, {"assertion_id_mismatch"}, {"assertion_id_mismatch", "assertion_count_mismatch"})
    if det:
        problems.append("MODULE_NOT_FOUND infra error was falsely counted as mutant detection")
    # Astra Round 3 P1-3: `hard_fail:other` (e.g. SIGSEGV) must still be rejected by `bypass-div-checked`!
    segv_res = {
        "moon": (1, "T start=1\n", "RuntimeError: divide by zero\n", False),
        "pion-native": (139, "T start=1\n", "", False),
        "pion-wasm32": (1, "T start=1\n", "RuntimeError: divide by zero\n", False),
    }
    segv_errs, _ = evaluate("div_i32_rt_zero", segv_res)
    det_segv, _ = mutant_detected(
        segv_errs,
        {"hard_fail:raw-wasm-trap", "outcome_mismatch"},
        {"hard_fail:raw-wasm-trap", "hard_fail:SIGFPE", "outcome_mismatch", "trace_mismatch"},
    )
    if det_segv:
        problems.append("SIGSEGV (hard_fail:other) was falsely accepted by bypass-div-checked")
    return problems


def self_test(env, moon_results):
    print("\n== negative self-test (every mutant must turn oracle RED with exact failure class)")
    ok = True
    for p in classifier_selftest():
        print("SELFTEST FAIL  classifier: " + p)
        ok = False
    if ok:
        print("selftest ok    classifier hard-fails SIGSEGV/timeout/raw-wasm-trap/empty-run and rejects MODULE_NOT_FOUND as detection")
    for name, case, rel_file, old, new, req_cls, allow_cls in MUTANTS:
        d = make_mutant(env, name, rel_file, old, new)
        res = {
            "moon": moon_results[case],
            "pion-native": run_pion(env, d, "native", case),
            "pion-wasm32": run_pion(env, d, "wasm32", case),
        }
        errs, _ = evaluate(case, res)
        detected, got_cls = mutant_detected(errs, req_cls, allow_cls)
        if detected:
            print("selftest ok    mutant %-20s on %-18s -> red %s" % (name, case, sorted(got_cls)))
        else:
            print("SELFTEST FAIL  mutant %-20s on %-18s got=%s req=%s allow=%s err=%s" % (
                name, case, sorted(got_cls), sorted(req_cls), sorted(allow_cls), errs[:2]))
            ok = False
    return ok


def emit_ci_golden(pionc, out_dir):
    """Single source of truth for CI cross-host golden generation (Astra Round 8 P0-2)."""
    import hashlib
    workdir = tempfile.mkdtemp(prefix="mbt2pion_ci_golden_")
    try:
        mbt_src_dir = os.path.join(workdir, "src")
        write_file(os.path.join(mbt_src_dir, "oracle_lib.mbt"), ORACLE_LIB_MBT)
        pion_acme_dir = os.path.join(workdir, "pion_acme")
        write_file(
            os.path.join(pion_acme_dir, "pion.toml"),
            '[package]\nname = "acme"\nversion = "0.1.0"\n',
        )
        write_file(os.path.join(pion_acme_dir, "src", "lib.pion"), ACME_PION_SRC)
        api_map_path = os.path.join(workdir, "acme_api_map.json")
        write_file(api_map_path, ACME_API_MAP_JSON)
        cli_bin = os.path.join(workdir, "mbt2pion")
        rc, out, err, to, secs = run_cmd([pionc, "build", CLI_DIR, "-o", cli_bin])
        if rc != 0:
            print("CI GOLDEN FAILED: build mbt2pion (rc=%s)\n%s\n%s" % (rc, out[-2000:], err[-2000:]))
            return 1
        os.makedirs(out_dir, exist_ok=True)
        rc, out, err, to, secs = run_cmd([
            cli_bin,
            "--src", mbt_src_dir,
            "--out", out_dir,
            "--target", "native",
            "--mode", "publish",
            "--api-map", api_map_path,
            "--dep", "acme=" + pion_acme_dir,
            "--mbt-compat", COMPAT_DIR,
            "--pionc", pionc,
            "--mbt2pion-commit", "ci-parity",
            "--toolchain-lock", "ci-lock",
            "--source-commit", "ci-src",
        ])
        if rc != 0:
            print("CI GOLDEN FAILED: mbt2pion publish (rc=%s)\n%s\n%s" % (rc, out[-2000:], err[-2000:]))
            return 1
        got_files = sorted(os.listdir(out_dir))
        expected_files = ["00_init_order.pion", "oracle_lib.pion"]
        if got_files != expected_files:
            print("CI GOLDEN FAILED: expected files %s, got %s" % (expected_files, got_files))
            return 1
        for fname in expected_files:
            fpath = os.path.join(out_dir, fname)
            data = open(fpath, "rb").read()
            if len(data) == 0:
                print("CI GOLDEN FAILED: empty output file %s" % fname)
                return 1
            print("ci-golden ok  %-22s sha256=%s (%d bytes)" % (
                fname, hashlib.sha256(data).hexdigest(), len(data)))
        return 0
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-self-test", action="store_true")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--pionc", default="")
    ap.add_argument("--report", default="")
    ap.add_argument("--case", action="append", default=[])
    ap.add_argument("--emit-ci-golden", default="")
    args = ap.parse_args()

    pionc = args.pionc or os.environ.get("PIONC", "") or find_tool("pionc", ["~/.pion/bin"])
    if args.emit_ci_golden:
        if not pionc:
            print("missing tool: pionc=%s" % (pionc,))
            return 2
        return emit_ci_golden(pionc, args.emit_ci_golden)

    moon = find_tool("moon", ["~/.moon/bin"])
    node = shutil.which("node")
    if not moon or not pionc or not node:
        print("missing tool: moon=%s pionc=%s node=%s" % (moon, pionc, node))
        return 2
    for c in args.case:
        if c not in CASES:
            print("unknown case " + c)
            return 2
    cases = args.case or sorted(CASES)
    workdir = tempfile.mkdtemp(prefix="mbt2pion_transpile_oracle_")
    env = Env(moon, pionc, workdir)
    try:
        if not prepare(env):
            return 1
        t0 = time.time()
        results = run_suite(env, cases, args.jobs)
        print("\n== transpile differential oracle: %d cases x %d engines (%.1fs)" %
              (len(cases), len(ENGINES), time.time() - t0))
        failed = 0
        total_asserts = 0
        total_traces = 0
        report = []
        for c in cases:
            errs, parsed = evaluate(c, results[c])
            cls = parsed["moon"][0]
            n_t = len(parsed["moon"][1])
            n_a = len(parsed["moon"][2])
            total_traces += n_t
            total_asserts += n_a
            status = "PASS" if not errs else "FAIL"
            print("%s %-22s outcome=%-16s traces=%-3d asserts=%-2d (moon=pion-native=pion-wasm32)"
                  % (status, c, cls, n_t, n_a) if not errs else "%s %s" % (status, c))
            for e in errs:
                print("     " + e)
            if errs:
                failed += 1
            report.append({
                "case": c,
                "ok": not errs,
                "outcome": {e: parsed[e][0] for e in ENGINES},
                "traces": n_t,
                "asserts": parsed["moon"][2],
                "errors": errs,
            })
        if total_asserts == 0:
            print("HARD FAIL: 0 assertions executed")
            failed += 1
        print("\nsummary: %d/%d cases identical on moon wasm-gc, pion native, pion wasm32; "
              "%d trace lines and %d assertions per engine" %
              (len(cases) - failed, len(cases), total_traces, total_asserts))
        ok = failed == 0
        if not args.no_self_test:
            moon_results = {c: results[c]["moon"] for c in cases}
            for m in MUTANTS:
                if m[1] not in moon_results:
                    moon_results[m[1]] = run_moon(env, m[1])
            ok = self_test(env, moon_results) and ok
        if args.report:
            with open(args.report, "w", encoding="utf-8") as f:
                json.dump({"ok": ok, "cases": report}, f, indent=1)
        print("\nTRANSPILE ORACLE " + ("GREEN" if ok else "RED"))
        return 0 if ok else 1
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
