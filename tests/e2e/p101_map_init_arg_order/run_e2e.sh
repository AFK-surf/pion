#!/bin/sh
# P101: `Map([(k, v), ..])` keeps its initial entries (string / int / value-type keys, heap
# values, duplicates, early exits) and named arguments are evaluated in source order.
# Native dev / --release and Wasm32 dev / --release must match `expected.txt`; the native
# objects must also be clean under ASan/LSan.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p101_map_init_arg_order"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

check() {
  if ! diff -u "$DIR/expected.txt" "$2"; then
    echo "FAIL: p101 $1" >&2
    exit 1
  fi
  echo "p101 $1 ok"
}

SRC="$DIR/p101.pion"
"$PIONC" run "$SRC" > "$TMP_DIR/dev.out"
check "native dev" "$TMP_DIR/dev.out"
"$PIONC" run --release "$SRC" > "$TMP_DIR/rel.out"
check "native release" "$TMP_DIR/rel.out"

if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/dev.wasm" "$SRC"
  node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/dev.wasm" > "$TMP_DIR/wdev.out"
  check "wasm32 dev" "$TMP_DIR/wdev.out"
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/rel.wasm" "$SRC"
  node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/rel.wasm" > "$TMP_DIR/wrel.out"
  check "wasm32 release" "$TMP_DIR/wrel.out"
else
  echo "NOTE: node unavailable; skipping p101 Wasm32 checks"
fi

CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/p101.o" "$SRC"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/p101.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p101_asan"
    "$TMP_DIR/p101_asan" > "$TMP_DIR/asan.out"
    check "ASan/LSan ${MODE:-dev}" "$TMP_DIR/asan.out"
  done
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p101 ASan check"
fi

cat > "$TMP_DIR/bad.pion" <<'EOF'
fn main(w : World) -> Unit {
  let m : Map[Int, String] = Map([(1, 5)])
  let n : Map[String, Int] = Map([(1, 5)])
  let o : Map[Int, Int] = Map([(1, nope())])
  io_println(w, "\{m.length() + n.length() + o.length()}")
}
EOF
if "$PIONC" check --json "$TMP_DIR/bad.pion" > "$TMP_DIR/bad.json"; then
  echo "FAIL: p101 ill-typed Map initializers were accepted" >&2
  exit 1
fi
if [ "$(grep -o 'E_TYPE_MISMATCH' "$TMP_DIR/bad.json" | wc -l)" -lt 2 ] || ! grep -q 'nope' "$TMP_DIR/bad.json"; then
  cat "$TMP_DIR/bad.json" >&2
  echo "FAIL: p101 missing Map initializer diagnostics" >&2
  exit 1
fi
echo "PASS: p101_map_init_arg_order"
