#!/bin/sh
# P107: Regression suite for qbe.pion & types.pion codegen fixes:
#   1. Default parameter scope isolation (prior param, early-return mut writeback & RC,
#      TCO fallback, stack-view UAF guard, generic `T` annotation, cross-pkg fn shadowing).
#   2a. Default parameter referencing prior optional parameter (`a?`).
#   2b. Transitive generic `Map(xs.copy())` monomorphization (`wrap[J] -> mk[K]`).
#   3a/3b. Early `return` / `?` RC cleanup (0 leaks / 0 UAF / 0 double-free under ASan/LSan).
#   4. Trait & dyn Trait methods with labelled params (`w~`/`h~`) called positionally.
#   5. Generic flat struct arrays (`Array[Pair[Int, Int]]` keeps flat 16B stride in SSA) +
#      polymorphic generic functions (`get_first`/`get_second`/`push_and_set_pair`).
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DIR="$ROOT_DIR/tests/e2e/p107_qbe_codegen_fixes"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

check() {
  if ! diff -u "$DIR/expected.txt" "$2"; then
    echo "FAIL: p107 $1" >&2
    exit 1
  fi
  echo "p107 $1 ok"
}

SRC="$DIR/p107.pion"

# 1. SSA flat-array stride preservation for generic struct Array[Pair[Int, Int]]
"$PIONC" build --release --emit-ssa "$TMP_DIR/p107.ssa" "$SRC"
python3 - "$TMP_DIR/p107.ssa" <<'PYEOF'
import sys, re
ssa = open(sys.argv[1]).read()
m = re.search(r"function [^\n]*\$[^\s(]*make_flat_int_pairs\([^\n]*\)\s*\{(.*?)\n\}", ssa, re.S)
assert m, "make_flat_int_pairs not found in SSA"
body = m.group(1)
assert "$pion_arr_new(l 0, w 16)" in body, f"Array[Pair[Int, Int]] lost 16B flat stride:\n{body}"
print("p107 SSA generic flat stride ok (w 16)")

# Verify swapped generic default-arg closure in flip_swapped[A, B] -> keep_swapped(b, a)
# retains and releases the captured `x` under the SAME caller flag (`%tp_B`, not `%tp_A`).
mf = re.search(r"function [^\n]*\$[^\s(]*flip_swapped\([^\n]*\)\s*\{(.*?)\n\}", ssa, re.S)
assert mf, "flip_swapped not found in SSA"
fbody = mf.group(1)
dm = re.search(r"call \$pion_alloc_uninit\(w \d+, w 6, l (\$pion_drop_clo_\d+)\)", fbody)
assert dm, f"flip_swapped closure alloc/drop not found:\n{fbody}"
drop_sym = dm.group(1)
# Capture retain before store into env must test %tp_B (never %tp_A)
alloc_pos = dm.start()
after_alloc = fbody[alloc_pos:]
m_rci = re.search(r"jnz (%tp_[AB]), @rci_do_", after_alloc)
assert m_rci and m_rci.group(1) == "%tp_B", f"expected retain jnz %tp_B in flip_swapped, got {m_rci and m_rci.group(1)}:\n{after_alloc}"
# Find which env offset %tp_B is stored at in flip_swapped
m_tpb_off = re.search(r"(%t\d+) =l add %t\d+, (\d+)\n\s*storel %tp_B, \1", after_alloc)
assert m_tpb_off, f"%tp_B env store not found in flip_swapped:\n{after_alloc}"
tpb_off = m_tpb_off.group(2)
# Destructor must load the flag from that exact same offset (tpb_off)
md = re.search(r"function " + re.escape(drop_sym) + r"\(l %p\)\s*\{(.*?)\n\}", ssa, re.S)
assert md, f"{drop_sym} not found in SSA"
dbody = md.group(1)
assert f"=l add %p, {tpb_off}\n" in dbody, f"{drop_sym} did not check %tp_B offset {tpb_off}:\n{dbody}"
print(f"p107 SSA flip_swapped retain+drop %tp_B parity ok (offset {tpb_off}, {drop_sym})")
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
  echo "NOTE: node unavailable; skipping p107 Wasm32 checks"
fi

# 4. ASan/LSan (dev & --release)
CC_BIN="${CC:-cc}"
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  for MODE in "" --release; do
    "$PIONC" build $MODE --emit-obj "$TMP_DIR/p107.o" "$SRC"
    "$CC_BIN" -fsanitize=address "$TMP_DIR/p107.o" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/p107_asan"
    "$TMP_DIR/p107_asan" > "$TMP_DIR/asan.out"
    check "ASan/LSan ${MODE:-dev}" "$TMP_DIR/asan.out"
  done
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p107 ASan check"
fi

# 5. Cross-package default param:
#    - prior param `x` not hijacked by dep's `fn x()`;
#    - type annotations (`let v : Reading = x`, `Array[Reading]`, closure param `(r : Reading)`) resolve in dep's package;
#    - private trait `dyn Meter`, private struct `Small::{ n: 8 }; s.n`, and `if/guard` `is Some(v)` bindings
#      work in dep's default params across Native & Wasm32 dev/release while caller visibility stays enforced.
mkdir -p "$TMP_DIR/xpkg/dep/src" "$TMP_DIR/xpkg/app/src"
cat > "$TMP_DIR/xpkg/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/xpkg/dep/src/lib.pion" <<'EOF'
fn x() -> Int { 99 }
pub fn pick(x : Int, y~ : Int = x) -> Int { x + y }

pub struct Reading {
  value : Int
}

pub fn pick_typed(
  x : Reading,
  y~ : Int = {
    let v : Reading = x
    let arr : Array[Reading] = [v]
    let f = fn(r : Reading) -> Int { r.value }
    f(arr[0])
  },
) -> Int {
  y
}

pub fn control_typed(x : Reading) -> Int {
  pick_typed(x)
}

trait Meter {
  fn size(self : Self) -> Int
}

pub struct PubSmall {
  n : Int
}

impl Meter for PubSmall {
  fn size(self : PubSmall) -> Int { self.n }
}

pub fn pick_priv_dyn(
  y~ : Int = {
    let m : dyn Meter = PubSmall::{ n: 8 }
    m.size()
  },
) -> Int {
  y
}

struct Small {
  n : Int
}

pub fn pick_priv_struct(
  y~ : Int = {
    let s : Small = Small::{ n: 8 }
    s.n
  },
) -> Int {
  y
}

fn v() -> Int { 99 }

pub fn pick_is_if(
  x : Option[Int],
  y~ : Int = if x is Some(v) { v } else { 0 },
) -> Int {
  y
}

pub fn pick_is_guard(
  x : Option[Int],
  y~ : Int = {
    guard x is Some(v) else { return 0 }
    v
  },
) -> Int {
  y
}

pub struct Choice {
  n : Int
}

pub fn Choice::step(
  self : Choice,
  go : Bool,
  y~ : Int = if go { return 7 } else { 2 },
) -> Int {
  self.n + y
}

pub fn mid_choice(r : Choice, go : Bool, y~ : Int = r.step(go)) -> Int {
  y
}
EOF
cat > "$TMP_DIR/xpkg/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/xpkg/app/src/main.pion" <<'EOF'
import "dep" as d
fn call_is_guard(x : Option[Int]) -> Int {
  d::pick_is_guard(x)
}
fn outer_choice(go : Bool) -> Int {
  d::mid_choice(d::Choice::{ n: 0 }, go) + 10
}
fn call_choice(mut n : Int, go : Bool) -> Int {
  let answer = outer_choice(go)
  n = n + 1
  100 + answer
}
fn main(w : World) -> Unit {
  let x = 777
  let _ = x
  let r = d::Reading::{ value: 5 }
  let mut cn = 0
  let c1 = call_choice(mut cn, true)
  let c2 = call_choice(mut cn, false)
  io_println(
    w,
    d::pick(5).to_string() +
    "," +
    d::pick_typed(r).to_string() +
    "," +
    d::control_typed(r).to_string() +
    "," +
    d::pick_priv_dyn().to_string() +
    "," +
    d::pick_priv_struct().to_string() +
    "," +
    d::pick_is_if(Some(5)).to_string() +
    "," +
    call_is_guard(Some(5)).to_string() +
    "," +
    call_is_guard(None).to_string() +
    "," +
    c1.to_string() +
    "," +
    c2.to_string() +
    "," +
    cn.to_string(),
  )
}
EOF
XPKG_EXP="10,5,5,8,8,5,5,0,107,112,2"
XPKG_DEV="$("$PIONC" run "$TMP_DIR/xpkg/app")"
XPKG_REL="$("$PIONC" run --release "$TMP_DIR/xpkg/app")"
if [ "$XPKG_DEV" != "$XPKG_EXP" ] || [ "$XPKG_REL" != "$XPKG_EXP" ]; then
  echo "FAIL: p107 cross-pkg default param expected $XPKG_EXP, got dev='$XPKG_DEV' rel='$XPKG_REL'" >&2
  exit 1
fi
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/xpkg_dev.wasm" "$TMP_DIR/xpkg/app"
  XPKG_WDEV="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/xpkg_dev.wasm")"
  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/xpkg_rel.wasm" "$TMP_DIR/xpkg/app"
  XPKG_WREL="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/xpkg_rel.wasm")"
  if [ "$XPKG_WDEV" != "$XPKG_EXP" ] || [ "$XPKG_WREL" != "$XPKG_EXP" ]; then
    echo "FAIL: p107 cross-pkg wasm32 expected $XPKG_EXP, got dev='$XPKG_WDEV' rel='$XPKG_WREL'" >&2
    exit 1
  fi
fi
if [ -f "$TMP_DIR/libpionrt_asan.a" ]; then
  cat > "$TMP_DIR/cc_asan.sh" <<EOF
#!/bin/sh
exec "$CC_BIN" -fsanitize=address "\$@"
EOF
  chmod +x "$TMP_DIR/cc_asan.sh"
  for MODE in "" --release; do
    CC="$TMP_DIR/cc_asan.sh" PION_RT_LIB="$TMP_DIR/libpionrt_asan.a" "$PIONC" build $MODE -o "$TMP_DIR/xpkg_app_asan" "$TMP_DIR/xpkg/app"
    XPKG_ASAN="$("$TMP_DIR/xpkg_app_asan")"
    if [ "$XPKG_ASAN" != "$XPKG_EXP" ]; then
      echo "FAIL: p107 cross-pkg ASan/LSan ${MODE:-dev} expected $XPKG_EXP, got '$XPKG_ASAN'" >&2
      exit 1
    fi
  done
  echo "p107 cross-pkg ASan/LSan (dev & release) ok"
fi

# 6. Negative visibility check: caller must still be rejected for private struct literal & private dyn trait
mkdir -p "$TMP_DIR/xpkg/bad_struct/src" "$TMP_DIR/xpkg/bad_trait/src"
cat > "$TMP_DIR/xpkg/bad_struct/pion.toml" <<'EOF'
[package]
name = "bad_struct"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/xpkg/bad_struct/src/main.pion" <<'EOF'
import "dep" as d
fn main(w : World) -> Unit {
  let _ = d::Small::{ n: 8 }
  let _ = w
}
EOF
if "$PIONC" check "$TMP_DIR/xpkg/bad_struct" >/dev/null 2>&1; then
  echo "FAIL: p107 expected private struct literal d::Small::{ n: 8 } to be rejected" >&2
  exit 1
fi

cat > "$TMP_DIR/xpkg/bad_trait/pion.toml" <<'EOF'
[package]
name = "bad_trait"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/xpkg/bad_trait/src/main.pion" <<'EOF'
import "dep" as d
fn main(w : World) -> Unit {
  let _ : dyn d::Meter = d::PubSmall::{ n: 8 }
  let _ = w
}
EOF
if "$PIONC" check "$TMP_DIR/xpkg/bad_trait" >/dev/null 2>&1; then
  echo "FAIL: p107 expected private dyn trait d::Meter to be rejected" >&2
  exit 1
fi
echo "p107 cross-pkg default param (shadow + type annotations + priv dyn/struct + is-bindings + visibility reject, native + wasm32) ok"

echo "PASS: p107_qbe_codegen_fixes"
