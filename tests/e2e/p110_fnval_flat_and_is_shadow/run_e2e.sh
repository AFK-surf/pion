#!/bin/sh
# P110: generic fns / static methods as first-class values + `is` binding
# shadowing in the codegen type probe.
# Verifies:
# 1. SSA (dev & --release): a generic fn value whose instance needs
#    monomorphization (`Array[Pair[Int, String]]` flat layout, `==`) is wrapped
#    around its `__mono_*` instance; a polymorphic one passes its trailing
#    `%tp_*` flags, loaded from the closure env inside a polymorphic generic.
# 2. Exact output across Native dev & --release, Wasm32 dev & --release and
#    ASan/LSan dev & --release (0 leaks): fn values passed to higher-order
#    generics (before / after the argument fixing the type param), bound to a
#    concretely typed local, through nested generics, as static method values,
#    `Float` / `UInt` / `Double` thunk ABIs, user fns named like thunk suffixes;
#    `if` / `else if` / `&&` / `guard` `is Some(x)` over an outer `x : Int`.
# 3. The same across packages: `d::second_of`, `d::Tool::pick`, a dep's
#    private generic and plain fn values inside its generic instantiated here.
# 4. Rejected: generic fn values violating a trait bound (also of one type
#    param while another stays open) or `==` rule, or conflicting with the
#    call's final instantiation (`consume(id, 1, true)`, also as `{ id }`,
#    `if` / `match` branches, `[id]`, `Some(id)`, `(id, id)`, struct fields,
#    enum payloads, or relayed as `pass(id)` / `keep(Holder::{ f: id })`);
#    arguments stay checked in source order (`move` after the value).
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p110_fnval_flat_and_is_shadow"
SRC="$DIR/p110.pion"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"
cp -R "$DIR/xpkg" "$TMP_DIR/xpkg"
XAPP="$TMP_DIR/xpkg/app"
XEXP="b2 b2 b2 b2,h:b2 p:a1 t:a1 t:a1 111 11"

check() {
  if ! diff -u "$DIR/expected.txt" "$2"; then
    echo "FAIL: p110 $1" >&2
    exit 1
  fi
  echo "p110 $1 ok"
}

check_x() {
  if [ "$2" != "$XEXP" ]; then
    echo "FAIL: p110 cross-pkg $1 expected '$XEXP', got '$2'" >&2
    exit 1
  fi
  echo "p110 cross-pkg $1 ok"
}

# 1. SSA shape + native dev / --release output
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG --emit-ssa "$TMP_DIR/$MODE.ssa" -o "$TMP_DIR/p110_$MODE" "$SRC"
  python3 - "$TMP_DIR/$MODE.ssa" "$MODE" <<'PYEOF'
import re, sys
ir, mode = open(sys.argv[1]).read(), sys.argv[2]
wraps = {
    m.group(1): m.group(0)
    for m in re.finditer(r'^function l (\$pion_\w*?wrap_\w+)\([^\n]*\{.*?^\}', ir, re.M | re.S)
}
def wrap(pat):
    hits = [w for w in wraps if re.search(pat, w)]
    assert hits, f"{mode}: no fn value wrapper matching {pat} (got {sorted(wraps)})"
    return hits
def callee(body):
    return re.search(r'call (\$[^\s(]+)\(', body).group(1)
# Monomorphized instances (flat `Array[Pair[Int, String]]`, `==`): a
# `wrap_m_*` thunk calling the `__mono_*` symbol.
for pat in (r'wrap_m_lf_second_of__mono_Int$', r'wrap_m_lf_count_eq__mono_String$',
            r'wrap_m_lf_count_eq__mono_Int$', r'wrap_m_lm_Pairs\w*second_uof__mono_Int$',
            r'wrap_m_lf_same__mono_Float$', r'wrap_m_lf_same__mono_UInt$', r'wrap_m_lf_same__mono_Double$'):
    for w in wrap(pat):
        assert '__mono_' in callee(wraps[w]), f"{mode}: {w} does not call a mono instance:\n{wraps[w]}"
# `Float` / `UInt` / `Double` targets are called with their own ABI.
for pat, abi in ((r'wrap_m_lf_same__mono_Float$', 's'), (r'wrap_lf_half$', 's'),
                 (r'wrap_m_lf_same__mono_UInt$', 'w'), (r'wrap_lf_bump$', 'w'),
                 (r'wrap_m_lf_same__mono_Double$', 'd')):
    for w in wrap(pat):
        body = wraps[w]
        assert re.search(r'%rv =' + abi + r' call \$[^(]+\(' + abi + ' %ap0', body), f"{mode}: {w} lost the {abi} ABI:\n{body}"
# Polymorphic `first_of`: a constant flag at the concrete `String` site, an
# env-loaded flag inside `poly_first[T]`, always after the value arguments
# (`Array[Int]` is a compact 4-byte layout: that instance is monomorphized).
fo = wrap(r'wrap_tp\w+_lf_first_of$')
flags = sorted(re.search(r'wrap_tp(\w+?)_lf_', w).group(1) for w in fo)
assert {'1', 'e'} <= set(flags), f"{mode}: first_of wrappers {flags}, want 1 (String) and e (env)"
for w in fo:
    body = wraps[w]
    call = re.search(r'call (\$\S+?)\((.*)\)', body).group(2)
    assert call.count(', l ') == 1, f"{mode}: {w} must pass 1 value + 1 flag: {call}"
    flag = re.search(r'wrap_tp(\w+?)_lf_', w).group(1)
    if flag == 'e':
        assert 'loadl' in body and call.endswith('l %tf0'), f"{mode}: {w} must load its flag from the env:\n{body}"
    else:
        assert call.endswith('l ' + flag), f"{mode}: {w} passes the wrong flag: {call}"
# `pick` (generic) and the user fns `pick__tp_0` / `pick__mono_Int` get
# distinct thunks.
for pat in (r'wrap_tp0_lf_pick$', r'wrap_lf_pick__tp_0$', r'wrap_lf_pick__mono_Int$'):
    assert len(wrap(pat)) == 1, f"{mode}: {pat}"
# No thunk calls a generic fn without instantiating it.
for w, body in wraps.items():
    if re.search(r'_(second_of|first_of|count_eq|same|second)(__|$)', w):
        assert 'wrap_m_' in w or 'wrap_tp' in w, f"{mode}: {w} is not instantiated"
print(f"p110 {mode} SSA ok ({len(wraps)} fn value wrappers)")
PYEOF
  "$TMP_DIR/p110_$MODE" > "$TMP_DIR/$MODE.out"
  check "native $MODE" "$TMP_DIR/$MODE.out"
  "$PIONC" build $FLAG -o "$TMP_DIR/x_$MODE" "$XAPP"
  check_x "native $MODE" "$("$TMP_DIR/x_$MODE")"
done

# 2. Wasm32 dev & --release
if command -v node >/dev/null 2>&1; then
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    "$PIONC" build $FLAG --target wasm32 -o "$TMP_DIR/$MODE.wasm" "$SRC"
    node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/$MODE.wasm" > "$TMP_DIR/w$MODE.out"
    check "wasm32 $MODE" "$TMP_DIR/w$MODE.out"
    "$PIONC" build $FLAG --target wasm32 -o "$TMP_DIR/x_$MODE.wasm" "$XAPP"
    check_x "wasm32 $MODE" "$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/x_$MODE.wasm")"
  done
else
  echo "NOTE: node unavailable; skipping p110 Wasm32 checks"
fi

# 3. ASan/LSan (dev & --release)
CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  printf '#!/bin/sh\nexec "%s" -fsanitize=address "$@"\n' "$CC_BIN" > "$TMP_DIR/cc_asan.sh"
  chmod +x "$TMP_DIR/cc_asan.sh"
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/p110.o" "$SRC"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/p110.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p110_asan"
    "$TMP_DIR/p110_asan" > "$TMP_DIR/asan.out"
    check "ASan/LSan ${MODE:-dev}" "$TMP_DIR/asan.out"
    CC="$TMP_DIR/cc_asan.sh" PION_RT_LIB="$TMP_DIR/libpionrt_asan.a" "$PIONC" build $MODE -o "$TMP_DIR/x_asan" "$XAPP"
    check_x "ASan/LSan ${MODE:-dev}" "$("$TMP_DIR/x_asan")"
  done
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p110 ASan check"
fi

# 4. A generic fn value obeys its trait bounds and `==` rules and must fit the
#    call's final instantiation, whether fixed before or after it is passed.
for CASE in bound_value:E_TRAIT_NOT_IMPLEMENTED bound_hof:E_TRAIT_NOT_IMPLEMENTED \
  bound_block:E_TRAIT_NOT_IMPLEMENTED bound_partial:E_TRAIT_NOT_IMPLEMENTED \
  eq_value:E_TYPE_MISMATCH eq_hof:E_TYPE_MISMATCH \
  conflict_first:E_TYPE_MISMATCH conflict_last:E_TYPE_MISMATCH \
  conflict_block:E_TYPE_MISMATCH conflict_branch:E_TYPE_MISMATCH \
  conflict_match:E_TYPE_MISMATCH conflict_array:E_TYPE_MISMATCH \
  conflict_array_last:E_TYPE_MISMATCH conflict_option:E_TYPE_MISMATCH \
  conflict_relay:E_TYPE_MISMATCH conflict_relay_last:E_TYPE_MISMATCH \
  bound_relay:E_TRAIT_NOT_IMPLEMENTED \
  conflict_tuple:E_TYPE_MISMATCH conflict_tuple_last:E_TYPE_MISMATCH \
  conflict_struct:E_TYPE_MISMATCH conflict_struct_last:E_TYPE_MISMATCH \
  conflict_enum:E_TYPE_MISMATCH conflict_enum_last:E_TYPE_MISMATCH \
  conflict_keep:E_TYPE_MISMATCH conflict_dot:E_TYPE_MISMATCH \
  move_order:E_USE_AFTER_MOVE conflict_named_relay:E_TYPE_MISMATCH \
  conflict_method_relay:E_TYPE_MISMATCH conflict_method_relay_last:E_TYPE_MISMATCH \
  bound_relay_callee:E_TRAIT_NOT_IMPLEMENTED bound_relay_callee_annot:E_TRAIT_NOT_IMPLEMENTED \
  conflict_opt_relay:E_TYPE_MISMATCH conflict_opt_relay_last:E_TYPE_MISMATCH \
  bound_method_relay:E_TRAIT_NOT_IMPLEMENTED bound_fn_relay_arg:E_TRAIT_NOT_IMPLEMENTED \
  conflict_relay_skip_opt:E_TYPE_MISMATCH conflict_relay_trailing_opt:E_TYPE_MISMATCH; do
  NAME="${CASE%%:*}"
  CODE="${CASE#*:}"
  if OUT=$("$PIONC" check --json "$DIR/neg/$NAME.pion" 2>&1); then
    echo "FAIL: p110 neg/$NAME.pion type-checked ($OUT)" >&2
    exit 1
  fi
  if ! printf '%s' "$OUT" | grep -q "\"code\":\"$CODE\""; then
    echo "FAIL: p110 neg/$NAME.pion: want $CODE, got $OUT" >&2
    exit 1
  fi
  echo "p110 neg $NAME -> $CODE ok"
done

echo "PASS: p110_fnval_flat_and_is_shadow"
