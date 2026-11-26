#!/usr/bin/env python3
r"""Wave M2-F3d Track F3d-1b 3-Engine Differential Oracle: Moon wasm-gc == Pion native == Pion wasm32.

Covers:
  1. Non-primitive `#derive(Eq)` structs, tuple structs, enums, and generics:
     - `Array`, `Option`, `Result`, tuples, nested `#derive(Eq)`, AND outer `#derive(Eq)`
       containing a custom `impl Eq` field (H2: verifies custom `equal` is NOT skipped!)
  2. Concrete `[pub] impl Eq for T with equal(a, b)`:
     - Omitted param & return types, custom equality logic, `!=` single evaluation == `!equal`
  3. Generic `impl[T] Eq for TheseItems[T]`, `impl[T : Eq] Eq for Box[T]`, `impl[A, B : Eq] Eq for Pair[A, B]`:
     - `TheseItems[() -> Unit]` closure payload comparable via `physical_equal`
  4. Payload-less enum with custom `impl Eq` + `[k] == [k]` (custom `equal` always returns false & counts 1)
  5. Cross-package dependency (`dep` exports `pub impl Eq` and non-primitive `#derive(Eq)`,
     main package compares directly and nests into local `#derive(Eq)` types)
  6. `#derive(Eq, Hash)` non-primitive struct & enum as `Map` keys
  7. Fail-closed negative publish gates (each in its own isolated package):
     - `impl Eq for T with not_equal(a, b)` -> `MBT2PION_UNSUPPORTED_SYNTAX`
     - Split `impl Eq for T with equal` + `impl Eq for T with not_equal` -> `MBT2PION_UNSUPPORTED_SYNTAX`
     - `#derive(Eq)` with closure field -> publish refused
     - Generic non-`Eq` `impl[T : Eq] Show for Array[T]` -> `MBT2PION_UNSUPPORTED_SYNTAX`
     - `impl[T : Eq] Eq for Box[T]` instantiated with closure -> publish refused
"""
import argparse, json, os, shutil, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
COMPAT_DIR = os.path.join(REPO_ROOT, "tools", "mbt_compat")
CLI_DIR = os.path.join(REPO_ROOT, "tools", "mbt2pion_cli")

DEP_EQ_MBT = r'''
#derive(Eq)
pub(all) struct DepRec {
  label : String
  nums : Array[Int]
  opt : Option[(Int, Bool)]
}

pub(all) struct DepCustom {
  key : Int
  ignored : String
}

pub impl Eq for DepCustom with equal(a, b) {
  a.key == b.key
}

#derive(Hash)
pub(all) struct DepHashKey {
  id : Int
}

pub impl Eq for DepHashKey with equal(a, b) {
  a.id == b.id
}
'''

F3D1B_MBT = r'''
// 1. Concrete custom `impl Eq` with call counter (verifies H2 nested `#derive(Eq)` & single-eval `!=`)
pub(all) struct CounterEq {
  id : Int
  tag : String
  hits : Array[Int]
}

impl Eq for CounterEq with equal(a, b) {
  a.hits[0] = a.hits[0] + 1
  a.id == b.id
}

#derive(Eq)
pub(all) struct OuterDerive {
  arr : Array[Int]
  opt : Option[(Int, String)]
  res : Result[Int, String]
  nested : CounterEq
}

#derive(Eq)
pub(all) enum OuterEnum {
  Empty
  Pair(Option[CounterEq], Array[(Int, Bool)])
}

#derive(Eq)
pub struct TupleWrap(Array[Int], Option[CounterEq])

// 2. Generic `impl[T]`, `impl[T : Eq]`, `impl[A, B : Eq]`
pub struct TheseItems[T](Array[T])

impl[T] Eq for TheseItems[T] with equal(a, b) {
  guard a.0.length() == b.0.length() else { return false }
  for i in 0..<a.0.length() {
    if !physical_equal(a.0[i], b.0[i]) {
      return false
    }
  }
  true
}

pub(all) struct Box[T] {
  v : T
}

pub impl[T : Eq] Eq for Box[T] with equal(a, b) {
  a.v == b.v
}

pub(all) struct Pair[A, B] {
  first : A
  second : B
}

impl[A, B : Eq] Eq for Pair[A, B] with equal(x, y) {
  x.second == y.second
}

// 3. Payload-less enum with custom `impl Eq` (non-reflexive, always returns false & increments counter)
let unit_enum_hits : Ref[Int] = Ref(0)

pub(all) enum NonRefl {
  A
  B
}

impl Eq for NonRefl with equal(_a, _b) {
  unit_enum_hits.val = unit_enum_hits.val + 1
  false
}

// 4. Cross-package nested `#derive(Eq)`
#derive(Eq)
pub(all) struct CrossWrap {
  rec : @dep_eq.DepRec
  custom : @dep_eq.DepCustom
}

// 5. `#derive(Eq, Hash)` non-primitive struct & enum as Map keys
#derive(Eq, Hash)
pub(all) struct KeyStruct {
  id : Int
  tags : Array[String]
}

#derive(Eq, Hash)
pub(all) enum KeyEnum {
  KNone
  KSome(Option[Int], Array[Int])
}

// 6. R2: Top-down forward-declared Bytes & Json chains + 3-level enum chain + generic BytesBox + GenBox[Json/Set]
#derive(Eq)
pub(all) struct OuterB {
  m : MidB
}

#derive(Eq)
pub(all) struct MidB {
  l : LeafB
}

#derive(Eq)
pub(all) struct LeafB {
  data : Bytes
}

#derive(Eq)
pub(all) struct OuterJ {
  m : MidJ
}

#derive(Eq)
pub(all) struct MidJ {
  l : LeafJ
}

#derive(Eq)
pub(all) struct LeafJ {
  j : Json
}

#derive(Eq)
pub(all) struct OuterE3 {
  mid : MidE3
}

#derive(Eq)
pub(all) struct MidE3 {
  inner : InnerE
  n : Int
}

#derive(Eq)
pub(all) enum InnerE {
  Raw(Bytes)
  Num(Int)
}

#derive(Eq)
priv struct BytesBox[T] {
  v : T
  data : Bytes
}

#derive(Eq)
pub(all) struct GenBox[T] {
  v : T
}

pub(all) struct SelfEq {
  v : Int
}

impl Eq for SelfEq with equal(a : SelfEq, b : SelfEq) -> Bool {
  a.v == b.v
}

// 7. R3: Mutually recursive MdInline/MdItem/MdBlock, generic Tree[T], mut-array single-eval, and `with fn equal`
#derive(Eq)
pub(all) enum MdInline {
  Text(String)
  Bold(Array[MdInline])
}

#derive(Eq)
pub(all) struct MdItem {
  task : Bool?
  blocks : Array[MdBlock]
}

#derive(Eq)
pub(all) enum MdBlock {
  Para(Array[MdInline])
  List(Array[MdItem])
  Rule
}

#derive(Eq)
pub(all) enum Tree[T] {
  Leaf(T)
  Node(Array[Tree[T]])
}

pub(all) struct MutK {
  id : Int
  flip : Ref[Bool]
  holder : Array[MutWrap[Int]]
}

impl Eq for MutK with equal(a, b) {
  if a.flip.val {
    a.flip.val = false
    if a.holder.length() > 0 {
      a.holder[0].v = [{ id: 999, flip: Ref(false), holder: [] }]
    }
  }
  a.id == b.id
}

#derive(Eq)
pub(all) struct MutWrap[T] {
  tag : T
  data : Bytes
  mut v : Array[MutK]
}

#derive(Hash)
pub(all) struct FnEqKey {
  code : Int
}

pub impl Eq for FnEqKey with fn equal(a, b) {
  a.code == b.code
}

// 8. R4/R5: Single-file, forward/reverse chained, & cross-file alias-mediated recursive #derive(Eq)
type AliasKids = Array[AliasTree]

#derive(Eq)
priv enum AliasTree {
  ALeaf(Int)
  ABranch(AliasKids)
}

type FwdKids = FwdMid
type FwdMid = Array[FwdAliasTree]

#derive(Eq)
priv enum FwdAliasTree {
  FLeaf(Int)
  FBranch(FwdKids)
}

type RevMid = Array[RevAliasTree]
type RevKids = RevMid

#derive(Eq)
priv enum RevAliasTree {
  RLeaf(Int)
  RBranch(RevKids)
}

pub fn run_all() -> String {
  // Case 1: non-primitive #derive(Eq) + H2 nested custom impl Eq + single-eval !=
  let h1 = [0]
  let c1 : CounterEq = { id: 7, tag: "x", hits: h1 }
  let c2 : CounterEq = { id: 7, tag: "y", hits: h1 }
  let c3 : CounterEq = { id: 8, tag: "x", hits: h1 }
  let d1 = c1 == c2
  let d2 = c1 != c3
  let o1 : OuterDerive = { arr: [1, 2], opt: Some((3, "a")), res: Ok(9), nested: c1 }
  let o2 : OuterDerive = { arr: [1, 2], opt: Some((3, "a")), res: Ok(9), nested: c2 }
  let o3 : OuterDerive = { arr: [1, 2], opt: Some((3, "a")), res: Ok(9), nested: c3 }
  let oe = o1 == o2 && o1 != o3
  let e1 = OuterEnum::Pair(Some(c1), [(1, true)])
  let e2 = OuterEnum::Pair(Some(c2), [(1, true)])
  let e3 = OuterEnum::Pair(Some(c3), [(1, true)])
  let ee = e1 == e2 && e1 != e3
  let tw1 = TupleWrap([4, 5], Some(c1))
  let tw2 = TupleWrap([4, 5], Some(c2))
  let twe = tw1 == tw2
  let line1 = "F3d1b-1:\{d1},\{d2},\{oe},\{ee},\{twe},hits=\{h1[0]}"

  // Case 2: generic impl[T] with closures, impl[T : Eq], impl[A, B : Eq]
  let f1 : () -> Unit = fn() { () }
  let f2 : () -> Unit = fn() { () }
  let ti1 = TheseItems([f1])
  let ti2 = TheseItems([f1])
  let ti3 = TheseItems([f2])
  let b1 : Box[CounterEq] = { v: c1 }
  let b2 : Box[CounterEq] = { v: c2 }
  let p1 : Pair[() -> Unit, Int] = { first: f1, second: 42 }
  let p2 : Pair[() -> Unit, Int] = { first: f2, second: 42 }
  let p3 : Pair[() -> Unit, Int] = { first: f1, second: 99 }
  let line2 = "F3d1b-2:\{ti1 == ti2},\{ti1 == ti3},\{b1 == b2},\{p1 == p2},\{p1 != p3}"

  // Case 3: payload-less enum custom impl Eq + [k] == [k] (no pointer-identity shortcut)
  unit_enum_hits.val = 0
  let k = NonRefl::A
  let arr_k = [k]
  let self_arr_eq = arr_k == arr_k
  let hits_after = unit_enum_hits.val
  let line3 = "F3d1b-3:\{self_arr_eq},hits=\{hits_after}"

  // Case 4: cross-package dep_eq
  let dr1 : @dep_eq.DepRec = { label: "hi", nums: [10, 20], opt: Some((1, true)) }
  let dr2 : @dep_eq.DepRec = { label: "hi", nums: [10, 20], opt: Some((1, true)) }
  let dc1 : @dep_eq.DepCustom = { key: 5, ignored: "a" }
  let dc2 : @dep_eq.DepCustom = { key: 5, ignored: "b" }
  let cw1 : CrossWrap = { rec: dr1, custom: dc1 }
  let cw2 : CrossWrap = { rec: dr2, custom: dc2 }
  let line4 = "F3d1b-4:\{dr1 == dr2},\{dc1 == dc2},\{cw1 == cw2}"

  // Case 5: #derive(Eq, Hash) non-primitive struct & enum as Map keys
  let ms : Map[KeyStruct, Int] = {}
  ms[{ id: 1, tags: ["a", "b"] }] = 100
  ms[{ id: 2, tags: ["c"] }] = 200
  let me : Map[KeyEnum, String] = {}
  me[KNone] = "z"
  me[KSome(Some(3), [1, 2])] = "ok"
  let v1 = ms.get({ id: 1, tags: ["a", "b"] }).unwrap_or(-1)
  let v2 = me.get(KSome(Some(3), [1, 2])).unwrap_or("miss")
  let line5 = "F3d1b-5:\{v1},\{v2}"

  // Case 6: R2 forward-declared Bytes/Json/enum chains, generic BytesBox & GenBox[Json/Set], cross-pkg Hash+impl Eq MapKey, Self
  let ob1 : OuterB = { m: { l: { data: b"abc" } } }
  let ob2 : OuterB = { m: { l: { data: b"abc" } } }
  let ob3 : OuterB = { m: { l: { data: b"abd" } } }
  let oj1 : OuterJ = { m: { l: { j: Json::number(3.5) } } }
  let oj2 : OuterJ = { m: { l: { j: Json::number(3.5) } } }
  let oj3 : OuterJ = { m: { l: { j: Json::string("no") } } }
  let oe1 : OuterE3 = { mid: { inner: Raw(b"xy"), n: 1 } }
  let oe2 : OuterE3 = { mid: { inner: Raw(b"xy"), n: 1 } }
  let oe3 : OuterE3 = { mid: { inner: Num(2), n: 1 } }
  let bb1 : BytesBox[Int] = { v: 7, data: b"ok" }
  let bb2 : BytesBox[Int] = { v: 7, data: b"ok" }
  let bb3 : BytesBox[Int] = { v: 7, data: b"no" }
  let gbj1 : GenBox[Json] = { v: Json::array([Json::number(1.0), Json::boolean(true)]) }
  let gbj2 : GenBox[Json] = { v: Json::array([Json::number(1.0), Json::boolean(true)]) }
  let gbs1 : GenBox[Set[Int]] = { v: Set::from_array([1, 2]) }
  let gbs2 : GenBox[Set[Int]] = { v: Set::from_array([2, 1]) }
  let mdep : Map[@dep_eq.DepHashKey, Int] = {}
  mdep[{ id: 9 }] = 42
  let dep_v = mdep.get({ id: 9 }).unwrap_or(-1)
  let se1 : SelfEq = { v: 5 }
  let se2 : SelfEq = { v: 5 }
  let line6 = "F3d1b-6:\{ob1 == ob2 && ob1 != ob3},\{oj1 == oj2 && oj1 != oj3},\{oe1 == oe2 && oe1 != oe3},\{bb1 == bb2 && bb1 != bb3},\{gbj1 == gbj2},\{gbs1 == gbs2},\{dep_v},\{se1 == se2}"

  // Case 7: R3 mutual recursion (MdInline/MdItem/MdBlock), generic Tree[T], mut-array single-eval, and `with fn equal` MapKey
  let md1 = MdBlock::List([
    { task: Some(true), blocks: [Para([Text("a"), Bold([Text("b")])]), Rule] },
  ])
  let md2 = MdBlock::List([
    { task: Some(true), blocks: [Para([Text("a"), Bold([Text("b")])]), Rule] },
  ])
  let md3 = MdBlock::List([
    { task: Some(false), blocks: [Para([Text("a"), Bold([Text("c")])]), Rule] },
  ])
  let tr1 : Tree[Int] = Node([Leaf(1), Node([Leaf(2), Leaf(3)])])
  let tr2 : Tree[Int] = Node([Leaf(1), Node([Leaf(2), Leaf(3)])])
  let tr3 : Tree[Int] = Node([Leaf(1), Node([Leaf(2), Leaf(4)])])
  let holder : Array[MutWrap[Int]] = []
  let flip = Ref(true)
  let mk1 : MutK = { id: 1, flip: flip, holder: holder }
  let mk2 : MutK = { id: 2, flip: Ref(false), holder: [] }
  let mk1b : MutK = { id: 1, flip: Ref(false), holder: [] }
  let mk2b : MutK = { id: 2, flip: Ref(false), holder: [] }
  let mw1 : MutWrap[Int] = { tag: 10, data: b"zz", v: [mk1, mk2] }
  let mw2 : MutWrap[Int] = { tag: 10, data: b"zz", v: [mk1b, mk2b] }
  holder.push(mw1)
  let mw_eq = mw1 == mw2
  let mfn : Map[FnEqKey, Int] = {}
  mfn[{ code: 7 }] = 42
  let fn_v = mfn.get({ code: 7 }).unwrap_or(-1)
  let line7 = "F3d1b-7:\{md1 == md2},\{md1 == md3},\{tr1 == tr2},\{tr1 == tr3},\{mw_eq},\{fn_v}"

  // Case 8: R4/R5 single-file, forward/reverse chained, & cross-file type-alias recursive #derive(Eq)
  let at1 : AliasTree = ABranch([ALeaf(1), ABranch([ALeaf(2)])])
  let at2 : AliasTree = ABranch([ALeaf(1), ABranch([ALeaf(2)])])
  let at3 : AliasTree = ABranch([ALeaf(1), ABranch([ALeaf(9)])])
  let ft1 : FwdAliasTree = FBranch([FLeaf(1)])
  let ft2 : FwdAliasTree = FBranch([FLeaf(2)])
  let rt1 : RevAliasTree = RBranch([RLeaf(3)])
  let rt2 : RevAliasTree = RBranch([RLeaf(3)])
  let xa1 : CrossA = CrossA::More([{ a: CrossA::Done }])
  let xa2 : CrossA = CrossA::More([{ a: CrossA::Done }])
  let xa3 : CrossA = CrossA::Done
  let line8 = "F3d1b-8:\{at1 == at2},\{at1 == at3},\{ft1 != ft2},\{rt1 == rt2},\{xa1 == xa2},\{xa1 == xa3},\{@shadow_eq.shadow_probe()},\{@shadow_eq.ctrl_probe()}"

  line1 + "\n" + line2 + "\n" + line3 + "\n" + line4 + "\n" + line5 + "\n" + line6 + "\n" + line7 + "\n" + line8
}
'''

LIB_ALIAS_A_MBT = r'''
#derive(Eq)
pub(all) enum CrossA {
  Done
  More(CrossKids)
}
'''

LIB_ALIAS_B_MBT = r'''
pub type CrossKids = Array[CrossB]

#derive(Eq)
pub(all) struct CrossB {
  a : CrossA
}
'''

LIB_ALIAS_SHADOW_MBT = r'''
type Array = Int
type ShadowKids = ReadOnlyArray[Int]
type ShadowTreeKids = ReadOnlyArray[ShadowTree]

#derive(Eq)
priv enum ShadowTree {
  SLeaf(Int)
  SBranch(ShadowTreeKids)
}

pub fn shadow_probe() -> String {
  let a : ShadowKids = [42]
  let t1 : ShadowTree = SBranch([SLeaf(1)])
  let t2 : ShadowTree = SBranch([SLeaf(2)])
  "\{a[0]},\{t1 != t2}"
}

type Spare = Int
type CtrlKids = ReadOnlyArray[Int]

type OptCb = (Int) -> Int
type MaybeCb = OptCb?
type MaybeCbGrouped = ((Int) -> Int)?
type CommentCb = (
  // byte offset of the first '('
  Int
) -> Int
type MaybeCommentCb = CommentCb?

pub fn ctrl_probe() -> String {
  let a : CtrlKids = [42]
  let f : OptCb = fn(x) { x + 1 }
  let m1 : MaybeCb = Some(f)
  let m2 : MaybeCbGrouped = Some(f)
  let m3 : MaybeCommentCb = Some(f)
  let r1 = match m1 {
    Some(g) => g(41)
    None => 0
  }
  let r2 = match m2 {
    Some(g) => g(41)
    None => 0
  }
  let r3 = match m3 {
    Some(g) => g(41)
    None => 0
  }
  "\{a[0]},\{r1},\{r2},\{r3}"
}
'''

NEG_NOT_EQUAL = r'''
pub struct BadNeq { x : Int }
impl Eq for BadNeq with not_equal(a, b) { a.x != b.x }
'''

NEG_SPLIT_NOT_EQUAL = r'''
pub struct BadSplit { x : Int }
impl Eq for BadSplit with equal(a, b) { a.x == b.x }
impl Eq for BadSplit with not_equal(a, b) { a.x != b.x }
'''

NEG_FN_NOT_EQUAL = r'''
pub struct BadFnNeq { x : Int }
impl Eq for BadFnNeq with fn not_equal(a, b) { a.x != b.x }
'''

NEG_CLOSURE_DERIVE = r'''
#derive(Eq)
pub struct BadClosure { cb : () -> Unit }
'''

NEG_GENERIC_SHOW = r'''
impl[T : Eq] Show for Array[T] with to_string(_self) -> String { "" }
'''

NEG_BOX_CLOSURE = r'''
pub(all) struct Box[T] { v : T }
impl[T : Eq] Eq for Box[T] with equal(a, b) { a.v == b.v }
pub fn bad() -> Bool {
  let f : () -> Unit = fn() { () }
  let a : Box[() -> Unit] = { v: f }
  let b : Box[() -> Unit] = { v: f }
  a == b
}
'''


def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
    if p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {' '.join(cmd)}\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
    return p.stdout.strip()


def assert_publish_refused(bin_path, pionc, work, name, src_text, expect_code=None):
    src_dir = os.path.join(work, f"neg_{name}_src")
    out_dir = os.path.join(work, f"neg_{name}_out")
    rep_path = os.path.join(work, f"neg_{name}_rep.json")
    os.makedirs(src_dir, exist_ok=True)
    open(os.path.join(src_dir, f"{name}.mbt"), "w").write(src_text)
    p = subprocess.run(
        [bin_path, "--src", src_dir, "--out", out_dir, "--mode", "publish",
         "--mbt-compat", COMPAT_DIR, "--pionc", pionc, "--report", rep_path, "--no-fmt"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=120,
    )
    assert p.returncode != 0, f"negative `{name}` unexpectedly succeeded!"
    assert not os.path.exists(out_dir), f"negative `{name}` must NOT publish output dir!"
    if expect_code is not None:
        rep = json.load(open(rep_path))
        codes = [d.get("code") for d in rep.get("diagnostics", [])]
        assert expect_code in codes, f"negative `{name}` expected {expect_code}, got {codes}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pionc", default=os.environ.get("PIONC", shutil.which("pionc") or os.path.expanduser("~/.pion/bin/pionc")))
    ap.add_argument("--moon", default=os.environ.get("MOON", shutil.which("moon") or os.path.expanduser("~/.moon/bin/moon")))
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="mbt2pion-f3d1b-oracle-")
    try:
        bin_path = os.path.join(work, "mbt2pion")
        run_cmd([args.pionc, "build", CLI_DIR, "-o", bin_path])

        # 1. MoonBit multi-package project (dep_eq, shadow_eq, lib, cmd)
        md = os.path.join(work, "moon_proj")
        for sub in ("dep_eq", "shadow_eq", "lib", "cmd"):
            os.makedirs(os.path.join(md, sub))
        for rel, txt in [
            ("moon.mod", 'name = "f3d1b/oracle"\n'),
            ("dep_eq/moon.pkg", "\n"),
            ("dep_eq/dep_eq.mbt", DEP_EQ_MBT),
            ("shadow_eq/moon.pkg", "\n"),
            ("shadow_eq/alias_shadow.mbt", LIB_ALIAS_SHADOW_MBT),
            ("lib/moon.pkg", 'import {\n  "f3d1b/oracle/dep_eq",\n  "f3d1b/oracle/shadow_eq",\n}\n'),
            ("lib/f3d1b.mbt", F3D1B_MBT),
            ("lib/alias_a.mbt", LIB_ALIAS_A_MBT),
            ("lib/alias_b.mbt", LIB_ALIAS_B_MBT),
            ("cmd/moon.pkg", 'import { "f3d1b/oracle/lib" }\npkgtype(kind: "executable")\n'),
            ("cmd/main.mbt", 'fn main { println(@lib.run_all()) }\n'),
        ]:
            open(os.path.join(md, rel), "w").write(txt)
        moon_out = run_cmd([args.moon, "run", "--target", "wasm-gc", "cmd"], cwd=md)

        # 2. Transpile dep_eq, shadow_eq, and lib to Pion in dependency order
        p_dep = os.path.join(work, "p_dep_eq")
        p_shadow = os.path.join(work, "p_shadow_eq")
        p_lib = os.path.join(work, "p_lib")
        os.makedirs(os.path.join(p_dep, "src"))
        open(os.path.join(p_dep, "pion.toml"), "w").write(
            f'[package]\nname = "dep_eq"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
        )
        run_cmd([
            bin_path, "--src", os.path.join(md, "dep_eq"), "--out", os.path.join(p_dep, "src"),
            "--package-manifest", os.path.join(p_dep, "pion.toml"),
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
        ])

        os.makedirs(os.path.join(p_shadow, "src"))
        open(os.path.join(p_shadow, "pion.toml"), "w").write(
            f'[package]\nname = "shadow_eq"\nversion = "0.1.0"\n[dependencies]\nmbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
        )
        run_cmd([
            bin_path, "--src", os.path.join(md, "shadow_eq"), "--out", os.path.join(p_shadow, "src"),
            "--package-manifest", os.path.join(p_shadow, "pion.toml"),
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
        ])

        os.makedirs(os.path.join(p_lib, "src"))
        open(os.path.join(p_lib, "pion.toml"), "w").write(
            f'[package]\nname = "f3d1blib"\nversion = "0.1.0"\n[dependencies]\n'
            f'mbt_compat = {{ path = "{COMPAT_DIR}" }}\n'
            f'dep_eq = {{ path = "{p_dep}" }}\n'
            f'shadow_eq = {{ path = "{p_shadow}" }}\n'
        )
        run_cmd([
            bin_path, "--src", os.path.join(md, "lib"), "--out", os.path.join(p_lib, "src"),
            "--package-manifest", os.path.join(p_lib, "pion.toml"),
            "--dep", f"dep_eq={p_dep}",
            "--dep", f"shadow_eq={p_shadow}",
            "--target", "native", "--mode", "publish", "--mbt-compat", COMPAT_DIR, "--pionc", args.pionc,
        ])
        open(os.path.join(p_lib, "src", "main.pion"), "w").write(
            'pub fn main(w : World) -> Int { io_println(w, run_all()); 0 }\n'
        )
        pion_native = run_cmd([args.pionc, "run", p_lib])
        pion_wasm = run_cmd([args.pionc, "run", "--target", "wasm32", p_lib])

        expected = (
            "F3d1b-1:true,true,true,true,true,hits=7\n"
            "F3d1b-2:true,false,true,true,true\n"
            "F3d1b-3:false,hits=1\n"
            "F3d1b-4:true,true,true\n"
            "F3d1b-5:100,ok\n"
            "F3d1b-6:true,true,true,true,true,true,42,true\n"
            "F3d1b-7:true,false,true,false,true,42\n"
            "F3d1b-8:true,false,true,true,true,false,42,true,42,42,42,42"
        )
        assert moon_out == expected and pion_native == moon_out and pion_wasm == moon_out, (
            f"MISMATCH:\nEXPECTED:\n{expected}\nMOON:\n{moon_out}\nNATIVE:\n{pion_native}\nWASM32:\n{pion_wasm}"
        )

        # 3. Negative fail-closed publish gates (each in its own isolated package)
        assert_publish_refused(bin_path, args.pionc, work, "not_equal", NEG_NOT_EQUAL, "MBT2PION_UNSUPPORTED_SYNTAX")
        assert_publish_refused(bin_path, args.pionc, work, "split_not_equal", NEG_SPLIT_NOT_EQUAL, "MBT2PION_UNSUPPORTED_SYNTAX")
        assert_publish_refused(bin_path, args.pionc, work, "fn_not_equal", NEG_FN_NOT_EQUAL, "MBT2PION_UNSUPPORTED_SYNTAX")
        assert_publish_refused(bin_path, args.pionc, work, "closure_derive", NEG_CLOSURE_DERIVE)
        assert_publish_refused(bin_path, args.pionc, work, "generic_show", NEG_GENERIC_SHOW, "MBT2PION_UNSUPPORTED_SYNTAX")
        assert_publish_refused(bin_path, args.pionc, work, "box_closure", NEG_BOX_CLOSURE)

        print("[f3d1b-oracle] PASS: 3-engine (moon wasm-gc == pion-native == pion-wasm32) + 6 fail-closed negative gates!\n" + moon_out)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
