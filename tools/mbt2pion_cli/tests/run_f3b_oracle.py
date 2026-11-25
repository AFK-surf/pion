#!/usr/bin/env python3
r"""Wave M2-F3b 3-Engine Differential Oracle: Moon wasm-gc == Pion native == Pion wasm32.

Covers (a two-package project: `f3dep` transpiled first, then `f3b` against it via `--dep`):
  1. Integer literals in `FixedArray[Byte]` / `Array[Byte]` literals (top-level and local)
  2. Bare constructor arm bodies followed by tuple-pattern arms
  3. Untyped `let f = fn(p) { ... }` closures + `.unwrap_or(1.0)` Float/Double if-else unification
  4. `Show::to_string(x)` for a custom `Show`, `Int`, `Double` and `String`
  5. `@dep.Type::method(.., Alpha)` where the caller also has a private enum with an `Alpha` constructor
  6. `fresh[:]` / `fresh[a:b]` / `fresh[a:]` passed to a dependency's `ArrayView[Int]` parameter
  7. `trim_end(chars=...)` with ASCII, multi-byte, astral and fully-trimmed inputs
Negative cases (must fail closed, never silently change semantics):
  - a borrowed slice of a user `copy()` that returns an alias must block with MBT2PION_BORROWED_ARRAY_SLICE
  - untyped closure params shadowed in the body, used via a field receiver `a.b.m(k)`, or passed next to a named
    argument must never be inferred (here: never as `Int64`)
"""
import argparse, os, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

DEP_MBT = r'''
pub(all) enum MaskType {
  Alpha
  Luminance
}

pub(all) struct Mask {
  v : Int
}

pub fn Mask::from_kind(base : Int, k : MaskType) -> Mask {
  match k {
    Alpha => { v: base + 1 }
    Luminance => { v: base + 2 }
  }
}

pub fn sum_view(xs : ArrayView[Int]) -> Int {
  let mut s = 0
  for i in 0..<xs.length() {
    s = s * 10 + xs[i]
  }
  s * 100 + xs.length()
}
'''

F3B_MBT = r'''
let table : FixedArray[Byte] = [0, 1, 127, 128, 255, 0x10, 0xFF]

fn table_sum() -> Int {
  let small : Array[Byte] = [3, 200]
  let mut s = 0
  for b in table {
    s = s + b.to_int()
  }
  s * 1000 + small[0].to_int() + small[1].to_int()
}

priv enum Mode {
  Alpha
  Other
}

fn mode_code(m : Mode) -> Int {
  match m {
    Alpha => 1
    Other => 2
  }
}

priv enum Kind {
  KStroke
  KFill
  KMarkers
}

priv enum Order {
  FillFirst
  StrokeFirst
}

fn order_of(a : Kind, b : Kind) -> Order {
  match (a, b) {
    (KStroke, _) => StrokeFirst
    (KMarkers, KStroke) => StrokeFirst
    _ => FillFirst
  }
}

fn order_name(o : Order) -> String {
  match o {
    FillFirst => "fill"
    StrokeFirst => "stroke"
  }
}

pub fn run_f3b_1() -> String {
  table_sum().to_string()
}

pub fn run_f3b_2() -> String {
  order_name(order_of(KStroke, KFill)) + "," + order_name(order_of(KMarkers, KStroke)) + "," +
  order_name(order_of(KMarkers, KFill)) + "," + order_name(order_of(KFill, KStroke))
}

priv struct Doc {
  names : Array[String]
  vals : Array[Float]
}

fn Doc::attr(self : Doc, key : String) -> Float? {
  for i, n in self.names {
    if n == key {
      return Some(self.vals[i])
    }
  }
  None
}

fn centi(f : Float) -> String {
  (f.to_double() * 100.0).to_int().to_string()
}

fn spec(doc : Doc) -> String {
  let n = fn(k) { doc.attr(k).unwrap_or(0.0) }
  let pick = fn(k) -> Int {
    match doc.attr(k) {
      Some(_) => 1
      None => 0
    }
  }
  let e = doc.attr("e").unwrap_or(1.0)
  let e = if e >= 0.0 { e } else { 1.0 }
  centi(n("x")) + "," + centi(n("missing")) + "," + pick("y").to_string() + pick("zz").to_string() + "," + centi(e)
}

pub fn run_f3b_3() -> String {
  let a : Doc = { names: ["x", "y", "e"], vals: [1.25, 2.5, -3.0] }
  let b : Doc = { names: ["e"], vals: [0.5] }
  spec(a) + "|" + spec(b)
}

priv enum Fam {
  Serif
  Named(String)
}

impl Show for Fam with output(self, logger) {
  match self {
    Serif => logger.write_string("Serif")
    Named(s) => {
      logger.write_string("Named(")
      logger.write_string(s)
      logger.write_string(")")
    }
  }
}

pub fn run_f3b_4() -> String {
  let fams = [Serif, Named("Inter")]
  let sb = StringBuilder()
  for f in fams {
    sb.write_string(Show::to_string(f))
    sb.write_char('|')
  }
  sb.write_string(Show::to_string(42))
  sb.write_char('|')
  sb.write_string(Show::to_string(1.5))
  sb.write_char('|')
  sb.write_string(Show::to_string(0.1 + 0.2))
  sb.write_char('|')
  sb.write_string(Show::to_string("ab"))
  sb.to_string()
}

pub fn run_f3b_5() -> String {
  let m = @f3dep.Mask::from_kind(10, Alpha)
  let l = @f3dep.Mask::from_kind(20, Luminance)
  m.v.to_string() + "," + l.v.to_string() + "," + mode_code(Alpha).to_string() + mode_code(Other).to_string()
}

pub fn run_f3b_6() -> String {
  let runs = [(0, 1, 3), (1, 2, 1), (2, 3, 4), (3, 4, 1)]
  let whole = @f3dep.sum_view(runs.map(fn(r) { r.2 })[:])
  let mid = @f3dep.sum_view(runs.map(fn(r) { r.2 + 1 })[1:3])
  let tail = @f3dep.sum_view(runs.map(fn(r) { r.0 })[2:])
  whole.to_string() + "," + mid.to_string() + "," + tail.to_string()
}

pub fn run_f3b_7() -> String {
  let a = "ab \t\n".trim_end(chars=" \t\n\r").to_owned()
  let b = "abc".trim_end(chars=" ").to_owned()
  let c = "   ".trim_end(chars=" ").to_owned()
  let d = "h\u{e9}llo\u{20ac}\u{20ac}".trim_end(chars="\u{20ac}").to_owned()
  let e = "x\u{e9}".trim_end(chars="\u{e8}").to_owned()
  let f = "A\u{1F600}\u{1F600}".trim_end(chars="\u{1F600}").to_owned()
  "[" + a + "][" + b + "][" + c + "][" + d + "][" + e + "][" + f + "]" + f.length().to_string()
}

fn items(k : Int) -> Array[Int] {
  [k, k + 1, k + 3]
}

pub fn run_f3b_8() -> String {
  let g = fn(k) { let mut n = 0; for x in items(k) { n = n + x }; n }
  g(1).to_string()
}

priv struct Reading {
  f : Float
}

impl Show for Reading with output(self, logger) {
  logger.write_string(self.f.to_string())
}

priv struct ReadingBytes {
  b : Bytes
}

impl Show for ReadingBytes with output(self, logger) {
  logger.write_string(self.b.to_string())
}

pub fn run_f3b_9() -> String {
  let r : Reading = { f: 0.1 }
  let rb : ReadingBytes = { b: b"abc" }
  let fs : Array[Float] = [1.0e-7, 1.0e21, 3.4028235e38, 0.33333334]
  let parts : Array[String] = []
  for f in fs {
    parts.push(f.to_string())
  }
  let half : Float = 2.5
  let nz : Float = -0.0
  let by : Byte = b'a'
  Show::to_string(r) + "|" + Show::to_string(rb) + "|" + Show::to_string((0.1 : Float)) + "|" +
  Show::to_string(b"abc") + "|" + Show::to_string(b'a') + "|" + parts.join(",") + "|" + "\{half}" + "|" +
  nz.to_string() + "|" + b"a\"b\\c\n".to_string() + "|" + by.to_string() + "|" + "\{by}"
}

priv struct Reading2 {
  f : Float
}

impl Show for Reading2 with output(self, logger) {
  logger.write_string("\{self.f + self.f}")
}

fn get_float() -> Float {
  0.1
}

pub fn run_f3b_10() -> String {
  let r : Reading2 = { f: 0.1 }
  let half : Float = 2.5
  let ml =
    $|v=\{half},\{-half}
  Show::to_string(r) + "|" + "\{get_float()}" + "|" + "\{-half}" + "|" + "\{0.1 + 0.2}" + "|" +
  "\{if half > 1.0 { half } else { -half }}" + "|" + ml
}

pub fn run_all() -> String {
  "F3b-1:" + run_f3b_1() + "\nF3b-2:" + run_f3b_2() + "\nF3b-3:" + run_f3b_3() + "\nF3b-4:" + run_f3b_4() +
  "\nF3b-5:" + run_f3b_5() + "\nF3b-6:" + run_f3b_6() + "\nF3b-7:" + run_f3b_7() +
  "\nF3b-8:" + run_f3b_8() + "\nF3b-9:" + run_f3b_9() + "\nF3b-10:" + run_f3b_10()
}
'''


NEG_COPY_MBT = r'''
priv struct Bag {
  values : Array[Int]
}

fn Bag::copy(self : Bag) -> Array[Int] {
  self.values
}

pub fn copy_alias() -> Int {
  let bag : Bag = { values: [1, 2] }
  let v = bag.copy()[0:2]
  bag.values[1] = 9
  v[1]
}
'''

NEG_SHOW_MBT = r'''
pub fn show_array() -> String {
  Show::to_string([1, 2])
}

fn[T : Show] show_generic(x : T) -> String {
  Show::to_string(x)
}

pub fn show_generic_use() -> String {
  show_generic(1)
}
'''

NEG_SHOW_INHERENT_MBT = r'''
priv struct H {
  x : Int
} derive(Show)

fn H::to_string(_self : H) -> String {
  "inherent"
}

pub fn eval_derive() -> String {
  let v : H = { x: 1 }
  Show::to_string(v)
}
'''

NEG_SHOW_BOTH_MBT = r'''
priv struct G {
  x : Int
}

impl Show for G with output(self, logger) {
  logger.write_string("G")
  ignore(self)
}

fn G::to_string(_self : G) -> String {
  "inherent"
}

pub fn eval_impl() -> String {
  let v : G = { x: 1 }
  Show::to_string(v)
}
'''

NEG_CLOSURE_MBT = r'''
fn use_wide(_w : Int64) -> Unit {
  ()
}

pub fn scope_case() -> Int {
  let g = fn(k) { let neg = (k + 1) < 0; { let k = 1L; use_wide(k) }; if neg { 1 } else { 0 } }
  g(2147483647)
}

priv struct Decoy {
  n : Int
}

fn Decoy::touch(self : Decoy, _v : Int64) -> Int {
  self.n
}

priv struct Inner {
  n : Int
}

fn Inner::touch(self : Inner, v : Int) -> Int {
  self.n + v
}

priv struct Parent {
  b : Inner
}

pub fn field_case() -> Int {
  let a : Parent = { b: { n: 0 } }
  let b : Decoy = { n: 0 }
  let g = fn(k) { let neg = (k + 1) < 0; let _ = a.b.touch(k); if neg { 1 } else { 0 } }
  g(2147483647) + b.n
}

fn[X] consume(_v : X, wide~ : Int64) -> Unit {
  ignore(wide)
}

priv struct Child {
  n : Int
}

fn Child::touch(self : Child, v : Int) -> Int {
  self.n + v
}

pub fn sibling_case() -> Int {
  let r : Decoy = { n: 0 }
  let g = fn(k, r : Child) { let neg = (k + 1) < 0; let _ = r.touch(k); if neg { 1 } else { 0 } }
  g(2147483647, { n: 0 }) + r.n
}

fn items64(v : Int64) -> Array[Int64] {
  [v]
}

pub fn loop_let_case() -> Int {
  let g = fn(k) {
    let neg = (k + 1) < 0
    {
      let
        k = 1L
      for x in items64(k) { ignore(x) }
    }
    if neg { 1 } else { 0 }
  }
  g(2147483647)
}

priv struct H {
  k : Int64
}

pub fn struct_let_case() -> Int {
  let h : H = { k: 1L }
  let g = fn(k) {
    let neg = (k + 1) < 0
    let { k } = h
    use_wide(k)
    if neg { 1 } else { 0 }
  }
  g(2147483647)
}

pub fn struct_arm_case(o : H?) -> Int {
  let g = fn(k) {
    let neg = (k + 1) < 0
    match o {
      Some({ k }) => use_wide(k)
      None => ()
    }
    if neg { 1 } else { 0 }
  }
  g(2147483647)
}

pub fn struct_is_case(o : H?) -> Int {
  let g = fn(k) {
    let neg = (k + 1) < 0
    if o is Some({ k }) && k > 0L { use_wide(k) }
    if neg { 1 } else { 0 }
  }
  g(2147483647)
}

pub fn guard_expr_case(o : H?) -> Int {
  let g = fn(k) {
    let neg = (k + 1) < 0
    match o {
      Some({ k }) if 1 >
        0 => use_wide(k)
      _ => ()
    }
    if neg { 1 } else { 0 }
  }
  g(2147483647)
}

pub fn named_case() -> Int {
  let g = fn(k) { let neg = (k + 1) < 0; consume(wide=0L, k); if neg { 1 } else { 0 } }
  g(2147483647)
}
'''


def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
    if p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
    return p.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", default=os.environ.get("PIONC", shutil.which("pionc") or os.path.expanduser("~/.pion/bin/pionc")))
    ap.add_argument("--moon", default=os.environ.get("MOON", shutil.which("moon") or os.path.expanduser("~/.moon/bin/moon")))
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="mbt2pion-f3b-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])
        md = os.path.join(work, "moon_proj")
        for sub in ("f3dep", "f3b", "cmd"):
            os.makedirs(os.path.join(md, sub))
        for rel, txt in [
            ("moon.mod", 'name = "f3b/oracle"\n'),
            ("f3dep/moon.pkg", "\n"),
            ("f3dep/dep.mbt", DEP_MBT),
            ("f3b/moon.pkg", 'import { "f3b/oracle/f3dep" }\n'),
            ("f3b/f3b.mbt", F3B_MBT),
            ("cmd/moon.pkg", 'import { "f3b/oracle/f3b" }\npkgtype(kind: "executable")\n'),
            ("cmd/main.mbt", "fn main { println(@f3b.run_all()) }\n"),
        ]:
            with open(os.path.join(md, rel), "w") as fh:
                fh.write(txt)
        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)

        pd = os.path.join(work, "p_dep")
        os.makedirs(os.path.join(pd, "src"))
        with open(os.path.join(pd, "pion.toml"), "w") as fh:
            fh.write(f'[package]\nname = "f3dep"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "f3dep"), "--out", os.path.join(pd, "src"), "--target", "native",
                 "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])

        pl = os.path.join(work, "p_f3b")
        os.makedirs(os.path.join(pl, "src"))
        with open(os.path.join(pl, "pion.toml"), "w") as fh:
            fh.write(f'[package]\nname = "f3b"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nf3dep = {{ path = "{pd}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "f3b"), "--out", os.path.join(pl, "src"), "--target", "native",
                 "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc, "--dep", f"f3dep={pd}"])
        with open(os.path.join(pl, "src", "main.pion"), "w") as fh:
            fh.write("pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n")
        pion_native = run_cmd([args.pionc, "run", pl])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", pl])

        expected = (
            "F3b-1:782203\n"
            "F3b-2:stroke,stroke,fill,fill\n"
            "F3b-3:125,0,10,100|0,0,00,50\n"
            "F3b-4:Serif|Named(Inter)|42|1.5|0.30000000000000004|ab\n"
            "F3b-5:11,22,12\n"
            "F3b-6:314104,2502,2302\n"
            "F3b-7:[ab][abc][][héllo][xé][A]1\n"
            "F3b-8:7\n"
            "F3b-9:0.1|b\"abc\"|0.1|b\"abc\"|97|1e-7,1e+21,3.4028235e+38,0.33333334|2.5|0|b\"a\\x22b\\x5cc\\x0a\"|97|97\n"
            "F3b-10:0.2|0.1|-2.5|0.30000000000000004|2.5|v=2.5,-2.5"
        )
        assert moon_out == expected and pion_native == moon_out and pion_wasm == moon_out, (
            f"MISMATCH:\nEXPECTED:\n{expected}\nMOON:\n{moon_out}\nNATIVE:\n{pion_native}\nWASM32:\n{pion_wasm}"
        )
        # Negative 1: borrowed slice of an aliasing user `copy()` must fail closed (Moon answers 9 via the alias).
        neg = os.path.join(md, "f3neg")
        os.makedirs(neg)
        with open(os.path.join(neg, "moon.pkg"), "w") as fh:
            fh.write("\n")
        with open(os.path.join(neg, "neg.mbt"), "w") as fh:
            fh.write(NEG_COPY_MBT)
        nout = os.path.join(work, "p_neg", "src")
        os.makedirs(nout)
        p = subprocess.run([bin_path, "--src", neg, "--out", nout, "--target", "native", "--mode", "publish",
                            "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
        assert p.returncode != 0 and "MBT2PION_BORROWED_ARRAY_SLICE" in (p.stdout + p.stderr), (
            f"copy-alias slice must block publish with MBT2PION_BORROWED_ARRAY_SLICE:\n{p.stdout}\n{p.stderr}"
        )
        assert not os.listdir(nout), "blocked publish must not write --out"

        # Negative 1b: `Show::to_string` on a container or an unconstrained generic parameter has no exact
        # lowering and must block publish instead of silently changing output.
        sneg = os.path.join(md, "f3sneg")
        os.makedirs(sneg)
        with open(os.path.join(sneg, "moon.pkg"), "w") as fh:
            fh.write("\n")
        with open(os.path.join(sneg, "neg.mbt"), "w") as fh:
            fh.write(NEG_SHOW_MBT)
        sout = os.path.join(work, "p_sneg", "src")
        os.makedirs(sout)
        p = subprocess.run([bin_path, "--src", sneg, "--out", sout, "--target", "native", "--mode", "publish",
                            "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
        sl = (p.stdout + p.stderr)
        for ty in ("Array[Int]", "T"):
            assert "on type `" + ty + "` has no MoonBit-exact lowering" in sl, f"Show::to_string({ty}) must fail closed:\n{sl}"
        assert p.returncode != 0 and not os.listdir(sout), f"Show::to_string negatives must block publish:\n{sl}"

        # Negative 1c: a user type whose `to_string` is (or may be) an inherent method, not its `Show`:
        # `derive(Show)` ignored by recipes + `fn H::to_string`, and `impl Show` + `fn G::to_string`.
        ineg = os.path.join(md, "f3ineg")
        os.makedirs(ineg)
        with open(os.path.join(ineg, "moon.pkg"), "w") as fh:
            fh.write("\n")
        with open(os.path.join(ineg, "neg.mbt"), "w") as fh:
            fh.write(NEG_SHOW_INHERENT_MBT)
        rec = os.path.join(work, "ignore_show.toml")
        with open(rec, "w") as fh:
            fh.write('[derives]\nignore = ["Show"]\n')
        iout = os.path.join(work, "p_ineg", "src")
        os.makedirs(iout)
        p = subprocess.run([bin_path, "--src", ineg, "--out", iout, "--target", "native", "--mode", "publish",
                            "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc, "--recipes", rec],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
        il = (p.stdout + p.stderr)
        assert p.returncode != 0 and not os.listdir(iout), f"inherent to_string cases must block publish:\n{il}"
        assert "on type `H` has no MoonBit-exact lowering" in il, f"derive(Show)-ignored + inherent H must fail closed:\n{il}"
        bneg = os.path.join(md, "f3bneg")
        os.makedirs(bneg)
        with open(os.path.join(bneg, "moon.pkg"), "w") as fh:
            fh.write("\n")
        with open(os.path.join(bneg, "neg.mbt"), "w") as fh:
            fh.write(NEG_SHOW_BOTH_MBT)
        bout = os.path.join(work, "p_bneg", "src")
        os.makedirs(bout)
        p = subprocess.run([bin_path, "--src", bneg, "--out", bout, "--target", "native", "--mode", "publish",
                            "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
        assert p.returncode != 0 and not os.listdir(bout), (
            "impl Show + inherent G::to_string must block publish:\n" + p.stdout + p.stderr
        )

        # Negative 2: shadowed / field-receiver / named-argument closure params are never inferred.
        cneg = os.path.join(md, "f3cneg")
        os.makedirs(cneg)
        with open(os.path.join(cneg, "moon.pkg"), "w") as fh:
            fh.write("\n")
        with open(os.path.join(cneg, "neg.mbt"), "w") as fh:
            fh.write(NEG_CLOSURE_MBT)
        cout = os.path.join(work, "p_cneg", "src")
        os.makedirs(cout)
        subprocess.run([bin_path, "--src", cneg, "--out", cout, "--target", "native", "--mode", "audit",
                        "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc, "--report", os.path.join(work, "cneg.json")],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
        gen = open(os.path.join(cout, "neg.pion"), encoding="utf-8").read()
        assert gen.count("let g = fn(k) {") == 8 and "let g = fn(k : Int, r : Child) {" in gen and "fn(k : Int64" not in gen, (
            "shadow/field/loop-let/struct-let/struct-arm/struct-is/named closure params must stay unannotated and the sibling one must use `r : Child`:\n" + gen
        )

        print("[f3b-oracle] PASS: 3-engine (moon wasm-gc == pion-native == pion-wasm32) 100% identical!\n" + moon_out)
        print("[f3b-oracle] PASS: negatives fail closed (copy-alias slice blocked; Show::to_string on Array/generic and inherent-to_string types blocked; 8 closure params not inferred; sibling param never reads outer `r`)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
