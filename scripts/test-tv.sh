#!/bin/sh
set -eu

# Translation-validation gate for QBE's SSA optimisations
# (`tools/qbe_tv`, the `#verify` kernel; `tools/qbe_tv_cli`, the front end).
#
#   1. build `qbe-tv` with <pionc>;
#   2. compile tests/tv/opt_suite.pion and tests/lean/{codec,algos,captable}
#      to QBE SSA, run the real optimiser `<qbe> -d MG` and validate every
#      function's load elimination -> slot coalescing -> GVN -> GCM snapshots
#      (`qbe-tv --trace`): 0 rejected; opt_suite also 0 skipped;
#   3. `qbe-tv --pair` on tests/tv/good (correct rewrites): all validated;
#   4. `qbe-tv --pair` on tests/tv/adversarial (miscompilations): every
#      pair rejected.
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

echo "=== [1/4] build qbe-tv ==="
PION_CACHE_DIR="$WORK/cas_cli" "$PIONC" build -o "$WORK/qbe-tv" "$ROOT_DIR/tools/qbe_tv_cli"
TV="$WORK/qbe-tv"

echo "=== [2/4] real qbe -d MG traces ==="
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

echo "=== [2b/4] tampered real traces: swapped jnz targets after GCM ==="
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

echo "=== [3/4] correct rewrites (tests/tv/good) ==="
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

echo "=== [4/4] adversarial miscompilations (tests/tv/adversarial) ==="
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
echo "PASS: test-tv"
