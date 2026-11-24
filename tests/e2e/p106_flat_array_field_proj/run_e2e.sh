#!/bin/sh
# P106: Flat array struct field direct projection (`arr[i].field` without temporary struct boxing).
# Verifies:
# 1. SSA zero-boxing in direct field projection functions (`$pion_alloc_uninit` / `$pion_alloc` == 0).
# 2. Exact output parity across Native dev, Native --release, Wasm32 dev, Wasm32 --release.
# 3. ASan/LSan 0 leaks / 0 UAF / 0 double-free (dev & --release) on heap fields, owned temp arrays,
#    mutation/reallocation/clear after projection, early return / `?`, and nested fields.
# 4. Out-of-bounds traps (`arr[-1].field`, `arr[len].field`, owned temp OOB, matrix OOB) in Native & Wasm32.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p106_flat_array_field_proj"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

check() {
  if ! diff -u "$DIR/expected.txt" "$2"; then
    echo "FAIL: p106 $1" >&2
    exit 1
  fi
  echo "p106 $1 ok"
}

SRC="$DIR/p106.pion"

# 1. SSA zero-boxing verification
"$PIONC" build --release --emit-ssa "$TMP_DIR/p106.ssa" "$SRC"
python3 - "$TMP_DIR/p106.ssa" <<'PYEOF'
import sys, re
ssa = open(sys.argv[1]).read()
def fn_body(name):
    m = re.search(rf"function [^\n]*\$[^\s(]*{re.escape(name)}\([^\n]*\)\s*\{{(.*?)\n\}}", ssa, re.S)
    assert m, f"function *{name} not found in SSA"
    return m.group(1)

for fn in [
    "proj_holder_scalar",
    "proj_holder_name",
    "proj_owned_branch_scalar",
    "proj_owned_branch_name",
    "proj_matrix_y",
    "proj_fixed_imm",
]:
    body = fn_body(fn)
    allocs = body.count("$pion_alloc_uninit") + body.count("$pion_alloc(")
    assert allocs == 0, f"{fn} should not materialize temporary struct box, found {allocs} alloc calls"
print("p106 SSA zero-boxing ok (6/6 functions)")
PYEOF

# 2. Native dev & release
"$PIONC" run "$SRC" > "$TMP_DIR/dev.out"
check "native dev" "$TMP_DIR/dev.out"
"$PIONC" run --release "$SRC" > "$TMP_DIR/rel.out"
check "native release" "$TMP_DIR/rel.out"

# 3. Wasm32 dev & release
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/dev.wasm" "$SRC"
  node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/dev.wasm" > "$TMP_DIR/wdev.out"
  check "wasm32 dev" "$TMP_DIR/wdev.out"
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/rel.wasm" "$SRC"
  node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/rel.wasm" > "$TMP_DIR/wrel.out"
  check "wasm32 release" "$TMP_DIR/wrel.out"
else
  echo "NOTE: node unavailable; skipping p106 Wasm32 checks"
fi

# 4. ASan/LSan (dev & --release)
CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/p106.o" "$SRC"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/p106.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p106_asan"
    "$TMP_DIR/p106_asan" > "$TMP_DIR/asan.out"
    check "ASan/LSan ${MODE:-dev}" "$TMP_DIR/asan.out"
  done
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p106 ASan check"
fi

# 5. Out-of-bounds traps (negative index, i >= len, owned temp array, matrix)
cat > "$TMP_DIR/oob.pion" <<'EOF'
struct Item {
  id : Int
  name : String
}

struct Box {
  items : Array[Item]
}

fn make_items() -> Array[Item] {
  [Item::{ id: 1, name: "a" }, Item::{ id: 2, name: "b" }]
}

fn main(w : World) -> Unit {
  let args = world_args(w)
  let mode = if args.length() > 1 { args[1] } else { "0" }
  let b = Box::{ items: make_items() }
  if mode == "neg_field" {
    let i = -1
    io_println(w, b.items[i].name)
  } else if mode == "hi_field" {
    let i = 2
    io_println(w, b.items[i].name)
  } else if mode == "neg_owned" {
    let i = -1
    io_println(w, make_items()[i].id.to_string())
  } else if mode == "hi_owned" {
    let i = 3
    io_println(w, make_items()[i].id.to_string())
  } else if mode == "mat_hi" {
    let m : Array[Array[Item]] = [make_items()]
    let r = 0
    let c = 2
    io_println(w, m[r][c].id.to_string())
  } else {
    io_println(w, b.items[0].name)
  }
}
EOF

"$PIONC" build --release -o "$TMP_DIR/oob_bin" "$TMP_DIR/oob.pion"
OK_OUT="$("$TMP_DIR/oob_bin")"
if [ "$OK_OUT" != "a" ]; then
  echo "FAIL: p106 oob baseline expected 'a', got '$OK_OUT'" >&2
  exit 1
fi
for MODE in neg_field hi_field neg_owned hi_owned mat_hi; do
  if "$TMP_DIR/oob_bin" "$MODE" >/dev/null 2>&1; then
    echo "FAIL: p106 native OOB ($MODE) did not trap!" >&2
    exit 1
  fi
done
echo "p106 native OOB traps ok (5/5)"

if command -v node >/dev/null 2>&1; then
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/oob.wasm" "$TMP_DIR/oob.pion"
  for MODE in neg_field hi_field neg_owned hi_owned mat_hi; do
    if node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/oob.wasm" "$MODE" >/dev/null 2>&1; then
      echo "FAIL: p106 wasm32 OOB ($MODE) did not trap!" >&2
      exit 1
    fi
  done
  echo "p106 wasm32 OOB traps ok (5/5)"
fi

echo "PASS: p106_flat_array_field_proj"
