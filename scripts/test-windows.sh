#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/out"
RT_DIR="$ROOT_DIR/runtime"
CC="${CC:-gcc}"

mkdir -p "$OUT_DIR"

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== [1/5] Windows x86_64 Environment & QBE (T_amd64_win) Build ==="
uname -a
"$CC" --version | head -n 1
CC="$CC" sh "$ROOT_DIR/scripts/build-qbe.sh" "$OUT_DIR/qbe.exe"

echo "=== [2/5] Build Win32 libpionrt.a & Run test_rt.c ==="
"$CC" -std=c11 -O2 -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident \
  -Wall -Wextra -Werror -c "$RT_DIR/pion_rt.c" -o "$OUT_DIR/pion_rt.o"
rm -f "$OUT_DIR/libpionrt.a"
ar rcs "$OUT_DIR/libpionrt.a" "$OUT_DIR/pion_rt.o"
LIB_SIZE="$(wc -c < "$OUT_DIR/libpionrt.a" | tr -d ' ')"
echo "Windows x86_64 libpionrt.a size: ${LIB_SIZE} bytes"
if [ "$LIB_SIZE" -ge 65536 ]; then
  echo "FAIL: libpionrt.a (${LIB_SIZE} bytes) exceeds 64 KB budget" >&2
  exit 1
fi

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -I"$RT_DIR" \
  "$RT_DIR/test_rt.c" "$OUT_DIR/libpionrt.a" -lm -lws2_32 -o "$OUT_DIR/test_rt_win.exe"
if ! "$OUT_DIR/test_rt_win.exe" > "$TMP_DIR/test_rt.out" 2>&1; then
  cat "$TMP_DIR/test_rt.out"
  exit 1
fi
cat "$TMP_DIR/test_rt.out"
grep -q 'tcp_loopback_mt (4 concurrent TCP clients on 127.0.0.1' "$TMP_DIR/test_rt.out" || {
  echo "FAIL: tcp_loopback_mt did not run the real 127.0.0.1 TCP loopback on Windows" >&2
  exit 1
}

echo "=== [3/5] Native Windows x86_64 pionc Bootstrap from bootstrap/pionc-seed.ssa.gz ==="
SEED_SSA="$TMP_DIR/pionc-seed.ssa"
gzip -dc "$ROOT_DIR/bootstrap/pionc-seed.ssa.gz" > "$SEED_SSA"

T_B0="$(now_ms)"
"$OUT_DIR/qbe.exe" -t amd64_win -o "$TMP_DIR/pionc_win.s" "$SEED_SSA"
"$CC" -c "$TMP_DIR/pionc_win.s" -o "$OUT_DIR/pionc_win.o"
"$CC" "$OUT_DIR/pionc_win.o" "$OUT_DIR/libpionrt.a" -lm -lws2_32 -o "$OUT_DIR/pionc_win.exe"
T_B1="$(now_ms)"
PIONC_SIZE="$(wc -c < "$OUT_DIR/pionc_win.exe" | tr -d ' ')"
echo "Native Windows x86_64 pionc_win.exe: assemble+link=$((T_B1 - T_B0))ms, size=${PIONC_SIZE} bytes"
"$OUT_DIR/pionc_win.exe" --version

export PION_QBE="$OUT_DIR/qbe.exe"
export PION_RT_LIB="$OUT_DIR/libpionrt.a"
export PION_CACHE_DIR="$TMP_DIR/cas_win"
mkdir -p "$PION_CACHE_DIR"

echo "=== [4/5] Windows Native Self-Hosting Fixed-Point (Stage 3 == Stage 4) ==="
T_S3_0="$(now_ms)"
(cd "$ROOT_DIR" && PION_TARGET="amd64_win" "$OUT_DIR/pionc_win.exe" build \
  --emit-ssa "$TMP_DIR/win_stage3.ssa" \
  -o "$TMP_DIR/pionc_win_s3.exe" \
  compiler/src/core \
  compiler/src/cli/main.pion)
T_S3_1="$(now_ms)"
S3_SIZE="$(wc -c < "$TMP_DIR/pionc_win_s3.exe" | tr -d ' ')"
echo "Windows x86_64 native self-host Stage 3: build=$((T_S3_1 - T_S3_0))ms, binary=${S3_SIZE} bytes"

# Stage 4 runs with PION_TARGET unset to prove pionc_win_s3 auto-detects Windows -> amd64_win!
unset PION_TARGET || true
T_S4_0="$(now_ms)"
(cd "$ROOT_DIR" && PION_CACHE_DIR="$TMP_DIR/cas_win_s4" "$TMP_DIR/pionc_win_s3.exe" build \
  --emit-ssa "$TMP_DIR/win_stage4.ssa" \
  -o "$TMP_DIR/pionc_win_s4.exe" \
  compiler/src/core \
  compiler/src/cli/main.pion)
T_S4_1="$(now_ms)"
S4_SIZE="$(wc -c < "$TMP_DIR/pionc_win_s4.exe" | tr -d ' ')"
echo "Windows x86_64 native self-host Stage 4: build=$((T_S4_1 - T_S4_0))ms, binary=${S4_SIZE} bytes"

"$TMP_DIR/pionc_win_s4.exe" --version
cmp "$TMP_DIR/win_stage3.ssa" "$TMP_DIR/win_stage4.ssa"
"$OUT_DIR/qbe.exe" -t amd64_win -o "$TMP_DIR/win_stage3.s" "$TMP_DIR/win_stage3.ssa"
"$OUT_DIR/qbe.exe" -t amd64_win -o "$TMP_DIR/win_stage4.s" "$TMP_DIR/win_stage4.ssa"
cmp "$TMP_DIR/win_stage3.s" "$TMP_DIR/win_stage4.s"
echo "[PASS] Windows x86_64 (amd64_win) Native Self-Hosting Fixed-Point (Stage 3 == Stage 4 SSA & ASM BIT-FOR-BIT IDENTICAL)!"

cp "$TMP_DIR/pionc_win_s4.exe" "$OUT_DIR/pionc_win.exe"
PIONC="$OUT_DIR/pionc_win.exe"

echo "=== [5/5] Native Windows x86_64 pionc: core / std / e2e / V1 Benchmark Checksums ==="
CORE_TEST_JSON="$("$PIONC" test --json "$ROOT_DIR/compiler/src/core")"
CORE_TEST_SUMMARY="$(printf '%s' "$CORE_TEST_JSON" | python3 -c 'import json, sys; d = json.load(sys.stdin); print("ok=%s passed=%d failed=%d total=%d" % (d.get("ok"), d.get("passed", 0), d.get("failed", 0), len(d.get("tests", []))))')"
echo "pionc_win test --json compiler/src/core -> $CORE_TEST_SUMMARY"
printf '%s' "$CORE_TEST_JSON" | grep -q '"ok":true'
printf '%s' "$CORE_TEST_JSON" | grep -q '"failed":0'

for TPKG in examples/text_stats std/json std/http std/regex; do
  PKG_JSON="$("$PIONC" test --json "$ROOT_DIR/$TPKG")"
  echo "pionc_win test --json $TPKG -> $PKG_JSON"
  printf '%s' "$PKG_JSON" | grep -q '"ok":true'
  printf '%s' "$PKG_JSON" | grep -q '"failed":0'
done

P27A_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/p27a_ergonomics_bug4.pion" | tr -d '\r')"
echo "pionc_win run p27a_ergonomics_bug4 -> $P27A_OUT"
if [ "$P27A_OUT" != "p27a_ergonomics_bug4 ok" ]; then
  echo "FAIL: p27a_ergonomics_bug4 output mismatch: '$P27A_OUT'" >&2
  exit 1
fi

sh "$ROOT_DIR/tests/e2e/p27c2_float_uint_fixedarray/run_e2e.sh" "$PIONC"

verify_bench() {
  name="$1"
  expected="$2"
  shift 2
  tb0="$(now_ms)"
  got="$("$PIONC" run --release "$ROOT_DIR/benchmarks/pion/${name}.pion" "$@" | tr -d '\r')"
  tb1="$(now_ms)"
  echo "WINDOWS_X64 ${name}: $((tb1 - tb0))ms out='${got}'"
  if [ "$got" != "$expected" ]; then
    echo "FAIL: ${name} checksum mismatch! expected='${expected}' got='${got}'" >&2
    exit 1
  fi
}

verify_bench nbody "-0.169075164 -0.169083134"
verify_bench binarytrees "stretch=262143 long=131071 total=14592688"
verify_bench fannkuchredux "73196 38"
verify_bench mandelbrot_mt "6351041 721219984" -- 4
verify_bench hashmap_str "200000 208681440 205599 815496841"

echo "ALL WINDOWS X86_64 (amd64_win) NATIVE BUILD, SELF-HOST & BENCHMARK CHECKSUM GATES PASSED!"
