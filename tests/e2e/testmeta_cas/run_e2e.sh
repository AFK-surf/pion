#!/bin/sh
# End-to-end adversarial soundness tests for `pionc test --deps` source-hash
# `testmeta` + `testbin` CAS fast path and streaming SSA temp cleanup:
#   1. Hot rerun of `pionc test --deps` (including `--filter` switching & 0-test
#      package): `PION_CAS_TRACE=1` shows `testmeta` HIT, `bins built=0`, and
#      zero leftover `.ssa.tmp.*` files.
#   2. Soundness invalidation matrix (every single mutation MUST invalidate
#      `testmeta`, rebuild, and observe the new behavior):
#        (a) edit test source (`*_test.pion`)
#        (b) edit tested package source (`lib.pion`)
#        (c) edit upstream dependency implementation (`.o` changes, `.pionsig` unchanged)
#        (d) edit upstream dependency public signature (`.pionsig` changes)
#        (e) edit link `c_sources` / link flags
#        (f) delete `testbin/` file while keeping `testmeta/` intact
#   3. `pionc cache prune` and `pionc cache clear`/`clean` properly clean
#      `testmeta/`, and compile/type errors NEVER write `testmeta/`.
#
# Usage: sh tests/e2e/testmeta_cas/run_e2e.sh <pionc>
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
case "$PIONC" in
  /*) ;;
  *) PIONC="$(CDPATH= cd -- "$(dirname -- "$PIONC")" && pwd)/$(basename -- "$PIONC")" ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL (testmeta_cas): $*" >&2
  exit 1
}

assert_no_tmp_ssa() {
  cas_d="$1"
  found="$(find "$cas_d/testbin" -name '*.ssa.tmp.*' 2>/dev/null || true)"
  if [ -n "$found" ]; then
    fail "leaked temp SSA files in $cas_d/testbin: $found"
  fi
}

echo "=== E2E: pionc test --deps testmeta CAS fast path & soundness ==="

WS="$TMP_DIR/ws"
mkdir -p "$WS/dep/src" "$WS/dep/csrc" "$WS/mid/src" "$WS/notests/src" "$WS/app/src"

cat > "$WS/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"

[link]
c_sources = ["csrc/dep_c.c"]
EOF
cat > "$WS/dep/csrc/dep_c.c" <<'EOF'
#include <stdint.h>
int64_t tm_dep_c_val(void) { return 10; }
EOF
cat > "$WS/dep/src/lib.pion" <<'EOF'
extern "C" fn tm_dep_c_val() -> Int64
pub fn dep_num() -> Int64 { tm_dep_c_val() + 1L }
EOF
cat > "$WS/dep/src/dep_test.pion" <<'EOF'
test "dep_basic" { debug_assert(dep_num() == 11L, "dep_basic") }
EOF

cat > "$WS/mid/pion.toml" <<'EOF'
[package]
name = "mid"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }
EOF
cat > "$WS/mid/src/lib.pion" <<'EOF'
import "dep"
pub fn mid_num() -> Int64 { dep::dep_num() * 2L }
EOF
cat > "$WS/mid/src/mid_test.pion" <<'EOF'
test "mid_alpha" { debug_assert(mid_num() == 22L, "mid_alpha") }
test "mid_beta" { debug_assert(mid_num() + 1L == 23L, "mid_beta") }
EOF

cat > "$WS/notests/pion.toml" <<'EOF'
[package]
name = "notests"
version = "0.1.0"
EOF
cat > "$WS/notests/src/lib.pion" <<'EOF'
pub fn helper() -> Int64 { 5L }
EOF

cat > "$WS/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
mid = { path = "../mid" }
notests = { path = "../notests" }
EOF
cat > "$WS/app/src/lib.pion" <<'EOF'
import "mid"
import "notests"
pub fn app_num() -> Int64 { mid::mid_num() + notests::helper() }
EOF
cat > "$WS/app/src/app_test.pion" <<'EOF'
test "app_alpha" { debug_assert(app_num() == 27L, "app_alpha") }
test "app_beta" { debug_assert(app_num() + 3L == 30L, "app_beta") }
EOF

CAS="$TMP_DIR/cas"
mkdir -p "$CAS"

# ----------------------------------------------------------------------------
# 1. Cold run -> populates testmeta (incl. NONE for `notests`) + testbin, 0 tmp SSA
# ----------------------------------------------------------------------------
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS" "$PIONC" test --deps --jobs 4 --json "$WS/app" \
  > "$TMP_DIR/cold.json" 2> "$TMP_DIR/cold.trace"
assert_no_tmp_ssa "$CAS"
python3 - "$TMP_DIR/cold.json" "$TMP_DIR/cold.trace" "$CAS" <<'PYEOF'
import glob, json, os, sys
d = json.load(open(sys.argv[1]))
trace = open(sys.argv[2]).read()
cas = sys.argv[3]
assert d["ok"] is True and d["total"] == 5 and d["passed"] == 5 and d["failed"] == 0, d
assert "[cas] testmeta=app MISS" in trace, trace
assert "[cas] testmeta=notests MISS" in trace, trace
metas = glob.glob(os.path.join(cas, "testmeta", "*.tsv"))
assert len(metas) == 4, f"expected 4 testmeta files (dep, mid, notests, app), got {metas}"
has_none = any(open(m).read().strip() == "NONE" for m in metas)
assert has_none, "expected NONE testmeta entry for 0-test package `notests`"
PYEOF

# ----------------------------------------------------------------------------
# 2. Hot rerun + --filter switching (shared testmeta + testbin, 0 bins built)
# ----------------------------------------------------------------------------
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS" "$PIONC" test --deps --jobs 4 --json "$WS/app" \
  > "$TMP_DIR/hot.json" 2> "$TMP_DIR/hot.trace"
assert_no_tmp_ssa "$CAS"
python3 - "$TMP_DIR/hot.json" "$TMP_DIR/hot.trace" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
trace = open(sys.argv[2]).read()
assert d["ok"] is True and d["total"] == 5 and d["passed"] == 5 and d["failed"] == 0, d
for pkg in ("dep", "mid", "app"):
    assert f"[cas] testmeta={pkg} HIT bin=" in trace, trace
assert "[cas] testmeta=notests HIT none" in trace, trace
assert "[cas] testmeta=" in trace and "MISS" not in trace, trace
assert "[test] bins built=0" in trace, trace
PYEOF

# Filter switch: --filter alpha then --filter beta -> both 100% testmeta HIT!
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS" "$PIONC" test --deps --jobs 4 --filter alpha --json "$WS/app" \
  > "$TMP_DIR/flt_a.json" 2> "$TMP_DIR/flt_a.trace"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS" "$PIONC" test --deps --jobs 4 --filter beta --json "$WS/app" \
  > "$TMP_DIR/flt_b.json" 2> "$TMP_DIR/flt_b.trace"
python3 - "$TMP_DIR/flt_a.json" "$TMP_DIR/flt_a.trace" "$TMP_DIR/flt_b.json" "$TMP_DIR/flt_b.trace" <<'PYEOF'
import json, sys
da, ta, db, tb = json.load(open(sys.argv[1])), open(sys.argv[2]).read(), json.load(open(sys.argv[3])), open(sys.argv[4]).read()
assert da["ok"] is True and da["total"] == 2 and da["passed"] == 2, da
assert db["ok"] is True and db["total"] == 2 and db["passed"] == 2, db
assert "MISS" not in ta and "[test] bins built=0" in ta, ta
assert "MISS" not in tb and "[test] bins built=0" in tb, tb
PYEOF
echo "(1-2) hot testmeta HIT + 0-test package + --filter sharing -> OK"

# ----------------------------------------------------------------------------
# 3. Soundness invalidation matrix
# ----------------------------------------------------------------------------
# (a) Edit test source (`app_test.pion`) -> must fail stale assertion
cat > "$WS/app/src/app_test.pion" <<'EOF'
test "app_alpha" { debug_assert(app_num() == 999L, "app_alpha_edited") }
test "app_beta" { debug_assert(app_num() + 3L == 30L, "app_beta") }
EOF
if PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS" "$PIONC" test --deps --jobs 4 --json "$WS/app" \
  > "$TMP_DIR/inv_a.json" 2> "$TMP_DIR/inv_a.trace"; then
  fail "(3a) expected failure after editing app_test.pion"
fi
python3 - "$TMP_DIR/inv_a.json" "$TMP_DIR/inv_a.trace" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
t = open(sys.argv[2]).read()
assert d["ok"] is False and d["failed"] == 1, d
assert "[cas] testmeta=app MISS" in t, t
assert "[cas] testmeta=dep HIT" in t and "[cas] testmeta=mid HIT" in t, t
PYEOF
# Restore app_test.pion
cat > "$WS/app/src/app_test.pion" <<'EOF'
test "app_alpha" { debug_assert(app_num() == 27L, "app_alpha") }
test "app_beta" { debug_assert(app_num() + 3L == 30L, "app_beta") }
EOF

# (b) Edit tested package source (`app/src/lib.pion`) -> must invalidate app
cat > "$WS/app/src/lib.pion" <<'EOF'
import "mid"
import "notests"
pub fn app_num() -> Int64 { mid::mid_num() + notests::helper() + 1L }
EOF
if PION_CACHE_DIR="$CAS" "$PIONC" test --deps --jobs 4 --json "$WS/app" > "$TMP_DIR/inv_b.json"; then
  fail "(3b) expected failure after editing app/src/lib.pion"
fi
python3 - "$TMP_DIR/inv_b.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is False and d["failed"] == 2, d
PYEOF
cat > "$WS/app/src/lib.pion" <<'EOF'
import "mid"
import "notests"
pub fn app_num() -> Int64 { mid::mid_num() + notests::helper() }
EOF

# (c) Edit upstream dep implementation ONLY (`.o` changes, `.pionsig` UNCHANGED!)
cat > "$WS/dep/src/lib.pion" <<'EOF'
extern "C" fn tm_dep_c_val() -> Int64
pub fn dep_num() -> Int64 { tm_dep_c_val() + 2L }
EOF
if PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS" "$PIONC" test --deps --jobs 4 --json "$WS/app" \
  > "$TMP_DIR/inv_c.json" 2> "$TMP_DIR/inv_c.trace"; then
  fail "(3c) expected failure after editing upstream dep impl (same .pionsig)"
fi
python3 - "$TMP_DIR/inv_c.json" "$TMP_DIR/inv_c.trace" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
t = open(sys.argv[2]).read()
assert d["ok"] is False and d["failed"] == 5, d
assert "[cas] testmeta=dep MISS" in t and "[cas] testmeta=mid MISS" in t and "[cas] testmeta=app MISS" in t, t
PYEOF
cat > "$WS/dep/src/lib.pion" <<'EOF'
extern "C" fn tm_dep_c_val() -> Int64
pub fn dep_num() -> Int64 { tm_dep_c_val() + 1L }
EOF

# (d) Edit upstream dep public signature (`.pionsig` changes) -> must invalidate downstream
cat > "$WS/dep/src/lib.pion" <<'EOF'
extern "C" fn tm_dep_c_val() -> Int64
pub fn dep_num() -> Int64 { tm_dep_c_val() + 1L }
pub fn dep_extra() -> Int64 { 7L }
EOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS" "$PIONC" test --deps --jobs 4 --json "$WS/app" \
  > "$TMP_DIR/inv_d.json" 2> "$TMP_DIR/inv_d.trace"
python3 - "$TMP_DIR/inv_d.json" "$TMP_DIR/inv_d.trace" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
t = open(sys.argv[2]).read()
assert d["ok"] is True and d["passed"] == 5, d
assert "[cas] testmeta=dep MISS" in t and "[cas] testmeta=mid MISS" in t and "[cas] testmeta=app MISS" in t, t
PYEOF

# (e) Edit `c_sources` -> must invalidate dep, mid, app
cat > "$WS/dep/csrc/dep_c.c" <<'EOF'
#include <stdint.h>
int64_t tm_dep_c_val(void) { return 20; }
EOF
if PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS" "$PIONC" test --deps --jobs 4 --json "$WS/app" \
  > "$TMP_DIR/inv_e.json" 2> "$TMP_DIR/inv_e.trace"; then
  fail "(3e) expected failure after editing c_sources"
fi
python3 - "$TMP_DIR/inv_e.json" "$TMP_DIR/inv_e.trace" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
t = open(sys.argv[2]).read()
assert d["ok"] is False and d["failed"] == 5, d
assert "[cas] testmeta=dep MISS" in t and "[cas] testmeta=mid MISS" in t and "[cas] testmeta=app MISS" in t, t
PYEOF
cat > "$WS/dep/csrc/dep_c.c" <<'EOF'
#include <stdint.h>
int64_t tm_dep_c_val(void) { return 10; }
EOF
PION_CACHE_DIR="$CAS" "$PIONC" test --deps --jobs 4 --json "$WS/app" > /dev/null

# (f) Delete `testbin/` files while leaving `testmeta/` intact -> must cleanly MISS and rebuild
rm -rf "$CAS/testbin"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS" "$PIONC" test --deps --jobs 4 --json "$WS/app" \
  > "$TMP_DIR/inv_f.json" 2> "$TMP_DIR/inv_f.trace"
assert_no_tmp_ssa "$CAS"
python3 - "$TMP_DIR/inv_f.json" "$TMP_DIR/inv_f.trace" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
t = open(sys.argv[2]).read()
assert d["ok"] is True and d["passed"] == 5 and d["failed"] == 0, d
assert "[cas] testmeta=app MISS" in t and "[cas] testmeta=mid MISS" in t and "[cas] testmeta=dep MISS" in t, t
PYEOF
echo "(3a-3f) soundness invalidation matrix -> OK"

# ----------------------------------------------------------------------------
# 4. Compile/type error MUST NOT write testmeta, and no temp SSA leaked
# ----------------------------------------------------------------------------
CAS_ERR="$TMP_DIR/cas_err"
mkdir -p "$CAS_ERR"
cat > "$WS/app/src/app_test.pion" <<'EOF'
test "app_bad_type" {
  let x : Int = "not_an_int"
  debug_assert(x == 0, "bad")
}
EOF
if PION_CACHE_DIR="$CAS_ERR" "$PIONC" test --deps --jobs 4 --json "$WS/app" > "$TMP_DIR/err.json" 2>&1; then
  fail "(4) expected type error in app_test.pion"
fi
assert_no_tmp_ssa "$CAS_ERR"
python3 - "$CAS_ERR" <<'PYEOF'
import glob, os, sys
cas = sys.argv[1]
metas = glob.glob(os.path.join(cas, "testmeta", "*.tsv"))
assert len(metas) == 0, f"compile error must not write testmeta, found: {metas}"
PYEOF
# Restore valid app_test.pion
cat > "$WS/app/src/app_test.pion" <<'EOF'
test "app_alpha" { debug_assert(app_num() == 27L, "app_alpha") }
test "app_beta" { debug_assert(app_num() + 3L == 30L, "app_beta") }
EOF
echo "(4) compile/type error writes 0 testmeta and leaks 0 temp SSA -> OK"

# ----------------------------------------------------------------------------
# 5. `cache stats`, `cache prune` (explicitly evicting `testmeta`), `cache clean`
# ----------------------------------------------------------------------------
STATS_BEFORE="$(PION_CACHE_DIR="$CAS" "$PIONC" cache stats --json)"
META_BEFORE="$(find "$CAS/testmeta" -name '*.tsv' 2>/dev/null | wc -l | tr -d ' ')"
[ "$META_BEFORE" -ge 4 ] || fail "(5) expected >= 4 testmeta files before prune, got $META_BEFORE"
PION_CACHE_DIR="$CAS" PION_CACHE_MAX_KB=1 "$PIONC" cache prune --json > "$TMP_DIR/prune.json"
python3 - "$STATS_BEFORE" "$TMP_DIR/prune.json" "$CAS" "$META_BEFORE" <<'PYEOF'
import glob, json, os, sys
sb = json.loads(sys.argv[1])
pr = json.load(open(sys.argv[2]))
cas = sys.argv[3]
meta_before = int(sys.argv[4])
assert sb["ok"] is True and sb["bin"]["files"] > 0, sb
assert pr["ok"] is True and pr["evicted"] > 0, pr
meta_after = len(glob.glob(os.path.join(cas, "testmeta", "*.tsv")))
assert meta_after < meta_before, f"expected cache prune to evict testmeta entries ({meta_before} -> {meta_after})"
PYEOF

PION_CACHE_DIR="$CAS" "$PIONC" clean --json > "$TMP_DIR/clean.json"
STATS_AFTER="$(PION_CACHE_DIR="$CAS" "$PIONC" cache stats --json)"
python3 - "$TMP_DIR/clean.json" "$STATS_AFTER" "$CAS" <<'PYEOF'
import glob, json, os, sys
cl = json.load(open(sys.argv[1]))
sa = json.loads(sys.argv[2])
cas = sys.argv[3]
assert cl["ok"] is True and cl["removed_files"] > 0, cl
assert sa["ok"] is True and sa["total_files"] == 0 and sa["total_bytes"] == 0, sa
metas = glob.glob(os.path.join(cas, "testmeta", "*.tsv"))
assert len(metas) == 0, f"expected 0 testmeta files after clean, got {metas}"
PYEOF
echo "(5) cache stats / prune (evicts testmeta) / clean -> OK"

# ----------------------------------------------------------------------------
# 6. `[verify] enabled = true` violations MUST fail in both --jobs 1 and --jobs 4
#    and NEVER write `testmeta`
# ----------------------------------------------------------------------------
WS_V="$TMP_DIR/ws_verify"
mkdir -p "$WS_V/vdep/src" "$WS_V/vapp/src"
cat > "$WS_V/vdep/pion.toml" <<'EOF'
[package]
name = "vdep"
version = "0.1.0"
EOF
cat > "$WS_V/vdep/src/lib.pion" <<'EOF'
pub fn ok_val() -> Int { 1 }
EOF
cat > "$WS_V/vdep/src/vdep_test.pion" <<'EOF'
test "vdep_ok" { debug_assert(ok_val() == 1, "vdep_ok") }
EOF
cat > "$WS_V/vapp/pion.toml" <<'EOF'
[package]
name = "vapp"
version = "0.1.0"

[verify]
enabled = true

[dependencies]
vdep = { path = "../vdep" }
EOF
cat > "$WS_V/vapp/src/lib.pion" <<'EOF'
import "vdep"
pub fn bad_float(x : Float) -> Float { x + 1.0 }
EOF
cat > "$WS_V/vapp/src/vapp_test.pion" <<'EOF'
test "vapp_bad" { debug_assert(bad_float(1.0) > 0.0, "vapp_bad") }
EOF
for J in 1 4; do
  CAS_V="$TMP_DIR/cas_verify_j${J}"
  mkdir -p "$CAS_V"
  if PION_CACHE_DIR="$CAS_V" "$PIONC" test --deps --jobs "$J" --json "$WS_V/vapp" > "$TMP_DIR/v_j${J}.json" 2>&1; then
    fail "(6) expected [verify] enabled = true violation to fail under --jobs $J"
  fi
  python3 - "$TMP_DIR/v_j${J}.json" "$CAS_V" <<'PYEOF'
import glob, json, os, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is False, d
metas = glob.glob(os.path.join(sys.argv[2], "testmeta", "*.tsv"))
assert len(metas) == 0, f"[verify] failure must not write testmeta: {metas}"
PYEOF
done
echo "(6) [verify] enabled = true violation fails under --jobs 1 & 4 with 0 testmeta -> OK"

# ----------------------------------------------------------------------------
# 7. Deterministic TOCTOU mid-run file edit via CC wrapper MUST NOT poison testmeta
# ----------------------------------------------------------------------------
CAS_TOCTOU="$TMP_DIR/cas_toctou"
mkdir -p "$CAS_TOCTOU"
REAL_CC="$(command -v "${CC:-cc}")"
MUTATE_FLAG="$TMP_DIR/toctou_mutated"
WRAP_CC="$TMP_DIR/wrap_cc.sh"
cat > "$WRAP_CC" <<EOF
#!/bin/sh
if [ ! -f "$MUTATE_FLAG" ]; then
  touch "$MUTATE_FLAG"
  cat > "$WS/app/src/lib.pion" <<'PIONEOF'
import "mid"
import "notests"
pub fn app_num() -> Int64 { 999L }
PIONEOF
fi
exec "$REAL_CC" "\$@"
EOF
chmod +x "$WRAP_CC"
# Cold run: `app/src/lib.pion` is snapshotted at workspace load BEFORE c_sources CC runs;
# mid-run disk edit during CC must NOT affect the compiled test binary or poison testmeta.
CC="$WRAP_CC" PION_CACHE_DIR="$CAS_TOCTOU" "$PIONC" test --deps --jobs 4 --json "$WS/app" > "$TMP_DIR/toctou1.json"
[ -f "$MUTATE_FLAG" ] || fail "(7) CC wrapper did not fire"
# Restore original app/src/lib.pion and run hot -> MUST hit testmeta and pass (not poisoned with 999L!)
cat > "$WS/app/src/lib.pion" <<'EOF'
import "mid"
import "notests"
pub fn app_num() -> Int64 { mid::mid_num() + notests::helper() }
EOF
CC="$WRAP_CC" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_TOCTOU" "$PIONC" test --deps --jobs 4 --json "$WS/app" \
  > "$TMP_DIR/toctou2.json" 2> "$TMP_DIR/toctou2.trace"
python3 - "$TMP_DIR/toctou1.json" "$TMP_DIR/toctou2.json" "$TMP_DIR/toctou2.trace" <<'PYEOF'
import json, sys
d1, d2, tr = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), open(sys.argv[3]).read()
assert d1["ok"] is True and d1["passed"] == 5 and d1["failed"] == 0, d1
assert d2["ok"] is True and d2["passed"] == 5 and d2["failed"] == 0, d2
assert "[cas] testmeta=app HIT bin=" in tr, tr
PYEOF
echo "(7) deterministic mid-run TOCTOU edit does not poison testmeta -> OK"

# ----------------------------------------------------------------------------
# 8. Corrupted `testmeta` files (garbage, ../escape, NONE + extra lines) safely MISS
# ----------------------------------------------------------------------------
python3 - "$CAS_TOCTOU" <<'PYEOF'
import glob, os, sys
metas = sorted(glob.glob(os.path.join(sys.argv[1], "testmeta", "*.tsv")))
assert len(metas) >= 3, metas
open(metas[0], "w").write("!!!garbage\\xbad\n")
open(metas[1], "w").write("../escape\nfake_test\n")
open(metas[2], "w").write("NONE\nextra_line\n")
PYEOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_TOCTOU" "$PIONC" test --deps --jobs 4 --json "$WS/app" \
  > "$TMP_DIR/corrupt.json" 2> "$TMP_DIR/corrupt.trace"
python3 - "$TMP_DIR/corrupt.json" "$TMP_DIR/corrupt.trace" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
tr = open(sys.argv[2]).read()
assert d["ok"] is True and d["passed"] == 5 and d["failed"] == 0, d
assert tr.count(" MISS key=") >= 3, tr
PYEOF
echo "(8) corrupted testmeta (garbage, ../escape, NONE+extra) safely misses and rebuilds -> OK"

# ----------------------------------------------------------------------------
# 9. Link failure (`-l nonexistent`) MUST NOT write `testmeta`
# ----------------------------------------------------------------------------
CAS_LERR="$TMP_DIR/cas_link_err"
mkdir -p "$CAS_LERR"
if PION_CACHE_DIR="$CAS_LERR" "$PIONC" test --deps --jobs 4 -l nonexistent_pion_testmeta_lib_xyz --json "$WS/app" \
  > "$TMP_DIR/lerr.json" 2>&1; then
  fail "(9) expected link failure with nonexistent -l library"
fi
assert_no_tmp_ssa "$CAS_LERR"
python3 - "$CAS_LERR" <<'PYEOF'
import glob, os, sys
# Zero-test packages may have NONE meta, but tested packages that failed to link MUST NOT write testmeta.
metas = glob.glob(os.path.join(sys.argv[1], "testmeta", "*.tsv"))
non_none = [m for m in metas if open(m).read().strip() != "NONE"]
assert len(non_none) == 0, f"link failure must not write non-NONE testmeta: {non_none}"
PYEOF
echo "(9) link failure writes 0 testbin testmeta and leaks 0 temp SSA -> OK"

# ----------------------------------------------------------------------------
# 10. Special characters in test names (tab, backslash, quote) round-trip + --filter
# ----------------------------------------------------------------------------
WS_SP="$TMP_DIR/ws_special"
mkdir -p "$WS_SP/sp/src"
cat > "$WS_SP/sp/pion.toml" <<'EOF'
[package]
name = "sp"
version = "0.1.0"
EOF
cat > "$WS_SP/sp/src/lib.pion" <<'EOF'
pub fn one() -> Int { 1 }
EOF
cat > "$WS_SP/sp/src/sp_test.pion" <<'EOF'
test "tab\tname\\slash\"quote" { debug_assert(one() == 1, "sp1") }
test "plain_other" { debug_assert(one() == 1, "sp2") }
EOF
CAS_SP="$TMP_DIR/cas_sp"
mkdir -p "$CAS_SP"
PION_CACHE_DIR="$CAS_SP" "$PIONC" test --deps --jobs 4 --json "$WS_SP/sp" > "$TMP_DIR/sp_cold.json"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_SP" "$PIONC" test --deps --jobs 4 --json "$WS_SP/sp" \
  > "$TMP_DIR/sp_hot.json" 2> "$TMP_DIR/sp_hot.trace"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_SP" "$PIONC" test --deps --jobs 4 --filter 'slash"quote' --json "$WS_SP/sp" \
  > "$TMP_DIR/sp_flt.json" 2> "$TMP_DIR/sp_flt.trace"
python3 - "$TMP_DIR/sp_cold.json" "$TMP_DIR/sp_hot.json" "$TMP_DIR/sp_hot.trace" "$TMP_DIR/sp_flt.json" "$TMP_DIR/sp_flt.trace" <<'PYEOF'
import json, sys
c, h, ht, f, ft = open(sys.argv[1]).read(), open(sys.argv[2]).read(), open(sys.argv[3]).read(), json.load(open(sys.argv[4])), open(sys.argv[5]).read()
assert c == h, f"cold vs hot JSON mismatch:\n{c}\nvs\n{h}"
assert "[cas] testmeta=sp HIT bin=" in ht and "MISS" not in ht, ht
assert "[cas] testmeta=sp HIT bin=" in ft and "MISS" not in ft, ft
assert f["ok"] is True and f["total"] == 1 and f["passed"] == 1, f
assert f["tests"][0]["name"] == 'tab\tname\\slash"quote', f
PYEOF
echo "(10) special characters in test names round-trip through testmeta + --filter -> OK"

# ----------------------------------------------------------------------------
# 11. `--jobs 1` vs `--jobs 4` byte-identical JSON parity + `cli_libs` invalidation
# ----------------------------------------------------------------------------
CAS_P1="$TMP_DIR/cas_p1"
CAS_P4="$TMP_DIR/cas_p4"
mkdir -p "$CAS_P1" "$CAS_P4"
PION_CACHE_DIR="$CAS_P1" "$PIONC" test --deps --jobs 1 --json "$WS/app" > "$TMP_DIR/p1_cold.json"
PION_CACHE_DIR="$CAS_P1" "$PIONC" test --deps --jobs 1 --json "$WS/app" > "$TMP_DIR/p1_hot.json"
PION_CACHE_DIR="$CAS_P4" "$PIONC" test --deps --jobs 4 --json "$WS/app" > "$TMP_DIR/p4_cold.json"
PION_CACHE_DIR="$CAS_P4" "$PIONC" test --deps --jobs 4 --json "$WS/app" > "$TMP_DIR/p4_hot.json"
# Passing extra `-l m` changes cli_libs -> must MISS testmeta (distinct test_src_key)
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_P4" "$PIONC" test --deps --jobs 4 -l m --json "$WS/app" \
  > "$TMP_DIR/p4_lm.json" 2> "$TMP_DIR/p4_lm.trace"
python3 - "$TMP_DIR/p1_cold.json" "$TMP_DIR/p1_hot.json" "$TMP_DIR/p4_cold.json" "$TMP_DIR/p4_hot.json" "$TMP_DIR/p4_lm.json" "$TMP_DIR/p4_lm.trace" <<'PYEOF'
import json, sys
j1c, j1h, j4c, j4h = [open(sys.argv[i]).read() for i in range(1, 5)]
assert j1c == j1h == j4c == j4h, "jobs 1 vs 4 cold/hot JSON parity mismatch"
dlm = json.load(open(sys.argv[5]))
tlm = open(sys.argv[6]).read()
assert dlm["ok"] is True and dlm["passed"] == 5, dlm
assert "[cas] testmeta=app MISS" in tlm, tlm
PYEOF
echo "(11) --jobs 1 vs --jobs 4 parity + cli_libs invalidation -> OK"

# ----------------------------------------------------------------------------
# 12. 0-byte `.pionstub` dependencies (empty `lib.pion` + small generic pkg)
#     under cold parallel `--jobs 4` (nmiss >= 2) vs `--jobs 1` JSON parity
# ----------------------------------------------------------------------------
WS_Z="$TMP_DIR/ws_zero_stub"
mkdir -p "$WS_Z/empty_dep/src" "$WS_Z/gen_dep/src" "$WS_Z/use_a/src" "$WS_Z/use_b/src" "$WS_Z/root/src"

cat > "$WS_Z/empty_dep/pion.toml" <<'EOF'
[package]
name = "empty_dep"
version = "0.1.0"
EOF
: > "$WS_Z/empty_dep/src/lib.pion"

cat > "$WS_Z/gen_dep/pion.toml" <<'EOF'
[package]
name = "gen_dep"
version = "0.1.0"
EOF
cat > "$WS_Z/gen_dep/src/lib.pion" <<'EOF'
pub fn id[T](x : T) -> T { x }
EOF

cat > "$WS_Z/use_a/pion.toml" <<'EOF'
[package]
name = "use_a"
version = "0.1.0"

[dependencies]
empty_dep = { path = "../empty_dep" }
gen_dep = { path = "../gen_dep" }
EOF
cat > "$WS_Z/use_a/src/lib.pion" <<'EOF'
import "empty_dep"
import "gen_dep"
pub fn a_val() -> Int { gen_dep::id(42) }
EOF
cat > "$WS_Z/use_a/src/use_a_test.pion" <<'EOF'
test "use_a_gen" { debug_assert(a_val() == 42, "use_a_gen") }
EOF

cat > "$WS_Z/use_b/pion.toml" <<'EOF'
[package]
name = "use_b"
version = "0.1.0"

[dependencies]
empty_dep = { path = "../empty_dep" }
gen_dep = { path = "../gen_dep" }
EOF
cat > "$WS_Z/use_b/src/lib.pion" <<'EOF'
import "empty_dep"
import "gen_dep"
pub fn b_val() -> String { gen_dep::id("ok") }
EOF
cat > "$WS_Z/use_b/src/use_b_test.pion" <<'EOF'
test "use_b_gen" { debug_assert(b_val() == "ok", "use_b_gen") }
EOF

cat > "$WS_Z/root/pion.toml" <<'EOF'
[package]
name = "root"
version = "0.1.0"

[dependencies]
use_a = { path = "../use_a" }
use_b = { path = "../use_b" }
EOF
cat > "$WS_Z/root/src/lib.pion" <<'EOF'
import "use_a"
import "use_b"
pub fn root_ok() -> Bool { use_a::a_val() == 42 && use_b::b_val() == "ok" }
EOF
cat > "$WS_Z/root/src/root_test.pion" <<'EOF'
test "root_both" { debug_assert(root_ok(), "root_both") }
EOF

CAS_Z1="$TMP_DIR/cas_z1"
CAS_Z4="$TMP_DIR/cas_z4"
mkdir -p "$CAS_Z1" "$CAS_Z4"
PION_CACHE_DIR="$CAS_Z1" "$PIONC" test --deps --jobs 1 --json "$WS_Z/root" > "$TMP_DIR/z_j1.json"
PION_CACHE_DIR="$CAS_Z4" "$PIONC" test --deps --jobs 4 --json "$WS_Z/root" > "$TMP_DIR/z_j4_cold.json"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_Z4" "$PIONC" test --deps --jobs 4 --json "$WS_Z/root" \
  > "$TMP_DIR/z_j4_hot.json" 2> "$TMP_DIR/z_j4_hot.trace"
python3 - "$TMP_DIR/z_j1.json" "$TMP_DIR/z_j4_cold.json" "$TMP_DIR/z_j4_hot.json" "$TMP_DIR/z_j4_hot.trace" "$CAS_Z4" <<'PYEOF'
import glob, json, os, sys
j1, j4c, j4h = open(sys.argv[1]).read(), open(sys.argv[2]).read(), open(sys.argv[3]).read()
tr = open(sys.argv[4]).read()
cas = sys.argv[5]
assert j1 == j4c == j4h, f"0-byte stub jobs 1 vs 4 mismatch:\n{j1}\n{j4c}\n{j4h}"
d = json.loads(j4c)
assert d["ok"] is True and d["total"] == 3 and d["passed"] == 3 and d["failed"] == 0, d
assert "MISS" not in tr and "[test] bins built=0" in tr, tr
# Confirm at least one 0-byte .pionstub actually existed in CAS_Z4
stubs = glob.glob(os.path.join(cas, "sig", "*.pionstub"))
zero_stubs = [s for s in stubs if os.path.getsize(s) == 0]
assert len(zero_stubs) >= 2, f"expected >=2 zero-byte .pionstub files, found {len(zero_stubs)} in {stubs}"
PYEOF
echo "(12) 0-byte .pionstub (empty lib + small generic pkg) cold --jobs 4 vs --jobs 1 parity -> OK"

echo "PASS: testmeta_cas"
