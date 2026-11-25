#!/bin/sh
# P114: QBE loop jump-table private spill-home store sinking
# (vendor/qbe/rega.c `sinktablehomes` / `sinkhome`;
#  Lean: tests/lean/proofs/QbeJtblEdgeSpill.lean).
# After register allocation, the shadow store of a single-definition integer
# temporary into its private spill home, in a loop jump-table block or its
# unique predecessor, becomes a `nop` and is prepended (from the register
# still holding the value after the dispatch) to the table targets that can
# read the home: only when they are at most half of the entries, each has the
# table as sole predecessor, and nothing reads the home after the original
# store. `-d R` reports `sunk homes: N` per function.
# Verifies:
#   1. p114.pion (register-hungry `match` interpreter: calls on a minority of
#      opcodes, gap / negative / out-of-range opcodes on the default entries,
#      early `break`, jumps, 0..5000 rounds): output equals ref.py exactly for
#      Native dev & --release, Wasm32 dev & --release and ASan dev & --release;
#      the native SSA of `run_vm` sinks at least one home.
#   2. gen_cfg.py fixture: `qbe -d SR` structure (check_dump.py) for
#      amd64_sysv, arm64_apple and arm64 (moved stores, sole-predecessor
#      targets, hot entries without the store, kept homes for majority /
#      late-read / multi-predecessor cases); C reference differential of
#      11 functions x 10244 inputs through `qbe --obj` and text assembly on
#      the host (x86-64 ELF or AArch64 Mach-O), with non-zero counts.
#   3. benchmarks/v2/pion/bytecode_vm.pion: dev and --release print the same
#      line as the C version; `run_vm` sinks at least one dispatch home.
#   4. An ASan + UBSan QBE (when the compiler can build one) replays every
#      QBE input of this test with halt_on_error.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p114_qbe_jtbl_edge_spill"
SRC="$DIR/p114.pion"
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC_BIN="${CC:-cc}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

if [ ! -x "$QBE" ]; then
  echo "FAIL: QBE binary not found at $QBE" >&2
  exit 1
fi

python3 -E "$DIR/ref.py" > "$TMP_DIR/expected.txt"
LINES=$(wc -l < "$TMP_DIR/expected.txt" | tr -d ' ')
if [ "$LINES" -ne 36 ]; then
  echo "FAIL: p114 reference has $LINES lines, want 36" >&2
  exit 1
fi

check() { # $1 label, $2 output file
  if ! cmp -s "$TMP_DIR/expected.txt" "$2"; then
    diff -u "$TMP_DIR/expected.txt" "$2" >&2 || true
    echo "FAIL: p114 $1" >&2
    exit 1
  fi
  echo "p114 $1 ok"
}

# sunk FILE FUNCTION-REGEX -> the `sunk homes` count of that function in a
# `qbe -d R` dump (fails when the function or the statistic is missing).
sunk() {
  python3 -E - "$1" "$2" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
parts = re.split(r'\*\*\*\* Function (\S+) \*\*\*\*', text)
hits = [(n, s) for n, s in zip(parts[1::2], parts[2::2]) if re.fullmatch(sys.argv[2], n)]
if len(hits) != 1:
    raise SystemExit(f"FAIL: p114 want one function matching {sys.argv[2]}, got {[n for n, _ in hits]}")
m = re.search(r'sunk homes: (\d+)', hits[0][1])
if m is None:
    raise SystemExit(f"FAIL: p114 no `sunk homes` statistic for {hits[0][0]}")
print(m.group(1))
PYEOF
}

# 1. Native dev / --release: exact output and a sunk home in run_vm.
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG --emit-ssa "$TMP_DIR/$MODE.ssa" -o "$TMP_DIR/p114_$MODE" "$SRC"
  "$TMP_DIR/p114_$MODE" > "$TMP_DIR/$MODE.out"
  check "native $MODE" "$TMP_DIR/$MODE.out"
  JT=$(grep -c '^[[:space:]]*jtbl ' "$TMP_DIR/$MODE.ssa") || {
    echo "FAIL: p114 $MODE SSA has no jtbl (or is unreadable)" >&2
    exit 1
  }
  "$QBE" -d R -o /dev/null "$TMP_DIR/$MODE.ssa" 2> "$TMP_DIR/$MODE.rega"
  N=$(sunk "$TMP_DIR/$MODE.rega" '\S*run_vm\S*')
  if [ "$N" -lt 1 ]; then
    echo "FAIL: p114 $MODE run_vm sinks no spill home" >&2
    exit 1
  fi
  echo "p114 native $MODE: $JT jtbl, run_vm sunk homes: $N"
done

# 2. Wasm32 dev & --release
if command -v node >/dev/null 2>&1; then
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    "$PIONC" build $FLAG --target wasm32 -o "$TMP_DIR/$MODE.wasm" "$SRC"
    node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/$MODE.wasm" > "$TMP_DIR/w$MODE.out"
    check "wasm32 $MODE" "$TMP_DIR/w$MODE.out"
  done
else
  echo "NOTE: node unavailable; skipping p114 Wasm32 checks"
fi

# 3. ASan (dev & --release). Only a compiler that cannot link a minimal ASan
# program skips this step (an error with PION_REQUIRE_SANITIZERS=1); once the
# probe passes, every compile and run below must succeed.
ASAN=0
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$TMP_DIR/asan_probe"; then
  ASAN=1
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  echo "FAIL: p114 needs ASan (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one" >&2
  exit 1
else
  echo "NOTE: $CC_BIN -fsanitize=address unavailable; skipping p114 ASan checks"
fi
# LeakSanitizer is not available everywhere (e.g. Apple Clang on macOS ARM64).
ASAN_RUN_OPTS=""
if [ "$ASAN" = 1 ] && ASAN_OPTIONS=detect_leaks=1 "$TMP_DIR/asan_probe" >/dev/null 2>&1; then
  ASAN_RUN_OPTS="detect_leaks=1"
fi
if [ "$ASAN" = 1 ]; then
  echo "p114 ASan options: ${ASAN_RUN_OPTS:-<none, no LeakSanitizer>}"
  "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o"
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/p114.o" "$SRC"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/p114.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p114_asan"
    ASAN_OPTIONS="$ASAN_RUN_OPTS" "$TMP_DIR/p114_asan" > "$TMP_DIR/asan.out"
    check "ASan ${MODE:-dev}" "$TMP_DIR/asan.out"
  done
fi

# 4. QBE fixture: -d SR structure on three targets, differential on the host.
mkdir -p "$TMP_DIR/cfg"
python3 -E "$DIR/gen_cfg.py" "$TMP_DIR/cfg"
for T in amd64_sysv arm64_apple arm64; do
  "$QBE" -t "$T" -d SR -o /dev/null "$TMP_DIR/cfg/cfg.ssa" 2> "$TMP_DIR/cfg/sr_$T.txt"
  python3 -E "$DIR/check_dump.py" "$TMP_DIR/cfg/sr_$T.txt" "$TMP_DIR/cfg/expect.txt" "$T"
done
NFUNC=$(wc -l < "$TMP_DIR/cfg/expect.txt" | tr -d ' ')
WANT=$((NFUNC * 10244))
fixture_run() { # $1 label, $2 object or assembly file
  "$CC_BIN" -O1 "$TMP_DIR/cfg/check.c" "$2" -o "$TMP_DIR/cfg/check_$1"
  "$TMP_DIR/cfg/check_$1" > "$TMP_DIR/cfg/$1.out"
  TOTAL=$(sed -n 's/^total \([0-9][0-9]*\) bad 0$/\1/p' "$TMP_DIR/cfg/$1.out")
  if [ "$TOTAL" != "$WANT" ]; then
    cat "$TMP_DIR/cfg/$1.out" >&2
    echo "FAIL: p114 fixture $1: want total $WANT bad 0" >&2
    exit 1
  fi
  ZERO=$(grep -c ' 0 [0-9a-f]*$' "$TMP_DIR/cfg/$1.out") || ZERO=0
  if [ "$ZERO" -ne 0 ]; then
    echo "FAIL: p114 fixture $1: a function ran no inputs" >&2
    exit 1
  fi
  echo "p114 fixture $1: $TOTAL inputs equal the C reference ($(tail -n 1 "$TMP_DIR/cfg/$1.out"))"
}
HOST_S="$(uname -s)"
HOST_M="$(uname -m)"
"$QBE" -o "$TMP_DIR/cfg/cfg.s" "$TMP_DIR/cfg/cfg.ssa"
fixture_run text "$TMP_DIR/cfg/cfg.s"
OBJ=0
case "$HOST_S/$HOST_M" in
  Linux/x86_64|Linux/amd64|Darwin/arm64|Darwin/aarch64) OBJ=1 ;;
esac
if [ "$OBJ" = 1 ]; then
  "$QBE" --obj -o "$TMP_DIR/cfg/cfg.o" "$TMP_DIR/cfg/cfg.ssa"
  fixture_run obj "$TMP_DIR/cfg/cfg.o"
  if ! cmp -s "$TMP_DIR/cfg/text.out" "$TMP_DIR/cfg/obj.out"; then
    diff -u "$TMP_DIR/cfg/text.out" "$TMP_DIR/cfg/obj.out" >&2 || true
    echo "FAIL: p114 fixture --obj and text assembly disagree" >&2
    exit 1
  fi
else
  echo "NOTE: no direct object route on $HOST_S/$HOST_M; text assembly only"
fi

# 5. bytecode_vm: dev == release == C, and run_vm sinks dispatch homes.
VM="$ROOT_DIR/benchmarks/v2/pion/bytecode_vm.pion"
"$CC_BIN" -O2 -o "$TMP_DIR/vm_c" "$ROOT_DIR/benchmarks/v2/c/bytecode_vm.c" -lm
"$TMP_DIR/vm_c" > "$TMP_DIR/vm_c.out"
if [ ! -s "$TMP_DIR/vm_c.out" ]; then
  echo "FAIL: p114 C bytecode_vm printed nothing" >&2
  exit 1
fi
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG --emit-ssa "$TMP_DIR/vm_$MODE.ssa" -o "$TMP_DIR/vm_$MODE" "$VM"
  "$TMP_DIR/vm_$MODE" > "$TMP_DIR/vm_$MODE.out"
  if ! cmp -s "$TMP_DIR/vm_c.out" "$TMP_DIR/vm_$MODE.out"; then
    diff -u "$TMP_DIR/vm_c.out" "$TMP_DIR/vm_$MODE.out" >&2 || true
    echo "FAIL: p114 bytecode_vm $MODE output differs from C" >&2
    exit 1
  fi
  "$QBE" -d R -o /dev/null "$TMP_DIR/vm_$MODE.ssa" 2> "$TMP_DIR/vm_$MODE.rega"
  N=$(sunk "$TMP_DIR/vm_$MODE.rega" '\S*run_vm\S*')
  if [ "$N" -lt 1 ]; then
    echo "FAIL: p114 bytecode_vm $MODE run_vm sinks no dispatch home" >&2
    exit 1
  fi
  echo "p114 bytecode_vm $MODE: $(cat "$TMP_DIR/vm_$MODE.out") (= C), run_vm sunk homes: $N"
done

# 6. ASan + UBSan QBE over every QBE input above.
if [ "$ASAN" = 1 ] && printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address,undefined -o "$TMP_DIR/ubsan_probe" 2>/dev/null \
  && "$TMP_DIR/ubsan_probe"; then
  mkdir -p "$TMP_DIR/sanq"
  # Every replay passes -t, so any default target will do.
  printf '#define Deftgt T_amd64_sysv\n' > "$TMP_DIR/sanq/config.h"
  (
    cd "$ROOT_DIR/vendor/qbe"
    for f in *.c amd64/*.c arm64/*.c rv64/*.c; do
      o="$TMP_DIR/sanq/$(printf '%s' "$f" | tr / _).o"
      "$CC_BIN" -std=c99 -O1 -g -w -fsanitize=address,undefined -fno-sanitize-recover=undefined \
        -fno-omit-frame-pointer -I "$TMP_DIR/sanq" -I . -c "$f" -o "$o"
    done
  )
  "$CC_BIN" -fsanitize=address,undefined "$TMP_DIR"/sanq/*.o -o "$TMP_DIR/sanq/qbe"
  for IN in "$TMP_DIR/dev.ssa" "$TMP_DIR/release.ssa" "$TMP_DIR/cfg/cfg.ssa" "$TMP_DIR/vm_dev.ssa" "$TMP_DIR/vm_release.ssa"; do
    for T in amd64_sysv arm64_apple; do
      ASAN_OPTIONS="${ASAN_RUN_OPTS:+$ASAN_RUN_OPTS:}halt_on_error=1" UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$TMP_DIR/sanq/qbe" -t "$T" -o "$TMP_DIR/sanq/out.s" "$IN"
      ASAN_OPTIONS="${ASAN_RUN_OPTS:+$ASAN_RUN_OPTS:}halt_on_error=1" UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$TMP_DIR/sanq/qbe" -t "$T" --obj -o "$TMP_DIR/sanq/out.o" "$IN"
    done
  done
  echo "p114 ASan+UBSan QBE: 5 inputs x {amd64_sysv, arm64_apple} x {text, --obj} clean"
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  echo "FAIL: p114 needs ASan+UBSan (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one" >&2
  exit 1
else
  echo "NOTE: $CC_BIN -fsanitize=address,undefined unavailable; skipping the sanitized QBE replay"
fi

echo "PASS: p114_qbe_jtbl_edge_spill"
