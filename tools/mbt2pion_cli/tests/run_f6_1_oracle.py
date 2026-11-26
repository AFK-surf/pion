#!/usr/bin/env python3
r"""4-Target Differential Oracle for checked-error lowering (`suberror`/`raise`/`try`/`catch`/`catch!`/`noraise`/`try?`/`try!`),
cross-package `pub fn ... raise E` ABI export, canonical package alias identity, and cross-package `pub let`/`pub const` struct update:
MoonBit native == MoonBit wasm-gc == Pion native == Pion wasm32, plus fail-closed negative blocking checks.
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

UP_MBT = r'''
pub suberror ApiErr {
  BadCode(Int)
  BadMsg(String)
}

pub(all) struct Cfg {
  x : Int
  y : Int
}

pub let default_cfg : Cfg = { x: 1, y: 2 }

pub const BASE_STEP : Int = 5

pub fn parse_code(s : String) -> Int raise ApiErr {
  if s == "" {
    raise BadMsg("empty")
  }
  if s == "neg" {
    raise BadCode(-7)
  }
  s.length() * 10
}
'''

CUSTOM_JSON_MBT = r'''
pub fn parse(s : String) -> Int {
  s.length() * 100 + 3
}
'''

UP2_MBT = r'''
pub suberror UErr {
  BadU(Int)
  OtherU
}

pub(all) suberror PubErr {
  PubBad
}

pub fn fail_u(x : Int) -> Int raise UErr {
  if x < 0 {
    raise BadU(x * 3)
  }
  x + 1
}
'''

DOWN_MBT = r'''
priv suberror LocalErr {
  Empty
  Code(Int)
}

fn check_local(x : Int) -> Int raise LocalErr {
  if x == 0 {
    raise Empty
  }
  if x < 0 {
    raise Code(x * -1)
  }
  x + 1
}

fn rethrow_explicit(x : Int) -> Int raise LocalErr {
  check_local(x) catch {
    Empty => 50
    e => raise e
  }
}

fn rethrow_catch_bang(x : Int) -> Int raise LocalErr {
  check_local(x) catch! {
    Empty => 60
  }
}

pub fn case_cross_pkg() -> String {
  let a = try @up.parse_code("abc") catch {
    @up.ApiErr::BadCode(c) => c
    @up.ApiErr::BadMsg(_) => -99
  } noraise {
    v => v + 1
  }
  let b = @up.parse_code("neg") catch {
    @up.ApiErr::BadCode(c) => c * 2
    @up.ApiErr::BadMsg(_) => -99
  }
  let c = @up.parse_code("") catch {
    @up.ApiErr::BadCode(c) => c
    @up.ApiErr::BadMsg(m) => m.length()
  }
  // Custom dependency aliased as `@json` vs renamed standard `@j` (`moonbitlang/core/json`)
  let custom_v = @json.parse("hi")
  let std_ok = try {
    let _ = @j.parse("{\"k\":1}")
    1
  } catch {
    _ => 0
  }
  let std_bad = try {
    let _ = @j.parse("{bad")
    1
  } catch {
    _ => 0
  }
  a.to_string() + "," + b.to_string() + "," + c.to_string() + "," + custom_v.to_string() + "," + std_ok.to_string() + "," + std_bad.to_string()
}

pub fn case_rethrow_and_nested() -> String {
  let r1 = rethrow_explicit(0) catch {
    Empty => -1
    Code(n) => n
  }
  let r2 = rethrow_explicit(-4) catch {
    Empty => -1
    Code(n) => n * 10
  }
  let r3 = rethrow_catch_bang(0) catch {
    Empty => -1
    Code(n) => n
  }
  let r4 = rethrow_catch_bang(-5) catch {
    Empty => -1
    Code(n) => n * 10
  }
  // Nested `try`: inner `catch` rethrows `e => raise e` to outer `try`/`catch`
  let r5 = try {
    try {
      check_local(-9)
    } catch {
      Empty => 100
      e => raise e
    }
  } catch {
    Empty => -1
    Code(n) => n + 200
  }
  // `try Ok(...) catch { e => Err(e) }` and `try!`
  let q_ok = match (try Ok(check_local(4)) catch { e => Err(e) }) {
    Ok(v) => v
    Err(_) => -1
  }
  let q_err = match (try Ok(check_local(-3)) catch { e => Err(e) }) {
    Ok(v) => v
    Err(Empty) => -1
    Err(Code(n)) => n + 100
  }
  let bang_ok = try! check_local(6)
  r1.to_string() + "," + r2.to_string() + "," + r3.to_string() + "," + r4.to_string() + "," + r5.to_string() + "," + q_ok.to_string() + "," + q_err.to_string() + "," + bang_ok.to_string()
}

pub fn case_interp_and_struct_update() -> String {
  let s1 = try {
    "v=\{check_local(8)}"
  } catch {
    _ => "err"
  }
  let s2 = try {
    "v=\{check_local(0)}"
  } catch {
    _ => "err"
  }
  let cfg = { ..@up.default_cfg, x: 10 + @up.BASE_STEP }
  s1 + "|" + s2 + "|" + cfg.x.to_string() + ":" + cfg.y.to_string()
}

pub fn case_headers_in_try() -> String {
  // 1. `match` header with block scrutinee inside `try`
  let h1 = try {
    let base = match { 2 } {
      2 => 20
      _ => 0
    }
    base + check_local(3)
  } catch {
    _ => -1
  }
  // 2. `for` loop with explicit state update + `continue`/`break` inside `try`
  let h2 = try {
    let mut sum = 0
    for n = 3; n >= 0; n = n - 1 {
      if n == 2 {
        continue
      }
      sum = sum + n
      if n == 0 {
        break
      }
    }
    sum + 6 + check_local(1)
  } catch {
    _ => -1
  }
  // 3. `while` header with block condition + local break inside `try`
  let h3 = try {
    let mut i = 0
    while { i < 4 } {
      i = i + 1
      if i == 3 {
        break
      }
    }
    i + check_local(2)
  } catch {
    _ => -1
  }
  // 4. `for` (for-in + C-style) with local break inside `try`
  let h4 = try {
    let mut acc = 0
    for x in [1, 2, 3] {
      acc = acc + x
      if x == 2 {
        break
      }
    }
    for j = 0; j < 5; j = j + 1 {
      acc = acc + j
      if j == 2 {
        break
      }
    }
    acc + check_local(4)
  } catch {
    _ => -1
  }
  h1.to_string() + "," + h2.to_string() + "," + h3.to_string() + "," + h4.to_string()
}

pub fn case_renamed_dep_compound_return(stop : Bool) -> Int {
  try {
    if stop {
      return 77
    }
    let v = @u.fail_u(-7)
    v + 1
  } catch {
    @u.UErr::BadU(c) => c
    @u.UErr::OtherU => -99
  }
}

priv suberror FlagErr {
  Flag(Bool)
}

fn raise_flag(b : Bool) -> Int raise FlagErr {
  raise Flag(b)
}

fn always_fail_g() -> Int raise LocalErr {
  raise Empty
}

fn good_or_fail(b : Bool) -> Int raise LocalErr {
  if b {
    raise Empty
  }
  0
}

fn yes_helper(_x : Int) -> Bool {
  true
}

fn yes_bool(_b : Bool) -> Bool {
  true
}

fn opt_none() -> Int? {
  Option::None
}

priv struct R9Box {
  v : Bool
}

fn pipe_both(a : Bool, _b : Int) -> Bool {
  a
}

fn plain_cmp_is() -> Bool {
  false == true is _
}

fn rb_fail() -> Bool raise LocalErr {
  raise Empty
}

fn ov_fail() -> Int? raise LocalErr {
  raise Empty
}

fn calm_ok() -> Int raise LocalErr {
  1
}

fn yes_res(_r : Result[Int, LocalErr]) -> Bool {
  true
}

fn pick_shadow_res(
  always_fail_g : () -> Result[Int, LocalErr],
  x? : Bool = yes_res(always_fail_g()) && yes_helper(calm_ok()) catch { _ => false },
) -> Bool {
  x
}

fn pick_shadow_int(always_fail_g : () -> Int, x? : Int = always_fail_g()) -> Int {
  x
}

fn pick_raise_def(x? : Int = always_fail_g()) -> Int raise LocalErr {
  x
}

fn pick_raise_chain(
  a : Int,
  x? : Int = a + 1,
  y? : Int = x + always_fail_g(),
) -> Int raise LocalErr {
  y
}

fn val() -> Int raise LocalErr {
  raise Empty
}

fn pick_later_shadow(
  x? : Int = always_fail_g(),
  always_fail_g : () -> Result[Int, LocalErr],
) -> Int raise LocalErr {
  match always_fail_g() {
    Ok(v) => x + v
    Err(_) => x
  }
}

fn pick_kw_rename(
  val : () -> Int,
  val_ : () -> Int,
  x? : Int = val(),
) -> Int {
  let _ = val_
  x
}

fn pick_kw_later(
  x? : Int = val(),
  val : () -> Int,
  val_ : () -> Int,
) -> Int raise LocalErr {
  let _ = val
  let _ = val_
  x
}

let r15_tag : String = "seed"

fn g_ok() -> Int {
  1
}

fn __mbt_parg_1_g_ok() -> Int {
  2
}

fn value_g(g~ : Int) -> Int {
  g
}

fn pick_parg_clash(
  x? : Int = g_ok(),
  g_ok : () -> Int,
  y? : Int = __mbt_parg_1_g_ok(),
) -> Int {
  let _ = g_ok
  x * 10 + __mbt_parg_1_g_ok() + y - 2
}

#callsite(autofill(loc))
fn pick_tag_loc(x? : String = r15_tag, loc~ : SourceLoc) -> Int {
  let _ = loc
  if x == "seed" { 42 } else { 9 }
}

fn pick_let_g(x? : Int = { let g = 1; g }, g~ : Int) -> Int {
  x + g
}

fn pick_pat_g(x? : Int = match Some(1) { Some(g) => g; None => 0 }, g~ : Int) -> Int {
  x + g
}

fn pick_named_g(x? : Int = value_g(g=1), g~ : Int) -> Int {
  x + g
}

priv struct R16V {
  a : Int
}

fn g_two() -> Int {
  2
}

fn pick_r16_pos_cmp_is(
  x? : Int = if false == (opt_none() is Some(g_two)) { g_two() } else { 0 },
  g_two : () -> Int,
) -> Int {
  let _ = g_two
  x
}

fn pick_r16_pos_or_is(
  x? : Int = if (opt_none() is Some(g_two)) || true { g_two() } else { 0 },
  g_two : () -> Int,
) -> Int {
  let _ = g_two
  x
}

fn pick_r16_pos_match_s(
  x? : Int = match R16V::{ a: g_two() } { { a } => a },
  g_two : () -> Int,
) -> Int {
  let _ = g_two
  x
}

fn pick_r16_lbl_paren_and(
  x? : Bool = (Some(1) is Some(g)) && g == 1,
  g~ : Int,
) -> Int {
  if x { g } else { 0 }
}

fn pick_r16_lbl_bare_and(
  x? : Bool = Some(1) is Some(g) && g == 1,
  g~ : Int,
) -> Int {
  if x { g } else { 0 }
}

let r17_g : Bool = false

fn g_true() -> Bool {
  true
}

fn pick_r17_rec() -> Int {
  let r17_g = true
  fn rec(n : Int) -> Bool {
    if n == 0 { true is _ == r17_g } else { rec(n - 1) }
  }
  if rec(2) { 1 } else { 0 }
}

fn pick_r17_interp(
  x? : String = "\{true is _ == g_true()}",
  g_true : () -> Bool,
) -> Int {
  let _ = g_true
  x.length()
}

fn pick_r17_ml_and(
  x? : Bool = (Some(true) is Some(g)) && true &&
  g,
  g~ : Bool,
) -> Int {
  if x && !g { 1 } else { 0 }
}

fn not() -> Bool {
  true
}

fn or() -> Bool {
  true
}

fn pick_r18_not(x? : Bool = not(), not : () -> Bool) -> Int {
  let _ = not
  if x { 1 } else { 0 }
}

fn pick_r18_or(x? : Bool = or(), or : () -> Bool) -> Int {
  let _ = or
  if x { 1 } else { 0 }
}

fn pick_r18_rec_block() -> Int {
  let r17_g = true
  fn rec(n : Int) -> Bool {
    if n == 0 {
      match { let t = r17_g; t } {
        true => true
        false => false
      }
    } else {
      rec(n - 1)
    }
  }
  if rec(2) { 1 } else { 0 }
}

fn pick_r18_nonrec_wrap() -> Int {
  fn wrap(x : Int) -> Int {
    "\{match Some(x) { Some(wrap) => wrap; None => 0 }}".length()
  }
  wrap(7)
}

let top_shadow_block : Int = {
  let always_fail_g = 41
  always_fail_g + 1
}

let top_shadow_match : Int = match Some(41) {
  Some(always_fail_g) => always_fail_g + 1
  None => 0
}

fn case_r5_paren_and_guard() -> String {
  let local_fn : () -> Int = fn() { 42 }
  let p1 = try {
    if (Some(local_fn) is Some(always_fail_g)) {
      let v = always_fail_g()
      v
    } else {
      0
    }
  } catch {
    _ => 7
  }
  let p2 = try {
    guard Some(local_fn) is Some(always_fail_g) else { return "0" }
    let v = always_fail_g()
    v
  } catch {
    _ => 7
  }
  let p3 = try {
    let _ = Some(1) is Some(_) == yes_helper(always_fail_g())
    good_or_fail(false) + 42
  } catch {
    _ => 7
  }
  // R6 P1-2: `guard ... else { let always_fail_g = ... }` MUST NOT leak into statements after `guard`
  let p4 = try {
    guard true else {
      let always_fail_g = local_fn
      let _ = always_fail_g()
      return "0"
    }
    let _ = always_fail_g()
    42
  } catch {
    _ => 7
  }
  // R6 P1-3: `(Some(local_fn) is Some(always_fail_g)) && yes_helper(always_fail_g())` propagates to `&&` only
  let p5 = try {
    let ok = (Some(local_fn) is Some(always_fail_g)) && yes_helper(always_fail_g())
    if ok {
      42
    } else {
      0
    }
  } catch {
    _ => 7
  }
  let p6 = try {
    let _ = (Some(local_fn) is Some(always_fail_g)) && yes_helper(always_fail_g())
    let _ = always_fail_g()
    42
  } catch {
    _ => 9
  }
  // R7 P1-1: call-arg `yes_bool(... is ...)` and negated `!(... is ...)` MUST NOT leak into `&&`
  let p7 = try {
    let _ = yes_bool(Some(1) is Some(always_fail_g)) && yes_helper(always_fail_g())
    good_or_fail(false) + 42
  } catch {
    _ => 7
  }
  let p8 = try {
    let _ = !(opt_none() is Some(always_fail_g)) && yes_helper(always_fail_g())
    good_or_fail(false) + 42
  } catch {
    _ => 7
  }
  // R8 P1-1 & P1-2: `false == (... is ...) && ...`, `true != (... is ...) && ...` MUST NOT leak;
  // newline-started `(Some(local_fn) is Some(always_fail_g)) && ...` MUST propagate!
  let p9 = try {
    let _ = false == (opt_none() is Some(always_fail_g)) && yes_helper(always_fail_g())
    good_or_fail(false) + 42
  } catch {
    _ => 7
  }
  let p10 = try {
    let _ = true != (opt_none() is Some(always_fail_g)) && yes_helper(always_fail_g())
    good_or_fail(false) + 42
  } catch {
    _ => 7
  }
  let p11 = try {
    let keep = yes_helper(1)
    let _ = keep
    let ok =
      (Some(local_fn) is Some(always_fail_g)) && yes_helper(always_fail_g())
    if ok {
      42
    } else {
      0
    }
  } catch {
    _ => 7
  }
  let p12 = try {
    let keep = yes_helper(1)
    (Some(local_fn) is Some(always_fail_g)) && yes_helper(always_fail_g()) |> ignore
    if keep {
      42
    } else {
      0
    }
  } catch {
    _ => 7
  }
  // R9 P1-1: struct field initializer `R9Box::{ v: (Some(local_fn) is Some(always_fail_g)) && ... }` MUST propagate!
  let p13 = try {
    let obj = R9Box::{ v: (Some(local_fn) is Some(always_fail_g)) && yes_helper(always_fail_g()) }
    if obj.v {
      42
    } else {
      0
    }
  } catch {
    _ => 7
  }
  // R10 P1: `|>` has lower precedence than `&&` -> `always_fail_g` MUST NOT leak across `|>`!
  let p14 = try {
    let obj = R9Box::{ v: (Some(local_fn) is Some(always_fail_g)) && yes_helper(always_fail_g()) |> pipe_both(always_fail_g()) }
    if obj.v {
      42
    } else {
      0
    }
  } catch {
    _ => 7
  }
  let p15 = try {
    let obj = R9Box::{ v: ((Some(local_fn) is Some(always_fail_g)) && yes_helper(always_fail_g())) |> pipe_both(always_fail_g()) }
    if obj.v {
      42
    } else {
      0
    }
  } catch {
    _ => 7
  }
  let p16 = try {
    let obj = R9Box::{ v: Some(local_fn) is Some(always_fail_g) && yes_helper(always_fail_g()) |> pipe_both(always_fail_g()) }
    if obj.v {
      42
    } else {
      0
    }
  } catch {
    _ => 7
  }
  let p17 = try {
    if ((Some(local_fn) is Some(always_fail_g)) && yes_helper(always_fail_g()) |> pipe_both(always_fail_g())) {
      42
    } else {
      0
    }
  } catch {
    _ => 7
  }
  // R11 P1: comparison RHS `is` precedence (`false == true is _` == `false == (true is _)` == `false`)
  let p18 = try {
    let v = false == true is _ && yes_helper(always_fail_g())
    if v { 42 } else { 0 }
  } catch {
    _ => 7
  }
  let p19 = try {
    let v = false == opt_none() is Some(always_fail_g) && yes_helper(always_fail_g())
    if v { 42 } else { 0 }
  } catch {
    _ => 7
  }
  let p20 = if plain_cmp_is() { 1 } else { 0 }
  // R11 P2: expression-level `<expr> catch { ... }` wraps full conjunction & exits `is` scope before handler
  let p21 = {
    let v = (Some(1) is Some(x)) && rb_fail() catch { _ => false }
    if v { 42 } else { 0 }
  }
  let p22 = {
    let v = Some(1) is Some(x) && rb_fail() catch { _ => false }
    if v { 42 } else { 0 }
  }
  let p23 = {
    let v = (ov_fail() is Some(x)) && rb_fail() catch { _ => false }
    if v { 42 } else { 0 }
  }
  let p24 = try {
    let v = (ov_fail() is Some(x)) && (rb_fail() catch { _ => false })
    if v { 42 } else { 0 }
  } catch {
    _ => 7
  }
  let p25 = try {
    let v = (Some(local_fn) is Some(always_fail_g)) && rb_fail() catch {
      _ => {
        let _ = always_fail_g()
        false
      }
    }
    if v { 42 } else { 0 }
  } catch {
    _ => 7
  }
  // R12 P1 #1: compound assignment RHS `catch`
  let p26 = {
    let mut x = 3
    x += always_fail_g() catch { _ => 9 }
    x -= always_fail_g() catch { _ => 2 }
    x *= always_fail_g() catch { _ => 3 }
    x
  }
  // R12 P1 #2: comparison RHS `is` inside `if` / `guard` MUST NOT leak into body or `&&`
  let p27 = try {
    if false == opt_none() is Some(always_fail_g) {
      let _ = always_fail_g()
      42
    } else {
      0
    }
  } catch {
    _ => 7
  }
  let p28 = try {
    guard false == opt_none() is Some(always_fail_g) else { return "0" }
    let _ = always_fail_g()
    42
  } catch {
    _ => 7
  }
  let p29 = try {
    if false == opt_none() is Some(always_fail_g) && yes_helper(always_fail_g()) {
      42
    } else {
      0
    }
  } catch {
    _ => 7
  }
  // R12 P2 #4: bare block `{ ... } catch { ... }` + separate block on previous line
  let p30 = {
    let v = {
      let _ = always_fail_g()
      42
    } catch {
      _ => 4
    }
    v
  }
  let p31 = {
    {
      let _ = 1
    }
    let v = always_fail_g() catch { _ => 4 }
    v
  }
  // R13: default param lexical scope (prior params shadow package raising fns) & raising fn default param frame
  let p32 = if pick_shadow_res(fn() { Err(Empty) }) { 42 } else { 0 }
  let p33 = pick_shadow_int(fn() { 42 })
  let p34 = pick_raise_def() catch { _ => 7 }
  let p35 = pick_raise_def(x=42) catch { _ => 7 }
  let p36 = pick_raise_chain(10) catch { _ => 7 }
  let p37 = pick_raise_chain(10, y=42) catch { _ => 7 }
  // R14: later positional param deferred binding & prior keyword param rename in defaults
  let p38 = pick_later_shadow(fn() { Ok(42) }) catch { _ => 7 }
  let p39 = pick_later_shadow(x=10, fn() { Ok(42) }) catch { _ => 7 }
  let p40 = pick_kw_rename(fn() { 42 }, fn() { 9 })
  let p41 = pick_kw_later(fn() { 42 }, fn() { 9 }) catch { _ => 7 }
  // R15: __mbt_parg collision avoidance, non-shadowing autofill loc, and local/pattern/named-arg default exprs
  let p42 = pick_parg_clash(x=1, fn() { 9 })
  let p43 = pick_parg_clash(fn() { 9 })
  let p44 = pick_tag_loc()
  let p45 = pick_let_g(g=8)
  let p46 = pick_pat_g(g=8)
  let p47 = pick_named_g(g=8)
  // R16: positional upper-bound defer (cmp-is / or-is / match-struct) + labeled `(is) &&` / bare `is &&`
  let p48 = pick_r16_pos_cmp_is(fn() { 9 })
  let p49 = pick_r16_pos_or_is(fn() { 9 })
  let p50 = pick_r16_pos_match_s(fn() { 9 })
  let p51 = pick_r16_lbl_paren_and(g=8)
  let p52 = pick_r16_lbl_bare_and(g=8)
  // R17: rec local fn `is == g` capture, interp `is == g()` positional defer, multiline `&&` continuation
  let p53 = pick_r17_rec()
  let p54 = pick_r17_interp(fn() { false })
  let p55 = pick_r17_ml_and(g=false)
  // R18: keyword-ident not/or defer, rec local fn match-block scrut, non-self-rec interp pattern
  let p56 = pick_r18_not(fn() { false })
  let p57 = pick_r18_or(fn() { false })
  let p58 = pick_r18_rec_block()
  let p59 = pick_r18_nonrec_wrap()
  p1.to_string() + "," + p2.to_string() + "," + p3.to_string() + "," + top_shadow_block.to_string() + "," + top_shadow_match.to_string() + "," + p4.to_string() + "," + p5.to_string() + "," + p6.to_string() + "," + p7.to_string() + "," + p8.to_string() + "," + p9.to_string() + "," + p10.to_string() + "," + p11.to_string() + "," + p12.to_string() + "," + p13.to_string() + "," + p14.to_string() + "," + p15.to_string() + "," + p16.to_string() + "," + p17.to_string() + "," + p18.to_string() + "," + p19.to_string() + "," + p20.to_string() + "," + p21.to_string() + "," + p22.to_string() + "," + p23.to_string() + "," + p24.to_string() + "," + p25.to_string() + "," + p26.to_string() + "," + p27.to_string() + "," + p28.to_string() + "," + p29.to_string() + "," + p30.to_string() + "," + p31.to_string() + "," + p32.to_string() + "," + p33.to_string() + "," + p34.to_string() + "," + p35.to_string() + "," + p36.to_string() + "," + p37.to_string() + "," + p38.to_string() + "," + p39.to_string() + "," + p40.to_string() + "," + p41.to_string() + "," + p42.to_string() + "," + p43.to_string() + "," + p44.to_string() + "," + p45.to_string() + "," + p46.to_string() + "," + p47.to_string() + "," + p48.to_string() + "," + p49.to_string() + "," + p50.to_string() + "," + p51.to_string() + "," + p52.to_string() + "," + p53.to_string() + "," + p54.to_string() + "," + p55.to_string() + "," + p56.to_string() + "," + p57.to_string() + "," + p58.to_string() + "," + p59.to_string()
}

pub fn case_r4_semantics() -> String {
  // P1-1: `is` scope isolation
  let s1 = try {
    let _ = Some(1) is Some(always_fail_g)
    let _ = always_fail_g()
    good_or_fail(false) + 42
  } catch {
    _ => 7
  }
  let s2 = if Some(1) is Some(always_fail_g) {
    always_fail_g
  } else {
    0
  }
  let s3 = try {
    let ok = Some(1) is Some(always_fail_g) && always_fail_g > 0
    let _ = always_fail_g()
    if ok {
      99
    } else {
      0
    }
  } catch {
    _ => 8
  }
  // P2-4: cross-package construction of `pub(all) suberror`
  let pe : Result[Int, @u.PubErr] = Err(@u.PubErr::PubBad)
  let s4 = match pe {
    Ok(v) => v
    Err(@u.PubErr::PubBad) => 55
  }
  // P2-5: exhaustive Bool payload catch (with trailing commas)
  let s5 = raise_flag(false) catch {
    Flag(true,) => 1
    Flag(false,) => 2
  }
  s1.to_string() + "," + s2.to_string() + "," + s3.to_string() + "," + s4.to_string() + "," + s5.to_string() + "|" + case_r5_paren_and_guard()
}

pub fn run_all() -> String {
  "X:" + case_cross_pkg() +
    "\nR:" + case_rethrow_and_nested() +
    "\nI:" + case_interp_and_struct_update() +
    "\nH:" + case_headers_in_try() +
    "\nU:" + case_renamed_dep_compound_return(true).to_string() + "," + case_renamed_dep_compound_return(false).to_string() +
    "\nS:" + case_r4_semantics()
}
'''

NEGATIVE_CASES = [
    (
        "incomplete_catch",
        "priv suberror E { A; B(Int) }\nfn g() -> Int raise E { raise A }\npub fn f() -> Int { g() catch { A => 1 } }\n",
    ),
    (
        "default_param_labeled_shadow",
        "priv suberror E { Bad }\nfn g() -> Int raise E { raise Bad }\npub fn pick_labeled_shadow(x? : Int = g(), g~ : () -> Result[Int, E]) -> Int raise E { let _ = g; x }\n",
    ),
    (
        "default_param_self_shadow",
        "priv suberror E { Bad }\nfn g() -> Int raise E { raise Bad }\npub fn pick_self_shadow(g? : Int = g()) -> Int raise E { g }\n",
    ),
    (
        "default_param_autofill_loc_shadow",
        "let loc : String = \"seed\"\n#callsite(autofill(loc))\npub fn pick_loc_shadow(x? : String = loc, loc~ : SourceLoc) -> Int { let _ = loc; if x == \"seed\" { 42 } else { 9 } }\n",
    ),
    (
        "default_param_labeled_cmp_is_shadow",
        "fn g() -> Int { 2 }\nfn none_i() -> Int? { None }\npub fn p(x? : Int = if false == (none_i() is Some(g)) { g() } else { 0 }, g~ : () -> Int) -> Int { let _ = g; x }\n",
    ),
    (
        "default_param_labeled_or_is_shadow",
        "fn g() -> Int { 2 }\nfn none_i() -> Int? { None }\npub fn p(x? : Int = if (none_i() is Some(g)) || true { g() } else { 0 }, g~ : () -> Int) -> Int { let _ = g; x }\n",
    ),
    (
        "default_param_labeled_match_struct_shadow",
        "priv struct R16V { a : Int }\nfn g() -> Int { 2 }\npub fn p(x? : Int = match R16V::{ a: g() } { { a } => a }, g~ : () -> Int) -> Int { let _ = g; x }\n",
    ),
    (
        "default_param_labeled_bare_is_cmp",
        "fn g() -> Bool { true }\npub fn p(x? : Bool = true is _ == g(), g~ : () -> Bool) -> Int { let _ = g; if x { 1 } else { 0 } }\n",
    ),
    (
        "default_param_labeled_newline_after_cmp",
        "fn g() -> Bool { true }\nfn none_i() -> Int? { None }\npub fn p(x? : Bool = false ==\n(none_i() is Some(g)) && g(), g~ : () -> Bool) -> Int { let _ = g; if x { 1 } else { 0 } }\n",
    ),
    (
        "default_param_labeled_kw_not",
        "fn not() -> Bool { true }\npub fn p(x? : Bool = not(), not~ : () -> Bool) -> Int { let _ = not; if x { 1 } else { 0 } }\n",
    ),
    (
        "default_param_labeled_kw_or",
        "fn or() -> Bool { true }\npub fn p(x? : Bool = or(), or~ : () -> Bool) -> Int { let _ = or; if x { 1 } else { 0 } }\n",
    ),
    (
        "default_param_labeled_nested_interp",
        "fn g() -> Bool { true }\nfn choose(_s : String, b : Bool) -> Bool { b }\npub fn p(x? : String = \"\\{choose(\"\\{\"}\"}\", g())}\", g~ : () -> Bool) -> Int { let _ = g; x.length() }\n",
    ),
    (
        "default_param_labeled_match_block_scrut",
        "fn g() -> Bool { true }\npub fn p(x? : Bool = match { let t = g(); t } { true => true; false => false }, g~ : () -> Bool) -> Int { let _ = g; if x { 1 } else { 0 } }\n",
    ),
    (
        "incomplete_bool_catch",
        "priv suberror E { Flag(Bool) }\nfn g() -> Int raise E { raise Flag(false) }\npub fn f() -> Int { g() catch { Flag(true) => 1 } }\n",
    ),
    (
        "bare_raise",
        "pub fn f(x : Int) -> Int raise { x }\n",
    ),
    (
        "raise_error",
        "pub fn f(x : Int) -> Int raise Error { x }\n",
    ),
    (
        "outer_raise_error_inner_concrete",
        "priv suberror E { A }\nfn g() -> Int raise E { raise A }\npub fn f() -> Int raise Error { g() }\n",
    ),
    (
        "closure_mismatched_rethrow",
        "priv suberror E1 { A1 }\npriv suberror E2 { A2 }\nfn g() -> Int raise E1 { raise A1 }\npub fn f() -> Int raise E2 { let h = fn() -> Int { g() catch { e => raise e } }; h() }\n",
    ),
    (
        "cross_closure_early_exit",
        "priv suberror E { A }\nfn g() -> Int raise E { raise A }\npub fn f() -> Int { let mut s = 0; while s < 5 { s = s + (try { if s == 2 { break }; g() } catch { A => 1 }) }; s }\n",
    ),
]


def run_cmd(cmd, cwd=None, check=True):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
    if check and p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", default=os.environ.get("PIONC", shutil.which("pionc") or os.path.expanduser("~/.pion/bin/pionc")))
    ap.add_argument("--moon", default=os.environ.get("MOON", shutil.which("moon") or os.path.expanduser("~/.moon/bin/moon")))
    ap.add_argument("--wasm-rt", default=os.path.join(REPO_ROOT, "runtime", "pion_wasm_rt.mjs"))
    args = ap.parse_args()

    work = tempfile.mkdtemp(prefix="mbt2pion-f6-1-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])

        # 1. Build MoonBit multi-package project and run native + wasm-gc
        md = os.path.join(work, "moon_proj")
        for sub in ("up", "up2", "custom_json", "down", "cmd"):
            os.makedirs(os.path.join(md, sub))
        files = [
            ("moon.mod", 'name = "f6/oracle"\n'),
            ("up/moon.pkg", "\n"),
            ("up/up.mbt", UP_MBT),
            ("up2/moon.pkg", "\n"),
            ("up2/up2.mbt", UP2_MBT),
            ("custom_json/moon.pkg", "\n"),
            ("custom_json/cj.mbt", CUSTOM_JSON_MBT),
            (
                "down/moon.pkg",
                'import { "f6/oracle/up", "f6/oracle/up2" @u, "f6/oracle/custom_json" @json, "moonbitlang/core/json" @j }\n',
            ),
            ("down/down.mbt", DOWN_MBT),
            ("cmd/moon.pkg", 'import { "f6/oracle/down" }\noptions("is-main": true)\n'),
            ("cmd/main.mbt", "fn main {\n  println(@down.run_all())\n}\n"),
        ]
        for rel, txt in files:
            with open(os.path.join(md, rel), "w") as f:
                f.write(txt)

        moon_nat = run_cmd([args.moon, "run", "--target", "native", "cmd"], cwd=md).stdout.strip()
        moon_wgc = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md).stdout.strip()
        assert moon_nat == moon_wgc, f"Moon native vs wasm-gc mismatch:\n{moon_nat}\nvs\n{moon_wgc}"

        # 2. Transpile `up`, `up2`, `custom_json`, `down` via real `mbt2pion_cli --mode publish`
        p_up = os.path.join(work, "p_up")
        p_up2 = os.path.join(work, "p_up2")
        p_cj = os.path.join(work, "p_cj")
        p_dn = os.path.join(work, "p_dn")
        for d in (p_up, p_up2, p_cj, p_dn):
            os.makedirs(os.path.join(d, "src"))

        with open(os.path.join(p_up, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "up"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "up"), "--out", os.path.join(p_up, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        up_abi_txt = open(os.path.join(p_up, "src", "mbt2pion_abi.json")).read()
        assert '"raising_fns"' in up_abi_txt and '"parse_code"' in up_abi_txt, f"missing raising_fns in up ABI: {up_abi_txt}"

        with open(os.path.join(p_up2, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "up2"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "up2"), "--out", os.path.join(p_up2, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])

        with open(os.path.join(p_cj, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "custom_json"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "custom_json"), "--out", os.path.join(p_cj, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])

        with open(os.path.join(p_dn, "pion.toml"), "w") as f:
            f.write(
                f'[package]\nname = "down"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nup = {{ path = "{p_up}" }}\nup2 = {{ path = "{p_up2}" }}\ncustom_json = {{ path = "{p_cj}" }}\n'
            )
        run_cmd([
            bin_path,
            "--src", os.path.join(md, "down"),
            "--out", os.path.join(p_dn, "src"),
            "--target", "native",
            "--mode", "publish",
            "--mbt-compat", COMPAT_DIR,
            "--dep", f"up={p_up}",
            "--dep", f"up2={p_up2}",
            "--dep", f"custom_json={p_cj}",
            "--pionc", args.pionc,
        ])
        with open(os.path.join(p_dn, "src", "main.pion"), "w") as f:
            f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_all())\n  0\n}\n")

        # 3. Run Pion native & Pion wasm32 and assert 4-target equality
        pion_nat = run_cmd([args.pionc, "run", p_dn]).stdout.strip()
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", p_dn]).stdout.strip()
        expected = "X:31,-14,5,203,1,0\nR:50,40,60,50,209,5,103,7\nI:v=9|err|15:2\nH:24,12,6,11\nU:77,-21\nS:7,1,8,55,2|42,42,7,42,42,7,42,9,7,7,7,7,42,42,42,7,7,7,7,0,7,0,0,0,0,7,7,30,7,7,7,4,4,42,42,7,42,7,42,7,52,42,7,12,12,42,9,9,9,2,2,2,8,8,1,4,1,1,1,1,1"
        assert moon_nat == expected, f"Expected mismatch:\nGOT:\n{moon_nat}\nEXP:\n{expected}"
        assert pion_nat == moon_nat and pion_wasm == moon_nat, (
            f"4-target mismatch:\nMoon-nat:\n{moon_nat}\nMoon-wgc:\n{moon_wgc}\nPion-nat:\n{pion_nat}\nPion-wasm:\n{pion_wasm}"
        )
        print("[f6-1-oracle] PASS: 4-engine (moon native == moon wasm-gc == pion native == pion wasm32) 100% identical!\n" + moon_nat)

        # 3a-1. P1-2 4-target check: user-defined `fn panic(_s : String) -> Int { 42 }` MUST NOT hijack `try!`
        for tc_name, tc_body in [
            ("direct_try_bang", "try! g()"),
            ("compound_try_bang", "try! { let x = g(); x + 1 }"),
        ]:
            sh_m = os.path.join(work, f"sh_{tc_name}_moon")
            os.makedirs(os.path.join(sh_m, "cmd"))
            sh_src = (
                "priv suberror E { Bad }\n"
                "fn panic(_s : String) -> Int { 42 }\n"
                "fn g() -> Int raise E { raise Bad }\n"
                f"pub fn run() -> Int {{ {tc_body} }}\n"
            )
            with open(os.path.join(sh_m, "moon.mod"), "w") as f:
                f.write('name = "f6/sh"\n')
            with open(os.path.join(sh_m, "cmd", "moon.pkg"), "w") as f:
                f.write('options("is-main": true)\n')
            with open(os.path.join(sh_m, "cmd", "main.mbt"), "w") as f:
                f.write(sh_src + "fn main { println(run().to_string()) }\n")
            mn_r = run_cmd([args.moon, "run", "--target", "native", "cmd"], cwd=sh_m, check=False)
            mw_r = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=sh_m, check=False)
            assert mn_r.returncode != 0 and mw_r.returncode != 0, f"Moon {tc_name} did not trap: nat={mn_r.returncode} wgc={mw_r.returncode}"

            sh_psrc = os.path.join(work, f"sh_{tc_name}_psrc")
            sh_pout = os.path.join(work, f"sh_{tc_name}_pout")
            os.makedirs(sh_psrc)
            os.makedirs(os.path.join(sh_pout, "src"))
            with open(os.path.join(sh_psrc, "moon.pkg"), "w") as f:
                f.write("\n")
            with open(os.path.join(sh_psrc, "sh.mbt"), "w") as f:
                f.write(sh_src)
            with open(os.path.join(sh_pout, "pion.toml"), "w") as f:
                f.write(f'[package]\nname = "sh_{tc_name}"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
            run_cmd([bin_path, "--src", sh_psrc, "--out", os.path.join(sh_pout, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
            with open(os.path.join(sh_pout, "src", "main.pion"), "w") as f:
                f.write("pub fn main(w : World) -> Int {\n  io_println(w, run().to_string())\n  0\n}\n")
            pn_r = run_cmd([args.pionc, "run", sh_pout], check=False)
            pw_r = run_cmd([args.pionc, "run", "--target", "wasm32", sh_pout], check=False)
            assert pn_r.returncode != 0 and "42" not in pn_r.stdout, f"Pion native {tc_name} hijacked: rc={pn_r.returncode} out={pn_r.stdout!r}"
            assert pw_r.returncode != 0 and "42" not in pw_r.stdout, f"Pion wasm32 {tc_name} hijacked: rc={pw_r.returncode} out={pw_r.stdout!r}"
            print(f"[f6-1-oracle] PASS P1-2 unshadowable try! ({tc_name}): 4-target trap confirmed")

        # 3a-2. P1-3 4-target check: swapped dep aliases (`a @b, b @a`) under both --dep orders
        sw_m = os.path.join(work, "sw_moon")
        for sub in ("a", "b", "down", "cmd"):
            os.makedirs(os.path.join(sw_m, sub))
        sw_files = [
            ("moon.mod", 'name = "f6/sw"\n'),
            ("a/moon.pkg", "\n"),
            ("a/a.mbt", "pub fn fetch() -> Result[Int, Int] { Err(1) }\n"),
            ("b/moon.pkg", "\n"),
            ("b/b.mbt", "pub suberror BErr { Bad }\npub fn fetch() -> Int raise BErr { raise Bad }\npub fn ok(fail_now : Bool) -> Int raise BErr { if fail_now { raise Bad }; 0 }\n"),
            ("down/moon.pkg", 'import { "f6/sw/a" @b, "f6/sw/b" @a }\n'),
            ("down/down.mbt", "pub fn run_sw() -> Int { try { let _ = @b.fetch(); @a.ok(false) + 42 } catch { _ => 7 } }\n"),
            ("cmd/moon.pkg", 'import { "f6/sw/down" }\noptions("is-main": true)\n'),
            ("cmd/main.mbt", "fn main { println(@down.run_sw().to_string()) }\n"),
        ]
        for rel, txt in sw_files:
            with open(os.path.join(sw_m, rel), "w") as f:
                f.write(txt)
        sw_mn = run_cmd([args.moon, "run", "--target", "native", "cmd"], cwd=sw_m).stdout.strip()
        sw_mw = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=sw_m).stdout.strip()
        assert sw_mn == "42" and sw_mw == "42", f"Swapped alias Moon mismatch: nat={sw_mn!r} wgc={sw_mw!r}"

        sw_pa = os.path.join(work, "sw_pa")
        sw_pb = os.path.join(work, "sw_pb")
        for nm, pd in [("a", sw_pa), ("b", sw_pb)]:
            os.makedirs(os.path.join(pd, "src"))
            with open(os.path.join(pd, "pion.toml"), "w") as f:
                f.write(f'[package]\nname = "{nm}"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
            run_cmd([bin_path, "--src", os.path.join(sw_m, nm), "--out", os.path.join(pd, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])

        for ord_name, dep_flags in [
            ("ab", ["--dep", f"a={sw_pa}", "--dep", f"b={sw_pb}"]),
            ("ba", ["--dep", f"b={sw_pb}", "--dep", f"a={sw_pa}"]),
        ]:
            sw_pd = os.path.join(work, f"sw_pd_{ord_name}")
            os.makedirs(os.path.join(sw_pd, "src"))
            with open(os.path.join(sw_pd, "pion.toml"), "w") as f:
                f.write(f'[package]\nname = "down_{ord_name}"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\na = {{ path = "{sw_pa}" }}\nb = {{ path = "{sw_pb}" }}\n')
            run_cmd([bin_path, "--src", os.path.join(sw_m, "down"), "--out", os.path.join(sw_pd, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, *dep_flags, "--pionc", args.pionc])
            with open(os.path.join(sw_pd, "src", "main.pion"), "w") as f:
                f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_sw().to_string())\n  0\n}\n")
            sw_pn = run_cmd([args.pionc, "run", sw_pd]).stdout.strip()
            sw_pw = run_cmd([args.pionc, "run", "--target", "wasm32", sw_pd]).stdout.strip()
            assert sw_pn == "42" and sw_pw == "42", f"Swapped alias Pion ({ord_name}) mismatch: nat={sw_pn!r} wasm={sw_pw!r}"
        print("[f6-1-oracle] PASS P1-3 swapped aliases (a @b, b @a) in both --dep orders: 4-target == 42")

        # 3a-3. R5 P1-1 4-target check: distinct full paths sharing trailing segment (`left/cache @cache`, `right/cache @other`)
        cs_m = os.path.join(work, "cs_moon")
        for sub in ("left/cache", "right/cache", "down", "cmd"):
            os.makedirs(os.path.join(cs_m, sub))
        cs_files = [
            ("moon.mod", 'name = "f6/cs"\n'),
            ("left/cache/moon.pkg", "\n"),
            ("left/cache/c.mbt", "pub fn get() -> Int { 1 }\n"),
            ("right/cache/moon.pkg", "\n"),
            ("right/cache/c.mbt", "pub fn get() -> Int { 2 }\n"),
            ("down/moon.pkg", 'import { "f6/cs/left/cache" @cache, "f6/cs/right/cache" @other }\n'),
            ("down/down.mbt", "pub fn run_cs() -> Int { @cache.get() * 10 + @other.get() }\n"),
            ("cmd/moon.pkg", 'import { "f6/cs/down" }\noptions("is-main": true)\n'),
            ("cmd/main.mbt", "fn main { println(@down.run_cs().to_string()) }\n"),
        ]
        for rel, txt in cs_files:
            with open(os.path.join(cs_m, rel), "w") as f:
                f.write(txt)
        cs_mn = run_cmd([args.moon, "run", "--target", "native", "cmd"], cwd=cs_m).stdout.strip()
        cs_mw = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=cs_m).stdout.strip()
        assert cs_mn == "12" and cs_mw == "12", f"Same-tail Moon mismatch: nat={cs_mn!r} wgc={cs_mw!r}"

        cs_pc = os.path.join(work, "cs_pc")
        cs_po = os.path.join(work, "cs_po")
        for nm, src_sub, pd in [("cache", "left/cache", cs_pc), ("other", "right/cache", cs_po)]:
            os.makedirs(os.path.join(pd, "src"))
            with open(os.path.join(pd, "pion.toml"), "w") as f:
                f.write(f'[package]\nname = "{nm}"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
            run_cmd([bin_path, "--src", os.path.join(cs_m, src_sub), "--out", os.path.join(pd, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])

        for ord_name, dep_flags in [
            ("co", ["--dep", f"cache={cs_pc}", "--dep", f"other={cs_po}"]),
            ("oc", ["--dep", f"other={cs_po}", "--dep", f"cache={cs_pc}"]),
        ]:
            cs_pd = os.path.join(work, f"cs_pd_{ord_name}")
            os.makedirs(os.path.join(cs_pd, "src"))
            with open(os.path.join(cs_pd, "pion.toml"), "w") as f:
                f.write(f'[package]\nname = "cs_down_{ord_name}"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\ncache = {{ path = "{cs_pc}" }}\nother = {{ path = "{cs_po}" }}\n')
            run_cmd([bin_path, "--src", os.path.join(cs_m, "down"), "--out", os.path.join(cs_pd, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, *dep_flags, "--pionc", args.pionc])
            with open(os.path.join(cs_pd, "src", "main.pion"), "w") as f:
                f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_cs().to_string())\n  0\n}\n")
            cs_pn = run_cmd([args.pionc, "run", cs_pd]).stdout.strip()
            cs_pw = run_cmd([args.pionc, "run", "--target", "wasm32", cs_pd]).stdout.strip()
            assert cs_pn == "12" and cs_pw == "12", f"Same-tail Pion ({ord_name}) mismatch: nat={cs_pn!r} wasm={cs_pw!r}"
        print("[f6-1-oracle] PASS R5 P1-1 same-tail distinct paths (left/cache @cache, right/cache @other): 4-target == 12")

        # 3a-4. R6 P1-1 4-target check: transitive `--dep y` MUST NOT hijack direct import `"f6/tr/x" @y`
        tr_m = os.path.join(work, "tr_moon")
        for sub in ("y", "x", "down", "cmd"):
            os.makedirs(os.path.join(tr_m, sub))
        tr_files = [
            ("moon.mod", 'name = "f6/tr"\n'),
            ("y/moon.pkg", "\n"),
            ("y/y.mbt", "pub fn get() -> Int { 2 }\n"),
            ("x/moon.pkg", 'import { "f6/tr/y" }\n'),
            ("x/x.mbt", "pub fn get() -> Int { @y.get() - 1 }\n"),
            ("down/moon.pkg", 'import { "f6/tr/x" @y }\n'),
            ("down/down.mbt", "pub fn run_tr() -> Int { @y.get() }\n"),
            ("cmd/moon.pkg", 'import { "f6/tr/down" }\noptions("is-main": true)\n'),
            ("cmd/main.mbt", "fn main { println(@down.run_tr().to_string()) }\n"),
        ]
        for rel, txt in tr_files:
            with open(os.path.join(tr_m, rel), "w") as f:
                f.write(txt)
        tr_mn = run_cmd([args.moon, "run", "--target", "native", "cmd"], cwd=tr_m).stdout.strip()
        tr_mw = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=tr_m).stdout.strip()
        assert tr_mn == "1" and tr_mw == "1", f"Transitive dep Moon mismatch: nat={tr_mn!r} wgc={tr_mw!r}"

        tr_py = os.path.join(work, "tr_py")
        tr_px = os.path.join(work, "tr_px")
        os.makedirs(os.path.join(tr_py, "src"))
        os.makedirs(os.path.join(tr_px, "src"))
        with open(os.path.join(tr_py, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "y"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(tr_m, "y"), "--out", os.path.join(tr_py, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        with open(os.path.join(tr_px, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "x"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\ny = {{ path = "{tr_py}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(tr_m, "x"), "--out", os.path.join(tr_px, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--dep", f"y={tr_py}", "--pionc", args.pionc])

        for ord_name, dep_flags, extra_toml in [
            ("x_only", ["--dep", f"x={tr_px}"], ""),
            ("xy", ["--dep", f"x={tr_px}", "--dep", f"y={tr_py}"], f'y = {{ path = "{tr_py}" }}\n'),
            ("yx", ["--dep", f"y={tr_py}", "--dep", f"x={tr_px}"], f'y = {{ path = "{tr_py}" }}\n'),
        ]:
            tr_pd = os.path.join(work, f"tr_pd_{ord_name}")
            os.makedirs(os.path.join(tr_pd, "src"))
            with open(os.path.join(tr_pd, "pion.toml"), "w") as f:
                f.write(f'[package]\nname = "tr_down_{ord_name}"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nx = {{ path = "{tr_px}" }}\n{extra_toml}')
            run_cmd([bin_path, "--src", os.path.join(tr_m, "down"), "--out", os.path.join(tr_pd, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, *dep_flags, "--pionc", args.pionc])
            with open(os.path.join(tr_pd, "src", "main.pion"), "w") as f:
                f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_tr().to_string())\n  0\n}\n")
            tr_pn = run_cmd([args.pionc, "run", tr_pd]).stdout.strip()
            tr_pw = run_cmd([args.pionc, "run", "--target", "wasm32", tr_pd]).stdout.strip()
            assert tr_pn == "1" and tr_pw == "1", f"Transitive dep Pion ({ord_name}) mismatch: nat={tr_pn!r} wasm={tr_pw!r}"
        print("[f6-1-oracle] PASS R6 P1-1 transitive dep y->x->down(x @y) in all 3 --dep configs: 4-target == 1")

        # 3a-5. R7 P2-2 4-target check: duplicate --dep aliases pointing to the SAME verified package MUST NOT fail as ambiguous
        dup_m = os.path.join(work, "dup_moon")
        for sub in ("down", "cmd"):
            os.makedirs(os.path.join(dup_m, sub))
        for rel, txt in [
            ("moon.mod", 'name = "f6/tr"\n'),
            ("y/moon.pkg", "\n"),
            ("y/y.mbt", "pub fn get() -> Int { 2 }\n"),
            ("down/moon.pkg", 'import { "f6/tr/y" @other }\n'),
            ("down/down.mbt", "pub fn run_dup() -> Int { @other.get() }\n"),
            ("cmd/moon.pkg", 'import { "f6/tr/down" }\noptions("is-main": true)\n'),
            ("cmd/main.mbt", "fn main { println(@down.run_dup().to_string()) }\n"),
        ]:
            os.makedirs(os.path.dirname(os.path.join(dup_m, rel)), exist_ok=True)
            with open(os.path.join(dup_m, rel), "w") as f:
                f.write(txt)
        dup_mn = run_cmd([args.moon, "run", "--target", "native", "cmd"], cwd=dup_m).stdout.strip()
        dup_mw = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=dup_m).stdout.strip()
        assert dup_mn == "2" and dup_mw == "2", f"Dup alias Moon mismatch: nat={dup_mn!r} wgc={dup_mw!r}"

        for ord_name, dep_flags in [
            ("yo", ["--dep", f"y={tr_py}", "--dep", f"other={tr_py}"]),
            ("oy", ["--dep", f"other={tr_py}", "--dep", f"y={tr_py}"]),
        ]:
            dup_pd = os.path.join(work, f"dup_pd_{ord_name}")
            os.makedirs(os.path.join(dup_pd, "src"))
            with open(os.path.join(dup_pd, "pion.toml"), "w") as f:
                f.write(f'[package]\nname = "dup_down_{ord_name}"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\ny = {{ path = "{tr_py}" }}\n')
            run_cmd([bin_path, "--src", os.path.join(dup_m, "down"), "--out", os.path.join(dup_pd, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, *dep_flags, "--pionc", args.pionc])
            with open(os.path.join(dup_pd, "src", "main.pion"), "w") as f:
                f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_dup().to_string())\n  0\n}\n")
            dup_pn = run_cmd([args.pionc, "run", dup_pd]).stdout.strip()
            dup_pw = run_cmd([args.pionc, "run", "--target", "wasm32", dup_pd]).stdout.strip()
            assert dup_pn == "2" and dup_pw == "2", f"Dup alias Pion ({ord_name}) mismatch: nat={dup_pn!r} wasm={dup_pw!r}"
        print("[f6-1-oracle] PASS R7 P2-2 duplicate --dep aliases to same verified package (both orders): 4-target == 2")

        # 3a-6. R8 P1-3 negative check: two DIFFERENT implementations with same canonical name `x` and same ABI
        # MUST fail closed with MBT2PION_DEP_ABI_ERROR (in both --dep orders)!
        diff_l_src = os.path.join(work, "diff_l_src")
        diff_r_src = os.path.join(work, "diff_r_src")
        diff_l_out = os.path.join(work, "diff_l_out")
        diff_r_out = os.path.join(work, "diff_r_out")
        for s_dir, o_dir, ret_val in [(diff_l_src, diff_l_out, "1"), (diff_r_src, diff_r_out, "2")]:
            os.makedirs(s_dir)
            os.makedirs(os.path.join(o_dir, "src"))
            with open(os.path.join(s_dir, "moon.pkg"), "w") as f:
                f.write("\n")
            with open(os.path.join(s_dir, "x.mbt"), "w") as f:
                f.write(f"pub fn get() -> Int {{ {ret_val} }}\n")
            with open(os.path.join(o_dir, "pion.toml"), "w") as f:
                f.write(f'[package]\nname = "x"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
            run_cmd([bin_path, "--src", s_dir, "--out", os.path.join(o_dir, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        diff_dn_src = os.path.join(work, "diff_dn_src")
        os.makedirs(diff_dn_src)
        with open(os.path.join(diff_dn_src, "moon.pkg"), "w") as f:
            f.write('import { "audit/check/x" @other }\n')
        with open(os.path.join(diff_dn_src, "dn.mbt"), "w") as f:
            f.write("pub fn run_diff() -> Int { @other.get() }\n")
        for ord_name, dep_flags in [
            ("lr", ["--dep", f"x={diff_l_out}", "--dep", f"other={diff_r_out}"]),
            ("rl", ["--dep", f"other={diff_r_out}", "--dep", f"x={diff_l_out}"]),
        ]:
            diff_dn_out = os.path.join(work, f"diff_dn_out_{ord_name}")
            os.makedirs(diff_dn_out)
            res = run_cmd(
                [bin_path, "--src", diff_dn_src, "--out", diff_dn_out, "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, *dep_flags, "--pionc", args.pionc],
                check=False,
            )
            combined = res.stdout + "\n" + res.stderr
            rep_p = os.path.join(diff_dn_out, "migration_report.json")
            if os.path.isfile(rep_p):
                combined += "\n" + open(rep_p).read()
            assert res.returncode != 0 and "MBT2PION_DEP_ABI_ERROR" in combined, (
                f"R8 P1-3 different impls ({ord_name}) MUST fail closed with MBT2PION_DEP_ABI_ERROR:\n{combined}"
            )
        print("[f6-1-oracle] PASS R8 P1-3 different impls with same canonical name & ABI fail closed (both orders)")

        # 3a-7. R9 P1-2: identical source/ABI/files_sha256 in DIFFERENT directories with DIFFERENT transitive deps
        # (`L/x -> L/leaf(1)` vs `R/x -> R/leaf(2)`) MUST fail closed, while same canonical dir (`R/x` vs `R/./x`) succeeds!
        r9_base = os.path.join(work, "r9_trans")
        r9_dirs = {}
        for side, leaf_val in [("L", "1"), ("R", "2")]:
            l_src = os.path.join(r9_base, side, "mbt", "leaf")
            l_out = os.path.join(r9_base, side, "leaf")
            x_src = os.path.join(r9_base, side, "mbt", "x")
            x_out = os.path.join(r9_base, side, "x")
            for d in (l_src, x_src):
                os.makedirs(d)
            for d in (l_out, x_out):
                os.makedirs(os.path.join(d, "src"))
            with open(os.path.join(l_src, "moon.pkg"), "w") as f:
                f.write("\n")
            with open(os.path.join(l_src, "leaf.mbt"), "w") as f:
                f.write(f"pub fn get() -> Int {{ {leaf_val} }}\n")
            with open(os.path.join(l_out, "pion.toml"), "w") as f:
                f.write(f'[package]\nname = "leaf"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
            run_cmd([bin_path, "--src", l_src, "--out", os.path.join(l_out, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
            with open(os.path.join(x_src, "moon.pkg"), "w") as f:
                f.write('import { "f6/r9/leaf" }\n')
            with open(os.path.join(x_src, "x.mbt"), "w") as f:
                f.write("pub fn get() -> Int { @leaf.get() }\n")
            with open(os.path.join(x_out, "pion.toml"), "w") as f:
                f.write(f'[package]\nname = "x"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nleaf = {{ path = "{l_out}" }}\n')
            run_cmd([bin_path, "--src", x_src, "--out", os.path.join(x_out, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--dep", f"leaf={l_out}", "--pionc", args.pionc])
            r9_dirs[side] = (l_out, x_out)

        assert open(os.path.join(r9_dirs["L"][1], "src", "mbt2pion_abi.json")).read() == open(os.path.join(r9_dirs["R"][1], "src", "mbt2pion_abi.json")).read(), \
            "L/x and R/x must have identical mbt2pion_abi.json (same ABI & files_sha256)"

        r9_dn_src = os.path.join(r9_base, "dn_src")
        os.makedirs(r9_dn_src)
        with open(os.path.join(r9_dn_src, "moon.pkg"), "w") as f:
            f.write('import { "f6/r9/x" @other }\n')
        with open(os.path.join(r9_dn_src, "dn.mbt"), "w") as f:
            f.write("pub fn run_r9() -> Int { @other.get() }\n")

        for ord_name, dep_flags in [
            ("lr", ["--dep", f"x={r9_dirs['L'][1]}", "--dep", f"other={r9_dirs['R'][1]}"]),
            ("rl", ["--dep", f"other={r9_dirs['R'][1]}", "--dep", f"x={r9_dirs['L'][1]}"]),
            ("dup_first_wins", ["--dep", f"x={r9_dirs['L'][1]}", "--dep", f"x={r9_dirs['R'][1]}", "--dep", f"other={r9_dirs['R'][1]}"]),
        ]:
            r9_dn_out = os.path.join(r9_base, f"dn_fail_{ord_name}")
            os.makedirs(r9_dn_out)
            res = run_cmd(
                [bin_path, "--src", r9_dn_src, "--out", r9_dn_out, "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, *dep_flags, "--pionc", args.pionc],
                check=False,
            )
            combined = res.stdout + "\n" + res.stderr
            rep_p = os.path.join(r9_dn_out, "migration_report.json")
            if os.path.isfile(rep_p):
                combined += "\n" + open(rep_p).read()
            assert res.returncode != 0 and "MBT2PION_DEP_ABI_ERROR" in combined, (
                f"R9 P1-2 different dirs with identical files_sha256 ({ord_name}) MUST fail closed:\n{combined}"
            )

        # Same canonical dir via `/./` MUST succeed and produce 2 on Pion native & wasm32 (matching Moon)
        r9_same_out = os.path.join(r9_base, "dn_same")
        os.makedirs(os.path.join(r9_same_out, "src"))
        r_x_dot = os.path.join(r9_base, "R", ".", "x")
        with open(os.path.join(r9_same_out, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "r9_same"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nx = {{ path = "{r9_dirs["R"][1]}" }}\n')
        run_cmd([bin_path, "--src", r9_dn_src, "--out", os.path.join(r9_same_out, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--dep", f"x={r9_dirs['R'][1]}", "--dep", f"other={r_x_dot}", "--pionc", args.pionc])
        with open(os.path.join(r9_same_out, "src", "main.pion"), "w") as f:
            f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_r9().to_string())\n  0\n}\n")
        r9_pn = run_cmd([args.pionc, "run", r9_same_out]).stdout.strip()
        r9_pw = run_cmd([args.pionc, "run", "--target", "wasm32", r9_same_out]).stdout.strip()
        assert r9_pn == "2" and r9_pw == "2", f"R9 same canonical dir (/./) mismatch: nat={r9_pn!r} wasm={r9_pw!r}"
        print("[f6-1-oracle] PASS R9 P1-2 identical files_sha256 different dirs fail closed; same canonical dir (/./) == 2")

        # 3a-8. R12 P1 #3: pure package with ZERO error keywords testing top-level let, default param, and interpolation `false == true is _`
        pure_m = os.path.join(work, "pure_is_moon")
        for sub in ("pure", "cmd"):
            os.makedirs(os.path.join(pure_m, sub))
        pure_src = (
            "let flag : Bool = false == true is _\n"
            "fn val1(x? : Bool = false == true is _) -> Bool { x }\n"
            'pub fn run_pure() -> String {\n'
            '  let a = if flag { 1 } else { 0 }\n'
            '  let b = if val1() { 1 } else { 0 }\n'
            '  let c = "\\{false == true is _}".length()\n'
            '  a.to_string() + "," + b.to_string() + "," + c.to_string()\n'
            '}\n'
        )
        for rel, txt in [
            ("moon.mod", 'name = "f6/pure"\n'),
            ("pure/moon.pkg", "\n"),
            ("pure/pure.mbt", pure_src),
            ("cmd/moon.pkg", 'import { "f6/pure/pure" }\noptions("is-main": true)\n'),
            ("cmd/main.mbt", "fn main { println(@pure.run_pure()) }\n"),
        ]:
            with open(os.path.join(pure_m, rel), "w") as f:
                f.write(txt)
        pure_mn = run_cmd([args.moon, "run", "--target", "native", "cmd"], cwd=pure_m).stdout.strip()
        pure_mw = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=pure_m).stdout.strip()
        assert pure_mn == "0,0,5" and pure_mw == "0,0,5", f"R12 pure pkg Moon mismatch: nat={pure_mn!r} wgc={pure_mw!r}"

        pure_pout = os.path.join(work, "pure_is_pion")
        os.makedirs(os.path.join(pure_pout, "src"))
        with open(os.path.join(pure_pout, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "pure"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(pure_m, "pure"), "--out", os.path.join(pure_pout, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        with open(os.path.join(pure_pout, "src", "main.pion"), "w") as f:
            f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_pure())\n  0\n}\n")
        pure_pn = run_cmd([args.pionc, "run", pure_pout]).stdout.strip()
        pure_pw = run_cmd([args.pionc, "run", "--target", "wasm32", pure_pout]).stdout.strip()
        assert pure_pn == "0,0,5" and pure_pw == "0,0,5", f"R12 pure pkg Pion mismatch: nat={pure_pn!r} wasm={pure_pw!r}"
        print("[f6-1-oracle] PASS R12 P1 #3 pure no-error-keyword pkg (top-level let, default param, interp): 4-target == 0,0,5")

        # 3b. Legacy `try?` + `try!` publish & Pion native == Pion wasm32 execution check
        tq_src = os.path.join(work, "tq_src")
        tq_out = os.path.join(work, "tq_out")
        os.makedirs(tq_src)
        os.makedirs(os.path.join(tq_out, "src"))
        with open(os.path.join(tq_src, "moon.pkg"), "w") as f:
            f.write("\n")
        with open(os.path.join(tq_src, "tq.mbt"), "w") as f:
            f.write(
                "priv suberror E { Bad(Int) }\n"
                "fn check_e(x : Int) -> Int raise E { if x < 0 { raise Bad(x * -1) }; x + 1 }\n"
                "pub fn run_tq() -> String {\n"
                "  let a = match (try? check_e(4)) { Ok(v) => v; Err(_) => -1 }\n"
                "  let b = match (try? check_e(-3)) { Ok(v) => v; Err(Bad(n)) => n + 100 }\n"
                "  let c = try! check_e(6)\n"
                "  a.to_string() + \",\" + b.to_string() + \",\" + c.to_string()\n"
                "}\n"
            )
        with open(os.path.join(tq_out, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "tq"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", tq_src, "--out", os.path.join(tq_out, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        with open(os.path.join(tq_out, "src", "main.pion"), "w") as f:
            f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_tq())\n  0\n}\n")
        tq_nat = run_cmd([args.pionc, "run", tq_out]).stdout.strip()
        tq_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", tq_out]).stdout.strip()
        assert tq_nat == "5,103,7" and tq_wasm == "5,103,7", f"try?/try! mismatch: nat={tq_nat!r} wasm={tq_wasm!r}"
        print("[f6-1-oracle] PASS: legacy `try?` + `try!` publish (pion native == pion wasm32): " + tq_nat)

        # 4. Negative fail-closed cases: publish MUST exit non-0 and report MBT2PION_UNSUPPORTED_SYNTAX
        for name, src in NEGATIVE_CASES:
            nsrc = os.path.join(work, f"neg_{name}_src")
            nout = os.path.join(work, f"neg_{name}_out")
            os.makedirs(nsrc)
            os.makedirs(nout)
            with open(os.path.join(nsrc, "moon.pkg"), "w") as f:
                f.write("\n")
            with open(os.path.join(nsrc, "neg.mbt"), "w") as f:
                f.write(src)
            res = run_cmd(
                [bin_path, "--src", nsrc, "--out", nout, "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc],
                check=False,
            )
            combined = res.stdout + "\n" + res.stderr
            rep_path = os.path.join(nout, "migration_report.json")
            if os.path.isfile(rep_path):
                combined += "\n" + open(rep_path).read()
            assert res.returncode != 0, f"Negative case `{name}` unexpectedly exited 0!\n{combined}"
            assert "MBT2PION_UNSUPPORTED_SYNTAX" in combined, f"Negative case `{name}` missing MBT2PION_UNSUPPORTED_SYNTAX!\n{combined}"
            print(f"[f6-1-oracle] PASS negative fail-closed: {name}")

        print(f"[f6-1-oracle] ALL PASS (4-target positive + {len(NEGATIVE_CASES)} negative fail-closed cases)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
