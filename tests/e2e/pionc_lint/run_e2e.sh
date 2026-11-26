#!/bin/sh
# E2E gate for `pionc lint` (single file, 2-round multi-file --fix + idempotency,
# E_* fail-fast, workspace + external ../path dep isolation, *_test.pion,
# [targets] inactive-file import protection, [verify] raw line count,
# symlink escape guard, zero-customization rejection, and real examples/).
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
PIONC="${1:-}"
if [ -z "$PIONC" ]; then
  echo "usage: $0 <pionc>" >&2
  exit 1
fi
case "$PIONC" in
  /*) ;;
  *) PIONC="$(pwd)/$PIONC" ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# 1. Single file: detect L_UNUSED_LOCAL + L_UNUSED_MUT, --fix, and verify idempotency.
SINGLE="$TMP_DIR/single.pion"
cat > "$SINGLE" <<'EOF'
pub fn compute(x : Int) -> Int {
  let mut y = x + 1
  let dead = 99
  y
}
EOF

set +e
OUT1="$("$PIONC" lint --json "$SINGLE")"
RC1=$?
set -e
[ "$RC1" -ne 0 ] || { echo "FAIL: expected non-zero rc for single.pion: $OUT1" >&2; exit 1; }
printf '%s' "$OUT1" | grep -q '"code":"L_UNUSED_MUT"' || { echo "FAIL: missing L_UNUSED_MUT: $OUT1" >&2; exit 1; }
printf '%s' "$OUT1" | grep -q '"code":"L_UNUSED_LOCAL"' || { echo "FAIL: missing L_UNUSED_LOCAL: $OUT1" >&2; exit 1; }

FIX1="$("$PIONC" lint --fix --json "$SINGLE")"
printf '%s' "$FIX1" | grep -q '"ok":true' || { echo "FAIL: single --fix not ok: $FIX1" >&2; exit 1; }
printf '%s' "$FIX1" | grep -q '"fixed":2' || { echo "FAIL: single --fix expected fixed:2: $FIX1" >&2; exit 1; }

FIX2="$("$PIONC" lint --fix --json "$SINGLE")"
printf '%s' "$FIX2" | grep -q '"ok":true' || { echo "FAIL: single --fix idempotent not ok: $FIX2" >&2; exit 1; }
printf '%s' "$FIX2" | grep -q '"fixed":0' || { echo "FAIL: single --fix not idempotent: $FIX2" >&2; exit 1; }
printf '%s' "$FIX2" | grep -q '"files":\[\]' || { echo "FAIL: single --fix modified files on second run: $FIX2" >&2; exit 1; }

# 2. E_* compile error must fail fast without running lint or touching disk.
BAD_E="$TMP_DIR/bad_e.pion"
cat > "$BAD_E" <<'EOF'
pub fn broken() -> Int {
  let mut x = 1
  "not_int"
}
EOF
BAD_HASH_BEFORE="$(file_sha256 "$BAD_E" | awk '{print $1}')"
set +e
OUT_E="$("$PIONC" lint --fix --json "$BAD_E")"
RC_E=$?
set -e
[ "$RC_E" -ne 0 ] || { echo "FAIL: expected non-zero rc on E_* file: $OUT_E" >&2; exit 1; }
printf '%s' "$OUT_E" | grep -q '"code":"E_TYPE_MISMATCH"' || { echo "FAIL: expected E_TYPE_MISMATCH: $OUT_E" >&2; exit 1; }
if printf '%s' "$OUT_E" | grep -q '"code":"L_'; then
  echo "FAIL: lint must not emit L_* when E_* exists: $OUT_E" >&2
  exit 1
fi
BAD_HASH_AFTER="$(file_sha256 "$BAD_E" | awk '{print $1}')"
[ "$BAD_HASH_BEFORE" = "$BAD_HASH_AFTER" ] || { echo "FAIL: --fix touched disk on E_* file" >&2; exit 1; }

# 3. Zero-customization guard: unknown flags like --disable must be rejected.
set +e
"$PIONC" lint --disable L_UNUSED_LOCAL "$SINGLE" >/dev/null 2>&1
RC_DIS=$?
set -e
[ "$RC_DIS" -ne 0 ] || { echo "FAIL: pionc lint must reject --disable" >&2; exit 1; }

# 4. Workspace + external ../path dependency isolation + 2-round cross-file import --fix + *_test.pion.
EXT_DEP="$TMP_DIR/ext_dep"
mkdir -p "$EXT_DEP/src"
cat > "$EXT_DEP/pion.toml" <<'EOF'
[package]
name = "ext_dep"
version = "0.1.0"
EOF
cat > "$EXT_DEP/src/lib.pion" <<'EOF'
pub fn add(a : Int, b : Int) -> Int {
  let mut keep_dep_dirty = a + b
  let dep_unused = 123
  keep_dep_dirty
}
EOF
cat > "$EXT_DEP/src/lib_test.pion" <<'EOF'
test "ext dep test with lint issues" {
  let dep_test_unused = 456
  let _ = add(1, 2)
}
EOF
EXT_HASH_BEFORE="$(file_sha256 "$EXT_DEP/src/lib.pion" | awk '{print $1}')"

WS="$TMP_DIR/ws"
mkdir -p "$WS/app/src"
cat > "$WS/pion.toml" <<'EOF'
[workspace]
members = ["app"]
EOF
cat > "$WS/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
ext_dep = { path = "../../ext_dep" }
EOF
cat > "$WS/app/src/a.pion" <<'EOF'
import "ext_dep"

pub fn fa() -> Int {
  1
}
EOF
cat > "$WS/app/src/b.pion" <<'EOF'
pub fn fb() -> Int {
  ext_dep::add(2, 3)
}
EOF
cat > "$WS/app/src/app_test.pion" <<'EOF'
test "app test" {
  let test_unused = fa() + fb()
  let _ = 0
}
EOF

set +e
WS_OUT="$("$PIONC" lint --json "$WS")"
WS_RC=$?
set -e
[ "$WS_RC" -ne 0 ] || { echo "FAIL: expected lint issues in workspace app: $WS_OUT" >&2; exit 1; }
if printf '%s' "$WS_OUT" | grep -q 'ext_dep/src/'; then
  echo "FAIL: external ../path dependency must not be linted: $WS_OUT" >&2
  exit 1
fi
printf '%s' "$WS_OUT" | grep -q '"code":"L_IMPLICIT_IMPORT"' || { echo "FAIL: missing L_IMPLICIT_IMPORT: $WS_OUT" >&2; exit 1; }
printf '%s' "$WS_OUT" | grep -q '"code":"L_UNUSED_IMPORT"' || { echo "FAIL: missing L_UNUSED_IMPORT: $WS_OUT" >&2; exit 1; }
printf '%s' "$WS_OUT" | grep -q 'app_test.pion' || { echo "FAIL: selected package *_test.pion must be linted: $WS_OUT" >&2; exit 1; }

# 2-round transactional --fix: round 1 adds import to b.pion & fixes app_test.pion,
# round 2 removes unused import from a.pion.
WS_FIX1="$("$PIONC" lint --fix --json "$WS")"
printf '%s' "$WS_FIX1" | grep -q '"ok":true' || { echo "FAIL: workspace 2-round --fix failed: $WS_FIX1" >&2; exit 1; }
grep -q 'import "ext_dep"' "$WS/app/src/b.pion" || { echo "FAIL: b.pion missing inserted import" >&2; exit 1; }
if grep -q 'import "ext_dep"' "$WS/app/src/a.pion"; then
  echo "FAIL: a.pion unused import was not removed in round 2" >&2
  exit 1
fi
EXT_HASH_AFTER="$(file_sha256 "$EXT_DEP/src/lib.pion" | awk '{print $1}')"
[ "$EXT_HASH_BEFORE" = "$EXT_HASH_AFTER" ] || { echo "FAIL: --fix modified external dependency!" >&2; exit 1; }

WS_FIX2="$("$PIONC" lint --fix --json "$WS")"
printf '%s' "$WS_FIX2" | grep -q '"ok":true' || { echo "FAIL: workspace --fix idempotent not ok: $WS_FIX2" >&2; exit 1; }
printf '%s' "$WS_FIX2" | grep -q '"fixed":0' || { echo "FAIL: workspace --fix not idempotent: $WS_FIX2" >&2; exit 1; }

# 5. [targets] inactive file implicitly using `ext_dep` must prevent --fix from deleting import.
TGT_PKG="$TMP_DIR/tgt_pkg"
mkdir -p "$TGT_PKG/src"
cat > "$TGT_PKG/pion.toml" <<'EOF'
[package]
name = "tgt_pkg"
version = "0.1.0"

[dependencies]
ext_dep = { path = "../ext_dep" }

[targets]
"src/wasm_only.pion" = ["wasm32"]
EOF
cat > "$TGT_PKG/src/lib.pion" <<'EOF'
import "ext_dep"

pub fn host_fn() -> Int {
  1
}
EOF
cat > "$TGT_PKG/src/wasm_only.pion" <<'EOF'
pub fn wasm_fn() -> Int {
  ext_dep::add(1, 2)
}
EOF
set +e
TGT_FIX="$("$PIONC" lint --fix --json "$TGT_PKG")"
TGT_RC=$?
set -e
[ "$TGT_RC" -ne 0 ] || { echo "FAIL: expected L_UNUSED_IMPORT to remain unfixed: $TGT_FIX" >&2; exit 1; }
printf '%s' "$TGT_FIX" | grep -q '"code":"L_UNUSED_IMPORT"' || { echo "FAIL: missing L_UNUSED_IMPORT: $TGT_FIX" >&2; exit 1; }
grep -q 'import "ext_dep"' "$TGT_PKG/src/lib.pion" || { echo "FAIL: inactive target implicit import was deleted!" >&2; exit 1; }

# 6. [verify] enabled = true: exact 10000-line file must NOT trigger L_FILE_TOO_LONG.
VER_PKG="$TMP_DIR/ver_pkg"
mkdir -p "$VER_PKG/src"
cat > "$VER_PKG/pion.toml" <<'EOF'
[package]
name = "ver_pkg"
version = "0.1.0"

[verify]
enabled = true
EOF
python3 - "$VER_PKG/src/lib.pion" <<'PYEOF'
import sys
with open(sys.argv[1], "w") as f:
    f.write("pub fn ok() -> Int {\n")
    for _ in range(9997):
        f.write("// pad\n")
    f.write("  1\n}\n")
PYEOF
VER_OUT="$("$PIONC" lint --json "$VER_PKG")"
[ "$VER_OUT" = '{"ok":true,"diagnostics":[]}' ] || { echo "FAIL: [verify] 10000-line package failed: $VER_OUT" >&2; exit 1; }

# 7. Symlink escape guard: symlink pointing outside selected package must NOT be rewritten by --fix.
OUTSIDE_DIR="$TMP_DIR/outside"
SYM_PKG="$TMP_DIR/sym_pkg"
mkdir -p "$OUTSIDE_DIR" "$SYM_PKG/src"
cat > "$OUTSIDE_DIR/leak.pion" <<'EOF'
pub fn leaked() -> Int {
  let mut x = 1
  x
}
EOF
LEAK_HASH_BEFORE="$(file_sha256 "$OUTSIDE_DIR/leak.pion" | awk '{print $1}')"
cat > "$SYM_PKG/pion.toml" <<'EOF'
[package]
name = "sym_pkg"
version = "0.1.0"
EOF
cat > "$SYM_PKG/src/main.pion" <<'EOF'
pub fn main() -> Int {
  leaked()
}
EOF
ln -s "$OUTSIDE_DIR/leak.pion" "$SYM_PKG/src/leak.pion"
set +e
"$PIONC" lint --fix --json "$SYM_PKG" >/dev/null
set -e
LEAK_HASH_AFTER="$(file_sha256 "$OUTSIDE_DIR/leak.pion" | awk '{print $1}')"
[ "$LEAK_HASH_BEFORE" = "$LEAK_HASH_AFTER" ] || { echo "FAIL: --fix wrote through symlink outside package!" >&2; exit 1; }

# 8. Real examples/ packages lint clean.
for EX in examples/text_stats examples/http_loopback; do
  EX_OUT="$("$PIONC" lint --json "$ROOT_DIR/$EX")"
  [ "$EX_OUT" = '{"ok":true,"diagnostics":[]}' ] || { echo "FAIL: pionc lint $EX -> $EX_OUT" >&2; exit 1; }
done

echo "[PASS] pionc_lint E2E: single-file, 2-round --fix + idempotency, E_* fail-fast, workspace/dep isolation, *_test.pion, [targets], [verify] 10000-line, symlink guard, examples/"
