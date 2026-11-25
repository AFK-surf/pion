#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

# =====================================================================
# Part 1: B1 (physical_equal) + B2 (Double/Float predicates) + B3 (Eq)
# Multi-package workspace covering cross-pkg forwarding, anti-hijacking,
# flat POD arrays, NaN self-comparison, Native dev/release == Wasm32, ASan/LSan
# =====================================================================
mkdir -p "$TMP_DIR/ws/dep_builtin/src" "$TMP_DIR/ws/dep_custom/src" "$TMP_DIR/ws/app/src"

cat > "$TMP_DIR/ws/dep_builtin/pion.toml" <<'EOF'
[package]
name = "dep_builtin"
version = "0.1.0"
EOF

cat > "$TMP_DIR/ws/dep_builtin/src/lib.pion" <<'EOF'
#derive(Eq)
pub struct CrossPt {
  pub x : Int
  pub y : Int
}

pub fn fwd_phys[T](a : T, b : T) -> Bool {
  physical_equal(a, b)
}

pub fn fwd_eq[T : Eq](a : T, b : T) -> Bool {
  a == b
}

pub fn fwd_ne[T : Eq](a : T, b : T) -> Bool {
  a != b
}

pub fn bound_only[T : Eq](_a : T) -> Int {
  77
}

pub trait Marker {
  fn tag(self : Self) -> Int
}

#derive(Eq)
pub struct DepBox {
  pub v : Int
}

fn id_dep[T](x~ : T) -> T {
  x
}

pub fn check_xpkg_named_none[T : Marker](n : Option[DepBox], t : T) -> Bool {
  let _ = t
  physical_equal(None, id_dep(x=n)) &&
  (None == id_dep(x=n)) &&
  (if None == id_dep(x=n) { true } else { false })
}
EOF

cat > "$TMP_DIR/ws/dep_custom/pion.toml" <<'EOF'
[package]
name = "dep_custom"
version = "0.1.0"
EOF

cat > "$TMP_DIR/ws/dep_custom/src/lib.pion" <<'EOF'
pub trait Eq {
  fn my_eq(self : Self, other : Self) -> Bool
}

pub struct Tag {
  pub id : Int
}

impl Eq for Tag {
  fn my_eq(self : Tag, other : Tag) -> Bool {
    self.id == other.id
  }
}

pub fn call_custom[T : Eq](a : T, b : T) -> Bool {
  a.my_eq(b)
}
EOF

cat > "$TMP_DIR/ws/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
dep_builtin = { path = "../dep_builtin" }
dep_custom = { path = "../dep_custom" }
EOF

cat > "$TMP_DIR/ws/app/src/main.pion" <<'EOF'
import "dep_builtin"
import "dep_custom"

// Custom trait Eq in consumer must NOT hijack dep_builtin's @builtin:Eq!
trait Eq {
  fn consumer_eq(self : Self, other : Self) -> Bool
}

#derive(Eq)
val struct FlatPod {
  a : Int
  b : Int
}

#derive(Eq)
struct BoxD {
  v : Double
}

#derive(Eq)
struct BoxF {
  v : Float
}

#derive(Eq)
struct BoxI {
  v : Int
}

#derive(Eq)
enum Mode {
  A
  B
}

#derive(Eq)
enum IList[T] {
  Nil
  Cons(T, IList[T])
}

#derive(Eq)
struct LeafArr {
  xs : Array[Int]
}

#derive(Eq)
struct Diamond {
  left : LeafArr
  right : LeafArr
}

fn id_phys[T](a : T, b : T) -> Bool {
  physical_equal(a, b)
}

struct Cmp {
  id : Int
}

fn Cmp::same_phys[T](self : Cmp, a : T, b : T) -> Bool {
  let _ = self.id
  physical_equal(a, b)
}

fn fwd_method_phys[T](c : Cmp, a : T, b : T) -> Bool {
  c.same_phys(a, b)
}

fn poly_phys_via_fnval[T](f : (T, T) -> Bool, a : T, b : T) -> Bool {
  f(a, b)
}

fn eq_gen[T](a : T, b : T) -> Bool {
  a == b
}

fn ne_gen[T](a : T, b : T) -> Bool {
  a != b
}

fn early_return_rhs(flag : Bool) -> Bool {
  let _ = physical_equal(
    BoxI::{ v: 10 },
    if flag {
      return true
    } else {
      BoxI::{ v: 10 }
    },
  )
  false
}

fn early_try_rhs(r : Result[BoxI, String]) -> Result[Bool, String] {
  let eq = physical_equal(BoxI::{ v: 20 }, r?)
  Ok(eq)
}

fn side_effect_unit(log : Array[Int]) -> Bool {
  physical_equal(
    {
      log.push(1)
      ()
    },
    {
      log.push(2)
      ()
    },
  )
}

fn make_opt_int(x : Int) -> Option[Int] {
  Some(x)
}

fn make_none_int() -> Option[Int] {
  None
}

fn empty_after[T](x~ : T) -> Option[BoxI] {
  let _ = x
  None
}

fn id_named[T](x~ : T) -> T {
  x
}

#derive(Eq)
struct GenBox[T] {
  v : T
}

#derive(Eq)
struct WideLeaf {
  leaf : GenBox[Option[Int]]
}

#derive(Eq)
enum ResetChain[T] {
  REnd(T)
  RNext(ResetChain[Option[Int]])
}

#derive(Eq)
enum Delay2[A, B] {
  DEnd(A, B)
  DNext(Delay2[Option[B], Option[Int]])
}

#derive(Eq)
enum Delay4[A, B, C, D] {
  D4End(A, B, C, D)
  D4Next(Delay4[Option[B], Option[C], Option[D], Option[Int]])
}

#derive(Eq)
struct PhantomTag[X] {
  tag : Int
}

#derive(Eq)
enum SneakyPhantom[T] {
  SPEnd(T)
  SPNext(PhantomTag[SneakyPhantom[Option[T]]])
}

impl dep_builtin::Marker for BoxI {
  fn tag(self : BoxI) -> Int {
    self.v
  }
}

fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

pub fn main(w : World) -> Int {
  // ---- B1: physical_equal ----
  let b1 = BoxI::{ v: 42 }
  let b1_alias = b1
  let b2 = BoxI::{ v: 42 }
  must(physical_equal(b1, b1_alias), "b1 alias true")
  must(!physical_equal(b1, b2), "b1 distinct false")
  must(id_phys(b1, b1_alias), "mono id_phys alias true")
  must(!id_phys(b1, b2), "mono id_phys distinct false")
  must(dep_builtin::fwd_phys(b1, b1_alias), "xpkg fwd_phys alias true")
  must(!dep_builtin::fwd_phys(b1, b2), "xpkg fwd_phys distinct false")
  let phys_fn : (BoxI, BoxI) -> Bool = fn(x : BoxI, y : BoxI) -> Bool { physical_equal(x, y) }
  must(poly_phys_via_fnval(phys_fn, b1, b1_alias), "poly fnval alias true")
  must(!poly_phys_via_fnval(phys_fn, b1, b2), "poly fnval distinct false")

  // Boxed Option[Int]
  let oi1 = make_opt_int(7)
  let oi2 = make_opt_int(7)
  must(physical_equal(oi1, oi1), "boxed Option alias true")
  must(!physical_equal(oi1, oi2), "boxed Option distinct Some(7) false")
  let on1 = make_none_int()
  let on2 = make_none_int()
  must(physical_equal(on1, on2), "boxed Option None same CU true")

  // Niche Option[Struct] & Option[UnitEnum]
  let os1 : Option[BoxI] = Some(b1)
  let os1_same : Option[BoxI] = Some(b1_alias)
  let os2 : Option[BoxI] = Some(b2)
  let os_none : Option[BoxI] = None
  must(physical_equal(os1, os1_same), "niche Option[Struct] alias true")
  must(!physical_equal(os1, os2), "niche Option[Struct] distinct false")
  must(physical_equal(os_none, None), "niche Option[Struct] None true")
  let om1 : Option[Mode] = Some(Mode::A)
  let om2 : Option[Mode] = Some(Mode::A)
  let om3 : Option[Mode] = Some(Mode::B)
  let om_none : Option[Mode] = None
  must(physical_equal(om1, om2), "niche Option[UnitEnum] same true")
  must(!physical_equal(om1, om3), "niche Option[UnitEnum] diff false")
  must(physical_equal(om_none, None), "niche Option[UnitEnum] None true")
  must(physical_equal(Mode::A, Mode::A) && !physical_equal(Mode::A, Mode::B), "unit enum")

  // Flat POD array materialization
  let pods : Array[FlatPod] = [FlatPod::{ a: 1, b: 2 }, FlatPod::{ a: 3, b: 4 }]
  let x = pods[0]
  must(physical_equal(x, x), "flat pod let x = a[0]; physical_equal(x, x) true")
  must(!physical_equal(pods[0], pods[0]), "flat pod physical_equal(a[0], a[0]) false")
  must(id_phys(x, x), "flat pod mono id_phys(x, x) true")
  must(!id_phys(pods[0], pods[0]), "flat pod mono id_phys(a[0], a[0]) false")
  must(dep_builtin::fwd_phys(x, x), "flat pod xpkg fwd_phys(x, x) true")
  must(!dep_builtin::fwd_phys(pods[0], pods[0]), "flat pod xpkg fwd_phys(a[0], a[0]) false")

  // Generic method Cmp::same_phys[T] (direct and forwarded) on Double +0.0/-0.0 and FlatPod
  let cmp = Cmp::{ id: 7 }
  let pz_m = Double::from_bits(0L)
  let nz_m = Double::from_bits(-9223372036854775808L)
  must(!cmp.same_phys(pz_m, nz_m), "method same_phys Double +0.0/-0.0 false")
  must(!fwd_method_phys(cmp, pz_m, nz_m), "fwd method same_phys Double +0.0/-0.0 false")
  must(cmp.same_phys(x, x), "method same_phys FlatPod x==x true")
  must(!cmp.same_phys(pods[0], pods[0]), "method same_phys FlatPod a[0]!=a[0] false")
  must(fwd_method_phys(cmp, x, x), "fwd method same_phys FlatPod x==x true")
  must(!fwd_method_phys(cmp, pods[0], pods[0]), "fwd method same_phys FlatPod a[0]!=a[0] false")

  // Under-specified LHS (`None`, `Option::None`, `(None, 1)`, `[]`, `Ok(...)`, `Err(...)`) + TUnit fields
  must(None == os_none, "None == os_none")
  must(!(None == os1), "!(None == os1)")
  must(None != os1, "None != os1")
  must(Option::None == os_none && !(Option::None == os1), "Option::None == os")
  must(physical_equal(None, os_none), "physical_equal(None, os_none)")
  must(!physical_equal(None, os1), "!physical_equal(None, os1)")
  must(physical_equal(Option::None, os_none) && !physical_equal(Option::None, os1), "physical_equal(Option::None, os)")
  must((None, 1) == (os_none, 1) && !((None, 1) == (os1, 1)), "(None, 1) == (os, 1)")
  must((1, None) == (1, os_none) && !((1, None) == (1, os1)), "(1, None) == (1, os)")
  must((Option::None, 1) == (os_none, 1) && !((Option::None, 1) == (os1, 1)), "(Option::None, 1) == (os, 1)")
  must([None] == [os_none] && !([None] == [os1]), "[None] == [os]")
  must([None] == [om_none] && !([None] == [om1]), "[None] == [om]")
  must(Some(None) == Some(os_none) && !(Some(None) == Some(os1)), "Some(None) == Some(os)")
  must((if true { None } else { os1 }) == os_none, "if None == os_none")
  must(({ None }) == os_none, "block None == os_none")
  must(physical_equal(None, empty_after(x=1)), "physical_equal(None, empty_after(x=1))")
  must(None == empty_after(x=1), "None == empty_after(x=1)")
  must(physical_equal(None, id_named(x=os_none)), "physical_equal(None, id_named(x=os_none))")
  must(None == id_named(x=os_none), "None == id_named(x=os_none)")
  must(if None == id_named(x=os_none) { true } else { false }, "if None == id_named(x=os_none)")
  let dep_none : Option[dep_builtin::DepBox] = None
  must(dep_builtin::check_xpkg_named_none(dep_none, b1), "xpkg check_xpkg_named_none")
  // Finite acyclic Box[Wide] and finite-graph Reset[Int] equality
  let bw1 = GenBox::{ v: WideLeaf::{ leaf: GenBox::{ v: Some(7) } } }
  let bw2 = GenBox::{ v: WideLeaf::{ leaf: GenBox::{ v: Some(7) } } }
  let bw3 = GenBox::{ v: WideLeaf::{ leaf: GenBox::{ v: None } } }
  must(bw1 == bw2 && !(bw1 == bw3) && bw1 != bw3, "Box[Wide] equality")
  let rc1 : ResetChain[Int] = RNext(RNext(REnd(Some(9))))
  let rc2 : ResetChain[Int] = RNext(RNext(REnd(Some(9))))
  let rc3 : ResetChain[Int] = RNext(RNext(REnd(None)))
  must(rc1 == rc2 && !(rc1 == rc3) && rc1 != rc3, "Reset[Int] equality")
  // Finite instantiation graphs Delay[A, B], Delay4[A, B, C, D], and Phantom-guarded Sneaky[T]
  let dl1 : Delay2[Int, Int] = DNext(DNext(DEnd(Some(Some(3)), Some(4))))
  let dl2 : Delay2[Int, Int] = DNext(DNext(DEnd(Some(Some(3)), Some(4))))
  let dl3 : Delay2[Int, Int] = DNext(DNext(DEnd(Some(None), Some(4))))
  must(dl1 == dl2 && !(dl1 == dl3) && dl1 != dl3, "Delay2[Int, Int] equality")
  let d4a : Delay4[Int, Int, Int, Int] = D4Next(D4Next(D4Next(D4Next(D4End(Some(Some(Some(Some(1)))), Some(Some(Some(2))), Some(Some(3)), Some(4))))))
  let d4b : Delay4[Int, Int, Int, Int] = D4Next(D4Next(D4Next(D4Next(D4End(Some(Some(Some(Some(1)))), Some(Some(Some(2))), Some(Some(3)), Some(4))))))
  let d4c : Delay4[Int, Int, Int, Int] = D4Next(D4Next(D4Next(D4Next(D4End(Some(Some(Some(None))), Some(Some(Some(2))), Some(Some(3)), Some(4))))))
  must(d4a == d4b && !(d4a == d4c) && d4a != d4c, "Delay4 equality")
  let sp1 : SneakyPhantom[Int] = SPNext(PhantomTag::{ tag: 11 })
  let sp2 : SneakyPhantom[Int] = SPNext(PhantomTag::{ tag: 11 })
  let sp3 : SneakyPhantom[Int] = SPNext(PhantomTag::{ tag: 12 })
  must(sp1 == sp2 && !(sp1 == sp3) && sp1 != sp3, "SneakyPhantom equality")
  let pa_empty : Array[FlatPod] = []
  must([] == pa_empty, "[] == pa_empty")
  must(!([] == pods), "!([] == pods)")
  let fa_empty : FixedArray[FlatPod] = FixedArray::from_array(pa_empty)
  let fa_pods : FixedArray[FlatPod] = FixedArray::from_array(pods)
  must([] == fa_empty && !([] == fa_pods), "[] == FixedArray[FlatPod]")
  let opt_u1 : Option[Unit] = Some(())
  let opt_u2 : Option[Unit] = Some(())
  must(opt_u1 == opt_u2 && !(opt_u1 != opt_u2), "Some(()) == Some(())")
  let res_u1 : Result[Unit, String] = Ok(())
  let res_u2 : Result[Unit, String] = Ok(())
  must(res_u1 == res_u2 && Ok(()) == res_u1, "Ok(()) == Ok(())")
  must(((), 1) == ((), 1) && ((), 1) != ((), 2), "((), 1) == ((), 1)")

  // Float / Double bitwise identity (+0.0 vs -0.0, same vs diff NaN payloads)
  let pz = Double::from_bits(0L)
  let nz = Double::from_bits(-9223372036854775808L)
  let dnan1 = Double::from_bits(9221120237041090561L)
  let dnan2 = Double::from_bits(9221120237041090562L)
  must(!physical_equal(pz, nz), "Double +0.0 vs -0.0 false")
  must(physical_equal(dnan1, dnan1), "Double same NaN bits true")
  must(!physical_equal(dnan1, dnan2), "Double diff NaN payload false")
  must(!dep_builtin::fwd_phys(pz, nz), "xpkg Double +0.0 vs -0.0 false")
  must(dep_builtin::fwd_phys(dnan1, dnan1), "xpkg Double same NaN true")

  let fpz = Float::from_bits(0)
  let fnz = Float::from_bits(-2147483648)
  let fnan1 = Float::from_bits(2143289345)
  let fnan2 = Float::from_bits(2143289346)
  must(!physical_equal(fpz, fnz), "Float +0.0 vs -0.0 false")
  must(physical_equal(fnan1, fnan1), "Float same NaN bits true")
  must(!physical_equal(fnan1, fnan2), "Float diff NaN payload false")

  // Unit side effects + right-arg early exit RC safety
  let log : Array[Int] = []
  must(side_effect_unit(log), "Unit physical_equal always true")
  must(log.length() == 2 && log[0] == 1 && log[1] == 2, "Unit eval order")
  must(early_return_rhs(true), "early return rhs")
  match early_try_rhs(Err("boom")) {
    Err(e) => must(e == "boom", "early try rhs")
    Ok(_) => panic("expected Err")
  }

  // ---- B2: Double & Float is_nan / is_inf / is_finite ----
  let d_pinf = Double::from_bits(9218868437227405312L)
  let d_ninf = Double::from_bits(-4503599627370496L)
  let d_min_sub = Double::from_bits(1L)
  let d_nmin_sub = Double::from_bits(-9223372036854775807L)
  let d_max_fin = Double::from_bits(9218868437227405311L)
  let d_nmax_fin = Double::from_bits(-4503599627370497L)
  must(!d_pinf.is_nan() && d_pinf.is_inf() && !d_pinf.is_finite(), "d +Inf")
  must(!d_ninf.is_nan() && d_ninf.is_inf() && !d_ninf.is_finite(), "d -Inf")
  must(dnan1.is_nan() && !dnan1.is_inf() && !dnan1.is_finite(), "d NaN")
  must(!pz.is_nan() && !pz.is_inf() && pz.is_finite(), "d +0")
  must(!nz.is_nan() && !nz.is_inf() && nz.is_finite(), "d -0")
  must(!d_min_sub.is_nan() && !d_min_sub.is_inf() && d_min_sub.is_finite(), "d +min_sub")
  must(!d_nmin_sub.is_nan() && !d_nmin_sub.is_inf() && d_nmin_sub.is_finite(), "d -min_sub")
  must(!d_max_fin.is_nan() && !d_max_fin.is_inf() && d_max_fin.is_finite(), "d +max_fin")
  must(!d_nmax_fin.is_nan() && !d_nmax_fin.is_inf() && d_nmax_fin.is_finite(), "d -max_fin")

  let f_pinf = Float::from_bits(2139095040)
  let f_ninf = Float::from_bits(-8388608)
  let f_min_sub = Float::from_bits(1)
  let f_nmin_sub = Float::from_bits(-2147483647)
  let f_max_fin = Float::from_bits(2139095039)
  let f_nmax_fin = Float::from_bits(-8388609)
  must(!f_pinf.is_nan() && f_pinf.is_inf() && !f_pinf.is_finite(), "f +Inf")
  must(!f_ninf.is_nan() && f_ninf.is_inf() && !f_ninf.is_finite(), "f -Inf")
  must(fnan1.is_nan() && !fnan1.is_inf() && !fnan1.is_finite(), "f NaN")
  must(!fpz.is_nan() && !fpz.is_inf() && fpz.is_finite(), "f +0")
  must(!fnz.is_nan() && !fnz.is_inf() && fnz.is_finite(), "f -0")
  must(!f_min_sub.is_nan() && !f_min_sub.is_inf() && f_min_sub.is_finite(), "f +min_sub")
  must(!f_nmin_sub.is_nan() && !f_nmin_sub.is_inf() && f_nmin_sub.is_finite(), "f -min_sub")
  must(!f_max_fin.is_nan() && !f_max_fin.is_inf() && f_max_fin.is_finite(), "f +max_fin")
  must(!f_nmax_fin.is_nan() && !f_nmax_fin.is_inf() && f_nmax_fin.is_finite(), "f -max_fin")

  // ---- B3: @builtin:Eq anti-hijacking + structural ==/!= + NaN conservation ----
  let cp1 = dep_builtin::CrossPt::{ x: 3, y: 4 }
  let cp2 = dep_builtin::CrossPt::{ x: 3, y: 4 }
  let cp3 = dep_builtin::CrossPt::{ x: 3, y: 5 }
  must(dep_builtin::fwd_eq(cp1, cp2) && !dep_builtin::fwd_eq(cp1, cp3), "xpkg builtin Eq")
  must(dep_builtin::bound_only(cp1) == 77, "xpkg bound_only")
  must(
    dep_custom::call_custom(dep_custom::Tag::{ id: 9 }, dep_custom::Tag::{ id: 9 }),
    "xpkg custom trait Eq",
  )

  // Option[Int], Option[Struct], Option[UnitEnum]
  must(oi1 == oi2 && !(oi1 != oi2), "Option[Int] structural eq")
  must(oi1 != on1 && on1 == on2, "Option[Int] None eq")
  must(os1 == os2 && os1 != os_none && os_none == None, "Option[Struct] structural eq")
  must(om1 == om2 && om1 != om3 && om1 != om_none && om_none == None, "Option[UnitEnum] eq")

  // Result & Tuple
  let r1 : Result[Int, String] = Ok(5)
  let r2 : Result[Int, String] = Ok(5)
  let r3 : Result[Int, String] = Err("no")
  let r4 : Result[Int, String] = Err("no")
  must(r1 == r2 && r1 != r3 && r3 == r4, "Result structural eq")
  must(Ok(5) == r1 && Err("no") == r3 && !(Ok(6) == r1), "under-specified Ok/Err LHS eq")
  must((1, "a", Some(2)) == (1, "a", Some(2)), "Tuple eq")
  must((1, "a", Some(2)) != (1, "a", Some(3)), "Tuple ne")

  // Array & FixedArray (including flat POD differing only in 2nd field of 2nd element!)
  let pa1 : Array[FlatPod] = [FlatPod::{ a: 1, b: 2 }, FlatPod::{ a: 3, b: 4 }]
  let pa2 : Array[FlatPod] = [FlatPod::{ a: 1, b: 2 }, FlatPod::{ a: 3, b: 4 }]
  let pa3 : Array[FlatPod] = [FlatPod::{ a: 1, b: 2 }, FlatPod::{ a: 3, b: 99 }]
  must(pa1 == pa2 && pa1 != pa3, "Array[FlatPod] eq")
  let fa1 : FixedArray[FlatPod] = FixedArray::from_array(pa1)
  let fa2 : FixedArray[FlatPod] = FixedArray::from_array(pa2)
  let fa3 : FixedArray[FlatPod] = FixedArray::from_array(pa3)
  must(fa1 == fa2 && fa1 != fa3, "FixedArray[FlatPod] eq")

  // Immutable recursive list inside Array + Diamond DAG
  let lst1 : IList[Int] = IList::Cons(1, IList::Cons(2, IList::Nil))
  let lst2 : IList[Int] = IList::Cons(1, IList::Cons(2, IList::Nil))
  let al1 : Array[IList[Int]] = [lst1]
  let al2 : Array[IList[Int]] = [lst2]
  must(al1 == al2, "Array[IList[Int]] eq")
  let dm1 = Diamond::{ left: LeafArr::{ xs: [1, 2] }, right: LeafArr::{ xs: [3] } }
  let dm2 = Diamond::{ left: LeafArr::{ xs: [1, 2] }, right: LeafArr::{ xs: [3] } }
  must(dm1 == dm2, "Diamond DAG eq")

  // NaN conservation on same object (x == x == false, x != x == true)
  let bd = BoxD::{ v: dnan1 }
  let bf = BoxF::{ v: fnan1 }
  let opt_bd : Option[BoxD] = Some(bd)
  let tup_bd = (1, bd)
  let arr_bd : Array[BoxD] = [bd]
  let farr_bd : FixedArray[BoxD] = FixedArray::from_array(arr_bd)
  must(!(bd == bd) && bd != bd, "BoxD NaN self eq/ne")
  must(!(bf == bf) && bf != bf, "BoxF NaN self eq/ne")
  must(!(opt_bd == opt_bd) && opt_bd != opt_bd, "Option[BoxD] NaN self eq/ne")
  must(!(tup_bd == tup_bd) && tup_bd != tup_bd, "Tuple NaN self eq/ne")
  must(!(arr_bd == arr_bd) && arr_bd != arr_bd, "Array NaN self eq/ne")
  must(!(farr_bd == farr_bd) && farr_bd != farr_bd, "FixedArray NaN self eq/ne")
  must(!eq_gen(bd, bd) && ne_gen(bd, bd), "generic eq_gen NaN self")
  must(!dep_builtin::fwd_eq(bd, bd) && dep_builtin::fwd_ne(bd, bd), "xpkg fwd_eq NaN self")

  io_println(w, "WAVE_L1B_CORE_OK")
  0
}
EOF

# Native dev & release
DEV_OUT="$("$PIONC" run "$TMP_DIR/ws/app")"
[ "$DEV_OUT" = "WAVE_L1B_CORE_OK" ] || { echo "FAIL: native dev output: $DEV_OUT" >&2; exit 1; }
"$PIONC" build --release -o "$TMP_DIR/app_rel" "$TMP_DIR/ws/app"
REL_OUT="$("$TMP_DIR/app_rel")"
[ "$REL_OUT" = "WAVE_L1B_CORE_OK" ] || { echo "FAIL: native release output: $REL_OUT" >&2; exit 1; }

# Wasm32 parity
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/app.wasm" "$TMP_DIR/ws/app"
  WASM_OUT="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/app.wasm")"
  [ "$WASM_OUT" = "WAVE_L1B_CORE_OK" ] || { echo "FAIL: wasm32 output: $WASM_OUT" >&2; exit 1; }
fi

# ASan/LSan 0-leak check on B1/B3 (standalone single-file version for direct --emit-obj + ASan link)
ASAN_CC="${CC:-cc}"
printf 'int main(void){return 0;}\n' > "$TMP_DIR/asan_probe.c"
if "$ASAN_CC" -fsanitize=address "$TMP_DIR/asan_probe.c" -o "$TMP_DIR/asan_probe" >/dev/null 2>&1 && "$TMP_DIR/asan_probe" >/dev/null 2>&1; then
  CC="$ASAN_CC" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"
  cat > "$TMP_DIR/l1b_asan.pion" <<'EOF'
#derive(Eq)
val struct Pod { a : Int, b : Int }
#derive(Eq)
enum Mode { A, B }
#derive(Eq)
struct BoxI { v : Int }
#derive(Eq)
struct BoxD { v : Double }

fn early_ret(flag : Bool) -> Bool {
  let _ = physical_equal(BoxI::{ v: 1 }, if flag { return true } else { BoxI::{ v: 2 } })
  false
}

fn early_try(r : Result[BoxI, String]) -> Result[Bool, String] {
  Ok(physical_equal(BoxI::{ v: 1 }, r?))
}

fn empty_after[T](x~ : T) -> Option[BoxI] {
  let _ = x
  None
}

fn id_named[T](x~ : T) -> T {
  x
}

fn must(cond : Bool, msg : String) -> Unit {
  if !cond {
    panic(msg)
  }
}

pub fn main(w : World) -> Int {
  let pods : Array[Pod] = [Pod::{ a: 1, b: 2 }, Pod::{ a: 3, b: 4 }]
  must(!physical_equal(pods[0], pods[0]), "pod mat")
  must(early_ret(true), "early ret")
  match early_try(Err("e")) {
    Err(_) => ()
    Ok(_) => panic("bad")
  }
  let a : Array[Option[(Int, String)]] = [Some((1, "hello")), None]
  let b : Array[Option[(Int, String)]] = [Some((1, "hello")), None]
  must(a == b, "nested eq")
  let os_none : Option[BoxI] = None
  let os_some : Option[BoxI] = Some(BoxI::{ v: 9 })
  must(None == os_none && !(None == os_some), "asan None == os")
  must(Option::None == os_none && !(Option::None == os_some), "asan Option::None == os")
  must(physical_equal(None, os_none) && !physical_equal(None, os_some), "asan phys None os")
  must((None, 1) == (os_none, 1) && !((None, 1) == (os_some, 1)), "asan (None, 1)")
  must((1, None) == (1, os_none) && !((1, None) == (1, os_some)), "asan (1, None)")
  let om_none : Option[Mode] = None
  let om_some : Option[Mode] = Some(Mode::A)
  must([None] == [os_none] && !([None] == [os_some]), "asan [None] == [os]")
  must([None] == [om_none] && !([None] == [om_some]), "asan [None] == [om]")
  must(Some(None) == Some(os_none) && !(Some(None) == Some(os_some)), "asan Some(None)")
  must(physical_equal(None, empty_after(x=1)), "asan physical_equal(None, empty_after(x=1))")
  must(None == empty_after(x=1), "asan None == empty_after(x=1)")
  must(physical_equal(None, id_named(x=os_none)), "asan physical_equal(None, id_named(x=os_none))")
  must(None == id_named(x=os_none), "asan None == id_named(x=os_none)")
  must(if None == id_named(x=os_none) { true } else { false }, "asan if None == id_named(x=os_none)")
  let empty_pods : Array[Pod] = []
  must([] == empty_pods && !([] == pods), "asan [] == pods")
  let ok_r : Result[Int, String] = Ok(5)
  let err_r : Result[Int, String] = Err("no")
  must(Ok(5) == ok_r && Err("no") == err_r, "asan Ok/Err LHS")
  let ou : Option[Unit] = Some(())
  let ru : Result[Unit, String] = Ok(())
  must(ou == Some(()) && ru == Ok(()), "asan TUnit eq")
  let bd = BoxD::{ v: Double::from_bits(9221120237041090561L) }
  must(!(bd == bd) && bd != bd, "nan eq")
  io_println(w, "L1B_ASAN_OK")
  0
}
EOF
  "$PIONC" build --emit-obj "$TMP_DIR/l1b_asan.o" "$TMP_DIR/l1b_asan.pion"
  "$ASAN_CC" -fsanitize=address "$TMP_DIR/l1b_asan.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/l1b_asan_bin"
  ASAN_OUT="$("$TMP_DIR/l1b_asan_bin")"
  [ "$ASAN_OUT" = "L1B_ASAN_OK" ] || { echo "FAIL: ASan output: $ASAN_OUT" >&2; exit 1; }
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = "1" ]; then
  echo "FAIL: PION_REQUIRE_SANITIZERS=1 but ASan probe failed" >&2
  exit 1
fi

# =====================================================================
# Part 2: #verify / extract-lean boundary checks (B1 + B2)
# =====================================================================
cat > "$TMP_DIR/verify_ok.pion" <<'EOF'
#verify
pub fn dbl_preds(d : Double) -> Bool {
  d.is_nan() || d.is_inf() || d.is_finite()
}

#verify
fn same[T : Eq](a : T, b : T) -> Bool {
  a == b
}

#verify
fn req_only[T : Eq](_x : T) -> Int {
  1
}

#verify
pub fn entry() -> Bool {
  same(1, 1) && req_only(2) == 1
}
EOF
"$PIONC" extract-lean --out "$TMP_DIR/lean_out" --json "$TMP_DIR/verify_ok.pion" | grep -q '"ok":true'
grep -q 'Pion.Double.is_inf' "$TMP_DIR/lean_out/VerifyOk/Funs.lean"
grep -q 'Pion.Double.is_finite' "$TMP_DIR/lean_out/VerifyOk/Funs.lean"
grep -q '\[Pion\.Eq ' "$TMP_DIR/lean_out/VerifyOk/Funs.lean"

cat > "$TMP_DIR/verify_custom_eq.pion" <<'EOF'
trait Eq {
  fn eq(self : Self, other : Self) -> Bool
}

struct Tag { v : Int }

impl Eq for Tag {
  #verify
  fn eq(self : Tag, other : Tag) -> Bool {
    self.v == other.v
  }
}

#verify
fn call_custom[T : Eq](a : T, b : T) -> Bool {
  a.eq(b)
}

#verify
pub fn entry_custom() -> Bool {
  call_custom(Tag::{ v: 1 }, Tag::{ v: 1 })
}
EOF
"$PIONC" extract-lean --out "$TMP_DIR/lean_custom_out" --json "$TMP_DIR/verify_custom_eq.pion" | grep -q '"ok":true'

cat > "$TMP_DIR/verify_bad_pe.pion" <<'EOF'
#verify
pub fn bad_pe(a : Int, b : Int) -> Bool {
  physical_equal(a, b)
}
EOF
if "$PIONC" check --json "$TMP_DIR/verify_bad_pe.pion" >/dev/null 2>&1; then
  echo "FAIL: #verify should reject physical_equal" >&2
  exit 1
fi

cat > "$TMP_DIR/verify_bad_flt.pion" <<'EOF'
#verify
pub fn bad_flt(x : Float) -> Bool {
  x.is_finite()
}
EOF
if "$PIONC" check --json "$TMP_DIR/verify_bad_flt.pion" >/dev/null 2>&1; then
  echo "FAIL: #verify should reject Float" >&2
  exit 1
fi

# =====================================================================
# Part 3: B4 — pion.toml [targets] conditional compilation, CAS isolation,
# android_x64 vs linux, pionc test --target wasm32 & cross-target refusal
# =====================================================================
mkdir -p "$TMP_DIR/tpkg/dep/src" "$TMP_DIR/tpkg/app/src"

cat > "$TMP_DIR/tpkg/dep/pion.toml" <<'EOF'
[package]
name = "tdep"
version = "0.1.0"

[targets]
"src/impl_native.pion" = ["native"]
"src/impl_wasm.pion" = ["wasm32"]
"src/only_linux.pion" = ["linux"]
EOF

cat > "$TMP_DIR/tpkg/dep/src/impl_native.pion" <<'EOF'
pub fn which_target() -> String {
  "native"
}
EOF

cat > "$TMP_DIR/tpkg/dep/src/impl_wasm.pion" <<'EOF'
pub fn which_target() -> String {
  "wasm32"
}
EOF

cat > "$TMP_DIR/tpkg/dep/src/only_linux.pion" <<'EOF'
pub fn linux_only_fn() -> Int {
  101
}
EOF

cat > "$TMP_DIR/tpkg/app/pion.toml" <<'EOF'
[package]
name = "tapp"
version = "0.1.0"

[dependencies]
tdep = { path = "../dep" }

[targets]
"src/app_native.pion" = ["native"]
"src/app_wasm.pion" = ["wasm32"]
"src/native_test.pion" = ["native"]
"src/wasm_test.pion" = ["wasm32"]
EOF

cat > "$TMP_DIR/tpkg/app/src/app_native.pion" <<'EOF'
import "tdep"

pub fn app_tag() -> String {
  "app-native:" + tdep::which_target()
}
EOF

cat > "$TMP_DIR/tpkg/app/src/app_wasm.pion" <<'EOF'
import "tdep"

pub fn app_tag() -> String {
  "app-wasm:" + tdep::which_target()
}
EOF

cat > "$TMP_DIR/tpkg/app/src/main.pion" <<'EOF'
pub fn main(w : World) -> Int {
  io_println(w, app_tag())
  0
}
EOF

cat > "$TMP_DIR/tpkg/app/src/native_test.pion" <<'EOF'
test "native target active" {
  debug_assert(app_tag() == "app-native:native", "expected app-native:native")
}
EOF

cat > "$TMP_DIR/tpkg/app/src/wasm_test.pion" <<'EOF'
test "wasm target active" {
  debug_assert(app_tag() == "app-wasm:wasm32", "expected app-wasm:wasm32")
}
EOF

# Shared CAS: native -> wasm32 -> native
T_NAT1="$("$PIONC" run "$TMP_DIR/tpkg/app")"
[ "$T_NAT1" = "app-native:native" ] || { echo "FAIL: tpkg native1=$T_NAT1" >&2; exit 1; }
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/tapp.wasm" "$TMP_DIR/tpkg/app"
  T_WASM="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/tapp.wasm")"
  [ "$T_WASM" = "app-wasm:wasm32" ] || { echo "FAIL: tpkg wasm=$T_WASM" >&2; exit 1; }
fi
T_NAT2="$("$PIONC" run "$TMP_DIR/tpkg/app")"
[ "$T_NAT2" = "app-native:native" ] || { echo "FAIL: tpkg native2=$T_NAT2" >&2; exit 1; }

# android_x64 MUST NOT match `linux`
cat > "$TMP_DIR/tpkg/use_linux.pion" <<'EOF'
import "tdep"
pub fn f() -> Int { tdep::linux_only_fn() }
EOF
mkdir -p "$TMP_DIR/tpkg/chk_linux/src"
cat > "$TMP_DIR/tpkg/chk_linux/pion.toml" <<'EOF'
[package]
name = "chk_linux"
version = "0.1.0"
[dependencies]
tdep = { path = "../dep" }
EOF
cp "$TMP_DIR/tpkg/use_linux.pion" "$TMP_DIR/tpkg/chk_linux/src/main.pion"
"$PIONC" check --target amd64_sysv --json "$TMP_DIR/tpkg/chk_linux" | grep -q '"ok":true'
if "$PIONC" check --target android_x64 --json "$TMP_DIR/tpkg/chk_linux" >/dev/null 2>&1; then
  echo "FAIL: android_x64 must NOT match [targets] linux predicate" >&2
  exit 1
fi

# pionc test native vs --target wasm32 vs cross-target refusal
TEST_NAT_JSON="$("$PIONC" test --json "$TMP_DIR/tpkg/app")"
printf '%s' "$TEST_NAT_JSON" | grep -q '"ok":true'
printf '%s' "$TEST_NAT_JSON" | grep -q '"native target active"'
if printf '%s' "$TEST_NAT_JSON" | grep -q '"wasm target active"'; then
  echo "FAIL: native test should not run wasm_test.pion" >&2
  exit 1
fi

if command -v node >/dev/null 2>&1; then
  TEST_WASM_JSON="$("$PIONC" test --target wasm32 --json "$TMP_DIR/tpkg/app")"
  printf '%s' "$TEST_WASM_JSON" | grep -q '"ok":true'
  printf '%s' "$TEST_WASM_JSON" | grep -q '"wasm target active"'
  if printf '%s' "$TEST_WASM_JSON" | grep -q '"native target active"'; then
    echo "FAIL: wasm32 test should not run native_test.pion" >&2
    exit 1
  fi
fi

# Cross-target refusal: --target android_arm64 AND PION_TARGET=android_arm64
set +e
CROSS1="$("$PIONC" test --target android_arm64 --json "$TMP_DIR/tpkg/app")"
RC1=$?
CROSS2="$(PION_TARGET=android_arm64 "$PIONC" test --json "$TMP_DIR/tpkg/app")"
RC2=$?
set -e
[ "$RC1" -ne 0 ] || { echo "FAIL: --target android_arm64 test must fail" >&2; exit 1; }
[ "$RC2" -ne 0 ] || { echo "FAIL: PION_TARGET=android_arm64 test must fail" >&2; exit 1; }
printf '%s' "$CROSS1" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False and "error" in d'
printf '%s' "$CROSS2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False and "error" in d'

# Hot-cache predicate flip: swap native/wasm32 in [targets] only (no source edits)
cat > "$TMP_DIR/tpkg/app/pion.toml" <<'EOF'
[package]
name = "tapp"
version = "0.1.0"

[dependencies]
tdep = { path = "../dep" }

[targets]
"src/app_native.pion" = ["wasm32"]
"src/app_wasm.pion" = ["native"]
"src/native_test.pion" = ["native"]
"src/wasm_test.pion" = ["wasm32"]
EOF
T_FLIP="$("$PIONC" run "$TMP_DIR/tpkg/app")"
[ "$T_FLIP" = "app-wasm:native" ] || { echo "FAIL: hot-cache predicate flip got $T_FLIP" >&2; exit 1; }

# pionc fmt formats ALL files regardless of [targets]
printf 'pub fn   fmt_me(x : Int) -> Int {\n    x+1\n}\n' > "$TMP_DIR/tpkg/app/src/app_wasm.pion"
"$PIONC" fmt "$TMP_DIR/tpkg/app"
"$PIONC" fmt --check --json "$TMP_DIR/tpkg/app" | grep -q '"ok":true'

# Restore tpkg/app for subsequent tests
cat > "$TMP_DIR/tpkg/app/pion.toml" <<'EOF'
[package]
name = "tapp"
version = "0.1.0"

[dependencies]
tdep = { path = "../dep" }

[targets]
"src/app_native.pion" = ["native"]
"src/app_wasm.pion" = ["wasm32"]
"src/native_test.pion" = ["native"]
"src/wasm_test.pion" = ["wasm32"]
EOF
cat > "$TMP_DIR/tpkg/app/src/app_wasm.pion" <<'EOF'
import "tdep"

pub fn app_tag() -> String {
  "app-wasm:" + tdep::which_target()
}
EOF

# Missing file in [targets] must error (including valid single JSON on check --json)
mkdir -p "$TMP_DIR/bad_missing/src"
cat > "$TMP_DIR/bad_missing/pion.toml" <<'EOF'
[package]
name = "bad_missing"
version = "0.1.0"
[targets]
"src/does_not_exist.pion" = ["native"]
EOF
printf 'pub fn f() -> Int { 1 }\n' > "$TMP_DIR/bad_missing/src/lib.pion"
set +e
MISS_CHK="$("$PIONC" check --json "$TMP_DIR/bad_missing")"
MISS_RC=$?
MISS_TARG="$("$PIONC" test --json --target)"
MISS_TARG_RC=$?
set -e
[ "$MISS_RC" -ne 0 ] || { echo "FAIL: missing file in [targets] must error" >&2; exit 1; }
printf '%s' "$MISS_CHK" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False and "error" in d'
[ "$MISS_TARG_RC" -ne 0 ] || { echo "FAIL: pionc test --json --target without value must fail" >&2; exit 1; }
printf '%s' "$MISS_TARG" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False and "error" in d'

# Item 7: PION_TARGET=android_arm64 overridden by --target <host_target> (single file + package + shared CAS re-run)
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
if [ "$HOST_OS" = "Darwin" ]; then
  if [ "$HOST_ARCH" = "arm64" ]; then HOST_TARGET="arm64_apple"; else HOST_TARGET="amd64_apple"; fi
else
  if [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]; then HOST_TARGET="arm64"; else HOST_TARGET="amd64_sysv"; fi
fi
cat > "$TMP_DIR/single_t.pion" <<'EOF'
test "single host override" {
  if 1 + 1 != 2 { panic("math") }
}
EOF
OV1="$(PION_TARGET=android_arm64 "$PIONC" test --target "$HOST_TARGET" --json "$TMP_DIR/single_t.pion")"
printf '%s' "$OV1" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True'
OV2="$(PION_TARGET=android_arm64 "$PIONC" test --target "$HOST_TARGET" --json "$TMP_DIR/tpkg/app")"
printf '%s' "$OV2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True'
OV3="$(PION_TARGET=android_arm64 "$PIONC" test --target "$HOST_TARGET" --json "$TMP_DIR/tpkg/app")"
printf '%s' "$OV3" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True'

# Item 8: Virtual workspace binary member resolution by active_target + query deps --target
mkdir -p "$TMP_DIR/vws/bin_nat/src" "$TMP_DIR/vws/bin_wasm/src"
cat > "$TMP_DIR/vws/pion.toml" <<'EOF'
[workspace]
members = ["bin_nat", "bin_wasm"]
EOF
cat > "$TMP_DIR/vws/bin_nat/pion.toml" <<'EOF'
[package]
name = "bin_nat"
version = "0.1.0"
[targets]
"src/main_nat.pion" = ["native"]
EOF
cat > "$TMP_DIR/vws/bin_nat/src/main_nat.pion" <<'EOF'
pub fn main(w : World) -> Int {
  io_println(w, "VWS_NAT")
  0
}
EOF
cat > "$TMP_DIR/vws/bin_nat/src/lib.pion" <<'EOF'
pub fn helper_nat() -> Int { 1 }
EOF
cat > "$TMP_DIR/vws/bin_wasm/pion.toml" <<'EOF'
[package]
name = "bin_wasm"
version = "0.1.0"
[targets]
"src/main_wasm.pion" = ["wasm32"]
EOF
cat > "$TMP_DIR/vws/bin_wasm/src/main_wasm.pion" <<'EOF'
pub fn main(w : World) -> Int {
  io_println(w, "VWS_WASM")
  0
}
EOF
cat > "$TMP_DIR/vws/bin_wasm/src/lib.pion" <<'EOF'
pub fn helper_wasm() -> Int { 2 }
EOF
VWS_NAT_OUT="$("$PIONC" run "$TMP_DIR/vws")"
[ "$VWS_NAT_OUT" = "VWS_NAT" ] || { echo "FAIL: virtual workspace native run got $VWS_NAT_OUT" >&2; exit 1; }
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/vws.wasm" "$TMP_DIR/vws"
  VWS_WASM_OUT="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/vws.wasm")"
  [ "$VWS_WASM_OUT" = "VWS_WASM" ] || { echo "FAIL: virtual workspace wasm32 run got $VWS_WASM_OUT" >&2; exit 1; }
fi
QDEPS_NAT="$("$PIONC" query deps --target "$HOST_TARGET" --json "$TMP_DIR/vws")"
QDEPS_WASM="$("$PIONC" query deps --target wasm32 --json "$TMP_DIR/vws")"
[ "$QDEPS_NAT" != "$QDEPS_WASM" ] || { echo "FAIL: query deps --target wasm32 must differ from host target" >&2; exit 1; }

# Item 9: Real Unicode path in [targets]
mkdir -p "$TMP_DIR/uni_pkg/src"
cat > "$TMP_DIR/uni_pkg/pion.toml" <<'EOF'
[package]
name = "uni_pkg"
version = "0.1.0"
[targets]
"src/平台.pion" = ["wasm32"]
EOF
printf 'pub fn uni_fn() -> Int { 42 }\n' > "$TMP_DIR/uni_pkg/src/平台.pion"
printf 'pub fn base() -> Int { 1 }\n' > "$TMP_DIR/uni_pkg/src/lib.pion"
"$PIONC" check --target wasm32 --json "$TMP_DIR/uni_pkg" | grep -q '"ok":true'

# Item 10: Wasm32 test runner unavailable vs real assertion fail vs workspace type error JSON
set +e
NO_NODE_OUT="$(PATH=/nonexistent "$PIONC" test --target wasm32 --json "$TMP_DIR/tpkg/app")"
NO_NODE_RC=$?
set -e
[ "$NO_NODE_RC" -ne 0 ] || { echo "FAIL: missing node must fail wasm32 test" >&2; exit 1; }
printf '%s' "$NO_NODE_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False and "wasm32 test runner unavailable" in d.get("error","")'

if command -v node >/dev/null 2>&1; then
  cat > "$TMP_DIR/wasm_fail_test.pion" <<'EOF'
test "wasm_expected_fail" {
  panic("boom_wasm")
}
EOF
  set +e
  WFAIL_OUT="$("$PIONC" test --target wasm32 --json "$TMP_DIR/wasm_fail_test.pion")"
  WFAIL_RC=$?
  set -e
  [ "$WFAIL_RC" -ne 0 ] || { echo "FAIL: failing wasm32 test must return non-zero" >&2; exit 1; }
  printf '%s' "$WFAIL_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False and any(t["name"]=="wasm_expected_fail" and t["ok"] is False for t in d.get("tests",[]))'
fi

mkdir -p "$TMP_DIR/wasm_tyerr/src"
cat > "$TMP_DIR/wasm_tyerr/pion.toml" <<'EOF'
[package]
name = "wasm_tyerr"
version = "0.1.0"
EOF
printf 'pub fn bad() -> Int { "not_an_int" }\n' > "$TMP_DIR/wasm_tyerr/src/lib.pion"
printf 'test "t" { let _ = bad() }\n' > "$TMP_DIR/wasm_tyerr/src/lib_test.pion"
set +e
WTY_OUT="$("$PIONC" test --target wasm32 --json "$TMP_DIR/wasm_tyerr")"
WTY_RC=$?
set -e
[ "$WTY_RC" -ne 0 ] || { echo "FAIL: wasm32 workspace type error must fail" >&2; exit 1; }
printf '%s' "$WTY_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False and len(d.get("diagnostics",[])) > 0'

echo "PASS: wave_l1b_eq_targets (B1 physical_equal, B2 Float/Double predicates, B3 @builtin:Eq + structural ==/!=, B4 [targets])"
