#!/bin/sh
# P116: byte-identical cold-bootstrap / Mach-O compile-speed changes (Opt-Track P;
# Lean: tests/lean/proofs/QbeColdBootstrapSpeedOpts.lean).
#   parse.c   one byte of lookahead instead of ungetc, reset per input; `s` / `d`
#             check for `_` before the float conversion;
#   live.c    filllive revisits a block only when a successor input changed;
#   util.c    bscopy / bsequal as memmove / memcmp;
#   ssa.c     philive: liveness projected onto the temporaries phiins queries;
#   rega.c    block snapshots copy the active bindings, entry registers in one
#             word (next to sinktablehomes);
#   arm64/macho.c  me_compute_gpr_out composes per-block keep / gen masks;
#   cli/main.pion  the first unit of the largest batch is emitted on the main
#             thread before the workers start; source hashes stay serial.
# Verifies:
#   1. Lexer: gen_il.py fixtures (s / d words, s_ / d_ floats, names > 127
#      bytes, negative and extreme integers, data) and a two-file run whose
#      first file ends without a newline: a C driver checks every value on the
#      host through text assembly and, where QBE writes objects for the host,
#      through `--obj` (exact check counts, `bad 0`; the driver itself under
#      UBSan with alignment checks when available); `--obj-batch` objects equal
#      one `--obj` run per file; four rejected inputs give exit 1 and the exact
#      `qbe:file:line: unknown keyword ...` line.
#   2. Liveness / phi placement / register allocation: flow.ssa (redefined
#      temporaries, loop jtbl with a duplicate entry, dead redefinitions,
#      existing phis, 20 values across a call, argument-free calls, float
#      classes) against C references over 14673 inputs, text and `--obj`.
#   3. A checking QBE (mkcheck.py: the real sources plus in-process oracles,
#      built with ASan + UBSan when available, first report fatal) compiles
#      every input of this test (the fixtures, the p114 jump-table fixture and
#      the SSA of prog/ dev / release) for amd64_sysv, arm64_apple, arm64 and
#      amd64_win (text, plus `--obj` for amd64_sysv / arm64_apple): filllive ==
#      a full sweep for every block, every philive candidate bit == filllive,
#      me_compute_gpr_out == the instruction-by-instruction scan; all its
#      outputs equal out/qbe byte for byte, also with P116_FALLBACK=1 (phi
#      placement from the general liveness); every oracle ran (non-zero
#      counters) and `-d R` reports the same sunk spill homes (> 0).
#   4. Every text output above assembles for its target when clang can
#      assemble a lone `nop` for it.
#   5. prog/ (4-file package, the largest unit is a jump-table interpreter):
#      dev and --release with --jobs 1, 2, 4, 8, each from an empty CAS, give
#      the same CAS units (4 SSA + 4 objects, byte for byte) and, outside
#      Darwin (ld64 gives every link a new LC_UUID), the same binary, printing ref.py's
#      output; Wasm32 and ASan dev / --release print it too.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p116_qbe_compile_speed_parity"
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
fail() {
  echo "FAIL: p116 $*" >&2
  exit 1
}

F="$TMP_DIR/fix"
python3 -E "$DIR/gen_il.py" "$F"

HOST_S="$(uname -s)"
HOST_M="$(uname -m)"
OBJ=0
case "$HOST_S/$HOST_M" in
  Linux/x86_64|Linux/amd64) HT=amd64_sysv; OBJ=1 ;;
  Linux/aarch64|Linux/arm64) HT=arm64 ;;
  Darwin/arm64|Darwin/aarch64) HT=arm64_apple; OBJ=1 ;;
  *) HT="" ;;
esac

# 1a. Rejected inputs: exit status 1 and exactly one diagnostic line.
NERR=0
while IFS="$(printf '\t')" read -r name want; do
  [ -n "$name" ] || continue
  set +e
  (cd "$F" && "$QBE" -o /dev/null "$name") > "$TMP_DIR/err.out" 2> "$TMP_DIR/err.txt"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "$name: exit $rc, want 1"
  [ ! -s "$TMP_DIR/err.out" ] || fail "$name: unexpected stdout"
  printf '%s\n' "$want" > "$TMP_DIR/err.want"
  if ! cmp -s "$TMP_DIR/err.want" "$TMP_DIR/err.txt"; then
    diff -u "$TMP_DIR/err.want" "$TMP_DIR/err.txt" >&2 || true
    fail "$name: wrong diagnostic"
  fi
  NERR=$((NERR + 1))
done < "$F/err_expect.txt"
[ "$NERR" -eq 4 ] || fail "checked $NERR rejected inputs, want 4"
echo "p116 lexer: 4 rejected inputs, exact diagnostics"

# 1b. --obj-batch == one --obj run per file (the lookahead is per input).
for T in amd64_sysv arm64_apple; do
  "$QBE" -t "$T" --obj-batch "$F/lexa.ssa" "$TMP_DIR/ba_$T.o" "$F/lexb.ssa" "$TMP_DIR/bb_$T.o" "$F/lex.ssa" "$TMP_DIR/bl_$T.o"
  "$QBE" -t "$T" --obj -o "$TMP_DIR/sa_$T.o" "$F/lexa.ssa"
  "$QBE" -t "$T" --obj -o "$TMP_DIR/sb_$T.o" "$F/lexb.ssa"
  "$QBE" -t "$T" --obj -o "$TMP_DIR/sl_$T.o" "$F/lex.ssa"
  for x in a b l; do
    cmp "$TMP_DIR/b${x}_$T.o" "$TMP_DIR/s${x}_$T.o" || fail "$T --obj-batch object $x differs from --obj"
  done
done
echo "p116 lexer: --obj-batch == per-file --obj (amd64_sysv, arm64_apple)"

# 1c + 2. Host execution against the C references.
EXPECT_RUN="lex 40
multifile 59
flow 14673
total 14772 bad 0"
# The C driver itself runs under UBSan (alignment included, first report fatal) when available.
DRV_SAN=""
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=undefined,alignment -fno-sanitize-recover=all \
  -o "$TMP_DIR/drv_probe" 2>/dev/null && "$TMP_DIR/drv_probe"; then
  DRV_SAN="-fsanitize=undefined,alignment -fno-sanitize-recover=all"
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  fail "needs UBSan for the C driver (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one"
fi
echo "p116 C driver sanitizers: ${DRV_SAN:-<none>}"
host_run() { # $1 label, then objects / assembly files
  label=$1
  shift
  "$CC_BIN" -O1 -ffp-contract=off $DRV_SAN "$F/check.c" "$@" -o "$TMP_DIR/check_$label"
  UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$TMP_DIR/check_$label" > "$TMP_DIR/check_$label.out" || {
    cat "$TMP_DIR/check_$label.out" >&2
    fail "host $label: C driver reported failures"
  }
  printf '%s\n' "$EXPECT_RUN" > "$TMP_DIR/check.want"
  if ! cmp -s "$TMP_DIR/check.want" "$TMP_DIR/check_$label.out"; then
    diff -u "$TMP_DIR/check.want" "$TMP_DIR/check_$label.out" >&2 || true
    fail "host $label: unexpected driver output"
  fi
  echo "p116 host $label: 14772 checks, bad 0"
}
if [ -n "$HT" ]; then
  "$QBE" -t "$HT" -o "$TMP_DIR/h_lex.s" "$F/lex.ssa"
  (cd "$F" && "$QBE" -t "$HT" -o "$TMP_DIR/h_mf.s" lexa.ssa lexb.ssa)
  "$QBE" -t "$HT" -o "$TMP_DIR/h_flow.s" "$F/flow.ssa"
  host_run text "$TMP_DIR/h_lex.s" "$TMP_DIR/h_mf.s" "$TMP_DIR/h_flow.s"
  if [ "$OBJ" = 1 ]; then
    "$QBE" -t "$HT" --obj -o "$TMP_DIR/h_lex.o" "$F/lex.ssa"
    (cd "$F" && "$QBE" -t "$HT" --obj -o "$TMP_DIR/h_mf.o" lexa.ssa lexb.ssa)
    "$QBE" -t "$HT" --obj -o "$TMP_DIR/h_flow.o" "$F/flow.ssa"
    host_run obj "$TMP_DIR/h_lex.o" "$TMP_DIR/h_mf.o" "$TMP_DIR/h_flow.o"
  else
    echo "NOTE: no direct object route on $HOST_S/$HOST_M; text assembly only"
  fi
else
  echo "NOTE: no QBE target for $HOST_S/$HOST_M; skipping host execution"
fi

# 5. prog/: --jobs 1 / 2 / 4 / 8 from empty CASes, dev and --release.
PROG="$DIR/prog"
python3 -E "$DIR/ref.py" > "$TMP_DIR/prog.want"
[ "$(wc -l < "$TMP_DIR/prog.want" | tr -d ' ')" -eq 7 ] || fail "ref.py output has the wrong length"
check_prog() { # $1 label, $2 output
  if ! cmp -s "$TMP_DIR/prog.want" "$2"; then
    diff -u "$TMP_DIR/prog.want" "$2" >&2 || true
    fail "prog $1"
  fi
}
cas_digest() { # every SSA unit and object of a CAS: relative path, size, SHA-256
  python3 -E - "$1" <<'PYEOF'
import hashlib, os, sys
root = sys.argv[1]
rows = []
for sub in ('ssa', 'obj'):
    for dp, _, fs in os.walk(os.path.join(root, sub)):
        for f in fs:
            if '.tmp.' in f:
                raise SystemExit(f"FAIL: p116 temporary file left in the CAS: {f}")
            p = os.path.join(dp, f)
            rows.append((os.path.relpath(p, root), os.path.getsize(p), hashlib.sha256(open(p, 'rb').read()).hexdigest()))
if sum(r[0].startswith('ssa' + os.sep) for r in rows) != 4 or sum(r[0].startswith('obj' + os.sep) for r in rows) != 4:
    raise SystemExit(f"FAIL: p116 CAS holds {[r[0] for r in rows]}, want 4 SSA units and 4 objects")
for r in sorted(rows):
    print(*r)
PYEOF
}
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = release ] && FLAG="--release"
  for J in 1 2 4 8; do
    rm -rf "$TMP_DIR/cas_j"
    mkdir -p "$TMP_DIR/cas_j"
    PION_CACHE_DIR="$TMP_DIR/cas_j" "$PIONC" build $FLAG --jobs "$J" -o "$TMP_DIR/prog_${MODE}_$J" "$PROG"
    N=$(find "$TMP_DIR/cas_j/ssa" -name '*.ssa' -type f | wc -l | tr -d ' ')
    [ "$N" -eq 4 ] || fail "prog $MODE --jobs $J: $N CAS SSA units, want 4"
    "$TMP_DIR/prog_${MODE}_$J" > "$TMP_DIR/prog_${MODE}_$J.out"
    check_prog "$MODE --jobs $J" "$TMP_DIR/prog_${MODE}_$J.out"
    cas_digest "$TMP_DIR/cas_j" > "$TMP_DIR/cas_${MODE}_$J.txt"
    cmp "$TMP_DIR/cas_${MODE}_1.txt" "$TMP_DIR/cas_${MODE}_$J.txt" || fail "prog $MODE: --jobs $J CAS units differ from --jobs 1"
    # Two ld64 links of the same objects differ (LC_UUID); ELF links are byte-stable.
    if [ "$HOST_S" != Darwin ]; then
      cmp "$TMP_DIR/prog_${MODE}_1" "$TMP_DIR/prog_${MODE}_$J" || fail "prog $MODE: --jobs $J binary differs from --jobs 1"
    fi
  done
  if [ "$HOST_S" != Darwin ]; then
    echo "p116 prog native $MODE: --jobs 1/2/4/8 identical binaries and CAS units (4 SSA + 4 objects), output == ref.py"
  else
    echo "p116 prog native $MODE: --jobs 1/2/4/8 identical CAS units (4 SSA + 4 objects), output == ref.py"
  fi
  "$PIONC" build $FLAG --emit-ssa "$TMP_DIR/prog_$MODE.ssa" -o "$TMP_DIR/prog_ssa_$MODE" "$PROG"
  "$TMP_DIR/prog_ssa_$MODE" > "$TMP_DIR/prog_ssa_$MODE.out"
  check_prog "$MODE --emit-ssa" "$TMP_DIR/prog_ssa_$MODE.out"
  grep -q '^[[:space:]]*jtbl ' "$TMP_DIR/prog_$MODE.ssa" || fail "prog $MODE SSA has no jtbl"
done
if command -v node >/dev/null 2>&1; then
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = release ] && FLAG="--release"
    "$PIONC" build $FLAG --target wasm32 -o "$TMP_DIR/prog_$MODE.wasm" "$PROG"
    node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/prog_$MODE.wasm" > "$TMP_DIR/prog_w$MODE.out"
    check_prog "wasm32 $MODE" "$TMP_DIR/prog_w$MODE.out"
  done
  echo "p116 prog wasm32 dev / release: output == ref.py"
else
  echo "NOTE: node unavailable; skipping p116 Wasm32 checks"
fi

# Sanitizer probes (a missing sanitizer only skips with PION_REQUIRE_SANITIZERS unset).
ASAN=0
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$TMP_DIR/asan_probe"; then
  ASAN=1
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  fail "needs ASan (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one"
else
  echo "NOTE: $CC_BIN -fsanitize=address unavailable; skipping p116 ASan checks"
fi
SAN_FLAGS=""
if [ "$ASAN" = 1 ] && printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address,undefined \
  -fno-sanitize-recover=all -o "$TMP_DIR/ubsan_probe" 2>/dev/null && "$TMP_DIR/ubsan_probe"; then
  SAN_FLAGS="-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer"
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  fail "needs ASan+UBSan (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one"
fi
if [ "$ASAN" = 1 ]; then
  CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/prog.o" "$PROG"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/prog.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/prog_asan"
    ASAN_OPTIONS=detect_leaks=0 "$TMP_DIR/prog_asan" > "$TMP_DIR/prog_asan.out"
    check_prog "ASan ${MODE:-dev}" "$TMP_DIR/prog_asan.out"
  done
  echo "p116 prog ASan dev / release: output == ref.py"
fi

# 3. Checking QBE over every input, four targets.
mkdir -p "$TMP_DIR/cfg"
python3 -E "$ROOT_DIR/tests/e2e/p114_qbe_jtbl_edge_spill/gen_cfg.py" "$TMP_DIR/cfg"
cp "$TMP_DIR/cfg/cfg.ssa" "$F/jtbl_cfg.ssa"
cp "$TMP_DIR/prog_dev.ssa" "$F/prog_dev.ssa"
cp "$TMP_DIR/prog_release.ssa" "$F/prog_release.ssa"
INPUTS="lex.ssa flow.ssa jtbl_cfg.ssa prog_dev.ssa prog_release.ssa"
python3 -E "$DIR/mkcheck.py" "$ROOT_DIR/vendor/qbe" "$TMP_DIR/cq"
printf '#define Deftgt T_amd64_sysv\n' > "$TMP_DIR/cq/config.h"
echo "p116 checking QBE sanitizers: ${SAN_FLAGS:-<none>}"
if [ -n "$SAN_FLAGS" ] && [ -n "${PION_QBE_SAN_DIR:-}" ] && [ -d "$PION_QBE_SAN_DIR/obj" ] \
  && { [ ! -f "$PION_QBE_SAN_DIR/qbe.cc" ] || [ "$(cat "$PION_QBE_SAN_DIR/qbe.cc")" = "$CC_BIN" ]; }; then
  # mkcheck.py modifies only live.c, ssa.c and arm64/macho.c: compile those 3
  # and link with the prebuilt ASan+UBSan QBE objects for all other units.
  CQ_OBJS=""
  for O in "$PION_QBE_SAN_DIR"/obj/*.o; do
    case "$O" in
      */live.c.o|*/ssa.c.o|*/arm64_macho.c.o) continue ;;
    esac
    CQ_OBJS="$CQ_OBJS $O"
  done
  for f in live.c ssa.c arm64/macho.c; do
    O="$TMP_DIR/cq/$(printf '%s' "$f" | tr / _).o"
    "$CC_BIN" -std=c99 -O1 -g -w $SAN_FLAGS -I "$PION_QBE_SAN_DIR" -I "$TMP_DIR/cq" -c "$TMP_DIR/cq/$f" -o "$O"
    CQ_OBJS="$CQ_OBJS $O"
  done
  "$CC_BIN" $SAN_FLAGS $CQ_OBJS -o "$TMP_DIR/cq/qbe"
else
  python3 -E - "$CC_BIN" "$SAN_FLAGS" "$TMP_DIR/cq" <<'PYEOF'
import glob, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
cc, san_str, cq = sys.argv[1:4]
san = san_str.split() if san_str else []
srcs = sorted(glob.glob("*.c", root_dir=cq) + glob.glob("amd64/*.c", root_dir=cq)
              + glob.glob("arm64/*.c", root_dir=cq) + glob.glob("rv64/*.c", root_dir=cq))
jobs = min(os.cpu_count() or 1, 8)
def build(f):
    o = os.path.join(cq, f.replace("/", "_") + ".o")
    r = subprocess.run([cc, "-std=c99", "-O1", "-g", "-w", *san, "-I", cq, "-c", os.path.join(cq, f), "-o", o])
    if r.returncode != 0:
        raise SystemExit(1)
    return o
with ThreadPoolExecutor(max_workers=jobs) as pool:
    objs = list(pool.map(build, srcs))
r = subprocess.run([cc, *san, *objs, "-o", os.path.join(cq, "qbe")])
if r.returncode != 0:
    raise SystemExit(1)
PYEOF
fi
CQ="$TMP_DIR/cq/qbe"
export ASAN_OPTIONS="detect_leaks=0:halt_on_error=1"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"
STATS="$TMP_DIR/stats.txt"
: > "$STATS"
NOUT=0
for T in amd64_sysv arm64_apple arm64 amd64_win; do
  for IN in $INPUTS; do
    B="${IN%.ssa}_$T"
    "$QBE" -t "$T" -o "$TMP_DIR/r_$B.s" "$F/$IN"
    P116_STATS="$STATS" "$CQ" -t "$T" -o "$TMP_DIR/c_$B.s" "$F/$IN" 2> "$TMP_DIR/c.err" || { cat "$TMP_DIR/c.err" >&2; fail "checking QBE $T $IN"; }
    [ ! -s "$TMP_DIR/c.err" ] || { cat "$TMP_DIR/c.err" >&2; fail "checking QBE $T $IN wrote diagnostics"; }
    P116_FALLBACK=1 "$CQ" -t "$T" -o "$TMP_DIR/g_$B.s" "$F/$IN"
    cmp "$TMP_DIR/r_$B.s" "$TMP_DIR/c_$B.s" || fail "$T $IN: checking QBE text differs from out/qbe"
    cmp "$TMP_DIR/r_$B.s" "$TMP_DIR/g_$B.s" || fail "$T $IN: general-liveness phi placement differs"
    NOUT=$((NOUT + 1))
    case "$T" in
      amd64_sysv|arm64_apple)
        "$QBE" -t "$T" --obj -o "$TMP_DIR/r_$B.o" "$F/$IN"
        P116_STATS="$STATS" "$CQ" -t "$T" --obj -o "$TMP_DIR/c_$B.o" "$F/$IN"
        P116_FALLBACK=1 "$CQ" -t "$T" --obj -o "$TMP_DIR/g_$B.o" "$F/$IN"
        cmp "$TMP_DIR/r_$B.o" "$TMP_DIR/c_$B.o" || fail "$T $IN: checking QBE --obj differs from out/qbe"
        cmp "$TMP_DIR/r_$B.o" "$TMP_DIR/g_$B.o" || fail "$T $IN: general-liveness --obj differs"
        NOUT=$((NOUT + 1))
        ;;
    esac
  done
  "$QBE" -t "$T" -d R -o /dev/null "$F/jtbl_cfg.ssa" 2> "$TMP_DIR/r_dr_$T.txt"
  "$CQ" -t "$T" -d R -o /dev/null "$F/jtbl_cfg.ssa" 2> "$TMP_DIR/c_dr_$T.txt"
  cmp "$TMP_DIR/r_dr_$T.txt" "$TMP_DIR/c_dr_$T.txt" || fail "$T: -d R dumps differ"
  SUNK=$(sed -n 's/.*sunk homes: \([0-9][0-9]*\).*/\1/p' "$TMP_DIR/r_dr_$T.txt" | awk '{s += $1} END {print s + 0}')
  [ "$SUNK" -gt 0 ] || fail "$T: jtbl fixture sinks no spill home"
  echo "p116 checking QBE $T: outputs == out/qbe (also with general phi liveness), sunk homes $SUNK"
done
[ "$NOUT" -eq 30 ] || fail "compared $NOUT outputs, want 30"
python3 -E - "$STATS" <<'PYEOF'
import sys
tot = {}
lines = [ln.split() for ln in open(sys.argv[1]).read().split('\n') if ln.strip()]
if len(lines) != 30:
    raise SystemExit(f"FAIL: p116 {len(lines)} checking QBE stat lines, want 30")
for ln in lines:
    if len(ln) != 18:
        raise SystemExit(f"FAIL: p116 malformed stat line {ln}")
    for k, v in zip(ln[0::2], ln[1::2]):
        tot[k] = tot.get(k, 0) + int(v)
need = ['live_calls', 'live_blocks', 'live_skips', 'phi_fns', 'phi_cands', 'phi_bits', 'gpr_fns', 'gpr_blocks']
zero = [k for k in need if tot.get(k, 0) <= 0]
if zero or tot.get('phi_general', -1) != 0:
    raise SystemExit(f"FAIL: p116 checking QBE counters {tot}: {zero} must be > 0, phi_general must be 0")
print("p116 oracles: " + ", ".join(f"{k} {tot[k]}" for k in need + ['phi_general']))
PYEOF

# 4. Text outputs assemble for every target clang can assemble for.
printf '\t.text\n\tnop\n' > "$TMP_DIR/probe.s"
NASM=0
for T in amd64_sysv arm64_apple arm64 amd64_win; do
  case "$T" in
    amd64_sysv) TRIPLE=x86_64-linux-gnu ;;
    arm64_apple) TRIPLE=arm64-apple-macos12 ;;
    arm64) TRIPLE=aarch64-linux-gnu ;;
    amd64_win) TRIPLE=x86_64-w64-windows-gnu ;;
  esac
  if command -v clang >/dev/null 2>&1 && clang --target="$TRIPLE" -c "$TMP_DIR/probe.s" -o "$TMP_DIR/probe.o" 2>/dev/null; then
    for IN in $INPUTS; do
      B="${IN%.ssa}_$T"
      clang --target="$TRIPLE" -c "$TMP_DIR/r_$B.s" -o "$TMP_DIR/a_$B.o" || fail "$T $IN: clang --target=$TRIPLE cannot assemble"
      NASM=$((NASM + 1))
    done
    echo "p116 $T text assembles with clang --target=$TRIPLE"
  else
    echo "NOTE: no clang assembler for $TRIPLE; skipping $T assembly"
  fi
done
echo "p116 assembled $NASM text outputs"

echo "PASS: p116_qbe_compile_speed_parity"
