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
echo "PASS: cas_pin_and_cstub_deps"
