#!/bin/sh
# P78: arm64_apple large-frame 64-bit spill truncation regression.
# arm64/emit.c lowers `copy <const> -> RSlot` to `storel x17, slot` but first
# resets i->cls to Kw; when the slot offset exceeds 8*4095 (frames > 32 KB,
# x18 reserved on Apple) the store goes through `fmov ?31, ?17`, which used to
# pick the width from i->cls and emit `fmov s31, w17; str s31` — dropping the
# high 32 bits of a 64-bit pointer (pionc1 SIGBUS in a 39 KB frame).
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
: "$PIONC"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
N=20

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
SSA="$TMP_DIR/bigframe.ssa"

# $big keeps N loop-carried pointers (phi of a data symbol on the entry edge)
# live across a call, so most are spilled; the 36000-byte alloca pushes their
# spill slots past 32760 and the entry edge becomes `copy $sK -> RSlot`.
# Every value live in the loop is 64-bit, so any `fmov s31, w17` is a bug.
{
  k=0
  while [ $k -lt $N ]; do
    printf 'data $s%d = { b "s%d", b 0 }\n' "$k" "$k"
    k=$((k + 1))
  done
  echo 'function $opaque(l %x) {'
  echo '@start'
  echo '  ret'
  echo '}'
  echo 'export function w $big(l %nl) {'
  echo '@start'
  echo '  %buf =l alloc8 36000'
  echo '  storel 0, %buf'
  echo '  %z =l loadl %buf'
  echo '  jmp @loop'
  echo '@loop'
  echo '  %i =l phi @start 0, @loop %i2'
  k=0
  while [ $k -lt $N ]; do
    echo "  %p$k =l phi @start \$s$k, @loop %q$k"
    k=$((k + 1))
  done
  echo '  call $opaque(l %buf)'
  k=0
  while [ $k -lt $N ]; do
    echo "  %q$k =l add %p$k, %z"
    k=$((k + 1))
  done
  echo '  %i2 =l add %i, 1'
  echo '  %c =w csltl %i2, %nl'
  echo '  jnz %c, @loop, @done'
  echo '@done'
  echo '  %ok0 =w copy 0'
  k=0
  while [ $k -lt $N ]; do
    echo "  %e$k =w ceql %q$k, \$s$k"
    echo "  %ok$((k + 1)) =w add %ok$k, %e$k"
    k=$((k + 1))
  done
  echo "  ret %ok$N"
  echo '}'
  echo 'export function w $main() {'
  echo '@start'
  echo '  %r =w call $big(l 3)'
  echo "  %bad =w cnew %r, $N"
  echo '  ret %bad'
  echo '}'
} > "$SSA"

"$QBE" -t arm64_apple -o "$TMP_DIR/arm64.s" "$SSA"
"$QBE" -t arm64_apple --obj -o "$TMP_DIR/arm64.o" "$SSA"
test -s "$TMP_DIR/arm64.o"

# The far-slot store path must be exercised and must keep 64 bits.
if ! grep -q 'fmov	d31, x17' "$TMP_DIR/arm64.s"; then
  echo "FAIL: p78 did not exercise the far-slot 64-bit store path (no 'fmov d31, x17')" >&2
  exit 1
fi
if grep -q 'fmov	s31, w17' "$TMP_DIR/arm64.s"; then
  echo "FAIL: p78 64-bit spill truncated to 32 bits ('fmov s31, w17'):" >&2
  grep -n -B3 -A2 'fmov	s31, w17' "$TMP_DIR/arm64.s" >&2
  exit 1
fi

if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
  CC_BIN="${CC:-cc}"
  "$CC_BIN" -o "$TMP_DIR/bin_s" "$TMP_DIR/arm64.s"
  "$CC_BIN" -o "$TMP_DIR/bin_o" "$TMP_DIR/arm64.o"
  "$TMP_DIR/bin_s" || { echo "FAIL: p78 asm binary returned $?" >&2; exit 1; }
  "$TMP_DIR/bin_o" || { echo "FAIL: p78 obj binary returned $?" >&2; exit 1; }
  echo "PASS: p78_qbe_arm64_bigframe_spill (asm d31/x17, asm + --obj binaries keep all $N pointers)"
else
  echo "PASS: p78_qbe_arm64_bigframe_spill (asm d31/x17; run skipped off macOS ARM64)"
fi
