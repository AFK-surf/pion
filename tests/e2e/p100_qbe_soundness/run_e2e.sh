#!/bin/sh
# P100: QBE soundness regressions found by the Lean-model review of vendor/qbe
# (tests/tv/qbe_bugs B7-B13):
#   QBE-1 copy.c dwl: a phi refuted in one arm of an `and` (or proved only by
#         a refuted cycle assumption) must not count as narrow in the other
#         arm, or `& 65535` is dropped;
#   QBE-2 gvn.c usecls: `jnz` tests 32 bits, a 64-bit `ret` of the tested temp
#         on the zero edge is not 0;
#   QBE-3 load.c loadopt: forwarding a narrow store to a load at a higher
#         offset masks the bits shifted down from above the stored bytes;
#   QBE-4 mem.c promote: an l-class loadsw/loaduw of a promoted 4-byte slot
#         extends 32 -> 64 bits;
#   QBE-5 copy.c copyref: `=l cnew %w, 0` is not replaced by the w temp,
#         nor (phicopyref, B13) an l 0/1 phi by the w jnz argument.
# 1. the 10-line pure-Pion QBE-1 reproducer: dev, --release and Wasm32 print
#    the masked value 22136 (0x5678), not 305419896 (0x12345678);
# 2. tests/tv/qbe_bugs through the host's text assembly and --obj with exact
#    results, arm64_apple / amd64_sysv text + --obj all emitted, and the
#    `qbe -d MG` trace of B7-B9, B11a/b, B12, B13 (w) validated by qbe-tv --strict.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
BUGS="$ROOT_DIR/tests/tv/qbe_bugs"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"

# 1. QBE-1 from pure Pion: `p & (p | 1)` of a phi, then `& 65535`.
cat <<'PION' > "$TMP_DIR/mask.pion"
fn mask16(c : Bool, x : Int, y : Int) -> Int {
  let p = if c { x } else { y }
  (p & (p | 1)) & 65535
}

fn main(world : World) -> Unit {
  let xs = [0x12345678, 3]
  io_println(world, mask16(true, 0x12345678, 3).to_string())
  io_println(world, mask16(xs.length() == 2, xs[0], xs[1]).to_string())
}
PION
WANT="22136
22136"
"$PIONC" build -o "$TMP_DIR/mask_dev" "$TMP_DIR/mask.pion"
"$PIONC" build --release -o "$TMP_DIR/mask_rel" "$TMP_DIR/mask.pion"
"$PIONC" build --target wasm32 -o "$TMP_DIR/mask.wasm" "$TMP_DIR/mask.pion"
for run in "dev:$TMP_DIR/mask_dev" "release:$TMP_DIR/mask_rel" "wasm32:node $WASM_RT $TMP_DIR/mask.wasm"; do
  label=${run%%:*}
  OUT=$(${run#*:})
  if [ "$OUT" != "$WANT" ]; then
    echo "FAIL: p100 QBE-1 Pion $label printed '$OUT', want 22136 twice" >&2
    exit 1
  fi
  echo "p100 QBE-1 Pion $label -> $(printf '%s' "$OUT" | tr '\n' ' ')"
done

# 2. SSA reproducers + C driver: host text asm and --obj run with exact results.
"$QBE" -o "$TMP_DIR/bugs.s" "$BUGS/qbe_bugs.ssa"
cc "$TMP_DIR/bugs.s" "$BUGS/driver.c" -o "$TMP_DIR/bugs_asm"
"$TMP_DIR/bugs_asm"
case "$(uname -s):$(uname -m)" in
  Darwin:arm64|Linux:x86_64|Linux:amd64)
    "$QBE" --obj -o "$TMP_DIR/bugs.o" "$BUGS/qbe_bugs.ssa"
    cc "$TMP_DIR/bugs.o" "$BUGS/driver.c" -o "$TMP_DIR/bugs_obj"
    "$TMP_DIR/bugs_obj"
    ;;
esac
for t in amd64_sysv arm64_apple; do
  "$QBE" -t "$t" -o "$TMP_DIR/bugs_$t.s" "$BUGS/qbe_bugs.ssa"
  "$QBE" -t "$t" --obj -o "$TMP_DIR/bugs_$t.o" "$BUGS/qbe_bugs.ssa"
  test -s "$TMP_DIR/bugs_$t.s"
  test -s "$TMP_DIR/bugs_$t.o"
done
# QBE-3: after load elimination the forwarded halfword keeps its `and 255`.
"$QBE" -d MG -o /dev/null "$BUGS/qbe_bugs.ssa" 2> "$TMP_DIR/bugs.mg"
awk '/^\*\*\*\* Function bug10_load_shr_mask /{f=1} f&&/^> After load elimination:/{l=1} l&&/^}/{exit} l{print}' \
  "$TMP_DIR/bugs.mg" > "$TMP_DIR/bug10.le"
if ! grep -q '=w and %ld\.[0-9]*, 255$' "$TMP_DIR/bug10.le"; then
  cat "$TMP_DIR/bug10.le" >&2
  echo "FAIL: p100 QBE-3 load forwarding lost its mask" >&2
  exit 1
fi

# B13: the l 0/1 phi stays, the w one still folds into the jnz argument.
gvn_of() {
  awk -v fn="$1" '$0 == "**** Function " fn " ****" {f=1} f&&/^> After GVN:/{l=1} l&&/^}/{exit} l{print}' "$TMP_DIR/bugs.mg"
}
if ! gvn_of bug13_phi_width_l | grep -q '=l phi '; then
  gvn_of bug13_phi_width_l >&2
  echo "FAIL: p100 B13 l phi was replaced" >&2
  exit 1
fi
if gvn_of bug13_phi_width_w | grep -q ' phi '; then
  gvn_of bug13_phi_width_w >&2
  echo "FAIL: p100 B13 w phi no longer folds" >&2
  exit 1
fi

# 3. qbe-tv on the real optimiser's trace (bug13_phi_width_l: see test-tv.sh,
#    its unchanged l phi is checked in step 2).
"$PIONC" build -o "$TMP_DIR/qbe-tv" "$ROOT_DIR/tools/qbe_tv_cli"
set +e
TV=$("$TMP_DIR/qbe-tv" --trace "$TMP_DIR/bugs.mg" --strict)
set -e
for f in bug7_dwl_phi_retry bug7b_dwl_nested_cycle bug8_dwl_phi_cycle bug9_gvn_jnz_retl \
         bug11a_promote_loadsw bug11b_promote_loaduw bug12_cnew_l_result \
         bug13_phi_width_w; do
  if ! printf '%s\n' "$TV" | grep -qx "VALIDATED $f"; then
    printf '%s\n' "$TV" >&2
    echo "FAIL: p100 qbe-tv did not validate $f" >&2
    exit 1
  fi
done

echo "PASS: p100_qbe_soundness (Pion dev/release/wasm32 + SSA asm/--obj x2 targets + qbe-tv)"
