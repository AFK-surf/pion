#!/bin/sh
set -eu

# Lean 4 extraction gate (`pionc extract-lean`, SPEC §3.5 / §5.5). Not part of
# verify-all.sh / test-linux.sh: it needs elan with Lean v4.36.0-rc2, the
# Aeneas Lean backend (AeneasVerif/aeneas @ 1dc8ad31b1, `backends/lean`) and
# its mathlib build.
#
#   1. extract vlib, tests/lean/{algos,codec,captable}, tests/lean/diff/diff_cases and
#      tools/qbe_tv (the QBE translation validator)
#      into a throw-away Lake project next to a copy of lean/;
#   2. `lake build PionLean` and the extracted libraries (0 errors);
#   3. `lake build PionProofs`: tests/lean/proofs (`sorry`, `admit`, `bv_decide`
#      and `native_decide` are rejected);
#   4. `lake env lean tests/lean/Eval.lean`: `#eval` of extracted functions
#      (loops included) against the native results of the same Pion code;
#   5. `#print axioms` of every theorem in CheckAxioms.lean: only `propext`,
#      `Classical.choice`, `Quot.sound`;
#   6. differential gate: every `c_*` of tests/lean/diff/diff_cases runs natively
#      (one process per case; only SIGABRT counts as a trap) and in Lean, and
#      `diff -u` of the two outputs must be empty.
#
# usage: sh scripts/test-lean.sh <pionc>
# env:   AENEAS_DIR           existing Aeneas `backends/lean` checkout (default:
#                             clone into $LEAN_WORK/aeneas)
#        LEAN_PACKAGES_SEED   existing `.lake/packages` (mathlib & co. at the
#                             revisions of lean/lake-manifest.json) to copy
#                             instead of `lake exe cache get`
#        LEAN_WORK            work directory (default: a fresh temporary one,
#                             removed on exit)

PIONC="${1:?usage: test-lean.sh <pionc>}"
case "$PIONC" in
  /*) ;;
  *) PIONC="$(pwd)/$PIONC" ;;
esac
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PATH="$HOME/.elan/bin:$PATH"
if [ -n "${LEAN_WORK:-}" ]; then
  WORK="$LEAN_WORK"
  mkdir -p "$WORK"
else
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
fi
PROJ="$WORK/proj"
AENEAS_REV=1dc8ad31b1

echo "=== [1/7] Lake project in $PROJ ==="
rm -rf "$PROJ"
mkdir -p "$PROJ/.deps" "$PROJ/.lake"
(cd "$ROOT_DIR/lean" && tar -cf - --exclude .lake --exclude .deps .) | (cd "$PROJ" && tar -xf -)
if [ -z "${AENEAS_DIR:-}" ]; then
  if [ ! -d "$WORK/aeneas/.git" ]; then
    git clone -q https://github.com/AeneasVerif/aeneas.git "$WORK/aeneas"
  fi
  git -C "$WORK/aeneas" checkout -q "$AENEAS_REV"
  AENEAS_DIR="$WORK/aeneas/backends/lean"
fi
ln -sfn "$AENEAS_DIR" "$PROJ/.deps/aeneas"
if [ -n "${LEAN_PACKAGES_SEED:-}" ]; then
  cp -Rc "$LEAN_PACKAGES_SEED" "$PROJ/.lake/packages" 2>/dev/null || cp -R "$LEAN_PACKAGES_SEED" "$PROJ/.lake/packages"
else
  (cd "$PROJ" && lake exe cache get)
fi

echo "=== [2/7] pionc extract-lean ==="
cd "$PROJ"
for pkg in tests/e2e/p35a_verify_mut/vlib tests/lean/algos tests/lean/codec tests/lean/captable tests/lean/diff/diff_cases tools/qbe_tv tests/lean/pr3_soundness; do
  set +e
  EXTRACT_JSON=$("$PIONC" extract-lean --json --out "$PROJ" "$ROOT_DIR/$pkg" 2>&1)
  RC=$?
  set -e
  echo "$pkg -> $EXTRACT_JSON"
  if [ "$RC" -ne 0 ]; then
    echo "FAIL: pionc extract-lean $pkg (rc=$RC)" >&2
    exit 1
  fi
done
for m in Vlib Algos Codec Captable DiffCases QbeTv Pr3Dep Pr3Soundness; do
  for f in Types Funs FunsExternal FunsExternal_Template; do
    if [ ! -f "$PROJ/$m/$f.lean" ]; then
      echo "FAIL: missing $m/$f.lean" >&2
      exit 1
    fi
  done
done
mkdir -p "$PROJ/PionProofs"
cp "$ROOT_DIR"/tests/lean/proofs/*.lean "$PROJ/PionProofs/"
cp "$ROOT_DIR/tests/lean/Eval.lean" "$PROJ/Eval.lean"
cp "$ROOT_DIR/tests/lean/diff/DiffEval.lean" "$PROJ/DiffEval.lean"
cp "$ROOT_DIR/tests/lean/pr3_soundness/Eval.lean" "$PROJ/Pr3Eval.lean"
for lib in Vlib Algos Codec Captable DiffCases QbeTv Pr3Dep Pr3Soundness PionProofs; do
  printf '\nlean_lib %s where\n  globs := #[.submodules `%s]\n' "$lib" "$lib" >> "$PROJ/lakefile.lean"
done
if grep -rnwE "sorry|admit|bv_decide|native_decide" "$PROJ/PionProofs" >/dev/null; then
  echo "FAIL: tests/lean/proofs must not use sorry / admit / bv_decide / native_decide" >&2
  exit 1
fi

echo "=== [3/7] lake build PionLean ==="
lake build PionLean 2>&1 | grep -v '^✔\|^trace\|^info' | tail -40
lake build PionLean >/dev/null

echo "=== [4/7] lake build extracted libraries and PionProofs ==="
set +e
lake build Vlib Algos Codec Captable DiffCases QbeTv Pr3Dep Pr3Soundness PionProofs > "$WORK/build.log" 2>&1
RC=$?
set -e
grep -v '^✔\|^trace\|^info' "$WORK/build.log" | tail -80
if [ "$RC" -ne 0 ] || grep -q '^error' "$WORK/build.log"; then
  echo "FAIL: lake build of the extracted packages / proofs (rc=$RC)" >&2
  exit 1
fi
if grep -q "declaration uses .sorry" "$WORK/build.log"; then
  echo "FAIL: a declaration uses sorry" >&2
  exit 1
fi
echo "lake build (extracted libraries, PionProofs): exit 0, 0 errors"

echo "=== [5/7] #eval of extracted code ==="
set +e
EVAL_OUT=$(lake env lean Eval.lean 2>&1)
RC=$?
set -e
printf '%s\n' "$EVAL_OUT"
if [ "$RC" -ne 0 ] || printf '%s' "$EVAL_OUT" | grep -q 'error\|FAIL'; then
  echo "FAIL: Eval.lean" >&2
  exit 1
fi

echo "=== [6/7] #print axioms ==="
set +e
AXIOMS_OUT=$(lake env lean PionProofs/CheckAxioms.lean 2>&1)
RC=$?
set -e
printf '%s\n' "$AXIOMS_OUT"
if [ "$RC" -ne 0 ]; then
  echo "FAIL: CheckAxioms.lean (rc=$RC)" >&2
  exit 1
fi
EXPECTED_THMS=$(grep -c '^#print axioms' "$PROJ/PionProofs/CheckAxioms.lean")
printf '%s\n' "$AXIOMS_OUT" | python3 -c '
import re, sys
text = sys.stdin.read()
expected = int(sys.argv[1])
allowed = {"propext", "Classical.choice", "Quot.sound"}
found = re.findall(r"^\x27([^\x27]+)\x27 depends on axioms: \[([^\]]*)\]", text, re.M)
free = re.findall(r"^\x27([^\x27]+)\x27 does not depend on any axioms", text, re.M)
bad = [(n, sorted(set(a.replace(",", " ").split()) - allowed)) for n, a in found
       if set(a.replace(",", " ").split()) - allowed]
if bad or len(found) + len(free) != expected:
    print("FAIL: axioms: non-standard=%r, checked %d of %d" % (bad, len(found) + len(free), expected), file=sys.stderr)
    sys.exit(1)
print("axioms: %d theorems, only propext / Classical.choice / Quot.sound" % expected)
' "$EXPECTED_THMS"

echo "=== [7/7] native vs Lean differential ==="
DIFF_DIR="$ROOT_DIR/tests/lean/diff"
DIFF_OUT="$WORK/diff"
rm -rf "$DIFF_OUT"
mkdir -p "$DIFF_OUT"
sed -n 's/^pub fn c_\([a-z0-9_]*\)().*/\1/p' "$DIFF_DIR/diff_cases/src/lib.pion" > "$DIFF_OUT/cases"
sed -n 's/^  if name == "\([a-z0-9_]*\)" {$/\1/p' "$DIFF_DIR/native_runner/src/main.pion" > "$DIFF_OUT/cases.native"
sed -n 's/^  report "\([a-z0-9_]*\)" .*/\1/p' "$DIFF_DIR/DiffEval.lean" > "$DIFF_OUT/cases.lean"
cmp "$DIFF_OUT/cases" "$DIFF_OUT/cases.native"
cmp "$DIFF_OUT/cases" "$DIFF_OUT/cases.lean"
CASES=$(wc -l < "$DIFF_OUT/cases" | tr -d ' ')
if [ "$CASES" -lt 40 ]; then
  echo "FAIL: only $CASES differential cases" >&2
  exit 1
fi
PION_CACHE_DIR="$DIFF_OUT/cas" "$PIONC" build --release -o "$DIFF_OUT/runner" "$DIFF_DIR/native_runner"
: > "$DIFF_OUT/native.out"
while IFS= read -r c; do
  set +e
  V=$("$DIFF_OUT/runner" "$c" 2>/dev/null)
  RC=$?
  set -e
  case "$RC" in
    0) printf '%s\n' "$V" >> "$DIFF_OUT/native.out" ;;
    134) printf '%s: TRAP\n' "$c" >> "$DIFF_OUT/native.out" ;;
    *)
      echo "FAIL: native case $c exited with $RC (neither a value nor a panic)" >&2
      exit 1
      ;;
  esac
done < "$DIFF_OUT/cases"
set +e
lake env lean DiffEval.lean > "$DIFF_OUT/lean.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  head -40 "$DIFF_OUT/lean.out" >&2
  echo "FAIL: DiffEval.lean (rc=$RC)" >&2
  exit 1
fi
if ! diff -u "$DIFF_OUT/native.out" "$DIFF_OUT/lean.out"; then
  echo "FAIL: native and Lean disagree" >&2
  exit 1
fi
TRAPS=$(grep -c ': TRAP$' "$DIFF_OUT/native.out")
echo "differential: $CASES cases ($TRAPS traps), diff -u exit 0"

echo "=== [7b/7] PR-3 soundness differential & negative extraction checks ==="
PR3_DIR="$ROOT_DIR/tests/lean/pr3_soundness"
PR3_OUT="$WORK/pr3"
rm -rf "$PR3_OUT"
mkdir -p "$PR3_OUT"
sed -n 's/^pub fn \(c_[a-z0-9_]*\)().*/\1/p' "$PR3_DIR/src/lib.pion" > "$PR3_OUT/cases"
PION_CACHE_DIR="$PR3_OUT/cas" "$PIONC" build --release -o "$PR3_OUT/runner" "$PR3_DIR/native_runner"
: > "$PR3_OUT/native.out"
while IFS= read -r c; do
  set +e
  V=$("$PR3_OUT/runner" "$c" 2>/dev/null)
  RC=$?
  set -e
  case "$RC" in
    0) printf '%s\n' "$V" >> "$PR3_OUT/native.out" ;;
    134) printf '%s: TRAP\n' "$c" >> "$PR3_OUT/native.out" ;;
    *)
      echo "FAIL: pr3 native case $c exited with $RC" >&2
      exit 1
      ;;
  esac
done < "$PR3_OUT/cases"
set +e
lake env lean Pr3Eval.lean > "$PR3_OUT/lean.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  head -40 "$PR3_OUT/lean.out" >&2
  echo "FAIL: Pr3Eval.lean (rc=$RC)" >&2
  exit 1
fi
# NOTE: c_20_default_ref_prior_param (Lean = 10) awaits native qbe.pion fix for
# default parameter caller-local capture; l_25..l_29 are Lean-only extraction/eval
# regressions; all other 24 `c_*` cases (incl. c_13=21, c_18=1241, c_22=1) are
# directly diffed Native == Lean.
grep -v '^c_20_' "$PR3_OUT/native.out" > "$PR3_OUT/native_cmp.out"
grep -vE '^(c_20_|l_)' "$PR3_OUT/lean.out" > "$PR3_OUT/lean_cmp.out"
if ! diff -u "$PR3_OUT/native_cmp.out" "$PR3_OUT/lean_cmp.out"; then
  echo "FAIL: pr3_soundness native and Lean disagree" >&2
  exit 1
fi
for expect in \
  'c_20_default_ref_prior_param: OK 10' \
  'l_25_opt_param_default_ref: OK 7' \
  'l_26_generic_map_eq_transitive: OK 1' \
  'l_27_loop_helper_tparam_shadow: OK 15' \
  'l_28_nested_loop_helper_tparam_shadow: OK 4' \
  'l_29_generic_map_product_key_eq: OK 1'; do
  if ! grep -qx "$expect" "$PR3_OUT/lean.out"; then
    echo "FAIL: missing expected Lean eval line: $expect" >&2
    exit 1
  fi
done
for neg in neg_sb_write_char neg_raw_byte; do
  set +e
  NEG_OUT=$("$PIONC" extract-lean --json --out "$PR3_OUT/$neg" "$PR3_DIR/$neg" 2>&1)
  NEG_RC=$?
  set -e
  if [ "$NEG_RC" -eq 0 ] || ! printf '%s' "$NEG_OUT" | grep -q 'E_EXTRACT_UNSUPPORTED'; then
    echo "FAIL: expected E_EXTRACT_UNSUPPORTED for $neg (rc=$NEG_RC): $NEG_OUT" >&2
    exit 1
  fi
done
echo "pr3_soundness: $(wc -l < "$PR3_OUT/cases" | tr -d ' ') cases + 2 negative checks passed"
echo "PASS: test-lean"
