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

# 5. [targets] inactive file isolation & fmt-clean:
#    5a) Host-only `import "ext_dep" as Box` + shared `caller.pion` vs wasm-only local `struct Box`:
#        host `pionc lint --fix` MUST NEVER inject `import` into inactive `wasm_only.pion`
#        OR into shared `caller.pion` (must keep `wasm32` `pionc check` green!).
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
"src/host_only.pion" = ["linux", "macos", "windows"]
EOF
cat > "$TGT_PKG/src/host_only.pion" <<'EOF'
import "ext_dep" as Box

pub fn host_fn() -> Int {
  Box::add(1, 2)
}
EOF
cat > "$TGT_PKG/src/caller.pion" <<'EOF'
pub fn call_box() -> Int {
  Box::add(3, 4)
}
EOF
cat > "$TGT_PKG/src/wasm_only.pion" <<'EOF'
struct Box { v : Int }

fn Box::add(a : Int, b : Int) -> Int {
  let b_val = Box::{ v: a + b }
  b_val.v
}

pub fn wasm_fn() -> Int {
  call_box()
}
EOF
WASM_HASH_BEFORE="$(file_sha256 "$TGT_PKG/src/wasm_only.pion")"
CALLER_HASH_BEFORE="$(file_sha256 "$TGT_PKG/src/caller.pion")"
set +e
TGT_FIX="$("$PIONC" lint --fix --json "$TGT_PKG")"
set -e
WASM_HASH_AFTER="$(file_sha256 "$TGT_PKG/src/wasm_only.pion")"
CALLER_HASH_AFTER="$(file_sha256 "$TGT_PKG/src/caller.pion")"
[ "$WASM_HASH_BEFORE" = "$WASM_HASH_AFTER" ] || { echo "FAIL: host lint --fix modified inactive wasm_only.pion!" >&2; exit 1; }
[ "$CALLER_HASH_BEFORE" = "$CALLER_HASH_AFTER" ] || { echo "FAIL: host lint --fix injected host-only import into shared caller.pion! $TGT_FIX" >&2; exit 1; }
"$PIONC" check --target wasm32 --json "$TGT_PKG" | grep -q '"ok":true' || { echo "FAIL: wasm32 check broken after host lint --fix!" >&2; exit 1; }

#    5b) Deleting sole unused import + multi-space `let mut  w` must pass `pionc fmt --check`.
FMT_PKG="$TMP_DIR/fmt_pkg"
mkdir -p "$FMT_PKG/src"
cat > "$FMT_PKG/pion.toml" <<'EOF'
[package]
name = "fmt_pkg"
version = "0.1.0"

[dependencies]
ext_dep = { path = "../ext_dep" }
EOF
cat > "$FMT_PKG/src/lib.pion" <<'EOF'
import "ext_dep"

pub fn host_fn() -> Int {
  let mut  w = 1
  w
}
EOF
FMT_FIX="$("$PIONC" lint --fix --json "$FMT_PKG")"
printf '%s' "$FMT_FIX" | grep -q '"ok":true' || { echo "FAIL: fmt_pkg --fix failed: $FMT_FIX" >&2; exit 1; }
FMT_AFTER="$("$PIONC" fmt --check --json "$FMT_PKG/src/lib.pion")"
[ "$FMT_AFTER" = '{"ok":true,"unformatted":[]}' ] || { echo "FAIL: lib.pion not fmt-clean after --fix: $FMT_AFTER" >&2; exit 1; }

#    5c) When an inactive target file fails to parse, conservatively forbid deleting ANY import.
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
SYM_CHK="$("$PIONC" lint --json "$SYM_PKG")"
"$PIONC" lint --fix --json "$SYM_PKG" >/dev/null
set -e
# R2 P2-1: public JSON must strip edits for non-committable symlink targets.
if printf '%s' "$SYM_CHK" | grep -q '"edits"'; then
  echo "FAIL: public lint --json exposed edits for symlink targets: $SYM_CHK" >&2
  exit 1
fi
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

# 11. P2-6, R2 P2-2, R3 P1-2, R3 P1-4, R3 P2-1, R3 P2-2:
#     CLI edge guards, lock failure fail-closed, nested sub-package isolation,
#     E_* symlink edit stripping, and all 4 `--fix --json` argument error schemas.
EMPTY_DIR="$TMP_DIR/empty_dir"
mkdir -p "$EMPTY_DIR"
set +e
EMPTY_OUT="$("$PIONC" lint --json "$EMPTY_DIR")"
EMPTY_RC=$?
EMPTY_FIX_OUT="$("$PIONC" lint --fix --json "$EMPTY_DIR")"
EMPTY_FIX_RC=$?
MIX_OUT="$("$PIONC" lint --json "$ISO_PKG" "$SINGLE")"
MIX_RC=$?
ARG_ERR1="$("$PIONC" lint --fix --json --target)"
ARG_RC1=$?
ARG_ERR2="$("$PIONC" lint --fix --json --target=bogus "$SINGLE")"
ARG_RC2=$?
ARG_ERR3="$("$PIONC" lint --fix --json --bad-opt "$SINGLE")"
ARG_RC3=$?
ARG_ERR4="$(cd "$EMPTY_DIR" && "$PIONC" lint --fix --json)"
ARG_RC4=$?
set -e
[ "$EMPTY_RC" -ne 0 ] || { echo "FAIL: empty directory must not return ok:true: $EMPTY_OUT" >&2; exit 1; }
[ "$EMPTY_FIX_RC" -ne 0 ] || { echo "FAIL: --fix on empty directory must fail: $EMPTY_FIX_OUT" >&2; exit 1; }
[ "$MIX_RC" -ne 0 ] || { echo "FAIL: mixing manifest root with multiple targets must fail: $MIX_OUT" >&2; exit 1; }
for ERR_PAIR in "$ARG_RC1|$ARG_ERR1" "$ARG_RC2|$ARG_ERR2" "$ARG_RC3|$ARG_ERR3" "$ARG_RC4|$ARG_ERR4" "$EMPTY_FIX_RC|$EMPTY_FIX_OUT"; do
  ERC="${ERR_PAIR%%|*}"
  EJSON="${ERR_PAIR#*|}"
  [ "$ERC" -ne 0 ] || { echo "FAIL: expected non-zero rc: $EJSON" >&2; exit 1; }
  printf '%s' "$EJSON" | grep -q '"fixed":0' || { echo "FAIL: --fix --json error missing fixed:0: $EJSON" >&2; exit 1; }
  printf '%s' "$EJSON" | grep -q '"files":\[\]' || { echo "FAIL: --fix --json error missing files:[]: $EJSON" >&2; exit 1; }
  printf '%s' "$EJSON" | grep -q '"diagnostics":\[\]' || { echo "FAIL: --fix --json error missing diagnostics:[]: $EJSON" >&2; exit 1; }
done

# R3 P1-2: Unwritable/file PION_CACHE_DIR must fail closed before writing any source file.
LOCK_FILE_BLOCKER="$TMP_DIR/not_a_dir"
printf 'blocker\n' > "$LOCK_FILE_BLOCKER"
LOCK_SRC="$TMP_DIR/lock_src.pion"
cat > "$LOCK_SRC" <<'EOF'
pub fn f() -> Int {
  let mut x = 1
  x
}
EOF
LOCK_HASH_BEFORE="$(file_sha256 "$LOCK_SRC")"
set +e
LOCK_OUT="$(PION_CACHE_DIR="$LOCK_FILE_BLOCKER" "$PIONC" lint --fix --json "$LOCK_SRC")"
LOCK_RC=$?
set -e
[ "$LOCK_RC" -ne 0 ] || { echo "FAIL: lock acquisition failure must exit non-zero: $LOCK_OUT" >&2; exit 1; }
printf '%s' "$LOCK_OUT" | grep -q '"fixed":0' || { echo "FAIL: lock failure must report fixed:0: $LOCK_OUT" >&2; exit 1; }
LOCK_HASH_AFTER="$(file_sha256 "$LOCK_SRC")"
[ "$LOCK_HASH_BEFORE" = "$LOCK_HASH_AFTER" ] || { echo "FAIL: lock failure still modified source file!" >&2; exit 1; }

# R3 P1-4: Nested sub-package (`outer/src/pion.toml`) must NOT be owned/linted by `outer`.
OUTER_PKG="$TMP_DIR/outer_pkg"
mkdir -p "$OUTER_PKG/src"
cat > "$OUTER_PKG/pion.toml" <<'EOF'
[package]
name = "outer_pkg"
version = "0.1.0"
EOF
cat > "$OUTER_PKG/lib.pion" <<'EOF'
pub fn outer_ok() -> Int {
  1
}
EOF
cat > "$OUTER_PKG/src/pion.toml" <<'EOF'
[package]
name = "nested_pkg"
version = "0.1.0"
EOF
cat > "$OUTER_PKG/src/nested.pion" <<'EOF'
pub fn nested_dirty() -> Int {
  let mut unused_mut = 7
  unused_mut
}
EOF
OUTER_OUT="$("$PIONC" lint --json "$OUTER_PKG")"
[ "$OUTER_OUT" = '{"ok":true,"diagnostics":[]}' ] || { echo "FAIL: nested src/pion.toml leaked into outer lint: $OUTER_OUT" >&2; exit 1; }

# R3 P2-1: E_* diagnostics on symlink targets must also strip non-committable edits.
SYM_E_REAL="$TMP_DIR/sym_e_real.pion"
cat > "$SYM_E_REAL" <<'EOF'
pub fn bad() -> Int {
  let x = 1
  x = 2
  x
}
EOF
SYM_E_LINK="$TMP_DIR/sym_e_link.pion"
ln -s "$SYM_E_REAL" "$SYM_E_LINK"
set +e
SYM_E_OUT="$("$PIONC" lint --json "$SYM_E_LINK")"
SYM_E_RC=$?
set -e
[ "$SYM_E_RC" -ne 0 ] || { echo "FAIL: expected E_* on sym_e_link" >&2; exit 1; }
printf '%s' "$SYM_E_OUT" | grep -q '"code":"E_TYPE_MISMATCH"' || { echo "FAIL: missing E_TYPE_MISMATCH: $SYM_E_OUT" >&2; exit 1; }
if printf '%s' "$SYM_E_OUT" | grep -q '"edits"'; then
  echo "FAIL: E_* on symlink must strip edits: $SYM_E_OUT" >&2
  exit 1
fi

# R4 P1-1 (Opus A): main calling a function defined in an out-of-package symlink must
# type-check identically to `pionc check` (0 spurious E_*) while not linting the symlink.
SYM_CALL_OUTSIDE="$TMP_DIR/sym_call_outside.pion"
cat > "$SYM_CALL_OUTSIDE" <<'EOF'
pub fn leaked() -> Int {
  let mut unused_outside = 7
  unused_outside
}
EOF
SYM_CALL_PKG="$TMP_DIR/sym_call_pkg"
mkdir -p "$SYM_CALL_PKG/src"
cat > "$SYM_CALL_PKG/pion.toml" <<'EOF'
[package]
name = "sym_call_pkg"
version = "0.1.0"
EOF
ln -s "$SYM_CALL_OUTSIDE" "$SYM_CALL_PKG/src/leak.pion"
cat > "$SYM_CALL_PKG/src/main.pion" <<'EOF'
pub fn main() -> Int {
  leaked()
}
EOF
"$PIONC" check "$SYM_CALL_PKG" >/dev/null
SYM_CALL_OUT="$("$PIONC" lint --json "$SYM_CALL_PKG")"
[ "$SYM_CALL_OUT" = '{"ok":true,"diagnostics":[]}' ] || { echo "FAIL: Opus A symlink caller regression: $SYM_CALL_OUT" >&2; exit 1; }

# R4 P1-1 (Opus B): outer/lib.pion calling nested `src/nested.pion` (when `src/pion.toml`
# exists) must type-check identically to `pionc check` (0 spurious E_*) without linting nested.
OUTER_CALL_PKG="$TMP_DIR/outer_call_pkg"
mkdir -p "$OUTER_CALL_PKG/src"
cat > "$OUTER_CALL_PKG/pion.toml" <<'EOF'
[package]
name = "outer_call_pkg"
version = "0.1.0"
EOF
cat > "$OUTER_CALL_PKG/lib.pion" <<'EOF'
pub fn outer_ok() -> Int {
  nested_dirty()
}
EOF
cat > "$OUTER_CALL_PKG/src/pion.toml" <<'EOF'
[package]
name = "nested_call_pkg"
version = "0.1.0"
EOF
cat > "$OUTER_CALL_PKG/src/nested.pion" <<'EOF'
pub fn nested_dirty() -> Int {
  let mut unused_mut = 7
  unused_mut
}
EOF
"$PIONC" check "$OUTER_CALL_PKG" >/dev/null
OUTER_CALL_OUT="$("$PIONC" lint --json "$OUTER_CALL_PKG")"
[ "$OUTER_CALL_OUT" = '{"ok":true,"diagnostics":[]}' ] || { echo "FAIL: Opus B nested caller regression: $OUTER_CALL_OUT" >&2; exit 1; }

# R4 P2-1 (Astra): normal writable package file with E_TYPE_MISMATCH must retain machine edits.
OWN_E_PKG="$TMP_DIR/own_e_pkg"
mkdir -p "$OWN_E_PKG/src"
cat > "$OWN_E_PKG/pion.toml" <<'EOF'
[package]
name = "own_e_pkg"
version = "0.1.0"
EOF
cat > "$OWN_E_PKG/src/main.pion" <<'EOF'
pub fn bad() -> Int {
  let x = 1
  x = 2
  x
}
EOF
set +e
OWN_E_OUT="$("$PIONC" lint --json "$OWN_E_PKG")"
OWN_E_RC=$?
set -e
[ "$OWN_E_RC" -ne 0 ] || { echo "FAIL: expected E_* on own_e_pkg" >&2; exit 1; }
printf '%s' "$OWN_E_OUT" | grep -q '"code":"E_TYPE_MISMATCH"' || { echo "FAIL: missing E_TYPE_MISMATCH on own_e_pkg: $OWN_E_OUT" >&2; exit 1; }
printf '%s' "$OWN_E_OUT" | grep -q '"edits":\[{' || { echo "FAIL: writable package file lost E_* machine edits: $OWN_E_OUT" >&2; exit 1; }

# R4 P1-2 (Astra): All 3 cross-target `[targets]` counterexamples must still pass
# `pionc check --target wasm32` after host `pionc lint --fix`.
# Case 1: host-only file (no inactive target file) + shared caller with local `Box::num()`
#         where wasm dep has conflicting signature.
CT1_DIR="$TMP_DIR/ct1"
mkdir -p "$CT1_DIR/dep/src" "$CT1_DIR/app/src"
cat > "$CT1_DIR/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"

[targets]
"src/native.pion" = ["native"]
"src/wasm.pion" = ["wasm32"]
EOF
cat > "$CT1_DIR/dep/src/native.pion" <<'EOF'
pub fn num() -> Int { 1 }
EOF
cat > "$CT1_DIR/dep/src/wasm.pion" <<'EOF'
pub fn num() -> String { "one" }
EOF
cat > "$CT1_DIR/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }

[targets]
"src/host.pion" = ["native"]
EOF
cat > "$CT1_DIR/app/src/host.pion" <<'EOF'
import "dep" as Box

pub fn host_fn() -> Int { Box::num() }
EOF
cat > "$CT1_DIR/app/src/caller.pion" <<'EOF'
pub struct Box { v : Int }
pub fn Box::num() -> Int { 2 }
pub fn call_num() -> Int { Box::num() }
EOF
"$PIONC" check "$CT1_DIR/app" >/dev/null
"$PIONC" check --target wasm32 "$CT1_DIR/app" >/dev/null
set +e
"$PIONC" lint --fix --json "$CT1_DIR/app" >/dev/null
set -e
"$PIONC" check "$CT1_DIR/app" >/dev/null
"$PIONC" check --target wasm32 "$CT1_DIR/app" >/dev/null

# Case 2: unconditional `one as Box` + wasm `two as Box` + shared caller.
CT2_DIR="$TMP_DIR/ct2"
mkdir -p "$CT2_DIR/one/src" "$CT2_DIR/two/src" "$CT2_DIR/app/src"
cat > "$CT2_DIR/one/pion.toml" <<'EOF'
[package]
name = "one"
version = "0.1.0"
EOF
cat > "$CT2_DIR/one/src/lib.pion" <<'EOF'
pub fn num() -> Int { 1 }
EOF
cat > "$CT2_DIR/two/pion.toml" <<'EOF'
[package]
name = "two"
version = "0.1.0"
EOF
cat > "$CT2_DIR/two/src/lib.pion" <<'EOF'
pub fn num() -> String { "two" }
EOF
cat > "$CT2_DIR/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
one = { path = "../one" }
two = { path = "../two" }

[targets]
"src/native.pion" = ["native"]
"src/wasm.pion" = ["wasm32"]
EOF
cat > "$CT2_DIR/app/src/native.pion" <<'EOF'
import "one" as Box

pub fn accept(x : Int) -> Int { x }
EOF
cat > "$CT2_DIR/app/src/wasm.pion" <<'EOF'
import "two" as Box

pub fn accept(x : String) -> Int { x.length() }
EOF
cat > "$CT2_DIR/app/src/caller.pion" <<'EOF'
pub fn call_it() -> Int { accept(Box::num()) }
EOF
"$PIONC" check "$CT2_DIR/app" >/dev/null
"$PIONC" check --target wasm32 "$CT2_DIR/app" >/dev/null
set +e
"$PIONC" lint --fix --json "$CT2_DIR/app" >/dev/null
set -e
"$PIONC" check "$CT2_DIR/app" >/dev/null
"$PIONC" check --target wasm32 "$CT2_DIR/app" >/dev/null

# Case 3: shared caller `let mut s; s.call()` where native takes `self` and wasm takes `mut self`.
CT3_DIR="$TMP_DIR/ct3"
mkdir -p "$CT3_DIR/dep/src" "$CT3_DIR/app/src"
cat > "$CT3_DIR/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"

[targets]
"src/native.pion" = ["native"]
"src/wasm.pion" = ["wasm32"]
EOF
cat > "$CT3_DIR/dep/src/native.pion" <<'EOF'
pub struct State { mut v : Int }
pub fn State::mk() -> State { State::{ v: 1 } }
pub fn State::call(self : State) -> Int { self.v }
EOF
cat > "$CT3_DIR/dep/src/wasm.pion" <<'EOF'
pub struct State { mut v : Int }
pub fn State::mk() -> State { State::{ v: 1 } }
pub fn State::call(mut self : State) -> Int {
  self.v = self.v + 1
  self.v
}
EOF
cat > "$CT3_DIR/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }
EOF
cat > "$CT3_DIR/app/src/caller.pion" <<'EOF'
import "dep"

pub fn run() -> Int {
  let mut s = dep::State::mk()
  s.call()
}
EOF
"$PIONC" check "$CT3_DIR/app" >/dev/null
"$PIONC" check --target wasm32 "$CT3_DIR/app" >/dev/null
CT3_OUT="$("$PIONC" lint --fix --json "$CT3_DIR/app")"
printf '%s' "$CT3_OUT" | grep -q '"ok":true' || { echo "FAIL: CT3 cross-target mut self should lint clean: $CT3_OUT" >&2; exit 1; }
"$PIONC" check "$CT3_DIR/app" >/dev/null
"$PIONC" check --target wasm32 "$CT3_DIR/app" >/dev/null

# R4 P1-3 (Astra): `pionc lint` and `pionc lint --fix` must NEVER create or modify `pion.lock`.
GIT_DEP="$TMP_DIR/git_dep_repo"
mkdir -p "$GIT_DEP/src"
cat > "$GIT_DEP/pion.toml" <<'EOF'
[package]
name = "git_dep"
version = "0.1.0"
EOF
cat > "$GIT_DEP/src/lib.pion" <<'EOF'
pub fn answer() -> Int { 42 }
EOF
git -C "$GIT_DEP" init -q
git -C "$GIT_DEP" config user.name "Test"
git -C "$GIT_DEP" config user.email "test@example.com"
git -C "$GIT_DEP" add -A
git -C "$GIT_DEP" commit -q -m "init"

GIT_APP="$TMP_DIR/git_app"
mkdir -p "$GIT_APP/src"
cat > "$GIT_APP/pion.toml" <<EOF
[package]
name = "git_app"
version = "0.1.0"

[dependencies]
git_dep = { git = "file://$GIT_DEP" }
EOF
cat > "$GIT_APP/src/main.pion" <<'EOF'
import "git_dep"

pub fn main() -> Int {
  let x = git_dep::answer()
  x = 1
  x
}
EOF
set +e
"$PIONC" lint --fix --json "$GIT_APP" >/dev/null
set -e
if [ -e "$GIT_APP/pion.lock" ]; then
  echo "FAIL: pionc lint --fix created pion.lock!" >&2
  exit 1
fi
set +e
"$PIONC" lint --json "$GIT_APP" >/dev/null
set -e
if [ -e "$GIT_APP/pion.lock" ]; then
  echo "FAIL: pionc lint created pion.lock!" >&2
  exit 1
fi

# 12. Real examples/ packages lint clean, and strict dynamic dogfood check explicitly
#     including all `compiler/src/core/*.pion` (including `lint*_test.pion`).
for EX in examples/text_stats examples/http_loopback; do
  EX_OUT="$("$PIONC" lint --json "$ROOT_DIR/$EX")"
  [ "$EX_OUT" = '{"ok":true,"diagnostics":[]}' ] || { echo "FAIL: pionc lint $EX -> $EX_OUT" >&2; exit 1; }
done
set +e
CORE_LINT_OUT="$("$PIONC" lint --json "$ROOT_DIR/compiler/src/core"/*.pion)"
CORE_LINT_RC=$?
set -e
if [ "$CORE_LINT_RC" -ne 0 ] && [ "$CORE_LINT_RC" -ne 1 ]; then
  echo "FAIL: unexpected exit code $CORE_LINT_RC from core dogfood lint" >&2
  exit 1
fi
python3 - "$CORE_LINT_OUT" "$ROOT_DIR/compiler/src/core" "$CORE_LINT_RC" <<'PYEOF'
import glob, json, os, sys
d = json.loads(sys.argv[1])
rc = int(sys.argv[3])
assert "error" not in d, f"unexpected error field in core dogfood JSON: {d}"
assert isinstance(d.get("ok"), bool), f"missing/non-bool ok in core dogfood JSON: {d}"
assert isinstance(d.get("diagnostics"), list), f"missing diagnostics array in core dogfood JSON: {d}"
diags = d["diagnostics"]
if rc == 0:
    assert d["ok"] is True and len(diags) == 0, f"rc=0 mismatch: {d}"
else:
    assert rc == 1 and d["ok"] is False and len(diags) > 0, f"rc={rc} mismatch: {d}"
e_diags = [x for x in diags if str(x.get("code", "")).startswith("E_")]
if e_diags:
    print("FAIL: unexpected E_* diagnostics in core/*.pion dogfood:", e_diags, file=sys.stderr)
    sys.exit(1)
lint_files = {os.path.basename(p) for p in glob.glob(os.path.join(sys.argv[2], "lint*.pion"))}
assert len(lint_files) >= 2 and "lint.pion" in lint_files and "lint_test.pion" in lint_files, f"expected lint*.pion files, got {lint_files}"
bad = [x for x in diags if os.path.basename(x.get("file", "")) in lint_files]
if bad:
    print("FAIL: dogfood diagnostics on lint*.pion:", bad, file=sys.stderr)
    sys.exit(1)
PYEOF

echo "[PASS] pionc_lint E2E: single-file, 2-round --fix + idempotency, fmt-clean, E_* fail-fast, workspace/dep isolation, *_test.pion, [targets], [verify] 10000-line, symlink guards, alternating alias, rollback, prod/test isolation, cross-target safety, read-only pion.lock, CLI guards, examples/, dogfood"
