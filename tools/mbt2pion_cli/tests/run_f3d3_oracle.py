#!/usr/bin/env python3
r"""Wave M2-F3d-3 3-Engine Differential Oracle: Moon wasm-gc == Pion native == Pion wasm32.

Covers (a two-package project: `f3d3dep` transpiled first, then `f3d3` against it via `--dep`):
  1. `if`/`guard <expr> is <struct-pat> [as alias] && <cond>`:
     - scrutinee evaluated exactly once (event log)
     - pattern failure never evaluates RHS; multiple `&&` short-circuit left-to-right
     - `else` and `guard ... else { return/break/continue }` never see `is` binders (outer var preserved)
     - `as` preserves exact object identity
  2. `match` guard `Some(x) if <guard>` + `Int::to_char()`:
     - `Int::to_char()` across ASCII, astral, negative, surrogate, and >0x10FFFF
     - guard mutating matched object & guard-false fallthrough restoring outer shadowed variable
  3. Struct update `{ ..base, field: val }`:
     - cross-package `@f3d3dep.FlipItem` updated via `items.get(prev) is Some(it)` + `items[prev] = { ..it, off: ... }`
       despite local decoy `LaidFacts` sharing field `off`
     - evaluation order log for base and override fields + alias mutation
  4. `autofill_loc`:
     - generic `#callsite(autofill(loc)) pub fn[T]` followed by `pub let` and `pub fn` without `loc`
     - explicit `loc=` vs autofilled `loc`, cross-file calls asserting callsite file & line
  5. Exhaustive array slice `match`:
     - `[] / [x, ..]`, `[] / [.., last]`, `[] / [a] / [a, b, ..]`
  6. `Array::push_iter(keep.iter())`:
     - `let keep = arr[2:].to_owned(); arr.clear(); arr.push_iter(keep.iter())` + self-append
Negative cases (must fail closed and leave `--out` empty):
  - Struct update with unknown base + local `LaidFacts` decoy -> `MBT2PION_AMBIGUOUS_STRUCT_UPDATE`
  - Non-exhaustive array matches (`[Some(x), ..]`, `[x, ..] if cond`, missing len 1) -> `E_NON_EXHAUSTIVE`
  - `push_iter` with mapped iterator / custom `Evil::iter()` -> `MBT2PION_ARRAY_ITER_MUTATION`
"""
import argparse, os, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

DEP_MBT = r'''
pub(all) struct FlipItem {
  off : (Double, Double, Double, Double)
  v : (Double, Double, Double, Double)
}

pub(all) struct Boxed {
  mut a : Int
  b : Int
  c : Int
}

#callsite(autofill(loc))
pub fn[T] dep_loc_fn(x : T, loc~ : SourceLoc) -> (T, String) {
  (x, loc.to_string())
}

pub let dep_sep : String = ":"

pub fn dep_plain(x : Int) -> Int {
  x * 3
}
'''

F3D3_MBT = r'''
priv struct Way {
  px : Double
  h : Double
}

priv struct Fling {
  mut tag : Int
  v0 : Double
  end_t : Double
  till : Double
  way : Way?
}

// 1. `if`/`guard <expr> is <struct-pat> [as alias] && <cond>`
pub fn run_f3d3_1() -> String {
  let log : Array[String] = []
  let get_opt = fn(f : Fling?, label : String) -> Fling? {
    log.push("scrut:" + label)
    f
  }
  let check_rhs = fn(label : String, res : Bool) -> Bool {
    log.push("rhs:" + label)
    res
  }
  let f_ok : Fling = { tag: 1, v0: 5.0, end_t: 10.0, till: 2.0, way: Some({ px: 12.0, h: 4.0 }) }
  let f_no_way : Fling = { tag: 2, v0: 5.0, end_t: 10.0, till: 2.0, way: None }

  // Outer `v0` must be visible in `else` (not shadowed by `is` binder!)
  let v0 = 999
  let r1 = if get_opt(Some(f_ok), "1") is Some({ v0, way: Some(_), .. }) && check_rhs("1a", v0 > 0.0) && check_rhs("1b", v0 < 10.0) {
    v0.to_int()
  } else {
    v0
  }
  // Pattern fails -> RHS must NEVER run, `else` sees outer `v0 == 999`
  let r2 = if get_opt(Some(f_no_way), "2") is Some({ v0, way: Some(_), .. }) && check_rhs("2a", v0 > 0.0) {
    v0.to_int()
  } else {
    v0
  }
  // First RHS fails -> second RHS must NOT run (left-to-right short-circuit)
  let r3 = if get_opt(Some(f_ok), "3") is Some({ v0, way: Some(_), .. }) && check_rhs("3a", v0 > 100.0) && check_rhs("3b", true) {
    1
  } else {
    v0
  }

  // `guard ... else { return }` + `as` object identity
  let guard_ret = fn(opt : Fling?) -> Int {
    let f = 77
    guard get_opt(opt, "g") is Some({ way: Some(w), .. } as f) && check_rhs("ga", f.v0 > 0.0) else {
      return f
    }
    f.tag = f.tag + 10
    (w.px / w.h).to_int() + f.tag
  }
  let gr1 = guard_ret(Some(f_ok))
  let gr2 = guard_ret(Some(f_no_way))

  // `guard ... else { continue }` & `guard ... else { break }`
  let items : Array[Fling?] = [Some(f_no_way), Some(f_ok), None, Some(f_ok)]
  let mut acc = 0
  for item in items {
    guard item is Some({ way: Some(w), .. } as f) && f.v0 > 0.0 else {
      if item is None { break }
      continue
    }
    acc = acc + (w.px / w.h).to_int()
  }

  // `if <is-chain> ... else if ... else` + double-diverging `if <is-chain> { return } else { return }`
  let eie_fn = fn(opt : Fling?, flag : Bool) -> Int {
    if opt is Some({ v0, .. }) && v0 > 10.0 {
      1
    } else if flag {
      2
    } else {
      3
    }
  }
  let dd_fn = fn(opt : Fling?) -> Int {
    if opt is Some({ v0, .. }) && v0 > 0.0 {
      return 11
    } else {
      return 22
    }
  }
  let eie_res = eie_fn(Some(f_ok), true).to_string() + "," + eie_fn(Some(f_ok), false).to_string()
  let dd_res = dd_fn(Some(f_ok)).to_string() + "," + dd_fn(None).to_string()

  // `.filter` / `.each` closure expected-type isolation
  let flings : Array[Fling] = [f_ok, f_no_way]
  let kept = flings.filter(fn(x) { x.way is Some(_) })
  let mut ksum = 0
  kept.each(fn(x) { ksum = ksum + x.tag })

  // `f_ok.tag` should be 11 (proving `as f` preserved identity!)
  r1.to_string() + "," + r2.to_string() + "," + r3.to_string() + "|" +
  gr1.to_string() + "," + gr2.to_string() + "," + f_ok.tag.to_string() + "|" +
  acc.to_string() + "|" + eie_res + "|" + dd_res + "," + ksum.to_string() + "|" + log.join(",")
}

// 2. `match` guard `Some(x) if <guard>` + `Int::to_char()`
priv struct Rec {
  mut gen : Int
  w : Double
}

fn keycap(c : Int) -> String {
  match (c - 1000).to_char() {
    Some(ch) if ch >= 'a' && ch <= 'z' => (ch.to_int() - 32).unsafe_to_char().to_string()
    Some(ch) if c > 1032 && ch != '\u{7f}' => ch.to_string()
    _ => "#" + c.to_string()
  }
}

pub fn run_f3d3_2() -> String {
  let caps = keycap(1097) + "," + keycap(1065) + "," + keycap(1127) + "," + keycap(999) + "," + keycap(0xD800 + 1000) + "," + keycap(0x110000 + 1000)

  // Shadowing outer tuple `b` in `Some(b) if b.gen == ...` and restoring outer `b` when guard fails
  let m : Map[Int, Rec] = Map::new()
  let r_hit : Rec = { gen: 5, w: 2.5 }
  let r_miss : Rec = { gen: 1, w: 9.0 }
  m[1] = r_hit
  m[2] = r_miss
  let flip : Map[Int, (Int, Map[Int, Rec])] = Map::new()
  flip[1] = (10, m)
  flip[2] = (20, m)

  let out : Array[String] = []
  for k, b in flip {
    let inner = b.1
    let res = match inner.get(k) {
      Some(b) if { let old_g = b.gen; b.gen = b.gen + 100; old_g == 5 } => "hit:" + b.gen.to_string() + ":" + b.w.to_int().to_string()
      _ => "miss:" + b.0.to_string()
    }
    out.push(res)
  }
  caps + "|" + out.join(",") + "|" + r_hit.gen.to_string() + "," + r_miss.gen.to_string()
}

// 3. Struct update `{ ..base, field: val }` with local decoy `LaidFacts` sharing field `off`
priv struct LaidFacts {
  off : Int
  extra : Int
}

priv struct LocalBoxed {
  mut a : Int
  b : Int
  c : Int
}

pub fn run_f3d3_3() -> String {
  let _decoy : LaidFacts = { off: 1, extra: 2 }
  let items : Map[Int, @f3d3dep.FlipItem] = Map::new()
  items[7] = { off: (1.0, 2.0, 3.0, 4.0), v: (5.0, 6.0, 7.0, 8.0) }
  if items.get(7) is Some(it) {
    items[7] = { ..it, off: (it.off.0, it.off.1, it.off.2, 0.0) }
  }
  let updated = items.get(7).unwrap()

  // Evaluation order log for local `{ ..base(), b: v_b(), c: v_c() }` (in field order, with alias mutation)
  let log : Array[String] = []
  let s0 : LocalBoxed = { a: 10, b: 20, c: 30 }
  let r : LocalBoxed = {
    ..{ log.push("base"); s0 },
    b: { log.push("b"); s0.a = 77; 200 },
    c: { log.push("c"); 300 },
  }
  updated.off.0.to_int().to_string() + "," + updated.off.3.to_int().to_string() + "," + updated.v.0.to_int().to_string() + "|" +
  log.join(",") + ":" + r.a.to_string() + "," + r.b.to_string() + "," + r.c.to_string() + ":" + s0.a.to_string()
}

// 4. `autofill_loc` isolation + explicit `loc=` + cross-package call
#callsite(autofill(loc))
pub fn[T] local_loc(x : T, loc~ : SourceLoc) -> (T, String) {
  (x, loc.to_string())
}

pub let local_sep : String = "-"

pub fn local_plain(x : Int) -> Int {
  x + 5
}

#callsite(autofill(loc))
#deprecated("stacked attr test")
fn capture_loc(loc~ : SourceLoc) -> SourceLoc {
  loc
}

pub fn run_f3d3_4() -> String {
  let cap = capture_loc()
  let (a, la) = local_loc(1)
  let (b, lb) = @f3d3dep.dep_loc_fn(2)
  let (c, lc) = local_loc(3, loc=cap)
  let p1 = local_plain(10)
  let p2 = @f3d3dep.dep_plain(4)
  let has_file = la.contains("f3d3.mbt") && lb.contains("f3d3.mbt")
  let diff_line = la != lb
  let explicit_same = lc == cap.to_string()
  a.to_string() + "," + b.to_string() + "," + c.to_string() + "|" +
  p1.to_string() + "," + p2.to_string() + "|" +
  has_file.to_string() + "," + diff_line.to_string() + "," + explicit_same.to_string()
}

// 5. Exhaustive array slice `match`
fn first_or(xs : Array[Int]) -> Int {
  match xs {
    [x, ..] => x
    [] => -1
  }
}

fn last_or(xs : Array[Int]) -> Int {
  match xs {
    [.., last] => last
    [] => -2
  }
}

fn three_way(xs : Array[Int]) -> Int {
  match xs {
    [] => 0
    [a] => a * 10
    [a, b, ..] => a * 100 + b
  }
}

pub fn run_f3d3_5() -> String {
  first_or([]).to_string() + "," + first_or([4, 5]).to_string() + "|" +
  last_or([]).to_string() + "," + last_or([4, 9]).to_string() + "|" +
  three_way([]).to_string() + "," + three_way([3]).to_string() + "," + three_way([3, 7, 9]).to_string()
}

// 6. `Array::push_iter(keep.iter())` + self-append
pub fn run_f3d3_6() -> String {
  let xs : Array[Int] = [1, 2, 3, 4, 5]
  let keep = xs[2:].to_owned()
  xs.clear()
  xs.push_iter(keep.iter())
  let ys : Array[Int] = [7, 8]
  ys.push_iter(ys.iter())
  xs.map(fn(x) { x.to_string() }).join(",") + "|" + ys.map(fn(x) { x.to_string() }).join(",")
}

// 7. Astra 5 adversarial regressions (3-engine parity)
priv struct LocalR {
  mut a : Int
  mut b : Int
  c : Int
}

priv struct PairAB {
  a : Int
  b : Int
}

priv struct ValFields {
  val : Int
  val_ : Int
}

priv struct StrBox {
  x : String
}

pub fn run_f3d3_7() -> String {
  // P1-1: local out-of-order & in-order effectful struct updates
  let s1 : LocalR = { a: 1, b: 2, c: 3 }
  let t1 = { ..s1, c: { s1.a = 8; 6 }, b: { s1.a = 9; 5 } }
  let s2 : LocalR = { a: 1, b: 2, c: 3 }
  let t2 = { ..s2, a: { s2.b = 88; 10 }, c: { s2.b = 99; 30 } }

  // P1-2: shadowed `panic(...)` must NOT be treated as diverging (else must NOT run)
  let panic = fn(_s : String) -> Unit { () }
  let v_p : PairAB? = Some({ a: 1, b: 2 })
  let mut n_p = 0
  if v_p is Some({ a, .. }) && a > 0 {
    n_p = 1
    panic("done")
  } else {
    n_p = 2
  }

  // P1-3: `val` binder vs outer `val_` and sibling `val_`
  let val_ = 9
  let vb1 = if v_p is Some({ a: val, .. }) && val > 0 { val * 10 + val_ } else { 0 }
  let vb2 = if v_p is Some({ a: val, b: val_ }) && val > 0 { val * 10 + val_ } else { 0 }

  // P1-4: `{ val: a, val_: b }` distinct field access
  let vf : ValFields? = Some({ val: 1, val_: 9 })
  let vf_r = if vf is Some({ val: a, val_: b }) && true { a * 10 + b } else { 0 }

  // P1-5: guard condition containing literal `"__MBT_GUARD_LEAF_TUPLE__"`
  let gs_fn = fn(v : StrBox?) -> String {
    guard v is Some({ x, .. }) && x == "__MBT_GUARD_LEAF_TUPLE__" else {
      return "miss"
    }
    "hit"
  }
  let gs_r = gs_fn(Some({ x: "__MBT_GUARD_LEAF_TUPLE__" }))

  t1.a.to_string() + "," + t2.b.to_string() + "|" +
  n_p.to_string() + "|" +
  vb1.to_string() + "," + vb2.to_string() + "|" +
  vf_r.to_string() + "|" + gs_r
}

pub fn run_all() -> String {
  "F3d3-1:" + run_f3d3_1() + "\n" +
  "F3d3-2:" + run_f3d3_2() + "\n" +
  "F3d3-3:" + run_f3d3_3() + "\n" +
  "F3d3-4:" + run_f3d3_4() + "\n" +
  "F3d3-5:" + run_f3d3_5() + "\n" +
  "F3d3-6:" + run_f3d3_6() + "\n" +
  "F3d3-7:" + run_f3d3_7()
}
'''

NEG_AMBIG_SU_MBT = r'''
priv struct LaidFacts {
  off : Int
  extra : Int
}

pub fn bad_su(x : Int) -> Int {
  let _d : LaidFacts = { off: x, extra: 0 }
  let unk = unknown_fn()
  let r = { ..unk, off: 9 }
  r.off
}
'''

NEG_ARR_REFUT_MBT = r'''
pub fn f(xs : Array[Int?]) -> Int {
  match xs {
    [Some(x), ..] => x
    [] => 0
  }
}
'''

NEG_ARR_GUARD_MBT = r'''
pub fn f(xs : Array[Int]) -> Int {
  match xs {
    [x, ..] if x > 0 => x
    [] => 0
  }
}
'''

NEG_ARR_GAP_MBT = r'''
pub fn f(xs : Array[Int]) -> Int {
  match xs {
    [a, b, ..] => a + b
    [] => 0
  }
}
'''

NEG_PUSH_ITER_MAP_MBT = r'''
pub fn f(xs : Array[Int]) -> Unit {
  xs.push_iter(xs.iter().map(fn(x) { x + 1 }))
}
'''

NEG_PUSH_ITER_CUSTOM_MBT = r'''
priv struct Evil {
  xs : Array[Int]
}

fn Evil::iter(self : Evil) -> Iter[Int] {
  self.xs.iter()
}

pub fn f(xs : Array[Int], e : Evil) -> Unit {
  xs.push_iter(e.iter())
}
'''

NEG_PIPE_AS_MBT = r'''
priv enum E {
  A(Int)
  B(Int)
}

pub fn f(e : E) -> Int {
  if e is (A(v) as x | B(v) as x) {
    let _ = x
    v
  } else {
    0
  }
}
'''

NEG_NESTED_AS_MBT = r'''
pub fn f(opt : Int?) -> Int {
  if opt is Some(x as y) && y > 0 {
    x
  } else {
    0
  }
}
'''

NEG_FOREIGN_EFFECT_SU_MBT = r'''
pub fn f(s : @f3d3dep.Boxed) -> Int {
  let t = { ..s, c: { s.a = 8; 6 }, b: { s.a = 9; 5 } }
  t.a
}
'''


def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
    if p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
    return p.stdout.strip()


def assert_publish_blocked(bin_path, pionc, work, name, src_text, expect_code):
    sdir = os.path.join(work, f"neg_{name}_src")
    odir = os.path.join(work, f"neg_{name}_out")
    rep = os.path.join(work, f"neg_{name}_report.json")
    os.makedirs(sdir)
    os.makedirs(odir)
    with open(os.path.join(sdir, f"{name}.mbt"), "w") as fh:
        fh.write(src_text)
    p = subprocess.run(
        [bin_path, "--src", sdir, "--out", odir, "--target", "native", "--mode", "publish",
         "--mbt-compat", COMPAT_DIR, "--pionc", pionc, "--report", rep],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300,
    )
    rep_txt = open(rep).read() if os.path.exists(rep) else ""
    combined = p.stdout + "\n" + p.stderr + "\n" + rep_txt
    assert p.returncode != 0 and expect_code in combined, (
        f"negative case `{name}` must block publish with `{expect_code}`:\n{combined}"
    )
    assert not os.listdir(odir), f"blocked publish `{name}` must leave --out empty"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", default=os.environ.get("PIONC", shutil.which("pionc") or os.path.expanduser("~/.pion/bin/pionc")))
    ap.add_argument("--moon", default=os.environ.get("MOON", shutil.which("moon") or os.path.expanduser("~/.moon/bin/moon")))
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="mbt2pion-f3d3-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])

        md = os.path.join(work, "moon_proj")
        for sub in ("f3d3dep", "f3d3", "cmd"):
            os.makedirs(os.path.join(md, sub))
        for rel, txt in [
            ("moon.mod", 'name = "f3d3/oracle"\n'),
            ("f3d3dep/moon.pkg", "\n"),
            ("f3d3dep/dep.mbt", DEP_MBT),
            ("f3d3/moon.pkg", 'import { "f3d3/oracle/f3d3dep" }\n'),
            ("f3d3/f3d3.mbt", F3D3_MBT),
            ("cmd/moon.pkg", 'import { "f3d3/oracle/f3d3" }\npkgtype(kind: "executable")\n'),
            ("cmd/main.mbt", "fn main { println(@f3d3.run_all()) }\n"),
        ]:
            with open(os.path.join(md, rel), "w") as fh:
                fh.write(txt)
        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)

        pd = os.path.join(work, "p_dep")
        os.makedirs(os.path.join(pd, "src"))
        with open(os.path.join(pd, "pion.toml"), "w") as fh:
            fh.write(f'[package]\nname = "f3d3dep"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "f3d3dep"), "--out", os.path.join(pd, "src"),
                 "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])

        pl = os.path.join(work, "p_f3d3")
        os.makedirs(os.path.join(pl, "src"))
        with open(os.path.join(pl, "pion.toml"), "w") as fh:
            fh.write(f'[package]\nname = "f3d3"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nf3d3dep = {{ path = "{pd}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "f3d3"), "--out", os.path.join(pl, "src"),
                 "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
                 "--dep", f"f3d3dep={pd}"])
        with open(os.path.join(pl, "src", "main.pion"), "w") as fh:
            fh.write("pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n")
        pion_native = run_cmd([args.pionc, "run", pl])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", pl])

        expected = (
            "F3d3-1:5,999,999|14,77,11|3|2,3|11,22,11|scrut:1,rhs:1a,rhs:1b,scrut:2,scrut:3,rhs:3a,scrut:g,rhs:ga,scrut:g\n"
            "F3d3-2:A,A,#1127,#999,#56296,#1115112|hit:105:2,miss:20|105,101\n"
            "F3d3-3:1,0,5|base,b,c:10,200,300:77\n"
            "F3d3-4:1,2,3|15,12|true,true,true\n"
            "F3d3-5:-1,4|-2,9|0,30,307\n"
            "F3d3-6:3,4,5|7,8,7,8\n"
            "F3d3-7:9,88|1|19,12|19|hit"
        )
        assert moon_out == expected and pion_native == moon_out and pion_wasm == moon_out, (
            f"MISMATCH:\nEXPECTED:\n{expected}\nMOON:\n{moon_out}\nNATIVE:\n{pion_native}\nWASM32:\n{pion_wasm}"
        )

        # Negative fail-closed gates
        assert_publish_blocked(bin_path, args.pionc, work, "ambig_su", NEG_AMBIG_SU_MBT, "MBT2PION_AMBIGUOUS_STRUCT_UPDATE")
        assert_publish_blocked(bin_path, args.pionc, work, "arr_refut", NEG_ARR_REFUT_MBT, "E_NON_EXHAUSTIVE")
        assert_publish_blocked(bin_path, args.pionc, work, "arr_guard", NEG_ARR_GUARD_MBT, "E_NON_EXHAUSTIVE")
        assert_publish_blocked(bin_path, args.pionc, work, "arr_gap", NEG_ARR_GAP_MBT, "E_NON_EXHAUSTIVE")
        assert_publish_blocked(bin_path, args.pionc, work, "pi_map", NEG_PUSH_ITER_MAP_MBT, "MBT2PION_ARRAY_ITER_MUTATION")
        assert_publish_blocked(bin_path, args.pionc, work, "pi_custom", NEG_PUSH_ITER_CUSTOM_MBT, "MBT2PION_ARRAY_ITER_MUTATION")
        assert_publish_blocked(bin_path, args.pionc, work, "pipe_as", NEG_PIPE_AS_MBT, "MBT2PION_UNSUPPORTED_SYNTAX")
        assert_publish_blocked(bin_path, args.pionc, work, "nested_as", NEG_NESTED_AS_MBT, "MBT2PION_UNSUPPORTED_SYNTAX")

        # Cross-package effectful struct update must fail-closed with MBT2PION_UNSUPPORTED_SYNTAX
        fs_sdir = os.path.join(work, "neg_foreign_su_src")
        fs_odir = os.path.join(work, "neg_foreign_su_out")
        fs_rep = os.path.join(work, "neg_foreign_su_report.json")
        os.makedirs(fs_sdir)
        os.makedirs(fs_odir)
        with open(os.path.join(fs_sdir, "moon.pkg"), "w") as fh:
            fh.write('import { "f3d3/oracle/f3d3dep" }\n')
        with open(os.path.join(fs_sdir, "fsu.mbt"), "w") as fh:
            fh.write(NEG_FOREIGN_EFFECT_SU_MBT)
        p_fsu = subprocess.run(
            [bin_path, "--src", fs_sdir, "--out", fs_odir, "--target", "native", "--mode", "publish",
             "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc, "--dep", f"f3d3dep={pd}", "--report", fs_rep],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300,
        )
        fsu_combined = p_fsu.stdout + "\n" + p_fsu.stderr + "\n" + (open(fs_rep).read() if os.path.exists(fs_rep) else "")
        assert p_fsu.returncode != 0 and "MBT2PION_UNSUPPORTED_SYNTAX" in fsu_combined, (
            f"foreign effectful struct update must fail closed:\n{fsu_combined}"
        )
        assert not os.listdir(fs_odir), "blocked foreign_su publish must leave --out empty"

        print("PASS: Wave M2-F3d-3 3-Engine Differential Oracle (Moon wasm-gc == Pion native == Pion wasm32, 7 positive + 9 negative cases)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
