#!/bin/sh
set -eu

export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"

# Bypass macOS /usr/bin/{cc,clang,ar,strip,ld,git} xcrun shims (~17ms/call).
if [ "$(uname -s)" = "Darwin" ]; then
  _xc_dirs=""
  for _xc_tool in clang git; do
    _xc_p="$(xcrun --find "$_xc_tool" 2>/dev/null || true)"
    if [ -n "$_xc_p" ]; then
      _xc_d="$(dirname -- "$_xc_p")"
      case ":$_xc_dirs:$PATH:" in
        *":$_xc_d:"*) ;;
        *) _xc_dirs="${_xc_dirs:+$_xc_dirs:}$_xc_d" ;;
      esac
    fi
  done
  if [ -n "$_xc_dirs" ]; then
    export PATH="$_xc_dirs:$PATH"
  fi
  if [ -z "${SDKROOT:-}" ]; then
    _xc_sdk="$(xcrun --show-sdk-path 2>/dev/null || true)"
    if [ -n "$_xc_sdk" ]; then
      export SDKROOT="$_xc_sdk"
    fi
  fi
fi

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="$ROOT_DIR/out"

# Helper sub-commands invoked inside run-e2e-parallel.sh (each uses its own
# mktemp -d + PION_CACHE_DIR and writes nothing to shared out/ or source tree).
if [ "${1:-}" = "--group" ]; then
  GROUP="$2"
  PIONC2="${PIONC2:-$OUT_DIR/pionc2}"
  G_TMP=$(mktemp -d)
  trap 'rm -rf "$G_TMP"' EXIT
  export PION_CACHE_DIR="$G_TMP/cas"
  mkdir -p "$PION_CACHE_DIR"
  case "$GROUP" in
    std_tests)
      for TPKG in examples/text_stats std/json std/http std/net std/regex std/proc std/tls; do
        if [ "$TPKG" = "examples/text_stats" ]; then
          TEST_OUT=$("$PIONC2" test --deps --json "$ROOT_DIR/$TPKG")
        else
          TEST_OUT=$("$PIONC2" test --json "$ROOT_DIR/$TPKG")
        fi
        printf 'pionc2 test --json %s -> %s\n' "$TPKG" "$TEST_OUT"
        if ! printf '%s' "$TEST_OUT" | grep -q '"ok":true' || ! printf '%s' "$TEST_OUT" | grep -q '"failed":0'; then
          echo "FAIL: pionc2 test --json $TPKG failed" >&2
          exit 1
        fi
        if [ "$TPKG" = "std/regex" ]; then
          # std/regex: 9 tests, two of them linear-time ReDoS guards ((a?){n}a{n}, nested quantifiers).
          REGEX_PASSED=$(printf '%s' "$TEST_OUT" | python3 -c 'import json, sys; d = json.load(sys.stdin); print("%d/%d" % (d["passed"], len(d["tests"])))')
          if [ "$REGEX_PASSED" != "9/9" ] || ! printf '%s' "$TEST_OUT" | grep -q '"name":"ReDoS: (a?){n}a{n} is linear","ok":true'; then
            echo "FAIL: std/regex expected 9/9 incl. ReDoS guards, got $REGEX_PASSED" >&2
            exit 1
          fi
          echo "std/regex: $REGEX_PASSED passed (ReDoS guards included)"
        fi
      done
      # `pionc init` scaffolds a package that is check/test/run/fmt-clean as is.
      "$PIONC2" init --json "$G_TMP/demo"
      "$PIONC2" check --json "$G_TMP/demo" | grep -q '"ok":true'
      INIT_TEST=$("$PIONC2" test --json "$G_TMP/demo")
      printf 'pionc2 test --json <init demo> -> %s\n' "$INIT_TEST"
      printf '%s' "$INIT_TEST" | grep -q '"ok":true'
      printf '%s' "$INIT_TEST" | grep -q '"failed":0'
      "$PIONC2" run "$G_TMP/demo"
      "$PIONC2" fmt --check --json "$G_TMP/demo" | grep -q '"ok":true'
      for DPKG in std/json std/http std/regex std/proc; do
        "$PIONC2" doc --json "$ROOT_DIR/$DPKG" | python3 -c 'import json, sys; d = json.load(sys.stdin); print("pionc2 doc --json %s -> valid JSON, %d package(s), %d public item(s)" % (sys.argv[1], len(d["packages"]), sum(len(p["items"]) for p in d["packages"])))' "$DPKG"
      done
      echo "[SUMMARY] std_tests (std/*, text_stats, regex 9/9 ReDoS, init, doc): OK"
      ;;
    mbt_tests)
      for TPKG in tools/mbt_compat tools/mbt2pion tools/mbt2pion_cli; do
        TEST_OUT=$("$PIONC2" test --json "$ROOT_DIR/$TPKG")
        printf 'pionc2 test --json %s -> %s\n' "$TPKG" "$TEST_OUT"
        if ! printf '%s' "$TEST_OUT" | grep -q '"ok":true' || ! printf '%s' "$TEST_OUT" | grep -q '"failed":0'; then
          echo "FAIL: pionc2 test --json $TPKG failed" >&2
          exit 1
        fi
      done
      echo "[SUMMARY] mbt_tests (mbt_compat, mbt2pion, mbt2pion_cli): OK"
      ;;
    dogfood_apps)
      for TPKG in examples/http_kv_service examples/http_event_server examples/sqlite_indexer; do
        TEST_OUT=$("$PIONC2" test --json "$ROOT_DIR/$TPKG")
        printf 'pionc2 test --json %s -> %s\n' "$TPKG" "$TEST_OUT"
        if ! printf '%s' "$TEST_OUT" | grep -q '"ok":true' || ! printf '%s' "$TEST_OUT" | grep -q '"failed":0'; then
          echo "FAIL: pionc2 test --json $TPKG failed" >&2
          exit 1
        fi
      done
      "$PIONC2" build --release -o "$G_TMP/http_kv_service" "$ROOT_DIR/examples/http_kv_service"
      "$G_TMP/http_kv_service" --self-test
      "$PIONC2" build --release -o "$G_TMP/http_event_server" "$ROOT_DIR/examples/http_event_server"
      "$G_TMP/http_event_server" --self-test
      "$PIONC2" build --release -o "$G_TMP/sqlite_indexer" "$ROOT_DIR/examples/sqlite_indexer"
      IDX_DB="$G_TMP/sqlite_indexer_check.db"
      IDX_JSON=$("$G_TMP/sqlite_indexer" "$ROOT_DIR/compiler/src/core" "$IDX_DB")
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
      # std/http over a workspace dependency graph (http -> json) must build and link.
      "$PIONC2" build -o "$G_TMP/http_loopback" "$ROOT_DIR/examples/http_loopback"
      echo "[SUMMARY] dogfood_apps (http_kv_service, http_event_server, sqlite_indexer, http_loopback): OK"
      ;;
    standalone_e2e)
      "$PIONC2" run "$ROOT_DIR/examples/text_stats"
      "$PIONC2" run "$ROOT_DIR/tests/e2e/net_ffi.pion"
      "$PIONC2" run "$ROOT_DIR/tests/e2e/utf8_text.pion"
      P22A_OUT=$("$PIONC2" run "$ROOT_DIR/tests/e2e/p22a_systems_io.pion")
      echo "p22a_systems_io -> $P22A_OUT"
      [ "$P22A_OUT" = "p22a_systems_io ok" ] || { echo "FAIL: p22a_systems_io output mismatch" >&2; exit 1; }
      P25A_OUT=$("$PIONC2" run "$ROOT_DIR/tests/e2e/p25a_c_varargs.pion")
      echo "p25a_c_varargs -> $P25A_OUT"
      [ "$P25A_OUT" = "a=42 b=-7 c=3.25" ] || { echo "FAIL: p25a_c_varargs output mismatch" >&2; exit 1; }
      P27A_OUT=$("$PIONC2" run "$ROOT_DIR/tests/e2e/p27a_ergonomics_bug4.pion")
      echo "p27a_ergonomics_bug4 -> $P27A_OUT"
      [ "$P27A_OUT" = "p27a_ergonomics_bug4 ok" ] || { echo "FAIL: p27a_ergonomics_bug4 output mismatch" >&2; exit 1; }
      P17A_OUT=$("$PIONC2" run "$ROOT_DIR/tests/e2e/p17a_ergonomics_mt.pion")
      echo "p17a_ergonomics_mt -> $P17A_OUT"
      [ "$P17A_OUT" = "p17a_ok log=2401 recs=3200 index=3200 keys=16" ] || { echo "FAIL: p17a_ergonomics_mt output mismatch" >&2; exit 1; }
      # Native libraries: `[link]` in pion.toml, `-l<lib>` on the CLI, and a failing link without them.
      "$PIONC2" run "$ROOT_DIR/tests/e2e/link_z"
      "$PIONC2" build -lz -o "$G_TMP/link_z_cli" "$ROOT_DIR/tests/e2e/link_z/src/main.pion"
      "$G_TMP/link_z_cli"
      if "$PIONC2" build -o "$G_TMP/link_z_nolib" "$ROOT_DIR/tests/e2e/link_z/src/main.pion" 2>/dev/null; then
        echo "FAIL: linking zlibVersion without -lz unexpectedly succeeded" >&2
        exit 1
      fi
      CROSS_O="$G_TMP/cross_ffi_traits.o"
      "$PIONC2" build --target amd64_sysv --emit-obj "$CROSS_O" "$ROOT_DIR/tests/e2e/ffi_traits.pion"
      CROSS_FILE=$(file "$CROSS_O")
      echo "$CROSS_FILE"
      printf '%s' "$CROSS_FILE" | grep -q 'ELF 64-bit LSB relocatable, x86-64' || {
        echo "FAIL: --target amd64_sysv --emit-obj did not produce an x86-64 ELF64 relocatable" >&2
        exit 1
      }
      # dyn Trait: fat-pointer dispatch, vtables, Option[dyn Trait] niche, freeze/drop.
      "$PIONC2" build -o "$G_TMP/dyn_trait" "$ROOT_DIR/tests/e2e/dyn_trait.pion"
      DYN_OUT=$("$G_TMP/dyn_trait")
      echo "dyn_trait -> $DYN_OUT"
      [ "$DYN_OUT" = "dyn_trait ok" ] || { echo "FAIL: dyn_trait output mismatch" >&2; exit 1; }
      # Wave J2: hot-path RC elision soundness (dev & --release + Wasm32 parity on single-threaded subset).
      "$PIONC2" build -o "$G_TMP/wave_j2_dev" "$ROOT_DIR/tests/e2e/wave_j2_rc_elision.pion"
      J2_DEV_OUT=$("$G_TMP/wave_j2_dev")
      "$PIONC2" build --release -o "$G_TMP/wave_j2_rel" "$ROOT_DIR/tests/e2e/wave_j2_rc_elision.pion"
      J2_REL_OUT=$("$G_TMP/wave_j2_rel")
      echo "wave_j2_rc_elision -> dev=$J2_DEV_OUT release=$J2_REL_OUT"
      case "$J2_DEV_OUT" in
        wave_j2_ok:*) ;;
        *) echo "FAIL: wave_j2_rc_elision bad dev output ($J2_DEV_OUT)" >&2; exit 1 ;;
      esac
      [ "$J2_DEV_OUT" = "$J2_REL_OUT" ] || {
        echo "FAIL: wave_j2_rc_elision dev/release mismatch (dev=$J2_DEV_OUT release=$J2_REL_OUT)" >&2
        exit 1
      }
      "$PIONC2" build --release -o "$G_TMP/wave_j2_st_rel" "$ROOT_DIR/tests/e2e/wave_j2_rc_elision_st.pion"
      J2_ST_NAT=$("$G_TMP/wave_j2_st_rel")
      case "$J2_ST_NAT" in
        wave_j2_st_ok:*) ;;
        *) echo "FAIL: wave_j2_rc_elision_st bad native output ($J2_ST_NAT)" >&2; exit 1 ;;
      esac
      if command -v node >/dev/null 2>&1; then
        "$PIONC2" build --release --target wasm32 -o "$G_TMP/wave_j2_st.wasm" "$ROOT_DIR/tests/e2e/wave_j2_rc_elision_st.pion"
        J2_ST_WASM=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$G_TMP/wave_j2_st.wasm")
        echo "wave_j2_rc_elision_st -> native=$J2_ST_NAT wasm32=$J2_ST_WASM"
        [ "$J2_ST_NAT" = "$J2_ST_WASM" ] || {
          echo "FAIL: wave_j2_rc_elision_st native/wasm32 mismatch (native=$J2_ST_NAT wasm32=$J2_ST_WASM)" >&2
          exit 1
        }
      fi
      P2_DEV_OUT=$("$PIONC2" run "$ROOT_DIR/tests/e2e/p_clbg_p2_divrem_licm_strbuf.pion")
      "$PIONC2" build --release -o "$G_TMP/p_clbg_p2_rel" "$ROOT_DIR/tests/e2e/p_clbg_p2_divrem_licm_strbuf.pion"
      P2_REL_OUT=$("$G_TMP/p_clbg_p2_rel")
      echo "p_clbg_p2_divrem_licm_strbuf -> dev=$P2_DEV_OUT release=$P2_REL_OUT"
      [ "$P2_DEV_OUT" = "p_clbg_p2_divrem_licm_strbuf ok" ] || { echo "FAIL: p_clbg_p2 dev output ($P2_DEV_OUT)" >&2; exit 1; }
      [ "$P2_REL_OUT" = "p_clbg_p2_divrem_licm_strbuf ok" ] || { echo "FAIL: p_clbg_p2 rel output ($P2_REL_OUT)" >&2; exit 1; }
      if command -v node >/dev/null 2>&1; then
        "$PIONC2" build --release --target wasm32 -o "$G_TMP/p_clbg_p2.wasm" "$ROOT_DIR/tests/e2e/p_clbg_p2_divrem_licm_strbuf.pion"
        P2_WASM_OUT=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$G_TMP/p_clbg_p2.wasm")
        echo "p_clbg_p2_divrem_licm_strbuf -> wasm32=$P2_WASM_OUT"
        [ "$P2_WASM_OUT" = "p_clbg_p2_divrem_licm_strbuf ok" ] || { echo "FAIL: p_clbg_p2 wasm32 output ($P2_WASM_OUT)" >&2; exit 1; }
      fi
      # CLBG P1: 2-variant null-niche enum 4-mode E2E (Native dev/release + Wasm32 dev/release)
      "$PIONC2" build -o "$G_TMP/p1_niche_dev" "$ROOT_DIR/tests/e2e/p_clbg_p1_null_niche_enum.pion"
      P1_DEV_OUT=$("$G_TMP/p1_niche_dev")
      "$PIONC2" build --release -o "$G_TMP/p1_niche_rel" "$ROOT_DIR/tests/e2e/p_clbg_p1_null_niche_enum.pion"
      P1_REL_OUT=$("$G_TMP/p1_niche_rel")
      echo "p_clbg_p1_null_niche_enum -> dev=$P1_DEV_OUT release=$P1_REL_OUT"
      [ "$P1_DEV_OUT" = "p1_ok s1=10 s2=64 s3=8 s4=60 s5=7 s6=28 s7=77 s8=39 s9=4102 s10=5 s11=441 s12=13" ] || {
        echo "FAIL: p_clbg_p1_null_niche_enum unexpected dev output ($P1_DEV_OUT)" >&2
        exit 1
      }
      [ "$P1_DEV_OUT" = "$P1_REL_OUT" ] || {
        echo "FAIL: p_clbg_p1_null_niche_enum dev/release mismatch" >&2
        exit 1
      }
      if command -v node >/dev/null 2>&1; then
        "$PIONC2" build --target wasm32 -o "$G_TMP/p1_niche_dev.wasm" "$ROOT_DIR/tests/e2e/p_clbg_p1_null_niche_enum.pion"
        P1_WASM_DEV=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$G_TMP/p1_niche_dev.wasm")
        "$PIONC2" build --release --target wasm32 -o "$G_TMP/p1_niche_rel.wasm" "$ROOT_DIR/tests/e2e/p_clbg_p1_null_niche_enum.pion"
        P1_WASM_REL=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$G_TMP/p1_niche_rel.wasm")
        echo "p_clbg_p1_null_niche_enum wasm32 -> dev=$P1_WASM_DEV release=$P1_WASM_REL"
        [ "$P1_DEV_OUT" = "$P1_WASM_DEV" ] && [ "$P1_DEV_OUT" = "$P1_WASM_REL" ] || {
          echo "FAIL: p_clbg_p1_null_niche_enum native/wasm32 mismatch" >&2
          exit 1
        }
      fi
      echo "[SUMMARY] standalone_e2e (text_stats, net_ffi, utf8, p22a/p25a/p27a/p17a, link_z, cross_elf, dyn_trait, wave_j2, p_clbg_p2, p1_niche): OK"
      ;;
    flagship_https_station)
      HTTPS_OUT=$("$PIONC2" test --json "$ROOT_DIR/examples/https_server")
      printf 'pionc2 test --json examples/https_server -> %s\n' "$HTTPS_OUT"
      if ! printf '%s' "$HTTPS_OUT" | grep -q '"ok":true' || ! printf '%s' "$HTTPS_OUT" | grep -q '"failed":0'; then
        echo "FAIL: pionc2 test --json examples/https_server failed" >&2
        exit 1
      fi
      # Flagship: HTTPS + SSE + SQLite WAL + dyn Handler + std/regex + worker pool.
      STATION_OUT=$("$PIONC2" test --deps --json "$ROOT_DIR/examples/pion_station")
      printf 'pionc2 test --json examples/pion_station -> %s\n' "$STATION_OUT"
      if ! printf '%s' "$STATION_OUT" | grep -q '"ok":true' || ! printf '%s' "$STATION_OUT" | grep -q '"failed":0'; then
        echo "FAIL: pionc2 test --json examples/pion_station failed" >&2
        exit 1
      fi
      echo "[SUMMARY] flagship_https_station (https_server + pion_station): OK"
      ;;
    *)
      echo "FAIL: unknown verify-all group: $GROUP" >&2
      exit 2
      ;;
  esac
  exit 0
fi

. "$ROOT_DIR/scripts/bg-lib.sh"
RT_LOG_DIR=$(mktemp -d)
TSAN_PID=""
ASAN_PID=""
SMOKE_PID=""
cleanup_verify() {
  bg_kill "$TSAN_PID" "$ASAN_PID" "$SMOKE_PID"
  rm -rf "$RT_LOG_DIR"
}
trap cleanup_verify EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "=== [1/6] Runtime Gate (libpionrt.a + MT bench; TSan + ASan + QBE smoke overlapped with Stage 0) ==="
sh "$ROOT_DIR/scripts/test-runtime.sh" --prep-only
bg_start "$RT_LOG_DIR/tsan.log" sh "$ROOT_DIR/scripts/test-runtime.sh" --step tsan
TSAN_PID="$BG_PID"
bg_start "$RT_LOG_DIR/asan.log" sh "$ROOT_DIR/scripts/test-runtime.sh" --step asan
ASAN_PID="$BG_PID"
bg_start "$RT_LOG_DIR/smoke.log" sh "$ROOT_DIR/scripts/test-runtime.sh" --step smoke
SMOKE_PID="$BG_PID"

echo "=== [2/6] 9/9 Pure-Pion Fixed-Point Self-Hosting Bootstrap (seed -> pionc0 -> pionc1 -> pionc2 + compiler/src/core tests) ==="
PION_SKIP_RT_TEST=1 PION_SKIP_QBE_BUILD=1 PION_STAGE0_ONLY=1 sh "$ROOT_DIR/scripts/bootstrap.sh"

echo "=== Joining async runtime gates (TSan + ASan + QBE smoke) ==="
RT_FAIL=0
if ! bg_join "$TSAN_PID" "$RT_LOG_DIR/tsan.log"; then
  RT_FAIL=1
  echo "FAIL: runtime ThreadSanitizer step" >&2
fi
TSAN_PID=""
if ! bg_join "$ASAN_PID" "$RT_LOG_DIR/asan.log"; then
  RT_FAIL=1
  echo "FAIL: runtime AddressSanitizer step" >&2
fi
ASAN_PID=""
if ! bg_join "$SMOKE_PID" "$RT_LOG_DIR/smoke.log"; then
  RT_FAIL=1
  echo "FAIL: QBE smoke step" >&2
fi
SMOKE_PID=""
if [ "$RT_FAIL" -ne 0 ]; then
  exit 1
fi

PION_STAGE0_ONLY=0 PION_STAGE0_BIN="$OUT_DIR/pionc0" PION_SKIP_RT_TEST=1 PION_SKIP_QBE_BUILD=1 PION_DEFER_CORE_TEST=1 sh "$ROOT_DIR/scripts/bootstrap.sh"

PIONC2="$OUT_DIR/pionc2"
export PION_QBE="$OUT_DIR/qbe"
export PION_RT_LIB="$OUT_DIR/libpionrt.a"

echo "=== [3/6] Standalone pionc2 Formatter Check ==="
FMT_OUT=$("$PIONC2" fmt --check --json "$ROOT_DIR/examples/text_stats" "$ROOT_DIR/benchmarks/pion" \
  "$ROOT_DIR/std/json" "$ROOT_DIR/std/http" "$ROOT_DIR/std/net" "$ROOT_DIR/examples/http_loopback" \
  "$ROOT_DIR/tests/e2e/net_ffi.pion" "$ROOT_DIR/tests/e2e/link_z" "$ROOT_DIR/examples/http_kv_service" \
  "$ROOT_DIR/examples/http_event_server" "$ROOT_DIR/examples/sqlite_indexer" \
  "$ROOT_DIR/tests/e2e/utf8_text.pion" "$ROOT_DIR/std/regex" "$ROOT_DIR/std/proc" "$ROOT_DIR/std/tls" \
  "$ROOT_DIR/tests/e2e/p17a_ergonomics_mt.pion" "$ROOT_DIR/examples/https_server" \
  "$ROOT_DIR/tests/e2e/dyn_trait.pion" "$ROOT_DIR/tests/e2e/p22a_systems_io.pion" \
  "$ROOT_DIR/tests/e2e/p25a_c_varargs.pion" "$ROOT_DIR/tests/e2e/p27a_ergonomics_bug4.pion" \
  "$ROOT_DIR/examples/pion_station" \
  "$ROOT_DIR/tools/mbt_compat" "$ROOT_DIR/tools/mbt2pion" "$ROOT_DIR/tools/mbt2pion_cli")
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

echo "=== [4-6/6] Parallel Test Runner, E2E Suites, Cross ELF64 .o & Flagship Dogfood ==="
# Independent test groups, E2E suites, dogfood apps and flagship TLS/SQLite tests
# (each in its own mktemp -d + CAS, ephemeral ports, nothing written to the source
# tree or out/) run concurrently; see scripts/run-e2e-parallel.sh.
export ROOT_DIR OUT_DIR PIONC2
# One ASan/TSan build of the runtime for all suites (see scripts/san-rt.sh).
. "$ROOT_DIR/scripts/san-rt-env.sh"
sh "$ROOT_DIR/scripts/run-e2e-parallel.sh" <<'E2E'
# Slowest suites first so the pool packs well.
# Gate [2/6] step [6/9], deferred by PION_DEFER_CORE_TEST=1: one long single-threaded build.
PION_CACHE_DIR="$OUT_DIR/cas_core_test" sh "$ROOT_DIR/scripts/core-test.sh" "$PIONC2"; RC=$?; rm -rf "$OUT_DIR/cas_core_test"; exit $RC
# Wave K1-A: Windows COFF per-symbol section GC, same-section jump tables, Mach-O .subsections_via_symbols & c_sources sections.
sh "$ROOT_DIR/tests/e2e/p98_section_gc/run_e2e.sh" "$PIONC2"
# Wave H-2 Track H5: ARM64 far conditional branches (> +-1MB) + QBE rega cold-call seeding + cold-block layout.
sh "$ROOT_DIR/tests/e2e/p90_qbe_far_branch_rega/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p87_st_frozen_rc/run_e2e.sh" "$PIONC2"
# P29-C: zero-toolchain WebAssembly (--target wasm32 + runtime/pion_wasm_rt.mjs + 4 V1 benchmarks in Node.js).
sh "$ROOT_DIR/tests/e2e/p29c_wasm32/run_e2e.sh" "$PIONC2"
# pionc add / update against an offline git-index registry.
sh "$ROOT_DIR/tests/e2e/pkg_cli/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tools/mbt2pion_cli/tests/run_e2e.sh" "$PIONC2"
# Wave J4b: Cargo-style package aliases, canonical package IDs, lockfile compat & C-export collision guard.
sh "$ROOT_DIR/tests/e2e/wave_j4b_pkg_alias/run_e2e.sh" "$PIONC2"
# Folded [4/6] std/* + text_stats + regex 9/9 ReDoS + init + doc, mbt*, dogfood release apps, [5/6] standalone e2e, and [6/6] TLS/flagship.
sh "$ROOT_DIR/scripts/verify-all.sh" --group std_tests
sh "$ROOT_DIR/scripts/verify-all.sh" --group mbt_tests
sh "$ROOT_DIR/scripts/verify-all.sh" --group dogfood_apps
sh "$ROOT_DIR/scripts/verify-all.sh" --group standalone_e2e
sh "$ROOT_DIR/scripts/verify-all.sh" --group flagship_https_station
sh "$ROOT_DIR/std/tls/e2e/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/std/tls/e2e/run_server_e2e.sh" "$PIONC2"
# Wave J3: first-class immutable Send sequence type ImmArray[T].
sh "$ROOT_DIR/tests/e2e/p94_imm_array/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/wave_l1b_eq_targets/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/closure_early_ret_and_infer/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p76_value_key_map/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p77_views_and_lib_os/run_e2e.sh" "$PIONC2"
# P30-H: cross-pkg generic Mutex[Array[Ev]] / Channel[Cmd] deep-freeze under real OS threads (release + ASan + TSan).
sh "$ROOT_DIR/tests/e2e/p30h_crosspkg_mt_deep_freeze/run_e2e.sh" "$PIONC2"
# Wave I1: pionc test single-pkg default + deps_skipped + parallel check+emit & c_sources + --version abi_rev.
sh "$ROOT_DIR/tests/e2e/p91_test_runner_cli/run_e2e.sh" "$PIONC2"
# P96: stack-promoted POD structs & StrView/BytesView carry 24B immortal PionHeader across multi-hop RC calls.
sh "$ROOT_DIR/tests/e2e/p96_pod_stack_rc_soundness/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p85_bytes_bce/run_e2e.sh" "$PIONC2"
# P97: per-process unique output staging directories (`test --jobs 4` race, same-pid leftovers, fail-fast mkdir errors).
sh "$ROOT_DIR/tests/e2e/p97_stage_dir_race/run_e2e.sh" "$PIONC2"
# P99: anonymous struct literals without a struct context fail closed in check (no NULL-struct SIGSEGV); legal contexts Native == Wasm32.
sh "$ROOT_DIR/tests/e2e/p99_anon_struct_lit/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p101_map_init_arg_order/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p27b_freeze_named_args/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p27c1_crosspkg_clo_intmap_eq/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p27c2_float_uint_fixedarray/run_e2e.sh" "$PIONC2"
# P26-A: native link ([link]/[link.macos]/[link.linux], c_sources .c/.cc, objects .a, search_paths, rpaths, frameworks, pionc test).
sh "$ROOT_DIR/tests/e2e/native_link/run_e2e.sh" "$PIONC2"
# P26-B: C callbacks (extern "C" fn body + c_fn_ptr), zero-copy FFI/math/StringBuilder, cross-pkg generic Option mono & private exports.
sh "$ROOT_DIR/tests/e2e/p26b_ffi_generics/run_e2e.sh" "$PIONC2"
# P29-A: multi-target (--target all 9 POSIX/mobile targets, --emit-asm, --emit-staticlib, --emit-cdylib, amd64_apple & ios_sim_arm64 cross checks).
sh "$ROOT_DIR/tests/e2e/p29a_multi_target/run_e2e.sh" "$PIONC2"
# P30-A: Bugs #9-#13 (Array/FixedArray::contains, tuple-Option-if match, E_CAPTURE_MUT_ASSIGN, Float bare lits, \u{...} escapes; native + ASan + Wasm32).
sh "$ROOT_DIR/tests/e2e/p30a_bugs9_to_13/run_e2e.sh" "$PIONC2"
# P30-B: single-thread RC fast path, borrow RC elision + adversarial ASan/LSan, Bug #15 unannotated closure param infer.
sh "$ROOT_DIR/tests/e2e/p30b_rc_borrow_perf/run_e2e.sh" "$PIONC2"
# P30-C: Bugs #16a & #16b (generic higher-order closure return infer + struct method own tparam unification; native + ASan + Wasm32).
sh "$ROOT_DIR/tests/e2e/p30c_generic_infer/run_e2e.sh" "$PIONC2"
# P31-A: -> Unit tail discard, struct TFn field direct call, local closure let mut auto-boxing, Array/Map::with_capacity (native + ASan/LSan + Wasm32).
sh "$ROOT_DIR/tests/e2e/p31a_ergonomics/run_e2e.sh" "$PIONC2"
# P31-C: leading-dot .Variant inference + pure compile-time desugared Pion-JSX + pionc fmt (native + ASan/LSan + Wasm32).
sh "$ROOT_DIR/tests/e2e/p31c_jsx_dot/run_e2e.sh" "$PIONC2"
# P32-A: relocatable zero-env toolchain, default ".", --help/--version, check --fix, doctor, cache/clean, remove, package-release.
sh "$ROOT_DIR/tests/e2e/p32a_toolchain/run_e2e.sh" "$PIONC2"
# P32-B: multi-package virtual [workspace], [workspace.dependencies], { workspace = true }, shared pion.lock, CLI --package/-p.
sh "$ROOT_DIR/tests/e2e/p32b_workspace/run_e2e.sh" "$PIONC2"
# P32-C: amd64_sysv direct ELF64 XMM stack-arg encoding (>8 Double/Float + mixed GPR/XMM).
sh "$ROOT_DIR/tests/e2e/p32c_abi_fp_stack/run_e2e.sh" "$PIONC2"
# P33-B: multi-package incremental CAS for `pionc check` (.pionsig/.pionstub) & `pionc build --target wasm32` (.ssa/.wasm).
sh "$ROOT_DIR/tests/e2e/p33b_incremental_cas/run_e2e.sh" "$PIONC2"
# P35-A: second-class `mut` parameters, `mut self`, `#verify` rules and runtime checks (native + ASan/LSan + Wasm32, cross-package `[verify]`).
sh "$ROOT_DIR/tests/e2e/p35a_verify_mut/run_e2e.sh" "$PIONC2"
# P68-B: QBE load.c/fold.c CAddr cross-type cast regression (enum String vs Double dead branch + direct cast).
sh "$ROOT_DIR/tests/e2e/p68b_qbe_caddr_cast/run_e2e.sh" "$PIONC2"
# P78: arm64_apple far (>32 KB) 64-bit spill slot store must not truncate via `fmov s31, w17`.
sh "$ROOT_DIR/tests/e2e/p78_qbe_arm64_bigframe_spill/run_e2e.sh" "$PIONC2"
# P79: QBE ARM64 fcsel/csel branchless if-conversion + ops.h xsel* widening + NaN soundness.
sh "$ROOT_DIR/tests/e2e/p79_qbe_fcsel/run_e2e.sh" "$PIONC2"
# P100: QBE soundness (copy.c dwl phi retry/cycle, gvn.c usecls jnz vs 64-bit ret, load.c shifted-store mask, mem.c 4-byte slot l extension, copyref cnew width).
sh "$ROOT_DIR/tests/e2e/p100_qbe_soundness/run_e2e.sh" "$PIONC2"
# P102: QBE codegen optimizations (test %r,%r, SIB shl folding + disp32/CAddr guards, short rel8, multi-byte NOP, acc imm32, arm64 stp/ldp).
sh "$ROOT_DIR/tests/e2e/p102_qbe_codegen_opts/run_e2e.sh" "$PIONC2"
# P103: Wave L0 — nested tuple patterns, Array::is_empty/truncate, Double::is_nan/compare/reinterpret_as_int64 + Hash -0.0, Int::lnot.
sh "$ROOT_DIR/tests/e2e/p103_wave_l0_stdlib_tuple/run_e2e.sh" "$PIONC2"
# P105: AArch64 private spill-slot stp/ldp pairing (arm64_slotpair unit test, text asm, qemu / native Mach-O --obj).
sh "$ROOT_DIR/tests/e2e/p105_arm64_spill_pairs/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p82a_wasm_arr_clear_f32_push/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p85_enum_sroa/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/query_analyze/run_e2e.sh" "$PIONC2"
# P108: QbeReadPair hoisted pair headers/bounds & bounded memchr byte scan.
sh "$ROOT_DIR/tests/e2e/p108_read_pair_and_byte_scan/run_e2e.sh" "$PIONC2"
# P109: native 3..8 part concat_n Int / Int64 `.to_string()` stack scratch parts (SSA + Native + Wasm32 + ASan).
sh "$ROOT_DIR/tests/e2e/p109_concat_scratch/run_e2e.sh" "$PIONC2"
# P110: generic fns / static methods as first-class values (mono / `%tp_*` wrappers) + `is` binding shadowing in the codegen probe (SSA + Native + Wasm32 + ASan, cross-package).
sh "$ROOT_DIR/tests/e2e/p110_fnval_flat_and_is_shadow/run_e2e.sh" "$PIONC2"
# P111: AArch64 seladdr local-slot [x29, #off] folding and single-use ldur/stur [base, #-1..-256] (text asm, matrix, native / qemu, Mach-O --obj == .s byte parity).
sh "$ROOT_DIR/tests/e2e/p111_arm64_addr_opts/run_e2e.sh" "$PIONC2"
# P112: native bounded integer string format in hot loops + QBE gcm groupconverts (SSA + Native + Wasm32 + ASan, -d G order, 8 x 625 C reference).
sh "$ROOT_DIR/tests/e2e/p112_bounded_format_and_swtof_sched/run_e2e.sh" "$PIONC2"
# P113: AMD64 movaps XMM copies + grouped-conversion xorps + cvtsi2{ss,sd}{l,q} text width (Native + Wasm32 + ASan, --obj == as, C driver).
sh "$ROOT_DIR/tests/e2e/p113_amd64_fp_dep_and_cvt_width/run_e2e.sh" "$PIONC2"
# P114: QBE loop jump-table private spill-home store sinking (rega.c sinktablehomes; -d SR structure on 3 targets, --obj / text C differential, Pion Native + Wasm32 + ASan, bytecode_vm, ASan+UBSan QBE replay).
sh "$ROOT_DIR/tests/e2e/p114_qbe_jtbl_edge_spill/run_e2e.sh" "$PIONC2"
# P117: QBE counted-loop expansion (main.c expandloops; -d G expansions on 5 targets, --obj / text C-oracle differential, --obj == as, no back edge, fannkuchredux, ASan+UBSan QBE replay).
sh "$ROOT_DIR/tests/e2e/p117_qbe_counted_loop_unroll/run_e2e.sh" "$PIONC2"
# P119: AMD64 scalar FP right-operand load fold (amd64/isel.c foldoperandloads; objdump structure of 20 folds / 12 controls on sysv text, win text, --obj and assembled text, --obj == text, checker mutation self-test, IEEE-754 bit + flag C differential over 4 rounding modes and misaligned operands with UBSan, ASan+UBSan QBE on 5 targets, Pion source + nbody).
sh "$ROOT_DIR/tests/e2e/p119_amd64_fp_rhs_load_fold/run_e2e.sh" "$PIONC2"
# P115: cross-package struct literal type probe uses canonical package ids (method symbols, SSA + Native + Wasm32).
sh "$ROOT_DIR/tests/e2e/p115_cross_pkg_struct_lit_probe/run_e2e.sh" "$PIONC2"
# P116: Opt-Track P byte-identical compile-speed changes (QBE 1-byte lexer lookahead, filllive worklist, philive projected phi liveness, rega compact snapshots next to sinktablehomes, Mach-O keep/gen GPR masks, main-thread first unit; checking QBE oracles with ASan+UBSan on 4 targets, host C differential, --jobs 1/2/4/8 parity).
sh "$ROOT_DIR/tests/e2e/p116_qbe_compile_speed_parity/run_e2e.sh" "$PIONC2"
# P118: Opt-Track R (amd64 jump-table selector in the dispatch scratch register, proven zero-extension indexes the table directly, widened-word interval comparison folding; text == --obj dispatch forms, -d G folds, host C differential with dirty high halves, bytecode_vm / fannkuchredux, ASan+UBSan QBE on 4 targets).
sh "$ROOT_DIR/tests/e2e/p118_qbe_jtbl_idx_and_widecmp/run_e2e.sh" "$PIONC2"
# P120: Win64 nonvolatile xmm6..xmm15 in QBE amd64_win (xmm0..xmm5-only rsave, 128-bit movups save/restore of the used xmm6..xmm14 and the xmm15 scratch; check_frames.py + mutants, x86-64 execution of the Win64 code with all 160 bytes of xmm6..xmm15 checked, ASan+UBSan QBE replay).
sh "$ROOT_DIR/tests/e2e/p120_win64_xmm_callee_saved/run_e2e.sh" "$PIONC2"
# Generic arithmetic operator instantiation checks & QBE monomorphization (dev, --release, wasm32, ASan).
sh "$ROOT_DIR/tests/e2e/generic_arith_mono/run_e2e.sh" "$PIONC2"
# P122: arm64_apple guarded jump-table dispatch copies (main.c replicatedispatch; br sites on 6 targets, text == Mach-O --obj, checker mutations, both-sides-table symmetry, no copy of a table shared by a rewritten edge, 24-copy limit, 8 QBE mutants of the match conditions and limit, 243712-input C reference via arm64_apple text and --obj on macOS ARM64, bytecode_vm == C with 24 run_vm sites, ASan+UBSan QBE replay).
sh "$ROOT_DIR/tests/e2e/p122_arm64_guarded_dispatch/run_e2e.sh" "$PIONC2"
# P123: amd64_sysv release guarded Array[Int] exchange (qbe_emit_guarded_exchange; @exchange_ structure on 6 targets + dev, 614 edge cases vs reference in --release and dev, 4 checked-loop SIGABRT traps with exact index, fannkuchredux = C with one 8-instruction exchange loop).
sh "$ROOT_DIR/tests/e2e/p123_amd64_guarded_exchange/run_e2e.sh" "$PIONC2"
# P125: native String slice spans + scalar Map[String, Int|Int64] entries + managed String file reads + native Channel[String].send without duplicate deep freeze (6 programs in --release and dev: exact exit status / stdout / stderr, slice-panic side-effect traces, call-mutated map fallback, 5 file kinds vs fs_read_bytes, SSA primitive presence).
sh "$ROOT_DIR/tests/e2e/p125_string_span_map_entry/run_e2e.sh" "$PIONC2"
# P121: Opt-Track T byte-identical cold frontend (#fmutlink dedup rows, checked ConstInitPlan reuse, call-free #cdep row replay, carried loop fingerprints; fan-out mut slots, const-init fast/fallback/cycle/type-error plans, 5 loop kinds with multi-pass fixed points + 64-pass fallback, QBE >64-copy parallel move, cold SSA + binary parity).
sh "$ROOT_DIR/tests/e2e/p121_frontend_cold_speed_opts/run_e2e.sh" "$PIONC2"
# P124: counted-fill length immediate for fresh local Array[Int] (qbe_record_counted_fill; 18 programs in --release and dev: immediate-only bounds checks for single / multi-array / empty fills, header length kept on alias, push, pop, capturing closure, mut and call arguments, shadowing incl. inside a while body that reads the outer array first; exact exit / stdout / stderr vs a plain-array reference incl. SIGABRT traps at -1, 37, 100 and 0 of 0).
sh "$ROOT_DIR/tests/e2e/p124_counted_array_length/run_e2e.sh" "$PIONC2"
# P126: Opt-Track X1 ecosystem codegen (cross-file immediately consumed Result/Option through scalar slots incl. ByteReader receiver writes, early Err, caller shadowing and argument `?`; immediately destructured 2-5 field primitive tuples in private stack slots, escaping / object-field tuples keep the heap box; fixed FixedArray / ImmArray literal table aliases check bounds against the literal length, shadowing / `let mut` / Array keep the header; native dev + --release SSA guards and exact output, Wasm32 dev + --release output).
sh "$ROOT_DIR/tests/e2e/p126_ecosystem_unbox_fixed_len/run_e2e.sh" "$PIONC2"
# P129: Opt-Track Z1 compile speed (single frame stack for check_binary_chain / qbe_emit_binary_chain, lazy left-operand guards, inline_rc substring scans + ASCII batch line split, target reuse in build/run; 4,000-deep left / right binary trees, 1,500 mixed &&/||, 1,200-part String +, 300 `?` operands, owned String/Array left operands with `?` / `return` right operands, inline_rc RC / call-only / `call`-prefixed identifier / UTF-8 bodies; dev + --release native, ASan/LSan and Wasm32 output, host / explicit / PION_TARGET / wasm32 build and run, --emit-web-rt accept / reject, bounded host probes).
sh "$ROOT_DIR/tests/e2e/p129_compile_speed_z1/run_e2e.sh" "$PIONC2"
# Track P3: opt-in single-hop `#into` converters and `into` parameter modifier (Native + Wasm32).
sh "$ROOT_DIR/tests/e2e/p_into_callsite/run_e2e.sh" "$PIONC2"
# P85: Hardware ROR + primitive bit-counting methods + struct/enum method call arity check.
sh "$ROOT_DIR/tests/e2e/p85_ror_bitops/run_e2e.sh" "$PIONC2"
# Wave G2: compact 4-byte Array/FixedArray of Int/UInt/Char (Native + ASan + Wasm32).
sh "$ROOT_DIR/tests/e2e/p85_compact_4b_arr/run_e2e.sh" "$PIONC2"
# Translation validation of QBE's SSA optimisations (tools/qbe_tv): every function of
# the real `qbe -d MG` traces validated by the strict checker, tampered traces and
# adversarial miscompilations rejected.
sh "$ROOT_DIR/scripts/test-tv.sh" "$PIONC2" "$OUT_DIR/qbe"
sh "$ROOT_DIR/tests/e2e/p71a_staticlib_android/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p71b_invar_fixes/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p72b_lang_cli/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p73_deep_rc_drop/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p74a_topo_init_and_variant/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p75a_compact_i8_f32/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p75b_simd_primitives/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p72a_flat_pod_opt/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p106_flat_array_field_proj/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p107_qbe_codegen_fixes/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p74c_licm_alias_soundness/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p74d_float_to_int_sat/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p74f_xpkg_pod_borrow_soundness/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p74e_cli_cas_hygiene/run_e2e.sh" "$PIONC2"
# Wave H-1: QBE spill/rega RSS + caller inline budget, ST frozen shared_rc + inline_rc upgrade, mut/chained borrow + scoped move-out.
sh "$ROOT_DIR/tests/e2e/p86_qbe_rss_budget/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/tests/e2e/p88_borrow_moveout/run_e2e.sh" "$PIONC2"
# Wave H-2 Track H4: unboxed 1-based C-style unit enums + Option[UnitEnum] null niche (dev + release + ASan/LSan + Wasm32 + xpkg).
sh "$ROOT_DIR/tests/e2e/p89_unit_enum/run_e2e.sh" "$PIONC2"
# Wave I2: *_data_ptr static E_TEMP_DATA_PTR guard + slot pinning (dev + release + ASan/LSan).
sh "$ROOT_DIR/tests/e2e/p91_data_ptr_safety/run_e2e.sh" "$PIONC2"
# Wave I3: zero-byte math primitives, exact Double::to_string, panic path sanitization & Web Wasm host bridge.
sh "$ROOT_DIR/tests/e2e/p92_math_wasm_paths/run_e2e.sh" "$PIONC2"
# Wave J0: symlinked pionc self-location + atomic (temp + rename) native/Wasm32 link publishing.
sh "$ROOT_DIR/tests/e2e/p93_cli_link_symlink/run_e2e.sh" "$PIONC2"
# P95: Wasm32 nested-loop outlining writes back inner-loop-only read+write slots (Native == Wasm32, Debug + --release).
sh "$ROOT_DIR/tests/e2e/p95_wasm_nested_loop_liveout/run_e2e.sh" "$PIONC2"
# Wave J1: 2,500-term &&+is short-circuit (Native+Wasm32), cold/hot CAS topo const-init, xpkg mono closure const.
sh "$ROOT_DIR/tests/e2e/wave_j1_soundness/run_e2e.sh" "$PIONC2"
# Wave L1-A: constant patterns, unified EIs scoping + ASan/LSan, closure fail-closed, builtin arity, test --json, struct lit & impl edit.
sh "$ROOT_DIR/tests/e2e/wave_l1a_soundness/run_e2e.sh" "$PIONC2"
sh "$ROOT_DIR/std/proc/e2e/run_e2e.sh" "$PIONC2"
E2E
# P71-C asserts wall-clock HashDoS budgets: run it alone, never next to the pool.
sh "$ROOT_DIR/tests/e2e/p71c_hashdos_bytes/run_e2e.sh" "$PIONC2"

echo "=== ALL 6 VERIFY-ALL GATES PASSED ==="
