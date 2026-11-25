#!/bin/sh
# Round 232: untyped tuple array literals passed to generic `Array[(K, V)]`
# parameters, 4-mode (Native dev/release + Wasm32 dev/release) + ASan.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
SRC="$ROOT_DIR/tests/e2e/generic_tuple_array_lit/main.pion"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

EXP="b1=1=10,2=20,1=30 b2=1=10,2=20,1=30 chain=460 pipe=1=10,2=20,1=30 assoc=1=10,2=20,1=30 meth=7=70,8=80,9=90 same=341 heap=1=a,2=b heap2=3=cd,4=e direct=1=10,2=20,1=30,1=a,2=b"

for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG -o "$TMP_DIR/bin_$MODE" "$SRC"
  OUT="$("$TMP_DIR/bin_$MODE")"
  if [ "$OUT" != "$EXP" ]; then
    echo "FAIL: generic_tuple_array_lit native $MODE: got '$OUT', want '$EXP'" >&2
    exit 1
  fi
  echo "generic_tuple_array_lit native $MODE ok"
done

if command -v node >/dev/null 2>&1; then
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    "$PIONC" build $FLAG --target wasm32 -o "$TMP_DIR/bin_$MODE.wasm" "$SRC"
    WOUT="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/bin_$MODE.wasm")"
    if [ "$WOUT" != "$EXP" ]; then
      echo "FAIL: generic_tuple_array_lit wasm32 $MODE: got '$WOUT', want '$EXP'" >&2
      exit 1
    fi
    echo "generic_tuple_array_lit wasm32 $MODE ok"
  done
fi

CC_BIN="${CC:-cc}"
if [ -n "${PION_ASAN_RT_LIB:-}" ] && [ -f "${PION_ASAN_RT_LIB:-}" ]; then
  ASAN_LIB="$PION_ASAN_RT_LIB"
elif printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  ASAN_LIB="$TMP_DIR/libpionrt_asan.a"
else
  ASAN_LIB=""
fi

if [ -n "$ASAN_LIB" ]; then
  # LeakSanitizer is only reliable on Linux; elsewhere still catch UAF / OOB.
  if [ "$(uname -s)" = "Linux" ]; then
    ASAN_OPTS="detect_leaks=1:halt_on_error=1"
  else
    ASAN_OPTS="detect_leaks=0:halt_on_error=1"
  fi
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/gt.o" "$SRC"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/gt.o" "$ASAN_LIB" -lm -lpthread -o "$TMP_DIR/gt_asan"
    AOUT="$(ASAN_OPTIONS="$ASAN_OPTS" "$TMP_DIR/gt_asan")"
    if [ "$AOUT" != "$EXP" ]; then
      echo "FAIL: generic_tuple_array_lit ASan ${MODE:-dev}: got '$AOUT', want '$EXP'" >&2
      exit 1
    fi
    echo "generic_tuple_array_lit ASan ${MODE:-dev} ok"
  done
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = "1" ]; then
  echo "FAIL: generic_tuple_array_lit ASan required (PION_REQUIRE_SANITIZERS=1) but unavailable" >&2
  exit 1
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping generic_tuple_array_lit ASan check"
fi

echo "PASS: generic_tuple_array_lit"
