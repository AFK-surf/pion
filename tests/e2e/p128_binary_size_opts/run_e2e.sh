#!/bin/sh
# P128: Opt-Track Z2 output-size changes (runtime/pion_rt.c,
# vendor/qbe/amd64/elf.c, compiler/src/core/wasm.pion; Lean:
# tests/lean/proofs/QbeBinarySizeOpts.lean).
#   1. Pooled runtime diagnostics: panics.pion traps (dev and --release) on a
#      string slice, a missing Map key and a negative Bytes length with exactly
#      `pion panic at pion_rt.c:<line>: <message>`, SIGABRT and the output
#      before the trap; pool.c calls every user-reachable pooled panic of the
#      runtime ABI (string index, slice, Bytes length / null destination, array
#      get / set / pop, null map, missing key on an empty and a non-empty map,
#      scope_spawn, argv index) the same way; in-bounds calls return normally.
#   2. Host I/O section: hello.pion (no file I/O) and fileio.pion (fs_write /
#      fs_read) build and print the reference output. On Linux x86_64 their
#      `--emit-obj` objects are linked with `--print-gc-sections`: the linker
#      removes `.text.pion_io` for hello and keeps it for fileio.
#   3. ELF64 writer (Linux x86_64): the `--emit-obj` object of literals.pion
#      (dev and --release) shares every section name with the tail of its
#      `.rela` name in `.shstrtab` and refers to the `pion_str_<n>_hdr` /
#      `pion_cstr_<n>` literals through local section symbols (no named
#      literal symbol, none in `.strtab`). Each build below starts from its own
#      empty PION_CACHE_DIR: two direct-object builds are byte-identical; the
#      direct object and the `--emit-asm` build (assembled by `cc -c`) have
#      byte-identical allocated sections other than `.text` (the literals
#      included) with the same relocation targets, every `.text` reference to
#      a literal resolves to the same section and offset, and both link to
#      executables printing the reference output. `.text` bytes are not
#      compared: the direct encoder picks shorter forms than GAS (`test` for
#      `cmp $0`).
#   4. Wasm32: wasm_map.pion (Map[String, Int]) prints the reference output
#      under Node (dev and --release); its module (`--wasm-names`, no
#      wasm-opt) has no `__pion_map_hash` and every function body is reachable
#      from the exports, the start function and the table.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p128_binary_size_opts"
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
CC_BIN="${CC:-cc}"
RT_LIB="${PION_RT_LIB:-$ROOT_DIR/out/libpionrt.a}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
export PION_NO_WASM_OPT=1
mkdir -p "$PION_CACHE_DIR"
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is required for the Wasm32 leg of P128" >&2
  exit 1
fi
if [ ! -s "$RT_LIB" ]; then
  echo "FAIL: runtime archive $RT_LIB not found (set PION_RT_LIB)" >&2
  exit 1
fi
LINUX_X64=0
if [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "x86_64" ]; then
  LINUX_X64=1
fi

fail() {
  echo "FAIL: p128 $*" >&2
  exit 1
}

# expect_trap <name> <message> <stdout-file> <stderr-file> <rc> <expected-stdout>
expect_trap() {
  [ "$5" -eq 134 ] || { cat "$4" >&2; fail "$1 exited $5, want 134 (SIGABRT)"; }
  [ "$(cat "$3")" = "$6" ] || { cat "$3" >&2; fail "$1 stdout differs"; }
  python3 -E -c '
import re, sys
err = open(sys.argv[1], "rb").read()
want = rb"pion panic at pion_rt\.c:[0-9]+: " + re.escape(sys.argv[2].encode()) + rb"\n"
sys.exit(0 if re.fullmatch(want, err) else 1)
' "$4" "$2" || { cat "$4" >&2; fail "$1 diagnostic is not exactly '$2'"; }
  echo "p128 $1: SIGABRT, pion panic at pion_rt.c:<line>: $2"
}

# 1a. Pion programs reaching pooled diagnostics.
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  BIN="$TMP_DIR/panics_$MODE"
  "$PIONC" build $FLAG -o "$BIN" "$DIR/panics.pion"
  for CASE in "slice:string slice out of bounds" "map:map key not found" "bytes:negative bytes length"; do
    ARG=${CASE%%:*}
    MSG=${CASE#*:}
    set +e
    ( exec "$BIN" "$ARG" > "$TMP_DIR/p.out" 2> "$TMP_DIR/p.err" ) 2> /dev/null
    RC=$?
    set -e
    expect_trap "panics $MODE $ARG" "$MSG" "$TMP_DIR/p.out" "$TMP_DIR/p.err" "$RC" "mode $ARG"
  done
  OUT=$("$BIN" ok)
  [ "$OUT" = "$(printf 'mode ok\nbc 42 2')" ] || fail "panics $MODE ok printed '$OUT'"
  "$PIONC" build $FLAG --target wasm32 -o "$BIN.wasm" "$DIR/panics.pion"
  WOUT=$(node "$WASM_RT" "$BIN.wasm" ok)
  [ "$WOUT" = "$OUT" ] || fail "panics $MODE Wasm32 ok printed '$WOUT'"
  echo "p128 panics $MODE: in-bounds native and Wasm32 output 'bc 42 2'"
done

# 1b. Every user-reachable pooled panic through the runtime ABI.
"$CC_BIN" -std=c11 -O2 -I"$ROOT_DIR/runtime" "$DIR/pool.c" "$RT_LIB" -lm -lpthread -o "$TMP_DIR/pool"
[ "$("$TMP_DIR/pool" ok)" = "ok 99 42 9 9" ] || fail "pool ok printed '$("$TMP_DIR/pool" ok)'"
N=0
for CASE in \
  "str_index:string index out of bounds" \
  "slice:string slice out of bounds" \
  "bytes_length:negative bytes length" \
  "bytes_dest:null dst in bytes_copy_to_ptr" \
  "arr_get:array index out of bounds" \
  "arr_set:array set index out of bounds" \
  "arr_pop:array pop on empty array" \
  "map_null:null map or key" \
  "map_empty:map key not found" \
  "map_miss:map key not found" \
  "spawn:invalid scope_spawn" \
  "argv_index:argv index out of bounds"; do
  ARG=${CASE%%:*}
  MSG=${CASE#*:}
  set +e
  ( exec "$TMP_DIR/pool" "$ARG" > "$TMP_DIR/c.out" 2> "$TMP_DIR/c.err" ) 2> /dev/null
  RC=$?
  set -e
  expect_trap "pool $ARG" "$MSG" "$TMP_DIR/c.out" "$TMP_DIR/c.err" "$RC" ""
  N=$((N + 1))
done
[ "$N" -eq 12 ]

# 2. Programs with and without host file I/O.
"$PIONC" build --release -o "$TMP_DIR/hello" "$DIR/hello.pion"
[ "$("$TMP_DIR/hello")" = "hello, p128" ] || fail "hello output"
"$PIONC" build --release -o "$TMP_DIR/fileio" "$DIR/fileio.pion"
"$TMP_DIR/fileio" "$TMP_DIR/io.txt" > "$TMP_DIR/fileio.out"
cmp -s "$DIR/fileio.expected" "$TMP_DIR/fileio.out" || {
  diff -u "$DIR/fileio.expected" "$TMP_DIR/fileio.out" >&2 || true
  fail "fileio output differs from the reference"
}
[ "$(cat "$TMP_DIR/io.txt")" = "$(printf 'p128 line one\np128 line two')" ] || fail "fileio wrote the wrong file"
echo "p128 hello / fileio: reference output"
if [ "$LINUX_X64" -eq 1 ]; then
  for PROG in hello fileio; do
    "$PIONC" build --release --emit-obj "$TMP_DIR/$PROG.o" "$DIR/$PROG.pion"
    "$CC_BIN" "$TMP_DIR/$PROG.o" "$RT_LIB" -lm -lpthread -Wl,--gc-sections -Wl,--print-gc-sections \
      -o "$TMP_DIR/$PROG.gc" 2> "$TMP_DIR/$PROG.gc.log"
    grep -q "removing unused section '\.text\.main'" "$TMP_DIR/$PROG.gc.log" && fail "$PROG: entry collected"
    if grep -q "removing unused section '\.text\.pion_io'" "$TMP_DIR/$PROG.gc.log"; then
      GC=removed
    else
      GC=kept
    fi
    # The log is never empty: the runtime always has other unused sections.
    [ -s "$TMP_DIR/$PROG.gc.log" ] || fail "$PROG: empty --print-gc-sections log"
    case "$PROG:$GC" in
      hello:removed|fileio:kept) echo "p128 $PROG: .text.pion_io $GC by --gc-sections" ;;
      *) cat "$TMP_DIR/$PROG.gc.log" >&2; fail "$PROG: .text.pion_io $GC" ;;
    esac
  done
  [ "$("$TMP_DIR/hello.gc")" = "hello, p128" ] || fail "hello.gc output"
  "$TMP_DIR/fileio.gc" "$TMP_DIR/io2.txt" > "$TMP_DIR/fileio.gc.out"
  cmp -s "$DIR/fileio.expected" "$TMP_DIR/fileio.gc.out" || fail "fileio.gc output"
fi

# 3. ELF64 objects (QBE amd64 direct-object writer).
if [ "$LINUX_X64" -eq 1 ]; then
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    B="$TMP_DIR/lit_$MODE"
    mkdir -p "$B.cas_obj" "$B.cas_obj2" "$B.cas_asm"
    PION_CACHE_DIR="$B.cas_obj" "$PIONC" build $FLAG --emit-obj "$B.o" "$DIR/literals.pion"
    python3 -E "$DIR/check.py" elf "$B.o"
    PION_CACHE_DIR="$B.cas_obj2" "$PIONC" build $FLAG --emit-obj "$B.2.o" "$DIR/literals.pion"
    cmp "$B.o" "$B.2.o" || fail "literals $MODE: direct objects from two empty caches differ"
    PION_CACHE_DIR="$B.cas_asm" "$PIONC" build $FLAG --emit-asm "$B.s" "$DIR/literals.pion"
    [ -s "$B.s" ] || fail "literals $MODE: empty --emit-asm output"
    "$CC_BIN" -c "$B.s" -o "$B.gas.o"
    "$CC_BIN" "$B.o" "$RT_LIB" -lm -lpthread -Wl,--gc-sections -o "$B.direct"
    "$CC_BIN" "$B.gas.o" "$RT_LIB" -lm -lpthread -Wl,--gc-sections -o "$B.gas"
    python3 -E "$DIR/check.py" objcmp "$B.o" "$B.gas.o"
    for EXE in "$B.direct" "$B.gas"; do
      "$EXE" > "$EXE.out"
      cmp -s "$DIR/literals.expected" "$EXE.out" || {
        diff -u "$DIR/literals.expected" "$EXE.out" >&2 || true
        fail "literals $MODE ${EXE##*.} output differs from the reference"
      }
    done
    echo "p128 literals $MODE: direct object == --emit-asm object data and literal references, reference output"
  done
else
  "$PIONC" build --release -o "$TMP_DIR/literals" "$DIR/literals.pion"
  "$TMP_DIR/literals" > "$TMP_DIR/literals.out"
  cmp -s "$DIR/literals.expected" "$TMP_DIR/literals.out" || fail "literals output differs from the reference"
  echo "p128 literals: reference output (ELF64 object checks run on Linux x86_64)"
fi

# 4. Wasm32 Map program without the dead hash helper.
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  W="$TMP_DIR/wasm_map_$MODE.wasm"
  "$PIONC" build $FLAG --target wasm32 --wasm-names -o "$W" "$DIR/wasm_map.pion"
  python3 -E "$DIR/check.py" wasm "$W"
  node "$WASM_RT" "$W" > "$W.out"
  cmp -s "$DIR/wasm_map.expected" "$W.out" || {
    diff -u "$DIR/wasm_map.expected" "$W.out" >&2 || true
    fail "wasm_map $MODE Wasm32 output differs from the reference"
  }
  "$PIONC" build $FLAG -o "$TMP_DIR/wasm_map_$MODE" "$DIR/wasm_map.pion"
  "$TMP_DIR/wasm_map_$MODE" > "$TMP_DIR/wasm_map_$MODE.out"
  cmp -s "$DIR/wasm_map.expected" "$TMP_DIR/wasm_map_$MODE.out" || fail "wasm_map $MODE native output differs"
  echo "p128 wasm_map $MODE: Node and native output equal the reference"
done

echo "PASS: p128_binary_size_opts"
