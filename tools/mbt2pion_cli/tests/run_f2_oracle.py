#!/usr/bin/env python3
r"""Wave M2-F2 3-Engine Differential Oracle: Moon wasm-gc == Pion native == Pion wasm32.

Covers:
  1. Optional `SourceLoc` (`made_for? : SourceLoc`, `made_for? : SourceLoc = ...`, `loc~ : SourceLoc` autofill)
  2. Value type ascriptions (`((4.0 : Float) - hue)`, `(0 : Double)`, `(0x10 : Double)`, `(1 : Int64)`, `(x : Double)`)
  3. `match` arm `if` guards (fall-through, `is` pattern in guard, multiline guard, or-pattern + guard, side-effect order)
  4. `Int::min`/`Int::max`/`Double::min`/`Double::max` (NaN & -0.0/+0.0 parity) + custom `.min`/`.max` untouched
"""
import argparse, os, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

F2_MBT = r'''
#callsite(autofill(loc))
fn tag_loc(made_for? : SourceLoc, loc~ : SourceLoc) -> String {
  let s = made_for.unwrap_or(loc).to_string()
  if s.contains("f2.mbt:") { "has_loc" } else { s }
}

#callsite(autofill(loc))
fn tag_loc_def(loc~ : SourceLoc, made_for? : SourceLoc = loc) -> String {
  let s = made_for.to_string()
  if s.contains("f2.mbt:") { "def_loc" } else { s }
}

fn pos_opt_loc(made_for : SourceLoc?, loc : SourceLoc) -> String {
  let s = made_for.unwrap_or(loc).to_string()
  if s.contains("f2.mbt:") { "pos_opt" } else { s }
}

#callsite(autofill(loc))
fn forward_loc(made_for? : SourceLoc, loc~ : SourceLoc) -> String {
  tag_loc(made_for=made_for.unwrap_or(loc)) + "," + tag_loc(made_for?=made_for) + "," + pos_opt_loc(made_for, loc)
}

pub fn run_f2_1() -> String {
  let a = tag_loc()
  let b = tag_loc(made_for?=None)
  let c = forward_loc()
  let d = tag_loc_def()
  a + "|" + b + "|" + c + "|" + d
}

fn hue_calc(t1 : Float, t2 : Float, hue : Float) -> Float {
  (t2 - t1) * ((4.0 : Float) - hue) + t1
}

pub fn run_f2_2() -> String {
  let f : Float = hue_calc((0.25 : Float), (0.75 : Float), (3.5 : Float))
  let d0 : Double = (0 : Double) + (0x10 : Double)
  let big_hex : Double = (0x80000000 : Double)
  let u64_hi : Bool = (0x8000000000000000 : Double) == 9223372036854775808.0
  let u64_max_d : Bool = (0xFFFFFFFFFFFFFFFF : Double) == 18446744073709551616.0
  let u64_max_f : Bool = (0xFFFFFFFFFFFFFFFF : Float).to_double() == 18446744073709551616.0
  let neg_z : Bool = 1.0 / (-0x0 : Double) < 0.0
  let i64 : Int64 = (42 : Int64)
  let x : Double = 3.5
  let xd : Double = (x : Double) * 2.0
  let opt : Int? = (None : Int?)
  let o = match opt { Some(v) => v; None => 9 }
  (f.to_double() * 100.0).to_int().to_string() + "," + d0.to_int().to_string() + "," + big_hex.to_int64().to_string() + "," + u64_hi.to_string() + "," + u64_max_d.to_string() + "," + u64_max_f.to_string() + "," + neg_z.to_string() + "," + i64.to_string() + "," + xd.to_int().to_string() + "," + o.to_string()
}

fn lookup_kind(k : Int) -> Int? {
  if k > 0 { Some(k * 10) } else { None }
}

pub fn run_f2_3() -> String {
  let trace : Array[Int] = []
  let probe = fn(tag : Int, ok : Bool) -> Bool {
    trace.push(tag)
    ok
  }
  let classify = fn(a : Int?, b : Int?) -> Int {
    match (a, b) {
      (Some(x), Some(y)) if probe(1, x > 0) &&
        lookup_kind(y) is Some(kind) => x + kind
      (Some(x), _) if probe(2, x > 10) => x * 2
      (Some(x), None) if {
        let s =
          #|one}
          #|two//
        let y = x + s.length()
        y > 15
      } => x + 100
      (Some(x), None) | (None, Some(x)) if x < 0 => -x
      _ => -99
    }
  }
  let r1 = classify(Some(3), Some(4))
  let r2 = classify(Some(15), Some(-2))
  let r3 = classify(Some(-5), None)
  let r4 = classify(None, Some(-7))
  let r5 = classify(Some(6), None)
  let r6 = classify(None, None)
  let tr = trace.map(fn(v) { v.to_string() }).join("-")
  r1.to_string() + "," + r2.to_string() + "," + r3.to_string() + "," + r4.to_string() + "," + r5.to_string() + "," + r6.to_string() + "|" + tr
}

priv struct CustomRange {
  lo : Int
  hi : Int
}

fn CustomRange::min(self : CustomRange, bias : Int) -> Int {
  self.lo + bias
}

fn CustomRange::max(self : CustomRange, bias : Int) -> Int {
  self.hi + bias
}

fn fmt_d(d : Double) -> String {
  if d != d {
    "NaN"
  } else {
    let b = d.reinterpret_as_int64()
    let sgn = if b < 0L { "-" } else { "+" }
    sgn + d.to_int().to_string()
  }
}

pub fn run_f2_4() -> String {
  let imin = (3).min(5).to_string() + "," + (9).min(2).to_string() + "," + Int::min(-4, -1).to_string()
  let imax = (3).max(5).to_string() + "," + (9).max(2).to_string() + "," + Int::max(-4, -1).to_string()
  let nan = 0.0 / 0.0
  let nz = -0.0
  let pz = 0.0
  let dm = fmt_d(nan.min(1.0)) + "," + fmt_d((1.0).min(nan)) + "," + fmt_d(nz.min(pz)) + "," + fmt_d(pz.min(nz)) + "," + fmt_d(Double::min(2.0, 5.0))
  let dx = fmt_d(nan.max(1.0)) + "," + fmt_d((1.0).max(nan)) + "," + fmt_d(nz.max(pz)) + "," + fmt_d(pz.max(nz)) + "," + fmt_d(Double::max(2.0, 5.0))
  let cr : CustomRange = { lo: 10, hi: 20 }
  let custom = cr.min(1).to_string() + "," + cr.max(2).to_string()
  imin + "|" + imax + "|" + dm + "|" + dx + "|" + custom
}

pub fn run_all() -> String {
  "F2-1:" + run_f2_1() + "\nF2-2:" + run_f2_2() + "\nF2-3:" + run_f2_3() + "\nF2-4:" + run_f2_4()
}
'''

SHADOW_MBT = r'''
fn Int::min(self : Int, y : Int) -> Int {
  self + y
}

pub fn run_local_int_min() -> Int {
  Int::min(2, 3)
}
'''

def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
    if p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
    return p.stdout.strip()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", default=os.environ.get("PIONC", shutil.which("pionc") or os.path.expanduser("~/.pion/bin/pionc")))
    ap.add_argument("--moon", default=os.environ.get("MOON", shutil.which("moon") or os.path.expanduser("~/.moon/bin/moon")))
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="mbt2pion-f2-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])
        md = os.path.join(work, "moon_proj")
        for sub in ("lib", "shadow", "cmd"):
            os.makedirs(os.path.join(md, sub))
        for rel, txt in [
            ("moon.mod", 'name = "f2/oracle"\n'),
            ("lib/moon.pkg", "\n"),
            ("lib/f2.mbt", F2_MBT),
            ("shadow/moon.pkg", "\n"),
            ("shadow/shadow.mbt", SHADOW_MBT),
            ("cmd/moon.pkg", 'import { "f2/oracle/lib", "f2/oracle/shadow" }\npkgtype(kind: "executable")\n'),
            ("cmd/main.mbt", 'fn main { println(@lib.run_all() + "\\nF2-5:" + @shadow.run_local_int_min().to_string()) }\n'),
        ]:
            open(os.path.join(md, rel), "w").write(txt)
        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)

        ps = os.path.join(work, "p_shadow")
        os.makedirs(os.path.join(ps, "src"))
        run_cmd([bin_path, "--src", os.path.join(md, "shadow"), "--out", os.path.join(ps, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        open(os.path.join(ps, "pion.toml"), "w").write(f'[package]\nname = "shadow"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')

        pl = os.path.join(work, "p_lib")
        os.makedirs(os.path.join(pl, "src"))
        run_cmd([bin_path, "--src", os.path.join(md, "lib"), "--out", os.path.join(pl, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        open(os.path.join(pl, "pion.toml"), "w").write(f'[package]\nname = "f2lib"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nshadow = {{ path = "{ps}" }}\n')
        open(os.path.join(pl, "src", "main.pion"), "w").write('import "shadow"\npub fn main(w : World) -> Int { io_println(w, run_all() + "\\nF2-5:" + shadow::run_local_int_min().to_string()); 0 }\n')
        pion_native = run_cmd([args.pionc, "run", pl])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", pl])

        expected = (
            "F2-1:has_loc|has_loc|has_loc,has_loc,pos_opt|def_loc\n"
            "F2-2:50,16,2147483648,true,true,true,true,42,7,9\n"
            "F2-3:43,30,5,7,106,-99|1-1-2-2-2\n"
            "F2-4:3,2,-4|5,9,-1|+1,+1,+0,-0,+2|+1,+1,+0,-0,+5|11,22\n"
            "F2-5:5"
        )
        assert moon_out == expected and pion_native == moon_out and pion_wasm == moon_out, (
            f"MISMATCH:\nEXPECTED:\n{expected}\nMOON:\n{moon_out}\nNATIVE:\n{pion_native}\nWASM32:\n{pion_wasm}"
        )
        print("[f2-oracle] PASS: 3-engine (moon wasm-gc == pion-native == pion-wasm32) 100% identical!\n" + moon_out)
    finally:
        shutil.rmtree(work, ignore_errors=True)

if __name__ == "__main__":
    main()
