#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
NEG_DIR="$TMP_DIR/neg"
PKG_DIR="$TMP_DIR/pkg"
mkdir -p "$CAS_DIR" "$NEG_DIR" "$PKG_DIR/src"
export PION_CACHE_DIR="$CAS_DIR"

# 1) Negative typecheck tests: temporary arguments must fail with E_TEMP_DATA_PTR + fix-it
check_reject() {
  label="$1"
  src_file="$NEG_DIR/neg_${label}.pion"
  cat > "$src_file"
  set +e
  OUT=$("$PIONC" check --json "$src_file" 2>&1)
  RC=$?
  set -e
  if [ "$RC" -eq 0 ]; then
    echo "FAIL: neg_${label} unexpectedly passed check: $OUT" >&2
    exit 1
  fi
  printf '%s' "$OUT" | grep -q '"code":"E_TEMP_DATA_PTR"' || {
    echo "FAIL: neg_${label} missing E_TEMP_DATA_PTR: $OUT" >&2
    exit 1
  }
  printf '%s' "$OUT" | grep -q 'local variable' || {
    echo "FAIL: neg_${label} missing local-variable fixit: $OUT" >&2
    exit 1
  }
}

check_reject str_concat <<'EOF'
pub fn f(a : String, b : String) -> Ptr {
  str_data_ptr(a + b)
}
EOF

check_reject str_call_ret <<'EOF'
fn mk() -> String { "hi" + "!" }
pub fn f() -> Ptr {
  str_data_ptr(mk())
}
EOF

check_reject str_make_field <<'EOF'
struct Box { s : String }
fn mk() -> Box { Box::{ s: "abc" } }
pub fn f() -> Ptr {
  str_data_ptr(mk().s)
}
EOF

check_reject str_arr_index <<'EOF'
pub fn f(arr : Array[String]) -> Ptr {
  str_data_ptr(arr[0])
}
EOF

check_reject str_interp <<'EOF'
pub fn f(x : Int) -> Ptr {
  str_data_ptr("n=\{x}")
}
EOF

check_reject bytes_call_ret <<'EOF'
fn mk_b() -> Bytes { Bytes::new(4) }
pub fn f() -> Ptr {
  bytes_data_ptr(mk_b())
}
EOF

check_reject bytes_arr_index <<'EOF'
pub fn f(xs : Array[Bytes]) -> Ptr {
  bytes_data_ptr(xs[0])
}
EOF

check_reject arr_call_ret <<'EOF'
fn mk_a() -> Array[Int] { [1, 2, 3] }
pub fn f() -> Ptr {
  array_data_ptr(mk_a())
}
EOF

check_reject arr_make_field <<'EOF'
struct Holder { a : Array[Int] }
fn mk_h() -> Holder { Holder::{ a: [1, 2] } }
pub fn f() -> Ptr {
  array_data_ptr(mk_h().a)
}
EOF

check_reject fixed_arr_call_ret <<'EOF'
fn mk_fa() -> FixedArray[Int] { FixedArray::make(4, 7) }
pub fn f() -> Ptr {
  fixed_array_data_ptr(mk_fa())
}
EOF

check_reject fixed_arr_index <<'EOF'
pub fn f(xs : Array[FixedArray[Int]]) -> Ptr {
  array_data_ptr(xs[0])
}
EOF

echo "p91_data_ptr_safety negative E_TEMP_DATA_PTR checks (11/11) PASSED"

# 1b) Negative arity checks: 0-arg & 2-arg for all 4 *_data_ptr builtins (check + build)
check_arity() {
  label="$1"
  src_file="$NEG_DIR/arity_${label}.pion"
  cat > "$src_file"
  set +e
  OUT=$("$PIONC" check --json "$src_file" 2>&1)
  RC=$?
  set -e
  if [ "$RC" -eq 0 ]; then
    echo "FAIL: arity_${label} unexpectedly passed check: $OUT" >&2
    exit 1
  fi
  printf '%s' "$OUT" | grep -q '"code":"E_ARITY_MISMATCH"' || {
    echo "FAIL: arity_${label} missing E_ARITY_MISMATCH in check: $OUT" >&2
    exit 1
  }
  set +e
  BOUT=$("$PIONC" build -o "$TMP_DIR/arity_${label}.bin" "$src_file" 2>&1)
  BRC=$?
  set -e
  if [ "$BRC" -eq 0 ]; then
    echo "FAIL: arity_${label} unexpectedly passed build: $BOUT" >&2
    exit 1
  fi
  printf '%s' "$BOUT" | grep -q 'E_ARITY_MISMATCH' || {
    echo "FAIL: arity_${label} missing E_ARITY_MISMATCH in build: $BOUT" >&2
    exit 1
  }
}

check_arity str_0 <<'EOF'
pub fn f() -> Ptr { str_data_ptr() }
EOF
check_arity str_2 <<'EOF'
pub fn f(s : String) -> Ptr { str_data_ptr(s, s) }
EOF
check_arity bytes_0 <<'EOF'
pub fn f() -> Ptr { bytes_data_ptr() }
EOF
check_arity bytes_2 <<'EOF'
pub fn f(b : Bytes) -> Ptr { bytes_data_ptr(b, b) }
EOF
check_arity arr_0 <<'EOF'
pub fn f() -> Ptr { array_data_ptr() }
EOF
check_arity arr_2 <<'EOF'
pub fn f(a : Array[Int]) -> Ptr { array_data_ptr(a, a) }
EOF
check_arity fa_0 <<'EOF'
pub fn f() -> Ptr { fixed_array_data_ptr() }
EOF
check_arity fa_2 <<'EOF'
pub fn f(a : FixedArray[Int]) -> Ptr { fixed_array_data_ptr(a, a) }
EOF

echo "p91_data_ptr_safety negative E_ARITY_MISMATCH checks (8/8 check+build) PASSED"

# 2) Positive runtime + ASan/LSan tests across all 4 carriers (String, Bytes, Array, FixedArray)
cat > "$PKG_DIR/helper.c" <<'EOF'
#include <stdint.h>
#include <string.h>

int32_t p91_c_str_sum(const char *p) {
    int32_t s = 0;
    for (size_t i = 0; p[i] != '\0'; i++) {
        s += (unsigned char)p[i];
    }
    return s;
}

int32_t p91_c_bytes_sum(const uint8_t *p, int32_t n) {
    int32_t s = 0;
    for (int32_t i = 0; i < n; i++) {
        s += (int32_t)p[i];
    }
    return s;
}

int32_t p91_c_i32_arr_sum(const int32_t *p, int32_t n) {
    int32_t s = 0;
    for (int32_t i = 0; i < n; i++) {
        s += p[i];
    }
    return s;
}
EOF

cat > "$PKG_DIR/pion.toml" <<'EOF'
[package]
name = "p91_data_ptr_safety"
version = "0.1.0"

[link]
c_sources = ["helper.c"]
EOF

cat > "$PKG_DIR/src/main.pion" <<'EOF'
extern "C" fn p91_c_str_sum(p : Ptr) -> Int
extern "C" fn p91_c_bytes_sum(p : Ptr, n : Int) -> Int
extern "C" fn p91_c_i32_arr_sum(p : Ptr, n : Int) -> Int

let GLOBAL_STR : String = "pion"

struct Inner {
  s : String
  bs : Bytes
  arr : Array[Int]
  fa : FixedArray[Int]
}

struct Outer {
  inner : Inner
}

fn alloc_noise(n : Int) -> Int {
  let mut acc = 0
  for i in 0..n {
    let tmp = "noise_" + i.to_string() + "_payload_padding"
    acc = acc + tmp.length()
  }
  acc
}

fn make_bytes(a : Int, b : Int, c : Int) -> Bytes {
  let bs = Bytes::new(3)
  bs[0] = a.to_byte()
  bs[1] = b.to_byte()
  bs[2] = c.to_byte()
  bs
}

// (1) Last-use before FFI: `let s = a + b; let p = str_data_ptr(s); noise(); ffi(p)`
fn case1_last_use_before_ffi(a : String, b : String) -> Int {
  let s = a + b
  let p = str_data_ptr(s)
  let _ = alloc_noise(16)
  let r1 = p91_c_str_sum(p)

  let bs = make_bytes(10, 20, 30)
  let bp = bytes_data_ptr(bs)
  let _ = alloc_noise(16)
  let r2 = p91_c_bytes_sum(bp, 3)

  let arr : Array[Int] = [100, 200, 300]
  let ap = array_data_ptr(arr)
  let _ = alloc_noise(16)
  let r3 = p91_c_i32_arr_sum(ap, 3)

  let fa : FixedArray[Int] = FixedArray::make(3, 7)
  let fp1 = array_data_ptr(fa)
  let fp2 = fixed_array_data_ptr(fa)
  let _ = alloc_noise(16)
  let r4 = p91_c_i32_arr_sum(fp1, 3) + p91_c_i32_arr_sum(fp2, 3)

  r1 + r2 + r3 + r4
}

// (2) Inner block: `let p = { str_data_ptr(s) }; ffi(p)`
fn case2_inner_block(a : String, b : String) -> Int {
  let s = a + b
  let p = {
    let _x = 1 + 2
    str_data_ptr(s)
  }
  let _ = alloc_noise(16)
  let r1 = p91_c_str_sum(p)

  let bs = make_bytes(1, 2, 3)
  let bp = { bytes_data_ptr(bs) }
  let _ = alloc_noise(16)
  let r2 = p91_c_bytes_sum(bp, 3)

  let fa : FixedArray[Int] = FixedArray::make(2, 11)
  let fp = { fixed_array_data_ptr(fa) }
  let _ = alloc_noise(16)
  let r3 = p91_c_i32_arr_sum(fp, 2)

  r1 + r2 + r3
}

// (3) Conditional branch takes pointer, used after branch
fn case3_branch(flag : Bool, a : String, b : String) -> Int {
  let s1 = a + "_1"
  let s2 = b + "_2"
  let p = if flag {
    str_data_ptr(s1)
  } else {
    str_data_ptr(s2)
  }
  let _ = alloc_noise(16)
  p91_c_str_sum(p)
}

// (4) Scope shadowing: inner `let s` shadows outer `s`
fn case4_shadowing(a : String, b : String) -> Int {
  let s = a + "_outer"
  let r_inner = {
    let s = b + "_inner"
    let p_in = str_data_ptr(s)
    let _ = alloc_noise(12)
    p91_c_str_sum(p_in)
  }
  // Outer `s` was NOT pinned by inner `str_data_ptr(s)`, and is still live here
  let p_out = str_data_ptr(s)
  let _ = alloc_noise(12)
  let r_outer = p91_c_str_sum(p_out)

  // Same-block shadowing: init of new `s` takes ptr of old `s`, then new `s` takes its own ptr
  let v = a + "X"
  let r_old = p91_c_str_sum(str_data_ptr(v))
  let v = b + "Y"
  let pv = str_data_ptr(v)
  let _ = alloc_noise(12)
  let r_new = p91_c_str_sum(pv)

  r_inner + r_outer + r_old + r_new
}

// (5) Direct FFI argument `ffi(str_data_ptr(s))`
fn case5_direct_ffi(a : String, b : String) -> Int {
  let s = a + b
  p91_c_str_sum(str_data_ptr(s))
}

// (6) Recursive field chain `obj.inner.s` / `.bs` / `.arr` / `.fa`
fn case6_field_chain(a : String, b : String) -> Int {
  let obj = Outer::{
    inner: Inner::{
      s: a + b,
      bs: make_bytes(4, 5, 6),
      arr: [10, 20],
      fa: FixedArray::make(2, 5),
    },
  }
  let ps = str_data_ptr(obj.inner.s)
  let pb = bytes_data_ptr(obj.inner.bs)
  let pa = array_data_ptr(obj.inner.arr)
  let pf = fixed_array_data_ptr(obj.inner.fa)
  let _ = alloc_noise(16)
  p91_c_str_sum(ps) + p91_c_bytes_sum(pb, 3) + p91_c_i32_arr_sum(pa, 2) + p91_c_i32_arr_sum(pf, 2)
}

// (7) String literal & global constant
fn case7_lit_and_const() -> Int {
  let p1 = str_data_ptr("AB")
  let p2 = str_data_ptr(GLOBAL_STR)
  let _ = alloc_noise(8)
  p91_c_str_sum(p1) + p91_c_str_sum(p2)
}

fn drop_owner(xs : Array[String]) -> Int {
  let _ = alloc_noise(12)
  xs.length()
}

fn make_opt_str(a : String, b : String) -> Option[String] {
  Some(a + b)
}

// (8a) SGuard pattern binding + SReturn move-out candidate on LHS before C read on RHS
fn case8_guard_ret(opt : Option[String]) -> Int {
  guard opt is Some(s) else {
    return 0
  }
  let p = str_data_ptr(s)
  return drop_owner([s]) + p91_c_str_sum(p)
}

// (8b) Release adjacent let/match fusion result slot + SReturn move-out
fn case8_let_match_fusion(a : String, b : String) -> Int {
  let r = make_opt_str(a, b)
  let s = match r {
    Some(v) => v
    None => ""
  }
  let p = str_data_ptr(s)
  return drop_owner([s]) + p91_c_str_sum(p)
}

// (8c) Inlined function with owned formal param + inline SReturn move-out
fn inl_owned_param_helper(s : String) -> Int {
  let p = str_data_ptr(s)
  return drop_owner([s]) + p91_c_str_sum(p)
}

fn case8_inline_owned_param(a : String, b : String) -> Int {
  inl_owned_param_helper(a + b)
}

// (8d) Match arm binding + SReturn move-out
fn case8_match_arm_ret(opt : Option[String]) -> Int {
  match opt {
    Some(s) => {
      let p = str_data_ptr(s)
      return drop_owner([s]) + p91_c_str_sum(p)
    }
    None => 0
  }
}

// (9) && RHS shadowing: outer `s` is NOT pinned by `opt is Some(s) && pred(str_data_ptr(s))`
fn case9_and_rhs_shadow(a : String, opt : Option[String]) -> Int {
  let s = a + "_outer_ed"
  let n = s.length()
  let mut r = n
  if opt is Some(s) && p91_c_str_sum(str_data_ptr(s)) > 0 {
    r = r + p91_c_str_sum(str_data_ptr(s))
  }
  r
}

// (9b) && RHS takes str_data_ptr(s) ONLY in condition; `then` body returns with move-out candidate
fn case9b_and_cond_only_ptr(opt : Option[String]) -> Int {
  let mut p = str_data_ptr("")
  if opt is Some(s) && { p = str_data_ptr(s); true } {
    return drop_owner([s]) + p91_c_str_sum(p)
  }
  0
}

// (9c) 3-segment &&: seg1 binds `s`, seg2 takes str_data_ptr(s), seg3 conditionally returns using saved `p`
fn case9c_and3_early_ret(opt : Option[String], trigger : Bool) -> Int {
  let mut p = str_data_ptr("")
  if opt is Some(s) && { p = str_data_ptr(s); true } && {
    if trigger {
      return drop_owner([s]) + p91_c_str_sum(p)
    }
    true
  } {
    return 1
  }
  0
}

// Helper returning boxed Result[String, String] (scalarizable by qbe_try_emit_opt_res_scalarized)
fn make_res_str(ok_flag : Bool, a : String, b : String) -> Result[String, String] {
  if ok_flag {
    Ok(a + b)
  } else {
    Err(b + a)
  }
}

// (10a) Two-arm scalarized Result[String, String] match (both Ok and Err owned payload arms) + SReturn move-out
fn case10_scalar_opt_match(ok_flag : Bool, a : String, b : String) -> Int {
  match make_res_str(ok_flag, a, b) {
    Ok(s) => {
      let p = str_data_ptr(s)
      return drop_owner([s]) + p91_c_str_sum(p)
    }
    Err(e) => {
      let p = str_data_ptr(e)
      return drop_owner([e]) + p91_c_str_sum(p)
    }
  }
}

enum Tag6 {
  A(String)
  B(String)
  C(String)
  D(Int)
  E(Int)
  F(Int)
}

// (10b) 6-variant enum jump-table match (>=6 tags triggers `jtbl`) + SReturn move-out
fn case10_jtbl_enum_match(e : Tag6) -> Int {
  match e {
    Tag6::A(s) => s.length()
    Tag6::B(s) => {
      let p = str_data_ptr(s)
      return drop_owner([s]) + p91_c_str_sum(p)
    }
    Tag6::C(s) => s.length() + 1
    Tag6::D(n) => n
    Tag6::E(n) => n + 1
    Tag6::F(n) => n + 2
  }
}

// (10c) Tail Option[Int] scalarized match into caller slots (`qbe_emit_tail_opt_res_expr_into_slots`)
// Outer `match` over `EBlock([EMatch(make_res_str(...))])` returning boxed `Option[Int]` triggers
// `qbe_try_emit_opt_res_scalarized` -> `qbe_emit_tail_opt_res_expr_into_slots` -> `@scnm_ok`/`@scnm_err`!
fn case10c_tail_opt_slot_match(ok_flag : Bool, a : String, b : String) -> Int {
  match {
    match make_res_str(ok_flag, a, b) {
      Ok(s) => {
        let p = str_data_ptr(s)
        Some(drop_owner([s]) + p91_c_str_sum(p))
      }
      Err(e) => {
        let p = str_data_ptr(e)
        Some(drop_owner([e]) + p91_c_str_sum(p))
      }
    }
  } {
    Some(v) => v
    None => 0
  }
}

// (11) C-style SFor init `let s = a + b` pinned across loop scope
fn case11_c_for_init(a : String, b : String) -> Int {
  for let s = a + b; s.length() > 0; let _ = 0 {
    let p = str_data_ptr(s)
    return drop_owner([s]) + p91_c_str_sum(p)
  }
  0
}

pub fn main(world : World) -> Int {
  let r1 = case1_last_use_before_ffi("he", "llo")
  let r2 = case2_inner_block("ab", "cd")
  let r3 = case3_branch(true, "hi", "no") + case3_branch(false, "hi", "no")
  let r4 = case4_shadowing("A", "B")
  let r5 = case5_direct_ffi("xy", "z")
  let r6 = case6_field_chain("o", "k")
  let r7 = case7_lit_and_const()
  let r8a = case8_guard_ret(Some("gu" + "ard"))
  let r8b = case8_let_match_fusion("fu", "se")
  let r8c = case8_inline_owned_param("in", "l")
  let r8d = case8_match_arm_ret(Some("ar" + "m"))
  let r9 = case9_and_rhs_shadow("Z", Some("hi" + "!"))
  let r9b = case9b_and_cond_only_ptr(Some("co" + "nd")) + case9c_and3_early_ret(Some("an" + "d3"), true)
  let r10a = case10_scalar_opt_match(true, "sc", "al") + case10_scalar_opt_match(false, "sc", "al")
  let r10c = case10c_tail_opt_slot_match(true, "to", "pt") + case10c_tail_opt_slot_match(false, "to", "pt")
  let r10 = r10a + case10_jtbl_enum_match(Tag6::B("jt" + "bl")) + r10c
  let r11 = case11_c_for_init("fo", "r")
  io_println(
    world,
    "p91_data_ptr_safety ok r1=" +
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
      (r8a + r8b + r8c + r8d).to_string() +
      " r9=" +
      r9.to_string() +
      " r9b=" +
      r9b.to_string() +
      " r10=" +
      r10.to_string() +
      " r11=" +
      r11.to_string(),
  )
  0
}
EOF

# Expected checksums:
# r1: "hello"(532) + bytes(60) + arr(600) + fa(21+21=42) = 1234
# r2: "abcd"(394) + bytes(6) + fa(22) = 422
# r3: "hi_1"(353) + "no_2"(366) = 719
# r4: "B_inner"(701) + "A_outer"(719) + "AX"(153) + "BY"(155) = 1728
# r5: "xyz"(363)
# r6: "ok"(218) + bytes(15) + arr(30) + fa(10) = 273
# r7: "AB"(131) + "pion"(438) = 569
# r8a: 1 + "guard"(531) = 532; r8b: 1 + "fuse"(435) = 436; r8c: 1 + "inl"(323) = 324; r8d: 1 + "arm"(320) = 321 -> r8 = 1613
# r9: len("Z_outer_ed")(10) + "hi!"(242) = 252
# r9b: (1 + "cond"(420) = 421) + (1 + "and3"(358) = 359) = 780
# r10: (420 + 420 = 840) + (1 + "jtbl"(428) = 429) + (456 + 456 = 912) = 2181
# r11: 1 + "for"(327) = 328
EXPECTED="p91_data_ptr_safety ok r1=1234 r2=422 r3=719 r4=1728 r5=363 r6=273 r7=569 r8=1613 r9=252 r9b=780 r10=2181 r11=328"

DEV_OUT=$("$PIONC" run "$PKG_DIR")
echo "p91_data_ptr_safety dev -> $DEV_OUT"
if [ "$DEV_OUT" != "$EXPECTED" ]; then
  echo "FAIL: dev output mismatch (expected '$EXPECTED')" >&2
  exit 1
fi

REL_OUT=$("$PIONC" run --release "$PKG_DIR")
echo "p91_data_ptr_safety release -> $REL_OUT"
if [ "$REL_OUT" != "$EXPECTED" ]; then
  echo "FAIL: release output mismatch (expected '$EXPECTED')" >&2
  exit 1
fi

# 3) ASan (+ LSan on Linux; detect_leaks=0 on Darwin)
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
  "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$PKG_DIR/helper.c" -o "$TMP_DIR/helper_asan.o"
  PION_CACHE_DIR="$CAS_DIR/asan_dev" "$PIONC" build --emit-obj "$TMP_DIR/p91_dev.o" "$PKG_DIR/src/main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p91_dev.o" "$TMP_DIR/helper_asan.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p91_asan_dev"
  ASAN_DEV_OUT=$(ASAN_OPTIONS="$ASAN_OPTS" "$TMP_DIR/p91_asan_dev")
  echo "p91_data_ptr_safety ASan dev ($UNAME_S) -> $ASAN_DEV_OUT"
  if [ "$ASAN_DEV_OUT" != "$EXPECTED" ]; then
    echo "FAIL: ASan dev output mismatch (expected '$EXPECTED')" >&2
    exit 1
  fi
  PION_CACHE_DIR="$CAS_DIR/asan_rel" "$PIONC" build --release --emit-ssa "$TMP_DIR/p91_rel.ssa" --emit-obj "$TMP_DIR/p91_rel.o" "$PKG_DIR/src/main.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p91_rel.o" "$TMP_DIR/helper_asan.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p91_asan_rel"
  ASAN_REL_OUT=$(ASAN_OPTIONS="$ASAN_OPTS" "$TMP_DIR/p91_asan_rel")
  echo "p91_data_ptr_safety ASan release ($UNAME_S) -> $ASAN_REL_OUT"
  if [ "$ASAN_REL_OUT" != "$EXPECTED" ]; then
    echo "FAIL: ASan release output mismatch (expected '$EXPECTED')" >&2
    exit 1
  fi
else
  echo "FAIL: cc -fsanitize=address unavailable; ASan verification required" >&2
  exit 1
fi

# 4) SSA audits:
#   - case8_let_match_fusion in --release actually fused (no call $make_opt_str)
#   - case8_inline_owned_param actually inlined (no call $inl_owned_param_helper)
#   - case9_and_rhs_shadow still early-drops outer `s` before `p91_c_str_sum` (not falsely pinned by && RHS `is`!)
python3 - "$TMP_DIR/p91_rel.ssa" <<'PYEOF'
import re, sys
ssa = open(sys.argv[1]).read()
def get_fn(name):
    m = re.search(rf'function [^\n]*\$[A-Za-z0-9_]*{name}\([^)]*\)\s*\{{(.*?)\n\}}', ssa, re.S)
    assert m, f"missing function *{name} in SSA"
    return m.group(1)

f_fus = get_fn("case8_let_match_fusion")
assert "make_opt_str(" not in f_fus, f"expected let/match fusion in case8_let_match_fusion:\n{f_fus}"

f_inl = get_fn("case8_inline_owned_param")
assert "inl_owned_param_helper(" not in f_inl, f"expected inline expansion in case8_inline_owned_param:\n{f_inl}"

# Trace back from each `call $p91_c_str_sum(l %arg)` to the exact `str_data_ptr` (`add %obj, 8`)
# and its owner local slot (`%obj =l loadl %owner_slot`), verifying `storel 0, %owner_slot`
# never fires between `add %obj, 8` and `call $p91_c_str_sum(l %arg)`.
def verify_data_ptr_owner_pinned(body, label):
    hits = list(re.finditer(r'call \$p91_c_str_sum\(l (%t\d+)\)', body))
    assert hits, f"missing p91_c_str_sum in {label}"
    for m_call in hits:
        arg = m_call.group(1)
        pos_c = m_call.start()
        prefix = body[:pos_c]
        # Unwrap optional loadl/storel through local slot `p` (e.g. `let p = str_data_ptr(s)`)
        ptr_reg = arg
        for _ in range(4):
            m_ld = re.search(rf'{re.escape(ptr_reg)} =l loadl (%t\d+)\b', prefix)
            if not m_ld:
                break
            p_slot = m_ld.group(1)
            stores = list(re.finditer(rf'storel (%t\d+), {re.escape(p_slot)}\b', prefix))
            assert stores, f"no storel into ptr slot {p_slot} before p91_c_str_sum in {label}"
            ptr_reg = stores[-1].group(1)
        m_add = re.search(rf'{re.escape(ptr_reg)} =l add (%t\d+), 8\b', prefix)
        assert m_add, f"could not trace {arg}->{ptr_reg} to str_data_ptr `add %obj, 8` in {label}:\n{prefix[-600:]}"
        obj_reg = m_add.group(1)
        m_own = re.search(rf'{re.escape(obj_reg)} =l loadl (%t\d+)\b', prefix[:m_add.start()])
        assert m_own, f"could not trace owner slot for {obj_reg} in {label}:\n{prefix[:m_add.start()][-400:]}"
        owner_slot = m_own.group(1)
        between = body[m_add.end():pos_c]
        assert f"storel 0, {owner_slot}" not in between, (
            f"unexpected owner slot zeroing `storel 0, {owner_slot}` between str_data_ptr and p91_c_str_sum in {label}:\n{between}"
        )

for fname in (
    "case8_guard_ret",
    "case8_let_match_fusion",
    "case8_inline_owned_param",
    "case8_match_arm_ret",
    "case9b_and_cond_only_ptr",
    "case9c_and3_early_ret",
    "case10_scalar_opt_match",
    "case10_jtbl_enum_match",
    "case10c_tail_opt_slot_match",
    "case11_c_for_init",
):
    verify_data_ptr_owner_pinned(get_fn(fname), fname)

# Confirm case10_scalar_opt_match hit 2-arm scalarized Result match (`@scm_ok`, `@scm_err`, no call to make_res_str)
f_sc2 = get_fn("case10_scalar_opt_match")
assert "make_res_str(" not in f_sc2 and "@scm_ok" in f_sc2 and "@scm_err" in f_sc2, f"expected scalarized 2-arm Result match in case10_scalar_opt_match:\n{f_sc2}"
# Confirm case10_jtbl_enum_match actually emitted an enum jump table (`jtbl `)
f_jtbl = get_fn("case10_jtbl_enum_match")
assert "jtbl " in f_jtbl, f"expected enum jump table `jtbl ` in case10_jtbl_enum_match:\n{f_jtbl}"
# Confirm case10c_tail_opt_slot_match hit inner tail-slot Result match (`@scnm_ok` & `@scnm_err`, no call to make_res_str)
# and audit BOTH inner arms individually!
f_topt = get_fn("case10c_tail_opt_slot_match")
assert "make_res_str(" not in f_topt, f"expected scalarized tail-slot Result match in case10c_tail_opt_slot_match:\n{f_topt}"
m_ok = re.search(r'^@scnm_ok_\d+\n(.*?)^@scnm_err_\d+\n', f_topt, re.S | re.M)
m_err = re.search(r'^@scnm_err_\d+\n(.*?)^@scnm_end_\d+\n', f_topt, re.S | re.M)
assert m_ok and m_err, f"expected inner `@scnm_ok` and `@scnm_err` blocks in case10c_tail_opt_slot_match:\n{f_topt}"
verify_data_ptr_owner_pinned(m_ok.group(1), "case10c_tail_opt_slot_match:@scnm_ok")
verify_data_ptr_owner_pinned(m_err.group(1), "case10c_tail_opt_slot_match:@scnm_err")

# Exact slot-level audit for case9_and_rhs_shadow:
# - outer_slot (stored right after pion_str_concat) MUST have `storel 0, <outer_slot>` (early-dropped!)
# - inner_slot (loaded right before `add %..., 8` for str_data_ptr(s)) MUST differ from outer_slot
#   and MUST NOT have `storel 0, <inner_slot>` before p91_c_str_sum!
f_and = get_fn("case9_and_rhs_shadow")
m_out = re.search(r'(%t\d+) =l call \$pion_str_concat\([^\n]+\)\n\s+storel \1, (%t\d+)', f_and)
assert m_out, f"could not locate outer `s` slot in case9_and_rhs_shadow:\n{f_and}"
outer_slot = m_out.group(2)
m_in = re.search(r'(%t\d+) =l loadl (%t\d+)\n\s+%t\d+ =l add \1, 8\n\s+%t\d+ =w call \$p91_c_str_sum\(', f_and)
assert m_in, f"could not locate inner `s` slot in case9_and_rhs_shadow:\n{f_and}"
inner_slot = m_in.group(2)
assert outer_slot != inner_slot, f"expected distinct outer/inner slots, got {outer_slot}"
pos_cat = m_out.end()
pos_c = f_and.find("call $p91_c_str_sum(")
assert f"storel 0, {outer_slot}" in f_and[pos_cat:], f"expected early-drop `storel 0, {outer_slot}` for outer `s`:\n{f_and[pos_cat:]}"
assert f"storel 0, {inner_slot}" not in f_and[pos_cat:pos_c], f"unexpected early-drop `storel 0, {inner_slot}` for inner `s` before p91_c_str_sum"
print(f"p91_data_ptr_safety SSA audits PASSED (outer={outer_slot} early-dropped, inner={inner_slot} pinned, 10x+scnm owner-pinned)")
PYEOF

# 5) Production vendor/qbe/load.c:icmp relational total-order C boundary unit test
# Directly #include "load.c" to test the real production `Insert` struct and `icmp` function!
mkdir -p "$TMP_DIR/qbe_inc" "$TMP_DIR/qbe_objs/amd64" "$TMP_DIR/qbe_objs/arm64" "$TMP_DIR/qbe_objs/rv64"
printf '#define Deftgt T_amd64_sysv\n' > "$TMP_DIR/qbe_inc/config.h"
cat > "$TMP_DIR/test_icmp.c" <<'EOF'
#include <assert.h>
#include <stdio.h>
#include "load.c"

Target T;
char debug['Z'+1];

int main(void) {
    uint bids[] = {0u, 1u, 0x7fffffffu, 0x80000000u, 0xffffffffu};
    uint offs[] = {0u, 1u, 0x7fffffffu, 0x80000000u, 0xffffffffu};
    uint nums[] = {0u, 1u, 0x3fffffffu, 0x7fffffffu};
    Insert items[256];
    int n = 0;
    for (int bi = 0; bi < 5; bi++) {
        for (int ni = 0; ni < 4; ni++) {
            Insert it = {0};
            it.isphi = 1;
            it.num = nums[ni];
            it.bid = bids[bi];
            it.off = 0;
            items[n++] = it;
        }
        for (int oi = 0; oi < 5; oi++) {
            for (int ni = 0; ni < 2; ni++) {
                Insert it = {0};
                it.isphi = 0;
                it.num = nums[ni];
                it.bid = bids[bi];
                it.off = offs[oi];
                items[n++] = it;
            }
        }
    }
    for (int i = 0; i < n; i++) {
        assert(icmp(&items[i], &items[i]) == 0);
        for (int j = 0; j < n; j++) {
            int c1 = icmp(&items[i], &items[j]);
            int c2 = icmp(&items[j], &items[i]);
            assert(c1 == -c2);
            if (i < j) assert(c1 < 0);
            if (i > j) assert(c1 > 0);
        }
    }
    /* Transitivity on triples */
    for (int i = 0; i < n; i += 3)
        for (int j = i + 1; j < n; j += 3)
            for (int k = j + 1; k < n; k += 3)
                assert(icmp(&items[i], &items[j]) < 0 &&
                       icmp(&items[j], &items[k]) < 0 &&
                       icmp(&items[i], &items[k]) < 0);
    printf("test_icmp (production vendor/qbe/load.c) ok (%d boundary items)\n", n);
    return 0;
}
EOF
QBE_SRCS="util parse abi cfg mem ssa alias copy fold gvn gcm simpl ifopt live spill rega emit \
amd64/targ amd64/sysv amd64/isel amd64/emit amd64/winabi amd64/elf \
arm64/targ arm64/abi arm64/isel arm64/emit arm64/macho \
rv64/targ rv64/abi rv64/isel rv64/emit"
QBE_OBJS=""
for qs in $QBE_SRCS; do
  if [ -f "$ROOT_DIR/out/qbe-build/$qs.o" ]; then
    QBE_OBJS="$QBE_OBJS $ROOT_DIR/out/qbe-build/$qs.o"
  else
    "$CC_BIN" -std=c99 -O2 -I"$TMP_DIR/qbe_inc" -I"$ROOT_DIR/vendor/qbe" -c "$ROOT_DIR/vendor/qbe/$qs.c" -o "$TMP_DIR/qbe_objs/$qs.o"
    QBE_OBJS="$QBE_OBJS $TMP_DIR/qbe_objs/$qs.o"
  fi
done
"$CC_BIN" -std=c99 -O2 -I"$TMP_DIR/qbe_inc" -I"$ROOT_DIR/vendor/qbe" "$TMP_DIR/test_icmp.c" $QBE_OBJS -o "$TMP_DIR/test_icmp"
"$TMP_DIR/test_icmp"

echo "p91_data_ptr_safety: ALL PASSED"
