#!/bin/sh
# Offline end-to-end test of `pionc add` / `pionc update` against a real git-index
# registry built from local `file://` repositories:
#   pionc init -> add --registry (v1) -> test -> index moves to v2 -> update -> test,
# plus `add --path` / `add --git`, idempotent re-add, error paths, and zero bytes
# written into the source tree. Everything lives in a temp dir with its own
# PION_CACHE_DIR; no network.
# usage: sh tests/e2e/pkg_cli/run_e2e.sh <pionc>
set -eu
PIONC=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
export PION_QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
export PION_RT_LIB="${PION_RT_LIB:-$ROOT_DIR/out/libpionrt.a}"
if git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  tree_state() { git -C "$ROOT_DIR" status --porcelain --untracked-files=all; }
else # a synced copy without .git: compare a listing of every file instead
  tree_state() { (cd "$ROOT_DIR" && find . -path ./out -prune -o -path ./compiler/_build -prune -o -type f -print | LC_ALL=C sort); }
fi
TREE_BEFORE=$(tree_state)
W=$(mktemp -d)
trap 'chmod -R u+w "$W" 2>/dev/null || true; rm -rf "$W"' EXIT
export PION_CACHE_DIR="$W/cache"
unset PION_REGISTRY || true
G="git -c user.name=pion-e2e -c user.email=e2e@pion.invalid -c init.defaultBranch=main -c commit.gpgsign=false -c tag.gpgsign=false"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { # expect <json> <needle> <what>
  printf '%s' "$1" | grep -q -- "$2" || fail "$3: expected $2 in $1"
}

# --- a library with two releases ---------------------------------------------
mkdir -p "$W/src/mylib/src"
cat > "$W/src/mylib/pion.toml" <<'T'
[package]
name = "mylib"
version = "1.0.0"
T
printf 'pub fn answer() -> Int {\n  1\n}\n' > "$W/src/mylib/src/lib.pion"
(cd "$W/src/mylib" && $G init -q && $G add -A && $G commit -q -m v1 && $G tag v1)
V1=$(git -C "$W/src/mylib" rev-parse HEAD)
printf 'pub fn answer() -> Int {\n  2\n}\n' > "$W/src/mylib/src/lib.pion"
(cd "$W/src/mylib" && $G commit -q -am v2 && $G tag v2)
V2=$(git -C "$W/src/mylib" rev-parse HEAD)
git clone -q --bare "$W/src/mylib" "$W/mylib.git"
LIB_URL="file://$W/mylib.git"

# --- a git-index registry pointing at v1 --------------------------------------
mkdir -p "$W/src/index/index"
printf 'name = "mylib"\nversion = "1.0.0"\ngit = "%s"\ntag = "v1"\n' "$LIB_URL" > "$W/src/index/index/mylib.toml"
(cd "$W/src/index" && $G init -q && $G add -A && $G commit -q -m "mylib 1.0.0")
git clone -q --bare "$W/src/index" "$W/index.git"
REG_URL="file://$W/index.git"

# --- pionc init + add from the registry ---------------------------------------
"$PIONC" init --json "$W/app" > /dev/null
printf 'import "mylib"\n\n///|\ntest "mylib answer" {\n  debug_assert(mylib::answer() == 1, "v1 answer")\n}\n' > "$W/app/dep_test.pion"
OUT=$("$PIONC" add --json mylib --registry "$REG_URL" "$W/app")
echo "add (registry) -> $OUT"
expect "$OUT" '"ok":true' "add"
expect "$OUT" '"action":"add"' "add action"
expect "$OUT" '"source":"registry"' "add source"
expect "$OUT" "\"rev\":\"$V1\"" "add locks v1"
expect "$OUT" '"version":"1.0.0"' "add version"
grep -q "mylib = { git = \"$LIB_URL\", tag = \"v1\", version = \"1.0.0\", registry = \"$REG_URL\" }" "$W/app/pion.toml" || fail "pion.toml entry: $(cat "$W/app/pion.toml")"
grep -q "rev = \"$V1\"" "$W/app/pion.lock" || fail "pion.lock pins v1"
cp "$W/app/pion.toml" "$W/toml.1"
OUT=$("$PIONC" add --json mylib --registry "$REG_URL" "$W/app")
expect "$OUT" '"changed":false' "re-add is idempotent"
cmp -s "$W/app/pion.toml" "$W/toml.1" || fail "re-add rewrote pion.toml"

OUT=$("$PIONC" test --json "$W/app")
echo "test (v1) -> $OUT"
expect "$OUT" '"ok":true' "test v1"
expect "$OUT" '"name":"mylib answer","ok":true' "dep test v1"
expect "$OUT" '"failed":0' "test v1 failed=0"

# --- the registry index moves to v2; update re-resolves -----------------------
printf 'name = "mylib"\nversion = "2.0.0"\ngit = "%s"\ntag = "v2"\n' "$LIB_URL" > "$W/src/index/index/mylib.toml"
(cd "$W/src/index" && $G commit -q -am "mylib 2.0.0" && $G push -q "$W/index.git" main)
OUT=$("$PIONC" update --json "$W/app")
echo "update -> $OUT"
expect "$OUT" '"ok":true' "update"
expect "$OUT" '"action":"update"' "update action"
expect "$OUT" "\"name\":\"mylib\",\"ref\":\"tag:v2\",\"from\":\"$V1\",\"to\":\"$V2\",\"updated\":true" "update v1 -> v2"
grep -q 'tag = "v2", version = "2.0.0"' "$W/app/pion.toml" || fail "pion.toml now asks for v2"
grep -q "rev = \"$V2\"" "$W/app/pion.lock" || fail "pion.lock pins v2"

OUT=$("$PIONC" test --json "$W/app" || true)
expect "$OUT" '"name":"mylib answer","ok":false' "the v1 assertion fails against v2 (no stale test binary)"
sed 's/== 1, "v1 answer"/== 2, "v2 answer"/' "$W/app/dep_test.pion" > "$W/dep_test.tmp" && mv "$W/dep_test.tmp" "$W/app/dep_test.pion"
OUT=$("$PIONC" test --json "$W/app")
echo "test (v2) -> $OUT"
expect "$OUT" '"ok":true' "test v2"
expect "$OUT" '"failed":0' "test v2 failed=0"

OUT=$("$PIONC" update --json mylib "$W/app")
expect "$OUT" "\"to\":\"$V2\",\"updated\":false" "second update is a no-op"

# --- add --path and add --git -------------------------------------------------
"$PIONC" init --json "$W/util" > /dev/null
OUT=$("$PIONC" add --json util --path ../util "$W/app")
expect "$OUT" '"source":"path"' "add --path"
grep -q 'util = { path = "../util" }' "$W/app/pion.toml" || fail "path entry"
OUT=$("$PIONC" add --json pinned --git "$LIB_URL" --tag v1 "$W/util" || true)
expect "$OUT" '"ok":false' "add --git with a mismatched package name fails"
expect "$OUT" 'does not declare package `pinned`' "name mismatch message"
grep -q pinned "$W/util/pion.toml" && fail "failed add left pion.toml modified"
[ ! -f "$W/util/pion.lock" ] || fail "failed add left a pion.lock"
OUT=$("$PIONC" add --json mylib --git "$LIB_URL" --tag v2 "$W/util")
expect "$OUT" '"source":"git"' "add --git --tag"
expect "$OUT" "\"rev\":\"$V2\"" "add --git locks the tag's commit"
grep -q "mylib = { git = \"$LIB_URL\", tag = \"v2\" }" "$W/util/pion.toml" || fail "git entry"
OUT=$("$PIONC" test --json "$W/app")
expect "$OUT" '"ok":true' "workspace with path + registry deps tests green"

# --- registry from [registry] url / PION_REGISTRY, and error paths -------------
"$PIONC" init --json "$W/app2" > /dev/null
printf '\n[registry]\nurl = "%s"\n' "$REG_URL" >> "$W/app2/pion.toml"
OUT=$("$PIONC" add --json mylib "$W/app2")
expect "$OUT" "\"rev\":\"$V2\"" "add via [registry] url gets the current index entry"
"$PIONC" init --json "$W/app3" > /dev/null
OUT=$(PION_REGISTRY="$REG_URL" "$PIONC" add --json mylib "$W/app3")
expect "$OUT" '"ok":true' "add via PION_REGISTRY"
OUT=$("$PIONC" add --json nosuch --registry "$REG_URL" "$W/app3" || true)
expect "$OUT" '"ok":false' "unknown registry package"
expect "$OUT" 'not found in registry' "unknown registry package message"
OUT=$("$PIONC" add --json other "$W/util" || true)
expect "$OUT" 'no source for' "no registry configured"
OUT=$("$PIONC" update --json util "$W/app" || true)
expect "$OUT" 'path dependency' "update of a path dependency"

# --- zero bytes in the source tree --------------------------------------------
TREE_AFTER=$(tree_state)
[ "$TREE_BEFORE" = "$TREE_AFTER" ] || fail "source tree changed: $TREE_AFTER"
echo "pkg_cli e2e: OK (registry add v1 -> update v2, path/git add, idempotent, errors restore files, 0 B in tree)"
