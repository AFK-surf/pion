#!/bin/sh
# Public-safe end-to-end verification suite for `mbt2pion` CLI:
# 1. Golden `.mbt` -> `.pion` full-byte equality (including platform-neutral headers) + `--check`
# 2. Generated golden package passes `pionc check --json` AND real `pionc run` runtime assertions
#    (val_guard_demo, guard_is_demo, first_val topological init, relay optional forwarding,
#     leading generics, ctor rest pattern, non-primitive struct Eq, same-line multi-probe, complex receivers)
# 3. Idempotency + dual clean absolute paths produce 100% identical bytes (including headers)
# 4. Project-agnostic proof: (a) no-map generic fixture AND (b) alternate-namespace `acme` fixture
#    asserting ZERO forbidden project identifiers
# 5. Negative mutation tests (untagged unit, stale overlay, unknown derive, init cycle)
#    all exit non-zero and `--mode publish` never modifies `--out`!

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PIONC="${1:-${PIONC:-$HOME/.pion/bin/pionc}}"
if [ ! -x "$PIONC" ]; then
  PIONC="$(command -v pionc)"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mbt2pion-e2e.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/mbt2pion"
echo "[e2e] building mbt2pion CLI with $PIONC..."
"$PIONC" build "$REPO_ROOT/tools/mbt2pion_cli" -o "$BIN"

# Link directly against the real repository `tools/mbt_compat` package (no stub!).
COMPAT_DIR="$REPO_ROOT/tools/mbt_compat"

# -----------------------------------------------------------------------------
# Test 1 + 2 + 3: Golden, pionc check, pionc run, idempotency, dual clean paths
# -----------------------------------------------------------------------------
SRC_A="$WORK/path_alpha/src"
SRC_B="$WORK/path_beta/src"
OUT_A="$WORK/path_alpha/out"
OUT_B="$WORK/path_beta/out"
mkdir -p "$SRC_A" "$SRC_B"

cat > "$SRC_A/demo.mbt" << 'EOF'
pub enum Tri {
  Tri(Int, b~ : Int, c~ : Int)
  Empty
}

#derive(Eq)
pub(all) struct Rec {
  opt : Int?
  arr : Array[Int]
}

pub(all) struct Holder {
  text : String
  items : Array[Int]
}

pub fn[T] id(x : T) -> T {
  x
}

pub fn match_tri(t : Tri) -> Int {
  match t {
    Tri(a, ..) => a
    Empty => 0
  }
}

#callsite(autofill(loc))
pub fn audit_log(msg : String, loc~ : SourceLoc) -> String {
  msg + "@" + loc.to_string()
}

pub fn val_guard_demo(flag : Bool) -> Int {
  guard flag else { 17 }
  42
}

pub fn guard_is_demo(opt : Int?) -> Int {
  guard opt is Some(v) else { 17 }
  v + 1
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

pub fn cascade_demo(h : Holder, val : Int) -> Array[Int] {
  let inc = (n : Int) => n + val
  h.items..push(inc(1))..push(2)
}

pub fn probe_demo(h : Holder, s : String, arr : Array[Int], a : Int, b : Int, d : Double) -> Int {
  let same_line = s.length() + arr.length()
  let chained = h.text.length()
  let q = (a + b) / b
  let fast = a / 2
  let _ = d.to_string()
  same_line + chained + q + fast
}

pub fn fmt_double_demo(d : Double) -> String {
  d.to_string()
}

pub fn utf16_len_demo(s : String) -> Int {
  s.length()
}

pub fn str_cmp_demo(a : String, b : String) -> Int {
  a.compare(b)
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
  --mbt-compat "$COMPAT_DIR" \
  --mbt2pion-commit "test-sha" --toolchain-lock "lock-v1" --source-commit "src-v1" \
  --report "$WORK/report_a.json" --drift-ledger "$WORK/drift_a.json" --run-report "$WORK/run_a.json" \
  --pionc "$PIONC"

# Verify `--check` passes with 0 diff
"$BIN" --src "$SRC_A" --out "$OUT_A" --target native --check \
  --mbt-compat "$COMPAT_DIR" \
  --mbt2pion-commit "test-sha" --toolchain-lock "lock-v1" --source-commit "src-v1" \
  --pionc "$PIONC"

# Run from a second completely different absolute path
"$BIN" --src "$SRC_B" --out "$OUT_B" --target native --mode publish \
  --mbt-compat "$COMPAT_DIR" \
  --mbt2pion-commit "test-sha" --toolchain-lock "lock-v1" --source-commit "src-v1" \
  --report "$WORK/report_b.json" --drift-ledger "$WORK/drift_b.json" --run-report "$WORK/run_b.json" \
  --pionc "$PIONC"

# Full-byte equality including headers across dual clean absolute paths!
diff -ru "$OUT_A" "$OUT_B"
echo "[e2e] PASS: dual clean absolute paths full-byte identical (including headers)"

# Verify Stage A.5 same-line multi-probe + complex receivers + canonical mbt_compat names + 0 residuals
grep -q "mbt_compat::utf16_len(s) + arr.length()" "$OUT_A/demo.pion"
grep -q "mbt_compat::utf16_len(h.text)" "$OUT_A/demo.pion"
grep -q "mbt_compat::div_checked_i32((a + b), b)" "$OUT_A/demo.pion"
grep -q "a / 2" "$OUT_A/demo.pion"
grep -q "mbt_compat::double_to_string(d)" "$OUT_A/demo.pion"
if grep -q "mbt_.*_probe" "$OUT_A/demo.pion"; then
  echo "[e2e] FAIL: probe residual found!"
  exit 1
fi
echo "[e2e] PASS: Stage A.5 same-line multi-probe + complex receivers + 0 residuals"

# Verify auto-emitted `import "mbt_compat"` below platform-neutral header (BUG-2: zero manual import hack!)
grep -q '^import "mbt_compat"$' "$OUT_A/demo.pion"
# Verify generated golden output passes `pionc check --json` AND real `pionc run` runtime behavior!
PKG_CHK="$WORK/chk_pkg"
mkdir -p "$PKG_CHK/src"
cat > "$PKG_CHK/pion.toml" << EOF
[package]
name = "golden_chk"
version = "0.1.0"

[dependencies]
mbt_compat = { path = "$COMPAT_DIR" }
EOF
cp "$OUT_A/demo.pion" "$PKG_CHK/src/demo.pion"
cp "$OUT_A/00_init_order.pion" "$PKG_CHK/src/00_init_order.pion"
cat > "$PKG_CHK/src/main.pion" << 'EOF'
pub fn main(_w : World) -> Int {
  if val_guard_demo(false) != 17 { panic("val_guard_demo(false)") }
  if val_guard_demo(true) != 42 { panic("val_guard_demo(true)") }
  if guard_is_demo(None) != 17 { panic("guard_is_demo(None)") }
  if guard_is_demo(Some(5)) != 6 { panic("guard_is_demo(Some(5))") }
  if first_val != 42 { panic("first_val topo init") }
  if relay(10) != 27 { panic("relay(10)") }
  if relay(10, x=3) != 13 { panic("relay(10, x=3)") }
  if id(99) != 99 { panic("leading generic id") }
  if match_tri(Tri(7, 8, 9)) != 7 { panic("ctor rest pattern") }
  let r1 = Rec::{ opt: Some(5), arr: [1, 2] }
  let r2 = Rec::{ opt: Some(5), arr: [1, 2] }
  let r3 = Rec::{ opt: Some(5), arr: [1, 3] }
  if !__mbt_eq_rec(r1, r2) { panic("structural eq true") }
  if __mbt_eq_rec(r1, r3) { panic("structural eq false") }
  let h = Holder::{ text: "abc", items: [10] }
  let out_items = cascade_demo(h, 5)
  if out_items.length() != 3 { panic("chained cascade") }
  if probe_demo(h, "hi", [1, 2, 3], 10, 2, 1.5) != 19 { panic("probe_demo runtime") }
  // Real mbt_compat behavioral assertions (cannot be satisfied by a trivial stub!):
  if utf16_len_demo("A中😀B") != 5 { panic("real mbt_compat utf16_len") }
  if fmt_double_demo(0.00000015) != "1.5e-7" { panic("real mbt_compat double_to_string") }
  if str_cmp_demo("k9", "alpha") >= 0 { panic("real mbt_compat str_compare") }
  0
}
EOF
"$PIONC" check --json "$PKG_CHK"
"$PIONC" run "$PKG_CHK"
if command -v node >/dev/null 2>&1; then
  "$PIONC" run --target wasm32 "$PKG_CHK"
  echo "[e2e] PASS: generated golden package passes pionc check --json, native pionc run, AND wasm32 pionc run against real tools/mbt_compat"
else
  echo "[e2e] PASS: generated golden package passes pionc check --json AND live pionc run against real tools/mbt_compat"
fi

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

#derive(Eq)
pub enum Mode {
  Off
  On(Int)
}

pub fn make_item() -> Ref[Int] {
  let _ = Center
  { val: 7 }
}
EOF
"$BIN" --src "$ACME_SRC" --out "$ACME_OUT" --target native --mode audit \
  --api-map "$WORK/acme_map.json" --recipes "$WORK/acme_recipes.toml" \
  --no-probes --pionc "$PIONC"

# Assert ZERO forbidden project identifiers in both no-map and alternate-namespace outputs
for dir in "$OUT_A" "$ACME_OUT"; do
  if grep -E -i '\b(invar|monoid|still\.fail)\b|(signals::|view::)' "$dir"/*.pion; then
    echo "[e2e] FAIL: project-specific identifier leaked into $dir"
    exit 1
  fi
done
grep -q "acme_ns::Align::Center" "$ACME_OUT/app.pion"
grep -q "acme_ns::make_ref(7)" "$ACME_OUT/app.pion"
grep -q "impl acme_ns::TrackEq for Item" "$ACME_OUT/app.pion"
grep -q "impl acme_ns::TrackEq for Mode" "$ACME_OUT/app.pion"
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
if "$BIN" --src "$ACME_SRC" --out "$NEG_OUT" --target native --mode publish --api-map "$WORK/bad_map.json" --pionc "$PIONC" 2>/dev/null; then
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
if "$BIN" --src "$NEG_DERIVE" --out "$NEG_OUT" --target native --mode publish --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: unknown #derive should have exited non-zero"
  exit 1
fi
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"

# 5c. Cyclic top-level initialization
NEG_CYC="$WORK/neg_cyc"
mkdir -p "$NEG_CYC"
cat > "$NEG_CYC/cyc.mbt" << 'EOF'
let a : Int = b + 1
let b : Int = a + 1
EOF
if "$BIN" --src "$NEG_CYC" --out "$NEG_OUT" --target native --mode publish --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: cyclic init should have exited non-zero"
  exit 1
fi
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"

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
if "$BIN" --src "$NEG_OV_SRC" --out "$NEG_OUT" --target native --mode publish --overlay-dir "$NEG_OV_DIR" --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: stale overlay should have exited non-zero"
  exit 1
fi
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"

# 5e. `--no-probes` is strictly forbidden in `--mode publish` (P0-2)
if "$BIN" --src "$SRC_A" --out "$NEG_OUT" --target native --mode publish --no-probes --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: --no-probes in --mode publish should have exited non-zero"
  exit 1
fi
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"

# 5f. Nonexistent `--pionc` fails hard in `--mode publish` (P0-2)
if "$BIN" --src "$SRC_A" --out "$NEG_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --pionc "/nonexistent/pionc" 2>/dev/null; then
  echo "[e2e] FAIL: nonexistent --pionc should have exited non-zero"
  exit 1
fi
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"

# 5g. Missing `--src` directory fails non-zero and never wipes `--out` (P0-4)
if "$BIN" --src "$WORK/does_not_exist" --out "$NEG_OUT" --target native --mode publish --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: missing --src should have exited non-zero"
  exit 1
fi
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"

# 5h. Hand-written `main.pion` preserved; stale managed `.pion` pruned; `--check` catches extra managed `.pion` (P0-4)
echo "// hand-written entry" > "$OUT_A/main.pion"
echo "// GENERATED BY mbt2pion — DO NOT HAND-EDIT" > "$OUT_A/stale_extra.pion"
if "$BIN" --src "$SRC_A" --out "$OUT_A" --target native --check --mbt-compat "$COMPAT_DIR" --mbt2pion-commit "test-sha" --toolchain-lock "lock-v1" --source-commit "src-v1" --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: --check should have detected unexpected stale managed file"
  exit 1
fi
"$BIN" --src "$SRC_A" --out "$OUT_A" --target native --mode publish --mbt-compat "$COMPAT_DIR" --mbt2pion-commit "test-sha" --toolchain-lock "lock-v1" --source-commit "src-v1" --pionc "$PIONC"
test -f "$OUT_A/main.pion"
test ! -f "$OUT_A/stale_extra.pion"

# 5i. Destination path occupied by directory exits non-zero and leaves no `.mbt2pion.*.tmp` (P0-4)
OCC_OUT="$WORK/occ_out"
mkdir -p "$OCC_OUT/demo.pion"
if "$BIN" --src "$SRC_A" --out "$OCC_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: directory-occupied destination should have exited non-zero"
  exit 1
fi
if ls "$OCC_OUT"/*.tmp 2>/dev/null; then
  echo "[e2e] FAIL: leftover .tmp file after failed publish"
  exit 1
fi
echo "[e2e] PASS: all negative & atomic-publish tests rejected & preserved --out / hand-written files"

# -----------------------------------------------------------------------------
# Test 6: Cross-package live pionc check + run covering BUG-1..BUG-7
#   (.mbti pkg extraction, auto-imports, nested generic T?, Ref(expr),
#    closure init order, ambiguous cross-pkg .Middle, [derives] ignore, Ctor(..))
# -----------------------------------------------------------------------------
XPKG_P1="$WORK/xpkg_p1"
XPKG_P2="$WORK/xpkg_p2"
XPKG_SRC="$WORK/xpkg_src"
XPKG_APP="$WORK/xpkg_app"
mkdir -p "$XPKG_P1/src" "$XPKG_P2/src" "$XPKG_SRC/deps" "$XPKG_APP/src"

cat > "$XPKG_P1/pion.toml" << 'EOF'
[package]
name = "p1"
version = "0.1.0"
EOF
cat > "$XPKG_P1/src/lib.pion" << 'EOF'
pub enum AlignA {
  Top
  Middle
  Bottom
}
pub struct Cell[T] {
  pub mut v : T
}
pub fn make_cell[T](x : T) -> Cell[T] {
  Cell::{ v: x }
}
pub fn read_cell[T](c : Cell[T]) -> T {
  c.v
}
pub fn take_a(a : AlignA) -> Int {
  match a {
    Top => 1
    Middle => 2
    Bottom => 3
  }
}
EOF

cat > "$XPKG_P2/pion.toml" << 'EOF'
[package]
name = "p2"
version = "0.1.0"
EOF
cat > "$XPKG_P2/src/lib.pion" << 'EOF'
pub enum AlignB {
  Left
  Middle
  Right
}
pub fn take_b(b : AlignB) -> Int {
  match b {
    Left => 10
    Middle => 20
    Right => 30
  }
}
EOF

cat > "$XPKG_SRC/deps/p1.mbti" << 'EOF'
package "org/repo/p1"

pub enum AlignA {
  Top
  Middle
  Bottom
}
EOF
cat > "$XPKG_SRC/deps/p2.mbti" << 'EOF'
package "org/repo/p2"

pub enum AlignB {
  Left
  Middle
  Right
}
EOF

cat > "$WORK/xpkg_recipes.toml" << 'EOF'
[ref]
enabled = true
ctor_call = "p1::make_cell"
field_name = "v"
type_name = "p1::Cell"

[derives]
ignore = ["Debug"]
EOF

cat > "$XPKG_SRC/app_lib.mbt" << 'EOF'
#derive(Debug, Eq)
pub(all) struct Wrap {
  x : Int
}

pub enum Trio {
  Trio(Int, Int, Int)
  Nil
}

let deferred_fn : () -> Int = fn() { base_num }
let base_num : Int = 20

pub fn xpkg_smoke(xs : Array[(Int?, String?)]) -> Int {
  let local_xs : Array[(Int?, String?)] = xs
  let c = Ref(base_num)
  let a = @p1.take_a(Middle)
  let b = @p2.take_b(Middle)
  let t = match Trio(1, 2, 3) {
    Trio(..) => 100
    Nil => 0
  }
  let call_def = deferred_fn
  @p1.read_cell(c) + call_def() + a + b + t + local_xs.length()
}
EOF

"$BIN" --src "$XPKG_SRC" --out "$XPKG_APP/src" --target native --mode publish \
  --recipes "$WORK/xpkg_recipes.toml" \
  --mbt-compat "$COMPAT_DIR" \
  --dep "p1=$XPKG_P1" --dep "p2=$XPKG_P2" \
  --pionc "$PIONC"

grep -q '^import "p1"$' "$XPKG_APP/src/app_lib.pion"
grep -q '^import "p2"$' "$XPKG_APP/src/app_lib.pion"
grep -q 'p1::take_a(.Middle)' "$XPKG_APP/src/app_lib.pion"
grep -q 'p2::take_b(.Middle)' "$XPKG_APP/src/app_lib.pion"
grep -q 'p1::make_cell(base_num)' "$XPKG_APP/src/app_lib.pion"
grep -q 'Array\[(Option\[Int\], Option\[String\])\]' "$XPKG_APP/src/app_lib.pion"

cat > "$XPKG_APP/pion.toml" << EOF
[package]
name = "xpkg_app"
version = "0.1.0"

[dependencies]
p1 = { path = "$XPKG_P1" }
p2 = { path = "$XPKG_P2" }
EOF
cat > "$XPKG_APP/src/main.pion" << 'EOF'
pub fn main(_w : World) -> Int {
  let got = xpkg_smoke([(Some(1), None)])
  if got != 163 { panic("xpkg_smoke mismatch") }
  0
}
EOF
"$PIONC" check --json "$XPKG_APP"
"$PIONC" run "$XPKG_APP"
echo "[e2e] PASS: cross-package BUG-1..BUG-7 live pionc check + run (auto-imports, .Middle, nested T?, Ref(expr), closure init, derive ignore, Ctor(..))"

echo "[e2e] ALL E2E TESTS PASSED!"
