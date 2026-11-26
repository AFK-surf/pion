#!/usr/bin/env python3
r"""Wave M2-F5 Track F5-1 4-Target Differential Oracle:
MoonBit native == MoonBit wasm-gc == Pion native == Pion wasm32.

Covers:
  1. `String::code_unit_at(i)` UTF-16 code-unit semantics on ASCII, BMP non-ASCII
     (curly quotes U+2018/U+2019, BOM U+FEFF, CJK U+4E2D), and astral surrogate pairs
     (U+1F600 -> 0xD83D, 0xDE00, plus `s.code_unit_at(s.length() - 1)`), while
     keeping non-`String` receivers intact.
  2. Match-arm sibling tuple type inference disambiguating overlapping local enum
     constructors (`Left`/`Right`) with explicit qualification.
  3. `match recv.field.get(...)` arm-first type inference feeding struct update
     `{ ..g, ... }` without falling back to the map's value type.
  4. Unqualified `Number(d, ..)` JSON pattern inside an untyped closure.
  5. Integer and character range patterns (`lo..=hi`, `lo..<hi`, `|`-combined).
  6. `impl Debug for T with to_repr(self)` containing `Repr(Show::to_string(self))`
     resolving nested Show + Debug probes cleanly.
  7. Negative fail-closed gate on ambiguous struct update.
"""
import argparse, os, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

APP_MBT = r'''
// 1. String::code_unit_at(i) UTF-16 code units (ASCII + BMP + BOM + surrogate pair + trailing comma + eq/compare/physical_equal/index)
pub fn run_code_unit_at() -> String {
  let s_ascii = "abc"
  let s_bmp = "\u{2018}\u{2019}\u{FEFF}\u{4E2D}"
  let s_emoji = "\u{1F600}"
  let s_mix = "a\u{2018}\u{1F600}z"
  let eq_ok = if s_ascii.code_unit_at(0) == s_mix.code_unit_at(0) { 1 } else { 0 }
  let peq_ok = if physical_equal("zz".code_unit_at(0), "zz".code_unit_at(1)) { 1 } else { 0 }
  let idx_eq = if s_emoji[1] == s_emoji.code_unit_at(1) { 1 } else { 0 }
  let lit_idx_eq = if "ab"[1] == "ab".code_unit_at(1) { 1 } else { 0 }
  let lit_eq = if "a".code_unit_at(0) == 97 { 1 } else { 0 }
  let cmp_v = "a".code_unit_at(0).compare("z".code_unit_at(0))
  let parts : Array[Int] = [
    s_ascii.code_unit_at(0).to_int(),
    s_bmp.code_unit_at(0).to_int(),
    s_bmp.code_unit_at(1).to_int(),
    s_bmp.code_unit_at(2).to_int(),
    s_bmp.code_unit_at(3).to_int(),
    s_emoji.length(),
    s_emoji.code_unit_at(0).to_int(),
    s_emoji.code_unit_at(s_emoji.length() - 1).to_int(),
    s_emoji.code_unit_at(1,).to_int(),
    eq_ok,
    peq_ok,
    idx_eq,
    lit_idx_eq,
    lit_eq,
    cmp_v,
    s_mix.length(),
    s_mix.code_unit_at(0).to_int(),
    s_mix.code_unit_at(1).to_int(),
    s_mix.code_unit_at(2).to_int(),
    s_mix.code_unit_at(3).to_int(),
    s_mix.code_unit_at(s_mix.length() - 1).to_int(),
  ]
  let out : Array[String] = []
  for x in parts {
    out.push(x.to_string())
  }
  out.join(",")
}

pub fn probe_peq_after_let() -> Int {
  let a = if physical_equal("ab".code_unit_at(1), 98) { 1 } else { 0 }
  let physical_equal = 9
  a + physical_equal
}

pub fn probe_peq_after_block() -> Int {
  let a = { let physical_equal = 9; physical_equal }
  if physical_equal("ab".code_unit_at(1), 98) { a } else { 0 }
}

// 2. Match-arm sibling tuple inference for overlapping local enum ctors
pub enum AnchorSide {
  Below
  Above
  Right
  Left
}

pub enum DrawerEdge {
  Top
  Bottom
  Left
  Right
}

fn side_code(s : AnchorSide) -> Int {
  match s {
    Below => 1
    Above => 2
    Right => 3
    Left => 4
  }
}

pub fn flip_side(asked : AnchorSide, a : Double, b : Double) -> Int {
  let (_, _, other) = match asked {
    Below => (a, b, Above)
    Above => (b, a, Below)
    Right => (a, b, Left)
    Left => (b, a, Right)
  }
  side_code(other)
}

// 3. match recv.field.get(...) arm-first inference feeding struct update
pub struct GroundShape {
  dx : Double
  dh : Double
}

struct Look {
  ground_drawn : GroundShape
}

struct Node {
  look : Look
  h : Double
}

pub struct Tree {
  nodes : Array[Node]
  shown_bys : Map[Int, (Int, (Double) -> GroundShape)]
}

pub fn Tree::drawn(self : Tree, idx : Int, less : Double) -> GroundShape {
  let g = match self.shown_bys.get(idx) {
    Some((of, f)) if of >= 0 => f(self.nodes[of].h)
    _ => self.nodes[idx].look.ground_drawn
  }
  if less != 0.0 {
    { ..g, dh: g.dh - less }
  } else {
    g
  }
}

pub fn run_struct_update() -> String {
  let g0 = GroundShape::{ dx: 3.0, dh: 10.0 }
  let nodes = [Node::{ look: Look::{ ground_drawn: g0 }, h: 25.0 }]
  let shown_bys : Map[Int, (Int, (Double) -> GroundShape)] = Map::new()
  shown_bys.set(0, (0, fn(h) { GroundShape::{ dx: 1.0, dh: h } }))
  let t = Tree::{ nodes, shown_bys }
  let r1 = t.drawn(0, 5.0)
  let t2 = Tree::{ nodes, shown_bys: Map::new() }
  let r2 = t2.drawn(0, 2.0)
  r1.dx.to_int().to_string() + "," + r1.dh.to_int().to_string() + "," + r2.dx.to_int().to_string() + "," + r2.dh.to_int().to_string()
}

// 4. Unqualified Number(d, ..) pattern in untyped closure
pub fn sum_json_nums(j : Json) -> Int {
  match j {
    Array(a) => {
      let ds = a.map(fn(v) {
        match v {
          Number(d, ..) => d
          _ => 0.0
        }
      })
      let mut acc = 0.0
      for d in ds {
        acc = acc + d
      }
      acc.to_int()
    }
    _ => 0
  }
}

// 5. Int and Char range patterns
pub fn classify_code(code : Int) -> Int {
  match code {
    0..=15 => 1
    16..=231 => 2
    232..=255 => 3
    _ => 0
  }
}

pub fn is_hex_char(c : Char) -> Int {
  match c {
    '0'..='9' | 'a'..='f' | 'A'..='F' => 1
    _ => 0
  }
}

// 6. impl Debug for T with to_repr(self) + Show::to_string(self)
pub struct Badge {
  label : String
  rank : Int
}

pub impl Show for Badge with output(self, logger) {
  logger.write_string("Badge(" + self.label + ":" + self.rank.to_string() + ")")
}

pub impl Debug for Badge with to_repr(self) {
  Repr(Show::to_string(self))
}

pub fn run_all() -> String {
  let s1 = run_code_unit_at()
  let s2 = flip_side(Below, 1.0, 2.0).to_string() + "," + flip_side(Right, 1.0, 2.0).to_string() + "," + flip_side(Left, 1.0, 2.0).to_string()
  let s3 = run_struct_update()
  let j : Json = Json::array([Json::number(4.0), Json::string("x"), Json::number(9.0)])
  let s4 = sum_json_nums(j).to_string()
  let s5 = classify_code(0).to_string() + "," + classify_code(100).to_string() + "," + classify_code(255).to_string() + "," + classify_code(300).to_string() + "," + is_hex_char('7').to_string() + "," + is_hex_char('e').to_string() + "," + is_hex_char('g').to_string()
  let b = Badge::{ label: "ok", rank: 7 }
  let _ = Debug::to_repr(b)
  let _ = Debug::to_repr(b,)
  let s6 = Show::to_string(b)
  let s7 = probe_peq_after_let().to_string() + "," + probe_peq_after_block().to_string()
  "F51-CU:" + s1 + "\nF51-CTOR:" + s2 + "\nF51-SU:" + s3 + "\nF51-JSON:" + s4 + "\nF51-RNG:" + s5 + "\nF51-DBG:" + s6 + "\nF51-PEQ:" + s7
}
'''


def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
    if p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
    return p.stdout.strip()


def assert_publish_blocked(bin_path, pionc, work, name, src_text, expect_code):
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
    ]
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
    work = tempfile.mkdtemp(prefix="mbt2pion-f5-1-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])

        # 1. MoonBit native & MoonBit wasm-gc
        md = os.path.join(work, "moon_proj")
        for sub in ("f51app", "cmd"):
            os.makedirs(os.path.join(md, sub))
        for rel, txt in [
            ("moon.mod", 'name = "f51/oracle"\n'),
            ("f51app/moon.pkg", "\n"),
            ("f51app/app.mbt", APP_MBT),
            ("cmd/moon.pkg", 'import { "f51/oracle/f51app" }\npkgtype(kind: "executable")\n'),
            ("cmd/main.mbt", "fn main { println(@f51app.run_all()) }\n"),
        ]:
            with open(os.path.join(md, rel), "w") as fh:
                fh.write(txt)

        moon_native = run_cmd([args.moon, "run", "--target", "native", "cmd"], cwd=md)
        moon_wasm = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)
        assert moon_native == moon_wasm, f"MoonBit native vs wasm-gc mismatch:\n{moon_native}\nvs\n{moon_wasm}"

        # 2. Transpile with `mbt2pion --mode publish`
        p_app = os.path.join(work, "p_f51app")
        os.makedirs(os.path.join(p_app, "src"))
        with open(os.path.join(p_app, "pion.toml"), "w") as fh:
            fh.write(
                f'[package]\nname = "f51app"\nversion = "0.1.0"\n'
                f'[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
            )
        run_cmd([
            bin_path, "--src", os.path.join(md, "f51app"), "--out", os.path.join(p_app, "src"),
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
        ])

        # Verify String::code_unit_at routed to mbt_compat::utf16_code_unit_at and no raw .code_unit_at( remains
        gen_app = open(os.path.join(p_app, "src", "app.pion")).read()
        assert "mbt_compat::utf16_code_unit_at(" in gen_app, "expected mbt_compat::utf16_code_unit_at in generated code"
        assert ".code_unit_at(" not in gen_app, "raw String::code_unit_at must not remain in generated code"
        assert "pub fn Badge::to_repr(self : Badge) -> String" in gen_app, "impl Debug must lower to Badge::to_repr"
        assert "impl Debug for Badge" not in gen_app, "impl Debug must not be emitted in Pion output"

        # 3. Run Pion native & Pion wasm32 and assert 4-target exact parity + Badge::to_repr runtime check
        with open(os.path.join(p_app, "src", "main.pion"), "w") as fh:
            fh.write(
                'pub fn main(w : World) -> Int {\n'
                '  let repr = Badge::to_repr(Badge::{ label: "ok", rank: 7 })\n'
                '  if repr != "\\"Badge(ok:7)\\"" { panic("unexpected Badge::to_repr: " + repr) }\n'
                '  io_println(w, run_all())\n'
                '  0\n'
                '}\n'
            )
        pion_native = run_cmd([args.pionc, "run", p_app])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", p_app])

        expected = (
            "F51-CU:97,8216,8217,65279,20013,2,55357,56832,56832,1,1,1,1,1,-1,5,97,8216,55357,56832,122\n"
            "F51-CTOR:2,4,3\n"
            "F51-SU:1,20,3,8\n"
            "F51-JSON:13\n"
            "F51-RNG:1,2,3,0,1,1,0\n"
            "F51-DBG:Badge(ok:7)\n"
            "F51-PEQ:10,9"
        )
        assert moon_native == expected and moon_wasm == expected and pion_native == expected and pion_wasm == expected, (
            f"4-TARGET MISMATCH:\nEXPECTED:\n{expected}\nMOON_NATIVE:\n{moon_native}\nMOON_WASM:\n{moon_wasm}\nPION_NATIVE:\n{pion_native}\nPION_WASM:\n{pion_wasm}"
        )

        # 4. Negative fail-closed gates
        # 4a. Struct update with unknown base & no expected type must block publish
        assert_publish_blocked(
            bin_path, args.pionc, work, "ambig_struct_update",
            "pub struct A { x : Int }\npub struct B { x : Int }\npub fn bad(v : Int) { let _ = { ..v, x: 1 } }\n",
            "MBT2PION_AMBIGUOUS_STRUCT_UPDATE",
        )
        # 4b. Unchecked UInt16 wraparound/escape contexts must fail closed with MBT2PION_UINT16_ESCAPE
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_add_wrap",
            'pub fn bad_add() -> Int { let n = "\\u{1F600}".code_unit_at(1); (n + n).to_int() }\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_sub_wrap",
            'pub fn bad_sub() -> Int { let s = "ab"; (s.code_unit_at(0) - s.code_unit_at(1)).to_int() }\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_cmp_wrap_rhs",
            'pub fn bad_cmp() -> Bool { "a".code_unit_at(0) == 65535 + 98 }\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_compare_wrap_arg",
            'pub fn bad_compare_arg() -> Int { "a".code_unit_at(0).compare(65535 + 98) }\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_compare_wrap_recv",
            'pub fn bad_compare_recv() -> Int { (65535 + 98).compare("a".code_unit_at(0)) }\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_shadowed_physical_equal",
            'fn[T] physical_equal(x : T, y : T) -> T { ignore(y); x }\n'
            'pub fn probe() -> Int {\n'
            '  let n = physical_equal("\\u{1F600}".code_unit_at(1), "\\u{1F600}".code_unit_at(1))\n'
            '  (n + n).to_int()\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_local_let_shadow_physical_equal",
            'pub fn probe() -> Int {\n'
            '  let physical_equal = fn(x, _y) { x }\n'
            '  let n = physical_equal("\\u{1F600}".code_unit_at(1), "\\u{1F600}".code_unit_at(1))\n'
            '  (n + n).to_int()\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_guard_is_shadow_physical_equal",
            'fn[T] first_for(_sample : T) -> (T, T) -> T { fn(x, _y) { x } }\n'
            'pub fn probe() -> Int {\n'
            '  let f = first_for("a"[0])\n'
            '  guard Some(f) is Some(physical_equal) else { return 0 }\n'
            '  let n = physical_equal("\\u{1F600}".code_unit_at(1), "\\u{1F600}".code_unit_at(1))\n'
            '  (n + n).to_int()\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_if_is_shadow_physical_equal",
            'fn[T] first_for(_sample : T) -> (T, T) -> T { fn(x, _y) { x } }\n'
            'pub fn probe() -> Int {\n'
            '  let f = first_for("a"[0])\n'
            '  if Some(f) is Some(physical_equal) {\n'
            '    let n = physical_equal("\\u{1F600}".code_unit_at(1), "\\u{1F600}".code_unit_at(1))\n'
            '    (n + n).to_int()\n'
            '  } else { 0 }\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_match_guard_shadow_physical_equal",
            'fn[T] first_for(_sample : T) -> (T, T) -> T { fn(x, _y) { x } }\n'
            'pub fn probe() -> Int {\n'
            '  let f = first_for("a"[0])\n'
            '  match Some(f) {\n'
            '    Some(physical_equal) if (physical_equal("\\u{1F600}".code_unit_at(1), "\\u{1F600}".code_unit_at(1)) + 1).to_int() > 0 => 1\n'
            '    _ => 0\n'
            '  }\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_paren_guard_is_shadow_physical_equal",
            'fn[T] first_for(_sample : T) -> (T, T) -> T { fn(x, _y) { x } }\n'
            'pub fn probe() -> Int {\n'
            '  let f = first_for("a"[0])\n'
            '  guard (Some(f) is Some(physical_equal)) else { return 0 }\n'
            '  let n = physical_equal("\\u{1F600}".code_unit_at(1), "\\u{1F600}".code_unit_at(1))\n'
            '  (n + n).to_int()\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_paren_if_is_shadow_physical_equal",
            'fn[T] first_for(_sample : T) -> (T, T) -> T { fn(x, _y) { x } }\n'
            'pub fn probe() -> Int {\n'
            '  let f = first_for("a"[0])\n'
            '  if (Some(f) is Some(physical_equal)) {\n'
            '    let n = physical_equal("\\u{1F600}".code_unit_at(1), "\\u{1F600}".code_unit_at(1))\n'
            '    (n + n).to_int()\n'
            '  } else { 0 }\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_paren_while_is_shadow_physical_equal",
            'fn[T] first_for(_sample : T) -> (T, T) -> T { fn(x, _y) { x } }\n'
            'pub fn probe() -> Int {\n'
            '  let f = first_for("a"[0])\n'
            '  while (Some(f) is Some(physical_equal)) {\n'
            '    let n = physical_equal("\\u{1F600}".code_unit_at(1), "\\u{1F600}".code_unit_at(1))\n'
            '    return (n + n).to_int()\n'
            '  }\n'
            '  0\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_paren_if_is_and_shadow_physical_equal",
            'fn[T] first_for(_sample : T) -> (T, T) -> T { fn(x, _y) { x } }\n'
            'pub fn probe() -> Int {\n'
            '  let f = first_for("a"[0])\n'
            '  if (Some(f) is Some(physical_equal)) && (physical_equal("\\u{1F600}".code_unit_at(1), "\\u{1F600}".code_unit_at(1)) + 1).to_int() > 0 { 1 } else { 0 }\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_let_is_and_shadow_physical_equal",
            'fn[T] first_for(_sample : T) -> (T, T) -> T { fn(x, _y) { x } }\n'
            'pub fn probe() -> Int {\n'
            '  let f = first_for("a"[0])\n'
            '  let same = Some(f) is Some(physical_equal) && (physical_equal("\\u{1F600}".code_unit_at(1), "\\u{1F600}".code_unit_at(1)) + 1).to_int() > 0\n'
            '  if same { 1 } else { 0 }\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_array_elem_eq",
            'pub fn probe() -> Int {\n'
            '  let t = "\\u{8001}"\n'
            '  let a = [t[0] + t[0]]\n'
            '  let s = "\\u{2}"\n'
            '  if s.code_unit_at(0) == a[0] { 1 } else { 0 }\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_array_elem_compare",
            'pub fn probe() -> Int {\n'
            '  let t = "\\u{8001}"\n'
            '  let a = [t[0] + t[0]]\n'
            '  let s = "\\u{2}"\n'
            '  s.code_unit_at(0).compare(a[0])\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )
        assert_publish_blocked(
            bin_path, args.pionc, work, "u16_array_elem_peq",
            'pub fn probe() -> Int {\n'
            '  let t = "\\u{8001}"\n'
            '  let a = [t[0] + t[0]]\n'
            '  let s = "\\u{2}"\n'
            '  if physical_equal(s.code_unit_at(0), a[0]) { 1 } else { 0 }\n'
            '}\n',
            "MBT2PION_UINT16_ESCAPE",
        )

        print("PASS: Wave M2-F5 Track F5-1 4-Target Differential Oracle (Moon native == Moon wasm-gc == Pion native == Pion wasm32)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
