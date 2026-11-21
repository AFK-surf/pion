#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

LIB_DIR="$TMP_DIR/intmap"
APP_DIR="$TMP_DIR/p26b_app"
CAS_DIR="$TMP_DIR/cas"
mkdir -p "$LIB_DIR/src" "$APP_DIR/src" "$APP_DIR/csrc" "$CAS_DIR"

# 1. Upstream package with private const + private fn + generic struct methods using Option[V]
cat > "$LIB_DIR/pion.toml" <<'EOF'
[package]
name = "intmap"
version = "0.1.0"
EOF

cat > "$LIB_DIR/src/lib.pion" <<'EOF'
let MASK : Int = 15

fn hash_int(k : Int) -> Int {
  let h = (k * 31) & MASK
  if h < 0 { 0 - h } else { h }
}

pub struct Wrap[V] {
  mut inner : Option[V]
}

pub fn Wrap::new[V]() -> Wrap[V] {
  Wrap::{ inner: None }
}

pub fn Wrap::set[V](self : Wrap[V], v : V) -> Unit {
  self.inner = Some(v)
}

pub fn Wrap::get[V](self : Wrap[V]) -> Option[V] {
  self.inner
}

pub struct IntMap[V] {
  keys : Array[Int]
  vals : Array[Option[V]]
}

pub fn IntMap::new[V]() -> IntMap[V] {
  let keys : Array[Int] = []
  let vals : Array[Option[V]] = []
  for _i in 0..16 {
    keys.push(-1)
    vals.push(None)
  }
  IntMap::{ keys: keys, vals: vals }
}

pub fn IntMap::set[V](self : IntMap[V], k : Int, v : V) -> Unit {
  let idx = hash_int(k)
  self.keys[idx] = k
  self.vals[idx] = Some(v)
}

pub fn IntMap::get[V](self : IntMap[V], k : Int) -> Option[V] {
  let idx = hash_int(k)
  if self.keys[idx] == k {
    self.vals[idx]
  } else {
    None
  }
}

pub fn lookup_helper[V](m : IntMap[V], k : Int) -> Option[V] {
  m.get(k)
}
EOF

# 2. C++ host stub exercising C callbacks from Pion + zero-copy data pointers + RC 0-leak check
cat > "$APP_DIR/csrc/cb_host.cc" <<'EOF'
#include <cstdint>
#include <cstring>
#include <cmath>

extern "C" {
void* pion_str_from_cstr(const char *s, int64_t len);
int64_t pion_str_len(void *s);
void pion_rc_dec(void *obj);
}

typedef int32_t (*cb_int_fn)(int32_t, int32_t);
typedef double (*cb_dbl_fn)(double);
typedef void (*cb_void_fn)(int32_t*, int32_t);
typedef void* (*cb_str_fn)(void*);

extern "C" int32_t host_call_int(void *fp, int32_t a, int32_t b) {
    cb_int_fn f = reinterpret_cast<cb_int_fn>(fp);
    return f(a, b);
}

extern "C" double host_call_dbl(void *fp, double x) {
    cb_dbl_fn f = reinterpret_cast<cb_dbl_fn>(fp);
    return f(x);
}

extern "C" int32_t host_call_void(void *fp, int32_t init, int32_t delta) {
    cb_void_fn f = reinterpret_cast<cb_void_fn>(fp);
    int32_t cell = init;
    f(&cell, delta);
    return cell;
}

extern "C" int32_t host_call_str(void *fp) {
    cb_str_fn f = reinterpret_cast<cb_str_fn>(fp);
    // Run multiple iterations to ensure zero RC corruption/leak
    for (int i = 0; i < 16; i++) {
        void *in_s = pion_str_from_cstr("pion", 4);
        void *out_s = f(in_s);
        int64_t n = pion_str_len(out_s);
        const char *data = reinterpret_cast<const char*>(out_s) + 8;
        bool ok = (n == 8 && std::memcmp(data, "pion_cb!", 8) == 0);
        pion_rc_dec(out_s);
        pion_rc_dec(in_s);
        if (!ok) {
            return -1;
        }
    }
    return 1;
}

extern "C" double host_sum_f64_buf(const double *p, int64_t n) {
    double sum = 0.0;
    for (int64_t i = 0; i < n; i++) {
        sum += p[i];
    }
    return sum;
}

extern "C" int32_t host_check_str_bytes(const char *s, const uint8_t *b, int64_t blen) {
    if (std::strcmp(s, "zero_copy") != 0) {
        return -1;
    }
    if (blen != 4 || b[0] != 65 || b[1] != 66 || b[2] != 67 || b[3] != 68) {
        return -2;
    }
    return 1;
}
EOF

cat > "$APP_DIR/pion.toml" <<'EOF'
[package]
name = "p26b_app"
version = "0.1.0"

[dependencies]
intmap = { path = "../intmap" }

[link]
c_sources = ["csrc/cb_host.cc"]
cc_flags = ["-O2"]

[link.linux]
libs = ["stdc++"]
EOF

cat > "$APP_DIR/src/main.pion" <<'EOF'
import "intmap"

extern "C" fn host_call_int(fp : Ptr, a : Int, b : Int) -> Int = "host_call_int"
extern "C" fn host_call_dbl(fp : Ptr, x : Double) -> Double = "host_call_dbl"
extern "C" fn host_call_void(fp : Ptr, init : Int, delta : Int) -> Int = "host_call_void"
extern "C" fn host_call_str(fp : Ptr) -> Int = "host_call_str"
extern "C" fn host_sum_f64_buf(p : Ptr, n : Int64) -> Double = "host_sum_f64_buf"
extern "C" fn host_check_str_bytes(s : Ptr, b : Ptr, blen : Int64) -> Int = "host_check_str_bytes"

extern "C" fn pion_cb_int(a : Int, b : Int) -> Int = "custom_pion_cb_int" {
  a * 10 + b
}

extern "C" fn pion_cb_dbl(x : Double) -> Double {
  x * 2.5 + 1.0
}

extern "C" fn pion_cb_void(cell : Ptr, delta : Int) -> Unit {
  let cur = ptr_read_i32(cell, 0L)
  ptr_write_i32(cell, 0L, cur + delta)
}

extern "C" fn pion_cb_str(s : String) -> String {
  s + "_cb!"
}

struct LocalWrap[V] {
  mut inner : Option[V]
}

fn LocalWrap::new[V]() -> LocalWrap[V] {
  LocalWrap::{ inner: None }
}

fn LocalWrap::set[V](self : LocalWrap[V], v : V) -> Unit {
  self.inner = Some(v)
}

fn LocalWrap::get[V](self : LocalWrap[V]) -> Option[V] {
  self.inner
}

fn near(a : Double, b : Double) -> Bool {
  math_abs(a - b) < 0.0001
}

pub fn main(world : World) -> Int {
  // 1. Bug 1: same-package generic methods with Option[V] (String, Int, Option[String])
  let lws : LocalWrap[String] = LocalWrap::new()
  debug_assert(lws.get().is_none(), "lws init none",)
  lws.set("hello")
  let lws_ok = match lws.get() {
    Some(s) => s == "hello"
    None => false
  }
  debug_assert(lws_ok, "lws set/get String",)

  let lwi : LocalWrap[Int] = LocalWrap::new()
  lwi.set(99)
  let lwi_ok = match lwi.get() {
    Some(n) => n == 99
    None => false
  }
  debug_assert(lwi_ok, "lwi set/get Int",)

  let lwo : LocalWrap[Option[String]] = LocalWrap::new()
  lwo.set(Some("nested"))
  let lwo_ok = match lwo.get() {
    Some(Some(s)) => s == "nested"
    _ => false
  }
  debug_assert(lwo_ok, "lwo set/get Option[String]",)

  // 2. Bug 1 & Bug 2: cross-package IntMap[V] & Wrap[V] calling upstream private hash_int & MASK
  let cws : intmap::Wrap[String] = intmap::Wrap::new()
  cws.set("cross_str")
  let cws_ok = match cws.get() {
    Some(s) => s == "cross_str"
    None => false
  }
  debug_assert(cws_ok, "cross Wrap[String]",)

  let ms : intmap::IntMap[String] = intmap::IntMap::new()
  ms.set(7, "seven")
  let ms_ok = match intmap::lookup_helper(ms, 7) {
    Some(s) => s == "seven"
    None => false
  }
  debug_assert(ms_ok, "cross IntMap[String]",)
  debug_assert(ms.get(8).is_none(), "cross IntMap[String] miss",)

  let mi : intmap::IntMap[Int] = intmap::IntMap::new()
  mi.set(3, 303)
  let mi_ok = match intmap::lookup_helper(mi, 3) {
    Some(v) => v == 303
    None => false
  }
  debug_assert(mi_ok, "cross IntMap[Int]",)

  // 3. C callbacks via extern "C" fn body + c_fn_ptr
  let ri = host_call_int(c_fn_ptr(pion_cb_int), 4, 2)
  debug_assert(ri == 42, "cb_int",)
  let rd = host_call_dbl(c_fn_ptr(pion_cb_dbl), 4.0)
  debug_assert(near(rd, 11.0), "cb_dbl",)
  let rv = host_call_void(c_fn_ptr(pion_cb_void), 100, 23)
  debug_assert(rv == 123, "cb_void",)
  let rs = host_call_str(c_fn_ptr(pion_cb_str))
  debug_assert(rs == 1, "cb_str",)

  // 4. Zero-copy FFI pointers & float ptr read/write
  let arr : Array[Double] = [1.5, 2.5, 3.0, 4.0]
  let ap = array_data_ptr(arr)
  let sum1 = host_sum_f64_buf(ap, 4L)
  debug_assert(near(sum1, 11.0), "array_data_ptr sum",)
  ptr_write_f64(ap, 16L, 10.0)
  debug_assert(near(ptr_read_f64(ap, 16L), 10.0), "ptr_read/write_f64",)
  debug_assert(near(arr[2], 10.0), "zero-copy array mutation",)

  let fbuf = ptr_alloc(16L)
  ptr_write_f32(fbuf, 0L, 3.25)
  ptr_write_f32(fbuf, 4L, -1.5)
  debug_assert(near(ptr_read_f32(fbuf, 0L), 3.25), "ptr_read/write_f32 pos",)
  debug_assert(near(ptr_read_f32(fbuf, 4L), -1.5), "ptr_read/write_f32 neg",)
  ptr_free(fbuf)

  let zstr = "zero_copy"
  let zbs = "ABCD".to_bytes()
  debug_assert(
    host_check_str_bytes(str_data_ptr(zstr), bytes_data_ptr(zbs), 4L) == 1,
    "str_data_ptr + bytes_data_ptr",
  )

  // 5. Direct libm math builtins
  debug_assert(near(math_tan(0.0), 0.0), "math_tan",)
  debug_assert(near(math_asin(0.0), 0.0), "math_asin",)
  debug_assert(near(math_acos(1.0), 0.0), "math_acos",)
  debug_assert(near(math_atan(0.0), 0.0), "math_atan",)
  debug_assert(near(math_atan2(1.0, 1.0), 0.78539816), "math_atan2",)
  debug_assert(near(math_exp(0.0), 1.0), "math_exp",)
  debug_assert(near(math_log(1.0), 0.0), "math_log",)
  debug_assert(near(math_round(2.6), 3.0), "math_round",)
  debug_assert(near(math_trunc(-2.9), -2.0), "math_trunc",)

  // 6. StringBuilder::write_byte & write_bytes
  let sb = StringBuilder()
  sb.write_byte(b'H')
  sb.write_bytes("i!".to_bytes())
  sb.write_bytes("".to_bytes())
  debug_assert(sb.to_string() == "Hi!", "sb write_byte/write_bytes",)

  io_println(world, "p26b_ok")
  0
}
EOF

OUT=$(PION_CACHE_DIR="$CAS_DIR" "$PIONC" run "$APP_DIR")
echo "p26b_ffi_generics -> $OUT"
if [ "$OUT" != "p26b_ok" ]; then
  echo "FAIL: p26b_ffi_generics output mismatch: $OUT" >&2
  exit 1
fi
echo "p26b_ffi_generics E2E: OK"
