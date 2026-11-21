#!/bin/sh
set -eu

export PATH="$HOME/.moon/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER_DIR="$ROOT_DIR/compiler"
OUT_DIR="$ROOT_DIR/out"

echo "=== [1/6] Stage 0 MoonBit Check & Unit Tests ==="
(cd "$COMPILER_DIR" && moon check && moon test)

echo "=== [2/6] Runtime Gate (libpionrt.a + MT bench + TSan + ASan + QBE smoke) ==="
sh "$ROOT_DIR/scripts/test-runtime.sh"

echo "=== [3/6] 9/9 Fixed-Point Self-Hosting Bootstrap (pionc0 -> pionc1 -> pionc2) ==="
sh "$ROOT_DIR/scripts/bootstrap.sh"

PIONC2="$OUT_DIR/pionc2"
export PION_QBE="$OUT_DIR/qbe"
export PION_RT_LIB="$OUT_DIR/libpionrt.a"

echo "=== [4/6] Standalone pionc2 Formatter Check ==="
FMT_OUT=$("$PIONC2" fmt --check --json "$ROOT_DIR/examples/text_stats" "$ROOT_DIR/benchmarks/pion" \
  "$ROOT_DIR/std/json" "$ROOT_DIR/std/http" "$ROOT_DIR/std/net" "$ROOT_DIR/examples/http_loopback" \
  "$ROOT_DIR/tests/e2e/net_ffi.pion" "$ROOT_DIR/tests/e2e/link_z" "$ROOT_DIR/examples/http_kv_service" \
  "$ROOT_DIR/examples/http_event_server" "$ROOT_DIR/examples/sqlite_indexer" \
  "$ROOT_DIR/tests/e2e/utf8_text.pion" "$ROOT_DIR/std/regex" "$ROOT_DIR/std/tls" \
  "$ROOT_DIR/tests/e2e/p17a_ergonomics_mt.pion" "$ROOT_DIR/examples/https_server" \
  "$ROOT_DIR/tests/e2e/dyn_trait.pion" "$ROOT_DIR/tests/e2e/p22a_systems_io.pion" \
  "$ROOT_DIR/tests/e2e/p25a_c_varargs.pion" "$ROOT_DIR/tests/e2e/p27a_ergonomics_bug4.pion" \
  "$ROOT_DIR/examples/pion_station")
printf 'pionc2 fmt --check --json -> %s\n' "$FMT_OUT"
if ! printf '%s' "$FMT_OUT" | grep -q '"ok":true'; then
  echo "FAIL: pionc2 fmt --check --json reported unformatted files" >&2
  exit 1
fi

# Non-ASCII UTF-8 (strings, comments) survives formatting byte-for-byte and stays idempotent.
UTF8_TMP=$(mktemp -d)
printf '// \344\270\255\346\226\207  \346\263\250\351\207\212\nfn f() -> String {\n      let   s = "\344\275\240\345\245\275"  +  "\360\237\232\200"   // \342\234\223\n  s\n}\n' > "$UTF8_TMP/u.pion"
printf '// \344\270\255\346\226\207  \346\263\250\351\207\212\nfn f() -> String {\n  let s = "\344\275\240\345\245\275" + "\360\237\232\200" // \342\234\223\n  s\n}\n' > "$UTF8_TMP/want.pion"
"$PIONC2" fmt "$UTF8_TMP/u.pion"
if ! cmp "$UTF8_TMP/u.pion" "$UTF8_TMP/want.pion"; then
  echo "FAIL: pionc2 fmt changed non-ASCII UTF-8 text" >&2
  exit 1
fi
"$PIONC2" fmt --check --json "$UTF8_TMP/u.pion" | grep -q '"ok":true'
rm -rf "$UTF8_TMP"
echo "pionc2 fmt keeps UTF-8 text byte-for-byte: OK"

echo "=== [5/6] Standalone pionc2 Test Runner (examples/text_stats, std/json, std/http, std/net, std/regex, dogfood apps) ==="
for TPKG in examples/text_stats std/json std/http std/net std/regex examples/http_kv_service examples/http_event_server examples/sqlite_indexer; do
  TEST_OUT=$("$PIONC2" test --json "$ROOT_DIR/$TPKG")
  printf 'pionc2 test --json %s -> %s\n' "$TPKG" "$TEST_OUT"
  if ! printf '%s' "$TEST_OUT" | grep -q '"ok":true' || ! printf '%s' "$TEST_OUT" | grep -q '"failed":0'; then
    echo "FAIL: pionc2 test --json $TPKG failed" >&2
    exit 1
  fi
done
# std/regex: 9 tests, two of them linear-time ReDoS guards ((a?){n}a{n}, nested quantifiers).
REGEX_OUT=$("$PIONC2" test --json "$ROOT_DIR/std/regex")
REGEX_PASSED=$(printf '%s' "$REGEX_OUT" | python3 -c 'import json, sys; d = json.load(sys.stdin); print("%d/%d" % (d["passed"], len(d["tests"])))')
if [ "$REGEX_PASSED" != "9/9" ] || ! printf '%s' "$REGEX_OUT" | grep -q '"name":"ReDoS: (a?){n}a{n} is linear","ok":true'; then
  echo "FAIL: std/regex expected 9/9 incl. ReDoS guards, got $REGEX_PASSED" >&2
  exit 1
fi
echo "std/regex: $REGEX_PASSED passed (ReDoS guards included)"

# `pionc init` scaffolds a package that is check/test/run/fmt-clean as is.
INIT_TMP=$(mktemp -d)
"$PIONC2" init --json "$INIT_TMP/demo"
"$PIONC2" check --json "$INIT_TMP/demo" | grep -q '"ok":true'
INIT_TEST=$("$PIONC2" test --json "$INIT_TMP/demo")
printf 'pionc2 test --json <init demo> -> %s\n' "$INIT_TEST"
printf '%s' "$INIT_TEST" | grep -q '"ok":true'
printf '%s' "$INIT_TEST" | grep -q '"failed":0'
"$PIONC2" run "$INIT_TMP/demo"
"$PIONC2" fmt --check --json "$INIT_TMP/demo" | grep -q '"ok":true'
rm -rf "$INIT_TMP"
echo "pionc2 init -> check/test/run/fmt --check: OK"

for DPKG in std/json std/http std/regex; do
  "$PIONC2" doc --json "$ROOT_DIR/$DPKG" | python3 -c 'import json, sys; d = json.load(sys.stdin); print("pionc2 doc --json %s -> valid JSON, %d package(s), %d public item(s)" % (sys.argv[1], len(d["packages"]), sum(len(p["items"]) for p in d["packages"])))' "$DPKG"
done

echo "=== [6/6] Standalone pionc2 Run (examples/text_stats, net_ffi) + Cross ELF64 .o ==="
"$PIONC2" run "$ROOT_DIR/examples/text_stats"
"$PIONC2" run "$ROOT_DIR/tests/e2e/net_ffi.pion"
"$PIONC2" run "$ROOT_DIR/tests/e2e/utf8_text.pion"
P22A_OUT=$("$PIONC2" run "$ROOT_DIR/tests/e2e/p22a_systems_io.pion")
echo "p22a_systems_io -> $P22A_OUT"
if [ "$P22A_OUT" != "p22a_systems_io ok" ]; then
  echo "FAIL: p22a_systems_io output mismatch" >&2
  exit 1
fi
P25A_OUT=$("$PIONC2" run "$ROOT_DIR/tests/e2e/p25a_c_varargs.pion")
echo "p25a_c_varargs -> $P25A_OUT"
if [ "$P25A_OUT" != "a=42 b=-7 c=3.25" ]; then
  echo "FAIL: p25a_c_varargs output mismatch" >&2
  exit 1
fi
P27A_OUT=$("$PIONC2" run "$ROOT_DIR/tests/e2e/p27a_ergonomics_bug4.pion")
echo "p27a_ergonomics_bug4 -> $P27A_OUT"
if [ "$P27A_OUT" != "p27a_ergonomics_bug4 ok" ]; then
  echo "FAIL: p27a_ergonomics_bug4 output mismatch" >&2
  exit 1
fi
sh "$ROOT_DIR/tests/e2e/p27b_freeze_named_args/run_e2e.sh" "$PIONC2"
P17A_OUT=$("$PIONC2" run "$ROOT_DIR/tests/e2e/p17a_ergonomics_mt.pion")
echo "p17a_ergonomics_mt -> $P17A_OUT"
if [ "$P17A_OUT" != "p17a_ok log=2401 recs=3200 index=3200 keys=16" ]; then
  echo "FAIL: p17a_ergonomics_mt output mismatch" >&2
  exit 1
fi
# Dogfood apps: multithreaded KV service (in-process routes + 8x500 concurrent
# stress) and the pure-pion libsqlite3 indexer cross-checked by the sqlite3 CLI.
"$PIONC2" build --release -o "$OUT_DIR/http_kv_service" "$ROOT_DIR/examples/http_kv_service"
"$OUT_DIR/http_kv_service" --self-test
"$PIONC2" build --release -o "$OUT_DIR/http_event_server" "$ROOT_DIR/examples/http_event_server"
"$OUT_DIR/http_event_server" --self-test
"$PIONC2" build --release -o "$OUT_DIR/sqlite_indexer" "$ROOT_DIR/examples/sqlite_indexer"
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
rm -f "$IDX_DB" "$OUT_DIR/http_kv_service" "$OUT_DIR/http_event_server" "$OUT_DIR/sqlite_indexer"
# std/http over a workspace dependency graph (http -> json) must build and link;
# its real-TCP run is part of scripts/test-linux.sh.
"$PIONC2" build -o "$OUT_DIR/http_loopback" "$ROOT_DIR/examples/http_loopback"
rm -f "$OUT_DIR/http_loopback"
# Native libraries: `[link]` in pion.toml, `-l<lib>` on the CLI, and a failing link without them.
"$PIONC2" run "$ROOT_DIR/tests/e2e/link_z"
"$PIONC2" build -lz -o "$OUT_DIR/link_z_cli" "$ROOT_DIR/tests/e2e/link_z/src/main.pion"
"$OUT_DIR/link_z_cli"
if "$PIONC2" build -o "$OUT_DIR/link_z_nolib" "$ROOT_DIR/tests/e2e/link_z/src/main.pion" 2>/dev/null; then
  echo "FAIL: linking zlibVersion without -lz unexpectedly succeeded" >&2
  exit 1
fi
rm -f "$OUT_DIR/link_z_cli" "$OUT_DIR/link_z_nolib"
CROSS_O="$OUT_DIR/cross_ffi_traits.o"
rm -f "$CROSS_O"
"$PIONC2" build --target amd64_sysv --emit-obj "$CROSS_O" "$ROOT_DIR/tests/e2e/ffi_traits.pion"
CROSS_FILE=$(file "$CROSS_O")
echo "$CROSS_FILE"
if ! printf '%s' "$CROSS_FILE" | grep -q 'ELF 64-bit LSB relocatable, x86-64'; then
  echo "FAIL: --target amd64_sysv --emit-obj did not produce an x86-64 ELF64 relocatable" >&2
  exit 1
fi
rm -f "$CROSS_O"
# dyn Trait: fat-pointer dispatch, vtables, Option[dyn Trait] niche, freeze/drop.
"$PIONC2" build -o "$OUT_DIR/dyn_trait" "$ROOT_DIR/tests/e2e/dyn_trait.pion"
DYN_OUT=$("$OUT_DIR/dyn_trait")
rm -f "$OUT_DIR/dyn_trait"
echo "dyn_trait -> $DYN_OUT"
if [ "$DYN_OUT" != "dyn_trait ok" ]; then
  echo "FAIL: dyn_trait output mismatch" >&2
  exit 1
fi
# pionc add / update against an offline git-index registry.
sh "$ROOT_DIR/tests/e2e/pkg_cli/run_e2e.sh" "$PIONC2"
# P26-A: native link ([link]/[link.macos]/[link.linux], c_sources .c/.cc, objects .a, search_paths, rpaths, frameworks, pionc test).
sh "$ROOT_DIR/tests/e2e/native_link/run_e2e.sh" "$PIONC2"
# P26-B: C callbacks (extern "C" fn body + c_fn_ptr), zero-copy FFI/math/StringBuilder, cross-pkg generic Option mono & private exports.
sh "$ROOT_DIR/tests/e2e/p26b_ffi_generics/run_e2e.sh" "$PIONC2"
# examples/https_server and examples/pion_station link the system OpenSSL; GitHub's macos-15 runner has no
# Homebrew openssl@3, so this runs only where it is installed.
if [ -d /opt/homebrew/opt/openssl@3/lib ]; then
  HTTPS_OUT=$(CC=cc LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib "$PIONC2" test --json "$ROOT_DIR/examples/https_server")
  printf 'pionc2 test --json examples/https_server -> %s\n' "$HTTPS_OUT"
  if ! printf '%s' "$HTTPS_OUT" | grep -q '"ok":true' || ! printf '%s' "$HTTPS_OUT" | grep -q '"failed":0'; then
    echo "FAIL: pionc2 test --json examples/https_server failed" >&2
    exit 1
  fi
  # Flagship: HTTPS + SSE + SQLite WAL + dyn Handler + std/regex + worker pool.
  STATION_OUT=$(CC=cc LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib "$PIONC2" test --json "$ROOT_DIR/examples/pion_station")
  printf 'pionc2 test --json examples/pion_station -> %s\n' "$STATION_OUT"
  if ! printf '%s' "$STATION_OUT" | grep -q '"ok":true' || ! printf '%s' "$STATION_OUT" | grep -q '"failed":0'; then
    echo "FAIL: pionc2 test --json examples/pion_station failed" >&2
    exit 1
  fi
else
  echo "NOTE: /opt/homebrew/opt/openssl@3/lib not found; skipping examples/https_server + examples/pion_station tests"
fi

echo "=== ALL 6 VERIFY-ALL GATES PASSED ==="
