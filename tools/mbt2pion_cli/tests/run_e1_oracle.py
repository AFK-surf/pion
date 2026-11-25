#!/usr/bin/env python3
"""Wave M2-E1 3-Engine Differential Oracle: Moon wasm-gc vs Pion native vs Pion wasm32.

Verifies all Wave M2-E1 contracts and Opus/Astra numerical assertions:
  E1-1: Chained .split().to_array() match + impl Show for Type with output(self, logger)
  E1-2: Layer 1/2/3 enum disambiguation (opt-default, call-arg, reversed labels x~,y~ vs y~,x~ -> 12,
        cross-pkg dep reversed labels + nested match + scrutinee single-eval cnt == 1)
  E1-3: Leading/middle rest patterns: Opus P1-1 (50), Astra P0-1 (9 top & nested),
        Astra P0-1 slot-cache triple (93, 13, 13), guard push/pop top & nested, inner shadow
  E1-4: Strictly whitelisted read-only slices (.length/.is_empty/.to_array/.join/interp)
        with receiver & bound single-eval counters == 1
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

DEP_MBT = r'''
pub(all) enum OutlineCmd {
  MoveTo(x~ : Int, y~ : Int)
  LineTo(y~ : Int, x~ : Int)
  Close
}

pub fn make_dep_cmd(kind : Int) -> OutlineCmd {
  if kind == 0 {
    OutlineCmd::MoveTo(x=3, y=4)
  } else if kind == 1 {
    OutlineCmd::LineTo(x=5, y=6)
  } else {
    OutlineCmd::Close
  }
}
'''

LIB_MBT = r'''
fn pk_info() -> String { "held\t42\tsrc" }

pub enum Tab { Downloads; Photos }
pub enum OtherTab { Downloads; Photos }

impl Show for Tab with output(self, logger) {
  match self {
    Downloads => logger.write_string("tab:dl")
    Photos => logger.write_string("tab:ph")
  }
}

pub fn run_e1_1() -> String {
  let info = pk_info().split("\t").to_array()
  let n = match info {
    [a, b, c] => a.length() * 100 + b.length() * 10 + c.length()
    _ => -1
  }
  n.to_string() + "|" + "\{Tab::Downloads}" + "," + "\{Tab::Photos}"
}

pub(all) enum AccKind { Single(collapsible~ : Bool); Multi }
pub(all) enum AltKind { Single(collapsible~ : Bool); Solo }

fn make_acc(kind? : AccKind = Single(collapsible=true)) -> Int {
  match kind {
    Single(collapsible~) => if collapsible { 11 } else { 10 }
    Multi => 20
  }
}

fn use_alt(axis~ : AltKind) -> Int {
  match axis {
    Single(collapsible~) => if collapsible { 31 } else { 30 }
    Solo => 40
  }
}

pub(all) enum E1 { C(x~ : Int, y~ : Int) }
pub(all) enum E2 { C(y~ : Int, x~ : Int) }

fn get_e2(cnt : Ref[Int]) -> E2 {
  cnt.val = cnt.val + 1
  E2::C(x=1, y=2)
}

pub(all) enum OutlineCmd {
  MoveTo(y~ : Int, x~ : Int)
  LineTo(x~ : Int, y~ : Int)
  Close
}

pub fn run_e1_2() -> String {
  let r_opt = make_acc()
  let r_arg = use_alt(axis=Single(collapsible=false))
  let c1 : Ref[Int] = { val: 0 }
  let r_rev = match get_e2(c1) {
    C(x~, y~) => 10 * x + y
  }
  let c2 : Ref[Int] = { val: 0 }
  let r_dep = match { c2.val = c2.val + 1; @dep.make_dep_cmd(1) } {
    MoveTo(x~, y~) => x * 10 + y
    LineTo(x~, y~) => {
      let inner = match { c2.val = c2.val + 1; @dep.make_dep_cmd(0) } {
        MoveTo(x~, y~) => x * 10 + y
        LineTo(x~, y~) => x + y
        Close => 0
      }
      x * 100 + y * 10 + inner
    }
    Close => -1
  }
  r_opt.to_string() + "," + r_arg.to_string() + "|rev=" + r_rev.to_string() + ",c1=" + c1.val.to_string() + "|dep=" + r_dep.to_string() + ",c2=" + c2.val.to_string()
}

pub fn run_e1_3() -> String {
  // Opus P1-1: shared ArrayView mutation
  let xs = [10, 20, 30]
  let opus50 = match xs {
    [_, .. as mid, _] => { xs[1] = 50; mid[0] }
    _ => -1
  }
  // Astra P0-1: guard mutation visible through mid (top-level & nested)
  let a_top = [1, 2, 3]
  let astra9_top = match a_top {
    [_, .. as mid, _] if { a_top[1] = 9; true } => mid[0]
    _ => -1
  }
  let a_nest = [1, 2, 3]
  let astra9_nest = match Some(a_nest) {
    Some([_, .. as mid, _]) if { a_nest[1] = 9; true } => mid[0]
    _ => -1
  }
  // Astra P0-1 slot-cache triple: 93, 13, 13
  let s1 = [1, 2, 3]
  let r93 = match s1 {
    [.., last] if { s1[0] = 9; s1[2] = 8; false } => last
    [y, .., z] => 10 * y + z
    _ => -1
  }
  let s2 = [1, 2, 3]
  let r13_top = match s2 {
    [_, .., last] if { s2[0] = 9; s2[2] = 8; false } => last
    [y, .., z] => 10 * y + z
    _ => -1
  }
  let s3 = [1, 2, 3]
  let r13_nest = match Some(s3) {
    Some([_, .., last]) if { s3[0] = 9; s3[2] = 8; false } => last
    Some([y, .., z]) => 10 * y + z
    _ => -1
  }
  // Guard push/pop top-level & nested (prefix arm -> uncached suffix reads live; suffix arm -> cached suffix reused)
  let gp1 = [1, 2, 3]
  let r_push_top = match gp1 {
    [x, ..] if { gp1.push(99); false } => x
    [.., z] => z
    _ => -1
  }
  let gp2 = [1, 2, 3]
  let r_pop_top = match gp2 {
    [x, ..] if { let _ = gp2.pop(); false } => x
    [.., z] => z
    _ => -1
  }
  let gp3 = [1, 2, 3]
  let r_push_nest = match Some(gp3) {
    Some([x, ..]) if { gp3.push(88); false } => x
    Some([.., z]) => z
    _ => -1
  }
  let gp4 = [1, 2, 3]
  let r_pop_nest = match Some(gp4) {
    Some([x, ..]) if { let _ = gp4.pop(); false } => x
    Some([.., z]) => z
    _ => -1
  }
  let gp5 = [1, 2, 3]
  let r_cached_suf = match gp5 {
    [.., last] if { gp5.push(77); false } => last
    [.., z] => z
    _ => -1
  }
  // #3: fixed-length arm guard push -> rest arm reuses cached len == 2 (top-level & nested => 3, 3)
  let fl1 = [1, 2]
  let r_fl_top = match fl1 {
    [x, y] if { let _ = x + y; fl1.push(99); false } => 1
    [_, _, _, ..] => 2
    _ => 3
  }
  let fl2 = [1, 2]
  let r_fl_nest = match Some(fl2) {
    Some([x, y]) if { let _ = x + y; fl2.push(99); false } => 1
    Some([_, _, _, ..]) => 2
    _ => 3
  }
  // #4: fixed-length [a, b, c] must NOT cross-fill reverse suffix cache (push/pop/mut => 99, 2, 88 top & nested)
  let fx1 = [1, 2, 3]
  let r_fx1 = match fx1 {
    [a, b, c] if { fx1.push(99); false } => a + b + c
    [.., z] => z
    _ => -1
  }
  let fx2 = [1, 2, 3]
  let r_fx2 = match fx2 {
    [a, b, c] if { let _ = fx2.pop(); false } => a + b + c
    [.., z] => z
    _ => -1
  }
  let fx3 = [1, 2, 3]
  let r_fx3 = match fx3 {
    [a, b, c] if { fx3[2] = 88; false } => a + b + c
    [.., z] => z
    _ => -1
  }
  let fx4 = [1, 2, 3]
  let r_fx4 = match Some(fx4) {
    Some([a, b, c]) if { fx4.push(99); false } => a + b + c
    Some([.., z]) => z
    _ => -1
  }
  let fx5 = [1, 2, 3]
  let r_fx5 = match Some(fx5) {
    Some([a, b, c]) if { let _ = fx5.pop(); false } => a + b + c
    Some([.., z]) => z
    _ => -1
  }
  let fx6 = [1, 2, 3]
  let r_fx6 = match Some(fx6) {
    Some([a, b, c]) if { fx6[2] = 88; false } => a + b + c
    Some([.., z]) => z
    _ => -1
  }
  // Astra P0: `.. as mid` must NOT leak into fallback arms when guard fails (top-level & nested => 4, 4)
  let mid = [4, 5, 6, 7]
  let sh_a = [1, 2, 3]
  let r_sh_top = match sh_a {
    [_, .. as mid, _] if mid.length() == 0 => 0
    _ => mid.length()
  }
  let r_sh_nest = match Some(sh_a) {
    Some([_, .. as mid, _]) if mid.length() == 0 => 0
    _ => mid.length()
  }
  // Empty/single/multi & inner shadow
  let empty_r = match ([] : Array[Int]) { [.., last] => last; _ => -7 }
  let single_r = match [42] { [.., last] => last; _ => -7 }
  let sh_r = match [1, 2, 3] { [.., last] => { let last = 99; last }; _ => -7 }
  let mid_arr = [7, 8]
  let mid_empty = match mid_arr { [a, .. as m, z] => a * 100 + m.length() * 10 + z; _ => -1 }
  opus50.to_string() + "," + astra9_top.to_string() + "," + astra9_nest.to_string() +
  "|cache=" + r93.to_string() + "," + r13_top.to_string() + "," + r13_nest.to_string() +
  "|gp=" + r_push_top.to_string() + "," + r_pop_top.to_string() + "," + r_push_nest.to_string() + "," + r_pop_nest.to_string() + "," + r_cached_suf.to_string() +
  "|fl=" + r_fl_top.to_string() + "," + r_fl_nest.to_string() +
  "|fx=" + r_fx1.to_string() + "," + r_fx2.to_string() + "," + r_fx3.to_string() + "," + r_fx4.to_string() + "," + r_fx5.to_string() + "," + r_fx6.to_string() +
  "|sh=" + r_sh_top.to_string() + "," + r_sh_nest.to_string() +
  "|misc=" + empty_r.to_string() + "," + single_r.to_string() + "," + sh_r.to_string() + "," + mid_empty.to_string()
}

pub struct Holder {
  arr : Array[Int]
  strs : Array[String]
  chars : Array[Char]
  fstrs : FixedArray[String]
}

fn view_join_show(vs : ArrayView[String], vi : ArrayView[Int]) -> String {
  vs[1:3].join(":") + "|" + "\{vi[0:2]}" + "|" + vs[0:2].to_string()
}

pub fn run_e1_4() -> String {
  let h : Holder = { arr: [10, 20, 30, 40], strs: ["a", "b", "c", "d"], chars: ['x', 'y', 'z'], fstrs: ["u", "v", "w"] }
  let c_recv : Ref[Int] = { val: 0 }
  let c_lo : Ref[Int] = { val: 0 }
  let c_hi : Ref[Int] = { val: 0 }
  let get_h = fn() -> Holder { c_recv.val = c_recv.val + 1; h }
  let get_lo = fn() -> Int { c_lo.val = c_lo.val + 1; 1 }
  let get_hi = fn() -> Int { c_hi.val = c_hi.val + 1; 3 }
  let l1 = get_h().arr[get_lo():get_hi()].length()
  let e1 = h.arr[2:2].is_empty()
  let cp = h.arr[1:3].to_array()
  let sep_var = ":"
  let j1 = h.strs[:3].join("-")
  let j2 = h.strs[1:3].join(sep_var)
  let s1 = "\{h.arr[0:2]}"
  // Astra P1: String/Char/FixedArray/ArrayBuf/ArrayView Show format (unquoted [a, b])
  let s_str = h.strs[0:2].to_string() + "/" + "\{h.strs[0:2]}" + "/" + h.chars[0:2].to_string() + "/" + "\{h.chars[0:2]}" + "/" + h.fstrs[0:2].to_string()
  // #1: ArrayBuf (promoted local array) + ArrayView param + Bytes slice ro_join/ro_show
  let buf_strs = ["p", "q", "r", "s"]
  let v_strs = buf_strs[0:4]
  let buf_ints = [5, 6, 7]
  let v_ints = buf_ints[0:3]
  let bj = buf_strs[:3].join("-")
  let bs_buf = "\{buf_ints[0:2]}" + "/" + buf_ints[0:2].to_string() + "/" + buf_strs[0:2].to_string()
  let vj = view_join_show(v_strs, v_ints)
  let b : Bytes = b"\x09\x0a\x0d\x22\x5c\x20\x7e\x00\xff"
  let by_s = b[:].to_string() + "/" + "\{b[:]}"
  l1.to_string() + "," + e1.to_string() + "," + cp.length().to_string() + "," + cp[0].to_string() +
  "|" + j1 + "|" + j2 + "|" + s1 + "|show=" + s_str +
  "|buf=" + bj + "," + bs_buf + "|view=" + vj + "|bytes=" + by_s +
  "|cnt=" + c_recv.val.to_string() + "," + c_lo.val.to_string() + "," + c_hi.val.to_string()
}

pub fn run_all() -> String {
  "E1-1:" + run_e1_1() + "\nE1-2:" + run_e1_2() + "\nE1-3:" + run_e1_3() + "\nE1-4:" + run_e1_4()
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

    work = tempfile.mkdtemp(prefix="mbt2pion-e1-oracle-")
    try:
        mbt2pion_bin = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", mbt2pion_bin])

        moon_dir = os.path.join(work, "moon_proj")
        os.makedirs(os.path.join(moon_dir, "dep"))
        os.makedirs(os.path.join(moon_dir, "lib"))
        os.makedirs(os.path.join(moon_dir, "cmd"))
        with open(os.path.join(moon_dir, "moon.mod"), "w") as f:
            f.write('name = "e1/oracle"\n')
        with open(os.path.join(moon_dir, "dep", "moon.pkg"), "w") as f:
            f.write("\n")
        with open(os.path.join(moon_dir, "dep", "dep.mbt"), "w") as f:
            f.write(DEP_MBT)
        with open(os.path.join(moon_dir, "lib", "moon.pkg"), "w") as f:
            f.write('import {\n  "e1/oracle/dep",\n}\n')
        with open(os.path.join(moon_dir, "lib", "lib.mbt"), "w") as f:
            f.write(LIB_MBT)
        with open(os.path.join(moon_dir, "cmd", "moon.pkg"), "w") as f:
            f.write('import {\n  "e1/oracle/lib",\n}\n\npkgtype(kind: "executable")\n')
        with open(os.path.join(moon_dir, "cmd", "main.mbt"), "w") as f:
            f.write('fn main {\n  println(@lib.run_all())\n}\n')

        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=moon_dir)

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
                f'[package]\nname = "e1_oracle_lib"\nversion = "0.1.0"\n\n[dependencies]\n'
                f'mbt_compat = {{ path = "{COMPAT_DIR}" }}\ndep = {{ path = "{pion_dep}" }}\n'
            )
        with open(os.path.join(pion_lib, "src", "main.pion"), "w") as f:
            f.write('pub fn main(w : World) -> Int {\n  io_println(w, run_all())\n  0\n}\n')

        pion_native_out = run_cmd([args.pionc, "run", pion_lib])
        pion_wasm_out = run_cmd([args.pionc, "run", "--target", "wasm32", pion_lib])

        expected_lines = [
            "E1-1:423|tab:dl,tab:ph",
            "E1-2:11,30|rev=12,c1=1|dep=594,c2=2",
            "E1-3:50,9,9|cache=93,13,13|gp=99,2,88,2,3|fl=3,3|fx=99,2,88,99,2,88|sh=4,4|misc=-7,42,99,708",
            "E1-4:2,true,2,20|a-b-c|b:c|[10, 20]|show=[a, b]/[a, b]/[x, y]/[x, y]/[u, v]|buf=p-q-r,[5, 6]/[5, 6]/[p, q]|view=q:r|[5, 6]|[p, q]|bytes=b\"\\x09\\x0a\\x0d\\x22\\x5c ~\\x00\\xff\"/b\"\\x09\\x0a\\x0d\\x22\\x5c ~\\x00\\xff\"|cnt=1,1,1",
        ]
        for ln in expected_lines:
            if ln not in moon_out.splitlines():
                raise AssertionError(f"Moon output missing expected contract line {ln!r}:\n{moon_out}")
        if moon_out != pion_native_out:
            raise AssertionError(f"MISMATCH moon vs pion-native:\n--- MOON ---\n{moon_out}\n--- PION-NATIVE ---\n{pion_native_out}")
        if moon_out != pion_wasm_out:
            raise AssertionError(f"MISMATCH moon vs pion-wasm32:\n--- MOON ---\n{moon_out}\n--- PION-WASM32 ---\n{pion_wasm_out}")

        print("[e1-oracle] PASS: 3-engine (moon wasm-gc == pion-native == pion-wasm32) 100% identical!")
        print(moon_out)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
