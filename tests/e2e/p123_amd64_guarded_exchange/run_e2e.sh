#!/bin/sh
# P123: amd64_sysv release guarded integer-array exchange
# (compiler/src/core/qbe.pion `qbe_emit_guarded_exchange`;
# Lean: tests/lean/proofs/QbeAmd64GuardedExchange.lean).
# Inside the 64-bit-guarded fast path of a versioned `while i < bound` loop,
# `let t = a[i]; a[i] = a[k - i]; a[k - i] = t; i = i + 1` over a native
# Array[Int] becomes a left / right pointer pair stepping by +4 / -4 until the
# one-past sentinel, and the exit stores `bound` back into `i`. Only
# `--release` builds for amd64_sysv do this; other targets and dev builds keep
# the indexed loop.
# Verifies:
#   1. Structure (check.py): the 614-case edge program's `exchange` has one
#      `@exchange_` block on amd64_sysv --release (two pointer phis, +4 / -4,
#      two loads / two stores, no extsw or pion_panic_oob, bound written back,
#      checked slow loop kept) and its `constrained` twin (extra `&& i < 2`
#      condition) has none; dev amd64_sysv and --release arm64, arm64_apple,
#      rv64, amd64_win, amd64_apple have none.
#   2. Execution (Linux x86-64: the transformed code; elsewhere the host's
#      indexed loop): 307 valid (start, bound, axis) over a 5-element array --
#      empty, single-element, self-exchange, coinciding and crossing pointers,
#      both axis ends -- through both functions (614 cases): exit induction
#      value and every final element equal gen.py's independent reference, in
#      --release and dev.
#   3. Traps: 4 out-of-range starts (left negative, left past the end, right
#      past the end, right negative) take the checked loop, abort with SIGABRT
#      (exit status 134) and name the exact index on stderr.
#   4. fannkuchredux --release prints the C result (73196 38); on Linux x86-64
#      its pion_fn_main has exactly one 8-instruction exchange loop in the amd64_sysv
#      assembly (and the edge program's `exchange` one, `constrained` none).
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p123_amd64_guarded_exchange"
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC_BIN="${CC:-cc}"
# check ARGS...: the structure checker (a function, so that paths with spaces
# stay one argument).
check() { python3 -E "$DIR/check.py" "$@"; }
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"
HOST="$(uname -s)/$(uname -m)"
NATIVE_SYSV=0
case "$HOST" in
  Linux/x86_64|Linux/amd64) NATIVE_SYSV=1 ;;
esac

if [ ! -x "$QBE" ]; then
  echo "FAIL: QBE binary not found at $QBE" >&2
  exit 1
fi

python3 -E "$DIR/gen.py" "$TMP_DIR"
EDGES="$TMP_DIR/edges.pion"
FN_X=pion_fn_exchange
FN_C=pion_fn_constrained

# 1. Structure of the QBE text.
"$PIONC" build --release --target amd64_sysv --emit-ssa "$TMP_DIR/sysv.ssa" "$EDGES"
check ssa "amd64_sysv --release" "$TMP_DIR/sysv.ssa" "$FN_X" hit
check ssa "amd64_sysv --release" "$TMP_DIR/sysv.ssa" "$FN_C" miss
"$PIONC" build --target amd64_sysv --emit-ssa "$TMP_DIR/sysv_dev.ssa" "$EDGES"
check ssa "amd64_sysv dev" "$TMP_DIR/sysv_dev.ssa" "$FN_X" miss
for T in arm64 arm64_apple rv64 amd64_win amd64_apple; do
  "$PIONC" build --release --target "$T" --emit-ssa "$TMP_DIR/$T.ssa" "$EDGES"
  check ssa "$T --release" "$TMP_DIR/$T.ssa" "$FN_X" miss
done
"$QBE" -t amd64_sysv -o "$TMP_DIR/sysv.s" "$TMP_DIR/sysv.ssa"
check asm "amd64_sysv --release" "$TMP_DIR/sysv.s" "$FN_X" 1
check asm "amd64_sysv --release" "$TMP_DIR/sysv.s" "$FN_C" 0

# 2. Execution against the reference.
for MODE in release dev; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG --emit-ssa "$TMP_DIR/edges_$MODE.ssa" -o "$TMP_DIR/edges_$MODE" "$EDGES"
  "$TMP_DIR/edges_$MODE" > "$TMP_DIR/edges_$MODE.out"
  if ! cmp -s "$TMP_DIR/edges.expected" "$TMP_DIR/edges_$MODE.out"; then
    diff -u "$TMP_DIR/edges.expected" "$TMP_DIR/edges_$MODE.out" | head -40 >&2
    echo "FAIL: p123 edge cases ($MODE) differ from the reference" >&2
    exit 1
  fi
  echo "p123 edges $MODE: $(wc -l < "$TMP_DIR/edges_$MODE.out" | tr -d ' ') cases equal the reference"
done
if [ "$NATIVE_SYSV" = 1 ]; then
  # The executed release binary is the transformed one.
  cmp "$TMP_DIR/edges_release.ssa" "$TMP_DIR/sysv.ssa"
  echo "p123 edges release: executed amd64_sysv SSA is the checked one"
else
  echo "NOTE: p123 host $HOST runs the indexed loop; the transformed code runs on Linux x86-64"
fi

# 3. Out-of-range starts abort on the checked loop with the exact index.
N_TRAP=0
while read -r NAME IDX; do
  "$PIONC" build --release --emit-ssa "$TMP_DIR/trap_$NAME.ssa" -o "$TMP_DIR/trap_$NAME" "$TMP_DIR/trap_$NAME.pion"
  if [ "$NATIVE_SYSV" = 1 ]; then
    check ssa "trap $NAME" "$TMP_DIR/trap_$NAME.ssa" "$FN_X" hit
  fi
  set +e
  "$TMP_DIR/trap_$NAME" > "$TMP_DIR/trap_$NAME.out" 2> "$TMP_DIR/trap_$NAME.err"
  RC=$?
  set -e
  if [ "$RC" -ne 134 ]; then
    cat "$TMP_DIR/trap_$NAME.err" >&2
    echo "FAIL: p123 trap $NAME exited $RC, want 134 (SIGABRT)" >&2
    exit 1
  fi
  if ! grep -qx "pion panic: index $IDX out of bounds (len 5)" "$TMP_DIR/trap_$NAME.err"; then
    cat "$TMP_DIR/trap_$NAME.err" >&2
    echo "FAIL: p123 trap $NAME does not report index $IDX" >&2
    exit 1
  fi
  if [ -s "$TMP_DIR/trap_$NAME.out" ]; then
    echo "FAIL: p123 trap $NAME printed to stdout" >&2
    exit 1
  fi
  echo "p123 trap $NAME: exit 134, index $IDX"
  N_TRAP=$((N_TRAP + 1))
done < "$TMP_DIR/traps.txt"
[ "$N_TRAP" -eq 4 ]

# 4. fannkuchredux.
FK="$ROOT_DIR/benchmarks/pion/fannkuchredux.pion"
"$CC_BIN" -O2 -o "$TMP_DIR/fk_c" "$ROOT_DIR/benchmarks/c/fannkuchredux.c"
"$TMP_DIR/fk_c" > "$TMP_DIR/fk_c.out"
if [ "$(cat "$TMP_DIR/fk_c.out")" != "73196 38" ]; then
  echo "FAIL: p123 C fannkuchredux printed '$(cat "$TMP_DIR/fk_c.out")'" >&2
  exit 1
fi
"$PIONC" build --release --emit-ssa "$TMP_DIR/fk.ssa" -o "$TMP_DIR/fk" "$FK"
"$TMP_DIR/fk" > "$TMP_DIR/fk.out"
if ! cmp -s "$TMP_DIR/fk_c.out" "$TMP_DIR/fk.out"; then
  diff -u "$TMP_DIR/fk_c.out" "$TMP_DIR/fk.out" >&2 || true
  echo "FAIL: p123 fannkuchredux --release differs from C" >&2
  exit 1
fi
echo "p123 fannkuchredux --release: $(cat "$TMP_DIR/fk.out") (= C)"
if [ "$NATIVE_SYSV" = 1 ]; then
  check ssa "fannkuchredux --release" "$TMP_DIR/fk.ssa" pion_fn_main hit
  "$QBE" -t amd64_sysv -o "$TMP_DIR/fk.s" "$TMP_DIR/fk.ssa"
  check asm "fannkuchredux --release" "$TMP_DIR/fk.s" pion_fn_main 1
fi

echo "PASS: p123_amd64_guarded_exchange"
