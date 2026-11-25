#!/usr/bin/env python3
r"""Wave M2-F1 3-Engine Differential Oracle: Moon wasm-gc == Pion native == Pion wasm32.

Covers:
1. Container index inference (`let pool = pools[d]`) + `.unsafe_set`/`.set`/`.push` enum disambiguation
2. `self.seen[0:hi].iter().map(fn(x) { x.to_string() }).collect().join("; ")` across empty/partial/full/clamped bounds
3. `match` with direct `for` arm bodies followed by trailing `{ ... }` struct literal return
4. `Float::to_double`, `Float::reinterpret_from_int`, `Double::to_uint` (normal, 0, neg, NaN, sat-max)
5. Array literal `[Move, Line, Close]` & `is Some(Close)` / `is (Some(Move) | Some(Close) | None)`
6. `trait` + `&Trait` (`dyn Trait`) + split `impl Trait for T with ...` + UFCS `Trait::method(self, ...)`
"""
import argparse, os, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

F1_MBT = r'''
pub(all) enum AlignA {
  Auto
  Start
  End
}

pub(all) enum AlignB {
  Auto
  Center
}

pub struct Pool {
  aligns : FixedArray[AlignA]
}

let pools : Array[Pool] = [{ aligns: FixedArray::make(4, AlignA::Start) }]

fn align_a_tag(a : AlignA) -> Int {
  match a {
    Auto => 1
    Start => 2
    End => 3
  }
}

pub fn case1_pool_unsafe_set() -> String {
  let pool = pools[0]
  pool.aligns.unsafe_set(1, Auto)
  pool.aligns.unsafe_set(2, End)
  let local_b : Array[AlignB] = []
  local_b.push(Auto)
  local_b.push(Center)
  let b_sum = (match local_b[0] { Auto => 10; Center => 20 }) + (match local_b[1] { Auto => 10; Center => 20 })
  align_a_tag(pool.aligns[0]).to_string() + "," + align_a_tag(pool.aligns[1]).to_string() + "," + align_a_tag(pool.aligns[2]).to_string() + "," + b_sum.to_string()
}

pub struct Log {
  seen : Array[Int]
}

fn Log::told(self : Log) -> String {
  let n = self.seen.length()
  "\{n}:" + self.seen[0:if n > 6 { 6 } else { n }].iter().map(fn(x) { x.to_string() }).collect().join("; ")
}

pub fn case2_slice_iter() -> String {
  let l0 : Log = { seen: [] }
  let l2 : Log = { seen: [10, 20] }
  let l8 : Log = { seen: [1, 2, 3, 4, 5, 6, 7, 8] }
  let sub = l8.seen[2:5].iter().map(fn(x) { (x + 1).to_string() }).collect().join(",")
  let empty_hi = l2.seen[2:2].iter().count().to_string()
  l0.told() + "|" + l2.told() + "|" + l8.told() + "|" + sub + "|" + empty_hi
}

pub(all) enum MaskKind {
  Alpha
  Luma
}

pub struct MaskOut {
  data : FixedArray[Int]
  n : Int
}

fn build_mask(src : FixedArray[Int], kind : MaskKind) -> MaskOut {
  let n = src.length()
  let data = FixedArray::make(n, 0)
  match kind {
    Alpha => for i in 0..<n { data[i] = src[i] + 1 }
    Luma =>
      for i in 0..<n {
        let v = src[i] * 2
        data[i] = v + 3
      }
  }
  { data, n }
}

pub fn case3_match_for_trailing_struct() -> String {
  let src = FixedArray::from_array([1, 2, 3])
  let a = build_mask(src, Alpha)
  let l = build_mask(src, Luma)
  a.n.to_string() + ":" + a.data[0].to_string() + "," + a.data[2].to_string() + "|" + l.data[0].to_string() + "," + l.data[2].to_string()
}

let f_eps : Float = 0.25
let f_eps_cubed : Double = Float::to_double(f_eps * f_eps * f_eps)

pub fn case4_float_double_ops() -> String {
  let f1 = Float::reinterpret_from_int(0x3f800000) // 1.0f
  let d1 = Float::to_double(f1)
  let u0 = (-5.0).to_uint()
  let u1 = (42.9).to_uint()
  let u2 = (0.0 / 0.0).to_uint()
  let u3 = (5000000000.0).to_uint()
  let u4 = (3000000000.0).to_uint()
  let u5 = (4294967294.9).to_uint()
  let arr : FixedArray[Float] = FixedArray::make(2, 0.75)
  let pick = if true { arr[1] } else { 1.0 }
  f_eps_cubed.to_string() + "|" + d1.to_string() + "|" + u0.to_string() + "," + u1.to_string() + "," + u2.to_string() + "," + u3.to_string() + "," + u4.to_string() + "," + u5.to_string() + "|" + Float::to_double(pick).to_string()
}

pub(all) enum Verb {
  Move
  Line
  Close
}

pub(all) enum OtherClose {
  Close
  Open
}

pub struct MyPath {
  verbs : Array[Verb]
}

fn make_rect_path() -> MyPath {
  { verbs: [Move, Line, Line, Close] }
}

fn check_verb(p : MyPath, next_verb : Verb?) -> Int {
  let a = if !(p.verbs.last() is Some(Close)) { 1 } else { 2 }
  let b = if next_verb is (Some(Move) | Some(Close) | None) { 10 } else { 20 }
  a + b
}

pub fn case5_ambig_close_disambig() -> String {
  let p = make_rect_path()
  let r1 = check_verb(p, Some(Verb::Close))
  let r2 = check_verb(p, Some(Verb::Line))
  let r3 = check_verb(p, None)
  r1.to_string() + "," + r2.to_string() + "," + r3.to_string()
}

priv trait Accum {
  add1(Self, x : Int) -> Unit
  add_pair(Self, x : Int, y : Int) -> Unit
}

priv struct Counter {
  mut total : Int
}

impl Accum for Counter with add1(self, x) {
  self.total = self.total + x
}

impl Accum for Counter with add_pair(self, x, y) {
  Accum::add1(self, x * 10 + y)
}

fn drive(acc : &Accum, a : Int, b : Int) -> Unit {
  acc.add1(a)
  acc.add_pair(a, b)
}

priv trait Price {
  cost(Self) -> Int
}

priv struct Item {
  value : Int
}

fn Item::cost(self : Item) -> Int {
  self.value + 100
}

impl Price for Item with cost(self) {
  self.value + 1
}

priv trait Area {
  area(Self) -> Int
  name(Self, Int) -> String
}

priv struct Sq {
  s : Int
}

impl Area for Sq with area(self) {
  self.s * self.s
}

impl Area for Sq with name(self, tag) {
  "sq:" + self.s.to_string() + ":" + tag.to_string()
}

fn show_area(a : &Area) -> String {
  a.name(7) + "=" + a.area().to_string()
}

pub fn case6_dyn_trait_and_split_impl() -> String {
  let c : Counter = { total: 5 }
  let dyn_c : &Accum = (c as &Accum)
  drive(dyn_c, 2, 7)
  let it : Item = { value: 2 }
  let p_trait = Price::cost(it)
  let p_inherent = it.cost()
  let q : Sq = { s: 3 }
  let a_str = show_area(q as &Area)
  c.total.to_string() + "|" + p_trait.to_string() + "," + p_inherent.to_string() + "|" + a_str
}

pub fn run_all() -> String {
  "F1-1:" + case1_pool_unsafe_set() +
  "\nF1-2:" + case2_slice_iter() +
  "\nF1-3:" + case3_match_for_trailing_struct() +
  "\nF1-4:" + case4_float_double_ops() +
  "\nF1-5:" + case5_ambig_close_disambig() +
  "\nF1-6:" + case6_dyn_trait_and_split_impl()
}
'''

F1_SHADOW_MBT = r'''
fn Float::reinterpret_from_int(_x : Int) -> Float {
  7.0
}

pub fn run_shadow() -> String {
  Float::reinterpret_from_int(0).to_double().to_string()
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
    work = tempfile.mkdtemp(prefix="mbt2pion-f1-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])
        md = os.path.join(work, "moon_proj")
        os.makedirs(os.path.join(md, "f1"))
        os.makedirs(os.path.join(md, "cmd"))
        open(os.path.join(md, "moon.mod"), "w").write('name = "f1/oracle"\n')
        open(os.path.join(md, "f1", "moon.pkg"), "w").write("\n")
        open(os.path.join(md, "f1", "f1.mbt"), "w").write(F1_MBT)
        open(os.path.join(md, "cmd", "moon.pkg"), "w").write('import { "f1/oracle/f1" }\npkgtype(kind: "executable")\n')
        open(os.path.join(md, "cmd", "main.mbt"), "w").write('fn main { println(@f1.run_all()) }\n')
        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)

        pdir = os.path.join(work, "pion_f1")
        os.makedirs(os.path.join(pdir, "src"))
        open(os.path.join(pdir, "pion.toml"), "w").write(
            f'[package]\nname = "f1"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
        )
        run_cmd([
            bin_path, "--src", os.path.join(md, "f1"), "--out", os.path.join(pdir, "src"),
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc
        ])
        open(os.path.join(pdir, "src", "main.pion"), "w").write(
            'pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n'
        )
        pion_nat = run_cmd([args.pionc, "run", pdir])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", pdir])

        assert moon_out == pion_nat == pion_wasm, (
            f"3-ENGINE MISMATCH!\n--- MOON ---\n{moon_out}\n--- PION NATIVE ---\n{pion_nat}\n--- PION WASM32 ---\n{pion_wasm}"
        )

        # Independent shadow package: local `fn Float::reinterpret_from_int` must not be hijacked by Float::from_bits
        os.makedirs(os.path.join(md, "f1_shadow"))
        os.makedirs(os.path.join(md, "cmd_shadow"))
        open(os.path.join(md, "f1_shadow", "moon.pkg"), "w").write("\n")
        open(os.path.join(md, "f1_shadow", "shadow.mbt"), "w").write(F1_SHADOW_MBT)
        open(os.path.join(md, "cmd_shadow", "moon.pkg"), "w").write('import { "f1/oracle/f1_shadow" }\npkgtype(kind: "executable")\n')
        open(os.path.join(md, "cmd_shadow", "main.mbt"), "w").write('fn main { println(@f1_shadow.run_shadow()) }\n')
        moon_sh = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd_shadow"], cwd=md)

        sdir = os.path.join(work, "pion_f1_shadow")
        os.makedirs(os.path.join(sdir, "src"))
        open(os.path.join(sdir, "pion.toml"), "w").write(
            f'[package]\nname = "f1_shadow"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
        )
        run_cmd([
            bin_path, "--src", os.path.join(md, "f1_shadow"), "--out", os.path.join(sdir, "src"),
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc
        ])
        open(os.path.join(sdir, "src", "main.pion"), "w").write(
            'pub fn main(w : World) -> Int { io_println(w, run_shadow()); 0 }\n'
        )
        pion_sh_nat = run_cmd([args.pionc, "run", sdir])
        pion_sh_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", sdir])
        assert moon_sh == pion_sh_nat == pion_sh_wasm == "7", (
            f"SHADOW 3-ENGINE MISMATCH! moon={moon_sh!r} nat={pion_sh_nat!r} wasm={pion_sh_wasm!r}"
        )

        print("[f1-oracle] PASS: Moon wasm-gc == Pion native == Pion wasm32")
        print(moon_out)
        print("F1-SHADOW:" + moon_sh)
    finally:
        shutil.rmtree(work, ignore_errors=True)

if __name__ == "__main__":
    main()
