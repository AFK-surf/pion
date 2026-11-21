#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
CC_BIN="${CC:-cc}"
RT_LIB="${PION_RT_LIB:-$ROOT_DIR/out/libpionrt.a}"
UNAME_S=$(uname -s)

# ---------------------------------------------------------------------------
# 1. All 9 POSIX / mobile targets: --emit-asm + target ISA signature check
# ---------------------------------------------------------------------------
cat > "$TMP_DIR/kernel.pion" <<'EOF'
pub extern "C" fn pion_add_mul(a : Int64, b : Int64, c : Int64) -> Int64 = "pion_add_mul" {
  a * b + c
}

pub fn main(world : World) -> Int {
  io_println(world, pion_add_mul(6L, 7L, 0L).to_string())
  0
}
EOF

check_asm_target() {
  tgt="$1"
  pat="$2"
  out_s="$TMP_DIR/kernel_${tgt}.s"
  PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --target "$tgt" --emit-asm "$out_s" "$TMP_DIR/kernel.pion"
  if [ ! -s "$out_s" ]; then
    echo "FAIL: --target $tgt --emit-asm produced empty file" >&2
    exit 1
  fi
  if ! grep -Eq "$pat" "$out_s"; then
    echo "FAIL: --target $tgt asm did not match expected pattern '$pat'" >&2
    head -n 40 "$out_s" >&2
    exit 1
  fi
  echo "  [asm OK] --target $tgt ($(wc -l < "$out_s" | tr -d ' ') lines)"
}

echo "=== P29-A/B [1/4] --emit-asm across all 10 targets ==="
check_asm_target arm64_apple   '(^|[[:space:]])ret($|[[:space:]])'
check_asm_target amd64_apple   '(^|[[:space:]])(ret|retq)($|[[:space:]])'
check_asm_target amd64_sysv    '(^|[[:space:]])(ret|retq)($|[[:space:]])'
check_asm_target amd64_win     '(^|[[:space:]])(ret|retq)($|[[:space:]])'
check_asm_target arm64         '(^|[[:space:]])ret($|[[:space:]])'
check_asm_target rv64          '(^|[[:space:]])(sd|ret)($|[[:space:]])'
check_asm_target ios_arm64     '(^|[[:space:]])ret($|[[:space:]])'
check_asm_target ios_sim_arm64 '(^|[[:space:]])ret($|[[:space:]])'
check_asm_target android_arm64 '(^|[[:space:]])ret($|[[:space:]])'
check_asm_target android_x64   '(^|[[:space:]])(ret|retq)($|[[:space:]])'

# ---------------------------------------------------------------------------
# 2. --emit-staticlib (workspace package with Pion + c_sources) + C host call
# ---------------------------------------------------------------------------
echo "=== P29-A [2/4] --emit-staticlib + C host link & run ==="
PKG_DIR="$TMP_DIR/demo_lib"
mkdir -p "$PKG_DIR/src" "$PKG_DIR/csrc"

cat > "$PKG_DIR/csrc/extra.c" <<'EOF'
#include <stdint.h>
int64_t demo_c_bonus(int64_t x) { return x + 100; }
EOF

cat > "$PKG_DIR/pion.toml" <<'EOF'
[package]
name = "demo_lib"
version = "0.1.0"

[link]
c_sources = ["csrc/extra.c"]
cc_flags = ["-O2"]
EOF

cat > "$PKG_DIR/src/lib.pion" <<'EOF'
extern "C" fn demo_c_bonus(x : Int64) -> Int64 = "demo_c_bonus"

pub extern "C" fn pion_calc(a : Int64, b : Int64) -> Int64 = "pion_calc" {
  demo_c_bonus(a * b)
}
EOF

STATIC_LIB="$TMP_DIR/libdemo.a"
PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --emit-staticlib "$STATIC_LIB" "$PKG_DIR"
if [ ! -s "$STATIC_LIB" ]; then
  echo "FAIL: --emit-staticlib did not create $STATIC_LIB" >&2
  exit 1
fi
AR_MEMBERS=$(ar t "$STATIC_LIB" | grep -c '\.o$' || true)
echo "  libdemo.a members (.o count): $AR_MEMBERS"
if [ "$AR_MEMBERS" -lt 2 ]; then
  echo "FAIL: expected >= 2 .o members (Pion + c_sources) in libdemo.a" >&2
  ar t "$STATIC_LIB" >&2
  exit 1
fi

cat > "$TMP_DIR/host_main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
extern int64_t pion_calc(int64_t a, int64_t b);
int main(void) {
    printf("static_or_dyn=%lld\n", (long long)pion_calc(6, 7));
    return 0;
}
EOF

"$CC_BIN" -O2 "$TMP_DIR/host_main.c" "$STATIC_LIB" "$RT_LIB" -lm -lpthread -o "$TMP_DIR/host_static"
STATIC_OUT=$("$TMP_DIR/host_static")
echo "  staticlib C host -> $STATIC_OUT"
if [ "$STATIC_OUT" != "static_or_dyn=142" ]; then
  echo "FAIL: staticlib C host output mismatch: '$STATIC_OUT'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. --emit-cdylib (.dylib on macOS, .so on Linux) + C host link & run
# ---------------------------------------------------------------------------
echo "=== P29-A [3/4] --emit-cdylib + C host link & run ==="
if [ "$UNAME_S" = "Darwin" ]; then
  DYLIB="$TMP_DIR/libdemo.dylib"
else
  DYLIB="$TMP_DIR/libdemo.so"
fi
PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --emit-cdylib "$DYLIB" "$PKG_DIR"
if [ ! -s "$DYLIB" ]; then
  echo "FAIL: --emit-cdylib did not create $DYLIB" >&2
  exit 1
fi
echo "  cdylib file: $(file "$DYLIB")"
"$CC_BIN" -O2 "$TMP_DIR/host_main.c" "$DYLIB" -Wl,-rpath,"$TMP_DIR" -o "$TMP_DIR/host_dyn"
DYN_OUT=$("$TMP_DIR/host_dyn")
echo "  cdylib C host -> $DYN_OUT"
if [ "$DYN_OUT" != "static_or_dyn=142" ]; then
  echo "FAIL: cdylib C host output mismatch: '$DYN_OUT'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. macOS cross-target checks: amd64_apple --emit-obj + ios_sim_arm64
# ---------------------------------------------------------------------------
echo "=== P29-A [4/4] Platform cross-target verification ==="
if [ "$UNAME_S" = "Darwin" ]; then
  AMD64_O="$TMP_DIR/kernel_amd64_apple.o"
  PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --target amd64_apple --emit-obj "$AMD64_O" "$TMP_DIR/kernel.pion"
  AMD64_FILE=$(file "$AMD64_O")
  echo "  amd64_apple --emit-obj -> $AMD64_FILE"
  printf '%s' "$AMD64_FILE" | grep -q 'Mach-O 64-bit object x86_64' || {
    echo "FAIL: amd64_apple --emit-obj did not produce Mach-O 64-bit object x86_64" >&2
    exit 1
  }

  IOS_SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)
  if [ -n "$IOS_SIM_SDK" ] && [ -d "$IOS_SIM_SDK" ]; then
    IOS_LIB="$TMP_DIR/libdemo_iossim.a"
    PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --target ios_sim_arm64 --emit-staticlib "$IOS_LIB" "$PKG_DIR"
    IOS_LIPO=$(lipo -info "$IOS_LIB" 2>&1 || file "$IOS_LIB")
    echo "  ios_sim_arm64 --emit-staticlib -> $IOS_LIPO"
    printf '%s' "$IOS_LIPO" | grep -qi 'arm64' || {
      echo "FAIL: ios_sim_arm64 staticlib missing arm64 architecture" >&2
      exit 1
    }

    IOS_RT_O="$TMP_DIR/pion_rt_iossim.o"
    xcrun --sdk iphonesimulator clang \
      -target arm64-apple-ios15.0-simulator \
      -isysroot "$IOS_SIM_SDK" \
      -std=c11 -O2 -fno-asynchronous-unwind-tables -Wall -Wextra -Werror \
      -c "$ROOT_DIR/runtime/pion_rt.c" -o "$IOS_RT_O"
    IOS_RT_FILE=$(file "$IOS_RT_O")
    echo "  pion_rt.c (ios_sim_arm64) -> $IOS_RT_FILE"
    printf '%s' "$IOS_RT_FILE" | grep -q 'Mach-O 64-bit object arm64' || {
      echo "FAIL: pion_rt.c ios_sim_arm64 did not produce Mach-O 64-bit object arm64" >&2
      exit 1
    }
  else
    echo "  NOTE: iOS Simulator SDK not installed; skipping ios_sim_arm64 native cross-compile check"
  fi
else
  echo "  NOTE: non-macOS host ($UNAME_S); skipping Apple Mach-O / iOS Simulator cross-compile checks"
fi

echo "p29a_multi_target E2E: OK"
