#!/bin/sh
set -eu

# Lean 4 extraction gate (`pionc extract-lean`, SPEC §3.5 / §5.5). Not part of
# verify-all.sh / test-linux.sh: it needs elan with Lean v4.36.0-rc2, the
# Aeneas Lean backend (AeneasVerif/aeneas @ 1dc8ad31b1, `backends/lean`) and
# its mathlib build.
#
#   1. extract tests/e2e/p35a_verify_mut/vlib and tests/lean/algos (which
#      depends on vlib) into a throw-away Lake project next to a copy of lean/;
#   2. `lake build PionLean`, `lake build Vlib Algos` (0 errors);
#   3. `lake build PionProofs`: tests/lean/proofs (step / scalar_tac proofs over
#      the extracted code; `sorry` is rejected);
#   4. `lake env lean tests/lean/Eval.lean`: `#eval` of extracted functions
#      (loops included) against the native results of the same Pion code.
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

echo "=== [1/5] Lake project in $PROJ ==="
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

echo "=== [2/5] pionc extract-lean ==="
cd "$PROJ"
for pkg in tests/e2e/p35a_verify_mut/vlib tests/lean/algos; do
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
for m in Vlib Algos; do
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
for lib in Vlib Algos PionProofs; do
  printf '\nlean_lib %s where\n  globs := #[.submodules `%s]\n' "$lib" "$lib" >> "$PROJ/lakefile.lean"
done
if grep -rn "sorry\|admit" "$PROJ/PionProofs" >/dev/null; then
  echo "FAIL: tests/lean/proofs must not use sorry / admit" >&2
  exit 1
fi

echo "=== [3/5] lake build PionLean ==="
lake build PionLean 2>&1 | grep -v '^✔\|^trace\|^info' | tail -40
lake build PionLean >/dev/null

echo "=== [4/5] lake build Vlib Algos PionProofs ==="
set +e
lake build Vlib Algos PionProofs > "$WORK/build.log" 2>&1
RC=$?
set -e
grep -v '^✔\|^trace\|^info' "$WORK/build.log" | tail -80
if [ "$RC" -ne 0 ] || grep -q '^error' "$WORK/build.log"; then
  echo "FAIL: lake build of the extracted packages / proofs (rc=$RC)" >&2
  exit 1
fi
echo "lake build Vlib Algos PionProofs: exit 0, 0 errors"

echo "=== [5/5] #eval of extracted code ==="
set +e
EVAL_OUT=$(lake env lean Eval.lean 2>&1)
RC=$?
set -e
printf '%s\n' "$EVAL_OUT"
if [ "$RC" -ne 0 ] || printf '%s' "$EVAL_OUT" | grep -q 'error\|FAIL'; then
  echo "FAIL: Eval.lean" >&2
  exit 1
fi
echo "PASS: test-lean"
