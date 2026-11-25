#!/usr/bin/env python3
r"""Wave M2-F3d-1a 3-Engine Differential Oracle: Moon wasm-gc == Pion native == Pion wasm32.

Covers (a two-package project: `f3d1adep` transpiled first, then `f3d1a` against it via `--dep`):
  1. Built-in `Int32` (an alias of `Int`) in fields, parameters, `Option`/`Array`/tuple positions and ascriptions:
     min/max, wrapping overflow, arithmetic `>>`, truncation from `Int64`, division/remainder rounding, across a
     dependency's signatures (MoonBit reserves the name: no user type can be called `Int32`).
  2. `Array::sort_by_key`: MoonBit's unstable sort calling `key` twice per comparison (`[3, 1, 2]` -> key trace
     `[3, 1, 3, 2, 1, 2]`), > 16 elements with repeated keys (`-1`) printed with their original index, `Double`
     keys with NaN / +-0, `String` keys (UTF-16 length first), and a counting key callback.
  3. `Map::from_array` (call and `|> Map::from_array`), `Map(arr, capacity=cap)` (`[arr, cap]` evaluation order,
     each once), duplicate keys (first position, last value), untyped literals (`let m = { 1: 10, .. }`,
     `let m = Map::from_array([..])`: bound by `let` before the generic call, see `hoist_untyped_pairs_literal`).
  4. `(Int, Int)` / `(Int, String, Bool)` map keys: overwrite, remove + re-insert order, `from_array`, 2000 keys.
  5. `Array::shrink_to_fit`: an `ArrayBuf` (array with a borrowed view) from `Array(capacity=8)` reallocates
     (`(8, 2, 1, 9)`), capacity == length keeps sharing, an empty one drops to 0; on a plain array the receiver
     is evaluated once, `clear(); shrink_to_fit()` inside a non-iterating closure and inside a loop over a private
     copy are exact.
  6. `Iter::to_array`: empty, partly consumed, exhausted, called twice, mapped-callback order, an append after
     the iterator was taken.
Traps (MoonBit aborts; Pion must abort too, native and wasm32): `Int32` `MIN / -1` and `x / 0`,
`Map(capacity=-1)`, `Map(capacity=872415233)`, `Array(capacity=-1)`.
Negatives (must fail closed with no `--out`, never silently change semantics):
  - `shrink_to_fit` inside `for x in xs`, inside an `each` callback, and with a kept `Array::iter()`
    (`MBT2PION_ARRAY_SHRINK_ITER`)
  - `Map(non_fresh, capacity=f())` (`MBT2PION_UNSUPPORTED_SYNTAX`)
  - a kept `xs.iter()` consumed by `to_array()` after `xs.pop()`, or after `xs.push(..)` + `xs[0] = ..`
    (MoonBit's iterator keeps the old buffer/length; `MBT2PION_ARRAY_ITER_MUTATION`)
"""
import argparse, os, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

DEP_MBT = r'''
pub(all) struct Cell32 {
  v : Int32
}

pub fn Cell32::make(v : Int32) -> Cell32 {
  { v: v * 2 }
}

pub fn wrap(x : Cell32) -> Int32 {
  x.v + 1
}
'''

F3D1A_MBT = r'''
fn ints(xs : Array[Int]) -> String {
  xs.map(fn(x) { x.to_string() }).join(",")
}

fn opt(o : Int?) -> String {
  match o {
    Some(v) => "Some(" + v.to_string() + ")"
    None => "None"
  }
}

priv struct Probe {
  at : Int32
  gens : Array[Int32?]
  pair : (Int32, Int32)
}

fn add32(a : Int32, b : Int32) -> Int32 {
  a + b
}

fn opt_sum(xs : Array[Int32?]) -> Int32 {
  let mut s : Int32 = 0
  for x in xs {
    match x {
      Some(v) => s = s + v
      None => ()
    }
  }
  s
}

pub fn run_1() -> String {
  let mx : Int32 = 2147483647
  let mn : Int32 = -2147483648
  let one : Int32 = 1
  let p : Probe = { at: mx, gens: [Some(1), None, Some(-3)], pair: (mn, one) }
  let wide : Int64 = 0x1_0000_0005L
  let t : Int32 = wide.to_int()
  let neg7 : Int32 = -7
  let two : Int32 = 2
  let back : Int64 = mn.to_int64()
  let d = @f3d1adep.Cell32::make(4)
  let parts : Array[Int32] = [
    add32(mx, one), mn - one, mn >> 1, neg7 >> 1, mx * two, neg7 / two, neg7 % two, t,
  ]
  ints(parts) + "," + back.to_string() + "," + opt_sum(p.gens).to_string() + "," + (p.pair.0 == mn).to_string() +
  "," + ((5 : Int32) * p.pair.1).to_string() + "," + @f3d1adep.wrap(d).to_string() + "," + p.at.to_string()
}

priv struct Item {
  id : Int
  key : Int
}

pub fn run_2() -> String {
  let trace : Array[Int] = []
  let a = [3, 1, 2]
  a.sort_by_key(fn(x) {
    trace.push(x)
    x
  })
  let items : Array[Item] = []
  let keys = [5, -1, 3, -1, 7, 2, -1, 9, 0, 4, -1, 8, 1, 6, -1, 3, 2, -1, 5, 0, -1, 4]
  for i, k in keys {
    items.push({ id: i, key: k })
  }
  let mut calls = 0
  items.sort_by_key(fn(it) {
    calls = calls + 1
    it.key
  })
  let order = items.map(fn(it) { it.id.to_string() + ":" + it.key.to_string() })
  let nan = 0.0 / 0.0
  let ds = [3.0, nan, -0.0, 0.0, 1.0, nan, -1.0, 0.5, -0.0, 2.0]
  let idx : Array[Int] = []
  for i in 0..<ds.length() {
    idx.push(i)
  }
  idx.sort_by_key(fn(i) { ds[i] })
  let ss = ["bb", "a", "ccc", "ab", "b", "", "aa"]
  ss.sort_by_key(fn(s) { s })
  ints(a) + "|" + ints(trace) + "|" + order.join(",") + "|" + calls.to_string() + "|" + ints(idx) + "|" + ss.join(",")
}

fn show_map(m : Map[Int, Int]) -> String {
  let parts : Array[String] = []
  for k, v in m {
    parts.push(k.to_string() + "=" + v.to_string())
  }
  parts.join(",")
}

pub fn run_3() -> String {
  let ev : Array[String] = []
  let note = fn(s : String, v : Int) -> Int {
    ev.push(s)
    v
  }
  let m1 = Map::from_array([(1, 10), (2, 20), (1, 30), (3, 40), (2, 50)])
  let m2 : Map[Int, Int] = [(9, 1), (8, 2), (9, 3)] |> Map::from_array
  let ks = [4, 5, 6]
  let m3 : Map[Int, Int] = Map([], capacity=ks.length())
  for k in ks {
    m3[k] = k * k
  }
  let m4 : Map[Int, Int] = Map([(note("arr", 7), 70), (note("arr", 6), 60)], capacity=note("cap", 1))
  let ps = [(5, 1), (4, 2), (5, 3)]
  let c = 16
  let m5 : Map[Int, Int] = Map(ps, capacity=c)
  let m6 : Map[Int, Int] = Map([], capacity=0)
  let lit = { 1: 10, 2: 20, 1: 30 }
  show_map(m1) + "|" + show_map(m2) + "|" + show_map(m3) + "|" + show_map(m4) + "|" + ev.join(",") + "|" +
  show_map(m5) + "|" + m6.length().to_string() + "|" + show_map(lit)
}

priv struct Slices {
  sids : Map[(Int, Int), Int]
}

pub fn run_4() -> String {
  let s : Slices = { sids: Map([]) }
  s.sids[(1, 2)] = 10
  s.sids[(2, 1)] = 20
  s.sids[(1, 2)] = 30
  s.sids[(0, 0)] = 40
  s.sids.remove((2, 1))
  s.sids[(2, 1)] = 50
  let parts : Array[String] = []
  for k, v in s.sids {
    let (a, b) : (Int, Int) = k
    parts.push("(" + a.to_string() + "," + b.to_string() + ")=" + v.to_string())
  }
  let got = match s.sids.get((1, 2)) {
    Some(v) => v
    None => -1
  }
  let fa = Map::from_array([((1, 1), "a"), ((1, 2), "b"), ((1, 1), "c")])
  let fparts : Array[String] = []
  for k, v in fa {
    let (a, b) : (Int, Int) = k
    fparts.push("(" + a.to_string() + "," + b.to_string() + ")=" + v)
  }
  let tri : Map[(Int, String, Bool), Int] = Map([])
  tri[(1, "x", true)] = 1
  tri[(1, "x", false)] = 2
  tri[(1, "x", true)] = 3
  let big : Map[(Int, Int), Int] = Map([])
  for i in 0..<2000 {
    big[(i % 50, i / 50)] = i
  }
  for i in 0..<2000 {
    big[(i % 50, i / 50)] = big[(i % 50, i / 50)] + 1
  }
  let mut sum = 0
  let mut first = -1
  for k, v in big {
    if first < 0 {
      first = k.0 * 1000 + k.1
    }
    sum = sum + v
  }
  parts.join(",") + "|" + got.to_string() + "|" + s.sids.contains((0, 0)).to_string() + "|" + fparts.join(",") + "|" +
  tri.length().to_string() + "," + opt(tri.get((1, "x", true))) + "|" + big.length().to_string() + "," +
  sum.to_string() + "," + first.to_string()
}

priv struct Holder {
  items : Array[Int]
}

fn get_items(h : Holder, n : Ref[Int]) -> Array[Int] {
  n.val = n.val + 1
  h.items
}

fn later(f : () -> Unit) -> Unit {
  f()
}

pub fn run_5() -> String {
  let xs : Array[Int] = Array(capacity=8)
  xs.push(1)
  xs.push(2)
  let v = xs[:]
  let c0 = xs.capacity()
  xs.shrink_to_fit()
  xs[0] = 9
  let r1 = "(" + ints([c0, xs.capacity(), v[0], xs[0]]) + ")"
  let ys = [1, 2]
  let w = ys[:]
  ys.shrink_to_fit()
  ys[0] = 9
  let r2 = "(" + ints([ys.capacity(), w[0], ys[0]]) + ")"
  let zs : Array[Int] = Array(capacity=4)
  let u = zs[:]
  zs.shrink_to_fit()
  zs.push(3)
  let r3 = "(" + ints([zs.capacity(), u.length(), zs[0]]) + ")"
  let h : Holder = { items: [4, 5, 6] }
  let n = Ref::new(0)
  get_items(h, n).shrink_to_fit()
  let faded : Array[Int] = [7, 8]
  later(fn() {
    faded.clear()
    faded.shrink_to_fit()
  })
  faded.push(1)
  let other : Array[Int] = [9, 9]
  let snapshot = h.items.copy()
  let mut visits = 0
  for x in snapshot {
    visits = visits + x
    if x == 5 {
      other.clear()
      other.shrink_to_fit()
      other.push(x)
    }
  }
  r1 + "|" + r2 + "|" + r3 + "|" + n.val.to_string() + "," + ints(h.items) + "|" + ints(faded) + "|" +
  visits.to_string() + "," + ints(other)
}

pub fn run_6() -> String {
  let e : Array[Int] = []
  let xs = [1, 2, 3]
  let it = xs.iter()
  let first = it.next()
  let rest = it.to_array()
  let again = it.to_array()
  let log : Array[Int] = []
  let mapped = xs.iter().map(fn(x) {
    log.push(x)
    x * 10
  }).to_array()
  let ys = [4, 5]
  let it2 = ys.iter()
  ys.push(6)
  ints(e.iter().to_array()) + "|" + opt(first) + "|" + ints(rest) + "|" + ints(again) + "|" + ints(mapped) + "|" +
  ints(log) + "|" + it2.count().to_string()
}

pub fn run_all() -> String {
  "F1:" + run_1() + "\nF2:" + run_2() + "\nF3:" + run_3() + "\nF4:" + run_4() + "\nF5:" + run_5() + "\nF6:" + run_6()
}

pub fn trap_div_overflow() -> Int {
  let mn : Int32 = -2147483648
  let m1 : Int32 = -1
  mn / m1
}

pub fn trap_div_zero() -> Int {
  let x : Int32 = 7
  let z : Int32 = 0
  x / z
}

pub fn trap_map_neg() -> Int {
  let n = -1
  let m : Map[Int, Int] = Map([], capacity=n)
  m.length()
}

pub fn trap_map_big() -> Int {
  let n = 872415233
  let m : Map[Int, Int] = Map([(1, 1)], capacity=n)
  m.length()
}

pub fn trap_arr_neg() -> Int {
  let n = -1
  let xs : Array[Int] = Array(capacity=n)
  xs.length()
}
'''

TRAPS = ["trap_div_overflow", "trap_div_zero", "trap_map_neg", "trap_map_big", "trap_arr_neg"]

NEG_SHRINK_MBT = r'''
pub fn shrink_in_for() -> Array[Int] {
  let xs : Array[Int] = [1, 2, 3]
  let seen : Array[Int] = []
  for x in xs {
    seen.push(x)
    if x == 1 {
      xs.shrink_to_fit()
      xs[1] = 9
    }
  }
  seen
}

pub fn shrink_in_each() -> Array[Int] {
  let xs : Array[Int] = [1, 2, 3]
  let seen : Array[Int] = []
  xs.each(fn(x) {
    seen.push(x)
    if x == 1 {
      xs.shrink_to_fit()
    }
  })
  seen
}

pub fn shrink_kept_iter() -> Array[Int] {
  let xs : Array[Int] = [1, 2, 3]
  let it = xs.iter()
  xs.shrink_to_fit()
  xs[0] = 7
  it.collect()
}
'''

NEG_ITER_MBT = r'''
pub fn pop_after_iter() -> Array[Int] {
  let xs = [1, 2, 3]
  let it = xs.iter()
  xs.pop() |> ignore
  it.to_array()
}

pub fn write_after_push() -> Array[Int] {
  let xs = [1, 2, 3]
  let it = xs.iter()
  xs.push(4)
  xs[0] = 9
  it.to_array()
}
'''

NEG_MAP_MBT = r'''
fn pairs() -> Array[(Int, Int)] {
  [(1, 2)]
}

fn cap() -> Int {
  4
}

pub fn map_cap_call() -> Int {
  let ps = pairs()
  let m : Map[Int, Int] = Map(ps, capacity=cap())
  m.length()
}
'''


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


def expect_blocked(bin_path, pionc, md, work, name, src, code, needles):
    d = os.path.join(md, name)
    write(os.path.join(d, "moon.pkg"), "\n")
    write(os.path.join(d, "neg.mbt"), src)
    out = os.path.join(work, "p_" + name, "src")
    os.makedirs(out)
    rc, log = run_rc([bin_path, "--src", d, "--out", out, "--target", "native", "--mode", "publish",
                      "--mbt-compat", COMPAT_DIR, "--pionc", pionc])
    assert rc != 0 and code in log, f"{name} must block publish with {code}:\n{log}"
    for nd in needles:
        assert nd in log, f"{name}: expected `{nd}` in diagnostics:\n{log}"
    assert not os.listdir(out), f"{name}: blocked publish must not write --out"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", default=os.environ.get("PIONC", shutil.which("pionc") or os.path.expanduser("~/.pion/bin/pionc")))
    ap.add_argument("--moon", default=os.environ.get("MOON", shutil.which("moon") or os.path.expanduser("~/.moon/bin/moon")))
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="mbt2pion-f3d1a-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])
        md = os.path.join(work, "moon_proj")
        files = [
            ("moon.mod", 'name = "f3d1a/oracle"\n'),
            ("f3d1adep/moon.pkg", "\n"),
            ("f3d1adep/dep.mbt", DEP_MBT),
            ("f3d1a/moon.pkg", 'import { "f3d1a/oracle/f3d1adep" }\n'),
            ("f3d1a/f3d1a.mbt", F3D1A_MBT),
            ("cmd/moon.pkg", 'import { "f3d1a/oracle/f3d1a" }\npkgtype(kind: "executable")\n'),
            ("cmd/main.mbt", "fn main { println(@f3d1a.run_all()) }\n"),
        ]
        for t in TRAPS:
            files.append((f"cmd_{t}/moon.pkg", 'import { "f3d1a/oracle/f3d1a" }\npkgtype(kind: "executable")\n'))
            files.append((f"cmd_{t}/main.mbt", f"fn main {{ println(@f3d1a.{t}()) }}\n"))
        for rel, txt in files:
            write(os.path.join(md, rel), txt)
        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)

        pd = os.path.join(work, "p_dep")
        write(os.path.join(pd, "pion.toml"),
              f'[package]\nname = "f3d1adep"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n')
        os.makedirs(os.path.join(pd, "src"))
        run_cmd([bin_path, "--src", os.path.join(md, "f3d1adep"), "--out", os.path.join(pd, "src"), "--target", "native",
                 "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc])
        dep_out = open(os.path.join(pd, "src", "dep.pion"), encoding="utf-8").read()
        assert "Int32" not in dep_out and "v : Int" in dep_out, "built-in `Int32` must lower to `Int`:\n" + dep_out

        pl = os.path.join(work, "p_f3d1a")
        write(os.path.join(pl, "pion.toml"),
              f'[package]\nname = "f3d1a"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nf3d1adep = {{ path = "{pd}" }}\n')
        os.makedirs(os.path.join(pl, "src"))
        run_cmd([bin_path, "--src", os.path.join(md, "f3d1a"), "--out", os.path.join(pl, "src"), "--target", "native",
                 "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc, "--dep", f"f3d1adep={pd}"])
        gen = open(os.path.join(pl, "src", "f3d1a.pion"), encoding="utf-8").read()
        assert "f3d1adep::Cell32::make" in gen and "Int32" not in gen, "built-in `Int32` must lower to `Int`:\n" + gen
        assert "mbt_compat::arr_sort_by_key(" in gen and "mbt_compat::ArrayBuf::with_capacity(8)" in gen, gen
        write(os.path.join(pl, "src", "main.pion"), "pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n")
        pion_native = run_cmd([args.pionc, "run", pl])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", pl])

        expected = (
            "F1:-2147483648,2147483647,-1073741824,-4,-2,-3,-1,5,-2147483648,-2,true,5,9,2147483647\n"
            "F2:1,2,3|3,1,3,2,1,2|1:-1,3:-1,10:-1,6:-1,14:-1,17:-1,20:-1,8:0,19:0,12:1,5:2,16:2,2:3,15:3,"
            "9:4,21:4,0:5,18:5,13:6,4:7,11:8,7:9|156|0,1,2,3,4,5,6,8,7,9|,a,b,aa,ab,bb,ccc\n"
            "F3:1=30,2=50,3=40|9=3,8=2|4=16,5=25,6=36|7=70,6=60|arr,arr,cap|5=3,4=2|0|1=30,2=20\n"
            "F4:(1,2)=30,(0,0)=40,(2,1)=50|30|true|(1,1)=c,(1,2)=b|2,Some(3)|2000,2001000,0\n"
            "F5:(8,2,1,9)|(2,9,9)|(8,0,3)|1,4,5,6|1|15,5\n"
            "F6:|Some(1)|2,3||10,20,30|1,2,3|2"
        )
        assert moon_out == expected, f"Moon reference drifted:\nEXPECTED:\n{expected}\nMOON:\n{moon_out}"
        assert pion_native == moon_out and pion_wasm == moon_out, (
            f"MISMATCH:\nMOON:\n{moon_out}\nNATIVE:\n{pion_native}\nWASM32:\n{pion_wasm}"
        )

        # Traps: MoonBit aborts; both Pion targets must abort too (non-zero exit, nothing printed as a result).
        for t in TRAPS:
            mrc, mlog = run_rc([args.moon, "run", "--target", "wasm-gc", f"cmd_{t}"], cwd=md)
            assert mrc != 0, f"{t}: MoonBit must abort:\n{mlog}"
            tp = os.path.join(work, "p_" + t)
            write(os.path.join(tp, "pion.toml"),
                  f'[package]\nname = "{t}"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nf3d1a = {{ path = "{pl}" }}\nf3d1adep = {{ path = "{pd}" }}\n')
            write(os.path.join(tp, "src", "main.pion"),
                  f'import "f3d1a"\n\npub fn main(w : World) -> Int {{ io_println(w, f3d1a::{t}().to_string()); 0 }}\n')
            for tgt in (["run", tp], ["run", "--target", "wasm32", tp]):
                prc, plog = run_rc([args.pionc] + tgt)
                assert prc != 0, f"{t} ({' '.join(tgt[:-1])}): Pion must abort like MoonBit:\n{plog}"

        # Negatives: fail closed, no output written.
        expect_blocked(bin_path, args.pionc, md, work, "negshrink", NEG_SHRINK_MBT, "MBT2PION_ARRAY_SHRINK_ITER",
                       ["inside a `for .. in` loop body", "inside a callback passed to", "keeps an `Array::iter()`"])
        expect_blocked(bin_path, args.pionc, md, work, "negiter", NEG_ITER_MBT, "MBT2PION_ARRAY_ITER_MUTATION",
                       ["`xs.pop(..)` runs while it is kept", "appended to and written in place"])
        expect_blocked(bin_path, args.pionc, md, work, "negmap", NEG_MAP_MBT, "MBT2PION_UNSUPPORTED_SYNTAX",
                       ["`Map(arr, capacity=...)` with a capacity expression that may run code"])

        print("[f3d1a-oracle] PASS: 3-engine (moon wasm-gc == pion-native == pion-wasm32) 100% identical!\n" + moon_out)
        print("[f3d1a-oracle] PASS: 5 traps abort on all 3 engines; shrink-under-snapshot (for/each/kept iter) and "
              "Map(non-fresh, capacity=call) and kept iterators after pop / push+write fail closed")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
