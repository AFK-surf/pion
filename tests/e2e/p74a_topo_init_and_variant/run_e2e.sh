#!/usr/bin/env sh
# P74-A E2E: Topological cross-package *_init_consts ordering (native/release/staticlib/test/wasm32)
#            + E_UNKNOWN_VARIANT compile-time checks + Enum::method positive check.
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc_linux}"
if [ ! -x "$PIONC" ] && [ -x "$ROOT_DIR/out/pionc2" ]; then
  PIONC="$ROOT_DIR/out/pionc2"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

echo "=== P74-A E2E: Topo *_init_consts + E_UNKNOWN_VARIANT ==="

# ----------------------------------------------------------------------------
# 1. 3-package workspace: alpha (lexicographically < zeta!) depends on zeta;
#    app depends on alpha. Both alpha & app read zeta's top-level const store.
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/ws/zeta/src" "$TMP_DIR/ws/alpha/src" "$TMP_DIR/ws/app/src"

cat > "$TMP_DIR/ws/zeta/pion.toml" <<'EOF'
[package]
name = "zeta"
version = "0.1.0"
EOF
cat > "$TMP_DIR/ws/zeta/src/lib.pion" <<'EOF'
let ZETA_STORE : Array[Int] = [42]

pub fn read_zeta() -> Int {
  ZETA_STORE[0]
}
EOF

cat > "$TMP_DIR/ws/alpha/pion.toml" <<'EOF'
[package]
name = "alpha"
version = "0.1.0"

[dependencies]
zeta = { path = "../zeta" }
EOF
cat > "$TMP_DIR/ws/alpha/src/lib.pion" <<'EOF'
import "zeta"

pub let ALPHA_VAL : Int = zeta::read_zeta() + 1

pub fn get_alpha() -> Int {
  ALPHA_VAL
}
EOF
cat > "$TMP_DIR/ws/alpha/src/alpha_test.pion" <<'EOF'
test "alpha_init_topo" {
  debug_assert(get_alpha() == 43, "alpha const should see initialized zeta store")
}
EOF

cat > "$TMP_DIR/ws/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
alpha = { path = "../alpha" }
EOF
cat > "$TMP_DIR/ws/app/src/main.pion" <<'EOF'
import "alpha"

extern "C" fn app_get_val() -> Int {
  alpha::get_alpha()
}

pub fn main(world : World) -> Int {
  io_println(world, alpha::get_alpha().to_string())
  0
}
EOF
cat > "$TMP_DIR/ws/app/src/app_test.pion" <<'EOF'
test "app_init_topo" {
  debug_assert(alpha::get_alpha() == 43, "app test should see initialized alpha & zeta")
}
EOF

# 1a. pionc build (dev)
"$PIONC" build -o "$TMP_DIR/ws/app_dev" "$TMP_DIR/ws/app"
OUT_DEV="$("$TMP_DIR/ws/app_dev")"
echo "1a. dev build -> $OUT_DEV"
[ "$OUT_DEV" = "43" ]

# 1b. pionc build --release
"$PIONC" build --release -o "$TMP_DIR/ws/app_rel" "$TMP_DIR/ws/app"
OUT_REL="$("$TMP_DIR/ws/app_rel")"
echo "1b. release build -> $OUT_REL"
[ "$OUT_REL" = "43" ]

# 1c. pionc build --emit-staticlib --no-main + C harness
"$PIONC" build --release --emit-staticlib "$TMP_DIR/ws/libapp.a" --no-main "$TMP_DIR/ws/app"
cat > "$TMP_DIR/ws/harness.c" <<'EOF'
#include <stdio.h>
#include <stdint.h>
extern void pion_pkg_app_init_consts(void);
extern int64_t app_get_val(void);
int main(void) {
  pion_pkg_app_init_consts();
  printf("%lld\n", (long long)app_get_val());
  return 0;
}
EOF
CC_BIN="${CC:-cc}"
RT_LIB="${PION_RT_LIB:-$ROOT_DIR/out/libpionrt.a}"
"$CC_BIN" "$TMP_DIR/ws/harness.c" "$TMP_DIR/ws/libapp.a" "$RT_LIB" -lm -lpthread -o "$TMP_DIR/ws/harness"
OUT_SLIB="$("$TMP_DIR/ws/harness")"
echo "1c. staticlib --no-main -> $OUT_SLIB"
[ "$OUT_SLIB" = "43" ]

# 1d. pionc test --deps (runs both alpha_test and app_test)
TEST_JSON="$("$PIONC" test --deps --json "$TMP_DIR/ws/app")"
echo "1d. pionc test -> $TEST_JSON"
printf '%s' "$TEST_JSON" | grep -q '"ok":true'
printf '%s' "$TEST_JSON" | grep -q '"failed":0'

# 1e. wasm32 (Node)
if command -v node >/dev/null 2>&1; then
  OUT_WASM="$("$PIONC" run --release --target wasm32 "$TMP_DIR/ws/app")"
  echo "1e. wasm32 -> $OUT_WASM"
  [ "$OUT_WASM" = "43" ]
fi

# ----------------------------------------------------------------------------
# 2. E_UNKNOWN_VARIANT negative checks + pkg::Enum::method positive check
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/ev/rlib/src" "$TMP_DIR/ev/ok_app/src"
cat > "$TMP_DIR/ev/rlib/pion.toml" <<'EOF'
[package]
name = "rlib"
version = "0.1.0"
EOF
cat > "$TMP_DIR/ev/rlib/src/lib.pion" <<'EOF'
pub enum Kind {
  A
  B(Int)
}

pub fn Kind::score(self : Kind) -> Int {
  match self {
    A => 10
    B(n) => n
  }
}
EOF

cat > "$TMP_DIR/ev/ok_app/pion.toml" <<'EOF'
[package]
name = "ok_app"
version = "0.1.0"

[dependencies]
rlib = { path = "../rlib" }
EOF
cat > "$TMP_DIR/ev/ok_app/src/main.pion" <<'EOF'
import "rlib"

pub fn main(world : World) -> Int {
  let f : (rlib::Kind) -> Int = rlib::Kind::score
  let v = f(rlib::Kind::B(7)) + rlib::Kind::score(rlib::Kind::A)
  io_println(world, v.to_string())
  0
}
EOF
"$PIONC" build --release -o "$TMP_DIR/ev/ok_bin" "$TMP_DIR/ev/ok_app"
OUT_OK="$("$TMP_DIR/ev/ok_bin")"
echo "2a. pkg::Enum::method positive -> $OUT_OK"
[ "$OUT_OK" = "17" ]

check_unknown_variant() {
  label="$1"
  src="$2"
  mkdir -p "$TMP_DIR/ev/bad_$label/src"
  cat > "$TMP_DIR/ev/bad_$label/pion.toml" <<EOF
[package]
name = "bad_$label"
version = "0.1.0"

[dependencies]
rlib = { path = "../rlib" }
EOF
  printf '%s\n' "$src" > "$TMP_DIR/ev/bad_$label/src/main.pion"
  if "$PIONC" check --json "$TMP_DIR/ev/bad_$label" > "$TMP_DIR/ev/bad_$label.json"; then
    echo "FAIL: case $label should fail check with E_UNKNOWN_VARIANT" >&2
    exit 1
  fi
  if ! grep -q "E_UNKNOWN_VARIANT" "$TMP_DIR/ev/bad_$label.json"; then
    echo "FAIL: case $label missing E_UNKNOWN_VARIANT: $(cat "$TMP_DIR/ev/bad_$label.json")" >&2
    exit 1
  fi
}

check_unknown_variant "local_call" 'enum E { A }
pub fn main() -> Int { let _ = E::Bogus(1)
 0 }'
check_unknown_variant "local_unit" 'enum E { A }
pub fn main() -> Int { let _ = E::Bogus
 0 }'
check_unknown_variant "xpkg_call" 'import "rlib"
pub fn main() -> Int { let _ = rlib::Kind::Bogus(1)
 0 }'
check_unknown_variant "xpkg_unit" 'import "rlib"
pub fn main() -> Int { let _ = rlib::Kind::Bogus
 0 }'
check_unknown_variant "opt_bogus" 'pub fn main() -> Int { let _ = Option::Bogus
 0 }'
check_unknown_variant "res_bogus" 'pub fn main() -> Int { let _ = Result::Bogus(1)
 0 }'
check_unknown_variant "match_bogus" 'import "rlib"
pub fn f(k : rlib::Kind) -> Int { match k { Bogus => 1
 _ => 0 } }
pub fn main() -> Int { f(rlib::Kind::A) }'
check_unknown_variant "is_bogus" 'import "rlib"
pub fn main() -> Int { if rlib::Kind::A is Bogus { 1 } else { 0 } }'

echo "2b. E_UNKNOWN_VARIANT 8 negative cases -> OK"

# ---------------------------------------------------------------------------
# 3. P74-B: Wasm32 multi-package shared-CAS sibling isolation regression
#    combo -> {sib_a, sib_b}, solo_b -> {sib_b}.
#    sib_b's cached CAS .ssa must NOT call sib_a's init_consts.
# ---------------------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
  mkdir -p "$TMP_DIR/wcas/sib_a/src" "$TMP_DIR/wcas/sib_b/src" \
           "$TMP_DIR/wcas/combo/src" "$TMP_DIR/wcas/solo_b/src"

  cat > "$TMP_DIR/wcas/sib_a/pion.toml" <<'EOF'
[package]
name = "sib_a"
version = "0.1.0"
EOF
  cat > "$TMP_DIR/wcas/sib_a/src/lib.pion" <<'EOF'
let A_STORE : Array[Int] = [10]

pub fn val_a() -> Int {
  A_STORE[0]
}
EOF

  cat > "$TMP_DIR/wcas/sib_b/pion.toml" <<'EOF'
[package]
name = "sib_b"
version = "0.1.0"
EOF
  cat > "$TMP_DIR/wcas/sib_b/src/lib.pion" <<'EOF'
let B_STORE : Array[Int] = [20]

pub fn val_b() -> Int {
  B_STORE[0]
}
EOF

  cat > "$TMP_DIR/wcas/combo/pion.toml" <<'EOF'
[package]
name = "combo"
version = "0.1.0"

[dependencies]
sib_a = { path = "../sib_a" }
sib_b = { path = "../sib_b" }
EOF
  cat > "$TMP_DIR/wcas/combo/src/main.pion" <<'EOF'
import "sib_a"
import "sib_b"

pub fn main(world : World) -> Int {
  io_println(world, (sib_a::val_a() + sib_b::val_b()).to_string())
  0
}
EOF

  cat > "$TMP_DIR/wcas/solo_b/pion.toml" <<'EOF'
[package]
name = "solo_b"
version = "0.1.0"

[dependencies]
sib_b = { path = "../sib_b" }
EOF
  cat > "$TMP_DIR/wcas/solo_b/src/main.pion" <<'EOF'
import "sib_b"

pub fn main(world : World) -> Int {
  io_println(world, sib_b::val_b().to_string())
  0
}
EOF

  SHARED_CAS="$TMP_DIR/wcas_shared_cas"
  mkdir -p "$SHARED_CAS"

  for mode in release dev; do
    if [ "$mode" = "release" ]; then
      combo_out="$(PION_CACHE_DIR="$SHARED_CAS" "$PIONC" run --release --target wasm32 "$TMP_DIR/wcas/combo")"
      solo_out="$(PION_CACHE_DIR="$SHARED_CAS" PION_TRACE_CAS=1 "$PIONC" run --release --target wasm32 "$TMP_DIR/wcas/solo_b" 2>"$TMP_DIR/wcas/solo_${mode}.err")"
    else
      combo_out="$(PION_CACHE_DIR="$SHARED_CAS" "$PIONC" run --target wasm32 "$TMP_DIR/wcas/combo")"
      solo_out="$(PION_CACHE_DIR="$SHARED_CAS" PION_TRACE_CAS=1 "$PIONC" run --target wasm32 "$TMP_DIR/wcas/solo_b" 2>"$TMP_DIR/wcas/solo_${mode}.err")"
    fi
    if [ "$combo_out" != "30" ]; then
      echo "FAIL: wasm32 shared-CAS combo ($mode) expected 30, got '$combo_out'" >&2
      exit 1
    fi
    if [ "$solo_out" != "20" ]; then
      echo "FAIL: wasm32 shared-CAS solo_b ($mode) expected 20, got '$solo_out'" >&2
      exit 1
    fi
    if ! grep -q "\[cas-wasm\] pkg=sib_b HIT" "$TMP_DIR/wcas/solo_${mode}.err"; then
      echo "FAIL: wasm32 shared-CAS solo_b ($mode) expected sib_b CAS HIT, stderr:" >&2
      cat "$TMP_DIR/wcas/solo_${mode}.err" >&2
      exit 1
    fi
  done

  sib_b_ssa_count=0
  for f in "$SHARED_CAS"/ssa/*.ssa; do
    if grep -q "pion_pkg_sib_b_init_consts" "$f" && \
       ! grep -q "pion_pkg_combo_init_consts" "$f" && \
       ! grep -q "pion_pkg_solo_b_init_consts" "$f"; then
      sib_b_ssa_count=$((sib_b_ssa_count + 1))
      if grep -q "pion_pkg_sib_a_init_consts" "$f"; then
        echo "FAIL: sib_b cached CAS .ssa ($f) is polluted by sibling sib_a init_consts" >&2
        exit 1
      fi
    fi
  done
  if [ "$sib_b_ssa_count" -lt 2 ]; then
    echo "FAIL: expected >=2 sib_b cached CAS .ssa files (release + dev), found $sib_b_ssa_count" >&2
    exit 1
  fi
  echo "3. Wasm32 shared-CAS sibling isolation (release + dev, $sib_b_ssa_count sib_b .ssa clean) -> OK"
else
  echo "3. Wasm32 shared-CAS sibling isolation -> SKIP (no node)"
fi

echo "PASS: p74a_topo_init_and_variant"
