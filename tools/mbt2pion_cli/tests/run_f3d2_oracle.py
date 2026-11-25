#!/usr/bin/env python3
r"""Wave M2-F3d Track F3d-2 3-Engine Differential Oracle: Moon wasm-gc == Pion native == Pion wasm32.

Covers:
  1. Recursive local `fn` capture inference & lexical identity:
     - `shown_across`-style `let (left, top, w0, h0) = self.rect()` (RHS evaluated strictly once!),
       `left + w0`, `top + h0`, `Ref(1.0e9)`/`Ref(-1.0e9)` final `(lo, hi)` check
     - Outer `let mut` reassignment, two closures sharing the same `Ref`, parameter shadowing,
       inner `let` shadowing, multi-level recursion / returned recursive closure, early `return`,
       typed local closure `let pt = fn(d : Dim) { ... }`
  2. `MBT2PION_AMBIGUOUS_CTOR` expected-type propagation:
     - Two dependency packages with colliding enum & variant names (`dep_a`, `dep_b`), aliases
     - Cross-package & local calls: positional vs out-of-order named args & omitted optional params,
       generic call parameter substitution, chained method calls
     - Bidirectional `==`/`!=`, struct literal/update/pattern fields, `Some(...)` unwrap
     - Opposite-order `match` sibling arms (patterns + tuple arm bodies), nested `match`,
       `if`/`else` sibling branches, `is (A | B)` OR-patterns
  3. Negative fail-closed publish gates:
     - Uninferrable captured variable in recursive local `fn` refuses publish (no output dir)
     - Contradicting or non-unique sibling `match`/`if` arms refuse publish with `MBT2PION_AMBIGUOUS_CTOR`
"""
import argparse, json, os, shutil, stat, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

DEP_A_MBT = r'''
pub(all) enum Role {
  Button
  Radio
  Separator
}

pub(all) enum Tone {
  Left
  Right
  Center
}

pub fn describe(role : Role, label? : String = "", alt? : Tone = Center) -> String {
  let r = match role {
    Button => "B"
    Radio => "R"
    Separator => "S"
  }
  let t = match alt {
    Left => "L"
    Right => "Ri"
    Center => "C"
  }
  r + ":" + label + ":" + t
}
'''

DEP_B_MBT = r'''
pub(all) enum Role {
  Button
  Radio
}

pub(all) enum Tone {
  Left
  Right
}

pub fn tag_b(role : Role) -> String {
  match role {
    Button => "bB"
    Radio => "bR"
  }
}
'''

EXTRA_LIB_MBT = r'''
let __mbt_cap_2_x : Int = 5
'''

F3D2_MBT = r'''
pub fn astra_cap_alias_collide_demo() -> String {
  let x : Int = 42
  let __mbt_cap_1_x = 0
  fn pick(n : Int) -> Int {
    if n == 0 {
      x
    } else {
      pick(n - 1)
    }
  }
  let _ = __mbt_cap_1_x
  "\{{ let __mbt_cap_1_x_1 = 5; pick(__mbt_cap_1_x_1 - 5) }}"
}

pub fn astra_cross_file_cap_demo() -> String {
  let x : Int = 42
  fn pick(n : Int) -> Int {
    if n == 0 {
      x
    } else {
      pick(n - 1)
    }
  }
  "\{__mbt_cap_2_x}:\{pick(1)}"
}

pub enum Dim {
  Pt(Double)
  Auto
}

pub struct TreeNode {
  x : Double
  y : Double
  w : Double
  h : Double
  kids : Array[Int]
  visible : Bool
}

pub struct TreeBox {
  nodes : Array[TreeNode]
  rect_calls : Ref[Int]
}

fn TreeBox::rect(self : TreeBox) -> (Double, Double, Double, Double) {
  self.rect_calls.val = self.rect_calls.val + 1
  (10.0, 20.0, 100.0, 80.0)
}

pub fn shown_across_demo() -> String {
  let tb : TreeBox = {
    nodes: [
      { x: 0.0, y: 0.0, w: 100.0, h: 80.0, kids: [1, 2, 3], visible: false },
      { x: 15.0, y: 25.0, w: 20.0, h: 10.0, kids: [], visible: true },
      { x: 60.0, y: 40.0, w: 25.0, h: 15.0, kids: [], visible: true },
      { x: 200.0, y: 25.0, w: 10.0, h: 10.0, kids: [], visible: true },
    ],
    rect_calls: Ref(0),
  }
  let (left, top, w0, h0) = tb.rect()
  let right = left + w0
  let foot = top + h0
  let lo = Ref(1.0e9)
  let hi = Ref(-1.0e9)
  let pt = fn(d : Dim) {
    match d {
      Pt(v) => v
      _ => 0.0
    }
  }
  let pad = pt(Pt(2.0))
  fn walk(at : Int) -> Unit {
    let n = tb.nodes[at]
    for k in n.kids {
      walk(k)
    }
    if !n.visible {
      return
    }
    if n.w <= 0.0 || n.h <= 0.0 || n.y + n.h <= top || n.y >= foot || n.x + n.w <= left || n.x >= right {
      return
    }
    let x0 = n.x - pad
    let x1 = n.x + n.w + pad
    if x0 < lo.val {
      lo.val = x0
    }
    if x1 > hi.val {
      hi.val = x1
    }
  }
  walk(0)
  tb.rect_calls.val.to_string() + ":" + lo.val.to_int().to_string() + ":" + hi.val.to_int().to_string()
}

pub fn capture_semantics_demo() -> String {
  // 1. Outer let mut reassigned + parameter shadowing + inner let shadowing
  let mut acc = 0
  let x = 100
  fn sum_down(x : Int) -> Unit {
    if x <= 0 {
      return
    }
    let delta = x * 2
    acc = acc + delta
    sum_down(x - 1)
  }
  sum_down(4)
  // 2. Two closures sharing the same Ref
  let shared = Ref(false)
  let flip = fn() -> Unit { shared.val = !shared.val }
  let read = fn() -> Bool { shared.val }
  flip()
  let r1 = read()
  // 3. Multi-level recursion + returning recursive closure
  let base = Ref(10)
  fn make_adder() -> (Int) -> Int {
    fn rec(n : Int) -> Int {
      if n <= 0 {
        return base.val
      }
      n + rec(n - 1)
    }
    rec
  }
  let adder = make_adder()
  let v1 = adder(3)
  base.val = 20
  let v2 = adder(3)
  x.to_string() + "," + acc.to_string() + "," + r1.to_string() + "," + v1.to_string() + "," + v2.to_string()
}

#derive(Eq)
pub enum Side {
  Below
  Above
  Left
  Right
}

pub enum Axis {
  Left
  Right
}

pub enum HoldRes {
  Ready
  Cancelled
}

pub enum HoldRd {
  Waiting
  Cancelled
}

pub enum Along {
  Start
  Middle
  End
}

pub enum Align {
  Start
  Middle
  End
}

pub enum Live[T] {
  Is(T)
  By(() -> T)
}

pub struct Panel {
  mut side : Side
  mut along : Along
}

fn Panel::set_side(self : Panel, s : Live[Side]) -> Panel {
  match s {
    Is(v) => self.side = v
    By(f) => self.side = f()
  }
  self
}

fn Panel::set_along(self : Panel, a : Live[Along?]) -> Panel {
  match a {
    Is(Some(v)) => self.along = v
    _ => ()
  }
  self
}

fn[T] Panel::apply_live(self : Panel, live : Live[T], f : (T) -> Unit) -> Panel {
  match live {
    Is(v) => f(v)
    By(g) => f(g())
  }
  self
}

fn side_code(s : Side) -> String {
  match s {
    Below => "B"
    Above => "A"
    Left => "L"
    Right => "R"
  }
}

pub fn ctor_expect_demo() -> String {
  // 1. Cross-package colliding enums + out-of-order named args + omitted optional
  let c1 = @dep_a.describe(alt=Right, Separator, label="sp")
  let c2 = @dep_a.describe(Button)
  let c3 = @dep_b.tag_b(Radio)
  // 2. Opposite-order match sibling arms (both patterns and tuple bodies!) + nested match
  let flip_side = fn(s : Side) -> (Int, Side) {
    match s {
      Right => (1, Left)
      Left => (2, Right)
      Below => (3, Above)
      Above => (4, Below)
    }
  }
  let (n1, s1) = flip_side(Right)
  let (n2, s2) = flip_side(Below)
  // 3. if/else sibling branches
  let h1 = if false { Ready } else { Cancelled }
  let hs = match h1 {
    Ready => "R"
    Cancelled => "C"
  }
  // 4. == / != and is (A | B)
  let eq_ok = (s1 == Left) && (s1 != Right) && (s2 is (Above | Right))
  // 5. Chained methods + generic enum Is(Some(Middle)) + generic call bind
  let p : Panel = { side: Below, along: Start }
  let _ = p.set_side(Is(Left)).set_along(Is(Some(Middle)))
  let picked = Ref("")
  let live_opt : Live[Along?] = Is(Some(End))
  let _ = p.apply_live(live_opt, fn(a) {
    match a {
      None => picked.val = "N"
      Some(Start) => picked.val = "S"
      Some(Middle) => picked.val = "M"
      Some(End) => picked.val = "E"
    }
  })
  c1 + "|" + c2 + "|" + c3 + "|" +
    n1.to_string() + side_code(s1) + n2.to_string() + side_code(s2) + "|" +
    hs + "|" + eq_ok.to_string() + "|" + side_code(p.side) + picked.val
}

let pkg_shadow_x : Int = 3

pub fn astra_callsite_shadow_demo() -> Int {
  let x = 30 + 12
  fn pick(n : Int) -> Int {
    if n == 0 {
      x
    } else {
      pick(n - 1)
    }
  }
  {
    let x = 5
    pick(x - 5)
  }
}

pub fn astra_interp_capture_demo() -> String {
  let pkg_shadow_x : Int = 42
  fn pick(n : Int) -> String {
    let _ = fn(pkg_shadow_x : Int) { pkg_shadow_x }
    if n == 0 {
      "\{pkg_shadow_x}"
    } else {
      pick(n - 1)
    }
  }
  pick(1)
}

pub fn astra_mut_interp_demo() -> String {
  let mut x : Int = 42
  fn pick(n : Int) -> String {
    if n == 0 {
      "\{x}"
    } else {
      pick(n - 1)
    }
  }
  x = 9
  pick(1)
}

pub fn run_all() -> String {
  "F3d2-1:" + shown_across_demo() +
    "\nF3d2-2:" + capture_semantics_demo() +
    "\nF3d2-3:" + ctor_expect_demo() +
    "\nF3d2-4:" + astra_callsite_shadow_demo().to_string() + "," + astra_interp_capture_demo() +
    "\nF3d2-5:" + astra_mut_interp_demo() + "," + astra_cap_alias_collide_demo() + "," + astra_cross_file_cap_demo()
}
'''

NEG_UNKNOWN_CAPTURE = r'''
pub fn bad_lift(n : Int) -> Int {
  let opaque_v = ext_opaque()
  fn walk(k : Int) -> Int {
    if k <= 0 { return opaque_v }
    walk(k - 1)
  }
  walk(n)
}
'''

NEG_CONTRADICT_SIBLING = r'''
pub enum Side { Below; Above; Left; Right }
pub enum Axis { Left; Right }
pub fn bad_sib(x : Int) -> Int {
  let _ = match x {
    0 => 42
    1 => Below
    _ => Left
  }
  0
}
'''

NEG_NON_UNIQUE_SIBLING = r'''
pub enum Side { Below; Above; Left; Right }
pub enum Axis { Left; Right }
pub fn bad_nu(b : Bool) -> Int {
  let _ = if b { Left } else { Right }
  0
}
'''


def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
    if p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
    return p.stdout.strip()


def assert_publish_refused(bin_path, pionc, work, name, src_text, expect_code=None):
    src_dir = os.path.join(work, f"neg_{name}_src")
    out_dir = os.path.join(work, f"neg_{name}_out")
    rep_path = os.path.join(work, f"neg_{name}_rep.json")
    os.makedirs(src_dir, exist_ok=True)
    open(os.path.join(src_dir, f"{name}.mbt"), "w").write(src_text)
    p = subprocess.run(
        [bin_path, "--src", src_dir, "--out", out_dir, "--mode", "publish",
         "--mbt-compat", COMPAT_DIR, "--pionc", pionc, "--report", rep_path, "--no-fmt"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=120,
    )
    assert p.returncode != 0, f"negative `{name}` unexpectedly succeeded!"
    assert not os.path.exists(out_dir), f"negative `{name}` must NOT publish output dir!"
    if expect_code is not None:
        rep = json.load(open(rep_path))
        codes = [d.get("code") for d in rep.get("diagnostics", [])]
        assert expect_code in codes, f"negative `{name}` expected {expect_code}, got {codes}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", default=os.environ.get("PIONC", shutil.which("pionc") or os.path.expanduser("~/.pion/bin/pionc")))
    ap.add_argument("--moon", default=os.environ.get("MOON", shutil.which("moon") or os.path.expanduser("~/.moon/bin/moon")))
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="mbt2pion-f3d2-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])

        # 1. MoonBit multi-package project (dep_a, dep_b, lib, cmd)
        md = os.path.join(work, "moon_proj")
        for sub in ("dep_a", "dep_b", "lib", "cmd"):
            os.makedirs(os.path.join(md, sub))
        for rel, txt in [
            ("moon.mod", 'name = "f3d2/oracle"\n'),
            ("dep_a/moon.pkg", "\n"),
            ("dep_a/dep_a.mbt", DEP_A_MBT),
            ("dep_b/moon.pkg", "\n"),
            ("dep_b/dep_b.mbt", DEP_B_MBT),
            ("lib/moon.pkg", 'import {\n  "f3d2/oracle/dep_a",\n  "f3d2/oracle/dep_b",\n}\n'),
            ("lib/extra.mbt", EXTRA_LIB_MBT),
            ("lib/f3d2.mbt", F3D2_MBT),
            ("cmd/moon.pkg", 'import { "f3d2/oracle/lib" }\npkgtype(kind: "executable")\n'),
            ("cmd/main.mbt", 'fn main { println(@lib.run_all()) }\n'),
        ]:
            open(os.path.join(md, rel), "w").write(txt)
        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)

        # 2. Transpile dep_a, dep_b, and lib to Pion in dependency order
        p_dep_a = os.path.join(work, "p_dep_a")
        p_dep_b = os.path.join(work, "p_dep_b")
        p_lib = os.path.join(work, "p_lib")
        for d, name in [(p_dep_a, "dep_a"), (p_dep_b, "dep_b")]:
            os.makedirs(os.path.join(d, "src"))
            open(os.path.join(d, "pion.toml"), "w").write(
                f'[package]\nname = "{name}"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
            )
            run_cmd([
                bin_path, "--src", os.path.join(md, name), "--out", os.path.join(d, "src"),
                "--package-manifest", os.path.join(d, "pion.toml"),
                "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
            ])

        os.makedirs(os.path.join(p_lib, "src"))
        open(os.path.join(p_lib, "pion.toml"), "w").write(
            f'[package]\nname = "f3d2lib"\nversion = "0.1.0"\n[dependencies]\n'
            f'mbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
            f'dep_a = {{ path = "{p_dep_a}" }}\n'
            f'dep_b = {{ path = "{p_dep_b}" }}\n'
        )
        run_cmd([
            bin_path, "--src", os.path.join(md, "lib"), "--out", os.path.join(p_lib, "src"),
            "--package-manifest", os.path.join(p_lib, "pion.toml"),
            "--dep", f"dep_a={p_dep_a}", "--dep", f"dep_b={p_dep_b}",
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
        ])
        open(os.path.join(p_lib, "src", "main.pion"), "w").write(
            'pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n'
        )
        pion_native = run_cmd([args.pionc, "run", p_lib])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", p_lib])

        expected = (
            "F3d2-1:1:13:87\n"
            "F3d2-2:100,20,true,16,26\n"
            "F3d2-3:S:sp:Ri|B::C|bR|1L3A|C|true|LE\n"
            "F3d2-4:42,42\n"
            "F3d2-5:9,42,5:42"
        )
        assert moon_out == expected and pion_native == moon_out and pion_wasm == moon_out, (
            f"MISMATCH:\nEXPECTED:\n{expected}\nMOON:\n{moon_out}\nNATIVE:\n{pion_native}\nWASM32:\n{pion_wasm}"
        )

        # 3. Negative fail-closed publish gates
        assert_publish_refused(bin_path, args.pionc, work, "unknown_capture", NEG_UNKNOWN_CAPTURE, "MBT2PION_UNSUPPORTED_SYNTAX")
        assert_publish_refused(bin_path, args.pionc, work, "contradict_sib", NEG_CONTRADICT_SIBLING, "MBT2PION_AMBIGUOUS_CTOR")
        assert_publish_refused(bin_path, args.pionc, work, "non_uniq_sib", NEG_NON_UNIQUE_SIBLING, "MBT2PION_AMBIGUOUS_CTOR")

        print("[f3d2-oracle] PASS: 3-engine (moon wasm-gc == pion-native == pion-wasm32) + 3 fail-closed negative gates!\n" + moon_out)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
