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
#   3. `shadow`: the workspace root package `paint` (canonical id `paint`, results
#      + 1000) and `paint2` (also named `paint`, id `paint__<8hex>`) have the same
#      structs. `app` imports the former as `paint` and instantiates `lg`, whose
#      `paint` is the latter; `app2` imports the former as `rootp` and the latter
#      as `paint`. An alias always means the package its own source imports,
#      for struct literals, struct / enum types and enum paths.
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

# check <label> <output> [expected]
check() {
  WANT="${3:-$DIR/expected.txt}"
  if ! cmp -s "$WANT" "$2"; then
    diff -u "$WANT" "$2" >&2 || :
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
  for APP in app app2; do
    OUT="$TMP_DIR/shadow_${APP}_$MODE"
    "$PIONC" build $FLAG -o "$OUT" "$PKGS/shadow/$APP"
    "$OUT" > "$OUT.txt"
    check "shadow $APP native $MODE" "$OUT.txt" "$DIR/shadow/$APP/expected.txt"
    if command -v node >/dev/null 2>&1; then
      "$PIONC" build $FLAG --target wasm32 -o "$OUT.wasm" "$PKGS/shadow/$APP"
      node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$OUT.wasm" > "$OUT.wasm.txt"
      check "shadow $APP wasm32 $MODE" "$OUT.wasm.txt" "$DIR/shadow/$APP/expected.txt"
    fi
  done
done
# 4. `app2`'s `paint` is `paint2`: names only the root package declares are unknown.
export PION_CACHE_DIR="$TMP_DIR/cas_neg"
mkdir -p "$PION_CACHE_DIR"
# neg <label> <statement> <name the diagnostic must mention>
neg() {
  printf 'import "paint"\nimport "rootp"\n\npub fn main(world : World) -> Int {\n  let r = rootp::RootOnly::{ n: 1 }\n  let o = rootp::RootKind::origin()\n  let g = paint::glass(1)\n  io_println(world, "\\{r.n} \\{o} \\{g.blur}")\n  %s\n  0\n}\n' \
    "$2" > "$PKGS/shadow/app2/src/main.pion"
  if "$PIONC" build -o "$TMP_DIR/neg" "$PKGS/shadow/app2" > "$TMP_DIR/neg.out" 2>&1; then
    echo "FAIL: p115 neg $1 compiled" >&2
    exit 1
  fi
  if ! { grep -q '"code":"E_' "$TMP_DIR/neg.out" && grep -qF "$3" "$TMP_DIR/neg.out"; }; then
    cat "$TMP_DIR/neg.out" >&2
    echo "FAIL: p115 neg $1: no diagnostic mentions $3" >&2
    exit 1
  fi
  echo "p115 neg $1 ok"
}
# Same source without the offending name must build, so `neg` fails for the name.
printf 'import "paint"\nimport "rootp"\n\npub fn main(world : World) -> Int {\n  let r = rootp::RootOnly::{ n: 1 }\n  let o = rootp::RootKind::origin()\n  let g = paint::glass(1)\n  io_println(world, "\\{r.n} \\{o} \\{g.blur}")\n  0\n}\n' \
  > "$PKGS/shadow/app2/src/main.pion"
"$PIONC" build -o "$TMP_DIR/neg" "$PKGS/shadow/app2"
CTRL_OUT=$("$TMP_DIR/neg")
[ "$CTRL_OUT" = "1 83 1" ] || { echo "FAIL: p115 neg control output" >&2; exit 1; }
neg annotated-literal 'let x : paint::RootOnly = paint::RootOnly::{ n: 87 }' paint::RootOnly
neg literal 'let x = paint::RootOnly::{ n: 87 }' paint::RootOnly
neg type 'let x : paint::RootOnly = r' paint::RootOnly
neg enum-type 'let x : paint::RootKind = rootp::RootKind::Root' paint::RootKind
neg enum-path 'let x = paint::RootKind::Root' paint::RootKind
neg static-call 'let x = paint::RootKind::origin()' paint::RootKind::origin
neg static-value 'let f = paint::RootKind::origin
  let x = f()' paint::RootKind::origin
echo "[SUMMARY] p115_cross_pkg_struct_lit_probe: OK"
