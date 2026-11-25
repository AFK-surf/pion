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

pub fn run_all() -> String {
  "F3b-1:" + run_f3b_1() + "\nF3b-2:" + run_f3b_2() + "\nF3b-3:" + run_f3b_3() + "\nF3b-4:" + run_f3b_4() +
  "\nF3b-5:" + run_f3b_5() + "\nF3b-6:" + run_f3b_6() + "\nF3b-7:" + run_f3b_7()
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
            "F3b-7:[ab][abc][][héllo][xé][A]1"
        )
        assert moon_out == expected and pion_native == moon_out and pion_wasm == moon_out, (
            f"MISMATCH:\nEXPECTED:\n{expected}\nMOON:\n{moon_out}\nNATIVE:\n{pion_native}\nWASM32:\n{pion_wasm}"
        )
        print("[f3b-oracle] PASS: 3-engine (moon wasm-gc == pion-native == pion-wasm32) 100% identical!\n" + moon_out)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
