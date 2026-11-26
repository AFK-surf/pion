#!/bin/sh
# PR-3 E2E: Multi-package workspace parallel build (Contract A & Contract B)
# Contract A: Isolated identical initial CAS, --jobs 1 vs --jobs 4 byte-for-byte SHA-256 parity:
#   1. Cold empty CAS build (diamond, Native + Wasm32)
#   2. Full hot CAS rebuild
#   3. Single-package private edit semi-hot rebuild
#   4. Public interface change rebuild
#   5. Legitimate empty .pionstub (pub generic fn) + empty .pionsig (no pub items)
#   6. P96 Case 6 non-empty stub (cold & hot)
#   7. Forced "2 parallel worker MISS upstreams -> sole ready downstream in parent" P96 Case 6
#   8. Diamond alias workspace (Native + Wasm32)
#   9. Simultaneous dual compile errors (deterministic minimum topo-index arbitration)
#  10. Wasm32 tight cache budget (PION_CACHE_MAX_KB=1, cold & partial-hit parity)
#  11. UTF-8 non-ASCII cache directory path parity
# Contract B: FIFO-synchronized concurrency (ZERO sleep):
#   1. Dual external processes racing on shared CAS (incl. legitimate 0-byte .pionsig/.pionstub)
#   2. Parent SIGKILL pre-publish barrier (worker exits, 0 partial CAS, .lock-based stage GC)
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"

# Force real multi-process worker dispatch even on tiny synthetic E2E fixtures;
# we also explicitly verify the default threshold path at the end.
export PION_WS_PAR_MIN_PKG_BYTES=1

TMP_DIR=$(mktemp -d)
LOCK_HOLDER_PID=""
cleanup() {
  if [ -n "$LOCK_HOLDER_PID" ]; then
    kill "$LOCK_HOLDER_PID" 2>/dev/null || true
    wait "$LOCK_HOLDER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

cas_manifest() {
  _cdir="$1"
  python3 - "$_cdir" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
rows = []
for sub in ("sig", "ssa", "obj"):
    d = os.path.join(root, sub)
    if not os.path.isdir(d):
        continue
    for fn in sorted(os.listdir(d)):
        if ".tmp." in fn:
            raise SystemExit(f"FAIL: leftover tmp file in CAS: {sub}/{fn}")
        p = os.path.join(d, fn)
        with open(p, "rb") as f:
            h = hashlib.sha256(f.read()).hexdigest()
        rows.append(f"{sub}/{fn} {h}")
print("\n".join(rows))
PY
}

assert_cas_parity() {
  _label="$1"
  _c1="$2"
  _c4="$3"
  _m1=$(cas_manifest "$_c1")
  _m4=$(cas_manifest "$_c4")
  if [ "$_m1" != "$_m4" ]; then
    echo "FAIL [$_label]: CAS manifest mismatch between --jobs 1 and --jobs 4" >&2
    printf '%s\n' "$_m1" > "$TMP_DIR/m1.txt"
    printf '%s\n' "$_m4" > "$TMP_DIR/m4.txt"
    diff -u "$TMP_DIR/m1.txt" "$TMP_DIR/m4.txt" >&2 || true
    exit 1
  fi
}

# --- Build diamond workspace fixture ---
WS_D="$TMP_DIR/ws_diamond"
mkdir -p "$WS_D/base/src" "$WS_D/left/src" "$WS_D/right/src" "$WS_D/app/src"
cat <<'EOF' > "$WS_D/base/pion.toml"
[package]
name = "base"
version = "0.1.0"
EOF
cat <<'EOF' > "$WS_D/base/src/lib.pion"
pub fn seed(x : Int) -> Int {
  x * 3 + 7
}
EOF
cat <<'EOF' > "$WS_D/left/pion.toml"
[package]
name = "left"
version = "0.1.0"

[dependencies]
b = { package = "base", path = "../base" }
EOF
cat <<'EOF' > "$WS_D/left/src/lib.pion"
import "b"

fn priv_adj(v : Int) -> Int {
  v + 10
}

pub fn calc_left(x : Int) -> Int {
  priv_adj(b::seed(x))
}
EOF
cat <<'EOF' > "$WS_D/right/pion.toml"
[package]
name = "right"
version = "0.1.0"

[dependencies]
b2 = { package = "base", path = "../base" }
EOF
cat <<'EOF' > "$WS_D/right/src/lib.pion"
import "b2"

pub fn calc_right(x : Int) -> Int {
  b2::seed(x) * 2 + 5
}
EOF
cat <<'EOF' > "$WS_D/app/pion.toml"
[package]
name = "app"
version = "0.1.0"

[dependencies]
l = { package = "left", path = "../left" }
r = { package = "right", path = "../right" }
EOF
cat <<'EOF' > "$WS_D/app/src/main.pion"
import "l"
import "r"

pub fn main(w : World) -> Int {
  let v = l::calc_left(10) + r::calc_right(10)
  io_println(w, "diamond=" + v.to_string())
  0
}
EOF

# 0. Check 1/1 linker determinism baseline on this host
CAS_B1="$TMP_DIR/cas_base1"
CAS_B2="$TMP_DIR/cas_base2"
mkdir -p "$CAS_B1" "$CAS_B2"
PION_CACHE_DIR="$CAS_B1" "$PIONC" build --jobs 1 -o "$TMP_DIR/bin_b1" "$WS_D/app"
PION_CACHE_DIR="$CAS_B2" "$PIONC" build --jobs 1 -o "$TMP_DIR/bin_b2" "$WS_D/app"
LINKER_DET=0
if [ "$(sha256_file "$TMP_DIR/bin_b1")" = "$(sha256_file "$TMP_DIR/bin_b2")" ]; then
  LINKER_DET=1
fi
echo "ws_parallel_build: host linker 1/1 determinism=$LINKER_DET"

# --- Contract A.1: Cold empty CAS build (Native + Wasm32) ---
CAS_A1_J1="$TMP_DIR/cas_a1_j1"
CAS_A1_J4="$TMP_DIR/cas_a1_j4"
mkdir -p "$CAS_A1_J1" "$CAS_A1_J4"
PION_CACHE_DIR="$CAS_A1_J1" "$PIONC" build --jobs 1 -o "$TMP_DIR/a1_j1" "$WS_D/app"
PION_CACHE_DIR="$CAS_A1_J4" "$PIONC" build --jobs 4 -o "$TMP_DIR/a1_j4" "$WS_D/app"
assert_cas_parity "A.1-native-cold" "$CAS_A1_J1" "$CAS_A1_J4"
if [ "$LINKER_DET" -eq 1 ]; then
  test "$(sha256_file "$TMP_DIR/a1_j1")" = "$(sha256_file "$TMP_DIR/a1_j4")"
fi
test "$("$TMP_DIR/a1_j1")" = "diamond=126"
test "$("$TMP_DIR/a1_j4")" = "diamond=126"

if command -v node >/dev/null 2>&1; then
  CAS_W1="$TMP_DIR/cas_w1"
  CAS_W4="$TMP_DIR/cas_w4"
  mkdir -p "$CAS_W1" "$CAS_W4"
  PION_CACHE_DIR="$CAS_W1" "$PIONC" build --jobs 1 --target wasm32 -o "$TMP_DIR/a1_j1.wasm" "$WS_D/app"
  PION_CACHE_DIR="$CAS_W4" "$PIONC" build --jobs 4 --target wasm32 -o "$TMP_DIR/a1_j4.wasm" "$WS_D/app"
  assert_cas_parity "A.1-wasm-cold" "$CAS_W1" "$CAS_W4"
  test "$(sha256_file "$TMP_DIR/a1_j1.wasm")" = "$(sha256_file "$TMP_DIR/a1_j4.wasm")"
  test "$(node "$WASM_RT" "$TMP_DIR/a1_j4.wasm")" = "diamond=126"
fi
echo "Contract A.1 (cold diamond Native + Wasm32): OK"

# --- Contract A.2: Full hot CAS rebuild ---
PION_CACHE_DIR="$CAS_A1_J1" "$PIONC" build --jobs 1 -o "$TMP_DIR/a2_j1" "$WS_D/app"
PION_CACHE_DIR="$CAS_A1_J4" "$PIONC" build --jobs 4 -o "$TMP_DIR/a2_j4" "$WS_D/app"
assert_cas_parity "A.2-native-hot" "$CAS_A1_J1" "$CAS_A1_J4"
test "$("$TMP_DIR/a2_j4")" = "diamond=126"
echo "Contract A.2 (full hot CAS): OK"

# --- Contract A.3: Single-package private edit semi-hot rebuild ---
cat <<'EOF' > "$WS_D/left/src/lib.pion"
import "b"

fn priv_adj(v : Int) -> Int {
  v + 20
}

pub fn calc_left(x : Int) -> Int {
  priv_adj(b::seed(x))
}
EOF
PION_CACHE_DIR="$CAS_A1_J1" "$PIONC" build --jobs 1 -o "$TMP_DIR/a3_j1" "$WS_D/app"
PION_CACHE_DIR="$CAS_A1_J4" "$PIONC" build --jobs 4 -o "$TMP_DIR/a3_j4" "$WS_D/app"
assert_cas_parity "A.3-semi-hot-private" "$CAS_A1_J1" "$CAS_A1_J4"
test "$("$TMP_DIR/a3_j1")" = "diamond=136"
test "$("$TMP_DIR/a3_j4")" = "diamond=136"
echo "Contract A.3 (single-package private edit): OK"

# --- Contract A.4: Public interface change ---
cat <<'EOF' > "$WS_D/left/src/lib.pion"
import "b"

pub fn calc_left(x : Int, y : Int) -> Int {
  b::seed(x) + y
}
EOF
cat <<'EOF' > "$WS_D/app/src/main.pion"
import "l"
import "r"

pub fn main(w : World) -> Int {
  let v = l::calc_left(10, 3) + r::calc_right(10)
  io_println(w, "diamond=" + v.to_string())
  0
}
EOF
PION_CACHE_DIR="$CAS_A1_J1" "$PIONC" build --jobs 1 -o "$TMP_DIR/a4_j1" "$WS_D/app"
PION_CACHE_DIR="$CAS_A1_J4" "$PIONC" build --jobs 4 -o "$TMP_DIR/a4_j4" "$WS_D/app"
assert_cas_parity "A.4-pub-iface-change" "$CAS_A1_J1" "$CAS_A1_J4"
test "$("$TMP_DIR/a4_j1")" = "diamond=119"
test "$("$TMP_DIR/a4_j4")" = "diamond=119"
echo "Contract A.4 (public interface change): OK"

# --- Contract A.5: Legitimate empty .pionstub (pub generic fn) + empty .pionsig ---
WS_E="$TMP_DIR/ws_empty_stub"
mkdir -p "$WS_E/g1/src" "$WS_E/g2/src" "$WS_E/nopub/src" "$WS_E/app/src"
cat <<'EOF' > "$WS_E/g1/pion.toml"
[package]
name = "g1"
version = "0.1.0"
EOF
cat <<'EOF' > "$WS_E/g1/src/lib.pion"
pub fn id1[T](x : T) -> T {
  x
}
EOF
cat <<'EOF' > "$WS_E/g2/pion.toml"
[package]
name = "g2"
version = "0.1.0"
EOF
cat <<'EOF' > "$WS_E/g2/src/lib.pion"
pub fn id2[T](x : T) -> T {
  x
}
EOF
cat <<'EOF' > "$WS_E/nopub/pion.toml"
[package]
name = "nopub"
version = "0.1.0"
EOF
cat <<'EOF' > "$WS_E/nopub/src/lib.pion"
fn internal_only() -> Int {
  42
}
EOF
cat <<'EOF' > "$WS_E/app/pion.toml"
[package]
name = "app_empty"
version = "0.1.0"

[dependencies]
g1 = { path = "../g1" }
g2 = { path = "../g2" }
nopub = { path = "../nopub" }
EOF
cat <<'EOF' > "$WS_E/app/src/main.pion"
import "g1"
import "g2"
import "nopub"

pub fn main(w : World) -> Int {
  let x = g1::id1(21) + g2::id2(21)
  io_println(w, "empty=" + x.to_string())
  0
}
EOF
CAS_E1="$TMP_DIR/cas_e1"
CAS_E4="$TMP_DIR/cas_e4"
mkdir -p "$CAS_E1" "$CAS_E4"
PION_CACHE_DIR="$CAS_E1" "$PIONC" build --jobs 1 -o "$TMP_DIR/e_j1" "$WS_E/app"
PION_CACHE_DIR="$CAS_E4" "$PIONC" build --jobs 4 -o "$TMP_DIR/e_j4" "$WS_E/app"
assert_cas_parity "A.5-empty-stub-and-sig" "$CAS_E1" "$CAS_E4"
test "$("$TMP_DIR/e_j4")" = "empty=42"
# Confirm 0-byte .pionstub files (pub generic fns g1/g2 + private-only nopub) and all .pionsig files were legitimately published.
python3 - "$CAS_E4/sig" <<'PY'
import os, sys
d = sys.argv[1]
zero_stubs = [f for f in os.listdir(d) if f.endswith(".pionstub") and os.path.getsize(os.path.join(d, f)) == 0]
sigs = [f for f in os.listdir(d) if f.endswith(".pionsig") and os.path.isfile(os.path.join(d, f))]
assert len(zero_stubs) >= 2, f"expected >=2 empty .pionstub files, got {zero_stubs}"
assert len(sigs) >= 4, f"expected >=4 .pionsig files, got {sigs}"
PY
# Pre-populate 0-byte .pionsig files for every package (simulating a concurrent publish race
# where an empty .pionsig already exists in CAS) and verify --jobs 4 overwrites/succeeds cleanly.
CAS_E_PRE="$TMP_DIR/cas_e_prezero"
mkdir -p "$CAS_E_PRE/sig"
for f in "$CAS_E4/sig/"*.pionsig; do
  : > "$CAS_E_PRE/sig/$(basename "$f")"
done
PION_CACHE_DIR="$CAS_E_PRE" "$PIONC" build --jobs 4 -o "$TMP_DIR/e_prezero" "$WS_E/app"
assert_cas_parity "A.5-prezero-pionsig" "$CAS_E1" "$CAS_E_PRE"
test "$("$TMP_DIR/e_prezero")" = "empty=42"
echo "Contract A.5 (empty .pionstub & .pionsig + pre-populated 0-byte .pionsig): OK"

# --- Contract A.6 & A.7: P96 Case 6 (cold, hot, AND forced 2 worker MISS upstreams -> sole ready downstream in parent) ---
WS_P96="$TMP_DIR/ws_p96"
mkdir -p "$WS_P96/safe_helper/src" "$WS_P96/keep_helper/src" "$WS_P96/bridge/src" "$WS_P96/app/src"
cat <<'EOF' > "$WS_P96/safe_helper/pion.toml"
[package]
name = "safe_helper"
version = "0.1.0"
EOF
cat <<'EOF' > "$WS_P96/safe_helper/src/lib.pion"
pub fn inspect(v : StrView) -> Int {
  let mut acc = 0
  let mut i = 0
  while i < v.length() {
    acc = acc + v.code_unit_at(i).to_int()
    i += 1
  }
  acc + v.length()
}
EOF
cat <<'EOF' > "$WS_P96/keep_helper/pion.toml"
[package]
name = "keep_helper"
version = "0.1.0"
EOF
cat <<'EOF' > "$WS_P96/keep_helper/src/lib.pion"
pub fn inspect(v : StrView) -> StrView {
  let mut acc = 0
  let mut i = 0
  while i < v.length() {
    acc = acc + v.code_unit_at(i).to_int()
    i += 1
  }
  if acc < 0 {
    return "".as_view()
  }
  v
}
EOF
cat <<'EOF' > "$WS_P96/bridge/pion.toml"
[package]
name = "bridge"
version = "0.1.0"

[dependencies]
x = { package = "keep_helper", path = "../keep_helper" }
EOF
cat <<'EOF' > "$WS_P96/bridge/src/lib.pion"
import "x"

pub fn forward(v : StrView) -> StrView {
  x::inspect(v)
}
EOF
cat <<'EOF' > "$WS_P96/app/pion.toml"
[package]
name = "app_p96"
version = "0.1.0"

[dependencies]
x = { package = "safe_helper", path = "../safe_helper" }
bridge = { path = "../bridge" }
EOF
cat <<'EOF' > "$WS_P96/app/src/main.pion"
import "x"
import "bridge"

fn run_fwd(s : String) -> StrView {
  let _ = x::inspect(s.as_view())
  bridge::forward(s.as_view())
}

pub fn main(w : World) -> Int {
  let s = "alias-bridge-" + "999"
  let v = run_fwd(s)
  io_println(w, "p96c6=" + v.to_string())
  0
}
EOF

# A.6 Cold build: keep_helper & safe_helper are both wave-0 ready MISS -> workers!
# Then bridge (wave-1) -> app (wave-2, sole ready downstream in parent!).
CAS_P1="$TMP_DIR/cas_p96_1"
CAS_P4="$TMP_DIR/cas_p96_4"
mkdir -p "$CAS_P1" "$CAS_P4"
PION_CACHE_DIR="$CAS_P1" "$PIONC" build --release --jobs 1 -o "$TMP_DIR/p96_j1" "$WS_P96/app"
PION_CACHE_DIR="$CAS_P4" "$PIONC" build --release --jobs 4 -o "$TMP_DIR/p96_j4" "$WS_P96/app"
assert_cas_parity "A.6-p96-cold" "$CAS_P1" "$CAS_P4"
test "$("$TMP_DIR/p96_j4")" = "p96c6=alias-bridge-999"

# A.7 Forced: pre-warm ONLY keep_helper in both CASes, then build app with --jobs 1 vs --jobs 4.
# Now BOTH safe_helper AND bridge are simultaneously ready MISS (2 worker MISS upstreams),
# and app is the sole ready downstream that falls back to the parent!
CAS_F1="$TMP_DIR/cas_p96_forced_1"
CAS_F4="$TMP_DIR/cas_p96_forced_4"
mkdir -p "$CAS_F1" "$CAS_F4"
# Build keep_helper standalone into CAS_F1 and copy to CAS_F4 as identical initial cache.
PION_CACHE_DIR="$CAS_F1" "$PIONC" build --release --jobs 1 --emit-staticlib "$TMP_DIR/kh.a" "$WS_P96/keep_helper"
cp -R "$CAS_F1/." "$CAS_F4/"
PION_CACHE_DIR="$CAS_F1" "$PIONC" build --release --jobs 1 -o "$TMP_DIR/p96f_j1" "$WS_P96/app"
PION_CACHE_DIR="$CAS_F4" "$PIONC" build --release --jobs 4 -o "$TMP_DIR/p96f_j4" "$WS_P96/app"
assert_cas_parity "A.7-p96-2worker-to-parent" "$CAS_F1" "$CAS_F4"
test "$("$TMP_DIR/p96f_j4")" = "p96c6=alias-bridge-999"

# Hot rebuild of app against non-empty cached stubs
printf '// hot edit\n' >> "$WS_P96/app/src/main.pion"
PION_CACHE_DIR="$CAS_P1" "$PIONC" build --release --jobs 1 -o "$TMP_DIR/p96_hot_j1" "$WS_P96/app"
PION_CACHE_DIR="$CAS_P4" "$PIONC" build --release --jobs 4 -o "$TMP_DIR/p96_hot_j4" "$WS_P96/app"
assert_cas_parity "A.6-p96-hot" "$CAS_P1" "$CAS_P4"
test "$("$TMP_DIR/p96_hot_j4")" = "p96c6=alias-bridge-999"
echo "Contract A.6 & A.7 (P96 Case 6 cold/hot + 2-worker-MISS-to-parent): OK"

# --- Contract A.9: Simultaneous dual compile errors (minimum topo-index arbitration) ---
WS_ERR="$TMP_DIR/ws_dual_err"
mkdir -p "$WS_ERR/aa_first/src" "$WS_ERR/zz_second/src" "$WS_ERR/app/src"
cat <<'EOF' > "$WS_ERR/aa_first/pion.toml"
[package]
name = "aa_first"
version = "0.1.0"
EOF
# Make aa_first slightly larger so zz_second finishes faster in parallel,
# proving parent waits for aa_first and returns aa_first's diagnostic!
python3 - "$WS_ERR/aa_first/src/lib.pion" <<'PY'
import sys
lines = []
for i in range(400):
    lines.append(f"fn pad_{i}(x : Int) -> Int {{ x + {i} }}")
lines.append('pub fn first_bad() -> Int { "not_an_int_first" }')
with open(sys.argv[1], "w") as f:
    f.write("\n".join(lines) + "\n")
PY
cat <<'EOF' > "$WS_ERR/zz_second/pion.toml"
[package]
name = "zz_second"
version = "0.1.0"
EOF
cat <<'EOF' > "$WS_ERR/zz_second/src/lib.pion"
pub fn second_bad() -> Int {
  "not_an_int_second"
}
EOF
cat <<'EOF' > "$WS_ERR/app/pion.toml"
[package]
name = "app_err"
version = "0.1.0"

[dependencies]
aa_first = { path = "../aa_first" }
zz_second = { path = "../zz_second" }
EOF
cat <<'EOF' > "$WS_ERR/app/src/main.pion"
import "aa_first"
import "zz_second"

pub fn main(_w : World) -> Int {
  aa_first::first_bad() + zz_second::second_bad()
}
EOF
CAS_ERR1="$TMP_DIR/cas_err1"
CAS_ERR4="$TMP_DIR/cas_err4"
mkdir -p "$CAS_ERR1" "$CAS_ERR4"
set +e
ERR_J1=$(PION_CACHE_DIR="$CAS_ERR1" "$PIONC" build --jobs 1 -o "$TMP_DIR/err_j1" "$WS_ERR/app" 2>&1)
RC_E1=$?
ERR_J4=$(PION_CACHE_DIR="$CAS_ERR4" "$PIONC" build --jobs 4 -o "$TMP_DIR/err_j4" "$WS_ERR/app" 2>&1)
RC_E4=$?
set -e
test "$RC_E1" -ne 0
test "$RC_E4" -ne 0
if [ "$ERR_J1" != "$ERR_J4" ]; then
  echo "FAIL [A.9-dual-error]: --jobs 1 and --jobs 4 diagnostics differ" >&2
  echo "--- jobs 1 ---" >&2
  printf '%s\n' "$ERR_J1" >&2
  echo "--- jobs 4 ---" >&2
  printf '%s\n' "$ERR_J4" >&2
  exit 1
fi
printf '%s' "$ERR_J4" | grep -q "aa_first"
echo "Contract A.9 (dual error minimum topo-index arbitration): OK"

# --- Contract A.10: Wasm32 PION_CACHE_MAX_KB=1 tight-budget regression (cold & partial-hit) ---
if command -v node >/dev/null 2>&1; then
  CAS_WM1="$TMP_DIR/cas_wmax1_j1"
  CAS_WM4="$TMP_DIR/cas_wmax1_j4"
  mkdir -p "$CAS_WM1" "$CAS_WM4"
  PION_CACHE_MAX_KB=1 PION_CACHE_DIR="$CAS_WM1" "$PIONC" build --jobs 1 --target wasm32 -o "$TMP_DIR/wm1_cold.wasm" "$WS_D/app"
  PION_CACHE_MAX_KB=1 PION_CACHE_DIR="$CAS_WM4" "$PIONC" build --jobs 4 --target wasm32 -o "$TMP_DIR/wm4_cold.wasm" "$WS_D/app"
  test "$(sha256_file "$TMP_DIR/wm1_cold.wasm")" = "$(sha256_file "$TMP_DIR/wm4_cold.wasm")"
  test "$(node "$WASM_RT" "$TMP_DIR/wm4_cold.wasm")" = "diamond=119"
  # Second build against the 1KB-evicted CAS (partial-hit / re-eviction path)
  PION_CACHE_MAX_KB=1 PION_CACHE_DIR="$CAS_WM1" "$PIONC" build --jobs 1 --target wasm32 -o "$TMP_DIR/wm1_re.wasm" "$WS_D/app"
  PION_CACHE_MAX_KB=1 PION_CACHE_DIR="$CAS_WM4" "$PIONC" build --jobs 4 --target wasm32 -o "$TMP_DIR/wm4_re.wasm" "$WS_D/app"
  test "$(sha256_file "$TMP_DIR/wm1_re.wasm")" = "$(sha256_file "$TMP_DIR/wm4_re.wasm")"
  test "$(node "$WASM_RT" "$TMP_DIR/wm4_re.wasm")" = "diamond=119"
  echo "Contract A.10 (Wasm32 PION_CACHE_MAX_KB=1 cold & partial-hit parity): OK"
fi

# --- Contract A.11: UTF-8 non-ASCII cache directory path parity ---
CAS_U1="$TMP_DIR/同一目录/cas_utf8_1"
CAS_U4="$TMP_DIR/同一目录/cas_utf8_4"
mkdir -p "$CAS_U1" "$CAS_U4"
PION_CACHE_DIR="$CAS_U1" "$PIONC" build --jobs 1 -o "$TMP_DIR/u_j1" "$WS_D/app"
PION_CACHE_DIR="$CAS_U4" "$PIONC" build --jobs 4 -o "$TMP_DIR/u_j4" "$WS_D/app"
assert_cas_parity "A.11-utf8-cache-dir" "$CAS_U1" "$CAS_U4"
test "$("$TMP_DIR/u_j1")" = "diamond=119"
test "$("$TMP_DIR/u_j4")" = "diamond=119"
echo "Contract A.11 (UTF-8 non-ASCII cache dir parity): OK"

# --- Contract A.12: SIGCHLD=SIG_IGN regression (graceful serial fallback, byte-identical Wasm32) ---
if command -v node >/dev/null 2>&1; then
  CAS_SIG1="$TMP_DIR/cas_sigchld_1"
  CAS_SIG4="$TMP_DIR/cas_sigchld_4"
  mkdir -p "$CAS_SIG1" "$CAS_SIG4"
  PION_CACHE_DIR="$CAS_SIG1" "$PIONC" build --jobs 1 --target wasm32 -o "$TMP_DIR/sig1.wasm" "$WS_D/app"
  python3 - "$PIONC" "$CAS_SIG4" "$TMP_DIR/sig4.wasm" "$WS_D/app" <<'PY'
import os, signal, subprocess, sys
pionc, cas_dir, out_wasm, app_dir = sys.argv[1:5]
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
env = os.environ.copy()
env["PION_CACHE_DIR"] = cas_dir
p = subprocess.run([pionc, "build", "--jobs", "4", "--target", "wasm32", "-o", out_wasm, app_dir], env=env, capture_output=True, text=True)
assert p.returncode == 0, f"FAIL [A.12 SIGCHLD=SIG_IGN]: rc={p.returncode}\nSTDOUT:{p.stdout}\nSTDERR:{p.stderr}"
PY
  test "$(sha256_file "$TMP_DIR/sig1.wasm")" = "$(sha256_file "$TMP_DIR/sig4.wasm")"
  test "$(node "$WASM_RT" "$TMP_DIR/sig4.wasm")" = "diamond=119"
  echo "Contract A.12 (SIGCHLD=SIG_IGN graceful fallback parity): OK"
fi

# --- Contract B.1: Dual external processes racing on shared CAS (FIFO start gate, zero sleep) ---
CAS_RACE="$TMP_DIR/cas_race"
mkdir -p "$CAS_RACE"
RACE_F1="$TMP_DIR/race_go1.fifo"
RACE_F2="$TMP_DIR/race_go2.fifo"
mkfifo "$RACE_F1" "$RACE_F2"
(
  read _go < "$RACE_F1"
  PION_CACHE_DIR="$CAS_RACE" "$PIONC" build --jobs 4 -o "$TMP_DIR/race_out_1" "$WS_E/app"
) &
PID_R1=$!
(
  read _go < "$RACE_F2"
  PION_CACHE_DIR="$CAS_RACE" "$PIONC" build --jobs 4 -o "$TMP_DIR/race_out_2" "$WS_E/app"
) &
PID_R2=$!
printf 'go\n' > "$RACE_F1" &
P_W1=$!
printf 'go\n' > "$RACE_F2" &
P_W2=$!
wait "$P_W1" "$P_W2" "$PID_R1" "$PID_R2"
test "$("$TMP_DIR/race_out_1")" = "empty=42"
test "$("$TMP_DIR/race_out_2")" = "empty=42"
# Verify zero .tmp.* leftovers and valid 0-byte .pionsig / .pionstub
cas_manifest "$CAS_RACE" >/dev/null
echo "Contract B.1 (dual external process shared CAS race incl. empty sig/stub): OK"

# --- Contract B.2: Parent SIGKILL pre-publish barrier (FIFO, zero sleep) ---
CAS_KILL="$TMP_DIR/cas_kill"
BDIR="$TMP_DIR/barrier"
mkdir -p "$CAS_KILL/ws_stage" "$BDIR"
mkfifo "$BDIR/ready.fifo" "$BDIR/release.fifo" "$BDIR/lock_ready.fifo" "$BDIR/lock_stop.fifo"
# Plant an active stage dir with a live flock on .lock, plus an unlocked stale stage dir
# sharing our live shell PID $$ (proving GC uses advisory .lock, not PID-namespace PID).
ACTIVE_STAGE="$CAS_KILL/ws_stage/.pion_ws.$$.999999"
UNLOCKED_SAME_PID_STAGE="$CAS_KILL/ws_stage/.pion_ws.$$.888888"
mkdir -p "$ACTIVE_STAGE" "$UNLOCKED_SAME_PID_STAGE"
printf 'active\n' > "$ACTIVE_STAGE/keep.txt"
: > "$UNLOCKED_SAME_PID_STAGE/.lock"
printf 'stale\n' > "$UNLOCKED_SAME_PID_STAGE/stale.txt"

python3 - "$ACTIVE_STAGE/.lock" "$BDIR/lock_ready.fifo" "$BDIR/lock_stop.fifo" <<'PY' &
import fcntl, os, sys
lock_path, ready_fifo, stop_fifo = sys.argv[1], sys.argv[2], sys.argv[3]
fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
with open(ready_fifo, "w") as f:
    f.write("locked\n")
with open(stop_fifo, "r") as f:
    f.read()
os.close(fd)
PY
LOCK_HOLDER_PID=$!
python3 - "$BDIR/lock_ready.fifo" "$LOCK_HOLDER_PID" <<'PY'
import errno, os, select, sys, time
fifo, pid_s = sys.argv[1], sys.argv[2]
pid = int(pid_s)
rfd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
buf = b""
deadline = time.monotonic() + 30.0
try:
    while b"\n" not in buf:
        rem = deadline - time.monotonic()
        if rem <= 0:
            raise AssertionError("FAIL: timed out waiting for lock holder on lock_ready.fifo")
        r, _, _ = select.select([rfd], [], [], min(0.1, rem))
        if r:
            try:
                chunk = os.read(rfd, 256)
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                raise
            if chunk:
                buf += chunk
                continue
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            raise AssertionError(f"FAIL: lock holder {pid} exited before signaling lock_ready.fifo")
finally:
    os.close(rfd)
PY

PION_TEST_WS_PRE_PUBLISH_BARRIER="$BDIR" \
  PION_CACHE_DIR="$CAS_KILL" \
  "$PIONC" build --jobs 4 -o "$TMP_DIR/kill_out" "$WS_E/app" >/dev/null 2>&1 &
PARENT_PID=$!

# Wait on ready.fifo with O_NONBLOCK + select timeout & parent-liveness check (zero sleep, never hangs),
# then SIGKILL parent and verify worker exits promptly via pidfd/kqueue.
python3 - "$BDIR/ready.fifo" "$PARENT_PID" "$CAS_KILL" <<'PY'
import errno, os, select, signal, sys, time
ready_fifo, ppid_s, cas_dir = sys.argv[1], sys.argv[2], sys.argv[3]
ppid = int(ppid_s)
rfd = os.open(ready_fifo, os.O_RDONLY | os.O_NONBLOCK)
buf = b""
deadline = time.monotonic() + 30.0
try:
    while b"\n" not in buf:
        rem = deadline - time.monotonic()
        if rem <= 0:
            raise AssertionError("FAIL: timed out waiting for worker on ready.fifo")
        r, _, _ = select.select([rfd], [], [], min(0.1, rem))
        if r:
            try:
                chunk = os.read(rfd, 256)
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                raise
            if chunk:
                buf += chunk
                continue
        # Check parent is still alive (not dead/zombie) while waiting
        try:
            os.kill(ppid, 0)
        except ProcessLookupError:
            raise AssertionError(f"FAIL: parent {ppid} exited before worker reached ready.fifo")
finally:
    os.close(rfd)
line = buf.decode("utf-8", errors="replace").splitlines()[0].strip()
assert line.isdigit(), f"FAIL: bad worker pid from ready.fifo: {line!r}"
wpid = int(line)
ws_stage = os.path.join(cas_dir, "ws_stage")
parent_stages = [d for d in os.listdir(ws_stage) if d.startswith(f".pion_ws.{ppid}.")]
assert len(parent_stages) == 1, f"expected 1 parent stage dir, got {parent_stages}"
# Watch worker exit without sleep using pidfd_open on Linux or kqueue on macOS.
if hasattr(os, "pidfd_open"):
    pfd = os.pidfd_open(wpid, 0)
    try:
        os.kill(ppid, signal.SIGKILL)
        r, _, _ = select.select([pfd], [], [], 10.0)
        assert r, f"FAIL: worker {wpid} did not exit within 10s after parent SIGKILL"
    finally:
        os.close(pfd)
elif hasattr(select, "kqueue"):
    kq = select.kqueue()
    try:
        kev = select.kevent(wpid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)
        os.kill(ppid, signal.SIGKILL)
        evs = kq.control([kev], 1, 10.0)
        assert evs, f"FAIL: worker {wpid} did not exit within 10s after parent SIGKILL"
    finally:
        kq.close()
else:
    os.kill(ppid, signal.SIGKILL)
PY
wait "$PARENT_PID" 2>/dev/null || true

# Verify ZERO CAS files were published by the killed workers!
python3 - "$CAS_KILL" <<'PY'
import os, sys
cas = sys.argv[1]
for sub in ("sig", "ssa", "obj"):
    d = os.path.join(cas, sub)
    if os.path.isdir(d):
        ents = os.listdir(d)
        assert len(ents) == 0, f"FAIL: partial CAS artifact after parent SIGKILL: {sub}/{ents}"
PY

# Next build must lazily clean the dead parent's orphaned stage dir AND the unlocked same-PID stage dir,
# while preserving the flock-held ACTIVE_STAGE!
PION_CACHE_DIR="$CAS_KILL" "$PIONC" build --jobs 1 -o "$TMP_DIR/post_kill_out" "$WS_E/app"
test "$("$TMP_DIR/post_kill_out")" = "empty=42"
python3 - "$CAS_KILL/ws_stage" "$PARENT_PID" "$$" <<'PY'
import os, sys
ws_stage, dead_pid, live_pid = sys.argv[1], sys.argv[2], sys.argv[3]
ents = os.listdir(ws_stage)
dead_left = [d for d in ents if d.startswith(f".pion_ws.{dead_pid}.")]
unlocked_left = [d for d in ents if d == f".pion_ws.{live_pid}.888888"]
live_left = [d for d in ents if d == f".pion_ws.{live_pid}.999999"]
assert len(dead_left) == 0, f"FAIL: stale stage dir from dead PID {dead_pid} was not cleaned: {dead_left}"
assert len(unlocked_left) == 0, f"FAIL: unlocked stage dir with colliding PID was not cleaned: {unlocked_left}"
assert len(live_left) == 1, f"FAIL: flock-held active stage dir was removed: {ents}"
PY
printf 'stop\n' > "$BDIR/lock_stop.fifo"
wait "$LOCK_HOLDER_PID" 2>/dev/null || true
echo "Contract B.2 (parent SIGKILL barrier, zero partial CAS, .lock-based stale stage GC + active kept): OK"

# --- Contract B.3: .gc.lock fail-closed (both stage creation and GC fail closed when .gc.lock is a directory) ---
CAS_FC1="$TMP_DIR/cas_gc_fc1"
CAS_FC4="$TMP_DIR/cas_gc_fc4"
mkdir -p "$CAS_FC1" "$CAS_FC4/ws_stage/.gc.lock" "$CAS_FC4/ws_stage/.pion_ws.999999.0"
: > "$CAS_FC4/ws_stage/.pion_ws.999999.0/.lock"
printf 'preserve_me\n' > "$CAS_FC4/ws_stage/.pion_ws.999999.0/keep.txt"
PION_CACHE_DIR="$CAS_FC1" "$PIONC" build --jobs 1 -o "$TMP_DIR/fc_j1" "$WS_D/app"
PION_CACHE_DIR="$CAS_FC4" "$PIONC" build --jobs 4 -o "$TMP_DIR/fc_j4" "$WS_D/app"
assert_cas_parity "B.3-gc-lock-fail-closed" "$CAS_FC1" "$CAS_FC4"
test "$("$TMP_DIR/fc_j1")" = "diamond=119"
test "$("$TMP_DIR/fc_j4")" = "diamond=119"
test -f "$CAS_FC4/ws_stage/.pion_ws.999999.0/keep.txt"
echo "Contract B.3 (.gc.lock fail-closed on stage create & GC, serial fallback parity): OK"

# --- Default threshold check: tiny packages stay in-process (no ws_stage created) and stay byte-identical ---
CAS_DEF1="$TMP_DIR/cas_def1"
CAS_DEF4="$TMP_DIR/cas_def4"
mkdir -p "$CAS_DEF1" "$CAS_DEF4"
env -u PION_WS_PAR_MIN_PKG_BYTES PION_CACHE_DIR="$CAS_DEF1" "$PIONC" build --jobs 1 -o "$TMP_DIR/def_j1" "$WS_E/app"
env -u PION_WS_PAR_MIN_PKG_BYTES PION_CACHE_DIR="$CAS_DEF4" "$PIONC" build --jobs 4 -o "$TMP_DIR/def_j4" "$WS_E/app"
assert_cas_parity "default-threshold-small-pkgs" "$CAS_DEF1" "$CAS_DEF4"
test ! -d "$CAS_DEF4/ws_stage"
test "$("$TMP_DIR/def_j4")" = "empty=42"
echo "Default threshold small-pkg in-process fast-path: OK"

# --- Contract A.13: Cross-package cold vs hot `.pionstub` runtime parity (generic fns, escapes, ECall(EField), SForIn, SLetTuple, generic method & generic impl) ---
WS_STUB="$TMP_DIR/ws_stub_fidelity"
mkdir -p "$WS_STUB/up/src" "$WS_STUB/app/src"
cat <<'EOF' > "$WS_STUB/up/pion.toml"
[package]
name = "up"
version = "0.1.0"
EOF
cat <<'EOF' > "$WS_STUB/up/src/lib.pion"
pub struct Holder {
  f : (Int) -> Int
}
pub fn Holder::f(self : Holder, x : Int) -> Int {
  x + 1000
}
pub fn pad1() -> Int { 1 }
pub fn pad2() -> Int { 2 }
pub fn pad3() -> Int { 3 }
pub fn pad4() -> Int { 4 }

pub fn call_field[T](h : Holder, t : T, x : Int) -> Int {
  let _ = t
  (h.f)(x)
}

pub fn check_escapes[T](t : T, def_s~ : String = "\x1b[0m中文😀") -> String {
  let _ = t
  let c_nl : Char = '\n'
  let b_esc : Byte = b'\x1b'
  let c_sq : Char = '\''
  let c_bs : Char = '\\'
  let s_esc : String = "\x1b[0m"
  let u_lit : String = "中文😀"
  let u_interp : String = "前\{def_s}后"
  let b0 = def_s.code_unit_at(0)
  let s0 = s_esc.code_unit_at(0)
  "nl=" + c_nl.to_int().to_string() +
    ",esc=" + b_esc.to_int().to_string() +
    ",sq=" + c_sq.to_int().to_string() +
    ",bs=" + c_bs.to_int().to_string() +
    ",ds=" + b0.to_string() +
    ",ss=" + s0.to_string() +
    ",u=" + u_lit +
    ",ui=" + u_interp
}

pub fn sum_loops[T](xs : Array[Int], t : T) -> Int {
  let _ = t
  let mut acc = 0
  for x in xs {
    acc = acc + x
  }
  for i, x in xs {
    acc = acc + i * 10 + x
  }
  for let (a, b) = (0, 3); a < 1; acc = acc + b {
    acc = acc + b
    break
  }
  acc
}

pub trait Wrap {
  fn tag_of(self) -> Int
}
pub struct WBox {
  tag : Int
}
pub impl Wrap for WBox {
  fn tag_of(self) -> Int {
    self.tag
  }
}
let priv_bias : Int = 10
fn priv_helper(x : Int) -> Int {
  x + priv_bias
}
pub fn call_priv[T](x : Int, t : T) -> Int {
  let _ = t
  priv_helper(x)
}

pub fn WBox::wrap_id[T](self : WBox, y : T) -> T {
  let _ = self.tag
  y
}
pub fn WBox::add_tag[T](self : WBox, y : Int, t : T) -> Int {
  let _ = t
  self.tag + y
}
EOF
cat <<'EOF' > "$WS_STUB/app/pion.toml"
[package]
name = "app_stub"
version = "0.1.0"

[dependencies]
up = { path = "../up" }
EOF
cat <<'EOF' > "$WS_STUB/app/src/main.pion"
import "up"

pub fn main(w : World) -> Int {
  let h = up::Holder::{ f: fn(x : Int) -> Int { x + 1 } }
  let cf = up::call_field(h, 0, 5)
  let es = up::check_escapes(0)
  let lp = up::sum_loops([2, 4, 6], 0)
  let wb = up::WBox::{ tag: 9 }
  let wi = wb.add_tag(wb.wrap_id(77), "ok")
  let pv = up::call_priv(5, "p")
  io_println(w, "field=" + cf.to_string() + " " + es + " loop=" + lp.to_string() + " wrap=" + wi.to_string() + " priv=" + pv.to_string())
  0
}
EOF
CAS_STUB="$TMP_DIR/cas_stub_fidelity"
mkdir -p "$CAS_STUB"
PION_CACHE_DIR="$CAS_STUB" "$PIONC" build --jobs 1 -o "$TMP_DIR/stub_cold" "$WS_STUB/app"
STUB_COLD_OUT="$("$TMP_DIR/stub_cold")"
echo "Contract A.13 cold=$STUB_COLD_OUT"
# Verify `up` actually emitted a non-empty `.pionstub` containing `call_field`
UP_STUB_FILE=$(grep -l "pub fn call_field" "$CAS_STUB"/sig/*.pionstub | head -n 1 || true)
test -n "$UP_STUB_FILE" || { echo "FAIL: no .pionstub with call_field"; ls -la "$CAS_STUB"/sig/; exit 1; }
# Touch app only so `up` is loaded from its cached `.pionstub` on hot rebuild
printf '\n// hot-stub-rebuild\n' >> "$WS_STUB/app/src/main.pion"
PION_CACHE_DIR="$CAS_STUB" "$PIONC" build --jobs 1 -o "$TMP_DIR/stub_hot" "$WS_STUB/app"
STUB_HOT_OUT="$("$TMP_DIR/stub_hot")"
echo "Contract A.13 hot=$STUB_HOT_OUT"
test "$STUB_COLD_OUT" = "$(printf 'field=6 nl=10,esc=27,sq=39,bs=92,ds=27,ss=27,u=中文😀,ui=前\033[0m中文😀后 loop=57 wrap=86 priv=15')"
test "$STUB_COLD_OUT" = "$STUB_HOT_OUT"
echo "Contract A.13 (cold vs hot .pionstub fidelity: ECall(EField), escapes, SForIn, SLetTuple, generic method & impl): OK"

echo "PASS: ws_parallel_build (Contract A & Contract B)"
