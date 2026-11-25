#!/bin/sh
# P112: two native runtime optimizations
# (Lean: tests/lean/proofs/QbeRuntimeOpts3.lean).
#   bounded format  compiler/src/core/qbe.pion `qbe_bounded_format`: in a
#                   native hot loop, a 2..8 part string `+` chain of ASCII
#                   literals of at most 8 bytes and `.to_string()` of `Int` /
#                   `Int64` locals is formatted into one bounded stack
#                   `PionStrBuf` and copied once by `$pion_str_from_cstr`.
#   groupconverts   vendor/qbe/gcm.c: a loop block without stores or calls
#                   with 2..4 `swtof` / `Kd` moves the conversions and their
#                   integer, non-comparison in-block dependencies first.
# Verifies:
#   1. SSA (dev & --release): each bounded chain is one `$pion_str_from_cstr`
#      with no `$pion_str_concat*` / heap integer temporaries; 9-byte and
#      non-ASCII literals, 9 parts, non-local / unsigned receivers, trait
#      dispatch and chains outside loops keep the original lowering.
#   2. Exact output across Native dev & --release, Wasm32 dev & --release and
#      ASan/LSan dev & --release (INT32/INT64 extremes, -1 / 0 / 1, embedded
#      NUL bytes, 8-byte literals, 8 integer parts, nested loops, map keys).
#   3. groupconverts: the `-d G` dump of sched.ssa groups the conversions of
#      conv2 / conv3 / conv4 and keeps the source order of every neg_* block
#      (store, call, load and comparison dependencies, five conversions);
#      driver.c checks all 8 functions bit for bit on 625 inputs each.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p112_bounded_format_and_swtof_sched"
SRC="$DIR/p112.pion"
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC_BIN="${CC:-cc}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

check() {
  if ! cmp -s "$DIR/expected.txt" "$2"; then
    diff -u "$DIR/expected.txt" "$2" || true
    echo "FAIL: p112 $1" >&2
    exit 1
  fi
  echo "p112 $1 ok"
}

# 1. SSA shape + native dev / --release output
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG --emit-ssa "$TMP_DIR/$MODE.ssa" -o "$TMP_DIR/p112_$MODE" "$SRC"
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
heap = ('$pion_str_concat', '$pion_int_to_str', '$pion_i64_to_str')
# Bounded chains: name -> integer parts.
want = {'two_int': 1, 'two_i64': 1, 'three': 1, 'four': 2, 'five': 3,
        'six': 3, 'seven': 3, 'eight': 8, 'nested': 2}
for name, ints in want.items():
    b = body(name)
    got = b.count('call $pion_str_from_cstr(')
    assert got == 1, f"{mode}: {name} has {got} pion_str_from_cstr calls, want 1"
    pushes = b.count('call $pion_strbuf_push_int(')
    assert pushes == ints, f"{mode}: {name} formats {pushes} integers, want {ints}"
    for h in heap:
        assert h not in b, f"{mode}: {name} still calls {h}"
for name in ('long_lit', 'non_ascii', 'nine', 'other_recv', 'cold', 'wrap__mono_Int'):
    b = body(name)
    assert '$pion_str_from_cstr' not in b, f"{mode}: {name} must keep the original lowering"
    assert '$pion_str_concat' in b, f"{mode}: {name} lost its concatenation"
print(f"p112 {mode} SSA ok ({len(want)} bounded chains, 6 fallbacks)")
PYEOF
  "$TMP_DIR/p112_$MODE" > "$TMP_DIR/$MODE.out"
  check "native $MODE" "$TMP_DIR/$MODE.out"
done

# 2. Wasm32 dev & --release (original lowering)
if command -v node >/dev/null 2>&1; then
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    "$PIONC" build $FLAG --target wasm32 --emit-ssa "$TMP_DIR/w$MODE.ssa" -o "$TMP_DIR/$MODE.wasm" "$SRC"
    if grep -q 'pion_str_from_cstr' "$TMP_DIR/w$MODE.ssa"; then
      echo "FAIL: p112 wasm32 $MODE uses the native bounded format" >&2
      exit 1
    fi
    node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/$MODE.wasm" > "$TMP_DIR/w$MODE.out"
    check "wasm32 $MODE" "$TMP_DIR/w$MODE.out"
  done
else
  echo "NOTE: node unavailable; skipping p112 Wasm32 checks"
fi

# 3. ASan/LSan (dev & --release)
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/p112.o" "$SRC"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/p112.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p112_asan"
    "$TMP_DIR/p112_asan" > "$TMP_DIR/asan.out"
    check "ASan/LSan ${MODE:-dev}" "$TMP_DIR/asan.out"
  done
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p112 ASan check"
fi

# 4. groupconverts on sched.ssa
if [ ! -x "$QBE" ]; then
  echo "FAIL: QBE binary not found at $QBE" >&2
  exit 1
fi
"$QBE" -d G -o "$TMP_DIR/dump.txt" "$DIR/sched.ssa" 2> "$TMP_DIR/gcm.txt"
python3 - "$TMP_DIR/gcm.txt" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
# The last dump of each function is the one after GCM (and groupconverts).
dumps = {}
for part in text.split('> After GCM:')[1:]:
    m = re.search(r'function \$(\w+)\(\) \{\n(.*?)\n\}', part, re.S)
    assert m, "no function after GCM"
    dumps[m.group(1)] = m.group(2)
def loop(name):
    assert name in dumps, f"{name}: no GCM dump (got {sorted(dumps)})"
    lines, on = [], False
    for ln in dumps[name].split('\n'):
        if ln.startswith('@'):
            on = ln == '@loop'
        elif on and ' phi ' not in ln:
            lines.append(ln.strip())
    return lines
def conv(ln):
    return re.search(r'=d swtof ', ln) is not None
def farith(ln):
    return re.search(r'=d (add|sub|mul|div) ', ln) is not None
for name, n in (('conv2', 2), ('conv3', 3), ('conv4', 4)):
    ls = loop(name)
    cs = [i for i, l in enumerate(ls) if conv(l)]
    fs = [i for i, l in enumerate(ls) if farith(l)]
    assert len(cs) == n, f"{name}: {len(cs)} conversions in the loop, want {n}: {ls}"
    assert max(cs) < min(fs), f"{name}: conversions not grouped before the arithmetic: {ls}"
for name, n in (('neg_store', 4), ('neg_call', 4), ('neg_load', 4), ('neg_cmp', 4), ('neg_five', 5)):
    ls = loop(name)
    cs = [i for i, l in enumerate(ls) if conv(l)]
    fs = [i for i, l in enumerate(ls) if farith(l)]
    assert len(cs) == n, f"{name}: {len(cs)} conversions in the loop, want {n}: {ls}"
    # Source order: arithmetic consumes f1 before the second conversion.
    assert min(fs) < cs[1], f"{name}: block was reordered: {ls}"
print("p112 groupconverts: conv2..4 grouped, 5 neg_* blocks in source order")
PYEOF
"$QBE" -o "$TMP_DIR/sched.s" "$DIR/sched.ssa"
"$CC_BIN" -O2 -ffp-contract=off "$DIR/driver.c" "$TMP_DIR/sched.s" -o "$TMP_DIR/sched"
"$TMP_DIR/sched" > "$TMP_DIR/sched.out"
cat "$TMP_DIR/sched.out"
if [ "$(grep -c ' 625/625$' "$TMP_DIR/sched.out")" -ne 8 ]; then
  echo "FAIL: p112 groupconverts results differ from the C reference" >&2
  exit 1
fi

echo "PASS: p112_bounded_format_and_swtof_sched"
