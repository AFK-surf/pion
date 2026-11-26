#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

WS="$TMP_DIR/ws"
CAS="$TMP_DIR/cas"
mkdir -p "$WS/extlib/src" "$WS/extlib/csrc" "$WS/app/src" "$CAS"

cat > "$WS/pion.toml" <<'EOF'
[workspace]
members = ["extlib", "app"]
EOF

cat > "$WS/extlib/csrc/ext_ops.c" <<'EOF'
#include <stdint.h>
#include <stddef.h>

static int32_t g_void_acc = 0;

int32_t ext_add_i32(int32_t a, int32_t b) { return a + b; }
uint32_t ext_add_u32(uint32_t a, uint32_t b) { return a + b; }
int64_t ext_mul_i64(int64_t a, int64_t b) { return a * b; }
double ext_fma_f64(double a, double b, double c) { return a * b + c; }
float ext_add_f32(float a, float b) { return a + b; }
int32_t ext_is_pos(int32_t x) { return x > 0 ? 1 : 0; }
uint8_t ext_xor_u8(uint8_t a, uint8_t b) { return (uint8_t)(a ^ b); }
int8_t ext_sub_i8(int8_t a, int8_t b) { return (int8_t)(a - b); }
uint64_t ext_add_u64(uint64_t a, uint64_t b) { return a + b; }
void ext_bump_void(int32_t delta) { g_void_acc += delta; }
int32_t ext_get_void_acc(void) { return g_void_acc; }
void *ext_ptr_id(void *p) { return p; }
EOF

cat > "$WS/extlib/pion.toml" <<'EOF'
[package]
name = "extlib"
version = "0.1.0"

[link]
c_sources = ["csrc/ext_ops.c"]
EOF

cat > "$WS/extlib/src/lib.pion" <<'EOF'
pub extern "C" fn c_add_i32(a : Int, b : Int) -> Int = "ext_add_i32"
pub extern "C" fn c_add_u32(a : UInt, b : UInt) -> UInt = "ext_add_u32"
pub extern "C" fn c_mul_i64(a : Int64, b : Int64) -> Int64 = "ext_mul_i64"
pub extern "C" fn c_fma_f64(a : Double, b : Double, c : Double) -> Double = "ext_fma_f64"
pub extern "C" fn c_add_f32(a : Float, b : Float) -> Float = "ext_add_f32"
pub extern "C" fn c_is_pos(x : Int) -> Bool = "ext_is_pos"
pub extern "C" fn c_xor_u8(a : Byte, b : Byte) -> Byte = "ext_xor_u8"
pub extern "C" fn c_sub_i8(a : Int8, b : Int8) -> Int8 = "ext_sub_i8"
pub extern "C" fn c_add_u64(a : UInt64, b : UInt64) -> UInt64 = "ext_add_u64"
pub extern "C" fn c_bump_void(delta : Int) -> Unit = "ext_bump_void"
pub extern "C" fn c_get_void_acc() -> Int = "ext_get_void_acc"
pub extern "C" fn c_ptr_id(p : Ptr) -> Ptr = "ext_ptr_id"

pub fn apply_via_mono_pkg[T](x : T, y : T, f : (T, T) -> T) -> T {
  let _ = c_bump_void
  f(x, y)
}

pub fn run_mono_extern_val[T](_tag : T, a : Int, b : Int) -> Int {
  let f : (Int, Int) -> Int = c_add_i32
  let bump : (Int) -> Unit = c_bump_void
  bump(3)
  f(a, b)
}
EOF

cat > "$WS/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
extlib = { path = "../extlib" }
EOF

cat > "$WS/app/src/main.pion" <<'EOF'
import "extlib" as ext

extern "C" fn local_add_i32(a : Int, b : Int) -> Int = "ext_add_i32"
extern "C" fn local_bump_void(delta : Int) -> Unit = "ext_bump_void"
extern "C" fn local_sub_i8(a : Int8, b : Int8) -> Int8 = "ext_sub_i8"

fn apply1[A, B](f : (A) -> B, a : A) -> B { f(a) }
fn apply2[A, B, C](f : (A, B) -> C, a : A, b : B) -> C { f(a, b) }
fn apply3[A, B, C, D](f : (A, B, C) -> D, a : A, b : B, c : C) -> D { f(a, b, c) }

fn main(world : World) -> Unit {
  // Local extern "C" fn values: let binding, HOF, closure body
  let f_i32 : (Int, Int) -> Int = local_add_i32
  let r_i32 = f_i32(-50, 8)
  debug_assert(r_i32 == -42, "local i32 neg")
  let k = 10
  let clo_local = fn(x : Int) -> Int { apply2(local_add_i32, x, k) }
  debug_assert(clo_local(5) == 15, "local closure")

  // Cross-package extern "C" fn values across all C ABI types
  let r_u32 = apply2(ext::c_add_u32, 0x80000000U, 7U)
  debug_assert(r_u32 == 0x80000007U, "u32 high bit extuw")

  let r_i64 = apply2(ext::c_mul_i64, -1000000L, 1000000L)
  debug_assert(r_i64 == -1000000000000L, "i64")

  let r_f64 = apply3(ext::c_fma_f64, 2.5, 4.0, 1.25)
  debug_assert(r_f64 == 11.25, "f64")

  let f_f32 : (Float, Float) -> Float = ext::c_add_f32
  let r_f32 = f_f32((1.5).to_float(), (2.25).to_float())
  debug_assert(r_f32 == (3.75).to_float(), "f32")

  let f_bool : (Int) -> Bool = ext::c_is_pos
  debug_assert(f_bool(9) == true && f_bool(-1) == false, "bool")

  let r_byte = apply2(ext::c_xor_u8, 0xF0.to_byte(), 0x0A.to_byte())
  debug_assert(r_byte.to_int() == 0xFA, "byte extub")

  let r_i8 = apply2(local_sub_i8, (10).to_int8(), (52).to_int8())
  debug_assert(r_i8.to_int() == -42, "i8 extsb")

  let r_i8_ext = apply2(ext::c_sub_i8, (-10).to_int8(), (5).to_int8())
  debug_assert(r_i8_ext.to_int() == -15, "xpkg i8 extsb")

  let r_u64 = apply2(ext::c_add_u64, 1000000000000UL, 42UL)
  debug_assert(r_u64 == 1000000000042UL, "u64")

  // Unit/void return via both local and cross-package extern fn values
  let _ = apply1(local_bump_void, 7)
  let _ = apply1(ext::c_bump_void, 11)
  let clo_void = fn(d : Int) -> Unit {
    let g : (Int) -> Unit = ext::c_bump_void
    g(d)
  }
  clo_void(4)

  // Ptr round-trip
  let f_ptr : (Ptr) -> Ptr = ext::c_ptr_id
  let p0 = ptr_null()
  debug_assert(f_ptr(p0) == p0, "ptr")

  // mono_pkg != "" path (generic in extlib referencing its own extern fn value)
  let r_mono = ext::run_mono_extern_val(1, 20, 22)
  debug_assert(r_mono == 42, "mono_pkg extern fn val")
  let r_mono2 = ext::apply_via_mono_pkg(100, 23, ext::c_add_i32)
  debug_assert(r_mono2 == 123, "apply_via_mono_pkg")

  let acc = ext::c_get_void_acc()
  debug_assert(acc == 25, "void acc should be 7+11+4+3=25")
  io_println(world, "extern_fn_value ok acc=" + acc.to_string())
}
EOF

PION_CACHE_DIR="$CAS" "$PIONC" build -o "$TMP_DIR/app_bin" "$WS/app"
OUT="$("$TMP_DIR/app_bin" | tr -d '\r')"
[ "$OUT" = "extern_fn_value ok acc=25" ] || {
  echo "FAIL: extern_fn_value output mismatch: '$OUT'" >&2
  exit 1
}
echo "PASS: extern_fn_value ($OUT)"
