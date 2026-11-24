#!/bin/sh
set -eu

# Wave J4b E2E: Cargo-style dependency aliases (`package = "..."`), canonical
# package ID (`canon_id`) symbol/CAS isolation, `pion.lock` v1 compatibility &
# `--locked`/`--offline`, package-name mismatch guard, and `E_DUPLICATE_C_SYMBOL`
# (Native + Wasm32).

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc_linux}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

HAVE_NODE=0
if command -v node >/dev/null 2>&1; then
  HAVE_NODE=1
fi

run_native_and_wasm() {
  pkg_dir="$1"
  expected="$2"
  label="$3"

  out_bin="$TMP_DIR/${label}_native"
  "$PIONC" build -o "$out_bin" "$pkg_dir"
  got="$("$out_bin")"
  if [ "$got" != "$expected" ]; then
    echo "FAIL: $label (native) expected '$expected', got '$got'" >&2
    exit 1
  fi

  if [ "$HAVE_NODE" -eq 1 ]; then
    out_wasm="$TMP_DIR/${label}.wasm"
    "$PIONC" build --target wasm32 -o "$out_wasm" "$pkg_dir"
    wgot="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$out_wasm")"
    if [ "$wgot" != "$expected" ]; then
      echo "FAIL: $label (wasm32) expected '$expected', got '$wgot'" >&2
      exit 1
    fi
  fi
}

# ============================================================================
# 1. Diamond same-source dual-alias (lib_a uses `j1`, lib_b uses `j2` -> same
#    physical `json` package -> `j1::Doc` == `j2::Doc`, Native + Wasm32)
# ============================================================================
mkdir -p "$TMP_DIR/diamond/vendor/json/src" \
         "$TMP_DIR/diamond/lib_a/src" \
         "$TMP_DIR/diamond/lib_b/src" \
         "$TMP_DIR/diamond/app/src"

cat > "$TMP_DIR/diamond/vendor/json/pion.toml" <<'EOF'
[package]
name = "json"
version = "0.1.0"
EOF
cat > "$TMP_DIR/diamond/vendor/json/src/lib.pion" <<'EOF'
pub struct Doc {
  num : Int
}

pub fn make_doc(v : Int) -> Doc {
  Doc::{ num: v }
}

pub fn read_doc(d : Doc) -> Int {
  d.num
}
EOF

cat > "$TMP_DIR/diamond/lib_a/pion.toml" <<'EOF'
[package]
name = "lib_a"
version = "0.1.0"

[dependencies]
j1 = { package = "json", path = "../vendor/json" }
EOF
cat > "$TMP_DIR/diamond/lib_a/src/lib.pion" <<'EOF'
import "j1"

pub fn produce(n : Int) -> j1::Doc {
  j1::make_doc(n + 10)
}
EOF

cat > "$TMP_DIR/diamond/lib_b/pion.toml" <<'EOF'
[package]
name = "lib_b"
version = "0.1.0"

[dependencies]
j2 = { package = "json", path = "../vendor/json" }
EOF
cat > "$TMP_DIR/diamond/lib_b/src/lib.pion" <<'EOF'
import "j2"

pub fn consume(d : j2::Doc) -> Int {
  j2::read_doc(d) * 2
}
EOF

cat > "$TMP_DIR/diamond/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
lib_a = { path = "../lib_a" }
lib_b = { path = "../lib_b" }
EOF
cat > "$TMP_DIR/diamond/app/src/main.pion" <<'EOF'
import "lib_a"
import "lib_b"

pub fn main(world : World) -> Int {
  let d = lib_a::produce(11)
  let r = lib_b::consume(d)
  io_println(world, "diamond=" + r.to_string())
  0
}
EOF

run_native_and_wasm "$TMP_DIR/diamond/app" "diamond=42" "diamond"
echo "1. Diamond same-source dual-alias (j1::Doc == j2::Doc, native+wasm32) -> OK"

# ============================================================================
# 2. Same-name different-source coexistence + type incompatibility guard
#    (local `json` + `ext_json = { package = "json", path = ... }`)
# ============================================================================
mkdir -p "$TMP_DIR/coexist/local_json/src" \
         "$TMP_DIR/coexist/ext_json/src" \
         "$TMP_DIR/coexist/app/src"

cat > "$TMP_DIR/coexist/local_json/pion.toml" <<'EOF'
[package]
name = "json"
version = "0.1.0"
EOF
cat > "$TMP_DIR/coexist/local_json/src/lib.pion" <<'EOF'
pub struct Val {
  x : Int
}

pub fn make_val(n : Int) -> Val {
  Val::{ x: n + 1 }
}

pub fn get_val(v : Val) -> Int {
  v.x
}
EOF

cat > "$TMP_DIR/coexist/ext_json/pion.toml" <<'EOF'
[package]
name = "json"
version = "0.2.0"
EOF
cat > "$TMP_DIR/coexist/ext_json/src/lib.pion" <<'EOF'
pub struct Val {
  x : Int
}

pub fn make_val(n : Int) -> Val {
  Val::{ x: n + 100 }
}

pub fn get_val(v : Val) -> Int {
  v.x
}
EOF

cat > "$TMP_DIR/coexist/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
json = { path = "../local_json" }
ext_json = { package = "json", path = "../ext_json" }
EOF
cat > "$TMP_DIR/coexist/app/src/main.pion" <<'EOF'
import "json"
import "ext_json"

pub fn main(world : World) -> Int {
  let a = json::make_val(5)
  let b = ext_json::make_val(5)
  io_println(world, "coexist=" + json::get_val(a).to_string() + "," + ext_json::get_val(b).to_string())
  0
}
EOF

run_native_and_wasm "$TMP_DIR/coexist/app" "coexist=6,105" "coexist"

# Verify nominal type incompatibility: passing json::Val to ext_json::get_val must fail typecheck!
mkdir -p "$TMP_DIR/coexist_bad/app/src"
cp "$TMP_DIR/coexist/app/pion.toml" "$TMP_DIR/coexist_bad/app/pion.toml"
sed 's|\.\./local_json|../../coexist/local_json|g; s|\.\./ext_json|../../coexist/ext_json|g' \
  "$TMP_DIR/coexist/app/pion.toml" > "$TMP_DIR/coexist_bad/app/pion.toml"
cat > "$TMP_DIR/coexist_bad/app/src/main.pion" <<'EOF'
import "json"
import "ext_json"

pub fn main() -> Int {
  let a = json::make_val(5)
  ext_json::get_val(a)
}
EOF
set +e
BAD_TY_OUT="$("$PIONC" check --json "$TMP_DIR/coexist_bad/app" 2>&1)"
BAD_TY_RC=$?
set -e
if [ "$BAD_TY_RC" -eq 0 ] || ! printf '%s' "$BAD_TY_OUT" | grep -q "E_TYPE_MISMATCH"; then
  echo "FAIL: expected E_TYPE_MISMATCH when passing json::Val to ext_json::get_val, rc=$BAD_TY_RC out=$BAD_TY_OUT" >&2
  exit 1
fi
echo "2. Same-name different-source coexistence (native+wasm32) + nominal type rejection -> OK"

# ============================================================================
# 3. Worktree relocation (CAS sharing across distinct host paths) +
#    Adding/removing an unrelated same-named dep keeps local_json CAS HIT
# ============================================================================
RELOC_CAS="$TMP_DIR/reloc_cas"
mkdir -p "$RELOC_CAS"
cp -R "$TMP_DIR/coexist" "$TMP_DIR/coexist_wt2"

PION_CACHE_DIR="$RELOC_CAS" PION_CAS_TRACE=1 "$PIONC" build -o "$TMP_DIR/wt1_bin" "$TMP_DIR/coexist/app" 2>"$TMP_DIR/wt1.err"
PION_CACHE_DIR="$RELOC_CAS" PION_CAS_TRACE=1 "$PIONC" build -o "$TMP_DIR/wt2_bin" "$TMP_DIR/coexist_wt2/app" 2>"$TMP_DIR/wt2.err"
if grep -q "MISS" "$TMP_DIR/wt2.err"; then
  echo "FAIL: relocated worktree expected 100% CAS HIT, got:" >&2
  cat "$TMP_DIR/wt2.err" >&2
  exit 1
fi

# Remove ext_json from coexist_wt2/app -> local_json MUST still be a CAS HIT!
cat > "$TMP_DIR/coexist_wt2/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
json = { path = "../local_json" }
EOF
cat > "$TMP_DIR/coexist_wt2/app/src/main.pion" <<'EOF'
import "json"

pub fn main(world : World) -> Int {
  io_println(world, "only=" + json::get_val(json::make_val(5)).to_string())
  0
}
EOF
PION_CACHE_DIR="$RELOC_CAS" PION_CAS_TRACE=1 "$PIONC" build -o "$TMP_DIR/wt2_single" "$TMP_DIR/coexist_wt2/app" 2>"$TMP_DIR/wt2_single.err"
if ! grep -q "\[cas\] pkg=json HIT" "$TMP_DIR/wt2_single.err"; then
  echo "FAIL: removing unrelated same-named dep invalidated local_json CAS! stderr:" >&2
  cat "$TMP_DIR/wt2_single.err" >&2
  exit 1
fi
echo "3. Worktree relocation (100% CAS HIT) + unrelated same-name removal stability -> OK"

# ============================================================================
# 4. Git dependency alias, legacy v1 `pion.lock` compatibility, `--locked` & `--offline`
# ============================================================================
GIT_REPO="$TMP_DIR/git_json_repo"
mkdir -p "$GIT_REPO/packages/json/src"
cat > "$GIT_REPO/packages/json/pion.toml" <<'EOF'
[package]
name = "json"
version = "1.0.0"
EOF
cat > "$GIT_REPO/packages/json/src/lib.pion" <<'EOF'
pub fn ver() -> Int { 10 }
EOF
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" config user.email "test@pion.dev"
git -C "$GIT_REPO" config user.name "Pion Test"
git -C "$GIT_REPO" add .
git -C "$GIT_REPO" commit -q -m "v1"
git -C "$GIT_REPO" tag v1
REV_V1="$(git -C "$GIT_REPO" rev-parse HEAD)"

cat > "$GIT_REPO/packages/json/src/lib.pion" <<'EOF'
pub fn ver() -> Int { 20 }
EOF
git -C "$GIT_REPO" add .
git -C "$GIT_REPO" commit -q -m "v2"
git -C "$GIT_REPO" tag v2
REV_V2="$(git -C "$GIT_REPO" rev-parse HEAD)"

mkdir -p "$TMP_DIR/git_app/src"
cat > "$TMP_DIR/git_app/pion.toml" <<EOF
[package]
name = "git_app"
version = "0.1.0"

[dependencies]
j_v1 = { package = "json", git = "file://$GIT_REPO", tag = "v1", subdir = "packages/json" }
j_v2 = { package = "json", git = "file://$GIT_REPO", tag = "v2", subdir = "packages/json" }
EOF
cat > "$TMP_DIR/git_app/src/main.pion" <<'EOF'
import "j_v1"
import "j_v2"

pub fn main(world : World) -> Int {
  io_println(world, "git=" + j_v1::ver().to_string() + "," + j_v2::ver().to_string())
  0
}
EOF

# --locked without pion.lock must fail and must NOT create pion.lock
set +e
LOCK_FAIL_OUT="$("$PIONC" build --locked -o "$TMP_DIR/git_app_bin" "$TMP_DIR/git_app" 2>&1)"
LOCK_FAIL_RC=$?
set -e
if [ "$LOCK_FAIL_RC" -eq 0 ] || [ -f "$TMP_DIR/git_app/pion.lock" ]; then
  echo "FAIL: --locked without pion.lock should fail without writing pion.lock (rc=$LOCK_FAIL_RC out=$LOCK_FAIL_OUT)" >&2
  exit 1
fi

# --offline without cache/lock must fail and must NOT create pion.lock
set +e
OFF_FAIL_OUT="$("$PIONC" build --offline -o "$TMP_DIR/git_app_bin" "$TMP_DIR/git_app" 2>&1)"
OFF_FAIL_RC=$?
set -e
if [ "$OFF_FAIL_RC" -eq 0 ] || [ -f "$TMP_DIR/git_app/pion.lock" ]; then
  echo "FAIL: --offline without pion.lock should fail without writing pion.lock (rc=$OFF_FAIL_RC out=$OFF_FAIL_OUT)" >&2
  exit 1
fi

# Seed a legacy v1 pion.lock (no `package` key, only `name = "json"`) for both refs!
cat > "$TMP_DIR/git_app/pion.lock" <<EOF
# pion.lock: generated by pionc; do not edit by hand.
version = 1

[[package]]
name = "json"
git = "file://$GIT_REPO"
ref = "tag:v1"
rev = "$REV_V1"
subdir = "packages/json"

[[package]]
name = "json"
git = "file://$GIT_REPO"
ref = "tag:v2"
rev = "$REV_V2"
subdir = "packages/json"
EOF
LOCK_BEFORE="$(cat "$TMP_DIR/git_app/pion.lock")"

# Build with --locked: reads legacy v1 pion.lock, builds both v1 & v2 aliased deps!
"$PIONC" build --locked -o "$TMP_DIR/git_app_bin" "$TMP_DIR/git_app"
GIT_OUT="$("$TMP_DIR/git_app_bin")"
if [ "$GIT_OUT" != "git=10,20" ]; then
  echo "FAIL: git dual-version alias expected 'git=10,20', got '$GIT_OUT'" >&2
  exit 1
fi
LOCK_AFTER="$(cat "$TMP_DIR/git_app/pion.lock")"
if [ "$LOCK_BEFORE" != "$LOCK_AFTER" ]; then
  echo "FAIL: --locked modified pion.lock!" >&2
  exit 1
fi

# Now cached: --offline --locked must succeed too!
"$PIONC" check --locked --offline --json "$TMP_DIR/git_app" | grep -q '"ok":true'
echo "4. Git dual-rev alias + legacy v1 pion.lock + --locked/--offline -> OK"

# ============================================================================
# 5. Declared `[package].name` mismatch guard
# ============================================================================
mkdir -p "$TMP_DIR/mismatch/real_pkg/src" "$TMP_DIR/mismatch/app/src"
cat > "$TMP_DIR/mismatch/real_pkg/pion.toml" <<'EOF'
[package]
name = "actual_name"
version = "0.1.0"
EOF
cat > "$TMP_DIR/mismatch/real_pkg/src/lib.pion" <<'EOF'
pub fn f() -> Int { 1 }
EOF
cat > "$TMP_DIR/mismatch/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
my_alias = { package = "wrong_name", path = "../real_pkg" }
EOF
cat > "$TMP_DIR/mismatch/app/src/main.pion" <<'EOF'
import "my_alias"
pub fn main() -> Int { my_alias::f() }
EOF
set +e
MM_OUT="$("$PIONC" check --json "$TMP_DIR/mismatch/app" 2>&1)"
MM_RC=$?
set -e
if [ "$MM_RC" -eq 0 ] || ! printf '%s' "$MM_OUT" | grep -q "actual_name"; then
  echo "FAIL: expected package name mismatch error, rc=$MM_RC out=$MM_OUT" >&2
  exit 1
fi
echo "5. Declared [package].name mismatch guard -> OK"

# ============================================================================
# 6. C export symbol collision explicit compile-time diagnostic (`E_DUPLICATE_C_SYMBOL`)
# ============================================================================
mkdir -p "$TMP_DIR/c_dup/lib1/src" "$TMP_DIR/c_dup/lib2/src" "$TMP_DIR/c_dup/app/src"
cat > "$TMP_DIR/c_dup/lib1/pion.toml" <<'EOF'
[package]
name = "clib"
version = "0.1.0"
EOF
cat > "$TMP_DIR/c_dup/lib1/src/lib.pion" <<'EOF'
pub extern "C" fn exp1() -> Int = "shared_c_export" {
  1
}
EOF
cat > "$TMP_DIR/c_dup/lib2/pion.toml" <<'EOF'
[package]
name = "clib"
version = "0.2.0"
EOF
cat > "$TMP_DIR/c_dup/lib2/src/lib.pion" <<'EOF'
pub extern "C" fn exp2() -> Int = "shared_c_export" {
  2
}
EOF
cat > "$TMP_DIR/c_dup/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
c1 = { package = "clib", path = "../lib1" }
c2 = { package = "clib", path = "../lib2" }
EOF
cat > "$TMP_DIR/c_dup/app/src/main.pion" <<'EOF'
import "c1"
import "c2"

pub fn main() -> Int {
  c1::exp1() + c2::exp2()
}
EOF
set +e
CDUP_OUT="$("$PIONC" check --json "$TMP_DIR/c_dup/app" 2>&1)"
CDUP_RC=$?
set -e
if [ "$CDUP_RC" -eq 0 ] || ! printf '%s' "$CDUP_OUT" | grep -q "E_DUPLICATE_C_SYMBOL"; then
  echo "FAIL: expected E_DUPLICATE_C_SYMBOL diagnostic, rc=$CDUP_RC out=$CDUP_OUT" >&2
  exit 1
fi
echo "6. C export symbol collision (E_DUPLICATE_C_SYMBOL) -> OK"

# ============================================================================
# 7. Workspace `[workspace.dependencies]` alias inheritance
# ============================================================================
mkdir -p "$TMP_DIR/ws_alias/vendor/json/src" "$TMP_DIR/ws_alias/app/src"
cat > "$TMP_DIR/ws_alias/pion.toml" <<'EOF'
[workspace]
members = ["app"]

[workspace.dependencies]
ws_json = { package = "json", path = "vendor/json" }
EOF
cat > "$TMP_DIR/ws_alias/vendor/json/pion.toml" <<'EOF'
[package]
name = "json"
version = "0.1.0"
EOF
cat > "$TMP_DIR/ws_alias/vendor/json/src/lib.pion" <<'EOF'
pub fn answer() -> Int { 77 }
EOF
cat > "$TMP_DIR/ws_alias/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
ws_json = { workspace = true }
EOF
cat > "$TMP_DIR/ws_alias/app/src/main.pion" <<'EOF'
import "ws_json"

pub fn main(world : World) -> Int {
  io_println(world, "ws_alias=" + ws_json::answer().to_string())
  0
}
EOF
run_native_and_wasm "$TMP_DIR/ws_alias/app" "ws_alias=77" "ws_alias"
echo "7. Workspace [workspace.dependencies] alias inheritance (native+wasm32) -> OK"

# ============================================================================
# 8. Upstream alias swap CAS invalidation (check + native + wasm32)
#    `mid` exports `pub fn f() -> j::Doc`; swapping `j`/`k` in `mid/pion.toml`
#    keeps `mid`'s raw `.pionsig` text identical, so downstream `app` MUST
#    invalidate via transitive effective sig hash on both hot and cold CAS.
# ============================================================================
SWAP_CAS="$TMP_DIR/swap_cas"
mkdir -p "$SWAP_CAS" \
         "$TMP_DIR/swap/json_a/src" \
         "$TMP_DIR/swap/json_b/src" \
         "$TMP_DIR/swap/mid/src" \
         "$TMP_DIR/swap/app_ty/src" \
         "$TMP_DIR/swap/app_val/src"

cat > "$TMP_DIR/swap/json_a/pion.toml" <<'EOF'
[package]
name = "json"
version = "0.1.0"
EOF
cat > "$TMP_DIR/swap/json_a/src/lib.pion" <<'EOF'
pub struct Doc {
  n : Int
}

pub fn make() -> Doc {
  Doc::{ n: 10 }
}

pub fn read(d : Doc) -> Int {
  d.n
}
EOF

cat > "$TMP_DIR/swap/json_b/pion.toml" <<'EOF'
[package]
name = "json"
version = "0.2.0"
EOF
cat > "$TMP_DIR/swap/json_b/src/lib.pion" <<'EOF'
pub struct Doc {
  n : Int
}

pub fn make() -> Doc {
  Doc::{ n: 20 }
}

pub fn read(d : Doc) -> Int {
  d.n
}
EOF

cat > "$TMP_DIR/swap/mid/pion.toml" <<'EOF'
[package]
name = "mid"
version = "0.1.0"

[dependencies]
j = { package = "json", path = "../json_a" }
k = { package = "json", path = "../json_b" }
EOF
cat > "$TMP_DIR/swap/mid/src/lib.pion" <<'EOF'
import "j"
import "k"

pub fn f() -> j::Doc {
  j::make()
}

pub fn get() -> Int {
  j::read(j::make()) + k::read(k::make()) * 10
}
EOF

cat > "$TMP_DIR/swap/app_ty/pion.toml" <<'EOF'
[package]
name = "app_ty"
version = "0.1.0"

[dependencies]
mid = { path = "../mid" }
ja = { package = "json", path = "../json_a" }
jb = { package = "json", path = "../json_b" }
EOF
cat > "$TMP_DIR/swap/app_ty/src/main.pion" <<'EOF'
import "mid"
import "ja"
import "jb"

pub fn main(world : World) -> Int {
  let d = mid::f()
  let _ = jb::make()
  io_println(world, "swap_ty=" + ja::read(d).to_string())
  0
}
EOF

cat > "$TMP_DIR/swap/app_val/pion.toml" <<'EOF'
[package]
name = "app_val"
version = "0.1.0"

[dependencies]
mid = { path = "../mid" }
EOF
cat > "$TMP_DIR/swap/app_val/src/main.pion" <<'EOF'
import "mid"

pub fn main(world : World) -> Int {
  io_println(world, "swap_val=" + mid::get().to_string())
  0
}
EOF

# Warm CAS before swap (check + native + wasm32)
PION_CACHE_DIR="$SWAP_CAS" "$PIONC" check --json "$TMP_DIR/swap/app_ty" | grep -q '"ok":true'
PION_CACHE_DIR="$SWAP_CAS" run_native_and_wasm "$TMP_DIR/swap/app_val" "swap_val=210" "swap_before"

# Swap j <-> k in mid/pion.toml
cat > "$TMP_DIR/swap/mid/pion.toml" <<'EOF'
[package]
name = "mid"
version = "0.1.0"

[dependencies]
j = { package = "json", path = "../json_b" }
k = { package = "json", path = "../json_a" }
EOF

# Hot CAS check on app_ty MUST now fail with E_TYPE_MISMATCH (matching cold CAS)
set +e
SWAP_HOT_OUT="$(PION_CACHE_DIR="$SWAP_CAS" "$PIONC" check --json "$TMP_DIR/swap/app_ty" 2>&1)"
SWAP_HOT_RC=$?
SWAP_COLD_OUT="$(PION_CACHE_DIR="$TMP_DIR/swap_cold_cas" "$PIONC" check --json "$TMP_DIR/swap/app_ty" 2>&1)"
SWAP_COLD_RC=$?
set -e
if [ "$SWAP_HOT_RC" -eq 0 ] || ! printf '%s' "$SWAP_HOT_OUT" | grep -q "E_TYPE_MISMATCH"; then
  echo "FAIL: hot CAS missed upstream alias swap type mismatch! rc=$SWAP_HOT_RC out=$SWAP_HOT_OUT" >&2
  exit 1
fi
if [ "$SWAP_COLD_RC" -eq 0 ] || ! printf '%s' "$SWAP_COLD_OUT" | grep -q "E_TYPE_MISMATCH"; then
  echo "FAIL: cold CAS expected E_TYPE_MISMATCH after alias swap! rc=$SWAP_COLD_RC out=$SWAP_COLD_OUT" >&2
  exit 1
fi

# Hot CAS build (native + wasm32) on app_val MUST reflect swapped value (20 + 10*10 = 120)
PION_CACHE_DIR="$SWAP_CAS" run_native_and_wasm "$TMP_DIR/swap/app_val" "swap_val=120" "swap_after"
echo "8. Upstream alias swap CAS invalidation (check + native + wasm32) -> OK"

# ============================================================================
# 9. Cold/hot `E_DUPLICATE_C_SYMBOL` consistency when dep changes extern decl -> def
# ============================================================================
CDUP_HOT_CAS="$TMP_DIR/cdup_hot_cas"
mkdir -p "$CDUP_HOT_CAS" "$TMP_DIR/c_hot/lib1/src" "$TMP_DIR/c_hot/lib2/src" "$TMP_DIR/c_hot/app/src"
cat > "$TMP_DIR/c_hot/lib1/pion.toml" <<'EOF'
[package]
name = "clib"
version = "0.1.0"
EOF
cat > "$TMP_DIR/c_hot/lib1/src/lib.pion" <<'EOF'
pub extern "C" fn exp1() -> Int = "hot_shared_c_sym" {
  1
}
EOF
cat > "$TMP_DIR/c_hot/lib2/pion.toml" <<'EOF'
[package]
name = "clib"
version = "0.2.0"
EOF
cat > "$TMP_DIR/c_hot/lib2/src/lib.pion" <<'EOF'
pub extern "C" fn exp2() -> Int = "hot_shared_c_sym"
EOF
cat > "$TMP_DIR/c_hot/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
c1 = { package = "clib", path = "../lib1" }
c2 = { package = "clib", path = "../lib2" }
EOF
cat > "$TMP_DIR/c_hot/app/src/main.pion" <<'EOF'
import "c1"
import "c2"

pub fn main() -> Int {
  c1::exp1() + c2::exp2()
}
EOF

# Warm CAS when lib2 is only a declaration (no body) -> check passes
PION_CACHE_DIR="$CDUP_HOT_CAS" "$PIONC" check --json "$TMP_DIR/c_hot/app" | grep -q '"ok":true'

# Now turn lib2's declaration into a definition -> BOTH hot CAS and cold CAS must fail with E_DUPLICATE_C_SYMBOL
cat > "$TMP_DIR/c_hot/lib2/src/lib.pion" <<'EOF'
pub extern "C" fn exp2() -> Int = "hot_shared_c_sym" {
  2
}
EOF
set +e
CHOT_OUT="$(PION_CACHE_DIR="$CDUP_HOT_CAS" "$PIONC" check --json "$TMP_DIR/c_hot/app" 2>&1)"
CHOT_RC=$?
CCOLD_OUT="$(PION_CACHE_DIR="$TMP_DIR/cdup_cold_cas" "$PIONC" check --json "$TMP_DIR/c_hot/app" 2>&1)"
CCOLD_RC=$?
set -e
if [ "$CHOT_RC" -eq 0 ] || ! printf '%s' "$CHOT_OUT" | grep -q "E_DUPLICATE_C_SYMBOL"; then
  echo "FAIL: hot CAS missed E_DUPLICATE_C_SYMBOL after decl->def! rc=$CHOT_RC out=$CHOT_OUT" >&2
  exit 1
fi
if [ "$CCOLD_RC" -eq 0 ] || ! printf '%s' "$CCOLD_OUT" | grep -q "E_DUPLICATE_C_SYMBOL"; then
  echo "FAIL: cold CAS missed E_DUPLICATE_C_SYMBOL after decl->def! rc=$CCOLD_RC out=$CCOLD_OUT" >&2
  exit 1
fi
echo "9. Cold/hot E_DUPLICATE_C_SYMBOL consistency (extern decl -> def) -> OK"

# ============================================================================
# 10. Workspace DFS dedup:
#     (a) Two distinct Git URLs with identical commit/subdir stay independent
#         in BOTH manifest orders (nominal type incompatibility preserved);
#     (b) Same local dir imported via real path AND symlink dedupes to ONE canon_id.
# ============================================================================
GIT_URL1="$TMP_DIR/git_same_rev_1"
GIT_URL2="$TMP_DIR/git_same_rev_2"
mkdir -p "$GIT_URL1/pkg/src"
cat > "$GIT_URL1/pkg/pion.toml" <<'EOF'
[package]
name = "boxpkg"
version = "0.1.0"
EOF
cat > "$GIT_URL1/pkg/src/lib.pion" <<'EOF'
pub struct Box {
  x : Int
}

pub fn wrap(n : Int) -> Box {
  Box::{ x: n }
}

pub fn unwrap(b : Box) -> Int {
  b.x
}
EOF
git -C "$GIT_URL1" init -q
git -C "$GIT_URL1" config user.email "test@pion.dev"
git -C "$GIT_URL1" config user.name "Pion Test"
git -C "$GIT_URL1" add .
git -C "$GIT_URL1" commit -q -m "init"
git -C "$GIT_URL1" tag v1
cp -R "$GIT_URL1" "$GIT_URL2"

for order in ab ba; do
  mkdir -p "$TMP_DIR/dfs_git_$order/src"
  if [ "$order" = "ab" ]; then
    cat > "$TMP_DIR/dfs_git_$order/pion.toml" <<EOF
[package]
name = "app"
version = "0.1.0"

[dependencies]
g1 = { package = "boxpkg", git = "file://$GIT_URL1", tag = "v1", subdir = "pkg" }
g2 = { package = "boxpkg", git = "file://$GIT_URL2", tag = "v1", subdir = "pkg" }
EOF
  else
    cat > "$TMP_DIR/dfs_git_$order/pion.toml" <<EOF
[package]
name = "app"
version = "0.1.0"

[dependencies]
g2 = { package = "boxpkg", git = "file://$GIT_URL2", tag = "v1", subdir = "pkg" }
g1 = { package = "boxpkg", git = "file://$GIT_URL1", tag = "v1", subdir = "pkg" }
EOF
  fi
  cat > "$TMP_DIR/dfs_git_$order/src/main.pion" <<'EOF'
import "g1"
import "g2"

pub fn main() -> Int {
  let b = g1::wrap(7)
  g2::unwrap(b)
}
EOF
  set +e
  GDIFF_OUT="$("$PIONC" check --json "$TMP_DIR/dfs_git_$order" 2>&1)"
  GDIFF_RC=$?
  set -e
  if [ "$GDIFF_RC" -eq 0 ] || ! printf '%s' "$GDIFF_OUT" | grep -q "E_TYPE_MISMATCH"; then
    echo "FAIL: distinct git URLs (order=$order) were merged! rc=$GDIFF_RC out=$GDIFF_OUT" >&2
    exit 1
  fi
done

# (b) Symlink dedup: real path + symlink path -> single canon_id, compatible types!
mkdir -p "$TMP_DIR/sym_dedup/real_pkg/src" "$TMP_DIR/sym_dedup/app/src"
ln -s "$TMP_DIR/sym_dedup/real_pkg" "$TMP_DIR/sym_dedup/link_pkg"
cat > "$TMP_DIR/sym_dedup/real_pkg/pion.toml" <<'EOF'
[package]
name = "json"
version = "0.1.0"
EOF
cat > "$TMP_DIR/sym_dedup/real_pkg/src/lib.pion" <<'EOF'
pub struct Doc {
  v : Int
}

pub fn make(n : Int) -> Doc {
  Doc::{ v: n }
}

pub fn read(d : Doc) -> Int {
  d.v
}
EOF
cat > "$TMP_DIR/sym_dedup/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
j_real = { package = "json", path = "../real_pkg" }
j_link = { package = "json", path = "../link_pkg" }
EOF
cat > "$TMP_DIR/sym_dedup/app/src/main.pion" <<'EOF'
import "j_real"
import "j_link"

pub fn main(world : World) -> Int {
  let d = j_real::make(88)
  io_println(world, "sym=" + j_link::read(d).to_string())
  0
}
EOF
run_native_and_wasm "$TMP_DIR/sym_dedup/app" "sym=88" "sym_dedup"
echo "10. DFS dedup (distinct git URLs stay separate; symlink path dedupes) -> OK"

# ============================================================================
# 11. `pionc update <alias>` (git + registry), `pionc remove <alias>` fallback,
#     and legacy `pion.lock` normalized subdir equivalence under `--locked`
# ============================================================================
# 11a: Two git branches of same `json` package -> `pionc update j_b1` updates ONLY j_b1
GIT_UPD="$TMP_DIR/git_upd_repo"
mkdir -p "$GIT_UPD/packages/json/src"
cat > "$GIT_UPD/packages/json/pion.toml" <<'EOF'
[package]
name = "json"
version = "1.0.0"
EOF
cat > "$GIT_UPD/packages/json/src/lib.pion" <<'EOF'
pub fn v() -> Int { 1 }
EOF
git -C "$GIT_UPD" init -q
git -C "$GIT_UPD" config user.email "test@pion.dev"
git -C "$GIT_UPD" config user.name "Pion Test"
git -C "$GIT_UPD" add .
git -C "$GIT_UPD" commit -q -m "base"
git -C "$GIT_UPD" checkout -q -b b1
cat > "$GIT_UPD/packages/json/src/lib.pion" <<'EOF'
pub fn v() -> Int { 11 }
EOF
git -C "$GIT_UPD" add .
git -C "$GIT_UPD" commit -q -m "b1-v1"
B1_OLD="$(git -C "$GIT_UPD" rev-parse HEAD)"

git -C "$GIT_UPD" checkout -q -b b2 HEAD~1
cat > "$GIT_UPD/packages/json/src/lib.pion" <<'EOF'
pub fn v() -> Int { 21 }
EOF
git -C "$GIT_UPD" add .
git -C "$GIT_UPD" commit -q -m "b2-v1"
B2_OLD="$(git -C "$GIT_UPD" rev-parse HEAD)"

mkdir -p "$TMP_DIR/upd_app/src"
cat > "$TMP_DIR/upd_app/pion.toml" <<EOF
[package]
name = "upd_app"
version = "0.1.0"

[dependencies]
j_b1 = { package = "json", git = "file://$GIT_UPD", branch = "b1", subdir = "packages/json" }
j_b2 = { package = "json", git = "file://$GIT_UPD", branch = "b2", subdir = "packages/json" }
EOF
cat > "$TMP_DIR/upd_app/src/main.pion" <<'EOF'
import "j_b1"
import "j_b2"

pub fn main() -> Int { j_b1::v() + j_b2::v() }
EOF
"$PIONC" fetch "$TMP_DIR/upd_app" >/dev/null

# Advance BOTH branches upstream
git -C "$GIT_UPD" checkout -q b1
cat > "$GIT_UPD/packages/json/src/lib.pion" <<'EOF'
pub fn v() -> Int { 12 }
EOF
git -C "$GIT_UPD" add .
git -C "$GIT_UPD" commit -q -m "b1-v2"
B1_NEW="$(git -C "$GIT_UPD" rev-parse HEAD)"

git -C "$GIT_UPD" checkout -q b2
cat > "$GIT_UPD/packages/json/src/lib.pion" <<'EOF'
pub fn v() -> Int { 22 }
EOF
git -C "$GIT_UPD" add .
git -C "$GIT_UPD" commit -q -m "b2-v2"
B2_NEW="$(git -C "$GIT_UPD" rev-parse HEAD)"

# Update ONLY j_b1 -> B1_NEW must appear, B2_OLD must remain (B2_NEW must NOT appear)!
"$PIONC" update --json j_b1 "$TMP_DIR/upd_app" | grep -q '"ok":true'
if ! grep -q "$B1_NEW" "$TMP_DIR/upd_app/pion.lock" || ! grep -q "$B2_OLD" "$TMP_DIR/upd_app/pion.lock" || grep -q "$B2_NEW" "$TMP_DIR/upd_app/pion.lock"; then
  echo "FAIL: pionc update j_b1 did not selectively update j_b1! lock:" >&2
  cat "$TMP_DIR/upd_app/pion.lock" >&2
  exit 1
fi

# 11d: Legacy unnormalized subdir = "./packages/json/" in pion.lock passes --locked unchanged
sed 's|subdir = "packages/json"|subdir = "./packages/json/"|g' \
  "$TMP_DIR/upd_app/pion.lock" > "$TMP_DIR/upd_app/pion.lock.legacy"
mv "$TMP_DIR/upd_app/pion.lock.legacy" "$TMP_DIR/upd_app/pion.lock"
LEGACY_BEFORE="$(cat "$TMP_DIR/upd_app/pion.lock")"
"$PIONC" check --locked --json "$TMP_DIR/upd_app" | grep -q '"ok":true'
LEGACY_AFTER="$(cat "$TMP_DIR/upd_app/pion.lock")"
if [ "$LEGACY_BEFORE" != "$LEGACY_AFTER" ]; then
  echo "FAIL: --locked rewrote legacy normalized pion.lock!" >&2
  exit 1
fi

# 11c: Healthy `pionc remove j_b2` precisely prunes j_b2's lock entry and keeps j_b1's.
cat > "$TMP_DIR/upd_app/src/main.pion" <<'EOF'
import "j_b1"
pub fn main() -> Int { j_b1::v() }
EOF
"$PIONC" remove --json j_b2 "$TMP_DIR/upd_app" | grep -q '"ok":true'
if ! grep -q "$B1_NEW" "$TMP_DIR/upd_app/pion.lock" || grep -q "$B2_OLD" "$TMP_DIR/upd_app/pion.lock"; then
  echo "FAIL: healthy pionc remove j_b2 did not selectively remove j_b2! lock:" >&2
  cat "$TMP_DIR/upd_app/pion.lock" >&2
  exit 1
fi

# 11b: Registry alias update (`my_reg = { package = "json", registry = ..., version = "0.1.0" }`)
REG_IDX="$TMP_DIR/reg_idx"
mkdir -p "$REG_IDX/index"
git -C "$GIT_UPD" checkout -q b1
git -C "$GIT_UPD" tag v0.1.0 "$B1_OLD"
git -C "$GIT_UPD" tag v0.2.0 "$B1_NEW"
cat > "$REG_IDX/index/json.toml" <<EOF
name = "json"
version = "0.2.0"
git = "file://$GIT_UPD"
tag = "v0.2.0"
subdir = "packages/json"
EOF
git -C "$REG_IDX" init -q
git -C "$REG_IDX" config user.email "test@pion.dev"
git -C "$REG_IDX" config user.name "Pion Test"
git -C "$REG_IDX" add .
git -C "$REG_IDX" commit -q -m "index"

mkdir -p "$TMP_DIR/reg_app/src"
cat > "$TMP_DIR/reg_app/pion.toml" <<EOF
[package]
name = "reg_app"
version = "0.1.0"

[dependencies]
my_reg = { package = "json", git = "file://$GIT_UPD", tag = "v0.1.0", subdir = "packages/json", version = "0.1.0", registry = "file://$REG_IDX" }
EOF
cat > "$TMP_DIR/reg_app/src/main.pion" <<'EOF'
import "my_reg"
pub fn main() -> Int { my_reg::v() }
EOF
"$PIONC" fetch "$TMP_DIR/reg_app" >/dev/null
REG_UPD_OUT="$("$PIONC" update --json my_reg "$TMP_DIR/reg_app" 2>&1)"
if ! printf '%s' "$REG_UPD_OUT" | grep -q '"ok":true'; then
  echo "FAIL: pionc update my_reg failed! out=$REG_UPD_OUT" >&2
  exit 1
fi
if ! grep -q 'my_reg = { package = "json",' "$TMP_DIR/reg_app/pion.toml" || ! grep -q 'version = "0.2.0"' "$TMP_DIR/reg_app/pion.toml"; then
  echo "FAIL: pionc update my_reg did not preserve alias & bump version! pion.toml:" >&2
  cat "$TMP_DIR/reg_app/pion.toml" >&2
  exit 1
fi
if ! grep -q "$B1_NEW" "$TMP_DIR/reg_app/pion.lock"; then
  echo "FAIL: pionc update my_reg did not update pion.lock to v0.2.0 rev! lock:" >&2
  cat "$TMP_DIR/reg_app/pion.lock" >&2
  exit 1
fi
echo "11. pionc update/remove aliases (git + registry) & legacy lockfile --locked -> OK"

# ============================================================================
# 12. `--locked` & `--offline` honored in `check --fix` and `query`
# ============================================================================
mkdir -p "$TMP_DIR/lock_cli_app/src"
cat > "$TMP_DIR/lock_cli_app/pion.toml" <<EOF
[package]
name = "lock_cli_app"
version = "0.1.0"

[dependencies]
j = { package = "json", git = "file://$GIT_REPO", tag = "v1", subdir = "packages/json" }
EOF
cat > "$TMP_DIR/lock_cli_app/src/main.pion" <<'EOF'
import "j"
pub fn main() -> Int { j::ver() }
EOF

COLD_CLI_CAS="$TMP_DIR/cold_cli_cas"
mkdir -p "$COLD_CLI_CAS"
for cmd_label in "check_fix_locked" "query_deps_locked" "check_fix_offline" "query_deps_offline"; do
  set +e
  case "$cmd_label" in
    check_fix_locked)
      OUT="$(PION_CACHE_DIR="$COLD_CLI_CAS" "$PIONC" check --fix --locked --json "$TMP_DIR/lock_cli_app" 2>&1)"
      ;;
    query_deps_locked)
      OUT="$(PION_CACHE_DIR="$COLD_CLI_CAS" "$PIONC" query deps --locked --json "$TMP_DIR/lock_cli_app" 2>&1)"
      ;;
    check_fix_offline)
      OUT="$(PION_CACHE_DIR="$COLD_CLI_CAS" "$PIONC" check --fix --offline --json "$TMP_DIR/lock_cli_app" 2>&1)"
      ;;
    query_deps_offline)
      OUT="$(PION_CACHE_DIR="$COLD_CLI_CAS" "$PIONC" query deps --offline --json "$TMP_DIR/lock_cli_app" 2>&1)"
      ;;
  esac
  RC=$?
  set -e
  if [ "$RC" -eq 0 ] || [ -f "$TMP_DIR/lock_cli_app/pion.lock" ]; then
    echo "FAIL: $cmd_label must fail without creating pion.lock! rc=$RC out=$OUT" >&2
    exit 1
  fi
done
echo "12. --locked / --offline honored in check --fix and query -> OK"

# ============================================================================
# 13. `extract-lean --pkg` resolution & clean Lean module names
# ============================================================================
LEAN_OUT="$TMP_DIR/lean_out"
"$PIONC" extract-lean --out "$LEAN_OUT" --pkg app --json "$TMP_DIR/coexist/app" | grep -q '"ok":true'
set +e
AMB_LEAN_OUT="$("$PIONC" extract-lean --out "$LEAN_OUT" --pkg json --json "$TMP_DIR/coexist/app" 2>&1)"
AMB_LEAN_RC=$?
set -e
if [ "$AMB_LEAN_RC" -eq 0 ] || ! printf '%s' "$AMB_LEAN_OUT" | grep -q "ambiguous" || ! printf '%s' "$AMB_LEAN_OUT" | grep -q "json__"; then
  echo "FAIL: extract-lean --pkg json expected ambiguity error listing canon_ids! rc=$AMB_LEAN_RC out=$AMB_LEAN_OUT" >&2
  exit 1
fi
# Unique declared_name dep (`tests/lean/algos` -> `vlib`) keeps clean `Vlib` Lean module name!
LEAN_ALGOS_OUT="$TMP_DIR/lean_algos_out"
ALGOS_JSON="$("$PIONC" extract-lean --json --out "$LEAN_ALGOS_OUT" "$ROOT_DIR/tests/lean/algos")"
if ! printf '%s' "$ALGOS_JSON" | grep -q '"name":"vlib","lean_mod":"Vlib"' || [ ! -f "$LEAN_ALGOS_OUT/Vlib/Types.lean" ] || [ ! -f "$LEAN_ALGOS_OUT/Vlib/Funs.lean" ]; then
  echo "FAIL: extract-lean on tests/lean/algos must emit clean Vlib module! json=$ALGOS_JSON" >&2
  exit 1
fi
# Dual same-declared-name deps (with [verify] enabled = true) still emit distinct hashed modules!
mkdir -p "$TMP_DIR/lean_dup/j1/src" "$TMP_DIR/lean_dup/j2/src" "$TMP_DIR/lean_dup/app/src"
cat > "$TMP_DIR/lean_dup/j1/pion.toml" <<'EOF'
[package]
name = "json"
version = "0.1.0"

[verify]
enabled = true
EOF
cat > "$TMP_DIR/lean_dup/j1/src/lib.pion" <<'EOF'
pub fn f(x : Int) -> Int { x + 1 }
EOF
cat > "$TMP_DIR/lean_dup/j2/pion.toml" <<'EOF'
[package]
name = "json"
version = "0.2.0"

[verify]
enabled = true
EOF
cat > "$TMP_DIR/lean_dup/j2/src/lib.pion" <<'EOF'
pub fn f(x : Int) -> Int { x + 2 }
EOF
cat > "$TMP_DIR/lean_dup/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[verify]
enabled = true

[dependencies]
ja = { package = "json", path = "../j1" }
jb = { package = "json", path = "../j2" }
EOF
cat > "$TMP_DIR/lean_dup/app/src/lib.pion" <<'EOF'
import "ja"
import "jb"

pub fn both(x : Int) -> Int {
  ja::f(x) + jb::f(x)
}
EOF
LEAN_COEXIST_OUT="$TMP_DIR/lean_coexist_out"
COEXIST_JSON="$("$PIONC" extract-lean --json --out "$LEAN_COEXIST_OUT" "$TMP_DIR/lean_dup/app")"
JSON_MOD_CNT="$(printf '%s' "$COEXIST_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); mods=[p["lean_mod"] for p in d["packages"] if p["name"].startswith("json__")]; print(len(set(mods)))')"
if [ "$JSON_MOD_CNT" != "2" ]; then
  echo "FAIL: extract-lean with two same-name deps expected 2 distinct json__ modules, got $JSON_MOD_CNT json=$COEXIST_JSON" >&2
  exit 1
fi
# Colliding Lean module names (`my_pkg` vs `my__pkg` both fold to `MyPkg`) must also disambiguate!
mkdir -p "$TMP_DIR/lean_mod_col/p1/src" "$TMP_DIR/lean_mod_col/p2/src" "$TMP_DIR/lean_mod_col/app/src"
cat > "$TMP_DIR/lean_mod_col/p1/pion.toml" <<'EOF'
[package]
name = "my_pkg"
version = "0.1.0"

[verify]
enabled = true
EOF
cat > "$TMP_DIR/lean_mod_col/p1/src/lib.pion" <<'EOF'
pub fn f1(x : Int) -> Int { x + 1 }
EOF
cat > "$TMP_DIR/lean_mod_col/p2/pion.toml" <<'EOF'
[package]
name = "my__pkg"
version = "0.1.0"

[verify]
enabled = true
EOF
cat > "$TMP_DIR/lean_mod_col/p2/src/lib.pion" <<'EOF'
pub fn f2(x : Int) -> Int { x + 2 }
EOF
cat > "$TMP_DIR/lean_mod_col/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[verify]
enabled = true

[dependencies]
my_pkg = { path = "../p1" }
my__pkg = { path = "../p2" }
EOF
cat > "$TMP_DIR/lean_mod_col/app/src/lib.pion" <<'EOF'
import "my_pkg"
import "my__pkg"

pub fn sum(x : Int) -> Int {
  my_pkg::f1(x) + my__pkg::f2(x)
}
EOF
LEAN_COL_OUT="$TMP_DIR/lean_col_out"
COL_JSON="$("$PIONC" extract-lean --json --out "$LEAN_COL_OUT" "$TMP_DIR/lean_mod_col/app")"
COL_CHECK="$(printf '%s' "$COL_JSON" | python3 -c 'import json,sys,os; d=json.load(sys.stdin); out=d["out"]; deps=[p for p in d["packages"] if p["name"]!="app"]; mods=[p["lean_mod"] for p in deps]; app_funs=open(os.path.join(out,"App","Funs.lean")).read(); ok=(len(deps)==2 and len(set(mods))==2 and all(os.path.isfile(os.path.join(out,m,"Funs.lean")) for m in mods) and all(("import " + m + ".Funs") in app_funs for m in mods)); print("OK" if ok else "BAD")')"
if [ "$COL_CHECK" != "OK" ]; then
  echo "FAIL: extract-lean my_pkg vs my__pkg collided! json=$COL_JSON" >&2
  exit 1
fi
# 3-package collision: my_pkg + my__pkg + a third package whose declared_name matches my_pkg's canon_id hash!
MY_PKG_HASH="$(printf '%s' "$COL_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); p=[p["name"] for p in d["packages"] if p["name"].startswith("my_pkg__")][0]; print(p.split("__",1)[1])')"
mkdir -p "$TMP_DIR/lean_mod_col3/p1/src" "$TMP_DIR/lean_mod_col3/p2/src" "$TMP_DIR/lean_mod_col3/p3/src" "$TMP_DIR/lean_mod_col3/app/src"
cp "$TMP_DIR/lean_mod_col/p1/pion.toml" "$TMP_DIR/lean_mod_col3/p1/pion.toml"
cp "$TMP_DIR/lean_mod_col/p1/src/lib.pion" "$TMP_DIR/lean_mod_col3/p1/src/lib.pion"
cp "$TMP_DIR/lean_mod_col/p2/pion.toml" "$TMP_DIR/lean_mod_col3/p2/pion.toml"
cp "$TMP_DIR/lean_mod_col/p2/src/lib.pion" "$TMP_DIR/lean_mod_col3/p2/src/lib.pion"
cat > "$TMP_DIR/lean_mod_col3/p3/pion.toml" <<EOF
[package]
name = "my__pkg__$MY_PKG_HASH"
version = "0.1.0"

[verify]
enabled = true
EOF
cat > "$TMP_DIR/lean_mod_col3/p3/src/lib.pion" <<'EOF'
pub fn f3(x : Int) -> Int { x + 3 }
EOF
cat > "$TMP_DIR/lean_mod_col3/app/pion.toml" <<EOF
[package]
name = "app"
version = "0.1.0"

[verify]
enabled = true

[dependencies]
my_pkg = { path = "../p1" }
my__pkg = { path = "../p2" }
p3_alias = { package = "my__pkg__$MY_PKG_HASH", path = "../p3" }
EOF
cat > "$TMP_DIR/lean_mod_col3/app/src/lib.pion" <<'EOF'
import "my_pkg"
import "my__pkg"
import "p3_alias"

pub fn sum3(x : Int) -> Int {
  my_pkg::f1(x) + my__pkg::f2(x) + p3_alias::f3(x)
}
EOF
LEAN_COL3_OUT="$TMP_DIR/lean_col3_out"
COL3_JSON="$("$PIONC" extract-lean --json --out "$LEAN_COL3_OUT" "$TMP_DIR/lean_mod_col3/app")"
COL3_CHECK="$(printf '%s' "$COL3_JSON" | python3 -c 'import json,sys,os; d=json.load(sys.stdin); out=d["out"]; deps=[p for p in d["packages"] if p["name"]!="app"]; mods=[p["lean_mod"] for p in deps]; app_funs=open(os.path.join(out,"App","Funs.lean")).read(); ok=(len(deps)==3 and len(set(mods))==3 and all(os.path.isfile(os.path.join(out,m,"Funs.lean")) for m in mods) and all(("import " + m + ".Funs") in app_funs for m in mods)); print("OK" if ok else "BAD")')"
if [ "$COL3_CHECK" != "OK" ]; then
  echo "FAIL: extract-lean 3-way collision (my_pkg, my__pkg, my__pkg__$MY_PKG_HASH) collided! json=$COL3_JSON" >&2
  exit 1
fi
# Case-insensitive Lean module collision: `my_pkg` (MyPkg) vs `mypkg` (Mypkg) must get distinct lowercased mods!
mkdir -p "$TMP_DIR/lean_case_col/p1/src" "$TMP_DIR/lean_case_col/p2/src" "$TMP_DIR/lean_case_col/app/src"
cat > "$TMP_DIR/lean_case_col/p1/pion.toml" <<'EOF'
[package]
name = "my_pkg"
version = "0.1.0"

[verify]
enabled = true
EOF
cat > "$TMP_DIR/lean_case_col/p1/src/lib.pion" <<'EOF'
pub fn f1(x : Int) -> Int { x + 1 }
EOF
cat > "$TMP_DIR/lean_case_col/p2/pion.toml" <<'EOF'
[package]
name = "mypkg"
version = "0.1.0"

[verify]
enabled = true
EOF
cat > "$TMP_DIR/lean_case_col/p2/src/lib.pion" <<'EOF'
pub fn f2(x : Int) -> Int { x + 2 }
EOF
cat > "$TMP_DIR/lean_case_col/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[verify]
enabled = true

[dependencies]
my_pkg = { path = "../p1" }
mypkg = { path = "../p2" }
EOF
cat > "$TMP_DIR/lean_case_col/app/src/lib.pion" <<'EOF'
import "my_pkg"
import "mypkg"

pub fn sum_case(x : Int) -> Int {
  my_pkg::f1(x) + mypkg::f2(x)
}
EOF
LEAN_CASE_OUT="$TMP_DIR/lean_case_out"
CASE_JSON="$("$PIONC" extract-lean --json --out "$LEAN_CASE_OUT" "$TMP_DIR/lean_case_col/app")"
CASE_CHECK="$(printf '%s' "$CASE_JSON" | python3 -c 'import json,sys,os; d=json.load(sys.stdin); out=d["out"]; deps=[p for p in d["packages"] if p["name"]!="app"]; mods=[p["lean_mod"] for p in deps]; lmods=[m.lower() for m in mods]; app_funs=open(os.path.join(out,"App","Funs.lean")).read(); bodies=[open(os.path.join(out,m,"Funs.lean")).read() for m in mods]; ok=(len(deps)==2 and len(set(lmods))==2 and any("f1" in b for b in bodies) and any("f2" in b for b in bodies) and all(("import " + m + ".Funs") in app_funs for m in mods)); print("OK" if ok else f"BAD mods={mods}")')"
if [ "$CASE_CHECK" != "OK" ]; then
  echo "FAIL: extract-lean case-insensitive collision (my_pkg vs mypkg) failed! check=$CASE_CHECK json=$CASE_JSON" >&2
  exit 1
fi
echo "13. extract-lean --pkg unique resolution, ambiguity error & clean Vlib / disambiguated modules -> OK"

# ============================================================================
# 14. Symlinked PION_CACHE_DIR + relative `../model` inside git repos (Astra #1)
# ============================================================================
SYM_CACHE_REAL="$TMP_DIR/sym_cache_real"
SYM_CACHE_LINK="$TMP_DIR/sym_cache_link"
mkdir -p "$SYM_CACHE_REAL"
ln -s "$SYM_CACHE_REAL" "$SYM_CACHE_LINK"

GIT_SYM1="$TMP_DIR/git_sym_repo1"
GIT_SYM2="$TMP_DIR/git_sym_repo2"
mkdir -p "$GIT_SYM1/model/src" "$GIT_SYM1/api/src"
cat > "$GIT_SYM1/model/pion.toml" <<'EOF'
[package]
name = "model"
version = "0.1.0"
EOF
cat > "$GIT_SYM1/model/src/lib.pion" <<'EOF'
pub struct Token {
  id : Int
}

pub fn mk(n : Int) -> Token {
  Token::{ id: n }
}

pub fn rd(t : Token) -> Int {
  t.id
}
EOF
cat > "$GIT_SYM1/api/pion.toml" <<'EOF'
[package]
name = "api"
version = "0.1.0"

[dependencies]
model = { path = "../model" }
EOF
cat > "$GIT_SYM1/api/src/lib.pion" <<'EOF'
import "model"

pub fn make_tok(n : Int) -> model::Token {
  model::mk(n)
}

pub fn read_tok(t : model::Token) -> Int {
  model::rd(t)
}
EOF
git -C "$GIT_SYM1" init -q
git -C "$GIT_SYM1" config user.email "test@pion.dev"
git -C "$GIT_SYM1" config user.name "Pion Test"
git -C "$GIT_SYM1" add .
git -C "$GIT_SYM1" commit -q -m "init"
git -C "$GIT_SYM1" tag v1
cp -R "$GIT_SYM1" "$GIT_SYM2"

# (a) Cross-origin: two distinct Git URLs with same commit + relative ../model -> E_TYPE_MISMATCH
mkdir -p "$TMP_DIR/sym_git_cross/src"
cat > "$TMP_DIR/sym_git_cross/pion.toml" <<EOF
[package]
name = "app"
version = "0.1.0"

[dependencies]
a1 = { package = "api", git = "file://$GIT_SYM1", tag = "v1", subdir = "api" }
a2 = { package = "api", git = "file://$GIT_SYM2", tag = "v1", subdir = "api" }
EOF
cat > "$TMP_DIR/sym_git_cross/src/main.pion" <<'EOF'
import "a1"
import "a2"

pub fn main() -> Int {
  let t = a1::make_tok(9)
  a2::read_tok(t)
}
EOF
set +e
SYM_CROSS_OUT="$(PION_CACHE_DIR="$SYM_CACHE_LINK" "$PIONC" check --json "$TMP_DIR/sym_git_cross" 2>&1)"
SYM_CROSS_RC=$?
set -e
if [ "$SYM_CROSS_RC" -eq 0 ] || ! printf '%s' "$SYM_CROSS_OUT" | grep -q "E_TYPE_MISMATCH"; then
  echo "FAIL: symlinked PION_CACHE_DIR collapsed ../model across distinct git URLs! rc=$SYM_CROSS_RC out=$SYM_CROSS_OUT" >&2
  exit 1
fi
SYM_FETCH_JSON="$(PION_CACHE_DIR="$SYM_CACHE_LINK" "$PIONC" fetch --json "$TMP_DIR/sym_git_cross")"
NON_GIT_EXT="$(printf '%s' "$SYM_FETCH_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); bad=[p for p in d["packages"] if p["name"] in ("api","model") and p["source"] != "git"]; print(len(bad))')"
if [ "$NON_GIT_EXT" != "0" ]; then
  echo "FAIL: symlinked PION_CACHE_DIR misclassified git pkgs as path! fetch=$SYM_FETCH_JSON" >&2
  exit 1
fi

# (b) Same-origin dual-alias: two aliases to GIT_SYM1 -> types compatible!
mkdir -p "$TMP_DIR/sym_git_same/src"
cat > "$TMP_DIR/sym_git_same/pion.toml" <<EOF
[package]
name = "app"
version = "0.1.0"

[dependencies]
a1 = { package = "api", git = "file://$GIT_SYM1", tag = "v1", subdir = "api" }
a2 = { package = "api", git = "file://$GIT_SYM1", tag = "v1", subdir = "api" }
EOF
cat > "$TMP_DIR/sym_git_same/src/main.pion" <<'EOF'
import "a1"
import "a2"

pub fn main() -> Int {
  let t = a1::make_tok(9)
  a2::read_tok(t)
}
EOF
PION_CACHE_DIR="$SYM_CACHE_LINK" "$PIONC" check --json "$TMP_DIR/sym_git_same" | grep -q '"ok":true'
echo "14. Symlinked PION_CACHE_DIR git_origin & ../model isolation + fetch source=git -> OK"

# ============================================================================
# 15. `pionc remove` preserves `pion.lock` when graph load fails (transitive path dep pin)
# ============================================================================
mkdir -p "$TMP_DIR/rm_shared/helper/src" "$TMP_DIR/rm_shared/app/src"
cat > "$TMP_DIR/rm_shared/helper/pion.toml" <<EOF
[package]
name = "helper"
version = "0.1.0"

[dependencies]
j_inner = { package = "json", git = "file://$GIT_UPD", branch = "b1", subdir = "packages/json" }
EOF
cat > "$TMP_DIR/rm_shared/helper/src/lib.pion" <<'EOF'
import "j_inner"
pub fn hv() -> Int { j_inner::v() }
EOF
cat > "$TMP_DIR/rm_shared/app/pion.toml" <<EOF
[package]
name = "rm_shared"
version = "0.1.0"

[dependencies]
helper = { path = "../helper" }
j2 = { package = "json", git = "file://$GIT_UPD", branch = "b1", subdir = "packages/json" }
EOF
cat > "$TMP_DIR/rm_shared/app/src/main.pion" <<'EOF'
import "helper"
import "j2"
pub fn main() -> Int { helper::hv() + j2::v() }
EOF
"$PIONC" fetch "$TMP_DIR/rm_shared/app" >/dev/null
# Add an unrelated broken dep so remove cannot load the full graph
cat >> "$TMP_DIR/rm_shared/app/pion.toml" <<'EOF'
broken_dep = { path = "../missing_dir_xyz" }
EOF
"$PIONC" remove --json j2 "$TMP_DIR/rm_shared/app" | grep -q '"ok":true'
# Restore broken_dep and remove j2 import; transitive helper pin MUST still pass --locked --offline!
sed '/broken_dep/d' "$TMP_DIR/rm_shared/app/pion.toml" > "$TMP_DIR/rm_shared/app/pion.toml.clean"
mv "$TMP_DIR/rm_shared/app/pion.toml.clean" "$TMP_DIR/rm_shared/app/pion.toml"
cat > "$TMP_DIR/rm_shared/app/src/main.pion" <<'EOF'
import "helper"
pub fn main() -> Int { helper::hv() }
EOF
"$PIONC" check --locked --offline --json "$TMP_DIR/rm_shared/app" | grep -q '"ok":true'
echo "15. pionc remove preserves pion.lock on incomplete graph (transitive helper pin intact) -> OK"

# ============================================================================
# 16. Targeted & no-arg `pionc update` from workspace member validates full workspace
#     + `[workspace.dependencies]` registry alias update + rollback on sibling break
# ============================================================================
mkdir -p "$TMP_DIR/ws_upd/mem_a/src" "$TMP_DIR/ws_upd/mem_b/src"
cat > "$TMP_DIR/ws_upd/pion.toml" <<EOF
[workspace]
members = ["mem_a", "mem_b"]

[workspace.dependencies]
my_reg = { package = "json", git = "file://$GIT_UPD", tag = "v0.1.0", subdir = "packages/json", version = "0.1.0", registry = "file://$REG_IDX" }
EOF
cat > "$TMP_DIR/ws_upd/mem_a/pion.toml" <<EOF
[package]
name = "mem_a"
version = "0.1.0"

[dependencies]
ja = { package = "json", git = "file://$GIT_UPD", branch = "b1", subdir = "packages/json" }
my_reg = { workspace = true }
EOF
cat > "$TMP_DIR/ws_upd/mem_a/src/lib.pion" <<'EOF'
import "ja"
import "my_reg"
pub fn fa() -> Int { ja::v() + my_reg::v() }
EOF
cat > "$TMP_DIR/ws_upd/mem_b/pion.toml" <<EOF
[package]
name = "mem_b"
version = "0.1.0"

[dependencies]
jb = { package = "json", git = "file://$GIT_UPD", tag = "v0.1.0", subdir = "packages/json" }
EOF
cat > "$TMP_DIR/ws_upd/mem_b/src/lib.pion" <<'EOF'
import "jb"
pub fn fb() -> Int { jb::v() }
EOF

"$PIONC" fetch "$TMP_DIR/ws_upd" >/dev/null
# (a) Update [workspace.dependencies] registry alias from MEMBER dir -> upgrades root pion.toml to v0.2.0
#     AND preserves mem_b's independent v0.1.0 tag pin!
"$PIONC" update --json my_reg "$TMP_DIR/ws_upd/mem_a" | grep -q '"ok":true'
if ! grep -q 'my_reg = { package = "json",' "$TMP_DIR/ws_upd/pion.toml" || ! grep -q 'version = "0.2.0"' "$TMP_DIR/ws_upd/pion.toml"; then
  echo "FAIL: update my_reg from member did not update [workspace.dependencies]! pion.toml:" >&2
  cat "$TMP_DIR/ws_upd/pion.toml" >&2
  exit 1
fi
"$PIONC" check --locked --offline --json "$TMP_DIR/ws_upd" | grep -q '"ok":true'

# (b) Reset to v0.1.0 and verify update my_reg from WORKSPACE ROOT also upgrades to v0.2.0!
sed 's|tag = "v0.2.0"|tag = "v0.1.0"|g; s|version = "0.2.0"|version = "0.1.0"|g' \
  "$TMP_DIR/ws_upd/pion.toml" > "$TMP_DIR/ws_upd/pion.toml.v1"
mv "$TMP_DIR/ws_upd/pion.toml.v1" "$TMP_DIR/ws_upd/pion.toml"
"$PIONC" fetch "$TMP_DIR/ws_upd" >/dev/null
"$PIONC" update --json my_reg "$TMP_DIR/ws_upd" | grep -q '"ok":true'
if ! grep -q 'my_reg = { package = "json",' "$TMP_DIR/ws_upd/pion.toml" || ! grep -q 'version = "0.2.0"' "$TMP_DIR/ws_upd/pion.toml"; then
  echo "FAIL: update my_reg from workspace root did not update [workspace.dependencies]! pion.toml:" >&2
  cat "$TMP_DIR/ws_upd/pion.toml" >&2
  exit 1
fi
# (c) No-arg `pionc update` from mem_a MUST NOT drop mem_b's lock entry!
"$PIONC" update --json "$TMP_DIR/ws_upd/mem_a" | grep -q '"ok":true'
"$PIONC" check --locked --offline --json "$TMP_DIR/ws_upd" | grep -q '"ok":true'

# (d) Breaking sibling member B on `pionc update my_reg` from member A MUST fail & restore all files byte-for-byte!
GIT_BRK="$TMP_DIR/git_brk_repo"
mkdir -p "$GIT_BRK/src"
cat > "$GIT_BRK/pion.toml" <<'EOF'
[package]
name = "brklib"
version = "0.1.0"
EOF
cat > "$GIT_BRK/src/lib.pion" <<'EOF'
pub fn common() -> Int { 1 }
pub fn only_v1() -> Int { 2 }
EOF
git -C "$GIT_BRK" init -q
git -C "$GIT_BRK" config user.email "test@pion.dev"
git -C "$GIT_BRK" config user.name "Pion Test"
git -C "$GIT_BRK" add .
git -C "$GIT_BRK" commit -q -m "v1"
git -C "$GIT_BRK" tag v1
cat > "$GIT_BRK/src/lib.pion" <<'EOF'
pub fn common() -> Int { 10 }
EOF
git -C "$GIT_BRK" add .
git -C "$GIT_BRK" commit -q -m "v2-breaks-only-v1"
git -C "$GIT_BRK" tag v2

REG_BRK="$TMP_DIR/reg_brk_idx"
mkdir -p "$REG_BRK/index"
cat > "$REG_BRK/index/brklib.toml" <<EOF
name = "brklib"
version = "0.2.0"
git = "file://$GIT_BRK"
tag = "v2"
EOF
git -C "$REG_BRK" init -q
git -C "$REG_BRK" config user.email "test@pion.dev"
git -C "$REG_BRK" config user.name "Pion Test"
git -C "$REG_BRK" add .
git -C "$REG_BRK" commit -q -m "idx"

mkdir -p "$TMP_DIR/ws_brk/ma/src" "$TMP_DIR/ws_brk/mb/src"
cat > "$TMP_DIR/ws_brk/pion.toml" <<EOF
[workspace]
members = ["ma", "mb"]

[workspace.dependencies]
my_brk = { package = "brklib", git = "file://$GIT_BRK", tag = "v1", version = "0.1.0", registry = "file://$REG_BRK" }
EOF
cat > "$TMP_DIR/ws_brk/ma_real_pion.toml" <<'EOF'
[package]
name = "ma"
version = "0.1.0"

[dependencies]
my_brk = { workspace = true }
EOF
ln -s "$TMP_DIR/ws_brk/ma_real_pion.toml" "$TMP_DIR/ws_brk/ma/pion.toml"
cat > "$TMP_DIR/ws_brk/ma/src/lib.pion" <<'EOF'
import "my_brk"
pub fn fa() -> Int { my_brk::common() }
EOF
cat > "$TMP_DIR/ws_brk/mb/pion.toml" <<'EOF'
[package]
name = "mb"
version = "0.1.0"

[dependencies]
my_brk = { workspace = true }
EOF
cat > "$TMP_DIR/ws_brk/mb/src/lib.pion" <<'EOF'
import "my_brk"
pub fn fb() -> Int { my_brk::only_v1() }
EOF
"$PIONC" fetch "$TMP_DIR/ws_brk" >/dev/null
WS_BRK_ROOT_BEFORE="$(cat "$TMP_DIR/ws_brk/pion.toml")"
WS_BRK_MA_BEFORE="$(cat "$TMP_DIR/ws_brk/ma/pion.toml")"
WS_BRK_LOCK_BEFORE="$(cat "$TMP_DIR/ws_brk/pion.lock")"
set +e
BRK_OUT="$("$PIONC" update --json my_brk "$TMP_DIR/ws_brk/ma" 2>&1)"
BRK_RC=$?
set -e
if [ "$BRK_RC" -eq 0 ]; then
  echo "FAIL: update my_brk from ma should fail when v2 breaks sibling mb! out=$BRK_OUT" >&2
  exit 1
fi
if [ ! -L "$TMP_DIR/ws_brk/ma/pion.toml" ] || [ "$(readlink "$TMP_DIR/ws_brk/ma/pion.toml")" != "$TMP_DIR/ws_brk/ma_real_pion.toml" ]; then
  echo "FAIL: rollback clobbered untouched member manifest symlink ma/pion.toml!" >&2
  exit 1
fi
if [ "$(cat "$TMP_DIR/ws_brk/pion.toml")" != "$WS_BRK_ROOT_BEFORE" ] || \
   [ "$(cat "$TMP_DIR/ws_brk/ma/pion.toml")" != "$WS_BRK_MA_BEFORE" ] || \
   [ "$(cat "$TMP_DIR/ws_brk/pion.lock")" != "$WS_BRK_LOCK_BEFORE" ]; then
  echo "FAIL: failed update my_brk did not restore manifests/lock byte-for-byte!" >&2
  exit 1
fi

# (e) Targeted registry update switching A from floating `stable@X` -> `tag:v2` MUST keep
#     sibling B's floating `stable` pin at `X` (NOT float to upstream `Y`)!
GIT_FLT="$TMP_DIR/git_flt_repo"
mkdir -p "$GIT_FLT/src"
cat > "$GIT_FLT/pion.toml" <<'EOF'
[package]
name = "fltlib"
version = "0.1.0"
EOF
cat > "$GIT_FLT/src/lib.pion" <<'EOF'
pub fn v() -> Int { 1 }
EOF
git -C "$GIT_FLT" init -q
git -C "$GIT_FLT" config user.email "test@pion.dev"
git -C "$GIT_FLT" config user.name "Pion Test"
git -C "$GIT_FLT" add .
git -C "$GIT_FLT" commit -q -m "stable-X"
git -C "$GIT_FLT" checkout -q -b stable
FLT_X="$(git -C "$GIT_FLT" rev-parse HEAD)"

REG_FLT="$TMP_DIR/reg_flt_idx"
mkdir -p "$REG_FLT/index"
cat > "$REG_FLT/index/fltlib.toml" <<EOF
name = "fltlib"
version = "0.1.0"
git = "file://$GIT_FLT"
branch = "stable"
EOF
git -C "$REG_FLT" init -q
git -C "$REG_FLT" config user.email "test@pion.dev"
git -C "$REG_FLT" config user.name "Pion Test"
git -C "$REG_FLT" add .
git -C "$REG_FLT" commit -q -m "idx-v1"

mkdir -p "$TMP_DIR/ws_flt/ma/src" "$TMP_DIR/ws_flt/mb/src"
cat > "$TMP_DIR/ws_flt/pion.toml" <<'EOF'
[workspace]
members = ["ma", "mb"]
EOF
cat > "$TMP_DIR/ws_flt/ma/pion.toml" <<EOF
[package]
name = "ma"
version = "0.1.0"

[dependencies]
my_flt = { package = "fltlib", git = "file://$GIT_FLT", branch = "stable", version = "0.1.0", registry = "file://$REG_FLT" }
EOF
cat > "$TMP_DIR/ws_flt/ma/src/lib.pion" <<'EOF'
import "my_flt"
pub fn fa() -> Int { my_flt::v() }
EOF
cat > "$TMP_DIR/ws_flt/mb/pion.toml" <<EOF
[package]
name = "mb"
version = "0.1.0"

[dependencies]
fb_dep = { package = "fltlib", git = "file://$GIT_FLT", branch = "stable" }
EOF
cat > "$TMP_DIR/ws_flt/mb/src/lib.pion" <<'EOF'
import "fb_dep"
pub fn fb() -> Int { fb_dep::v() }
EOF
"$PIONC" fetch "$TMP_DIR/ws_flt" >/dev/null

# Advance upstream `stable` to Y and publish tag `v2` (at Z) in registry
cat > "$GIT_FLT/src/lib.pion" <<'EOF'
pub fn v() -> Int { 99 }
EOF
git -C "$GIT_FLT" add .
git -C "$GIT_FLT" commit -q -m "stable-Y"
FLT_Y="$(git -C "$GIT_FLT" rev-parse HEAD)"

git -C "$GIT_FLT" checkout -q -b rel_v2 "$FLT_X"
cat > "$GIT_FLT/src/lib.pion" <<'EOF'
pub fn v() -> Int { 2 }
EOF
git -C "$GIT_FLT" add .
git -C "$GIT_FLT" commit -q -m "tag-v2"
git -C "$GIT_FLT" tag v2
FLT_Z="$(git -C "$GIT_FLT" rev-parse HEAD)"
git -C "$GIT_FLT" checkout -q stable

cat > "$REG_FLT/index/fltlib.toml" <<EOF
name = "fltlib"
version = "0.2.0"
git = "file://$GIT_FLT"
tag = "v2"
EOF
git -C "$REG_FLT" add .
git -C "$REG_FLT" commit -q -m "idx-v2"

"$PIONC" update --json my_flt "$TMP_DIR/ws_flt/ma" | grep -q '"ok":true'
if ! grep -q "$FLT_X" "$TMP_DIR/ws_flt/pion.lock" || grep -q "$FLT_Y" "$TMP_DIR/ws_flt/pion.lock" || ! grep -q "$FLT_Z" "$TMP_DIR/ws_flt/pion.lock"; then
  echo "FAIL: targeted update floated sibling mb's stable pin from X to Y! lock:" >&2
  cat "$TMP_DIR/ws_flt/pion.lock" >&2
  exit 1
fi
"$PIONC" check --locked --offline --json "$TMP_DIR/ws_flt" | grep -q '"ok":true'
echo "16. Workspace member targeted/no-arg update, sibling pin stability & symlink-safe rollback -> OK"

# ============================================================================
# 17. (a) `pionc test --json <symlink_to_pkg>` (macOS /var -> /private/var canon bug)
#     (b) `pionc update` with unreadable `pion.lock` fails without modifying files
# ============================================================================
mkdir -p "$TMP_DIR/sym_test_real/src"
cat > "$TMP_DIR/sym_test_real/pion.toml" <<'EOF'
[package]
name = "sym_test"
version = "0.1.0"
EOF
cat > "$TMP_DIR/sym_test_real/src/lib.pion" <<'EOF'
pub fn add(a : Int, b : Int) -> Int { a + b }

test "symlinked root runs tests" {
  if add(2, 3) != 5 {
    abort("bad sum")
  }
}
EOF
ln -s "$TMP_DIR/sym_test_real" "$TMP_DIR/sym_test_link"
SYM_TEST_JSON="$("$PIONC" test --json "$TMP_DIR/sym_test_link")"
SYM_TEST_OK="$(printf '%s' "$SYM_TEST_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("OK" if d["ok"] and d["passed"]>=1 and d["deps_skipped"]==0 else "BAD")')"
if [ "$SYM_TEST_OK" != "OK" ]; then
  echo "FAIL: pionc test via directory symlink skipped root package! json=$SYM_TEST_JSON" >&2
  exit 1
fi

# (b) Unreadable pion.lock must fail immediately without touching manifests or lock
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$TMP_DIR/ws_brk/pion.lock"
  set +e
  UNREAD_OUT="$("$PIONC" update --json my_brk "$TMP_DIR/ws_brk/ma" 2>&1)"
  UNREAD_RC=$?
  set -e
  chmod 644 "$TMP_DIR/ws_brk/pion.lock"
  if [ "$UNREAD_RC" -eq 0 ]; then
    echo "FAIL: pionc update with unreadable pion.lock must fail! out=$UNREAD_OUT" >&2
    exit 1
  fi
  if [ "$(cat "$TMP_DIR/ws_brk/pion.toml")" != "$WS_BRK_ROOT_BEFORE" ] || \
     [ "$(cat "$TMP_DIR/ws_brk/ma/pion.toml")" != "$WS_BRK_MA_BEFORE" ] || \
     [ "$(cat "$TMP_DIR/ws_brk/pion.lock")" != "$WS_BRK_LOCK_BEFORE" ]; then
    echo "FAIL: unreadable pion.lock update modified manifests or lock!" >&2
    exit 1
  fi
fi
# (c) `pionc remove` with read-only workspace root (pion.lock write fails) must fail & restore member pion.toml
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$TMP_DIR/ws_ro/m/src"
  cat > "$TMP_DIR/ws_ro/pion.toml" <<'EOF'
[workspace]
members = ["m"]
EOF
  cat > "$TMP_DIR/ws_ro/m/pion.toml" <<EOF
[package]
name = "m"
version = "0.1.0"

[dependencies]
j = { package = "json", git = "file://$GIT_REPO", tag = "v1", subdir = "packages/json" }
EOF
  cat > "$TMP_DIR/ws_ro/m/src/lib.pion" <<'EOF'
import "j"
pub fn f() -> Int { j::ver() }
EOF
  "$PIONC" fetch "$TMP_DIR/ws_ro" >/dev/null
  RO_MF_BEFORE="$(cat "$TMP_DIR/ws_ro/m/pion.toml")"
  RO_LOCK_BEFORE="$(cat "$TMP_DIR/ws_ro/pion.lock")"
  chmod 555 "$TMP_DIR/ws_ro"
  set +e
  RO_OUT="$("$PIONC" remove --json j "$TMP_DIR/ws_ro/m" 2>&1)"
  RO_RC=$?
  set -e
  chmod 755 "$TMP_DIR/ws_ro"
  if [ "$RO_RC" -eq 0 ]; then
    echo "FAIL: pionc remove with read-only workspace root must fail! out=$RO_OUT" >&2
    exit 1
  fi
  if [ "$(cat "$TMP_DIR/ws_ro/m/pion.toml")" != "$RO_MF_BEFORE" ] || \
     [ "$(cat "$TMP_DIR/ws_ro/pion.lock")" != "$RO_LOCK_BEFORE" ]; then
    echo "FAIL: failed pionc remove did not restore m/pion.toml & pion.lock!" >&2
    exit 1
  fi
fi
# (d) `pionc check --json <symlink_to_ws>` preserves caller symlink prefix in diagnostic & fix-it `file`
mkdir -p "$TMP_DIR/sym_diag_real/pkg_a/src" "$TMP_DIR/sym_diag_real/pkg_b/src"
cat > "$TMP_DIR/sym_diag_real/pion.toml" <<'EOF'
[workspace]
members = ["pkg_a", "pkg_b"]
EOF
cat > "$TMP_DIR/sym_diag_real/pkg_a/pion.toml" <<'EOF'
[package]
name = "pkg_a"
version = "0.1.0"
EOF
cat > "$TMP_DIR/sym_diag_real/pkg_a/src/lib.pion" <<'EOF'
pub fn bad_a() -> Int { "not_int" }
EOF
cat > "$TMP_DIR/sym_diag_real/pkg_b/pion.toml" <<'EOF'
[package]
name = "pkg_b"
version = "0.1.0"

[dependencies]
pkg_a = { path = "../pkg_a" }
EOF
cat > "$TMP_DIR/sym_diag_real/pkg_b/src/lib.pion" <<'EOF'
import "pkg_a"
pub fn bad_b() -> Int {
  let _ = pkg_a::bad_a()
  "also_not_int"
}
EOF
ln -s "$TMP_DIR/sym_diag_real" "$TMP_DIR/sym_diag_link"
set +e
SYM_DIAG_JSON="$("$PIONC" check --json "$TMP_DIR/sym_diag_link" 2>&1)"
SYM_DIAG_RC=$?
set -e
SYM_DIAG_OK="$(printf '%s' "$SYM_DIAG_JSON" | python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(sys.stdin); fs={x["file"] for x in d["diagnostics"]}; efs={e["file"] for x in d["diagnostics"] for e in x.get("edits",[]) if e.get("file")}; want={p+"/pkg_a/src/lib.pion", p+"/pkg_b/src/lib.pion"}; ok=(fs==want and all(f.startswith(p+"/") for f in efs)); print("OK" if ok else f"BAD fs={fs} efs={efs}")' "$TMP_DIR/sym_diag_link")"
if [ "$SYM_DIAG_RC" -eq 0 ] || [ "$SYM_DIAG_OK" != "OK" ]; then
  echo "FAIL: symlinked workspace check lost caller path prefix! rc=$SYM_DIAG_RC check=$SYM_DIAG_OK json=$SYM_DIAG_JSON" >&2
  exit 1
fi
echo "17. pionc test/check via symlinked dir + unreadable pion.lock + read-only remove rollback -> OK"

# ============================================================================
# 18. R6 edge regressions:
#     (a) Symlinked app entry (`view/app -> real/packages/app`) resolves `../lib`
#         relative to physical `real/packages/lib` (111), NOT `view/lib` (999);
#     (b) Member `pionc add` preserves sibling member's same-name different-source pin;
#     (c) Early load failure preserves symlinked `pion.lock` untouched.
# ============================================================================
mkdir -p "$TMP_DIR/sym_rel/real/packages/lib/src" \
         "$TMP_DIR/sym_rel/real/packages/app/src" \
         "$TMP_DIR/sym_rel/view/lib/src"
cat > "$TMP_DIR/sym_rel/real/packages/lib/pion.toml" <<'EOF'
[package]
name = "lib"
version = "0.1.0"
EOF
cat > "$TMP_DIR/sym_rel/real/packages/lib/src/lib.pion" <<'EOF'
pub fn num() -> Int { 111 }
EOF
cat > "$TMP_DIR/sym_rel/view/lib/pion.toml" <<'EOF'
[package]
name = "lib"
version = "0.1.0"
EOF
cat > "$TMP_DIR/sym_rel/view/lib/src/lib.pion" <<'EOF'
pub fn num() -> Int { 999 }
EOF
cat > "$TMP_DIR/sym_rel/real/packages/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
lib = { path = "../lib" }
EOF
cat > "$TMP_DIR/sym_rel/real/packages/app/src/main.pion" <<'EOF'
import "lib"

pub fn main(world : World) -> Int {
  io_println(world, "rel=" + lib::num().to_string())
  0
}
EOF
ln -s "$TMP_DIR/sym_rel/real/packages/app" "$TMP_DIR/sym_rel/view/app"
run_native_and_wasm "$TMP_DIR/sym_rel/real/packages/app" "rel=111" "sym_rel_real"
run_native_and_wasm "$TMP_DIR/sym_rel/view/app" "rel=111" "sym_rel_view"

# (b) Member `pionc add` preserves sibling member's same-name different-source pin
mkdir -p "$TMP_DIR/ws_add/ma/src" "$TMP_DIR/ws_add/mb/src"
cat > "$TMP_DIR/ws_add/pion.toml" <<'EOF'
[workspace]
members = ["ma", "mb"]
EOF
cat > "$TMP_DIR/ws_add/ma/pion.toml" <<'EOF'
[package]
name = "ma"
version = "0.1.0"
EOF
cat > "$TMP_DIR/ws_add/ma/src/lib.pion" <<'EOF'
pub fn fa() -> Int { 1 }
EOF
cat > "$TMP_DIR/ws_add/mb/pion.toml" <<EOF
[package]
name = "mb"
version = "0.1.0"

[dependencies]
json = { git = "file://$GIT_UPD", branch = "b1", subdir = "packages/json" }
EOF
cat > "$TMP_DIR/ws_add/mb/src/lib.pion" <<'EOF'
import "json"
pub fn fb() -> Int { json::v() }
EOF
"$PIONC" fetch "$TMP_DIR/ws_add" >/dev/null
"$PIONC" add --json json --git "file://$GIT_REPO" --tag v1 --subdir packages/json "$TMP_DIR/ws_add/ma" | grep -q '"ok":true'
if ! grep -q "$B1_NEW" "$TMP_DIR/ws_add/pion.lock" || ! grep -q "$REV_V1" "$TMP_DIR/ws_add/pion.lock"; then
  echo "FAIL: member pionc add clobbered sibling member's same-name different-source pin! lock:" >&2
  cat "$TMP_DIR/ws_add/pion.lock" >&2
  exit 1
fi
"$PIONC" check --locked --offline --json "$TMP_DIR/ws_add" | grep -q '"ok":true'

# (c) Early load failure preserves symlinked `pion.lock` untouched
mkdir -p "$TMP_DIR/sym_lock/app/src"
cat > "$TMP_DIR/sym_lock/app/pion.toml" <<EOF
[package]
name = "app"
version = "0.1.0"

[dependencies]
j = { package = "json", git = "file://$GIT_REPO", tag = "v1", subdir = "packages/json" }
EOF
cat > "$TMP_DIR/sym_lock/app/src/main.pion" <<'EOF'
import "j"
pub fn main() -> Int { j::ver() }
EOF
"$PIONC" fetch "$TMP_DIR/sym_lock/app" >/dev/null
mv "$TMP_DIR/sym_lock/app/pion.lock" "$TMP_DIR/sym_lock/real_pion.lock"
ln -s "$TMP_DIR/sym_lock/real_pion.lock" "$TMP_DIR/sym_lock/app/pion.lock"
SYM_LOCK_BEFORE="$(cat "$TMP_DIR/sym_lock/app/pion.lock")"
# Add a missing path dep so `pionc update` fails early during workspace load (before writing lock)
cat >> "$TMP_DIR/sym_lock/app/pion.toml" <<'EOF'
missing_dep = { path = "../does_not_exist_r6" }
EOF
set +e
SYM_LOCK_OUT="$("$PIONC" update --json j "$TMP_DIR/sym_lock/app" 2>&1)"
SYM_LOCK_RC=$?
set -e
if [ "$SYM_LOCK_RC" -eq 0 ]; then
  echo "FAIL: pionc update with missing path dep must fail! out=$SYM_LOCK_OUT" >&2
  exit 1
fi
if [ ! -L "$TMP_DIR/sym_lock/app/pion.lock" ] || \
   [ "$(readlink "$TMP_DIR/sym_lock/app/pion.lock")" != "$TMP_DIR/sym_lock/real_pion.lock" ] || \
   [ "$(cat "$TMP_DIR/sym_lock/app/pion.lock")" != "$SYM_LOCK_BEFORE" ]; then
  echo "FAIL: early-failure rollback clobbered symlinked pion.lock!" >&2
  exit 1
fi
echo "18. Symlinked ../lib physical identity + member pionc add sibling pin + symlinked pion.lock rollback -> OK"

# ============================================================================
# 19. R7 `pionc add` edge regressions:
#     (a) Virtual workspace root refuses `pionc add` without modifying manifest or lock;
#     (b) External symlink to workspace member (`view/ma -> ws/ma`) finds enclosing workspace
#         and writes ONLY `ws/pion.lock` (never `ws/ma/pion.lock`);
#     (c) Symlinked entry (`view2/app -> real2/packages/app`) runs `pionc add lib --path ../lib`
#         against physical `real2/packages/lib/pion.toml`.
# ============================================================================
# (a) Virtual workspace root refuses `pionc add`
WS_VROOT_MF_BEFORE="$(cat "$TMP_DIR/ws_add/pion.toml")"
WS_VROOT_LOCK_BEFORE="$(cat "$TMP_DIR/ws_add/pion.lock")"
set +e
VROOT_ADD_OUT="$("$PIONC" add --json json --git "file://$GIT_REPO" --tag v2 --subdir packages/json "$TMP_DIR/ws_add" 2>&1)"
VROOT_ADD_RC=$?
set -e
if [ "$VROOT_ADD_RC" -eq 0 ] || \
   [ "$(cat "$TMP_DIR/ws_add/pion.toml")" != "$WS_VROOT_MF_BEFORE" ] || \
   [ "$(cat "$TMP_DIR/ws_add/pion.lock")" != "$WS_VROOT_LOCK_BEFORE" ]; then
  echo "FAIL: virtual workspace root must refuse pionc add without touching manifest/lock! rc=$VROOT_ADD_RC out=$VROOT_ADD_OUT" >&2
  exit 1
fi

# (b) External symlink to workspace member finds enclosing workspace & updates root pion.lock only
mkdir -p "$TMP_DIR/ws_ext_sym/ma/src" "$TMP_DIR/ws_ext_sym/mb/src" "$TMP_DIR/ext_view"
cat > "$TMP_DIR/ws_ext_sym/pion.toml" <<'EOF'
[workspace]
members = ["ma", "mb"]
EOF
cat > "$TMP_DIR/ws_ext_sym/ma/pion.toml" <<'EOF'
[package]
name = "ma"
version = "0.1.0"
EOF
cat > "$TMP_DIR/ws_ext_sym/ma/src/lib.pion" <<'EOF'
pub fn fa() -> Int { 1 }
EOF
cat > "$TMP_DIR/ws_ext_sym/mb/pion.toml" <<EOF
[package]
name = "mb"
version = "0.1.0"

[dependencies]
json = { git = "file://$GIT_UPD", branch = "b1", subdir = "packages/json" }
EOF
cat > "$TMP_DIR/ws_ext_sym/mb/src/lib.pion" <<'EOF'
import "json"
pub fn fb() -> Int { json::v() }
EOF
"$PIONC" fetch "$TMP_DIR/ws_ext_sym" >/dev/null
ln -s "$TMP_DIR/ws_ext_sym/ma" "$TMP_DIR/ext_view/ma"
"$PIONC" add --json json --git "file://$GIT_REPO" --tag v1 --subdir packages/json "$TMP_DIR/ext_view/ma" | grep -q '"ok":true'
if [ -e "$TMP_DIR/ws_ext_sym/ma/pion.lock" ] || \
   ! grep -q "$B1_NEW" "$TMP_DIR/ws_ext_sym/pion.lock" || \
   ! grep -q "$REV_V1" "$TMP_DIR/ws_ext_sym/pion.lock"; then
  echo "FAIL: external symlink member pionc add wrote member lock or lost sibling pin!" >&2
  exit 1
fi
"$PIONC" check --locked --offline --json "$TMP_DIR/ws_ext_sym" | grep -q '"ok":true'

# (c) Symlinked entry `view2/app -> real2/packages/app` runs `pionc add lib --path ../lib`
mkdir -p "$TMP_DIR/sym_add/real2/packages/lib/src" \
         "$TMP_DIR/sym_add/real2/packages/app/src" \
         "$TMP_DIR/sym_add/view2"
cat > "$TMP_DIR/sym_add/real2/packages/lib/pion.toml" <<'EOF'
[package]
name = "lib"
version = "0.1.0"
EOF
cat > "$TMP_DIR/sym_add/real2/packages/lib/src/lib.pion" <<'EOF'
pub fn val_r7() -> Int { 777 }
EOF
cat > "$TMP_DIR/sym_add/real2/packages/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
EOF
cat > "$TMP_DIR/sym_add/real2/packages/app/src/main.pion" <<'EOF'
pub fn main(world : World) -> Int {
  io_println(world, "init")
  0
}
EOF
ln -s "$TMP_DIR/sym_add/real2/packages/app" "$TMP_DIR/sym_add/view2/app"
"$PIONC" add --json lib --path ../lib "$TMP_DIR/sym_add/view2/app" | grep -q '"ok":true'
cat > "$TMP_DIR/sym_add/real2/packages/app/src/main.pion" <<'EOF'
import "lib"

pub fn main(world : World) -> Int {
  io_println(world, "r7=" + lib::val_r7().to_string())
  0
}
EOF
run_native_and_wasm "$TMP_DIR/sym_add/view2/app" "r7=777" "sym_add_view2"

# (d) Outward member symlink (`ws_out_sym/ma -> ext_member/ma`) finds enclosing workspace
#     and updates ONLY `ws_out_sym/pion.lock` (preserving sibling pin, never writing `ext_member/ma/pion.lock`)
mkdir -p "$TMP_DIR/ext_member/ma/src" "$TMP_DIR/ws_out_sym/mb/src"
cat > "$TMP_DIR/ws_out_sym/pion.toml" <<'EOF'
[workspace]
members = ["ma", "mb"]
EOF
cat > "$TMP_DIR/ext_member/ma/pion.toml" <<'EOF'
[package]
name = "ma"
version = "0.1.0"
EOF
cat > "$TMP_DIR/ext_member/ma/src/lib.pion" <<'EOF'
pub fn fa_out() -> Int { 2 }
EOF
ln -s "$TMP_DIR/ext_member/ma" "$TMP_DIR/ws_out_sym/ma"
cat > "$TMP_DIR/ws_out_sym/mb/pion.toml" <<EOF
[package]
name = "mb"
version = "0.1.0"

[dependencies]
json = { git = "file://$GIT_UPD", branch = "b1", subdir = "packages/json" }
EOF
cat > "$TMP_DIR/ws_out_sym/mb/src/lib.pion" <<'EOF'
import "json"
pub fn fb_out() -> Int { json::v() }
EOF
"$PIONC" fetch "$TMP_DIR/ws_out_sym" >/dev/null
"$PIONC" add --json json --git "file://$GIT_REPO" --tag v1 --subdir packages/json "$TMP_DIR/ws_out_sym/ma" | grep -q '"ok":true'
if [ -e "$TMP_DIR/ext_member/ma/pion.lock" ] || \
   ! grep -q "$B1_NEW" "$TMP_DIR/ws_out_sym/pion.lock" || \
   ! grep -q "$REV_V1" "$TMP_DIR/ws_out_sym/pion.lock"; then
  echo "FAIL: outward symlink member pionc add wrote external member lock or lost sibling pin!" >&2
  exit 1
fi
"$PIONC" check --locked --offline --json "$TMP_DIR/ws_out_sym" | grep -q '"ok":true'

# (e) Missing sibling member (`mb/pion.toml` removed) MUST NOT strip `ma`'s workspace membership:
#     `pionc add` on `ma` must fail citing `mb`, keep `ma/pion.toml` & `ws/pion.lock` byte-identical,
#     and never create `ma/pion.lock`.
mkdir -p "$TMP_DIR/ws_missing_sib/ma/src" "$TMP_DIR/ws_missing_sib/mb/src"
cat > "$TMP_DIR/ws_missing_sib/pion.toml" <<'EOF'
[workspace]
members = ["ma", "mb"]
EOF
cat > "$TMP_DIR/ws_missing_sib/ma/pion.toml" <<'EOF'
[package]
name = "ma"
version = "0.1.0"
EOF
cat > "$TMP_DIR/ws_missing_sib/ma/src/lib.pion" <<'EOF'
pub fn ma_fn() -> Int { 1 }
EOF
cat > "$TMP_DIR/ws_missing_sib/mb/pion.toml" <<EOF
[package]
name = "mb"
version = "0.1.0"

[dependencies]
json = { git = "file://$GIT_UPD", branch = "b1", subdir = "packages/json" }
EOF
cat > "$TMP_DIR/ws_missing_sib/mb/src/lib.pion" <<'EOF'
import "json"
pub fn mb_fn() -> Int { json::v() }
EOF
"$PIONC" fetch "$TMP_DIR/ws_missing_sib" >/dev/null
rm "$TMP_DIR/ws_missing_sib/mb/pion.toml"
cp "$TMP_DIR/ws_missing_sib/ma/pion.toml" "$TMP_DIR/ws_missing_sib_ma.before"
cp "$TMP_DIR/ws_missing_sib/pion.lock" "$TMP_DIR/ws_missing_sib_lock.before"
set +e
MISS_SIB_OUT="$("$PIONC" add --json json --git "file://$GIT_REPO" --tag v1 --subdir packages/json "$TMP_DIR/ws_missing_sib/ma" 2>&1)"
MISS_SIB_RC=$?
set -e
if [ "$MISS_SIB_RC" -eq 0 ] || \
   ! printf '%s' "$MISS_SIB_OUT" | grep -q 'workspace member `mb`' || \
   ! cmp -s "$TMP_DIR/ws_missing_sib/ma/pion.toml" "$TMP_DIR/ws_missing_sib_ma.before" || \
   ! cmp -s "$TMP_DIR/ws_missing_sib/pion.lock" "$TMP_DIR/ws_missing_sib_lock.before" || \
   [ -e "$TMP_DIR/ws_missing_sib/ma/pion.lock" ]; then
  echo "FAIL: missing sibling member broke workspace membership or leaked ma/pion.lock! rc=$MISS_SIB_RC out=$MISS_SIB_OUT" >&2
  exit 1
fi
echo "19. Virtual ws root add guard + inward/outward symlink member add + symlinked add --path + missing sibling guard -> OK"

echo "PASS: wave_j4b_pkg_alias"
