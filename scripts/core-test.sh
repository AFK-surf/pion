#!/bin/sh
# Compiler core unit tests: `pionc test --json compiler/src/core` must pass.
#   sh scripts/core-test.sh <pionc>
set -eu

PIONC="${1:?usage: core-test.sh <pionc>}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

RC=0
OUT="$(cd "$ROOT_DIR" && "$PIONC" test --json "$ROOT_DIR/compiler/src/core")" || RC=$?
SUMMARY="$(printf '%s' "$OUT" | python3 -c 'import json, sys; d = json.load(sys.stdin); print("ok=%s passed=%d failed=%d total=%d" % (d.get("ok"), d.get("passed", 0), d.get("failed", 0), len(d.get("tests", []))))' 2>/dev/null)" || SUMMARY="unparseable output"
echo "[SUMMARY] $(basename -- "$PIONC") test --json compiler/src/core -> $SUMMARY"
if [ "$RC" -ne 0 ] || ! printf '%s' "$OUT" | grep -q '"ok":true' || ! printf '%s' "$OUT" | grep -q '"failed":0'; then
  echo "FAIL: $PIONC test --json compiler/src/core failed (exit $RC):" >&2
  printf '%s\n' "$OUT" >&2
  exit 1
fi
