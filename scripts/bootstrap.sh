#!/bin/sh
set -eu

export PATH="$HOME/.moon/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER_DIR="$ROOT_DIR/compiler"
OUT_DIR="$ROOT_DIR/out"
mkdir -p "$OUT_DIR"

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

export PION_QBE="$OUT_DIR/qbe"
export PION_RT_LIB="$OUT_DIR/libpionrt.a"

echo "=== [1/9] Build QBE + Runtime (unit + MT + 4-core bench + TSan + ASan + smoke) ==="
sh "$ROOT_DIR/scripts/build-qbe.sh" "$PION_QBE"
sh "$ROOT_DIR/scripts/test-runtime.sh"

echo "=== [2/9] Existing Frontend Gate (moon check / moon test / pionc0 frontend) ==="
sh "$ROOT_DIR/scripts/test-frontend.sh"

echo "=== [3/9] Stage 0: moon build --target native --release -> out/pionc0 ==="
T_S0_0=$(now_ms)
(cd "$COMPILER_DIR" && moon build --target native --release)
T_S0_1=$(now_ms)
cp "$COMPILER_DIR/_build/native/release/build/compat_moon/compat_moon.exe" "$OUT_DIR/pionc0"
S0_MS=$((T_S0_1 - T_S0_0))
S0_BYTES=$(wc -c < "$OUT_DIR/pionc0" | tr -d ' ')
echo "Stage 0 (pionc0): build=${S0_MS} ms, size=${S0_BYTES} bytes"

echo "=== [4/9] Stage 1: pionc0 -> out/pionc1 (fresh CAS) ==="
CAS_S1="$TMP_DIR/cas_stage1"
mkdir -p "$CAS_S1"
T_S1_0=$(now_ms)
PION_CACHE_DIR="$CAS_S1" "$OUT_DIR/pionc0" build \
  --emit-ssa "$OUT_DIR/stage1.ssa" \
  --emit-asm "$OUT_DIR/stage1.s" \
  -o "$OUT_DIR/pionc1" \
  "$COMPILER_DIR/src/core" \
  "$COMPILER_DIR/src/compat_pion/main.pion"
T_S1_1=$(now_ms)
S1_MS=$((T_S1_1 - T_S1_0))
S1_SSA_LINES=$(wc -l < "$OUT_DIR/stage1.ssa" | tr -d ' ')
S1_SSA_BYTES=$(wc -c < "$OUT_DIR/stage1.ssa" | tr -d ' ')
S1_ASM_LINES=$(wc -l < "$OUT_DIR/stage1.s" | tr -d ' ')
S1_BYTES=$(wc -c < "$OUT_DIR/pionc1" | tr -d ' ')
echo "Stage 1 (pionc1): build=${S1_MS} ms, stage1.ssa=${S1_SSA_LINES} lines (${S1_SSA_BYTES} bytes), stage1.s=${S1_ASM_LINES} lines, binary=${S1_BYTES} bytes"

echo "=== [5/9] Stage 2: pionc1 -> out/pionc2 (fresh CAS, pure pion native + multicore) ==="
CAS_S2="$TMP_DIR/cas_stage2"
mkdir -p "$CAS_S2"
T_S2_0=$(now_ms)
PION_CACHE_DIR="$CAS_S2" "$OUT_DIR/pionc1" build \
  --emit-ssa "$OUT_DIR/stage2.ssa" \
  --emit-asm "$OUT_DIR/stage2.s" \
  -o "$OUT_DIR/pionc2" \
  "$COMPILER_DIR/src/core" \
  "$COMPILER_DIR/src/compat_pion/main.pion"
T_S2_1=$(now_ms)
S2_MS=$((T_S2_1 - T_S2_0))
S2_SSA_LINES=$(wc -l < "$OUT_DIR/stage2.ssa" | tr -d ' ')
S2_SSA_BYTES=$(wc -c < "$OUT_DIR/stage2.ssa" | tr -d ' ')
S2_ASM_LINES=$(wc -l < "$OUT_DIR/stage2.s" | tr -d ' ')
S2_BYTES=$(wc -c < "$OUT_DIR/pionc2" | tr -d ' ')
echo "Stage 2 (pionc2): build=${S2_MS} ms, stage2.ssa=${S2_SSA_LINES} lines (${S2_SSA_BYTES} bytes), stage2.s=${S2_ASM_LINES} lines, binary=${S2_BYTES} bytes"

echo "=== [6/9] Fixed-Point Proof (Stage 1 == Stage 2 bit-for-bit) ==="
shasum -a 256 "$OUT_DIR/stage1.ssa" "$OUT_DIR/stage2.ssa"
cmp "$OUT_DIR/stage1.ssa" "$OUT_DIR/stage2.ssa"
echo "SSA fixed-point: BIT-FOR-BIT IDENTICAL"
shasum -a 256 "$OUT_DIR/stage1.s" "$OUT_DIR/stage2.s"
cmp "$OUT_DIR/stage1.s" "$OUT_DIR/stage2.s"
echo "ASM fixed-point: BIT-FOR-BIT IDENTICAL"

PIONC2="$OUT_DIR/pionc2"
export PION_CACHE_DIR="$TMP_DIR/cas_pionc2"
mkdir -p "$PION_CACHE_DIR"

echo "=== [7/9] Standalone pionc2 Gate: Self-check + All Frontend Fixtures (zero moon/pionc0) ==="
SELF_CORE_OUT=$("$PIONC2" check --json "$COMPILER_DIR/src/core")
printf 'pionc2 check compiler/src/core -> %s\n' "$SELF_CORE_OUT"
if [ "$SELF_CORE_OUT" != '{"ok":true,"diagnostics":[]}' ]; then
  echo "FAIL: pionc2 check compiler/src/core failed" >&2
  exit 1
fi

SELF_ALL_OUT=$("$PIONC2" check --json "$COMPILER_DIR/src/core" "$COMPILER_DIR/src/compat_pion/main.pion")
printf 'pionc2 check core + compat_pion  -> %s\n' "$SELF_ALL_OUT"
if [ "$SELF_ALL_OUT" != '{"ok":true,"diagnostics":[]}' ]; then
  echo "FAIL: pionc2 check core + compat_pion failed" >&2
  exit 1
fi

OK_OUT=$("$PIONC2" check --json "$ROOT_DIR/tests/frontend/ok_full.pion")
printf 'ok_full.pion -> %s\n' "$OK_OUT"
if [ "$OK_OUT" != '{"ok":true,"diagnostics":[]}' ]; then
  echo "FAIL: ok_full.pion expected ok:true" >&2
  exit 1
fi

expect_err_code_pionc2() {
  fixture="$1"
  code="$2"
  set +e
  out=$("$PIONC2" check --json "$ROOT_DIR/tests/frontend/$fixture")
  rc=$?
  set -e
  printf '%s -> %s (rc=%d)\n' "$fixture" "$out" "$rc"
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $fixture expected non-zero exit code" >&2
    exit 1
  fi
  if ! printf '%s' "$out" | grep -q "\"code\":\"$code\""; then
    echo "FAIL: $fixture expected error code $code" >&2
    exit 1
  fi
}

expect_err_code_pionc2 "err_parse.pion" "E_PARSE"
expect_err_code_pionc2 "err_missing_type.pion" "E_MISSING_TYPE"
expect_err_code_pionc2 "err_type_mismatch.pion" "E_TYPE_MISMATCH"
expect_err_code_pionc2 "err_non_exhaustive.pion" "E_NON_EXHAUSTIVE"
expect_err_code_pionc2 "err_not_send.pion" "E_NOT_SEND"
expect_err_code_pionc2 "err_use_after_move.pion" "E_USE_AFTER_MOVE"
expect_err_code_pionc2 "err_capability_missing.pion" "E_CAPABILITY_MISSING"

DEFS_OUT=$("$PIONC2" query defs --json "$ROOT_DIR/tests/frontend/ok_full.pion")
SIG_OUT=$("$PIONC2" query sig --json "$ROOT_DIR/tests/frontend/ok_full.pion")
CALLERS_OUT=$("$PIONC2" query callers --json "$ROOT_DIR/tests/frontend/ok_full.pion")
DEPS_OUT=$("$PIONC2" query deps --json "$ROOT_DIR/tests/frontend/ok_full.pion")
printf '%s' "$DEFS_OUT" | grep -q '"defs":\['
printf '%s' "$SIG_OUT" | grep -q '"sig_hash":'
printf '%s' "$CALLERS_OUT" | grep -q '"callers":\['
printf '%s' "$DEPS_OUT" | grep -q '"packages":\['
echo "pionc2 query defs/sig/callers/deps --json: PASS"

SIG_DIR="$TMP_DIR/sig_check"
mkdir -p "$SIG_DIR"
cp "$ROOT_DIR/tests/frontend/sig_v1.pion" "$SIG_DIR/mod.pion"
"$PIONC2" emit-sig "$SIG_DIR/mod.pion" > "$SIG_DIR/v1.pionsig"
cp "$ROOT_DIR/tests/frontend/sig_v2.pion" "$SIG_DIR/mod.pion"
"$PIONC2" emit-sig "$SIG_DIR/mod.pion" > "$SIG_DIR/v2.pionsig"
cmp "$SIG_DIR/v1.pionsig" "$SIG_DIR/v2.pionsig"
echo "pionc2 emit-sig byte-for-byte stability: PASS"

echo "=== [8/9] Standalone pionc2 Gate: All E2E Tests (hello / adt_generics / multicore_bench / contracts) ==="
T_H0=$(now_ms)
"$PIONC2" build -o "$TMP_DIR/hello" "$ROOT_DIR/tests/e2e/hello.pion"
T_H1=$(now_ms)
HELLO_SIZE=$(wc -c < "$TMP_DIR/hello" | tr -d ' ')
HELLO_OUT=$("$TMP_DIR/hello")
echo "hello.pion (pionc2): cold build=$((T_H1 - T_H0)) ms, binary=${HELLO_SIZE} bytes, output='${HELLO_OUT}'"
if [ "$HELLO_OUT" != "hello pion" ]; then
  echo "FAIL: hello.pion output mismatch: '$HELLO_OUT'" >&2
  exit 1
fi
if [ "$HELLO_SIZE" -ge 81920 ]; then
  echo "FAIL: hello binary (${HELLO_SIZE} bytes) exceeds 80 KB (81920 bytes)" >&2
  exit 1
fi

"$PIONC2" build -o "$TMP_DIR/adt_generics" "$ROOT_DIR/tests/e2e/adt_generics.pion"
ADT_OUT=$("$TMP_DIR/adt_generics")
echo "$ADT_OUT"
ADT_EXP=$(printf 'ast=49\nbox=boxed:42\narr=28,len=3,cplen=5\nmap=100,has_beta=false,cp_beta=200,len=2\nsb=pion-ok\nclo=43\ni32wrap=true')
if [ "$ADT_OUT" != "$ADT_EXP" ]; then
  echo "FAIL: adt_generics.pion output mismatch!" >&2
  exit 1
fi

"$PIONC2" build -o "$TMP_DIR/multicore_bench" "$ROOT_DIR/tests/e2e/multicore_bench.pion"
"$TMP_DIR/multicore_bench"

"$PIONC2" build --emit-ssa "$TMP_DIR/contracts_dev.ssa" -o "$TMP_DIR/contracts_dev" "$ROOT_DIR/tests/e2e/contracts.pion"
if ! grep -q "pion_debug_assert" "$TMP_DIR/contracts_dev.ssa"; then
  echo "FAIL: dev build missing pion_debug_assert" >&2
  exit 1
fi
set +e
"$TMP_DIR/contracts_dev" 2>/dev/null
DEV_RC=$?
set -e
echo "contracts dev exit code: $DEV_RC (expected non-zero)"
if [ "$DEV_RC" -eq 0 ]; then
  echo "FAIL: dev build did not abort on debug_assert" >&2
  exit 1
fi

"$PIONC2" build --release --emit-ssa "$TMP_DIR/contracts_rel.ssa" -o "$TMP_DIR/contracts_rel" "$ROOT_DIR/tests/e2e/contracts.pion"
if grep -q "pion_debug_assert" "$TMP_DIR/contracts_rel.ssa"; then
  echo "FAIL: --release SSA still contains pion_debug_assert!" >&2
  exit 1
fi
REL_OUT=$("$TMP_DIR/contracts_rel")
echo "contracts --release output: '$REL_OUT'"
if [ "$REL_OUT" != "release ok" ]; then
  echo "FAIL: release output mismatch" >&2
  exit 1
fi

echo "=== [9/9] Standalone pionc2 Gate: Global CAS + Incremental Speed + LRU Eviction + Zero target/ ==="
SRC_DIR="$TMP_DIR/pkg_cas"
mkdir -p "$SRC_DIR"
cat > "$SRC_DIR/main.pion" <<'EOF'
pub fn compute(x : Int) -> Int {
  x * 2 + 1
}
pub fn main(world : World) -> Int {
  io_println(world, compute(20).to_string())
  0
}
EOF

BEFORE_FILES=$(ls -A "$SRC_DIR" | tr '\n' ' ')
TC0=$(now_ms)
"$PIONC2" build "$SRC_DIR"
TC1=$(now_ms)
COLD_MS=$((TC1 - TC0))

TH0=$(now_ms)
"$PIONC2" build "$SRC_DIR"
TH1=$(now_ms)
HOT_MS=$((TH1 - TH0))

SIG1=$("$PIONC2" emit-sig "$SRC_DIR")
cat > "$SRC_DIR/main.pion" <<'EOF'
pub fn compute(x : Int) -> Int {
  x * 3 - 19
}
pub fn main(world : World) -> Int {
  io_println(world, compute(20).to_string())
  0
}
EOF
SIG2=$("$PIONC2" emit-sig "$SRC_DIR")
if [ "$SIG1" != "$SIG2" ]; then
  echo "FAIL: .pionsig changed on body-only edit!" >&2
  exit 1
fi

TI0=$(now_ms)
"$PIONC2" build "$SRC_DIR"
TI1=$(now_ms)
INCR_MS=$((TI1 - TI0))

AFTER_FILES=$(ls -A "$SRC_DIR" | tr '\n' ' ')
echo "CAS timing (pionc2): cold=${COLD_MS}ms, hot=${HOT_MS}ms, body-edit-incr=${INCR_MS}ms"
echo "Source dir files before='${BEFORE_FILES}' after='${AFTER_FILES}'"
if [ "$BEFORE_FILES" != "$AFTER_FILES" ]; then
  echo "FAIL: source dir polluted with build artifacts!" >&2
  exit 1
fi

RUN_OUT=$("$PIONC2" run "$SRC_DIR")
if [ "$RUN_OUT" != "41" ]; then
  echo "FAIL: pionc2 run output mismatch: '$RUN_OUT'" >&2
  exit 1
fi

LRU_CAS="$TMP_DIR/cas_lru"
mkdir -p "$LRU_CAS"
for k in 1 2 3 4 5; do
  F="$TMP_DIR/lru_${k}.pion"
  printf 'pub fn main(world : World) -> Int {\n  io_println(world, "item-%s")\n  0\n}\n' "$k" > "$F"
  PION_CACHE_DIR="$LRU_CAS" PION_CACHE_MAX_KB=4 "$PIONC2" build "$F"
done
INDEX_LINES=$(wc -l < "$LRU_CAS/index.tsv" | tr -d ' ')
OBJ_FILES=$(ls "$LRU_CAS/obj" | wc -l | tr -d ' ')
echo "LRU eviction test (5 builds, 4KB cap): index entries=${INDEX_LINES}, obj files=${OBJ_FILES}"
if [ "$INDEX_LINES" -ge 5 ] || [ "$OBJ_FILES" -ge 5 ]; then
  echo "FAIL: LRU eviction did not evict old CAS entries!" >&2
  exit 1
fi

echo "=== SUMMARY ==="
echo "Stage 0 (pionc0): ${S0_MS} ms | ${S0_BYTES} bytes"
echo "Stage 1 (pionc1): ${S1_MS} ms | ${S1_BYTES} bytes | stage1.ssa=${S1_SSA_LINES} lines"
echo "Stage 2 (pionc2): ${S2_MS} ms | ${S2_BYTES} bytes | stage2.ssa=${S2_SSA_LINES} lines"
echo "ALL 9 D4 BOOTSTRAP & STANDALONE PIONC2 GATES PASSED!"
