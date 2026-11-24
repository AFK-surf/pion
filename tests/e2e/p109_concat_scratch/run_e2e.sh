#!/bin/sh
# P109: native integer `.to_string()` parts of 3..8 part `pion_str_concat_n`
# chains are formatted into caller stack slots (`$pion_strbuf_push_int`)
# instead of heap temporaries (`$pion_int_to_str`).
# Verifies:
# 1. SSA (dev & --release): every 3..8 part Int / Int64 hot function calls
#    `$pion_strbuf_push_int` and never `$pion_int_to_str` / `$pion_i64_to_str`;
#    the 9 part chain, the trait-dispatched `Render::to_string`, unsigned
#    receivers (`(x as UInt64) >> 1`, `UInt` / `UInt64` extremes) and the
#    Wasm32 module keep the heap path.
# 2. Exact output across Native dev & --release, Wasm32 dev & --release and
#    ASan/LSan dev & --release (0..8 parts, INT32/INT64 extremes, repeated
#    receivers, loop slot reuse, side-effect order, `?` exits, custom types).
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p109_concat_scratch"
SRC="$DIR/p109.pion"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

check() {
  if ! diff -u "$DIR/expected.txt" "$2"; then
    echo "FAIL: p109 $1" >&2
    exit 1
  fi
  echo "p109 $1 ok"
}

# 1. SSA shape + native dev / --release output
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG --emit-ssa "$TMP_DIR/$MODE.ssa" -o "$TMP_DIR/p109_$MODE" "$SRC"
  python3 - "$TMP_DIR/$MODE.ssa" "$MODE" <<'PYEOF'
import re, sys
ir, mode = open(sys.argv[1]).read(), sys.argv[2]
funcs = {
    m.group(1): m.group(0)
    for m in re.finditer(r'^(?:export )?function [^\n]*\$pion_fn_(\w+)\([^\n]*\{.*?^\}', ir, re.M | re.S)
}
def body(name):
    assert name in funcs, f"{mode}: $pion_fn_{name} missing (got {sorted(funcs)})"
    return funcs[name]
heap = ('$pion_int_to_str', '$pion_i64_to_str')
want = {'hot3': 2, 'hot4': 2, 'hot5': 3, 'hot6': 3, 'hot7': 5, 'hot8': 4,
        'same_recv': 4, 'method_recv': 3, 'ordered': 3, 'try_join': 2}
for name, n in want.items():
    b = body(name)
    got = b.count('call $pion_strbuf_push_int(')
    assert got == n, f"{mode}: {name} has {got} stack-formatted parts, want {n}"
    for h in heap:
        assert h not in b, f"{mode}: {name} still calls {h}"
    assert b.count('call $pion_str_concat_n(') == 1, f"{mode}: {name} is not one concat_n chain"
# Fallbacks: > 8 parts and trait dispatch keep the original lowering.
w9 = body('wide9')
assert '$pion_strbuf_push_int' not in w9 and w9.count('call $pion_int_to_str(') == 5, f"{mode}: wide9 must use heap temporaries"
assert '$pion_strbuf_push_int' not in body('wrap__mono_Int'), f"{mode}: trait-dispatched to_string was rewritten"
# Unsigned receivers (shifts with an `Int` count, `as` casts) keep their own
# lowering: never `extsw`-truncated into the signed stack formatter.
for name in ('shr_u64', 'unsigned_parts', 'effect_u64', 'closure_u64'):
    assert '$pion_strbuf_push_int' not in body(name), f"{mode}: unsigned receiver in {name} was stack-formatted"
assert 'u64s_big' in body('shr_u64'), f"{mode}: shr_u64 lost the UInt64 to_string lowering"
print(f"p109 {mode} SSA ok ({len(want)} stack-formatted chains, 6 fallbacks)")
PYEOF
  "$TMP_DIR/p109_$MODE" > "$TMP_DIR/$MODE.out"
  check "native $MODE" "$TMP_DIR/$MODE.out"
done

# 2. Wasm32 dev & --release (heap path)
if command -v node >/dev/null 2>&1; then
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    "$PIONC" build $FLAG --target wasm32 --emit-ssa "$TMP_DIR/w$MODE.ssa" -o "$TMP_DIR/$MODE.wasm" "$SRC"
    if grep -q 'pion_strbuf_push_int' "$TMP_DIR/w$MODE.ssa"; then
      echo "FAIL: p109 wasm32 $MODE uses the native stack scratch" >&2
      exit 1
    fi
    node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/$MODE.wasm" > "$TMP_DIR/w$MODE.out"
    check "wasm32 $MODE" "$TMP_DIR/w$MODE.out"
  done
else
  echo "NOTE: node unavailable; skipping p109 Wasm32 checks"
fi

# 3. ASan/LSan (dev & --release)
CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/p109.o" "$SRC"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/p109.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p109_asan"
    "$TMP_DIR/p109_asan" > "$TMP_DIR/asan.out"
    check "ASan/LSan ${MODE:-dev}" "$TMP_DIR/asan.out"
  done
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p109 ASan check"
fi

echo "PASS: p109_concat_scratch"
