#!/bin/sh
# P124: counted-fill length immediate for fresh local Array[Int]
# (compiler/src/core/qbe.pion `qbe_record_counted_fill` /
# `qbe_array_length_operand`; Lean: tests/lean/proofs/QbeCountedArrayLength.lean).
# After `let a : Array[Int] = []` (one or more fresh arrays), `let mut i = 0`
# and `while i < N { a.push(lit); ...; i = i + 1 }` with a literal
# 0 <= N <= 2147483647, later bounds checks on an array whose length stays
# stable compare the index against the immediate N instead of the header length.
# Verifies, for --release and dev builds of 15 programs (gen.py):
#   1. Structure (check.py): single- and multi-array fills use the immediate in
#      every bounds check of `probe` (37, and 0 for the empty fill); an alias
#      that grows, a push, a pop, a capturing closure that pushes, a `mut`
#      argument and a plain call argument keep the header length (no check
#      against 37); a shadowing inner `let a = [...]` keeps its own length
#      (exactly one check against 37: the outer read).
#   2. Execution: exit status, stdout and stderr equal gen.py's plain-array
#      reference exactly: alias / push / closure / `mut` growth read the new
#      element 19 at index 37, pop traps at index 36 with len 36, the short
#      shadow traps with len 2 and the long shadow reads past 37, and
#      out-of-range reads and writes (-1, 37, 100, and 0 after an empty fill)
#      abort with SIGABRT (134) naming the original index and the true length.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p124_counted_array_length"
check() { python3 -E "$DIR/check.py" "$@"; }
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

python3 -E "$DIR/gen.py" "$TMP_DIR"
N_CASE=0
while read -r NAME CODE IMM MIN MAX ALL; do
  for MODE in release dev; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    BASE="$TMP_DIR/${NAME}_$MODE"
    "$PIONC" build $FLAG --emit-ssa "$BASE.ssa" -o "$BASE" "$TMP_DIR/$NAME.pion"
    check "$NAME $MODE" "$BASE.ssa" "$IMM" "$MIN" "$MAX" "$ALL"
    set +e
    # Compare the program's own streams only: the shell's "Aborted" /
    # "Abort trap" notice for a signalled child stays out of $BASE.err.
    ( exec "$BASE" > "$BASE.out" 2> "$BASE.err" ) 2> /dev/null
    RC=$?
    set -e
    if [ "$RC" -ne "$CODE" ]; then
      cat "$BASE.err" >&2
      echo "FAIL: p124 $NAME $MODE exited $RC, want $CODE" >&2
      exit 1
    fi
    if ! cmp -s "$TMP_DIR/$NAME.stdout" "$BASE.out"; then
      diff -u "$TMP_DIR/$NAME.stdout" "$BASE.out" >&2 || true
      echo "FAIL: p124 $NAME $MODE stdout differs from the reference" >&2
      exit 1
    fi
    if ! cmp -s "$TMP_DIR/$NAME.stderr" "$BASE.err"; then
      diff -u "$TMP_DIR/$NAME.stderr" "$BASE.err" >&2 || true
      echo "FAIL: p124 $NAME $MODE stderr differs from the reference" >&2
      exit 1
    fi
    echo "p124 $NAME $MODE: exit $RC, stdout / stderr equal the reference"
  done
  N_CASE=$((N_CASE + 1))
done < "$TMP_DIR/cases.txt"
[ "$N_CASE" -eq 15 ]

echo "PASS: p124_counted_array_length"
