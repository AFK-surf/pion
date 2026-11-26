#!/bin/sh
# P122: arm64_apple guarded jump-table dispatch copies (Opt-Track U;
# Lean: tests/lean/proofs/QbeArm64GuardedDispatch.lean).
#   main.c replicatedispatch, after rega / simpljmp and only for arm64_apple:
#   a hot loop-internal predecessor (b->loop >= head->loop, not only a strict
#   back edge) ending in `jmp` to a short guard block (>= 3 predecessors, no
#   call, <= 16 instructions) of which either side is a private short jump
#   table (one predecessor, <= 32 entries, no call, <= 16 instructions) gets
#   the guard appended and its own copy of the table block (<= 24 copies per
#   function).
# Verifies:
#   1. gen_il.py dispatch.ssa: `guarded` / `guarded_rev` (table on either side
#      of the guard, default, duplicate entries, per-iteration stores) go from
#      1 to 5 `br` sites on arm64_apple, text and Mach-O `--obj` alike;
#      `dual_bigfirst` / `dual_bigsecond` (both guard sides are tables, the
#      33-entry one on either side) both copy the 5-entry table (2 -> 6
#      sites); `reshare` (a rewritten predecessor shares the other table with
#      the guard, and edges into it then see that table) copies no shared
#      table (6 sites); `cap31` (31 arms back to the guard) stops at the
#      24-copy limit (1 + 24 sites); the eight `c_*` controls (call in the guard / table, > 16 instructions in
#      the guard / table, 33 entries, a shared table, two guard predecessors,
#      no loop) keep theirs; arm64, amd64_sysv, amd64_win, amd64_apple and
#      rv64 keep one indirect branch per table (check_sites.py, which must
#      reject a dropped `br`, a text/--obj mismatch and a missing function).
#   2. Eight QBE mutants (mk_mutants.py): six each without one condition, so
#      exactly the control aimed at it gets copies (every control is a near
#      miss), and MaxSites 23 / 25, which move cap31 to 24 / 26 sites.
#   3. check.c: 14 functions x 512 rounds x 34 bounds (n = -1..32; selectors
#      0..4, 0x80000000, 0xffffffff, arbitrary words; wrapping arithmetic),
#      result and all 32 trace slots against a C reference: natively through
#      arm64_apple text and --obj on macOS ARM64 (amd64_sysv text and --obj on
#      Linux x86-64), the driver under UBSan.
#   4. bytecode_vm (benchmarks/v2) dev / --release prints the C program's
#      output (on macOS ARM64 through the copied dispatch); the --release
#      run_vm has 24 `br` sites on arm64_apple (the table and 23 copies, under
#      the limit; text == --obj) and one
#      indirect branch on every other target.
#   5. An ASan + UBSan QBE (first report fatal) replays dispatch.ssa and both
#      bytecode_vm SSA files for six targets (text, plus --obj for arm64_apple
#      and amd64_sysv) with output equal to out/qbe byte for byte; the
#      mutants of 2 are built from the same sanitized objects.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p122_arm64_guarded_dispatch"
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC_BIN="${CC:-cc}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"
fail() {
  echo "FAIL: p122 $*" >&2
  exit 1
}
[ -x "$QBE" ] || fail "QBE binary not found at $QBE"

F="$TMP_DIR/fix"
python3 -E "$DIR/gen_il.py" "$F"
[ "$(wc -l < "$F/expect.txt" | tr -d ' ')" -eq 14 ] || fail "expect.txt length"
TARGETS="arm64_apple arm64 amd64_sysv amd64_win amd64_apple rv64"

# 1. Dispatch sites per target; arm64_apple text == --obj.
for T in $TARGETS; do
  "$QBE" -t "$T" -o "$TMP_DIR/d_$T.s" "$F/dispatch.ssa"
  python3 -E "$DIR/check_sites.py" "$F/expect.txt" "$T" "$TMP_DIR/d_$T.s"
done
"$QBE" -t arm64_apple --obj -o "$TMP_DIR/d.o" "$F/dispatch.ssa"
python3 -E "$DIR/check_sites.py" "$F/expect.txt" arm64_apple "$TMP_DIR/d_arm64_apple.s" "$TMP_DIR/d.o"
"$QBE" -t amd64_sysv --obj -o "$TMP_DIR/d_sysv.o" "$F/dispatch.ssa"
# The checker must reject tampered output.
python3 -E - "$TMP_DIR/d_arm64_apple.s" "$TMP_DIR/d.o" "$TMP_DIR" <<'PYEOF'
import re, sys
text, obj, out = open(sys.argv[1]).read(), open(sys.argv[2], 'rb').read(), sys.argv[3]
s = text.index('\n_guarded:\n')
e = text.index('/* end function guarded */', s)
body = text[s:e]
k = body.index('\tbr\tx')
# a: one copy's `br` gone; b: the function renamed away.
open(f'{out}/mut_a.s', 'w').write(text[:s] + body[:k] + '\tnop' + body[body.index('\n', k):] + text[e:])
open(f'{out}/mut_b.s', 'w').write(text.replace('_guarded_rev:', '_renamed:').replace('end function guarded_rev ', 'end function renamed '))
# c: one `br x17` word of the object turned into `nop`.
w = bytes.fromhex('20021fd6')  # br x17
if obj.count(w) != 62:
    raise SystemExit(f'FAIL: p122 object has {obj.count(w)} `br x17` words, want 62')
open(f'{out}/mut_c.o', 'wb').write(obj.replace(w, bytes.fromhex('1f2003d5'), 1))
PYEOF
rejects() { # $1 label, $2 text the report must contain, then the checker arguments
  label=$1
  want=$2
  shift 2
  if python3 -E "$DIR/check_sites.py" "$@" > "$TMP_DIR/mut.out" 2>&1; then
    fail "checker accepts mutation $label"
  fi
  grep -q '^FAIL: p122 ' "$TMP_DIR/mut.out" && grep -qF "$want" "$TMP_DIR/mut.out" || {
    cat "$TMP_DIR/mut.out" >&2
    fail "mutation $label: rejected for another reason"
  }
}
rejects dropped-br "guarded has 4 indirect branches, want 5" "$F/expect.txt" arm64_apple "$TMP_DIR/mut_a.s"
rejects missing "function guarded_rev not found" "$F/expect.txt" arm64_apple "$TMP_DIR/mut_b.s"
rejects obj-br "guarded has 4 br words, text has 5" "$F/expect.txt" arm64_apple "$TMP_DIR/d_arm64_apple.s" "$TMP_DIR/mut_c.o"
rejects other-target "guarded has 5 indirect branches, want 1" "$F/expect.txt" arm64 "$TMP_DIR/d_arm64_apple.s"
echo "p122 site checker rejects 4 mutations"

# Sanitized QBE objects (2 and 5); reuse prebuilt $PION_QBE_SAN_DIR when available.
SAN=""
Q="$TMP_DIR/sanq"
mkdir -p "$Q"
export ASAN_OPTIONS="detect_leaks=0:halt_on_error=1"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"
if [ -n "${PION_QBE_SAN_DIR:-}" ] && [ -x "$PION_QBE_SAN_DIR/qbe" ] && [ -d "$PION_QBE_SAN_DIR/obj" ] \
  && { [ ! -f "$PION_QBE_SAN_DIR/qbe.cc" ] || [ "$(cat "$PION_QBE_SAN_DIR/qbe.cc")" = "$CC_BIN" ]; }; then
  SAN="-fsanitize=address,undefined -fno-sanitize-recover=all"
  Q_OBJ_DIR="$PION_QBE_SAN_DIR/obj"
  Q_INC_DIR="$PION_QBE_SAN_DIR"
  Q_BIN="$PION_QBE_SAN_DIR/qbe"
else
  SAN_RC=0
  CC="$CC_BIN" sh "$ROOT_DIR/scripts/build-qbe-san.sh" "$Q" || SAN_RC=$?
  if [ "$SAN_RC" -eq 0 ]; then
    SAN="-fsanitize=address,undefined -fno-sanitize-recover=all"
    Q_OBJ_DIR="$Q/obj"
    Q_INC_DIR="$Q"
    Q_BIN="$Q/qbe"
  elif [ "$SAN_RC" -eq 77 ]; then
    if [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
      fail "needs ASan+UBSan (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one"
    fi
    echo "NOTE: $CC_BIN -fsanitize=address,undefined unavailable; mutants unsanitized, no sanitized replay"
    mkdir -p "$Q/obj"
    printf '#define Deftgt T_amd64_sysv\n' > "$Q/config.h"
    python3 -E - "$CC_BIN" "$ROOT_DIR/vendor/qbe" "$Q" <<'PYEOF'
import glob, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
cc, qbe_dir, out_dir = sys.argv[1:4]
obj_dir = os.path.join(out_dir, "obj")
srcs = sorted(glob.glob("*.c", root_dir=qbe_dir) + glob.glob("amd64/*.c", root_dir=qbe_dir)
              + glob.glob("arm64/*.c", root_dir=qbe_dir) + glob.glob("rv64/*.c", root_dir=qbe_dir))
srcs = [s for s in srcs if s != "main.c"]
jobs = min(os.cpu_count() or 1, 8)
def build(s):
    o = os.path.join(obj_dir, s.replace("/", "_") + ".o")
    r = subprocess.run([cc, "-std=c99", "-O1", "-g", "-w", "-fno-omit-frame-pointer",
                        "-I", out_dir, "-I", qbe_dir, "-c", os.path.join(qbe_dir, s), "-o", o])
    if r.returncode != 0:
        raise SystemExit(1)
with ThreadPoolExecutor(max_workers=jobs) as pool:
    list(pool.map(build, srcs))
PYEOF
    Q_OBJ_DIR="$Q/obj"
    Q_INC_DIR="$Q"
    Q_BIN="$Q/qbe"
  else
    fail "sanitized QBE build failed (exit $SAN_RC)"
  fi
fi
Q_BASE_OBJS=""
for o in "$Q_OBJ_DIR"/*.o; do
  case "$o" in
    */main.c.o) continue ;;
  esac
  Q_BASE_OBJS="$Q_BASE_OBJS $o"
done
qbe_with() { # $1 main.c source, $2 output binary
  "$CC_BIN" -std=c99 -O1 -g -w $SAN -fno-omit-frame-pointer -I "$Q_INC_DIR" -I "$ROOT_DIR/vendor/qbe" -c "$1" -o "$2.o"
  "$CC_BIN" $SAN $Q_BASE_OBJS "$2.o" -o "$2"
}
if [ ! -x "$Q_BIN" ]; then
  qbe_with "$ROOT_DIR/vendor/qbe/main.c" "$Q_BIN"
fi
[ "$(ls "$Q_OBJ_DIR"/*.o | wc -l | tr -d ' ')" -ge 20 ] || fail "sanitized QBE: objects missing"

# 2. Mutants: each control is rejected by its own condition only (bounded parallel compile + run).
MUTS=$(python3 -E "$DIR/mk_mutants.py" "$ROOT_DIR/vendor/qbe/main.c" "$Q")
python3 -E - "$CC_BIN" "$SAN" "$Q_INC_DIR" "$ROOT_DIR/vendor/qbe" "$Q_OBJ_DIR" "$Q" "$TMP_DIR" "$F" "$DIR/check_sites.py" $MUTS <<'PYEOF'
import glob, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

cc, san_str, q_inc, qbe_dir, q_obj_dir, q_dir, tmp_dir, f_dir, checker = sys.argv[1:10]
muts = sys.argv[10:]
if len(muts) != 8:
    raise SystemExit(f"FAIL: p122 {len(muts)} mutants, want 8")
san = san_str.split() if san_str else []
base_objs = sorted(o for o in glob.glob(os.path.join(q_obj_dir, "*.o")) if os.path.basename(o) != "main.c.o")
jobs = min(os.cpu_count() or 1, 4)

def run_mutant(m):
    src = os.path.join(q_dir, f"main_{m}.c")
    obj = os.path.join(q_dir, f"qbe_{m}.o")
    exe = os.path.join(q_dir, f"qbe_{m}")
    r = subprocess.run([cc, "-std=c99", "-O1", "-g", "-w", *san, "-fno-omit-frame-pointer",
                        "-I", q_inc, "-I", qbe_dir, "-c", src, "-o", obj])
    if r.returncode != 0:
        raise SystemExit(f"FAIL: p122 mutant {m} compile")
    r = subprocess.run([cc, *san, *base_objs, obj, "-o", exe])
    if r.returncode != 0:
        raise SystemExit(f"FAIL: p122 mutant {m} link")
    out_s = os.path.join(tmp_dir, f"m_{m}.s")
    r = subprocess.run([exe, "-t", "arm64_apple", "-o", out_s, os.path.join(f_dir, "dispatch.ssa")],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        raise SystemExit(f"FAIL: p122 mutant {m}")
    if r.stderr:
        sys.stderr.write(r.stderr)
        raise SystemExit(f"FAIL: p122 mutant {m} wrote diagnostics")
    r = subprocess.run([sys.executable, "-E", checker, os.path.join(f_dir, f"expect_{m}.txt"), "arm64_apple", out_s],
                       stdout=subprocess.DEVNULL)
    if r.returncode != 0:
        raise SystemExit(f"FAIL: p122 mutant {m} expect check")
    r = subprocess.run([sys.executable, "-E", checker, os.path.join(f_dir, "expect.txt"), "arm64_apple", out_s],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if r.returncode == 0:
        raise SystemExit(f"FAIL: p122 mutant {m} changes no control")

with ThreadPoolExecutor(max_workers=jobs) as pool:
    list(pool.map(run_mutant, muts))
PYEOF
echo "p122 mutants: each of $MUTS changes exactly its control"

# 3. Host execution against the C reference.
DRV_SAN=""
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=undefined -fno-sanitize-recover=all \
  -o "$TMP_DIR/drv_probe" 2>/dev/null && "$TMP_DIR/drv_probe"; then
  DRV_SAN="-fsanitize=undefined -fno-sanitize-recover=all"
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = 1 ]; then
  fail "needs UBSan for the C driver (PION_REQUIRE_SANITIZERS=1) but $CC_BIN cannot build one"
fi
HOST="$(uname -s)/$(uname -m)"
case "$HOST" in
  Darwin/arm64|Darwin/aarch64) HT=arm64_apple ;;
  Linux/x86_64|Linux/amd64) HT=amd64_sysv ;;
  *) HT="" ;;
esac
host_run() { # $1 label, $2 object or assembly file
  "$CC_BIN" -O1 $DRV_SAN "$DIR/check.c" "$2" -o "$TMP_DIR/check_$1"
  "$TMP_DIR/check_$1" > "$TMP_DIR/check_$1.out" || {
    cat "$TMP_DIR/check_$1.out" >&2
    fail "host $1: C driver reported failures"
  }
  [ "$(cat "$TMP_DIR/check_$1.out")" = "checks 243712 bad 0 opaque called" ] || fail "host $1: $(cat "$TMP_DIR/check_$1.out")"
  echo "p122 host $HT $1: 243712 checks (14 functions x 512 x 34), bad 0"
}
if [ -n "$HT" ]; then
  host_run text "$TMP_DIR/d_$HT.s"
  if [ "$HT" = arm64_apple ]; then
    host_run obj "$TMP_DIR/d.o"
  else
    host_run obj "$TMP_DIR/d_sysv.o"
  fi
else
  echo "NOTE: no direct-object QBE target for $HOST; skipping host execution"
fi

# 4. bytecode_vm against C; run_vm dispatch sites.
SRC="$ROOT_DIR/benchmarks/v2/pion/bytecode_vm.pion"
"$CC_BIN" -O2 -o "$TMP_DIR/c_vm" "$ROOT_DIR/benchmarks/v2/c/bytecode_vm.c" -lm
"$TMP_DIR/c_vm" > "$TMP_DIR/c_vm.out"
[ -s "$TMP_DIR/c_vm.out" ] || fail "C bytecode_vm printed nothing"
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = release ] && FLAG="--release"
  "$PIONC" build $FLAG --emit-ssa "$F/vm_$MODE.ssa" -o "$TMP_DIR/vm_$MODE" "$SRC"
  "$TMP_DIR/vm_$MODE" > "$TMP_DIR/vm_$MODE.out"
  cmp "$TMP_DIR/c_vm.out" "$TMP_DIR/vm_$MODE.out" || fail "bytecode_vm $MODE output differs from C"
  echo "p122 bytecode_vm $MODE ($HOST): output == C"
done
IN="$F/vm_release.ssa"
VM=$(sed -n 's/^.*function .*\$\([A-Za-z0-9_.]*run_vm[A-Za-z0-9_.]*\)(.*/\1/p' "$IN")
[ "$(printf '%s\n' "$VM" | wc -l | tr -d ' ')" -eq 1 ] && [ -n "$VM" ] || fail "bytecode_vm: run_vm is '$VM'"
NT=$(awk -v f="\$$VM(" '/^(export )?function /{on = index($0, f) > 0} on && $1 == "jtbl" {n++} END {print n + 0}' "$IN")
[ "$NT" -eq 1 ] || fail "bytecode_vm: $VM has $NT jump tables, want 1"
# 24 = the table and one copy for each of its 23 loop-internal predecessors
# (under the 24-copy limit, which cap31 checks).
echo "$VM 1 24" > "$TMP_DIR/vm_expect.txt"
for T in $TARGETS; do
  "$QBE" -t "$T" -o "$TMP_DIR/vm_$T.s" "$IN"
  python3 -E "$DIR/check_sites.py" "$TMP_DIR/vm_expect.txt" "$T" "$TMP_DIR/vm_$T.s"
done
"$QBE" -t arm64_apple --obj -o "$TMP_DIR/vm.o" "$IN"
python3 -E "$DIR/check_sites.py" "$TMP_DIR/vm_expect.txt" arm64_apple "$TMP_DIR/vm_arm64_apple.s" "$TMP_DIR/vm.o"

# 5. ASan + UBSan QBE replay.
if [ -n "$SAN" ]; then
  N=0
  replay() { # $1 input, then qbe options
    in=$1
    shift
    "$QBE" "$@" -o "$TMP_DIR/ref.out" "$in"
    "$Q_BIN" "$@" -o "$TMP_DIR/san.out" "$in" 2> "$TMP_DIR/san.err" || { cat "$TMP_DIR/san.err" >&2; fail "sanitized QBE $* $in"; }
    [ ! -s "$TMP_DIR/san.err" ] || { cat "$TMP_DIR/san.err" >&2; fail "sanitized QBE $* $in wrote diagnostics"; }
    cmp "$TMP_DIR/ref.out" "$TMP_DIR/san.out" || fail "sanitized QBE $* $in: output differs from out/qbe"
    N=$((N + 1))
  }
  for IN in "$F/dispatch.ssa" "$F/vm_dev.ssa" "$F/vm_release.ssa"; do
    for T in $TARGETS; do
      replay "$IN" -t "$T"
      case "$T" in
        arm64_apple|amd64_sysv) replay "$IN" -t "$T" --obj ;;
      esac
    done
  done
  [ "$N" -eq 24 ] || fail "replayed $N outputs, want 24"
  echo "p122 ASan+UBSan QBE: 24 outputs (3 inputs, 6 targets text, 2 --obj) clean and equal to out/qbe"
fi

echo "PASS: p122_arm64_guarded_dispatch"
