#!/bin/sh
set -eu

export PATH="$HOME/.moon/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER_DIR="$ROOT_DIR/compiler"
M2C0="$COMPILER_DIR/_build/native/debug/build/compat_moon/compat_moon.exe"

echo "=== [1/6] moon check --target native (zero warnings) ==="
CHECK_OUT=$(cd "$COMPILER_DIR" && moon check --target native 2>&1)
printf '%s\n' "$CHECK_OUT"
if printf '%s\n' "$CHECK_OUT" | grep -q "Warning:"; then
  echo "FAIL: moon check emitted warnings" >&2
  exit 1
fi

echo "=== [2/6] moon test --target native ==="
(cd "$COMPILER_DIR" && moon test --target native)

echo "=== [3/6] moon build --target native ==="
(cd "$COMPILER_DIR" && moon build --target native)

echo "=== [4/6] Self-eat check: m2c0 check --json compiler/src/core ==="
SELF_OUT=$("$M2C0" check --json "$COMPILER_DIR/src/core")
printf '%s\n' "$SELF_OUT"
if [ "$SELF_OUT" != '{"ok":true,"diagnostics":[]}' ]; then
  echo "FAIL: self-eat check did not return clean ok JSON" >&2
  exit 1
fi

echo "=== [5/6] CLI check --json positive & negative fixtures ==="
OK_OUT=$("$M2C0" check --json "$ROOT_DIR/tests/frontend/ok_full.m2")
printf 'ok_full.m2 -> %s\n' "$OK_OUT"
if [ "$OK_OUT" != '{"ok":true,"diagnostics":[]}' ]; then
  echo "FAIL: ok_full.m2 expected ok:true" >&2
  exit 1
fi

expect_err_code() {
  fixture="$1"
  code="$2"
  set +e
  out=$("$M2C0" check --json "$ROOT_DIR/tests/frontend/$fixture")
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

expect_err_code "err_parse.m2" "E_PARSE"
expect_err_code "err_missing_type.m2" "E_MISSING_TYPE"
expect_err_code "err_type_mismatch.m2" "E_TYPE_MISMATCH"
expect_err_code "err_non_exhaustive.m2" "E_NON_EXHAUSTIVE"
expect_err_code "err_not_send.m2" "E_NOT_SEND"
expect_err_code "err_use_after_move.m2" "E_USE_AFTER_MOVE"
expect_err_code "err_capability_missing.m2" "E_CAPABILITY_MISSING"

echo "=== [6/6] CLI query --json & .m2sig byte-for-byte stability ==="
DEFS_OUT=$("$M2C0" query defs --json "$ROOT_DIR/tests/frontend/ok_full.m2")
SIG_OUT=$("$M2C0" query sig --json "$ROOT_DIR/tests/frontend/ok_full.m2")
CALLERS_OUT=$("$M2C0" query callers --json "$ROOT_DIR/tests/frontend/ok_full.m2")
DEPS_OUT=$("$M2C0" query deps --json "$ROOT_DIR/tests/frontend/ok_full.m2")

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
cp "$ROOT_DIR/tests/frontend/sig_v1.m2" "$TMP_SIG_DIR/mod.m2"
"$M2C0" emit-sig "$TMP_SIG_DIR/mod.m2" > "$TMP_SIG_DIR/v1.m2sig"
cp "$ROOT_DIR/tests/frontend/sig_v2.m2" "$TMP_SIG_DIR/mod.m2"
"$M2C0" emit-sig "$TMP_SIG_DIR/mod.m2" > "$TMP_SIG_DIR/v2.m2sig"
cmp "$TMP_SIG_DIR/v1.m2sig" "$TMP_SIG_DIR/v2.m2sig"
echo "m2sig byte-for-byte stability: PASS"

echo "ALL FRONTEND CHECKS PASSED!"
