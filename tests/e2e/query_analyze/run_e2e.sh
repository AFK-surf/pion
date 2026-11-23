#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Single-file CLI test (including JSX + val struct + mut struct + let mut)
cat > "$TMP_DIR/single.pion" <<'EOF'
val struct Pt {
  x : Int
}

struct State {
  mut label : String
}

fn State::get(self : State) -> String {
  self.label
}

fn Text(text_by~ : () -> String) -> Int {
  text_by().length()
}

#no_io
fn view(st : State) -> Int {
  let mut n = 0
  let p = Pt::{ x: 1 }
  let f = fn() -> Int {
    n = n + p.x
    n
  }
  let _ = f()
  <Text text_by=>{st.get()} />
}
EOF

SINGLE_JSON="$("$PIONC" query analyze --json "$TMP_DIR/single.pion")"
printf '%s' "$SINGLE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ok"] is True, d
types = {t["name"]: t for t in d["types"]}
assert types["Pt"]["is_val"] is True and types["Pt"]["has_mut_fields"] is False
assert types["State"]["is_val"] is False and types["State"]["has_mut_fields"] is True
fns = {f["name"]: f for f in d["fns"]}
assert fns["view"]["no_io"] is True
closures = d["closures"]
assert len(closures) == 2, closures
c_jsx = [c for c in closures if c["context_arg"] == "text_by"][0]
assert c_jsx["context_callee"] == "single::Text", c_jsx
assert c_jsx["captures"][0]["name"] == "st"
assert c_jsx["captures"][0]["is_mutable_ty"] is True
assert c_jsx["calls"][0]["target"] == "single::State::get"
print("single-file query analyze ok")
'

# 2. Multi-package workspace CLI test
mkdir -p "$TMP_DIR/ws/pkg_a/src" "$TMP_DIR/ws/pkg_b/src"
cat > "$TMP_DIR/ws/pion.toml" <<'EOF'
[workspace]
members = ["pkg_a", "pkg_b"]
EOF

cat > "$TMP_DIR/ws/pkg_a/pion.toml" <<'EOF'
[package]
name = "pkg_a"
version = "0.1.0"
EOF

cat > "$TMP_DIR/ws/pkg_a/src/lib.pion" <<'EOF'
pub struct Store {
  mut count : Int
}

pub fn Store::inc(self : Store) -> Int {
  self.count = self.count + 1
  self.count
}

pub fn computed(f : () -> Int) -> Int {
  f()
}
EOF

cat > "$TMP_DIR/ws/pkg_b/pion.toml" <<'EOF'
[package]
name = "pkg_b"
version = "0.1.0"

[dependencies]
pkg_a = { path = "../pkg_a" }
EOF

cat > "$TMP_DIR/ws/pkg_b/src/main.pion" <<'EOF'
import "pkg_a"

pub fn main_logic(s : pkg_a::Store) -> Int {
  let _ = s.inc()
  pkg_a::computed(fn() -> Int {
    s.inc()
  })
}
EOF

WS_JSON="$("$PIONC" query analyze --json "$TMP_DIR/ws")"
printf '%s' "$WS_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ok"] is True, d
fns = {(f["pkg"], f["name"]): f for f in d["fns"]}
main_calls = [c["target"] for c in fns[("pkg_b", "main_logic")]["calls"]]
assert "pkg_a::Store::inc" in main_calls, main_calls
assert "pkg_a::computed" in main_calls, main_calls
assert len(d["closures"]) == 1, d["closures"]
cl = d["closures"][0]
assert cl["pkg"] == "pkg_b"
assert cl["enclosing_fn"] == "pkg_b::main_logic"
assert cl["context_callee"] == "pkg_a::computed"
assert cl["context_arg"] == "0"
assert cl["captures"][0]["ty"] == "pkg_a::Store"
assert cl["captures"][0]["has_mut_fields"] is True
assert cl["calls"][0]["target"] == "pkg_a::Store::inc"
print("workspace query analyze ok")
'

# 3. Type error produces ok=false with diagnostics and partial results
cat > "$TMP_DIR/bad.pion" <<'EOF'
struct Bad {
  mut x : Int
}

fn broken() -> Int {
  "oops"
}
EOF

set +e
BAD_JSON="$("$PIONC" query analyze --json "$TMP_DIR/bad.pion")"
BAD_RC=$?
set -e
if [ "$BAD_RC" -eq 0 ]; then
  echo "FAIL: expected non-zero exit code for query analyze with type error" >&2
  exit 1
fi
printf '%s' "$BAD_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ok"] is False, d
assert len(d["diagnostics"]) >= 1, d
assert d["types"][0]["name"] == "Bad" and d["types"][0]["has_mut_fields"] is True
print("error-case query analyze ok")
'

echo "[PASS] query analyze e2e (single file, workspace, JSX, diagnostics)"
