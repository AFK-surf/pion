#!/usr/bin/env python3
r"""Wave M2-F4 Track F4-2 4-Target Differential Oracle:
MoonBit native == MoonBit wasm-gc == Pion native == Pion wasm32.

Covers:
  1. `MbtJson::to_string` (Show format across all 7 variants, unescaped strings/keys, -0.0, NaN, Inf, -Inf, nested).
  2. `Repr(x)` formatting (`Option[Double]`, `String`, `Array[Int]`, tuple) + negative unsupported-type fail-closed.
  3. `Iter::head` consuming semantics on `Array::iter()` and `Map::keys()`.
  4. `Map[String, Json]` / `Map[String, Double]` K/V propagation & `path[depth]` indexing under `Json`.
  5. Match-arm `(pat as x)` & nested `Some(Object(_) as v)` & `((A(v) | B(v)) as x)` (single-eval, guard, outer shadow)
     + negative per-branch `as` inside or-pattern fail-closed.
  6. 4 read-only slice patterns (`contains`, `iter().any` w/ scalar capture, `for k in xs[1:]`, `ArrayView` call arg
     with 0-call closure when path missing) + negative mutated array slice fail-closed.
  7. Cross-package foreign struct update wired to F4-3 ABI v2:
     - in-order effectful update (`{ ..s, b: { s.a = 9; 7 } }` -> `u.a = 1, s.a = 9`)
     - out-of-order effectful update (eval-order log + value parity)
     - two-package generic `Box[T]` with distinct type args
     - negative fail-closed on `priv`-field struct & legacy ABI struct (even with pure overrides).
"""
import argparse, hashlib, json, os, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

DEP1_MBT = r'''
pub(all) struct S {
  mut a : Int
  b : Int
}

pub(all) struct Box[T] {
  mut item : T
  tag : Int
}

pub(all) struct PrivS {
  x : Int
  priv secret : Int
}

pub fn make_priv(x : Int, s : Int) -> PrivS {
  PrivS::{ x: x, secret: s }
}

pub(all) struct Color {
  r : Int
}
'''

DEP2_MBT = r'''
pub(all) struct Box[T] {
  label : T
  weight : Int
}
'''

APP_MBT = r'''
pub enum Kind {
  A(Int)
  B(Int)
}

pub enum MyVal {
  Number(Int)
  Other
}

pub type Color = @f42dep1.Color

fn run_json_show() -> String {
  let j0 : Json = null
  let j1 : Json = true
  let j2 : Json = false
  let j3 : Json = 1
  let j4 : Json = 1.5
  let j5 : Json = Json::number(-0.0)
  let j6 : Json = Json::number(0.0 / 0.0)
  let j7 : Json = Json::number(1.0 / 0.0)
  let j8 : Json = Json::number(-1.0 / 0.0)
  let j9 : Json = "a\"b\\c\nd"
  let j10 : Json = [1, "hi\n", null]
  let j11 : Json = { "a": 1, "b c": "hi\n" }
  [
    j0.to_string(),
    j1.to_string(),
    j2.to_string(),
    j3.to_string(),
    j4.to_string(),
    j5.to_string(),
    j6.to_string(),
    j7.to_string(),
    j8.to_string(),
    j9.to_string(),
    j10.to_string(),
    j11.to_string(),
  ].join("|")
}

fn run_repr_and_iter() -> String {
  let opt_d : Double? = Some(1.5)
  let opt_n : Double? = None
  let s_hi = "hi"
  let r_str = "\{Repr(opt_d)}|\{Repr(opt_n)}|\{Repr(s_hi)}"
  let arr = [10, 20, 30]
  let it = arr.iter()
  let h1 = it.head().unwrap_or(-1)
  let h2 = it.head().unwrap_or(-1)
  let h3 = it.head().unwrap_or(-1)
  let h4 = it.head().unwrap_or(-1)
  let m : Map[String, Int] = { "alpha": 1, "beta": 2 }
  let kh = m.keys().head().unwrap_or("none")
  let kn = m.keys().next().unwrap_or("none")
  let ka = m.keys().any(fn(k) { k == "beta" })
  let c_alias : Color = { r: 7 }
  r_str + "|" + h1.to_string() + "," + h2.to_string() + "," + h3.to_string() + "," + h4.to_string() + "|" + kh + "|" + kn + "|" + ka.to_string() + "|" + c_alias.r.to_string()
}

fn run_map_kv_and_json_index() -> String {
  let path : Array[Json] = [10, "mid", true]
  let depth = 1
  let existing : Json = "keep"
  let mj : Map[String, Json] = { "n": 42, "e": existing, "p": path[depth] }
  let md : Map[String, Double] = { "i": 3, "f": 4.5 }
  let p_val = mj.get("p").unwrap_or(Json::null())
  let n_val = mj.get("n").unwrap_or(Json::null())
  let e_val = mj.get("e").unwrap_or(Json::null())
  let sum_d = md.get("i").unwrap_or(0.0) + md.get("f").unwrap_or(0.0)
  p_val.to_string() + "|" + n_val.to_string() + "|" + e_val.to_string() + "|" + sum_d.to_string()
}

fn run_match_as() -> String {
  let log : Array[String] = []
  let get_j = fn(v : Json?, tag : String) -> Json? {
    log.push("j:" + tag)
    v
  }
  let v = 999
  let r1 = match get_j(Some({ "k": 7 }), "1") {
    Some(Object(_) as v) => v.to_string()
    _ => "no:" + v.to_string()
  }
  let r2 = match get_j(Some(5), "2") {
    Some(Object(_) as v) => v.to_string()
    _ => "no:" + v.to_string()
  }
  let r3 = match Kind::B(11) {
    ((A(n) | B(n)) as x) => {
      let tag = match x {
        A(_) => "A"
        B(_) => "B"
      }
      tag + ":" + n.to_string()
    }
  }
  let r4 = match (Some(MyVal::Number(42)) : MyVal?) {
    Some(Number(_) as x) => match x {
      Number(n) => n.to_string()
      Other => "other"
    }
    _ => "none"
  }
  let check_opt = fn(o : Int?) -> Int {
    match o {
      Some(1) => 10
      (Some(2) as y) => match y {
        Some(n) => 20 + n
        None => -1
      }
      _ => 30
    }
  }
  let r5 = check_opt(None).to_string() + "," + check_opt(Some(1)).to_string() + "," + check_opt(Some(2)).to_string()
  r1 + "|" + r2 + "|" + r3 + "|" + r4 + "|" + r5 + "|" + log.join(",")
}

fn patch_all(dst : Array[Int], ops : ArrayView[Int]) -> Int {
  let mut s = 0
  for i = 0; i < ops.length(); i = i + 1 {
    s = s + ops[i]
  }
  dst.length() + s
}

fn maybe_call(run : Bool, f : (Array[Int]) -> Int) -> Int {
  if run {
    f([100])
  } else {
    -1
  }
}

fn run_ro_slices() -> String {
  let log : Array[String] = []
  let xs = [1, 2, 3, 4, 5]
  let pairs = [(1, 10), (2, 20), (3, 30)]
  let k = 2
  let h = 2
  let c1 = xs[k:].contains(4)
  let c2 = xs[k:].contains(1)
  let a1 = pairs[:k].iter().any(fn(e) { e.0 == h })
  let a2 = pairs[:k].iter().any(fn(e) { e.0 == 3 })
  let mut sum = 0
  for v in xs[1:] {
    sum = sum + v
  }
  let ops = [5, 6, 7, 8]
  let r_hit = maybe_call(true, fn(list) {
    log.push("hit")
    patch_all(list, ops[1:3])
  })
  let r_miss = maybe_call(false, fn(list) {
    log.push("miss")
    patch_all(list, ops[1:3])
  })
  c1.to_string() + "," + c2.to_string() + "," + a1.to_string() + "," + a2.to_string() + "," +
  sum.to_string() + "," + r_hit.to_string() + "," + r_miss.to_string() + "," + log.join(",")
}

fn run_foreign_struct_update() -> String {
  let log : Array[String] = []
  let s : @f42dep1.S = { a: 1, b: 2 }
  let u : @f42dep1.S = { ..s, b: { s.a = 9; log.push("b"); 7 } }
  let s2 : @f42dep1.S = { a: 10, b: 20 }
  let u2 : @f42dep1.S = {
    ..s2,
    b: { log.push("o1"); 30 },
    a: { log.push("o2"); 40 },
  }
  let b1 : @f42dep1.Box[Int] = { item: 5, tag: 1 }
  let b1u : @f42dep1.Box[Int] = { ..b1, tag: { b1.item = 8; 2 } }
  let b2 : @f42dep2.Box[String] = { label: "hi", weight: 3 }
  let b2u : @f42dep2.Box[String] = { ..b2, weight: { log.push("w"); 4 } }
  u.a.to_string() + "," + u.b.to_string() + "," + s.a.to_string() + "|" +
  u2.a.to_string() + "," + u2.b.to_string() + "|" +
  b1u.item.to_string() + "," + b1u.tag.to_string() + "," + b1.item.to_string() + "|" +
  b2u.label + ":" + b2u.weight.to_string() + "|" + log.join(",")
}

pub fn run_all() -> String {
  "J:" + run_json_show() +
  "\nR:" + run_repr_and_iter() +
  "\nM:" + run_map_kv_and_json_index() +
  "\nA:" + run_match_as() +
  "\nS:" + run_ro_slices() +
  "\nU:" + run_foreign_struct_update()
}
'''


def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
    if p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
    return p.stdout.strip()


def assert_publish_blocked(bin_path, pionc, work, name, src_text, expect_code, extra_args=None):
    sdir = os.path.join(work, f"neg_{name}_src")
    odir = os.path.join(work, f"neg_{name}_out")
    rep = os.path.join(work, f"neg_{name}_report.json")
    os.makedirs(sdir)
    os.makedirs(odir)
    with open(os.path.join(sdir, f"{name}.mbt"), "w") as fh:
        fh.write(src_text)
    cmd = [
        bin_path, "--src", sdir, "--out", odir, "--target", "native", "--mode", "publish",
        "--mbt-compat", COMPAT_DIR, "--pionc", pionc, "--report", rep,
    ] + (extra_args or [])
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
    rep_txt = open(rep).read() if os.path.exists(rep) else ""
    combined = p.stdout + "\n" + p.stderr + "\n" + rep_txt
    assert p.returncode != 0 and expect_code in combined, (
        f"negative case `{name}` must block publish with `{expect_code}`:\n{combined}"
    )
    assert not os.listdir(odir), f"blocked publish `{name}` must leave --out empty"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", default=os.environ.get("PIONC", shutil.which("pionc") or os.path.expanduser("~/.pion/bin/pionc")))
    ap.add_argument("--moon", default=os.environ.get("MOON", shutil.which("moon") or os.path.expanduser("~/.moon/bin/moon")))
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="mbt2pion-f4-2-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])

        # 1. Build MoonBit project and run BOTH MoonBit native & MoonBit wasm-gc
        md = os.path.join(work, "moon_proj")
        for sub in ("f42dep1", "f42dep2", "f42app", "cmd"):
            os.makedirs(os.path.join(md, sub))
        for rel, txt in [
            ("moon.mod", 'name = "f42/oracle"\n'),
            ("f42dep1/moon.pkg", "\n"),
            ("f42dep1/dep1.mbt", DEP1_MBT),
            ("f42dep2/moon.pkg", "\n"),
            ("f42dep2/dep2.mbt", DEP2_MBT),
            ("f42app/moon.pkg", 'import { "f42/oracle/f42dep1", "f42/oracle/f42dep2" }\n'),
            ("f42app/app.mbt", APP_MBT),
            ("cmd/moon.pkg", 'import { "f42/oracle/f42app" }\npkgtype(kind: "executable")\n'),
            ("cmd/main.mbt", "fn main { println(@f42app.run_all()) }\n"),
        ]:
            with open(os.path.join(md, rel), "w") as fh:
                fh.write(txt)

        moon_native = run_cmd([args.moon, "run", "--target", "native", "cmd"], cwd=md)
        moon_wasm = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)
        assert moon_native == moon_wasm, f"MoonBit native vs wasm-gc mismatch:\n{moon_native}\nvs\n{moon_wasm}"

        # 2. Transpile in topological order with `mbt2pion --mode publish`
        def make_pkg(name, deps):
            pdir = os.path.join(work, f"p_{name}")
            os.makedirs(os.path.join(pdir, "src"))
            dep_lines = [f'mbt_compat = {{ path = "{COMPAT_DIR}" }}']
            cli_deps = []
            for dn, dp in deps:
                dep_lines.append(f'{dn} = {{ path = "{dp}" }}')
                cli_deps += ["--dep", f"{dn}={dp}"]
            with open(os.path.join(pdir, "pion.toml"), "w") as fh:
                fh.write(f'[package]\nname = "{name}"\nversion = "0.1.0"\n[dependencies]\n' + "\n".join(dep_lines) + "\n")
            run_cmd([
                bin_path, "--src", os.path.join(md, name), "--out", os.path.join(pdir, "src"),
                "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
            ] + cli_deps)
            return pdir

        p_dep1 = make_pkg("f42dep1", [])
        p_dep2 = make_pkg("f42dep2", [])
        p_app = make_pkg("f42app", [("f42dep1", p_dep1), ("f42dep2", p_dep2)])

        with open(os.path.join(p_app, "src", "main.pion"), "w") as fh:
            fh.write("pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n")
        pion_native = run_cmd([args.pionc, "run", p_app])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", p_app])

        assert moon_native == pion_native and moon_native == pion_wasm, (
            f"4-TARGET MISMATCH:\nMOON_NATIVE:\n{moon_native}\nMOON_WASM:\n{moon_wasm}\nPION_NATIVE:\n{pion_native}\nPION_WASM:\n{pion_wasm}"
        )

        # 3. Negative fail-closed gates
        # 3a. Foreign priv-field struct update with pure override MUST fail closed
        assert_publish_blocked(
            bin_path, args.pionc, work, "priv_struct_upd",
            "pub fn f(p : @f42dep1.PrivS) -> @f42dep1.PrivS { { ..p, x: 2 } }\n",
            "MBT2PION_DEP_ABI_ERROR",
            ["--dep", f"f42dep1={p_dep1}"],
        )

        # 3b. Legacy v2 ABI (no `structs`) foreign struct update with pure override MUST fail closed
        leg_dep = os.path.join(work, "p_leg")
        os.makedirs(os.path.join(leg_dep, "src"))
        with open(os.path.join(leg_dep, "pion.toml"), "w") as fh:
            fh.write('[package]\nname = "leg"\nversion = "0.1.0"\n')
        leg_pl = {"schema_version": 2, "package": "leg", "enums": [], "struct_val_fields": [], "publishable": True}
        leg_sha = hashlib.sha256(json.dumps(leg_pl, separators=(",", ":")).encode()).hexdigest()
        leg_ptxt = f"// GENERATED BY mbt2pion\n// abi-sha256: {leg_sha}\npub struct Pt {{ x : Int; y : Int }}\n"
        with open(os.path.join(leg_dep, "src", "leg.pion"), "w") as fh:
            fh.write(leg_ptxt)
        leg_fsha = hashlib.sha256(f"leg.pion:{len(leg_ptxt)}:{hashlib.sha256(leg_ptxt.encode()).hexdigest()}\n".encode()).hexdigest()
        with open(os.path.join(leg_dep, "src", "mbt2pion_abi.json"), "w") as fh:
            fh.write(json.dumps({"schema_version": 2, "package": "leg", "abi_sha256": leg_sha, "files_sha256": leg_fsha, "payload": leg_pl}))
        assert_publish_blocked(
            bin_path, args.pionc, work, "legacy_struct_upd",
            "pub fn f(p : @leg.Pt) -> @leg.Pt { { ..p, x: 2 } }\n",
            "MBT2PION_DEP_ABI_ERROR",
            ["--dep", f"leg={leg_dep}"],
        )

        # 3c. Per-branch `as` inside or-pattern MUST fail closed
        assert_publish_blocked(
            bin_path, args.pionc, work, "or_branch_as",
            "priv enum E { A(Int); B(Int) }\npub fn f(e : E) -> Int { match e { A(1 as y) | B(2 as y) => y; _ => 0 } }\n",
            "MBT2PION_UNSUPPORTED_SYNTAX",
        )

        # 3d. Mutated array slice passed as ArrayView MUST fail closed
        assert_publish_blocked(
            bin_path, args.pionc, work, "mut_ro_view",
            "fn use_v(v : ArrayView[Int]) -> Int { v.length() }\npub fn f(xs : Array[Int]) -> Int { xs.push(1); use_v(xs[0:1]) }\n",
            "MBT2PION_BORROWED_ARRAY_SLICE",
        )

        # 3e. Repr(x) on unsupported custom struct MUST fail closed
        assert_publish_blocked(
            bin_path, args.pionc, work, "repr_custom_struct",
            "priv struct Opaque { a : Int }\npub fn f(o : Opaque) -> String { \"\\{Repr(o)}\" }\n",
            "MBT2PION_UNSUPPORTED_SYNTAX",
        )

        # 3f. Aliased array slice passed as ArrayView MUST fail closed
        assert_publish_blocked(
            bin_path, args.pionc, work, "alias_ro_view",
            "fn use_v(v : ArrayView[Int]) -> Int { v.length() }\npub fn f(ops : Array[Int]) -> Int { let alias = ops; alias[0] = 99; use_v(ops[0:2]) }\n",
            "MBT2PION_BORROWED_ARRAY_SLICE",
        )

        # 3g. Same-call other-arg mutation with ArrayView slice MUST fail closed
        assert_publish_blocked(
            bin_path, args.pionc, work, "mutate_and_read_view",
            "fn mutate_and_read(a : Array[Int], v : ArrayView[Int]) -> Int { a[0] = 99; v.length() }\npub fn f(ops : Array[Int]) -> Int { mutate_and_read(ops, ops[0:2]) }\n",
            "MBT2PION_BORROWED_ARRAY_SLICE",
        )

        # 3h. Callee writing to ArrayView param MUST fail closed
        assert_publish_blocked(
            bin_path, args.pionc, work, "write_view",
            "fn write_view(v : ArrayView[Int]) -> Int { v[0] = 99; v.length() }\npub fn f(ops : Array[Int]) -> Int { write_view(ops[0:2]) }\n",
            "MBT2PION_BORROWED_ARRAY_SLICE",
        )

        # 3i. Aliased array mutated inside `for v in xs[1:]` MUST fail closed
        assert_publish_blocked(
            bin_path, args.pionc, work, "alias_for_ro_slice",
            "pub fn f(xs : Array[Int]) -> Int { let ys = xs; let mut s = 0; for v in xs[1:] { ys[0] = 99; s = s + v }; s }\n",
            "MBT2PION_BORROWED_ARRAY_SLICE",
        )

        # 3j. Labeled ctor arg `as` and array pattern `as` MUST fail closed
        assert_publish_blocked(
            bin_path, args.pionc, work, "labeled_as",
            "priv enum E { A(Int) }\npriv enum W { Ctor(x~ : E) }\npub fn f(w : W) -> Int { match w { Ctor(x=A(n) as y) => n; _ => 0 } }\n",
            "MBT2PION_UNSUPPORTED_SYNTAX",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "array_as",
            "priv enum E { A(Int) }\npub fn f(xs : Array[E]) -> Int { match xs { [A(n) as x, ..] => n; _ => 0 } }\n",
            "MBT2PION_UNSUPPORTED_SYNTAX",
        )

        print("PASS: Wave M2-F4 Track F4-2 4-Target Differential Oracle (Moon native == Moon wasm-gc == Pion native == Pion wasm32 + all negative gates)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
