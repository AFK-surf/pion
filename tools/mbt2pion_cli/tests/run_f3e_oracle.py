#!/usr/bin/env python3
r"""Wave M2-F3e 3-Engine Differential Oracle: Moon wasm-gc == Pion native == Pion wasm32.

`Array[T]` / `FixedArray[T]` `.unsafe_get(i)` / `.unsafe_set(i, v)` are lowered to native `recv[i]` /
`{ recv[i] = v }` instead of the cross-package generic `mbt_compat::*_unsafe_*` helpers. Covers:
  1. Evaluation order: receiver before index before value, even when the index or value reassigns the
     receiver field (`h.xs.unsafe_get({ h.xs = other; 0 })`, `h.xs.unsafe_set({ ... }, { h.xs = other; ... })`)
  2. Non-lvalue receivers (`get_arr().unsafe_set(0, 7)`), 2-D chains (`grid.unsafe_get(1).unsafe_set(0, 5)`)
  3. Expression positions: `if` / `match` arms, `let _ =`, multi-line calls with trailing commas
  4. Untouched receivers: custom struct `P::unsafe_get` / `P::unsafe_set`, `String::unsafe_get`
and asserts the generated `.pion` holds no `arr_unsafe_*` / `fixed_array_unsafe_*` helper call.
"""
import argparse, os, re, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

F3E_MBT = r'''
priv struct Holder {
  mut xs : Array[Int]
  fs : FixedArray[Int]
}

priv struct P {
  v : Int
}

fn P::unsafe_get(self : P, i : Int) -> Int {
  self.v * 100 + i
}

fn P::unsafe_set(self : P, i : Int, x : Int) -> Int {
  self.v + i + x
}

fn show(a : Array[Int]) -> String {
  let mut s = ""
  for x in a {
    s = s + x.to_string() + ","
  }
  s
}

fn show_fa(a : FixedArray[Int]) -> String {
  let mut s = ""
  for x in a {
    s = s + x.to_string() + ","
  }
  s
}

fn get_arr(log : Array[String], a : Array[Int]) -> Array[Int] {
  log.push("recv")
  a
}

fn get_fa(log : Array[String], a : FixedArray[Int]) -> FixedArray[Int] {
  log.push("frecv")
  a
}

pub fn run_f3e_1() -> String {
  let log : Array[String] = []
  let h : Holder = { xs: [1, 2, 3], fs: FixedArray::make(3, 0) }
  let other = [100, 200, 300]
  let g = h.xs.unsafe_get({ h.xs = other; 0 })
  h.xs = [1, 2, 3]
  let old = h.xs
  h.xs.unsafe_set({ log.push("i"); 1 }, { h.xs = other; log.push("v"); 99 })
  g.to_string() + "|" + show(old) + "|" + show(h.xs) + "|" + show(other) + "|" + log.join(";")
}

pub fn run_f3e_2() -> String {
  let log : Array[String] = []
  let base = [0, 0]
  get_arr(log, base).unsafe_set(0, 7)
  let g2 = get_arr(log, base).unsafe_get(0)
  let fbase : FixedArray[Int] = FixedArray::make(2, 5)
  get_fa(log, fbase).unsafe_set(1, 8)
  let grid : Array[Array[Int]] = [[1, 2], [3, 4]]
  grid.unsafe_get(1).unsafe_set(0, 5)
  let d = grid.unsafe_get(1).unsafe_get(0) * 10 + grid.unsafe_get(0).unsafe_get(1)
  g2.to_string() + "|" + show(base) + "|" + show_fa(fbase) + "|" + d.to_string() + "|" + log.join(";")
}

pub fn run_f3e_3() -> String {
  let h : Holder = { xs: [4, 5, 6], fs: FixedArray::make(3, 0) }
  let base = [1, 0]
  let n = if base.unsafe_get(0) > 0 {
    base.unsafe_set(1, 4)
    1
  } else {
    0
  }
  match n {
    1 => h.fs.unsafe_set(2, 9)
    _ => ()
  }
  let _ = h.fs.unsafe_set(0, h.fs.unsafe_get(2) + 1)
  h.fs.unsafe_set(
    h.fs.unsafe_get(0) - 9,
    if n > 0 { 5 } else { 6 },
  )
  let w = if n > 1 { h.xs.unsafe_get(0) } else { h.xs.unsafe_get(2) }
  show(base) + "|" + show_fa(h.fs) + "|" + w.to_string()
}

pub fn run_f3e_4() -> String {
  let p : P = { v: 3 }
  let s = "a\u{e9}\u{1F600}z"
  let ps = p.unsafe_get(2).to_string() + "," + p.unsafe_set(1, 2).to_string()
  let su = s.unsafe_get(1).to_int().to_string() + "," + s.unsafe_get(2).to_int().to_string() + "," + s.unsafe_get(4).to_int().to_string()
  ps + "|" + su
}

pub fn run_all() -> String {
  "F3e-1:" + run_f3e_1() + "\nF3e-2:" + run_f3e_2() + "\nF3e-3:" + run_f3e_3() + "\nF3e-4:" + run_f3e_4()
}
'''

FORBIDDEN = re.compile(r"\b(arr_unsafe_get|arr_unsafe_set|fixed_array_unsafe_get|fixed_array_unsafe_set)\b")


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
    work = tempfile.mkdtemp(prefix="mbt2pion-f3e-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])
        md = os.path.join(work, "moon_proj")
        for sub in ("lib", "cmd"):
            os.makedirs(os.path.join(md, sub))
        for rel, txt in [
            ("moon.mod", 'name = "f3e/oracle"\n'),
            ("lib/moon.pkg", "\n"),
            ("lib/f3e.mbt", F3E_MBT),
            ("cmd/moon.pkg", 'import { "f3e/oracle/lib" }\npkgtype(kind: "executable")\n'),
            ("cmd/main.mbt", "fn main { println(@lib.run_all()) }\n"),
        ]:
            open(os.path.join(md, rel), "w").write(txt)
        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)

        pl = os.path.join(work, "p_lib")
        os.makedirs(os.path.join(pl, "src"))
        run_cmd([bin_path, "--src", os.path.join(md, "lib"), "--out", os.path.join(pl, "src"), "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        gen = ""
        for name in sorted(os.listdir(os.path.join(pl, "src"))):
            if name.endswith(".pion"):
                gen += open(os.path.join(pl, "src", name)).read()
        hits = FORBIDDEN.findall(gen)
        assert not hits, f"generated .pion still calls generic unsafe helpers: {hits}\n{gen}"
        assert "mbt_compat::utf16_code_unit_at(s, " in gen, f"String::unsafe_get must keep its UTF-16 helper\n{gen}"
        assert "p.unsafe_get(2)" in gen and "p.unsafe_set(1, 2)" in gen, f"custom struct methods must stay untouched\n{gen}"
        open(os.path.join(pl, "pion.toml"), "w").write(f'[package]\nname = "f3elib"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        open(os.path.join(pl, "src", "main.pion"), "w").write('pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n')
        pion_native = run_cmd([args.pionc, "run", pl])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", pl])

        expected = (
            "F3e-1:1|1,99,3,|100,200,300,|100,200,300,|i;v\n"
            "F3e-2:7|7,0,|5,8,|52|recv;recv;frecv\n"
            "F3e-3:1,4,|10,5,9,|6\n"
            "F3e-4:302,6|233,55357,122"
        )
        assert moon_out == expected and pion_native == moon_out and pion_wasm == moon_out, (
            f"MISMATCH:\nEXPECTED:\n{expected}\nMOON:\n{moon_out}\nNATIVE:\n{pion_native}\nWASM32:\n{pion_wasm}"
        )
        print("[f3e-oracle] PASS: 3-engine (moon wasm-gc == pion-native == pion-wasm32) 100% identical, 0 generic unsafe helpers!\n" + moon_out)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
