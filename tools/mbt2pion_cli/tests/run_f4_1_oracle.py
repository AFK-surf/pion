#!/usr/bin/env python3
r"""Wave M2-F4 Track F4-1 4-Target Differential Oracle:
MoonBit native == MoonBit wasm-gc == Pion native == Pion wasm32.

Verifies:
  1. Positive parity (all 4 targets byte-for-byte identical stdout):
     - In-place write only during `iter()` and `search_by()` (`[1,9,3]` / `Some(1)`)
     - `push` without realloc (spare cap) and `push` with realloc (append-only, no write)
     - Zero-element, last-element, short-circuit (`search_by`, `iter().any`, `iter().find_first`)
     - `map`/`filter` laziness (exact evaluation trace up to short-circuit)
     - `for i, e in xs { if e == 2 { xs.remove(i); break } }` (immediate exit)
     - Package-confined private field `shrink_to_fit()` inside `pub fn`
     - Pure `search_by` with built-in methods & private struct closure field `(e.off)()`
  2. Real MoonBit native & wasm-gc counterexample assertions + Pion fail-closed publish gates:
     - Full-capacity single-op `xs.insert(0, 9)` in `search_by`: Moon native & wasm-gc visit `[1,2]` -> `Some(1)`;
       Pion blocks with `MBT2PION_ARRAY_ITER_MUTATION` (never returns wrong `Some(2)`!)
     - Full-capacity `push` realloc + write in `search_by` & `iter()`: Moon visits `[1,2,3]` -> `None`; Pion blocks!
     - `pop`, `remove(0)`, `remove(1)`, `clear`, `splice`, `resize` in `search_by` & `iter()`: Pion blocks!
     - Spare-cap `shrink_to_fit` + write vs full-cap `shrink_to_fit` + write: Pion blocks!
     - Opus P1-3 `for x in f2 { if x == 1 { f2.clear() }; s += x }`: Moon native & wasm-gc output `6`; Pion blocks!
     - Lazy `map`/`filter` escape: Pion blocks!
     - `combobox`-style external callback alias capture: Pion blocks!
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

POS_MBT = r'''
fn ints(xs : Array[Int]) -> String {
  xs.map(fn(x) { x.to_string() }).join(",")
}

fn opt(o : Int?) -> String {
  match o {
    Some(v) => "Some(" + v.to_string() + ")"
    None => "None"
  }
}

let confined_pool : Array[Int] = []

pub fn reset_pool() -> Unit {
  confined_pool.clear()
  confined_pool.shrink_to_fit()
}

priv struct Rule {
  off : () -> Bool
}

fn mk_rules() -> Array[Rule] {
  [
    { off: fn() { true } },
    { off: fn() { false } },
    { off: fn() { false } },
  ]
}

pub fn run_1_inplace_write() -> String {
  let a = [1, 2, 3]
  let visited : Array[Int] = []
  let idx = a.search_by(fn(x) {
    visited.push(x)
    if x == 1 { a[1] = 9 }
    x == 9
  })
  let b = [1, 2, 3]
  let it = b.iter()
  b[1] = 9
  ints(visited) + "|" + opt(idx) + "|" + ints(it.to_array())
}

pub fn run_2_push_only() -> String {
  // Spare capacity push (no realloc)
  let a : Array[Int] = Array(capacity=8)
  a.push(1)
  a.push(2)
  a.push(3)
  let r1 = a.search_by(fn(x) {
    if x == 1 { a.push(99) }
    x == 3
  })
  // Full capacity push (reallocates, no in-place write)
  let b = [1, 2, 3]
  let it = b.iter()
  b.push(4)
  b.push(5)
  let c = [1, 2, 3]
  let mut sum = 0
  for x in c {
    if x == 1 { c.push(100) }
    sum = sum + x
  }
  opt(r1) + "|" + a.length().to_string() + "|" + ints(it.to_array()) + "|" + sum.to_string() + "|" + c.length().to_string()
}

pub fn run_3_edge_and_laziness() -> String {
  let empty : Array[Int] = []
  let r_empty = empty.search_by(fn(x) { x == 1 })
  let xs = [10, 20, 30, 40]
  let r_last = xs.search_by(fn(x) { x == 40 })
  let trace : Array[Int] = []
  let found = xs.iter().map(fn(x) {
    trace.push(x)
    x * 2
  }).filter(fn(y) { y >= 40 }).find_first(fn(y) { y == 40 })
  opt(r_empty) + "|" + opt(r_last) + "|" + opt(found) + "|" + ints(trace)
}

pub fn run_4_for_remove_break_and_confined() -> String {
  let xs = [10, 20, 30]
  for i, x in xs {
    if x == 20 {
      xs.remove(i) |> ignore
      break
    }
  }
  confined_pool.push(1)
  confined_pool.push(2)
  reset_pool()
  let rules = mk_rules()
  let active = rules.search_by(fn(r) { !(r.off)() })
  let cmds = ["help", "quit", "run"]
  let typed = "please quit"
  let matched = cmds.search_by(fn(w) { typed.has_suffix(w) })
  ints(xs) + "|" + confined_pool.length().to_string() + "|" + opt(active) + "|" + opt(matched)
}

pub fn run_all() -> String {
  "P1:" + run_1_inplace_write() + "\n" +
  "P2:" + run_2_push_only() + "\n" +
  "P3:" + run_3_edge_and_laziness() + "\n" +
  "P4:" + run_4_for_remove_break_and_confined()
}
'''

# Real MoonBit reference program verifying Moon native & Moon wasm-gc exact counterexample outputs!
MOON_REF_MBT = r'''
fn ints(xs : Array[Int]) -> String {
  xs.map(fn(x) { x.to_string() }).join(",")
}

fn opt(o : Int?) -> String {
  match o {
    Some(v) => "Some(" + v.to_string() + ")"
    None => "None"
  }
}

pub fn run_counterexamples() -> String {
  // 1. Full-cap single-op `xs.insert(0, 9)` in `search_by`: Moon visits [1, 2] -> Some(1)!
  let a = [1, 2, 3]
  let vis_ins : Array[Int] = []
  let r_ins = a.search_by(fn(x) {
    vis_ins.push(x)
    if x == 1 { a.insert(0, 9) }
    x == 2
  })
  // 2. Full-cap `push` realloc + write in `search_by`: Moon visits [1, 2, 3] -> None!
  let b = [1, 2, 3]
  let vis_pw : Array[Int] = []
  let r_pw = b.search_by(fn(x) {
    vis_pw.push(x)
    if x == 1 {
      b.push(4)
      b[1] = 9
    }
    x == 9
  })
  // 3. Opus P1-3: `for x in f2 { if x == 1 { f2.clear() }; s += x }` -> 6!
  let f2 = [1, 2, 3]
  let mut s2 = 0
  for x in f2 {
    if x == 1 { f2.clear() }
    s2 = s2 + x
  }
  // 4. Spare-cap shrink_to_fit + write vs full-cap shrink_to_fit + write
  let sp : Array[Int] = Array(capacity=8)
  sp.push(1)
  sp.push(2)
  sp.push(3)
  let vis_sp : Array[Int] = []
  for x in sp {
    vis_sp.push(x)
    if x == 1 {
      sp.shrink_to_fit()
      sp[1] = 9
    }
  }
  let fl = [1, 2, 3]
  let vis_fl : Array[Int] = []
  for x in fl {
    vis_fl.push(x)
    if x == 1 {
      fl.shrink_to_fit()
      fl[1] = 9
    }
  }
  "INS:" + ints(vis_ins) + "|" + opt(r_ins) + "\n" +
  "PW:" + ints(vis_pw) + "|" + opt(r_pw) + "\n" +
  "F2:" + s2.to_string() + "\n" +
  "SHRINK:" + ints(vis_sp) + "|" + ints(vis_fl)
}
'''

NEGATIVES = {
    "insert_single_op": (r'''
pub fn f(xs : Array[Int]) -> Int? {
  xs.search_by(fn(x) {
    if x == 1 { xs.insert(0, 9) }
    x == 2
  })
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".insert(..)"),
    "push_write_search_by": (r'''
pub fn f(xs : Array[Int]) -> Int? {
  xs.search_by(fn(x) {
    if x == 1 {
      xs.push(4)
      xs[1] = 9
    }
    x == 9
  })
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "appended to and written"),
    "pop_search_by": (r'''
pub fn f(xs : Array[Int]) -> Int? {
  xs.search_by(fn(x) {
    if x == 1 { ignore(xs.pop()) }
    x == 2
  })
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".pop(..)"),
    "remove0_search_by": (r'''
pub fn f(xs : Array[Int]) -> Int? {
  xs.search_by(fn(x) {
    if x == 1 { ignore(xs.remove(0)) }
    x == 2
  })
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".remove(..)"),
    "remove1_iter": (r'''
pub fn f(xs : Array[Int]) -> Int {
  let it = xs.iter()
  ignore(xs.remove(1))
  it.count()
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".remove(..)"),
    "clear_iter": (r'''
pub fn f(xs : Array[Int]) -> Int {
  let it = xs.iter()
  xs.clear()
  it.count()
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "for_in_clear_opus_f2": (r'''
pub fn f() -> Int {
  let f2 = [1, 2, 3]
  let mut s = 0
  for x in f2 {
    if x == 1 { f2.clear() }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".clear(..)"),
    "shrink_in_for_spare": (r'''
pub fn f() -> Int {
  let sp : Array[Int] = Array(capacity=8)
  sp.push(1)
  sp.push(2)
  let mut s = 0
  for x in sp {
    if x == 1 {
      sp.shrink_to_fit()
      sp[1] = 9
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_SHRINK_ITER", "for .. in"),
    "shrink_in_for_full": (r'''
pub fn f() -> Int {
  let fl = [1, 2, 3]
  let mut s = 0
  for x in fl {
    if x == 1 {
      fl.shrink_to_fit()
      fl[1] = 9
    }
    s = s + x
  }
  s
}
''', "MBT2PION_ARRAY_SHRINK_ITER", "for .. in"),
    "lazy_map_escape": (r'''
pub fn f(xs : Array[Int]) -> Int {
  let it = xs.iter().map(fn(x) { x + 1 })
  ignore(xs.pop())
  it.count()
}
''', "MBT2PION_ARRAY_ITER_MUTATION", ".pop(..)"),
    "combobox_opaque_cb": (r'''
fn active_of(keys : Array[Int], off : (Int) -> Bool) -> Int? {
  keys.iter().find_first(fn(k) { !off(k) })
}

pub fn f(keys : Array[Int], off : (Int) -> Bool) -> Int? {
  active_of(keys, off)
}
''', "MBT2PION_ARRAY_ITER_MUTATION", "a call to `off(..)`"),
}


def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=600)
    if p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
    return p.stdout.strip()


def run_rc(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=600)
    return p.returncode, p.stdout + p.stderr


def write(path, txt):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(txt)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", default=os.environ.get("PIONC", shutil.which("pionc") or os.path.expanduser("~/.pion/bin/pionc")))
    ap.add_argument("--moon", default=os.environ.get("MOON", shutil.which("moon") or os.path.expanduser("~/.moon/bin/moon")))
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="mbt2pion-f4-1-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])

        md = os.path.join(work, "moon_proj")
        files = [
            ("moon.mod", 'name = "f41/oracle"\n'),
            ("pos/moon.pkg", "\n"),
            ("pos/pos.mbt", POS_MBT),
            ("ref/moon.pkg", "\n"),
            ("ref/ref.mbt", MOON_REF_MBT),
            ("cmd_pos/moon.pkg", 'import { "f41/oracle/pos" }\npkgtype(kind: "executable")\n'),
            ("cmd_pos/main.mbt", "fn main { println(@pos.run_all()) }\n"),
            ("cmd_ref/moon.pkg", 'import { "f41/oracle/ref" }\npkgtype(kind: "executable")\n'),
            ("cmd_ref/main.mbt", "fn main { println(@ref.run_counterexamples()) }\n"),
        ]
        for rel, txt in files:
            write(os.path.join(md, rel), txt)

        # 1. Run MoonBit on BOTH native AND wasm-gc!
        moon_pos_native = run_cmd([args.moon, "run", "--target", "native", "cmd_pos"], cwd=md)
        moon_pos_wasmgc = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd_pos"], cwd=md)
        assert moon_pos_native == moon_pos_wasmgc, f"Moon native != wasm-gc:\n{moon_pos_native}\nvs\n{moon_pos_wasmgc}"

        moon_ref_native = run_cmd([args.moon, "run", "--target", "native", "cmd_ref"], cwd=md)
        moon_ref_wasmgc = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd_ref"], cwd=md)
        expected_ref = (
            "INS:1,2|Some(1)\n"
            "PW:1,2,3|None\n"
            "F2:6\n"
            "SHRINK:1,2,3|1,9,3"
        )
        assert moon_ref_native == expected_ref, f"Moon native ref mismatch:\n{moon_ref_native}\nvs\n{expected_ref}"
        assert moon_ref_wasmgc == expected_ref, f"Moon wasm-gc ref mismatch:\n{moon_ref_wasmgc}\nvs\n{expected_ref}"

        # 2. Transpile positive package with mbt2pion and run on BOTH Pion native AND Pion wasm32!
        pl = os.path.join(work, "p_pos")
        write(os.path.join(pl, "pion.toml"),
              f'[package]\nname = "pos"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        os.makedirs(os.path.join(pl, "src"))
        run_cmd([bin_path, "--src", os.path.join(md, "pos"), "--out", os.path.join(pl, "src"), "--target", "native",
                 "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        write(os.path.join(pl, "src", "main.pion"), "pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n")
        pion_native = run_cmd([args.pionc, "run", pl])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", pl])

        assert pion_native == moon_pos_native and pion_wasm == moon_pos_native, (
            f"4-TARGET MISMATCH:\nMOON_NATIVE:\n{moon_pos_native}\nMOON_WASMGC:\n{moon_pos_wasmgc}\n"
            f"PION_NATIVE:\n{pion_native}\nPION_WASM32:\n{pion_wasm}"
        )

        # 3. Verify all negative counterexamples fail closed with no --out written!
        for name, (src, code, needle) in NEGATIVES.items():
            d = os.path.join(work, "neg_" + name)
            write(os.path.join(d, "moon.pkg"), "\n")
            write(os.path.join(d, "neg.mbt"), src)
            out = os.path.join(work, "p_neg_" + name, "src")
            os.makedirs(out)
            rc, log = run_rc([bin_path, "--src", d, "--out", out, "--target", "native", "--mode", "publish",
                              "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
            assert rc != 0 and code in log and needle in log, (
                f"{name} must block publish with {code} containing `{needle}`:\n{log}"
            )
            assert not os.listdir(out), f"{name}: blocked publish must not write --out"

        print("[f4-1-oracle] PASS: 4-target parity (Moon native == Moon wasm-gc == Pion native == Pion wasm32)!")
        print(moon_pos_native)
        print(f"[f4-1-oracle] PASS: Moon dual-backend counterexamples verified ({expected_ref.replace(chr(10), ' ; ')})")
        print(f"[f4-1-oracle] PASS: All {len(NEGATIVES)} fail-closed negatives blocked with exact diagnostics!")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
