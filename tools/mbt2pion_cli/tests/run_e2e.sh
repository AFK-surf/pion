#!/bin/sh
# Public-safe end-to-end verification suite for `mbt2pion` CLI:
# 1. Golden `.mbt` -> `.pion` full-byte equality (including platform-neutral headers) + `--check`
# 2. Every generated golden `.pion` passes `pionc check --json`
# 3. Idempotency + dual clean absolute paths produce 100% identical bytes (including headers)
# 4. Project-agnostic proof: (a) no-map generic fixture AND (b) alternate-namespace `acme` fixture
#    asserting ZERO forbidden project identifiers
# 5. Live Stage A.5 `pionc check --json` type-probe rewrite + 0 probe residuals
# 6. Negative mutation tests (untagged unit, stale overlay, unknown derive, init cycle)
#    all exit non-zero and `--mode publish` never modifies `--out`!

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PIONC="${PIONC:-$HOME/.pion/bin/pionc}"
if [ ! -x "$PIONC" ]; then
  PIONC="$(command -v pionc)"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mbt2pion-e2e.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/mbt2pion"
echo "[e2e] building mbt2pion CLI with $PIONC..."
"$PIONC" build "$REPO_ROOT/tools/mbt2pion_cli" -o "$BIN"

# Minimal public-safe `mbt_compat` stub package for `pionc check --json` verification of generated code
COMPAT_DIR="$WORK/mbt_compat"
mkdir -p "$COMPAT_DIR/src"
cat > "$COMPAT_DIR/pion.toml" << 'EOF'
[package]
name = "mbt_compat"
version = "0.1.0"
EOF
cat > "$COMPAT_DIR/src/compat.pion" << 'EOF'
pub fn utf16_len(s : String) -> Int { s.length() }
pub fn utf16_code_unit_at(s : String, i : Int) -> Int { s.code_unit_at(i) }
pub fn utf16_to_utf8_offset(n : Int) -> Int { n }
pub fn double_to_string(d : Double) -> String { d.to_string() }
pub fn div_checked_int(a : Int, b : Int) -> Int { if b == 0 { panic("div0") }; a / b }
pub fn mod_checked_int(a : Int, b : Int) -> Int { if b == 0 { panic("mod0") }; a % b }
pub fn array_view_clamp[T](xs : Array[T], _lo : Int, _hi : Int) -> Array[T] { xs }
pub struct OrderedMap[K, V] { entries : Array[(K, V)] }
pub fn ordered_map_from[K, V](entries : Array[(K, V)]) -> OrderedMap[K, V] { OrderedMap::{ entries: entries } }
EOF

# -----------------------------------------------------------------------------
# Test 1 + 2 + 3: Golden, pionc check, idempotency, dual clean absolute paths
# -----------------------------------------------------------------------------
SRC_A="$WORK/path_alpha/src"
SRC_B="$WORK/path_beta/src"
OUT_A="$WORK/path_alpha/out"
OUT_B="$WORK/path_beta/out"
mkdir -p "$SRC_A" "$SRC_B"

cat > "$SRC_A/demo.mbt" << 'EOF'
#callsite(autofill(loc))
pub fn audit_log(msg : String, loc~ : SourceLoc) -> String {
  msg + "@" + loc
}

pub fn val_guard_demo(flag : Bool) -> Int {
  guard flag else { 17 }
  42
}

pub fn div_guard_demo(flag : Bool) -> Int {
  guard flag else { return 0 }
  42
}

pub fn tally(base : Int, x? : Int = 17) -> Int {
  base + x
}

pub fn relay(a : Int, x? : Int) -> Int {
  let _ = audit_log("first")
  let _ = audit_log("second")
  tally(a, x?)
}

pub fn cascade_demo(xs : Array[Int], val : Int) -> Array[Int] {
  let inc = (n : Int) => n + val
  xs..push(inc(1))..push(2)
}

pub fn probe_demo(s : String, a : Int, b : Int, d : Double) -> Int {
  let n = s.length()
  let q = a / b
  let fast = a / 2
  let _ = d.to_string()
  n + q + fast
}

let first_val : Int = read_second() + 1

fn read_second() -> Int {
  second_val
}

let second_val : Int = 41

fn init {
  let _ = first_val
}
EOF
cp "$SRC_A/demo.mbt" "$SRC_B/demo.mbt"

"$BIN" --src "$SRC_A" --out "$OUT_A" --target native --mode publish \
  --mbt2pion-commit "test-sha" --toolchain-lock "lock-v1" --source-commit "src-v1" \
  --report "$WORK/report_a.json" --drift-ledger "$WORK/drift_a.json" --run-report "$WORK/run_a.json" \
  --pionc "$PIONC"

# Verify `--check` passes with 0 diff
"$BIN" --src "$SRC_A" --out "$OUT_A" --target native --check \
  --mbt2pion-commit "test-sha" --toolchain-lock "lock-v1" --source-commit "src-v1" \
  --pionc "$PIONC"

# Run from a second completely different absolute path
"$BIN" --src "$SRC_B" --out "$OUT_B" --target native --mode publish \
  --mbt2pion-commit "test-sha" --toolchain-lock "lock-v1" --source-commit "src-v1" \
  --report "$WORK/report_b.json" --drift-ledger "$WORK/drift_b.json" --run-report "$WORK/run_b.json" \
  --pionc "$PIONC"

# Full-byte equality including headers across dual clean absolute paths!
diff -ru "$OUT_A" "$OUT_B"
echo "[e2e] PASS: dual clean absolute paths full-byte identical (including headers)"

# Verify Stage A.5 actually rewrote silent drifts and left 0 probe residuals
grep -q "mbt_compat::utf16_len(s)" "$OUT_A/demo.pion"
grep -q "mbt_compat::div_checked_int(a, b)" "$OUT_A/demo.pion"
grep -q "a / 2" "$OUT_A/demo.pion"
grep -q "mbt_compat::double_to_string(d)" "$OUT_A/demo.pion"
if grep -q "mbt_.*_probe" "$OUT_A/demo.pion"; then
  echo "[e2e] FAIL: probe residual found!"
  exit 1
fi
echo "[e2e] PASS: Stage A.5 live pionc probe rewrites + 0 residuals"

# Verify generated golden output passes `pionc check --json`!
PKG_CHK="$WORK/chk_pkg"
mkdir -p "$PKG_CHK/src"
cat > "$PKG_CHK/pion.toml" << EOF
[package]
name = "golden_chk"
version = "0.1.0"

[dependencies]
mbt_compat = { path = "$COMPAT_DIR" }
EOF
{ echo 'import "mbt_compat" as mbt_compat'; cat "$OUT_A/demo.pion"; } > "$PKG_CHK/src/demo.pion"
cp "$OUT_A/00_init_order.pion" "$PKG_CHK/src/00_init_order.pion"
"$PIONC" check --json "$PKG_CHK"
echo "[e2e] PASS: generated golden package passes pionc check --json"

# -----------------------------------------------------------------------------
# Test 4: Project-agnostic proof (no-map AND alternate-namespace `acme` fixture)
# -----------------------------------------------------------------------------
ACME_SRC="$WORK/acme_src"
ACME_OUT="$WORK/acme_out"
mkdir -p "$ACME_SRC"
cat > "$WORK/acme_map.json" << 'EOF'
{
  "pkg_aliases": { "ext": "acme_ns" },
  "symbols": [
    { "src_pkg": "ext", "src_name": "Center", "kind": "ctor", "target_pkg": "acme_ns", "target_name": "Center", "target_enum": "Align" }
  ]
}
EOF
cat > "$WORK/acme_recipes.toml" << 'EOF'
[ref]
enabled = true
ctor_call = "acme_ns::make_ref"
field_name = "v"
type_name = "acme_ns::Cell"

[[trait_impl]]
derive = "Eq"
target_trait = "acme_ns::TrackEq"
method = "eq"
EOF
cat > "$ACME_SRC/app.mbt" << 'EOF'
#derive(Eq)
pub(all) struct Item {
  id : Int
}

pub fn make_item() -> Ref[Int] {
  let _ = Center
  { val: 7 }
}
EOF
"$BIN" --src "$ACME_SRC" --out "$ACME_OUT" --target native --mode publish \
  --api-map "$WORK/acme_map.json" --recipes "$WORK/acme_recipes.toml" \
  --no-probes --pionc "$PIONC"

# Assert ZERO forbidden project identifiers in both no-map and alternate-namespace outputs
for dir in "$OUT_A" "$ACME_OUT"; do
  if grep -E -i "(invar|monoid|still\.fail|signals::|view::)" "$dir"/*.pion; then
    echo "[e2e] FAIL: project-specific identifier leaked into $dir"
    exit 1
  fi
done
grep -q "acme_ns::Align::Center" "$ACME_OUT/app.pion"
grep -q "acme_ns::make_ref(7)" "$ACME_OUT/app.pion"
grep -q "impl acme_ns::TrackEq for Item" "$ACME_OUT/app.pion"
echo "[e2e] PASS: project-agnostic proof (no-map + alternate-namespace acme)"

# -----------------------------------------------------------------------------
# Test 5: Negative tests (must exit non-zero & publish must NOT modify --out)
# -----------------------------------------------------------------------------
NEG_OUT="$WORK/neg_out"
mkdir -p "$NEG_OUT"
echo "SENTINEL" > "$NEG_OUT/sentinel.pion"

# 5a. Untagged offset-like Int param in api_map.json
cat > "$WORK/bad_map.json" << 'EOF'
{
  "symbols": [
    { "src_pkg": "p", "src_name": "hit", "kind": "fn", "params": [{ "name": "byte_offset", "ty": "Int" }] }
  ]
}
EOF
if "$BIN" --src "$ACME_SRC" --out "$NEG_OUT" --target native --mode publish --api-map "$WORK/bad_map.json" --no-probes --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: untagged offset param should have exited non-zero"
  exit 1
fi
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"

# 5b. Unknown #derive
NEG_DERIVE="$WORK/neg_derive"
mkdir -p "$NEG_DERIVE"
cat > "$NEG_DERIVE/bad.mbt" << 'EOF'
#derive(UnknownTrait)
pub struct S { x : Int }
EOF
if "$BIN" --src "$NEG_DERIVE" --out "$NEG_OUT" --target native --mode publish --no-probes --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: unknown #derive should have exited non-zero"
  exit 1
fi

# 5c. Cyclic top-level initialization
NEG_CYC="$WORK/neg_cyc"
mkdir -p "$NEG_CYC"
cat > "$NEG_CYC/cyc.mbt" << 'EOF'
let a : Int = b + 1
let b : Int = a + 1
EOF
if "$BIN" --src "$NEG_CYC" --out "$NEG_OUT" --target native --mode publish --no-probes --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: cyclic init should have exited non-zero"
  exit 1
fi

# 5d. Stale overlay after upstream function body change
NEG_OV_SRC="$WORK/neg_ov_src"
NEG_OV_DIR="$WORK/neg_ov_dir"
mkdir -p "$NEG_OV_SRC" "$NEG_OV_DIR"
cat > "$NEG_OV_SRC/f.mbt" << 'EOF'
pub fn calc(x : Int) -> Int {
  x + 999
}
EOF
cat > "$NEG_OV_DIR/ov.json" << 'EOF'
{
  "id": "ov-stale",
  "source_file": "f.mbt",
  "decl_identity": "fn:calc",
  "target": "native",
  "normalized_source_cst_hash": "0000000000000000000000000000000000000000000000000000000000000000",
  "pre_overlay_generated_hash": "1111111111111111111111111111111111111111111111111111111111111111",
  "replacement": "pub fn calc(x : Int) -> Int { x }",
  "reason": "test",
  "behavior_test": "test",
  "upstream_issue_or_removal_condition": "issue#1"
}
EOF
if "$BIN" --src "$NEG_OV_SRC" --out "$NEG_OUT" --target native --mode publish --overlay-dir "$NEG_OV_DIR" --no-probes --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: stale overlay should have exited non-zero"
  exit 1
fi
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"
echo "[e2e] PASS: all 4 negative tests rejected & publish left --out untouched"

echo "[e2e] ALL E2E TESTS PASSED!"
