#!/bin/sh
# P130: real-workload static data (compiler/src/core/qbe.pion,
# compiler/src/core/wasm.pion; Lean: tests/lean/proofs/QbeRealWorkloadDataOpts.lean).
# gen.py writes the programs and their reference outputs:
#   1. strings: long Base64 / quote / backslash / UTF-8 / escape literals are
#      emitted as quoted byte runs `b "..."` next to numeric bytes;
#   2. ints: 1,024+ element Array / FixedArray / ImmArray[Int] literals
#      (0, +/-, INT32_MIN / INT32_MAX, hex, underscores) copy a private word
#      table with `$pion_arr_copy`; every call returns a fresh mutable array;
#      a 1,100 element literal with side-effecting elements keeps in-order
#      element evaluation;
#   3. records: 128+ row tables of all-String records are written straight
#      into the array slots (no row box), with cross-row shared strings and a
#      row that outlives its array; dynamic-field, reordered-field and
#      single-row tables keep row boxes;
#   4. sparse: the Wasm32 data section of a mostly-zero 2,048 word table is
#      split into active segments that skip edge and 16+ byte zero runs and
#      rebuild the dense memory image.
# Each program: check.py on the dev and --release SSA, exact stdout natively
# (dev, --release) and on Wasm32 (Node, dev and --release); ints and records
# also under ASan/LSan; sparse also through check.py on the .wasm module
# (PION_NO_WASM_OPT=1). Every build uses its own empty cache directory.
set -eu
unset PION_TARGET || true

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p130_real_workload_data_opts"
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
GEN="$TMP_DIR/gen"
mkdir -p "$GEN"
python3 -E "$DIR/gen.py" "$GEN"
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is required for the Wasm32 leg of P130" >&2
  exit 1
fi

# Each build gets a fresh, empty CAS so no unit comes from an earlier build.
build() {
  PION_CACHE_DIR=$(mktemp -d "$TMP_DIR/cas.XXXXXX")
  export PION_CACHE_DIR
  "$PIONC" build "$@"
}

same_output() {
  # $1 label, $2 expected file, $3 actual file
  if [ ! -s "$3" ] || ! cmp -s "$2" "$3"; then
    diff -u "$2" "$3" >&2 || true
    echo "FAIL: p130 $1 output differs from the reference" >&2
    exit 1
  fi
}

CC_BIN="${CC:-cc}"
ASAN=0
if "$CC_BIN" -fsanitize=address -x c - -o "$TMP_DIR/asan_probe" <<'PROBE' >/dev/null 2>&1
int main(void) { return 0; }
PROBE
then
  CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"
  ASAN=1
fi

N=0
for PROG in strings ints records sparse; do
  SRC="$GEN/$PROG.pion"
  EXP="$GEN/$PROG.expected"
  [ -s "$EXP" ] || { echo "FAIL: p130 $PROG has no reference output" >&2; exit 1; }
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    BASE="$TMP_DIR/${PROG}_$MODE"
    build $FLAG --emit-ssa "$BASE.ssa" -o "$BASE" "$SRC"
    python3 -E "$DIR/check.py" ssa "$PROG" "$BASE.ssa" "$GEN"
    "$BASE" > "$BASE.out" 2> "$BASE.err"
    same_output "$PROG $MODE native" "$EXP" "$BASE.out"
    if [ -s "$BASE.err" ]; then
      cat "$BASE.err" >&2
      echo "FAIL: p130 $PROG $MODE wrote to stderr" >&2
      exit 1
    fi
    PION_NO_WASM_OPT=1 build $FLAG --target wasm32 -o "$BASE.wasm" "$SRC"
    if [ "$PROG" = "sparse" ]; then
      python3 -E "$DIR/check.py" wasm "$BASE.wasm" "$GEN"
    fi
    node "$WASM_RT" "$BASE.wasm" > "$BASE.wout"
    same_output "$PROG $MODE Wasm32" "$EXP" "$BASE.wout"
    echo "p130 $PROG $MODE: SSA checks, native and Wasm32 output equal the reference"
  done
  case "$PROG" in
    ints | records)
      if [ "$ASAN" -eq 1 ]; then
        BASE="$TMP_DIR/${PROG}_asan"
        build --release --emit-asm "$BASE.s" "$SRC"
        "$CC_BIN" -fsanitize=address -g -O1 "$BASE.s" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$BASE"
        ASAN_OPTIONS=detect_leaks=1 "$BASE" > "$BASE.out"
        same_output "$PROG ASan/LSan" "$EXP" "$BASE.out"
        echo "p130 $PROG: ASan/LSan clean, output equals the reference"
      else
        echo "p130 $PROG: ASan/LSan SKIP (cc lacks -fsanitize=address)"
      fi
      ;;
  esac
  N=$((N + 1))
done
[ "$N" -eq 4 ]

echo "PASS: p130_real_workload_data_opts"
