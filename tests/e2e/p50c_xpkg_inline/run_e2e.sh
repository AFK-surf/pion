#!/bin/sh
# E2E verification for P50-C:
#   - Cross-package small `pub` function / method inlining (Native --release & Wasm32 --release)
#   - Sound `.pionstub` / codegen CAS invalidation:
#     1. Cold build -> inlined SSA (0 `call $pion_pkg_geom_` in `hot_path`), correct output
#     2. Warm app-only edit -> upstream `geom` CAS HIT, correct output
#     3. Upstream small `pub` inline fn body edit -> downstream invalidated, immediate new output
#     4. Upstream private/non-inlined fn body edit -> downstream CAS HIT, updated runtime output
set -eu

PIONC="${1:-./out/pionc2}"
ROOT_DIR="$(pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pion_p50c_e2e.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

WS="$TMP_DIR/ws"
CAS="$TMP_DIR/cas"
mkdir -p "$WS/geom/src" "$WS/app/src" "$CAS"

cat > "$WS/pion.toml" <<'EOF'
[workspace]
members = ["geom", "app"]
EOF

cat > "$WS/geom/pion.toml" <<'EOF'
[package]
name = "geom"
version = "0.1.0"
EOF

cat > "$WS/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
geom = { path = "../geom" }
EOF

write_geom() {
  SCALE_ADD="$1"
  PRIV_BIAS="$2"
  cat > "$WS/geom/src/lib.pion" <<EOF
pub struct Vec2 {
  x : Int
  y : Int
}

pub fn Vec2::new(x : Int, y : Int) -> Vec2 {
  Vec2::{ x: x, y: y }
}

pub fn Vec2::dot(self : Vec2, other : Vec2) -> Int {
  self.x * other.x + self.y * other.y
}

pub fn add_scaled(a : Int, b : Int, k : Int) -> Int {
  a + b * k + $SCALE_ADD
}

pub fn acc_add(a : Int, b : Int) -> Int {
  let mut r = a
  r += b
  r
}

fn priv_helper(x : Int) -> Int {
  x * 3 + $PRIV_BIAS
}

pub fn uses_priv(x : Int) -> Int {
  priv_helper(x) + 1
}

pub fn big_fn(n : Int) -> Int {
  let mut acc = 0
  let mut i = 0
  while i < n {
    acc = acc + i
    i = i + 1
  }
  acc
}
EOF
}

write_app() {
  TAG="$1"
  cat > "$WS/app/src/main.pion" <<EOF
import "geom" as geom

pub fn hot_path(a : Int, b : Int) -> Int {
  let u = geom::Vec2::new(a, b)
  let v = geom::Vec2::new(b, a)
  geom::acc_add(geom::add_scaled(u.dot(v), a, 3), b)
}

pub fn cold_path(x : Int) -> Int {
  geom::uses_priv(x) + geom::big_fn(x)
}

fn main(w : World) -> Unit {
  let h = hot_path(4, 5)
  let c = cold_path(6)
  io_println(w, "$TAG:" + h.to_string() + ":" + c.to_string())
}
EOF
}

export PION_CACHE_DIR="$CAS"
export PION_CAS_TRACE=1
export PION_TRACE_CAS=1
if [ -x "$ROOT_DIR/out/qbe" ]; then
  export PION_QBE="$ROOT_DIR/out/qbe"
fi
if [ -f "$ROOT_DIR/out/libpionrt.a" ]; then
  export PION_RT_LIB="$ROOT_DIR/out/libpionrt.a"
fi
if [ -f "$ROOT_DIR/runtime/pion_wasm_rt.mjs" ]; then
  export PION_WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
fi

echo "=== [P50-C E2E] 1. Native --release ==="
write_geom 0 1
write_app "v1"
BIN="$TMP_DIR/app_bin"
TRACE1="$TMP_DIR/trace1.log"
PION_KEEP_NATIVE_SSA=1 "$PIONC" build --release -o "$BIN" "$WS/app" 2>"$TRACE1"
OUT1="$("$BIN")"
# hot_path(4,5): dot = 4*5 + 5*4 = 40; add_scaled(40, 4, 3) = 52; acc_add(52, 5) = 57
# cold_path(6): uses_priv(6) = (6*3+1)+1 = 20; big_fn(6) = 0+1+2+3+4+5 = 15; total = 35
echo "Native step1: $OUT1"
[ "$OUT1" = "v1:57:35" ]

# Check app SSA in CAS has 0 `call $pion_pkg_geom_` inside `hot_path`
APP_KEY1="$(grep '\[cas\] pkg=app MISS key=' "$TRACE1" | sed 's/.*key=//')"
APP_SSA1="$(ls "$CAS"/ssa/"$APP_KEY1"*.ssa | head -n 1)"
awk '/^export function .*\$pion_pkg_app_fn_hot_path\(/,/^}/' "$APP_SSA1" > "$TMP_DIR/hot1.ssa"
grep -q 'pion_pkg_app_fn_hot_path' "$TMP_DIR/hot1.ssa"
if grep -q 'call \$pion_pkg_geom_' "$TMP_DIR/hot1.ssa"; then
  echo "FAIL: hot_path still calls geom in Native SSA:"
  cat "$TMP_DIR/hot1.ssa"
  exit 1
fi

# Step 2: Warm app-only edit -> geom MUST be CAS HIT
write_app "v2"
TRACE2="$TMP_DIR/trace2.log"
"$PIONC" build --release -o "$BIN" "$WS/app" 2>"$TRACE2"
OUT2="$("$BIN")"
echo "Native step2: $OUT2"
[ "$OUT2" = "v2:57:35" ]
grep -q '\[cas\] pkg=geom HIT ' "$TRACE2"

# Step 3: Upstream small `pub` inline fn body edit -> downstream MUST invalidate & reflect new value
write_geom 100 1
TRACE3="$TMP_DIR/trace3.log"
"$PIONC" build --release -o "$BIN" "$WS/app" 2>"$TRACE3"
OUT3="$("$BIN")"
echo "Native step3: $OUT3"
[ "$OUT3" = "v2:157:35" ]
grep -q '\[cas\] pkg=geom MISS ' "$TRACE3"
grep -q '\[cas\] pkg=app MISS ' "$TRACE3"

# Step 4: Upstream private fn body edit -> `.pionstub` unchanged -> downstream `app` MUST be CAS HIT, runtime gets new value!
write_geom 100 11
TRACE4="$TMP_DIR/trace4.log"
"$PIONC" build --release -o "$BIN" "$WS/app" 2>"$TRACE4"
OUT4="$("$BIN")"
echo "Native step4: $OUT4"
[ "$OUT4" = "v2:157:45" ]
grep -q '\[cas\] pkg=geom MISS ' "$TRACE4"
grep -q '\[cas\] pkg=app HIT ' "$TRACE4"

if command -v node >/dev/null 2>&1 && [ -f "${PION_WASM_RT:-}" ]; then
  echo "=== [P50-C E2E] 2. Wasm32 --release ==="
  rm -rf "$CAS" && mkdir -p "$CAS"
  write_geom 0 1
  write_app "w1"
  WASM="$TMP_DIR/app.wasm"
  WTRACE1="$TMP_DIR/wtrace1.log"
  "$PIONC" build --release --target wasm32 -o "$WASM" "$WS/app" 2>"$WTRACE1"
  WOUT1="$(node "$PION_WASM_RT" "$WASM")"
  echo "Wasm step1: $WOUT1"
  [ "$WOUT1" = "w1:57:35" ]

  # Warm app-only edit -> geom CAS HIT
  write_app "w2"
  WTRACE2="$TMP_DIR/wtrace2.log"
  "$PIONC" build --release --target wasm32 -o "$WASM" "$WS/app" 2>"$WTRACE2"
  WOUT2="$(node "$PION_WASM_RT" "$WASM")"
  echo "Wasm step2: $WOUT2"
  [ "$WOUT2" = "w2:57:35" ]
  grep -q '\[cas-wasm\] pkg=geom HIT ' "$WTRACE2"

  # Upstream inline fn body edit -> downstream invalidated, immediate new value
  write_geom 200 1
  WTRACE3="$TMP_DIR/wtrace3.log"
  "$PIONC" build --release --target wasm32 -o "$WASM" "$WS/app" 2>"$WTRACE3"
  WOUT3="$(node "$PION_WASM_RT" "$WASM")"
  echo "Wasm step3: $WOUT3"
  [ "$WOUT3" = "w2:257:35" ]
  grep -q '\[cas-wasm\] pkg=geom MISS ' "$WTRACE3"
  grep -q '\[cas-wasm\] pkg=app MISS ' "$WTRACE3"

  # Upstream private fn body edit -> downstream CAS HIT, runtime gets new value
  write_geom 200 21
  WTRACE4="$TMP_DIR/wtrace4.log"
  "$PIONC" build --release --target wasm32 -o "$WASM" "$WS/app" 2>"$WTRACE4"
  WOUT4="$(node "$PION_WASM_RT" "$WASM")"
  echo "Wasm step4: $WOUT4"
  [ "$WOUT4" = "w2:257:55" ]
  grep -q '\[cas-wasm\] pkg=geom MISS ' "$WTRACE4"
  grep -q '\[cas-wasm\] pkg=app HIT ' "$WTRACE4"
else
  echo "=== [P50-C E2E] Wasm32 skipped (node or PION_WASM_RT missing) ==="
fi

echo "=== [P50-C E2E] ALL PASSED ==="
