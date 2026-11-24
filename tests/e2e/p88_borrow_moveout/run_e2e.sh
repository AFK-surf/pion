#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

cat > "$TMP_DIR/p88_main.pion" <<'EOF'
struct Leaf {
  mut items : Array[Int]
  mut text : String
  mut view : StrView
  score : Int
}

struct Mid {
  mut leaf : Leaf
}

struct Top {
  mut mid : Mid
  mut children : Array[Int]
  mut pair : (Leaf, Int)
}

struct Mutator {
  target : Top
  idx : Int
  replacement : Array[Int]
}

fn Mutator::length(self : Mutator) -> Int {
  self.target.children = self.replacement
  self.idx
}

struct Pair {
  a : Int
  tag : String
}

// 1) mut field .length() must read live value after mutation (no stale cache)
fn test_mut_field_len_live() -> Int {
  let parent = Top::{
    mid: Mid::{
      leaf: Leaf::{
        items: [1, 2],
        text: "hi",
        view: "hello".view(1, 4),
        score: 7,
      },
    },
    children: [10, 20],
    pair: (
      Leaf::{
        items: [9],
        text: "z",
        view: "zz".view(0, 1),
        score: 3,
      },
      42,
    ),
  }
  let mut total = 0
  let mut i = 0
  while i < 4 {
    total += parent.children.length()
    if i == 0 {
      parent.children = [1, 2, 3, 4, 5]
    } else if i == 1 {
      parent.children = [8]
    } else if i == 2 {
      parent.children = [1, 2, 3]
    }
    i += 1
  }
  // 2 + 5 + 1 + 3 = 11
  total
}

// 2) chained field .length(), arr[i].field.length(), chained EField reads
fn test_chained_borrow() -> Int {
  let l1 = Leaf::{
    items: [10, 20, 30],
    text: "abcd",
    view: "abcdef".view(1, 5),
    score: 11,
  }
  let l2 = Leaf::{
    items: [40, 50],
    text: "xy",
    view: "wxyz".view(0, 3),
    score: 22,
  }
  let top = Top::{
    mid: Mid::{ leaf: l1 },
    children: [1, 2, 3, 4],
    pair: (l2, 99),
  }
  let arr : Array[Leaf] = [l1, l2]
  let mut sum = 0
  sum += top.mid.leaf.items.length()   // 3
  sum += top.mid.leaf.text.length()    // 4
  sum += top.mid.leaf.view.length()    // 4
  sum += top.mid.leaf.score            // 11
  sum += top.mid.leaf.text.length()    // 4
  let tag = top.mid.leaf.text
  sum += tag.length()                  // 4
  sum += top.pair.0.items.length()     // 2
  sum += top.pair.0.score              // 22
  sum += arr[0].items.length()         // 3
  sum += arr[1].view.length()          // 3
  // Mutate mid.leaf and re-read chained .length() to ensure no stale cache
  top.mid.leaf = Leaf::{
    items: [1, 2, 3, 4, 5, 6],
    text: "1234567",
    view: "0123456789".view(2, 7),
    score: 33,
  }
  sum += top.mid.leaf.items.length()   // 6
  sum += top.mid.leaf.view.length()    // 5
  sum += top.mid.leaf.score            // 33
  // 3+4+4+11+4+4+2+22+3+3+6+5+33 = 104
  sum
}

// 3) mut field indexing: pure index borrow + mutation invalidation + call negative (no UAF)
fn mutate_and_index(p : Top) -> Int {
  p.children = [900, 901, 902]
  1
}

fn test_mut_arr_index() -> Int {
  let p = Top::{
    mid: Mid::{
      leaf: Leaf::{ items: [1], text: "a", view: "ab".view(0, 1), score: 1 },
    },
    children: [10, 20, 30],
    pair: (
      Leaf::{ items: [2], text: "b", view: "bc".view(0, 1), score: 2 },
      0,
    ),
  }
  let mut acc = 0
  let mut i = 0
  while i < 3 {
    acc += p.children[i]
    i += 1
  }
  p.children = [100, 200]
  acc += p.children[0] + p.children[1]
  let old_v = p.children[mutate_and_index(p)]
  acc += old_v + p.children[2]
  // (10+20+30) + (100+200) + 200 + 902 = 1462
  acc
}

// 4) block-tail mut local move-out + negative cases (outer mut local in branch & loop)
fn make_vec(n : Int) -> Array[Int] {
  let mut out : Array[Int] = []
  let mut i = 0
  while i < n {
    out.push(i + 1)
    i += 1
  }
  out
}

fn test_block_tail_moveout() -> Int {
  let v = make_vec(5)
  let mut sum = v.length() // 5
  let v2 = {
    let mut tmp : Array[Int] = []
    tmp.push(10)
    tmp.push(20)
    tmp
  }
  sum += v2[0] + v2[1] // +30 = 35

  let mut x : Array[Int] = [1, 2, 3]
  let y : Array[Int] = [4, 5]
  let p1 = if true { x } else { y }
  let p2 = if false { x } else { y }
  sum += p1.length() + p2.length() + x.length() + x[2] // +11 = 46

  let mut outer_s : String = "hello" + "_world"
  let mut k = 0
  while k < 3 {
    let picked = {
      let _ = k + 1
      outer_s
    }
    sum += picked.length() // 11 * 3 = 33
    k += 1
  }
  sum += outer_s.length() // +11 = 90
  sum
}

// 5) inlined conditional early return of mut local (both early-ret and normal paths)
fn inline_early_ret(cond : Bool, base : Int) -> Array[Int] {
  let mut a : Array[Int] = []
  a.push(base)
  a.push(base + 1)
  if cond {
    return a
  }
  let mut b : Array[Int] = []
  b.push(base + 10)
  b.push(base + 20)
  b.push(a.length())
  b
}

fn test_inline_early_ret() -> Int {
  let mut acc = 0
  let mut i = 0
  while i < 6 {
    let cond = i % 2 == 0
    let r = inline_early_ret(cond, i)
    if cond {
      acc += r[0] + r[1]
    } else {
      acc += r[0] + r[1] + r[2]
    }
    i += 1
  }
  // 1+34+5+38+9+42 = 129
  acc
}

// 6) R2 Regression #1 (Astra #1): match / if..is / block shadowing outer String var
//    x.length() inside index must NOT be misclassified as String::length() -> no borrow -> no UAF
fn test_shadow_mut_index() -> Int {
  let p = Top::{
    mid: Mid::{
      leaf: Leaf::{ items: [1], text: "a", view: "ab".view(0, 1), score: 1 },
    },
    children: [11, 22, 33],
    pair: (
      Leaf::{ items: [2], text: "b", view: "bc".view(0, 1), score: 2 },
      0,
    ),
  }
  let x : String = "outer_string_shadowed"
  let mut acc = x.length() // 21

  let opt1 : Option[Mutator] = Some(
    Mutator::{ target: p, idx: 1, replacement: [44, 55, 66] },
  )
  // Must read old p.children[1] == 22 before replacement takes effect on p.children
  let v1 = p.children[match opt1 { Some(x) => x.length(); None => 0 }]
  acc += v1 // +22 = 43

  let opt2 : Option[Mutator] = Some(
    Mutator::{ target: p, idx: 2, replacement: [77, 88, 99] },
  )
  // Must read old p.children[2] == 66
  let v2 = p.children[if opt2 is Some(x) { x.length() } else { 0 }]
  acc += v2 // +66 = 109

  let m3 = Mutator::{ target: p, idx: 0, replacement: [101, 102] }
  // Must read old p.children[0] == 77
  let v3 = p.children[{ let x = m3; x.length() }]
  acc += v3 // +77 = 186

  // R3 Regression #1: `if opt is Some(x) && x.length() > 0` shadowing outer String `x`
  let opt4 : Option[Mutator] = Some(
    Mutator::{ target: p, idx: 1, replacement: [201, 202] },
  )
  // Must read old p.children[1] == 102 before replacement takes effect
  let v4 = p.children[if opt4 is Some(x) && x.length() > 0 { 1 } else { 0 }]
  acc += v4 + p.children[0] // +102 + 201 = 489
  acc
}

// 7) R2/R3/R4 Regression #2 (Astra #2 & R4 #4): stack view pinning owner across inline & non-inline SReturn
//    First operand `drop_owner([s], 0)` boxes `s` into a temporary owned Array[String] and drops
//    that array (and its element ref) before returning; second operand `v.code_unit_at(0)` reads
//    `s`'s underlying bytes -> ASan UAF if `s` were wrongly moved out instead of rc_inc'd!
pub fn drop_owner(box : Array[String], depth : Int) -> Int {
  if depth > 0 {
    return drop_owner(box, depth - 1)
  }
  box[0].length()
}

fn pinned_view_inline(cond : Bool, prefix : String) -> Int {
  let mut s = prefix + "_payload_012345"
  let v = s.view(0, 6)
  if cond {
    return drop_owner([s], 0) + v.code_unit_at(0)
  }
  v.length() + s.length()
}

pub fn pinned_view_non_inline(cond : Bool, prefix : String, depth : Int) -> Int {
  if depth > 0 {
    return pinned_view_non_inline(cond, prefix, depth - 1)
  }
  let mut s = prefix + "_payload_012345"
  let v = s.view(0, 6)
  if cond {
    return drop_owner([s], 0) + v.code_unit_at(0)
  }
  v.length() + s.length()
}

fn test_pinned_stack_view_return() -> Int {
  // inline early-ret: "alpha_payload_012345"(20) + 'a'(97) = 117
  let r_inl_early = pinned_view_inline(true, "alpha")
  // inline normal: 6 + "beta_payload_012345"(19) = 25
  let r_inl_norm = pinned_view_inline(false, "beta")
  // non-inline early-ret: "gamma_payload_012345"(20) + 'g'(103) = 123
  let r_non_early = pinned_view_non_inline(true, "gamma", 1)
  // non-inline normal: 6 + "delta_payload_012345"(20) = 26
  let r_non_norm = pinned_view_non_inline(false, "delta", 1)
  // 117 + 25 + 123 + 26 = 291
  r_inl_early + r_inl_norm + r_non_early + r_non_norm
}

// 8) R2/R3/R4 Regression #3 & #4 (Astra #3 + R3 #4 + R4 #2/#3):
//    (a) vmap.get(k).unwrap_or(mut_fallback) on hit & miss (0 leaks)
//    (b) `(move m).get(k).unwrap_or(side_effect_fallback())` hitting vmap_try_get fast path
//        with last-ref owned map (hit value retained before map drop + eager fallback side effect)
//    (c) `m.get(k).unwrap_or(none_opt?)` hit + `?` early exit (0 leaks under ASan/LSan)
struct SideCounter {
  mut count : Int
}

fn make_temp_vmap(seed : Int) -> Map[(Int, Int), Array[Int]] {
  let m : Map[(Int, Int), Array[Int]] = Map([])
  m.set((1, 2), [seed, seed + 1, seed + 2])
  m
}

fn side_effect_fallback(sc : SideCounter, tag : Int) -> Array[Int] {
  sc.count += 1
  [tag, tag + 10]
}

fn vmap_lookup_tail(m : Map[(Int, Int), Array[Int]], k : (Int, Int), tag : Int) -> Array[Int] {
  let mut fallback : Array[Int] = []
  fallback.push(tag)
  fallback.push(tag + 1)
  m.get(k).unwrap_or(fallback)
}

fn vmap_lookup_inline_ret(m : Map[(Int, Int), Array[Int]], k : (Int, Int), tag : Int) -> Array[Int] {
  let mut fallback : Array[Int] = []
  fallback.push(tag)
  if tag >= 0 {
    return m.get(k).unwrap_or(fallback)
  }
  fallback
}

fn vmap_owned_unwrap_or(seed : Int, hit : Bool, sc : SideCounter) -> Array[Int] {
  let m = make_temp_vmap(seed)
  let k = if hit { (1, 2) } else { (9, 9) }
  (move m).get(k).unwrap_or(side_effect_fallback(sc, 70))
}

fn vmap_unwrap_or_try_early_exit(m : Map[(Int, Int), Array[Int]]) -> Option[Int] {
  let none_opt : Option[Array[Int]] = None
  let v = m.get((1, 2)).unwrap_or(none_opt?)
  Some(v.length())
}

fn test_vmap_unwrap_or_moveout() -> Int {
  let m : Map[(Int, Int), Array[Int]] = Map([])
  m.set((1, 2), [10, 20, 30])
  let mut acc = 0
  let mut i = 0
  while i < 4 {
    let hit1 = vmap_lookup_tail(m, (1, 2), 100 + i)
    let miss1 = vmap_lookup_tail(m, (9, 9), 5 + i)
    let hit2 = vmap_lookup_inline_ret(m, (1, 2), 200 + i)
    let miss2 = vmap_lookup_inline_ret(m, (8, 8), 7 + i)
    acc += hit1.length() + miss1.length() + hit2.length() + miss2.length()
    i += 1
  }
  // Owned `(move m).get(k).unwrap_or(side_effect_fallback(...))`: hit & miss fast path
  let sc = SideCounter::{ count: 0 }
  let thit = vmap_owned_unwrap_or(50, true, sc)
  let tmiss = vmap_owned_unwrap_or(60, false, sc)
  // Hit + `?` early exit in default arg: must return None AND drop retained hit object (0 leaks!)
  let early_none = match vmap_unwrap_or_try_early_exit(m) {
    None => 1
    Some(_) => 0
  }
  // Unspellable internal slot name check: user local `__vmu_hit_own` must NOT be shadowed
  let __vmu_hit_own : Array[Int] = [42]
  let no_shadow = m.get((9, 9)).unwrap_or(__vmu_hit_own)
  // acc=36, thit[0]+thit[2]=102, tmiss[0]+tmiss[1]=150, sc.count=2, early_none=1, no_shadow[0]=42
  // total = 36 + 102 + 150 + 2 + 1 + 42 = 333
  acc + thit[0] + thit[2] + tmiss[0] + tmiss[1] + sc.count + early_none + no_shadow[0]
}

// 9) R2 Regression #4 (Astra #4): EStructLit spread mentions & straight-line move-out
fn spread_block_tail(base : Int) -> Pair {
  let mut x = Pair::{ a: base, tag: "tag_" + base.to_string() }
  Pair::{ ..x, a: x.a + 1 }
}

fn spread_inline_ret(cond : Bool, base : Int) -> Pair {
  let mut x = Pair::{ a: base, tag: "inl_" + base.to_string() }
  if cond {
    return Pair::{ ..x, a: x.a + 2 }
  }
  Pair::{ ..x, a: x.a + 3 }
}

fn test_struct_spread_moveout() -> Int {
  let p1 = spread_block_tail(10)
  let p2 = spread_inline_ret(true, 20)
  let p3 = spread_inline_ret(false, 30)
  // p1: a=11, tag="tag_10" (6)
  // p2: a=22, tag="inl_20" (6)
  // p3: a=33, tag="inl_30" (6)
  // total = 11+6+22+6+33+6 = 84
  p1.a + p1.tag.length() + p2.a + p2.tag.length() + p3.a + p3.tag.length()
}

pub fn main(world : World) -> Int {
  let r1 = test_mut_field_len_live()
  let r2 = test_chained_borrow()
  let r3 = test_mut_arr_index()
  let r4 = test_block_tail_moveout()
  let r5 = test_inline_early_ret()
  let r6 = test_shadow_mut_index()
  let r7 = test_pinned_stack_view_return()
  let r8 = test_vmap_unwrap_or_moveout()
  let r9 = test_struct_spread_moveout()

  io_println(
    world,
    "p88_borrow_moveout ok r1=" +
      r1.to_string() +
      " r2=" +
      r2.to_string() +
      " r3=" +
      r3.to_string() +
      " r4=" +
      r4.to_string() +
      " r5=" +
      r5.to_string() +
      " r6=" +
      r6.to_string() +
      " r7=" +
      r7.to_string() +
      " r8=" +
      r8.to_string() +
      " r9=" +
      r9.to_string(),
  )
  0
}
EOF

EXPECTED="p88_borrow_moveout ok r1=11 r2=104 r3=1462 r4=90 r5=129 r6=489 r7=291 r8=333 r9=84"

# 1) Native dev
DEV_OUT=$("$PIONC" run "$TMP_DIR/p88_main.pion")
echo "p88_borrow_moveout dev -> $DEV_OUT"
if [ "$DEV_OUT" != "$EXPECTED" ]; then
  echo "FAIL: p88_borrow_moveout dev output mismatch (expected '$EXPECTED')" >&2
  exit 1
fi

# 2) Native release
REL_OUT=$("$PIONC" run --release "$TMP_DIR/p88_main.pion")
echo "p88_borrow_moveout release -> $REL_OUT"
if [ "$REL_OUT" != "$EXPECTED" ]; then
  echo "FAIL: p88_borrow_moveout release output mismatch (expected '$EXPECTED')" >&2
  exit 1
fi

# 3) ASan (+ LSan on Linux; detect_leaks=0 on Darwin/macOS)
CC_BIN="${CC:-cc}"
UNAME_S="$(uname -s)"
if [ "$UNAME_S" = "Darwin" ]; then
  ASAN_OPTS="detect_leaks=0:halt_on_error=1"
else
  ASAN_OPTS="detect_leaks=1:halt_on_error=1"
fi

if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"; then
  PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --release --emit-obj "$TMP_DIR/p88_main.o" "$TMP_DIR/p88_main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p88_main.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p88_asan"
  ASAN_OUT=$(ASAN_OPTIONS="$ASAN_OPTS" "$TMP_DIR/p88_asan")
  echo "p88_borrow_moveout ASan ($UNAME_S) -> $ASAN_OUT"
  if [ "$ASAN_OUT" != "$EXPECTED" ]; then
    echo "FAIL: p88_borrow_moveout ASan output mismatch or leak (expected '$EXPECTED')" >&2
    exit 1
  fi
else
  echo "FAIL: cc -fsanitize=address unavailable; ASan verification required" >&2
  exit 1
fi

echo "p88_borrow_moveout: ALL PASSED"
