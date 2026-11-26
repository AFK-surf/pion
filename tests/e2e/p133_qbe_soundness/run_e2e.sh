#!/bin/sh
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
export PION_CACHE_DIR="$CAS_DIR"

# =====================================================================
# P133: QBE Soundness 4-Mode Matrix
# 1. Local generic `impl[T : Eq] Eq for BytesBox[T]` calling cross-pkg `dep::bytes_eq`
# 2. Same-alias-different-pkg sentinels (local->imported default, imported mono->own default,
#    imported->root trait impl default, nested default + caller sentinel after return,
#    explicit vs omitted default inlined & non-inlined, call count & eval order,
#    source alias colliding with another canonical package name)
# 3. Frontend negative test (private/missing symbol reports frontend diag, no ICE)
# =====================================================================
WS="$TMP_DIR/ws"
mkdir -p \
  "$WS/pkg_root_a/src" \
  "$WS/pkg_dep_a/src" \
  "$WS/pkg_collide/src" \
  "$WS/dep_mid/src" \
  "$WS/app/src"

cat > "$WS/pkg_root_a/pion.toml" <<'EOF'
[package]
name = "pkg_root_a"
version = "0.1.0"
EOF

cat > "$WS/pkg_root_a/src/lib.pion" <<'EOF'
pub let SENTINEL_CONST : Int = 1001

pub enum SentinelTag {
  TagA
  TagB
}

pub fn sentinel_fn() -> Int {
  101
}

pub fn sentinel_tag_val(t : SentinelTag) -> Int {
  match t {
    SentinelTag::TagA => 11
    SentinelTag::TagB => 12
  }
}

pub fn bytes_eq(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

fn private_secret() -> Int {
  999
}
EOF

cat > "$WS/pkg_dep_a/pion.toml" <<'EOF'
[package]
name = "pkg_dep_a"
version = "0.1.0"
EOF

cat > "$WS/pkg_dep_a/src/lib.pion" <<'EOF'
pub let SENTINEL_CONST : Int = 2002

pub enum SentinelTag {
  TagA
  TagB
}

pub fn sentinel_fn() -> Int {
  202
}

pub fn sentinel_tag_val(t : SentinelTag) -> Int {
  match t {
    SentinelTag::TagA => 21
    SentinelTag::TagB => 22
  }
}
EOF

cat > "$WS/pkg_collide/pion.toml" <<'EOF'
[package]
name = "pkg_collide"
version = "0.1.0"
EOF

cat > "$WS/pkg_collide/src/lib.pion" <<'EOF'
pub let SENTINEL_CONST : Int = 3003

pub fn sentinel_fn() -> Int {
  303
}
EOF

cat > "$WS/dep_mid/pion.toml" <<'EOF'
[package]
name = "dep_mid"
version = "0.1.0"

[dependencies]
pkg_dep_a = { path = "../pkg_dep_a" }
pkg_collide = { path = "../pkg_collide" }
EOF

cat > "$WS/dep_mid/src/lib.pion" <<'EOF'
import "pkg_dep_a" as s
import "pkg_dep_a" as pkg_collide

pub enum LocalMidEnum {
  MidA
  MidB
}

pub fn mid_enum_code(e : LocalMidEnum) -> Int {
  match e {
    LocalMidEnum::MidA => 71
    LocalMidEnum::MidB => 72
  }
}

pub fn inlined_default(x : Int = s::sentinel_fn()) -> Int {
  x + 1
}

pub fn non_inlined_default(
  a : Int = s::sentinel_fn(),
  b : Int = s::SENTINEL_CONST,
  c : Int = s::sentinel_tag_val(s::SentinelTag::TagA),
  d : Int = pkg_collide::sentinel_fn(),
  e : LocalMidEnum = LocalMidEnum::MidA,
) -> Int {
  let mut acc = 0
  let mut i = 0
  while i < 3 {
    acc = acc + i
    i = i + 1
  }
  a + b + c + d + mid_enum_code(e) + acc
}

pub fn mono_with_default[T : Eq](
  lhs : T,
  rhs : T,
  tag : Int = s::sentinel_fn() + pkg_collide::sentinel_fn(),
) -> Int {
  if lhs == rhs {
    tag
  } else {
    -1
  }
}

pub fn trace_default(
  log : Array[Int],
  a : Int = {
    log.push(s::sentinel_fn())
    s::sentinel_fn()
  },
  b : Int = {
    log.push(pkg_collide::sentinel_fn() + 1)
    pkg_collide::sentinel_fn() + 1
  },
) -> Int {
  log.push(900)
  a * 1000 + b
}

pub trait ProbeTrait {
  fn probe(self : Self, v : Int = s::sentinel_fn()) -> Int
}

pub fn run_trait_probe[T : ProbeTrait](x : T) -> Int {
  x.probe()
}
EOF

cat > "$WS/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
pkg_root_a = { path = "../pkg_root_a" }
pkg_collide = { path = "../pkg_collide" }
dep_mid = { path = "../dep_mid" }
EOF

cat > "$WS/app/src/main.pion" <<'EOF'
import "pkg_root_a" as s
import "pkg_collide"
import "dep_mid"

pub struct BytesBox[T] {
  pub tag : T
  pub data : Bytes
}

impl[T : Eq] Eq for BytesBox[T] {
  fn equal(self : BytesBox[T], other : BytesBox[T]) -> Bool {
    self.tag == other.tag && s::bytes_eq(self.data, other.data)
  }
}

pub struct LocalCarrier {
  pub base : Int
}

impl dep_mid::ProbeTrait for LocalCarrier {
  fn probe(self : LocalCarrier, v : Int = s::sentinel_fn()) -> Int {
    self.base + v
  }
}

fn local_nested_default(
  x : Int = dep_mid::inlined_default(),
  y : Int = s::sentinel_fn(),
) -> Int {
  x * 1000 + y
}

pub fn main(world : World) -> Int {
  // 1. Original repro: local generic impl[T : Eq] Eq calling cross-pkg bytes_eq
  let b1 = BytesBox::{ tag: 7, data: "pion".to_bytes() }
  let b2 = BytesBox::{ tag: 7, data: "pion".to_bytes() }
  let b3 = BytesBox::{ tag: 7, data: "diff".to_bytes() }
  let eq_same = b1 == b2
  let eq_diff = b1 == b3

  // 2a. Local -> imported default (inlined & non-inlined, plus alias colliding with pkg_collide)
  let inl_def = dep_mid::inlined_default()
  let inl_exp = dep_mid::inlined_default(x=s::sentinel_fn())
  let non_inl_def = dep_mid::non_inlined_default()
  let non_inl_exp = dep_mid::non_inlined_default(a=1, b=2, c=3, d=4, e=dep_mid::LocalMidEnum::MidB)

  // 2b. Imported mono -> its own default arg
  let mono_def = dep_mid::mono_with_default(b1, b2)
  let mono_exp = dep_mid::mono_with_default(b1, b2, tag=pkg_collide::sentinel_fn())

  // 2c. Imported generic -> root-pkg trait impl default arg (must restore mono_pkg to root!)
  let carrier = LocalCarrier::{ base: 10 }
  let trait_def = dep_mid::run_trait_probe(carrier)

  // 2d. Nested default call reading caller sentinel after return
  let nested = local_nested_default()
  let after_caller = s::sentinel_fn() + pkg_collide::sentinel_fn()

  // 2e. Call count and evaluation order (omitted vs explicit)
  let log_def : Array[Int] = []
  let tr_def = dep_mid::trace_default(log_def)
  let log_exp : Array[Int] = []
  let tr_exp = dep_mid::trace_default(
    log_exp,
    a={
      log_exp.push(s::sentinel_fn())
      s::sentinel_fn()
    },
    b={
      log_exp.push(pkg_collide::sentinel_fn())
      pkg_collide::sentinel_fn()
    },
  )

  let out =
    "eq=" + eq_same.to_string() + "," + eq_diff.to_string() +
    " inl=" + inl_def.to_string() + "," + inl_exp.to_string() +
    " noninl=" + non_inl_def.to_string() + "," + non_inl_exp.to_string() +
    " mono=" + mono_def.to_string() + "," + mono_exp.to_string() +
    " trait=" + trait_def.to_string() +
    " nested=" + nested.to_string() +
    " after=" + after_caller.to_string() +
    " trdef=" + tr_def.to_string() + ":" + log_def.length().to_string() + ":" + log_def[0].to_string() + "," + log_def[1].to_string() + "," + log_def[2].to_string() +
    " trexp=" + tr_exp.to_string() + ":" + log_exp.length().to_string() + ":" + log_exp[0].to_string() + "," + log_exp[1].to_string() + "," + log_exp[2].to_string()
  io_println(world, out)
  0
}
EOF

EXPECTED="eq=true,false inl=203,102 noninl=2501,85 mono=404,303 trait=111 nested=203101 after=404 trdef=202203:3:202,203,900 trexp=101303:3:101,303,900"

# Mode 1: Native dev
"$PIONC" build -o "$TMP_DIR/app_dev" "$WS/app"
OUT_DEV="$("$TMP_DIR/app_dev")"
echo "p133 native dev:     $OUT_DEV"
[ "$OUT_DEV" = "$EXPECTED" ] || { echo "FAIL native dev: expected '$EXPECTED', got '$OUT_DEV'" >&2; exit 1; }

# Mode 2: Native release
"$PIONC" build --release -o "$TMP_DIR/app_rel" "$WS/app"
OUT_REL="$("$TMP_DIR/app_rel")"
echo "p133 native release: $OUT_REL"
[ "$OUT_REL" = "$EXPECTED" ] || { echo "FAIL native release: expected '$EXPECTED', got '$OUT_REL'" >&2; exit 1; }

# Mode 3 & 4: Wasm32 dev & release
if command -v node >/dev/null 2>&1; then
  "$PIONC" build --target wasm32 -o "$TMP_DIR/app_dev.wasm" "$WS/app"
  OUT_WDEV="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/app_dev.wasm")"
  echo "p133 wasm32 dev:     $OUT_WDEV"
  [ "$OUT_WDEV" = "$EXPECTED" ] || { echo "FAIL wasm32 dev: expected '$EXPECTED', got '$OUT_WDEV'" >&2; exit 1; }

  "$PIONC" build --release --target wasm32 -o "$TMP_DIR/app_rel.wasm" "$WS/app"
  OUT_WREL="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$TMP_DIR/app_rel.wasm")"
  echo "p133 wasm32 release: $OUT_WREL"
  [ "$OUT_WREL" = "$EXPECTED" ] || { echo "FAIL wasm32 release: expected '$EXPECTED', got '$OUT_WREL'" >&2; exit 1; }
fi

# Frontend negative test: private/missing qualified symbol must report frontend diagnostic (not ICE)
mkdir -p "$TMP_DIR/neg/src"
cat > "$TMP_DIR/neg/pion.toml" <<'EOF'
[package]
name = "neg"
version = "0.1.0"

[dependencies]
pkg_root_a = { path = "../ws/pkg_root_a" }
EOF
cat > "$TMP_DIR/neg/src/main.pion" <<'EOF'
import "pkg_root_a" as s

pub fn main(_world : World) -> Int {
  s::private_secret() + s::does_not_exist()
}
EOF
set +e
NEG_OUT="$("$PIONC" check --json "$TMP_DIR/neg" 2>&1)"
NEG_RC=$?
set -e
echo "p133 frontend neg rc=$NEG_RC"
[ "$NEG_RC" -ne 0 ] || { echo "FAIL: expected frontend check error on private/missing symbol" >&2; exit 1; }
printf '%s' "$NEG_OUT" | grep -q '"ok":false' || { echo "FAIL: expected JSON ok:false, got: $NEG_OUT" >&2; exit 1; }
if printf '%s' "$NEG_OUT" | grep -q 'ICE:'; then
  echo "FAIL: frontend error triggered ICE instead of diagnostic: $NEG_OUT" >&2
  exit 1
fi

# Backend missing-binding ICE test: clean TypeChecker (0 diagnostics) with an
# unresolved qualified call must fail closed with an ICE panic, never silent 0.
cat > "$TMP_DIR/ice_probe.pion" <<'EOF'
pub fn main(_world : World) -> Int {
  let cr = check_source_files_full("ice_root", ["ok.pion"], ["pub fn ok() -> Int { 1 }\n"])
  let bad_pkg = parse_package("ice_root", ["bad.pion"], ["pub fn ok() -> Int { ghost_pkg::ghost_fn() }\n"])
  let _ = emit_qbe_package_with_tc(bad_pkg, cr.tc, false)
  0
}
EOF
"$PIONC" build -o "$TMP_DIR/ice_probe" "$ROOT_DIR/compiler/src/core" "$TMP_DIR/ice_probe.pion"
set +e
ICE_OUT="$("$TMP_DIR/ice_probe" 2>&1)"
ICE_RC=$?
set -e
echo "p133 backend ice rc=$ICE_RC out=$ICE_OUT"
[ "$ICE_RC" -ne 0 ] || { echo "FAIL: expected ICE panic on unresolved binding with clean tc" >&2; exit 1; }
printf '%s' "$ICE_OUT" | grep -q 'ICE: unresolved qualified_call qual=ghost_pkg mem=ghost_fn' || {
  echo "FAIL: expected ICE diagnostic message, got: $ICE_OUT" >&2
  exit 1
}

echo "[PASS] p133_qbe_soundness (4-mode native/wasm32 dev/release + frontend diag + backend ICE)"
