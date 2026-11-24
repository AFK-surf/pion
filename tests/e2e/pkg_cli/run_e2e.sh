#!/bin/sh
# Offline end-to-end test of `pionc add` / `pionc update` / `pionc search` against
# real git registries built from local repositories:
#   pionc init -> add --registry (v1) -> test -> index moves to v2 -> update -> test,
# plus `add --path` / `add --git`, idempotent re-add, error paths, `search` over a
# `catalog.json` registry and a legacy `index/` one (UTF-8, ANSI, AND, category,
# ranking, offline / TTL / stale, source priority, cache keys, invalid catalogs,
# option injection), and zero bytes written into the source tree. Everything lives
# in a temp dir with its own PION_CACHE_DIR; PION_REGISTRY=off keeps the default
# (network) registry out of reach, so nothing here goes online.
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
export PION_REGISTRY=off
G="git -c user.name=pion-e2e -c user.email=e2e@pion.invalid -c init.defaultBranch=main -c commit.gpgsign=false -c tag.gpgsign=false"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { # expect <json> <needle> <what>
  printf '%s' "$1" | grep -q -- "$2" || fail "$3: expected $2 in $1"
}
detached_at() { # detached_at <mirror> <oid>: HEAD is detached and equals oid
  ! git --git-dir "$1" symbolic-ref --quiet HEAD >/dev/null 2>&1 && [ "$(git --git-dir "$1" rev-parse HEAD)" = "$2" ]
}
REAL_GIT=$(command -v git)
bounded() { if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"; else "$@"; fi; }
lock_free() { # lock_free <file>: no process holds the exclusive flock on <file>
  python3 -c 'import fcntl, sys; f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)' "$1" 2>/dev/null
}
run_fail() { # run_fail <cmd...>: the command must exit exactly 1; prints its stdout
  set +e
  RF_OUT=$("$@")
  RF_EC=$?
  set -e
  [ "$RF_EC" = 1 ] || fail "expected exit 1, got $RF_EC: $* -> $RF_OUT"
  printf '%s' "$RF_OUT"
}
jcheck() { # jcheck <json> <python expr over d (output) and C (catalog fixture)> <what>
  printf '%s' "$1" | CATF="${CATF:-}" python3 -c '
import json, os, sys
d = json.loads(sys.stdin.buffer.read().decode("utf-8"))
C = json.load(open(os.environ["CATF"], encoding="utf-8")) if os.environ["CATF"] else None
names = [p["name"] for p in d.get("packages", [])]
if not eval(sys.argv[1]):
    sys.exit("assertion failed: %s\n%s" % (sys.argv[1], json.dumps(d, ensure_ascii=False)))
' "$2" || fail "$3"
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
OUT=$(run_fail "$PIONC" add --json pinned --git "$LIB_URL" --tag v1 "$W/util")
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
OUT=$(run_fail "$PIONC" add --json nosuch --registry "$REG_URL" "$W/app3")
expect "$OUT" '"ok":false' "unknown registry package"
expect "$OUT" 'not found in registry' "unknown registry package message"
OUT=$(run_fail "$PIONC" add --json other "$W/util")
expect "$OUT" 'no source for' "no registry configured"
expect "$OUT" '"code":"E_REGISTRY_DISABLED"' "PION_REGISTRY=off disables the default registry for add"
"$PIONC" init --json "$W/app4" > /dev/null
printf '\n[registry]\nurl = "../index.git"\n' >> "$W/app4/pion.toml"
OUT=$(cd "$W/src" && "$PIONC" add --json mylib "$W/app4")
expect "$OUT" '"ok":true' "a relative [registry] url resolves against the pion.toml directory, not PWD"
OUT=$(run_fail "$PIONC" add --json mylib --registry "-evil://x" "$W/app4")
expect "$OUT" '"code":"E_INVALID_ARGS"' "add refuses a registry starting with -"
OUT=$(run_fail "$PIONC" update --json util "$W/app")
expect "$OUT" 'path dependency' "update of a path dependency"

# --- pionc search over a catalog.json registry --------------------------------
mkdir -p "$W/src/cat/index"
: > "$W/src/cat/index/.gitkeep"
# `mylib` is installable for real (index/mylib.toml), the others only searchable.
printf 'name = "mylib"\nversion = "1.0.0"\ngit = "%s"\ntag = "v1"\n' "$LIB_URL" > "$W/src/cat/index/mylib.toml"
python3 - "$W/src/cat/catalog.json" <<'PY'
import json, sys
pk = lambda name, cat, summary, kw, deps=(), wasm=True, wf=True: {
    "name": name, "version": "0.1.0", "tag": name + "-v0.1.0", "subdir": "packages/" + name,
    "category": cat, "summary": summary, "keywords": list(kw), "deps": list(deps),
    "wasm32": wasm, "world_free": wf}
cat = {"schema_version": 1, "registry": "local", "package_count": 6, "packages": [
    pk("jsonpath", "query-lang", "RFC 9535 JSONPath queries", ["query", "路径"], ["regex"]),
    pk("crypto", "crypto-auth", "SHA-256 签名 and \"quoted\" \\ text", ["sha", "签名"], wasm=False),
    pk("json", "data-formats", "Strict JSON parser 严格解析器 with \"quotes\" and \\ backslash / and é \U0001f600 emoji", ["json", "解析", "parser"]),
    pk("evil", "misc", "red \u001b[31mALERT\u001b[0m tab\there csi\u009b2J bell\u0007 del\u007f", ["ansi", "esc"]),
    pk("json5", "data-formats", "JSON5 and JSONC", ["json", "config"], ["json"]),
    pk("mylib", "core-utils", "The e2e answer library", ["answer"]),
]}
# Raw UTF-8 throughout, except the emoji as a \u surrogate pair (both must decode).
text = json.dumps(cat, ensure_ascii=False, indent=2).replace("\U0001f600", "\\ud83d\\ude00")
open(sys.argv[1], "w", encoding="utf-8").write(text + "\n")
PY
(cd "$W/src/cat" && $G init -q && $G add -A && $G commit -q -m catalog)
git clone -q --bare "$W/src/cat" "$W/cat.git"
export CAT_URL="file://$W/cat.git"
export CATF="$W/src/cat/catalog.json"
OUT=$("$PIONC" search --json --registry "$CAT_URL" json)
echo "search json -> $OUT"
jcheck "$OUT" 'd["ok"] and d["format"] == "catalog" and d["stale"] is False and d["source"] == "flag" and d["registry"] == os.environ["CAT_URL"]' "search reads catalog.json via --registry (overriding PION_REGISTRY=off)"
jcheck "$OUT" 'names == ["json", "json5", "jsonpath"] and d["count"] == 3' "exact name, then name prefix, then by name"
jcheck "$OUT" '{k: v for k, v in d["packages"][0].items() if k != "installable"} == [p for p in C["packages"] if p["name"] == "json"][0]' "--json is lossless for UTF-8, quotes, backslashes and surrogate pairs"
jcheck "$OUT" 'all(p["installable"] is False for p in d["packages"])' "packages without index/<name>.toml are not installable"
OUT=$("$PIONC" search --json --registry "$CAT_URL" ANSI)
jcheck "$OUT" '[{k: v for k, v in p.items() if k != "installable"} for p in d["packages"]] == [p for p in C["packages"] if p["name"] == "evil"]' "control characters round-trip through --json escapes"
OUT=$("$PIONC" search --json --registry "$CAT_URL" json query)
jcheck "$OUT" 'names == ["jsonpath"]' "multi-word AND"
OUT=$("$PIONC" search --json --registry "$CAT_URL" "JSON 解析")
jcheck "$OUT" 'names == ["json"]' "ASCII case-insensitive + UTF-8 keyword"
OUT=$("$PIONC" search --json --registry "$CAT_URL" "$(printf 'json\013parser\014')")
jcheck "$OUT" 'names == ["json"]' "VT / FF split query words"
OUT=$("$PIONC" search --json --registry "$CAT_URL" 签名)
jcheck "$OUT" 'names == ["crypto"] and d["packages"][0]["wasm32"] is False' "UTF-8 query and false flags"
OUT=$("$PIONC" search --json --registry "$CAT_URL" --category DATA-formats json)
jcheck "$OUT" 'names == ["json", "json5"]' "--category is an exact, case-insensitive filter"
OUT=$("$PIONC" search --json --registry "$CAT_URL")
jcheck "$OUT" 'names == ["crypto", "evil", "json", "json5", "jsonpath", "mylib"]' "an empty query lists every package by name"
OUT=$("$PIONC" search --json --registry "$CAT_URL" nosuchthing)
jcheck "$OUT" 'd["ok"] and d["count"] == 0 and d["packages"] == []' "zero matches is success"
OUT=$("$PIONC" search --json --registry "$CAT_URL" -- json5)
jcheck "$OUT" 'names == ["json5"]' "words after -- are query words"
OUT=$("$PIONC" search --json --registry "$CAT_URL" -- --bogus)
jcheck "$OUT" 'd["ok"] and d["count"] == 0' "an option-like word after -- is a query word"
OUT=$("$PIONC" search --registry "$CAT_URL" ansi)
echo "search (human) -> $OUT"
printf '%s' "$OUT" | python3 -c 'import sys; b = sys.stdin.buffer.read(); sys.exit(any(c < 32 and c != 10 or c == 127 for c in b) or b"\xc2\x9b" in b)' || fail "human output carries control characters"
case "$OUT" in *"install:"*) fail "install hint for a package without index/<name>.toml: $OUT" ;; esac
"$PIONC" search --registry "$CAT_URL" nosuchthing > /dev/null || fail "zero matches exits 0 (human)"
OUT=$("$PIONC" search --registry "$CAT_URL" answer)
expect "$OUT" "install: pionc add mylib --registry $CAT_URL" "install hint for an installable package"
"$PIONC" init --json "$W/app6" > /dev/null
OUT=$("$PIONC" add --json mylib --registry "$CAT_URL" "$W/app6")
expect "$OUT" "\"rev\":\"$V1\"" "the hinted install command works"
git clone -q --bare "$W/src/cat" "$W/sp ace's.git"
OUT=$("$PIONC" search --registry "$W/sp ace's.git" answer)
expect "$OUT" "install: pionc add mylib --registry '$W/sp ace'\\\\''s.git'" "the hint shell-quotes the registry"

OUT=$(run_fail "$PIONC" search --json --bogus)
expect "$OUT" '"code":"E_INVALID_ARGS"' "unknown option"
OUT=$(run_fail "$PIONC" search --json --registry "$CAT_URL" --category)
expect "$OUT" '"code":"E_INVALID_ARGS"' "missing option value"
OUT=$(run_fail "$PIONC" search --json --registry "")
expect "$OUT" '"code":"E_INVALID_ARGS"' "empty --registry"
OUT=$(run_fail "$PIONC" search --json --offline --refresh --registry "$CAT_URL")
expect "$OUT" '"code":"E_INVALID_ARGS"' "--offline with --refresh"
OUT=$(run_fail "$PIONC" search --json --registry "-evil://x")
expect "$OUT" '"code":"E_INVALID_ARGS"' "a registry URL starting with - is refused"
OUT=$(run_fail env PION_REGISTRY="-evil://x" "$PIONC" search --json)
expect "$OUT" '"code":"E_INVALID_ARGS"' "a PION_REGISTRY starting with - is refused"
OUT=$(cd "$W/src" && run_fail env PION_REGISTRY=OFF "$PIONC" search --json)
expect "$OUT" '"code":"E_REGISTRY_DISABLED"' "PION_REGISTRY=OFF outside a project"
OUT=$(cd "$W/src" && run_fail env PION_REGISTRY=None "$PIONC" search --json)
expect "$OUT" '"code":"E_REGISTRY_DISABLED"' "PION_REGISTRY=None outside a project"
ERR=$(cd "$W/src" && { "$PIONC" search json 2>&1 >/dev/null && echo "ec=0" || echo "ec=$?"; })
expect "$ERR" 'error\[E_REGISTRY_DISABLED\]' "human-mode error carries the code"
expect "$ERR" 'ec=1' "human-mode error exits 1"
OUT=$(cd "$W/src" && PION_REGISTRY="$CAT_URL" "$PIONC" search --json json5)
jcheck "$OUT" 'd["source"] == "env" and names == ["json5"]' "PION_REGISTRY as the source"
OUT=$(run_fail "$PIONC" add --json mylib --registry "" "$W/app6")
expect "$OUT" '"code":"E_INVALID_ARGS"' "add --registry \"\" is refused"

# --- offline, TTL and stale fallback (own caches) -----------------------------
C2="$W/cache2"
OUT=$(run_fail env PION_CACHE_DIR="$C2" "$PIONC" search --json --offline --registry "$CAT_URL")
expect "$OUT" '"code":"E_REGISTRY_UNREACHABLE"' "--offline with a cold cache"
[ ! -e "$C2" ] || fail "--offline created $C2"
OUT=$(PION_CACHE_DIR="$C2" "$PIONC" search --json --registry "$CAT_URL" json5)
jcheck "$OUT" 'names == ["json5"]' "online warm-up"
OUT=$(PION_CACHE_DIR="$C2" "$PIONC" search --json --offline --registry "$CAT_URL" json5)
jcheck "$OUT" 'names == ["json5"] and d["stale"] is False' "--offline with a warm cache"
mv "$W/cat.git" "$W/cat.git.away"
OUT=$(PION_CACHE_DIR="$C2" "$PIONC" search --json --registry "$CAT_URL" json5)
jcheck "$OUT" 'names == ["json5"] and d["stale"] is False' "within the 10-minute TTL no fetch happens"
OUT=$(PION_CACHE_DIR="$C2" "$PIONC" search --json --refresh --registry "$CAT_URL" json5)
jcheck "$OUT" 'd["ok"] and names == ["json5"] and d["stale"] is True' "a failed --refresh falls back to the cached mirror as stale"
OUT=$(PION_CACHE_DIR="$C2" "$PIONC" search --refresh --registry "$CAT_URL" json5 2>&1 >/dev/null)
expect "$OUT" 'stale' "human mode warns about the stale index on stderr"
for M in "$C2"/registry/*.git; do printf '1\n' > "$M/.pion_last_fetch"; done
for N in 1 2; do
  OUT=$(PION_CACHE_DIR="$C2" "$PIONC" search --json --registry "$CAT_URL" json5)
  jcheck "$OUT" 'd["ok"] and d["stale"] is True' "expired stamp + failed refresh #$N stays stale (a failure never renews the stamp)"
done
OUT=$(run_fail env PION_CACHE_DIR="$W/cache3" "$PIONC" search --json --registry "$CAT_URL")
expect "$OUT" '"code":"E_REGISTRY_UNREACHABLE"' "unreachable registry without a mirror"
mv "$W/cat.git.away" "$W/cat.git"
git init -q --bare "$W/empty.git"
OUT=$(run_fail env PION_CACHE_DIR="$W/cache3" "$PIONC" search --json --registry "$W/empty.git")
expect "$OUT" '"code":"E_REGISTRY_UNREACHABLE"' "a registry without commits is unreachable, not an invalid catalog"
OUT=$(run_fail env PION_CACHE_DIR="$W/cache3" "$PIONC" search --json --offline --registry "$W/empty.git")
expect "$OUT" '"code":"E_REGISTRY_UNREACHABLE"' "an empty registry is never cached"
[ -z "$(ls -A "$W/cache3/registry" 2>/dev/null)" ] || fail "an empty registry left a mirror: $(ls -A "$W/cache3/registry")"
# A mirror a former pionc cloned while the registry was still empty (origin
# config + mirror refspec, unborn symbolic HEAD).
C8="$W/cache8"
EMPTY_KEY=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$W/empty.git")
mkdir -p "$C8/registry"
git clone -q --mirror "$W/empty.git" "$C8/registry/$EMPTY_KEY.git" 2>/dev/null
git --git-dir "$C8/registry/$EMPTY_KEY.git" symbolic-ref HEAD refs/heads/main
# Upstream gains a commit B on main, but its HEAD names a missing branch: B is never published.
mkdir -p "$W/src/emp"
printf '{"schema_version": 1, "packages": [{"name": "leak"}]}\n' > "$W/src/emp/catalog.json"
(cd "$W/src/emp" && $G init -q && $G add -A && $G commit -q -m B && $G push -q "$W/empty.git" main)
git --git-dir "$W/empty.git" symbolic-ref HEAD refs/heads/gone
# Neither a fresh cache nor that legacy empty mirror may leak B.
for CD in "$W/cache3" "$C8"; do
  OUT=$(run_fail env PION_CACHE_DIR="$CD" "$PIONC" search --json --refresh --registry "$W/empty.git")
  expect "$OUT" '"code":"E_REGISTRY_UNREACHABLE"' "a registry whose HEAD names no commit stays unreachable"
  OUT=$(run_fail env PION_CACHE_DIR="$CD" "$PIONC" search --json --offline --registry "$W/empty.git")
  expect "$OUT" '"code":"E_REGISTRY_UNREACHABLE"' "and is never published offline"
  case "$OUT" in *leak*) fail "the unpublished commit B leaked: $OUT" ;; esac
done
# Once upstream HEAD is valid, the empty legacy mirror is replaced by a verified fresh clone.
git --git-dir "$W/empty.git" symbolic-ref HEAD refs/heads/main
export EMPTY_B=$(git --git-dir "$W/empty.git" rev-parse refs/heads/main)
OUT=$(PION_CACHE_DIR="$C8" "$PIONC" search --json --refresh --registry "$W/empty.git")
jcheck "$OUT" 'names == ["leak"] and d["commit"] == os.environ["EMPTY_B"] and d["stale"] is False' "an unusable legacy mirror is replaced once upstream is valid"
detached_at "$C8/registry/$EMPTY_KEY.git" "$EMPTY_B" || fail "the replacement mirror is detached at B"
[ -f "$C8/registry/$EMPTY_KEY.git.replace.flock" ] && lock_free "$C8/registry/$EMPTY_KEY.git.replace.flock" || fail "the replace lock was released"

# Two processes repair the same legacy empty mirror: the slow one (held by a FIFO
# barrier right after detaching its verified clone of B, before replacing) must
# not overwrite the fast one's repair to C.
git init -q --bare "$W/empty2.git"
C10="$W/cache10"
E2_KEY=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$W/empty2.git")
mkdir -p "$C10/registry"
git clone -q --mirror "$W/empty2.git" "$C10/registry/$E2_KEY.git" 2>/dev/null
git --git-dir "$C10/registry/$E2_KEY.git" symbolic-ref HEAD refs/heads/main
mkdir -p "$W/src/emp2"
printf '{"schema_version": 1, "packages": [{"name": "rb"}]}\n' > "$W/src/emp2/catalog.json"
(cd "$W/src/emp2" && $G init -q && $G add -A && $G commit -q -m B && $G push -q "$W/empty2.git" main)
git --git-dir "$W/empty2.git" symbolic-ref HEAD refs/heads/main
BAR2="$W/barrier2"
mkdir -p "$BAR2/bin"
mkfifo "$BAR2/ready" "$BAR2/done"
cat > "$BAR2/bin/git" <<WRAP
#!/bin/sh
"$REAL_GIT" "\$@"
rc=\$?
case " \$* " in
  *" update-ref --no-deref HEAD "*)
    if mkdir "$BAR2/held" 2>/dev/null; then
      echo ready > "$BAR2/ready"
      read go < "$BAR2/done"
    fi ;;
esac
exit \$rc
WRAP
chmod +x "$BAR2/bin/git"
(PATH="$BAR2/bin:$PATH" PION_CACHE_DIR="$C10" "$PIONC" search --json --refresh --registry "$W/empty2.git" > "$BAR2/slow.out" 2>&1) &
SLOW2=$!
bounded sh -c 'read r < "$1"' sh "$BAR2/ready" || fail "the slow repair never detached its clone"
printf '{"schema_version": 1, "packages": [{"name": "rc"}]}\n' > "$W/src/emp2/catalog.json"
(cd "$W/src/emp2" && $G commit -q -am C && $G push -q "$W/empty2.git" main)
export REPAIR_C=$(git -C "$W/src/emp2" rev-parse HEAD)
OUT=$(PION_CACHE_DIR="$C10" "$PIONC" search --json --refresh --registry "$W/empty2.git")
jcheck "$OUT" 'names == ["rc"] and d["stale"] is False and d["commit"] == os.environ["REPAIR_C"]' "the fast repair publishes C"
echo go > "$BAR2/done"
wait "$SLOW2" || true
echo "slow repair -> $(cat "$BAR2/slow.out")"
jcheck "$(cat "$BAR2/slow.out")" 'd["ok"] and d["stale"] is True and d["commit"] == os.environ["REPAIR_C"]' "the slow repair yields to the winner C"
OUT=$(PION_CACHE_DIR="$C10" "$PIONC" search --json --offline --registry "$W/empty2.git")
jcheck "$OUT" 'names == ["rc"] and d["commit"] == os.environ["REPAIR_C"]' "the concurrent repair C survives"
detached_at "$C10/registry/$E2_KEY.git" "$REPAIR_C" || fail "HEAD stays detached at C after the slow repair"
[ -f "$C10/registry/$E2_KEY.git.replace.flock" ] && lock_free "$C10/registry/$E2_KEY.git.replace.flock" || fail "the replace lock was released"

# The process holding the replace lock is killed (-9) mid-repair, under the
# lock: the kernel drops the lock, so the next repair proceeds and publishes C.
git init -q --bare "$W/empty3.git"
C11="$W/cache11"
E3_KEY=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$W/empty3.git")
M11="$C11/registry/$E3_KEY.git"
mkdir -p "$C11/registry"
git clone -q --mirror "$W/empty3.git" "$M11" 2>/dev/null
git --git-dir "$M11" symbolic-ref HEAD refs/heads/main
mkdir -p "$M11.replace.lock"  # a lock directory left by an earlier pionc must not block repairs
mkdir -p "$W/src/emp3"
printf '{"schema_version": 1, "packages": [{"name": "rk"}]}\n' > "$W/src/emp3/catalog.json"
(cd "$W/src/emp3" && $G init -q && $G add -A && $G commit -q -m C && $G push -q "$W/empty3.git" main)
git --git-dir "$W/empty3.git" symbolic-ref HEAD refs/heads/main
export KILL_C=$(git -C "$W/src/emp3" rev-parse HEAD)
BAR3="$W/barrier3"
mkdir -p "$BAR3/bin"
mkfifo "$BAR3/ready" "$BAR3/done"
cat > "$BAR3/bin/git" <<WRAP
#!/bin/sh
"$REAL_GIT" "\$@"
rc=\$?
case " \$* " in
  *" --git-dir $M11 rev-parse "*)
    # 1st: the up-front usability check; 2nd: the re-check under the lock.
    if ! mkdir "$BAR3/first" 2>/dev/null && mkdir "$BAR3/held" 2>/dev/null; then
      echo ready > "$BAR3/ready"
      read go < "$BAR3/done"
    fi ;;
esac
exit \$rc
WRAP
chmod +x "$BAR3/bin/git"
PATH="$BAR3/bin:$PATH" PION_CACHE_DIR="$C11" "$PIONC" search --json --refresh --registry "$W/empty3.git" > "$BAR3/holder.out" 2>&1 &
HOLDER=$!
bounded sh -c 'read r < "$1"' sh "$BAR3/ready" || fail "the repair never reached its re-check under the lock"
lock_free "$M11.replace.flock" && fail "fixture: the repair must hold the lock while paused"
kill -9 "$HOLDER"
wait "$HOLDER" 2>/dev/null || true
# Its git child is still blocked in the barrier: the lock fd is close-on-exec,
# so the kernel has already released the lock.
lock_free "$M11.replace.flock" || fail "the kernel released the lock of the killed holder"
echo go > "$BAR3/done"
OUT=$(PION_CACHE_DIR="$C11" "$PIONC" search --json --refresh --registry "$W/empty3.git")
jcheck "$OUT" 'names == ["rk"] and d["stale"] is False and d["commit"] == os.environ["KILL_C"]' "after the lock holder is killed, the next repair succeeds"
OUT=$(PION_CACHE_DIR="$C11" "$PIONC" search --json --offline --registry "$W/empty3.git")
jcheck "$OUT" 'names == ["rk"] and d["commit"] == os.environ["KILL_C"]' "the repaired mirror is readable offline"
detached_at "$M11" "$KILL_C" || fail "the repaired mirror is detached at C"
# PION_REGISTRY="" means unset: the default registry, here a pre-seeded mirror read offline.
C6="$W/cache6"
DEF_KEY=$(python3 -c 'import hashlib; print(hashlib.sha256(b"https://github.com/AFK-surf/pion-packages.git").hexdigest())')
mkdir -p "$C6/registry"
git clone -q --mirror "$W/cat.git" "$C6/registry/$DEF_KEY.git"
OUT=$(cd "$W/src" && PION_CACHE_DIR="$C6" PION_REGISTRY= "$PIONC" search --json --offline json5)
jcheck "$OUT" 'd["source"] == "default" and d["registry"] == "https://github.com/AFK-surf/pion-packages.git" and names == ["json5"]' "PION_REGISTRY=\"\" falls through to the default registry"

# --- the upstream default branch moves ----------------------------------------
mkdir -p "$W/src/br"
printf '{"schema_version": 1, "packages": [{"name": "first"}]}\n' > "$W/src/br/catalog.json"
(cd "$W/src/br" && $G init -q && $G add -A && $G commit -q -m first)
git clone -q --bare "$W/src/br" "$W/br.git"
C7="$W/cache7"
OUT=$(PION_CACHE_DIR="$C7" "$PIONC" search --json --registry "$W/br.git")
jcheck "$OUT" 'names == ["first"] and d["packages"][0]["wasm32"] is None and d["packages"][0]["world_free"] is None and d["packages"][0]["summary"] == ""' "default branch main; omitted catalog fields take their defaults (null flags)"
detached_at "$(ls -d "$C7"/registry/*.git)" "$(git -C "$W/src/br" rev-parse HEAD)" || fail "a fresh mirror is born with a detached HEAD at the upstream commit"
printf '{"schema_version": 1, "packages": [{"name": "second"}]}\n' > "$W/src/br/catalog.json"
(cd "$W/src/br" && $G checkout -q -b trunk && $G commit -q -am second && $G push -q "$W/br.git" trunk)
export TRUNK=$(git -C "$W/src/br" rev-parse HEAD)
git --git-dir "$W/br.git" symbolic-ref HEAD refs/heads/trunk
git --git-dir "$W/br.git" branch -q -D main
OUT=$(PION_CACHE_DIR="$C7" "$PIONC" search --json --refresh --registry "$W/br.git")
jcheck "$OUT" 'names == ["second"] and d["stale"] is False and d["commit"] == os.environ["TRUNK"]' "--refresh follows a new upstream default branch (old one deleted)"
STAMP1=$(cat "$C7"/registry/*.git/.pion_last_fetch)
# Upstream deletes the published branch and points HEAD at a branch that does not exist.
git --git-dir "$W/br.git" symbolic-ref HEAD refs/heads/gone
git --git-dir "$W/br.git" update-ref -d refs/heads/trunk
OUT=$(PION_CACHE_DIR="$C7" "$PIONC" search --json --refresh --registry "$W/br.git")
jcheck "$OUT" 'names == ["second"] and d["stale"] is True and d["commit"] == os.environ["TRUNK"]' "deleted branch + dangling upstream HEAD: the refresh fails as stale and the last snapshot stays readable"
[ "$STAMP1" = "$(cat "$C7"/registry/*.git/.pion_last_fetch)" ] || fail "a failed refresh renewed the TTL stamp"
OUT=$(PION_CACHE_DIR="$C7" "$PIONC" search --json --offline --registry "$W/br.git")
jcheck "$OUT" 'names == ["second"] and d["commit"] == os.environ["TRUNK"]' "after the failed mid-refresh the old mirror HEAD is intact and readable"
# Upstream HEAD detached at a commit no branch or tag points to: --refresh must fetch it explicitly.
printf '{"schema_version": 1, "packages": [{"name": "third"}]}\n' > "$W/src/br/catalog.json"
(cd "$W/src/br" && $G commit -q -am third && $G push -q "$W/br.git" HEAD:refs/tmp/third)
export DETACHED=$(git -C "$W/src/br" rev-parse HEAD)
git --git-dir "$W/br.git" update-ref --no-deref HEAD "$DETACHED"
git --git-dir "$W/br.git" update-ref -d refs/tmp/third
[ -z "$(git --git-dir "$W/br.git" for-each-ref --points-at "$DETACHED")" ] || fail "fixture: the detached commit must be unreferenced"
OUT=$(PION_CACHE_DIR="$C7" "$PIONC" search --json --refresh --registry "$W/br.git")
jcheck "$OUT" 'names == ["third"] and d["stale"] is False and d["commit"] == os.environ["DETACHED"]' "--refresh follows a detached upstream HEAD outside every ref"
M7=$(ls -d "$C7"/registry/*.git)
detached_at "$M7" "$DETACHED" || fail "a successful refresh publishes a detached HEAD at the new commit"
# Upstream: trunk = A (= the published commit) and HEAD -> trunk; a refresh keeps HEAD detached at A.
git --git-dir "$W/br.git" update-ref refs/heads/trunk "$DETACHED"
git --git-dir "$W/br.git" symbolic-ref HEAD refs/heads/trunk
export TRUNK_A="$DETACHED"
OUT=$(PION_CACHE_DIR="$C7" "$PIONC" search --json --refresh --registry "$W/br.git")
jcheck "$OUT" 'names == ["third"] and d["stale"] is False and d["commit"] == os.environ["TRUNK_A"]' "refresh to trunk A"
detached_at "$M7" "$TRUNK_A" || fail "HEAD stays detached even when upstream HEAD is a branch"
# An older pionc left a symbolic HEAD -> refs/heads/trunk. Upstream force-pushes B
# to trunk (the fetch pulls it) and breaks its HEAD: the snapshot must stay A, never B.
git --git-dir "$M7" symbolic-ref HEAD refs/heads/trunk
STAMP2=$(cat "$M7/.pion_last_fetch")
printf '{"schema_version": 1, "packages": [{"name": "fourth"}]}\n' > "$W/src/br/catalog.json"
(cd "$W/src/br" && $G commit -q -am fourth && $G push -q -f "$W/br.git" HEAD:refs/heads/trunk)
export TRUNK_B=$(git -C "$W/src/br" rev-parse HEAD)
git --git-dir "$W/br.git" symbolic-ref HEAD refs/heads/gone
OUT=$(PION_CACHE_DIR="$C7" "$PIONC" search --json --refresh --registry "$W/br.git")
jcheck "$OUT" 'names == ["third"] and d["stale"] is True and d["commit"] == os.environ["TRUNK_A"]' "a fetched-but-unpublished commit never replaces the snapshot (symbolic HEAD migrated first)"
OUT=$(PION_CACHE_DIR="$C7" "$PIONC" search --json --offline --registry "$W/br.git")
jcheck "$OUT" 'names == ["third"] and d["commit"] == os.environ["TRUNK_A"]' "offline still reads the published snapshot"
[ "$STAMP2" = "$(cat "$M7/.pion_last_fetch")" ] || fail "a failed refresh renewed the TTL stamp"
detached_at "$M7" "$TRUNK_A" || fail "the legacy symbolic HEAD was detached at A"
[ "$(git --git-dir "$M7" rev-parse refs/heads/trunk)" = "$TRUNK_B" ] || fail "fixture: the fetch must have moved trunk to B"

# --- a slow refresh never overwrites a newer concurrent publish ---------------
# Mirror at A, upstream at B. Refresh #1 is held (FIFO barrier in a `git`
# wrapper, no sleeps) right after its ls-remote saw B; meanwhile upstream moves
# to C and refresh #2 publishes C; then #1 resumes and its CAS publish of B fails.
mkdir -p "$W/src/cc"
printf '{"schema_version": 1, "packages": [{"name": "ca"}]}\n' > "$W/src/cc/catalog.json"
(cd "$W/src/cc" && $G init -q && $G add -A && $G commit -q -m A)
git clone -q --bare "$W/src/cc" "$W/cc.git"
C9="$W/cache9"
PION_CACHE_DIR="$C9" "$PIONC" search --json --registry "$W/cc.git" > /dev/null
M9=$(ls -d "$C9"/registry/*.git)
printf '{"schema_version": 1, "packages": [{"name": "cb"}]}\n' > "$W/src/cc/catalog.json"
(cd "$W/src/cc" && $G commit -q -am B && $G push -q "$W/cc.git" main)
BAR="$W/barrier"
mkdir -p "$BAR/bin"
mkfifo "$BAR/ready" "$BAR/done"
cat > "$BAR/bin/git" <<WRAP
#!/bin/sh
"$REAL_GIT" "\$@"
rc=\$?
case " \$* " in
  *" ls-remote "*)
    if mkdir "$BAR/held" 2>/dev/null; then
      echo ready > "$BAR/ready"
      read go < "$BAR/done"
    fi ;;
esac
exit \$rc
WRAP
chmod +x "$BAR/bin/git"
(PATH="$BAR/bin:$PATH" PION_CACHE_DIR="$C9" "$PIONC" search --json --refresh --registry "$W/cc.git" > "$BAR/slow.out" 2>&1; echo "$?" > "$BAR/slow.rc") &
SLOW=$!
bounded sh -c 'read r < "$1"' sh "$BAR/ready" || fail "the slow refresh never reached its ls-remote"
printf '{"schema_version": 1, "packages": [{"name": "cc"}]}\n' > "$W/src/cc/catalog.json"
(cd "$W/src/cc" && $G commit -q -am C && $G push -q "$W/cc.git" main)
export COMMIT_C=$(git -C "$W/src/cc" rev-parse HEAD)
OUT=$(PION_CACHE_DIR="$C9" "$PIONC" search --json --refresh --registry "$W/cc.git")
jcheck "$OUT" 'names == ["cc"] and d["stale"] is False and d["commit"] == os.environ["COMMIT_C"]' "the fast refresh publishes C"
echo go > "$BAR/done"
wait "$SLOW" || true
echo "slow refresh -> $(cat "$BAR/slow.out")"
jcheck "$(cat "$BAR/slow.out")" 'd["ok"] and d["stale"] is True and d["commit"] == os.environ["COMMIT_C"]' "the slow refresh loses the CAS and reads the winner C"
OUT=$(PION_CACHE_DIR="$C9" "$PIONC" search --json --offline --registry "$W/cc.git")
jcheck "$OUT" 'names == ["cc"] and d["commit"] == os.environ["COMMIT_C"]' "the newer publish C survives the slow refresh"
detached_at "$M9" "$COMMIT_C" || fail "HEAD stays detached at C"

# --- Windows drive roots are local paths, `g:repo.git` is an scp remote -------
OUT=$(run_fail "$PIONC" search --json --offline --registry C:)
expect "$OUT" '"code":"E_REGISTRY_UNREACHABLE"' "--registry C: offline"
expect "$OUT" 'registry C:/ has no usable cached mirror' "--registry C: normalizes to the drive root C:/"
mkdir -p "$W/drivep"
printf '[package]\nname = "drivep"\nversion = "0.1.0"\n\n[registry]\nurl = "C:"\n' > "$W/drivep/pion.toml"
OUT=$(cd "$W/drivep" && run_fail "$PIONC" search --json --offline)
expect "$OUT" 'registry C:/ has no usable cached mirror' "[registry] url = \"C:\" is the drive root, not <manifest_dir>/C:"
OUT=$(run_fail "$PIONC" search --json --offline --registry g:repo.git)
expect "$OUT" 'registry g:repo.git has no usable cached mirror' "g:repo.git stays an scp-style remote"

# --- pion.lock revs and direct git URLs are validated before any cache path ---
cp -R "$W/util" "$W/badlock"
sed 's/^rev = ".*"/rev = "..\/..\/x"/' "$W/util/pion.lock" > "$W/badlock/pion.lock"
OUT=$(run_fail sh -c '"$0" fetch --json "$1" 2>&1' "$PIONC" "$W/badlock")
expect "$OUT" 'full lowercase hex commit id' "a non-hex locked rev is rejected"
cp "$W/util/pion.toml" "$W/toml.util"
OUT=$(run_fail "$PIONC" add --json bad --git -bad "$W/util")
expect "$OUT" 'must not start with' "a direct git URL starting with - is refused"
cmp -s "$W/util/pion.toml" "$W/toml.util" || fail "refused add left pion.toml modified"

# --- source priority, relative paths and the shared mirror cache key ----------
C4="$W/cache4"
mkdir -p "$W/proj/sub"
printf '[package]\nname = "proj"\nversion = "0.1.0"\n\n[registry]\nurl = "../cat.git"\n' > "$W/proj/pion.toml"
R1=$(cd "$W/proj" && PION_CACHE_DIR="$C4" "$PIONC" search --json json)
jcheck "$R1" 'd["source"] == "manifest" and d["registry"].startswith("/") and d["registry"].endswith("/cat.git") and "/../" not in d["registry"]' "[registry] url relative to pion.toml beats PION_REGISTRY=off"
R2=$(cd "$W/proj/sub" && PION_CACHE_DIR="$C4" "$PIONC" search --json --registry ../../cat.git json)
jcheck "$R2" 'd["source"] == "flag"' "--registry relative to PWD"
[ "$(printf '%s' "$R1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["registry"])')" = "$(printf '%s' "$R2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["registry"])')" ] || fail "manifest-relative and PWD-relative paths normalize to the same registry"
[ "$(ls -d "$C4"/registry/*.git | wc -l | tr -d ' ')" = 1 ] || fail "both share one mirror: $(ls "$C4/registry")"
mkdir -p "$W/broken"
printf '[package]\nname = "broken"\n\n[registry]\nurl = "unterminated\n' > "$W/broken/pion.toml"
OUT=$(cd "$W/broken" && run_fail "$PIONC" search --json)
expect "$OUT" '"code":"E_INVALID_MANIFEST"' "a broken pion.toml is an error, not skipped"
OUT=$(cd "$W/broken" && run_fail "$PIONC" search --json --registry "$CAT_URL")
expect "$OUT" '"code":"E_INVALID_MANIFEST"' "a broken pion.toml is an error even with --registry"

# --- UTF-8 paths: --registry, [registry] url and PION_REGISTRY share one mirror
mkdir -p "$W/中文" "$W/项目"
git clone -q --bare "$W/src/cat" "$W/中文/包索引.git"
printf '[package]\nname = "proj"\nversion = "0.1.0"\n\n[registry]\nurl = "../中文/包索引.git"\n' > "$W/项目/pion.toml"
C5="$W/cache5"
U1=$(cd "$W/项目" && PION_CACHE_DIR="$C5" "$PIONC" search --json json5)
U2=$(cd "$W/中文" && PION_CACHE_DIR="$C5" "$PIONC" search --json --registry 包索引.git json5)
U3=$(cd "$W" && PION_CACHE_DIR="$C5" PION_REGISTRY=中文/包索引.git "$PIONC" search --json json5)
echo "search (UTF-8 path) -> $U1"
for U in "$U1" "$U2" "$U3"; do
  jcheck "$U" 'd["registry"].endswith("/中文/包索引.git") and d["registry"].startswith("/") and names == ["json5"]' "a UTF-8 registry path survives normalization byte for byte"
done
jcheck "$U1" 'd["source"] == "manifest"' "UTF-8 [registry] url"
jcheck "$U2" 'd["source"] == "flag"' "UTF-8 --registry"
jcheck "$U3" 'd["source"] == "env"' "UTF-8 PION_REGISTRY"
[ "$(printf '%s\n%s\n%s\n' "$U1" "$U2" "$U3" | python3 -c 'import json,sys; print(len({json.loads(l)["registry"] for l in sys.stdin}))')" = 1 ] || fail "the three UTF-8 sources normalize to one registry"
[ "$(ls -d "$C5"/registry/*.git | wc -l | tr -d ' ')" = 1 ] || fail "the three UTF-8 sources share one mirror: $(ls "$C5/registry")"
"$PIONC" init --json "$W/app5" > /dev/null
OUT=$(cd "$W" && "$PIONC" add --json mylib --registry 中文/包索引.git "$W/app5")
jcheck "$OUT" 'd["ok"] and d["location"].endswith("/中文/包索引.git")' "add --json keeps a UTF-8 location intact"
grep -q 'registry = "/.*/中文/包索引.git" }' "$W/app5/pion.toml" || fail "pion.toml keeps the UTF-8 registry path: $(cat "$W/app5/pion.toml")"
OUT=$("$PIONC" update --json mylib "$W/app5")
expect "$OUT" '"ok":true' "update re-reads the UTF-8 registry path from pion.toml"

# --- legacy index/ registry (no catalog.json) ---------------------------------
mkdir -p "$W/src/legacy/index/nested"
printf 'name = "alpha"\nversion = "1.2.0"\ngit = "%s"\ntag = "v1"\n\n\n' "$LIB_URL" > "$W/src/legacy/index/alpha.toml"
printf 'version = "0.3.0"\ngit = "%s"\nbranch = "main"\nsubdir = "pkgs/beta"\n' "$LIB_URL" > "$W/src/legacy/index/beta.toml"
printf 'version = "9.9.9"\ngit = "x"\n' > "$W/src/legacy/index/9bad.toml"
printf 'version = "9.9.9"\ngit = "x"\n' > "$W/src/legacy/index/nested/gamma.toml"
: > "$W/src/legacy/index/.gitkeep"
(cd "$W/src/legacy" && $G init -q && $G add -A && $G commit -q -m legacy)
git clone -q --bare "$W/src/legacy" "$W/legacy.git"
CATF=
OUT=$("$PIONC" search --json --registry "$W/legacy.git")
echo "search (index) -> $OUT"
jcheck "$OUT" 'd["format"] == "index" and names == ["alpha", "beta"]' "index/ fallback lists regular, validly named .toml entries only"
jcheck "$OUT" 'd["packages"][0]["version"] == "1.2.0" and d["packages"][0]["tag"] == "v1" and d["packages"][1]["subdir"] == "pkgs/beta" and d["packages"][1]["category"] == "" and d["packages"][1]["keywords"] == [] and d["packages"][1]["wasm32"] is None' "index entries fill defaults"
OUT=$("$PIONC" search --json --registry "$W/legacy.git" --category core alpha)
jcheck "$OUT" 'd["count"] == 0' "an empty category never matches --category"

# --- invalid catalogs never fall back to index/ -------------------------------
for CASE in broken schema2 nullsum nullwasm badname; do
  mkdir -p "$W/src/$CASE/index"
  printf 'version = "1.0.0"\ngit = "x"\n' > "$W/src/$CASE/index/fallback.toml"
  case "$CASE" in
    broken) printf '{"schema_version": 1, "packages": [' ;;
    schema2) printf '{"schema_version": 2, "packages": []}\n' ;;
    nullsum) printf '{"schema_version": 1, "packages": [{"name": "a", "summary": null}]}\n' ;;
    nullwasm) printf '{"schema_version": 1, "packages": [{"name": "a", "wasm32": null}]}\n' ;;
    badname) printf '{"schema_version": 1, "packages": [{"name": "bad name"}]}\n' ;;
  esac > "$W/src/$CASE/catalog.json"
  (cd "$W/src/$CASE" && $G init -q && $G add -A && $G commit -q -m "$CASE")
  git clone -q --bare "$W/src/$CASE" "$W/$CASE.git"
  OUT=$(run_fail "$PIONC" search --json --registry "$W/$CASE.git")
  echo "search ($CASE catalog) -> $OUT"
  expect "$OUT" '"code":"E_REGISTRY_INVALID_CATALOG"' "$CASE catalog.json is reported"
  expect "$OUT" '"ok":false' "$CASE catalog.json fails"
  case "$CASE" in
    schema2) expect "$OUT" 'unsupported schema_version 2' "schema_version message" ;;
    nullsum) expect "$OUT" '`summary` must be a string' "explicit null summary" ;;
    nullwasm) expect "$OUT" '`wasm32` must be a boolean' "explicit null wasm32" ;;
    badname) expect "$OUT" 'invalid package name' "invalid catalog package name" ;;
  esac
done

# --- zero bytes in the source tree --------------------------------------------
TREE_AFTER=$(tree_state)
[ "$TREE_BEFORE" = "$TREE_AFTER" ] || fail "source tree changed: $TREE_AFTER"
echo "pkg_cli e2e: OK (registry add v1 -> update v2, path/git add, idempotent, errors restore files, search catalog/index/offline/TTL/stale/priority, 0 B in tree)"
