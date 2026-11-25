#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
DIR="$ROOT_DIR/tests/e2e/generic_arith_mono"
SRC="$DIR/main.pion"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

EXP="ok=true neg=-2.5 sub=-2.5 add=3.5 mul=3 dv=0.75 str=ab arr=-2.5"

for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG -o "$TMP_DIR/bin_$MODE" "$SRC"
  OUT="$("$TMP_DIR/bin_$MODE")"
  if [ "$OUT" != "$EXP" ]; then
    echo "FAIL: generic_arith_mono native $MODE: got '$OUT', want '$EXP'" >&2
    exit 1
  fi
  echo "generic_arith_mono native $MODE ok"
done

if command -v node >/dev/null 2>&1; then
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    "$PIONC" build $FLAG --target wasm32 -o "$TMP_DIR/bin_$MODE.wasm" "$SRC"
    WOUT="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/bin_$MODE.wasm")"
    if [ "$WOUT" != "$EXP" ]; then
      echo "FAIL: generic_arith_mono wasm32 $MODE: got '$WOUT', want '$EXP'" >&2
      exit 1
    fi
    echo "generic_arith_mono wasm32 $MODE ok"
  done
fi

CC_BIN="${CC:-cc}"
if [ -n "${PION_ASAN_RT_LIB:-}" ] && [ -f "${PION_ASAN_RT_LIB:-}" ]; then
  ASAN_LIB="$PION_ASAN_RT_LIB"
elif printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  ASAN_LIB="$TMP_DIR/libpionrt_asan.a"
else
  ASAN_LIB=""
fi

if [ -n "$ASAN_LIB" ]; then
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/ga.o" "$SRC"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/ga.o" "$ASAN_LIB" -lm -lpthread -o "$TMP_DIR/ga_asan"
    AOUT="$("$TMP_DIR/ga_asan")"
    if [ "$AOUT" != "$EXP" ]; then
      echo "FAIL: generic_arith_mono ASan ${MODE:-dev}: got '$AOUT', want '$EXP'" >&2
      exit 1
    fi
    echo "generic_arith_mono ASan ${MODE:-dev} ok"
  done
elif [ "${PION_REQUIRE_SANITIZERS:-0}" = "1" ]; then
  echo "FAIL: generic_arith_mono ASan required (PION_REQUIRE_SANITIZERS=1) but unavailable" >&2
  exit 1
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping generic_arith_mono ASan check"
fi

check_reject() {
  name="$1"
  code="$2"
  printf '%s\n' "$code" > "$TMP_DIR/$name.pion"
  if OUT="$("$PIONC" check --json "$TMP_DIR/$name.pion" 2>&1)"; then
    echo "FAIL: generic_arith_mono $name unexpectedly passed ($OUT)" >&2
    exit 1
  fi
  if ! printf '%s' "$OUT" | grep -q '"code":"E_TYPE_MISMATCH"'; then
    echo "FAIL: generic_arith_mono $name expected E_TYPE_MISMATCH, got $OUT" >&2
    exit 1
  fi
}

check_reject neg_str 'fn neg[T](x : T) -> T { -x }
pub fn main() -> Int { let _ = neg("abc"); 0 }'
check_reject neg_bool 'fn neg[T](x : T) -> T { -x }
pub fn main() -> Int { let _ = neg(true); 0 }'
check_reject add_bool 'fn add[T](a : T, b : T) -> T { a + b }
pub fn main() -> Int { let _ = add(true, false); 0 }'
check_reject sub_str 'fn sub[T](a : T, b : T) -> T { a - b }
pub fn main() -> Int { let _ = sub("a", "b"); 0 }'
check_reject bit_dbl 'fn bit_and[T](a : T, b : T) -> T { a & b }
pub fn main() -> Int { let _ = bit_and(1.5, 2.5); 0 }'
check_reject wrap_str 'fn neg[T](x : T) -> T { -x }
fn wrap_neg[U](x : U) -> U { neg(x) }
pub fn main() -> Int { let _ = wrap_neg("abc"); 0 }'
check_reject lt_struct 'struct P { x : Int }
fn lt[T](a : T, b : T) -> Bool { a < b }
pub fn main() -> Int { let _ = lt(P::{ x: 1 }, P::{ x: 2 }); 0 }'
check_reject lt_struct_direct 'struct P { x : Int }
pub fn main() -> Int { let _ = P::{ x: 1 } < P::{ x: 2 }; 0 }'
check_reject lt_payload_enum 'enum E { A(Int); B(Int) }
fn lt[T](a : T, b : T) -> Bool { a < b }
pub fn main() -> Int { let _ = lt(E::A(1), E::B(2)); 0 }'
check_reject lt_payload_enum_direct 'enum E { A(Int); B(Int) }
pub fn main() -> Int { let _ = E::A(1) < E::B(2); 0 }'

# Cross-package public generic calling private generic helper
mkdir -p "$TMP_DIR/xpkg/num/src" "$TMP_DIR/xpkg/app/src"
cat > "$TMP_DIR/xpkg/num/pion.toml" <<'EOF'
[package]
name = "num"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xpkg/num/src/num.pion" <<'EOF'
fn inner_add[T](a : T, b : T) -> T {
  a + b
}

pub fn add2[T](a : T, b : T) -> T {
  inner_add(a, b)
}
EOF
cat > "$TMP_DIR/xpkg/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
num = { path = "../num" }
EOF
cat > "$TMP_DIR/xpkg/app/src/main.pion" <<'EOF'
import "num" as n

pub fn main(world : World) -> Int {
  let d = n::add2(1.5, 2.0)
  let s = n::add2("a", "b")
  let ok = d == 3.5 && s == "ab"
  io_println(world, "xpkg=" + ok.to_string() + " d=" + d.to_string() + " s=" + s)
  if ok { 0 } else { 1 }
}
EOF

XEXP="xpkg=true d=3.5 s=ab"
for MODE in dev release; do
  FLAG=""
  [ "$MODE" = "release" ] && FLAG="--release"
  "$PIONC" build $FLAG -o "$TMP_DIR/xbin_$MODE" "$TMP_DIR/xpkg/app"
  XOUT="$("$TMP_DIR/xbin_$MODE")"
  if [ "$XOUT" != "$XEXP" ]; then
    echo "FAIL: generic_arith_mono xpkg native $MODE: got '$XOUT', want '$XEXP'" >&2
    exit 1
  fi
  echo "generic_arith_mono xpkg native $MODE ok"
done

if command -v node >/dev/null 2>&1; then
  for MODE in dev release; do
    FLAG=""
    [ "$MODE" = "release" ] && FLAG="--release"
    "$PIONC" build $FLAG --target wasm32 -o "$TMP_DIR/xbin_$MODE.wasm" "$TMP_DIR/xpkg/app"
    XWOUT="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/xbin_$MODE.wasm")"
    if [ "$XWOUT" != "$XEXP" ]; then
      echo "FAIL: generic_arith_mono xpkg wasm32 $MODE: got '$XWOUT', want '$XEXP'" >&2
      exit 1
    fi
    echo "generic_arith_mono xpkg wasm32 $MODE ok"
  done
fi

if [ -n "$ASAN_LIB" ]; then
  printf '#!/bin/sh\nexec "%s" -fsanitize=address "$@"\n' "$CC_BIN" > "$TMP_DIR/cc_asan.sh"
  chmod +x "$TMP_DIR/cc_asan.sh"
  for MODE in "" --release; do
    CC="$TMP_DIR/cc_asan.sh" PION_RT_LIB="$ASAN_LIB" "$PIONC" build $MODE -o "$TMP_DIR/xga_asan" "$TMP_DIR/xpkg/app"
    XAOUT="$("$TMP_DIR/xga_asan")"
    if [ "$XAOUT" != "$XEXP" ]; then
      echo "FAIL: generic_arith_mono xpkg ASan ${MODE:-dev}: got '$XAOUT', want '$XEXP'" >&2
      exit 1
    fi
    echo "generic_arith_mono xpkg ASan ${MODE:-dev} ok"
  done
fi

echo "PASS: generic_arith_mono"
