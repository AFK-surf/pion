#!/bin/sh
set -eu

export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER_DIR="$ROOT_DIR/compiler"
PIONC="${PIONC:-$ROOT_DIR/out/pionc2}"

if [ ! -x "$PIONC" ]; then
  sh "$ROOT_DIR/scripts/bootstrap.sh"
fi

export PION_QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
export PION_RT_LIB="${PION_RT_LIB:-$ROOT_DIR/out/libpionrt.a}"

echo "=== [1/5] Self-check: pionc check --json compiler/src/core ==="
SELF_OUT=$("$PIONC" check --json "$COMPILER_DIR/src/core")
printf '%s\n' "$SELF_OUT"
if [ "$SELF_OUT" != '{"ok":true,"diagnostics":[]}' ]; then
  echo "FAIL: self-check did not return clean ok JSON" >&2
  exit 1
fi

echo "=== [2/5] Self-check: pionc check --json compiler/src/core + cli ==="
SELF_ALL=$("$PIONC" check --json "$COMPILER_DIR/src/core" "$COMPILER_DIR/src/cli/main.pion")
printf '%s\n' "$SELF_ALL"
if [ "$SELF_ALL" != '{"ok":true,"diagnostics":[]}' ]; then
  echo "FAIL: self-check core + cli did not return clean ok JSON" >&2
  exit 1
fi

echo "=== [3/5] Compiler core unit tests: pionc test --json compiler/src/core ==="
TEST_OUT=$("$PIONC" test --json "$COMPILER_DIR/src/core")
printf '%s' "$TEST_OUT" | python3 -c 'import json, sys; d = json.load(sys.stdin); print("ok=%s passed=%d failed=%d total=%d" % (d.get("ok"), d.get("passed", 0), d.get("failed", 0), len(d.get("tests", []))))'
if ! printf '%s' "$TEST_OUT" | grep -q '"ok":true' || ! printf '%s' "$TEST_OUT" | grep -q '"failed":0'; then
  echo "FAIL: compiler/src/core unit tests failed" >&2
  exit 1
fi

echo "=== [4/5] CLI check --json positive & negative fixtures ==="
OK_OUT=$("$PIONC" check --json "$ROOT_DIR/tests/frontend/ok_full.pion")
printf 'ok_full.pion -> %s\n' "$OK_OUT"
if [ "$OK_OUT" != '{"ok":true,"diagnostics":[]}' ]; then
  echo "FAIL: ok_full.pion expected ok:true" >&2
  exit 1
fi
OKV_OUT=$("$PIONC" check --json "$ROOT_DIR/tests/frontend/ok_verify_mut.pion")
printf 'ok_verify_mut.pion -> %s\n' "$OKV_OUT"
if [ "$OKV_OUT" != '{"ok":true,"diagnostics":[]}' ]; then
  echo "FAIL: ok_verify_mut.pion expected ok:true" >&2
  exit 1
fi

expect_err_code() {
  fixture="$1"
  code="$2"
  set +e
  out=$("$PIONC" check --json "$ROOT_DIR/tests/frontend/$fixture")
  rc=$?
  set -e
  printf '%s -> %s\n' "$fixture" "$out"
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $fixture expected non-zero exit code" >&2
    exit 1
  fi
  if ! printf '%s' "$out" | grep -q "\"code\":\"$code\""; then
    echo "FAIL: $fixture expected error code $code" >&2
    exit 1
  fi
}

expect_err_code "err_parse.pion" "E_PARSE"
expect_err_code "err_missing_type.pion" "E_MISSING_TYPE"
expect_err_code "err_type_mismatch.pion" "E_TYPE_MISMATCH"
expect_err_code "err_non_exhaustive.pion" "E_NON_EXHAUSTIVE"
expect_err_code "err_not_send.pion" "E_NOT_SEND"
expect_err_code "err_use_after_move.pion" "E_USE_AFTER_MOVE"
expect_err_code "err_capability_missing.pion" "E_CAPABILITY_MISSING"
expect_err_code "err_verify_unsupported.pion" "E_VERIFY_UNSUPPORTED"
expect_err_code "err_verify_move.pion" "E_VERIFY_MOVE"
expect_err_code "err_verify_borrow_escape.pion" "E_VERIFY_BORROW_ESCAPE"
expect_err_code "err_verify_mut_escape.pion" "E_VERIFY_MUT_ESCAPE"
expect_err_code "err_verify_aliasing.pion" "E_VERIFY_ALIASING"
expect_err_code "err_verify_closure_capture.pion" "E_VERIFY_CLOSURE_CAPTURE"
expect_err_code "err_verify_unverified_callee.pion" "E_VERIFY_UNVERIFIED_CALLEE"

echo "=== [5/5] CLI query --json & .pionsig byte-for-byte stability ==="
DEFS_OUT=$("$PIONC" query defs --json "$ROOT_DIR/tests/frontend/ok_full.pion")
SIG_OUT=$("$PIONC" query sig --json "$ROOT_DIR/tests/frontend/ok_full.pion")
CALLERS_OUT=$("$PIONC" query callers --json "$ROOT_DIR/tests/frontend/ok_full.pion")
DEPS_OUT=$("$PIONC" query deps --json "$ROOT_DIR/tests/frontend/ok_full.pion")

printf 'query defs    -> %s\n' "$DEFS_OUT"
printf 'query sig     -> %s\n' "$SIG_OUT"
printf 'query callers -> %s\n' "$CALLERS_OUT"
printf 'query deps    -> %s\n' "$DEPS_OUT"

printf '%s' "$DEFS_OUT" | grep -q '"defs":\['
printf '%s' "$SIG_OUT" | grep -q '"sig_hash":'
printf '%s' "$CALLERS_OUT" | grep -q '"callers":\['
printf '%s' "$DEPS_OUT" | grep -q '"packages":\['

TMP_SIG_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_SIG_DIR"' EXIT
cp "$ROOT_DIR/tests/frontend/sig_v1.pion" "$TMP_SIG_DIR/mod.pion"
"$PIONC" emit-sig "$TMP_SIG_DIR/mod.pion" > "$TMP_SIG_DIR/v1.pionsig"
cp "$ROOT_DIR/tests/frontend/sig_v2.pion" "$TMP_SIG_DIR/mod.pion"
"$PIONC" emit-sig "$TMP_SIG_DIR/mod.pion" > "$TMP_SIG_DIR/v2.pionsig"
cmp "$TMP_SIG_DIR/v1.pionsig" "$TMP_SIG_DIR/v2.pionsig"
echo "pionsig byte-for-byte stability: PASS"

echo "ALL FRONTEND CHECKS PASSED!"
