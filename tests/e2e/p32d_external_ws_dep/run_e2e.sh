#!/bin/sh
# P32-D E2E: `{ workspace = true }` in an external path/git dependency inherits from
# the `[workspace]` enclosing *that* package, never from the consumer's workspace.
#   1. consumer [workspace] -> nested independent workspace `deps/ext/packages/a`
#      (consumer also declares a decoy `b` that must NOT be picked)
#   2. consumer [workspace] -> sibling independent workspace `../ext/packages/a`
#   3. single-package consumer -> independent workspace `../ext/packages/a`
#   4. negative: an orphan package (member of no workspace) writing `{ workspace = true }`
#      fails even though the consumer's [workspace.dependencies] defines the same name
#      (both outside and nested inside the consumer directory)
#   5. git dependency whose checkout is its own [workspace] (consumer decoy `b` again)
#   6. external workspace member reached through an outward symlink
# Each positive case runs `pionc check` and `pionc build`; case 1 also drives
# `pionc check --server` `reload` after editing the external workspace manifest.
set -eu

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

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# write_pkg <dir> <name> <lib-body> [<deps-toml>]
write_pkg() {
  mkdir -p "$1/src"
  {
    printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "$2"
    if [ -n "${4:-}" ]; then
      printf '\n[dependencies]\n%s\n' "$4"
    fi
  } > "$1/pion.toml"
  printf '%s\n' "$3" > "$1/src/lib.pion"
}

# write_ext_ws <dir>: independent workspace with packages/a -> b = { workspace = true }.
write_ext_ws() {
  mkdir -p "$1"
  cat > "$1/pion.toml" <<'EOF'
[workspace]
members = ["packages/*"]

[workspace.dependencies]
b = { path = "packages/b" }
EOF
  write_pkg "$1/packages/a" a 'import "b" as b

pub fn get() -> Int {
  b::value() + 1
}' 'b = { workspace = true }'
  write_pkg "$1/packages/b" b 'pub fn value() -> Int {
  41
}'
}

# write_app <dir> <a-dep-toml>
write_app() {
  mkdir -p "$1/src"
  printf '[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\n%s\n' "$2" > "$1/pion.toml"
  cat > "$1/src/main.pion" <<'EOF'
import "a" as a

pub fn main(world : World) -> Int {
  io_println(world, "a=" + a::get().to_string())
  0
}
EOF
}

# write_consumer_ws <dir>: consumer [workspace] with member `app` and a decoy `b`.
write_consumer_ws() {
  mkdir -p "$1"
  cat > "$1/pion.toml" <<'EOF'
[workspace]
members = ["app"]

[workspace.dependencies]
b = { path = "decoy_b" }
EOF
  write_pkg "$1/decoy_b" b 'pub fn value() -> Int {
  998
}'
}

# expect_ok <label> <app-dir> <build-cwd>
expect_ok() {
  out="$(cd "$2" && "$PIONC" check --json)" || fail "$1: pionc check failed: $out"
  printf '%s' "$out" | grep -q '"ok":true' || fail "$1: pionc check not ok: $out"
  bin="$TMP_DIR/bin_$1"
  (cd "$3" && "$PIONC" build -o "$bin" "$2") || fail "$1: pionc build failed"
  got="$("$bin")"
  [ "$got" = "a=42" ] || fail "$1: expected 'a=42' (external workspace b), got '$got'"
  echo "  [$1] check + build: OK"
}

# expect_orphan_err <label> <app-dir>
expect_orphan_err() {
  set +e
  err="$(cd "$2" && "$PIONC" check 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$1: orphan { workspace = true } must fail, got rc=0: $err"
  printf '%s' "$err" | grep -q "marked workspace = true but no enclosing \[workspace\] pion.toml found for .*orphan" ||
    fail "$1: unexpected orphan error: $err"
  set +e
  err="$(cd "$2" && "$PIONC" build -o "$TMP_DIR/bin_$1" . 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$1: orphan build must fail, got rc=0"
  echo "  [$1] orphan rejected: OK"
}

# 1. Consumer workspace -> nested independent workspace (decoy `b` in consumer).
S1="$TMP_DIR/s1/consumer"
write_consumer_ws "$S1"
write_ext_ws "$S1/deps/ext"
write_app "$S1/app" 'a = { path = "../deps/ext/packages/a" }'
expect_ok nested "$S1/app" "$S1"
# Building from the consumer workspace root with --package must agree.
(cd "$S1" && "$PIONC" build --package app -o "$TMP_DIR/bin_nested_ws") || fail "nested: build --package app failed"
[ "$("$TMP_DIR/bin_nested_ws")" = "a=42" ] || fail "nested: build --package app picked the wrong b"

# 1b. Editing only the external workspace manifest must be seen by `pionc check`
#     and by `pionc check --server` `reload`.
write_pkg "$S1/deps/ext/packages/b2" b 'pub fn value() -> String {
  "not an int"
}'
python3 - "$PIONC" "$S1" <<'PY'
import json, os, subprocess, sys

pionc, consumer = sys.argv[1], sys.argv[2]
app = os.path.join(consumer, "app")
ext_mf = os.path.join(consumer, "deps", "ext", "pion.toml")
good = open(ext_mf).read()
bad = good.replace('b = { path = "packages/b" }', 'b = { path = "packages/b2" }')
assert bad != good

def check_cli():
    p = subprocess.run([pionc, "check", "--json", app], capture_output=True, text=True)
    return p.returncode

srv = subprocess.Popen([pionc, "check", "--server", app], stdin=subprocess.PIPE,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def rpc(line):
    srv.stdin.write(line + "\n")
    srv.stdin.flush()
    out = srv.stdout.readline()
    assert out, f"server exited early: {srv.stderr.read()}"
    return json.loads(out)

try:
    r0 = rpc('{"id":"s0"}')
    assert r0["ok"] is True, f"server initial check failed: {r0}"
    with open(ext_mf, "w") as f:
        f.write(bad)
    assert check_cli() == 1, "pionc check ignored the external workspace manifest edit"
    r1 = rpc('{"id":"s1","reload":true}')
    assert r1.get("reloaded") is True and r1["ok"] is False and r1["diagnostics"], \
        f"reload ignored the external workspace manifest edit: {r1}"
    with open(ext_mf, "w") as f:
        f.write(good)
    assert check_cli() == 0, "pionc check did not recover after reverting the external manifest"
    r2 = rpc('{"id":"s2","reload":true}')
    assert r2.get("reloaded") is True and r2["ok"] is True, f"reload did not recover: {r2}"
    r3 = rpc('{"id":"q","quit":true}')
    assert r3.get("quit") is True
    assert srv.wait(timeout=30) == 0
finally:
    if srv.poll() is None:
        srv.kill()
        srv.wait()
print("  [nested] check --server reload tracks external workspace pion.toml: OK")
PY

# 2. Consumer workspace -> sibling independent workspace.
S2="$TMP_DIR/s2"
write_consumer_ws "$S2/consumer"
write_ext_ws "$S2/ext"
write_app "$S2/consumer/app" 'a = { path = "../../ext/packages/a" }'
expect_ok sibling "$S2/consumer/app" "$S2/consumer"

# 3. Single-package consumer -> independent workspace.
S3="$TMP_DIR/s3"
write_ext_ws "$S3/ext"
write_app "$S3/app" 'a = { path = "../ext/packages/a" }'
expect_ok single "$S3/app" "$S3/app"

# 4. Orphan package outside / inside the consumer workspace directory.
S4="$TMP_DIR/s4"
write_consumer_ws "$S4/consumer"
write_pkg "$S4/orphan" a 'import "b" as b

pub fn get() -> Int {
  b::value() + 1
}' 'b = { workspace = true }'
mkdir -p "$S4/consumer/app/src"
cat > "$S4/consumer/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
a = { path = "../../orphan" }
EOF
cp "$S1/app/src/main.pion" "$S4/consumer/app/src/main.pion"
expect_orphan_err orphan_outside "$S4/consumer/app"
mkdir -p "$S4/consumer/deps"
cp -R "$S4/orphan" "$S4/consumer/deps/orphan"
sed 's#"../../orphan"#"../deps/orphan"#' "$S4/consumer/app/pion.toml" > "$S4/consumer/app/pion.toml.new"
mv "$S4/consumer/app/pion.toml.new" "$S4/consumer/app/pion.toml"
expect_orphan_err orphan_nested "$S4/consumer/app"

# 5. Git dependency whose checkout is an independent workspace.
S5="$TMP_DIR/s5"
write_ext_ws "$S5/ext_repo"
git -C "$S5/ext_repo" init -q
git -C "$S5/ext_repo" config user.name "pion-test"
git -C "$S5/ext_repo" config user.email "pion-test@example.com"
git -C "$S5/ext_repo" add .
git -C "$S5/ext_repo" commit -q -m "init ext workspace"
EXT_REV="$(git -C "$S5/ext_repo" rev-parse HEAD)"
# The consumer declares a decoy `b`: the git package's inherited `b` must neither
# resolve against it nor be redirected onto it as a root pin.
write_consumer_ws "$S5/consumer"
write_app "$S5/consumer/app" "a = { git = \"file://$S5/ext_repo\", rev = \"$EXT_REV\", subdir = \"packages/a\" }"
expect_ok git "$S5/consumer/app" "$S5/consumer"

# 6. External workspace whose member is an outward symlink (`ext/packages/a -> ../../real_a`):
#    the enclosing workspace is found through the literal (non-canonical) ancestors.
S6="$TMP_DIR/s6"
write_ext_ws "$S6/ext"
mv "$S6/ext/packages/a" "$S6/real_a"
ln -s ../../real_a "$S6/ext/packages/a"
write_app "$S6/app" 'a = { path = "../ext/packages/a" }'
expect_ok symlink "$S6/app" "$S6/app"

echo "p32d_external_ws_dep: ALL PASSED (nested, sibling, single, orphan x2, git, symlinked member, check --server reload)"
