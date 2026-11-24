#!/bin/sh
set -eu

# Translation-validation gate for QBE's SSA optimisations
# (`tools/qbe_tv`, the `#verify` kernel; `tools/qbe_tv_cli`, the front end).
#
#   1. build `qbe-tv` with <pionc>;
#   2. compile tests/tv/opt_suite.pion and tests/lean/{codec,algos,captable}
#      to QBE SSA, run the real optimiser `<qbe> -d MG` and validate every
#      function's `After load elimination` snapshot directly against its
#      `After GCM` snapshot with the strict checker (`qbe-tv --trace`):
#      0 rejected; opt_suite also 0 skipped; then swap a `jnz` of every
#      opt_suite function after GCM: all rejected;
#   3. `qbe-tv --pair` on tests/tv/good (correct rewrites): all validated;
#   4. `qbe-tv --pair` on tests/tv/adversarial (miscompilations): every
#      pair rejected;
#   5. tests/tv/qbe_bugs: reproducers of vendor/qbe bugs B1-B6 found by
#      qbe-tv + differential fuzzing and B7-B12 found by the Lean-model
#      review, built through text assembly and, where the target has it,
#      `--obj`, and run against exact expected results; their `-d MG` trace
#      validated by the strict checker (all but bug1, whose fold is beyond
#      qbe-tv's completeness, and bug10/bug11c/bug11d, whose slot rewrites
#      happen before the first traced snapshot or use class s).
#
# usage: sh scripts/test-tv.sh <pionc> <qbe>

PIONC="${1:?usage: test-tv.sh <pionc> <qbe>}"
QBE="${2:?usage: test-tv.sh <pionc> <qbe>}"
case "$PIONC" in /*) ;; *) PIONC="$(pwd)/$PIONC" ;; esac
case "$QBE" in /*) ;; *) QBE="$(pwd)/$QBE" ;; esac
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export PION_QBE="$QBE"
if [ -z "${PION_RT_LIB:-}" ] && [ -f "$(dirname "$QBE")/libpionrt.a" ]; then
  export PION_RT_LIB="$(dirname "$QBE")/libpionrt.a"
fi

echo "=== [1/5] build qbe-tv ==="
PION_CACHE_DIR="$WORK/cas_cli" "$PIONC" build -o "$WORK/qbe-tv" "$ROOT_DIR/tools/qbe_tv_cli"
TV="$WORK/qbe-tv"

echo "=== [2/5] real qbe -d MG traces ==="
FAIL=0
for spec in "opt_suite:tests/tv/opt_suite.pion:strict" "codec:tests/lean/codec:" "algos:tests/lean/algos:" "captable:tests/lean/captable:"; do
  name=${spec%%:*}
  rest=${spec#*:}
  path=${rest%%:*}
  mode=${rest#*:}
  cas="$WORK/cas_$name"
  mkdir -p "$cas"
  PION_CACHE_DIR="$cas" "$PIONC" build --emit-staticlib "$WORK/$name.a" "$ROOT_DIR/$path" >/dev/null
  V=0; S=0; R=0
  for ssa in "$cas"/ssa/*.ssa; do
    dump="$WORK/$name.$(basename "$ssa" .ssa).mg"
    "$QBE" -d MG -o /dev/null "$ssa" 2> "$dump"
    set +e
    if [ "$mode" = strict ]; then
      OUT=$("$TV" --trace "$dump" --strict)
    else
      OUT=$("$TV" --trace "$dump")
    fi
    RC=$?
    set -e
    printf '%s\n' "$OUT" | grep -v '^VALIDATED ' || true
    SUM=$(printf '%s\n' "$OUT" | tail -1)
    V=$((V + $(printf '%s' "$SUM" | sed -n 's/.*validated=\([0-9]*\).*/\1/p')))
    S=$((S + $(printf '%s' "$SUM" | sed -n 's/.*skipped=\([0-9]*\).*/\1/p')))
    R=$((R + $(printf '%s' "$SUM" | sed -n 's/.*rejected=\([0-9]*\).*/\1/p')))
    if [ "$RC" -ne 0 ]; then
      FAIL=1
    fi
  done
  echo "$name: validated=$V skipped=$S rejected=$R"
done
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: real QBE optimisations were not all validated" >&2
  exit 1
fi

echo "=== [2b/5] tampered real traces: swapped jnz targets after GCM ==="
for dump in "$WORK"/opt_suite.*.mg; do
  awk '
    /^\*\*\*\* Function / { fn = $3; done = 0 }
    /^> / { gcm = ($0 == "> After GCM:") }
    gcm && !done && /^\tjnz / {
      n = split($0, p, ", ")
      if (n == 3 && p[2] != p[3]) {
        print p[1] ", " p[3] ", " p[2]
        print fn > "/dev/stderr"
        done = 1
        next
      }
    }
    { print }
  ' "$dump" > "$dump.bad" 2> "$dump.names"
  set +e
  OUT=$("$TV" --trace "$dump.bad")
  set -e
  T=0; M=0
  while IFS= read -r f; do
    T=$((T + 1))
    if printf '%s\n' "$OUT" | grep -q "^REJECTED $f: "; then
      M=$((M + 1))
    else
      echo "FAIL: tampered $f was not rejected" >&2
      printf '%s\n' "$OUT" | grep " $f" >&2 || true
      exit 1
    fi
  done < "$dump.names"
  echo "tampered: $M/$T functions rejected"
done

echo "=== [3/5] correct rewrites (tests/tv/good) ==="
for before in "$ROOT_DIR"/tests/tv/good/*.before.ssa; do
  after=${before%.before.ssa}.after.ssa
  case_name=$(basename "$before" .before.ssa)
  if OUT=$("$TV" --pair "$before" "$after" --strict); then
    echo "VALIDATED $case_name"
  else
    printf '%s\n' "$OUT" >&2
    echo "FAIL: correct rewrite $case_name not validated" >&2
    exit 1
  fi
done

echo "=== [4/5] adversarial miscompilations (tests/tv/adversarial) ==="
N=0
for before in "$ROOT_DIR"/tests/tv/adversarial/*.before.ssa; do
  after=${before%.before.ssa}.after.ssa
  case_name=$(basename "$before" .before.ssa)
  set +e
  OUT=$("$TV" --pair "$before" "$after")
  RC=$?
  set -e
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q '^REJECTED '; then
    echo "REJECTED $case_name: $(printf '%s\n' "$OUT" | sed -n 's/^REJECTED [^:]*: //p' | head -1)"
    N=$((N + 1))
  else
    printf '%s\n' "$OUT" >&2
    echo "FAIL: miscompilation $case_name was not rejected (rc=$RC)" >&2
    exit 1
  fi
done
if [ "$N" -lt 10 ]; then
  echo "FAIL: only $N adversarial cases" >&2
  exit 1
fi
echo "adversarial: $N/$N rejected"

echo "=== [5/5] vendor/qbe miscompilation regressions (tests/tv/qbe_bugs) ==="
BUGS="$ROOT_DIR/tests/tv/qbe_bugs"
"$QBE" -o "$WORK/qbe_bugs.s" "$BUGS/qbe_bugs.ssa"
cc "$WORK/qbe_bugs.s" "$BUGS/driver.c" -o "$WORK/qbe_bugs_asm"
printf "asm: "
"$WORK/qbe_bugs_asm"
# --obj emits arm64_apple Mach-O / amd64_sysv ELF64 only.
case "$(uname -s):$(uname -m)" in
  Darwin:arm64|Linux:x86_64|Linux:amd64)
    "$QBE" --obj -o "$WORK/qbe_bugs.o" "$BUGS/qbe_bugs.ssa"
    cc "$WORK/qbe_bugs.o" "$BUGS/driver.c" -o "$WORK/qbe_bugs_obj"
    printf "obj: "
    "$WORK/qbe_bugs_obj"
    ;;
  *) echo "obj: --obj not supported on $(uname -s) $(uname -m), skipped" ;;
esac
"$QBE" -d MG -o /dev/null "$BUGS/qbe_bugs.ssa" 2> "$WORK/qbe_bugs.mg"
set +e
OUT=$("$TV" --trace "$WORK/qbe_bugs.mg" --strict)
set -e
printf '%s\n' "$OUT"
# bug1's fold of `jnz 4294967296` (only the low 32 bits count) is beyond
# qbe-tv's completeness, so it is not required to validate; the driver checks
# it. bug10 (load.c forwarding) and bug11c/d (mem.c promotion of an s store)
# act before the first traced snapshot and are skipped (slot coalescing,
# class s); the driver checks them too. Every other reproducer must validate.
for f in bug2_phi_class bug3_dwl_shr32 bug4a_amd64_jnz_l_and bug4b_amd64_jnz_l_neg \
         bug4c_amd64_sel_l_and bug5_amd64_shift_zflag bug6_amd64_shift_imm \
         bug7_dwl_phi_retry bug8_dwl_phi_cycle bug9_gvn_jnz_retl \
         bug11a_promote_loadsw bug11b_promote_loaduw bug12_cnew_l_result; do
  if ! printf '%s\n' "$OUT" | grep -qx "VALIDATED $f"; then
    echo "FAIL: qbe_bugs trace: $f not validated" >&2
    exit 1
  fi
done
if printf '%s\n' "$OUT" | grep -E '^(REJECTED|SKIPPED) ' |
   grep -Evq '^(REJECTED bug1_dedupjmp_lowbits|SKIPPED (bug10_load_shr_mask|bug11c_promote_s_loadsw|bug11d_promote_s_loaduw)): '; then
  echo "FAIL: qbe_bugs trace: unexpected rejection" >&2
  exit 1
fi
echo "qbe_bugs: asm + obj exact, trace 13/13 validated (bug1, bug10, bug11c/d outside qbe-tv's reach)"
echo "PASS: test-tv"
