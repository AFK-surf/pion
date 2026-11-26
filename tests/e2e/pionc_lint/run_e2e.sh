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

# 5. [targets] inactive file implicitly using `ext_dep`:
#    5a) Valid inactive file gets L_IMPLICIT_IMPORT + 2-round --fix + `pionc fmt --check` clean.
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
  let mut  w = 1
  w
}
EOF
cat > "$TGT_PKG/src/wasm_only.pion" <<'EOF'
pub fn wasm_fn() -> Int {
  ext_dep::add(1, 2)
}
EOF
set +e
TGT_CHK="$("$PIONC" lint --json "$TGT_PKG")"
TGT_CHK_RC=$?
set -e
[ "$TGT_CHK_RC" -ne 0 ] || { echo "FAIL: expected lint issues on tgt_pkg: $TGT_CHK" >&2; exit 1; }
printf '%s' "$TGT_CHK" | grep -q 'wasm_only.pion' || { echo "FAIL: inactive target file L_IMPLICIT_IMPORT missing: $TGT_CHK" >&2; exit 1; }
TGT_FIX="$("$PIONC" lint --fix --json "$TGT_PKG")"
printf '%s' "$TGT_FIX" | grep -q '"ok":true' || { echo "FAIL: tgt_pkg --fix failed: $TGT_FIX" >&2; exit 1; }
grep -q 'import "ext_dep"' "$TGT_PKG/src/wasm_only.pion" || { echo "FAIL: wasm_only.pion missing inserted import" >&2; exit 1; }
if grep -q 'import "ext_dep"' "$TGT_PKG/src/lib.pion"; then
  echo "FAIL: lib.pion unused import should be deleted after wasm_only.pion gets explicit import" >&2
  exit 1
fi
# P1-5: after deleting sole import & multi-space `let mut  w`, `pionc fmt --check` MUST pass!
FMT_AFTER="$("$PIONC" fmt --check --json "$TGT_PKG/src/lib.pion")"
[ "$FMT_AFTER" = '{"ok":true,"unformatted":[]}' ] || { echo "FAIL: lib.pion not fmt-clean after --fix: $FMT_AFTER" >&2; exit 1; }

#    5b) When an inactive target file fails to parse, conservatively forbid deleting ANY import.
TGT_BAD="$TMP_DIR/tgt_bad"
mkdir -p "$TGT_BAD/src"
cat > "$TGT_BAD/pion.toml" <<'EOF'
[package]
name = "tgt_bad"
version = "0.1.0"

[dependencies]
ext_dep = { path = "../ext_dep" }

[targets]
"src/broken_wasm.pion" = ["wasm32"]
EOF
cat > "$TGT_BAD/src/lib.pion" <<'EOF'
import "ext_dep"

pub fn host_fn() -> Int {
  1
}
EOF
cat > "$TGT_BAD/src/broken_wasm.pion" <<'EOF'
pub fn broken( {
EOF
set +e
TGT_BAD_FIX="$("$PIONC" lint --fix --json "$TGT_BAD")"
TGT_BAD_RC=$?
set -e
[ "$TGT_BAD_RC" -ne 0 ] || { echo "FAIL: expected L_UNUSED_IMPORT to remain on tgt_bad: $TGT_BAD_FIX" >&2; exit 1; }
grep -q 'import "ext_dep"' "$TGT_BAD/src/lib.pion" || { echo "FAIL: incomplete inactive target file failed to protect import!" >&2; exit 1; }

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

# 7. Symlink guards:
#    7a) Symlink pointing outside selected package must NOT be rewritten.
#    7b) Symlink pointing INSIDE selected package must NOT be replaced with regular file.
OUTSIDE_DIR="$TMP_DIR/outside"
SYM_PKG="$TMP_DIR/sym_pkg"
mkdir -p "$OUTSIDE_DIR" "$SYM_PKG/src"
cat > "$OUTSIDE_DIR/leak.pion" <<'EOF'
pub fn leaked() -> Int {
  let mut x = 1
  x
}
EOF
LEAK_HASH_BEFORE="$(file_sha256 "$OUTSIDE_DIR/leak.pion")"
cat > "$SYM_PKG/pion.toml" <<'EOF'
[package]
name = "sym_pkg"
version = "0.1.0"
EOF
cat > "$SYM_PKG/src/real.inc" <<'EOF'
pub fn inner_sym() -> Int {
  let mut y = 2
  y
}
EOF
INNER_HASH_BEFORE="$(file_sha256 "$SYM_PKG/src/real.inc")"
cat > "$SYM_PKG/src/main.pion" <<'EOF'
pub fn main() -> Int {
  leaked() + inner_sym()
}
EOF
ln -s "$OUTSIDE_DIR/leak.pion" "$SYM_PKG/src/leak.pion"
ln -s "real.inc" "$SYM_PKG/src/inner.pion"
set +e
"$PIONC" lint --fix --json "$SYM_PKG" >/dev/null
set -e
LEAK_HASH_AFTER="$(file_sha256 "$OUTSIDE_DIR/leak.pion")"
INNER_HASH_AFTER="$(file_sha256 "$SYM_PKG/src/real.inc")"
[ "$LEAK_HASH_BEFORE" = "$LEAK_HASH_AFTER" ] || { echo "FAIL: --fix wrote through outside symlink!" >&2; exit 1; }
[ -L "$SYM_PKG/src/inner.pion" ] || { echo "FAIL: --fix replaced in-package symlink with regular file!" >&2; exit 1; }
[ "$INNER_HASH_BEFORE" = "$INNER_HASH_AFTER" ] || { echo "FAIL: --fix modified in-package symlink target!" >&2; exit 1; }

# 8. P1-1: Alternating alias imports in same file: --fix must NOT change runtime output (11 vs 22).
ALT_DIR="$TMP_DIR/alt_pkg"
mkdir -p "$ALT_DIR/a/src" "$ALT_DIR/b/src" "$ALT_DIR/app/src"
cat > "$ALT_DIR/a/pion.toml" <<'EOF'
[package]
name = "a"
version = "0.1.0"
EOF
cat > "$ALT_DIR/a/src/lib.pion" <<'EOF'
pub fn num() -> Int { 11 }
EOF
cat > "$ALT_DIR/b/pion.toml" <<'EOF'
[package]
name = "b"
version = "0.1.0"
EOF
cat > "$ALT_DIR/b/src/lib.pion" <<'EOF'
pub fn num() -> Int { 22 }
EOF
cat > "$ALT_DIR/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
a = { path = "../a" }
b = { path = "../b" }
EOF
cat > "$ALT_DIR/app/src/main.pion" <<'EOF'
import "a" as d
import "b" as d
import "a" as d

pub fn main(w : World) -> Unit {
  io_println(w, d::num().to_string())
}
EOF
ALT_RUN_BEFORE="$("$PIONC" run "$ALT_DIR/app")"
[ "$ALT_RUN_BEFORE" = "11" ] || { echo "FAIL: alt_pkg expected 11 before fix, got $ALT_RUN_BEFORE" >&2; exit 1; }
set +e
"$PIONC" lint --fix --json "$ALT_DIR/app" >/dev/null
set -e
ALT_RUN_AFTER="$("$PIONC" run "$ALT_DIR/app")"
[ "$ALT_RUN_AFTER" = "11" ] || { echo "FAIL: alt_pkg semantics changed after --fix ($ALT_RUN_BEFORE -> $ALT_RUN_AFTER)!" >&2; exit 1; }

# 9. P1-2: Partial write failure rolls back earlier committed files to initial snapshots (non-root).
if [ "$(id -u)" -ne 0 ]; then
  RB_PKG="$TMP_DIR/rb_pkg"
  mkdir -p "$RB_PKG/src"
  cat > "$RB_PKG/pion.toml" <<'EOF'
[package]
name = "rb_pkg"
version = "0.1.0"
EOF
  cat > "$RB_PKG/a.pion" <<'EOF'
pub fn fa() -> Int {
  let mut x = 1
  x
}
EOF
  cat > "$RB_PKG/src/b.pion" <<'EOF'
pub fn fb() -> Int {
  let mut y = 2
  y
}
EOF
  RB_A_BEFORE="$(file_sha256 "$RB_PKG/a.pion")"
  RB_B_BEFORE="$(file_sha256 "$RB_PKG/src/b.pion")"
  chmod 555 "$RB_PKG/src"
  set +e
  "$PIONC" lint --fix --json "$RB_PKG" >/dev/null
  RB_RC=$?
  set -e
  chmod 755 "$RB_PKG/src"
  [ "$RB_RC" -ne 0 ] || { echo "FAIL: expected write failure on read-only dir" >&2; exit 1; }
  RB_A_AFTER="$(file_sha256 "$RB_PKG/a.pion")"
  RB_B_AFTER="$(file_sha256 "$RB_PKG/src/b.pion")"
  [ "$RB_A_BEFORE" = "$RB_A_AFTER" ] || { echo "FAIL: rollback did not restore a.pion after b.pion write failure!" >&2; exit 1; }
  [ "$RB_B_BEFORE" = "$RB_B_AFTER" ] || { echo "FAIL: read-only b.pion changed unexpectedly!" >&2; exit 1; }
fi

# 10. P2-2: Production vs test semantic isolation: test `fn panic` must NOT mask prod L_UNREACHABLE_CODE.
ISO_PKG="$TMP_DIR/iso_pkg"
mkdir -p "$ISO_PKG/src"
cat > "$ISO_PKG/pion.toml" <<'EOF'
[package]
name = "iso_pkg"
version = "0.1.0"
EOF
cat > "$ISO_PKG/src/lib.pion" <<'EOF'
pub fn boom() -> Int {
  panic("fatal")
  42
}
EOF
cat > "$ISO_PKG/src/lib_test.pion" <<'EOF'
fn panic(_s : String) -> Unit {
  ()
}

test "shadow" {
  panic("ok")
}
EOF
set +e
ISO_OUT="$("$PIONC" lint --json "$ISO_PKG")"
ISO_RC=$?
set -e
[ "$ISO_RC" -ne 0 ] || { echo "FAIL: expected L_UNREACHABLE_CODE in iso_pkg: $ISO_OUT" >&2; exit 1; }
printf '%s' "$ISO_OUT" | grep -q '"code":"L_UNREACHABLE_CODE"' || { echo "FAIL: test fn panic masked prod L_UNREACHABLE_CODE: $ISO_OUT" >&2; exit 1; }

# 11. P2-6: CLI edge guards (multi-target with manifest root; empty directory with 0 .pion files).
EMPTY_DIR="$TMP_DIR/empty_dir"
mkdir -p "$EMPTY_DIR"
set +e
EMPTY_OUT="$("$PIONC" lint --json "$EMPTY_DIR")"
EMPTY_RC=$?
MIX_OUT="$("$PIONC" lint --json "$ISO_PKG" "$SINGLE")"
MIX_RC=$?
set -e
[ "$EMPTY_RC" -ne 0 ] || { echo "FAIL: empty directory must not return ok:true: $EMPTY_OUT" >&2; exit 1; }
[ "$MIX_RC" -ne 0 ] || { echo "FAIL: mixing manifest root with multiple targets must fail: $MIX_OUT" >&2; exit 1; }

# 12. Real examples/ packages lint clean, and dynamic dogfood check on all compiler/src/core/lint*.pion.
for EX in examples/text_stats examples/http_loopback; do
  EX_OUT="$("$PIONC" lint --json "$ROOT_DIR/$EX")"
  [ "$EX_OUT" = '{"ok":true,"diagnostics":[]}' ] || { echo "FAIL: pionc lint $EX -> $EX_OUT" >&2; exit 1; }
done
set +e
CORE_LINT_OUT="$("$PIONC" lint --json "$ROOT_DIR/compiler/src/core")"
set -e
python3 - "$CORE_LINT_OUT" "$ROOT_DIR/compiler/src/core" <<'PYEOF'
import glob, json, os, sys
d = json.loads(sys.argv[1])
lint_files = {os.path.basename(p) for p in glob.glob(os.path.join(sys.argv[2], "lint*.pion"))}
assert len(lint_files) >= 2, f"expected lint*.pion files, got {lint_files}"
bad = [x for x in d.get("diagnostics", []) if os.path.basename(x.get("file", "")) in lint_files]
if bad:
    print("FAIL: dogfood diagnostics on lint*.pion:", bad, file=sys.stderr)
    sys.exit(1)
PYEOF

echo "[PASS] pionc_lint E2E: single-file, 2-round --fix + idempotency, fmt-clean, E_* fail-fast, workspace/dep isolation, *_test.pion, [targets], [verify] 10000-line, symlink guards, alternating alias, rollback, prod/test isolation, CLI guards, examples/, dogfood"
