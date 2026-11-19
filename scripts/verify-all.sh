#!/bin/sh
set -eu

export PATH="$HOME/.moon/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER_DIR="$ROOT_DIR/compiler"
OUT_DIR="$ROOT_DIR/out"

echo "=== [1/6] Stage 0 MoonBit Check & Unit Tests ==="
(cd "$COMPILER_DIR" && moon check && moon test)

echo "=== [2/6] Runtime Gate (libm2rt.a + MT bench + TSan + ASan + QBE smoke) ==="
sh "$ROOT_DIR/scripts/test-runtime.sh"

echo "=== [3/6] 9/9 Fixed-Point Self-Hosting Bootstrap (m2c0 -> m2c1 -> m2c2) ==="
sh "$ROOT_DIR/scripts/bootstrap.sh"

M2C2="$OUT_DIR/m2c2"
export M2_QBE="$OUT_DIR/qbe"
export M2_RT_LIB="$OUT_DIR/libm2rt.a"

echo "=== [4/6] Standalone m2c2 Formatter Check ==="
FMT_OUT=$("$M2C2" fmt --check --json "$ROOT_DIR/examples/text_stats" "$ROOT_DIR/benchmarks/m2")
printf 'm2c2 fmt --check --json -> %s\n' "$FMT_OUT"
if ! printf '%s' "$FMT_OUT" | grep -q '"ok":true'; then
  echo "FAIL: m2c2 fmt --check --json reported unformatted files" >&2
  exit 1
fi

echo "=== [5/6] Standalone m2c2 Test Runner (examples/text_stats) ==="
TEST_OUT=$("$M2C2" test --json "$ROOT_DIR/examples/text_stats")
printf 'm2c2 test --json -> %s\n' "$TEST_OUT"
if ! printf '%s' "$TEST_OUT" | grep -q '"ok":true'; then
  echo "FAIL: m2c2 test --json examples/text_stats failed" >&2
  exit 1
fi

echo "=== [6/6] Standalone m2c2 Run (examples/text_stats) ==="
"$M2C2" run "$ROOT_DIR/examples/text_stats"

echo "=== ALL 6 VERIFY-ALL GATES PASSED ==="
