#!/bin/sh
set -eu

# P32-C permanent E2E regression:
#   amd64_sysv direct ELF64 Ostorel/Ostorew encoding for XMM registers (>8 Double/Float stack args).
#   Tests:
#     1. 19 Double + self + Int64 method (mirroring Invar Scene::push_inst with runtime vars & defaults)
#     2. 14 Float (f32) function (runtime vars, negatives, constants)
#     3. Mixed 10 Int64 (>6 GPR) + 12 Double (>8 XMM) + 4 Float interleaved stack slots
#     4. Linux x86_64 dual-path parity: direct ELF64 vs --emit-asm GAS path + objdump movq %xmm check
#     5. Native Release + ASan/LSan + Wasm32 + pionc fmt --check

PIONC="${1:-}"
if [ -z "$PIONC" ] || [ ! -x "$PIONC" ]; then
  echo "usage: $0 <path-to-pionc>" >&2
  exit 1
fi

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

EXPECTED="p32c_abi_fp_stack ok count=3 sum=1109.125 fsum=-6.25 isum=10045 c1=1000000000 c2=1000000000 tex=42.5"
SRC="$TEST_DIR/main.pion"

# 1. Formatter check
FMT_OUT=$("$PIONC" fmt --check --json "$SRC")
if ! printf '%s' "$FMT_OUT" | grep -q '"ok":true'; then
  echo "FAIL: p32c_abi_fp_stack main.pion failed pionc fmt --check: $FMT_OUT" >&2
  exit 1
fi

# 2. Native Release build (uses direct ELF64 encoder on Linux x86_64)
"$PIONC" build --release -o "$TMP_DIR/p32c_native" "$SRC"
NATIVE_OUT=$("$TMP_DIR/p32c_native")
echo "p32c_abi_fp_stack native -> $NATIVE_OUT"
if [ "$NATIVE_OUT" != "$EXPECTED" ]; then
  echo "FAIL: p32c_abi_fp_stack native mismatch: expected '$EXPECTED', got '$NATIVE_OUT'" >&2
  exit 1
fi

# 3. Linux x86_64 dual-path parity (direct ELF64 vs --emit-asm GAS) + objdump verification
UNAME_S=$(uname -s)
UNAME_M=$(uname -m)
CC_BIN="${CC:-cc}"
if [ "$UNAME_S" = "Linux" ] && [ "$UNAME_M" = "x86_64" ]; then
  RT_LIB="${PION_RT_LIB:-$ROOT_DIR/out/libpionrt.a}"
  if [ ! -f "$RT_LIB" ]; then
    "$CC_BIN" -std=c11 -O2 -fPIC -fno-asynchronous-unwind-tables -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt.o"
    ar rcs "$TMP_DIR/libpionrt.a" "$TMP_DIR/pion_rt.o"
    RT_LIB="$TMP_DIR/libpionrt.a"
  fi
  "$PIONC" build --release --emit-asm "$TMP_DIR/p32c.s" -o "$TMP_DIR/p32c_dummy" "$SRC"
  "$CC_BIN" "$TMP_DIR/p32c.s" "$RT_LIB" -lm -lpthread -o "$TMP_DIR/p32c_gas"
  GAS_OUT=$("$TMP_DIR/p32c_gas")
  echo "p32c_abi_fp_stack gas -> $GAS_OUT"
  if [ "$GAS_OUT" != "$NATIVE_OUT" ]; then
    echo "FAIL: direct ELF64 vs GAS mismatch: elf='$NATIVE_OUT' gas='$GAS_OUT'" >&2
    exit 1
  fi
  "$PIONC" build --release --emit-obj "$TMP_DIR/p32c_direct.o" "$SRC"
  if command -v objdump >/dev/null 2>&1; then
    XMM_STORES=$(objdump -d "$TMP_DIR/p32c_direct.o" | grep -E '66 (4[0-9a-f] )?0f (d6|7e)|mov[qd][[:space:]]+%xmm[0-9]+,.*\(%rsp\)' || true)
    if [ -z "$XMM_STORES" ]; then
      echo "FAIL: expected movq/movd %xmm -> (%rsp) (66 [REX] 0f d6/7e) in direct ELF64 object" >&2
      exit 1
    fi
    XMM_CNT=$(printf '%s\n' "$XMM_STORES" | wc -l | tr -d ' ')
    echo "p32c_abi_fp_stack objdump XMM stack stores: $XMM_CNT insns (OK)"
  fi
fi

# 4. ASan/LSan check
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --emit-obj "$TMP_DIR/p32c_asan.o" "$SRC"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/p32c_asan.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p32c_asan"
  ASAN_OUT=$("$TMP_DIR/p32c_asan")
  echo "p32c_abi_fp_stack ASan/LSan -> $ASAN_OUT"
  if [ "$ASAN_OUT" != "$EXPECTED" ]; then
    echo "FAIL: p32c_abi_fp_stack ASan/LSan mismatch: '$ASAN_OUT'" >&2
    exit 1
  fi
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p32c ASan check"
fi

# 5. Wasm32 check
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/p32c.wasm" "$SRC"
  WASM_OUT=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p32c.wasm")
  echo "p32c_abi_fp_stack wasm32 -> $WASM_OUT"
  if [ "$WASM_OUT" != "$EXPECTED" ]; then
    echo "FAIL: p32c_abi_fp_stack wasm32 mismatch: expected '$EXPECTED', got '$WASM_OUT'" >&2
    exit 1
  fi
else
  echo "NOTE: node unavailable; skipping p32c wasm32 check"
fi

echo "PASS: p32c_abi_fp_stack"
