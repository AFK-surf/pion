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
if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"; then
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/p101.o" "$SRC"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/p101.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p101_asan"
    "$TMP_DIR/p101_asan" > "$TMP_DIR/asan.out"
    check "ASan/LSan ${MODE:-dev}" "$TMP_DIR/asan.out"
  done
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p101 ASan check"
fi

# Cross-package: monomorphized bodies and reordered generic calls of an imported package,
# first with a cold cache, then with the library served from the CAS (warm rebuild).
LIB="$TMP_DIR/lib"; APP="$TMP_DIR/app"
mkdir -p "$LIB/src" "$APP/src"
cat > "$LIB/pion.toml" <<'EOF'
[package]
name = "maplib"
version = "0.1.0"
EOF
cat > "$LIB/src/lib.pion" <<'EOF'
pub struct Key {
  a : Int
  b : Int
}

fn id[T](x : T) -> T {
  x
}

fn pairs[K, V](k : K, v : V) -> Array[(K, V)] {
  [(k, v), (k, v)]
}

pub fn keep[T](x~ : T, o~ : Option[T]) -> Int {
  match o {
    Some(_) => 1
    None => 2
  }
}

pub fn inner[T](v : T) -> Int {
  keep(o=None, x=id(v)) * 10 + Map([(id(7), v)]).length()
}

pub fn lit[T](v : T) -> Int {
  let m = Map([(Key::{ a: 1, b: 2 }, id(v)), (Key::{ a: 3, b: 4 }, v)])
  let n = Map(pairs("k", v))
  m.length() * 10 + n.length()
}

pub fn fixed() -> Int {
  let m = Map(pairs(id(5), "five"))
  match m.get(5) {
    Some(s) => s.length()
    None => -1
  }
}
EOF
cat > "$APP/pion.toml" <<EOF
[package]
name = "mapapp"
version = "0.1.0"

[dependencies]
maplib = { path = "$LIB" }
EOF
cat > "$APP/src/main.pion" <<'EOF'
import "maplib" as l

fn id[T](x : T) -> T {
  x
}

pub fn main(w : World) -> Int {
  io_println(w, "\{l::keep(o=None, x=id("s"))} \{l::keep(o=None, x=id(1))} \{l::inner("a")} \{l::inner(3)} \{l::lit("a")} \{l::lit([1])} \{l::fixed()}")
  0
}
EOF
XWANT="2 2 21 21 21 21 4"
for round in cold warm; do
  XDEV="$("$PIONC" run "$APP")"
  XREL="$("$PIONC" run --release "$APP")"
  if [ "$XDEV" != "$XWANT" ] || [ "$XREL" != "$XWANT" ]; then
    echo "FAIL: p101 cross-package ($round) dev=$XDEV release=$XREL want=$XWANT" >&2
    exit 1
  fi
  printf '\nfn unused_%s() -> Int {\n  0\n}\n' "$round" >> "$APP/src/main.pion"
done
echo "p101 cross-package ok"

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
