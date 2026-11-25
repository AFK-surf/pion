#!/bin/sh
# Wave M2-E1 E2E negative & fail-closed verification gate:
# 1. Astra P0-3: Box::to_array(_) -> String { "😀" } matched against [_, _] / [_] -> MBT2PION_UNSUPPORTED_SYNTAX
# 2. Ambiguous match with insufficient candidates -> MBT2PION_AMBIGUOUS_CTOR
# 3. Double rest pattern [.., _, ..] -> MBT2PION_UNSUPPORTED_SYNTAX
# 4. Non-local mutable array `.. as mid` -> MBT2PION_BORROWED_ARRAY_SLICE
# 5. Slice `.iter()` -> MBT2PION_BORROWED_ARRAY_SLICE
# 6. Slice `.each(...)` -> MBT2PION_BORROWED_ARRAY_SLICE
# 7. Slice `.join({ ... })` impure separator -> MBT2PION_BORROWED_ARRAY_SLICE
# 8. Slice `\{h.custom_show_arr[0:2]}` custom Show -> MBT2PION_BORROWED_ARRAY_SLICE
# 9. Escaping slices `let v = h.arr[0:2]`, `pass_view(h.arr[0:2])`, `h.arr[0:2][0] = 9` -> MBT2PION_BORROWED_ARRAY_SLICE
# 10. User ident `mbt_match_scrut_probe_count` allowed; genuine `.mbt_match_scrut_probe__p0()` rejected

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PIONC="${1:-${PIONC:-$HOME/.pion/bin/pionc}}"
if [ ! -x "$PIONC" ]; then
  PIONC="$(command -v pionc)"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mbt2pion-e1-e2e.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/mbt2pion"
"$PIONC" build "$REPO_ROOT/tools/mbt2pion_cli" -o "$BIN"
COMPAT_DIR="$REPO_ROOT/tools/mbt_compat"

NEG_OUT="$WORK/neg_out"
mkdir -p "$NEG_OUT"
echo "SENTINEL" > "$NEG_OUT/sentinel.pion"

check_fail() {
  case_id="$1"
  expected_code="$2"
  src_dir="$WORK/$case_id"
  rep="$WORK/r_$case_id.json"
  if "$BIN" --src "$src_dir" --out "$NEG_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --report "$rep" --pionc "$PIONC" 2>/dev/null; then
    echo "[e1-e2e] FAIL ($case_id): expected non-zero exit"
    exit 1
  fi
  if ! grep -q "$expected_code" "$rep"; then
    echo "[e1-e2e] FAIL ($case_id): expected $expected_code in $rep"
    cat "$rep"
    exit 1
  fi
  test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"
}

# 1. Astra P0-3: Box::to_array -> String matched as array pattern must fail closed
mkdir -p "$WORK/s1"
cat > "$WORK/s1/t.mbt" << 'EOF'
pub struct Box { v : Int }
pub fn Box::to_array(self : Box) -> String { let _ = self; "😀" }
pub fn f(b : Box) -> Int {
  match b.to_array() {
    [_, _] => 2
    [_] => 1
    _ => 0
  }
}
EOF
check_fail s1 MBT2PION_UNSUPPORTED_SYNTAX

# 2. Ambiguous match with unresolvable/incomplete candidate set fails closed
mkdir -p "$WORK/s2"
cat > "$WORK/s2/t.mbt" << 'EOF'
pub(all) enum A { X(Int) }
pub(all) enum B { X(Int); Y(Int) }
pub fn f(v : Int) -> Int {
  match v {
    X(n) => n
    _ => 0
  }
}
EOF
check_fail s2 MBT2PION_AMBIGUOUS_CTOR

# 3. Double rest pattern fails closed
mkdir -p "$WORK/s3"
cat > "$WORK/s3/t.mbt" << 'EOF'
pub fn f(xs : Array[Int]) -> Int {
  match xs {
    [.., _, ..] => 1
    _ => 0
  }
}
EOF
check_fail s3 MBT2PION_UNSUPPORTED_SYNTAX

# 4. Non-local mutable array `.. as mid` fails closed with MBT2PION_BORROWED_ARRAY_SLICE
mkdir -p "$WORK/s4"
cat > "$WORK/s4/t.mbt" << 'EOF'
pub fn f(xs : Array[Int]) -> Int {
  match xs {
    [_, .. as mid, _] => mid[0]
    _ => -1
  }
}
EOF
check_fail s4 MBT2PION_BORROWED_ARRAY_SLICE

# 5. Escaping slice `.iter()` fails closed
mkdir -p "$WORK/s5"
cat > "$WORK/s5/t.mbt" << 'EOF'
pub struct H { arr : Array[Int] }
pub fn f(h : H) -> Int { let it = h.arr[0:2].iter(); it.count() }
EOF
check_fail s5 MBT2PION_BORROWED_ARRAY_SLICE

# 6. Slice `.each(...)` fails closed
mkdir -p "$WORK/s6"
cat > "$WORK/s6/t.mbt" << 'EOF'
pub struct H { arr : Array[Int] }
pub fn f(h : H) -> Unit { h.arr[0:3].each(fn(x) { h.arr[2] = x }) }
EOF
check_fail s6 MBT2PION_BORROWED_ARRAY_SLICE

# 7. Slice `.join({ ... })` impure separator fails closed
mkdir -p "$WORK/s7"
cat > "$WORK/s7/t.mbt" << 'EOF'
pub struct H { strs : Array[String] }
pub fn f(h : H) -> String { h.strs[:].join({ h.strs[1] = "z"; "-" }) }
EOF
check_fail s7 MBT2PION_BORROWED_ARRAY_SLICE

# 8. Custom Show element slice interpolation fails closed
mkdir -p "$WORK/s8"
cat > "$WORK/s8/t.mbt" << 'EOF'
pub struct CustomShow { v : Int }
impl Show for CustomShow with output(self, logger) { logger.write_string(self.v.to_string()) }
pub struct H { xs : Array[CustomShow] }
pub fn f(h : H) -> String { "\{h.xs[0:2]}" }
EOF
check_fail s8 MBT2PION_BORROWED_ARRAY_SLICE

# 9a/9b/9c. Escaping slices fail closed
mkdir -p "$WORK/s9a" "$WORK/s9b" "$WORK/s9c"
cat > "$WORK/s9a/t.mbt" << 'EOF'
pub struct H { arr : Array[Int] }
pub fn f(h : H) -> Int { let v = h.arr[0:2]; v[0] }
EOF
check_fail s9a MBT2PION_BORROWED_ARRAY_SLICE

cat > "$WORK/s9b/t.mbt" << 'EOF'
pub struct H { arr : Array[Int] }
fn pass_view(v : ArrayView[Int]) -> Int { v.length() }
pub fn f(h : H) -> Int { pass_view(h.arr[0:2]) }
EOF
check_fail s9b MBT2PION_BORROWED_ARRAY_SLICE

cat > "$WORK/s9c/t.mbt" << 'EOF'
pub struct H { arr : Array[Int] }
pub fn f(h : H) -> Unit { h.arr[0:2][0] = 9 }
EOF
check_fail s9c MBT2PION_BORROWED_ARRAY_SLICE

# 10. User ident `mbt_match_scrut_probe_count` allowed; genuine `.mbt_match_scrut_probe__p0()` rejected
mkdir -p "$WORK/s10a" "$WORK/out10a" "$WORK/s10b"
cat > "$WORK/s10a/t.mbt" << 'EOF'
fn mbt_match_scrut_probe_count() -> Int { 7 }
pub fn sample() -> Int { mbt_match_scrut_probe_count() }
EOF
"$BIN" --src "$WORK/s10a" --out "$WORK/out10a" --target native --mode publish --mbt-compat "$COMPAT_DIR" --report "$WORK/r10a.json" --pionc "$PIONC"
if grep -q "MBT2PION_PROBE_RESIDUAL" "$WORK/r10a.json"; then
  echo "[e1-e2e] FAIL (s10a): user ident triggered MBT2PION_PROBE_RESIDUAL"
  exit 1
fi

cat > "$WORK/s10b/t.mbt" << 'EOF'
pub fn f(x : Int) -> Int { (x).mbt_match_scrut_probe__p0() }
EOF
check_fail s10b MBT2PION_PROBE_RESIDUAL

echo "[e1-e2e] PASS: all Wave M2-E1 negative/fail-closed gates verified"
