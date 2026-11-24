#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

LIB_DIR="$TMP_DIR/native_lib"
APP_DIR="$TMP_DIR/native_app"
CAS_DIR="$TMP_DIR/cas"
mkdir -p "$LIB_DIR/src" "$LIB_DIR/csrc" "$LIB_DIR/vendor" "$LIB_DIR/extlib" "$APP_DIR/src" "$CAS_DIR"

CC_BIN="${CC:-cc}"

# 1. Precompiled static library in sub-package linked via `objects`
cat > "$TMP_DIR/ext_obj.c" <<'EOF'
#include <stdint.h>
int64_t ext_obj_val(void) { return 100; }
EOF
"$CC_BIN" -O2 -c "$TMP_DIR/ext_obj.c" -o "$TMP_DIR/ext_obj.o"
ar rcs "$LIB_DIR/vendor/libextobj.a" "$TMP_DIR/ext_obj.o"

# 2. Precompiled static library in sub-package linked via `search_paths` (-L) + `libs` (-l)
cat > "$TMP_DIR/search_lib.c" <<'EOF'
#include <stdint.h>
int64_t search_lib_val(void) { return 77; }
EOF
"$CC_BIN" -O2 -c "$TMP_DIR/search_lib.c" -o "$TMP_DIR/search_lib.o"
ar rcs "$LIB_DIR/extlib/libsearchdemo.a" "$TMP_DIR/search_lib.o"

# 3. Local C header + C stub in sub-package (also verifies `#include "pion_rt.h"` works)
cat > "$LIB_DIR/csrc/c_helper.h" <<'EOF'
#ifndef C_HELPER_H
#define C_HELPER_H
#define C_HELPER_MAGIC 40
#endif
EOF

cat > "$LIB_DIR/csrc/c_helper.c" <<'EOF'
#include <stdint.h>
#include "pion_rt.h"
#include "c_helper.h"

int64_t c_helper_val(void) {
    void *s = pion_str_from_cstr("hi", 2);
    int64_t n = pion_str_len(s);
    pion_rc_dec(s);
    return (int64_t)C_HELPER_MAGIC + n;
}
EOF

# 4. C++ stub in sub-package using std::string + extern "C" + #include "pion_rt.h"
cat > "$LIB_DIR/csrc/cxx_shim.cc" <<'EOF'
#include <cstdint>
#include <string>
#include "pion_rt.h"

extern "C" int64_t cxx_str_len(int64_t extra) {
    std::string s = "hello_cxx";
    void *ps = pion_str_from_cstr(s.c_str(), static_cast<int64_t>(s.size()));
    int64_t n = pion_str_len(ps);
    pion_rc_dec(ps);
    return n + extra;
}
EOF

# 5. Platform-specific C stubs in sub-package:
#    - macOS: calls CoreFoundation's CFAbsoluteTimeGetCurrent()
#    - Linux: exercises [link.linux] libs = ["stdc++"]
cat > "$LIB_DIR/csrc/plat_macos.c" <<'EOF'
#include <stdint.h>
extern double CFAbsoluteTimeGetCurrent(void);
int64_t plat_check(void) {
    double t = CFAbsoluteTimeGetCurrent();
    return t > 0.0 ? 1 : 0;
}
EOF

cat > "$LIB_DIR/csrc/plat_linux.c" <<'EOF'
#include <stdint.h>
int64_t plat_check(void) {
    return 1;
}
EOF

# 6. Sub-package pion.toml declaring all native link settings (relative to native_lib)
cat > "$LIB_DIR/pion.toml" <<'EOF'
[package]
name = "native_lib"
version = "0.1.0"

[link]
libs = [
  "searchdemo",
]
search_paths = ["extlib"]
objects = ["vendor/libextobj.a"]
c_sources = [
  "csrc/c_helper.c",
  # C++ stub
  "csrc/cxx_shim.cc",
]
cc_flags = ["-O2", "-Icsrc"]

[link.macos]
frameworks = [
  "CoreFoundation",
]
rpaths = [
  "@executable_path/../lib",
  "extlib",
]
c_sources = ["csrc/plat_macos.c"]

[link.linux]
libs = ["stdc++"]
rpaths = [
  "$ORIGIN/../lib",
  "extlib",
]
c_sources = ["csrc/plat_linux.c"]
EOF

cat > "$LIB_DIR/src/lib.pion" <<'EOF'
extern "C" fn c_helper_val() -> Int64 = "c_helper_val"

extern "C" fn cxx_str_len(extra : Int64) -> Int64 = "cxx_str_len"

extern "C" fn ext_obj_val() -> Int64 = "ext_obj_val"

extern "C" fn search_lib_val() -> Int64 = "search_lib_val"

extern "C" fn plat_check() -> Int64 = "plat_check"

pub fn get_c_val() -> Int64 {
  c_helper_val()
}

pub fn get_cxx_val(extra : Int64) -> Int64 {
  cxx_str_len(extra)
}

pub fn get_obj_val() -> Int64 {
  ext_obj_val()
}

pub fn get_search_val() -> Int64 {
  search_lib_val()
}

pub fn get_plat_val() -> Int64 {
  plat_check()
}

pub fn summary() -> String {
  "native_link ok: c=" +
  c_helper_val().to_string() +
  " cxx=" +
  cxx_str_len(2L).to_string() +
  " obj=" +
  ext_obj_val().to_string() +
  " search=" +
  search_lib_val().to_string() +
  " plat=" +
  plat_check().to_string()
}
EOF

cat > "$LIB_DIR/lib_test.pion" <<'EOF'
test "subpkg native link c/cxx/static/platform" {
  debug_assert(get_c_val() > 0L, "c_helper_val")
  debug_assert(get_cxx_val(2L) == 11L, "cxx_str_len")
  debug_assert(get_obj_val() >= 100L, "ext_obj_val")
  debug_assert(get_search_val() == 77L, "search_lib_val")
  debug_assert(get_plat_val() == 1L, "plat_check")
}
EOF

# 7. Root package importing native_lib with NO [link] section of its own
cat > "$APP_DIR/pion.toml" <<'EOF'
[package]
name = "native_app"
version = "0.1.0"

[dependencies]
native_lib = { path = "../native_lib" }
EOF

cat > "$APP_DIR/src/main.pion" <<'EOF'
import "native_lib"

pub fn main(world : World) -> Int {
  io_println(world, native_lib::summary())
  0
}
EOF

cat > "$APP_DIR/main_test.pion" <<'EOF'
test "root app links transitive subpkg native deps" {
  debug_assert(native_lib::get_c_val() > 0L, "root c_helper_val")
  debug_assert(native_lib::get_cxx_val(2L) == 11L, "root cxx_str_len")
  debug_assert(native_lib::get_obj_val() >= 100L, "root ext_obj_val")
  debug_assert(native_lib::get_search_val() == 77L, "root search_lib_val")
  debug_assert(native_lib::get_plat_val() == 1L, "root plat_check")
}
EOF

# Snapshot both package directories to prove zero pollution
BEFORE=$(find "$LIB_DIR" "$APP_DIR" -type f | sort)

# Cold run: sub-package c_sources compiled (MISS) and linked into root app
OUT1=$(PION_CACHE_DIR="$CAS_DIR" PION_CAS_TRACE=1 "$PIONC" run "$APP_DIR" 2>"$TMP_DIR/trace1.log")
echo "native_link cold -> $OUT1"
if [ "$OUT1" != "native_link ok: c=42 cxx=11 obj=100 search=77 plat=1" ]; then
  echo "FAIL: native_link cold output mismatch: $OUT1" >&2
  cat "$TMP_DIR/trace1.log" >&2
  exit 1
fi
grep -q '\[cas\] cstub=.*c_helper\.c MISS' "$TMP_DIR/trace1.log"
grep -q '\[cas\] cstub=.*cxx_shim\.cc MISS' "$TMP_DIR/trace1.log"

AFTER=$(find "$LIB_DIR" "$APP_DIR" -type f | sort)
if [ "$BEFORE" != "$AFTER" ]; then
  echo "FAIL: native_link polluted workspace directories!" >&2
  exit 1
fi

# Warm run: c_sources cache HIT
OUT2=$(PION_CACHE_DIR="$CAS_DIR" PION_CAS_TRACE=1 "$PIONC" run "$APP_DIR" 2>"$TMP_DIR/trace2.log")
echo "native_link warm -> $OUT2"
if [ "$OUT2" != "$OUT1" ]; then
  echo "FAIL: native_link warm output mismatch: $OUT2" >&2
  exit 1
fi
grep -q '\[cas\] cstub=.*c_helper\.c HIT' "$TMP_DIR/trace2.log"
grep -q '\[cas\] cstub=.*cxx_shim\.cc HIT' "$TMP_DIR/trace2.log"
if grep -q '\[cas\] cstub=.*MISS' "$TMP_DIR/trace2.log"; then
  echo "FAIL: expected 100% cstub cache HIT on warm run" >&2
  cat "$TMP_DIR/trace2.log" >&2
  exit 1
fi

# pionc test --deps --json on multi-package graph (both native_lib and native_app tests must pass)
TEST_OUT=$(PION_CACHE_DIR="$CAS_DIR" "$PIONC" test --deps --json "$APP_DIR")
echo "native_link test -> $TEST_OUT"
printf '%s' "$TEST_OUT" | grep -q '"ok":true'
printf '%s' "$TEST_OUT" | grep -q '"total":2'
printf '%s' "$TEST_OUT" | grep -q '"passed":2'
printf '%s' "$TEST_OUT" | grep -q '"failed":0'
printf '%s' "$TEST_OUT" | grep -q '"packages":\["native_lib","native_app"\]'

# Header modification in sub-package invalidates cstub CAS key (changes size for 1s-mtime FS determinism)
cat > "$LIB_DIR/csrc/c_helper.h" <<'EOF'
#ifndef C_HELPER_H
#define C_HELPER_H
#define C_HELPER_MAGIC 50 /* updated */
#endif
EOF
OUT3=$(PION_CACHE_DIR="$CAS_DIR" "$PIONC" run "$APP_DIR")
echo "native_link header-updated -> $OUT3"
if [ "$OUT3" != "native_link ok: c=52 cxx=11 obj=100 search=77 plat=1" ]; then
  echo "FAIL: header edit did not invalidate cstub cache: $OUT3" >&2
  exit 1
fi

# External static library (.a) modification in sub-package invalidates root app binary cache key
cat > "$TMP_DIR/ext_obj.c" <<'EOF'
#include <stdint.h>
int64_t ext_obj_val(void) { return 200; }
int64_t ext_obj_extra_pad(void) { return 1; }
EOF
"$CC_BIN" -O2 -c "$TMP_DIR/ext_obj.c" -o "$TMP_DIR/ext_obj.o"
rm -f "$LIB_DIR/vendor/libextobj.a"
ar rcs "$LIB_DIR/vendor/libextobj.a" "$TMP_DIR/ext_obj.o"
OUT4=$(PION_CACHE_DIR="$CAS_DIR" "$PIONC" run "$APP_DIR")
echo "native_link objects-updated -> $OUT4"
if [ "$OUT4" != "native_link ok: c=52 cxx=11 obj=200 search=77 plat=1" ]; then
  echo "FAIL: objects (.a) update did not invalidate binary cache: $OUT4" >&2
  exit 1
fi

echo "native_link multi-pkg workspace E2E: OK"
