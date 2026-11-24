#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
PIONC="${1:-$ROOT_DIR/out/pionc_linux}"
if [ ! -x "$PIONC" ] && [ -x "$ROOT_DIR/out/pionc2" ]; then
  PIONC="$ROOT_DIR/out/pionc2"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export PION_CACHE_DIR="$TMP_DIR/cas"

echo "=== P72-B E2E: immutable fields / priv fields / enum methods / pionc test --no-deps ==="

# ----------------------------------------------------------------------------
# 1. Immutable struct field assignment (= and +=) rejected; mut field allowed
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/immut"
cat > "$TMP_DIR/immut/bad.pion" <<'EOF'
struct S {
  a : Int
  mut b : Int
}
pub fn main() -> Int {
  let s = S::{ a: 1, b: 2 }
  s.a = 3
  s.a += 1
  s.b = 4
  s.b += 5
  s.b
}
EOF
if "$PIONC" check --json "$TMP_DIR/immut/bad.pion" > "$TMP_DIR/immut/out.json"; then
  echo "FAIL: immutable field assignment should fail check" >&2
  exit 1
fi
grep -q "cannot assign to immutable field" "$TMP_DIR/immut/out.json"
echo "1. Immutable field check -> OK"

# ----------------------------------------------------------------------------
# 2. Cross-package priv fields + enum methods (negative checks + Native & Wasm32)
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/ws/crypto/src" "$TMP_DIR/ws/app/src" "$TMP_DIR/ws/bad_app/src"
cat > "$TMP_DIR/ws/crypto/pion.toml" <<'EOF'
[package]
name = "crypto"
version = "0.1.0"
EOF
cat > "$TMP_DIR/ws/crypto/src/lib.pion" <<'EOF'
pub struct KeyPair {
  pub_id : Int
  priv scalar : String
  priv mut uses : Int
}

pub fn KeyPair::new(id : Int, secret : String) -> KeyPair {
  KeyPair::{ pub_id: id, scalar: secret, uses: 0 }
}

pub fn KeyPair::sign_len(self : KeyPair) -> Int {
  self.uses += 1
  self.scalar.length() + self.uses
}

pub enum Base64Error {
  InvalidLen(Int)
  InvalidChar(String)
}

pub fn Base64Error::message(self : Base64Error) -> String {
  match self {
    InvalidLen(n) => "bad_len:" + n.to_string()
    InvalidChar(c) => "bad_char:" + c
  }
}

pub enum Boxed[T] {
  Wrap(T)
  Empty
}

pub fn Boxed::describe[T](self : Boxed[T], fallback : String) -> String {
  match self {
    Wrap(_) => "wrapped"
    Empty => fallback
  }
}
EOF

cat > "$TMP_DIR/ws/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
crypto = { path = "../crypto" }
EOF
cat > "$TMP_DIR/ws/app/src/main.pion" <<'EOF'
import "crypto"

enum LocalErr {
  Timeout(Int)
}

fn LocalErr::label(self : LocalErr) -> String {
  match self {
    Timeout(ms) => "to:" + ms.to_string()
  }
}

pub fn main(world : World) -> Int {
  let kp = crypto::KeyPair::new(7, "secret")
  let a = kp.pub_id
  let b = kp.sign_len()
  let c = kp.sign_len()
  let e1 = crypto::Base64Error::InvalidLen(12)
  let e2 = crypto::Base64Error::InvalidChar("?")
  let l1 = LocalErr::Timeout(50)
  let bx : crypto::Boxed[Int] = crypto::Boxed::Wrap(1)
  io_println(
    world,
    a.to_string() +
    "," +
    b.to_string() +
    "," +
    c.to_string() +
    "|" +
    e1.message() +
    "|" +
    crypto::Base64Error::message(e2) +
    "|" +
    l1.label() +
    "|" +
    LocalErr::label(l1) +
    "|" +
    bx.describe("none"),
  )
  0
}
EOF

cat > "$TMP_DIR/ws/bad_app/pion.toml" <<'EOF'
[package]
name = "bad_app"
version = "0.1.0"

[dependencies]
crypto = { path = "../crypto" }
EOF
cat > "$TMP_DIR/ws/bad_app/src/main.pion" <<'EOF'
import "crypto"

pub fn main() -> Int {
  let kp = crypto::KeyPair::{ pub_id: 1, scalar: "s", uses: 0 }
  kp.pub_id = 2
  kp.uses = 3
  kp.scalar.length()
}
EOF

if "$PIONC" check --json "$TMP_DIR/ws/bad_app" > "$TMP_DIR/ws/bad.json"; then
  echo "FAIL: cross-package priv/immut access should fail check" >&2
  exit 1
fi
grep -q "E_PRIVATE_FIELD" "$TMP_DIR/ws/bad.json"
grep -q "cannot assign to immutable field" "$TMP_DIR/ws/bad.json"
echo "2a. Cross-package priv & immut negative checks -> OK"

WANT="7,7,8|bad_len:12|bad_char:?|to:50|to:50|wrapped"
"$PIONC" build --release -o "$TMP_DIR/ws/app_bin" "$TMP_DIR/ws/app"
OUT_NAT="$("$TMP_DIR/ws/app_bin")"
echo "2b. Native -> $OUT_NAT"
[ "$OUT_NAT" = "$WANT" ]

if command -v node >/dev/null 2>&1; then
  OUT_WASM="$("$PIONC" run --release --target wasm32 "$TMP_DIR/ws/app")"
  echo "2c. Wasm32 -> $OUT_WASM"
  [ "$OUT_WASM" = "$WANT" ]
fi

# ----------------------------------------------------------------------------
# 3. pionc test --no-deps (and --only-pkg alias)
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/tnd/dep/src" "$TMP_DIR/tnd/app/src"
cat > "$TMP_DIR/tnd/dep/pion.toml" <<'EOF'
[package]
name = "dep"
version = "0.1.0"
EOF
cat > "$TMP_DIR/tnd/dep/src/lib.pion" <<'EOF'
pub fn answer() -> Int { 42 }
EOF
cat > "$TMP_DIR/tnd/dep/src/dep_test.pion" <<'EOF'
test "dep_fail" {
  debug_assert(1 == 2, "dep_fail")
}
EOF

cat > "$TMP_DIR/tnd/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
dep = { path = "../dep" }
EOF
cat > "$TMP_DIR/tnd/app/src/lib.pion" <<'EOF'
import "dep"

pub fn app_answer() -> Int { dep::answer() }
EOF
cat > "$TMP_DIR/tnd/app/src/app_test.pion" <<'EOF'
test "app_ok" {
  debug_assert(app_answer() == 42, "app_ok")
}
EOF

# Default single-package `pionc test` skips local path deps -> runs ONLY app_ok and succeeds
"$PIONC" test --json "$TMP_DIR/tnd/app" > "$TMP_DIR/tnd/default.json"
grep -q '"ok":true' "$TMP_DIR/tnd/default.json"
grep -q '"app_ok"' "$TMP_DIR/tnd/default.json"
grep -q '"deps_skipped":1' "$TMP_DIR/tnd/default.json"
if grep -q '"dep_fail"' "$TMP_DIR/tnd/default.json"; then
  echo "FAIL: default single-package pionc test ran dep_fail!" >&2
  exit 1
fi

# Explicit --deps runs dep_fail and fails
if "$PIONC" test --deps --json "$TMP_DIR/tnd/app" > "$TMP_DIR/tnd/deps.json" 2>&1; then
  echo "FAIL: pionc test --deps should run dep_fail and fail" >&2
  exit 1
fi
grep -q '"dep_fail"' "$TMP_DIR/tnd/deps.json"
grep -q '"deps_skipped":0' "$TMP_DIR/tnd/deps.json"

# --no-deps compatibility alias runs ONLY app_ok and succeeds
"$PIONC" test --no-deps --json "$TMP_DIR/tnd/app" > "$TMP_DIR/tnd/nodeps.json"
grep -q '"ok":true' "$TMP_DIR/tnd/nodeps.json"
grep -q '"app_ok"' "$TMP_DIR/tnd/nodeps.json"
grep -q '"deps_skipped":1' "$TMP_DIR/tnd/nodeps.json"
if grep -q '"dep_fail"' "$TMP_DIR/tnd/nodeps.json"; then
  echo "FAIL: --no-deps ran dep_fail!" >&2
  exit 1
fi

# --only-pkg alias works identically
"$PIONC" test --only-pkg --json "$TMP_DIR/tnd/app" > "$TMP_DIR/tnd/onlypkg.json"
grep -q '"ok":true' "$TMP_DIR/tnd/onlypkg.json"
grep -q '"app_ok"' "$TMP_DIR/tnd/onlypkg.json"

# Mutual exclusion with --package
if "$PIONC" test --no-deps -p app --json "$TMP_DIR/tnd/app" > "$TMP_DIR/tnd/mutex.json" 2>&1; then
  echo "FAIL: --no-deps -p should be mutually exclusive" >&2
  exit 1
fi
grep -q "mutually exclusive" "$TMP_DIR/tnd/mutex.json"
echo "3. pionc test default / --deps / --no-deps / --only-pkg -> OK"

echo "PASS: p72b_lang_cli"
