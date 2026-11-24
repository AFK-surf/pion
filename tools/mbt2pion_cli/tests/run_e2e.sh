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
pub(all) enum Tri {
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

# 5j. `--check --no-probes` rejected (Astra P0-1)
if "$BIN" --src "$SRC_A" --out "$OUT_A" --target native --check --no-probes --mbt-compat "$COMPAT_DIR" --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: --check --no-probes should have exited non-zero"
  exit 1
fi

# 5k. Hand-written unmanaged file collision rejected without overwriting + dual-file atomic rollback (Astra P0-1 + P0-2)
ATOM_SRC="$WORK/atom_src"
ATOM_OUT="$WORK/atom_out"
mkdir -p "$ATOM_SRC" "$ATOM_OUT"
cat > "$ATOM_SRC/a.mbt" << 'EOF'
pub fn fa() -> Int { 1 }
EOF
cat > "$ATOM_SRC/b.mbt" << 'EOF'
pub fn fb() -> Int { 1 }
EOF
"$BIN" --src "$ATOM_SRC" --out "$ATOM_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --pionc "$PIONC"
# Replace b.pion with hand-written unmanaged file, mutate a.mbt to v2, attempt publish -> MUST fail and keep a.pion at v1!
echo "pub fn fb() -> Int { 999 }" > "$ATOM_OUT/b.pion"
cat > "$ATOM_SRC/a.mbt" << 'EOF'
pub fn fa() -> Int { 2 }
EOF
if "$BIN" --src "$ATOM_SRC" --out "$ATOM_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: unmanaged file collision should have exited non-zero"
  exit 1
fi
grep -q "pub fn fa() -> Int { 1 }" "$ATOM_OUT/a.pion"
grep -q "pub fn fb() -> Int { 999 }" "$ATOM_OUT/b.pion"

# 5l. Hand-written `driver.pion` with duplicate `fn fa` caught by final check gate (Astra P0-1)
DUP_OUT="$WORK/dup_out"
mkdir -p "$DUP_OUT"
echo "pub fn fa() -> Int { 777 }" > "$DUP_OUT/driver.pion"
if "$BIN" --src "$ATOM_SRC" --out "$DUP_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: duplicate def with preserved unmanaged driver.pion should have been rejected"
  exit 1
fi
test ! -f "$DUP_OUT/a.pion"

# 5m. Same-file String slice + param Array borrowed slice MUST STILL block publish (Astra P0-4)
MIX_SLICE_SRC="$WORK/mix_slice_src"
MIX_SLICE_OUT="$WORK/mix_slice_out"
mkdir -p "$MIX_SLICE_SRC" "$MIX_SLICE_OUT"
cat > "$MIX_SLICE_SRC/mix.mbt" << 'EOF'
pub fn bad_mix(s : String, xs : Array[Int]) -> Int {
  let _ = s[0:1]
  let _ = xs[0:1]
  0
}
EOF
if "$BIN" --src "$MIX_SLICE_SRC" --out "$MIX_SLICE_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --pionc "$PIONC" 2>/dev/null; then
  echo "[e2e] FAIL: unresolved param Array slice in same file as String slice should have blocked publish"
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
pub fn label(n : Int) -> String {
  if n > 0 { "A中😀B" } else { "" }
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
  @p1.read_cell(c) + call_def() + a + b + t + local_xs.length() + @p1.label(base_num).length()
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
mbt_compat = { path = "$COMPAT_DIR" }
EOF
cat > "$XPKG_APP/src/main.pion" << 'EOF'
pub fn main(_w : World) -> Int {
  let got = xpkg_smoke([(Some(1), None)])
  if got != 168 { panic("xpkg_smoke mismatch") }
  0
}
EOF
"$PIONC" check --json "$XPKG_APP"
"$PIONC" run "$XPKG_APP"
echo "[e2e] PASS: cross-package BUG-1..BUG-7 live pionc check + run (auto-imports, .Middle, nested T?, Ref(expr), closure init, derive ignore, Ctor(..))"

# -----------------------------------------------------------------------------
# Test 7: Round 3 Astra structural acceptance tests (P0-1, P0-2, P0-4, P1-2)
# -----------------------------------------------------------------------------
python3 - "$BIN" "$PIONC" "$COMPAT_DIR" "$WORK/r3_tests" << 'PY'
import json, os, stat, subprocess, sys, threading

bin_path, pionc, compat_dir, root = sys.argv[1:5]
os.makedirs(root, exist_ok=True)

def run_cli(args, cwd=None):
    return subprocess.run([bin_path] + args, capture_output=True, text=True, cwd=cwd)

# 7a. P0-1: preserve mode 0000 file, mode 0751 binary file, symlink, empty dir + reports inside --out
s1 = os.path.join(root, "s1")
o1 = os.path.join(root, "o1")
os.makedirs(s1, exist_ok=True)
os.makedirs(o1, exist_ok=True)
with open(os.path.join(s1, "a.mbt"), "w") as f:
    f.write("pub fn f() -> Int { 1 }\n")
readme = os.path.join(o1, "readme")
with open(readme, "wb") as f: f.write(b"persist")
os.chmod(readme, 0o000)
orig = os.path.join(o1, "original")
with open(orig, "wb") as f: f.write(b"ab\x00\xffc")
os.chmod(orig, 0o751)
alias = os.path.join(o1, "alias")
os.symlink("original", alias)
empty_d = os.path.join(o1, "empty")
os.makedirs(empty_d, exist_ok=True)

rep_in = os.path.join(o1, "migration_report.json")
drf_in = os.path.join(o1, "drift_ledger.json")
r = run_cli(["--src", s1, "--out", o1, "--target", "native", "--mode", "publish",
             "--mbt-compat", compat_dir, "--pionc", pionc,
             "--report", rep_in, "--drift-ledger", drf_in])
assert r.returncode == 0, f"7a publish failed: {r.returncode} {r.stderr}"
assert os.path.isfile(os.path.join(o1, "a.pion")), "7a missing a.pion"
assert os.path.exists(readme) and (os.lstat(readme).st_mode & 0o777) == 0o000, "7a mode 0000 lost"
assert os.path.exists(orig) and (os.lstat(orig).st_mode & 0o777) == 0o751, "7a mode 0751 lost"
with open(orig, "rb") as f: assert f.read() == b"ab\x00\xffc", "7a binary bytes corrupted"
assert os.path.islink(alias) and os.readlink(alias) == "original", "7a symlink corrupted"
assert os.path.isdir(empty_d) and not os.path.islink(empty_d), "7a empty dir lost"
assert os.path.isfile(rep_in) and json.load(open(rep_in))["blockers"] == 0, "7a in-out report missing"
assert os.path.isfile(drf_in) and json.load(open(drf_in))["unresolved_entries"] == 0, "7a in-out drift missing"
# restore readme mode so trap rm -rf succeeds cleanly
os.chmod(readme, 0o644)

# 7b. P0-1: zero ENOENT under concurrent reader across 10 consecutive publishes
enoent_count = [0]
stop_flag = [False]
def reader():
    while not stop_flag[0]:
        try:
            os.stat(o1)
        except FileNotFoundError:
            enoent_count[0] += 1
th = threading.Thread(target=reader)
th.start()
try:
    for idx in range(10):
        with open(os.path.join(s1, "a.mbt"), "w") as f:
            f.write(f"pub fn f() -> Int {{ {idx + 1} }}\n")
        rr = run_cli(["--src", s1, "--out", o1, "--target", "native", "--mode", "publish",
                      "--mbt-compat", compat_dir, "--pionc", pionc])
        assert rr.returncode == 0, f"7b publish #{idx} failed: {rr.stderr}"
finally:
    stop_flag[0] = True
    th.join()
assert enoent_count[0] == 0, f"7b observed {enoent_count[0]} ENOENT during atomic swaps!"

# 7c. P0-1: unsafely-preservable objects (FIFO special file, non-dir --out, and for non-root: mode 0000 subdir)
#     refuse publish (exit 3) & leave --out untouched
fifo_path = os.path.join(o1, "pipe_special")
os.mkfifo(fifo_path)
try:
    with open(os.path.join(s1, "a.mbt"), "w") as f: f.write("pub fn f() -> Int { 998 }\n")
    r_fifo = run_cli(["--src", s1, "--out", o1, "--target", "native", "--mode", "publish",
                      "--mbt-compat", compat_dir, "--pionc", pionc])
    assert r_fifo.returncode == 3, f"7c FIFO special file should exit 3, got {r_fifo.returncode}"
    assert "998" not in open(os.path.join(o1, "a.pion")).read(), "7c --out was modified on FIFO failure"
finally:
    os.unlink(fifo_path)

nondir_out = os.path.join(root, "file_not_dir")
with open(nondir_out, "w") as f: f.write("keep-file")
r_nd = run_cli(["--src", s1, "--out", nondir_out, "--target", "native", "--mode", "publish",
                "--mbt-compat", compat_dir, "--pionc", pionc])
assert r_nd.returncode == 3, f"7c non-dir --out should exit 3, got {r_nd.returncode}"
assert open(nondir_out).read() == "keep-file", "7c non-dir --out was modified"

if os.geteuid() != 0:
    unr_dir = os.path.join(o1, "secret_dir")
    os.makedirs(unr_dir, exist_ok=True)
    with open(os.path.join(unr_dir, "x"), "w") as f: f.write("keep")
    os.chmod(unr_dir, 0o000)
    try:
        with open(os.path.join(s1, "a.mbt"), "w") as f: f.write("pub fn f() -> Int { 999 }\n")
        r_unr = run_cli(["--src", s1, "--out", o1, "--target", "native", "--mode", "publish",
                         "--mbt-compat", compat_dir, "--pionc", pionc])
        assert r_unr.returncode == 3, f"7c unreadable dir should exit 3, got {r_unr.returncode}"
        assert "999" not in open(os.path.join(o1, "a.pion")).read(), "7c --out was modified on failure"
    finally:
        os.chmod(unr_dir, 0o755)

# 7d. P0-2: same_receiver (borrowed Array[Int] slice + String slice named `x` in same file) MUST block
s2 = os.path.join(root, "s2")
o2 = os.path.join(root, "o2")
os.makedirs(s2, exist_ok=True)
with open(os.path.join(s2, "a.mbt"), "w") as f:
    f.write(
        "fn view_val(x : Array[Int]) -> Int {\n"
        "  let v = x[0:1]\n"
        "  x[0] = 2\n"
        "  v[0]\n"
        "}\n"
        "pub fn text(x : String) -> String { x[0:1].to_owned() }\n"
    )
drf2 = os.path.join(root, "drf2.json")
r2 = run_cli(["--src", s2, "--out", o2, "--target", "native", "--mode", "publish",
              "--mbt-compat", compat_dir, "--pionc", pionc, "--drift-ledger", drf2])
assert r2.returncode == 1, f"7d same_receiver must block publish (rc=1), got {r2.returncode}"
dl2 = json.load(open(drf2))
unres = [e for e in dl2["entries"] if e["category"] == "array_view_slice" and e["status"] == "unresolved"]
res_s = [e for e in dl2["entries"] if e["category"] == "string_utf16_slice" and e["status"] == "resolved"]
assert len(unres) == 1 and len(res_s) == 1, f"7d unexpected ledger: {dl2}"

# 7e. P0-4: positional `@ext.caret("中A", 1)` live pionc run returns 65 ('A'), not 184
dep_dir = os.path.join(root, "acme_dep")
os.makedirs(os.path.join(dep_dir, "src"), exist_ok=True)
with open(os.path.join(dep_dir, "pion.toml"), "w") as f:
    f.write('[package]\nname = "acme"\nversion = "0.1.0"\n')
with open(os.path.join(dep_dir, "src", "main.pion"), "w") as f:
    f.write('pub fn caret(text : String, offset : Int) -> Int { text.code_unit_at(offset) }\n')
am_path = os.path.join(root, "pos_map.json")
with open(am_path, "w") as f:
    json.dump({"symbols": [{"src_pkg": "ext", "src_name": "caret", "kind": "fn",
                            "target_pkg": "acme", "target_name": "caret",
                            "params": [{"name": "text", "ty": "String", "unit": "none"},
                                       {"name": "offset", "ty": "Int", "unit": "utf8", "str_param": "text"}]}]}, f)
s3 = os.path.join(root, "s3")
pkg3 = os.path.join(root, "pkg3")
os.makedirs(s3, exist_ok=True)
os.makedirs(os.path.join(pkg3, "src"), exist_ok=True)
with open(os.path.join(s3, "a.mbt"), "w") as f:
    f.write('pub fn sample() -> Int { @ext.caret("中A", 1) }\n')
drf3 = os.path.join(root, "drf3.json")
r3 = run_cli(["--src", s3, "--out", os.path.join(pkg3, "src"), "--target", "native", "--mode", "publish",
              "--api-map", am_path, "--dep", "acme=" + dep_dir,
              "--mbt-compat", compat_dir, "--pionc", pionc, "--drift-ledger", drf3])
assert r3.returncode == 0, f"7e publish failed: {r3.stderr}"
dl3 = json.load(open(drf3))
assert any(e["category"] == "string_unit_boundary" for e in dl3["entries"]), f"7e missing drift entry: {dl3}"
with open(os.path.join(pkg3, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "pos_chk"\nversion = "0.1.0"\n[dependencies]\nacme = {{ path = "{dep_dir}" }}\nmbt_compat = {{ path = "{compat_dir}" }}\n')
with open(os.path.join(pkg3, "src", "main.pion"), "w") as f:
    f.write('pub fn main(_w : World) -> Int { if sample() != 65 { panic("expected 65") }; 0 }\n')
rr3 = subprocess.run([pionc, "run", pkg3], capture_output=True, text=True)
assert rr3.returncode == 0, f"7e pionc run failed: {rr3.stderr}"

# 7f. P1-2: qualified method `pub fn Widget::value_of` span_map points to exact published bytes
s4 = os.path.join(root, "s4")
o4 = os.path.join(root, "o4")
os.makedirs(s4, exist_ok=True)
with open(os.path.join(s4, "w.mbt"), "w") as f:
    f.write("pub struct Widget {\n  value : Int\n}\npub fn Widget::value_of(self : Widget) -> Int {\n  self.value\n}\n")
rep4 = os.path.join(root, "rep4.json")
r4 = run_cli(["--src", s4, "--out", o4, "--target", "native", "--mode", "publish",
              "--mbt-compat", compat_dir, "--pionc", pionc, "--report", rep4])
assert r4.returncode == 0, f"7f publish failed: {r4.stderr}"
raw_bytes = open(os.path.join(o4, "w.pion"), "rb").read()
spans = json.load(open(rep4))["span_map"]
m_spans = [sp for sp in spans if sp["kind"] == "fn:Widget::value_of"]
assert len(m_spans) == 1, f"7f missing fn:Widget::value_of span: {spans}"
sl = raw_bytes[m_spans[0]["out_start"]:m_spans[0]["out_end"]]
assert sl.startswith(b"pub fn Widget::value_of") and sl.endswith(b"}"), f"7f bad span bytes: {sl!r}"

print("[e2e] PASS: Round 3 Astra structural suite (0-ENOENT atomic swap, modes/symlinks/empty-dir, in-out reports, same_receiver, positional api_map, qualified span_map)")

# -----------------------------------------------------------------------------
# 8. Round 4 Astra P0-1, P0-2, P0-4 E2E acceptance suite
# -----------------------------------------------------------------------------
# 8a. P0-1: report colliding with generated `.pion` or hand-written `.pion` MUST block;
#     failed publish MUST NOT write report into `--out`; unwritable report MUST exit non-zero!
s8 = os.path.join(root, "s8")
o8 = os.path.join(root, "o8")
os.makedirs(s8, exist_ok=True)
os.makedirs(o8, exist_ok=True)
with open(os.path.join(s8, "a.mbt"), "w") as f:
    f.write("pub fn ok_fn() -> Int { 7 }\n")
with open(os.path.join(o8, "driver.pion"), "w") as f:
    f.write("pub fn keep_driver() -> Int { 11 }\n")
# First clean publish
r8_0 = run_cli(["--src", s8, "--out", o8, "--target", "native", "--mode", "publish",
                "--mbt-compat", compat_dir, "--pionc", pionc])
assert r8_0.returncode == 0, f"8a initial publish failed: {r8_0.stderr}"
snap_a = open(os.path.join(o8, "a.pion"), "rb").read()
snap_drv = open(os.path.join(o8, "driver.pion"), "rb").read()

# Collide --report with generated a.pion
r8_rep = run_cli(["--src", s8, "--out", o8, "--target", "native", "--mode", "publish",
                  "--mbt-compat", compat_dir, "--pionc", pionc,
                  "--report", os.path.join(o8, "a.pion")])
assert r8_rep.returncode == 1, f"8a --report OUT/a.pion must block (rc=1), got {r8_rep.returncode}"
assert open(os.path.join(o8, "a.pion"), "rb").read() == snap_a, "8a a.pion was overwritten by --report!"

# Collide --drift-ledger with hand-written driver.pion
r8_drf = run_cli(["--src", s8, "--out", o8, "--target", "native", "--mode", "publish",
                  "--mbt-compat", compat_dir, "--pionc", pionc,
                  "--drift-ledger", os.path.join(o8, "driver.pion")])
assert r8_drf.returncode == 1, f"8a --drift-ledger OUT/driver.pion must block (rc=1), got {r8_drf.returncode}"
assert open(os.path.join(o8, "driver.pion"), "rb").read() == snap_drv, "8a driver.pion was overwritten!"

# Blocked publish with --report OUT/failure.json MUST NOT create OUT/failure.json!
s8_bad = os.path.join(root, "s8_bad")
os.makedirs(s8_bad, exist_ok=True)
with open(os.path.join(s8_bad, "a.mbt"), "w") as f:
    f.write("pub fn bad(x : Array[Int]) -> Int { let v = x[0:1]; v[0] }\n")
r8_fail = run_cli(["--src", s8_bad, "--out", o8, "--target", "native", "--mode", "publish",
                   "--mbt-compat", compat_dir, "--pionc", pionc,
                   "--report", os.path.join(o8, "failure.json"),
                   "--run-report", os.path.join(o8, "run_fail.json")])
assert r8_fail.returncode == 1, f"8a blocked publish should exit 1, got {r8_fail.returncode}"
assert not os.path.exists(os.path.join(o8, "failure.json")), "8a blocked publish polluted --out with failure.json!"
assert not os.path.exists(os.path.join(o8, "run_fail.json")), "8a blocked publish polluted --out with run_fail.json!"
assert open(os.path.join(o8, "a.pion"), "rb").read() == snap_a, "8a --out modified on blocked publish"

# Unwritable report path (parent is a regular file) MUST exit non-zero (rc=3)
blk_file = os.path.join(root, "not_a_dir")
with open(blk_file, "w") as f: f.write("x")
r8_io = run_cli(["--src", s8, "--out", o8, "--target", "native", "--mode", "publish",
                 "--mbt-compat", compat_dir, "--pionc", pionc,
                 "--report", os.path.join(blk_file, "rep.json")])
assert r8_io.returncode == 3, f"8a unwritable report should exit 3, got {r8_io.returncode}"

# 8b. P0-2: symlinked `.pion` (`shared.pion -> common.pion`) causing E_DUP_DEF MUST block publish & --check!
common_pion = os.path.join(root, "common.pion")
with open(common_pion, "w") as f:
    f.write("pub fn key() -> Int { 1 }\n")
s8_dup = os.path.join(root, "s8_dup")
o8_dup = os.path.join(root, "o8_dup")
os.makedirs(s8_dup, exist_ok=True)
os.makedirs(o8_dup, exist_ok=True)
with open(os.path.join(s8_dup, "a.mbt"), "w") as f:
    f.write("pub fn key() -> Int { 2 }\n")
os.symlink(common_pion, os.path.join(o8_dup, "shared.pion"))
r8_sym_pub = run_cli(["--src", s8_dup, "--out", o8_dup, "--target", "native", "--mode", "publish",
                      "--mbt-compat", compat_dir, "--pionc", pionc])
assert r8_sym_pub.returncode == 1, f"8b symlinked .pion E_DUP_DEF must block publish (rc=1), got {r8_sym_pub.returncode}"
r8_sym_chk = run_cli(["--src", s8_dup, "--out", o8_dup, "--target", "native", "--check",
                      "--mbt-compat", compat_dir, "--pionc", pionc])
assert r8_sym_chk.returncode == 1, f"8b symlinked .pion E_DUP_DEF must fail --check (rc=1), got {r8_sym_chk.returncode}"

# 8c. P0-4: optional/default `flag? : Int = 0` skipped for positional args; BOTH caret("中A", 1) & caret("中A", flag=1, 1) -> 65!
dep8 = os.path.join(root, "acme_opt_dep")
os.makedirs(os.path.join(dep8, "src"), exist_ok=True)
with open(os.path.join(dep8, "pion.toml"), "w") as f:
    f.write('[package]\nname = "acme_opt"\nversion = "0.1.0"\n')
with open(os.path.join(dep8, "src", "main.pion"), "w") as f:
    f.write('pub fn caret(text : String, flag~ : Int = 0, offset : Int) -> Int { let _ = flag; text.code_unit_at(offset) }\n')
am8 = os.path.join(root, "opt_map.json")
with open(am8, "w") as f:
    json.dump({"symbols": [{"src_pkg": "ext", "src_name": "caret", "kind": "fn",
                            "target_pkg": "acme_opt", "target_name": "caret",
                            "params": [{"name": "text", "type": "String", "unit": "none"},
                                       {"name": "flag", "type": "Int", "is_optional": True, "has_default": True, "unit": "none"},
                                       {"name": "offset", "type": "Int", "unit": "utf8", "str_param": "text"}]}]}, f)
s8_opt = os.path.join(root, "s8_opt")
pkg8 = os.path.join(root, "pkg8")
os.makedirs(s8_opt, exist_ok=True)
os.makedirs(os.path.join(pkg8, "src"), exist_ok=True)
with open(os.path.join(s8_opt, "a.mbt"), "w") as f:
    f.write('pub fn s_omit() -> Int { @ext.caret("中A", 1) }\npub fn s_flag() -> Int { @ext.caret("中A", flag=1, 1) }\n')
r8_opt = run_cli(["--src", s8_opt, "--out", os.path.join(pkg8, "src"), "--target", "native", "--mode", "publish",
                  "--api-map", am8, "--dep", "acme_opt=" + dep8,
                  "--mbt-compat", compat_dir, "--pionc", pionc])
assert r8_opt.returncode == 0, f"8c publish failed: {r8_opt.stderr}"
with open(os.path.join(pkg8, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "opt_chk"\nversion = "0.1.0"\n[dependencies]\nacme_opt = {{ path = "{dep8}" }}\nmbt_compat = {{ path = "{compat_dir}" }}\n')
with open(os.path.join(pkg8, "src", "main.pion"), "w") as f:
    f.write('pub fn main(_w : World) -> Int { if s_omit() != 65 { panic("s_omit != 65") }; if s_flag() != 65 { panic("s_flag != 65") }; 0 }\n')
rr8 = subprocess.run([pionc, "run", pkg8], capture_output=True, text=True)
assert rr8.returncode == 0, f"8c pionc run failed: {rr8.stderr}"

print("[e2e] PASS: Round 4 Astra P0-1/P0-2/P0-4 suite (report role collisions, zero-write on failed publish, symlink .pion E_DUP_DEF, optional-skip positional binding == 65)")

# -----------------------------------------------------------------------------
# 9. Round 5 Astra P0-2 & P0-3 E2E acceptance suite
# -----------------------------------------------------------------------------
# 9a. P0-2: relative symlink `alias.pion -> a.pion` starts valid (comment-only a.pion);
#     when a.mbt adds `pub fn new_key()`, BOTH publish AND --check MUST block & preserve old OUT!
s9 = os.path.join(root, "s9")
o9 = os.path.join(root, "o9")
os.makedirs(s9, exist_ok=True)
os.makedirs(o9, exist_ok=True)
with open(os.path.join(s9, "a.mbt"), "w") as f:
    f.write("// comment-only v1\n")
r9_v1 = run_cli(["--src", s9, "--out", o9, "--target", "native", "--mode", "publish",
                 "--mbt-compat", compat_dir, "--pionc", pionc])
assert r9_v1.returncode == 0, f"9a v1 publish failed: {r9_v1.stderr}"
os.symlink("a.pion", os.path.join(o9, "alias.pion"))
old_a_bytes = open(os.path.join(o9, "a.pion"), "rb").read()
# Verify v1 with alias.pion is valid under pionc check
r9_v1_pub2 = run_cli(["--src", s9, "--out", o9, "--target", "native", "--mode", "publish",
                      "--mbt-compat", compat_dir, "--pionc", pionc])
assert r9_v1_pub2.returncode == 0, f"9a v1 re-publish with alias.pion failed: {r9_v1_pub2.stderr}"
# Now add `pub fn new_key() -> Int { 1 }` to a.mbt: alias.pion -> a.pion will now cause E_DUP_DEF!
with open(os.path.join(s9, "a.mbt"), "w") as f:
    f.write("pub fn new_key() -> Int { 1 }\n")
r9_v2_pub = run_cli(["--src", s9, "--out", o9, "--target", "native", "--mode", "publish",
                     "--mbt-compat", compat_dir, "--pionc", pionc])
assert r9_v2_pub.returncode == 1, f"9a v2 publish with relative alias.pion -> a.pion E_DUP_DEF must block (rc=1), got {r9_v2_pub.returncode}"
assert open(os.path.join(o9, "a.pion"), "rb").read() == old_a_bytes, "9a old OUT was modified on blocked v2 publish!"
r9_v2_chk = run_cli(["--src", s9, "--out", o9, "--target", "native", "--check",
                     "--mbt-compat", compat_dir, "--pionc", pionc])
assert r9_v2_chk.returncode == 1, f"9a v2 --check must fail (rc=1), got {r9_v2_chk.returncode}"

# 9a-2. Round 6 Astra P0-2: ABSOLUTE symlink `alias.pion -> <abs_OUT>/a.pion` MUST also block on new_key,
#       while a stable external symlink `ext.pion -> <external>/ok.pion` passes!
os.unlink(os.path.join(o9, "alias.pion"))
os.symlink(os.path.join(os.path.abspath(o9), "a.pion"), os.path.join(o9, "alias.pion"))
r9_abs_pub = run_cli(["--src", s9, "--out", o9, "--target", "native", "--mode", "publish",
                      "--mbt-compat", compat_dir, "--pionc", pionc])
assert r9_abs_pub.returncode == 1, f"9a-2 absolute symlink to OUT/a.pion must block publish (rc=1), got {r9_abs_pub.returncode}"
assert open(os.path.join(o9, "a.pion"), "rb").read() == old_a_bytes, "9a-2 old OUT modified on blocked abs symlink publish!"
r9_abs_chk = run_cli(["--src", s9, "--out", o9, "--target", "native", "--check",
                      "--mbt-compat", compat_dir, "--pionc", pionc])
assert r9_abs_chk.returncode == 1, f"9a-2 absolute symlink must fail --check (rc=1), got {r9_abs_chk.returncode}"

os.unlink(os.path.join(o9, "alias.pion"))
ext_ok = os.path.join(root, "ext_ok.pion")
with open(ext_ok, "w") as f:
    f.write("pub fn ext_helper() -> Int { 99 }\n")
os.symlink(ext_ok, os.path.join(o9, "ext.pion"))
r9_ext_ok = run_cli(["--src", s9, "--out", o9, "--target", "native", "--mode", "publish",
                     "--mbt-compat", compat_dir, "--pionc", pionc])
assert r9_ext_ok.returncode == 0, f"9a-3 stable external symlink should succeed, got {r9_ext_ok.returncode} {r9_ext_ok.stderr}"

# 9b. P0-3: (1) 228-byte legal external --run-report filename succeeds (short sibling temp never hits ENAMETOOLONG);
#           (2) external --run-report target failure (existing dir) aborts BEFORE swap (old_key preserved, NO rep.json!)
s9b = os.path.join(root, "s9b")
o9b = os.path.join(root, "o9b")
os.makedirs(s9b, exist_ok=True)
with open(os.path.join(s9b, "a.mbt"), "w") as f:
    f.write("pub fn old_key() -> Int { 1 }\n")
long_run_rep = os.path.join(root, "r" * 223 + ".json") # 228-byte filename (< NAME_MAX 255)
r9b_1 = run_cli(["--src", s9b, "--out", o9b, "--target", "native", "--mode", "publish",
                 "--mbt-compat", compat_dir, "--pionc", pionc,
                 "--run-report", long_run_rep])
assert r9b_1.returncode == 0, f"9b 228-byte external --run-report failed: {r9b_1.returncode} {r9b_1.stderr}"
assert json.load(open(long_run_rep))["ok"] is True, "9b 228-byte run report missing ok:true"

snap_9b = {p: open(os.path.join(o9b, p), "rb").read() for p in sorted(os.listdir(o9b))}
with open(os.path.join(s9b, "a.mbt"), "w") as f:
    f.write("pub fn new_key() -> Int { 2 }\n")
dir_as_run_rep = os.path.join(root, "run_rep_is_dir")
os.makedirs(dir_as_run_rep, exist_ok=True)
r9b_2 = run_cli(["--src", s9b, "--out", o9b, "--target", "native", "--mode", "publish",
                 "--mbt-compat", compat_dir, "--pionc", pionc,
                 "--report", os.path.join(o9b, "rep.json"),
                 "--run-report", dir_as_run_rep])
assert r9b_2.returncode == 3, f"9b external --run-report dir collision must exit 3, got {r9b_2.returncode}"
after_9b = {p: open(os.path.join(o9b, p), "rb").read() for p in sorted(os.listdir(o9b))}
assert after_9b == snap_9b, f"9b OUT mutated on external run-report failure! before={list(snap_9b.keys())} after={list(after_9b.keys())}"
assert not os.path.exists(os.path.join(o9b, "rep.json")), "9b in-out rep.json leaked on external run-report failure!"

print("[e2e] PASS: Round 5+6 Astra P0-2/P0-3 suite (relative+absolute+external symlinks, 228-byte short-temp run-report, pre-swap failure leaves OUT untouched)")

# -----------------------------------------------------------------------------
# 10. Round 7 Astra P1: Case-folded report path collision check (cross-platform)
# -----------------------------------------------------------------------------
s10 = os.path.join(root, "s10")
o10 = os.path.join(root, "o10")
os.makedirs(s10, exist_ok=True)
with open(os.path.join(s10, "a.mbt"), "w") as f:
    f.write("pub fn v10() -> Int { 10 }\n")
r10_init = run_cli(["--src", s10, "--out", o10, "--target", "native", "--mode", "publish",
                    "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10_init.returncode == 0, f"10 init publish failed: {r10_init.stderr}"
snap_10 = {p: open(os.path.join(o10, p), "rb").read() for p in sorted(os.listdir(o10))}

with open(os.path.join(s10, "a.mbt"), "w") as f:
    f.write("pub fn v10_new() -> Int { 20 }\n")

# 10a. Case-colliding in-out reports: --report OUT/Migration.json --drift-ledger OUT/migration.json
r10_in = run_cli(["--src", s10, "--out", o10, "--target", "native", "--mode", "publish",
                  "--mbt-compat", compat_dir, "--pionc", pionc,
                  "--report", os.path.join(o10, "Migration.json"),
                  "--drift-ledger", os.path.join(o10, "migration.json")])
assert r10_in.returncode == 1, f"10a case-colliding in-out reports must fail (rc=1), got {r10_in.returncode}"
assert "MBT2PION_REPORT_PATH_COLLISION" in (r10_in.stdout + r10_in.stderr), "10a missing MBT2PION_REPORT_PATH_COLLISION"
assert {p: open(os.path.join(o10, p), "rb").read() for p in sorted(os.listdir(o10))} == snap_10, "10a OUT modified on collision!"

# 10b. Case-colliding external reports: --report <tmp>/Migration.json --drift-ledger <tmp>/migration.json
ext_dir10 = os.path.join(root, "ext10")
os.makedirs(ext_dir10, exist_ok=True)
r10_ext = run_cli(["--src", s10, "--out", o10, "--target", "native", "--mode", "publish",
                   "--mbt-compat", compat_dir, "--pionc", pionc,
                   "--report", os.path.join(ext_dir10, "Migration.json"),
                   "--drift-ledger", os.path.join(ext_dir10, "migration.json")])
assert r10_ext.returncode == 1, f"10b case-colliding external reports must fail (rc=1), got {r10_ext.returncode}"
assert "MBT2PION_REPORT_PATH_COLLISION" in (r10_ext.stdout + r10_ext.stderr), "10b missing MBT2PION_REPORT_PATH_COLLISION"
assert os.listdir(ext_dir10) == [], f"10b wrote colliding external report: {os.listdir(ext_dir10)}"
assert {p: open(os.path.join(o10, p), "rb").read() for p in sorted(os.listdir(o10))} == snap_10, "10b OUT modified on collision!"

# 10c. Distinct filenames with case-aliased `--out` dir (`--out output --report OUTPUT/report.json --drift-ledger output/ledger.json`)
o10c = os.path.join(root, "output")
os.makedirs(o10c, exist_ok=True)
o10c_upper = os.path.join(root, "OUTPUT")
r10_alias = run_cli(["--src", s10, "--out", o10c, "--target", "native", "--mode", "publish",
                     "--mbt-compat", compat_dir, "--pionc", pionc,
                     "--report", os.path.join(o10c_upper, "report.json"),
                     "--drift-ledger", os.path.join(o10c, "ledger.json")])
assert r10_alias.returncode == 0, f"10c case-aliased --out dir publish failed: {r10_alias.returncode} {r10_alias.stderr}"
rep10c_path = os.path.join(o10c_upper, "report.json")
drf10c_path = os.path.join(o10c, "ledger.json")
assert os.path.isfile(rep10c_path) and os.path.isfile(drf10c_path), "10c missing report.json or ledger.json"
assert "files_generated" in json.load(open(rep10c_path)), "10c report.json missing files_generated"
assert "unresolved_entries" in json.load(open(drf10c_path)), "10c ledger.json missing unresolved_entries"
if os.path.exists(o10c_upper) and os.path.samefile(o10c, o10c_upper):
    entries10c = sorted(os.listdir(o10c))
    assert "report.json" in entries10c and "ledger.json" in entries10c, f"10c case-insensitive volume lost in-out report: {entries10c}"

# 10d. Unicode case (`État.json` vs `état.json`) and NFC/NFD (`caf\u00e9.json` vs `cafe\u0301.json`), both in-out and external
def volume_folds(base_dir, n1, n2):
    import shutil
    td = os.path.join(base_dir, ".probe_fold_" + str(abs(hash((n1, n2))) % 100000))
    os.makedirs(td, exist_ok=True)
    try:
        fd1 = os.open(os.path.join(td, n1), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd1)
        try:
            fd2 = os.open(os.path.join(td, n2), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd2)
            return False
        except FileExistsError:
            return True
    finally:
        shutil.rmtree(td, ignore_errors=True)

for tag, n1, n2 in [
    ("unicode_case", "\u00c9tat.json", "\u00e9tat.json"),
    ("nfc_nfd", "caf\u00e9.json", "cafe\u0301.json"),
]:
    folds = volume_folds(root, n1, n2)
    # In-out test
    o10u = os.path.join(root, f"o10u_{tag}")
    r_init = run_cli(["--src", s10, "--out", o10u, "--target", "native", "--mode", "publish",
                      "--mbt-compat", compat_dir, "--pionc", pionc])
    assert r_init.returncode == 0
    snap_u = {p: open(os.path.join(o10u, p), "rb").read() for p in sorted(os.listdir(o10u))}
    r_u_in = run_cli(["--src", s10, "--out", o10u, "--target", "native", "--mode", "publish",
                      "--mbt-compat", compat_dir, "--pionc", pionc,
                      "--report", os.path.join(o10u, n1),
                      "--drift-ledger", os.path.join(o10u, n2)])
    if folds:
        assert r_u_in.returncode == 1, f"10d in-out {tag} must block on folding volume, got {r_u_in.returncode}"
        assert "MBT2PION_REPORT_PATH_COLLISION" in (r_u_in.stdout + r_u_in.stderr), f"10d in-out {tag} missing collision code"
        assert {p: open(os.path.join(o10u, p), "rb").read() for p in sorted(os.listdir(o10u))} == snap_u, f"10d in-out {tag} mutated OUT!"
    else:
        assert r_u_in.returncode == 0, f"10d in-out {tag} must succeed on case-sensitive volume, got {r_u_in.returncode} {r_u_in.stderr}"
        assert "files_generated" in json.load(open(os.path.join(o10u, n1)))
        assert "unresolved_entries" in json.load(open(os.path.join(o10u, n2)))
    # External test
    ext_u = os.path.join(root, f"ext10u_{tag}")
    os.makedirs(ext_u, exist_ok=True)
    r_u_ext = run_cli(["--src", s10, "--out", o10u, "--target", "native", "--mode", "publish",
                       "--mbt-compat", compat_dir, "--pionc", pionc,
                       "--report", os.path.join(ext_u, n1),
                       "--drift-ledger", os.path.join(ext_u, n2)])
    if folds:
        assert r_u_ext.returncode == 1, f"10d ext {tag} must block on folding volume, got {r_u_ext.returncode}"
        assert "MBT2PION_REPORT_PATH_COLLISION" in (r_u_ext.stdout + r_u_ext.stderr), f"10d ext {tag} missing collision code"
        assert os.listdir(ext_u) == [], f"10d ext {tag} leaked files: {os.listdir(ext_u)}"
    else:
        assert r_u_ext.returncode == 0, f"10d ext {tag} must succeed on case-sensitive volume, got {r_u_ext.returncode} {r_u_ext.stderr}"
        assert "files_generated" in json.load(open(os.path.join(ext_u, n1)))
        assert "unresolved_entries" in json.load(open(os.path.join(ext_u, n2)))

print("[e2e] PASS: Round 7+8 Astra P1 suite (ASCII + inode-aliased --out + Unicode État/état + NFC/NFD café volume-truth collision & delivery)")

# 10e. Round 9 Astra P0: unmanaged hardlink backup `OUT/retained.json` linked to `OUT/migration.json`
#      MUST be preserved byte-for-byte with old content when `OUT/migration.json` is regenerated!
s10e = os.path.join(root, "s10e")
o10e = os.path.join(root, "o10e")
os.makedirs(s10e, exist_ok=True)
with open(os.path.join(s10e, "a.mbt"), "w") as f:
    f.write("pub fn old_hl() -> Int { 1 }\n")
rep10e = os.path.join(o10e, "migration.json")
r10e_1 = run_cli(["--src", s10e, "--out", o10e, "--target", "native", "--mode", "publish",
                  "--mbt-compat", compat_dir, "--pionc", pionc,
                  "--report", rep10e])
assert r10e_1.returncode == 0, f"10e v1 publish failed: {r10e_1.stderr}"
old_mig_bytes = open(rep10e, "rb").read()
retained_path = os.path.join(o10e, "retained.json")
os.link(rep10e, retained_path)
with open(os.path.join(s10e, "a.mbt"), "w") as f:
    f.write("pub fn new_hl_one() -> Int { 2 }\npub fn new_hl_two() -> Int { 3 }\n")
r10e_2 = run_cli(["--src", s10e, "--out", o10e, "--target", "native", "--mode", "publish",
                  "--mbt-compat", compat_dir, "--pionc", pionc,
                  "--report", rep10e])
assert r10e_2.returncode == 0, f"10e v2 publish failed: {r10e_2.stderr}"
new_mig_bytes = open(rep10e, "rb").read()
assert new_mig_bytes != old_mig_bytes, "10e migration.json was not updated!"
assert os.path.isfile(retained_path), "10e unmanaged hardlink retained.json was deleted!"
assert open(retained_path, "rb").read() == old_mig_bytes, "10e unmanaged hardlink retained.json bytes changed!"

# 10f. Round 9 Astra P1a: non-existent Unicode subdirs `OUT/Équipe/info.json` vs `OUT/équipe/info.json`
folds_eq = volume_folds(root, "\u00c9quipe", "\u00e9quipe")
o10f = os.path.join(root, "o10f")
r10f_init = run_cli(["--src", s10, "--out", o10f, "--target", "native", "--mode", "publish",
                     "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10f_init.returncode == 0
snap_10f = {p: open(os.path.join(o10f, p), "rb").read() for p in sorted(os.listdir(o10f))}
r10f = run_cli(["--src", s10, "--out", o10f, "--target", "native", "--mode", "publish",
                "--mbt-compat", compat_dir, "--pionc", pionc,
                "--report", os.path.join(o10f, "\u00c9quipe", "info.json"),
                "--drift-ledger", os.path.join(o10f, "\u00e9quipe", "info.json")])
if folds_eq:
    assert r10f.returncode == 1, f"10f non-existent Équipe/équipe must block on folding volume, got {r10f.returncode}"
    assert "MBT2PION_REPORT_PATH_COLLISION" in (r10f.stdout + r10f.stderr), "10f missing collision code"
    assert {p: open(os.path.join(o10f, p), "rb").read() for p in sorted(os.listdir(o10f))} == snap_10f, "10f OUT mutated!"
else:
    assert r10f.returncode == 0, f"10f non-existent Équipe/équipe must succeed on case-sensitive volume, got {r10f.returncode} {r10f.stderr}"
    assert "files_generated" in json.load(open(os.path.join(o10f, "\u00c9quipe", "info.json")))
    assert "unresolved_entries" in json.load(open(os.path.join(o10f, "\u00e9quipe", "info.json")))

# 10g. Round 9 Astra P1b: brand-new non-existent `--out fresh_output` with `--report FRESH_OUTPUT/report.json`
fresh_out = os.path.join(root, "fresh_output")
fresh_upper = os.path.join(root, "FRESH_OUTPUT")
assert not os.path.exists(fresh_out) and not os.path.exists(fresh_upper)
r10g = run_cli(["--src", s10, "--out", fresh_out, "--target", "native", "--mode", "publish",
                "--mbt-compat", compat_dir, "--pionc", pionc,
                "--report", os.path.join(fresh_upper, "report.json"),
                "--drift-ledger", os.path.join(fresh_out, "ledger.json")])
assert r10g.returncode == 0, f"10g brand-new fresh_output/FRESH_OUTPUT publish failed: {r10g.returncode} {r10g.stderr}"
assert "files_generated" in json.load(open(os.path.join(fresh_upper, "report.json")))
assert "unresolved_entries" in json.load(open(os.path.join(fresh_out, "ledger.json")))
if os.path.exists(fresh_upper) and os.path.samefile(fresh_out, fresh_upper):
    entries10g = sorted(os.listdir(fresh_out))
    assert "a.pion" in entries10g and "report.json" in entries10g and "ledger.json" in entries10g, f"10g missing files in fresh_output: {entries10g}"

print("[e2e] PASS: Round 9 Astra P0/P1 suite (hardlink backup retained.json preserved, non-existent Équipe/équipe subdir collision, brand-new fresh_output/FRESH_OUTPUT atomic delivery)")

# 10h. Round 10 Astra P0: 0555 read-only subdir `OUT/reports/` with `Migration.json` hardlinked to
#      `retained.json`: re-publishing with `--report OUT/reports/migration.json` MUST preserve
#      `retained.json` byte-for-byte with old content AND preserve `0555` mode on `OUT/reports`!
s10h = os.path.join(root, "s10h")
o10h = os.path.join(root, "o10h")
os.makedirs(s10h, exist_ok=True)
with open(os.path.join(s10h, "a.mbt"), "w") as f:
    f.write("pub fn ro_v1() -> Int { 1 }\n")
rep10h_dir = os.path.join(o10h, "reports")
rep10h_cap = os.path.join(rep10h_dir, "Migration.json")
rep10h_low = os.path.join(rep10h_dir, "migration.json")
rep10h_ret = os.path.join(rep10h_dir, "retained.json")
r10h_1 = run_cli(["--src", s10h, "--out", o10h, "--target", "native", "--mode", "publish",
                  "--mbt-compat", compat_dir, "--pionc", pionc,
                  "--report", rep10h_cap])
assert r10h_1.returncode == 0, f"10h v1 publish failed: {r10h_1.stderr}"
old_10h_bytes = open(rep10h_cap, "rb").read()
os.link(rep10h_cap, rep10h_ret)
os.chmod(rep10h_dir, 0o555)
try:
    with open(os.path.join(s10h, "a.mbt"), "w") as f:
        f.write("pub fn ro_v2_a() -> Int { 2 }\npub fn ro_v2_b() -> Int { 3 }\n")
    r10h_2 = run_cli(["--src", s10h, "--out", o10h, "--target", "native", "--mode", "publish",
                      "--mbt-compat", compat_dir, "--pionc", pionc,
                      "--report", rep10h_low])
    assert r10h_2.returncode == 0, f"10h v2 publish in 0555 reports/ failed: {r10h_2.returncode} {r10h_2.stderr}"
    new_10h_bytes = open(rep10h_low, "rb").read()
    assert new_10h_bytes != old_10h_bytes, "10h migration.json was not updated!"
    assert os.path.isfile(rep10h_ret), "10h retained.json was deleted!"
    assert open(rep10h_ret, "rb").read() == old_10h_bytes, "10h retained.json bytes corrupted by shared-inode overwrite!"
    assert (os.stat(rep10h_dir).st_mode & 0o777) == 0o555, f"10h reports/ mode changed: {oct(os.stat(rep10h_dir).st_mode & 0o777)}"

    # 10i. Round 10 Astra P0: 0555 read-only subdir `OUT/reports/` Unicode `État.json` vs `état.json`
    folds_ro = volume_folds(root, "\u00c9tat.json", "\u00e9tat.json")
    snap_10i = {p: open(os.path.join(rep10h_dir, p), "rb").read() for p in sorted(os.listdir(rep10h_dir))}
    r10i = run_cli(["--src", s10h, "--out", o10h, "--target", "native", "--mode", "publish",
                    "--mbt-compat", compat_dir, "--pionc", pionc,
                    "--report", os.path.join(rep10h_dir, "\u00c9tat.json"),
                    "--drift-ledger", os.path.join(rep10h_dir, "\u00e9tat.json")])
    if folds_ro:
        assert r10i.returncode == 1, f"10i 0555 reports/ État/état must block on folding volume, got {r10i.returncode}"
        assert "MBT2PION_REPORT_PATH_COLLISION" in (r10i.stdout + r10i.stderr), "10i missing collision code"
        assert {p: open(os.path.join(rep10h_dir, p), "rb").read() for p in sorted(os.listdir(rep10h_dir))} == snap_10i, "10i 0555 reports/ mutated!"
    else:
        assert r10i.returncode == 0, f"10i 0555 reports/ État/état must succeed on case-sensitive volume, got {r10i.returncode} {r10i.stderr}"
        assert "files_generated" in json.load(open(os.path.join(rep10h_dir, "\u00c9tat.json")))
        assert "unresolved_entries" in json.load(open(os.path.join(rep10h_dir, "\u00e9tat.json")))
finally:
    if os.path.isdir(rep10h_dir):
        os.chmod(rep10h_dir, 0o755)

print("[e2e] PASS: Round 10 Astra P0 suite (0555 read-only subdir hardlink backup preserved + 0555 mode kept + 0555 Unicode État/état collision)")

# 10j. Round 11 Astra P1: Near-PATH_MAX directory triggers probe_err (-1, unknown location);
#      publish MUST exit 3 AND MUST NOT create `o/` or `O/` for any of --report / --drift-ledger / --run-report,
#      while a confirmed-external diagnostic report on a normal blocked publish is still written!
path_max = os.pathconf(root, "PC_PATH_MAX")
if path_max <= 0:
    path_max = 1024
deep_base = os.path.join(os.path.realpath(root), "d10j")
os.makedirs(deep_base, exist_ok=True)
# Build nested dir so len(deep_base) == path_max - 13:
#   - `<deep_base>/O/r.json` (+7) and `<deep_base>/É.json` (+8) stay strictly < PATH_MAX
#   - `<deep_base>/.m2pvp.<pid>.0/o` (+12 + len(pid)) is ALWAYS >= PATH_MAX even for a 1-digit PID!
target_len = path_max - 13
while len(deep_base) + 120 < target_len:
    deep_base = os.path.join(deep_base, "x" * 119)
rem = target_len - len(deep_base) - 1
if rem > 4:
    deep_base = os.path.join(deep_base, "y" * rem)
os.makedirs(deep_base, exist_ok=True)
o_low = os.path.join(deep_base, "o")
o_up = os.path.join(deep_base, "O")
for rflag in ("--report", "--drift-ledger", "--run-report"):
    r10j = run_cli(["--src", s10, "--out", o_low, "--target", "native", "--mode", "publish",
                    "--mbt-compat", compat_dir, "--pionc", pionc,
                    rflag, os.path.join(o_up, "r.json")])
    assert r10j.returncode == 3, f"10j near-PATH_MAX {rflag} must exit 3, got {r10j.returncode} {r10j.stderr}"
    assert not os.path.exists(o_low), f"10j {rflag} leaked o/ directory!"
    assert not os.path.exists(o_up), f"10j {rflag} leaked O/ directory!"

# Confirmed-external diagnostic report on a normal blocked publish is still written
s10j_bad = os.path.join(root, "s10j_bad")
o10j_bad = os.path.join(root, "o10j_bad")
os.makedirs(s10j_bad, exist_ok=True)
with open(os.path.join(s10j_bad, "a.mbt"), "w") as f:
    f.write("pub fn broken() -> Int { unknown_sym_10j() }\n")
ext_diag_rep = os.path.join(root, "ext_diag_10j.json")
r10j_ext = run_cli(["--src", s10j_bad, "--out", o10j_bad, "--target", "native", "--mode", "publish",
                    "--mbt-compat", compat_dir, "--pionc", pionc,
                    "--run-report", ext_diag_rep])
assert r10j_ext.returncode == 1, f"10j normal blocked publish should exit 1, got {r10j_ext.returncode}"
assert os.path.isfile(ext_diag_rep) and json.load(open(ext_diag_rep))["ok"] is False, "10j confirmed-external run-report missing or not ok:false"

print("[e2e] PASS: Round 11 Astra P1 suite (unknown-location probe_err never leaks o/ or O/ for any report flag; confirmed-external diag report still written)")

# 10k. Round 12 Astra P1: Pairwise volume collision probe failure (`vc < 0` in near-PATH_MAX external dir)
#      MUST mark both participating reports bad (preserving pre-existing `É.json` sentinel byte-for-byte & leaving `--out` untouched),
#      while still writing an independent 3rd external `--run-report` with `"ok": false`!
o10k = os.path.join(root, "o10k")
r10k_init = run_cli(["--src", s10, "--out", o10k, "--target", "native", "--mode", "publish",
                     "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10k_init.returncode == 0
snap_10k = {p: open(os.path.join(o10k, p), "rb").read() for p in sorted(os.listdir(o10k))}
sentinel_e = os.path.join(deep_base, "\u00c9.json")
sentinel_bytes = b'{"sentinel":"keep-me-r12"}\n'
with open(sentinel_e, "wb") as f:
    f.write(sentinel_bytes)
diag_run_10k = os.path.join(root, "diag_run_10k.json")
r10k = run_cli(["--src", s10, "--out", o10k, "--target", "native", "--mode", "publish",
                "--mbt-compat", compat_dir, "--pionc", pionc,
                "--report", sentinel_e,
                "--drift-ledger", os.path.join(deep_base, "\u00e9.json"),
                "--run-report", diag_run_10k])
assert r10k.returncode == 3, f"10k pairwise probe_err must exit 3, got {r10k.returncode} {r10k.stderr}"
assert open(sentinel_e, "rb").read() == sentinel_bytes, "10k pre-existing É.json sentinel was overwritten!"
assert {p: open(os.path.join(o10k, p), "rb").read() for p in sorted(os.listdir(o10k))} == snap_10k, "10k OUT mutated!"
assert os.path.isfile(diag_run_10k) and json.load(open(diag_run_10k))["ok"] is False, "10k independent 3rd external --run-report missing or not ok:false"

print("[e2e] PASS: Round 12 Astra P1 suite (pairwise probe_err preserves pre-existing É.json sentinel & OUT, still writes independent external --run-report)")

# 10l. Final Opus P1: dirname("/tmp") must return "/" (not ""), so running from `cd $WORK` with
#      nonexistent `--out out` and any report flag succeeds (rc=0) instead of EINVAL exit 3!
w10l = os.path.join(root, "w10l")
os.makedirs(w10l, exist_ok=True)
s10l = os.path.join(w10l, "src")
os.makedirs(s10l, exist_ok=True)
with open(os.path.join(s10l, "a.mbt"), "w") as f:
    f.write("pub fn ok10l() -> Int { 10 }\n")
os.makedirs(os.path.join(w10l, "rep"), exist_ok=True)
os.makedirs(os.path.join(w10l, "out6"), exist_ok=True)

cases_10l = [
    ("1_nonexist_out_rel_report", ["--out", "out1", "--report", "r1.json"], "out1", "r1.json", "files_generated"),
    ("2_nonexist_out_subdir_report", ["--out", "out2", "--report", "rep/r2.json"], "out2", "rep/r2.json", "files_generated"),
    ("3_nonexist_out_drift", ["--out", "out3", "--drift-ledger", "d3.json"], "out3", "d3.json", "unresolved_entries"),
    ("4_nonexist_abs_from_cwd", ["--out", os.path.join(w10l, "out4"), "--report", os.path.join(w10l, "r4.json")], "out4", "r4.json", "files_generated"),
    ("5_nonexist_out_no_report", ["--out", "out5"], "out5", None, None),
    ("6_exist_out_rel_report", ["--out", "out6", "--report", "r6.json"], "out6", "r6.json", "files_generated"),
]
for label, extra, out_rel, rep_rel, rep_key in cases_10l:
    r = run_cli(["--src", "src", "--target", "native", "--mode", "publish",
                 "--mbt-compat", compat_dir, "--pionc", pionc] + extra, cwd=w10l)
    assert r.returncode == 0, f"10l {label} failed (rc={r.returncode}): {r.stdout} {r.stderr}"
    assert os.path.isfile(os.path.join(w10l, out_rel, "a.pion")), f"10l {label} missing a.pion"
    if rep_rel is not None:
        rp = os.path.join(w10l, rep_rel)
        assert os.path.isfile(rp), f"10l {label} missing report {rep_rel}"
        assert rep_key in json.load(open(rp)), f"10l {label} report missing key {rep_key}"

print("[e2e] PASS: Final Opus P1 suite (10l: 6/6 fresh/existing --out + report combos from cd $WORK exit 0)")

# 10m. Final Astra P0-1 + P0-2 downstream runtime acceptance:
#      #cfg(target="js") brace-less decls (tuple struct, = "%identity", extern "js" fn) followed by kept() -> 41,
#      and wasm_bothbits w() + g() under --target wasm32 (exclusive wasm-gc) -> live `pionc run --target wasm32` prints 41:2!
s10m = os.path.join(root, "s10m")
o10m = os.path.join(root, "o10m")
os.makedirs(s10m, exist_ok=True)
with open(os.path.join(s10m, "cfg_exec.mbt"), "w") as f:
    f.write(
        '#cfg(target="js")\n'
        'struct Box(Int)\n'
        '#cfg(target="js")\n'
        'fn ident(x : Int) -> Int = "%identity"\n'
        '#cfg(target="js")\n'
        'extern "js" fn js_f() -> Int = "() => 1"\n'
        'pub fn kept() -> Int { 41 }\n'
        '#cfg(target="wasm")\n'
        'pub fn w() -> Int { 1 }\n'
        '#cfg(not(target="wasm"))\n'
        'pub fn w() -> Int { 0 }\n'
        '#cfg(target="wasm-gc")\n'
        'pub fn g() -> Int { 2 }\n'
        '#cfg(not(target="wasm-gc"))\n'
        'pub fn g() -> Int { 0 }\n'
    )
r10m_pub = run_cli(["--src", s10m, "--out", o10m, "--target", "wasm32", "--mode", "publish",
                    "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10m_pub.returncode == 0, f"10m wasm32 publish failed: {r10m_pub.returncode} {r10m_pub.stdout} {r10m_pub.stderr}"

pkg10m = os.path.join(root, "pkg10m")
os.makedirs(os.path.join(pkg10m, "src"), exist_ok=True)
import shutil
shutil.copyfile(os.path.join(o10m, "cfg_exec.pion"), os.path.join(pkg10m, "src", "cfg_exec.pion"))
with open(os.path.join(pkg10m, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "e2e_10m"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
with open(os.path.join(pkg10m, "src", "main.pion"), "w") as f:
    f.write(
        'pub fn main(world : World) -> Int {\n'
        '  let a = kept()\n'
        '  let b = w() + g()\n'
        '  io_println(world, a.to_string() + ":" + b.to_string())\n'
        '  0\n'
        '}\n'
    )
if shutil.which("node"):
    r10m_run = subprocess.run([pionc, "run", "--target", "wasm32", pkg10m], capture_output=True, text=True)
    assert r10m_run.returncode == 0, f"10m pionc run --target wasm32 failed: {r10m_run.stdout} {r10m_run.stderr}"
    assert r10m_run.stdout.strip() == "41:2", f"10m expected '41:2', got {r10m_run.stdout!r}"
else:
    r10m_run = subprocess.run([pionc, "run", pkg10m], capture_output=True, text=True)
    assert r10m_run.returncode == 0, f"10m pionc run failed: {r10m_run.stdout} {r10m_run.stderr}"
    assert r10m_run.stdout.strip() == "41:2", f"10m expected '41:2', got {r10m_run.stdout!r}"

print("[e2e] PASS: Final Astra P0-1+P0-2 suite (10m: #cfg brace-less decls + exclusive wasm-gc live wasm32 run == 41:2)")

# 10m-2. Astra single-source-of-truth moon.pkg + #cfg wasm32->wasm-gc alignment:
#        extra.mbt (`fn init { xs.push(9) }`) under `["wasm"]` -> 21; under `["not", "wasm"]` -> 22!
for tag_mp, rules_str, expected_out in [
    ("wasm_only", '["wasm"]', "21"),
    ("not_wasm", '["not", "wasm"]', "22"),
    ("single_str_wasm", '"wasm"', "21"),
    ("and_wasmgc_native", '["and", "wasm-gc", "native"]', "21"),
    ("or_and_js", '["or", ["and", "wasm", "native"], "js"]', "21"),
]:
    s_mp = os.path.join(root, f"s10m_{tag_mp}")
    o_mp = os.path.join(root, f"o10m_{tag_mp}")
    os.makedirs(s_mp, exist_ok=True)
    with open(os.path.join(s_mp, "moon.pkg"), "w") as f:
        f.write(f'options(targets: {{"extra.mbt": {rules_str}}})\n')
    with open(os.path.join(s_mp, "extra.mbt"), "w") as f:
        f.write("fn init {\n  xs.push(9)\n}\n")
    with open(os.path.join(s_mp, "common.mbt"), "w") as f:
        f.write(
            'let xs : Array[Int] = [0]\n'
            '#cfg(target="wasm-gc")\n'
            'fn bit() -> Int { 20 }\n'
            '#cfg(not(target="wasm-gc"))\n'
            'fn bit() -> Int { 10 }\n'
            'pub fn sample() -> Int { xs.length() + bit() }\n'
        )
    r_mp_pub = run_cli(["--src", s_mp, "--out", o_mp, "--target", "wasm32", "--mode", "publish",
                        "--mbt-compat", compat_dir, "--pionc", pionc])
    assert r_mp_pub.returncode == 0, f"10m-2 {tag_mp} publish failed: {r_mp_pub.returncode} {r_mp_pub.stdout} {r_mp_pub.stderr}"
    pkg_mp = os.path.join(root, f"pkg10m_{tag_mp}")
    os.makedirs(os.path.join(pkg_mp, "src"), exist_ok=True)
    for fn in sorted(os.listdir(o_mp)):
        if fn.endswith(".pion"):
            shutil.copyfile(os.path.join(o_mp, fn), os.path.join(pkg_mp, "src", fn))
    with open(os.path.join(pkg_mp, "pion.toml"), "w") as f:
        f.write(f'[package]\nname = "e2e_10m_{tag_mp}"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
    with open(os.path.join(pkg_mp, "src", "main.pion"), "w") as f:
        f.write(
            'pub fn main(world : World) -> Int {\n'
            '  io_println(world, sample().to_string())\n'
            '  0\n'
            '}\n'
        )
    run_cmd = [pionc, "run", "--target", "wasm32", pkg_mp] if shutil.which("node") else [pionc, "run", pkg_mp]
    r_mp_run = subprocess.run(run_cmd, capture_output=True, text=True)
    assert r_mp_run.returncode == 0, f"10m-2 {tag_mp} run failed: {r_mp_run.stdout} {r_mp_run.stderr}"
    assert r_mp_run.stdout.strip() == expected_out, f"10m-2 {tag_mp} expected {expected_out!r}, got {r_mp_run.stdout!r}"

print("[e2e] PASS: Final Astra moon.pkg+#cfg alignment suite (10m-2: [\"wasm\"]/'wasm'/and/or -> 21, [\"not\", \"wasm\"] -> 22 on live wasm32)")

# 10m-3. Astra P0 fail-closed unknown moon.pkg predicates `["debug"]` and `["not", "debug"]` MUST exit 1 with MBT2PION_UNSUPPORTED_TARGET_RULE
for tag_bad, bad_rule in [("debug", '["debug"]'), ("not_debug", '["not", "debug"]')]:
    s_bd = os.path.join(root, f"s10m_bad_{tag_bad}")
    o_bd = os.path.join(root, f"o10m_bad_{tag_bad}")
    os.makedirs(s_bd, exist_ok=True)
    with open(os.path.join(s_bd, "moon.pkg"), "w") as f:
        f.write(f'options(targets: {{"extra.mbt": {bad_rule}}})\n')
    with open(os.path.join(s_bd, "extra.mbt"), "w") as f:
        f.write("pub fn x() -> Int { 1 }\n")
    r_bd = run_cli(["--src", s_bd, "--out", o_bd, "--target", "wasm32", "--mode", "publish",
                    "--mbt-compat", compat_dir, "--pionc", pionc])
    assert r_bd.returncode == 1, f"10m-3 {tag_bad} must fail (rc=1), got {r_bd.returncode}"
    assert "MBT2PION_UNSUPPORTED_TARGET_RULE" in (r_bd.stdout + r_bd.stderr), f"10m-3 {tag_bad} missing MBT2PION_UNSUPPORTED_TARGET_RULE"

print("[e2e] PASS: Final Astra P0 fail-closed unknown moon.pkg rules (10m-3: [\"debug\"] & [\"not\", \"debug\"] -> rc=1 MBT2PION_UNSUPPORTED_TARGET_RULE)")

# 10m-4. Final Astra P0 lexer-backed moon.pkg whitespace & comment immunity + malformed fail-closed:
#        (a) `targets :` with space -> extra.pion absent & live wasm32 run == 21
#        (b) `// "extra.mbt": "wasm",` commented out -> extra.pion present & live wasm32 run == 22
#        (c) `// }` inside targets table -> extra.pion absent & live wasm32 run == 21
#        (d) malformed `options(targets: 123)` -> rc=1 + MBT2PION_UNSUPPORTED_TARGET_RULE
for tag_lx, pkg_txt, expect_extra, expected_out in [
    ("space_colon", 'options(targets : {"extra.mbt": "wasm"})\n', False, "21"),
    ("commented_out", 'options(targets: {\n // "extra.mbt": "wasm",\n})\n', True, "22"),
    ("comment_brace", 'options(targets: {\n // }\n "extra.mbt": "wasm",\n})\n', False, "21"),
]:
    s_lx = os.path.join(root, f"s10m4_{tag_lx}")
    o_lx = os.path.join(root, f"o10m4_{tag_lx}")
    os.makedirs(s_lx, exist_ok=True)
    with open(os.path.join(s_lx, "moon.pkg"), "w") as f:
        f.write(pkg_txt)
    with open(os.path.join(s_lx, "extra.mbt"), "w") as f:
        f.write("fn init {\n  xs.push(9)\n}\n")
    with open(os.path.join(s_lx, "common.mbt"), "w") as f:
        f.write(
            'let xs : Array[Int] = [0]\n'
            '#cfg(target="wasm-gc")\n'
            'fn bit() -> Int { 20 }\n'
            '#cfg(not(target="wasm-gc"))\n'
            'fn bit() -> Int { 10 }\n'
            'pub fn sample() -> Int { xs.length() + bit() }\n'
        )
    r_lx_pub = run_cli(["--src", s_lx, "--out", o_lx, "--target", "wasm32", "--mode", "publish",
                        "--mbt-compat", compat_dir, "--pionc", pionc])
    assert r_lx_pub.returncode == 0, f"10m-4 {tag_lx} publish failed: {r_lx_pub.returncode} {r_lx_pub.stdout} {r_lx_pub.stderr}"
    has_extra = os.path.isfile(os.path.join(o_lx, "extra.pion"))
    assert has_extra == expect_extra, f"10m-4 {tag_lx} extra.pion exists={has_extra}, expected {expect_extra}"
    pkg_lx = os.path.join(root, f"pkg10m4_{tag_lx}")
    os.makedirs(os.path.join(pkg_lx, "src"), exist_ok=True)
    for fn in sorted(os.listdir(o_lx)):
        if fn.endswith(".pion"):
            shutil.copyfile(os.path.join(o_lx, fn), os.path.join(pkg_lx, "src", fn))
    with open(os.path.join(pkg_lx, "pion.toml"), "w") as f:
        f.write(f'[package]\nname = "e2e_10m4_{tag_lx}"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
    with open(os.path.join(pkg_lx, "src", "main.pion"), "w") as f:
        f.write('pub fn main(world : World) -> Int {\n  io_println(world, sample().to_string())\n  0\n}\n')
    run_cmd = [pionc, "run", "--target", "wasm32", pkg_lx] if shutil.which("node") else [pionc, "run", pkg_lx]
    r_lx_run = subprocess.run(run_cmd, capture_output=True, text=True)
    assert r_lx_run.returncode == 0, f"10m-4 {tag_lx} run failed: {r_lx_run.stdout} {r_lx_run.stderr}"
    assert r_lx_run.stdout.strip() == expected_out, f"10m-4 {tag_lx} expected {expected_out!r}, got {r_lx_run.stdout!r}"

s_lx_bad = os.path.join(root, "s10m4_bad")
o_lx_bad = os.path.join(root, "o10m4_bad")
os.makedirs(s_lx_bad, exist_ok=True)
with open(os.path.join(s_lx_bad, "moon.pkg"), "w") as f:
    f.write("options(targets: 123)\n")
with open(os.path.join(s_lx_bad, "a.mbt"), "w") as f:
    f.write("pub fn ok() -> Int { 1 }\n")
r_lx_bad = run_cli(["--src", s_lx_bad, "--out", o_lx_bad, "--target", "wasm32", "--mode", "publish",
                    "--mbt-compat", compat_dir, "--pionc", pionc])
assert r_lx_bad.returncode == 1, f"10m-4 malformed targets must exit 1, got {r_lx_bad.returncode}"
assert "MBT2PION_UNSUPPORTED_TARGET_RULE" in (r_lx_bad.stdout + r_lx_bad.stderr), "10m-4 missing MBT2PION_UNSUPPORTED_TARGET_RULE"

print("[e2e] PASS: Final Astra P0 lexer-backed moon.pkg suite (10m-4: targets : / // comment / // } -> 21/22/21 + malformed 123 -> rc=1)")

# 10m-5. Final Astra P0 moon.pkg string escape decoding + decoded duplicate key fail-closed:
#        escaped_name / escaped_field / escaped_value -> publish rc=0, extra.pion absent, live wasm32 == 21;
#        duplicate_decoded & invalid_escape -> publish rc=1 + MBT2PION_UNSUPPORTED_TARGET_RULE!
for tag_es, pkg_txt in [
    ("escaped_name", 'options(targets: {"ex\\u0074ra.mbt": "wasm"})\n'),
    ("escaped_field", 'options("tar\\u0067ets": {"extra.mbt": "wasm"})\n'),
    ("escaped_value", 'options(targets: {"extra.mbt": "w\\u0061sm"})\n'),
]:
    s_es = os.path.join(root, f"s10m5_{tag_es}")
    o_es = os.path.join(root, f"o10m5_{tag_es}")
    os.makedirs(s_es, exist_ok=True)
    with open(os.path.join(s_es, "moon.pkg"), "w") as f:
        f.write(pkg_txt)
    with open(os.path.join(s_es, "extra.mbt"), "w") as f:
        f.write("fn init {\n  xs.push(9)\n}\n")
    with open(os.path.join(s_es, "common.mbt"), "w") as f:
        f.write(
            'let xs : Array[Int] = [0]\n'
            '#cfg(target="wasm-gc")\n'
            'fn bit() -> Int { 20 }\n'
            '#cfg(not(target="wasm-gc"))\n'
            'fn bit() -> Int { 10 }\n'
            'pub fn sample() -> Int { xs.length() + bit() }\n'
        )
    r_es_pub = run_cli(["--src", s_es, "--out", o_es, "--target", "wasm32", "--mode", "publish",
                        "--mbt-compat", compat_dir, "--pionc", pionc])
    assert r_es_pub.returncode == 0, f"10m-5 {tag_es} publish failed: {r_es_pub.returncode} {r_es_pub.stdout} {r_es_pub.stderr}"
    assert not os.path.isfile(os.path.join(o_es, "extra.pion")), f"10m-5 {tag_es} should have excluded extra.pion!"
    pkg_es = os.path.join(root, f"pkg10m5_{tag_es}")
    os.makedirs(os.path.join(pkg_es, "src"), exist_ok=True)
    for fn in sorted(os.listdir(o_es)):
        if fn.endswith(".pion"):
            shutil.copyfile(os.path.join(o_es, fn), os.path.join(pkg_es, "src", fn))
    with open(os.path.join(pkg_es, "pion.toml"), "w") as f:
        f.write(f'[package]\nname = "e2e_10m5_{tag_es}"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
    with open(os.path.join(pkg_es, "src", "main.pion"), "w") as f:
        f.write('pub fn main(world : World) -> Int {\n  io_println(world, sample().to_string())\n  0\n}\n')
    run_cmd = [pionc, "run", "--target", "wasm32", pkg_es] if shutil.which("node") else [pionc, "run", pkg_es]
    r_es_run = subprocess.run(run_cmd, capture_output=True, text=True)
    assert r_es_run.returncode == 0, f"10m-5 {tag_es} run failed: {r_es_run.stdout} {r_es_run.stderr}"
    assert r_es_run.stdout.strip() == "21", f"10m-5 {tag_es} expected '21', got {r_es_run.stdout!r}"

for tag_eb, bad_pkg_txt in [
    ("duplicate_decoded", 'options(targets: {"extra.mbt": "native", "ex\\u0074ra.mbt": "wasm"})\n'),
    ("invalid_escape", 'options(targets: {"extra.mbt": "w\\qsm"})\n'),
    ("escapedhex", 'options(targets: {"ex\\x74ra.mbt": "wasm"})\n'),
    ("escapedbraces", 'options(targets: {"ex\\u{74}ra.mbt": "wasm"})\n'),
]:
    s_eb = os.path.join(root, f"s10m5_bad_{tag_eb}")
    o_eb = os.path.join(root, f"o10m5_bad_{tag_eb}")
    os.makedirs(s_eb, exist_ok=True)
    with open(os.path.join(s_eb, "moon.pkg"), "w") as f:
        f.write(bad_pkg_txt)
    with open(os.path.join(s_eb, "extra.mbt"), "w") as f:
        f.write("pub fn ok() -> Int { 1 }\n")
    r_eb = run_cli(["--src", s_eb, "--out", o_eb, "--target", "wasm32", "--mode", "publish",
                    "--mbt-compat", compat_dir, "--pionc", pionc])
    assert r_eb.returncode == 1, f"10m-5 {tag_eb} must fail (rc=1), got {r_eb.returncode}"
    assert "MBT2PION_UNSUPPORTED_TARGET_RULE" in (r_eb.stdout + r_eb.stderr), f"10m-5 {tag_eb} missing MBT2PION_UNSUPPORTED_TARGET_RULE"

s_cfg_esc = os.path.join(root, "s10m5_cfg_escape")
o_cfg_esc = os.path.join(root, "o10m5_cfg_escape")
os.makedirs(s_cfg_esc, exist_ok=True)
with open(os.path.join(s_cfg_esc, "a.mbt"), "w") as f:
    f.write('#cfg(target="w\\u0061sm-gc")\npub fn f() -> Int { 1 }\n')
r_cfg_esc = run_cli(["--src", s_cfg_esc, "--out", o_cfg_esc, "--target", "wasm32", "--mode", "publish",
                     "--mbt-compat", compat_dir, "--pionc", pionc])
assert r_cfg_esc.returncode == 1, f"10m-5 cfg_escape must fail (rc=1), got {r_cfg_esc.returncode}"
assert "MBT2PION_UNSUPPORTED_CFG" in (r_cfg_esc.stdout + r_cfg_esc.stderr), "10m-5 cfg_escape missing MBT2PION_UNSUPPORTED_CFG"

print("[e2e] PASS: Final Astra P0+P1 strict RFC 8259 JSON escape & raw #cfg suite (10m-5: escaped_name/field/value -> 21, duplicate/hex/braces/cfg_escape -> rc=1)")

# 10n. Red-team P0 live native acceptance:
#      extern "C" fn c_abs(x : Int) -> Int = "abs" + #cfg(target="js") js_only + #cfg(target="native") native_only + kept()
#      -> publish --target native rc=0, 0 js_only, 4 exact dispositions, live `pionc run` prints `2`!
s10n = os.path.join(root, "s10n")
o10n = os.path.join(root, "o10n")
rep10n = os.path.join(root, "rep10n.json")
os.makedirs(s10n, exist_ok=True)
with open(os.path.join(s10n, "ffi_cfg.mbt"), "w") as f:
    f.write(
        'extern "C" fn c_abs(x : Int) -> Int = "abs"\n'
        '#cfg(target="js")\n'
        'pub fn js_only() -> Int { 1 }\n'
        '#cfg(target="native")\n'
        'pub fn native_only() -> Int { c_abs(-2) }\n'
        'pub fn kept() -> Int { native_only() }\n'
    )
r10n_pub = run_cli(["--src", s10n, "--out", o10n, "--target", "native", "--mode", "publish",
                    "--mbt-compat", compat_dir, "--pionc", pionc, "--report", rep10n])
assert r10n_pub.returncode == 0, f"10n native publish failed: {r10n_pub.returncode} {r10n_pub.stdout} {r10n_pub.stderr}"
gen10n = open(os.path.join(o10n, "ffi_cfg.pion")).read()
assert "js_only" not in gen10n, f"10n leaked js_only into output:\n{gen10n}"
rep10n_obj = json.load(open(rep10n))
disps10n = [(d["decl"], d["disposition"]) for d in rep10n_obj["dispositions"]]
assert disps10n == [
    ("fn:c_abs", "transpiled"),
    ("fn:js_only", "excluded_by_cfg"),
    ("fn:native_only", "transpiled"),
    ("fn:kept", "transpiled"),
], f"10n unexpected dispositions: {disps10n}"

pkg10n = os.path.join(root, "pkg10n")
os.makedirs(os.path.join(pkg10n, "src"), exist_ok=True)
for fn in sorted(os.listdir(o10n)):
    if fn.endswith(".pion"):
        shutil.copyfile(os.path.join(o10n, fn), os.path.join(pkg10n, "src", fn))
with open(os.path.join(pkg10n, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "e2e_10n"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
with open(os.path.join(pkg10n, "src", "main.pion"), "w") as f:
    f.write(
        'pub fn main(world : World) -> Int {\n'
        '  io_println(world, kept().to_string())\n'
        '  0\n'
        '}\n'
    )
r10n_run = subprocess.run([pionc, "run", pkg10n], capture_output=True, text=True)
assert r10n_run.returncode == 0, f"10n pionc run failed: {r10n_run.stdout} {r10n_run.stderr}"
assert r10n_run.stdout.strip() == "2", f"10n expected '2', got {r10n_run.stdout!r}"

print("[e2e] PASS: Red-team P0 suite (10n: extern \"C\" fn c_abs = \"abs\" + #cfg(target=\"js\") excluded + live native run == 2)")

# 10n-2. Astra P1: `#borrow(s) extern "C" fn first(s : String) -> Int = "first_unit"` MUST fail publish (rc=1)
#        with MBT2PION_UNSUPPORTED_FFI_SIGNATURE and disposition `fn:first` == "unsupported"!
s10n2 = os.path.join(root, "s10n2")
o10n2 = os.path.join(root, "o10n2")
rep10n2 = os.path.join(root, "rep10n2.json")
os.makedirs(s10n2, exist_ok=True)
with open(os.path.join(s10n2, "bad_ffi.mbt"), "w") as f:
    f.write('#borrow(s)\nextern "C" fn first(s : String) -> Int = "first_unit"\n')
r10n2 = run_cli(["--src", s10n2, "--out", o10n2, "--target", "native", "--mode", "publish",
                 "--mbt-compat", compat_dir, "--pionc", pionc, "--report", rep10n2])
assert r10n2.returncode == 1, f"10n-2 non-C-ABI extern C fn must fail (rc=1), got {r10n2.returncode}"
assert "MBT2PION_UNSUPPORTED_FFI_SIGNATURE" in (r10n2.stdout + r10n2.stderr), "10n-2 missing MBT2PION_UNSUPPORTED_FFI_SIGNATURE"
disps10n2 = [(d["decl"], d["disposition"]) for d in json.load(open(rep10n2))["dispositions"]]
assert disps10n2 == [("fn:first", "unsupported")], f"10n-2 unexpected dispositions: {disps10n2}"

print("[e2e] PASS: Final Astra P1 suite (10n-2: #borrow(s) String extern \"C\" fn -> rc=1 MBT2PION_UNSUPPORTED_FFI_SIGNATURE + unsupported)")

# 10o. Quadrant 2: CLI negative tests for P0-5 (5 malformed asset manifests) & P0-6 (--closure-report path collision)
s10o = os.path.join(root, "s10o")
o10o = os.path.join(root, "o10o")
os.makedirs(s10o, exist_ok=True)
with open(os.path.join(s10o, "ok.mbt"), "w") as f:
    f.write("pub fn ok() -> Int { 1 }\n")
with open(os.path.join(s10o, "data.mbt"), "w") as f:
    f.write("pub let d : Array[Int] = [1, 2]\n")
import hashlib
d_sha = hashlib.sha256(open(os.path.join(s10o, "data.mbt"), "rb").read()).hexdigest()
bad_manifests = [
    ("missing_sha", [{"path": "data.mbt", "sha256": "", "allowed_decls": ["d"]}]),
    ("empty_decls", [{"path": "data.mbt", "sha256": d_sha, "allowed_decls": []}]),
    ("abs_path", [{"path": "/etc/passwd", "sha256": d_sha, "allowed_decls": ["d"]}]),
    ("parent_ref", [{"path": "../data.mbt", "sha256": d_sha, "allowed_decls": ["d"]}]),
    ("bad_ident", [{"path": "data.mbt", "sha256": d_sha, "allowed_decls": ["9bad"]}]),
]
for mtag, mlist in bad_manifests:
    mf = os.path.join(root, f"bad_manifest_{mtag}.json")
    with open(mf, "w") as f:
        json.dump({"assets": mlist}, f)
    rm = run_cli(["--src", s10o, "--out", o10o, "--target", "native", "--mode", "publish",
                  "--asset-manifest", mf, "--mbt-compat", compat_dir, "--pionc", pionc])
    assert rm.returncode == 1, f"10o {mtag} must fail (rc=1), got {rm.returncode}"
    assert "MBT2PION_ASSET_MANIFEST_INVALID" in (rm.stdout + rm.stderr), f"10o {mtag} missing MBT2PION_ASSET_MANIFEST_INVALID"

# P0-6: --closure-report inside --out must fail before publish!
r_cc = run_cli(["--src", s10o, "--out", o10o, "--target", "native", "--mode", "publish",
                "--closure-report", os.path.join(o10o, "ok.pion"), "--mbt-compat", compat_dir, "--pionc", pionc])
assert r_cc.returncode == 1, f"10o --closure-report inside --out must fail (rc=1), got {r_cc.returncode}"
assert "--closure-report" in (r_cc.stdout + r_cc.stderr), f"10o missing --closure-report error: {r_cc.stdout} {r_cc.stderr}"

print("[e2e] PASS: Quadrant 2 P0-5 & P0-6 CLI negative tests (5 malformed manifests + --closure-report collision)")

# 10p. Quadrant 2 Item 10: --with-tests end-to-end (`*_wbtest.mbt` -> `*_wb_test.pion`, `*_test.mbt` -> `*_test.pion`,
#      isolation from `00_init_order.pion`, assertions + `raise` stripping -> `pionc check` + `pionc test` PASS,
#      and mutated assertion FAILS `pionc test`!)
s10p = os.path.join(root, "s10p_pkg")
o10p = os.path.join(root, "o10p")
os.makedirs(s10p, exist_ok=True)
with open(os.path.join(s10p, "math.mbt"), "w") as f:
    f.write("pub let base_val = 40\npub fn add2(x : Int) -> Int { x + 2 }\nfn internal_mul(x : Int) -> Int { x * 3 }\n")
with open(os.path.join(s10p, "math_wbtest.mbt"), "w") as f:
    f.write(
        'let wb_k = 7\n'
        'fn check_pair(a : Int, b : Int) raise {\n'
        '  assert_eq(a, b)\n'
        '  assert_not_eq(a, b + 1)\n'
        '}\n'
        'test {\n'
        '  check_pair(internal_mul(wb_k), 21)\n'
        '  assert_true(add2(base_val) == 42)\n'
        '  assert_false(add2(base_val) == 0)\n'
        '  inspect(add2(base_val), content="42")\n'
        '}\n'
    )
with open(os.path.join(s10p, "math_test.mbt"), "w") as f:
    f.write(
        'test "blackbox_add2" {\n'
        '  assert_eq(@s10p_pkg.add2(@s10p_pkg.base_val), 42)\n'
        '  inspect(@s10p_pkg.add2(10), content="12")\n'
        '}\n'
    )
r10p = run_cli(["--src", s10p, "--out", o10p, "--target", "native", "--mode", "publish", "--with-tests",
                "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10p.returncode == 0, f"10p --with-tests publish failed: {r10p.returncode}\n{r10p.stdout}\n{r10p.stderr}"
assert os.path.exists(os.path.join(o10p, "math_wbtest_test.pion")), "10p missing math_wbtest_test.pion"
assert os.path.exists(os.path.join(o10p, "math_test.pion")), "10p missing math_test.pion"
assert os.path.exists(os.path.join(o10p, "00_init_order.pion")), "10p missing 00_init_order.pion"
assert os.path.exists(os.path.join(o10p, "00_init_order_test.pion")), "10p missing 00_init_order_test.pion"
prod_init_10p = open(os.path.join(o10p, "00_init_order.pion")).read()
assert "wb_k" not in prod_init_10p, f"10p test let leaked into production 00_init_order.pion:\n{prod_init_10p}"

pkg10p = os.path.join(root, "pkg10p")
os.makedirs(os.path.join(pkg10p, "src"), exist_ok=True)
for fn in sorted(os.listdir(o10p)):
    if fn.endswith(".pion"):
        shutil.copyfile(os.path.join(o10p, fn), os.path.join(pkg10p, "src", fn))
with open(os.path.join(pkg10p, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "s10p_pkg"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
r10p_chk = subprocess.run([pionc, "check", pkg10p], capture_output=True, text=True)
assert r10p_chk.returncode == 0, f"10p pionc check failed:\n{r10p_chk.stdout}\n{r10p_chk.stderr}"
r10p_tst = subprocess.run([pionc, "test", pkg10p], capture_output=True, text=True)
assert r10p_tst.returncode == 0, f"10p pionc test failed:\n{r10p_tst.stdout}\n{r10p_tst.stderr}"
assert "2 passed; 0 failed" in r10p_tst.stdout, f"10p expected 2 passed tests, got:\n{r10p_tst.stdout}"

# Mutate one assertion and verify `pionc test` genuinely FAILS!
mut_path = os.path.join(pkg10p, "src", "math_test.pion")
mut_orig = open(mut_path).read()
assert "42" in mut_orig, f"10p expected 42 in math_test.pion:\n{mut_orig}"
with open(mut_path, "w") as f:
    f.write(mut_orig.replace("42", "999", 1))
r10p_fail = subprocess.run([pionc, "test", pkg10p], capture_output=True, text=True)
assert r10p_fail.returncode != 0, f"10p mutated assertion MUST fail pionc test!\n{r10p_fail.stdout}"

print("[e2e] PASS: Quadrant 2 --with-tests E2E (math_wbtest_test.pion + math_test.pion + isolated init -> pionc check & test 2/2 PASS, mutant FAIL)")

# 10q. Astra Final 5 P0 + 2 P1 E2E regressions:
# 10q-1 (P0-1): `f_wb_test.mbt` (pass) + `f_wbtest.mbt` (fail) must NOT collide!
s10q1 = os.path.join(root, "s10q1")
o10q1 = os.path.join(root, "o10q1")
os.makedirs(s10q1, exist_ok=True)
with open(os.path.join(s10q1, "lib.mbt"), "w") as f:
    f.write("pub fn id(x : Int) -> Int { x }\n")
with open(os.path.join(s10q1, "f_wb_test.mbt"), "w") as f:
    f.write('test "bb_pass" { assert_true(true) }\n')
with open(os.path.join(s10q1, "f_wbtest.mbt"), "w") as f:
    f.write('test "wb_fail" { assert_true(false) }\n')
r10q1 = run_cli(["--src", s10q1, "--out", o10q1, "--target", "native", "--mode", "publish", "--with-tests",
                 "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q1.returncode == 0, f"10q-1 publish failed: {r10q1.returncode}\n{r10q1.stdout}\n{r10q1.stderr}"
assert os.path.exists(os.path.join(o10q1, "f_wb_test.pion")), "10q-1 missing f_wb_test.pion"
assert os.path.exists(os.path.join(o10q1, "f_wbtest_test.pion")), "10q-1 missing f_wbtest_test.pion"
pkg10q1 = os.path.join(root, "pkg10q1")
os.makedirs(os.path.join(pkg10q1, "src"), exist_ok=True)
for fn in os.listdir(o10q1):
    if fn.endswith(".pion"): shutil.copyfile(os.path.join(o10q1, fn), os.path.join(pkg10q1, "src", fn))
with open(os.path.join(pkg10q1, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "s10q1"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
r10q1_t = subprocess.run([pionc, "test", pkg10q1], capture_output=True, text=True)
assert r10q1_t.returncode != 0 and "1 passed; 1 failed" in r10q1_t.stdout, f"10q-1 expected 1 passed + 1 failed, got:\n{r10q1_t.stdout}\n{r10q1_t.stderr}"

# 10q-2 (P0-2): black-box `bb_test.mbt` defining no-op `fn assert_true` MUST NOT shadow white-box `wb_wbtest.mbt`!
s10q2 = os.path.join(root, "s10q2")
o10q2 = os.path.join(root, "o10q2")
os.makedirs(s10q2, exist_ok=True)
with open(os.path.join(s10q2, "lib.mbt"), "w") as f:
    f.write("pub fn ok() -> Int { 1 }\n")
with open(os.path.join(s10q2, "bb_test.mbt"), "w") as f:
    f.write('fn assert_true(_c : Bool) -> Unit { () }\ntest "bb_noop_pass" { assert_true(false) }\n')
with open(os.path.join(s10q2, "wb_wbtest.mbt"), "w") as f:
    f.write('test "wb_real_fail" { assert_true(false) }\n')
r10q2 = run_cli(["--src", s10q2, "--out", o10q2, "--target", "native", "--mode", "publish", "--with-tests",
                 "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q2.returncode == 0, f"10q-2 publish failed: {r10q2.returncode}\n{r10q2.stdout}\n{r10q2.stderr}"
pkg10q2 = os.path.join(root, "pkg10q2")
os.makedirs(os.path.join(pkg10q2, "src"), exist_ok=True)
for fn in os.listdir(o10q2):
    if fn.endswith(".pion"): shutil.copyfile(os.path.join(o10q2, fn), os.path.join(pkg10q2, "src", fn))
with open(os.path.join(pkg10q2, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "s10q2"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
r10q2_t = subprocess.run([pionc, "test", pkg10q2], capture_output=True, text=True)
assert r10q2_t.returncode != 0 and "1 passed; 1 failed" in r10q2_t.stdout, f"10q-2 expected bb PASS + wb FAIL, got:\n{r10q2_t.stdout}\n{r10q2_t.stderr}"

# 10q-2b (Astra Follow-up P0): black-box `a_test.mbt` + `b_test.mbt` share black-box module symbols,
# while staying isolated from white-box `c_wbtest.mbt`!
s10q2b = os.path.join(root, "s10q2b")
o10q2b = os.path.join(root, "o10q2b")
os.makedirs(s10q2b, exist_ok=True)
with open(os.path.join(s10q2b, "lib.mbt"), "w") as f:
    f.write("pub fn ok() -> Int { 1 }\n")
with open(os.path.join(s10q2b, "a_test.mbt"), "w") as f:
    f.write('fn assert_true(_v : Bool) -> Unit { abort("custom") }\n')
with open(os.path.join(s10q2b, "b_test.mbt"), "w") as f:
    f.write('test "bb_calls_a_assert" { assert_true(true) }\n')
with open(os.path.join(s10q2b, "c_wbtest.mbt"), "w") as f:
    f.write('test "wb_calls_builtin_assert" { assert_true(false) }\n')
r10q2b = run_cli(["--src", s10q2b, "--out", o10q2b, "--target", "native", "--mode", "publish", "--with-tests",
                  "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q2b.returncode == 0, f"10q-2b publish failed: {r10q2b.returncode}\n{r10q2b.stdout}\n{r10q2b.stderr}"
pkg10q2b = os.path.join(root, "pkg10q2b")
os.makedirs(os.path.join(pkg10q2b, "src"), exist_ok=True)
for fn in os.listdir(o10q2b):
    if fn.endswith(".pion"): shutil.copyfile(os.path.join(o10q2b, fn), os.path.join(pkg10q2b, "src", fn))
with open(os.path.join(pkg10q2b, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "s10q2b"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
r10q2b_t = subprocess.run([pionc, "test", pkg10q2b], capture_output=True, text=True)
assert r10q2b_t.returncode != 0 and "0 passed; 2 failed" in r10q2b_t.stdout, f"10q-2b expected 0 passed + 2 failed, got:\n{r10q2b_t.stdout}\n{r10q2b_t.stderr}"

# 10q-6 (Astra Follow-up P1-3): multiline top-level `let` in `v.mbt` reports distinct ProbeDisposition lines (2 & 3) AND runs via `pionc run`!
s10q6 = os.path.join(root, "s10q6")
o10q6 = os.path.join(root, "o10q6")
rep10q6 = os.path.join(root, "rep10q6.json")
os.makedirs(s10q6, exist_ok=True)
with open(os.path.join(s10q6, "v.mbt"), "w") as f:
    f.write('pub let n : Int =\n  "x".length() +\n  "ab".length()\n')
r10q6 = run_cli(["--src", s10q6, "--out", o10q6, "--target", "native", "--mode", "publish",
                 "--report", rep10q6, "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q6.returncode == 0, f"10q-6 publish failed: {r10q6.returncode}\n{r10q6.stdout}\n{r10q6.stderr}"
rep6_j = json.load(open(rep10q6))
pds6 = [(p["file"], p["line"], p["col"]) for p in rep6_j["probe_dispositions"] if p["disposition"] == "rewritten"]
assert ("v.mbt", 2, 7) in pds6 and ("v.mbt", 3, 8) in pds6, f"10q-6 expected v.mbt:2:7 and v.mbt:3:8, got {pds6}"
pkg10q6 = os.path.join(root, "pkg10q6")
os.makedirs(os.path.join(pkg10q6, "src"), exist_ok=True)
for fn in os.listdir(o10q6):
    if fn.endswith(".pion"): shutil.copyfile(os.path.join(o10q6, fn), os.path.join(pkg10q6, "src", fn))
with open(os.path.join(pkg10q6, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "s10q6"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
with open(os.path.join(pkg10q6, "src", "main.pion"), "w") as f:
    f.write('pub fn main(_w : World) -> Int { if n != 3 { panic("bad") }; 0 }\n')
r10q6_run = subprocess.run([pionc, "run", pkg10q6], capture_output=True, text=True)
assert r10q6_run.returncode == 0, f"10q-6 pionc run failed: {r10q6_run.stderr}"

# 10q-3b (Opus P2-1): assertion args evaluate in MoonBit declaration order (positional -> msg= -> loc=),
# AND 10q-2c (Opus P2-2): black-box module preserves `#callsite(autofill(loc))` without leaking to white-box!
s10q7 = os.path.join(root, "s10q7")
o10q7 = os.path.join(root, "o10q7")
os.makedirs(s10q7, exist_ok=True)
with open(os.path.join(s10q7, "lib.mbt"), "w") as f:
    f.write("pub fn ok() -> Int { 1 }\n")
with open(os.path.join(s10q7, "af_test.mbt"), "w") as f:
    f.write(
        '#callsite(autofill(loc))\n'
        'fn chk(x : Int, loc~ : SourceLoc) -> String {\n'
        '  let _ = x\n'
        '  loc.to_string()\n'
        '}\n'
        'test "bb_autofill_and_decl_order" {\n'
        '  let mut log = ""\n'
        '  assert_eq(msg={ log = log + "1"; "m" }, { log = log + "2"; 10 }, { log = log + "2"; 10 })\n'
        '  assert_eq(log, "221")\n'
        '  let got = chk(6)\n'
        '  assert_true(got.starts_with("af_test.mbt:"))\n'
        '}\n'
    )
r10q7 = run_cli(["--src", s10q7, "--out", o10q7, "--target", "native", "--mode", "publish", "--with-tests",
                 "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q7.returncode == 0, f"10q-7 publish failed: {r10q7.returncode}\n{r10q7.stdout}\n{r10q7.stderr}"
pkg10q7 = os.path.join(root, "pkg10q7")
os.makedirs(os.path.join(pkg10q7, "src"), exist_ok=True)
for fn in os.listdir(o10q7):
    if fn.endswith(".pion"): shutil.copyfile(os.path.join(o10q7, fn), os.path.join(pkg10q7, "src", fn))
with open(os.path.join(pkg10q7, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "s10q7"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
r10q7_t = subprocess.run([pionc, "test", pkg10q7], capture_output=True, text=True)
assert r10q7_t.returncode == 0 and "1 passed; 0 failed" in r10q7_t.stdout, f"10q-7 expected 1 passed, got:\n{r10q7_t.stdout}\n{r10q7_t.stderr}"

# 10q-2d (Astra Final P0): black-box `b_test.mbt` sees production `pub fn assert_true`,
# while production private `fn assert_false` is NOT visible to black-box (falls through to builtin)!
s10q2d = os.path.join(root, "s10q2d")
o10q2d = os.path.join(root, "o10q2d")
os.makedirs(s10q2d, exist_ok=True)
with open(os.path.join(s10q2d, "main.mbt"), "w") as f:
    f.write(
        'pub fn assert_true(_v : Bool) -> Unit { abort("in library") }\n'
        'fn assert_false(_v : Bool) -> Unit { () }\n'
    )
with open(os.path.join(s10q2d, "b_test.mbt"), "w") as f:
    f.write(
        'test "bb_sees_prod_pub" { assert_true(true) }\n'
        'test "bb_ignores_prod_priv" { assert_false(true) }\n'
    )
r10q2d = run_cli(["--src", s10q2d, "--out", o10q2d, "--target", "native", "--mode", "publish", "--with-tests",
                  "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q2d.returncode == 0, f"10q-2d publish failed: {r10q2d.returncode}\n{r10q2d.stdout}\n{r10q2d.stderr}"
btest_txt = open(os.path.join(o10q2d, "b_test.pion")).read()
assert "mbt_compat::assert_true" not in btest_txt, f"10q-2d prod pub assert_true must not be rewritten:\n{btest_txt}"
assert "mbt_compat::assert_false" in btest_txt, f"10q-2d prod priv assert_false must fall through to builtin:\n{btest_txt}"
pkg10q2d = os.path.join(root, "pkg10q2d")
os.makedirs(os.path.join(pkg10q2d, "src"), exist_ok=True)
for fn in os.listdir(o10q2d):
    if fn.endswith(".pion"): shutil.copyfile(os.path.join(o10q2d, fn), os.path.join(pkg10q2d, "src", fn))
with open(os.path.join(pkg10q2d, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "s10q2d"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
r10q2d_t = subprocess.run([pionc, "test", pkg10q2d], capture_output=True, text=True)
assert r10q2d_t.returncode != 0 and "0 passed; 2 failed" in r10q2d_t.stdout, f"10q-2d expected 0 passed + 2 failed, got:\n{r10q2d_t.stdout}\n{r10q2d_t.stderr}"

# 10q-6b (Astra Final P1): compact single-line `pub let n:Int="x".length() + "ab".length()` reports exact 1:19 and 1:35!
s10q6b = os.path.join(root, "s10q6b")
o10q6b = os.path.join(root, "o10q6b")
rep10q6b = os.path.join(root, "rep10q6b.json")
os.makedirs(s10q6b, exist_ok=True)
with open(os.path.join(s10q6b, "vs.mbt"), "w") as f:
    f.write('pub let n:Int="x".length() + "ab".length()\n')
r10q6b = run_cli(["--src", s10q6b, "--out", o10q6b, "--target", "native", "--mode", "publish",
                  "--report", rep10q6b, "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q6b.returncode == 0, f"10q-6b publish failed: {r10q6b.returncode}\n{r10q6b.stdout}\n{r10q6b.stderr}"
rep6b_j = json.load(open(rep10q6b))
pds6b = [(p["file"], p["line"], p["col"]) for p in rep6b_j["probe_dispositions"] if p["disposition"] == "rewritten"]
assert ("vs.mbt", 1, 19) in pds6b and ("vs.mbt", 1, 35) in pds6b, f"10q-6b expected vs.mbt:1:19 and vs.mbt:1:35, got {pds6b}"

# 10q-2e (Astra Structural P0): `pub enum Mode { Ready }\nfn assert_true` MUST NOT leak pub to `assert_true`,
# AND fn-body local `let assert_true = ...` MUST NOT pollute package-level symtab!
s10q2e = os.path.join(root, "s10q2e")
o10q2e = os.path.join(root, "o10q2e")
os.makedirs(s10q2e, exist_ok=True)
with open(os.path.join(s10q2e, "main.mbt"), "w") as f:
    f.write(
        'pub enum Mode { Ready }\n'
        'fn assert_true(_v : Bool) -> Unit { () }\n'
        'pub fn helper() -> Int {\n'
        '  let assert_false = 1\n'
        '  assert_false\n'
        '}\n'
    )
with open(os.path.join(s10q2e, "b_test.mbt"), "w") as f:
    f.write('test "bb_enum_no_pub_leak" { assert_true(false) }\n')
with open(os.path.join(s10q2e, "w_wbtest.mbt"), "w") as f:
    f.write('test "wb_local_let_no_symtab_leak" { assert_false(true) }\n')
r10q2e = run_cli(["--src", s10q2e, "--out", o10q2e, "--target", "native", "--mode", "publish", "--with-tests",
                  "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q2e.returncode == 0, f"10q-2e publish failed: {r10q2e.returncode}\n{r10q2e.stdout}\n{r10q2e.stderr}"
assert "mbt_compat::assert_true" in open(os.path.join(o10q2e, "b_test.pion")).read(), "10q-2e b_test.pion must call builtin assert_true"
assert "mbt_compat::assert_false" in open(os.path.join(o10q2e, "w_wbtest_test.pion")).read(), "10q-2e w_wbtest_test.pion must call builtin assert_false"
pkg10q2e = os.path.join(root, "pkg10q2e")
os.makedirs(os.path.join(pkg10q2e, "src"), exist_ok=True)
for fn in os.listdir(o10q2e):
    if fn.endswith(".pion"): shutil.copyfile(os.path.join(o10q2e, fn), os.path.join(pkg10q2e, "src", fn))
with open(os.path.join(pkg10q2e, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "s10q2e"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
r10q2e_t = subprocess.run([pionc, "test", pkg10q2e], capture_output=True, text=True)
assert r10q2e_t.returncode != 0 and "0 passed; 2 failed" in r10q2e_t.stdout, f"10q-2e expected 0 passed + 2 failed, got:\n{r10q2e_t.stdout}\n{r10q2e_t.stderr}"

# 10q-6c (Astra Structural P1): single-line `pub let n:Int={ let _v : Int? = Some(1); "ab".length() }`
# reports exact source column 1:47 despite `Int?` -> `Option[Int]` Stage A expansion!
s10q6c = os.path.join(root, "s10q6c")
o10q6c = os.path.join(root, "o10q6c")
rep10q6c = os.path.join(root, "rep10q6c.json")
os.makedirs(s10q6c, exist_ok=True)
with open(os.path.join(s10q6c, "v.mbt"), "w") as f:
    f.write('pub let n:Int={ let _v : Int? = Some(1); "ab".length() }\n')
r10q6c = run_cli(["--src", s10q6c, "--out", o10q6c, "--target", "native", "--mode", "publish",
                  "--report", rep10q6c, "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q6c.returncode == 0, f"10q-6c publish failed: {r10q6c.returncode}\n{r10q6c.stdout}\n{r10q6c.stderr}"
rep6c_j = json.load(open(rep10q6c))
pds6c = [(p["file"], p["line"], p["col"]) for p in rep6c_j["probe_dispositions"] if p["disposition"] == "rewritten"]
assert ("v.mbt", 1, 47) in pds6c, f"10q-6c expected v.mbt:1:47, got {pds6c}"

# 10q-6d (Astra Final P1): 1, 2, 3 consecutive interpolations in top-level `let` report exact cols
# [28], [28, 42], [28, 42, 56] AND Pion native outputs `a2b2b2`!
for k_cnt, body_lit, exp_cols in [
    (1, '"a\\{s.length()}"', [28]),
    (2, '"a\\{s.length()}b\\{s.length()}"', [28, 42]),
    (3, '"a\\{s.length()}b\\{s.length()}b\\{s.length()}"', [28, 42, 56]),
]:
    s10q6d = os.path.join(root, f"s10q6d_{k_cnt}")
    o10q6d = os.path.join(root, f"o10q6d_{k_cnt}")
    rep10q6d = os.path.join(root, f"rep10q6d_{k_cnt}.json")
    os.makedirs(s10q6d, exist_ok=True)
    with open(os.path.join(s10q6d, "vi.mbt"), "w") as f:
        f.write(f'pub let s : String = "hi"\npub let n : String = {body_lit}\n')
    r10q6d = run_cli(["--src", s10q6d, "--out", o10q6d, "--target", "native", "--mode", "publish",
                      "--report", rep10q6d, "--mbt-compat", compat_dir, "--pionc", pionc])
    assert r10q6d.returncode == 0, f"10q-6d({k_cnt}) publish failed: {r10q6d.returncode}\n{r10q6d.stdout}\n{r10q6d.stderr}"
    rep6d_j = json.load(open(rep10q6d))
    got_cols = [p["col"] for p in rep6d_j["probe_dispositions"] if p["file"] == "vi.mbt" and p["line"] == 2 and p["probe_kind"] == "mbt_len_probe"]
    assert got_cols == exp_cols, f"10q-6d({k_cnt}) expected cols {exp_cols}, got {got_cols}"
    if k_cnt == 3:
        pkg10q6d = os.path.join(root, "pkg10q6d")
        os.makedirs(os.path.join(pkg10q6d, "src"), exist_ok=True)
        for fn in os.listdir(o10q6d):
            if fn.endswith(".pion"): shutil.copyfile(os.path.join(o10q6d, fn), os.path.join(pkg10q6d, "src", fn))
        with open(os.path.join(pkg10q6d, "pion.toml"), "w") as f:
            f.write(f'[package]\nname = "s10q6d"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
        with open(os.path.join(pkg10q6d, "src", "main.pion"), "w") as f:
            f.write('pub fn main(_w : World) -> Int { if n != "a2b2b2" { panic("bad: " + n) }; 0 }\n')
        r10q6d_run = subprocess.run([pionc, "run", pkg10q6d], capture_output=True, text=True)
        assert r10q6d_run.returncode == 0, f"10q-6d pionc run failed: {r10q6d_run.stderr}"

# 10q-6e (Astra Final 3-line P1): simple-ident `mbt_show_probe` in `"a\{  s  }b\{ s }"` reports [28, 36]
# and `"a\{s}b\{s}"` reports [26, 31], AND `pionc run == "ahibhi"`!
for tag, body_lit, exp_cols in [
    ("padded", '"a\\{  s  }b\\{ s }"', [28, 36]),
    ("tight", '"a\\{s}b\\{s}"', [26, 31]),
]:
    s10q6e = os.path.join(root, f"s10q6e_{tag}")
    o10q6e = os.path.join(root, f"o10q6e_{tag}")
    rep10q6e = os.path.join(root, f"rep10q6e_{tag}.json")
    os.makedirs(s10q6e, exist_ok=True)
    with open(os.path.join(s10q6e, "vs_show.mbt"), "w") as f:
        f.write(f'pub let s : String = "hi"\npub let n : String = {body_lit}\n')
    r10q6e = run_cli(["--src", s10q6e, "--out", o10q6e, "--target", "native", "--mode", "publish",
                      "--report", rep10q6e, "--mbt-compat", compat_dir, "--pionc", pionc])
    assert r10q6e.returncode == 0, f"10q-6e({tag}) publish failed: {r10q6e.returncode}\n{r10q6e.stdout}\n{r10q6e.stderr}"
    rep6e_j = json.load(open(rep10q6e))
    got_cols = [p["col"] for p in rep6e_j["probe_dispositions"] if p["file"] == "vs_show.mbt" and p["line"] == 2 and p["probe_kind"] == "mbt_show_probe"]
    assert got_cols == exp_cols, f"10q-6e({tag}) expected cols {exp_cols}, got {got_cols}"
    pkg10q6e = os.path.join(root, f"pkg10q6e_{tag}")
    os.makedirs(os.path.join(pkg10q6e, "src"), exist_ok=True)
    for fn in os.listdir(o10q6e):
        if fn.endswith(".pion"): shutil.copyfile(os.path.join(o10q6e, fn), os.path.join(pkg10q6e, "src", fn))
    with open(os.path.join(pkg10q6e, "pion.toml"), "w") as f:
        f.write(f'[package]\nname = "s10q6e_{tag}"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
    with open(os.path.join(pkg10q6e, "src", "main.pion"), "w") as f:
        f.write('pub fn main(_w : World) -> Int { if n != "ahibhi" { panic("bad: " + n) }; 0 }\n')
    r10q6e_run = subprocess.run([pionc, "run", pkg10q6e], capture_output=True, text=True)
    assert r10q6e_run.returncode == 0, f"10q-6e({tag}) pionc run failed: {r10q6e_run.stderr}"

# 10q-3 (P0-3): `assert_true(true, msg={ n = n + 1; "expected" })` evaluates side effects AND `msg=abort("boom")` fails!
s10q3 = os.path.join(root, "s10q3")
o10q3 = os.path.join(root, "o10q3")
os.makedirs(s10q3, exist_ok=True)
with open(os.path.join(s10q3, "lib.mbt"), "w") as f:
    f.write("pub fn ok() -> Int { 1 }\n")
with open(os.path.join(s10q3, "msg_wbtest.mbt"), "w") as f:
    f.write(
        'test "msg_side_effect_evals" {\n'
        '  let mut n = 0\n'
        '  assert_true(true, msg={ n = n + 1; "expected" })\n'
        '  assert_eq(n, 1)\n'
        '}\n'
        'test "msg_abort_fails" {\n'
        '  assert_true(true, msg=panic("boom"))\n'
        '}\n'
    )
r10q3 = run_cli(["--src", s10q3, "--out", o10q3, "--target", "native", "--mode", "publish", "--with-tests",
                 "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q3.returncode == 0, f"10q-3 publish failed: {r10q3.returncode}\n{r10q3.stdout}\n{r10q3.stderr}"
pkg10q3 = os.path.join(root, "pkg10q3")
os.makedirs(os.path.join(pkg10q3, "src"), exist_ok=True)
for fn in os.listdir(o10q3):
    if fn.endswith(".pion"): shutil.copyfile(os.path.join(o10q3, fn), os.path.join(pkg10q3, "src", fn))
with open(os.path.join(pkg10q3, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "s10q3"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
r10q3_t = subprocess.run([pionc, "test", pkg10q3], capture_output=True, text=True)
assert r10q3_t.returncode != 0 and "1 passed; 1 failed" in r10q3_t.stdout, f"10q-3 expected 1 passed (n==1) + 1 failed (msg panic), got:\n{r10q3_t.stdout}\n{r10q3_t.stderr}"

# 10q-4 (P0-4): Asset manifest `blob.mbt` MUST NOT match `nested/blob.mbt` by basename!
s10q4 = os.path.join(root, "s10q4")
o10q4 = os.path.join(root, "o10q4")
os.makedirs(os.path.join(s10q4, "nested"), exist_ok=True)
with open(os.path.join(s10q4, "nested", "blob.mbt"), "w") as f:
    f.write("pub let b : Int = 1\n")
b_sha = hashlib.sha256(open(os.path.join(s10q4, "nested", "blob.mbt"), "rb").read()).hexdigest()
mf10q4 = os.path.join(root, "mf10q4.json")
with open(mf10q4, "w") as f:
    json.dump({"assets": [{"path": "blob.mbt", "sha256": b_sha, "allowed_decls": ["b"]}]}, f)
r10q4 = run_cli(["--src", s10q4, "--out", o10q4, "--target", "native", "--mode", "publish",
                 "--asset-manifest", mf10q4, "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q4.returncode != 0, f"10q-4 basename manifest entry must fail for nested/blob.mbt, got rc=0"

# 10q-5 (P0-5): `--closure-report <nonempty_dir>` must fail AND leave `--out` untouched (no `new.pion`)!
s10q5 = os.path.join(root, "s10q5")
o10q5 = os.path.join(root, "o10q5")
cls_dir10q5 = os.path.join(root, "cls_nonempty_dir")
os.makedirs(s10q5, exist_ok=True)
os.makedirs(o10q5, exist_ok=True)
os.makedirs(cls_dir10q5, exist_ok=True)
with open(os.path.join(cls_dir10q5, "keep.txt"), "w") as f:
    f.write("nonempty")
with open(os.path.join(s10q5, "new.mbt"), "w") as f:
    f.write("pub fn hi() -> Int { 1 }\n")
r10q5 = run_cli(["--src", s10q5, "--out", o10q5, "--target", "native", "--mode", "publish",
                 "--closure-report", cls_dir10q5, "--mbt-compat", compat_dir, "--pionc", pionc])
assert r10q5.returncode != 0, f"10q-5 --closure-report <nonempty_dir> must fail, got rc=0"
assert not os.path.exists(os.path.join(o10q5, "new.pion")), f"10q-5 --out was polluted with new.pion!"

print("[e2e] PASS: Astra Final 5 P0 regressions (10q-1..10q-5: no wbtest collision, blackbox isolation, msg= side effects, no basename asset bypass, atomic --closure-report)")

# Wave M2-A Round 2 E2E regressions:
# (1) Item 9: publish --with-tests Check 2 must fail on broken *_test.mbt with MBT2PION_FINAL_CHECK_FAILED!
r2_badtest_src = os.path.join(root, "r2_badtest_src")
r2_badtest_out = os.path.join(root, "r2_badtest_out")
r2_badtest_rep = os.path.join(root, "r2_badtest_rep.json")
os.makedirs(r2_badtest_src, exist_ok=True)
with open(os.path.join(r2_badtest_src, "lib.mbt"), "w") as f:
    f.write("pub fn ok() -> Int { 1 }\n")
with open(os.path.join(r2_badtest_src, "broken_test.mbt"), "w") as f:
    f.write('test "bad" { let x : Int = "not_an_int"; let _ = x }\n')
r2_bt = run_cli(["--src", r2_badtest_src, "--out", r2_badtest_out, "--target", "native", "--mode", "publish", "--with-tests",
                 "--report", r2_badtest_rep, "--mbt-compat", compat_dir, "--pionc", pionc])
assert r2_bt.returncode != 0, f"R2 Check 2: broken *_test.mbt must fail publish --with-tests, got rc=0"
r2_bt_codes = [d["code"] for d in json.load(open(r2_badtest_rep)).get("diagnostics", [])]
assert "MBT2PION_FINAL_CHECK_FAILED" in r2_bt_codes, f"R2 Check 2: expected MBT2PION_FINAL_CHECK_FAILED, got {r2_bt_codes}"

# (2) Item 1: debug_inspect("ab", content="ab") MUST FAIL while debug_inspect("ab", content="\"ab\"") MUST PASS!
r2_di_src = os.path.join(root, "r2_di_src")
r2_di_out = os.path.join(root, "r2_di_out")
os.makedirs(r2_di_src, exist_ok=True)
with open(os.path.join(r2_di_src, "lib.mbt"), "w") as f:
    f.write("pub fn ok() -> Int { 1 }\n")
with open(os.path.join(r2_di_src, "di_wbtest.mbt"), "w") as f:
    f.write(
        'test "di_quoted_pass" {\n'
        '  debug_inspect("ab", content="\\"ab\\"")\n'
        '  debug_inspect([(1, 2), (3, 4)], content="[(1, 2), (3, 4)]")\n'
        '}\n'
        'test "di_unquoted_fail" {\n'
        '  debug_inspect("ab", content="ab")\n'
        '}\n'
    )
r2_di = run_cli(["--src", r2_di_src, "--out", r2_di_out, "--target", "native", "--mode", "publish", "--with-tests",
                 "--mbt-compat", compat_dir, "--pionc", pionc])
assert r2_di.returncode == 0, f"R2 debug_inspect publish failed: {r2_di.returncode}\n{r2_di.stdout}\n{r2_di.stderr}"
pkg_r2_di = os.path.join(root, "pkg_r2_di")
os.makedirs(os.path.join(pkg_r2_di, "src"), exist_ok=True)
for fn in os.listdir(r2_di_out):
    if fn.endswith(".pion"): shutil.copyfile(os.path.join(r2_di_out, fn), os.path.join(pkg_r2_di, "src", fn))
with open(os.path.join(pkg_r2_di, "pion.toml"), "w") as f:
    f.write(f'[package]\nname = "r2_di"\nversion = "0.1.0"\n\n[dependencies]\nmbt_compat = {{ path = "{compat_dir}" }}\n')
r2_di_t = subprocess.run([pionc, "test", pkg_r2_di], capture_output=True, text=True)
assert r2_di_t.returncode != 0 and "1 passed; 1 failed" in r2_di_t.stdout, f"R2 debug_inspect expected 1 passed + 1 failed, got:\n{r2_di_t.stdout}\n{r2_di_t.stderr}"

# (3) Item 1 negative: debug_inspect on unsupported user struct must fail closed with MBT2PION_UNSUPPORTED_SYNTAX!
r2_di_bad_src = os.path.join(root, "r2_di_bad_src")
r2_di_bad_out = os.path.join(root, "r2_di_bad_out")
r2_di_bad_rep = os.path.join(root, "r2_di_bad_rep.json")
os.makedirs(r2_di_bad_src, exist_ok=True)
with open(os.path.join(r2_di_bad_src, "lib.mbt"), "w") as f:
    f.write("pub(all) struct Foo { x : Int }\n")
with open(os.path.join(r2_di_bad_src, "bad_wbtest.mbt"), "w") as f:
    f.write('test "di_struct" { debug_inspect(Foo::{ x: 1 }, content="Foo") }\n')
r2_di_bad = run_cli(["--src", r2_di_bad_src, "--out", r2_di_bad_out, "--target", "native", "--mode", "publish", "--with-tests",
                     "--report", r2_di_bad_rep, "--mbt-compat", compat_dir, "--pionc", pionc])
assert r2_di_bad.returncode != 0, "R2 debug_inspect(Foo) must fail closed"
r2_di_bad_codes = [d["code"] for d in json.load(open(r2_di_bad_rep)).get("diagnostics", [])]
assert "MBT2PION_UNSUPPORTED_SYNTAX" in r2_di_bad_codes, f"R2 debug_inspect(Foo) expected MBT2PION_UNSUPPORTED_SYNTAX, got {r2_di_bad_codes}"

print("[e2e] PASS: Wave M2-A Round 2 regressions (Check 2 test gate, debug_inspect quoted/unquoted/struct fail-closed)")
PY

PIONC="$PIONC" python3 "$(dirname "$0")/test_zero_rc_leak.py"

echo "[e2e] ALL E2E TESTS PASSED!"
