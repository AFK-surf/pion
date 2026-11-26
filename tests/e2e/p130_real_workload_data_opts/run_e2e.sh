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
#      rebuild the dense memory image; sparsecap: a leading zero, 4,095
#      `1, 0 x 16` blocks and a final 1 reach exactly the 4,096 segment cap
#      and still rebuild the image;
#   5. collide: `extern "C"` exports named `pion_i32_literal_0` and
#      `pion_i32_literal_1_words` next to two word-table literals (the tables
#      take other names); edges: out-of-range decimal / hex / underscore /
#      negative literals give the same words through 1,023 element stores and
#      a 1,024 element word table;
#   6. ints as a static library whose `--entry-symbol` is
#      `pion_i32_literal_0` / `pion_i32_literal_0_words` (dev, --release),
#      linked into a C host: same output; twopkg: an `--entry-symbol` equal
#      to a dependency's first word table name gives byte-identical warm
#      (dependency cached) and cold static library objects that run
#      correctly.
# Each program: check.py on the dev and --release SSA, exact stdout natively
# (dev, --release) and on Wasm32 (Node, dev and --release); ints and records
# (and collide, edges) also under ASan/LSan; sparse and sparsecap also
# through check.py on the .wasm module
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

no_stderr() {
  # $1 label, $2 stderr file
  if [ -s "$2" ]; then
    cat "$2" >&2
    echo "FAIL: p130 $1 wrote to stderr" >&2
    exit 1
  fi
}

CC_BIN="${CC:-cc}"
# Apple's AddressSanitizer has no leak checker and rejects detect_leaks=1.
case "$(uname -s)" in
  Darwin) ASAN_OPTS="detect_leaks=0:halt_on_error=1" ;;
  *) ASAN_OPTS="detect_leaks=1:halt_on_error=1" ;;
esac
ASAN=0
if "$CC_BIN" -fsanitize=address -x c - -o "$TMP_DIR/asan_probe" <<'PROBE' >/dev/null 2>&1
int main(void) { return 0; }
PROBE
then
  CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"
  ASAN=1
fi

N=0
for PROG in strings ints records sparse sparsecap collide edges; do
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
    no_stderr "$PROG $MODE native" "$BASE.err"
    PION_NO_WASM_OPT=1 build $FLAG --target wasm32 -o "$BASE.wasm" "$SRC"
    case "$PROG" in
      sparse | sparsecap) python3 -E "$DIR/check.py" wasm "$PROG" "$BASE.wasm" "$GEN" ;;
    esac
    node "$WASM_RT" "$BASE.wasm" > "$BASE.wout" 2> "$BASE.werr"
    same_output "$PROG $MODE Wasm32" "$EXP" "$BASE.wout"
    no_stderr "$PROG $MODE Wasm32" "$BASE.werr"
    echo "p130 $PROG $MODE: SSA checks, native and Wasm32 output equal the reference"
  done
  case "$PROG" in
    ints | records | collide | edges)
      if [ "$ASAN" -eq 1 ]; then
        BASE="$TMP_DIR/${PROG}_asan"
        build --release --emit-asm "$BASE.s" "$SRC"
        "$CC_BIN" -fsanitize=address -g -O1 "$BASE.s" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$BASE"
        ASAN_OPTIONS="$ASAN_OPTS" "$BASE" > "$BASE.out" 2> "$BASE.err"
        same_output "$PROG ASan/LSan" "$EXP" "$BASE.out"
        no_stderr "$PROG ASan/LSan" "$BASE.err"
        echo "p130 $PROG: ASan ($ASAN_OPTS) clean, output equals the reference"
      else
        echo "p130 $PROG: ASan/LSan SKIP (cc lacks -fsanitize=address)"
      fi
      ;;
  esac
  N=$((N + 1))
done
[ "$N" -eq 7 ]

# --entry-symbol renames the entry point to the names the first word table
# would take: the tables avoid it, the static library links and runs.
RT_LIB="${PION_RT_LIB:-$ROOT_DIR/out/libpionrt.a}"
for SYM in pion_i32_literal_0 pion_i32_literal_0_words; do
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    BASE="$TMP_DIR/entry_${SYM}_$MODE"
    build $FLAG --entry-symbol "$SYM" --emit-staticlib "$BASE.a" "$GEN/ints.pion"
    printf 'int %s(int argc, char **argv);\nint main(int argc, char **argv) { return %s(argc, argv); }\n' \
      "$SYM" "$SYM" > "$BASE.c"
    "$CC_BIN" -O1 "$BASE.c" "$BASE.a" "$RT_LIB" -lm -lpthread -o "$BASE"
    "$BASE" > "$BASE.out" 2> "$BASE.err"
    same_output "ints --entry-symbol $SYM $MODE" "$GEN/ints.expected" "$BASE.out"
    no_stderr "ints --entry-symbol $SYM $MODE" "$BASE.err"
  done
  echo "p130 --entry-symbol $SYM: static library links, output equals the reference"
done

# The entry symbol is keyed only into the entry package: an entry symbol equal
# to the dependency's first word table name leaves the dependency's object
# unchanged, so a warm build (dependency cached from a default build) and a
# cold build produce byte-identical member objects.
APP="$GEN/twopkg/app"
TP="$TMP_DIR/twopkg"
mkdir -p "$TP"
WARM_CAS=$(mktemp -d "$TMP_DIR/cas.XXXXXX")
PION_CACHE_DIR="$WARM_CAS" "$PIONC" build --release --emit-staticlib "$TP/default.a" "$APP"
# The dependency's first word table descriptor (a local data symbol).
DEP_SYM=$(nm "$TP/default.a" | sed -n 's/.* [dDsS] _\{0,1\}\(pion_[A-Za-z0-9_]*i32_literal_0\)$/\1/p' | head -n 1)
case "$DEP_SYM" in
  pion_?*i32_literal_0) ;;
  *) echo "FAIL: p130 twopkg: no dependency word table in the library (got '$DEP_SYM')" >&2; exit 1 ;;
esac
PION_CACHE_DIR="$WARM_CAS" "$PIONC" build --release --entry-symbol "$DEP_SYM" --emit-staticlib "$TP/warm.a" "$APP"
build --release --entry-symbol "$DEP_SYM" --emit-staticlib "$TP/cold.a" "$APP"
# Compare member objects, not archives: BSD ar stamps member headers with the
# archive time.
for KIND in warm cold; do
  mkdir -p "$TP/${KIND}_objs"
  (cd "$TP/${KIND}_objs" && ar x "$TP/$KIND.a")
  rm -f "$TP/${KIND}_objs"/__.SYMDEF*
  (cd "$TP/${KIND}_objs" && ls) > "$TP/$KIND.members"
  [ "$(ar t "$TP/$KIND.a" | grep -v '^__\.SYMDEF' | sort | uniq -d)" = "" ] ||
    { echo "FAIL: p130 twopkg: duplicate member names in $KIND.a" >&2; exit 1; }
done
if [ "$(grep -c '\.o$' "$TP/cold.members")" -lt 2 ] || ! cmp -s "$TP/warm.members" "$TP/cold.members"; then
  diff -u "$TP/warm.members" "$TP/cold.members" >&2 || true
  echo "FAIL: p130 twopkg: warm and cold libraries hold different objects" >&2
  exit 1
fi
while read -r OBJ; do
  if ! cmp -s "$TP/warm_objs/$OBJ" "$TP/cold_objs/$OBJ"; then
    echo "FAIL: p130 twopkg: $OBJ differs between warm and cold --entry-symbol $DEP_SYM builds" >&2
    exit 1
  fi
done < "$TP/cold.members"
printf 'int %s(int argc, char **argv);\nint main(int argc, char **argv) { return %s(argc, argv); }\n' \
  "$DEP_SYM" "$DEP_SYM" > "$TP/host.c"
"$CC_BIN" -O1 "$TP/host.c" "$TP/cold.a" "$RT_LIB" -lm -lpthread -o "$TP/host"
"$TP/host" > "$TP/host.out" 2> "$TP/host.err"
same_output "twopkg --entry-symbol $DEP_SYM" "$GEN/twopkg.expected" "$TP/host.out"
no_stderr "twopkg --entry-symbol $DEP_SYM" "$TP/host.err"
echo "p130 twopkg: --entry-symbol $DEP_SYM warm == cold objects ($(wc -l < "$TP/cold.members" | tr -d ' ')), output equals the reference"

echo "PASS: p130_real_workload_data_opts"
