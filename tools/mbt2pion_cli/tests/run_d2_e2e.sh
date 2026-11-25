#!/bin/sh
# Wave M2-D2 E2E negative & fail-closed verification gate:
# 1. Trait object type ascription `(x : &Show)` -> MBT2PION_UNSUPPORTED_SYNTAX (fail-closed)
# 2. Non-literal `const` used as a pattern -> MBT2PION_UNSUPPORTED_SYNTAX (fail-closed)
# 3. `pub using @dep { type Box }` -> records gap in `--mode audit` and fails closed in `--mode publish`
# 4. Ambiguous bare labeled enum variant -> MBT2PION_ENUM_LABEL_ERROR (fail-closed)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PIONC="${1:-${PIONC:-$HOME/.pion/bin/pionc}}"
if [ ! -x "$PIONC" ]; then
  PIONC="$(command -v pionc)"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mbt2pion-d2-e2e.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/mbt2pion"
"$PIONC" build "$REPO_ROOT/tools/mbt2pion_cli" -o "$BIN"
COMPAT_DIR="$REPO_ROOT/tools/mbt_compat"

NEG_OUT="$WORK/neg_out"
mkdir -p "$NEG_OUT"
echo "SENTINEL" > "$NEG_OUT/sentinel.pion"

# 1. Trait object ascription `(x : &Show)` fails closed
S1="$WORK/s1"; mkdir -p "$S1"
cat > "$S1/t.mbt" << 'EOF'
pub fn f(x : Int) -> Unit {
  let _ = (x : &Show)
}
EOF
if "$BIN" --src "$S1" --out "$NEG_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --report "$WORK/r1.json" --pionc "$PIONC" 2>/dev/null; then
  echo "[d2-e2e] FAIL: (x : &Show) should have exited non-zero"
  exit 1
fi
grep -q "MBT2PION_UNSUPPORTED_SYNTAX" "$WORK/r1.json"
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"

# 2. Non-literal const in pattern fails closed
S2="$WORK/s2"; mkdir -p "$S2"
cat > "$S2/t.mbt" << 'EOF'
const BAD : Int = 1 + 2
pub fn f(v : Int) -> Int {
  match v {
    BAD => 1
    _ => 0
  }
}
EOF
if "$BIN" --src "$S2" --out "$NEG_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --report "$WORK/r2.json" --pionc "$PIONC" 2>/dev/null; then
  echo "[d2-e2e] FAIL: non-literal const in pattern should have exited non-zero"
  exit 1
fi
grep -q "MBT2PION_UNSUPPORTED_SYNTAX" "$WORK/r2.json"
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"

# 3. `pub using @dep { type Box }` records gap in audit and fails closed in publish
S3="$WORK/s3"; OUT3="$WORK/out3"; mkdir -p "$S3" "$OUT3"
cat > "$S3/t.mbt" << 'EOF'
pub using @dep { type Box }
pub fn id_box(b : Box) -> Box { b }
EOF
"$BIN" --src "$S3" --out "$OUT3" --target native --mode audit --no-probes --report "$WORK/r3_audit.json" --pionc "$PIONC" || true
grep -q "MBT2PION_UNSUPPORTED_SYNTAX" "$WORK/r3_audit.json"
grep -q "dep::Box" "$OUT3/t.pion"
if "$BIN" --src "$S3" --out "$NEG_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --report "$WORK/r3_pub.json" --pionc "$PIONC" 2>/dev/null; then
  echo "[d2-e2e] FAIL: pub using should have failed closed in --mode publish"
  exit 1
fi
grep -q "MBT2PION_UNSUPPORTED_SYNTAX" "$WORK/r3_pub.json"
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"

# 4. Ambiguous bare labeled enum fails closed with MBT2PION_ENUM_LABEL_ERROR
S4="$WORK/s4"; mkdir -p "$S4"
cat > "$S4/t.mbt" << 'EOF'
pub(all) enum A { Dup(x~ : Int) }
pub(all) enum B { Dup(x~ : Int) }
pub fn f() -> Unit {
  let _ = Dup(x=1)
}
EOF
if "$BIN" --src "$S4" --out "$NEG_OUT" --target native --mode publish --mbt-compat "$COMPAT_DIR" --report "$WORK/r4.json" --pionc "$PIONC" 2>/dev/null; then
  echo "[d2-e2e] FAIL: ambiguous labeled enum should have exited non-zero"
  exit 1
fi
grep -q "MBT2PION_ENUM_LABEL_ERROR" "$WORK/r4.json"
test "$(cat "$NEG_OUT/sentinel.pion")" = "SENTINEL"

echo "[d2-e2e] PASS: all Wave M2-D2 negative/fail-closed gates verified"
