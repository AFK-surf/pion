#!/bin/sh
# P119: AMD64 scalar floating-point right-operand load fold
# (vendor/qbe/amd64/isel.c `foldoperandloads`;
# Lean: tests/lean/proofs/QbeAmd64FpRhsLoadFold.lean).
# An adjacent, same-class, single-use `load` that is the right operand of a
# scalar FP `sub` / `div` whose left operand is a temporary becomes the
# memory source of subss / subsd / divss / divsd; the integer Oxcmp fold keeps
# its conditions.
# Verifies:
#   1. Structure (check_fpfold.py, real instruction boundaries): the 22 p_*
#      functions of fold.ssa (subss/subsd/divss/divsd x RTmp pointer, base +
#      offset, base + index*scale + offset, stack slot + index + offset, and
#      20 live XMM values with the left operand reloaded from its spill slot
#      by a movs<k> of the operation's width; plus subss/subsd where the
#      unfolded load temp shares the result register) fold with the expected
#      addressing mode and no leftover load; the 12 n_* controls (left-operand
#      load, two uses, store or call in between, loads+exts / loadd+truncd, FP
#      constant left operand) do not, and keep their arithmetic; no
#      instruction has two memory operands. Checked on the amd64_sysv text,
#      the amd64_win text, and (Linux x86-64 / macOS, objdump required) the
#      objdump listing of `--obj` and of the assembled text; the executable
#      sections, relocations and referenced data of `--obj` and of the
#      assembled text are identical.
#   2. Checker self-test: a missed fold, a folded control, a spill-free
#      high-pressure function, a one-function --obj/text difference (all
#      produced by QBE from mutated copies of fold.ssa), a control whose
#      arithmetic is gone, a 32-bit movss reload in front of a subsd, and two
#      objects that differ only in a global data symbol they define and use
#      are rejected.
#   3. IEEE-754 differential (driver.c, UBSan + alignment when available):
#      34 functions x 4 rounding modes x 16 x 16 boundary values (+-0,
#      subnormals, min / max normals, +-Inf, qNaN / sNaN payloads, ordinary
#      numbers) x 2 misaligned addresses: result bits, written memory and
#      fetestexcept flags equal the C reference (exact everywhere, except
#      that a NaN result of n_const_subd's pre-existing `neg; add` lowering
#      only has to be a NaN), identically on the host's
#      text-assembly and direct-object routes (amd64_sysv or arm64[_apple]).
#   4. Pion source: p119.pion (f32 / f64 sub / div from array elements and
#      struct fields over the same boundary values) prints pion_ref.c's lines
#      on dev and --release; benchmarks/pion/nbody.pion --release prints the C
#      result. Their amd64_sysv QBE text has folded loads (nbody's advance:
#      at least 3 subsd).
#   5. ASan + UBSan QBE: fold.ssa and the Pion SSA of step 4 on amd64_sysv
#      (text and --obj), amd64_win, arm64, arm64_apple (text and --obj), output
#      equal to the plain QBE with no report; its host text runs the
#      differential of step 3 with identical rows.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p119_amd64_fp_rhs_load_fold"
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC_BIN="${CC:-cc}"
# check ARGS...: the structure / encoder checker (a function, so that a
# worktree path with spaces is passed as one argument).
check() { python3 -E "$DIR/check_fpfold.py" "$@"; }
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"
FOLD="$DIR/fold.ssa"
HOST="$(uname -s)/$(uname -m)"

if [ ! -x "$QBE" ]; then
  echo "FAIL: QBE binary not found at $QBE" >&2
  exit 1
fi

# The x86-64 ELF tools: objdump (GNU or LLVM) and an assembler for the text.
OBJDUMP=""
for t in objdump llvm-objdump; do
  if command -v "$t" >/dev/null 2>&1; then OBJDUMP="$t"; break; fi
done
XAS=""
case "$HOST" in
  Linux/x86_64|Linux/amd64) XAS="$CC_BIN -c" ;;
  Darwin/*) XAS="clang -target x86_64-unknown-linux-gnu -c" ;;
esac
NEED_ELF=0
case "$HOST" in
  Linux/x86_64|Linux/amd64|Darwin/*) NEED_ELF=1 ;;
esac

# 1. Structure.
"$QBE" -t amd64_sysv -o "$TMP_DIR/sysv.s" "$FOLD"
check asm "amd64_sysv text" "$TMP_DIR/sysv.s"
"$QBE" -t amd64_win -o "$TMP_DIR/win.s" "$FOLD"
check asm "amd64_win text" "$TMP_DIR/win.s"
"$QBE" -t amd64_sysv --obj -o "$TMP_DIR/sysv.o" "$FOLD"
ELF=0
if [ -n "$OBJDUMP" ] && [ -n "$XAS" ] && $XAS -o "$TMP_DIR/sysv_text.o" "$TMP_DIR/sysv.s" 2> "$TMP_DIR/as.log" \
  && [ ! -s "$TMP_DIR/as.log" ] && "$OBJDUMP" -d --no-show-raw-insn "$TMP_DIR/sysv.o" > "$TMP_DIR/sysv_obj.dis" 2>/dev/null; then
  ELF=1
  "$OBJDUMP" -d --no-show-raw-insn "$TMP_DIR/sysv_text.o" > "$TMP_DIR/sysv_text.dis"
  check dis "amd64_sysv --obj ($OBJDUMP)" "$TMP_DIR/sysv_obj.dis"
  check dis "amd64_sysv text, assembled ($OBJDUMP)" "$TMP_DIR/sysv_text.dis"
  check elfeq "$TMP_DIR/sysv.o" "$TMP_DIR/sysv_text.o"
elif [ "$NEED_ELF" = 1 ]; then
  cat "$TMP_DIR/as.log" >&2 2>/dev/null || true
  echo "FAIL: p119 needs objdump / llvm-objdump and an x86-64 ELF assembler on $HOST" >&2
  exit 1
else
  echo "NOTE: p119 no x86-64 objdump / assembler on $HOST; ELF listings and --obj == text skipped"
fi

# 2. Checker self-test on QBE output of mutated fixtures.
# mutate NAME FUNCTION OLD NEW: copy of fold.ssa with OLD -> NEW in FUNCTION.
mutate() {
  python3 -E - "$FOLD" "$TMP_DIR/$1.ssa" "$2" "$3" "$4" <<'PYEOF'
import sys
src, dst, fn, old, new = sys.argv[1:]
text = open(src).read()
start = text.index(f'${fn}(')
end = text.index('\n}\n', start)
body = text[start:end]
old, new = old.replace('\\n', '\n').replace('\\t', '\t'), new.replace('\\n', '\n').replace('\\t', '\t')
if body.count(old) < 1:
    raise SystemExit(f'p119 mutation: {old!r} not in {fn}')
open(dst, 'w').write(text[:start] + body.replace(old, new) + text[end:])
PYEOF
}
# reject LABEL PATTERN CMD...: CMD must fail and name PATTERN.
reject() {
  label=$1
  pat=$2
  shift 2
  if "$@" > "$TMP_DIR/rej.out" 2> "$TMP_DIR/rej.err"; then
    echo "FAIL: p119 checker accepted the mutation: $label" >&2
    exit 1
  fi
  if ! grep -q "$pat" "$TMP_DIR/rej.err"; then
    cat "$TMP_DIR/rej.err" >&2
    echo "FAIL: p119 checker rejected '$label' without naming $pat" >&2
    exit 1
  fi
  echo "p119 self-test: rejected $label"
}
mutate missed p_subd_ptr '\tret %r' '\tstored %v, %p\n\tret %r'
mutate wrong n_store_subd '\tstored %y, %p\n' ''
python3 -E - "$FOLD" "$TMP_DIR/nospill.ssa" <<'PYEOF'
import re, sys
# Drop every store before the division in p_divd_hp: in[0] stays in a register.
src, dst = sys.argv[1:]
text = open(src).read()
start = text.index('$p_divd_hp(')
cut = text.index('%v =d loadd %q', start)
end = text.index('\n}\n', start)
pre = re.sub(r'\t%o\d+ =l add %out, \d+\n\tstored %a\d+, %o\d+\n', '', text[start:cut])
open(dst, 'w').write(text[:start] + pre + text[cut:])
PYEOF
for m in missed wrong nospill; do
  "$QBE" -t amd64_sysv -o "$TMP_DIR/$m.s" "$TMP_DIR/$m.ssa"
  "$QBE" -t amd64_sysv --obj -o "$TMP_DIR/$m.o" "$TMP_DIR/$m.ssa"
done
reject "missed fold (text)" p_subd_ptr check asm missed "$TMP_DIR/missed.s"
reject "folded control (text)" n_store_subd check asm wrong "$TMP_DIR/wrong.s"
reject "high pressure without a spill (text)" p_divd_hp check asm nospill "$TMP_DIR/nospill.s"
reject "--obj differing from text in one function" .text.p_subd_ptr check elfeq "$TMP_DIR/sysv.o" "$TMP_DIR/missed.o"
# Listing-level mutations of the real amd64_sysv text.
python3 -E - "$TMP_DIR/sysv.s" "$TMP_DIR" <<'PYEOF'
import re, sys
src, tmp = sys.argv[1:]
text = open(src).read()
def body(fn):
    start = text.index(f'\n{fn}:\n')
    return start, text.index('/* end function', start)
# n_call_divd without its division (the function now returns its argument).
s, e = body('n_call_divd')
lost = text[s:e]
assert re.search(r'\tdivsd %xmm\d+, %xmm\d+\n', lost)
open(f'{tmp}/lost.s', 'w').write(text[:s] + re.sub(r'\tdivsd %xmm\d+, %xmm\d+\n', '', lost) + text[e:])
# p_subd_hp: the stack reload that last writes subsd's destination becomes
# a 32-bit movss.
s, e = body('p_subd_hp')
lines = text[s:e].split('\n')
k = next(i for i, l in enumerate(lines) if re.match(r'\tsubsd \(', l))
dst = lines[k].rsplit(' ', 1)[1]
j = next(i for i in range(k - 1, -1, -1) if lines[i].endswith(', ' + dst))
m = re.fullmatch(r'\tmovsd (-?\d*\(%r[sb]p\)), (%xmm\d+)', lines[j])
assert m, f'p_subd_hp: {dst} of subsd is last written by {lines[j]!r}'
lines[j] = f'\tmovss {m.group(1)}, {m.group(2)}'
hp = '\n'.join(lines)
open(f'{tmp}/narrow.s', 'w').write(text[:s] + hp + text[e:])
# p_subd_hp: a 64-bit stack reload followed by a narrowing 32-bit reg copy
# (movss) drops the high 32 bits of the double and must be rejected.
lines[j:j + 1] = [f'\tmovsd {m.group(1)}, %xmm15', f'\tmovss %xmm15, {m.group(2)}']
open(f'{tmp}/narrowcopy.s', 'w').write(text[:s] + '\n'.join(lines) + text[e:])
# p_subs_hp: a 32-bit stack reload followed by a 64-bit register copy (movsd)
# preserves all 32 bits of the float and must be accepted.
s, e = body('p_subs_hp')
lines = text[s:e].split('\n')
k = next(i for i, l in enumerate(lines) if re.match(r'\tsubss \(', l))
dst = lines[k].rsplit(' ', 1)[1]
j = next(i for i in range(k - 1, -1, -1) if lines[i].endswith(', ' + dst))
m = re.fullmatch(r'\tmovss (-?\d*\(%r[sb]p\)), (%xmm\d+)', lines[j])
assert m, f'p_subs_hp: {dst} of subss is last written by {lines[j]!r}'
lines[j:j + 1] = [f'\tmovss {m.group(1)}, %xmm15', f'\tmovsd %xmm15, {m.group(2)}']
open(f'{tmp}/widecopy.s', 'w').write(text[:s] + '\n'.join(lines) + text[e:])
PYEOF
reject "control without its arithmetic (text)" n_call_divd check asm lost "$TMP_DIR/lost.s"
reject "32-bit movss reload before subsd (text)" p_subd_hp check asm narrow "$TMP_DIR/narrow.s"
reject "32-bit movss reg copy before subsd (text)" p_subd_hp check asm narrowcopy "$TMP_DIR/narrowcopy.s"
check asm "64-bit movsd reg copy after movss reload (text)" "$TMP_DIR/widecopy.s" > /dev/null
echo "p119 self-test: accepted 64-bit movsd reg copy after movss reload (text)"
# Two objects whose code is identical but whose global datum differs.
for v in 42 99; do
  printf 'export data $datum = { b %s }\nexport function w $getd() {\n@start\n\t%%v =w loadub $datum\n\tret %%v\n}\n' "$v" > "$TMP_DIR/datum$v.ssa"
  "$QBE" -t amd64_sysv --obj -o "$TMP_DIR/datum$v.o" "$TMP_DIR/datum$v.ssa"
done
check elfeq "$TMP_DIR/datum42.o" "$TMP_DIR/datum42.o" > /dev/null
reject "objects differing in a global data symbol" "referenced data differs" check elfeq "$TMP_DIR/datum42.o" "$TMP_DIR/datum99.o"
if [ "$ELF" = 1 ]; then
  for m in missed wrong nospill; do
    "$OBJDUMP" -d --no-show-raw-insn "$TMP_DIR/$m.o" > "$TMP_DIR/$m.dis"
  done
  reject "missed fold (--obj listing)" p_subd_ptr check dis missed "$TMP_DIR/missed.dis"
  reject "folded control (--obj listing)" n_store_subd check dis wrong "$TMP_DIR/wrong.dis"
  reject "high pressure without a spill (--obj listing)" p_divd_hp check dis nospill "$TMP_DIR/nospill.dis"
fi

# 3. IEEE-754 differential on the host target.
FPFLAGS="-O1 -ffp-contract=off -frounding-math"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsignaling-nans -Werror -o "$TMP_DIR/probe" 2>/dev/null; then
  FPFLAGS="$FPFLAGS -fsignaling-nans"
fi
UBFLAGS="-fsanitize=undefined,alignment -fno-sanitize-recover=all"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - $UBFLAGS -o "$TMP_DIR/ubprobe" 2>/dev/null \
  && "$TMP_DIR/ubprobe"; then
  DRVFLAGS="$FPFLAGS -g $UBFLAGS"
  DRVLINK="$UBFLAGS"
  DRVNOTE="UBSan + alignment"
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  echo "FAIL: p119 needs UBSan (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build it" >&2
  exit 1
else
  DRVFLAGS="$FPFLAGS"
  DRVLINK=""
  DRVNOTE="no sanitizer available"
fi
"$CC_BIN" $DRVFLAGS -c "$DIR/driver.c" -o "$TMP_DIR/driver.o"
export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
# route LABEL OBJECT: link the driver with OBJECT, run it, keep its rows.
route() {
  "$CC_BIN" $DRVLINK "$TMP_DIR/driver.o" "$2" -lm -o "$TMP_DIR/drv_$1"
  if ! "$TMP_DIR/drv_$1" > "$TMP_DIR/rows_$1" 2> "$TMP_DIR/drv_$1.err" \
    || grep -q 'runtime error\|Sanitizer' "$TMP_DIR/drv_$1.err"; then
    head -50 "$TMP_DIR/drv_$1.err" >&2
    echo "FAIL: p119 IEEE differential ($1)" >&2
    exit 1
  fi
  echo "$(cat "$TMP_DIR/drv_$1.err") [$1, $DRVNOTE]"
}
# asm_obj QBE INPUT OUTPUT: host-target text, assembled (no diagnostics).
asm_obj() {
  "$1" -o "$3.s" "$2"
  if ! "$CC_BIN" -c "$3.s" -o "$3" 2> "$3.log" || [ -s "$3.log" ]; then
    cat "$3.log" >&2
    echo "FAIL: p119 assembler diagnostics for $2" >&2
    exit 1
  fi
}
asm_obj "$QBE" "$FOLD" "$TMP_DIR/host_text.o"
route text "$TMP_DIR/host_text.o"
case "$HOST" in
  Linux/x86_64|Linux/amd64|Darwin/arm64|Darwin/aarch64)
    "$QBE" --obj -o "$TMP_DIR/host_obj.o" "$FOLD"
    route obj "$TMP_DIR/host_obj.o"
    cmp "$TMP_DIR/rows_text" "$TMP_DIR/rows_obj"
    echo "p119 IEEE rows: text and --obj identical ($(wc -l < "$TMP_DIR/rows_text" | tr -d ' ') rows)"
    ;;
  *) echo "NOTE: p119 no direct object route on $HOST; text route only" ;;
esac

# 4. Pion source to native code.
"$CC_BIN" -O1 -ffp-contract=off -o "$TMP_DIR/pion_ref" "$DIR/pion_ref.c"
"$TMP_DIR/pion_ref" > "$TMP_DIR/pion_ref.out"
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG --emit-ssa "$TMP_DIR/p119_$MODE.ssa" -o "$TMP_DIR/p119_$MODE" "$DIR/p119.pion"
  "$TMP_DIR/p119_$MODE" > "$TMP_DIR/p119_$MODE.out"
  if ! diff -u "$TMP_DIR/pion_ref.out" "$TMP_DIR/p119_$MODE.out" >&2; then
    echo "FAIL: p119.pion $MODE differs from pion_ref.c" >&2
    exit 1
  fi
  echo "p119.pion $MODE: $(wc -l < "$TMP_DIR/p119_$MODE.out" | tr -d ' ') lines equal pion_ref.c"
done
NB="$ROOT_DIR/benchmarks/pion/nbody.pion"
"$CC_BIN" -O2 -ffp-contract=off -o "$TMP_DIR/nbody_c" "$ROOT_DIR/benchmarks/c/nbody.c" -lm
"$TMP_DIR/nbody_c" > "$TMP_DIR/nbody_c.out"
"$PIONC" build --release --emit-ssa "$TMP_DIR/nbody.ssa" -o "$TMP_DIR/nbody" "$NB"
"$TMP_DIR/nbody" > "$TMP_DIR/nbody.out"
if ! diff -u "$TMP_DIR/nbody_c.out" "$TMP_DIR/nbody.out" >&2; then
  echo "FAIL: p119 nbody --release differs from C" >&2
  exit 1
fi
echo "p119 nbody --release: $(tr '\n' ' ' < "$TMP_DIR/nbody.out")(= C)"
"$QBE" -t amd64_sysv -o "$TMP_DIR/p119_release.s" "$TMP_DIR/p119_release.ssa"
check pion "p119.pion --release amd64_sysv" "$TMP_DIR/p119_release.s" '*:subsd,divsd,subss,divss:1'
"$QBE" -t amd64_sysv -o "$TMP_DIR/nbody.s" "$TMP_DIR/nbody.ssa"
check pion "nbody --release amd64_sysv" "$TMP_DIR/nbody.s" 'pion_fn_advance:subsd:3'

# 5. ASan + UBSan QBE.
SAN_QBE=""
mkdir -p "$TMP_DIR/sanq"
if [ -n "${PION_QBE_SAN:-}" ] && [ -x "$PION_QBE_SAN" ] \
  && { [ ! -f "${PION_QBE_SAN}.cc" ] || [ "$(cat "${PION_QBE_SAN}.cc")" = "$CC_BIN" ]; }; then
  SAN_QBE="$PION_QBE_SAN"
else
  SAN_RC=0
  CC="$CC_BIN" sh "$ROOT_DIR/scripts/build-qbe-san.sh" "$TMP_DIR/sanq" || SAN_RC=$?
  if [ "$SAN_RC" -eq 0 ]; then
    SAN_QBE="$TMP_DIR/sanq/qbe"
  elif [ "$SAN_RC" -ne 77 ]; then
    echo "FAIL: p119 ASan+UBSan QBE build failed (exit $SAN_RC)" >&2
    exit 1
  fi
fi
if [ -n "$SAN_QBE" ]; then
  SAN_ENV="ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1"
  RUNS=0
  # san ARGS...: sanitized QBE, no report, same output as the plain QBE.
  san() {
    if ! env $SAN_ENV "$SAN_QBE" -o "$TMP_DIR/sanq/out" "$@" 2> "$TMP_DIR/sanq/err" \
      || [ -s "$TMP_DIR/sanq/err" ]; then
      cat "$TMP_DIR/sanq/err" >&2
      echo "FAIL: p119 sanitized QBE $*" >&2
      exit 1
    fi
    "$QBE" -o "$TMP_DIR/sanq/plain" "$@"
    cmp "$TMP_DIR/sanq/out" "$TMP_DIR/sanq/plain"
    RUNS=$((RUNS + 1))
  }
  for IN in "$FOLD" "$TMP_DIR/p119_release.ssa" "$TMP_DIR/nbody.ssa"; do
    san -t amd64_sysv "$IN"
    san -t amd64_sysv --obj "$IN"
    san -t amd64_win "$IN"
    san -t arm64 "$IN"
    san -t arm64_apple "$IN"
    san -t arm64_apple --obj "$IN"
  done
  env $SAN_ENV "$SAN_QBE" -t amd64_sysv -o "$TMP_DIR/san_sysv.s" "$FOLD"
  check asm "ASan+UBSan QBE amd64_sysv text" "$TMP_DIR/san_sysv.s"
  asm_obj "$SAN_QBE" "$FOLD" "$TMP_DIR/san_text.o"
  route asan-ubsan-qbe-text "$TMP_DIR/san_text.o"
  cmp "$TMP_DIR/rows_text" "$TMP_DIR/rows_asan-ubsan-qbe-text"
  echo "p119 ASan+UBSan QBE: 3 inputs x 6 target/route runs = $RUNS runs clean, output equal to the plain QBE"
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  echo "FAIL: p119 needs ASan+UBSan (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one" >&2
  exit 1
else
  echo "NOTE: $CC_BIN -fsanitize=address,undefined unavailable; skipping the sanitized QBE replay"
fi

echo "PASS: p119_amd64_fp_rhs_load_fold"
