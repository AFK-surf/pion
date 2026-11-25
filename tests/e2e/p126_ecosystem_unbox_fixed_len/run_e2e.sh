#!/bin/sh
# P126: Opt-Track X1 ecosystem code generation (compiler/src/core/qbe.pion;
# Lean: tests/lean/proofs/QbeEcosystemUnboxFixedLen.lean).
#   1. variant/ (two files): `Result` / `Option` callees in reader.pion are
#      consumed immediately by `?` / `match` in main.pion: a ByteReader method
#      that writes its receiver's cursor, an early `return Err(...)`, a caller
#      parameter shadowing the callee's top-level `bias`, and a `?` inside an
#      argument that leaves before the callee runs.
#   2. tuple.pion: `let (a, b) = mix(x, y)` of 2-5 field primitive tuples
#      (Int / Float / Double / Int64 / UInt / Bool, `_` fields, in a loop)
#      lives in a private stack buffer; an escaping tuple keeps its identity
#      and an object-field tuple (String, Array[Int]) keeps its heap box and
#      reference counting; plain and destructuring inlined bodies keep the
#      callee's lexical scope.
#   3. fixed.pion: immutable aliases of package FixedArray / ImmArray literal
#      tables check bounds against the literal length, also after a write
#      through another alias; a parameter or local shadowing the table, a
#      `let mut` alias and a dynamic Array keep the loaded header length; an
#      index equal to the length still traps.
# For dev and --release: check.py on the emitted SSA (native), and exact
# stdout (plus exit status, and stderr for the trap) natively and on Wasm32
# against the reference outputs <program>.expected. An `--emit-ssa` build
# compiles the package as one unit; variant and tuple are also built once more
# with a plain `build --release` (per-file CAS units, where cross-file callees
# stay calls) and must print the same reference output.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p126_ecosystem_unbox_fixed_len"
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is required for the Wasm32 leg of P126" >&2
  exit 1
fi

N=0
for PROG in variant tuple fixed; do
  case "$PROG" in
    variant) set -- "$DIR/variant/reader.pion" "$DIR/variant/main.pion"; CODE=0 ;;
    fixed) set -- "$DIR/fixed.pion"; CODE=134 ;;
    *) set -- "$DIR/$PROG.pion"; CODE=0 ;;
  esac
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    BASE="$TMP_DIR/${PROG}_$MODE"
    "$PIONC" build $FLAG --emit-ssa "$BASE.ssa" -o "$BASE" "$@"
    python3 -E "$DIR/check.py" "$PROG" "$MODE" "$BASE.ssa"
    set +e
    # Compare the program's own streams only: the shell's "Aborted" notice
    # for a signalled child stays out of $BASE.err.
    ( exec "$BASE" > "$BASE.out" 2> "$BASE.err" ) 2> /dev/null
    RC=$?
    set -e
    if [ "$RC" -ne "$CODE" ]; then
      cat "$BASE.err" >&2
      echo "FAIL: p126 $PROG $MODE exited $RC, want $CODE" >&2
      exit 1
    fi
    if ! cmp -s "$DIR/$PROG.expected" "$BASE.out"; then
      diff -u "$DIR/$PROG.expected" "$BASE.out" >&2 || true
      echo "FAIL: p126 $PROG $MODE stdout differs from the reference" >&2
      exit 1
    fi
    if [ "$CODE" -eq 0 ]; then
      if [ -s "$BASE.err" ]; then
        cat "$BASE.err" >&2
        echo "FAIL: p126 $PROG $MODE wrote to stderr" >&2
        exit 1
      fi
    elif [ "$(cat "$BASE.err")" != "pion panic: index 4 out of bounds (len 4)" ]; then
      cat "$BASE.err" >&2
      echo "FAIL: p126 $PROG $MODE trap diagnostic differs" >&2
      exit 1
    fi
    "$PIONC" build $FLAG --target wasm32 -o "$BASE.wasm" "$@"
    set +e
    node "$WASM_RT" "$BASE.wasm" > "$BASE.wout" 2> "$BASE.werr"
    WRC=$?
    set -e
    if [ "$CODE" -eq 0 ] && [ "$WRC" -ne 0 ]; then
      cat "$BASE.werr" >&2
      echo "FAIL: p126 $PROG $MODE Wasm32 exited $WRC" >&2
      exit 1
    fi
    if [ "$CODE" -ne 0 ] && { [ "$WRC" -eq 0 ] || ! grep -q 'idx=4, len=4' "$BASE.werr"; }; then
      cat "$BASE.werr" >&2
      echo "FAIL: p126 $PROG $MODE Wasm32 did not trap at idx=4, len=4 (exit $WRC)" >&2
      exit 1
    fi
    if ! cmp -s "$DIR/$PROG.expected" "$BASE.wout"; then
      diff -u "$DIR/$PROG.expected" "$BASE.wout" >&2 || true
      echo "FAIL: p126 $PROG $MODE Wasm32 stdout differs from the reference" >&2
      exit 1
    fi
    if [ "$MODE" = "release" ] && [ "$CODE" -eq 0 ]; then
      "$PIONC" build --release -o "$BASE.plain" "$@"
      "$BASE.plain" > "$BASE.plain.out"
      if ! cmp -s "$DIR/$PROG.expected" "$BASE.plain.out"; then
        diff -u "$DIR/$PROG.expected" "$BASE.plain.out" >&2 || true
        echo "FAIL: p126 $PROG plain --release build stdout differs from the reference" >&2
        exit 1
      fi
      echo "p126 $PROG plain --release build (per-file CAS units): output equals the reference"
    fi
    echo "p126 $PROG $MODE: SSA guards, native exit $RC and Wasm32 output equal the reference"
  done
  N=$((N + 1))
done
[ "$N" -eq 3 ]

echo "PASS: p126_ecosystem_unbox_fixed_len"
