#!/bin/sh
set -eu

export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPILER_DIR="$ROOT_DIR/compiler"
PIONC="${PIONC:-$ROOT_DIR/out/pionc2}"

if [ ! -x "$PIONC" ]; then
  sh "$ROOT_DIR/scripts/bootstrap.sh"
fi

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

export PION_QBE="$ROOT_DIR/out/qbe"
export PION_RT_LIB="$ROOT_DIR/out/libpionrt.a"
export PION_CACHE_DIR="$TMP_DIR/cas"

echo "=== [1/8] Build QBE + Runtime (TSan/ASan/bench) ==="
sh "$ROOT_DIR/scripts/build-qbe.sh" "$PION_QBE"
sh "$ROOT_DIR/scripts/test-runtime.sh"

echo "=== [2/8] Frontend + Self-check + Compiler Unit Tests ==="
PIONC="$PIONC" sh "$ROOT_DIR/scripts/test-frontend.sh"

echo "=== [3/8] E2E hello.pion (output + binary size < 80 KB) ==="
T0=$(now_ms)
"$PIONC" build -o "$TMP_DIR/hello" "$ROOT_DIR/tests/e2e/hello.pion"
T1=$(now_ms)
HELLO_SIZE=$(wc -c < "$TMP_DIR/hello" | tr -d ' ')
HELLO_OUT=$("$TMP_DIR/hello")
echo "hello.pion: cold build=$((T1 - T0)) ms, binary=${HELLO_SIZE} bytes, output='${HELLO_OUT}'"
if [ "$HELLO_OUT" != "hello pion" ]; then
  echo "FAIL: hello.pion output mismatch: '$HELLO_OUT'" >&2
  exit 1
fi
if [ "$HELLO_SIZE" -ge 81920 ]; then
  echo "FAIL: hello binary (${HELLO_SIZE} bytes) exceeds 80 KB (81920 bytes)" >&2
  exit 1
fi

echo "=== [4/8] E2E adt_generics.pion (ADT, mut struct, generics, containers, closures, i32 wrap) ==="
"$PIONC" build -o "$TMP_DIR/adt_generics" "$ROOT_DIR/tests/e2e/adt_generics.pion"
ADT_OUT=$("$TMP_DIR/adt_generics")
echo "$ADT_OUT"
ADT_EXP=$(printf 'ast=49\nbox=boxed:42\narr=28,len=3,cplen=5\nmap=100,has_beta=false,cp_beta=200,len=2\nsb=pion-ok\nclo=43\ni32wrap=true')
if [ "$ADT_OUT" != "$ADT_EXP" ]; then
  echo "FAIL: adt_generics.pion output mismatch! Expected:" >&2
  echo "$ADT_EXP" >&2
  exit 1
fi

echo "=== [5/8] E2E multicore_bench.pion (scope + 4x spawn + Channel + Mutex + AtomicInt > 3.0x) ==="
"$PIONC" build -o "$TMP_DIR/multicore_bench" "$ROOT_DIR/tests/e2e/multicore_bench.pion"
BENCH_NCPUS=""
case "${PION_BENCH_NCPUS:-}" in
  ""|*[!0-9]*) ;;
  *)
    _ov=$(awk -v s="${PION_BENCH_NCPUS}" 'BEGIN { v=0; for(i=1;i<=length(s);i++){ d=substr(s,i,1)+0; if(v<1000000){ v=v*10+d; if(v>1000000) v=1000000 } } if(v>0) print v }')
    if [ -n "$_ov" ]; then BENCH_NCPUS="$_ov"; fi
    ;;
esac
if [ -z "$BENCH_NCPUS" ]; then
  BENCH_NCPUS="$(sysctl -n hw.activecpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
  _cg_root="${PION_TEST_CGROUP_ROOT:-/sys/fs/cgroup}"
  _cg_proc="${PION_TEST_PROC_CGROUP:-/proc/self/cgroup}"
  if [ -r "$_cg_proc" ] && [ -d "$_cg_root" ]; then
    _cg_rel=$(awk -F: '$1 == "0" && $2 == "" { sub(/^0::/, ""); print; exit }' "$_cg_proc" 2>/dev/null || true)
    _cg_cur="${_cg_root}${_cg_rel}"
    while :; do
      if [ -r "$_cg_cur/cpu.max" ]; then
        _cg=$(awk 'NR==1 && $1 != "max" && $2 > 0 { q=int($1/$2); if (q<1) q=1; print q }' "$_cg_cur/cpu.max" 2>/dev/null || true)
        if [ -n "$_cg" ] && [ "$_cg" -lt "$BENCH_NCPUS" ] 2>/dev/null; then BENCH_NCPUS="$_cg"; fi
      fi
      [ "$_cg_cur" = "$_cg_root" ] && break
      _cg_parent="${_cg_cur%/*}"
      [ -z "$_cg_parent" ] || [ "$_cg_parent" = "$_cg_cur" ] && break
      _cg_cur="$_cg_parent"
    done
  fi
fi
PION_BENCH_NCPUS="$BENCH_NCPUS" "$TMP_DIR/multicore_bench"

echo "=== [6/8] E2E contracts.pion (dev debug_assert aborts, --release strips to 0 bytes) ==="
"$PIONC" build --emit-ssa "$TMP_DIR/contracts_dev.ssa" -o "$TMP_DIR/contracts_dev" "$ROOT_DIR/tests/e2e/contracts.pion"
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

"$PIONC" build --release --emit-ssa "$TMP_DIR/contracts_rel.ssa" -o "$TMP_DIR/contracts_rel" "$ROOT_DIR/tests/e2e/contracts.pion"
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

echo "=== [7/8] CAS Cache + Zero target/ + Incremental Speed + LRU Eviction ==="
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
"$PIONC" build "$SRC_DIR"
TC1=$(now_ms)
COLD_MS=$((TC1 - TC0))

TH0=$(now_ms)
"$PIONC" build "$SRC_DIR"
TH1=$(now_ms)
HOT_MS=$((TH1 - TH0))

SIG1=$("$PIONC" emit-sig "$SRC_DIR")

# Edit function body without changing pub signature
cat > "$SRC_DIR/main.pion" <<'EOF'
pub fn compute(x : Int) -> Int {
  x * 3 - 19
}
pub fn main(world : World) -> Int {
  io_println(world, compute(20).to_string())
  0
}
EOF

SIG2=$("$PIONC" emit-sig "$SRC_DIR")
if [ "$SIG1" != "$SIG2" ]; then
  echo "FAIL: .pionsig changed on body-only edit!" >&2
  exit 1
fi

TI0=$(now_ms)
"$PIONC" build "$SRC_DIR"
TI1=$(now_ms)
INCR_MS=$((TI1 - TI0))

AFTER_FILES=$(ls -A "$SRC_DIR" | tr '\n' ' ')
echo "CAS timing: cold=${COLD_MS}ms, hot=${HOT_MS}ms, body-edit-incr=${INCR_MS}ms"
echo "Source dir files before='${BEFORE_FILES}' after='${AFTER_FILES}'"
if [ "$BEFORE_FILES" != "$AFTER_FILES" ]; then
  echo "FAIL: source dir polluted with build artifacts!" >&2
  exit 1
fi

# Verify pionc run works cleanly too
RUN_OUT=$("$PIONC" run "$SRC_DIR")
if [ "$RUN_OUT" != "41" ]; then
  echo "FAIL: pionc run output mismatch: '$RUN_OUT'" >&2
  exit 1
fi

# Test LRU eviction under tiny PION_CACHE_MAX_KB quota (4 KB)
LRU_CAS="$TMP_DIR/cas_lru"
mkdir -p "$LRU_CAS"
for k in 1 2 3 4 5; do
  F="$TMP_DIR/lru_${k}.pion"
  printf 'pub fn main(world : World) -> Int {\n  io_println(world, "item-%s")\n  0\n}\n' "$k" > "$F"
  PION_CACHE_DIR="$LRU_CAS" PION_CACHE_MAX_KB=4 "$PIONC" build "$F"
done
INDEX_LINES=$(wc -l < "$LRU_CAS/index.tsv" | tr -d ' ')
OBJ_FILES=$(ls "$LRU_CAS/obj" | wc -l | tr -d ' ')
echo "LRU eviction test (5 builds, 4KB cap): index entries=${INDEX_LINES}, obj files=${OBJ_FILES}"
if [ "$INDEX_LINES" -ge 5 ] || [ "$OBJ_FILES" -ge 5 ]; then
  echo "FAIL: LRU eviction did not evict old CAS entries!" >&2
  exit 1
fi

echo "=== [8/8] D4 Pre-check: Lower entire compiler/src/core -> QBE IL -> arm64_apple asm ==="
CORE_SSA="$TMP_DIR/pion_core_preview.ssa"
T_CORE0=$(now_ms)
"$PIONC" build --emit-ssa "$CORE_SSA" "$COMPILER_DIR/src/core"
T_CORE1=$(now_ms)
CORE_LINES=$(wc -l < "$CORE_SSA" | tr -d ' ')
CORE_BYTES=$(wc -c < "$CORE_SSA" | tr -d ' ')
"$PION_QBE" -t arm64_apple -o "$TMP_DIR/pion_core_preview.s" "$CORE_SSA"
as -o "$TMP_DIR/pion_core_preview.o" "$TMP_DIR/pion_core_preview.s"
CORE_OBJ_BYTES=$(wc -c < "$TMP_DIR/pion_core_preview.o" | tr -d ' ')
echo "D4 pre-check PASS: compiler/src/core -> ${CORE_LINES} lines (${CORE_BYTES} bytes) QBE IL -> ${CORE_OBJ_BYTES} bytes arm64 .o in $((T_CORE1 - T_CORE0)) ms"

echo "ALL 8 BACKEND GATES PASSED!"
