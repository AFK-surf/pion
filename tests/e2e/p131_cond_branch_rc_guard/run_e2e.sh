#!/bin/sh
# P131: owned left operands of comparisons in `if` / `while` conditions
# (compiler/src/core/qbe.pion, qbe_emit_cond_branch_leaf) are held while a
# right operand that may leave early (`return`, `break`, `continue`, `?`)
# runs, and released exactly once on every path. cond.pion covers String
# `==` / `!=` / `<` / `>=`, loop `break` / `continue`, `?` in Result functions, Array[Int], #derive(Eq) struct / enum
# with String fields, StrView over a fresh String, and a left operand that
# leaves itself.
# For dev and --release, each build in its own empty PION_CACHE_DIR: exact
# stdout, exit status 0 and empty stderr natively, with an AddressSanitizer
# runtime (LeakSanitizer on Linux) and on Wasm32.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p131_cond_branch_rc_guard"
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
unset PION_TARGET || true
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
CC_BIN="${CC:-cc}"
REF="$DIR/cond.expected"
[ -s "$REF" ] || { echo "FAIL: p131 missing reference" >&2; exit 1; }

fresh_cas() {
  PION_CACHE_DIR=$(mktemp -d "$TMP_DIR/cas.XXXXXX")
  export PION_CACHE_DIR
}

# check <label> <out> <err> <exit status>
check() {
  if [ "$4" -ne 0 ]; then
    cat "$3" >&2
    echo "FAIL: p131 $1 exited $4" >&2
    exit 1
  fi
  if [ -s "$3" ]; then
    cat "$3" >&2
    echo "FAIL: p131 $1 wrote to stderr" >&2
    exit 1
  fi
  if [ ! -s "$2" ] || ! cmp -s "$REF" "$2"; then
    diff -u "$REF" "$2" >&2 || true
    echo "FAIL: p131 $1 stdout differs from the reference (or is empty)" >&2
    exit 1
  fi
}

ASAN=0
if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"; then
  ASAN=1
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = "1" ]; then
  echo "FAIL: p131 ASan required by PION_REQUIRE_SANITIZERS=1" >&2
  exit 1
fi
if [ "$(uname -s)" = "Darwin" ]; then
  ASAN_OPTS="detect_leaks=0:halt_on_error=1"
else
  ASAN_OPTS="detect_leaks=1:halt_on_error=1"
fi
HAVE_NODE=0
command -v node >/dev/null 2>&1 && HAVE_NODE=1

N=0
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  BASE="$TMP_DIR/cond_$MODE"
  fresh_cas
  "$PIONC" build $FLAG -o "$BASE" "$DIR/cond.pion"
  set +e
  "$BASE" > "$BASE.out" 2> "$BASE.err"
  RC=$?
  set -e
  check "$MODE native" "$BASE.out" "$BASE.err" "$RC"
  LEGS="native"
  if [ "$ASAN" -eq 1 ]; then
    fresh_cas
    "$PIONC" build $FLAG --emit-obj "$BASE.o" "$DIR/cond.pion"
    "$CC_BIN" -fsanitize=address "$BASE.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$BASE.asan"
    set +e
    ASAN_OPTIONS="$ASAN_OPTS" "$BASE.asan" > "$BASE.asan.out" 2> "$BASE.asan.err"
    RC=$?
    set -e
    check "$MODE ASan" "$BASE.asan.out" "$BASE.asan.err" "$RC"
    LEGS="$LEGS + ASan"
  fi
  if [ "$HAVE_NODE" -eq 1 ]; then
    fresh_cas
    "$PIONC" build $FLAG --target wasm32 -o "$BASE.wasm" "$DIR/cond.pion"
    set +e
    node "$WASM_RT" "$BASE.wasm" > "$BASE.wout" 2> "$BASE.werr"
    RC=$?
    set -e
    check "$MODE Wasm32" "$BASE.wout" "$BASE.werr" "$RC"
    LEGS="$LEGS + Wasm32"
  fi
  echo "p131 cond $MODE: $LEGS output equals the reference"
  N=$((N + 1))
done
[ "$N" -eq 2 ]

echo "PASS: p131_cond_branch_rc_guard"
