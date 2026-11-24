#!/bin/sh
set -eu

PIONC="${1:-./out/pionc}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== P74-E + P75-C E2E: CLI/CAS Hygiene & Float Local Slot Stores ==="

# ----------------------------------------------------------------------------
# 1. Empty PION_CACHE_DIR + 8-process concurrent builds (Native + Wasm32)
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/cas_race/shared/src"
cat > "$TMP_DIR/cas_race/shared/pion.toml" <<'EOF'
[package]
name = "shared"
version = "0.1.0"
EOF
cat > "$TMP_DIR/cas_race/shared/src/lib.pion" <<'EOF'
pub fn add_bias(x : Int) -> Int {
  x * 3 + 7
}
EOF

for i in 1 2 3 4 5 6 7 8; do
  mkdir -p "$TMP_DIR/cas_race/app_$i/src"
  cat > "$TMP_DIR/cas_race/app_$i/pion.toml" <<EOF
[package]
name = "app_$i"
version = "0.1.0"

[dependencies]
shared = { path = "../shared" }
EOF
  cat > "$TMP_DIR/cas_race/app_$i/src/main.pion" <<EOF
import "shared"

pub fn main(world : World) -> Int {
  let v = shared::add_bias($i)
  io_println(world, "app_$i=" + v.to_string())
  0
}
EOF
done

COLD_CAS_NAT="$TMP_DIR/cold_cas_native"
mkdir -p "$COLD_CAS_NAT"
PIDS=""
for i in 1 2 3 4 5 6 7 8; do
  PION_CACHE_DIR="$COLD_CAS_NAT" "$PIONC" build --release \
    -o "$TMP_DIR/cas_race/out_nat_$i" \
    "$TMP_DIR/cas_race/app_$i" >"$TMP_DIR/cas_race/nat_$i.log" 2>&1 &
  PIDS="$PIDS $!"
done
NAT_FAIL=0
for pid in $PIDS; do
  if ! wait "$pid"; then
    NAT_FAIL=1
  fi
done
if [ "$NAT_FAIL" -ne 0 ]; then
  echo "FAIL: concurrent native cold CAS build failed:" >&2
  for i in 1 2 3 4 5 6 7 8; do
    echo "--- nat_$i.log ---" >&2
    cat "$TMP_DIR/cas_race/nat_$i.log" >&2
  done
  exit 1
fi
for i in 1 2 3 4 5 6 7 8; do
  if grep -q 'failed to write CAS' "$TMP_DIR/cas_race/nat_$i.log"; then
    echo "FAIL: nat_$i.log reported failed to write CAS" >&2
    cat "$TMP_DIR/cas_race/nat_$i.log" >&2
    exit 1
  fi
  GOT="$("$TMP_DIR/cas_race/out_nat_$i")"
  EXP="app_$i=$((i * 3 + 7))"
  if [ "$GOT" != "$EXP" ]; then
    echo "FAIL: out_nat_$i got '$GOT' expected '$EXP'" >&2
    exit 1
  fi
done
LEFTOVER_NAT="$(find "$COLD_CAS_NAT" -name '*.tmp.*' | wc -l | tr -d ' ')"
if [ "$LEFTOVER_NAT" -ne 0 ]; then
  echo "FAIL: leftover .tmp. files in native CAS:" >&2
  find "$COLD_CAS_NAT" -name '*.tmp.*' >&2
  exit 1
fi

COLD_CAS_WASM="$TMP_DIR/cold_cas_wasm"
mkdir -p "$COLD_CAS_WASM"
PIDS=""
for i in 1 2 3 4 5 6 7 8; do
  PION_CACHE_DIR="$COLD_CAS_WASM" "$PIONC" build --release --target wasm32 \
    -o "$TMP_DIR/cas_race/out_wasm_$i.wasm" \
    "$TMP_DIR/cas_race/app_$i" >"$TMP_DIR/cas_race/wasm_$i.log" 2>&1 &
  PIDS="$PIDS $!"
done
WASM_FAIL=0
for pid in $PIDS; do
  if ! wait "$pid"; then
    WASM_FAIL=1
  fi
done
if [ "$WASM_FAIL" -ne 0 ]; then
  echo "FAIL: concurrent wasm32 cold CAS build failed:" >&2
  for i in 1 2 3 4 5 6 7 8; do
    echo "--- wasm_$i.log ---" >&2
    cat "$TMP_DIR/cas_race/wasm_$i.log" >&2
  done
  exit 1
fi
for i in 1 2 3 4 5 6 7 8; do
  if grep -q 'failed to write CAS' "$TMP_DIR/cas_race/wasm_$i.log"; then
    echo "FAIL: wasm_$i.log reported failed to write CAS" >&2
    cat "$TMP_DIR/cas_race/wasm_$i.log" >&2
    exit 1
  fi
  if command -v node >/dev/null 2>&1; then
    GOT="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/cas_race/out_wasm_$i.wasm")"
    EXP="app_$i=$((i * 3 + 7))"
    if [ "$GOT" != "$EXP" ]; then
      echo "FAIL: out_wasm_$i got '$GOT' expected '$EXP'" >&2
      exit 1
    fi
  fi
done
LEFTOVER_WASM="$(find "$COLD_CAS_WASM" -name '*.tmp.*' | wc -l | tr -d ' ')"
if [ "$LEFTOVER_WASM" -ne 0 ]; then
  echo "FAIL: leftover .tmp. files in wasm CAS:" >&2
  find "$COLD_CAS_WASM" -name '*.tmp.*' >&2
  exit 1
fi
echo "1. 8-process concurrent cold CAS build (Native + Wasm32, 0 leftover .tmp.) -> OK"

# ----------------------------------------------------------------------------
# 2a. Duplicate package name: root pins time v2 + external git-cache ical -> ../time v1
# ----------------------------------------------------------------------------
DUP_CAS="$TMP_DIR/dup_cas"
EXT_CO="$DUP_CAS/git/checkouts/rev_ical"
mkdir -p "$EXT_CO/time/src" "$EXT_CO/ical/src" "$TMP_DIR/dup_pin/time_v2/src" "$TMP_DIR/dup_pin/app/src"

cat > "$EXT_CO/time/pion.toml" <<'EOF'
[package]
name = "time"
version = "0.1.0"
EOF
cat > "$EXT_CO/time/src/lib.pion" <<'EOF'
pub fn ver() -> Int { 1 }
EOF

cat > "$EXT_CO/ical/pion.toml" <<'EOF'
[package]
name = "ical"
version = "0.1.0"

[dependencies]
time = { path = "../time" }
EOF
cat > "$EXT_CO/ical/src/lib.pion" <<'EOF'
import "time"

pub fn use_time() -> Int { time::ver() * 10 }
EOF

cat > "$TMP_DIR/dup_pin/time_v2/pion.toml" <<'EOF'
[package]
name = "time"
version = "0.2.0"
EOF
cat > "$TMP_DIR/dup_pin/time_v2/src/lib.pion" <<'EOF'
pub fn ver() -> Int { 2 }
EOF

cat > "$TMP_DIR/dup_pin/app/pion.toml" <<EOF
[package]
name = "app"
version = "0.1.0"

[dependencies]
time = { path = "../time_v2" }
ical = { path = "$EXT_CO/ical" }
EOF
cat > "$TMP_DIR/dup_pin/app/src/main.pion" <<'EOF'
import "time"
import "ical"

pub fn main(world : World) -> Int {
  let a = time::ver()
  let b = ical::use_time()
  io_println(world, "unified=" + a.to_string() + "," + b.to_string())
  0
}
EOF

PION_CACHE_DIR="$DUP_CAS" "$PIONC" build --release -o "$TMP_DIR/dup_pin/app_bin" "$TMP_DIR/dup_pin/app"
UNI_OUT="$("$TMP_DIR/dup_pin/app_bin")"
if [ "$UNI_OUT" != "unified=2,20" ]; then
  echo "FAIL: root pin unification got '$UNI_OUT', expected 'unified=2,20'" >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# 2b. Unpinned duplicate package name -> fail fast before compile/link
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/dup_err/time_v1/src" "$TMP_DIR/dup_err/time_v2/src" \
         "$TMP_DIR/dup_err/dep_a/src" "$TMP_DIR/dup_err/dep_b/src" "$TMP_DIR/dup_err/app/src"
cat > "$TMP_DIR/dup_err/time_v1/pion.toml" <<'EOF'
[package]
name = "time"
version = "0.1.0"
EOF
cat > "$TMP_DIR/dup_err/time_v1/src/lib.pion" <<'EOF'
pub fn ver() -> Int { 1 }
EOF
cat > "$TMP_DIR/dup_err/time_v2/pion.toml" <<'EOF'
[package]
name = "time"
version = "0.2.0"
EOF
cat > "$TMP_DIR/dup_err/time_v2/src/lib.pion" <<'EOF'
pub fn ver() -> Int { 2 }
EOF
cat > "$TMP_DIR/dup_err/dep_a/pion.toml" <<'EOF'
[package]
name = "dep_a"
version = "0.1.0"
[dependencies]
time = { path = "../time_v1" }
EOF
cat > "$TMP_DIR/dup_err/dep_a/src/lib.pion" <<'EOF'
import "time"

pub fn a() -> Int { time::ver() }
EOF
cat > "$TMP_DIR/dup_err/dep_b/pion.toml" <<'EOF'
[package]
name = "dep_b"
version = "0.1.0"
[dependencies]
time = { path = "../time_v2" }
EOF
cat > "$TMP_DIR/dup_err/dep_b/src/lib.pion" <<'EOF'
import "time"

pub fn b() -> Int { time::ver() }
EOF
cat > "$TMP_DIR/dup_err/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
[dependencies]
dep_a = { path = "../dep_a" }
dep_b = { path = "../dep_b" }
EOF
cat > "$TMP_DIR/dup_err/app/src/main.pion" <<'EOF'
import "dep_a"
import "dep_b"

pub fn main() -> Int { dep_a::a() + dep_b::b() }
EOF

# 2b. Distinct same-named transitive dependencies now coexist cleanly via canon_id isolation
"$PIONC" build -o "$TMP_DIR/dup_err/app_bin" "$TMP_DIR/dup_err/app"
set +e
"$TMP_DIR/dup_err/app_bin"
COEXIST_RC=$?
set -e
if [ "$COEXIST_RC" -ne 3 ]; then
  echo "FAIL: expected same-name multi-source coexistence exit code 3 (1+2), got rc=$COEXIST_RC" >&2
  exit 1
fi
echo "2. Duplicate package unification (root pin -> unified=2,20) + multi-source canon_id coexistence (rc=3) -> OK"

# ----------------------------------------------------------------------------
# 3. `pionc test dir1 dir2` multi-package directories + mixed-target guard
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/multi_test/common/src" "$TMP_DIR/multi_test/pkg_a/src" "$TMP_DIR/multi_test/pkg_b/src"
cat > "$TMP_DIR/multi_test/common/pion.toml" <<'EOF'
[package]
name = "common"
version = "0.1.0"
EOF
cat > "$TMP_DIR/multi_test/common/src/lib.pion" <<'EOF'
pub fn twice(x : Int) -> Int { x * 2 }
EOF

cat > "$TMP_DIR/multi_test/pkg_a/pion.toml" <<'EOF'
[package]
name = "pkg_a"
version = "0.1.0"
[dependencies]
common = { path = "../common" }
EOF
cat > "$TMP_DIR/multi_test/pkg_a/src/lib.pion" <<'EOF'
import "common"

pub fn fa() -> Int { common::twice(21) }
test "pkg_a_ok" {
  if fa() != 42 { panic("fa mismatch") }
}
EOF

cat > "$TMP_DIR/multi_test/pkg_b/pion.toml" <<'EOF'
[package]
name = "pkg_b"
version = "0.1.0"
[dependencies]
common = { path = "../common" }
EOF
cat > "$TMP_DIR/multi_test/pkg_b/src/lib.pion" <<'EOF'
import "common"

pub fn fb() -> Int { common::twice(50) }
test "pkg_b_ok" {
  if fb() != 100 { panic("fb mismatch") }
}
EOF

MT_OUT="$("$PIONC" test --no-deps "$TMP_DIR/multi_test/pkg_a" "$TMP_DIR/multi_test/pkg_b")"
if ! printf '%s' "$MT_OUT" | grep -q 'pkg_a_ok' || ! printf '%s' "$MT_OUT" | grep -q 'pkg_b_ok'; then
  echo "FAIL: pionc test pkg_a pkg_b did not run both packages: $MT_OUT" >&2
  exit 1
fi

cat > "$TMP_DIR/multi_test/bare.pion" <<'EOF'
test "bare_ok" { if 1 != 1 { panic("bad") } }
EOF
set +e
MIX_OUT="$("$PIONC" test "$TMP_DIR/multi_test/pkg_a" "$TMP_DIR/multi_test/bare.pion" 2>&1)"
MIX_RC=$?
set -e
if [ "$MIX_RC" -eq 0 ] || ! printf '%s' "$MIX_OUT" | grep -q 'cannot mix pion.toml'; then
  echo "FAIL: mixing manifest dir + bare .pion should fail, rc=$MIX_RC out=$MIX_OUT" >&2
  exit 1
fi
echo "3. pionc test dir1 dir2 multi-package + mixed-target guard -> OK"

# ----------------------------------------------------------------------------
# 4. P75-C: Float scalar accumulation loop (Native + Wasm32 + SSA audit)
# ----------------------------------------------------------------------------
cat > "$TMP_DIR/p75c_float.pion" <<'EOF'
pub fn f32_acc(n : Int) -> Float {
  let mut acc : Float = 0.0f
  let mut i = 0
  while i < n {
    acc = acc + 1.5f
    i += 1
  }
  acc
}

pub fn main(world : World) -> Int {
  let s = f32_acc(1000)
  let ok = s == 1500.0f
  if !ok {
    panic("f32_acc mismatch")
  }
  io_println(world, "p75c_float ok")
  0
}
EOF

"$PIONC" build --release --emit-ssa "$TMP_DIR/p75c_float.ssa" -o "$TMP_DIR/p75c_float" "$TMP_DIR/p75c_float.pion"
[ "$("$TMP_DIR/p75c_float")" = "p75c_float ok" ]

LOOP_BODY="$(awk '/\$pion_fn_f32_acc/,/^}/' "$TMP_DIR/p75c_float.ssa" | awk '/@wh_b_/,/^}/')"
if ! printf '%s' "$LOOP_BODY" | grep -q 'stores ' || ! printf '%s' "$LOOP_BODY" | grep -q '=s loads '; then
  echo "FAIL: f32_acc loop missing stores / =s loads:" >&2
  printf '%s\n' "$LOOP_BODY" >&2
  exit 1
fi
if printf '%s' "$LOOP_BODY" | grep -qE '=w cast |storel '; then
  echo "FAIL: f32_acc loop still contains =w cast or storel:" >&2
  printf '%s\n' "$LOOP_BODY" >&2
  exit 1
fi

if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/p75c_float.wasm" "$TMP_DIR/p75c_float.pion"
  [ "$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p75c_float.wasm")" = "p75c_float ok" ]
fi
echo "4. P75-C Float local slot stores (Native + Wasm32 + SSA zero cast/storel) -> OK"

echo "PASS: p74e_cli_cas_hygiene"
