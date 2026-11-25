#!/bin/sh
# P115: the codegen type probe resolves a cross-package struct literal
# (`paint::Glass::{ .. }`, `{ ..base }`, `paint::Box::{ ..b }`) to the same
# canonical package id as the emitter (compiler/src/core/qbe.pion
# `qbe_resolve_struct_lit_name`), so a method called on a `match` / `if` of such
# literals gets the symbol its package exports.
# Verifies, in dev & --release:
#   1. The SSA of every package (app, thin, mid, lg, paint, other) uses a canonical
#      package id in each method symbol, never the alias (`$pion_pkg_paint_m_*`,
#      `$pion_pkg_pt_m_*`).
#   2. Native and Wasm32 dev & --release link and print expected.txt. `app`
#      imports another package under the alias `paint`, so `lg`'s generic body
#      instantiated there must not resolve through the caller's aliases;
#      `thin` instantiates `lg` generics without importing `lg` or `paint`.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p115_cross_pkg_struct_lit_probe"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
cp -R "$DIR" "$TMP_DIR/p115"
PKGS="$TMP_DIR/p115"

# scan <ssa files dir> <label>: every `.ssa` the build produced, per package.
scan() {
  python3 -E - "$1" "$2" <<'PYEOF'
import pathlib, re, sys
label = sys.argv[2]
refs, pkgs = [], set()
for p in sorted(pathlib.Path(sys.argv[1]).rglob('*.ssa')):
    found = re.findall(r'\$(pion_pkg_(\w+?)_m_(?:Glass|Box|Slab)__\w+)', p.read_text())
    refs += found
    pkgs |= {pkg for _, pkg in found}
# Canonical id `paint__<8hex>`, mangled `0L<len>_paint_u_u<8hex>`.
canon = re.compile(r'0L\d+_(\w+)_u_u[0-9a-f]{8}')
bad = sorted({s for s, pkg in refs if not canon.fullmatch(pkg)})
if bad:
    raise SystemExit(f"FAIL: p115 {label}: non-canonical method symbols {bad}")
names = {canon.fullmatch(pkg).group(1) for pkg in pkgs}
if names != {'paint', 'other', 'lg'}:
    raise SystemExit(f"FAIL: p115 {label}: method symbols of packages {sorted(names)}, want lg, paint and other")
PYEOF
  echo "p115 $2 ok"
}

check() {
  if ! cmp -s "$DIR/expected.txt" "$2"; then
    diff -u "$DIR/expected.txt" "$2" >&2 || :
    echo "FAIL: p115 $1 output mismatch" >&2
    exit 1
  fi
  echo "p115 $1 ok"
}

for MODE in dev release; do
  FLAG=""
  [ "$MODE" = dev ] || FLAG="--release"
  export PION_CACHE_DIR="$TMP_DIR/cas_$MODE"
  mkdir -p "$PION_CACHE_DIR"
  for APP in app thin; do
    "$PIONC" build $FLAG -o "$TMP_DIR/${APP}_$MODE" "$PKGS/$APP"
  done
  scan "$PION_CACHE_DIR" "ssa $MODE"
  "$TMP_DIR/app_$MODE" > "$TMP_DIR/native.$MODE.txt"
  "$TMP_DIR/thin_$MODE" >> "$TMP_DIR/native.$MODE.txt"
  check "native $MODE" "$TMP_DIR/native.$MODE.txt"
  if command -v node >/dev/null 2>&1; then
    : > "$TMP_DIR/wasm.$MODE.txt"
    for APP in app thin; do
      "$PIONC" build $FLAG --target wasm32 -o "$TMP_DIR/${APP}_$MODE.wasm" "$PKGS/$APP"
      node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/${APP}_$MODE.wasm" >> "$TMP_DIR/wasm.$MODE.txt"
    done
    check "wasm32 $MODE" "$TMP_DIR/wasm.$MODE.txt"
  else
    echo "NOTE: p115 wasm32 $MODE skipped (node not found)"
  fi
done
echo "[SUMMARY] p115_cross_pkg_struct_lit_probe: OK"
