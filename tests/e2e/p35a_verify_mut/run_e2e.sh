#!/bin/sh
set -eu

# P35-A permanent E2E regression: second-class `mut` parameters and `#verify`.
#   1. `pionc fmt --check` on every source
#   2. cross-package workspace (vlib has `[verify] enabled = true`): scalar /
#      struct-field / array-element / whole-object `mut` arguments, `mut self`
#      (inherent, cross-package, trait-bound generic), generic `mut T`,
#      `Array::swap`, P38-B+C compact `Bool`/`Byte` and flat POD struct arrays
#      (`swap` incl. `i == j`, `mut arr[i]` write-back), `mut` forwarding, early return write-back, `#verify_opaque`
#   3. `#verify` runtime checks: division by zero, MIN / -1, MIN % -1, shift range
#   4. Native release, ASan/LSan (single-file flattening), and `--target wasm32`

PIONC="${1:?usage: run_e2e.sh <pionc>}"
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"
CC_BIN="${CC:-cc}"

EXPECTED="p35a n=52 arr=10,2,103,10,4 p=4,1 acc=499500/1000/0/0 s=beta,alpha name=late r=750 big=renewnewb/1/fresh names=z,B,c,a sum=10 len=5 div=3 rem=2 shl=48 b=0011 by=250,77,3,1 fby=5,45,25,35,15 pods=5:6,40:41,1:2 fp=1:100,0:0,2:200 q=7:8 p3=4:5:6,1:2:3"
APP_DIR="$TEST_DIR/app"

# 1. Formatter
for f in "$TEST_DIR/vlib/src/lib.pion" "$APP_DIR/src/main.pion"; do
  FMT_OUT=$("$PIONC" fmt --check --json "$f")
  if ! printf '%s' "$FMT_OUT" | grep -q '"ok":true'; then
    echo "FAIL: p35a fmt --check $f: $FMT_OUT" >&2
    exit 1
  fi
done

# 2. Native release (cross-package)
"$PIONC" build --release -o "$TMP_DIR/p35a" "$APP_DIR"
OUT=$("$TMP_DIR/p35a")
echo "p35a native -> $OUT"
if [ "$OUT" != "$EXPECTED" ]; then
  echo "FAIL: p35a native mismatch: expected '$EXPECTED', got '$OUT'" >&2
  exit 1
fi

# 3. `#verify` runtime checks (child process must abort with the message)
expect_panic() {
  mode="$1"
  msg="$2"
  set +e
  "$TMP_DIR/p35a" "$mode" > "$TMP_DIR/panic.out" 2> "$TMP_DIR/panic.err"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] || ! grep -q "$msg" "$TMP_DIR/panic.err"; then
    echo "FAIL: p35a mode '$mode' expected non-zero exit and '$msg' (rc=$rc): $(cat "$TMP_DIR/panic.err")" >&2
    exit 1
  fi
  echo "p35a $mode -> rc=$rc: $(head -1 "$TMP_DIR/panic.err")"
}
expect_panic zero "division by zero"
expect_panic ovf "integer overflow in division"
expect_panic removf "integer overflow in division"
expect_panic shift "shift amount out of range"

# 4. ASan/LSan: the same program flattened into one file (no pion.toml).
sed -e '/^import "vlib"/d' -e 's/vlib:://g' "$APP_DIR/src/main.pion" > "$TMP_DIR/main_body.pion"
cat "$TEST_DIR/vlib/src/lib.pion" "$TMP_DIR/main_body.pion" > "$TMP_DIR/flat.pion"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --emit-obj "$TMP_DIR/flat.o" "$TMP_DIR/flat.pion"
  "$CC_BIN" -fsanitize=address "$TMP_DIR/flat.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/flat_asan"
  ASAN_OUT=$("$TMP_DIR/flat_asan")
  echo "p35a ASan/LSan -> $ASAN_OUT"
  if [ "$ASAN_OUT" != "$EXPECTED" ]; then
    echo "FAIL: p35a ASan/LSan mismatch: '$ASAN_OUT'" >&2
    exit 1
  fi
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p35a ASan check"
fi

# 5. Wasm32 (cross-package)
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/p35a.wasm" "$APP_DIR"
  WASM_OUT=$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/p35a.wasm")
  echo "p35a wasm32 -> $WASM_OUT"
  if [ "$WASM_OUT" != "$EXPECTED" ]; then
    echo "FAIL: p35a wasm32 mismatch: expected '$EXPECTED', got '$WASM_OUT'" >&2
    exit 1
  fi
else
  echo "NOTE: node unavailable; skipping p35a wasm32 check"
fi

echo "PASS: p35a_verify_mut"
