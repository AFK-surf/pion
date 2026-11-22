#!/bin/sh
# P32-A end-to-end regression suite:
#   1) Relocatable zero-env install layout (<prefix>/{bin,lib,share/pion}) via PATH only
#   2) --help (exit 0), --version --json, doctor --json (ok:true)
#   3) Zero-arg default "." for check / fmt / test / run / build --release
#   4) pionc check --fix --json (auto-applies TextEdits, re-checks clean, runs clean)
#   5) pionc add + pionc remove --json (preserves comments/other sections, project stays clean)
#   6) pionc cache stats --json -> pionc clean --json -> pionc cache stats --json (0 files/bytes)
#   7) scripts/package-release.sh full archive + self-check
# Usage: sh tests/e2e/p32a_toolchain/run_e2e.sh <pionc>
set -eu

PIONC_ABS=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT_DIR="$ROOT_DIR/out"

if git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  tree_state() { git -C "$ROOT_DIR" status --porcelain --untracked-files=all; }
else
  tree_state() { (cd "$ROOT_DIR" && find . -path ./out -prune -o -path ./compiler/_build -prune -o -type f -print | LC_ALL=C sort); }
fi
TREE_BEFORE=$(tree_state)

W=$(mktemp -d)
trap 'chmod -R u+w "$W" 2>/dev/null || true; rm -rf "$W"' EXIT

fail() { echo "FAIL (p32a_toolchain): $*" >&2; exit 1; }
expect() {
  printf '%s' "$1" | grep -q -- "$2" || fail "$3: expected '$2' in '$1'"
}

# --- 1) Assemble relocatable prefix in /tmp -----------------------------------
PREFIX="$W/prefix"
mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/share/pion/runtime"
cp "$PIONC_ABS" "$PREFIX/bin/pionc"
cp "$OUT_DIR/qbe" "$PREFIX/bin/qbe"
chmod +x "$PREFIX/bin/pionc" "$PREFIX/bin/qbe"
cp "$OUT_DIR/libpionrt.a" "$PREFIX/lib/libpionrt.a"
cp "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$PREFIX/share/pion/pion_wasm_rt.mjs"
cp "$ROOT_DIR/runtime/pion_rt.c" "$PREFIX/share/pion/runtime/pion_rt.c"
cp "$ROOT_DIR/runtime/pion_rt.h" "$PREFIX/share/pion/runtime/pion_rt.h"

WORK="$W/work"
mkdir -p "$WORK"

(
  # Clear every PION_* variable to prove zero-env self-location via PATH alone.
  unset PION_QBE PION_RT_LIB PION_WASM_RT PION_SRC PION_TARGET PION_REGISTRY PION_CACHE_MAX_KB PION_CACHE_MAX_MB || true
  export PION_CACHE_DIR="$W/cas"
  export PATH="$PREFIX/bin:$PATH"
  cd "$WORK"

  # --- 2) --help, --version --json, doctor --json -----------------------------
  HELP_OUT=$(pionc --help)
  expect "$HELP_OUT" "pionc doctor" "--help mentions doctor"
  expect "$HELP_OUT" "pionc check \[--fix\]" "--help mentions check --fix"

  VER_JSON=$(pionc --version --json)
  echo "p32a --version --json -> $VER_JSON"
  expect "$VER_JSON" '"version":"0.1.0"' "version json"
  expect "$VER_JSON" '"target":' "version target"

  DOC_JSON=$(pionc doctor --json)
  echo "p32a doctor --json -> $DOC_JSON"
  expect "$DOC_JSON" '"ok":true' "doctor ok"
  expect "$DOC_JSON" "$PREFIX/bin/qbe" "doctor resolves relocatable qbe"
  expect "$DOC_JSON" "$PREFIX/lib/libpionrt.a" "doctor resolves relocatable rt_lib"
  expect "$DOC_JSON" "$PREFIX/share/pion/pion_wasm_rt.mjs" "doctor resolves relocatable wasm_rt"

  # No pion.toml in empty dir -> clear error and exit 1
  mkdir -p "$WORK/empty"
  if (cd "$WORK/empty" && pionc check >/dev/null 2>&1); then
    fail "pionc check in empty dir should exit non-zero"
  fi

  # --- 3) init + zero-arg check / fmt / test / run / build --release ----------
  pionc init demo >/dev/null
  cd "$WORK/demo"
  CHK0=$(pionc check)
  expect "$CHK0" '"ok":true' "zero-arg pionc check"
  FMT0=$(pionc fmt --check --json)
  expect "$FMT0" '"ok":true' "zero-arg pionc fmt --check --json"
  TST0=$(pionc test --json)
  expect "$TST0" '"ok":true' "zero-arg pionc test --json"
  expect "$TST0" '"failed":0' "zero-arg pionc test failed=0"
  pionc run >/dev/null
  pionc build --release -o "$W/demo_rel"
  "$W/demo_rel" >/dev/null
  echo "p32a zero-arg init/check/fmt/test/run/build --release: OK"

  # --- 4) pionc check --fix --json --------------------------------------------
  mkdir -p "$WORK/fixme"
  cat > "$WORK/fixme/app.pion" <<'EOF'
fn compute(x : Int) {
  x * 2 + 1
}

fn may_ok(v : Int) -> Result[Int, String] {
  Ok(v)
}

pub fn main(world : World) -> Int {
  may_ok(10)
  io_println(world, "fixed=" + compute(20).to_string())
  0
}
EOF
  if pionc check --json "$WORK/fixme/app.pion" >/dev/null 2>&1; then
    fail "fixme/app.pion should fail before --fix"
  fi
  FIX_JSON=$(pionc check --fix --json "$WORK/fixme/app.pion")
  echo "p32a check --fix --json -> $FIX_JSON"
  expect "$FIX_JSON" '"ok":true' "check --fix ok"
  expect "$FIX_JSON" '"fixed":2' "check --fix applied 2 edits"
  CHK_AFTER=$(pionc check --json "$WORK/fixme/app.pion")
  expect "$CHK_AFTER" '"ok":true' "re-check after --fix ok"
  FIX_RUN=$(pionc run "$WORK/fixme/app.pion")
  [ "$FIX_RUN" = "fixed=41" ] || fail "run after --fix expected 'fixed=41', got '$FIX_RUN'"
  echo "p32a check --fix --json + run: OK ($FIX_RUN)"

  # --- 5) pionc add + pionc remove --json -------------------------------------
  cd "$WORK"
  pionc init helper >/dev/null
  cd "$WORK/demo"
  printf '\n# keep this comment\n' >> "$WORK/demo/pion.toml"
  ADD_JSON=$(pionc add --json helper --path ../helper)
  expect "$ADD_JSON" '"ok":true' "add helper"
  grep -q 'helper = { path = "../helper" }' "$WORK/demo/pion.toml" || fail "helper not in pion.toml"

  REM_JSON=$(pionc remove --json helper)
  echo "p32a remove --json -> $REM_JSON"
  expect "$REM_JSON" '"ok":true' "remove helper ok"
  expect "$REM_JSON" '"removed":"helper"' "remove helper name"
  if grep -q 'helper =' "$WORK/demo/pion.toml"; then
    fail "helper still in pion.toml after remove"
  fi
  grep -q '# keep this comment' "$WORK/demo/pion.toml" || fail "remove dropped comment"
  CHK_REM=$(pionc check)
  expect "$CHK_REM" '"ok":true' "check after remove ok"

  # Removing missing dep must fail
  if pionc remove --json nosuch >/dev/null 2>&1; then
    fail "remove of missing dep should exit non-zero"
  fi
  echo "p32a add + remove --json: OK"

  # --- 6) pionc cache stats --json -> clean --json -> cache stats --json ------
  STATS1=$(pionc cache stats --json)
  echo "p32a cache stats (before clean) -> $STATS1"
  expect "$STATS1" '"ok":true' "cache stats ok"
  FILES_BEFORE=$(printf '%s' "$STATS1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_files"])')
  [ "$FILES_BEFORE" -gt 0 ] || fail "expected non-empty cache before clean, got $FILES_BEFORE"

  CLEAN_JSON=$(pionc clean --json)
  echo "p32a clean --json -> $CLEAN_JSON"
  expect "$CLEAN_JSON" '"ok":true' "clean ok"

  STATS2=$(pionc cache stats --json)
  echo "p32a cache stats (after clean) -> $STATS2"
  expect "$STATS2" '"total_files":0' "cache files zero after clean"
  expect "$STATS2" '"total_bytes":0' "cache bytes zero after clean"
)

# --- 7) scripts/package-release.sh archive + self-check -----------------------
PIONC="$PIONC_ABS" sh "$ROOT_DIR/scripts/package-release.sh" "$W/dist"

TREE_AFTER=$(tree_state)
[ "$TREE_BEFORE" = "$TREE_AFTER" ] || fail "source tree changed: $TREE_AFTER"
echo "p32a_toolchain e2e: ALL CHECKS PASSED (zero-env relocatable, --fix, doctor, cache/clean, remove, package-release)"
