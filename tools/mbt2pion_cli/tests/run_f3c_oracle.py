#!/usr/bin/env python3
r"""Wave M2-F3c 3-Engine Differential Oracle: Moon wasm-gc == Pion native == Pion wasm32.

Covers:
  1. `match` arm `for k, v in map`, C-style `for`, multiline `match\n  expr { ... }`,
     and tuple-destructuring `for (a, b) in xs` / `for idx, (a, b) in xs` / nested `for ((x, y), z) in xs`
  2. High-frequency core methods: `Array::search_by`, `shrink_to_fit`, `push_iter`, `rev`, `drain`,
     `Option::map_or`, `Option::bind`, `Map::copy`, `Map::get_or_init`, `Iter::to_array`, `Char::is_ascii_alphabetic`
  3. Recursive nested struct patterns (`Some({ hit: Some({ back: Some(p), .. }), .. })`),
     tuple-wrapped struct patterns (`(Some({ way: Some(w), .. }), _)`), and `is (None | Some({ back: None, .. }))`
"""
import argparse, os, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

F3C_MBT = r'''
priv struct CBox {
  n : Int
}

fn CBox::ok(self : CBox) -> Bool {
  self.n > 0
}

pub fn run_f3c_1() -> String {
  let m : Map[Int, Int] = { 1: 10, 2: 20, 3: 30 }
  let mut s1 = 0
  match Some(3) {
    Some(limit) if limit > 0 =>
      for k, v in m {
        if k < limit {
          s1 = s1 + v
        }
      }
    _ => ()
  }
  let mut s2 = 0
  let xs : Array[Int] = [4, 5, 6]
  match (None : Int?) {
    Some(_) => ()
    None =>
      for i = 0; i < xs.length(); i = i + 1 {
        s2 = s2 + xs[i]
      }
  }
  let mut s3 = 0
  match Some(1) {
    Some(idx) =>
      match
        xs.get(idx) {
        Some(v) => s3 = v * 10
        None => ()
      }
    None => ()
  }
  let pairs : Array[(Int, Int)] = [(1, 2), (3, 4), (5, 6)]
  let mut s4 = 0
  for (a, b) in pairs {
    if a == 3 {
      continue
    }
    s4 = s4 + a * 10 + b
  }
  let mut s5 = 0
  for idx, (a, _) in pairs {
    s5 = s5 + idx * a
  }
  let nested : Array[((Int, Int), Int)] = [((1, 2), 3), ((4, 5), 6)]
  let mut s6 = 0
  for ((x, y), z) in nested {
    s6 = s6 + x + y * 2 + z * 3
  }
  let mut s7 = 0
  match Some(4) {
    Some(t) => while { s7 < t } { s7 = s7 + 1 }
    None => ()
  }
  let mut s8 = 3
  match Some(1) {
    Some(_) => while { CBox::{ n: s8 } }
      .ok() { s8 = s8 - 1 }
    None => ()
  }
  s1.to_string() + "," + s2.to_string() + "," + s3.to_string() + "," + s4.to_string() + "," + s5.to_string() + "," + s6.to_string() + "," + s7.to_string() + "," + s8.to_string()
}

pub fn run_f3c_2() -> String {
  let arr : Array[Int] = [10, 25, 30, 45]
  let idx1 = arr.search_by(fn(x) { x > 20 }).unwrap_or(-1)
  let idx2 = arr.search_by(fn(x) { x > 100 }).unwrap_or(-1)
  let rev_arr = arr.rev()
  let rev_s = rev_arr.map(fn(x) { x.to_string() }).join("-")
  let orig_s = arr.map(fn(x) { x.to_string() }).join("-")
  let drained = arr.drain(1, 3)
  let dr_s = drained.map(fn(x) { x.to_string() }).join("-")
  let rem_s = arr.map(fn(x) { x.to_string() }).join("-")
  arr.push_iter([7, 8].iter())
  let pushed_s = arr.map(fn(x) { x.to_string() }).join("-")
  let self_arr : Array[Int] = [1, 2]
  self_arr.push_iter(self_arr.iter())
  let self_s = self_arr.map(fn(x) { x.to_string() }).join("-")

  let mo1 = Some(5).map_or(99, fn(x) { x * 3 })
  let mo2 = (None : Int?).map_or(99, fn(x) { x * 3 })
  let b1 = Some(4).bind(fn(x) { if x > 0 { Some(x + 1) } else { None } }).unwrap_or(-1)
  let b2 = Some(-2).bind(fn(x) { if x > 0 { Some(x + 1) } else { None } }).unwrap_or(-1)
  let b3 = (None : Int?).bind(fn(x) { Some(x + 1) }).unwrap_or(-1)

  let m : Map[String, Int] = { "a": 1, "b": 2 }
  let mut init_calls = 0
  let g1 = m.get_or_init("a", fn() {
    init_calls = init_calls + 1
    100
  })
  let g2 = m.get_or_init("c", fn() {
    init_calls = init_calls + 1
    3
  })
  let cp = m.copy()
  cp.set("b", 20)
  cp.set("d", 4)
  let m_b = m.get("b").unwrap_or(-1)
  let cp_keys : Array[String] = []
  for k, v in cp {
    cp_keys.push(k + "=" + v.to_string())
  }

  let alpha = 'a'.is_ascii_alphabetic().to_string() + "," +
    'Z'.is_ascii_alphabetic().to_string() + "," +
    '5'.is_ascii_alphabetic().to_string() + "," +
    '_'.is_ascii_alphabetic().to_string()

  idx1.to_string() + "," + idx2.to_string() + "|" + rev_s + "|" + orig_s + "|" +
    dr_s + "|" + rem_s + "|" + pushed_s + "|" + self_s + "|" +
    mo1.to_string() + "," + mo2.to_string() + "," + b1.to_string() + "," + b2.to_string() + "," + b3.to_string() + "|" +
    g1.to_string() + "," + g2.to_string() + "," + init_calls.to_string() + "," + m_b.to_string() + "," + cp_keys.join(";") + "|" +
    alpha
}

priv struct Leaf {
  rest : Int
}

priv struct Mid {
  back : Leaf?
}

priv struct Outer {
  hit : Mid?
  way : Leaf?
}

fn eval_nested(a : Outer?, b : Mid?) -> Int {
  if a is None && b is (None | Some({ back: None, .. })) {
    return -1
  }
  let x = match a {
    Some({ hit: Some({ back: Some(p), .. }), .. }) => p.rest
    _ => 0
  }
  let y = match (a, b) {
    (Some({ way: Some(w), .. }), _) => w.rest * 10
    (_, Some({ back: Some(p), .. })) => p.rest * 100
    _ => 7
  }
  x + y
}

pub fn run_f3c_3() -> String {
  let l1 : Leaf = { rest: 3 }
  let l2 : Leaf = { rest: 5 }
  let m_none : Mid = { back: None }
  let m_some : Mid = { back: Some(l1) }
  let o_both : Outer = { hit: Some(m_some), way: Some(l2) }
  let o_hit_only : Outer = { hit: Some(m_none), way: None }
  let r1 = eval_nested(None, None)
  let r2 = eval_nested(None, Some(m_none))
  let r3 = eval_nested(None, Some(m_some))
  let r4 = eval_nested(Some(o_both), None)
  let r5 = eval_nested(Some(o_hit_only), Some(m_some))
  let r6 = eval_nested(Some(o_hit_only), Some(m_none))
  let same_ctor_hit = fn(x : Leaf?) -> Int {
    if x is (Some({ rest: 1 }) | Some({ rest: 3 })) { 1 } else { 0 }
  }
  let r7 = same_ctor_hit(Some(l1))
  let r8 = same_ctor_hit(Some(l2))
  let r9 = same_ctor_hit(None)
  r1.to_string() + "," + r2.to_string() + "," + r3.to_string() + "," + r4.to_string() + "," + r5.to_string() + "," + r6.to_string() + "," + r7.to_string() + "," + r8.to_string() + "," + r9.to_string()
}

pub fn run_all() -> String {
  "F3c-1:" + run_f3c_1() + "\nF3c-2:" + run_f3c_2() + "\nF3c-3:" + run_f3c_3()
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
    work = tempfile.mkdtemp(prefix="mbt2pion-f3c-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])
        md = os.path.join(work, "moon_proj")
        for sub in ("lib", "cmd"):
            os.makedirs(os.path.join(md, sub))
        for rel, txt in [
            ("moon.mod", 'name = "f3c/oracle"\n'),
            ("lib/moon.pkg", "\n"),
            ("lib/f3c.mbt", F3C_MBT),
            ("cmd/moon.pkg", 'import { "f3c/oracle/lib" }\npkgtype(kind: "executable")\n'),
            ("cmd/main.mbt", 'fn main { println(@lib.run_all()) }\n'),
        ]:
            open(os.path.join(md, rel), "w").write(txt)
        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)

        pl = os.path.join(work, "p_lib")
        os.makedirs(os.path.join(pl, "src"))
        open(os.path.join(pl, "pion.toml"), "w").write(
            f'[package]\nname = "f3clib"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
        )
        run_cmd([
            bin_path, "--src", os.path.join(md, "lib"), "--out", os.path.join(pl, "src"),
            "--package-manifest", os.path.join(pl, "pion.toml"),
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
        ])
        open(os.path.join(pl, "src", "main.pion"), "w").write(
            'pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n'
        )
        pion_native = run_cmd([args.pionc, "run", pl])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", pl])

        expected = (
            "F3c-1:30,15,50,68,13,46,4,0\n"
            "F3c-2:1,-1|45-30-25-10|10-25-30-45|25-30|10-45|10-45-7-8|1-2-1-2|15,99,5,-1,-1|1,3,1,2,a=1;b=20;c=3;d=4|true,true,false,false\n"
            "F3c-3:-1,-1,300,53,300,7,1,0,0"
        )
        assert moon_out == expected and pion_native == moon_out and pion_wasm == moon_out, (
            f"MISMATCH:\nEXPECTED:\n{expected}\nMOON:\n{moon_out}\nNATIVE:\n{pion_native}\nWASM32:\n{pion_wasm}"
        )
        print("[f3c-oracle] PASS: 3-engine (moon wasm-gc == pion-native == pion-wasm32) 100% identical!\n" + moon_out)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
