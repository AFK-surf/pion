#!/bin/sh
# P135: the QBE statement scanners behind TCO / TRMA (heap writes, TRMA
# early exits, shadowing of the function name / borrowed RC parameters) and the
# single-push loop guard see every `Stmt` (`for i in a..<b`, `for x in arr`,
# C-style `for`, `guard`, tuple `let`, `debug_assert`): exact output in dev and
# --release, native, ASan/LSan and Wasm32.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p135_sforrange_scanners"
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
unset PION_TARGET || true
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
CC_BIN="${CC:-cc}"
REF="$DIR/scanners.expected"
[ -s "$REF" ] || { echo "FAIL: p135 missing reference" >&2; exit 1; }

fresh_cas() {
  PION_CACHE_DIR=$(mktemp -d "$TMP_DIR/cas.XXXXXX")
  export PION_CACHE_DIR
}

check() {
  if [ "$4" -ne 0 ]; then
    cat "$3" >&2
    echo "FAIL: p135 $1 exited $4" >&2
    exit 1
  fi
  if [ -s "$3" ]; then
    cat "$3" >&2
    echo "FAIL: p135 $1 wrote to stderr" >&2
    exit 1
  fi
  if [ ! -s "$2" ] || ! cmp -s "$REF" "$2"; then
    diff -u "$REF" "$2" >&2 || true
    echo "FAIL: p135 $1 stdout differs from the reference (or is empty)" >&2
    exit 1
  fi
}

ASAN=0
if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"; then
  ASAN=1
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = "1" ]; then
  echo "FAIL: p135 ASan required by PION_REQUIRE_SANITIZERS=1" >&2
  exit 1
fi
if [ "$(uname -s)" = "Darwin" ]; then
  ASAN_OPTS="detect_leaks=0:halt_on_error=1"
else
  ASAN_OPTS="detect_leaks=1:halt_on_error=1"
fi
HAVE_NODE=0
command -v node >/dev/null 2>&1 && HAVE_NODE=1
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

run_bounded() {
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" 30 "$@"
  else
    "$@"
  fi
}

N=0
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  BASE="$TMP_DIR/scanners_$MODE"
  fresh_cas
  "$PIONC" build $FLAG -o "$BASE" "$DIR/scanners.pion"
  set +e
  run_bounded "$BASE" > "$BASE.out" 2> "$BASE.err"
  RC=$?
  set -e
  check "$MODE native" "$BASE.out" "$BASE.err" "$RC"
  LEGS="native"
  if [ "$ASAN" -eq 1 ]; then
    fresh_cas
    "$PIONC" build $FLAG --emit-obj "$BASE.o" "$DIR/scanners.pion"
    "$CC_BIN" -fsanitize=address "$BASE.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$BASE.asan"
    set +e
    ASAN_OPTIONS="$ASAN_OPTS" run_bounded "$BASE.asan" > "$BASE.asan.out" 2> "$BASE.asan.err"
    RC=$?
    set -e
    check "$MODE ASan" "$BASE.asan.out" "$BASE.asan.err" "$RC"
    LEGS="$LEGS + ASan"
  fi
  if [ "$HAVE_NODE" -eq 1 ]; then
    fresh_cas
    "$PIONC" build $FLAG --target wasm32 -o "$BASE.wasm" "$DIR/scanners.pion"
    set +e
    run_bounded node "$WASM_RT" "$BASE.wasm" > "$BASE.wout" 2> "$BASE.werr"
    RC=$?
    set -e
    check "$MODE Wasm32" "$BASE.wout" "$BASE.werr" "$RC"
    LEGS="$LEGS + Wasm32"
  fi
  echo "p135 scanners $MODE: $LEGS output equals the reference"
  N=$((N + 1))
done
[ "$N" -eq 2 ]

echo "PASS: p135_sforrange_scanners"
