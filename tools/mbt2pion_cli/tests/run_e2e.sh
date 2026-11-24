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

def run_cli(args):
    return subprocess.run([bin_path] + args, capture_output=True, text=True)

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
PY

echo "[e2e] ALL E2E TESTS PASSED!"
