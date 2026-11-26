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
  p1.to_string() + "," + p2.to_string() + "," + p3.to_string() + "," + top_shadow_block.to_string() + "," + top_shadow_match.to_string() + "," + p4.to_string() + "," + p5.to_string() + "," + p6.to_string()
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
        expected = "X:31,-14,5,203,1,0\nR:50,40,60,50,209,5,103,7\nI:v=9|err|15:2\nH:24,12,6,11\nU:77,-21\nS:7,1,8,55,2|42,42,7,42,42,7,42,9"
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
