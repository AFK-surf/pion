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
  "$ROOT_DIR/tests/e2e/link_z" "$ROOT_DIR/examples/http_kv_service" "$ROOT_DIR/examples/sqlite_indexer" \
  "$ROOT_DIR/tests/e2e/utf8_text.m2")
printf 'm2c2 fmt --check --json -> %s\n' "$FMT_OUT"
if ! printf '%s' "$FMT_OUT" | grep -q '"ok":true'; then
  echo "FAIL: m2c2 fmt --check --json reported unformatted files" >&2
  exit 1
fi

# Non-ASCII UTF-8 (strings, comments) survives formatting byte-for-byte and stays idempotent.
UTF8_TMP=$(mktemp -d)
printf '// \344\270\255\346\226\207  \346\263\250\351\207\212\nfn f() -> String {\n      let   s = "\344\275\240\345\245\275"  +  "\360\237\232\200"   // \342\234\223\n  s\n}\n' > "$UTF8_TMP/u.m2"
printf '// \344\270\255\346\226\207  \346\263\250\351\207\212\nfn f() -> String {\n  let s = "\344\275\240\345\245\275" + "\360\237\232\200" // \342\234\223\n  s\n}\n' > "$UTF8_TMP/want.m2"
"$M2C2" fmt "$UTF8_TMP/u.m2"
if ! cmp "$UTF8_TMP/u.m2" "$UTF8_TMP/want.m2"; then
  echo "FAIL: m2c2 fmt changed non-ASCII UTF-8 text" >&2
  exit 1
fi
"$M2C2" fmt --check --json "$UTF8_TMP/u.m2" | grep -q '"ok":true'
rm -rf "$UTF8_TMP"
echo "m2c2 fmt keeps UTF-8 text byte-for-byte: OK"

echo "=== [5/6] Standalone m2c2 Test Runner (examples/text_stats, std/json, std/http, dogfood apps) ==="
for TPKG in examples/text_stats std/json std/http examples/http_kv_service examples/sqlite_indexer; do
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
"$M2C2" run "$ROOT_DIR/tests/e2e/utf8_text.m2"
# Dogfood apps: multithreaded KV service (in-process routes + 8x500 concurrent
# stress) and the pure-m2 libsqlite3 indexer cross-checked by the sqlite3 CLI.
"$M2C2" build --release -o "$OUT_DIR/http_kv_service" "$ROOT_DIR/examples/http_kv_service"
"$OUT_DIR/http_kv_service" --self-test
"$M2C2" build --release -o "$OUT_DIR/sqlite_indexer" "$ROOT_DIR/examples/sqlite_indexer"
IDX_DB="$OUT_DIR/sqlite_indexer_check.db"
rm -f "$IDX_DB"
IDX_JSON=$("$OUT_DIR/sqlite_indexer" "$ROOT_DIR/compiler/src/core" "$IDX_DB")
echo "sqlite_indexer -> $(printf '%s' "$IDX_JSON" | cut -c1-160)..."
IDX_WANT=$(printf '%s' "$IDX_JSON" | python3 -c 'import json, sys; t = json.load(sys.stdin)["totals"]; print("%d|%d" % (t["files"], t["lines"]))')
if command -v sqlite3 >/dev/null 2>&1; then
  IDX_GOT=$(sqlite3 "$IDX_DB" "SELECT COUNT(*), SUM(lines) FROM files;")
  if [ "$IDX_GOT" != "$IDX_WANT" ]; then
    echo "FAIL: sqlite3 CLI sees $IDX_GOT, indexer reported $IDX_WANT" >&2
    exit 1
  fi
  echo "sqlite3 CLI cross-check: $IDX_GOT (files|lines) == indexer JSON"
fi
rm -f "$IDX_DB" "$OUT_DIR/http_kv_service" "$OUT_DIR/sqlite_indexer"
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
