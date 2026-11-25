#!/bin/sh
# P111: AArch64 address folding in vendor/qbe/arm64/isel.c `seladdr`
# (Opt-Track H, Lean: tests/lean/proofs/QbeArm64AddrOpts.lean).
#   localaddr  fixed local allocs and their constant, 4-byte aligned in-object
#              offsets (inside the local area, never a private spill slot)
#              stay `SLOT(...)`: `[x29, #off]` without `add x, x29, #off`;
#              offsets beyond the scaled imm12 range or not a multiple of the
#              access width fall back to a register address (fixarg /
#              me_fixarg `s % sz`), `slot - k` never folds;
#   imm9       a single-use `add base, -k` / `sub base, k` (1 <= k <= 256)
#              becomes `ldur` / `stur [base, #-k]` for every width and
#              extension; -257 and multi-use addresses keep the register.
#   1. text asm (arm64 + arm64_apple) shapes of addr.ssa, and 4,608 negative
#      offsets in the generated matrix (matrix.py: 256 offsets x 18 forms,
#      plus 112 local-slot cases);
#   2. constants (loadcon): every W/X logical immediate (6,636) as
#      `orr rd, zr, #imm` plus the movz/movn edges (`w -65536` -> movn);
#   3. Mach-O --obj == `.s -> assembler` __text byte for byte for addr.ssa,
#      the matrix and the constants (system cc on Darwin, clang
#      --target=arm64-apple-macos12 elsewhere); Linux ARM64 ELF matrix and
#      constant text (clang) == Mach-O text; GNU as == clang ELF bytes;
#   4. execution: Darwin ARM64 (.s and --obj), native Linux AArch64, or
#      aarch64 cross + qemu.
# An assembler is "missing" (SKIP) only if it cannot assemble a lone `nop`;
# after that probe every real assembly must succeed.
set -eu

PIONC="${1:-}"
: "$PIONC"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$HERE/../../.." && pwd)
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC="${CC:-cc}"
EXPECT="local_struct=12345699e local_array=13ec bigframe=20406092b4 unaligned=30052 sub_mid=2a
hdr_w=5eed1234 neg_loads=ee9c49f52e4f650 neg_257=ffffffffffffffe6 neg_twice=be99744f2a05e0c0 mem=34c5fd20bbe6806c"
NMATRIX=4608

if [ ! -x "$QBE" ]; then
  echo "FAIL: QBE binary not found at $QBE" >&2
  exit 1
fi
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

fn_lines() { # $1 asm, $2 function
  awk -v f="$2" '
    $0 ~ "^_?" f ":" { on = 1; next }
    on && /^_?[A-Za-z_][A-Za-z0-9_]*:/ { on = 0 }
    on && /end function/ { on = 0 }
    on { print }' "$1"
}
count() { # $1 asm, $2 function, $3 ERE
  fn_lines "$1" "$2" | grep -cE "$3" || true
}
fail() { # $1 asm, $2 function, $3 message
  echo "FAIL[$LABEL]: $2: $3" >&2
  fn_lines "$1" "$2" >&2
  exit 1
}
NEG='\[x[0-9]+, #-[0-9]+\]'
FP_ADD='add[[:space:]]+x[0-9]+, x29, #'
check_asm() { # $1 asm, $2 label
  LABEL=$2
  # One `add x0, x29, #16` passes the escaping address; every field access
  # addresses x29 directly.
  for f in local_struct local_array; do
    [ "$(count "$1" "$f" "$FP_ADD")" -eq 1 ] || fail "$1" "$f" "expected exactly one add x, x29 (the escaping argument)"
  done
  [ "$(count "$1" local_struct '\[x29, #?(16|20|24|32|40)\]')" -eq 10 ] || fail "$1" local_struct "field accesses are not [x29, #off]"
  [ "$(count "$1" local_array '\[x29, #?(16|20|24|76)\]')" -eq 8 ] || fail "$1" local_array "element accesses are not [x29, #off]"
  # > 4095*8: register address; the small offset still folds.
  [ "$(count "$1" bigframe '\[x29, #?24\]')" -eq 2 ] || fail "$1" bigframe "low field must fold"
  [ "$(count "$1" bigframe '\[x1[78]\]')" -eq 2 ] || fail "$1" bigframe "32776 must go through x16/x17/x18"
  # s % sz != 0: no [x29, #20] / [x29, #28] 8-byte access.
  if [ "$(count "$1" unaligned '(ldr|str)[[:space:]]+x[0-9]+, \[x29, #?(20|28)\]')" -ne 0 ]; then
    fail "$1" unaligned "misaligned 8-byte slot access must use a register address"
  fi
  [ "$(count "$1" unaligned "$FP_ADD"'(20|28)')" -eq 4 ] || fail "$1" unaligned "missing Oaddr fallback"
  # slot - 8 stays a subtraction.
  # slot - 8 stays a subtraction: the load reads [p - 8], never the field
  # p + 8 at [x29, #24] (what folding `sub` as `add` would select).
  [ "$(count "$1" sub_slot 'sub[[:space:]]+x[0-9]+, x[0-9]+, #8')" -eq 1 ] || fail "$1" sub_slot "slot - 8 must not fold"
  [ "$(count "$1" sub_slot 'ldr[[:space:]]+x[0-9]+, \[x29, #?24\]')" -eq 0 ] || fail "$1" sub_slot "slot - 8 folded as slot + 8"
  [ "$(count "$1" sub_slot 'ldr[[:space:]]+x[0-9]+, \[x[0-9]+\]')" -eq 1 ] || fail "$1" sub_slot "slot - 8 must load through a register"
  [ "$(count "$1" sub_mid 'ldr[[:space:]]+x0, \[x29, #?24\]')" -eq 1 ] || fail "$1" sub_mid "(p + 16) - 8 must read p + 8"
  [ "$(count "$1" hdr_w 'ldr[[:space:]]+w0, \[x0, #-24\]')" -eq 1 ] || fail "$1" hdr_w "no ldur w0, [x0, #-24]"
  [ "$(count "$1" hdr_w 'sub[[:space:]]')" -eq 0 ] || fail "$1" hdr_w "sub left behind"
  [ "$(count "$1" neg_loads "$NEG")" -eq 10 ] || fail "$1" neg_loads "expected 10 negative-offset loads"
  for o in 1 2 24 26 255 256 248 244 64 72; do
    [ "$(count "$1" neg_loads "#-$o\]")" -eq 1 ] || fail "$1" neg_loads "missing #-$o"
  done
  [ "$(count "$1" neg_loads '(add|sub)[[:space:]]+x[0-9]+, x[0-9]+, #')" -eq 0 ] || fail "$1" neg_loads "address arithmetic left behind"
  [ "$(count "$1" neg_stores "$NEG")" -eq 6 ] || fail "$1" neg_stores "expected 6 negative-offset stores"
  for s in 'strb[[:space:]]+w1, \[x0, #-1\]' 'strh[[:space:]]+w1, \[x0, #-4\]' 'str[[:space:]]+w1, \[x0, #-40\]' \
           'str[[:space:]]+x2, \[x0, #-256\]' 'str[[:space:]]+s0, \[x0, #-100\]' 'str[[:space:]]+d1, \[x0, #-200\]'; do
    [ "$(count "$1" neg_stores "$s")" -eq 1 ] || fail "$1" neg_stores "missing $s"
  done
  [ "$(count "$1" neg_257 "$NEG")" -eq 0 ] || fail "$1" neg_257 "-257 is outside imm9"
  [ "$(count "$1" neg_257 'sub[[:space:]]+x[0-9]+, x[0-9]+, #257')" -eq 2 ] || fail "$1" neg_257 "expected two sub #257"
  [ "$(count "$1" neg_twice "$NEG")" -eq 0 ] || fail "$1" neg_twice "multi-use address must stay a register"
  echo "[PASS] $2: x29 slot and ldur/stur shapes"
}
check_matrix() { # $1 asm, $2 label
  n=$(grep -cE "$NEG" "$1" || true)
  if [ "$n" -ne "$NMATRIX" ]; then
    echo "FAIL[$2]: $n negative-offset accesses in the matrix, expected $NMATRIX" >&2
    exit 1
  fi
  echo "[PASS] $2: matrix has $n negative-offset accesses"
}

python3 -I "$HERE/matrix.py" gen "$TMP_DIR/matrix.ssa"
for t in arm64 arm64_apple; do
  "$QBE" -t "$t" -o "$TMP_DIR/addr_$t.s" "$HERE/addr.ssa"
  check_asm "$TMP_DIR/addr_$t.s" "$t text asm"
  "$QBE" -t "$t" -o "$TMP_DIR/matrix_$t.s" "$TMP_DIR/matrix.ssa"
  check_matrix "$TMP_DIR/matrix_$t.s" "$t text asm"
done

check_run() { # $1 label, $2 output
  if [ "$2" != "$EXPECT" ]; then
    echo "FAIL: $1 execution:" >&2
    printf '%s\n' "$2" >&2
    echo "expected:" >&2
    printf '%s\n' "$EXPECT" >&2
    exit 1
  fi
  echo "[PASS] $1 execution"
}
same_text() { # $1 obj a, $2 obj b, $3 label
  python3 -I "$HERE/matrix.py" text "$1" "$TMP_DIR/a.bin"
  python3 -I "$HERE/matrix.py" text "$2" "$TMP_DIR/b.bin"
  if ! cmp -s "$TMP_DIR/a.bin" "$TMP_DIR/b.bin"; then
    echo "FAIL: $3: executable bytes differ ($(wc -c < "$TMP_DIR/a.bin") vs $(wc -c < "$TMP_DIR/b.bin") B)" >&2
    cmp "$TMP_DIR/a.bin" "$TMP_DIR/b.bin" >&2 || true
    exit 1
  fi
  echo "[PASS] $3: $(wc -c < "$TMP_DIR/a.bin" | tr -d ' ') B identical"
}
imm9_words() { # $1 obj
  python3 -I "$HERE/matrix.py" text "$1" "$TMP_DIR/w.bin"
  python3 -I "$HERE/matrix.py" imm9 "$TMP_DIR/w.bin"
}

UNAME_M="$(uname -m)"
UNAME_S="$(uname -s)"
IS_DARWIN_ARM64=0
if [ "$UNAME_S" = Darwin ] && { [ "$UNAME_M" = arm64 ] || [ "$UNAME_M" = aarch64 ]; }; then
  IS_DARWIN_ARM64=1
fi

# An assembler counts as present only if it assembles a lone `nop`; once the
# probe passes, every real assembly below must succeed (set -e), never SKIP.
printf '\tnop\n' > "$TMP_DIR/probe.s"
APPLE_AS=""
if [ "$IS_DARWIN_ARM64" = 1 ]; then
  APPLE_AS="$CC -c"
elif command -v clang >/dev/null 2>&1 \
&& clang --target=arm64-apple-macos12 -c "$TMP_DIR/probe.s" -o "$TMP_DIR/probe_m.o" 2>/dev/null; then
  APPLE_AS="clang --target=arm64-apple-macos12 -c"
fi
ELF_CLANG=0
if command -v clang >/dev/null 2>&1 \
&& clang --target=aarch64-linux-gnu -c "$TMP_DIR/probe.s" -o "$TMP_DIR/probe_e.o" 2>/dev/null; then
  ELF_CLANG=1
fi
GAS=0
if command -v aarch64-linux-gnu-as >/dev/null 2>&1 \
&& aarch64-linux-gnu-as -o "$TMP_DIR/probe_g.o" "$TMP_DIR/probe.s" 2>/dev/null; then
  GAS=1
fi

# Constant materialization (loadcon): every W/X logical immediate as
# `orr rd, zr, #imm`, and the movz/movn edges; `w -65536` must be spelled
# `movn w0, #65535` (a `mov` alias may assemble as movz ..., lsl #16).
python3 -I "$HERE/matrix.py" consts "$TMP_DIR/consts.ssa"
for t in arm64 arm64_apple; do
  "$QBE" -t "$t" -o "$TMP_DIR/consts_$t.s" "$TMP_DIR/consts.ssa"
  if ! grep -qE 'movn[[:space:]]+w0, #65535$' "$TMP_DIR/consts_$t.s"; then
    echo "FAIL[$t]: w -65536 is not spelled movn w0, #65535" >&2
    exit 1
  fi
done
echo "[PASS] text asm: w -65536 -> movn w0, #65535"

# Mach-O --obj == `.s -> assembler` __text, byte for byte.
if [ -n "$APPLE_AS" ]; then
  for c in addr matrix consts; do
    src="$TMP_DIR/$c.ssa"
    [ "$c" = addr ] && src="$HERE/addr.ssa"
    $APPLE_AS "$TMP_DIR/${c}_arm64_apple.s" -o "$TMP_DIR/${c}_asm.o"
    "$QBE" -t arm64_apple --obj -o "$TMP_DIR/${c}_obj.o" "$src"
    same_text "$TMP_DIR/${c}_obj.o" "$TMP_DIR/${c}_asm.o" "$c: Mach-O --obj vs .s -> $APPLE_AS __text"
  done
  n=$(imm9_words "$TMP_DIR/matrix_obj.o")
  [ "$n" -eq "$NMATRIX" ] || { echo "FAIL: --obj matrix has $n ldur/stur imm9 words, expected $NMATRIX" >&2; exit 1; }
  m=$(imm9_words "$TMP_DIR/addr_obj.o")
  [ "$m" -eq 17 ] || { echo "FAIL: --obj addr.ssa has $m ldur/stur imm9 words, expected 17" >&2; exit 1; }
  echo "[PASS] Mach-O --obj: $n + $m negative ldur/stur words"
else
  echo "[SKIP] no Mach-O arm64 assembler (--obj byte parity)"
fi

# Linux ARM64 ELF. addr.ssa is not compared with Mach-O: its store fallbacks
# use x18 on Linux and x17 on Apple, where x18 is the platform register.
if [ "$ELF_CLANG" = 1 ]; then
  for c in addr matrix consts; do
    clang --target=aarch64-linux-gnu -c "$TMP_DIR/${c}_arm64.s" -o "$TMP_DIR/${c}_elf.o"
  done
  n=$(imm9_words "$TMP_DIR/matrix_elf.o")
  m=$(imm9_words "$TMP_DIR/addr_elf.o")
  if [ "$n" -ne "$NMATRIX" ] || [ "$m" -ne 17 ]; then
    echo "FAIL: clang ELF: $n + $m negative ldur/stur words, expected $NMATRIX + 17" >&2
    exit 1
  fi
  echo "[PASS] clang aarch64-linux-gnu: $NMATRIX + 17 negative ldur/stur words"
  if [ -n "$APPLE_AS" ]; then
    for c in matrix consts; do
      same_text "$TMP_DIR/${c}_elf.o" "$TMP_DIR/${c}_obj.o" "$c: Linux ARM64 ELF text vs Mach-O --obj"
    done
  fi
else
  echo "[SKIP] no clang for aarch64-linux-gnu (ELF checks)"
fi
if [ "$GAS" = 1 ]; then
  # GNU as must pick the same encodings (unscaled ldur/stur, orr, movn).
  for c in addr matrix consts; do
    aarch64-linux-gnu-as -o "$TMP_DIR/${c}_gas.o" "$TMP_DIR/${c}_arm64.s"
  done
  n=$(imm9_words "$TMP_DIR/matrix_gas.o")
  m=$(imm9_words "$TMP_DIR/addr_gas.o")
  if [ "$n" -ne "$NMATRIX" ] || [ "$m" -ne 17 ]; then
    echo "FAIL: GNU as: $n + $m negative ldur/stur words, expected $NMATRIX + 17" >&2
    exit 1
  fi
  if [ "$ELF_CLANG" = 1 ]; then
    for c in addr matrix consts; do
      same_text "$TMP_DIR/${c}_gas.o" "$TMP_DIR/${c}_elf.o" "$c: GNU as vs clang aarch64 ELF text"
    done
  fi
  echo "[PASS] GNU as aarch64: $NMATRIX + 17 negative ldur/stur words"
fi

# Execution.
if [ "$IS_DARWIN_ARM64" = 1 ]; then
  for v in asm obj; do
    "$CC" -O2 "$HERE/driver.c" "$TMP_DIR/addr_$v.o" -o "$TMP_DIR/run_$v"
    out=$("$TMP_DIR/run_$v")
    check_run "arm64_apple $v" "$out"
  done
  if command -v otool >/dev/null 2>&1; then
    for v in asm obj; do
      n=$(otool -tV "$TMP_DIR/addr_$v.o" | grep -cE '(ldur|stur)[a-z]*[[:space:]].*#-' || true)
      [ "$n" -eq 17 ] || { echo "FAIL: otool $v: $n ldur/stur in addr.ssa, expected 17" >&2; exit 1; }
    done
    echo "[PASS] otool -tV: 17 ldur/stur in both objects"
  fi
elif [ "$UNAME_S" = Linux ] && { [ "$UNAME_M" = aarch64 ] || [ "$UNAME_M" = arm64 ]; }; then
  "$CC" -O2 "$HERE/driver.c" "$TMP_DIR/addr_arm64.s" -o "$TMP_DIR/run_arm64"
  out=$("$TMP_DIR/run_arm64")
  check_run "linux arm64 native" "$out"
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 && command -v qemu-aarch64 >/dev/null 2>&1; then
  aarch64-linux-gnu-gcc -static -O2 "$HERE/driver.c" "$TMP_DIR/addr_arm64.s" -o "$TMP_DIR/run_arm64"
  out=$(qemu-aarch64 "$TMP_DIR/run_arm64")
  check_run "aarch64 qemu" "$out"
else
  echo "[SKIP] P111 execution: not AArch64 and no aarch64-linux-gnu-gcc + qemu-aarch64"
fi
echo "P111 arm64 local-slot, imm9 address folding and constant parity: OK"
