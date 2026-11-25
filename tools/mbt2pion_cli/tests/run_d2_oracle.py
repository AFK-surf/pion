#!/usr/bin/env python3
"""Wave M2-D2 3-Engine Differential Oracle: Moon wasm-gc vs Pion native vs Pion wasm32.

Verifies all 5 Wave M2-D2 features and 4 high-risk acceptance contracts:
  D2-1: FuncRef[(Int, Int) -> Int] in struct field and fn param
  D2-2: Labeled enum bare/qualified/punned evaluation order == declaration order (2431)
  D2-3: Type ascription (0.1 : Float).to_bits(), (4.0 : Float) - h, ({x:1,y:2} : UtPt).x, (None : Int?)
  D2-4: Private + pub const pattern inlining, private using (with local shadowing), array spread [..a, {a.push(9); 5}, ..a]
  D2-5: Nested constructor array patterns (Some(Array([Number(x, ..), ...])), guard-true snapshot,
        guard-false mutation visible, outer-shadow fallthrough let x = 77)
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

DEP_MBT = r'''
pub(all) struct Box {
  v : Int
}

pub fn helper(b : Box) -> Int {
  b.v * 10
}
'''

LIB_MBT = r'''
using @dep { helper, type Box }

pub(all) struct CbHolder {
  cb : FuncRef[(Int, Int) -> Int]
}

pub fn run_funcref(f : FuncRef[(Int, Int) -> Int], a : Int, b : Int) -> Int {
  let h : CbHolder = { cb: f }
  (h.cb)(a, b)
}

pub(all) enum Ev {
  NavAction(x~ : Int, y~ : Int, w~ : Int, h~ : Int)
  Fold(hinge~ : Int, divisions~ : Int, val~ : Int)
}

pub fn run_enum_order() -> String {
  let mut acc = 0
  let tick = fn(tag : Int) -> Int {
    acc = acc * 10 + tag
    acc
  }
  let out : Array[Ev] = []
  out.push(NavAction(h=tick(1), x=tick(2), w=tick(3), y=tick(4)))
  let q = Ev::NavAction(y=20, h=40, x=10, w=30)
  out.push(q)
  let hinge = 7
  let divisions = 3
  let val_ = 99
  let val = 9
  let _ = val_
  out.push(Fold(val~, divisions~, hinge~))
  let sb = StringBuilder::new()
  sb.write_string("trace=" + acc.to_string())
  for ev in out {
    match ev {
      NavAction(x~, y~, w~, h~) =>
        sb.write_string("|N(" + x.to_string() + "," + y.to_string() + "," + w.to_string() + "," + h.to_string() + ")")
      Fold(hinge~, divisions~, val~) =>
        sb.write_string("|F(" + hinge.to_string() + "," + divisions.to_string() + "," + val.to_string() + ")")
    }
  }
  sb.to_string()
}

pub(all) struct UtPt {
  x : Int
  y : Int
}

pub fn run_ascription(h : Float) -> String {
  let f01 = (0.1 : Float)
  let diff = (4.0 : Float) - h
  let px = ({ x: 1, y: 2 } : UtPt).x
  let none_v = match (None : Int?) {
    Some(v) => v
    None => -7
  }
  f01.reinterpret_as_int().to_string() + "|" + diff.reinterpret_as_int().to_string() + "|" + px.to_string() + "|" + none_v.to_string()
}

const KIND : Int = 64
pub const PUB_KIND : Int = 128

fn classify(v : Int) -> String {
  match v {
    KIND => "k"
    PUB_KIND => "p"
    _ => "other"
  }
}

pub fn run_const_using_spread() -> String {
  let c_res = classify(64) + "," + classify(128) + "," + classify(3)
  let b : Box = Box::{ v: 4 }
  let u1 = helper(b)
  let u2 = {
    let helper = fn(x : Int) -> Int { x + 1 }
    helper(4)
  }
  let a = [1, 2]
  let sp = [..a, { a.push(9); 5 }, ..a]
  let sb = StringBuilder::new()
  for x in sp { sb.write_string(x.to_string()) }
  c_res + "|" + u1.to_string() + "," + u2.to_string() + "|" + sb.to_string()
}

fn match_rect(opt : Json?) -> Int {
  match opt {
    Some(Array([Number(x, ..), Number(y, ..), Number(w, ..), Number(h, ..)])) =>
      x.to_int() * 1000 + y.to_int() * 100 + w.to_int() * 10 + h.to_int()
    _ => -1
  }
}

pub fn run_nested_array_patterns() -> String {
  let j4 : Json = [1.0, 2.0, 3.0, 4.0]
  let j3 : Json = [1.0, 2.0, 3.0]
  let jbad : Json = [1.0, "two", 3.0, 4.0]
  let r4 = match_rect(Some(j4))
  let r3 = match_rect(Some(j3))
  let rbad = match_rect(Some(jbad))

  let a1 = [1, 2]
  let mut calls1 = 0
  let g_true = match Some(a1) {
    Some([x, _]) if { a1[0] = 9; calls1 = calls1 + 1; true } => x
    _ => -1
  }

  let a2 = [1, 2]
  let mut calls2 = 0
  let g_false = match Some(a2) {
    Some([x, _]) if { a2[0] = 9; calls2 = calls2 + 1; false } => x
    _ => a2[0]
  }

  let x = 77
  let a3 = [1, 2]
  let shadow = match Some(a3) {
    Some([x, _]) if x == 0 => x
    _ => x
  }

  // Astra P0-1 + Red-team P1-1: inner shadowing inside arm body and guard
  let s_let = match Some([7, 2]) {
    Some([x, _]) => {
      let x = 9
      x
    }
    _ => -1
  }
  let s_yx = match Some([1, 2]) {
    Some([x, _]) => {
      let y = x
      let x = 99
      y + x
    }
    _ => -1
  }
  let s_fn = match Some([1, 2]) {
    Some([x, _]) => {
      let f = fn(x : Int) -> Int { x * 2 }
      f(10) + x
    }
    _ => -1
  }
  let s_self = match Some([1, 2]) {
    Some([x, y]) => {
      let x = x * 100
      x + y
    }
    _ => -1
  }
  let s_grd = match Some([5, 2]) {
    Some([x, _]) if { let x = 0; x == 0 } => x
    _ => -1
  }

  // Red-team P1-2: guard array length mutations (push / pop / element mutation)
  let lp1 = [1, 2]
  let r_push = match Some(lp1) {
    Some([x, _]) if { lp1.push(99); false } => x
    Some([_, _, z]) => z
    _ => -1
  }
  let lp2 = [1, 2, 3]
  let r_pop_fix = match Some(lp2) {
    Some([x, _, _]) if { let _ = lp2.pop(); false } => x
    Some([_, y]) => y
    Some([_, _, z]) => z * 100
    _ => -1
  }
  let lp3 = [1, 2, 3]
  let r_pop_rest = match Some(lp3) {
    Some([x, ..]) if { let _ = lp3.pop(); false } => x
    Some([_, _, z]) => z
    _ => -1
  }
  let lp4 = [1, 2, 3]
  let r_mut_rest = match Some(lp4) {
    Some([x, ..]) if { lp4[2] = 99; false } => x
    Some([_, _, z]) => z
    _ => -1
  }

  r4.to_string() + "," + r3.to_string() + "," + rbad.to_string() +
  "|gt=" + g_true.to_string() + "," + a1[0].to_string() + "," + calls1.to_string() +
  "|gf=" + g_false.to_string() + "," + calls2.to_string() +
  "|sh=" + shadow.to_string() +
  "|in=" + s_let.to_string() + "," + s_yx.to_string() + "," + s_fn.to_string() + "," + s_self.to_string() + "," + s_grd.to_string() +
  "|lm=" + r_push.to_string() + "," + r_pop_fix.to_string() + "," + r_pop_rest.to_string() + "," + r_mut_rest.to_string()
}

pub fn run_all() -> String {
  let s1 = run_funcref(fn(a, b) { a * 10 + b }, 3, 7).to_string()
  let s2 = run_enum_order()
  let s3 = run_ascription((1.5 : Float))
  let s4 = run_const_using_spread()
  let s5 = run_nested_array_patterns()
  "D2-1:" + s1 + "\nD2-2:" + s2 + "\nD2-3:" + s3 + "\nD2-4:" + s4 + "\nD2-5:" + s5
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

    work = tempfile.mkdtemp(prefix="mbt2pion-d2-oracle-")
    try:
        mbt2pion_bin = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", mbt2pion_bin])

        # 1. Moon wasm-gc project
        moon_dir = os.path.join(work, "moon_proj")
        os.makedirs(os.path.join(moon_dir, "dep"))
        os.makedirs(os.path.join(moon_dir, "lib"))
        os.makedirs(os.path.join(moon_dir, "cmd"))
        with open(os.path.join(moon_dir, "moon.mod"), "w") as f:
            f.write('name = "d2/oracle"\n')
        with open(os.path.join(moon_dir, "dep", "moon.pkg"), "w") as f:
            f.write("\n")
        with open(os.path.join(moon_dir, "dep", "dep.mbt"), "w") as f:
            f.write(DEP_MBT)
        with open(os.path.join(moon_dir, "lib", "moon.pkg"), "w") as f:
            f.write('import {\n  "d2/oracle/dep",\n}\n')
        with open(os.path.join(moon_dir, "lib", "lib.mbt"), "w") as f:
            f.write(LIB_MBT)
        with open(os.path.join(moon_dir, "cmd", "moon.pkg"), "w") as f:
            f.write('import {\n  "d2/oracle/lib",\n}\n\npkgtype(kind: "executable")\n')
        with open(os.path.join(moon_dir, "cmd", "main.mbt"), "w") as f:
            f.write('fn main {\n  println(@lib.run_all())\n}\n')

        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=moon_dir)

        # 2. Transpile dep & lib via mbt2pion --mode publish
        pion_dep = os.path.join(work, "pion_dep")
        pion_lib = os.path.join(work, "pion_lib")
        os.makedirs(os.path.join(pion_dep, "src"))
        os.makedirs(os.path.join(pion_lib, "src"))
        with open(os.path.join(pion_dep, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "dep"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([
            mbt2pion_bin, "--src", os.path.join(moon_dir, "dep"), "--out", os.path.join(pion_dep, "src"),
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
        ])
        run_cmd([
            mbt2pion_bin, "--src", os.path.join(moon_dir, "lib"), "--out", os.path.join(pion_lib, "src"),
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR,
            "--dep", f"dep={pion_dep}", "--pionc", args.pionc,
        ])
        with open(os.path.join(pion_lib, "pion.toml"), "w") as f:
            f.write(
                f'[package]\nname = "d2_oracle_lib"\nversion = "0.1.0"\n\n[dependencies]\n'
                f'mbt_compat = {{ path = "{COMPAT_DIR}" }}\ndep = {{ path = "{pion_dep}" }}\n'
            )
        with open(os.path.join(pion_lib, "src", "main.pion"), "w") as f:
            f.write('pub fn main(w : World) -> Int {\n  io_println(w, run_all())\n  0\n}\n')

        pion_native_out = run_cmd([args.pionc, "run", pion_lib])
        pion_wasm_out = run_cmd([args.pionc, "run", "--target", "wasm32", pion_lib])

        # Verify exact values AND 3-engine verbatim parity!
        expected_lines = [
            "D2-1:37",
            "D2-2:trace=2431|N(2,24,243,2431)|N(10,20,30,40)|F(7,3,9)",
            "D2-4:k,p,other|40,5|125129",
            "D2-5:1234,-1,-1|gt=1,9,1|gf=9,1|sh=77|in=9,100,21,102,5|lm=-1,300,-1,99",
        ]
        for ln in expected_lines:
            if ln not in moon_out.splitlines():
                raise AssertionError(f"Moon output missing expected contract line {ln!r}:\n{moon_out}")
        if moon_out != pion_native_out:
            raise AssertionError(f"MISMATCH moon vs pion-native:\n--- MOON ---\n{moon_out}\n--- PION-NATIVE ---\n{pion_native_out}")
        if moon_out != pion_wasm_out:
            raise AssertionError(f"MISMATCH moon vs pion-wasm32:\n--- MOON ---\n{moon_out}\n--- PION-WASM32 ---\n{pion_wasm_out}")

        print("[d2-oracle] PASS: 3-engine (moon wasm-gc == pion-native == pion-wasm32) 100% identical!")
        print(moon_out)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
