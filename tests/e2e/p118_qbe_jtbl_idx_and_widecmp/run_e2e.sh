#!/bin/sh
# P118: amd64 jump-table selectors in the dispatch scratch register and
# widened-word comparison folding (Opt-Track R;
# Lean: tests/lean/proofs/QbeJtblIdxAndWideCmp.lean).
#   spill.c / rega.c   a selector dead on every successor lives in T.jtblidx
#             (%r10) up to the dispatch instead of competing with live-outs;
#   amd64/emit.c / elf.c   the `movl` that zero-extends the selector is dropped
#             only when a 32-bit write in the block proves it
#             (`amd64_table_word`), and the table is indexed directly;
#   copy.c    `widecmp`: csgel / csgtl / cslel / csltl of extsw / extuw (plus an
#             optional 32-bit offset) against a constant, when both ends of the
#             interval agree.
# Verifies:
#   1. gen_il.py jtbl.ssa (30 selector definitions x {dead, live on the
#      successors}, plus two with 16 other live values; duplicate entries,
#      default, dirty high halves such as 0xdeadbeef00000002): the dispatch
#      form and entry count of every table in amd64_sysv text and ELF `--obj`
#      (identical registers, normalization and self-copies) and in amd64_win
#      text (check_dispatch.py; the checker rejects dropped / added / misplaced
#      normalizations, a wrong entry count and a live selector in %r10).
#      bounds.ssa: 432 comparisons, `-d G` folds exactly the constant ones and
#      returns or branches on every kept one (relation, operand and limit
#      checked by check_gvn.py; tampered dumps are rejected; four targets). A C
#      driver with independent oracles runs both files on the host through text
#      assembly and `--obj`, exact check counts, `bad 0` (the driver under UBSan
#      with alignment checks).
#   2. The p114 loop jump tables: sunk spill homes coexist with `%r10`
#      selectors, C reference differential (133172 inputs, text and `--obj`).
#   3. bytecode_vm and fannkuchredux dev / --release print the C program's
#      output; the amd64 `run_vm` dispatch indexes the table by %r10 without
#      normalization; fannkuchredux loses its widened `<= 2147483648` tests.
#   4. An ASan + UBSan QBE (first report fatal) replays every QBE input above
#      for four targets (text, plus `--obj` for amd64_sysv / arm64_apple) with
#      output equal to out/qbe byte for byte.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p118_qbe_jtbl_idx_and_widecmp"
P114="$ROOT_DIR/tests/e2e/p114_qbe_jtbl_edge_spill"
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC_BIN="${CC:-cc}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"
fail() {
  echo "FAIL: p118 $*" >&2
  exit 1
}
[ -x "$QBE" ] || fail "QBE binary not found at $QBE"

F="$TMP_DIR/fix"
python3 -E "$DIR/gen_il.py" "$F"
[ "$(wc -l < "$F/jtbl_expect.txt" | tr -d ' ')" -eq 62 ] || fail "jtbl_expect.txt length"
[ "$(wc -l < "$F/bounds_expect.txt" | tr -d ' ')" -eq 432 ] || fail "bounds_expect.txt length"

HOST_S="$(uname -s)"
HOST_M="$(uname -m)"
OBJ=0
case "$HOST_S/$HOST_M" in
  Linux/x86_64|Linux/amd64) HT=amd64_sysv; OBJ=1 ;;
  Linux/aarch64|Linux/arm64) HT=arm64 ;;
  Darwin/arm64|Darwin/aarch64) HT=arm64_apple; OBJ=1 ;;
  *) HT="" ;;
esac

# The usual toolchains of these hosts have an x86-64 objdump (cross-check).
case "$HOST_S/$HOST_M" in
  Linux/x86_64|Linux/amd64|Darwin/*) export P118_OBJDUMP=1 ;;
esac

# 1a. Dispatch forms: amd64_sysv text == --obj, amd64_win text.
"$QBE" -t amd64_sysv -o "$TMP_DIR/jt.s" "$F/jtbl.ssa"
"$QBE" -t amd64_sysv --obj -o "$TMP_DIR/jt.o" "$F/jtbl.ssa"
"$QBE" -t amd64_win -o "$TMP_DIR/jt_win.s" "$F/jtbl.ssa"
python3 -E "$DIR/check_dispatch.py" "$F/jtbl_expect.txt" both "$TMP_DIR/jt.s" "$TMP_DIR/jt.o"
python3 -E "$DIR/check_dispatch.py" "$F/jtbl_expect.txt" asm "$TMP_DIR/jt_win.s"
# The checker must reject tampered output.
python3 -E - "$TMP_DIR/jt.s" "$TMP_DIR/jt_win.s" "$TMP_DIR" <<'PYEOF'
import re, sys
text, win, out = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
def fn(name, text=text):
    m = re.search(r'^' + name + r':\n.*?/\* end function ' + name + r' \*/', text, re.M | re.S)
    return m.start(), m.end()
def sub(name, a, b, text=text):
    s, e = fn(name, text)
    body = text[s:e]
    if body.count(a) != 1:
        raise SystemExit(f'FAIL: p118 mutation {name}: {a!r} found {body.count(a)} times')
    return text[:s] + body.replace(a, b) + text[e:]
norm = '\tmovl %r10d, %r10d\n'
load = '\tmovslq (%r11,%r10,4), %r10\n'
muts = [sub('d_arg_0', norm, ''), sub('d_opaque_0', norm, ''), sub('d_add_0', load, norm + load),
        sub('d_loaduw_0', load, '\tmovslq (%r11,%rax,4), %r10\n')]
s, e = fn('d_add_1')
m = re.search(r'\tcmpl \$8, %(\w+)\n(?:.*\n){2}\tmovslq \(%r11,%(\w+),4\)', text[s:e])
body = text[s:e].replace(f'cmpl $8, %{m[1]}', 'cmpl $8, %r10d').replace(f'(%r11,%{m[2]},4)', '(%r11,%r10,4)')
muts.append(text[:s] + body + text[e:])
for n, t in enumerate(muts):
    open(f'{out}/mut{n}.s', 'w').write(t)
# Wrong entry count (amd64_win) and a misplaced self-copy (text only).
open(f'{out}/mutn.s', 'w').write(sub('d_arg_0', 'cmpl $8, %r10d', 'cmpl $9, %r10d', win))
open(f'{out}/mutc.s', 'w').write(sub('d_add_0', '\tcmpl $8, %r10d\n', norm + '\tcmpl $8, %r10d\n'))
PYEOF
rejects() { # $1 label, $2 text the report must contain, then the checker command
  label=$1
  want=$2
  shift 2
  if python3 -E "$@" > "$TMP_DIR/mut.out" 2>&1; then
    fail "checker accepts mutation $label"
  fi
  grep -q '^FAIL: p118 ' "$TMP_DIR/mut.out" && grep -qF "$want" "$TMP_DIR/mut.out" || {
    cat "$TMP_DIR/mut.out" >&2
    fail "mutation $label: rejected for another reason"
  }
}
n=0
for NAME in d_arg_0 d_opaque_0 d_add_0 d_loaduw_0 d_add_1; do
  rejects "$n" "$NAME is " "$DIR/check_dispatch.py" "$F/jtbl_expect.txt" asm "$TMP_DIR/mut$n.s"
  n=$((n + 1))
done
rejects entries "d_arg_0 compares against 9, want 8 entries" "$DIR/check_dispatch.py" "$F/jtbl_expect.txt" asm "$TMP_DIR/mutn.s"
rejects self-copy "d_add_0: text " "$DIR/check_dispatch.py" "$F/jtbl_expect.txt" both "$TMP_DIR/mutc.s" "$TMP_DIR/jt.o"
rejects self-copy-asm "d_add_0 is bad" "$DIR/check_dispatch.py" "$F/jtbl_expect.txt" asm "$TMP_DIR/mutc.s"
# Instruction boundaries: an immediate ending like `movl %r10d, %r10d` is no
# self-copy (d_addmagic_0 above; its bytes must be there), and a self-copy after
# an immediate that looks like a REX prefix is one.
python3 -E - "$TMP_DIR/jt.o" <<'PYEOF'
import sys
if open(sys.argv[1], 'rb').read().count(bytes.fromhex('004589d24183fa08')) != 1:
    raise SystemExit('FAIL: p118 d_addmagic_0: immediate bytes not found before the compare')
PYEOF
python3 -E "$DIR/mk_selfcopy.py" "$TMP_DIR"
grep -qx 'd_addmagic_0 direct 8' "$F/jtbl_expect.txt" || fail "d_addmagic_0 expectation"
python3 -E "$DIR/check_dispatch.py" "$TMP_DIR/selfcopy_expect.txt" both "$TMP_DIR/selfcopy.s" "$TMP_DIR/selfcopy_ok.o"
rejects elf-self-copy-both "selfcopy: text " "$DIR/check_dispatch.py" "$TMP_DIR/selfcopy_expect.txt" both "$TMP_DIR/selfcopy.s" "$TMP_DIR/selfcopy_bad.o"
rejects elf-self-copy-obj "selfcopy is bad" "$DIR/check_dispatch.py" "$TMP_DIR/selfcopy_expect.txt" obj "$TMP_DIR/selfcopy_bad.o"
echo "p118 dispatch checker rejects 10 mutations"

# 1b. GVN folds exactly the constant comparisons.
for T in amd64_sysv amd64_win arm64 arm64_apple; do
  "$QBE" -t "$T" -d G -o /dev/null "$F/bounds.ssa" 2> "$TMP_DIR/g_$T.txt"
  python3 -E "$DIR/check_gvn.py" "$F/bounds_expect.txt" "$TMP_DIR/g_$T.txt"
done
# The checker must reject another relation and an unused result.
python3 -E - "$TMP_DIR/g_amd64_sysv.txt" "$TMP_DIR" <<'PYEOF'
import re, sys
text, out = open(sys.argv[1]).read(), sys.argv[2]
s = text.index('> After GVN:', text.index('**** Function r2_extsw_csgel_2 ****'))
e = text.index('\n> ', s)
for n, (pat, rep) in enumerate([(r'\bcsgel\b', 'csltl'), (r'\bretw %\S+', 'retw 0')]):
    body, k = re.subn(pat, rep, text[s:e])
    if k != 1:
        raise SystemExit(f'FAIL: p118 gvn mutation {n}: {k} matches')
    open(f'{out}/gmut{n}.txt', 'w').write(text[:s] + body + text[e:])
PYEOF
for n in 0 1; do
  rejects "gvn$n" "p118 gvn: r2_extsw_csgel_2: want keep" "$DIR/check_gvn.py" "$F/bounds_expect.txt" "$TMP_DIR/gmut$n.txt"
done
echo "p118 gvn checker rejects 2 mutations"

# 1c. Host execution against the C oracles.
DRV_SAN=""
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=undefined,alignment -fno-sanitize-recover=all \
  -o "$TMP_DIR/drv_probe" 2>/dev/null && "$TMP_DIR/drv_probe"; then
  DRV_SAN="-fsanitize=undefined,alignment -fno-sanitize-recover=all"
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  fail "needs UBSan for the C driver (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one"
fi
echo "p118 C driver sanitizers: ${DRV_SAN:-<none>}"
# (2048 + 5 * 12 * 4 * 2) inputs x 62 tables; 18 * 5 inputs x 432 comparisons.
EXPECT_RUN="jtbl 156736
bounds 38880
total 195616 bad 0"
host_run() { # $1 label, then objects / assembly files
  label=$1
  shift
  "$CC_BIN" -O1 $DRV_SAN "$F/check.c" "$@" -o "$TMP_DIR/check_$label"
  UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$TMP_DIR/check_$label" > "$TMP_DIR/check_$label.out" || {
    cat "$TMP_DIR/check_$label.out" >&2
    fail "host $label: C driver reported failures"
  }
  printf '%s\n' "$EXPECT_RUN" > "$TMP_DIR/check.want"
  if ! cmp -s "$TMP_DIR/check.want" "$TMP_DIR/check_$label.out"; then
    diff -u "$TMP_DIR/check.want" "$TMP_DIR/check_$label.out" >&2 || true
    fail "host $label: unexpected driver output"
  fi
  echo "p118 host $label: 195616 checks, bad 0"
}
# 2. p114 loop tables next to sinktablehomes.
mkdir -p "$TMP_DIR/cfg"
python3 -E "$P114/gen_cfg.py" "$TMP_DIR/cfg"
cfg_run() { # $1 label, $2 object or assembly file
  "$CC_BIN" -O1 $DRV_SAN "$TMP_DIR/cfg/check.c" "$2" -o "$TMP_DIR/cfg/check_$1"
  UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$TMP_DIR/cfg/check_$1" > "$TMP_DIR/cfg/$1.out" || {
    tail -5 "$TMP_DIR/cfg/$1.out" >&2
    fail "p114 tables $1: C driver reported failures"
  }
  [ "$(wc -l < "$TMP_DIR/cfg/$1.out" | tr -d ' ')" -eq 14 ] || fail "p114 tables $1: output length"
  [ "$(tail -1 "$TMP_DIR/cfg/$1.out")" = "total 133172 bad 0" ] || fail "p114 tables $1: $(tail -1 "$TMP_DIR/cfg/$1.out")"
  echo "p118 p114 tables $1: total 133172 bad 0"
}
if [ -n "$HT" ]; then
  for x in jtbl bounds; do
    "$QBE" -t "$HT" -o "$TMP_DIR/h_$x.s" "$F/$x.ssa"
  done
  host_run text "$TMP_DIR/h_jtbl.s" "$TMP_DIR/h_bounds.s"
  "$QBE" -t "$HT" -o "$TMP_DIR/cfg/h.s" "$TMP_DIR/cfg/cfg.ssa"
  cfg_run text "$TMP_DIR/cfg/h.s"
  if [ "$OBJ" = 1 ]; then
    for x in jtbl bounds; do
      "$QBE" -t "$HT" --obj -o "$TMP_DIR/h_$x.o" "$F/$x.ssa"
    done
    host_run obj "$TMP_DIR/h_jtbl.o" "$TMP_DIR/h_bounds.o"
    "$QBE" -t "$HT" --obj -o "$TMP_DIR/cfg/h.o" "$TMP_DIR/cfg/cfg.ssa"
    cfg_run obj "$TMP_DIR/cfg/h.o"
    cmp "$TMP_DIR/cfg/text.out" "$TMP_DIR/cfg/obj.out" || fail "p114 tables: --obj and text disagree"
  else
    echo "NOTE: no direct object route on $HOST_S/$HOST_M; text assembly only"
  fi
else
  echo "NOTE: no QBE target for $HOST_S/$HOST_M; skipping host execution"
fi
LOOPS="sink7 sink11 sink14 sink18 sink23 pred14 dup14 dup23"
for x in $LOOPS; do
  echo "$x direct 9"
done > "$TMP_DIR/cfg/loops.txt"
"$QBE" -t amd64_sysv -o "$TMP_DIR/cfg/sysv.s" "$TMP_DIR/cfg/cfg.ssa"
"$QBE" -t amd64_sysv --obj -o "$TMP_DIR/cfg/sysv.o" "$TMP_DIR/cfg/cfg.ssa"
python3 -E "$DIR/check_dispatch.py" "$TMP_DIR/cfg/loops.txt" both "$TMP_DIR/cfg/sysv.s" "$TMP_DIR/cfg/sysv.o"
"$QBE" -t amd64_sysv -d R -o /dev/null "$TMP_DIR/cfg/cfg.ssa" 2> "$TMP_DIR/cfg/r.txt"
python3 -E - "$TMP_DIR/cfg/r.txt" $LOOPS <<'PYEOF'
import re, sys
parts = re.split(r'\*\*\*\* Function (\S+) \*\*\*\*', open(sys.argv[1]).read())
body = dict(zip(parts[1::2], parts[2::2]))
sunk = {n: int(re.search(r'sunk homes: (\d+)', body[n])[1]) for n in sys.argv[2:]}
both = [n for n, k in sunk.items() if k > 0]
if len(both) < 4:
    raise SystemExit(f'FAIL: p118 sunk homes {sunk}')
print(f'p118 p114 tables: %r10 selector and sunk homes together in {len(both)} functions ({sum(sunk.values())} homes)')
PYEOF

# 3. Real programs against C.
for NAME in bytecode_vm fannkuchredux; do
  case "$NAME" in
    bytecode_vm) SRC="$ROOT_DIR/benchmarks/v2/pion/$NAME.pion"; CSRC="$ROOT_DIR/benchmarks/v2/c/$NAME.c" ;;
    *) SRC="$ROOT_DIR/benchmarks/pion/$NAME.pion"; CSRC="$ROOT_DIR/benchmarks/c/$NAME.c" ;;
  esac
  "$CC_BIN" -O2 -o "$TMP_DIR/c_$NAME" "$CSRC" -lm
  "$TMP_DIR/c_$NAME" > "$TMP_DIR/c_$NAME.out"
  [ -s "$TMP_DIR/c_$NAME.out" ] || fail "C $NAME printed nothing"
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = release ] && FLAG="--release"
    "$PIONC" build $FLAG --emit-ssa "$F/${NAME}_$MODE.ssa" -o "$TMP_DIR/${NAME}_$MODE" "$SRC"
    "$TMP_DIR/${NAME}_$MODE" > "$TMP_DIR/${NAME}_$MODE.out"
    cmp "$TMP_DIR/c_$NAME.out" "$TMP_DIR/${NAME}_$MODE.out" || fail "$NAME $MODE output differs from C"
    echo "p118 $NAME $MODE: output == C"
  done
done
for MODE in dev release; do
  IN="$F/bytecode_vm_$MODE.ssa"
  VM=$(sed -n 's/^.*function .*\$\([A-Za-z0-9_.]*run_vm[A-Za-z0-9_.]*\)(.*/\1/p' "$IN")
  [ "$(printf '%s\n' "$VM" | wc -l | tr -d ' ')" -eq 1 ] && [ -n "$VM" ] || fail "bytecode_vm $MODE: run_vm is '$VM'"
  # Entries = the targets after the default in its only jtbl.
  NT=$(awk -v f="\$$VM(" '/^(export )?function /{on = index($0, f) > 0} on && $1 == "jtbl" {print NF - 3}' "$IN")
  echo "$VM direct $NT" > "$TMP_DIR/vm_expect.txt"
  "$QBE" -t amd64_sysv -o "$TMP_DIR/vm.s" "$IN"
  "$QBE" -t amd64_sysv --obj -o "$TMP_DIR/vm.o" "$IN"
  python3 -E "$DIR/check_dispatch.py" "$TMP_DIR/vm_expect.txt" both "$TMP_DIR/vm.s" "$TMP_DIR/vm.o"
  IN="$F/fannkuchredux_$MODE.ssa"
  B=$(grep -c 'cslel .*, 2147483648$' "$IN") || fail "fannkuchredux $MODE: no widened bound in the SSA"
  "$QBE" -d G -o /dev/null "$IN" 2> "$TMP_DIR/fann.g"
  grep -q '> After GVN:' "$TMP_DIR/fann.g" || fail "fannkuchredux $MODE: no GVN dump"
  A=$(grep -c 'cslel .*, 2147483648$' "$TMP_DIR/fann.g" || true)
  [ "$A" -eq 0 ] || fail "fannkuchredux $MODE: $A of $B widened bounds left after GVN"
  echo "p118 fannkuchredux $MODE: $B widened bounds folded"
done

# 4. ASan + UBSan QBE.
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address,undefined -fno-sanitize-recover=all \
  -o "$TMP_DIR/san_probe" 2>/dev/null && "$TMP_DIR/san_probe"; then
  mkdir -p "$TMP_DIR/sanq"
  # Every replay passes -t, so any default target will do.
  printf '#define Deftgt T_amd64_sysv\n' > "$TMP_DIR/sanq/config.h"
  (
    cd "$ROOT_DIR/vendor/qbe"
    for f in *.c amd64/*.c arm64/*.c rv64/*.c; do
      "$CC_BIN" -std=c99 -O1 -g -w -fsanitize=address,undefined -fno-sanitize-recover=all \
        -fno-omit-frame-pointer -I "$TMP_DIR/sanq" -I . -c "$f" -o "$TMP_DIR/sanq/$(printf '%s' "$f" | tr / _).o"
    done
  )
  "$CC_BIN" -fsanitize=address,undefined "$TMP_DIR"/sanq/*.o -o "$TMP_DIR/sanq/qbe"
  export ASAN_OPTIONS="detect_leaks=0:halt_on_error=1"
  export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"
  N=0
  replay() { # $1 input, then qbe options
    in=$1
    shift
    "$QBE" "$@" -o "$TMP_DIR/ref.out" "$in"
    "$TMP_DIR/sanq/qbe" "$@" -o "$TMP_DIR/san.out" "$in" 2> "$TMP_DIR/san.err" || { cat "$TMP_DIR/san.err" >&2; fail "sanitized QBE $* $in"; }
    [ ! -s "$TMP_DIR/san.err" ] || { cat "$TMP_DIR/san.err" >&2; fail "sanitized QBE $* $in wrote diagnostics"; }
    cmp "$TMP_DIR/ref.out" "$TMP_DIR/san.out" || fail "sanitized QBE $* $in: output differs from out/qbe"
    N=$((N + 1))
  }
  for IN in "$F/jtbl.ssa" "$F/bounds.ssa" "$TMP_DIR/cfg/cfg.ssa" "$F/bytecode_vm_dev.ssa" "$F/bytecode_vm_release.ssa" \
    "$F/fannkuchredux_dev.ssa" "$F/fannkuchredux_release.ssa"; do
    for T in amd64_sysv arm64_apple arm64 amd64_win; do
      replay "$IN" -t "$T"
      case "$T" in
        amd64_sysv|arm64_apple) replay "$IN" -t "$T" --obj ;;
      esac
    done
  done
  [ "$N" -eq 42 ] || fail "replayed $N outputs, want 42"
  echo "p118 ASan+UBSan QBE: 42 outputs (7 inputs, 4 targets text, 2 --obj) clean and equal to out/qbe"
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  fail "needs ASan+UBSan (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one"
else
  echo "NOTE: $CC_BIN -fsanitize=address,undefined unavailable; skipping the sanitized QBE replay"
fi

echo "PASS: p118_qbe_jtbl_idx_and_widecmp"
