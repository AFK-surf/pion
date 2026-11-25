#!/bin/sh
# P121: Opt-Track T byte-identical cold-compile frontend optimizations
# (Lean: tests/lean/proofs/QbeFrontendColdSpeedOpts.lean; unit tests:
# compiler/src/core/frontend_test.pion `opt_t: ...`).
#   front_slot_seen   hashed `#fmutlink` dedup (`slot_mut_links_seen`, on main
#                     since #56) next to the ordered `slot_mut_links` array;
#   front_plan_once   `cli_prepare_qbe_units` reuses the `ConstInitPlan` the
#                     full type check computed, or its empty plan when the
#                     package has no top-level constant (diagnostics first);
#   front_const_rows  `compute_const_init_plan_from_pkg_tc` replays only the
#                     `#cdep` rows when no constant initializer has a call,
#                     falling back to every summary line otherwise;
#   front_loop_fp     the four `while iter < 64` dependency fixed points carry
#                     the fingerprint along the back edge.
# Verifies (native, every package built twice from cold CAS dirs with
# byte-identical SSA and binaries; with P121_BASELINE_PIONC=<older pionc> the
# SSA must also equal that compiler's, byte for byte):
#   1. High fan-out `mut` callable slots: 16 locals x 3 installers x 4 rounds
#      (192 calls, 144 of them repeating a `#fmutlink` row already seen) plus a
#      callback reading all of them; the unit signature cached by a plain
#      build carries exactly the 48 rows in first-occurrence order.
#   2. Constant initialization: direct reads across files (fast path), a call
#      (fallback), non-ASCII string constants, a call cycle across files and a
#      direct cycle (E_CONST_CYCLE, check + build), a package without constants,
#      a type error next to a constant plan, cycle + type error together, and a
#      cold -> hot CAS rebuild that reuses a cached unit signature twice.
#   3. Loop dependency fixed points: container-rotating loops of all five
#      kinds (`while`, `while ... is`, C-style `for`, range `for`, `for-in`)
#      that need 6 passes, a `while` needing 41 and the 64-pass budget
#      exhausted at n = 63 and n = 70 (fallback; frontend_test.pion checks the
#      plans of the same shapes, including the boundary). Rotating 71 plain
#      callable locals puts more than 64 copies in one QBE parallel move
#      (vendor/qbe/rega.c `pm` used to die with "no more pm slots"; it now
#      grows, output unchanged for <= 64).
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p121_frontend_cold_speed_opts"
PIONC="${1:-$ROOT_DIR/out/pionc2}"
case "$PIONC" in
  /*) ;;
  *) PIONC="$PWD/$PIONC" ;;
esac
BASE="${P121_BASELINE_PIONC:-}"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pion p121 e2e.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

export PION_QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
export PION_RT_LIB="${PION_RT_LIB:-$ROOT_DIR/out/libpionrt.a}"

fail() {
  echo "FAIL: p121 $*" >&2
  exit 1
}

SEQ=0
# build_pkg <name> <files...>: two cold builds with --emit-ssa; SSA and binary
# must be identical (and equal to the baseline compiler's SSA when given). The
# second binary keeps the same file name (in b2/): Mach-O ad-hoc signatures
# embed the output name.
build_pkg() {
  name="$1"
  shift
  SEQ=$((SEQ + 1))
  mkdir -p "$TMP_DIR/b2"
  PION_CACHE_DIR="$TMP_DIR/cas_${name}_1" "$PIONC" build --emit-ssa "$TMP_DIR/$name.1.ssa" -o "$TMP_DIR/$name.bin" "$@" \
    || fail "$name: build failed"
  PION_CACHE_DIR="$TMP_DIR/cas_${name}_2" "$PIONC" build --emit-ssa "$TMP_DIR/$name.2.ssa" -o "$TMP_DIR/b2/$name.bin" "$@" \
    || fail "$name: second build failed"
  cmp -s "$TMP_DIR/$name.1.ssa" "$TMP_DIR/$name.2.ssa" || fail "$name: SSA differs between cold builds"
  cmp -s "$TMP_DIR/$name.bin" "$TMP_DIR/b2/$name.bin" || fail "$name: binary differs between cold builds"
  if [ -n "$BASE" ]; then
    PION_CACHE_DIR="$TMP_DIR/cas_${name}_base" "$BASE" build --emit-ssa "$TMP_DIR/$name.base.ssa" -o "$TMP_DIR/$name.base.bin" "$@" \
      || fail "$name: baseline build failed"
    cmp -s "$TMP_DIR/$name.1.ssa" "$TMP_DIR/$name.base.ssa" || fail "$name: SSA differs from the baseline compiler"
  fi
}

# expect_out <name> <want>
expect_out() {
  got=$("$TMP_DIR/$1.bin") || fail "$1: run failed"
  [ "$got" = "$2" ] || fail "$1: output '$got', want '$2'"
  echo "  $1: '$got' (OK)"
}

# expect_fail <name> <code...>: `check --json` and `build` both reject.
expect_fail() {
  name="$1"
  shift
  set +e
  chk=$("$PIONC" check --json "$TMP_DIR/$name"/*.pion 2>&1)
  chk_rc=$?
  bld=$(PION_CACHE_DIR="$TMP_DIR/cas_$name" "$PIONC" build -o "$TMP_DIR/$name.bin" "$TMP_DIR/$name"/*.pion 2>&1)
  bld_rc=$?
  set -e
  [ "$chk_rc" -ne 0 ] || fail "$name: check accepted"
  [ "$bld_rc" -ne 0 ] || fail "$name: build accepted"
  [ ! -e "$TMP_DIR/$name.bin" ] || fail "$name: build wrote a binary"
  for code in "$@"; do
    printf '%s' "$chk" | grep -q "$code" || fail "$name: check lacks $code: $chk"
    printf '%s' "$bld" | grep -q "$code" || fail "$name: build lacks $code: $bld"
  done
  echo "  $name: rejected with $* (check rc=$chk_rc, build rc=$bld_rc) (OK)"
}

echo "=== P121 [1/3]: high fan-out mut callable slots (front_slot_seen) ==="
python3 -E "$DIR/gen_fanout.py" fanout "$TMP_DIR/fan"
NCALL=$(grep -c '^  install_[0-9]*(mut f' "$TMP_DIR/fan/b.pion")
NROW=$(wc -l < "$TMP_DIR/fan/links.txt" | tr -d ' ')
[ "$NCALL" -eq 192 ] && [ "$NROW" -eq 48 ] || fail "fan-out generator: $NCALL calls / $NROW distinct rows, want 192 / 48"
build_pkg fan "$TMP_DIR/fan/a.pion" "$TMP_DIR/fan/b.pion"
expect_out fan "$(cat "$TMP_DIR/fan/expect.txt")"
# A plain build caches each unit's signature (usig/*.sig); b.pion's must carry
# every distinct link exactly once, in first-occurrence order.
PION_CACHE_DIR="$TMP_DIR/cas_fan_sig" "$PIONC" build -o "$TMP_DIR/fan_sig.bin" "$TMP_DIR/fan/a.pion" "$TMP_DIR/fan/b.pion" \
  || fail "fan: plain build failed"
expect_out fan_sig "$(cat "$TMP_DIR/fan/expect.txt")"
find "$TMP_DIR/cas_fan_sig/usig" -type f -name '*.sig' -exec grep -h '^#fmutlink ' {} + > "$TMP_DIR/fan/rows.txt" || true
cmp -s "$TMP_DIR/fan/rows.txt" "$TMP_DIR/fan/links.txt" \
  || { diff "$TMP_DIR/fan/links.txt" "$TMP_DIR/fan/rows.txt" | head -20 >&2; fail "fan: cached #fmutlink rows differ from the first-occurrence list"; }
echo "  fan: 192 installer calls -> 48 #fmutlink rows, first-occurrence order (OK)"

echo "=== P121 [2/3]: constant initialization plans (front_const_rows, front_plan_once) ==="
mkdir -p "$TMP_DIR/direct"
cat > "$TMP_DIR/direct/a.pion" <<'EOF'
let A : Int = B + C * 2
let D : String = S + "!" + T
pub fn main(world : World) -> Unit { io_println(world, A.to_string() + ":" + D) }
EOF
cat > "$TMP_DIR/direct/b.pion" <<'EOF'
let B : Int = 7
let C : Int = B + 1
let S : String = "h\u{e9}llo-\u{4e2d}"
let T : String = "\u{fc}"
EOF
build_pkg direct "$TMP_DIR/direct/a.pion" "$TMP_DIR/direct/b.pion"
expect_out direct "23:héllo-中!ü"

mkdir -p "$TMP_DIR/call"
cat > "$TMP_DIR/call/a.pion" <<'EOF'
let A : Int = f() + E
let E : Int = 1
pub fn main(world : World) -> Unit { io_println(world, A.to_string()) }
EOF
cat > "$TMP_DIR/call/b.pion" <<'EOF'
fn f() -> Int { B * 2 }
let B : Int = make()
fn make() -> Int { 20 }
EOF
build_pkg call "$TMP_DIR/call/a.pion" "$TMP_DIR/call/b.pion"
expect_out call "41"
# Cold -> hot CAS. `--emit-ssa` builds keep no per-unit signatures, so first a
# plain cold build fills a fresh cache (usig/*.sig + *.stub for both units),
# then b.pion changes twice and each rebuild reuses a.pion's cached unit.
CAS_HOT="$TMP_DIR/cas_call_hot"
usig_count() { find "$CAS_HOT/usig" -type f -name "*.$1" -size +0 2>/dev/null | wc -l | tr -d ' '; }
PION_CACHE_DIR="$CAS_HOT" "$PIONC" build -o "$TMP_DIR/call_cold.bin" "$TMP_DIR/call/a.pion" "$TMP_DIR/call/b.pion" \
  || fail "call: plain cold build failed"
expect_out call_cold "41"
[ "$(usig_count sig)" -eq 2 ] && [ "$(usig_count stub)" -eq 2 ] \
  || fail "call: cold build cached $(usig_count sig) .sig / $(usig_count stub) .stub units, want 2 / 2"
sed 's/{ 20 }/{ 30 }/' "$TMP_DIR/call/b.pion" > "$TMP_DIR/call/b.new" && mv "$TMP_DIR/call/b.new" "$TMP_DIR/call/b.pion"
PION_CACHE_DIR="$CAS_HOT" "$PIONC" build -o "$TMP_DIR/call_hot.bin" "$TMP_DIR/call/a.pion" "$TMP_DIR/call/b.pion" \
  || fail "call: hot build failed"
expect_out call_hot "61"
[ "$(usig_count sig)" -eq 3 ] || fail "call: hot build should add exactly one unit signature (b.pion), cache has $(usig_count sig)"
sed 's/{ 30 }/{ 40 }/' "$TMP_DIR/call/b.pion" > "$TMP_DIR/call/b.new" && mv "$TMP_DIR/call/b.new" "$TMP_DIR/call/b.pion"
PION_CACHE_DIR="$CAS_HOT" "$PIONC" build -o "$TMP_DIR/call_hot2.bin" "$TMP_DIR/call/a.pion" "$TMP_DIR/call/b.pion" \
  || fail "call: second hot build failed"
expect_out call_hot2 "81"
[ "$(usig_count sig)" -eq 4 ] || fail "call: second hot build should add exactly one unit signature, cache has $(usig_count sig)"

mkdir -p "$TMP_DIR/none"
cat > "$TMP_DIR/none/main.pion" <<'EOF'
fn helper(x : Int) -> Int { x * 3 }
pub fn main(world : World) -> Unit { io_println(world, "none:" + helper(4).to_string()) }
EOF
build_pkg none "$TMP_DIR/none/main.pion"
expect_out none "none:12"

mkdir -p "$TMP_DIR/cyc_direct" "$TMP_DIR/cyc_call" "$TMP_DIR/type_err" "$TMP_DIR/cyc_type"
cat > "$TMP_DIR/cyc_direct/main.pion" <<'EOF'
let A : Int = B + 1
let B : Int = C + 1
let C : Int = A + 1
pub fn main() -> Int { 0 }
EOF
cat > "$TMP_DIR/cyc_call/a.pion" <<'EOF'
let A : Int = g()
pub fn main() -> Int { 0 }
EOF
cat > "$TMP_DIR/cyc_call/b.pion" <<'EOF'
fn g() -> Int { B }
let B : Int = A + 1
EOF
cat > "$TMP_DIR/type_err/main.pion" <<'EOF'
let A : Int = B
let B : Int = "x"
pub fn main() -> Int { A }
EOF
cat > "$TMP_DIR/cyc_type/main.pion" <<'EOF'
let A : Int = B
let B : Int = A
let C : Int = "x"
pub fn main() -> Int { 0 }
EOF
expect_fail cyc_direct E_CONST_CYCLE
expect_fail cyc_call E_CONST_CYCLE
expect_fail type_err E_TYPE_MISMATCH
expect_fail cyc_type E_CONST_CYCLE E_TYPE_MISMATCH

echo "=== P121 [3/3]: loop dependency fixed points (front_loop_fp) ==="
mkdir -p "$TMP_DIR/loops"
cat > "$TMP_DIR/loops/a.pion" <<'EOF'
let W : Int = go_while()
let L : Int = go_while_is()
let F : Int = go_cfor()
let R : Int = go_range()
let I : Int = go_for_in()
pub fn main(world : World) -> Unit {
  io_println(world, W.to_string() + "," + L.to_string() + "," + F.to_string() + "," + R.to_string() + "," + I.to_string())
}
EOF
cat > "$TMP_DIR/loops/b.pion" <<'EOF'
fn zero() -> Int { 0 }
fn read_b() -> Int { B }
fn make_b() -> Int { 9 }
fn go_while() -> Int {
  let mut f = zero
  let mut g = zero
  let mut h = zero
  let mut k = zero
  let mut i = 0
  while i < 4 { k = h; h = g; g = f; f = read_b; i = i + 1 }
  k()
}
fn go_while_is() -> Int {
  let mut f = zero
  let mut g = zero
  let mut h = zero
  let mut k = zero
  let mut it : Option[Int] = Some(4)
  while it is Some(n) {
    k = h
    h = g
    g = f
    f = read_b
    it = if n > 1 { Some(n - 1) } else { None }
  }
  k() + 1
}
fn go_cfor() -> Int {
  let mut f = zero
  let mut g = zero
  let mut h = zero
  let mut k = zero
  for i = 0; i < 4; i = i + 1 { k = h; h = g; g = f; f = read_b }
  k() + 2
}
fn go_range() -> Int {
  let mut f = zero
  let mut g = zero
  let mut h = zero
  let mut k = zero
  let mut acc = 0
  for i in 0..<4 { k = h; h = g; g = f; f = read_b; acc = acc + i }
  k() + acc
}
fn go_for_in() -> Int {
  let mut f = zero
  let mut g = zero
  let mut h = zero
  let mut k = zero
  let mut acc = 0
  for x in [1, 2, 3, 4] { k = h; h = g; g = f; f = read_b; acc = acc + x }
  k() + acc
}
let B : Int = make_b()
EOF
build_pkg loops "$TMP_DIR/loops/a.pion" "$TMP_DIR/loops/b.pion"
expect_out loops "9,10,11,15,19"

for kind in while while_is cfor range for_in; do
  python3 -E "$DIR/gen_fanout.py" cslots "$TMP_DIR/cs_${kind}5" "$kind" 5
  build_pkg "cs_${kind}5" "$TMP_DIR/cs_${kind}5/a.pion" "$TMP_DIR/cs_${kind}5/b.pion"
  expect_out "cs_${kind}5" "$(cat "$TMP_DIR/cs_${kind}5/expect.txt")"
done
for n in 40 63 70; do
  python3 -E "$DIR/gen_fanout.py" cslots "$TMP_DIR/cs_while$n" while "$n"
  build_pkg "cs_while$n" "$TMP_DIR/cs_while$n/a.pion" "$TMP_DIR/cs_while$n/b.pion"
  expect_out "cs_while$n" "$(cat "$TMP_DIR/cs_while$n/expect.txt")"
done
python3 -E "$DIR/gen_fanout.py" rotate "$TMP_DIR/rot70" 70
build_pkg rot70 "$TMP_DIR/rot70/a.pion" "$TMP_DIR/rot70/b.pion"
expect_out rot70 "$(cat "$TMP_DIR/rot70/expect.txt")"

if [ -n "$BASE" ]; then
  echo "  $SEQ packages: SSA identical to the baseline compiler ($BASE)"
fi
echo "PASS: p121_frontend_cold_speed_opts ($SEQ packages, cold SSA + binary parity)"
