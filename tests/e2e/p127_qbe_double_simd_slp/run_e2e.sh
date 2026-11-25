#!/bin/sh
# P127: strict 2 x f64 SLP in the vendored QBE (vendor/qbe/slp.h with
# spill.c / rega.c / {amd64,arm64}/emit.c / amd64/elf.c / arm64/macho.c;
# Lean: tests/lean/proofs/QbeDoubleSimdSlp.lean).
# On amd64_sysv and arm64_apple a bounded function with paired 8-byte Double
# writes to one base is replayed with each corresponding add / sub / mul /
# load / store pair as one 128-bit operation (SSE2 / NEON), keeping the
# scalar operand order, and joined with the original scalar allocation
# behind an entry test of MXCSR / FPCR: any unmasked exception runs the
# scalar graph. A packet live across a call is kept in a 16-byte frame slot.
# Verifies, for dev and --release builds of p127.pion (kernels drift: a
# field recurrence through memory on one base with a broadcast `dt` and a
# horizontal sum; orbit: the recurrence in locals, i.e. vector loop phis,
# with a subtraction; kick: a packet live across a foreign call that dirties
# every volatile vector register and the high halves of v8-v15; shear: the
# drift recurrence on two bases that may alias; the two-base kernels also run
# with both arguments naming one struct):
#   1. Bit-exact results: 16 x 16 input rows (+-0, 1, -1.5, 0.1, 4, pi, min /
#      max subnormal, min normal, max finite, +-Inf, quiet NaNs with different
#      signs and payloads, a signalling NaN) printed as IEEE-754 bit patterns
#      once with all exceptions masked and once with only the divide-by-zero
#      trap enabled (fpmode.c; no kernel divides), which selects the retained
#      scalar arm: both runs are identical, NaN payloads included, and equal
#      to the strict C reference ref.c (a NaN there only requires a NaN).
#   2. The direct-object executable and the assembled-text executable
#      (PION_NO_DIRECT_OBJ=1) print the same bytes.
#   3. On Linux x86-64 (amd64_sysv) and macOS arm64 (arm64_apple), the
#      --emit-asm text of drift / orbit / kick has the entry test
#      (stmxcsr + andl/cmpl $8064, or mrs fpcr + tst #0x9f00), the packed
#      operations (movupd / pshufd / addpd / subpd / mulpd, or ldr / str q,
#      dup / fadd / fsub / fmul .2d, faddp), a scalar arm, and in
#      kick the packet stored to and reloaded from one 16-byte aligned frame
#      slot around the call; shear stays scalar (no entry test, no packed
#      code); on Linux x86-64 the objdump listings of both
#      executables carry the same packed mnemonics in the three kernels.
#      Other hosts (no SLP) run steps 1 and 2 only.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p127_qbe_double_simd_slp"
CC_BIN="${CC:-cc}"
check() { python3 -E "$DIR/check.py" "$@"; }
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

TARGET=""
case "$(uname -s) $(uname -m)" in
  "Linux x86_64") TARGET="amd64_sysv" ;;
  "Darwin arm64") TARGET="arm64_apple" ;;
esac

# The executables come from a package whose [link] c_sources builds
# fpmode.c; the --emit-asm text (which does not link) from p127.pion alone.
APP="$TMP_DIR/app"
mkdir -p "$APP/src"
cp "$DIR/p127.pion" "$APP/src/main.pion"
cp "$DIR/fpmode.c" "$APP/fpmode.c"
cat > "$APP/pion.toml" <<'EOF'
[package]
name = "p127_app"
version = "0.1.0"

[link]
c_sources = ["fpmode.c"]
cc_flags = ["-O2"]
EOF
"$CC_BIN" -O0 -ffp-contract=off -Wall -Wextra -Werror "$DIR/ref.c" -o "$TMP_DIR/ref"
"$TMP_DIR/ref" > "$TMP_DIR/ref.out"

for MODE in release dev; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  BASE="$TMP_DIR/p127_$MODE"
  "$PIONC" build $FLAG -o "$BASE" "$APP"
  PION_NO_DIRECT_OBJ=1 "$PIONC" build $FLAG -o "${BASE}_text" "$APP"
  "$BASE" > "$BASE.out"
  "${BASE}_text" > "${BASE}_text.out"
  if ! cmp -s "$BASE.out" "${BASE}_text.out"; then
    diff -u "$BASE.out" "${BASE}_text.out" | head -20 >&2 || true
    echo "FAIL: p127 $MODE: direct-object and assembled-text executables differ" >&2
    exit 1
  fi
  if [ -n "$TARGET" ]; then
    check out "$BASE.out" "$TMP_DIR/ref.out" "1 1"
    "$PIONC" build $FLAG --emit-asm "$BASE.s" "$DIR/p127.pion"
    check asm "$BASE.s" "$TARGET"
    if [ "$TARGET" = "amd64_sysv" ] && command -v objdump >/dev/null 2>&1; then
      objdump -d --no-show-raw-insn "$BASE" > "$BASE.dis"
      objdump -d --no-show-raw-insn "${BASE}_text" > "${BASE}_text.dis"
      check objcmp "$BASE.dis" "${BASE}_text.dis"
    fi
  else
    check out "$BASE.out" "$TMP_DIR/ref.out" any
    echo "p127 $MODE: $(uname -s) $(uname -m) has no SLP target; packed-code checks skipped"
  fi
done

echo "PASS: p127_qbe_double_simd_slp"
