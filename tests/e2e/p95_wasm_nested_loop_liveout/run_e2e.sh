#!/bin/sh
# P95: Wasm32 `wasm_outline_nested_loops` live-out of promoted slots that are both read and
# written only inside an outlined depth-2 loop (`let mut pos` declared before the outer `while`,
# touched only by the inner `while`). Before the fix the slot was not written back to the caller,
# so every outer iteration re-entered the outlined loop with the stale initial value.
# Native vs Wasm32, Debug and --release, must print byte-identical output.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

echo "=== [P95] Wasm32 nested-loop outlining: inner-loop-only read+write slot live-out ==="

SRC="$ROOT_DIR/tests/e2e/p95_wasm_nested_loop_liveout/p95.pion"

NAT_DBG="$("$PIONC" run "$SRC")"
NAT_REL="$("$PIONC" run --release "$SRC")"
echo "native debug:"
printf '%s\n' "$NAT_DBG"
if [ "$NAT_DBG" != "$NAT_REL" ]; then
  echo "FAIL: native debug vs release mismatch" >&2
  printf 'release:\n%s\n' "$NAT_REL" >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is required for the Wasm32 leg of P95" >&2
  exit 1
fi
"$PIONC" build --target wasm32 -o "$TMP_DIR/p95_dbg.wasm" "$SRC"
"$PIONC" build --release --target wasm32 -o "$TMP_DIR/p95_rel.wasm" "$SRC"
for mode in dbg rel; do
  OUT_W="$(node "$WASM_RT" "$TMP_DIR/p95_$mode.wasm")"
  if [ "$OUT_W" != "$NAT_DBG" ]; then
    echo "FAIL: Wasm32 ($mode) diverges from Native" >&2
    printf 'native:\n%s\nwasm32 (%s):\n%s\n' "$NAT_DBG" "$mode" "$OUT_W" >&2
    exit 1
  fi
done
echo "[PASS] P95 Native == Wasm32 (Debug + --release) for while->if/if-else/match->while live-out and >8-slot back-off"
