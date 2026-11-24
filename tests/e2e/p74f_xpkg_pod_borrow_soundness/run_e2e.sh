#!/bin/sh
# P74-F E2E soundness regression:
# `.pionstub` `{ panic() }` placeholder bodies MUST NOT trigger `qbe_fn_param_is_pod_borrow`
# (stack-allocating a POD struct without a PionHeader and passing it to a non-inlined
# cross-package or sibling-unit callee that retains/stores it on the heap and RC-inc/decs it).
# Covers:
#   Case 1: Multi-package cross-package `.pionstub` (dep_pkg::Holder::from_payload)
#   Case 2: Same-package multi-file per-unit `.pionstub` (a.pion -> b.pion)
#   Targets: Native --release, Native dev, Native ASan/LSan (0 leaks/0 stack-underflow/0 UAF), Wasm32 Node
#   SSA check: app_pkg CAS `.ssa` allocates `lim` via `$pion_alloc_uninit`, never `alloc8 24`.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
CC_BIN="${CC:-cc}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# --- Case 1: Multi-package cross-package `.pionstub` ---
mkdir -p "$TMP_DIR/ws/dep_pkg/src" "$TMP_DIR/ws/app_pkg/src"

cat <<'EOF' > "$TMP_DIR/ws/dep_pkg/pion.toml"
[package]
name = "dep_pkg"
version = "0.1.0"
EOF

cat <<'EOF' > "$TMP_DIR/ws/dep_pkg/src/lib.pion"
pub struct Limits {
  max_string_len : Int
  max_packet_len : Int
  max_list_items : Int
}

pub struct Holder {
  lim : Limits
  mut acc : Int
  items : Array[Limits]
}

// Intentionally complex & non-inlinable so `.pionstub` emits `{ panic() }`.
// Stores `lim` into heap struct `Holder` and `Array[Limits]`, exercising `pion_rc_inc`/`pion_rc_dec`
// on `lim - 24` (PionHeader). Previously crashed with SIGBUS rc=138 when caller stack-allocated `lim`.
pub fn Holder::from_payload(payload : Bytes, lim : Limits) -> Holder {
  let items : Array[Limits] = []
  let mut i = 0
  let mut acc = 0
  let n = payload.length()
  while i < n {
    let b = payload[i].to_int()
    if b > lim.max_string_len {
      acc = acc + lim.max_string_len
    } else {
      acc = acc + b
    }
    if i < 4 {
      items.push(lim)
    }
    i = i + 1
  }
  if acc > lim.max_packet_len {
    acc = lim.max_packet_len
  }
  let mut j = 0
  while j < items.length() {
    let it = items[j]
    acc = acc + it.max_list_items
    j = j + 1
  }
  Holder::{ lim: lim, acc: acc, items: items }
}

pub fn Holder::summary(self : Holder) -> Int {
  self.acc + self.lim.max_string_len + self.lim.max_packet_len + self.lim.max_list_items + self.items.length()
}
EOF

cat <<'EOF' > "$TMP_DIR/ws/app_pkg/pion.toml"
[package]
name = "app_pkg"
version = "0.1.0"

[dependencies]
dep_pkg = { path = "../dep_pkg" }
EOF

cat <<'EOF' > "$TMP_DIR/ws/app_pkg/src/main.pion"
import "dep_pkg"

fn run_once(k : Int) -> Int {
  let payload = Bytes::new(8)
  let mut i = 0
  while i < 8 {
    payload[i] = ((i + k) * 3) as Byte
    i = i + 1
  }
  let lim = dep_pkg::Limits::{
    max_string_len: 100 + k,
    max_packet_len: 65536,
    max_list_items: 1024,
  }
  let h = dep_pkg::Holder::from_payload(payload, lim)
  h.summary()
}

fn main(world : World) -> Unit {
  let mut total = 0
  let mut k = 0
  while k < 16 {
    total = total + run_once(k)
    k = k + 1
  }
  io_println(world, "p74f_xpkg=" + total.to_string())
}
EOF

# --- Case 2: Same-package multi-file per-unit `.pionstub` ---
mkdir -p "$TMP_DIR/mf/src"

cat <<'EOF' > "$TMP_DIR/mf/pion.toml"
[package]
name = "mf_pkg"
version = "0.1.0"
EOF

cat <<'EOF' > "$TMP_DIR/mf/src/b.pion"
pub struct LocalPod {
  a : Int
  b : Int
  c : Int
}

pub struct BoxPod {
  pod : LocalPod
  copies : Array[LocalPod]
  score : Int
}

pub fn consume_local_pod(pod : LocalPod, rounds : Int) -> BoxPod {
  let copies : Array[LocalPod] = []
  let mut i = 0
  let mut score = 0
  while i < rounds {
    copies.push(pod)
    score = score + pod.a + pod.b + pod.c + i
    i = i + 1
  }
  let mut j = 0
  while j < copies.length() {
    let p = copies[j]
    score = score + p.a
    j = j + 1
  }
  BoxPod::{ pod: pod, copies: copies, score: score }
}
EOF

cat <<'EOF' > "$TMP_DIR/mf/src/a.pion"
fn run_unit_once(k : Int) -> Int {
  let lim = LocalPod::{ a: 10 + k, b: 20 + k, c: 30 + k }
  let bx = consume_local_pod(lim, 6)
  bx.score + bx.pod.c + bx.copies.length()
}

fn main(world : World) -> Unit {
  let mut total = 0
  let mut k = 0
  while k < 16 {
    total = total + run_unit_once(k)
    k = k + 1
  }
  io_println(world, "p74f_unit=" + total.to_string())
}
EOF

# Use isolated CAS so we can inspect app_pkg's emitted SSA directly.
CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"

# 1. Case 1: Native --release + SSA verification
PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --release -o "$TMP_DIR/xpkg_rel" "$TMP_DIR/ws/app_pkg"
XPKG_REL=$("$TMP_DIR/xpkg_rel")
echo "p74f Case 1 native release -> $XPKG_REL"
test -n "$XPKG_REL"

# Inspect app_pkg SSA in CAS to confirm `run_once` heap-allocates `lim` via `$pion_alloc_uninit(w 24, ...)`
APP_SSA=$(grep -l "fn_run_once(" "$CAS_DIR"/ssa/*.ssa | head -n 1)
test -n "$APP_SSA"
python3 -c '
import sys
ssa = open(sys.argv[1]).read()
idx = ssa.find("fn_run_once(")
assert idx >= 0, "run_once not found in app_pkg SSA"
end = ssa.find("\n}\n", idx)
body = ssa[idx:end]
assert "call $pion_alloc_uninit(w 24," in body, "expected heap alloc for lim in run_once:\n" + body
assert "alloc8 24" not in body, "FORBIDDEN stack alloc8 24 for lim in run_once:\n" + body
assert "alloc8 48" not in body, "FORBIDDEN stack alloc8 48 for lim in run_once:\n" + body
' "$APP_SSA"
echo "p74f Case 1 SSA check OK (heap pion_alloc_uninit, no stack alloc8 24/48)"

# 2. Case 1: Native dev
PION_CACHE_DIR="$CAS_DIR" "$PIONC" build -o "$TMP_DIR/xpkg_dev" "$TMP_DIR/ws/app_pkg"
XPKG_DEV=$("$TMP_DIR/xpkg_dev")
echo "p74f Case 1 native dev -> $XPKG_DEV"
test "$XPKG_DEV" = "$XPKG_REL"

# 3. Case 1: Wasm32 Node
if command -v node >/dev/null 2>&1; then
  PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --release --target wasm32 -o "$TMP_DIR/xpkg.wasm" "$TMP_DIR/ws/app_pkg"
  XPKG_WASM=$(node "$WASM_RT" "$TMP_DIR/xpkg.wasm")
  echo "p74f Case 1 wasm32 -> $XPKG_WASM"
  test "$XPKG_WASM" = "$XPKG_REL"
fi

# 4. Case 2: Same-package multi-file per-unit `.pionstub` (Native release + dev + Wasm32)
PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --release -o "$TMP_DIR/mf_rel" "$TMP_DIR/mf"
MF_REL=$("$TMP_DIR/mf_rel")
echo "p74f Case 2 native release -> $MF_REL"
test -n "$MF_REL"

PION_CACHE_DIR="$CAS_DIR" "$PIONC" build -o "$TMP_DIR/mf_dev" "$TMP_DIR/mf"
MF_DEV=$("$TMP_DIR/mf_dev")
echo "p74f Case 2 native dev -> $MF_DEV"
test "$MF_DEV" = "$MF_REL"

if command -v node >/dev/null 2>&1; then
  PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --release --target wasm32 -o "$TMP_DIR/mf.wasm" "$TMP_DIR/mf"
  MF_WASM=$(node "$WASM_RT" "$TMP_DIR/mf.wasm")
  echo "p74f Case 2 wasm32 -> $MF_WASM"
  test "$MF_WASM" = "$MF_REL"
fi

# 5. Native ASan/LSan on both Case 1 (via staticlib + ASan rt) and Case 2
if printf 'int main(void){return 0;}\n' | "$CC_BIN" -x c - -fsanitize=address -o "$TMP_DIR/asan_probe" 2>/dev/null \
  && "$CC_BIN" -std=c11 -O1 -fsanitize=address -fno-omit-frame-pointer -c "$ROOT_DIR/runtime/pion_rt.c" -o "$TMP_DIR/pion_rt_asan.o" 2>/dev/null; then
  ar rcs "$TMP_DIR/libpionrt_asan.a" "$TMP_DIR/pion_rt_asan.o"
  PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --release --emit-staticlib "$TMP_DIR/libxpkg.a" "$TMP_DIR/ws/app_pkg"
  "$CC_BIN" -fsanitize=address -Wl,--whole-archive "$TMP_DIR/libxpkg.a" -Wl,--no-whole-archive "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/xpkg_asan" 2>/dev/null \
    || "$CC_BIN" -fsanitize=address -Wl,-force_load,"$TMP_DIR/libxpkg.a" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/xpkg_asan"
  XPKG_ASAN=$("$TMP_DIR/xpkg_asan")
  echo "p74f Case 1 ASan/LSan -> $XPKG_ASAN"
  test "$XPKG_ASAN" = "$XPKG_REL"

  PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --release --emit-staticlib "$TMP_DIR/libmf.a" "$TMP_DIR/mf"
  "$CC_BIN" -fsanitize=address -Wl,--whole-archive "$TMP_DIR/libmf.a" -Wl,--no-whole-archive "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/mf_asan" 2>/dev/null \
    || "$CC_BIN" -fsanitize=address -Wl,-force_load,"$TMP_DIR/libmf.a" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/mf_asan"
  MF_ASAN=$("$TMP_DIR/mf_asan")
  echo "p74f Case 2 ASan/LSan -> $MF_ASAN"
  test "$MF_ASAN" = "$MF_REL"
else
  echo "NOTE: cc -fsanitize=address unavailable; skipping p74f ASan check"
fi

echo "PASS: p74f_xpkg_pod_borrow_soundness (Case 1 xpkg + Case 2 multi-file unit + SSA + Native rel/dev + ASan/LSan + Wasm32)"
