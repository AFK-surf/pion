#!/bin/sh
# P33-B E2E: multi-package incremental CAS for `pionc check` (.pionsig/.pionstub)
# and `pionc build --target wasm32` (per-package .pionsig/.pionstub/.ssa + final .wasm binary).
set -eu

PIONC="${1:-}"
if [ -z "$PIONC" ]; then
  echo "usage: $0 <pionc>" >&2
  exit 1
fi
case "$PIONC" in
  /*) ;;
  *) PIONC="$(pwd)/$PIONC" ;;
esac

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export PION_CACHE_DIR="$TMP_DIR/cas"
mkdir -p "$PION_CACHE_DIR"

# 6-package virtual workspace:
#   diamond: base -> mid_a, mid_b -> ui -> app
#   sibling: extra
WS="$TMP_DIR/ws"
mkdir -p \
  "$WS/packages/base/src" \
  "$WS/packages/mid_a/src" \
  "$WS/packages/mid_b/src" \
  "$WS/packages/ui/src" \
  "$WS/packages/extra/src" \
  "$WS/cmd/app/src"

cat > "$WS/pion.toml" <<'EOF'
[workspace]
members = [
  "packages/*",
  "cmd/*",
]

[workspace.dependencies]
base = { path = "packages/base" }
mid_a = { path = "packages/mid_a" }
mid_b = { path = "packages/mid_b" }
ui = { path = "packages/ui" }
EOF

cat > "$WS/packages/base/pion.toml" <<'EOF'
[package]
name = "base"
version = "0.1.0"
EOF
cat > "$WS/packages/base/src/lib.pion" <<'EOF'
pub fn seed(x : Int) -> Int {
  x * 2
}
EOF

cat > "$WS/packages/mid_a/pion.toml" <<'EOF'
[package]
name = "mid_a"
version = "0.1.0"

[dependencies]
base = { workspace = true }
EOF
cat > "$WS/packages/mid_a/src/lib.pion" <<'EOF'
import "base" as base

fn helper(v : Int) -> Int {
  v + 1
}

pub fn calc_a(x : Int) -> Int {
  helper(base::seed(x))
}
EOF

cat > "$WS/packages/mid_b/pion.toml" <<'EOF'
[package]
name = "mid_b"
version = "0.1.0"

[dependencies]
base = { workspace = true }
EOF
cat > "$WS/packages/mid_b/src/lib.pion" <<'EOF'
import "base" as base

pub fn calc_b(x : Int) -> Int {
  base::seed(x) + 10
}
EOF

cat > "$WS/packages/ui/pion.toml" <<'EOF'
[package]
name = "ui"
version = "0.1.0"

[dependencies]
mid_a = { workspace = true }
mid_b = { workspace = true }
EOF
cat > "$WS/packages/ui/src/lib.pion" <<'EOF'
import "mid_a" as mid_a
import "mid_b" as mid_b

pub fn summary(x : Int) -> Int {
  mid_a::calc_a(x) + mid_b::calc_b(x)
}
EOF

cat > "$WS/packages/extra/pion.toml" <<'EOF'
[package]
name = "extra"
version = "0.1.0"
EOF
cat > "$WS/packages/extra/src/lib.pion" <<'EOF'
pub fn tag() -> String {
  "extra"
}
EOF

cat > "$WS/cmd/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
ui = { workspace = true }
EOF
cat > "$WS/cmd/app/src/main.pion" <<'EOF'
import "ui" as ui

pub fn main(world : World) -> Int {
  io_println(world, "v1=" + ui::summary(5).to_string())
  0
}
EOF

count_lines() {
  # Returns count of lines matching $1 in file $2 (0 if none).
  grep -c "$1" "$2" 2>/dev/null || true
}

# --- 1. Cold `pionc check`: 6 MISS / 0 HIT ---
LOG1="$TMP_DIR/check_cold.err"
OUT1="$(cd "$WS" && PION_TRACE_CAS=1 "$PIONC" check --json 2>"$LOG1")"
printf '%s' "$OUT1" | grep -q '"ok":true' || {
  echo "FAIL: cold check failed: $OUT1" >&2
  cat "$LOG1" >&2
  exit 1
}
MISS1="$(count_lines '^\[cas-check\] pkg=.* MISS ' "$LOG1")"
HIT1="$(count_lines '^\[cas-check\] pkg=.* HIT ' "$LOG1")"
if [ "$MISS1" -ne 6 ] || [ "$HIT1" -ne 0 ]; then
  echo "FAIL: cold check expected 6 MISS / 0 HIT, got MISS=$MISS1 HIT=$HIT1" >&2
  cat "$LOG1" >&2
  exit 1
fi

# --- 2. Warm `pionc check`: 6 HIT / 0 MISS ---
LOG2="$TMP_DIR/check_warm.err"
OUT2="$(cd "$WS" && PION_TRACE_CAS=1 "$PIONC" check --json 2>"$LOG2")"
printf '%s' "$OUT2" | grep -q '"ok":true' || {
  echo "FAIL: warm check failed: $OUT2" >&2
  cat "$LOG2" >&2
  exit 1
}
MISS2="$(count_lines '^\[cas-check\] pkg=.* MISS ' "$LOG2")"
HIT2="$(count_lines '^\[cas-check\] pkg=.* HIT ' "$LOG2")"
if [ "$MISS2" -ne 0 ] || [ "$HIT2" -ne 6 ]; then
  echo "FAIL: warm check expected 0 MISS / 6 HIT, got MISS=$MISS2 HIT=$HIT2" >&2
  cat "$LOG2" >&2
  exit 1
fi

# --- 3. Private body edit in `mid_a` (same pub sig): ONLY `mid_a` MISS, 5 HIT ---
cat > "$WS/packages/mid_a/src/lib.pion" <<'EOF'
import "base" as base

fn helper(v : Int) -> Int {
  v + 2
}

pub fn calc_a(x : Int) -> Int {
  helper(base::seed(x))
}
EOF
LOG3="$TMP_DIR/check_body.err"
OUT3="$(cd "$WS" && PION_TRACE_CAS=1 "$PIONC" check --json 2>"$LOG3")"
printf '%s' "$OUT3" | grep -q '"ok":true' || {
  echo "FAIL: body-edit check failed: $OUT3" >&2
  cat "$LOG3" >&2
  exit 1
}
MISS3="$(count_lines '^\[cas-check\] pkg=.* MISS ' "$LOG3")"
HIT3="$(count_lines '^\[cas-check\] pkg=.* HIT ' "$LOG3")"
if [ "$MISS3" -ne 1 ] || [ "$HIT3" -ne 5 ] || ! grep -q '^\[cas-check\] pkg=mid_a MISS ' "$LOG3"; then
  echo "FAIL: body-edit check expected ONLY mid_a MISS (1 MISS / 5 HIT), got MISS=$MISS3 HIT=$HIT3" >&2
  cat "$LOG3" >&2
  exit 1
fi

# --- 4. Breaking pub signature in `mid_a`: error reported & NEVER cached ---
cat > "$WS/packages/mid_a/src/lib.pion" <<'EOF'
import "base" as base

pub fn calc_a(x : String) -> Int {
  base::seed(x.length())
}
EOF
set +e
ERR4A="$(cd "$WS" && PION_TRACE_CAS=1 "$PIONC" check --json 2>"$TMP_DIR/err4a.err")"
RC4A=$?
ERR4B="$(cd "$WS" && PION_TRACE_CAS=1 "$PIONC" check --json 2>"$TMP_DIR/err4b.err")"
RC4B=$?
set -e
if [ "$RC4A" -eq 0 ] || ! printf '%s' "$ERR4A" | grep -q 'E_TYPE_MISMATCH'; then
  echo "FAIL: breaking pub sig first check must fail with E_TYPE_MISMATCH (rc=$RC4A): $ERR4A" >&2
  exit 1
fi
if [ "$RC4B" -eq 0 ] || ! printf '%s' "$ERR4B" | grep -q 'E_TYPE_MISMATCH'; then
  echo "FAIL: breaking pub sig repeated check must still fail (never cached) (rc=$RC4B): $ERR4B" >&2
  exit 1
fi

# Restore `mid_a` and verify check turns green again.
cat > "$WS/packages/mid_a/src/lib.pion" <<'EOF'
import "base" as base

fn helper(v : Int) -> Int {
  v + 2
}

pub fn calc_a(x : Int) -> Int {
  helper(base::seed(x))
}
EOF
OUT4C="$(cd "$WS" && PION_TRACE_CAS=1 "$PIONC" check --json 2>"$TMP_DIR/err4c.err")"
printf '%s' "$OUT4C" | grep -q '"ok":true' || {
  echo "FAIL: restored check failed: $OUT4C" >&2
  exit 1
}

# --- 5. Multi-package `pionc build --release --target wasm32` CAS ---
WASM_OUT="$TMP_DIR/app.wasm"

# 5a. Cold wasm32 build: all 5 packages in `app` closure MISS + binary MISS
WLOG1="$TMP_DIR/wasm_cold.err"
(cd "$WS" && PION_TRACE_CAS=1 "$PIONC" build --release --target wasm32 -p app -o "$WASM_OUT" 2>"$WLOG1")
WMISS1="$(count_lines '^\[cas-wasm\] pkg=.* MISS ' "$WLOG1")"
WHIT1="$(count_lines '^\[cas-wasm\] pkg=.* HIT ' "$WLOG1")"
if [ "$WMISS1" -ne 5 ] || [ "$WHIT1" -ne 0 ] || ! grep -q '^\[cas-wasm-bin\] MISS ' "$WLOG1"; then
  echo "FAIL: cold wasm32 expected 5 MISS / 0 HIT + bin MISS, got MISS=$WMISS1 HIT=$WHIT1" >&2
  cat "$WLOG1" >&2
  exit 1
fi
WRUN1="$(node "$WASM_RT" "$WASM_OUT")"
# seed(5)=10; calc_a(5)=10+2=12; calc_b(5)=10+10=20; summary(5)=32
if [ "$WRUN1" != "v1=32" ]; then
  echo "FAIL: cold wasm32 run output mismatch: expected 'v1=32', got '$WRUN1'" >&2
  exit 1
fi

# 5b. Warm wasm32 rebuild: all 5 pkg HIT + [cas-wasm-bin] HIT
WLOG2="$TMP_DIR/wasm_warm.err"
(cd "$WS" && PION_TRACE_CAS=1 "$PIONC" build --release --target wasm32 -p app -o "$WASM_OUT" 2>"$WLOG2")
WMISS2="$(count_lines '^\[cas-wasm\] pkg=.* MISS ' "$WLOG2")"
WHIT2="$(count_lines '^\[cas-wasm\] pkg=.* HIT ' "$WLOG2")"
if [ "$WMISS2" -ne 0 ] || [ "$WHIT2" -ne 5 ] || ! grep -q '^\[cas-wasm-bin\] HIT ' "$WLOG2"; then
  echo "FAIL: warm wasm32 expected 0 MISS / 5 HIT + bin HIT, got MISS=$WMISS2 HIT=$WHIT2" >&2
  cat "$WLOG2" >&2
  exit 1
fi
WRUN2="$(node "$WASM_RT" "$WASM_OUT")"
if [ "$WRUN2" != "v1=32" ]; then
  echo "FAIL: warm wasm32 run output mismatch: expected 'v1=32', got '$WRUN2'" >&2
  exit 1
fi

# 5c. Edit ONLY `app`: base/mid_a/mid_b/ui ALL [cas-wasm] HIT, ONLY app MISS, updated output in Node
cat > "$WS/cmd/app/src/main.pion" <<'EOF'
import "ui" as ui

pub fn main(world : World) -> Int {
  io_println(world, "v2=" + (ui::summary(5) + 100).to_string())
  0
}
EOF
WLOG3="$TMP_DIR/wasm_incr.err"
(cd "$WS" && PION_TRACE_CAS=1 "$PIONC" build --release --target wasm32 -p app -o "$WASM_OUT" 2>"$WLOG3")
WMISS3="$(count_lines '^\[cas-wasm\] pkg=.* MISS ' "$WLOG3")"
WHIT3="$(count_lines '^\[cas-wasm\] pkg=.* HIT ' "$WLOG3")"
if [ "$WMISS3" -ne 1 ] || [ "$WHIT3" -ne 4 ] || ! grep -q '^\[cas-wasm\] pkg=app MISS ' "$WLOG3"; then
  echo "FAIL: incr wasm32 expected ONLY app MISS (1 MISS / 4 HIT), got MISS=$WMISS3 HIT=$WHIT3" >&2
  cat "$WLOG3" >&2
  exit 1
fi
for UP in base mid_a mid_b ui; do
  grep -q "^\[cas-wasm\] pkg=${UP} HIT " "$WLOG3" || {
    echo "FAIL: expected upstream ${UP} to [cas-wasm] HIT" >&2
    cat "$WLOG3" >&2
    exit 1
  }
done
WRUN3="$(node "$WASM_RT" "$WASM_OUT")"
if [ "$WRUN3" != "v2=132" ]; then
  echo "FAIL: incr wasm32 run output mismatch: expected 'v2=132', got '$WRUN3'" >&2
  exit 1
fi

# --- 6. Single-package multi-file incremental unit CAS soundness (P34-B) ---
# Verifies: (a) cold --release multi-file build works, (b) editing ONLY b.pion
# (while a.pion is loaded as a `{ panic() }` .stub) never inlines panic stubs,
# and (c) editing ONLY a.pion's private body & const value (same .sig) updates
# output immediately with zero stale cross-file inline or const folding.
SPKG="$TMP_DIR/single_pkg_units"
mkdir -p "$SPKG"
cat > "$SPKG/a.pion" <<'EOF'
let K : Int = 7

fn tiny_add(x : Int) -> Int {
  x + 10
}
EOF
cat > "$SPKG/b.pion" <<'EOF'
fn run(x : Int) -> Int {
  tiny_add(x) + K
}
EOF
cat > "$SPKG/main.pion" <<'EOF'
pub fn main(world : World) -> Int {
  io_println(world, "u=" + run(5).to_string())
  0
}
EOF

UBIN="$TMP_DIR/unit_app"
# 6a. Cold --release build
"$PIONC" build --release -o "$UBIN" "$SPKG"
UOUT1="$("$UBIN")"
if [ "$UOUT1" != "u=22" ]; then
  echo "FAIL: P34-B cold multi-file unit build expected 'u=22', got '$UOUT1'" >&2
  exit 1
fi

# 6b. Edit ONLY b.pion -> a.pion is parsed from `{ panic() }` stub; must NOT panic
cat > "$SPKG/b.pion" <<'EOF'
fn run(x : Int) -> Int {
  tiny_add(x) + K + 5
}
EOF
"$PIONC" build --release -o "$UBIN" "$SPKG"
UOUT2="$("$UBIN")"
if [ "$UOUT2" != "u=27" ]; then
  echo "FAIL: P34-B incremental edit of b.pion expected 'u=27', got '$UOUT2'" >&2
  exit 1
fi

# 6c. Edit ONLY a.pion body & const value (identical .sig) -> b.o CAS hit must see new values
cat > "$SPKG/a.pion" <<'EOF'
let K : Int = 13

fn tiny_add(x : Int) -> Int {
  x + 100
}
EOF
"$PIONC" build --release -o "$UBIN" "$SPKG"
UOUT3="$("$UBIN")"
if [ "$UOUT3" != "u=123" ]; then
  echo "FAIL: P34-B incremental edit of a.pion body/const expected 'u=123', got '$UOUT3'" >&2
  exit 1
fi

# --- 7. Linker dead-code & dead-data section GC (P35-B) ---
# Large unreferenced function + 64 KB dead string literal in a dependency package
# must be stripped by `-Wl,--gc-sections` (Linux ELF64 per-fn/per-data sections)
# and `-dead_strip` / `-Wl,-dead_strip` (macOS Mach-O).
GC_WS="$TMP_DIR/gc_ws"
mkdir -p "$GC_WS/deadlib/src" "$GC_WS/deadapp/src"
cat > "$GC_WS/deadlib/pion.toml" <<'EOF'
[package]
name = "deadlib"
version = "0.1.0"
EOF
python3 - "$GC_WS/deadlib/src/lib.pion" <<'PYEOF'
import sys
payload = "DEAD_SENTINEL_P35B_" + ("Z" * 65536)
with open(sys.argv[1], "w") as f:
    f.write('pub fn live_calc(x : Int) -> Int {\n  x * 3 + 1\n}\n\n')
    f.write('pub fn dead_heavy_fn(x : Int) -> Int {\n')
    f.write(f'  let big = "{payload}"\n')
    f.write('  big.length() + x\n')
    f.write('}\n')
PYEOF
cat > "$GC_WS/deadapp/pion.toml" <<'EOF'
[package]
name = "deadapp"
version = "0.1.0"

[dependencies]
deadlib = { path = "../deadlib" }
EOF
cat > "$GC_WS/deadapp/src/main.pion" <<'EOF'
import "deadlib" as deadlib

pub fn main(world : World) -> Int {
  io_println(world, "gc=" + deadlib::live_calc(14).to_string())
  0
}
EOF

GC_BIN="$TMP_DIR/gc_app"
"$PIONC" build --release -o "$GC_BIN" "$GC_WS/deadapp"
GC_OUT="$("$GC_BIN")"
if [ "$GC_OUT" != "gc=43" ]; then
  echo "FAIL: P35-B gc_app output mismatch: expected 'gc=43', got '$GC_OUT'" >&2
  exit 1
fi
if grep -a -q "DEAD_SENTINEL_P35B_" "$GC_BIN"; then
  echo "FAIL: P35-B dead 64 KB string literal was NOT stripped from $GC_BIN" >&2
  exit 1
fi
if command -v nm >/dev/null 2>&1 && nm "$GC_BIN" 2>/dev/null | grep -q "dead_heavy_fn"; then
  echo "FAIL: P35-B dead_heavy_fn symbol was NOT stripped from $GC_BIN" >&2
  exit 1
fi
GC_SIZE="$(wc -c < "$GC_BIN" | tr -d ' ')"
if [ "$GC_SIZE" -ge 131072 ]; then
  echo "FAIL: P35-B gc_app size too large (${GC_SIZE} B >= 131072 B)" >&2
  exit 1
fi

echo "p33b_incremental_cas: ALL PASSED (check 6/6 cold->warm->body-edit->err-no-cache + wasm32 5-pkg .ssa/.wasm CAS + P34-B single-pkg unit CAS soundness + P35-B section GC size=${GC_SIZE}B)"
