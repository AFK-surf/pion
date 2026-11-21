#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

APP_DIR="$TMP_DIR/app"
CAS_DIR="$TMP_DIR/cas"
mkdir -p "$APP_DIR/src" "$CAS_DIR"

# Native C helper to verify IEEE-754 float (s) and uint32_t/uint64_t C ABI
cat > "$APP_DIR/c_ffi.c" <<'EOF'
#include <stdint.h>

float p27c2_fma_f32(float a, float b, float c) {
  return a * b + c;
}

uint32_t p27c2_rotl32(uint32_t x, int n) {
  return (x << n) | (x >> (32 - n));
}

uint64_t p27c2_add_u64(uint64_t a, uint64_t b) {
  return a + b;
}
EOF

cat > "$APP_DIR/pion.toml" <<'EOF'
[package]
name = "p27c2_app"
version = "0.1.0"

[link]
c_sources = ["c_ffi.c"]
EOF

cat > "$APP_DIR/src/main.pion" <<'EOF'
extern "C" fn p27c2_fma_f32(a : Float, b : Float, c : Float) -> Float
extern "C" fn p27c2_rotl32(x : UInt, n : Int) -> UInt
extern "C" fn p27c2_add_u64(a : UInt64, b : UInt64) -> UInt64

#derive(Eq)
struct Pixel {
  r : Float
  g : Float
  rgba : UInt
  tag : UInt64
}

fn id_gen[T](x : T) -> T {
  x
}

fn main(world : World) -> Unit {
  // 1. Float arithmetic, expected-type literals, suffix f, comparisons, methods, Option[Float], #derive(Eq), C FFI
  let mut a : Float = 1.5
  let b : Float = 2.5f
  debug_assert(a + b == 4.0, "float add")
  debug_assert(b - a == 1.0, "float sub")
  debug_assert(a * b == 3.75, "float mul")
  debug_assert(b / 2.0 == 1.25, "float div")
  debug_assert(-a == -1.5, "float neg")
  a += 0.5
  debug_assert(a == 2.0, "float +=")
  a *= 3.0
  debug_assert(a == 6.0, "float *=")
  a -= 1.5
  debug_assert(a == 4.5, "float -=")
  a /= 3.0
  debug_assert(a == 1.5, "float /=")
  debug_assert(1.5f < 2.0f && 1.5f <= 1.5f && 2.0f > 1.5f && 2.0f >= 2.0f && 1.5f != 2.0f, "float cmp")
  if a < 2.0 && b > 2.0 {
    debug_assert(true, "float fused branch")
  } else {
    debug_assert(false, "float fused branch fail")
  }

  let f_from_d = Float::from_double(3.25)
  let f_from_i = Float::from_int(-7)
  debug_assert(f_from_d == 3.25 && f_from_i == -7.0, "Float::from_double/from_int")
  debug_assert((3.5).to_float() == 3.5 && (-4).to_float() == -4.0, "Double/Int::to_float")
  debug_assert(f_from_d.to_double() == 3.25, "Float::to_double")
  debug_assert((3.75f).to_int() == 3 && (-3.75f).to_int64() == -3L, "Float::to_int/to_int64")
  let bits = (1.5f).to_bits()
  debug_assert(bits == 0x3FC00000, "Float::to_bits 1.5f")
  debug_assert(Float::from_bits(bits) == 1.5f, "Float::from_bits")
  debug_assert((1.5f).reinterpret_as_int() == 0x3FC00000, "Float::reinterpret_as_int")
  debug_assert((1.5f).reinterpret_as_uint() == 0x3FC00000U, "Float::reinterpret_as_uint")
  debug_assert((-4.25f).abs() == 4.25f, "Float::abs")
  debug_assert((9.0f).sqrt() == 3.0f, "Float::sqrt")
  debug_assert((2.7f).floor() == 2.0f && (2.2f).ceil() == 3.0f, "Float::floor/ceil")
  debug_assert((2.6f).round() == 3.0f && (-2.9f).trunc() == -2.0f, "Float::round/trunc")
  debug_assert((1.5f).to_string() == "1.5", "Float::to_string")

  let opt_f : Option[Float] = Some(2.25)
  match opt_f {
    Some(v) => debug_assert(v == 2.25f, "Option[Float] Some")
    None => debug_assert(false, "Option[Float] None")
  }
  let gen_f : Float = id_gen(7.5f)
  debug_assert(gen_f == 7.5f, "generic Float")

  let fma = p27c2_fma_f32(2.0, 3.5, 1.25)
  debug_assert(fma == 8.25f, "extern C float ABI")

  // 2. UInt & UInt64 unsigned semantics
  let umax : UInt = 0xFFFF_FFFFU
  let uhi : UInt = 0x8000_0000U
  let uone : UInt = 1
  debug_assert(umax > 0U && umax > uhi && uhi > uone && uone < uhi, "UInt unsigned cmp")
  if umax > 10U && uhi >= 0x8000_0000U {
    debug_assert(true, "UInt fused branch")
  } else {
    debug_assert(false, "UInt fused branch fail")
  }
  debug_assert(umax / 2U == 0x7FFF_FFFFU, "UInt udiv")
  debug_assert(umax % 10U == 5U, "UInt urem")
  debug_assert(uhi >> 1 == 0x4000_0000U, "UInt logical shr")
  let mut uacc : UInt = 0x8000_0000U
  uacc >>= 2
  debug_assert(uacc == 0x2000_0000U, "UInt >>=")
  uacc <<= 1
  debug_assert(uacc == 0x4000_0000U, "UInt <<=")
  debug_assert(umax.to_int64() == 4294967295L, "UInt::to_int64 zero-ext")
  debug_assert(umax.to_uint64() == 4294967295UL, "UInt::to_uint64 zero-ext")
  debug_assert(umax.to_string() == "4294967295", "UInt::to_string")
  debug_assert((-1).reinterpret_as_uint() == umax, "Int::reinterpret_as_uint")
  debug_assert(umax.reinterpret_as_int() == -1, "UInt::reinterpret_as_int")
  debug_assert((0x3FC00000U).reinterpret_as_float() == 1.5f, "UInt::reinterpret_as_float")
  debug_assert((3000000000U).to_double() == 3000000000.0, "UInt::to_double")
  debug_assert((42U).to_float() == 42.0f, "UInt::to_float")
  debug_assert(p27c2_rotl32(0x80000001U, 1) == 0x00000003U, "extern C uint32 ABI")

  let u64max : UInt64 = 0xFFFF_FFFF_FFFF_FFFFUL
  let u64hi : UInt64 = 0x8000_0000_0000_0000UL
  debug_assert(u64max > 0UL && u64max > u64hi && u64hi > 1UL, "UInt64 unsigned cmp")
  if u64max > 100UL && u64hi < u64max {
    debug_assert(true, "UInt64 fused branch")
  } else {
    debug_assert(false, "UInt64 fused branch fail")
  }
  debug_assert(u64max / 2UL == 0x7FFF_FFFF_FFFF_FFFFUL, "UInt64 udiv")
  debug_assert(u64max % 10UL == 5UL, "UInt64 urem")
  debug_assert(u64hi >> 1 == 0x4000_0000_0000_0000UL, "UInt64 logical shr")
  debug_assert(u64max.to_string() == "18446744073709551615", "UInt64::to_string max")
  debug_assert(u64hi.to_string() == "9223372036854775808", "UInt64::to_string 2^63")
  debug_assert((42UL).to_string() == "42", "UInt64::to_string small")
  debug_assert((-1L).reinterpret_as_uint64() == u64max, "Int64::reinterpret_as_uint64")
  debug_assert(u64max.reinterpret_as_int64() == -1L, "UInt64::reinterpret_as_int64")
  let d_bits : UInt64 = (1.5).reinterpret_as_uint64()
  debug_assert(d_bits.reinterpret_as_double() == 1.5, "Double <-> UInt64 reinterpret")
  debug_assert((1000000UL).to_double() == 1000000.0, "UInt64::to_double")
  debug_assert(p27c2_add_u64(u64hi, 5UL) == 0x8000_0000_0000_0005UL, "extern C uint64 ABI")

  // #derive(Eq) with Float, UInt, UInt64
  let p1 = Pixel::{ r: 0.5, g: 1.0, rgba: umax, tag: u64max }
  let p2 = Pixel::{ r: 0.5, g: 1.0, rgba: umax, tag: u64max }
  let p3 = Pixel::{ r: 0.25, g: 1.0, rgba: umax, tag: u64max }
  debug_assert(p1 == p2 && p1 != p3, "#derive(Eq) Float/UInt/UInt64")

  // 3. FixedArray[Float], FixedArray[Int], FixedArray[String] + Array::make
  let ff : FixedArray[Float] = [1.0, 2.0, 3.0, 4.0]
  debug_assert(ff.length() == 4 && ff[0] == 1.0f && ff[3] == 4.0f, "FixedArray[Float] lit")
  ff[1] += 5.5
  debug_assert(ff[1] == 7.5f, "FixedArray[Float] +=")
  let mut fsum : Float = 0.0
  for i, v in ff {
    fsum += v + Float::from_int(i)
  }
  debug_assert(fsum == 21.5f, "FixedArray[Float] for-in")

  let fi : FixedArray[Int] = FixedArray::makei(5, fn(i : Int) -> Int { (i + 1) * 10 })
  debug_assert(fi.length() == 5 && fi[0] == 10 && fi[4] == 50, "FixedArray::makei")
  // Overlapping self-blit forward & backward
  fi.blit_to(fi, len=3, src_offset=0, dst_offset=2)
  debug_assert(fi[0] == 10 && fi[1] == 20 && fi[2] == 10 && fi[3] == 20 && fi[4] == 30, "FixedArray::blit_to overlap right")
  fi.blit_to(fi, len=3, src_offset=2, dst_offset=0)
  debug_assert(fi[0] == 10 && fi[1] == 20 && fi[2] == 30, "FixedArray::blit_to overlap left")

  let fs : FixedArray[String] = FixedArray::make(4, "init_" + 1.to_string())
  debug_assert(fs.length() == 4 && fs[0] == "init_1" && fs[3] == "init_1", "FixedArray::make String")
  fs.fill("fill_" + 2.to_string())
  debug_assert(fs[0] == "fill_2" && fs[3] == "fill_2", "FixedArray::fill String")
  let fs2 : FixedArray[String] = FixedArray::makei(4, fn(i : Int) -> String { "s_" + i.to_string() })
  fs2.blit_to(fs, len=2, src_offset=1, dst_offset=2)
  debug_assert(fs[0] == "fill_2" && fs[2] == "s_1" && fs[3] == "s_2", "FixedArray::blit_to String")
  let fs_cp = fs.copy()
  fs[0] = "changed"
  debug_assert(fs_cp[0] == "fill_2", "FixedArray::copy String")

  let fa_arr : Array[Int] = Array::make(4, 99)
  let fa_from : FixedArray[Int] = FixedArray::from_array(fa_arr)
  fa_arr[0] = 1
  debug_assert(fa_from.length() == 4 && fa_from[0] == 99 && fa_from[3] == 99, "Array::make + FixedArray::from_array")
  let ptr = array_data_ptr(ff)
  debug_assert(!ptr_is_null(ptr), "array_data_ptr(FixedArray)")

  io_println(world, "p27c2_float_uint_fixedarray ok")
}
EOF

OUT=$(PION_CACHE_DIR="$CAS_DIR" "$PIONC" run "$APP_DIR")
echo "p27c2_float_uint_fixedarray -> $OUT"
if [ "$OUT" != "p27c2_float_uint_fixedarray ok" ]; then
  echo "FAIL: p27c2_float_uint_fixedarray output mismatch: $OUT" >&2
  exit 1
fi

# ASan/LSan 0-leak verification for Float/UInt/UInt64 + FixedArray[String]
CC_BIN="${CC:-cc}"
# Probe an ASan link first: MSYS2 UCRT64 GCC compiles -fsanitize=address but ships no -lasan.
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  cat > "$TMP_DIR/asan_p27c2.pion" <<'EOF'
fn main(world : World) -> Unit {
  let mut round = 0
  while round < 32 {
    let fs : FixedArray[String] = FixedArray::make(8, "base_" + round.to_string())
    let fs2 : FixedArray[String] = FixedArray::makei(8, fn(i : Int) -> String { "elem_" + i.to_string() })
    fs2.blit_to(fs, len=4, src_offset=2, dst_offset=3)
    fs.blit_to(fs, len=4, src_offset=0, dst_offset=2)
    fs.fill("done_" + round.to_string())
    let cp = fs.copy()
    let arr : Array[String] = Array::make(4, "arr_" + round.to_string())
    let fa = FixedArray::from_array(arr)
    let u64s = (0xFFFF_FFFF_FFFF_FFFFUL).to_string()
    let f_s = (1.5f).to_string()
    debug_assert(cp.length() == 8 && fa.length() == 4 && u64s == "18446744073709551615" && f_s == "1.5", "asan p27c2")
    round = round + 1
  }
  io_println(world, "p27c2_asan ok")
}
EOF
  PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --emit-obj "$TMP_DIR/asan_p27c2.o" "$TMP_DIR/asan_p27c2.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/asan_p27c2.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/asan_p27c2"
  ASAN_OUT=$("$TMP_DIR/asan_p27c2")
  echo "p27c2_asan -> $ASAN_OUT"
  if [ "$ASAN_OUT" != "p27c2_asan ok" ]; then
    echo "FAIL: p27c2_asan output mismatch: $ASAN_OUT" >&2
    exit 1
  fi
fi

echo "[PASS] p27c2_float_uint_fixedarray (Float + UInt/UInt64 + FixedArray + C FFI + ASan/LSan)"
