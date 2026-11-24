#!/bin/sh
# P105: AArch64 compiler-private spill-slot pairing (Opt-Track B).
# vendor/qbe/arm64/isel.c `arm64_slotpair` turns two adjacent str/ldr (or slot
# copies) of the same integer class on adjacent spill slots (rsval >= firstspill)
# into one stp/ldp [x29, #off] in both arm64/emit.c and arm64/macho.c.
#   1. white-box unit test of arm64_slotpair (user/arg slots, ldp Rt == Rt2,
#      mixed kind/width, adjacency, alignment, imm7 range, fp/lr/sp/zr);
#   2. text asm: pairs appear where expected, never in the 4 KB frame or on
#      escaping user allocs, every ldp has distinct registers, every new pair
#      offset is w-aligned and <= 63*w;
#   3. execution: aarch64 cross + qemu when present (Linux), and on Darwin
#      ARM64 both text asm and direct Mach-O (--obj), with otool -tV checks and
#      an instruction-for-instruction comparison of the two objects' pairs.
set -eu

PIONC="${1:-}"
: "$PIONC"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$HERE/../../.." && pwd)
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
QBE_BUILD="${PION_QBE_BUILD:-$ROOT_DIR/out/qbe-build}"
CC="${CC:-cc}"
EXPECT="spill_l=3f37c02ac spill_w=8fb4082c many_l=1ab3f6f many_w=8f5c850a bigframe=3f49f4818 user_alloc=123451a vsum=3f37c030f dyn=3f49f4813"
FUNCS="spill_l spill_w many_l many_w bigframe user_alloc vsum dyn"

if [ ! -x "$QBE" ]; then
  echo "FAIL: QBE binary not found at $QBE" >&2
  exit 1
fi
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Unit test against the objects scripts/build-qbe.sh left in out/qbe-build.
if [ ! -f "$QBE_BUILD/arm64/isel.o" ]; then
  echo "FAIL: $QBE_BUILD/arm64/isel.o missing (run scripts/build-qbe.sh)" >&2
  exit 1
fi
"$CC" -std=c99 -O2 -I"$QBE_BUILD" -I"$ROOT_DIR/vendor/qbe" -c "$HERE/slotpair_unit.c" -o "$TMP_DIR/unit.o"
OBJS=$(find "$QBE_BUILD" -name '*.o' ! -path "$QBE_BUILD/main.o" | sort)
# shellcheck disable=SC2086
"$CC" "$TMP_DIR/unit.o" $OBJS -o "$TMP_DIR/unit"
"$TMP_DIR/unit"

# Lines of function $2 in asm/disassembly $1 that pair x29-relative cells
# outside the callee-save registers (x19-x28 are saved by the prologue).
fn_lines() {
  awk -v f="$2" '
    $0 ~ "^_?" f ":" { on = 1; next }
    on && /^_?[A-Za-z_][A-Za-z0-9_]*:/ { on = 0 }
    on && /end function/ { on = 0 }
    on { print }' "$1"
}
new_pairs() {
  fn_lines "$1" "$2" | grep -E "(ldp|stp)[[:space:]]+$3([0-9]|1[0-8]), $3[0-9]+, \[x29, #" || true
}
check_asm() { # $1 asm/disassembly, $2 label
  for spec in spill_l:ldp:x spill_w:ldp:w many_l:stp:x many_l:ldp:x many_w:stp:w many_w:ldp:w vsum:ldp:x dyn:ldp:x; do
    f=${spec%%:*}; rest=${spec#*:}; op=${rest%%:*}; r=${rest#*:}
    if ! new_pairs "$1" "$f" "$r" | grep -q "$op"; then
      echo "FAIL[$2]: no private-slot $op of $r registers in $f" >&2
      fn_lines "$1" "$f" >&2
      exit 1
    fi
  done
  for f in bigframe user_alloc; do
    if [ -n "$(new_pairs "$1" "$f" x)$(new_pairs "$1" "$f" w)" ]; then
      echo "FAIL[$2]: $f must not pair (imm7 overflow / user alloc)" >&2
      fn_lines "$1" "$f" >&2
      exit 1
    fi
  done
  for f in $FUNCS; do
    { new_pairs "$1" "$f" x; new_pairs "$1" "$f" w; } | sed -E 's/.*(ldp|stp)[[:space:]]+([xw])([0-9]+), [xw]([0-9]+), \[x29, #(0x[0-9a-f]+|[0-9]+)\].*/\1 \2 \3 \4 \5/'
  done | while read -r op r a b off; do
    w=8; [ "$r" = w ] && w=4
    off=$((off)) # otool prints hex offsets
    if [ "$op" = ldp ] && [ "$a" = "$b" ]; then
      echo "FAIL[$2]: ldp with Rt == Rt2 ($r$a)" >&2; exit 1
    fi
    if [ $((off % w)) -ne 0 ] || [ $((off / w)) -gt 63 ]; then
      echo "FAIL[$2]: pair offset $off out of imm7 range for $r" >&2; exit 1
    fi
  done
  echo "[PASS] $2: private spill-slot stp/ldp shapes"
}

"$QBE" -t arm64 -o "$TMP_DIR/pairs.s" "$HERE/pairs.ssa"
check_asm "$TMP_DIR/pairs.s" "arm64 text asm"
# The prologue of a > 4 KB frame stays on single str (no pair offsets > 504).
if fn_lines "$TMP_DIR/pairs.s" bigframe | grep -qE "(ldp|stp)[[:space:]]+[xw][0-9]+, [xw][0-9]+, \[x29, #(5[1-9][0-9]|[6-9][0-9][0-9]|[0-9]{4,})\]"; then
  echo "FAIL: bigframe pair offset beyond imm7" >&2
  exit 1
fi

UNAME_M="$(uname -m)"
UNAME_S="$(uname -s)"
if [ "$UNAME_S" = Darwin ] && { [ "$UNAME_M" = arm64 ] || [ "$UNAME_M" = aarch64 ]; }; then
  "$QBE" -t arm64_apple -o "$TMP_DIR/pairs_apple.s" "$HERE/pairs.ssa"
  check_asm "$TMP_DIR/pairs_apple.s" "arm64_apple text asm"
  "$CC" -c "$TMP_DIR/pairs_apple.s" -o "$TMP_DIR/pairs_asm.o"
  "$QBE" -t arm64_apple --obj -o "$TMP_DIR/pairs_obj.o" "$HERE/pairs.ssa"
  for v in asm obj; do
    "$CC" -O2 "$HERE/driver.c" "$TMP_DIR/pairs_$v.o" -o "$TMP_DIR/run_$v"
    OUT="$("$TMP_DIR/run_$v")"
    if [ "$OUT" != "$EXPECT" ]; then
      echo "FAIL: arm64_apple $v execution: $OUT" >&2
      echo "      expected:            $EXPECT" >&2
      exit 1
    fi
    echo "[PASS] arm64_apple $v execution: $OUT"
  done
  if command -v otool >/dev/null 2>&1; then
    for v in asm obj; do
      otool -tV "$TMP_DIR/pairs_$v.o" | sed -E 's/^[0-9a-f]+[[:space:]]+//' > "$TMP_DIR/pairs_$v.dis"
    done
    check_asm "$TMP_DIR/pairs_obj.dis" "Mach-O --obj (otool -tV)"
    # The direct encoder and the system assembler agree on every pair.
    for f in $FUNCS; do
      for v in asm obj; do
        { new_pairs "$TMP_DIR/pairs_$v.dis" "$f" x; new_pairs "$TMP_DIR/pairs_$v.dis" "$f" w; } > "$TMP_DIR/$f.$v"
      done
      if ! cmp -s "$TMP_DIR/$f.asm" "$TMP_DIR/$f.obj"; then
        echo "FAIL: $f: Mach-O --obj pairs differ from assembled text" >&2
        diff "$TMP_DIR/$f.asm" "$TMP_DIR/$f.obj" >&2 || true
        exit 1
      fi
    done
    echo "[PASS] Mach-O --obj stp/ldp encodings == assembler's"
  fi
elif [ "$UNAME_S" = Linux ] && { [ "$UNAME_M" = aarch64 ] || [ "$UNAME_M" = arm64 ]; }; then
  "$CC" -O2 "$HERE/driver.c" "$TMP_DIR/pairs.s" -o "$TMP_DIR/run_arm64"
  OUT="$("$TMP_DIR/run_arm64")"
  if [ "$OUT" != "$EXPECT" ]; then
    echo "FAIL: linux arm64 native execution: $OUT" >&2
    echo "      expected:                   $EXPECT" >&2
    exit 1
  fi
  echo "[PASS] linux arm64 native execution: $OUT"
  if command -v objdump >/dev/null 2>&1; then
    # The assembler's encoding of every pair, disassembled back, keeps its shape.
    objdump -d --no-show-raw-insn "$TMP_DIR/run_arm64" \
      | sed -E 's/^[[:space:]]*[0-9a-f]+:[[:space:]]+//; s/^([a-z]+)[[:space:]]+/\1\t/; s/<([A-Za-z_0-9]+)>:$/\1:/; s/^[0-9a-f]+ //' \
      > "$TMP_DIR/run_arm64.dis"
    check_asm "$TMP_DIR/run_arm64.dis" "linux arm64 objdump"
  fi
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 && command -v qemu-aarch64 >/dev/null 2>&1; then
  aarch64-linux-gnu-gcc -static -O2 "$HERE/driver.c" "$TMP_DIR/pairs.s" -o "$TMP_DIR/run_arm64"
  OUT="$(qemu-aarch64 "$TMP_DIR/run_arm64")"
  if [ "$OUT" != "$EXPECT" ]; then
    echo "FAIL: aarch64 (qemu) execution: $OUT" >&2
    exit 1
  fi
  echo "[PASS] aarch64 qemu execution: $OUT"
else
  echo "[SKIP] P105 execution: not AArch64 and no aarch64-linux-gnu-gcc + qemu-aarch64 (text-asm checks only)"
fi
echo "P105 arm64 private spill-slot pairing: OK"
