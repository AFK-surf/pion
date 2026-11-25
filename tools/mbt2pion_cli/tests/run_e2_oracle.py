#!/usr/bin/env python3
r"""Wave M2-E2 3-Engine Differential Oracle: Moon wasm-gc == Pion native == Pion wasm32."""
import argparse, os, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

ORIG_MBT = r'''
pub(all) enum Side { Left(w~ : Int, h~ : Int); Right }
pub fn Side::area(self : Side) -> Int { match self { Left(w~, h~) => w * h; Right => 0 } }
pub fn rect(a : Int, b : Int) -> Int { a * 10 + b }
pub fn alt_val() -> Int { 11 }
'''
OTHER_MBT = 'pub fn alt_val() -> Int { 22 }\n'
MID_MBT = 'pub using @real { type Side, rect }\npub using @orig { alt_val }\npub fn mid_tag() -> Int { 42 }\n'
LEAF_MBT = r'''
using @m { type Side }
priv suberror Bad
fn bad() -> Int raise Bad { raise Bad }
fn case1_inner() -> Int raise Bad { let k = try { bad() } catch { Bad => 7 }; k + 1 }
pub fn run_case1() -> Int { try { case1_inner() } catch { Bad => -1 } }
pub fn run_case2() -> Int {
  try { let x = try { bad() } catch { Bad => return 77 }; if x < 0 { raise Bad }; x + 100 } catch { Bad => 999 }
}
fn parse_color_model(mode : Int, v1 : Double?, v2 : Double?) -> Int? {
  let mut color = 10
  let ok = fn(v : Double?) -> Double raise Failure { match v { Some(x) => x; None => fail("bad") } }
  try {
    if mode == 0 { return None }
    let a = ok(v1); let b = ok(v2)
    color = color + a.to_int() * 10 + b.to_int()
  } catch { _ => return None }
  Some(color)
}
pub fn run_case3() -> String {
  let a = match parse_color_model(1, Some(2.0), Some(3.0)) { Some(v) => v; None => -1 }
  let b = match parse_color_model(1, Some(2.0), None) { Some(v) => v; None => -1 }
  let c = match parse_color_model(0, Some(2.0), Some(3.0)) { Some(v) => v; None => -1 }
  a.to_string() + "," + b.to_string() + "," + c.to_string()
}
priv struct A { x : Int }
priv struct B { x : Int }
priv suberror Other
fn A::parse(self : A) -> Int raise Bad { if self.x < 0 { raise Bad }; self.x * 2 }
fn make_a() -> A { { x: -1 } }
fn B::parse(self : B) -> Int { self.x + 100 }
fn B::fail(self : B) -> Int { self.x }
fn other_err() -> Int raise Other { raise Other }
pub fn run_case4() -> String {
  let a1 : A = { x: 5 }; let a2 : A = { x: -1 }; let b1 : B = { x: 7 }
  let r1 = try { a1.parse() } catch { Bad => -9 }
  let r2 = try { a2.parse() } catch { Bad => -9 }
  let r3 = b1.parse()
  let ok = fn(v : Int) -> Int raise Bad { if v < 0 { raise Bad }; v + 1 }
  let r4 = try { ok(4) } catch { Bad => -1 }
  let r5 = { let ok = fn(v : Int) -> Int { v * 10 }; ok(4) }
  let p = make_a()
  let r6 = try { let _ = p.parse(); 10 } catch { Bad => 9 }
  let r7 = try { let _ = make_a().parse(); 10 } catch { Bad => 9 }
  let r8 = try { let s = "\{ { let _ = bad(); 3 } }"; s.length() + 10 } catch { Bad => 9 }
  let r9 = try { let x = try { other_err() } catch { Other => 7 }; if x < 0 { raise Bad }; x + 1 } catch { Bad => -1 }
  let fail = fn(s : String) -> Int { s.length() }
  let r10 = fail("abc")
  let r11 = try { let _ = b1.fail(); bad() } catch { Bad => 7 }
  let r12 = try { let fail = fn(s : String) -> Int { s.length() }; let k = fail("abc"); if k == 0 { let _ = bad() }; k } catch { Bad => 9 }
  let r13 = try { let fail = fn(i : Int) -> Int { i + 1 }; if false { let _ = bad() }; "\{fail(2)}" } catch { Bad => "bad" }
  if Some(2) is Some(bad) { ignore(bad) }
  let r14 = try { let _ = bad(); 10 } catch { Bad => 9 }
  let pa : A = { x: -1 }
  if Some(b1) is Some(pa) { ignore(pa.x) }
  let r15 = try { let _ = pa.parse(); 10 } catch { Bad => 9 }
  r1.to_string() + "," + r2.to_string() + "," + r3.to_string() + "," + r4.to_string() + "," + r5.to_string() + "," + r6.to_string() + "," + r7.to_string() + "," + r8.to_string() + "," + r9.to_string() + "," + r10.to_string() + "," + r11.to_string() + "," + r12.to_string() + "," + r13 + "," + r14.to_string() + "," + r15.to_string()
}
pub fn run_case5() -> String {
  let s : Side = @m.Side::Left(h=4, w=3)
  let a = @m.Side::area(s); let rect = 99; let r = @m.rect(2, 5)
  "a=\{a},loc=\{rect},r=\{r},i=\{@m.rect(3, 6)},m=\{@m.mid_tag()},alt=\{@m.alt_val()}"
}
pub fn run_all() -> String {
  "E2-1:" + run_case1().to_string() + "\nE2-2:" + run_case2().to_string() + "\nE2-3:" + run_case3() + "\nE2-4:" + run_case4() + "\nE2-5:" + run_case5()
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
    work = tempfile.mkdtemp(prefix="mbt2pion-e2-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])
        md = os.path.join(work, "moon_proj")
        for sub in ("orig", "other", "mid", "leaf", "cmd"): os.makedirs(os.path.join(md, sub))
        for rel, txt in [("moon.mod", 'name = "e2/oracle"\n'), ("orig/moon.pkg", "\n"), ("orig/orig.mbt", ORIG_MBT), ("other/moon.pkg", "\n"), ("other/other.mbt", OTHER_MBT), ("mid/moon.pkg", 'import { "e2/oracle/orig" @real, "e2/oracle/other" @orig }\n'), ("mid/mid.mbt", MID_MBT), ("leaf/moon.pkg", 'import { "e2/oracle/mid" @m }\n'), ("leaf/leaf.mbt", LEAF_MBT), ("cmd/moon.pkg", 'import { "e2/oracle/leaf" }\npkgtype(kind: "executable")\n'), ("cmd/main.mbt", 'fn main { println(@leaf.run_all()) }\n')]:
            open(os.path.join(md, rel), "w").write(txt)
        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)
        po, p2, pm, pl = os.path.join(work, "p_orig"), os.path.join(work, "p_other"), os.path.join(work, "p_mid"), os.path.join(work, "p_leaf")
        for d in (po, p2, pm, pl): os.makedirs(os.path.join(d, "src"))
        open(os.path.join(po, "pion.toml"), "w").write(f'[package]\nname = "orig"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "orig"), "--out", os.path.join(po, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        open(os.path.join(p2, "pion.toml"), "w").write(f'[package]\nname = "other"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "other"), "--out", os.path.join(p2, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        open(os.path.join(pm, "pion.toml"), "w").write(f'[package]\nname = "mid"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\norig = {{ path = "{po}" }}\nother = {{ path = "{p2}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "mid"), "--out", os.path.join(pm, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--dep", f"orig={po}", "--dep", f"other={p2}", "--pionc", args.pionc])
        assert '"name":"alt_val","kind":"value","target_pkg":"other","target_name":"alt_val"' in open(os.path.join(pm, "src", "mbt2pion_abi.json")).read()
        run_cmd([bin_path, "--src", os.path.join(md, "leaf"), "--out", os.path.join(pl, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--dep", f"orig={po}", "--dep", f"other={p2}", "--dep", f"mid={pm}", "--pionc", args.pionc])
        open(os.path.join(pl, "pion.toml"), "w").write(f'[package]\nname = "leaf"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\norig = {{ path = "{po}" }}\nother = {{ path = "{p2}" }}\nmid = {{ path = "{pm}" }}\n')
        open(os.path.join(pl, "src", "main.pion"), "w").write('pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n')
        pion_native, pion_wasm = run_cmd([args.pionc, "run", pl]), run_cmd([args.pionc, "run", "--target", "wasm32", pl])
        expected = "E2-1:8\nE2-2:77\nE2-3:33,-1,-1\nE2-4:10,-9,107,5,40,9,9,9,8,3,7,3,3,9,9\nE2-5:a=12,loc=99,r=25,i=36,m=42,alt=22"
        assert moon_out == expected and pion_native == moon_out and pion_wasm == moon_out, f"MISMATCH:\nM:{moon_out}\nN:{pion_native}\nW:{pion_wasm}"
        print("[e2-oracle] PASS: 3-engine (moon wasm-gc == pion-native == pion-wasm32) 100% identical!\n" + moon_out)
    finally:
        shutil.rmtree(work, ignore_errors=True)

if __name__ == "__main__":
    main()
