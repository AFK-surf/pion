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

pub fn run_all() -> String {
  "X:" + case_cross_pkg() +
    "\nR:" + case_rethrow_and_nested() +
    "\nI:" + case_interp_and_struct_update() +
    "\nH:" + case_headers_in_try()
}
'''

NEGATIVE_CASES = [
    (
        "incomplete_catch",
        "priv suberror E { A; B(Int) }\nfn g() -> Int raise E { raise A }\npub fn f() -> Int { g() catch { A => 1 } }\n",
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
        for sub in ("up", "custom_json", "down", "cmd"):
            os.makedirs(os.path.join(md, sub))
        files = [
            ("moon.mod", 'name = "f6/oracle"\n'),
            ("up/moon.pkg", "\n"),
            ("up/up.mbt", UP_MBT),
            ("custom_json/moon.pkg", "\n"),
            ("custom_json/cj.mbt", CUSTOM_JSON_MBT),
            (
                "down/moon.pkg",
                'import { "f6/oracle/up", "f6/oracle/custom_json" @json, "moonbitlang/core/json" @j }\n',
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

        # 2. Transpile `up`, `custom_json`, `down` via real `mbt2pion_cli --mode publish`
        p_up = os.path.join(work, "p_up")
        p_cj = os.path.join(work, "p_cj")
        p_dn = os.path.join(work, "p_dn")
        for d in (p_up, p_cj, p_dn):
            os.makedirs(os.path.join(d, "src"))

        with open(os.path.join(p_up, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "up"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "up"), "--out", os.path.join(p_up, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        up_abi_txt = open(os.path.join(p_up, "src", "mbt2pion_abi.json")).read()
        assert '"raising_fns"' in up_abi_txt and '"parse_code"' in up_abi_txt, f"missing raising_fns in up ABI: {up_abi_txt}"

        with open(os.path.join(p_cj, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "custom_json"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        run_cmd([bin_path, "--src", os.path.join(md, "custom_json"), "--out", os.path.join(p_cj, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])

        with open(os.path.join(p_dn, "pion.toml"), "w") as f:
            f.write(
                f'[package]\nname = "down"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nup = {{ path = "{p_up}" }}\ncustom_json = {{ path = "{p_cj}" }}\n'
            )
        run_cmd([
            bin_path,
            "--src", os.path.join(md, "down"),
            "--out", os.path.join(p_dn, "src"),
            "--target", "native",
            "--mode", "publish",
            "--mbt-compat", COMPAT_DIR,
            "--dep", f"up={p_up}",
            "--dep", f"custom_json={p_cj}",
            "--pionc", args.pionc,
        ])
        with open(os.path.join(p_dn, "src", "main.pion"), "w") as f:
            f.write("pub fn main(w : World) -> Int {\n  io_println(w, run_all())\n  0\n}\n")

        # 3. Run Pion native & Pion wasm32 and assert 4-target equality
        pion_nat = run_cmd([args.pionc, "run", p_dn]).stdout.strip()
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", p_dn]).stdout.strip()
        expected = "X:31,-14,5,203,1,0\nR:50,40,60,50,209,5,103,7\nI:v=9|err|15:2\nH:24,12,6,11"
        assert moon_nat == expected, f"Expected mismatch:\nGOT:\n{moon_nat}\nEXP:\n{expected}"
        assert pion_nat == moon_nat and pion_wasm == moon_nat, (
            f"4-target mismatch:\nMoon-nat:\n{moon_nat}\nMoon-wgc:\n{moon_wgc}\nPion-nat:\n{pion_nat}\nPion-wasm:\n{pion_wasm}"
        )
        print("[f6-1-oracle] PASS: 4-engine (moon native == moon wasm-gc == pion native == pion wasm32) 100% identical!\n" + moon_nat)

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
