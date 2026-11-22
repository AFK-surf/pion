#!/bin/sh
# P32-B E2E: multi-package virtual [workspace], [workspace.dependencies] (path + git+subdir),
# { workspace = true } inheritance, shared root pion.lock, full CLI integration
# (fetch/check/fmt/test/query/doc/build/run), sub-package upward discovery, and negative checks.
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

# 1. Create a local git repository with a `crates/ext_math` subdir package.
EXT_REPO="$TMP_DIR/ext_repo"
mkdir -p "$EXT_REPO/crates/ext_math/src"
cat > "$EXT_REPO/crates/ext_math/pion.toml" <<'EOF'
[package]
name = "ext_math"
version = "0.1.0"
EOF
cat > "$EXT_REPO/crates/ext_math/src/lib.pion" <<'EOF'
pub fn triple(x : Int) -> Int {
  x * 3
}
EOF
git -C "$EXT_REPO" init -q
git -C "$EXT_REPO" config user.name "pion-test"
git -C "$EXT_REPO" config user.email "pion-test@example.com"
git -C "$EXT_REPO" add .
git -C "$EXT_REPO" commit -q -m "init ext_math"
EXT_REV="$(git -C "$EXT_REPO" rev-parse HEAD)"

# 1b. Second local git repo `ext_aux` declared only in [workspace.dependencies]
# (NOT depended on by `cmd/app`) to guard against partial member loads pruning
# sibling entries from the shared root pion.lock.
AUX_REPO="$TMP_DIR/ext_aux_repo"
mkdir -p "$AUX_REPO/src"
cat > "$AUX_REPO/pion.toml" <<'EOF'
[package]
name = "ext_aux"
version = "0.1.0"
EOF
cat > "$AUX_REPO/src/lib.pion" <<'EOF'
pub fn bump(x : Int) -> Int {
  x + 100
}
EOF
git -C "$AUX_REPO" init -q
git -C "$AUX_REPO" config user.name "pion-test"
git -C "$AUX_REPO" config user.email "pion-test@example.com"
git -C "$AUX_REPO" add .
git -C "$AUX_REPO" commit -q -m "init ext_aux"
AUX_REV="$(git -C "$AUX_REPO" rev-parse HEAD)"

# 2. Build a virtual multi-package workspace: packages/core, packages/ui, cmd/app.
WS="$TMP_DIR/ws"
mkdir -p "$WS/packages/core/src" "$WS/packages/ui/src" "$WS/cmd/app/src"

cat > "$WS/pion.toml" <<EOF
[workspace]
members = [
  "packages/*",
  "cmd/*",
]

[workspace.dependencies]
core = { path = "packages/core" }
ui = { path = "packages/ui" }
ext_math = { git = "file://$EXT_REPO", rev = "$EXT_REV", subdir = "crates/ext_math" }
ext_aux = { git = "file://$AUX_REPO", rev = "$AUX_REV" }
EOF

cat > "$WS/packages/core/pion.toml" <<'EOF'
[package]
name = "core"
version = "0.1.0"

[dependencies]
ext_math = { workspace = true }
EOF
cat > "$WS/packages/core/src/lib.pion" <<'EOF'
import "ext_math" as ext_math

pub fn compute(x : Int) -> Int {
  ext_math::triple(x) + 1
}
EOF
cat > "$WS/packages/core/core_test.pion" <<'EOF'
test "core compute" {
  debug_assert(compute(10) == 31, "compute")
}
EOF

cat > "$WS/packages/ui/pion.toml" <<'EOF'
[package]
name = "ui"
version = "0.1.0"

[dependencies]
core = { workspace = true }
EOF
cat > "$WS/packages/ui/src/lib.pion" <<'EOF'
import "core" as core

pub fn render_score(x : Int) -> String {
  "score=" + core::compute(x).to_string()
}
EOF
cat > "$WS/packages/ui/ui_test.pion" <<'EOF'
test "ui render" {
  debug_assert(render_score(10) == "score=31", "render")
}
EOF

cat > "$WS/cmd/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
ui = { workspace = true }
core = { workspace = true }
ext_math = { workspace = true }
EOF
cat > "$WS/cmd/app/src/main.pion" <<'EOF'
import "ui" as ui
import "ext_math" as ext_math

pub fn main(world : World) -> Int {
  io_println(world, ui::render_score(10) + " raw=" + ext_math::triple(7).to_string())
  0
}
EOF
cat > "$WS/cmd/app/app_test.pion" <<'EOF'
import "ui" as ui

test "app wiring" {
  debug_assert(ui::render_score(5) == "score=16", "app")
}
EOF

# 3. Root-level commands with NO path argument (default ".").
FETCH_OUT="$(cd "$WS" && "$PIONC" fetch --json)"
printf '%s' "$FETCH_OUT" | grep -q '"ok":true' || {
  echo "FAIL: pionc fetch --json failed: $FETCH_OUT" >&2
  exit 1
}
printf '%s' "$FETCH_OUT" | grep -q '"name":"ext_math"' || {
  echo "FAIL: pionc fetch --json missing ext_math: $FETCH_OUT" >&2
  exit 1
}
if [ ! -f "$WS/pion.lock" ]; then
  echo "FAIL: expected shared root pion.lock at $WS/pion.lock" >&2
  exit 1
fi
grep -q 'name = "ext_math"' "$WS/pion.lock" && grep -q 'name = "ext_aux"' "$WS/pion.lock" || {
  echo "FAIL: root pion.lock missing ext_math or ext_aux after fetch" >&2
  cat "$WS/pion.lock" >&2
  exit 1
}

CHECK_OUT="$(cd "$WS" && "$PIONC" check --json)"
printf '%s' "$CHECK_OUT" | grep -q '"ok":true' || {
  echo "FAIL: pionc check --json at ws root failed: $CHECK_OUT" >&2
  exit 1
}

FMT_OUT="$(cd "$WS" && "$PIONC" fmt --check --json)"
printf '%s' "$FMT_OUT" | grep -q '"ok":true' || {
  echo "FAIL: pionc fmt --check at ws root failed: $FMT_OUT" >&2
  exit 1
}

TEST_OUT="$(cd "$WS" && "$PIONC" test --json)"
printf '%s' "$TEST_OUT" | grep -q '"ok":true' || {
  echo "FAIL: pionc test --json at ws root failed: $TEST_OUT" >&2
  exit 1
}
printf '%s' "$TEST_OUT" | grep -q '"passed":3,"failed":0' || {
  echo "FAIL: expected 3/3 passed across workspace members: $TEST_OUT" >&2
  exit 1
}

TEST_UI="$(cd "$WS" && "$PIONC" test --json --package ui)"
printf '%s' "$TEST_UI" | grep -q '"ok":true' && printf '%s' "$TEST_UI" | grep -q '"passed":1,"failed":0' || {
  echo "FAIL: pionc test --package ui failed: $TEST_UI" >&2
  exit 1
}

DEPS_OUT="$(cd "$WS" && "$PIONC" query deps)"
printf '%s' "$DEPS_OUT" | grep -q '"name":"app"' && printf '%s' "$DEPS_OUT" | grep -q '"name":"ext_math"' || {
  echo "FAIL: pionc query deps at ws root failed: $DEPS_OUT" >&2
  exit 1
}

DOC_OUT="$(cd "$WS" && "$PIONC" doc --json)"
printf '%s' "$DOC_OUT" | grep -q '"compute"' && printf '%s' "$DOC_OUT" | grep -q '"render_score"' || {
  echo "FAIL: pionc doc --json at ws root failed: $DOC_OUT" >&2
  exit 1
}

APP_BIN="$TMP_DIR/app_bin"
(cd "$WS" && "$PIONC" build --package app -o "$APP_BIN")
BIN_OUT="$("$APP_BIN")"
if [ "$BIN_OUT" != "score=31 raw=21" ]; then
  echo "FAIL: built app output mismatch: '$BIN_OUT'" >&2
  exit 1
fi
grep -q 'name = "ext_aux"' "$WS/pion.lock" || {
  echo "FAIL: pionc build --package app pruned sibling ext_aux from root pion.lock" >&2
  cat "$WS/pion.lock" >&2
  exit 1
}

RUN_P_OUT="$(cd "$WS" && "$PIONC" run -p app)"
if [ "$RUN_P_OUT" != "score=31 raw=21" ]; then
  echo "FAIL: pionc run -p app output mismatch: '$RUN_P_OUT'" >&2
  exit 1
fi

# Virtual root with unique main member auto-selects `app`.
RUN_AUTO_OUT="$(cd "$WS" && "$PIONC" run)"
if [ "$RUN_AUTO_OUT" != "score=31 raw=21" ]; then
  echo "FAIL: pionc run (auto-select unique main) output mismatch: '$RUN_AUTO_OUT'" >&2
  exit 1
fi

# 4. Inside sub-package `cmd/app` with NO path argument: auto-discovers enclosing workspace.
SUB_CHECK="$(cd "$WS/cmd/app" && "$PIONC" check --json)"
printf '%s' "$SUB_CHECK" | grep -q '"ok":true' || {
  echo "FAIL: sub-package pionc check failed: $SUB_CHECK" >&2
  exit 1
}
SUB_RUN="$(cd "$WS/cmd/app" && "$PIONC" run)"
if [ "$SUB_RUN" != "score=31 raw=21" ]; then
  echo "FAIL: sub-package pionc run output mismatch: '$SUB_RUN'" >&2
  exit 1
fi
if [ -f "$WS/cmd/app/pion.lock" ]; then
  echo "FAIL: sub-package should share root pion.lock, not create cmd/app/pion.lock" >&2
  exit 1
fi
grep -q 'name = "ext_aux"' "$WS/pion.lock" || {
  echo "FAIL: sub-package check/run pruned sibling ext_aux from root pion.lock" >&2
  cat "$WS/pion.lock" >&2
  exit 1
}

# 5. Negative check: undeclared { workspace = true } dependency fails cleanly.
mkdir -p "$WS/cmd/bad/src"
cat > "$WS/cmd/bad/pion.toml" <<'EOF'
[package]
name = "bad"
version = "0.1.0"

[dependencies]
ghost = { workspace = true }
EOF
cat > "$WS/cmd/bad/src/main.pion" <<'EOF'
pub fn main(world : World) -> Int {
  let _ = world
  0
}
EOF
set +e
BAD_ERR="$(cd "$WS/cmd/bad" && "$PIONC" check 2>&1)"
BAD_RC=$?
set -e
if [ "$BAD_RC" -eq 0 ]; then
  echo "FAIL: expected undeclared workspace dep to fail, got rc=0" >&2
  exit 1
fi
printf '%s' "$BAD_ERR" | grep -q "not found in \[workspace.dependencies\]" || {
  echo "FAIL: unexpected error for undeclared workspace dep: $BAD_ERR" >&2
  exit 1
}

echo "p32b_workspace: ALL PASSED (fetch, check, fmt, test, query, doc, build -p, run -p, auto-main, sub-pkg discovery, negative check)"
