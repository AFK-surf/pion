#!/bin/sh
# P120: Microsoft x64 frames in QBE `amd64_win`
# (Lean: tests/lean/proofs/QbeWin64XmmCalleeSaved.lean).
#   amd64/winabi.c / targ.c   only xmm0..xmm5 are caller-saved
#             (`amd64_winabi_rsave`), values live across calls may stay in
#             xmm6..xmm14; vastart addresses the caller's home slot; call
#             return / argument register counts fixed;
#   amd64/emit.c   `winabi_prologue`: pushes, one `subq` (pages probed below
#             %rsp first), `movq %rsp, %rbp` (frame offset 0), 128-bit `movups`
#             saves of the used xmm6..xmm14 and the emitter's xmm15 scratch
#             (`winabi_uses_xmm15`), all described by `.seh_*` directives
#             (.pdata / .xdata); %rsp 16-byte aligned after every prologue;
#             epilogues restore from the frame base, `leaq fsz(%rbp), %rsp` /
#             `addq`, pops;
#   {amd64,arm64,rv64}/isel.c   fixed allocs laid out from largest alignment
#             down and the slot area padded to the max alloc alignment (an
#             alloc16 after an alloc4, or alloc8 after alloc4 in top-down
#             frames, used to land 4 bytes off).
# Verifies:
#   1. gen_il.py fixture.ssa, 25 Win64 functions: a leaf with > 18 live
#      doubles, stack arguments and an alloc16 slot; a non-leaf keeping 10
#      doubles across two calls; varargs; a dynamic alloca; 8 KB frames (leaf
#      %rsp and non-leaf %rbp, probed); the three xmm15 scratch forms; a
#      function touching only xmm0..xmm5; mixed alloc4 / alloc8 / alloc16;
#      dynamic allocas behind 0..7 pushed GPRs; the call-site %rsp of callees
#      (p120_rsp). check_frames.py checks the prologue / epilogue shape, the
#      saved set (exactly the xmm6..xmm15 the body uses), disjoint 16-byte
#      aligned save cells clear of every frame access, alignment, matching
#      restores and pops; 10 mutants (dropped / moved / overlapping restore,
#      missing save, wrong addq, missing dynalloc reset, undescribed push,
#      misaligned frame, lying .seh_savexmm, the pre-fix output) are rejected.
#   2. Real execution on x86-64 hosts (Linux: the same text assembled as ELF,
#      to_elf.py only rewrites COFF section directives and drops .seh_*;
#      Windows: as is): harness.S fills all 10 of xmm6..xmm15 with distinct
#      128-bit patterns and rbx rbp rdi rsi r12..r15 with patterns, makes a
#      Win64 call (shadow space, stack arguments, aligned %rsp) and the C
#      driver checks the 160 bytes of xmm6..xmm15, the GPRs, %rsp and the
#      result (which folds alloc16 / dynamic-alloca addresses mod 16 and the
#      callee entry %rsp mod 16) bit for bit against gen_il.py's Python
#      reference, 3 seeds per case; restore and misalignment mutants fail.
#   2b. With PE/COFF binutils (MSYS2 on Windows, mingw-w64 elsewhere;
#      PION_REQUIRE_COFF=1 to insist): check_unwind.py decodes `objdump -x`
#      .pdata / .xdata of every framed function and matches the unwind codes
#      to the prologue instructions; a lying .seh_savexmm is caught.
#   3. nbody / spectralnorm / mandelbrot_mt --release SSA and the bootstrap
#      seed (the whole compiler): every amd64_win function passes
#      check_frames.py; amd64_sysv has no xmm saves.
#   4. An ASan + UBSan QBE replays every input above for amd64_win, amd64_sysv
#      (text and --obj), arm64 and arm64_apple with output equal to out/qbe.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p120_win64_xmm_callee_saved"
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC_BIN="${CC:-cc}"
command -v "$CC_BIN" >/dev/null 2>&1 || CC_BIN=gcc
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"
fail() {
  echo "FAIL: p120 $*" >&2
  exit 1
}
[ -x "$QBE" ] || fail "QBE binary not found at $QBE"

F="$TMP_DIR/fix dir"
python3 -E "$DIR/gen_il.py" "$F"
[ "$(wc -l < "$F/expect.txt" | tr -d ' ')" -eq 25 ] || fail "expect.txt length"
NCALLS=$(sed -n 's/^#define P120_NCALLS \([0-9]*\)$/\1/p' "$F/cases.h")
[ "$NCALLS" -eq 198 ] || fail "cases.h: $NCALLS calls, want 198"

# 1. Structure of the amd64_win text, default (no unwind directives, what
# MinGW builds use) and --seh (MSVC / lld-link builds): the same layout.
"$QBE" -t amd64_win -o "$TMP_DIR/win.s" "$F/fixture.ssa"
"$QBE" --seh -t amd64_win -o "$TMP_DIR/winseh.s" "$F/fixture.ssa"
python3 -E "$DIR/check_frames.py" "$TMP_DIR/win.s" "$F/expect.txt" --report "$TMP_DIR/frames.txt"
python3 -E "$DIR/check_frames.py" "$TMP_DIR/winseh.s" "$F/expect.txt" --seh --report "$TMP_DIR/frames_seh.txt"
cmp "$TMP_DIR/frames.txt" "$TMP_DIR/frames_seh.txt" || fail "--seh changed a frame"
python3 -E - "$TMP_DIR/winseh.s" "$TMP_DIR/win.s" <<'PYEOF' \
  || fail "--seh text minus its .seh_* lines and COMDAT key differs from the default text"
import re, sys
# Normalize `--seh`'s inline COFF COMDAT (`.section .text$sym,"xr",one_only,sym`)
# to the default MinGW form (`.section .text$sym,"xr"` + `.linkonce one_only`)
# and drop `.seh_*` directives: every instruction in every function must match.
comdat_re = re.compile(rb'^(\.section \.(?:text|data|bss)\$([^,]+),"[a-z]+"),one_only,\2(\r?\n)$')
seh = []
for ln in open(sys.argv[1], 'rb'):
    if ln.lstrip().startswith(b'.seh_'):
        continue
    m = comdat_re.match(ln)
    if m:
        nl = m.group(3)
        seh.append(m.group(1) + nl)
        seh.append(b'.linkonce one_only' + nl)
    else:
        seh.append(ln)
base = list(open(sys.argv[2], 'rb'))
if seh != base:
    raise SystemExit(1)
PYEOF
if grep -q '\.seh_' "$TMP_DIR/win.s"; then fail "default amd64_win text has .seh_* directives"; fi
if python3 -E "$DIR/check_frames.py" "$TMP_DIR/win.s" "$F/expect.txt" --seh > /dev/null; then
  fail "check_frames.py --seh accepted text without unwind directives"
fi
if python3 -E "$DIR/check_frames.py" "$TMP_DIR/winseh.s" "$F/expect.txt" > /dev/null; then
  fail "check_frames.py accepted .seh_* directives without --seh"
fi
# dynamic allocations behind 1, 3 and 5 pushed GPRs (plus %rbp) are covered
for N in 1 3 5; do
  awk -v n="$N" '$1 ~ /^p120_dynpush/ && $4 == n {f = 1} END {exit !f}' "$TMP_DIR/frames.txt" \
    || fail "no p120_dynpush function with $N pushed GPRs"
done
NMUT=0
mutants() { # $1 text, $2 suffix, $3 check_frames mode flag (or ""), then kinds
  src=$1 sfx=$2 mode=$3
  shift 3
  for K in "$@"; do
    python3 -E "$DIR/mutate.py" "$K" "$src" "$TMP_DIR/mut_$K$sfx.s" || fail "mutate.py $K$sfx"
    # shellcheck disable=SC2086
    if python3 -E "$DIR/check_frames.py" "$TMP_DIR/mut_$K$sfx.s" "$F/expect.txt" $mode > "$TMP_DIR/mut_$K$sfx.log"; then
      fail "check_frames.py accepted mutant $K$sfx"
    fi
    grep -q '^FAIL: check_frames' "$TMP_DIR/mut_$K$sfx.log" || fail "mutant $K$sfx: no checker diagnostic"
    NMUT=$((NMUT + 1))
  done
}
mutants "$TMP_DIR/win.s" "" "" norestore nosave15 moved overlap badadd nodynreset misalign nosave
mutants "$TMP_DIR/winseh.s" _seh --seh norestore nosave15 moved overlap badadd nodynreset nosehpush misalign sehlie nosave
[ "$NMUT" -eq 18 ] || fail "$NMUT mutants, want 18"
echo "p120 check_frames: default + --seh fixture OK, $NMUT mutants rejected"

# 2. Execute on x86-64 hosts.
HOST_S="$(uname -s)"
HOST_M="$(uname -m)"
RUN=""
case "$HOST_S/$HOST_M" in
  Linux/x86_64|Linux/amd64) RUN=elf ;;
  MINGW*/x86_64|MSYS*/x86_64|CYGWIN*/x86_64) RUN=pe ;;
esac
# Discover Clang (for `--seh` associative COFF COMDAT assembly) and lld-link
# (for linked PE32+ `/OPT:REF` verification), including standard Windows LLVM
# install paths used alongside MSYS2 (matching p98_section_gc).
CLANG_BIN=""
printf '.section .text$p,"xr",one_only,p\n.globl p\np:\n\tret\n' > "$TMP_DIR/clang_probe.s"
for cand in clang "/c/Program Files/LLVM/bin/clang.exe"; do
  _cbin=""
  if command -v "$cand" >/dev/null 2>&1; then
    _cbin="$(command -v "$cand")"
  elif [ -x "$cand" ]; then
    _cbin="$cand"
  fi
  if [ -n "$_cbin" ]; then
    if "$_cbin" --target=x86_64-pc-windows-msvc -c "$TMP_DIR/clang_probe.s" -o "$TMP_DIR/clang_probe.obj" 2>/dev/null; then
      CLANG_BIN="$_cbin"
      break
    fi
  fi
done
LLD_LINK=""
for cand in lld-link lld-link-21 lld-link-20 lld-link-19 lld-link-18 \
    /usr/lib/llvm-21/bin/lld-link /usr/lib/llvm-19/bin/lld-link /usr/lib/llvm-18/bin/lld-link \
    "/c/Program Files/LLVM/bin/lld-link.exe"; do
  if command -v "$cand" >/dev/null 2>&1; then
    LLD_LINK="$(command -v "$cand")"
    break
  elif [ -x "$cand" ]; then
    LLD_LINK="$cand"
    break
  fi
done
if command -v cygpath >/dev/null 2>&1; then
  TMP_NAT="$(cygpath -w "$TMP_DIR")"
  NAT_SEP='\'
else
  TMP_NAT="$TMP_DIR"
  NAT_SEP='/'
fi
DRV_SAN=""
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=undefined -fno-sanitize-recover=all \
  -o "$TMP_DIR/ubsan_probe" 2>/dev/null && "$TMP_DIR/ubsan_probe"; then
  DRV_SAN="-fsanitize=undefined -fno-sanitize-recover=all"
elif [ -n "$RUN" ] && [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  fail "needs UBSan for the C driver (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one"
fi
if [ -n "$RUN" ]; then
  # shellcheck disable=SC2086
  "$CC_BIN" -std=c99 -O1 -Wall -Wextra -Werror $DRV_SAN -I"$F" -c "$DIR/driver.c" -o "$TMP_DIR/driver.o"
  "$CC_BIN" -c "$DIR/harness.S" -o "$TMP_DIR/harness.o"
fi
build_run() { # $1 asm, $2 exe; prints the driver output, returns its status
  rm -f "$1.o" "$2"
  if [ "$RUN" = elf ]; then
    python3 -E "$DIR/to_elf.py" "$1" "$1.elf.s" || return 1
    "$CC_BIN" -c "$1.elf.s" -o "$1.o" || return 1
    LDX="-Wl,-z,noexecstack"
  else
    "$CC_BIN" -c "$1" -o "$1.o" || return 1
    LDX=""
  fi
  # shellcheck disable=SC2086
  "$CC_BIN" $DRV_SAN "$TMP_DIR/driver.o" "$TMP_DIR/harness.o" "$1.o" -o "$2" $LDX || return 1
  "$2"
}
if [ -n "$RUN" ]; then
  OUT=$(build_run "$TMP_DIR/win.s" "$TMP_DIR/p120 drv") || { echo "$OUT" >&2; fail "Win64 execution"; }
  LAST_LINE=$(printf '%s\n' "$OUT" | tr -d '\r' | tail -n 1)
  echo "$LAST_LINE"
  [ "$LAST_LINE" = "p120 calls $NCALLS bad 0" ] || { echo "$OUT" >&2; fail "unexpected driver output"; }
  # runtime mutants: one xmm6 restore of p120_leaf dropped; p120_align's
  # frame 8 bytes off (alloc16 slots and %rsp misaligned)
  python3 -E - "$TMP_DIR/win.s" "$TMP_DIR/mut_run.s" <<'PYEOF' || fail "runtime mutant is not a mutant"
import re, sys
out, on, dropped = [], False, False
for ln in open(sys.argv[1], 'r', newline=''):
    s = ln.rstrip('\r\n')
    if s == 'p120_leaf:':
        on = True
    if on and not dropped and re.fullmatch(r'\tmovups -?\d+\(%rsp\), %xmm6', s):
        dropped = True
        continue
    out.append(ln)
if not dropped:
    raise SystemExit(1)
open(sys.argv[2], 'w', newline='').writelines(out)
PYEOF
  if MOUT=$(build_run "$TMP_DIR/mut_run.s" "$TMP_DIR/p120 mut"); then
    fail "driver accepted a function that clobbers xmm6"
  fi
  printf '%s\n' "$MOUT" | tr -d '\r' | grep -q '^BAD p120_leaf seed 1: xmm6 ' || { echo "$MOUT" >&2; fail "runtime mutant: no xmm6 report"; }
  if [ "$RUN" = pe ]; then
    if [ -n "$CLANG_BIN" ]; then
      # --seh emits MSVC/Clang inline COMDAT (`,one_only,<sym>`) for associative
      # .pdata/.xdata; assemble with clang and run natively on Windows too.
      "$CLANG_BIN" -target x86_64-pc-windows-msvc -c "$TMP_DIR/winseh.s" -o "$TMP_DIR/winseh.s.o" || fail "clang assemble winseh.s"
      # shellcheck disable=SC2086
      "$CC_BIN" $DRV_SAN "$TMP_DIR/driver.o" "$TMP_DIR/harness.o" "$TMP_DIR/winseh.s.o" -o "$TMP_DIR/p120 drvseh" || fail "link winseh"
      OUT=$("$TMP_DIR/p120 drvseh") || { echo "$OUT" >&2; fail "Win64 --seh execution"; }
      LAST_SEH=$(printf '%s\n' "$OUT" | tr -d '\r' | tail -n 1)
      echo "p120 --seh: $LAST_SEH"
      [ "$LAST_SEH" = "p120 calls $NCALLS bad 0" ] || { echo "$OUT" >&2; fail "unexpected --seh driver output"; }
    elif [ "${PION_REQUIRE_COFF:-0}" = 1 ]; then
      fail "needs clang for Win64 --seh native execution (PION_REQUIRE_COFF=1)"
    fi
  fi
  if MOUT=$(build_run "$TMP_DIR/mut_misalign.s" "$TMP_DIR/p120 mis"); then
    fail "driver accepted misaligned alloc16 slots"
  fi
  printf '%s\n' "$MOUT" | tr -d '\r' | grep -q '^BAD p120_align seed 1: result ' || { echo "$MOUT" >&2; fail "runtime mutant: no p120_align report"; }
  echo "p120 Win64 execution ($RUN): $NCALLS calls, 160 bytes of xmm6..xmm15 + 8 GPRs + %rsp intact, alloc16 / dynamic / call-site alignment; restore and misalignment mutants caught"
else
  echo "NOTE: p120 Win64 execution needs an x86-64 Linux or Windows host ($HOST_S/$HOST_M); structural checks only"
fi

# 2b. COFF unwind tables & final PE `/OPT:REF` link gate:
#   - With clang (Linux / macOS / MSVC Windows): assemble `--seh` text as COFF
#     and verify associative COMDAT `.pdata`/`.xdata` directly on the binary
#     (check_unwind.py --coff), catch a lying `.seh_savexmm`, and verify default
#     text emits zero unwind sections.
#   - With GNU as (x86_64-w64-mingw32-as or MSYS2 gcc): verify default text
#     assembles cleanly with zero unwind sections (p98 MinGW GC contract).
#   - With clang + lld-link: link final PE32+ images with `/OPT:REF` and verify
#     live functions keep exact 12-byte RUNTIME_FUNCTION records while dead
#     global & static functions (and their unwind tables) are GC'd, and two
#     same-named static functions in separate objects stay isolated.
GAS_AS=""
if [ "$RUN" = pe ]; then
  GAS_AS="$CC_BIN -c"
elif command -v x86_64-w64-mingw32-as >/dev/null 2>&1; then
  GAS_AS="x86_64-w64-mingw32-as"
fi
if [ -n "$CLANG_BIN" ]; then
  "$CLANG_BIN" -target x86_64-pc-windows-msvc -c "$TMP_DIR/winseh.s" -o "$TMP_DIR/winseh.obj" || fail "clang assemble winseh.s"
  python3 -E "$DIR/check_unwind.py" --coff "$TMP_DIR/winseh.s" "$TMP_DIR/winseh.obj" || fail "COFF unwind tables"
  "$CLANG_BIN" -target x86_64-pc-windows-msvc -c "$TMP_DIR/win.s" -o "$TMP_DIR/win_clang.obj" || fail "clang assemble default win.s"
  python3 -E "$DIR/check_unwind.py" --no-unwind "$TMP_DIR/win_clang.obj" || fail "default amd64_win object has unwind data"
  "$CLANG_BIN" -target x86_64-pc-windows-msvc -c "$TMP_DIR/mut_sehlie_seh.s" -o "$TMP_DIR/mut_sehlie.obj" || fail "clang assemble sehlie mutant"
  if python3 -E "$DIR/check_unwind.py" --coff "$TMP_DIR/mut_sehlie_seh.s" "$TMP_DIR/mut_sehlie.obj" > "$TMP_DIR/sehlie.log" 2>&1; then
    fail "check_unwind.py accepted a .seh_savexmm offset that differs from the store"
  fi
  grep -q '^FAIL: check_unwind' "$TMP_DIR/sehlie.log" || { cat "$TMP_DIR/sehlie.log" >&2; fail "sehlie: no unwind diagnostic"; }
  echo "p120 COFF: --seh associative COMDAT .pdata/.xdata of all framed functions match prologues, default has none; lying .seh directive caught"
elif [ "${PION_REQUIRE_COFF:-0}" = 1 ]; then
  fail "needs clang targeting x86_64-pc-windows-msvc (PION_REQUIRE_COFF=1)"
else
  echo "NOTE: no clang targeting x86_64-pc-windows-msvc; skipping associative COFF unwind decode"
fi
if [ -n "$GAS_AS" ]; then
  # shellcheck disable=SC2086
  $GAS_AS "$TMP_DIR/win.s" -o "$TMP_DIR/win_gas.obj" || fail "GNU as default text"
  python3 -E "$DIR/check_unwind.py" --no-unwind "$TMP_DIR/win_gas.obj" || fail "default GNU as amd64_win object has unwind data"
fi
if [ -n "$CLANG_BIN" ] && [ -n "$LLD_LINK" ]; then
  # Single-object PE /OPT:REF: live `entry` + dead `unused` + dead static `local_dead`
  cat > "$TMP_DIR/pe_gc.ssa" <<'SSAEOF'
export function d $entry(d %a, d %b) {
@start
	%r =d div %b, %a
	ret %r
}
export function d $unused(d %a, d %b) {
@start
	%r =d div %b, %a
	ret %r
}
function d $local_dead(d %a, d %b) {
@start
	%r =d div %b, %a
	ret %r
}
SSAEOF
  "$QBE" --seh -t amd64_win -o "$TMP_DIR/pe_gc_seh.s" "$TMP_DIR/pe_gc.ssa"
  "$QBE" -t amd64_win -o "$TMP_DIR/pe_gc_def.s" "$TMP_DIR/pe_gc.ssa"
  "$CLANG_BIN" -target x86_64-pc-windows-msvc -c "$TMP_DIR/pe_gc_seh.s" -o "$TMP_DIR/pe_gc_seh.obj"
  "$CLANG_BIN" -target x86_64-pc-windows-msvc -c "$TMP_DIR/pe_gc_def.s" -o "$TMP_DIR/pe_gc_def.obj"
  MSYS2_ARG_CONV_EXCL="*" "$LLD_LINK" /NOLOGO /entry:entry /nodefaultlib /subsystem:console /opt:ref \
    "/map:${TMP_NAT}${NAT_SEP}pe_gc_seh.map" "/out:${TMP_NAT}${NAT_SEP}pe_gc_seh.exe" "${TMP_NAT}${NAT_SEP}pe_gc_seh.obj"
  python3 -E "$DIR/check_unwind.py" --pe-link "$TMP_DIR/pe_gc_seh.exe" "$TMP_DIR/pe_gc_seh.map" "$TMP_DIR/pe_gc_seh.s" \
    --live entry --dead unused,local_dead --expect-entries 1 || fail "PE /OPT:REF --seh"
  MSYS2_ARG_CONV_EXCL="*" "$LLD_LINK" /NOLOGO /entry:entry /nodefaultlib /subsystem:console /opt:ref \
    "/map:${TMP_NAT}${NAT_SEP}pe_gc_def.map" "/out:${TMP_NAT}${NAT_SEP}pe_gc_def.exe" "${TMP_NAT}${NAT_SEP}pe_gc_def.obj"
  python3 -E "$DIR/check_unwind.py" --pe-link "$TMP_DIR/pe_gc_def.exe" "$TMP_DIR/pe_gc_def.map" "$TMP_DIR/pe_gc_def.s" \
    --live entry --dead unused,local_dead --expect-entries 0 || fail "PE /OPT:REF default"

  # Two-object PE /OPT:REF: static symbol isolation (`local_same` in both objs) + GC + SEH
  cat > "$TMP_DIR/pe_obj1.ssa" <<'SSAEOF'
export function d $entry(d %a, d %b) {
@start
	%x =d call $local_same(d %a, d %b)
	%y =d call $call_obj2(d %x, d %b)
	%r =d div %y, %a
	ret %r
}
function d $local_same(d %a, d %b) {
@start
	%r =d div %b, %a
	ret %r
}
export function d $unused(d %a, d %b) {
@start
	%r =d div %b, %a
	ret %r
}
function d $local_dead(d %a, d %b) {
@start
	%r =d div %b, %a
	ret %r
}
SSAEOF
  cat > "$TMP_DIR/pe_obj2.ssa" <<'SSAEOF'
export function d $call_obj2(d %a, d %b) {
@start
	%x =d call $local_same(d %a, d %b)
	%r =d div %x, %a
	ret %r
}
function d $local_same(d %a, d %b) {
@start
	%t =d add %b, d_1.0
	%r =d div %t, %a
	ret %r
}
function d $local_dead2(d %a, d %b) {
@start
	%r =d div %b, %a
	ret %r
}
SSAEOF
  "$QBE" --seh -t amd64_win -o "$TMP_DIR/pe_obj1.s" "$TMP_DIR/pe_obj1.ssa"
  "$QBE" --seh -t amd64_win -o "$TMP_DIR/pe_obj2.s" "$TMP_DIR/pe_obj2.ssa"
  "$CLANG_BIN" -target x86_64-pc-windows-msvc -c "$TMP_DIR/pe_obj1.s" -o "$TMP_DIR/pe_obj1.obj"
  "$CLANG_BIN" -target x86_64-pc-windows-msvc -c "$TMP_DIR/pe_obj2.s" -o "$TMP_DIR/pe_obj2.obj"
  MSYS2_ARG_CONV_EXCL="*" "$LLD_LINK" /NOLOGO /entry:entry /nodefaultlib /subsystem:console /opt:ref \
    "/map:${TMP_NAT}${NAT_SEP}pe_two.map" "/out:${TMP_NAT}${NAT_SEP}pe_two.exe" \
    "${TMP_NAT}${NAT_SEP}pe_obj1.obj" "${TMP_NAT}${NAT_SEP}pe_obj2.obj"
  python3 -E "$DIR/check_unwind.py" --pe-link "$TMP_DIR/pe_two.exe" "$TMP_DIR/pe_two.map" \
    --asm "$TMP_DIR/pe_obj1.s" --asm "$TMP_DIR/pe_obj2.s" \
    --live entry,call_obj2,local_same:2 --dead unused,local_dead,local_dead2 --expect-entries 4 || fail "PE two-obj /OPT:REF --seh"
  echo "p120 PE /OPT:REF: single-obj exc_dir=0x0c (1 entry, dead GC'd) + two-obj static isolation exc_dir=0x30 (4 entries, 0 collisions)"
elif [ "${PION_REQUIRE_PE_LINK:-0}" = 1 ]; then
  fail "needs clang + lld-link for PE /OPT:REF gate (PION_REQUIRE_PE_LINK=1)"
else
  echo "NOTE: clang or lld-link unavailable; skipping linked PE /OPT:REF unwind gate"
fi

# 3. Real programs and the other backends.
for B in nbody spectralnorm mandelbrot_mt; do
  "$PIONC" build --release --emit-ssa "$TMP_DIR/$B.ssa" -o "$TMP_DIR/$B.bin" "$ROOT_DIR/benchmarks/pion/$B.pion"
  "$QBE" -t amd64_win -o "$TMP_DIR/$B.win.s" "$TMP_DIR/$B.ssa"
  python3 -E "$DIR/check_frames.py" "$TMP_DIR/$B.win.s" /dev/null
done
# The whole compiler (bootstrap seed SSA, ~2400 functions) as amd64_win.
gzip -dc "$ROOT_DIR/bootstrap/pionc-seed.ssa.gz" > "$TMP_DIR/seed.ssa"
"$QBE" -t amd64_win -o "$TMP_DIR/seed.win.s" "$TMP_DIR/seed.ssa"
python3 -E "$DIR/check_frames.py" "$TMP_DIR/seed.win.s" /dev/null
"$QBE" --seh -t amd64_win -o "$TMP_DIR/seed.winseh.s" "$TMP_DIR/seed.ssa"
python3 -E "$DIR/check_frames.py" "$TMP_DIR/seed.winseh.s" /dev/null --seh
if [ -n "$CLANG_BIN" ]; then
  "$CLANG_BIN" -target x86_64-pc-windows-msvc -c "$TMP_DIR/seed.winseh.s" -o "$TMP_DIR/seed.winseh.obj" || fail "clang assemble seed.winseh.s"
fi
# pionc passes --seh exactly for MSVC builds (PION_WIN_ABI=msvc)
printf 'pub fn main(world : World) -> Int {\n  io_println(world, "seh")\n  0\n}\n' > "$TMP_DIR/seh_main.pion"
PION_WIN_ABI=msvc "$PIONC" build --target amd64_win --emit-asm "$TMP_DIR/msvc.s" "$TMP_DIR/seh_main.pion"
PION_WIN_ABI=mingw "$PIONC" build --target amd64_win --emit-asm "$TMP_DIR/mingw.s" "$TMP_DIR/seh_main.pion"
grep -q '^[[:space:]]*\.seh_proc ' "$TMP_DIR/msvc.s" || fail "pionc PION_WIN_ABI=msvc did not pass --seh"
if grep -q '\.seh_' "$TMP_DIR/mingw.s"; then fail "pionc PION_WIN_ABI=mingw emitted .seh_*"; fi
python3 -E "$DIR/check_frames.py" "$TMP_DIR/msvc.s" /dev/null --seh
python3 -E "$DIR/check_frames.py" "$TMP_DIR/mingw.s" /dev/null
"$QBE" -t amd64_sysv -o "$TMP_DIR/sysv.s" "$F/fixture.ssa"
if grep -q 'movups' "$TMP_DIR/sysv.s"; then fail "amd64_sysv text has movups"; fi
awk '/^p120_vol:/,/end function/' "$TMP_DIR/win.s" > "$TMP_DIR/vol_only.s"
python3 -E "$DIR/check_frames.py" "$TMP_DIR/vol_only.s" --all-nosave
# Mixed alloc4 + alloc8 (without alloc16) and alloc4 + alloc8 + alloc16 across
# all QBE targets: slot area must be padded to the max alloc alignment so both
# bottom-up (amd64_win) and top-down (amd64_sysv/apple rbp, arm64, rv64) keep
# every alloc aligned.
cat > "$TMP_DIR/mix_alloc.ssa" <<'SSAEOF'
export function l $mix48_call() {
@start
	%a4 =l alloc4 4
	%b8 =l alloc8 8
	storew 1, %a4
	storel 2, %b8
	call $p120_sink(l %a4, l %b8)
	%m =l and %b8, 7
	ret %m
}
export function l $mix48_leaf() {
@start
	%a4 =l alloc4 4
	%b8 =l alloc8 8
	storew 1, %a4
	storel 2, %b8
	%m =l and %b8, 7
	ret %m
}
export function l $mix4816_call() {
@start
	%a4 =l alloc4 4
	%b8 =l alloc8 8
	%c16 =l alloc16 16
	storew 1, %a4
	storel 2, %b8
	storel 3, %c16
	call $p120_sink3(l %a4, l %b8, l %c16)
	%m1 =l and %b8, 7
	%m2 =l and %c16, 15
	%m =l or %m1, %m2
	ret %m
}
SSAEOF
cat > "$TMP_DIR/mix_drv.c" <<'CEOF'
#include <stdio.h>
void p120_sink(void *a, void *b) { (void)a; (void)b; }
void p120_sink3(void *a, void *b, void *c) { (void)a; (void)b; (void)c; }
extern long long mix48_call(void);
extern long long mix48_leaf(void);
extern long long mix4816_call(void);
int main(void) {
  long long r1 = mix48_call();
  long long r2 = mix48_leaf();
  long long r3 = mix4816_call();
  if (r1 || r2 || r3) {
    fprintf(stderr, "BAD mix_alloc: r1=%lld r2=%lld r3=%lld\n", r1, r2, r3);
    return 1;
  }
  return 0;
}
CEOF
for TGT in amd64_sysv amd64_apple amd64_win arm64 arm64_apple rv64; do
  "$QBE" -t "$TGT" -o "$TMP_DIR/mix_$TGT.s" "$TMP_DIR/mix_alloc.ssa"
done
python3 -E - "$TMP_DIR" <<'PYEOF' || fail "cross-target mixed alloc4+alloc8 alignment"
import pathlib, re, sys
d = pathlib.Path(sys.argv[1])
def fn_lines(path, name):
    lines = path.read_text().splitlines()
    out, on = [], False
    for ln in lines:
        if re.match(rf'^_?{name}:$', ln.strip()):
            on = True; continue
        if on:
            if re.match(r'^(\.size|/\* end function|export|function|_?mix)', ln.strip()):
                break
            out.append(ln)
    assert out, f"missing {name} in {path}"
    return out

def find_off(tgt, txt, reg):
    if tgt.startswith('amd64'):
        m = re.search(rf'(?:leaq\s+(-?\d*)\(%rbp\),\s*%{reg}|movq\s+%rbp,\s*%{reg})\b', txt)
        if not m:
            return None
        return int(m.group(1)) if m.group(1) else 0
    if tgt.startswith('arm64'):
        m = re.search(rf'add\s+{reg},\s*x29,\s*#(\d+)\b', txt)
        if m:
            return int(m.group(1))
        if re.search(rf'mov\s+{reg},\s*x29\b', txt):
            return 0
        return None
    if tgt == 'rv64':
        m = re.search(rf'addi?\s+{reg},\s*fp,\s*(-?\d+)\b', txt)
        if m:
            return int(m.group(1))
        if re.search(rf'mv\s+{reg},\s*fp\b', txt):
            return 0
        return None
    return None

# Check mix48_call's 2nd argument (%b8, alloc8 8) offset is 0 mod 8 on every target
for tgt, reg in [
    ('amd64_sysv', 'rsi'), ('amd64_apple', 'rsi'), ('amd64_win', 'rdx'),
    ('arm64', 'x1'), ('arm64_apple', 'x1'), ('rv64', 'a1'),
]:
    txt = '\n'.join(fn_lines(d / f'mix_{tgt}.s', 'mix48_call'))
    off = find_off(tgt, txt, reg)
    if off is None:
        print(f"FAIL: {tgt} mix48_call missing expected %b8 addr:\n{txt}", file=sys.stderr)
        raise SystemExit(1)
    if off % 8 != 0:
        print(f"FAIL: {tgt} mix48_call alloc8 offset {off} not 8-byte aligned", file=sys.stderr)
        raise SystemExit(1)

# Check mix4816_call's 3rd argument (%c16, alloc16 16) is 0 mod 16 and 2nd (%b8) is 0 mod 8
for tgt, r8, r16 in [
    ('amd64_sysv', 'rsi', 'rdx'), ('amd64_apple', 'rsi', 'rdx'), ('amd64_win', 'rdx', 'r8'),
    ('arm64', 'x1', 'x2'), ('arm64_apple', 'x1', 'x2'), ('rv64', 'a1', 'a2'),
]:
    txt = '\n'.join(fn_lines(d / f'mix_{tgt}.s', 'mix4816_call'))
    o8, o16 = find_off(tgt, txt, r8), find_off(tgt, txt, r16)
    if o8 is None or o16 is None:
        print(f"FAIL: {tgt} mix4816_call missing expected addr:\n{txt}", file=sys.stderr)
        raise SystemExit(1)
    if o8 % 8 != 0 or o16 % 16 != 0:
        print(f"FAIL: {tgt} mix4816_call misaligned: b8={o8} c16={o16}", file=sys.stderr)
        raise SystemExit(1)
PYEOF
if [ "$RUN" = elf ]; then
  "$QBE" -t amd64_sysv --obj -o "$TMP_DIR/mix_sysv.o" "$TMP_DIR/mix_alloc.ssa"
  "$CC_BIN" -std=c99 -O1 "$TMP_DIR/mix_drv.c" "$TMP_DIR/mix_amd64_sysv.s" -Wl,-z,noexecstack -o "$TMP_DIR/mix_txt"
  "$TMP_DIR/mix_txt" || fail "amd64_sysv text mix_alloc alignment"
  "$CC_BIN" -std=c99 -O1 "$TMP_DIR/mix_drv.c" "$TMP_DIR/mix_sysv.o" -Wl,-z,noexecstack -o "$TMP_DIR/mix_obj"
  "$TMP_DIR/mix_obj" || fail "amd64_sysv --obj mix_alloc alignment"
elif [ "$RUN" = pe ]; then
  "$CC_BIN" -std=c99 -O1 "$TMP_DIR/mix_drv.c" "$TMP_DIR/mix_amd64_win.s" -o "$TMP_DIR/mix_win"
  "$TMP_DIR/mix_win" || fail "amd64_win text mix_alloc alignment"
  if [ -n "$CLANG_BIN" ]; then
    "$QBE" --seh -t amd64_win -o "$TMP_DIR/mix_amd64_win_seh.s" "$TMP_DIR/mix_alloc.ssa"
    "$CLANG_BIN" -target x86_64-pc-windows-msvc -c "$TMP_DIR/mix_amd64_win_seh.s" -o "$TMP_DIR/mix_amd64_win_seh.o"
    "$CC_BIN" -std=c99 -O1 "$TMP_DIR/mix_drv.c" "$TMP_DIR/mix_amd64_win_seh.o" -o "$TMP_DIR/mix_winseh"
    "$TMP_DIR/mix_winseh" || fail "amd64_win --seh mix_alloc alignment"
  fi
elif [ "$HOST_S/$HOST_M" = "Darwin/arm64" ]; then
  "$QBE" -t arm64_apple --obj -o "$TMP_DIR/mix_arm64.o" "$TMP_DIR/mix_alloc.ssa"
  "$CC_BIN" -std=c99 -O1 "$TMP_DIR/mix_drv.c" "$TMP_DIR/mix_arm64_apple.s" -o "$TMP_DIR/mix_txt"
  "$TMP_DIR/mix_txt" || fail "arm64_apple text mix_alloc alignment"
  "$CC_BIN" -std=c99 -O1 "$TMP_DIR/mix_drv.c" "$TMP_DIR/mix_arm64.o" -o "$TMP_DIR/mix_obj"
  "$TMP_DIR/mix_obj" || fail "arm64_apple --obj mix_alloc alignment"
fi
echo "p120 benchmarks + seed: amd64_win frames OK; amd64_sysv without xmm saves; xmm0..xmm5-only code saves nothing; mixed alloc4+alloc8(+alloc16) aligned across all 6 targets"

# 4. ASan + UBSan QBE.
SAN_QBE=""
if [ -n "${PION_QBE_SAN:-}" ] && [ -x "$PION_QBE_SAN" ]; then
  SAN_QBE="$PION_QBE_SAN"
else
  SAN_RC=0
  CC="$CC_BIN" sh "$ROOT_DIR/scripts/build-qbe-san.sh" "$TMP_DIR/sanq" || SAN_RC=$?
  if [ "$SAN_RC" -eq 0 ]; then
    SAN_QBE="$TMP_DIR/sanq/qbe"
  elif [ "$SAN_RC" -ne 77 ]; then
    fail "ASan+UBSan QBE build failed (exit $SAN_RC)"
  fi
fi
if [ -n "$SAN_QBE" ]; then
  export ASAN_OPTIONS="detect_leaks=0:halt_on_error=1:detect_stack_use_after_return=0:fast_unwind_on_malloc=0:quarantine_size_mb=16"
  export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"
  N=0
  replay() { # $1 input, then qbe options
    in=$1
    shift
    "$QBE" "$@" -o "$TMP_DIR/ref.out" "$in"
    "$SAN_QBE" "$@" -o "$TMP_DIR/san.out" "$in" 2> "$TMP_DIR/san.err" || { cat "$TMP_DIR/san.err" >&2; fail "sanitized QBE $* $in"; }
    [ ! -s "$TMP_DIR/san.err" ] || { cat "$TMP_DIR/san.err" >&2; fail "sanitized QBE $* $in wrote diagnostics"; }
    cmp "$TMP_DIR/ref.out" "$TMP_DIR/san.out" || fail "sanitized QBE $* $in: output differs from out/qbe"
    N=$((N + 1))
  }
  for IN in "$F/fixture.ssa" "$TMP_DIR/nbody.ssa" "$TMP_DIR/spectralnorm.ssa" "$TMP_DIR/mandelbrot_mt.ssa"; do
    replay "$IN" -t amd64_win
    replay "$IN" --seh -t amd64_win
    replay "$IN" -t amd64_sysv
    replay "$IN" -t amd64_sysv --obj
    replay "$IN" -t arm64
    replay "$IN" -t arm64_apple
  done
  [ "$N" -eq 24 ] || fail "replayed $N outputs, want 24"
  echo "p120 ASan+UBSan QBE: 24 outputs (4 inputs x amd64_win default / --seh / amd64_sysv text + --obj / arm64 / arm64_apple) clean and equal to out/qbe"
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  fail "needs ASan+UBSan (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one"
else
  echo "NOTE: $CC_BIN -fsanitize=address,undefined unavailable; skipping the sanitized QBE replay"
fi
echo "p120 OK"
