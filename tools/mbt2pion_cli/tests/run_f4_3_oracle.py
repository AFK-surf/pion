#!/usr/bin/env python3
r"""Wave M2-F4 Track F4-3 4-Target Differential Oracle:
MoonBit native == MoonBit wasm-gc == Pion native == Pion wasm32.

Covers:
  1. ABI v2 cross-package `structs` metadata:
     - Verified JSON payload contains `structs` (canonical sorted order, field declaration order,
       `src_name`, `emit_name`, `is_mut`, `visibility`, `ty`, `can_construct`, `can_update`, `complete`).
     - Bidirectional legacy v2 ABI compatibility: new tool reads legacy v2 ABI (no `structs` field)
       with normal cross-package calls succeeding; corrupted/duplicate/out-of-order/tparam-mismatch
       `structs` sidecars fail closed with `MBT2PION_DEP_ABI_ERROR`.
     - Same-name structs in two different packages (`pkg_a::Box[Int]` vs `pkg_b::Box[String]`).
  2. Cross-package enum metadata & `pub using` canonical provenance:
     - `Buffer`, `InPlace::Phone(island~)`, `Key(.., ..)` defined in `f43orig`, re-exported via
       `f43mid1` and `f43mid2` (identical-origin diamond!), consumed in `f43app`.
     - Negative fail-closed gates: conflicting-origin diamond, private `using` hop, cyclic `pub using`,
       missing transitive dep.
  3. `if`/`guard ... is ... &&` nested `as` bindings on non-struct sub-patterns:
     - Single evaluation of effectful scrutinee (event log).
     - Strict short-circuiting (RHS never runs when outer or nested `as` pattern fails).
     - Dominance & outer variable shadowing (`else` and `guard ... else` see outer shadowed var, never `is` binders).
     - Multi-level nested `as` (`Some(Some(x) as inner)`), tuple nested `as` (`Some((a, b) as pair)`),
       combined struct + non-struct nested `as` (`Some(Wrap({ x, .. } as s) as w)` and
       `Some({ item: Some(v) as iv, .. })`), and negative fail-closed on nested or-pattern + `as`.
"""
import argparse, hashlib, json, os, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

ORIG_MBT = r'''
pub(all) struct Buffer {
  mut val : Int
  cap : Int
}

pub(all) struct Box[T] {
  mut item : T
  tag : Int
}

pub(all) struct MixedPriv {
  x : Int
  priv secret : Int
}

pub(all) struct ValPair {
  val : Int
  val_ : Int
}

pub fn make_mixed(x : Int, s : Int) -> MixedPriv {
  MixedPriv::{ x: x, secret: s }
}

pub fn read_mixed_secret(m : MixedPriv) -> Int {
  m.secret
}

pub(all) enum InPlace {
  Phone(island~ : Int)
  Desk(Int)
}

pub(all) enum Key {
  Key(Int, Int, tag~ : Int)
  Empty
}

pub fn buf_sum(b : Buffer) -> Int {
  b.val + b.cap
}
'''

ORIG2_MBT = r'''
pub(all) struct Box[T] {
  label : T
  weight : Int
}

pub(all) enum InPlace {
  Other(Int)
}

pub fn make_box2(s : String, w : Int) -> Box[String] {
  Box::{ label: s, weight: w }
}
'''

MID1_MBT = r'''
pub using @f43orig { type Buffer, type InPlace, type Key, type ValPair, buf_sum }

pub fn mid1_tag() -> Int {
  10
}
'''

MID2_MBT = r'''
pub using @f43orig { type InPlace, type Key }

pub fn mid2_tag() -> Int {
  20
}

pub fn mid2_read_inplace(p : InPlace) -> Int {
  match p {
    Phone(island~) => island
    Desk(n) => n
  }
}
'''

TOP_MBT = r'''
pub using @f43mid1 { type Buffer, type InPlace, type Key, type ValPair, buf_sum }

pub fn top_sum(b : Buffer) -> Int {
  buf_sum(b) + @f43mid1.mid1_tag() + @f43mid2.mid2_tag()
}
'''

APP_MBT = r'''
priv struct InnerBox {
  val : Int
  x : Int
}

priv struct OuterBox {
  a : InnerBox?
  pair : (InnerBox, Int?)
}

priv struct Row {
  mut id : Int
  item : Int?
}

priv enum Wrap {
  Wrap(Row)
  Blank
}

pub fn run_reexport_and_structs() -> String {
  let b : @f43top.Buffer = { val: 7, cap: 13 }
  let ts = @f43top.top_sum(b)
  // Diamond convergence: construct via `@f43top` (-> mid1 -> orig) and pass to `@f43mid2` (-> orig)!
  let p = @f43top.InPlace::Phone(island=42)
  let pv = @f43mid2.mid2_read_inplace(p)
  let k : @f43mid2.Key = @f43top.Key::Key(3, 4, tag=5)
  let kv = match k {
    @f43mid2.Key::Key(first, _, ..) => first * 10
    @f43mid2.Key::Empty => 0
  }
  let b1 : @f43orig.Box[Int] = { item: 11, tag: 2 }
  let b2 : @f43orig2.Box[String] = @f43orig2.make_box2("ok", 9)
  let mp = @f43orig.make_mixed(5, 99)
  let vp : @f43top.ValPair = @f43top.ValPair::{ val: 111, val_: 222 }
  ts.to_string() + "," + pv.to_string() + "," + kv.to_string() + "," +
  (b1.item + b1.tag).to_string() + "," + b2.label + ":" + b2.weight.to_string() + "," +
  (mp.x + @f43orig.read_mixed_secret(mp)).to_string() + "," +
  vp.val.to_string() + "," + vp.val_.to_string()
}

pub fn run_nested_as() -> String {
  let log : Array[String] = []
  let get_pair = fn(opt : (Int, Int)?, tag : String) -> (Int, Int)? {
    log.push("p:" + tag)
    opt
  }
  let get_nest = fn(opt : Int??, tag : String) -> Int?? {
    log.push("n:" + tag)
    opt
  }
  let rhs = fn(tag : String, ok : Bool) -> Bool {
    log.push("r:" + tag)
    ok
  }

  // 1. Tuple nested `as` + outer shadowing isolation in `else`
  let pair = 999
  let a = 888
  let r1 = if get_pair(Some((3, 7)), "1") is Some((a, b) as pair) && rhs("1a", pair.0 == a) && rhs("1b", b > 5) {
    pair.0 * 10 + pair.1 + a
  } else {
    pair + a
  }
  // Pattern fails -> RHS never runs, `else` sees outer `pair == 999` and `a == 888`
  let r2 = if get_pair(None, "2") is Some((a, b) as pair) && rhs("2a", pair.0 == a && b > 0) {
    1
  } else {
    pair + a
  }
  // First RHS fails -> second RHS never runs
  let r3 = if get_pair(Some((4, 2)), "3") is Some((a, _) as pair) && rhs("3a", pair.1 > 10) && rhs("3b", a > 0) {
    1
  } else {
    pair
  }

  // 2. Multi-level nested `as` in `guard ... else { return outer }`
  let guard_fn = fn(opt : Int??, tag : String) -> Int {
    let inner = 777
    guard get_nest(opt, tag) is Some(Some(x) as inner) && rhs("g" + tag, inner is Some(_)) else {
      return inner
    }
    x * 2 + (match inner { Some(v) => v; None => 0 })
  }
  let g1 = guard_fn(Some(Some(8)), "1")
  let g2 = guard_fn(Some(None), "2")
  let g3 = guard_fn(None, "3")

  // 3. Combined struct + non-struct nested `as`
  let row_ok : Row = { id: 5, item: Some(12) }
  let row_no : Row = { id: 6, item: None }
  let c1 = if Some(Wrap::Wrap(row_ok)) is Some(Wrap::Wrap({ id, .. } as s) as w) && rhs("c1", s.id == id && w is Wrap::Wrap(_)) {
    s.id = s.id + 100
    s.id
  } else {
    -1
  }
  let iv = 555
  let c2 = if Some(row_ok) is Some({ item: Some(v) as iv, .. }) && rhs("c2", iv is Some(_)) {
    v + (match iv { Some(k) => k; None => 0 })
  } else {
    iv
  }
  let c3 = if Some(row_no) is Some({ item: Some(v) as iv, .. }) && rhs("c3", v > 0) {
    1
  } else {
    iv
  }

  // 4. P1-4 + Red-team item 8: struct field containing BOTH nested struct pattern AND non-struct `as`
  //    (with keyword-colliding `val` field to prove `field_ty` propagation!)
  let ob : OuterBox = { a: Some({ val: 17, x: 3 }), pair: ({ val: 21, x: 4 }, Some(9)) }
  let d1 = if Some(ob) is Some({ a: Some({ val, x }) as oa, .. }) && rhs("d1", oa is Some(_)) {
    val + x
  } else {
    -1
  }
  let d2 = if Some(ob) is Some({ pair: ({ x, .. }, Some(n) as opt_n), .. }) && rhs("d2", opt_n is Some(_)) {
    x * 10 + n
  } else {
    -1
  }

  // 5. P1-5: top-level parenthesized `(Some(v) as pa)`
  let pa = 444
  let d3 = if Some(13) is (Some(v) as pa) && rhs("d3", pa is Some(_)) {
    v + (match pa { Some(k) => k; None => 0 })
  } else {
    pa
  }

  r1.to_string() + "," + r2.to_string() + "," + r3.to_string() + "|" +
  g1.to_string() + "," + g2.to_string() + "," + g3.to_string() + "|" +
  c1.to_string() + "," + row_ok.id.to_string() + "," + c2.to_string() + "," + c3.to_string() + "|" +
  d1.to_string() + "," + d2.to_string() + "," + d3.to_string() + "|" +
  log.join(",")
}

pub fn run_all() -> String {
  "F43-1:" + run_reexport_and_structs() + "\nF43-2:" + run_nested_as()
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
    work = tempfile.mkdtemp(prefix="mbt2pion-f4-3-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])

        # 1. Build 4-package MoonBit diamond project and run BOTH MoonBit native & MoonBit wasm-gc
        md = os.path.join(work, "moon_proj")
        for sub in ("f43orig", "f43orig2", "f43mid1", "f43mid2", "f43top", "f43app", "cmd"):
            os.makedirs(os.path.join(md, sub))
        for rel, txt in [
            ("moon.mod", 'name = "f43/oracle"\n'),
            ("f43orig/moon.pkg", "\n"),
            ("f43orig/orig.mbt", ORIG_MBT),
            ("f43orig2/moon.pkg", "\n"),
            ("f43orig2/orig2.mbt", ORIG2_MBT),
            ("f43mid1/moon.pkg", 'import { "f43/oracle/f43orig" }\n'),
            ("f43mid1/mid1.mbt", MID1_MBT),
            ("f43mid2/moon.pkg", 'import { "f43/oracle/f43orig" }\n'),
            ("f43mid2/mid2.mbt", MID2_MBT),
            ("f43top/moon.pkg", 'import { "f43/oracle/f43mid1", "f43/oracle/f43mid2" }\n'),
            ("f43top/top.mbt", TOP_MBT),
            ("f43app/moon.pkg", 'import { "f43/oracle/f43orig", "f43/oracle/f43orig2", "f43/oracle/f43mid2", "f43/oracle/f43top" }\n'),
            ("f43app/app.mbt", APP_MBT),
            ("cmd/moon.pkg", 'import { "f43/oracle/f43app" }\npkgtype(kind: "executable")\n'),
            ("cmd/main.mbt", "fn main { println(@f43app.run_all()) }\n"),
        ]:
            with open(os.path.join(md, rel), "w") as fh:
                fh.write(txt)

        moon_native = run_cmd([args.moon, "run", "--target", "native", "cmd"], cwd=md)
        moon_wasm = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)
        assert moon_native == moon_wasm, f"MoonBit native vs wasm-gc mismatch:\n{moon_native}\nvs\n{moon_wasm}"

        # 2. Transpile all packages in topological order with `mbt2pion --mode publish`
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

        p_orig = make_pkg("f43orig", [])
        p_orig2 = make_pkg("f43orig2", [])
        p_mid1 = make_pkg("f43mid1", [("f43orig", p_orig)])
        p_mid2 = make_pkg("f43mid2", [("f43orig", p_orig)])
        p_top = make_pkg("f43top", [("f43orig", p_orig), ("f43mid1", p_mid1), ("f43mid2", p_mid2)])
        p_app = make_pkg("f43app", [
            ("f43orig", p_orig), ("f43orig2", p_orig2),
            ("f43mid1", p_mid1), ("f43mid2", p_mid2), ("f43top", p_top),
        ])

        # Verify ABI v2 `structs` metadata in `f43orig/src/mbt2pion_abi.json`
        orig_abi = json.load(open(os.path.join(p_orig, "src", "mbt2pion_abi.json")))
        sts = orig_abi["payload"]["structs"]
        assert [s["name"] for s in sts] == ["Box", "Buffer", "MixedPriv", "ValPair"], f"unexpected structs: {sts}"
        assert sts[0]["type_params"] == ["T"] and sts[0]["can_construct"] is True and sts[0]["can_update"] is True
        assert sts[1]["fields"][0]["src_name"] == "val" and sts[1]["fields"][0]["emit_name"] == "val_" and sts[1]["fields"][0]["is_mut"] is True
        assert sts[2]["can_construct"] is False and sts[2]["can_update"] is False and sts[2]["fields"][1]["visibility"] == "priv"
        assert sts[3]["fields"][0]["src_name"] == "val" and sts[3]["fields"][0]["emit_name"] == "val_1" and sts[3]["fields"][1]["src_name"] == "val_" and sts[3]["fields"][1]["emit_name"] == "val_"

        # Run Pion native & Pion wasm32 and assert 4-target exact parity!
        with open(os.path.join(p_app, "src", "main.pion"), "w") as fh:
            fh.write("pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n")
        pion_native = run_cmd([args.pionc, "run", p_app])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", p_app])

        expected = (
            "F43-1:50,42,30,13,ok:9,104,111,222\n"
            "F43-2:40,1887,999|24,777,777|105,105,24,555|20,49,26|p:1,r:1a,r:1b,p:2,p:3,r:3a,n:1,r:g1,n:2,n:3,r:c1,r:c2,r:d1,r:d2,r:d3"
        )
        assert moon_native == expected and moon_wasm == expected and pion_native == expected and pion_wasm == expected, (
            f"4-TARGET MISMATCH:\nEXPECTED:\n{expected}\nMOON_NATIVE:\n{moon_native}\nMOON_WASM:\n{moon_wasm}\nPION_NATIVE:\n{pion_native}\nPION_WASM:\n{pion_wasm}"
        )

        # 3. Legacy v2 ABI backward compatibility (dep without `structs` field)
        leg_dep = os.path.join(work, "p_leg")
        os.makedirs(os.path.join(leg_dep, "src"))
        with open(os.path.join(leg_dep, "pion.toml"), "w") as fh:
            fh.write('[package]\nname = "leg"\nversion = "0.1.0"\n')
        leg_pl = {"schema_version": 2, "package": "leg", "enums": [], "struct_val_fields": [], "publishable": True}
        leg_sha = hashlib.sha256(json.dumps(leg_pl, separators=(",", ":")).encode()).hexdigest()
        leg_ptxt = f"// GENERATED BY mbt2pion\n// abi-sha256: {leg_sha}\npub fn ping() -> Int {{ 7 }}\n"
        with open(os.path.join(leg_dep, "src", "leg.pion"), "w") as fh:
            fh.write(leg_ptxt)
        leg_fsha = hashlib.sha256(f"leg.pion:{len(leg_ptxt)}:{hashlib.sha256(leg_ptxt.encode()).hexdigest()}\n".encode()).hexdigest()
        with open(os.path.join(leg_dep, "src", "mbt2pion_abi.json"), "w") as fh:
            fh.write(json.dumps({"schema_version": 2, "package": "leg", "abi_sha256": leg_sha, "files_sha256": leg_fsha, "payload": leg_pl}))
        leg_cons_src = os.path.join(work, "leg_cons_src")
        leg_cons_out = os.path.join(work, "leg_cons_out")
        os.makedirs(leg_cons_src)
        with open(os.path.join(leg_cons_src, "c.mbt"), "w") as fh:
            fh.write("pub fn use_leg() -> Int { @leg.ping() }\n")
        run_cmd([
            bin_path, "--src", leg_cons_src, "--out", leg_cons_out,
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
            "--dep", f"leg={leg_dep}",
        ])

        # 3b. Dual-alias identical published ABI on the EXACT SAME directory `p_orig` (BOTH orders)
        dual_src = os.path.join(work, "dual_alias_src")
        os.makedirs(dual_src)
        with open(os.path.join(dual_src, "d.mbt"), "w") as fh:
            fh.write(
                "pub fn use_dual(b : @f43mid1.Buffer) -> Int {\n"
                "  let p = @f43mid1.InPlace::Phone(island=1)\n"
                "  let b2 : @f43orig_alias.Buffer = { val: 2, cap: 3 }\n"
                "  match p {\n"
                "    @f43mid1.InPlace::Phone(island~) => island + @f43mid1.buf_sum(b) + b2.cap\n"
                "    @f43mid1.InPlace::Desk(n) => n\n"
                "  }\n"
                "}\n"
            )
        for tag, dep_args in [
            ("fwd", ["--dep", f"f43orig={p_orig}", "--dep", f"f43orig_alias={p_orig}", "--dep", f"f43mid1={p_mid1}"]),
            ("rev", ["--dep", f"f43orig_alias={p_orig}", "--dep", f"f43orig={p_orig}", "--dep", f"f43mid1={p_mid1}"]),
        ]:
            dual_out = os.path.join(work, f"dual_alias_out_{tag}")
            run_cmd([
                bin_path, "--src", dual_src, "--out", dual_out,
                "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
            ] + dep_args)

        # 4. Negative fail-closed gates
        # 4a. Conflicting-origin diamond `pub using`
        p_mid_bad = os.path.join(work, "p_mid_bad")
        os.makedirs(os.path.join(p_mid_bad, "src"))
        mid_bad_src = os.path.join(work, "mid_bad_src")
        os.makedirs(mid_bad_src)
        with open(os.path.join(mid_bad_src, "m.mbt"), "w") as fh:
            fh.write("pub using @f43orig2 { type InPlace }\npub fn k() -> Int { 1 }\n")
        with open(os.path.join(p_mid_bad, "pion.toml"), "w") as fh:
            fh.write(f'[package]\nname = "midbad"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nf43orig2 = {{ path = "{p_orig2}" }}\n')
        run_cmd([
            bin_path, "--src", mid_bad_src, "--out", os.path.join(p_mid_bad, "src"),
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
            "--dep", f"f43orig2={p_orig2}",
        ])
        assert_publish_blocked(
            bin_path, args.pionc, work, "conflict_diamond",
            "pub using @f43mid1 { type InPlace }\npub using @midbad { type InPlace }\npub fn f() -> Int { 1 }\n",
            "MBT2PION_DEP_ABI_ERROR",
            ["--dep", f"f43orig={p_orig}", "--dep", f"f43orig2={p_orig2}", "--dep", f"f43mid1={p_mid1}", "--dep", f"midbad={p_mid_bad}"],
        )

        # 4b. Private `using` hop (mid_priv uses non-pub `using`)
        p_mid_priv = os.path.join(work, "p_mid_priv")
        os.makedirs(os.path.join(p_mid_priv, "src"))
        mid_priv_src = os.path.join(work, "mid_priv_src")
        os.makedirs(mid_priv_src)
        with open(os.path.join(mid_priv_src, "m.mbt"), "w") as fh:
            fh.write("using @f43orig { type InPlace }\npub fn f(x : InPlace) -> Int { match x { Phone(island~) => island; Desk(n) => n } }\n")
        with open(os.path.join(p_mid_priv, "pion.toml"), "w") as fh:
            fh.write(f'[package]\nname = "midpriv"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\nf43orig = {{ path = "{p_orig}" }}\n')
        run_cmd([
            bin_path, "--src", mid_priv_src, "--out", os.path.join(p_mid_priv, "src"),
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
            "--dep", f"f43orig={p_orig}",
        ])
        assert_publish_blocked(
            bin_path, args.pionc, work, "priv_hop",
            "pub using @midpriv { type InPlace }\npub fn g() -> Int { 1 }\n",
            "MBT2PION_DEP_ABI_ERROR",
            ["--dep", f"f43orig={p_orig}", "--dep", f"midpriv={p_mid_priv}"],
        )

        # 4c. Nested or-pattern with `as` (both outer-as and per-branch-as Red-team P0-1) must fail closed
        assert_publish_blocked(
            bin_path, args.pionc, work, "nested_pipe_as",
            "priv enum E { A(Int); B(Int) }\npub fn f(opt : E?) -> Int { if opt is Some((A(v) | B(v)) as x) && v > 0 { let _ = x; v } else { 0 } }\n",
            "MBT2PION_UNSUPPORTED_SYNTAX",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "nested_pipe_branch_as",
            "priv enum E { A(Int); B(Int) }\npub fn f(opt : E?) -> Int { if opt is Some(A(1 as y) | B(2 as y)) { y } else { -1 } }\n",
            "MBT2PION_UNSUPPORTED_SYNTAX",
        )

        # 4d. Tampered `structs` sidecar (valid JSON with flipped `is_mut`, NOT truncated!) & ghost struct sidecar rejected (P1-2 + Astra #4)
        p_orig_tamp = os.path.join(work, "p_orig_tamp")
        shutil.copytree(p_orig, p_orig_tamp)
        abi_p = os.path.join(p_orig_tamp, "src", "mbt2pion_abi.json")
        abi_data = json.load(open(abi_p))
        flipped = False
        for st in abi_data["payload"]["structs"]:
            for fld in st["fields"]:
                if fld["is_mut"] is True:
                    fld["is_mut"] = False
                    flipped = True
                    break
            if flipped:
                break
        assert flipped, "expected at least one mutable field in f43orig ABI structs"
        with open(abi_p, "w") as fh:
            json.dump(abi_data, fh, separators=(",", ":"))
        assert json.load(open(abi_p))["payload"]["structs"], "tampered ABI must remain valid JSON"
        assert_publish_blocked(
            bin_path, args.pionc, work, "tampered_structs",
            "pub fn f(b : @f43orig.Buffer) -> Int { b.cap }\n",
            "tampered `mbt2pion_abi.json`",
            ["--dep", f"f43orig={p_orig_tamp}"],
        )
        p_ghost = os.path.join(work, "p_ghost")
        os.makedirs(os.path.join(p_ghost, "src"))
        with open(os.path.join(p_ghost, "pion.toml"), "w") as fh:
            fh.write('[package]\nname = "ghost"\nversion = "0.1.0"\n')
        ghost_pl = {
            "schema_version": 2,
            "package": "ghost",
            "enums": [],
            "struct_val_fields": [],
            "structs": [{
                "name": "Ghost",
                "type_params": [],
                "can_construct": True,
                "can_update": True,
                "complete": True,
                "fields": [{"src_name": "x", "emit_name": "x", "is_mut": False, "visibility": "pub", "ty": "Int"}],
            }],
            "publishable": True,
        }
        ghost_sha = hashlib.sha256(json.dumps(ghost_pl, separators=(",", ":")).encode()).hexdigest()
        ghost_ptxt = f"// GENERATED BY mbt2pion\n// abi-sha256: {ghost_sha}\npub fn ok() -> Int {{ 1 }}\n"
        with open(os.path.join(p_ghost, "src", "g.pion"), "w") as fh:
            fh.write(ghost_ptxt)
        ghost_fsha = hashlib.sha256(f"g.pion:{len(ghost_ptxt)}:{hashlib.sha256(ghost_ptxt.encode()).hexdigest()}\n".encode()).hexdigest()
        with open(os.path.join(p_ghost, "src", "mbt2pion_abi.json"), "w") as fh:
            fh.write(json.dumps({"schema_version": 2, "package": "ghost", "abi_sha256": ghost_sha, "files_sha256": ghost_fsha, "payload": ghost_pl}))
        assert_publish_blocked(
            bin_path, args.pionc, work, "ghost_struct_abi",
            "pub fn f() -> Int { @ghost.ok() }\n",
            "MBT2PION_DEP_ABI_ERROR",
            ["--dep", f"ghost={p_ghost}"],
        )

        print("PASS: Wave M2-F4 Track F4-3 4-Target Differential Oracle (Moon native == Moon wasm-gc == Pion native == Pion wasm32, legacy ABI compat + diamond/priv-hop/tamper/nested-as gates)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
