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
# Part 1: Core + Option niche + Struct/Enum/Tuple + FlatTok Array/FixedArray +
#         Map/vmap composite key & generic GKey[Int]/GKey[Color] (both orders) +
#         Forward-ref Map[FwdColor, Int] + Result[Color, Int]/Result[Int, Color] +
#         GenUnit[T] boxed control + #derive(Eq) + dyn Trait + jtbl
#         (Runs on Native dev, Native release, ASan/LSan, and Wasm32!)
# =====================================================================
cat > "$TMP_DIR/p89_core.pion" <<'EOF'
// Forward reference: Map[FwdColor, Int] used BEFORE `enum FwdColor` is declared!
struct FwdMapHolder {
  m : Map[FwdColor, Int]
}

fn read_fwd_map(h : FwdMapHolder, k : FwdColor) -> Int {
  h.m.get(k).unwrap_or(-1)
}

enum FwdColor {
  Cyan
  Magenta
  Yellow
}

enum A {
  A1
  A2
}

enum A__Int {
  B1
  B2
}

#derive(Eq)
enum Color {
  Red
  Green
  Blue
}

enum Day {
  Mon
  Tue
  Wed
  Thu
  Fri
  Sat
  Sun
}

// Generic payload-less enum: MUST stay boxed (control case)
enum GenUnit[T] {
  U1
  U2
}

#derive(Eq)
struct Palette {
  primary : Color
  name : String
}

struct OptHolder {
  c : Color
  oc : Option[Color]
  n : Int
}

struct FlatTok {
  kind : Color
  opt : Option[Color]
  n : Int
}

struct GKey[T] {
  a : T
  b : Int
}

enum Payload {
  One(Color)
  Maybe(Option[Color])
  Text(String)
}

trait Label {
  fn label(self : Self) -> String
}

impl Label for Color {
  fn label(self : Color) -> String {
    match self {
      Color::Red => "red"
      Color::Green => "green"
      Color::Blue => "blue"
    }
  }
}

let DEF_COLOR : Color = Color::Green
let DEF_OPT : Option[Color] = Some(Color::Blue)

fn id_gen[T](x : T) -> T {
  x
}

fn wrap_opt_gen[T](x : T) -> Option[T] {
  Some(x)
}

fn color_code(c : Color) -> Int {
  match c {
    Color::Red => 10
    Color::Green => 20
    Color::Blue => 30
  }
}

fn day_num(d : Day) -> Int {
  match d {
    Day::Mon => 1
    Day::Tue => 2
    Day::Wed => 3
    Day::Thu => 4
    Day::Fri => 5
    Day::Sat => 6
    Day::Sun => 7
  }
}

fn try_color_sum(a : Option[Color], b : Option[Color]) -> Option[Int] {
  let ca = a?
  let cb = b?
  Some(color_code(ca) + color_code(cb))
}

fn make_opt_color(flag : Bool) -> Option[Color] {
  if flag {
    Some(.Blue)
  } else {
    None
  }
}

fn test_basic_and_jtbl() -> Int {
  let r = Color::Red
  let g = DEF_COLOR
  let b : Color = .Blue
  let mut acc = color_code(r) + color_code(g) + color_code(b)
  if r == Color::Red && r != g && g == Color::Green {
    acc += 1
  }
  if b is Color::Blue {
    acc += 2
  }
  if !(r is Color::Green) {
    acc += 4
  }
  let g2 = id_gen(g)
  if g2 == Color::Green {
    acc += 8
  }
  let days : Array[Day] = [Day::Mon, Day::Tue, Day::Wed, Day::Thu, Day::Fri, Day::Sat, Day::Sun]
  let mut dsum = 0
  for d in days {
    dsum += day_num(d)
  }
  // 60 + 15 + 28 = 103
  acc + dsum
}

fn test_option_niche() -> Int {
  let o1 = make_opt_color(true)
  let o2 = make_opt_color(false)
  let o3 = wrap_opt_gen(Color::Red)
  let o4 = DEF_OPT
  let mut acc = 0
  if o1.is_some() && o2.is_none() {
    acc += 1
  }
  acc += color_code(o1.unwrap_or(Color::Red))
  acc += color_code(o2.unwrap_or(Color::Green))
  if o3 is Some(Color::Red) {
    acc += 5
  }
  if o4 is Some(c) {
    acc += color_code(c)
  }
  let s1 = try_color_sum(o1, o3).unwrap_or(-1)
  let s2 = try_color_sum(o1, o2).unwrap_or(99)
  // 1 + 30 + 20 + 5 + 30 + 40 + 99 = 225
  acc + s1 + s2
}

fn test_containers_and_eq() -> Int {
  let p1 = Palette::{ primary: Color::Red, name: "warm" }
  let p2 = Palette::{ primary: Color::Red, name: "warm" }
  let p3 = Palette::{ primary: Color::Green, name: "warm" }
  let h1 = OptHolder::{ c: Color::Blue, oc: Some(Color::Red), n: 0 }
  let mut acc = 0
  if p1 == p2 && p1 != p3 && h1.c == Color::Blue && (h1.oc is Some(Color::Red)) {
    acc += 10
  }
  let e1 = Payload::One(Color::Blue)
  let e2 = Payload::Maybe(Some(Color::Green))
  let e3 = Payload::Text("hi")
  acc += match e1 {
    Payload::One(c) => color_code(c)
    Payload::Maybe(oc) => color_code(oc.unwrap_or(Color::Red))
    Payload::Text(s) => s.length()
  }
  acc += match e2 {
    Payload::One(c) => color_code(c)
    Payload::Maybe(oc) => color_code(oc.unwrap_or(Color::Red))
    Payload::Text(s) => s.length()
  }
  acc += match e3 {
    Payload::One(c) => color_code(c)
    Payload::Maybe(oc) => color_code(oc.unwrap_or(Color::Red))
    Payload::Text(s) => s.length()
  }
  let tup : (Color, Option[Color], String) = (Color::Red, Some(Color::Blue), "ok")
  acc += color_code(tup.0) + color_code(tup.1.unwrap_or(Color::Green)) + tup.2.length()

  let arr : Array[Color] = [Color::Red, Color::Green]
  arr.push(Color::Blue)
  if arr.contains(Color::Green) && !arr.contains(Color::Red) == false {
    acc += 1
  }
  let popped = arr.pop().unwrap_or(Color::Red)
  acc += color_code(popped)

  let farr : FixedArray[Color] = FixedArray::make(3, Color::Green)
  farr[0] = Color::Red
  farr[2] = Color::Blue
  acc += color_code(farr[0]) + color_code(farr[1]) + color_code(farr[2])

  let oarr : Array[Option[Color]] = [None, Some(Color::Red), Some(Color::Blue)]
  oarr.push(Some(Color::Green))
  let mut osum = 0
  for oc in oarr {
    osum += match oc {
      Some(c) => color_code(c)
      None => 1
    }
  }
  // 10 + 30 + 20 + 2 + 10 + 30 + 2 + 1 + 30 + 60 + (1 + 10 + 30 + 20) = 256
  acc + osum
}

fn test_flat_tok_arrays() -> Int {
  let toks : Array[FlatTok] = [
    FlatTok::{ kind: Color::Red, opt: None, n: 1 },
    FlatTok::{ kind: Color::Green, opt: Some(Color::Blue), n: 2 },
  ]
  toks.push(FlatTok::{ kind: Color::Blue, opt: Some(Color::Red), n: 3 })
  toks[0] = FlatTok::{ kind: Color::Green, opt: Some(Color::Green), n: 4 }
  let cp = toks.copy()
  let mut acc = 0
  for t in cp {
    acc += color_code(t.kind) + color_code(t.opt.unwrap_or(Color::Red)) + t.n
  }
  let ftoks : FixedArray[FlatTok] = FixedArray::make(2, FlatTok::{ kind: Color::Red, opt: None, n: 5 })
  ftoks[1] = FlatTok::{ kind: Color::Blue, opt: Some(Color::Green), n: 6 }
  acc += color_code(ftoks[0].kind) + ftoks[0].n + color_code(ftoks[1].opt.unwrap_or(Color::Red)) + ftoks[1].n
  // cp: (20+20+4) + (20+30+2) + (30+10+3) = 44 + 52 + 43 = 139
  // ftoks: (10+5) + (20+6) = 41 -> total 180
  acc
}

fn test_maps_and_gkey() -> Int {
  let m1 : Map[Color, Int] = Map::new()
  m1.set(Color::Red, 100)
  m1.set(Color::Green, 200)
  m1.set(Color::Blue, 300)
  m1.set(Color::Green, 250)
  let mut acc = m1.get(Color::Red).unwrap_or(0) + m1.get(Color::Green).unwrap_or(0)
  if m1.contains(Color::Blue) {
    acc += 1
  }
  m1.remove(Color::Blue)
  if !m1.contains(Color::Blue) {
    acc += 2
  }
  let ks = m1.keys()
  let mut ksum = 0
  for k in ks {
    ksum += color_code(k)
  }
  acc += ksum

  let m2 : Map[String, Color] = Map::new()
  m2.set("a", Color::Red)
  m2.set("b", Color::Blue)
  acc += color_code(m2.get("a").unwrap_or(Color::Green)) + color_code(m2.get("b").unwrap_or(Color::Green))

  let m3 : Map[(Color, Int), Array[Int]] = Map::new()
  m3.set((Color::Red, 1), [1, 2, 3])
  m3.set((Color::Blue, 2), [10, 20])
  let v1 = m3.get((Color::Red, 1)).unwrap_or([])
  let v2 = m3.get((Color::Blue, 2)).unwrap_or([])
  acc += v1.length() + v2[1]

  // Generic GKey[Int] and GKey[Color] in BOTH orders (distinct vmap layouts!)
  let mi : Map[GKey[Int], String] = Map::new()
  mi.set(GKey::{ a: 7, b: 1 }, "abcd")
  let mc : Map[GKey[Color], String] = Map::new()
  mc.set(GKey::{ a: Color::Blue, b: 2 }, "xyz")
  acc += mi.get(GKey::{ a: 7, b: 1 }).unwrap_or("").length()
  acc += mc.get(GKey::{ a: Color::Blue, b: 2 }).unwrap_or("").length()

  let mc2 : Map[GKey[Color], Int] = Map::new()
  mc2.set(GKey::{ a: Color::Red, b: 9 }, 11)
  let mi2 : Map[GKey[Int], Int] = Map::new()
  mi2.set(GKey::{ a: 9, b: 9 }, 13)
  acc += mc2.get(GKey::{ a: Color::Red, b: 9 }).unwrap_or(0) + mi2.get(GKey::{ a: 9, b: 9 }).unwrap_or(0)

  // Forward-referenced Map[FwdColor, Int]
  let fm : Map[FwdColor, Int] = Map::new()
  fm.set(FwdColor::Magenta, 19)
  let fh = FwdMapHolder::{ m: fm }
  acc += read_fwd_map(fh, FwdColor::Magenta)

  // Tuple vmap non-collision: Map[(A, Int, Int), Int] vs Map[(A__Int, Int), Int]
  let tm3 : Map[(A, Int, Int), Int] = Map::new()
  tm3.set((A::A1, 1, 2), 31)
  tm3.set((A::A2, 3, 4), 41)
  let tm2 : Map[(A__Int, Int), Int] = Map::new()
  tm2.set((A__Int::B1, 2), 51)
  tm2.set((A__Int::B2, 4), 61)
  acc += tm3.get((A::A1, 1, 2)).unwrap_or(0) + tm2.get((A__Int::B2, 4)).unwrap_or(0)

  // 446 + 4 + 3 + 11 + 13 + 19 + (31 + 61) = 588
  acc
}

fn score_gen_unit[T](g : GenUnit[T]) -> Int {
  match g {
    GenUnit::U1 => 3
    GenUnit::U2 => 6
  }
}

fn test_result_and_gen_unit() -> Int {
  let r_ok : Result[Color, Int] = Ok(Color::Blue)
  let r_err : Result[Int, Color] = Err(Color::Green)
  let mut acc = match r_ok {
    Ok(c) => color_code(c)
    Err(n) => n
  }
  acc += match r_err {
    Ok(n) => n
    Err(c) => color_code(c)
  }
  let g1 : GenUnit[Int] = GenUnit::U1
  let g2 : GenUnit[String] = GenUnit::U2
  let gs : Array[GenUnit[Int]] = [g1]
  acc += score_gen_unit(gs[0]) + score_gen_unit(g2)
  // 30 + 20 + 3 + 6 = 59
  acc
}

fn test_dyn_trait() -> Int {
  let d1 : dyn Label = Color::Red
  let d2 : dyn Label = Color::Green
  let d3 : dyn Label = Color::Blue
  let arr : Array[dyn Label] = [d1, d2, d3]
  let mut total = 0
  for item in arr {
    total += item.label().length()
  }
  let od : Option[dyn Label] = Some(Color::Green)
  let extra = match od {
    Some(x) => x.label().length()
    None => 0
  }
  // (3 + 5 + 4) + 5 = 17
  total + extra
}

pub fn main(world : World) -> Int {
  let r1 = test_basic_and_jtbl()
  let r2 = test_option_niche()
  let r3 = test_containers_and_eq()
  let r4 = test_maps_and_gkey()
  let r5 = test_dyn_trait()
  let r6 = test_flat_tok_arrays()
  let r7 = test_result_and_gen_unit()
  io_println(
    world,
    "p89_core ok r1=" + r1.to_string() +
      " r2=" + r2.to_string() +
      " r3=" + r3.to_string() +
      " r4=" + r4.to_string() +
      " r5=" + r5.to_string() +
      " r6=" + r6.to_string() +
      " r7=" + r7.to_string(),
  )
  0
}
EOF

EXP_CORE="p89_core ok r1=103 r2=225 r3=256 r4=588 r5=17 r6=180 r7=59"

# 1a. Native dev
OUT_DEV=$("$PIONC" run "$TMP_DIR/p89_core.pion")
echo "p89_unit_enum core dev -> $OUT_DEV"
if [ "$OUT_DEV" != "$EXP_CORE" ]; then
  echo "FAIL: p89_core dev mismatch (expected '$EXP_CORE')" >&2
  exit 1
fi

# 1b. Native release
OUT_REL=$("$PIONC" run --release "$TMP_DIR/p89_core.pion")
echo "p89_unit_enum core release -> $OUT_REL"
if [ "$OUT_REL" != "$EXP_CORE" ]; then
  echo "FAIL: p89_core release mismatch (expected '$EXP_CORE')" >&2
  exit 1
fi

# 1c. SSA audit
"$PIONC" build --release --emit-ssa "$TMP_DIR/p89_core.ssa" "$TMP_DIR/p89_core.pion"
python3 - "$TMP_DIR/p89_core.ssa" <<'SSA_EOF'
import sys
ssa = open(sys.argv[1]).read()
assert "$pion_enum_Color__" not in ssa, "unexpected static $pion_enum_Color__ hdr"
assert "$pion_enum_Day__" not in ssa, "unexpected static $pion_enum_Day__ hdr"
assert "$pion_drop_enum_Color" not in ssa, "unexpected $pion_drop_enum_Color"
assert "$pion_drop_enum_Day" not in ssa, "unexpected $pion_drop_enum_Day"
assert "jtbl " in ssa, "expected jtbl for 7-variant Day match"
assert "_ZAInt_ZE" in ssa and "Color_ZE" in ssa, "expected distinct GKey[Int] and GKey[Color] vmap symbols"
assert "$pion_enum_GenUnit__U1_hdr" in ssa, "generic unit-like enum GenUnit[T] must remain boxed"
SSA_EOF
echo "p89_unit_enum core SSA audit -> OK"

# 1d. Negative type-check: non-generic unit enum with extra type args `Color[Int]` must be rejected
cat > "$TMP_DIR/p89_neg.pion" <<'EOF'
enum Color {
  Red
  Green
}

pub fn bad(c : Color[Int]) -> Int {
  match c {
    Color::Red => 1
    Color::Green => 2
  }
}
EOF
set +e
NEG_OUT=$("$PIONC" check --json "$TMP_DIR/p89_neg.pion")
NEG_RC=$?
set -e
if [ "$NEG_RC" -eq 0 ] || ! printf '%s' "$NEG_OUT" | grep -q 'E_TYPE_MISMATCH'; then
  echo "FAIL: expected E_TYPE_MISMATCH for Color[Int], got rc=$NEG_RC out=$NEG_OUT" >&2
  exit 1
fi
echo "p89_unit_enum negative Color[Int] check -> OK"

# 1e. ASan / LSan
CC_BIN="${CC:-cc}"
UNAME_S="$(uname -s)"
if [ "$UNAME_S" = "Darwin" ]; then
  ASAN_OPTS="detect_leaks=0:halt_on_error=1"
else
  ASAN_OPTS="detect_leaks=1:halt_on_error=1"
fi

if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --release --emit-obj "$TMP_DIR/p89_core.o" "$TMP_DIR/p89_core.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p89_core.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p89_core_asan"
  OUT_ASAN=$(ASAN_OPTIONS="$ASAN_OPTS" "$TMP_DIR/p89_core_asan")
  echo "p89_unit_enum core ASan ($UNAME_S) -> $OUT_ASAN"
  if [ "$OUT_ASAN" != "$EXP_CORE" ]; then
    echo "FAIL: p89_core ASan mismatch (expected '$EXP_CORE')" >&2
    exit 1
  fi
else
  echo "FAIL: cc -fsanitize=address unavailable; ASan verification required" >&2
  exit 1
fi

# 1f. Wasm32
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p89_core.wasm" "$TMP_DIR/p89_core.pion"
  OUT_WASM="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p89_core.wasm")"
  echo "p89_unit_enum core Wasm32 -> $OUT_WASM"
  if [ "$OUT_WASM" != "$EXP_CORE" ]; then
    echo "FAIL: p89_core Wasm32 mismatch (expected '$EXP_CORE')" >&2
    exit 1
  fi
fi

# =====================================================================
# Part 2: Concurrency (Channel[Color], Channel[Option[Color]],
#         Mutex[Color], Mutex[Map[Color, Int]], scope/spawn capture)
# =====================================================================
cat > "$TMP_DIR/p89_mt.pion" <<'EOF'
enum Color {
  Red
  Green
  Blue
}

fn color_val(c : Color) -> Int {
  match c {
    Color::Red => 1
    Color::Green => 2
    Color::Blue => 3
  }
}

pub fn main(world : World) -> Int {
  let ch : Channel[Color] = Channel::new(8)
  let och : Channel[Option[Color]] = Channel::new(8)
  let mx : Mutex[Color] = Mutex::new(Color::Red)
  let mm : Mutex[Map[Color, Int]] = Mutex::new(Map::new())
  let cap_c = Color::Blue
  let cap_o : Option[Color] = Some(Color::Green)

  scope(world, fn(s : Scope) -> Unit {
    spawn(s, fn() -> Unit {
      let _ = ch.send(Color::Red)
      let _ = ch.send(cap_c)
      let _ = och.send(None)
      let _ = och.send(cap_o)
      mx.set(Color::Green)
      let m = mm.lock()
      m.set(Color::Red, 10)
      m.set(cap_c, 30)
      mm.unlock()
      ()
    })
    ()
  })
  ch.close()
  och.close()

  let c1 = ch.recv().unwrap_or(Color::Red)
  let c2 = ch.recv().unwrap_or(Color::Red)
  let o1 = och.recv().unwrap_or(Some(Color::Red))
  let o2 = och.recv().unwrap_or(None)
  let mv = mx.lock()
  mx.unlock()
  let m = mm.lock()
  let msum = m.get(Color::Red).unwrap_or(0) + m.get(Color::Blue).unwrap_or(0)
  mm.unlock()

  let o1v = match o1 {
    None => 5
    Some(_) => 0
  }
  let o2v = match o2 {
    Some(c) => color_val(c)
    None => 0
  }
  // 1 + 3 + 5 + 2 + 2 + 40 = 53
  let total = color_val(c1) + color_val(c2) + o1v + o2v + color_val(mv) + msum
  io_println(world, "p89_mt ok total=" + total.to_string())
  0
}
EOF

EXP_MT="p89_mt ok total=53"
OUT_MT=$("$PIONC" run --release "$TMP_DIR/p89_mt.pion")
echo "p89_unit_enum mt release -> $OUT_MT"
if [ "$OUT_MT" != "$EXP_MT" ]; then
  echo "FAIL: p89_mt mismatch (expected '$EXP_MT')" >&2
  exit 1
fi
PION_CACHE_DIR="$CAS_DIR/asan_mt" "$PIONC" build --release --emit-obj "$TMP_DIR/p89_mt.o" "$TMP_DIR/p89_mt.pion"
"$CC_BIN" -fsanitize=address "$TMP_DIR/p89_mt.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p89_mt_asan"
OUT_MT_ASAN=$(ASAN_OPTIONS="$ASAN_OPTS" "$TMP_DIR/p89_mt_asan")
echo "p89_unit_enum mt ASan -> $OUT_MT_ASAN"
if [ "$OUT_MT_ASAN" != "$EXP_MT" ]; then
  echo "FAIL: p89_mt ASan mismatch (expected '$EXP_MT')" >&2
  exit 1
fi

# =====================================================================
# Part 3: Cross-package (dev + release + ASan):
#   - Same-name opposite-representation enum (`app::Color` unit vs `colorlib::Color` payload)
#     passed into `colorlib::same[T](a : T, b : T)`
#   - Cross-package `pub extern "C" fn` returning & taking `Tone` and `Option[Tone]`
#   - Transitive 3-package chain `colorapp -> colorlib -> basepkg` (colorapp does NOT import basepkg)
#   - Multi-file forward-ref `Map[Tone, Int]` across files in `colorlib`
# =====================================================================
mkdir -p "$TMP_DIR/xpkg/base/src" "$TMP_DIR/xpkg/lib/src" "$TMP_DIR/xpkg/app/src"

cat > "$TMP_DIR/xpkg/base/pion.toml" <<'EOF'
[package]
name = "basepkg"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xpkg/base/src/lib.pion" <<'EOF'
#derive(Eq)
pub enum BaseKind {
  Alpha
  Beta
  Gamma
}

pub fn base_code(k : BaseKind) -> Int {
  match k {
    BaseKind::Alpha => 11
    BaseKind::Beta => 22
    BaseKind::Gamma => 33
  }
}
EOF

cat > "$TMP_DIR/xpkg/lib/pion.toml" <<'EOF'
[package]
name = "colorlib"
version = "0.1.0"

[dependencies]
basepkg = { path = "../base" }
EOF
# File 1 (alphabetically before lib.pion): forward-references Tone in Map[Tone, Int]!
cat > "$TMP_DIR/xpkg/lib/src/a_fwd.pion" <<'EOF'
pub fn fwd_map_lookup(m : Map[Tone, Int], k : Tone) -> Int {
  m.get(k).unwrap_or(0)
}
EOF
cat > "$TMP_DIR/xpkg/lib/src/lib.pion" <<'EOF'
import "basepkg"

#derive(Eq)
pub enum Tone {
  Low
  Mid
  High
}

// Intentionally shares the name `Color` with `colorapp::Color`, but carries a payload (BOXED)!
#derive(Eq)
pub enum Color {
  Rgb(Int, Int, Int)
  Empty
}

#derive(Eq)
pub struct Spec {
  tone : Tone
  tag : Int
}

pub struct OptSpec {
  tone : Tone
  alt : Option[Tone]
}

pub fn same[T](a : T, b : T) -> Bool {
  a == b
}

pub fn make_tone(n : Int) -> Tone {
  if n == 0 {
    Tone::Low
  } else if n == 1 {
    Tone::Mid
  } else {
    Tone::High
  }
}

pub fn make_opt(flag : Bool) -> Option[Tone] {
  if flag {
    Some(Tone::High)
  } else {
    None
  }
}

pub fn tone_score(t : Tone) -> Int {
  match t {
    Tone::Low => 1
    Tone::Mid => 2
    Tone::High => 3
  }
}

pub extern "C" fn c_mk_tone(n : Int) -> Tone = "p89_c_mk_tone" {
  make_tone(n)
}

pub extern "C" fn c_mk_opt_tone(flag : Int) -> Option[Tone] = "p89_c_mk_opt_tone" {
  if flag != 0 {
    Some(Tone::Mid)
  } else {
    None
  }
}

pub extern "C" fn c_score_opt_tone(ot : Option[Tone]) -> Int = "p89_c_score_opt_tone" {
  match ot {
    Some(t) => tone_score(t)
    None => 100
  }
}

// Re-export transitive basepkg::BaseKind values without colorapp importing basepkg
pub fn get_base_kind() -> basepkg::BaseKind {
  basepkg::BaseKind::Gamma
}

pub fn get_base_opt(flag : Bool) -> Option[basepkg::BaseKind] {
  if flag {
    Some(basepkg::BaseKind::Beta)
  } else {
    None
  }
}

pub fn score_base(k : basepkg::BaseKind) -> Int {
  basepkg::base_code(k)
}
EOF

cat > "$TMP_DIR/xpkg/app/pion.toml" <<'EOF'
[package]
name = "colorapp"
version = "0.1.0"

[dependencies]
colorlib = { path = "../lib" }
EOF
cat > "$TMP_DIR/xpkg/app/src/main.pion" <<'EOF'
import "colorlib"

// Unboxed unit enum with the EXACT SAME NAME as colorlib's boxed `Color`!
#derive(Eq)
enum Color {
  Red
  Green
  Blue
}

// Nested local unboxed `Color` inside `#derive(Eq)` struct passed to `colorlib::same[T]`!
#derive(Eq)
struct Item {
  color : Color
  tag : Int
}

fn app_id[T](x : T) -> T {
  x
}

pub fn main(world : World) -> Int {
  let t0 = colorlib::make_tone(0)
  let t1 = colorlib::make_tone(1)
  let t2 = colorlib::Tone::High
  let o1 = colorlib::make_opt(true)
  let o2 = colorlib::make_opt(false)
  let s1 = colorlib::Spec::{ tone: t1, tag: 7 }
  let s2 = colorlib::Spec::{ tone: colorlib::Tone::Mid, tag: 7 }
  let os = colorlib::OptSpec::{ tone: t1, alt: o1 }
  let mut acc = colorlib::tone_score(t0) + colorlib::tone_score(t1) + colorlib::tone_score(t2)
  if s1 == s2 && os.tone == colorlib::Tone::Mid {
    acc += 10
  }
  acc += match o1 {
    Some(colorlib::Tone::High) => 20
    _ => 0
  }
  acc += match o2 {
    None => 5
    Some(_) => 0
  }
  let m : Map[colorlib::Tone, Int] = Map::new()
  m.set(colorlib::Tone::Low, 7)
  m.set(colorlib::Tone::High, 13)
  acc += colorlib::fwd_map_lookup(m, t0) + m.get(t2).unwrap_or(0)

  // 1) Cross-pkg generic `colorlib::same[T]` with unboxed `app::Color`, boxed `colorlib::Color`,
  //    and `#derive(Eq)` struct `Item` containing nested local unboxed `Color`!
  if colorlib::same(Color::Red, Color::Red) && !colorlib::same(Color::Red, Color::Blue) {
    acc += 100
  }
  if colorlib::same(colorlib::Color::Rgb(1, 2, 3), colorlib::Color::Rgb(1, 2, 3)) &&
    !colorlib::same(colorlib::Color::Rgb(1, 2, 3), colorlib::Color::Empty) {
    acc += 200
  }
  if colorlib::same(Item::{ color: Color::Red, tag: 1 }, Item::{ color: Color::Red, tag: 1 }) &&
    !colorlib::same(Item::{ color: Color::Red, tag: 1 }, Item::{ color: Color::Blue, tag: 1 }) {
    acc += 300
  }

  // 2) Cross-pkg `pub extern "C" fn` returning & accepting Tone / Option[Tone] (also discard return!)
  let _ = colorlib::c_mk_tone(2)
  let _ = colorlib::c_mk_opt_tone(1)
  let ct = colorlib::c_mk_tone(1)
  let cot1 = colorlib::c_mk_opt_tone(1)
  let cot0 = colorlib::c_mk_opt_tone(0)
  acc += colorlib::tone_score(ct) + colorlib::c_score_opt_tone(cot1) + colorlib::c_score_opt_tone(cot0)

  // 3) Transitive A -> B -> C (colorapp does NOT import basepkg!)
  let bk = colorlib::get_base_kind()
  let bo = colorlib::get_base_opt(true)
  let b_arr = [bk]
  let bk2 = app_id(b_arr[0])
  acc += colorlib::score_base(bk2)
  acc += match bo {
    Some(k) => colorlib::score_base(k)
    None => 0
  }

  // 61 + 100 + 200 + 300 + (2 + 2 + 100) + (33 + 22) = 820
  io_println(world, "p89_xpkg ok acc=" + acc.to_string())
  0
}
EOF

EXP_XPKG="p89_xpkg ok acc=820"
OUT_XPKG_DEV=$("$PIONC" run "$TMP_DIR/xpkg/app")
echo "p89_unit_enum xpkg dev -> $OUT_XPKG_DEV"
if [ "$OUT_XPKG_DEV" != "$EXP_XPKG" ]; then
  echo "FAIL: p89_xpkg dev mismatch (expected '$EXP_XPKG')" >&2
  exit 1
fi
OUT_XPKG_REL=$("$PIONC" run --release "$TMP_DIR/xpkg/app")
echo "p89_unit_enum xpkg release -> $OUT_XPKG_REL"
if [ "$OUT_XPKG_REL" != "$EXP_XPKG" ]; then
  echo "FAIL: p89_xpkg release mismatch (expected '$EXP_XPKG')" >&2
  exit 1
fi

# Cross-pkg ASan/LSan (links all 3 packages + ASan runtime)
PION_CACHE_DIR="$CAS_DIR/asan_xpkg" "$PIONC" build --release --emit-staticlib "$TMP_DIR/libp89_xpkg.a" "$TMP_DIR/xpkg/app"
"$CC_BIN" -fsanitize=address -Wl,--whole-archive "$TMP_DIR/libp89_xpkg.a" -Wl,--no-whole-archive "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p89_xpkg_asan" 2>/dev/null \
  || "$CC_BIN" -fsanitize=address -Wl,-force_load,"$TMP_DIR/libp89_xpkg.a" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p89_xpkg_asan"
OUT_XPKG_ASAN=$(ASAN_OPTIONS="$ASAN_OPTS" "$TMP_DIR/p89_xpkg_asan")
echo "p89_unit_enum xpkg ASan -> $OUT_XPKG_ASAN"
if [ "$OUT_XPKG_ASAN" != "$EXP_XPKG" ]; then
  echo "FAIL: p89_xpkg ASan mismatch (expected '$EXP_XPKG')" >&2
  exit 1
fi

# C host round-trip against `pub extern "C" fn` (`p89_c_mk_tone`, `p89_c_mk_opt_tone`, `p89_c_score_opt_tone`)
cat > "$TMP_DIR/c_host.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
extern int64_t p89_c_mk_tone(int32_t n);
extern int64_t p89_c_mk_opt_tone(int32_t flag);
extern int32_t p89_c_score_opt_tone(int64_t ot);

int main(void) {
  int64_t t0 = p89_c_mk_tone(0);
  int64_t t1 = p89_c_mk_tone(1);
  int64_t t2 = p89_c_mk_tone(2);
  int64_t o_none = p89_c_mk_opt_tone(0);
  int64_t o_some = p89_c_mk_opt_tone(1);
  int32_t s_none = p89_c_score_opt_tone(0);
  int32_t s_some = p89_c_score_opt_tone(o_some);
  printf("c_host ok t=%lld,%lld,%lld opt=%lld,%lld score=%d,%d\n",
         (long long)t0, (long long)t1, (long long)t2,
         (long long)o_none, (long long)o_some,
         s_none, s_some);
  return (t0 == 1 && t1 == 2 && t2 == 3 && o_none == 0 && o_some == 2 && s_none == 100 && s_some == 2) ? 0 : 1;
}
EOF
PION_CACHE_DIR="$CAS_DIR/chost" "$PIONC" build --release --emit-staticlib "$TMP_DIR/libp89_lib.a" "$TMP_DIR/xpkg/lib"
"$CC_BIN" -O2 "$TMP_DIR/c_host.c" "$TMP_DIR/libp89_lib.a" "$ROOT_DIR/out/libpionrt.a" -lm -lpthread -o "$TMP_DIR/p89_c_host"
OUT_CHOST=$("$TMP_DIR/p89_c_host")
echo "p89_unit_enum C host -> $OUT_CHOST"
if [ "$OUT_CHOST" != "c_host ok t=1,2,3 opt=0,2 score=100,2" ]; then
  echo "FAIL: p89 C host mismatch: $OUT_CHOST" >&2
  exit 1
fi

# Regression: qualified local generic struct inside monomorphized closure calling erased generic fn/method
# (matches invar/packages/view/src/list_window.pion: Sight[K] + Places[K] + sg.first == k with K=Int)
mkdir -p "$TMP_DIR/qmono/view/src" "$TMP_DIR/qmono/app/src"
cat > "$TMP_DIR/qmono/view/pion.toml" <<'EOF'
[package]
name = "view"
version = "0.1.0"
EOF
cat > "$TMP_DIR/qmono/view/src/lib.pion" <<'EOF'
pub struct Places[K] {
  items : Array[K]
}

pub fn Places::length[K](self : Places[K]) -> Int {
  self.items.length()
}

pub fn Places::key[K](self : Places[K], idx : Int) -> K {
  self.items[idx]
}

pub struct Sight[K] {
  first : K
  last : K
  whole : Option[K]
}

pub struct RefBox[T] {
  mut v : T
}

pub fn sight_counted[K](all : Places[K]) -> Option[Sight[K]] {
  if all.length() == 0 {
    None
  } else {
    let f = all.key(0)
    let l = all.key(all.length() - 1)
    Some(Sight::{ first: f, last: l, whole: Some(f) })
  }
}

pub fn opt_eq[K](a : Option[K], b : Option[K]) -> Bool {
  match a {
    None =>
      match b {
        None => true
        Some(_) => false
      }
    Some(x) =>
      match b {
        None => false
        Some(y) => x == y
      }
  }
}

pub struct ListPlace[K] {
  all : Places[K]
  fading : RefBox[Option[(K, Double)]]
}

pub fn make_sight_fn[K](lp : ListPlace[K]) -> () -> Option[Sight[K]] {
  let all = lp.all
  let fading = lp.fading
  fn() -> Option[Sight[K]] {
    match sight_counted(all) {
      Some(sg) =>
        match fading.v {
          Some(fd) if all.length() >= 2 => {
            let k = fd.0
            let over = all.key(all.length() - 2)
            Some(Sight::{
              ..sg,
              first: if sg.first == k { over } else { sg.first },
              last: if sg.last == k { over } else { sg.last },
              whole: if opt_eq(sg.whole, Some(k)) { Some(over) } else { sg.whole },
            })
          }
          _ => Some(sg)
        }
      other => other
    }
  }
}

pub fn run_window[K](lp : ListPlace[K]) -> Option[Sight[K]] {
  let f = make_sight_fn(lp)
  f()
}
EOF
cat > "$TMP_DIR/qmono/app/pion.toml" <<'EOF'
[package]
name = "qapp"
version = "0.1.0"

[dependencies]
view = { path = "../view" }
EOF
cat > "$TMP_DIR/qmono/app/src/main.pion" <<'EOF'
import "view"

pub fn main(world : World) -> Int {
  let lp = view::ListPlace::{
    all: view::Places::{ items: [10, 20, 30] },
    fading: view::RefBox::{ v: Some((10, 1.5)) },
  }
  let res = view::run_window(lp)
  let out1 = match res {
    Some(sg) => {
      let w = match sg.whole {
        Some(x) => x.to_string()
        None => "none"
      }
      "first=" + sg.first.to_string() + " last=" + sg.last.to_string() + " whole=" + w
    }
    None => "none"
  }
  let lp_d = view::ListPlace::{
    all: view::Places::{ items: [0.0, 2.5, 3.5] },
    fading: view::RefBox::{ v: Some((-0.0, 1.5)) },
  }
  let res_d = view::run_window(lp_d)
  let out2 = match res_d {
    Some(sg) => {
      let w = match sg.whole {
        Some(x) => x.to_string()
        None => "none"
      }
      "dfirst=" + sg.first.to_string() + " dlast=" + sg.last.to_string() + " dwhole=" + w
    }
    None => "none"
  }
  io_println(world, "qmono ok " + out1 + " " + out2)
  0
}
EOF
EXP_QMONO="qmono ok first=20 last=30 whole=20 dfirst=2.5 dlast=3.5 dwhole=2.5"
OUT_QMONO_DEV=$("$PIONC" run "$TMP_DIR/qmono/app")
echo "p89_unit_enum qmono dev -> $OUT_QMONO_DEV"
if [ "$OUT_QMONO_DEV" != "$EXP_QMONO" ]; then
  echo "FAIL: p89 qmono dev mismatch: $OUT_QMONO_DEV" >&2
  exit 1
fi
OUT_QMONO_REL=$("$PIONC" run --release "$TMP_DIR/qmono/app")
echo "p89_unit_enum qmono release -> $OUT_QMONO_REL"
if [ "$OUT_QMONO_REL" != "$EXP_QMONO" ]; then
  echo "FAIL: p89 qmono release mismatch: $OUT_QMONO_REL" >&2
  exit 1
fi

echo "p89_unit_enum: ALL PASSED"
