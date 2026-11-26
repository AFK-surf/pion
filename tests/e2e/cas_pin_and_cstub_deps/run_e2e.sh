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
PYEOF

echo "(D) cross-process kernel-locked CAS pin + stale crash cleanup -> OK"

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
# Scenario F (Round 2 #3): Same-size + same-mtime external .a edit invalidates
# ============================================================================
cp -p "$WS_C/app/libext_mtime.a" "$TMP_DIR/libext_mtime.ref"
cat > "$WS_C/ext_obj.c" <<'EOF'
#include <stdint.h>
int64_t mtime_ext_lib_val(void) { return 99; }
EOF
"${CC:-cc}" -c "$WS_C/ext_obj.c" -o "$WS_C/ext_obj.o"
rm -f "$WS_C/app/libext_mtime.a"
ar rcs "$WS_C/app/libext_mtime.a" "$WS_C/ext_obj.o"
touch -r "$TMP_DIR/libext_mtime.ref" "$WS_C/app/libext_mtime.a"
PION_CACHE_DIR="$CAS_C" "$PIONC" build -o "$TMP_DIR/f_bin" "$WS_C/app"
OUT_F="$("$TMP_DIR/f_bin")"
[ "$OUT_F" = "mtime_sum=114" ] || fail "Scenario F expected mtime_sum=114 after same-size/same-mtime .a edit, got $OUT_F"
echo "(F) external .a content edit with identical size & mtime -> MISS & relink OK"

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
  PION_CACHE_DIR="$CAS_RACY" "$PIONC" build -o "$TMP_DIR/racy_bin1" "$WS_RACY/pkg"
[ "$("$TMP_DIR/racy_bin1")" = "10" ] || fail "Scenario G3 racy run 1 expected 10"
# Next run (no race) MUST MISS and pick up 20 because run 1 refused to publish racy .deps!
REAL_CC_BIN="$REAL_CC_ABS" INJECT_RACE=0 RACY_HDR="$WS_RACY/pkg/racy.h" CC="$RACY_CC" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_RACY" "$PIONC" build -o "$TMP_DIR/racy_bin2" "$WS_RACY/pkg" 2>"$TMP_DIR/racy2.trace"
grep -q "cstub=.*stub\.c MISS key=" "$TMP_DIR/racy2.trace" || fail "Scenario G3 expected MISS after racy compile"
[ "$("$TMP_DIR/racy_bin2")" = "20" ] || fail "Scenario G3 expected 20 after racy compile self-healed"

echo "(G) -I shadowing + UTF-8 Chinese path + racy compile-time edit self-heal -> OK"
echo "PASS: cas_pin_and_cstub_deps"
