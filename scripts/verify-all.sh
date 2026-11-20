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
FMT_OUT=$("$M2C2" fmt --check --json "$ROOT_DIR/examples/text_stats" "$ROOT_DIR/benchmarks/m2" \
  "$ROOT_DIR/std/json" "$ROOT_DIR/std/http" "$ROOT_DIR/examples/http_loopback" "$ROOT_DIR/tests/e2e/net_ffi.m2" \
  "$ROOT_DIR/tests/e2e/link_z")
printf 'm2c2 fmt --check --json -> %s\n' "$FMT_OUT"
if ! printf '%s' "$FMT_OUT" | grep -q '"ok":true'; then
  echo "FAIL: m2c2 fmt --check --json reported unformatted files" >&2
  exit 1
fi

echo "=== [5/6] Standalone m2c2 Test Runner (examples/text_stats, std/json, std/http) ==="
for TPKG in examples/text_stats std/json std/http; do
  TEST_OUT=$("$M2C2" test --json "$ROOT_DIR/$TPKG")
  printf 'm2c2 test --json %s -> %s\n' "$TPKG" "$TEST_OUT"
  if ! printf '%s' "$TEST_OUT" | grep -q '"ok":true' || ! printf '%s' "$TEST_OUT" | grep -q '"failed":0'; then
    echo "FAIL: m2c2 test --json $TPKG failed" >&2
    exit 1
  fi
done
for DPKG in std/json std/http; do
  "$M2C2" doc --json "$ROOT_DIR/$DPKG" | python3 -c 'import json, sys; d = json.load(sys.stdin); print("m2c2 doc --json %s -> valid JSON, %d package(s), %d public item(s)" % (sys.argv[1], len(d["packages"]), sum(len(p["items"]) for p in d["packages"])))' "$DPKG"
done

echo "=== [6/6] Standalone m2c2 Run (examples/text_stats, net_ffi) + Cross ELF64 .o ==="
"$M2C2" run "$ROOT_DIR/examples/text_stats"
"$M2C2" run "$ROOT_DIR/tests/e2e/net_ffi.m2"
# std/http over a workspace dependency graph (http -> json) must build and link;
# its real-TCP run is part of scripts/test-linux.sh.
"$M2C2" build -o "$OUT_DIR/http_loopback" "$ROOT_DIR/examples/http_loopback"
rm -f "$OUT_DIR/http_loopback"
# Native libraries: `[link]` in m2.toml, `-l<lib>` on the CLI, and a failing link without them.
"$M2C2" run "$ROOT_DIR/tests/e2e/link_z"
"$M2C2" build -lz -o "$OUT_DIR/link_z_cli" "$ROOT_DIR/tests/e2e/link_z/src/main.m2"
"$OUT_DIR/link_z_cli"
if "$M2C2" build -o "$OUT_DIR/link_z_nolib" "$ROOT_DIR/tests/e2e/link_z/src/main.m2" 2>/dev/null; then
  echo "FAIL: linking zlibVersion without -lz unexpectedly succeeded" >&2
  exit 1
fi
rm -f "$OUT_DIR/link_z_cli" "$OUT_DIR/link_z_nolib"
CROSS_O="$OUT_DIR/cross_ffi_traits.o"
rm -f "$CROSS_O"
"$M2C2" build --target amd64_sysv --emit-obj "$CROSS_O" "$ROOT_DIR/tests/e2e/ffi_traits.m2"
CROSS_FILE=$(file "$CROSS_O")
echo "$CROSS_FILE"
if ! printf '%s' "$CROSS_FILE" | grep -q 'ELF 64-bit LSB relocatable, x86-64'; then
  echo "FAIL: --target amd64_sysv --emit-obj did not produce an x86-64 ELF64 relocatable" >&2
  exit 1
fi
rm -f "$CROSS_O"

echo "=== ALL 6 VERIFY-ALL GATES PASSED ==="
