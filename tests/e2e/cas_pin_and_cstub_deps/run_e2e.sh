#!/bin/sh
# End-to-end regression tests for:
#   1. CAS runtime pinning + post-run eviction under tiny cache budgets
#      (`PION_CACHE_MAX_KB=1`), preventing intra-batch and cross-phase
#      self-eviction during `pionc test --jobs 4` and `pionc build`.
#   2. cstub Direct Mode header dependency tracking (`../`, `-I`, transitive
#      headers) with identical size & identical mtime, plus C compiler version
#      fingerprinting (`--version`).
#
# Usage: sh tests/e2e/cas_pin_and_cstub_deps/run_e2e.sh <pionc>
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
case "$PIONC" in
  /*) ;;
  *) PIONC="$(CDPATH= cd -- "$(dirname -- "$PIONC")" && pwd)/$(basename -- "$PIONC")" ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL (cas_pin_and_cstub_deps): $*" >&2
  exit 1
}

echo "=== E2E: CAS runtime pinning + cstub real header deps & compiler version ==="

# ============================================================================
# Scenario A (Bug 1): 6-package workspace (with c_sources) under PION_CACHE_MAX_KB=1
# ============================================================================
WS_A="$TMP_DIR/ws_pin"
mkdir -p "$WS_A/base/src" "$WS_A/base/csrc" \
         "$WS_A/p1/src" "$WS_A/p2/src" "$WS_A/p3/src" "$WS_A/p4/src" "$WS_A/app/src"

cat > "$WS_A/pion.toml" <<'EOF'
[workspace]
members = ["base", "p1", "p2", "p3", "p4", "app"]
EOF

cat > "$WS_A/base/pion.toml" <<'EOF'
[package]
name = "base"
version = "0.1.0"

[link]
c_sources = ["csrc/base.c"]
EOF
cat > "$WS_A/base/csrc/base.c" <<'EOF'
#include <stdint.h>
int64_t cas_pin_base_c(void) { return 7; }
EOF
cat > "$WS_A/base/src/lib.pion" <<'EOF'
extern "C" fn cas_pin_base_c() -> Int64
pub fn base_val() -> Int64 { cas_pin_base_c() }
EOF
cat > "$WS_A/base/src/base_test.pion" <<'EOF'
test "base_t1" { debug_assert(base_val() == 7L, "base_t1") }
test "base_t2" { debug_assert(base_val() + 1L == 8L, "base_t2") }
EOF

for N in 1 2 3 4; do
  cat > "$WS_A/p${N}/pion.toml" <<EOF
[package]
name = "p${N}"
version = "0.1.0"

[dependencies]
base = { path = "../base" }
EOF
  cat > "$WS_A/p${N}/src/lib.pion" <<EOF
import "base"
pub fn val_${N}() -> Int64 { base::base_val() + ${N}L }
EOF
  cat > "$WS_A/p${N}/src/p${N}_test.pion" <<EOF
test "p${N}_t1" { debug_assert(val_${N}() == $((7 + N))L, "p${N}_t1") }
test "p${N}_t2" { debug_assert(val_${N}() * 2L == $((2 * (7 + N)))L, "p${N}_t2") }
EOF
done

cat > "$WS_A/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
p1 = { path = "../p1" }
p2 = { path = "../p2" }
p3 = { path = "../p3" }
p4 = { path = "../p4" }
EOF
cat > "$WS_A/app/src/main.pion" <<'EOF'
import "p1"
import "p2"
import "p3"
import "p4"

pub fn total_val() -> Int64 {
  p1::val_1() + p2::val_2() + p3::val_3() + p4::val_4()
}

fn main(world : World) -> Unit {
  io_println(world, "pin_sum=" + total_val().to_string())
}
EOF
cat > "$WS_A/app/src/app_test.pion" <<'EOF'
test "app_sum" { debug_assert(total_val() == 38L, "app_sum") }
EOF

CAS_A="$TMP_DIR/cas_a"
mkdir -p "$CAS_A"

# Cold test under PION_CACHE_MAX_KB=1 (1024 B budget)
PION_CACHE_DIR="$CAS_A" PION_CACHE_MAX_KB=1 "$PIONC" test --jobs 4 --json "$WS_A" > "$TMP_DIR/a_cold.json"
python3 - "$TMP_DIR/a_cold.json" "$CAS_A/index.tsv" <<'PYEOF'
import json, os, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["total"] == 11 and d["passed"] == 11 and d["failed"] == 0, d
# Verify post-run eviction trimmed index.tsv down to <= 80% of 1024 bytes (819 B)
idx_path = sys.argv[2]
assert os.path.isfile(idx_path), "expected index.tsv to exist"
total_bytes = 0
for line in open(idx_path):
    parts = line.strip().split("\t")
    if len(parts) == 3:
        total_bytes += int(parts[1])
assert total_bytes <= 819, f"post-run eviction did not trim index.tsv: total_bytes={total_bytes}"
PYEOF

# Warm/repeat test under PION_CACHE_MAX_KB=1
PION_CACHE_DIR="$CAS_A" PION_CACHE_MAX_KB=1 "$PIONC" test --jobs 4 --json "$WS_A" > "$TMP_DIR/a_hot.json"
python3 - "$TMP_DIR/a_hot.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["total"] == 11 and d["passed"] == 11 and d["failed"] == 0, d
PYEOF

# Build under PION_CACHE_MAX_KB=1 (cold & repeat)
PION_CACHE_DIR="$CAS_A" PION_CACHE_MAX_KB=1 "$PIONC" build -o "$TMP_DIR/app_bin_1" "$WS_A/app"
OUT_A1="$("$TMP_DIR/app_bin_1")"
[ "$OUT_A1" = "pin_sum=38" ] || fail "Scenario A cold build output mismatch: $OUT_A1"

PION_CACHE_DIR="$CAS_A" PION_CACHE_MAX_KB=1 "$PIONC" build -o "$TMP_DIR/app_bin_2" "$WS_A/app"
OUT_A2="$("$TMP_DIR/app_bin_2")"
[ "$OUT_A2" = "pin_sum=38" ] || fail "Scenario A repeat build output mismatch: $OUT_A2"

echo "(A) PION_CACHE_MAX_KB=1 test --jobs 4 + build + post-run trim -> OK"

# ============================================================================
# Scenario B (Bug 2): cstub real header deps (../, -I, transitive) & cc version
# ============================================================================
WS_B="$TMP_DIR/ws_cstub"
mkdir -p "$WS_B/pkg/src" "$WS_B/native/fetch" "$WS_B/ext_inc"

cat > "$WS_B/native/win_compat.h" <<'EOF'
#define COMPAT_VAL 100
EOF

cat > "$WS_B/ext_inc/sub.h" <<'EOF'
#define SUB_VAL 000
EOF

cat > "$WS_B/ext_inc/ext.h" <<'EOF'
#include "sub.h"
#define EXT_VAL SUB_VAL
EOF

# Note: ZERO .h files exist in $WS_B/pkg or $WS_B/native/fetch!
cat > "$WS_B/native/fetch/fetch.c" <<'EOF'
#include <stdint.h>
#include "../win_compat.h"
#include "ext.h"

int64_t fetch_combined_val(void) {
  return (int64_t)(COMPAT_VAL + EXT_VAL);
}
EOF

cat > "$WS_B/pkg/pion.toml" <<'EOF'
[package]
name = "fetch_pkg"
version = "0.1.0"

[link]
c_sources = ["../native/fetch/fetch.c"]
cc_flags = ["-I../ext_inc"]
EOF

cat > "$WS_B/pkg/src/main.pion" <<'EOF'
extern "C" fn fetch_combined_val() -> Int64

pub fn get_val() -> Int64 {
  fetch_combined_val()
}

fn main(world : World) -> Unit {
  io_println(world, get_val().to_string())
}
EOF

cat > "$WS_B/pkg/src/pkg_test.pion" <<'EOF'
test "fetch_val_matches_env" {
  // Always assert positive; exact value is checked via build output AND a
  // dedicated test expectation updated in lockstep below.
  debug_assert(get_val() >= 100L, "fetch_val")
}
EOF

CAS_B="$TMP_DIR/cas_b"
mkdir -p "$CAS_B"

# 1) Cold build -> MISS, outputs 100
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_B" "$PIONC" build -o "$TMP_DIR/b_bin1" "$WS_B/pkg" 2>"$TMP_DIR/b_build1.trace"
grep -q "cstub=.*fetch\.c MISS key=" "$TMP_DIR/b_build1.trace" || fail "expected cold build cstub MISS"
OUT_B1="$("$TMP_DIR/b_bin1")"
[ "$OUT_B1" = "100" ] || fail "expected 100 on cold build, got $OUT_B1"

# 2) Warm build & test -> HIT, outputs 100
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_B" "$PIONC" build -o "$TMP_DIR/b_bin2" "$WS_B/pkg" 2>"$TMP_DIR/b_build2.trace"
grep -q "cstub=.*fetch\.c HIT key=" "$TMP_DIR/b_build2.trace" || fail "expected warm build cstub HIT"
OUT_B2="$("$TMP_DIR/b_bin2")"
[ "$OUT_B2" = "100" ] || fail "expected 100 on warm build, got $OUT_B2"

PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_B" "$PIONC" test --jobs 2 --json "$WS_B/pkg" > "$TMP_DIR/b_test1.json" 2>"$TMP_DIR/b_test1.trace"
grep -q "cstub=.*fetch\.c HIT key=" "$TMP_DIR/b_test1.trace" || fail "expected warm test cstub HIT"

# 3) Modify ../win_compat.h: 100 -> 200 with IDENTICAL byte length AND IDENTICAL mtime!
cp -p "$WS_B/native/win_compat.h" "$TMP_DIR/win_compat.ref"
cat > "$WS_B/native/win_compat.h" <<'EOF'
#define COMPAT_VAL 200
EOF
touch -r "$TMP_DIR/win_compat.ref" "$WS_B/native/win_compat.h"

# Verify size and mtime truly match
python3 - "$TMP_DIR/win_compat.ref" "$WS_B/native/win_compat.h" <<'PYEOF'
import os, sys
s1, s2 = os.stat(sys.argv[1]), os.stat(sys.argv[2])
assert s1.st_size == s2.st_size, f"size changed: {s1.st_size} vs {s2.st_size}"
assert int(s1.st_mtime) == int(s2.st_mtime), f"mtime changed: {s1.st_mtime} vs {s2.st_mtime}"
PYEOF

# Test with `pionc test --jobs 2` first (uses drv_compile_ws_c_sources_parallel)
cat > "$WS_B/pkg/src/pkg_test.pion" <<'EOF'
test "fetch_val_200" {
  debug_assert(get_val() == 200L, "expected 200 after ../win_compat.h edit")
}
EOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_B" "$PIONC" test --jobs 2 --json "$WS_B/pkg" > "$TMP_DIR/b_test2.json" 2>"$TMP_DIR/b_test2.trace"
grep -q "cstub=.*fetch\.c MISS key=" "$TMP_DIR/b_test2.trace" || fail "expected test cstub MISS after ../win_compat.h edit"
python3 - "$TMP_DIR/b_test2.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["passed"] == 1 and d["failed"] == 0, d
PYEOF

# Also verify `pionc build` picks up 200 (now HIT from test's published cstub, or fresh MISS in separate CAS)
CAS_B_BUILD="$TMP_DIR/cas_b_build"
mkdir -p "$CAS_B_BUILD"
cat > "$WS_B/native/win_compat.h" <<'EOF'
#define COMPAT_VAL 100
EOF
touch -r "$TMP_DIR/win_compat.ref" "$WS_B/native/win_compat.h"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_B_BUILD" "$PIONC" build -o "$TMP_DIR/b_bin_b1" "$WS_B/pkg" 2>/dev/null
[ "$("$TMP_DIR/b_bin_b1")" = "100" ] || fail "expected 100 in CAS_B_BUILD"

cat > "$WS_B/native/win_compat.h" <<'EOF'
#define COMPAT_VAL 200
EOF
touch -r "$TMP_DIR/win_compat.ref" "$WS_B/native/win_compat.h"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_B_BUILD" "$PIONC" build -o "$TMP_DIR/b_bin_b2" "$WS_B/pkg" 2>"$TMP_DIR/b_build3.trace"
grep -q "cstub=.*fetch\.c MISS key=" "$TMP_DIR/b_build3.trace" || fail "expected build cstub MISS after ../win_compat.h edit"
[ "$("$TMP_DIR/b_bin_b2")" = "200" ] || fail "expected 200 on build after ../win_compat.h edit"

# 4) Modify transitive header ext_inc/sub.h: 000 -> 100 (total 200+100=300), SAME byte length & SAME mtime!
cp -p "$WS_B/ext_inc/sub.h" "$TMP_DIR/sub.ref"
cat > "$WS_B/ext_inc/sub.h" <<'EOF'
#define SUB_VAL 100
EOF
touch -r "$TMP_DIR/sub.ref" "$WS_B/ext_inc/sub.h"

PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_B_BUILD" "$PIONC" build -o "$TMP_DIR/b_bin_b3" "$WS_B/pkg" 2>"$TMP_DIR/b_build4.trace"
grep -q "cstub=.*fetch\.c MISS key=" "$TMP_DIR/b_build4.trace" || fail "expected build cstub MISS after transitive sub.h edit"
[ "$("$TMP_DIR/b_bin_b3")" = "300" ] || fail "expected 300 on build after transitive sub.h edit"

cat > "$WS_B/pkg/src/pkg_test.pion" <<'EOF'
test "fetch_val_300" {
  debug_assert(get_val() == 300L, "expected 300 after transitive sub.h edit")
}
EOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_B" "$PIONC" test --jobs 2 --json "$WS_B/pkg" > "$TMP_DIR/b_test3.json" 2>"$TMP_DIR/b_test3.trace"
grep -q "cstub=.*fetch\.c MISS key=" "$TMP_DIR/b_test3.trace" || fail "expected test cstub MISS after transitive sub.h edit"
python3 - "$TMP_DIR/b_test3.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["passed"] == 1 and d["failed"] == 0, d
PYEOF

# 5) Compiler --version change invalidates cstub CAS key even when compiler path is identical!
REAL_CC_ABS="$(command -v "${CC:-cc}")"
MOCK_CC="$TMP_DIR/mock_cc.sh"
cat > "$MOCK_CC" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  echo "mockcc ${MOCK_CC_VER:-1.0}"
  exit 0
fi
exec "${REAL_CC_BIN}" "$@"
EOF
chmod +x "$MOCK_CC"

CAS_VER="$TMP_DIR/cas_ver"
mkdir -p "$CAS_VER"

REAL_CC_BIN="$REAL_CC_ABS" MOCK_CC_VER="1.0" CC="$MOCK_CC" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_VER" "$PIONC" build -o "$TMP_DIR/b_ver1" "$WS_B/pkg" 2>"$TMP_DIR/ver1.trace"
grep -q "cstub=.*fetch\.c MISS key=" "$TMP_DIR/ver1.trace" || fail "expected MISS for mockcc 1.0 cold"

REAL_CC_BIN="$REAL_CC_ABS" MOCK_CC_VER="1.0" CC="$MOCK_CC" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_VER" "$PIONC" build -o "$TMP_DIR/b_ver1_hot" "$WS_B/pkg" 2>"$TMP_DIR/ver1_hot.trace"
grep -q "cstub=.*fetch\.c HIT key=" "$TMP_DIR/ver1_hot.trace" || fail "expected HIT for mockcc 1.0 warm"

REAL_CC_BIN="$REAL_CC_ABS" MOCK_CC_VER="2.0" CC="$MOCK_CC" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_VER" "$PIONC" build -o "$TMP_DIR/b_ver2" "$WS_B/pkg" 2>"$TMP_DIR/ver2.trace"
grep -q "cstub=.*fetch\.c MISS key=" "$TMP_DIR/ver2.trace" || fail "expected MISS after mockcc --version changed 1.0 -> 2.0"

echo "(B) cstub Direct Mode (../, -I, transitive same-size/same-mtime, --version) -> OK"

# ============================================================================
# Scenario C (Round 367): Cross-runner mtime perturbation -> 0 MISS / 100% HIT
# ============================================================================
WS_C="$TMP_DIR/ws_mtime"
mkdir -p "$WS_C/dep/src" "$WS_C/dep/csrc" "$WS_C/app/src"

cat > "$WS_C/ext_obj.c" <<'EOF'
#include <stdint.h>
int64_t mtime_ext_lib_val(void) { return 42; }
EOF
"${CC:-cc}" -c "$WS_C/ext_obj.c" -o "$WS_C/ext_obj.o"
ar rcs "$WS_C/app/libext_mtime.a" "$WS_C/ext_obj.o"

cat > "$WS_C/pion.toml" <<'EOF'
[workspace]
members = ["dep", "app"]
EOF

cat > "$WS_C/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"

[link]
c_sources = ["csrc/dep.c"]
EOF
cat > "$WS_C/dep/csrc/dep.h" <<'EOF'
#define DEP_C_VAL 15
EOF
cat > "$WS_C/dep/csrc/dep.c" <<'EOF'
#include <stdint.h>
#include "dep.h"
int64_t mtime_dep_c_val(void) { return DEP_C_VAL; }
EOF
cat > "$WS_C/dep/src/lib.pion" <<'EOF'
extern "C" fn mtime_dep_c_val() -> Int64
pub fn dep_val() -> Int64 { mtime_dep_c_val() }
EOF
cat > "$WS_C/dep/src/dep_test.pion" <<'EOF'
test "dep_mtime_ok" { debug_assert(dep_val() == 15L, "dep_mtime_ok") }
EOF

cat > "$WS_C/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }

[link]
objects = ["libext_mtime.a"]
EOF
cat > "$WS_C/app/src/main.pion" <<'EOF'
import "dep"
extern "C" fn mtime_ext_lib_val() -> Int64

pub fn combined() -> Int64 { dep::dep_val() + mtime_ext_lib_val() }

fn main(world : World) -> Unit {
  io_println(world, "mtime_sum=" + combined().to_string())
}
EOF
cat > "$WS_C/app/src/app_test.pion" <<'EOF'
test "app_mtime_ok" { debug_assert(combined() == 57L, "app_mtime_ok") }
EOF

CAS_C="$TMP_DIR/cas_c"
mkdir -p "$CAS_C"

# Cold build & cold test populate CAS_C
PION_CACHE_DIR="$CAS_C" "$PIONC" build -o "$TMP_DIR/c_bin1" "$WS_C/app"
[ "$("$TMP_DIR/c_bin1")" = "mtime_sum=57" ] || fail "Scenario C cold build mismatch"
PION_CACHE_DIR="$CAS_C" "$PIONC" test --jobs 2 --json "$WS_C" > "$TMP_DIR/c_test1.json"
python3 - "$TMP_DIR/c_test1.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["total"] == 2 and d["passed"] == 2 and d["failed"] == 0, d
PYEOF

# Perturb mtime of EVERY file in workspace (sources, headers, external .a) AND
# EVERY file inside $CAS_C (simulating git checkout + actions/cache restore).
find "$WS_C" "$CAS_C" -type f -exec touch -t 202001010000 {} +

PION_CAS_TRACE=1 PION_TRACE_CAS=1 PION_CACHE_DIR="$CAS_C" \
  "$PIONC" build -o "$TMP_DIR/c_bin2" "$WS_C/app" 2>"$TMP_DIR/c_build_hot.trace"
[ "$("$TMP_DIR/c_bin2")" = "mtime_sum=57" ] || fail "Scenario C hot build mismatch"

PION_CAS_TRACE=1 PION_TRACE_CAS=1 PION_CACHE_DIR="$CAS_C" \
  "$PIONC" test --jobs 2 --json "$WS_C" > "$TMP_DIR/c_test2.json" 2>"$TMP_DIR/c_test_hot.trace"

python3 - "$TMP_DIR/c_test2.json" "$TMP_DIR/c_build_hot.trace" "$TMP_DIR/c_test_hot.trace" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["total"] == 2 and d["passed"] == 2 and d["failed"] == 0, d
for label, path in [("build", sys.argv[2]), ("test", sys.argv[3])]:
    txt = open(path).read()
    misses = [l for l in txt.splitlines() if " MISS " in l]
    hits = [l for l in txt.splitlines() if " HIT " in l]
    assert len(misses) == 0, f"expected 0 MISS after mtime perturbation in {label}, got: {misses}"
    assert len(hits) >= 2, f"expected >=2 HITs after mtime perturbation in {label}, got: {txt}"
PYEOF

echo "(C) cross-runner mtime perturbation (sources + headers + external .a + CAS) -> 0 MISS / 100% HIT OK"

# ============================================================================
# Scenario D (Round 2 #1): Cross-process kernel-locked pins & stale crash cleanup
# ============================================================================
CAS_D="$TMP_DIR/cas_d"
mkdir -p "$CAS_D/pins"

# Populate CAS_D with WS_C (dep + app)
PION_CACHE_DIR="$CAS_D" "$PIONC" test --jobs 2 --json "$WS_C" > /dev/null

# Pick one real CAS object key from CAS_D/obj/ to simulate an active peer holding it
PEER_OBJ_FILE="$(ls "$CAS_D/obj/"*.o | head -n 1)"
PEER_OBJ_KEY="$(basename "$PEER_OBJ_FILE" .o)"
[ -n "$PEER_OBJ_KEY" ] || fail "Scenario D: no .o found in CAS_D/obj"

# Create an unlocked stale pin (simulating a SIGKILLed process)
printf '%s\n' "$PEER_OBJ_KEY" > "$CAS_D/pins/stale_99999_0.pin"
: > "$CAS_D/pins/stale_99999_0.pin.lock"

# Hold an active flock on peer_live.pin.lock while Process B runs with PION_CACHE_MAX_KB=1
python3 - "$CAS_D" "$PEER_OBJ_KEY" "$PEER_OBJ_FILE" "$PIONC" "$WS_C" <<'PYEOF'
import fcntl, json, os, subprocess, sys

cas_dir, peer_key, peer_obj, pionc, ws_c = sys.argv[1:6]
live_lock = os.path.join(cas_dir, "pins", "live_peer_0.pin.lock")
live_data = os.path.join(cas_dir, "pins", "live_peer_0.pin")
stale_lock = os.path.join(cas_dir, "pins", "stale_99999_0.pin.lock")
stale_data = os.path.join(cas_dir, "pins", "stale_99999_0.pin")

with open(live_data, "w") as f:
    f.write(peer_key + "\n")

fd = os.open(live_lock, os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX)
    env = os.environ.copy()
    env["PION_CACHE_DIR"] = cas_dir
    env["PION_CACHE_MAX_KB"] = "1"
    proc = subprocess.run(
        [pionc, "test", "--jobs", "2", "--json", ws_c],
        env=env, capture_output=True, text=True, check=True,
    )
    d = json.loads(proc.stdout)
    assert d["ok"] is True and d["passed"] == 2 and d["failed"] == 0, d
    # Active peer's pinned object MUST survive post-run eviction!
    assert os.path.isfile(peer_obj), f"active peer pinned object was evicted: {peer_obj}"
    # Crashed peer's stale lock & data files MUST be auto-cleaned!
    assert not os.path.exists(stale_lock), "stale pin lock was not cleaned"
    assert not os.path.exists(stale_data), "stale pin data was not cleaned"
    # Explicit `pionc cache prune` under PION_CACHE_MAX_KB=1 MUST also respect active peer pins!
    prune_proc = subprocess.run(
        [pionc, "cache", "prune", "--json"],
        env=env, capture_output=True, text=True, check=True,
    )
    pd = json.loads(prune_proc.stdout)
    assert pd["ok"] is True and pd["action"] == "prune", pd
    assert os.path.isfile(peer_obj), f"cache prune evicted active peer pinned object: {peer_obj}"
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)

# Once peer releases its lock, the next run trims the cache and cleans live_peer_0.*
env = os.environ.copy()
env["PION_CACHE_DIR"] = cas_dir
env["PION_CACHE_MAX_KB"] = "1"
proc2 = subprocess.run(
    [pionc, "test", "--jobs", "2", "--json", ws_c],
    env=env, capture_output=True, text=True, check=True,
)
d2 = json.loads(proc2.stdout)
assert d2["ok"] is True and d2["passed"] == 2 and d2["failed"] == 0, d2
assert not os.path.exists(live_lock), "released peer pin lock was not cleaned"
assert not os.path.exists(live_data), "released peer pin data was not cleaned"

# Two real concurrent `pionc` processes sharing the same CAS_D under PION_CACHE_MAX_KB=1
out_p1 = os.path.join(os.path.dirname(cas_dir), "conc_bin_1")
out_p2 = os.path.join(os.path.dirname(cas_dir), "conc_bin_2")
p1 = subprocess.Popen(
    [pionc, "build", "-o", out_p1, os.path.join(ws_c, "app")],
    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
)
p2 = subprocess.Popen(
    [pionc, "test", "--jobs", "2", "--json", ws_c],
    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
)
o1, e1 = p1.communicate(timeout=120)
o2, e2 = p2.communicate(timeout=120)
assert p1.returncode == 0, f"concurrent build failed: {o1}\n{e1}"
assert p2.returncode == 0, f"concurrent test failed: {o2}\n{e2}"
d_conc = json.loads(o2)
assert d_conc["ok"] is True and d_conc["passed"] == 2 and d_conc["failed"] == 0, d_conc
r1 = subprocess.run([out_p1], capture_output=True, text=True, check=True)
assert r1.stdout.strip() == "mtime_sum=57", r1.stdout
PYEOF

echo "(D) cross-process kernel-locked CAS pin + cache prune + real concurrent pionc -> OK"

# ============================================================================
# Scenario E (Round 2 #2): Wasm32 build without `-o` under PION_CACHE_MAX_KB=1
# ============================================================================
WS_E="$TMP_DIR/ws_wasm_pin"
mkdir -p "$WS_E/lib_w/src" "$WS_E/app_w/src"
cat > "$WS_E/lib_w/pion.toml" <<'EOF'
[package]
name = "lib_w"
version = "0.1.0"
EOF
cat > "$WS_E/lib_w/src/lib.pion" <<'EOF'
pub fn answer() -> Int { 42 }
EOF
cat > "$WS_E/app_w/pion.toml" <<'EOF'
[package]
name = "app_w"
version = "0.1.0"

[dependencies]
lib_w = { path = "../lib_w" }
EOF
cat > "$WS_E/app_w/src/main.pion" <<'EOF'
import "lib_w"
fn main(world : World) -> Unit {
  io_println(world, "wasm_pin=" + lib_w::answer().to_string())
}
EOF

CAS_E="$TMP_DIR/cas_e"
mkdir -p "$CAS_E"
PION_TRACE_CAS=1 PION_CACHE_DIR="$CAS_E" PION_CACHE_MAX_KB=1 "$PIONC" build --target wasm32 "$WS_E/app_w" 2>"$TMP_DIR/e1.trace"
WASM_OUT1="$(ls "$CAS_E/bin/"wasm_*.wasm 2>/dev/null | head -n 1 || true)"
[ -n "$WASM_OUT1" ] && [ -s "$WASM_OUT1" ] || fail "Scenario E run 1 evicted or missed wasm binary in $CAS_E/bin"
PION_TRACE_CAS=1 PION_CACHE_DIR="$CAS_E" PION_CACHE_MAX_KB=1 "$PIONC" build --target wasm32 "$WS_E/app_w" 2>"$TMP_DIR/e2.trace"
WASM_OUT2="$(ls "$CAS_E/bin/"wasm_*.wasm 2>/dev/null | head -n 1 || true)"
[ -n "$WASM_OUT2" ] && [ -s "$WASM_OUT2" ] || fail "Scenario E run 2 evicted wasm binary in $CAS_E/bin"
grep -q "\[cas-wasm-bin\] HIT" "$TMP_DIR/e2.trace" || fail "Scenario E run 2 expected wasmbin HIT"
if command -v node >/dev/null 2>&1; then
  WASM_RUN="$(PION_TRACE_CAS=1 PION_CACHE_DIR="$CAS_E" PION_CACHE_MAX_KB=1 "$PIONC" run --target wasm32 "$WS_E/app_w" 2>"$TMP_DIR/e3.trace")"
  [ "$WASM_RUN" = "wasm_pin=42" ] || fail "Scenario E pionc run --target wasm32 output mismatch: $WASM_RUN"
  grep -q "\[cas-wasm-bin\] HIT" "$TMP_DIR/e3.trace" || fail "Scenario E pionc run expected wasmbin HIT"
fi
echo "(E) Wasm32 build/run without -o under PION_CACHE_MAX_KB=1 (keep_keys + HIT) -> OK"

# ============================================================================
# Scenario F (Round 2 #3 + Round 3/4): Same-size + same-mtime_ns external .a edit
# ============================================================================
cp -p "$WS_C/app/libext_mtime.a" "$TMP_DIR/libext_mtime.ref"
# Ensure hot default build & hot testbin exist in CAS_C before rewriting .a
PION_CACHE_DIR="$CAS_C" "$PIONC" build "$WS_C/app"
PION_CACHE_DIR="$CAS_C" "$PIONC" test --jobs 2 --json "$WS_C" > "$TMP_DIR/f_test_before.json"
python3 - "$TMP_DIR/f_test_before.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["passed"] == 2 and d["failed"] == 0, d
PYEOF
cat > "$WS_C/ext_obj.c" <<'EOF'
#include <stdint.h>
int64_t mtime_ext_lib_val(void) { return 99; }
EOF
"${CC:-cc}" -c "$WS_C/ext_obj.c" -o "$WS_C/ext_obj.o"
rm -f "$WS_C/app/libext_mtime.a"
ar rcs "$WS_C/app/libext_mtime.a" "$WS_C/ext_obj.o"
# Restore nanosecond-exact atime/mtime and verify BOTH st_size & st_mtime_ns match!
python3 - "$TMP_DIR/libext_mtime.ref" "$WS_C/app/libext_mtime.a" <<'PYEOF'
import os, sys
ref_p, cur_p = sys.argv[1], sys.argv[2]
s1 = os.stat(ref_p)
os.utime(cur_p, ns=(s1.st_atime_ns, s1.st_mtime_ns))
s2 = os.stat(cur_p)
assert s1.st_size == s2.st_size, f"expected identical .a size: {s1.st_size} vs {s2.st_size}"
assert s1.st_mtime_ns == s2.st_mtime_ns, f"expected identical .a mtime_ns: {s1.st_mtime_ns} vs {s2.st_mtime_ns}"
PYEOF
# Without touching ANY .pion test source, hot `pionc test` MUST relink testbin and
# fail `app_mtime_ok` (which asserts combined() == 57, now 114)!
if PION_CACHE_DIR="$CAS_C" "$PIONC" test --jobs 2 --json "$WS_C" > "$TMP_DIR/f_test_after.json"; then
  fail "Scenario F expected hot pionc test to relink and fail stale 57 expectation"
fi
python3 - "$TMP_DIR/f_test_after.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is False and d["passed"] == 1 and d["failed"] == 1, d
PYEOF
# Hot `pionc run` (default CAS bin key, not `-o`) MUST also relink and print 114
OUT_F="$(PION_CACHE_DIR="$CAS_C" "$PIONC" run "$WS_C/app")"
[ "$OUT_F" = "mtime_sum=114" ] || fail "Scenario F expected mtime_sum=114 from default CAS bin after same-size/same-mtime_ns .a edit, got $OUT_F"
echo "(F) external .a content edit with identical size & st_mtime_ns (untouched test) -> relink OK"

# ============================================================================
# Scenario G (Round 2 #5): -I shadowing, UTF-8 Chinese path, racy compile edit
# ============================================================================
# G1: -I search-order shadowing
WS_G="$TMP_DIR/ws_shadow"
mkdir -p "$WS_G/pkg/src" "$WS_G/inc_first" "$WS_G/inc_second"
cat > "$WS_G/inc_second/val.h" <<'EOF'
#define SHADOW_VAL 10
EOF
cat > "$WS_G/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "val.h"
int64_t shadow_val(void) { return SHADOW_VAL; }
EOF
cat > "$WS_G/pkg/pion.toml" <<'EOF'
[package]
name = "shadow_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
cc_flags = ["-I../inc_first", "-I../inc_second"]
EOF
cat > "$WS_G/pkg/src/main.pion" <<'EOF'
extern "C" fn shadow_val() -> Int64
fn main(world : World) -> Unit { io_println(world, shadow_val().to_string()) }
EOF
CAS_G="$TMP_DIR/cas_g"
mkdir -p "$CAS_G"
PION_CACHE_DIR="$CAS_G" "$PIONC" build -o "$TMP_DIR/g1_bin1" "$WS_G/pkg"
[ "$("$TMP_DIR/g1_bin1")" = "10" ] || fail "Scenario G1 cold expected 10"
# Add shadowing header in higher-priority -I../inc_first
cat > "$WS_G/inc_first/val.h" <<'EOF'
#define SHADOW_VAL 99
EOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_G" "$PIONC" build -o "$TMP_DIR/g1_bin2" "$WS_G/pkg" 2>"$TMP_DIR/g1_shadow.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/g1_shadow.trace" || fail "Scenario G1 expected MISS when higher-priority -I shadows header"
[ "$("$TMP_DIR/g1_bin2")" = "99" ] || fail "Scenario G1 expected 99 after -I shadowing"

# G2: UTF-8 Chinese directory & header path
WS_U8="$TMP_DIR/中文目录"
mkdir -p "$WS_U8/pkg/src" "$WS_U8/头文件"
cat > "$WS_U8/头文件/配置.h" <<'EOF'
#define U8_VAL 101
EOF
cat > "$WS_U8/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "配置.h"
int64_t u8_val(void) { return U8_VAL; }
EOF
cat > "$WS_U8/pkg/pion.toml" <<'EOF'
[package]
name = "u8_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
cc_flags = ["-I../头文件"]
EOF
cat > "$WS_U8/pkg/src/main.pion" <<'EOF'
extern "C" fn u8_val() -> Int64
fn main(world : World) -> Unit { io_println(world, u8_val().to_string()) }
EOF
CAS_U8="$TMP_DIR/cas_u8"
mkdir -p "$CAS_U8"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_U8" "$PIONC" build -o "$TMP_DIR/u8_bin1" "$WS_U8/pkg" 2>"$TMP_DIR/u8_1.trace"
[ "$("$TMP_DIR/u8_bin1")" = "101" ] || fail "Scenario G2 cold expected 101"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_U8" "$PIONC" build -o "$TMP_DIR/u8_bin2" "$WS_U8/pkg" 2>"$TMP_DIR/u8_2.trace"
grep -q "cstub=.*stub\.c HIT key=" "$TMP_DIR/u8_2.trace" || fail "Scenario G2 expected warm HIT on UTF-8 path"
cp -p "$WS_U8/头文件/配置.h" "$TMP_DIR/u8.ref"
cat > "$WS_U8/头文件/配置.h" <<'EOF'
#define U8_VAL 202
EOF
touch -r "$TMP_DIR/u8.ref" "$WS_U8/头文件/配置.h"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_U8" "$PIONC" build -o "$TMP_DIR/u8_bin3" "$WS_U8/pkg" 2>"$TMP_DIR/u8_3.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/u8_3.trace" || fail "Scenario G2 expected MISS after UTF-8 header edit"
[ "$("$TMP_DIR/u8_bin3")" = "202" ] || fail "Scenario G2 expected 202 after UTF-8 header edit"

# G3: Racy compile-time header edit must NOT poison .deps manifest permanently
WS_RACY="$TMP_DIR/ws_racy"
mkdir -p "$WS_RACY/pkg/src"
cat > "$WS_RACY/pkg/racy.h" <<'EOF'
#define RACY_VAL 10
EOF
cat > "$WS_RACY/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "racy.h"
int64_t racy_val(void) { return RACY_VAL; }
EOF
cat > "$WS_RACY/pkg/pion.toml" <<'EOF'
[package]
name = "racy_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
EOF
cat > "$WS_RACY/pkg/src/main.pion" <<'EOF'
extern "C" fn racy_val() -> Int64
fn main(world : World) -> Unit { io_println(world, racy_val().to_string()) }
EOF

RACY_CC="$TMP_DIR/racy_cc.sh"
cat > "$RACY_CC" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  exec "${REAL_CC_BIN}" --version
fi
"${REAL_CC_BIN}" "$@"
RC=$?
if [ "$RC" = "0" ] && [ "${INJECT_RACE:-0}" = "1" ]; then
  case "$*" in
    *-c*stub.c*)
      printf '#define RACY_VAL 20\n' > "${RACY_HDR}"
      ;;
  esac
fi
exit "$RC"
EOF
chmod +x "$RACY_CC"

CAS_RACY="$TMP_DIR/cas_racy"
mkdir -p "$CAS_RACY"
REAL_CC_BIN="$REAL_CC_ABS" INJECT_RACE=1 RACY_HDR="$WS_RACY/pkg/racy.h" CC="$RACY_CC" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_RACY" "$PIONC" build -o "$TMP_DIR/racy_bin1" "$WS_RACY/pkg" 2>"$TMP_DIR/racy1.trace"
[ "$("$TMP_DIR/racy_bin1")" = "10" ] || fail "Scenario G3 racy run 1 expected 10"
grep -q "cstub=.*stub\.c MISS key=.*(local: racy_" "$TMP_DIR/racy1.trace" || fail "Scenario G3 expected (local: racy_*) on racy run 1: $(cat "$TMP_DIR/racy1.trace")"
RACY_CSTUB_OBJS="$(find "$CAS_RACY/obj" -maxdepth 1 -name 'cstub_*.o' 2>/dev/null | wc -l | tr -d ' ')"
[ "$RACY_CSTUB_OBJS" = "0" ] || fail "Scenario G3 racy run 1 must NOT publish any cstub_*.o into CAS/obj (found $RACY_CSTUB_OBJS)"
# Next run (no race) MUST MISS and pick up 20 because run 1 refused to publish racy .deps!
REAL_CC_BIN="$REAL_CC_ABS" INJECT_RACE=0 RACY_HDR="$WS_RACY/pkg/racy.h" CC="$RACY_CC" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_RACY" "$PIONC" build -o "$TMP_DIR/racy_bin2" "$WS_RACY/pkg" 2>"$TMP_DIR/racy2.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/racy2.trace" || fail "Scenario G3 expected MISS after racy compile"
[ "$("$TMP_DIR/racy_bin2")" = "20" ] || fail "Scenario G3 expected 20 after racy compile self-healed"

echo "(G) -I shadowing + UTF-8 Chinese path + racy compile-time edit self-heal -> OK"

# ============================================================================
# Scenario H (Round 3): Nested `-I dir -I dir/sub` header shadowing
# ============================================================================
WS_H="$TMP_DIR/ws_nested_shadow"
mkdir -p "$WS_H/pkg/src" "$WS_H/inc/sub"
cat > "$WS_H/inc/sub/nested.h" <<'EOF'
#define NESTED_VAL 11
EOF
cat > "$WS_H/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "nested.h"
int64_t nested_val(void) { return NESTED_VAL; }
EOF
cat > "$WS_H/pkg/pion.toml" <<'EOF'
[package]
name = "nested_shadow_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
cc_flags = ["-I../inc", "-I../inc/sub"]
EOF
cat > "$WS_H/pkg/src/main.pion" <<'EOF'
extern "C" fn nested_val() -> Int64
fn main(world : World) -> Unit { io_println(world, nested_val().to_string()) }
EOF
CAS_H="$TMP_DIR/cas_h"
mkdir -p "$CAS_H"
PION_CACHE_DIR="$CAS_H" "$PIONC" build -o "$TMP_DIR/h_bin1" "$WS_H/pkg"
[ "$("$TMP_DIR/h_bin1")" = "11" ] || fail "Scenario H cold expected 11"
# Introduce shadowing header at higher-priority parent `-I../inc/nested.h`
cat > "$WS_H/inc/nested.h" <<'EOF'
#define NESTED_VAL 88
EOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_H" "$PIONC" build -o "$TMP_DIR/h_bin2" "$WS_H/pkg" 2>"$TMP_DIR/h_shadow.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/h_shadow.trace" || fail "Scenario H expected MISS on nested -I shadowing"
[ "$("$TMP_DIR/h_bin2")" = "88" ] || fail "Scenario H expected 88 after nested -I shadowing"
echo "(H) nested -I dir -I dir/sub header shadowing -> OK"

# ============================================================================
# Scenario I (Round 3): Header symlink retargeting (inc/h.h -> v1.h => v2.h)
# ============================================================================
WS_I="$TMP_DIR/ws_sym_hdr"
mkdir -p "$WS_I/pkg/src" "$WS_I/inc" "$WS_I/vers"
cat > "$WS_I/vers/v1.h" <<'EOF'
#define SYM_VAL 31
EOF
cat > "$WS_I/vers/v2.h" <<'EOF'
#define SYM_VAL 62
EOF
ln -s "$WS_I/vers/v1.h" "$WS_I/inc/h.h"
cat > "$WS_I/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "h.h"
int64_t sym_val(void) { return SYM_VAL; }
EOF
cat > "$WS_I/pkg/pion.toml" <<'EOF'
[package]
name = "sym_hdr_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
cc_flags = ["-I../inc"]
EOF
cat > "$WS_I/pkg/src/main.pion" <<'EOF'
extern "C" fn sym_val() -> Int64
fn main(world : World) -> Unit { io_println(world, sym_val().to_string()) }
EOF
CAS_I="$TMP_DIR/cas_i"
mkdir -p "$CAS_I"
PION_CACHE_DIR="$CAS_I" "$PIONC" build -o "$TMP_DIR/i_bin1" "$WS_I/pkg"
[ "$("$TMP_DIR/i_bin1")" = "31" ] || fail "Scenario I cold expected 31"
# Retarget symlink inc/h.h -> v2.h while keeping v1.h completely untouched
ln -sfn "$WS_I/vers/v2.h" "$WS_I/inc/h.h"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_I" "$PIONC" build -o "$TMP_DIR/i_bin2" "$WS_I/pkg" 2>"$TMP_DIR/i_sym.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/i_sym.trace" || fail "Scenario I expected MISS after header symlink retarget"
[ "$("$TMP_DIR/i_bin2")" = "62" ] || fail "Scenario I expected 62 after header symlink retarget"
echo "(I) header symlink retargeting (v1.h intact) -> OK"

# ============================================================================
# Scenario J (Round 3): Preserved-mtime atomic rename of header during compile
# ============================================================================
WS_J="$TMP_DIR/ws_racy_rename"
mkdir -p "$WS_J/pkg/src"
cat > "$WS_J/pkg/hdr.h" <<'EOF'
#define RENAME_VAL 100
EOF
touch -t 202001010000 "$WS_J/pkg/hdr.h"
cat > "$WS_J/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "hdr.h"
int64_t rename_val(void) { return RENAME_VAL; }
EOF
cat > "$WS_J/pkg/pion.toml" <<'EOF'
[package]
name = "racy_rename_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
EOF
cat > "$WS_J/pkg/src/main.pion" <<'EOF'
extern "C" fn rename_val() -> Int64
fn main(world : World) -> Unit { io_println(world, rename_val().to_string()) }
EOF

RACY_RENAME_CC="$TMP_DIR/racy_rename_cc.sh"
cat > "$RACY_RENAME_CC" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  exec "${REAL_CC_BIN}" --version
fi
"${REAL_CC_BIN}" "$@"
RC=$?
if [ "$RC" = "0" ] && [ "${INJECT_RENAME:-0}" = "1" ]; then
  case "$*" in
    *-c*stub.c*)
      TMP_H="${RENAME_HDR}.new"
      printf '#define RENAME_VAL 200\n' > "$TMP_H"
      touch -r "${RENAME_HDR}" "$TMP_H"
      mv -f "$TMP_H" "${RENAME_HDR}"
      ;;
  esac
fi
exit "$RC"
EOF
chmod +x "$RACY_RENAME_CC"

CAS_J="$TMP_DIR/cas_j"
mkdir -p "$CAS_J"
REAL_CC_BIN="$REAL_CC_ABS" INJECT_RENAME=1 RENAME_HDR="$WS_J/pkg/hdr.h" CC="$RACY_RENAME_CC" \
  PION_CACHE_DIR="$CAS_J" "$PIONC" build -o "$TMP_DIR/j_bin1" "$WS_J/pkg"
[ "$("$TMP_DIR/j_bin1")" = "100" ] || fail "Scenario J run 1 expected 100"
# Next run (no race) MUST MISS and pick up 200 because ctime + parent dir changed!
REAL_CC_BIN="$REAL_CC_ABS" INJECT_RENAME=0 RENAME_HDR="$WS_J/pkg/hdr.h" CC="$RACY_RENAME_CC" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_J" "$PIONC" build -o "$TMP_DIR/j_bin2" "$WS_J/pkg" 2>"$TMP_DIR/j2.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/j2.trace" || fail "Scenario J expected MISS after preserved-mtime atomic rename"
[ "$("$TMP_DIR/j_bin2")" = "200" ] || fail "Scenario J expected 200 after preserved-mtime atomic rename"
echo "(J) preserved-mtime atomic header rename during compile -> ctime/dir guard self-heal OK"

# ============================================================================
# Scenario K (Round 4): Transitive header parent shadowing, truncated .deps,
#                       and symlinked directory + `..` retargeting
# ============================================================================
# K1: Transitive header `a/a.h` includes `"b.h"` hitting `inc/b.h`; adding `a/b.h` shadows it
WS_K1="$TMP_DIR/ws_k1"
mkdir -p "$WS_K1/pkg/src" "$WS_K1/a" "$WS_K1/inc"
cat > "$WS_K1/inc/b.h" <<'EOF'
#define K1_VAL 17
EOF
cat > "$WS_K1/a/a.h" <<'EOF'
#include "b.h"
EOF
cat > "$WS_K1/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "../a/a.h"
int64_t k1_val(void) { return K1_VAL; }
EOF
cat > "$WS_K1/pkg/pion.toml" <<'EOF'
[package]
name = "k1_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
cc_flags = ["-I../inc"]
EOF
cat > "$WS_K1/pkg/src/main.pion" <<'EOF'
extern "C" fn k1_val() -> Int64
fn main(world : World) -> Unit { io_println(world, k1_val().to_string()) }
EOF
CAS_K1="$TMP_DIR/cas_k1"
mkdir -p "$CAS_K1"
PION_CACHE_DIR="$CAS_K1" "$PIONC" build -o "$TMP_DIR/k1_bin1" "$WS_K1/pkg"
[ "$("$TMP_DIR/k1_bin1")" = "17" ] || fail "Scenario K1 cold expected 17"
# K2: Truncate the .deps manifest -> MUST MISS and self-heal!
DEPS_FILE="$(ls "$CAS_K1/obj/"cstub_dep_*.deps | head -n 1)"
[ -n "$DEPS_FILE" ] || fail "Scenario K2 expected .deps file in $CAS_K1/obj"
python3 - "$DEPS_FILE" <<'PYEOF'
import sys
p = sys.argv[1]
txt = open(p).read()
# Drop the trailing sha256 line
lines = txt.splitlines()
assert lines[0] == "v3" and lines[-1].startswith("sha256:"), lines
open(p, "w").write("\n".join(lines[:-1]) + "\n")
PYEOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_K1" "$PIONC" build -o "$TMP_DIR/k2_bin" "$WS_K1/pkg" 2>"$TMP_DIR/k2.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/k2.trace" || fail "Scenario K2 expected MISS on truncated .deps manifest"
[ "$("$TMP_DIR/k2_bin")" = "17" ] || fail "Scenario K2 expected 17 after self-heal"
# Now introduce sibling `a/b.h` shadowing `inc/b.h` for `a/a.h`
cat > "$WS_K1/a/b.h" <<'EOF'
#define K1_VAL 71
EOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_K1" "$PIONC" build -o "$TMP_DIR/k1_bin2" "$WS_K1/pkg" 2>"$TMP_DIR/k1.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/k1.trace" || fail "Scenario K1 expected MISS on transitive parent-dir shadowing"
[ "$("$TMP_DIR/k1_bin2")" = "71" ] || fail "Scenario K1 expected 71 after transitive parent-dir shadowing"

# K3: Header reached via symlinked directory + `..` (`sym_dir -> d1/sub`, `sym_dir/../target.h`)
WS_K3="$TMP_DIR/ws_k3"
mkdir -p "$WS_K3/pkg/src" "$WS_K3/d1/sub" "$WS_K3/d2/sub"
cat > "$WS_K3/d1/target.h" <<'EOF'
#define K3_VAL 101
EOF
cat > "$WS_K3/d2/target.h" <<'EOF'
#define K3_VAL 202
EOF
ln -s "$WS_K3/d1/sub" "$WS_K3/pkg/sym_dir"
cat > "$WS_K3/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "sym_dir/../target.h"
int64_t k3_val(void) { return K3_VAL; }
EOF
cat > "$WS_K3/pkg/pion.toml" <<'EOF'
[package]
name = "k3_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
EOF
cat > "$WS_K3/pkg/src/main.pion" <<'EOF'
extern "C" fn k3_val() -> Int64
fn main(world : World) -> Unit { io_println(world, k3_val().to_string()) }
EOF
CAS_K3="$TMP_DIR/cas_k3"
mkdir -p "$CAS_K3"
PION_CACHE_DIR="$CAS_K3" "$PIONC" build -o "$TMP_DIR/k3_bin1" "$WS_K3/pkg"
[ "$("$TMP_DIR/k3_bin1")" = "101" ] || fail "Scenario K3 cold expected 101"
# Retarget sym_dir -> d2/sub while d1/target.h remains untouched
ln -sfn "$WS_K3/d2/sub" "$WS_K3/pkg/sym_dir"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_K3" "$PIONC" build -o "$TMP_DIR/k3_bin2" "$WS_K3/pkg" 2>"$TMP_DIR/k3.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/k3.trace" || fail "Scenario K3 expected MISS after symlink-dir + .. retarget"
[ "$("$TMP_DIR/k3_bin2")" = "202" ] || fail "Scenario K3 expected 202 after symlink-dir + .. retarget"
echo "(K) transitive parent shadowing + truncated v3 .deps + symlink-dir/.. retarget -> OK"

# ============================================================================
# Scenario L (Round 5): Pre-existing dual headers (#include_next) -> 100% HIT,
#   quoted external/system header shadowed by new sibling -> MISS,
#   intermediate directory symlink swap with preserved old mtime -> self-heal
# ============================================================================
# L1 (Opus R4): Two non-/usr dirs with same-named header both included via #include_next
WS_L1="$TMP_DIR/ws_l1"
mkdir -p "$WS_L1/pkg/src" "$WS_L1/inc_a" "$WS_L1/inc_b"
cat > "$WS_L1/inc_b/dual.h" <<'EOF'
#define DUAL_B 30
EOF
cat > "$WS_L1/inc_a/dual.h" <<'EOF'
#include_next "dual.h"
#define DUAL_A (DUAL_B + 12)
EOF
cat > "$WS_L1/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "dual.h"
int64_t l1_val(void) { return DUAL_A; }
EOF
cat > "$WS_L1/pkg/pion.toml" <<'EOF'
[package]
name = "l1_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
cc_flags = ["-I../inc_a", "-I../inc_b"]
EOF
cat > "$WS_L1/pkg/src/main.pion" <<'EOF'
extern "C" fn l1_val() -> Int64
fn main(world : World) -> Unit { io_println(world, l1_val().to_string()) }
EOF
CAS_L1="$TMP_DIR/cas_l1"
mkdir -p "$CAS_L1"
PION_CACHE_DIR="$CAS_L1" "$PIONC" build -o "$TMP_DIR/l1_bin1" "$WS_L1/pkg"
[ "$("$TMP_DIR/l1_bin1")" = "42" ] || fail "Scenario L1 cold expected 42"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_L1" "$PIONC" build -o "$TMP_DIR/l1_bin2" "$WS_L1/pkg" 2>"$TMP_DIR/l1_hot.trace"
grep -q "cstub=.*stub\.c HIT key=" "$TMP_DIR/l1_hot.trace" || fail "Scenario L1 expected warm HIT on pre-existing dual headers (#include_next)"
[ "$("$TMP_DIR/l1_bin2")" = "42" ] || fail "Scenario L1 warm expected 42"

# L2 (Astra #3): Nested project header quotes external/system header, then sibling added
WS_L2="$TMP_DIR/ws_l2"
mkdir -p "$WS_L2/pkg/src" "$WS_L2/sub" "$WS_L2/ext_sdk/include"
cat > "$WS_L2/ext_sdk/include/ext_sys.h" <<'EOF'
#define EXT_SYS_VAL 50
EOF
cat > "$WS_L2/sub/a.h" <<'EOF'
#include "ext_sys.h"
EOF
cat > "$WS_L2/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "../sub/a.h"
int64_t l2_val(void) { return EXT_SYS_VAL; }
EOF
cat > "$WS_L2/pkg/pion.toml" <<EOF
[package]
name = "l2_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
cc_flags = ["-isystem", "$WS_L2/ext_sdk/include"]
EOF
cat > "$WS_L2/pkg/src/main.pion" <<'EOF'
extern "C" fn l2_val() -> Int64
fn main(world : World) -> Unit { io_println(world, l2_val().to_string()) }
EOF
CAS_L2="$TMP_DIR/cas_l2"
mkdir -p "$CAS_L2"
PION_CACHE_DIR="$CAS_L2" "$PIONC" build -o "$TMP_DIR/l2_bin1" "$WS_L2/pkg"
[ "$("$TMP_DIR/l2_bin1")" = "50" ] || fail "Scenario L2 cold expected 50"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_L2" "$PIONC" build -o "$TMP_DIR/l2_bin2" "$WS_L2/pkg" 2>"$TMP_DIR/l2_hot.trace"
grep -q "cstub=.*stub\.c HIT key=" "$TMP_DIR/l2_hot.trace" || fail "Scenario L2 expected warm HIT before shadowing"
# Now add sibling `sub/ext_sys.h` shadowing the -isystem header for `sub/a.h`
cat > "$WS_L2/sub/ext_sys.h" <<'EOF'
#define EXT_SYS_VAL 95
EOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_L2" "$PIONC" build -o "$TMP_DIR/l2_bin3" "$WS_L2/pkg" 2>"$TMP_DIR/l2_miss.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/l2_miss.trace" || fail "Scenario L2 expected MISS when sibling shadows external/system header"
[ "$("$TMP_DIR/l2_bin3")" = "95" ] || fail "Scenario L2 expected 95 after sibling shadow"

# L3 (Astra #2): Intermediate directory symlink swap during compile with preserved old mtime
WS_L3="$TMP_DIR/ws_l3"
mkdir -p "$WS_L3/pkg/src" "$WS_L3/dir_v1" "$WS_L3/dir_v2"
cat > "$WS_L3/dir_v1/hdr.h" <<'EOF'
#define L3_VAL 111
EOF
cat > "$WS_L3/dir_v2/hdr.h" <<'EOF'
#define L3_VAL 222
EOF
touch -t 202001010000 "$WS_L3/dir_v1/hdr.h" "$WS_L3/dir_v2/hdr.h" "$WS_L3/dir_v1" "$WS_L3/dir_v2"
ln -s "$WS_L3/dir_v1" "$WS_L3/pkg/inc_link"
cat > "$WS_L3/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "inc_link/hdr.h"
int64_t l3_val(void) { return L3_VAL; }
EOF
cat > "$WS_L3/pkg/pion.toml" <<'EOF'
[package]
name = "l3_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
EOF
cat > "$WS_L3/pkg/src/main.pion" <<'EOF'
extern "C" fn l3_val() -> Int64
fn main(world : World) -> Unit { io_println(world, l3_val().to_string()) }
EOF

RACY_SYMLINK_CC="$TMP_DIR/racy_symlink_cc.sh"
cat > "$RACY_SYMLINK_CC" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  exec "${REAL_CC_BIN}" --version
fi
"${REAL_CC_BIN}" "$@"
RC=$?
if [ "$RC" = "0" ] && [ "${INJECT_SWAP:-0}" = "1" ]; then
  case "$*" in
    *-c*stub.c*)
      ln -sfn "${SWAP_TARGET}" "${SWAP_LINK}"
      ;;
  esac
fi
exit "$RC"
EOF
chmod +x "$RACY_SYMLINK_CC"

CAS_L3="$TMP_DIR/cas_l3"
mkdir -p "$CAS_L3"
REAL_CC_BIN="$REAL_CC_ABS" INJECT_SWAP=1 SWAP_LINK="$WS_L3/pkg/inc_link" SWAP_TARGET="$WS_L3/dir_v2" CC="$RACY_SYMLINK_CC" \
  PION_CACHE_DIR="$CAS_L3" "$PIONC" build -o "$TMP_DIR/l3_bin1" "$WS_L3/pkg"
[ "$("$TMP_DIR/l3_bin1")" = "111" ] || fail "Scenario L3 run 1 expected 111"
# Next run (no race) MUST MISS and pick up 222 because ancestor symlink swap was caught!
REAL_CC_BIN="$REAL_CC_ABS" INJECT_SWAP=0 SWAP_LINK="$WS_L3/pkg/inc_link" SWAP_TARGET="$WS_L3/dir_v2" CC="$RACY_SYMLINK_CC" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_L3" "$PIONC" build -o "$TMP_DIR/l3_bin2" "$WS_L3/pkg" 2>"$TMP_DIR/l3_2.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/l3_2.trace" || fail "Scenario L3 expected MISS after intermediate dir symlink swap"
[ "$("$TMP_DIR/l3_bin2")" = "222" ] || fail "Scenario L3 expected 222 after intermediate dir symlink swap"

echo "(L) dual-header #include_next HIT + external sibling shadow + intermediate symlink swap self-heal -> OK"

# ============================================================================
# Scenario M (Round 6): single-file no-main .o survives post-run,
#   -isystem SDK -I gen compiler search order, and 2-hop symlink chain swap
# ============================================================================
# M1: Single-file library (no fn main) without -o under PION_CACHE_MAX_KB=1 -> .o survives
cat > "$TMP_DIR/nomain_lib.pion" <<'EOF'
pub fn add_one(x : Int) -> Int { x + 1 }
EOF
CAS_M1="$TMP_DIR/cas_m1"
mkdir -p "$CAS_M1"
PION_CACHE_DIR="$CAS_M1" PION_CACHE_MAX_KB=1 "$PIONC" build "$TMP_DIR/nomain_lib.pion"
M1_OBJ="$(ls "$CAS_M1/obj/"*.o 2>/dev/null | head -n 1 || true)"
[ -n "$M1_OBJ" ] && [ -s "$M1_OBJ" ] && [ -r "$M1_OBJ" ] || fail "Scenario M1 expected readable non-empty .o after single-file no-main build"

# M2: `-isystem SDK -I gen` (flag order puts -isystem first, but compiler searches -I first!)
WS_M2="$TMP_DIR/ws_m2"
mkdir -p "$WS_M2/pkg/src" "$WS_M2/sdk" "$WS_M2/gen"
cat > "$WS_M2/sdk/cfg.h" <<'EOF'
#define M2_VAL 10
EOF
cat > "$WS_M2/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "cfg.h"
int64_t m2_val(void) { return M2_VAL; }
EOF
cat > "$WS_M2/pkg/pion.toml" <<EOF
[package]
name = "m2_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
cc_flags = ["-isystem", "$WS_M2/sdk", "-I../gen"]
EOF
cat > "$WS_M2/pkg/src/main.pion" <<'EOF'
extern "C" fn m2_val() -> Int64
fn main(world : World) -> Unit { io_println(world, m2_val().to_string()) }
EOF
CAS_M2="$TMP_DIR/cas_m2"
mkdir -p "$CAS_M2"
PION_CACHE_DIR="$CAS_M2" "$PIONC" build -o "$TMP_DIR/m2_bin1" "$WS_M2/pkg"
[ "$("$TMP_DIR/m2_bin1")" = "10" ] || fail "Scenario M2 cold expected 10"
# Add gen/cfg.h which outranks -isystem sdk despite appearing later on argv!
cat > "$WS_M2/gen/cfg.h" <<'EOF'
#define M2_VAL 77
EOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_M2" "$PIONC" build -o "$TMP_DIR/m2_bin2" "$WS_M2/pkg" 2>"$TMP_DIR/m2.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/m2.trace" || fail "Scenario M2 expected MISS when -I gen shadows earlier -isystem sdk"
[ "$("$TMP_DIR/m2_bin2")" = "77" ] || fail "Scenario M2 expected 77 after -I gen shadowed -isystem sdk"

# M3: 2-hop directory symlink chain (`proj_link -> sdk_sel -> dir_v1`), swap mid-hop `sdk_sel -> dir_v2`
WS_M3="$TMP_DIR/ws_m3"
mkdir -p "$WS_M3/pkg/src" "$WS_M3/dir_v1" "$WS_M3/dir_v2"
cat > "$WS_M3/dir_v1/hdr.h" <<'EOF'
#define M3_VAL 123
EOF
cat > "$WS_M3/dir_v2/hdr.h" <<'EOF'
#define M3_VAL 456
EOF
touch -t 202001010000 "$WS_M3/dir_v1/hdr.h" "$WS_M3/dir_v2/hdr.h" "$WS_M3/dir_v1" "$WS_M3/dir_v2"
ln -s "$WS_M3/dir_v1" "$WS_M3/sdk_sel"
ln -s "$WS_M3/sdk_sel" "$WS_M3/pkg/proj_link"
cat > "$WS_M3/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include "proj_link/hdr.h"
int64_t m3_val(void) { return M3_VAL; }
EOF
cat > "$WS_M3/pkg/pion.toml" <<'EOF'
[package]
name = "m3_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
EOF
cat > "$WS_M3/pkg/src/main.pion" <<'EOF'
extern "C" fn m3_val() -> Int64
fn main(world : World) -> Unit { io_println(world, m3_val().to_string()) }
EOF
CAS_M3="$TMP_DIR/cas_m3"
mkdir -p "$CAS_M3"
REAL_CC_BIN="$REAL_CC_ABS" INJECT_SWAP=1 SWAP_LINK="$WS_M3/sdk_sel" SWAP_TARGET="$WS_M3/dir_v2" CC="$RACY_SYMLINK_CC" \
  PION_CACHE_DIR="$CAS_M3" "$PIONC" build -o "$TMP_DIR/m3_bin1" "$WS_M3/pkg"
[ "$("$TMP_DIR/m3_bin1")" = "123" ] || fail "Scenario M3 run 1 expected 123"
REAL_CC_BIN="$REAL_CC_ABS" INJECT_SWAP=0 SWAP_LINK="$WS_M3/sdk_sel" SWAP_TARGET="$WS_M3/dir_v2" CC="$RACY_SYMLINK_CC" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_M3" "$PIONC" build -o "$TMP_DIR/m3_bin2" "$WS_M3/pkg" 2>"$TMP_DIR/m3_2.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/m3_2.trace" || fail "Scenario M3 expected MISS after mid-hop symlink swap"
[ "$("$TMP_DIR/m3_bin2")" = "456" ] || fail "Scenario M3 expected 456 after mid-hop symlink swap"

echo "(M) single-file no-main .o + -isystem/-I order + 2-hop symlink swap -> OK"

# M4 (macOS $TMPDIR parallel mktemp regression): mutating $TMPDIR with sibling
# temp dirs during compile must NOT trigger false-positive racy-skip of .deps!
CUSTOM_TMP="$TMP_DIR/custom_tmpdir"
WS_M4="$CUSTOM_TMP/ws_m4"
mkdir -p "$WS_M4/pkg/src"
cat > "$WS_M4/pkg/stub.c" <<'EOF'
#include <stdint.h>
int64_t m4_val(void) { return 88; }
EOF
cat > "$WS_M4/pkg/pion.toml" <<'EOF'
[package]
name = "m4_pkg"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
EOF
cat > "$WS_M4/pkg/src/main.pion" <<'EOF'
extern "C" fn m4_val() -> Int64
fn main(world : World) -> Unit { io_println(world, m4_val().to_string()) }
EOF
SIBLING_TMP_CC="$TMP_DIR/sibling_tmp_cc.sh"
cat > "$SIBLING_TMP_CC" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  exec "${REAL_CC_BIN}" --version
fi
if [ "${TOUCH_TMPDIR:-0}" = "1" ]; then
  mkdir -p "${TMPDIR}/unrelated_peer_tmp_$$"
fi
exec "${REAL_CC_BIN}" "$@"
EOF
chmod +x "$SIBLING_TMP_CC"
CAS_M4="$TMP_DIR/cas_m4"
mkdir -p "$CAS_M4"
TMPDIR="$CUSTOM_TMP" REAL_CC_BIN="$REAL_CC_ABS" TOUCH_TMPDIR=1 CC="$SIBLING_TMP_CC" \
  PION_CACHE_DIR="$CAS_M4" "$PIONC" build -o "$TMP_DIR/m4_bin1" "$WS_M4/pkg"
[ "$("$TMP_DIR/m4_bin1")" = "88" ] || fail "Scenario M4 cold expected 88"
TMPDIR="$CUSTOM_TMP" REAL_CC_BIN="$REAL_CC_ABS" TOUCH_TMPDIR=0 CC="$SIBLING_TMP_CC" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_M4" "$PIONC" build -o "$TMP_DIR/m4_bin2" "$WS_M4/pkg" 2>"$TMP_DIR/m4_hot.trace"
grep -q "cstub=.*stub\.c HIT key=" "$TMP_DIR/m4_hot.trace" || fail "Scenario M4 expected warm HIT despite sibling creation in TMPDIR"
echo "(M4) active sibling creation in \$TMPDIR does not trigger false racy-skip -> OK"

# M5 (Windows MSVC / cross-compile rt_lib inside $PION_CACHE_DIR/obj/ regression):
# When PION_RT_LIB resides in $PION_CACHE_DIR/obj/, drv_cstub_rt_inc_dirs MUST NOT
# add $PION_CACHE_DIR/obj as an -I search_dir (otherwise creating cstub_stage_* inside
# $PION_CACHE_DIR/obj makes it racy, causing 100% warm MISS and obj/ bloat).
CAS_M5="$TMP_DIR/cas_m5"
mkdir -p "$CAS_M5/obj"
RT_LIB_SRC="${PION_RT_LIB:-}"
if [ -z "$RT_LIB_SRC" ] || [ ! -f "$RT_LIB_SRC" ]; then
  RT_LIB_SRC="$(dirname -- "$PIONC")/libpionrt.a"
fi
[ -f "$RT_LIB_SRC" ] || fail "Scenario M5: could not locate libpionrt.a (PION_RT_LIB='$RT_LIB_SRC')"
cp "$RT_LIB_SRC" "$CAS_M5/obj/libpionrt_sim.a"

PION_RT_LIB="$CAS_M5/obj/libpionrt_sim.a" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_M5" \
  "$PIONC" build -o "$TMP_DIR/m5_bin1" "$WS_M4/pkg" 2>"$TMP_DIR/m5_cold.trace"
[ "$("$TMP_DIR/m5_bin1")" = "88" ] || fail "Scenario M5 cold expected 88"
if grep -q "(local:" "$TMP_DIR/m5_cold.trace"; then
  fail "Scenario M5 cold unexpectedly fell back to local: $(cat "$TMP_DIR/m5_cold.trace")"
fi
M5_DEPS_COUNT="$(find "$CAS_M5/obj" -maxdepth 1 -name 'cstub_dep_*.deps' | wc -l | tr -d ' ')"
M5_OBJS_COLD="$(find "$CAS_M5/obj" -maxdepth 1 -name 'cstub_*.o' | wc -l | tr -d ' ')"
[ "$M5_DEPS_COUNT" = "1" ] && [ "$M5_OBJS_COLD" = "1" ] || \
  fail "Scenario M5 expected 1 .deps and 1 cstub_*.o after cold build (got deps=$M5_DEPS_COUNT objs=$M5_OBJS_COLD)"

PION_RT_LIB="$CAS_M5/obj/libpionrt_sim.a" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_M5" \
  "$PIONC" build -o "$TMP_DIR/m5_bin2" "$WS_M4/pkg" 2>"$TMP_DIR/m5_hot.trace"
[ "$("$TMP_DIR/m5_bin2")" = "88" ] || fail "Scenario M5 warm expected 88"
grep -q "cstub=.*stub\.c HIT key=" "$TMP_DIR/m5_hot.trace" || \
  fail "Scenario M5 expected 100% warm HIT when PION_RT_LIB is in CAS/obj: $(cat "$TMP_DIR/m5_hot.trace")"
M5_OBJS_HOT="$(find "$CAS_M5/obj" -maxdepth 1 -name 'cstub_*.o' | wc -l | tr -d ' ')"
[ "$M5_OBJS_HOT" = "$M5_OBJS_COLD" ] || \
  fail "Scenario M5 warm build bloated CAS/obj cstub_*.o count ($M5_OBJS_COLD -> $M5_OBJS_HOT)"
echo "(M5) PION_RT_LIB in \$CAS/obj -> cold publish + 100% warm HIT + 0 obj/ bloat -> OK"

# ============================================================================
# Scenario N1: `pionc build -o <out>` warm `nativebin:` CAS HIT (0 link calls),
#              exec mode 0755, invalidation (src/hdr/rt_lib/cc --version), and
#              fail-closed `-L` / `search_paths` direct-link fallback.
# ============================================================================
WS_N1="$TMP_DIR/ws_n1"
mkdir -p "$WS_N1/app/src"
cat > "$WS_N1/app/stub.h" <<'EOF'
#define N1_VAL 11
EOF
cat > "$WS_N1/app/stub.c" <<'EOF'
#include <stdint.h>
#include "stub.h"
int64_t n1_stub_val(void) { return N1_VAL; }
EOF
cat > "$WS_N1/app/pion.toml" <<'EOF'
[package]
name = "n1_app"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
EOF
cat > "$WS_N1/app/src/main.pion" <<'EOF'
extern "C" fn n1_stub_val() -> Int64
fn main(world : World) -> Unit {
  io_println(world, "n1=" + n1_stub_val().to_string())
}
EOF

N1_CC="$TMP_DIR/n1_cc.sh"
cat > "$N1_CC" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  echo "n1_mockcc ${N1_CC_VER:-1.0}"
  exit 0
fi
printf 'CALL %s\n' "$*" >> "${N1_CC_LOG}"
exec "${REAL_CC_BIN}" "$@"
EOF
chmod +x "$N1_CC"

# Prepare a copy of libpionrt.a with an extra marker object so we can swap its
# content with identical size & mtime to test rt_lib SHA-256 invalidation.
cat > "$TMP_DIR/n1_rt_m1.c" <<'EOF'
const char n1_rt_marker_sym[] = "RT_MARK_V1";
EOF
cat > "$TMP_DIR/n1_rt_m2.c" <<'EOF'
const char n1_rt_marker_sym[] = "RT_MARK_V2";
EOF
"${REAL_CC_ABS}" -c "$TMP_DIR/n1_rt_m1.c" -o "$TMP_DIR/n1_rt_m1.o"
"${REAL_CC_ABS}" -c "$TMP_DIR/n1_rt_m2.c" -o "$TMP_DIR/n1_rt_m2.o"
cp "$RT_LIB_SRC" "$TMP_DIR/n1_rt.a"
ar rcs "$TMP_DIR/n1_rt.a" "$TMP_DIR/n1_rt_m1.o"
cp -p "$TMP_DIR/n1_rt.a" "$TMP_DIR/n1_rt.ref"

CAS_N1="$TMP_DIR/cas_n1"
mkdir -p "$CAS_N1"
N1_CC_LOG="$TMP_DIR/n1_cc.log"

# 1) Cold build -o n1_d1/n1_app -> MISS, 1 cstub compile + 1 link
mkdir -p "$TMP_DIR/n1_d1" "$TMP_DIR/n1_d2"
: > "$N1_CC_LOG"
REAL_CC_BIN="$REAL_CC_ABS" N1_CC_VER="1.0" N1_CC_LOG="$N1_CC_LOG" CC="$N1_CC" \
  PION_RT_LIB="$TMP_DIR/n1_rt.a" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1" \
  "$PIONC" build -o "$TMP_DIR/n1_d1/n1_app" "$WS_N1/app" 2>"$TMP_DIR/n1_1.trace"
grep -q "\[cas\] bin=n1_app MISS key=" "$TMP_DIR/n1_1.trace" || \
  fail "Scenario N1 cold expected bin MISS: $(cat "$TMP_DIR/n1_1.trace")"
[ -x "$TMP_DIR/n1_d1/n1_app" ] || fail "Scenario N1 cold out1 not executable"
[ "$("$TMP_DIR/n1_d1/n1_app")" = "n1=11" ] || fail "Scenario N1 cold out1 mismatch"
N1_COLD_CALLS="$(wc -l < "$N1_CC_LOG" | tr -d ' ')"
[ "$N1_COLD_CALLS" -ge 1 ] || fail "Scenario N1 cold expected CC/link call, got $N1_COLD_CALLS"

# 2) Warm build -o n1_d2/n1_app (different dir, same basename!) -> HIT, ZERO CC/link calls, executable!
: > "$N1_CC_LOG"
REAL_CC_BIN="$REAL_CC_ABS" N1_CC_VER="1.0" N1_CC_LOG="$N1_CC_LOG" CC="$N1_CC" \
  PION_RT_LIB="$TMP_DIR/n1_rt.a" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1" \
  "$PIONC" build -o "$TMP_DIR/n1_d2/n1_app" "$WS_N1/app" 2>"$TMP_DIR/n1_2.trace"
grep -q "\[cas\] bin=n1_app HIT key=" "$TMP_DIR/n1_2.trace" || \
  fail "Scenario N1 warm expected bin HIT: $(cat "$TMP_DIR/n1_2.trace")"
N1_WARM_CALLS="$(wc -l < "$N1_CC_LOG" | tr -d ' ')"
[ "$N1_WARM_CALLS" = "0" ] || fail "Scenario N1 warm expected 0 CC/link calls, got $N1_WARM_CALLS: $(cat "$N1_CC_LOG")"
[ -x "$TMP_DIR/n1_d2/n1_app" ] || fail "Scenario N1 warm out2 not executable"
[ "$("$TMP_DIR/n1_d2/n1_app")" = "n1=11" ] || fail "Scenario N1 warm out2 mismatch"
if [ "$(uname -s)" = "Darwin" ]; then
  N1_CS_ID="$(codesign -dv "$TMP_DIR/n1_d2/n1_app" 2>&1 | sed -n 's/^Identifier=//p')"
  [ "$N1_CS_ID" = "n1_app" ] || fail "Scenario N1 warm Darwin codesign Identifier mismatch: '$N1_CS_ID'"
fi

# 3) Source edit -> MISS
cat > "$WS_N1/app/src/main.pion" <<'EOF'
extern "C" fn n1_stub_val() -> Int64
fn main(world : World) -> Unit {
  io_println(world, "n1_src=" + n1_stub_val().to_string())
}
EOF
: > "$N1_CC_LOG"
REAL_CC_BIN="$REAL_CC_ABS" N1_CC_VER="1.0" N1_CC_LOG="$N1_CC_LOG" CC="$N1_CC" \
  PION_RT_LIB="$TMP_DIR/n1_rt.a" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1" \
  "$PIONC" build -o "$TMP_DIR/n1_out3" "$WS_N1/app" 2>"$TMP_DIR/n1_3.trace"
grep -q "\[cas\] bin=n1_app MISS key=" "$TMP_DIR/n1_3.trace" || \
  fail "Scenario N1 src edit expected bin MISS"
[ "$("$TMP_DIR/n1_out3")" = "n1_src=11" ] || fail "Scenario N1 src edit output mismatch"

# 4) Header edit -> MISS
cat > "$WS_N1/app/stub.h" <<'EOF'
#define N1_VAL 22
EOF
: > "$N1_CC_LOG"
REAL_CC_BIN="$REAL_CC_ABS" N1_CC_VER="1.0" N1_CC_LOG="$N1_CC_LOG" CC="$N1_CC" \
  PION_RT_LIB="$TMP_DIR/n1_rt.a" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1" \
  "$PIONC" build -o "$TMP_DIR/n1_out4" "$WS_N1/app" 2>"$TMP_DIR/n1_4.trace"
grep -q "\[cas\] bin=n1_app MISS key=" "$TMP_DIR/n1_4.trace" || \
  fail "Scenario N1 header edit expected bin MISS"
[ "$("$TMP_DIR/n1_out4")" = "n1_src=22" ] || fail "Scenario N1 header edit output mismatch"

# 5) Replace libpionrt.a content (preserving mtime) -> MISS
cp "$RT_LIB_SRC" "$TMP_DIR/n1_rt.a"
ar rcs "$TMP_DIR/n1_rt.a" "$TMP_DIR/n1_rt_m2.o"
touch -r "$TMP_DIR/n1_rt.ref" "$TMP_DIR/n1_rt.a"
: > "$N1_CC_LOG"
REAL_CC_BIN="$REAL_CC_ABS" N1_CC_VER="1.0" N1_CC_LOG="$N1_CC_LOG" CC="$N1_CC" \
  PION_RT_LIB="$TMP_DIR/n1_rt.a" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1" \
  "$PIONC" build -o "$TMP_DIR/n1_out5" "$WS_N1/app" 2>"$TMP_DIR/n1_5.trace"
grep -q "\[cas\] bin=n1_app MISS key=" "$TMP_DIR/n1_5.trace" || \
  fail "Scenario N1 rt_lib content change expected bin MISS: $(cat "$TMP_DIR/n1_5.trace")"
[ "$("$TMP_DIR/n1_out5")" = "n1_src=22" ] || fail "Scenario N1 rt_lib edit output mismatch"

# 6) Linker driver --version change -> MISS
: > "$N1_CC_LOG"
REAL_CC_BIN="$REAL_CC_ABS" N1_CC_VER="2.0" N1_CC_LOG="$N1_CC_LOG" CC="$N1_CC" \
  PION_RT_LIB="$TMP_DIR/n1_rt.a" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1" \
  "$PIONC" build -o "$TMP_DIR/n1_out6" "$WS_N1/app" 2>"$TMP_DIR/n1_6.trace"
grep -q "\[cas\] bin=n1_app MISS key=" "$TMP_DIR/n1_6.trace" || \
  fail "Scenario N1 cc --version change expected bin MISS: $(cat "$TMP_DIR/n1_6.trace")"
[ "$("$TMP_DIR/n1_out6")" = "n1_src=22" ] || fail "Scenario N1 cc --version output mismatch"

# 7) Package with `search_paths` (-L) falls back to direct link (never false-hits nativebin:)
WS_N1L="$TMP_DIR/ws_n1_libpath"
mkdir -p "$WS_N1L/app/src" "$WS_N1L/app/extlib"
cat > "$WS_N1L/ext.c" <<'EOF'
#include <stdint.h>
int64_t n1_ext_val(void) { return 100; }
EOF
"${REAL_CC_ABS}" -c "$WS_N1L/ext.c" -o "$WS_N1L/ext.o"
ar rcs "$WS_N1L/app/extlib/libn1ext.a" "$WS_N1L/ext.o"
cp -p "$WS_N1L/app/extlib/libn1ext.a" "$TMP_DIR/libn1ext.ref"
cat > "$WS_N1L/app/pion.toml" <<'EOF'
[package]
name = "n1_libpath_app"
version = "0.1.0"

[link]
search_paths = ["extlib"]
libs = ["n1ext"]
EOF
cat > "$WS_N1L/app/src/main.pion" <<'EOF'
extern "C" fn n1_ext_val() -> Int64
fn main(world : World) -> Unit {
  io_println(world, n1_ext_val().to_string())
}
EOF
CAS_N1L="$TMP_DIR/cas_n1l"
mkdir -p "$CAS_N1L"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1L" "$PIONC" build -o "$TMP_DIR/n1l_1" "$WS_N1L/app" 2>"$TMP_DIR/n1l_1.trace"
[ "$("$TMP_DIR/n1l_1")" = "100" ] || fail "Scenario N1 -L run 1 expected 100"
if grep -q "\[cas\] bin=n1_libpath_app" "$TMP_DIR/n1l_1.trace"; then
  fail "Scenario N1 -L package must bypass nativebin CAS: $(cat "$TMP_DIR/n1l_1.trace")"
fi
cat > "$WS_N1L/ext.c" <<'EOF'
#include <stdint.h>
int64_t n1_ext_val(void) { return 200; }
EOF
"${REAL_CC_ABS}" -c "$WS_N1L/ext.c" -o "$WS_N1L/ext.o"
rm -f "$WS_N1L/app/extlib/libn1ext.a"
ar rcs "$WS_N1L/app/extlib/libn1ext.a" "$WS_N1L/ext.o"
touch -r "$TMP_DIR/libn1ext.ref" "$WS_N1L/app/extlib/libn1ext.a"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1L" "$PIONC" build -o "$TMP_DIR/n1l_2" "$WS_N1L/app" 2>"$TMP_DIR/n1l_2.trace"
[ "$("$TMP_DIR/n1l_2")" = "200" ] || fail "Scenario N1 -L run 2 expected 200 after external .a rebuild"

# 8) LIBRARY_PATH + libs = ["n1ext"] (without search_paths) must also bypass nativebin CAS
WS_N1ENV="$TMP_DIR/ws_n1_env"
mkdir -p "$WS_N1ENV/app/src" "$WS_N1ENV/extlib"
cat > "$WS_N1ENV/ext.c" <<'EOF'
#include <stdint.h>
int64_t n1_env_val(void) { return 100; }
EOF
"${REAL_CC_ABS}" -c "$WS_N1ENV/ext.c" -o "$WS_N1ENV/ext.o"
ar rcs "$WS_N1ENV/extlib/libn1env.a" "$WS_N1ENV/ext.o"
cp -p "$WS_N1ENV/extlib/libn1env.a" "$TMP_DIR/libn1env.ref"
cat > "$WS_N1ENV/app/pion.toml" <<'EOF'
[package]
name = "n1_env_app"
version = "0.1.0"

[link]
libs = ["n1env"]
EOF
cat > "$WS_N1ENV/app/src/main.pion" <<'EOF'
extern "C" fn n1_env_val() -> Int64
fn main(world : World) -> Unit {
  io_println(world, n1_env_val().to_string())
}
EOF
CAS_N1ENV="$TMP_DIR/cas_n1env"
mkdir -p "$CAS_N1ENV"
LIBRARY_PATH="$WS_N1ENV/extlib" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1ENV" \
  "$PIONC" build -o "$TMP_DIR/n1env_1" "$WS_N1ENV/app" 2>"$TMP_DIR/n1env_1.trace"
[ "$("$TMP_DIR/n1env_1")" = "100" ] || fail "Scenario N1 LIBRARY_PATH run 1 expected 100"
cat > "$WS_N1ENV/ext.c" <<'EOF'
#include <stdint.h>
int64_t n1_env_val(void) { return 200; }
EOF
"${REAL_CC_ABS}" -c "$WS_N1ENV/ext.c" -o "$WS_N1ENV/ext.o"
rm -f "$WS_N1ENV/extlib/libn1env.a"
ar rcs "$WS_N1ENV/extlib/libn1env.a" "$WS_N1ENV/ext.o"
touch -r "$TMP_DIR/libn1env.ref" "$WS_N1ENV/extlib/libn1env.a"
LIBRARY_PATH="$WS_N1ENV/extlib" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1ENV" \
  "$PIONC" build -o "$TMP_DIR/n1env_2" "$WS_N1ENV/app" 2>"$TMP_DIR/n1env_2.trace"
[ "$("$TMP_DIR/n1env_2")" = "200" ] || fail "Scenario N1 LIBRARY_PATH run 2 expected 200 after external .a rebuild"

# 9) Non-whitelisted linker flag `-Wl,--library-path=<extlib>` (GNU ld) or `-Wl,-L,<extlib>` (Darwin) must bypass nativebin CAS
WS_N1WL="$TMP_DIR/ws_n1_wl"
mkdir -p "$WS_N1WL/app/src" "$WS_N1WL/extlib"
cat > "$WS_N1WL/ext.c" <<'EOF'
#include <stdint.h>
int64_t n1_wl_val(void) { return 100; }
EOF
"${REAL_CC_ABS}" -c "$WS_N1WL/ext.c" -o "$WS_N1WL/ext.o"
ar rcs "$WS_N1WL/extlib/libn1wl.a" "$WS_N1WL/ext.o"
cp -p "$WS_N1WL/extlib/libn1wl.a" "$TMP_DIR/libn1wl.ref"
if [ "$(uname -s)" = "Darwin" ]; then
  N1_WL_FLAG="-Wl,-L,$WS_N1WL/extlib"
else
  N1_WL_FLAG="-Wl,--library-path=$WS_N1WL/extlib"
fi
cat > "$WS_N1WL/app/pion.toml" <<EOF
[package]
name = "n1_wl_app"
version = "0.1.0"

[link]
flags = ["$N1_WL_FLAG"]
libs = ["n1wl"]
EOF
cat > "$WS_N1WL/app/src/main.pion" <<'EOF'
extern "C" fn n1_wl_val() -> Int64
fn main(world : World) -> Unit {
  io_println(world, n1_wl_val().to_string())
}
EOF
CAS_N1WL="$TMP_DIR/cas_n1wl"
mkdir -p "$CAS_N1WL"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1WL" \
  "$PIONC" build -o "$TMP_DIR/n1wl_1" "$WS_N1WL/app" 2>"$TMP_DIR/n1wl_1.trace"
[ "$("$TMP_DIR/n1wl_1")" = "100" ] || fail "Scenario N1 -Wl,--library-path run 1 expected 100"
cat > "$WS_N1WL/ext.c" <<'EOF'
#include <stdint.h>
int64_t n1_wl_val(void) { return 200; }
EOF
"${REAL_CC_ABS}" -c "$WS_N1WL/ext.c" -o "$WS_N1WL/ext.o"
rm -f "$WS_N1WL/extlib/libn1wl.a"
ar rcs "$WS_N1WL/extlib/libn1wl.a" "$WS_N1WL/ext.o"
touch -r "$TMP_DIR/libn1wl.ref" "$WS_N1WL/extlib/libn1wl.a"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_N1WL" \
  "$PIONC" build -o "$TMP_DIR/n1wl_2" "$WS_N1WL/app" 2>"$TMP_DIR/n1wl_2.trace"
[ "$("$TMP_DIR/n1wl_2")" = "200" ] || fail "Scenario N1 -Wl,--library-path run 2 expected 200 after external .a rebuild"
echo "(N1) nativebin: warm -o HIT (0 link calls, 0755) + src/hdr/rt_lib/ccver invalidation + -L/LIBRARY_PATH/-Wl,--library-path fallback -> OK"

# ============================================================================
# Scenario N2: `-I/usr/include/...` system headers must NOT pollute `proj_hdr_dirs`
#              and inflate `.deps` `absent:` entries.
# ============================================================================
SYS_INC_N2=""
if [ -d /usr/include ]; then
  SYS_INC_N2="/usr/include"
elif command -v xcrun >/dev/null 2>&1; then
  SDK_P="$(xcrun --show-sdk-path 2>/dev/null || true)"
  if [ -n "$SDK_P" ] && [ -d "$SDK_P/usr/include" ]; then
    SYS_INC_N2="$SDK_P/usr/include"
  fi
fi
if [ -n "$SYS_INC_N2" ]; then
  WS_N2="$TMP_DIR/ws_n2_sysinc"
  mkdir -p "$WS_N2/pkg/src"
  cat > "$WS_N2/pkg/local_n2.h" <<'EOF'
#define N2_VAL 77
EOF
  cat > "$WS_N2/pkg/stub.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include "local_n2.h"
int64_t n2_val(void) { return N2_VAL; }
EOF
  cat > "$WS_N2/pkg/pion.toml" <<EOF
[package]
name = "n2_sysinc"
version = "0.1.0"

[link]
c_sources = ["stub.c"]
cc_flags = ["-I${SYS_INC_N2}"]
EOF
  cat > "$WS_N2/pkg/src/main.pion" <<'EOF'
extern "C" fn n2_val() -> Int64
fn main(world : World) -> Unit { io_println(world, n2_val().to_string()) }
EOF
  CAS_N2="$TMP_DIR/cas_n2"
  mkdir -p "$CAS_N2"
  PION_CACHE_DIR="$CAS_N2" "$PIONC" build -o "$TMP_DIR/n2_out" "$WS_N2/pkg"
  [ "$("$TMP_DIR/n2_out")" = "77" ] || fail "Scenario N2 expected 77"
  N2_DEPS="$(find "$CAS_N2/obj" -maxdepth 1 -name 'cstub_dep_*.deps' | head -n 1)"
  [ -n "$N2_DEPS" ] && [ -f "$N2_DEPS" ] || fail "Scenario N2 expected .deps file"
  python3 - "$N2_DEPS" "$SYS_INC_N2" <<'PYEOF'
import sys
deps_path, sys_inc = sys.argv[1], sys.argv[2].rstrip("/")
in_absent = False
bad = []
for line in open(deps_path):
    s = line.strip()
    if s.startswith("absent:"):
        in_absent = True
        continue
    if s.startswith("sha256:"):
        break
    if in_absent and s.startswith(sys_inc + "/") and s.endswith("/local_n2.h"):
        bad.append(s)
assert not bad, f"system header dir polluted proj_hdr_dirs/absent: {bad[:5]}"
PYEOF
  echo "(N2) -I${SYS_INC_N2} system header dirs do not pollute proj_hdr_dirs -> OK"
fi

echo "PASS: cas_pin_and_cstub_deps"
