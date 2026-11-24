#!/bin/sh
# Build the release toolchain for this host from bootstrap/pionc-seed.ssa.gz:
#   out/qbe[.exe], out/libpionrt.a (< 65,536 B gate), out/libpionrt_cli.a and
#   out/pionc_release[.exe] = seed -> stage 1 (this tree, dev) -> stage 2 (this tree, --release).
# The --release compiler then rebuilds itself and must emit bit-identical SSA,
# proving the --release binary behaves exactly like the dev-built compiler.
# Runtime flags match the CI gates: scripts/test-runtime.sh (macOS ARM64),
# scripts/test-linux.sh (Linux x86_64 / aarch64) and scripts/test-windows.sh (MSYS2 UCRT64).
# Usage: sh scripts/build-release.sh   (then: PIONC=out/pionc_release sh scripts/package-release.sh dist)
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="$ROOT_DIR/out"
RT_DIR="$ROOT_DIR/runtime"
mkdir -p "$OUT_DIR"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

UNAME_S=$(uname -s)
UNAME_M=$(uname -m)
EXE=""
LINK_LIBS="-lm -lpthread"
STRIP_CMD="strip --strip-unneeded"
SEED_OBJ=0          # 1: `qbe --obj` emits ELF64 directly (no `as`)
SEED_ASFLAGS=""
STAGE1_TARGET=""    # PION_TARGET for the seed-driven stage 1 (seeds may predate host auto-detection)
STAGE1_SPLIT_LINK=0 # 1: the seed's driver cannot link this host, link stage 1 here
case "$UNAME_S:$UNAME_M" in
  Darwin:arm64)
    CC="${CC:-clang}"
    RT_FLAGS="-O2 -fno-asynchronous-unwind-tables"
    STRIP_CMD="strip -x"
    QBE_TARGET="arm64_apple"
    ;;
  Linux:x86_64)
    CC="${CC:-cc}"
    RT_FLAGS="-O2 -fPIC -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident"
    QBE_TARGET="amd64_sysv"
    SEED_OBJ=1
    ;;
  Linux:aarch64|Linux:arm64)
    CC="${CC:-cc}"
    RT_FLAGS="-Os -mbranch-protection=none -fno-stack-protector -fPIC -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident"
    QBE_TARGET="arm64"
    STAGE1_TARGET="arm64"
    ;;
  MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64)
    CC="${CC:-gcc}"
    RT_FLAGS="-O2 -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident"
    STRIP_CMD=""
    QBE_TARGET="amd64_win"
    EXE=".exe"
    LINK_LIBS="-lm -lws2_32 -Wl,--stack,16777216"
    SEED_ASFLAGS="-Wa,-mbig-obj"
    STAGE1_TARGET="amd64_win"
    STAGE1_SPLIT_LINK=1
    ;;
  *)
    echo "FAIL: unsupported release host $UNAME_S/$UNAME_M" >&2
    exit 1
    ;;
esac

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

QBE="$OUT_DIR/qbe$EXE"
RT_LIB="$OUT_DIR/libpionrt.a"
RT_CLI_LIB="$OUT_DIR/libpionrt_cli.a"
RELEASE_BIN="$OUT_DIR/pionc_release$EXE"

echo "=== [1/5] QBE ($QBE_TARGET) ==="
"$CC" --version | head -n 1
CC="$CC" sh "$ROOT_DIR/scripts/build-qbe.sh" "$QBE"

echo "=== [2/5] libpionrt.a / libpionrt_cli.a ($RT_FLAGS) ==="
# shellcheck disable=SC2086
"$CC" -std=c11 $RT_FLAGS -Wall -Wextra -Werror -c "$RT_DIR/pion_rt.c" -o "$OUT_DIR/pion_rt.o"
if [ -n "$STRIP_CMD" ]; then
  $STRIP_CMD "$OUT_DIR/pion_rt.o"
fi
rm -f "$RT_LIB"
ar rcs "$RT_LIB" "$OUT_DIR/pion_rt.o"
LIB_SIZE=$(wc -c < "$RT_LIB" | tr -d ' ')
echo "libpionrt.a: ${LIB_SIZE} bytes"
if [ "$LIB_SIZE" -ge 65536 ]; then
  echo "FAIL: libpionrt.a (${LIB_SIZE} bytes) exceeds the 64 KB budget (65536 bytes)" >&2
  exit 1
fi
# shellcheck disable=SC2086
"$CC" -std=c11 $RT_FLAGS -Wall -Wextra -Werror -c "$RT_DIR/pion_cli.c" -o "$OUT_DIR/pion_cli.o"
rm -f "$RT_CLI_LIB"
ar rcs "$RT_CLI_LIB" "$OUT_DIR/pion_rt.o" "$OUT_DIR/pion_cli.o"

echo "=== [3/5] Seed: bootstrap/pionc-seed.ssa.gz -> pionc_seed$EXE ==="
gzip -dc "$ROOT_DIR/bootstrap/pionc-seed.ssa.gz" > "$TMP_DIR/seed.ssa"
SEED_BIN="$TMP_DIR/pionc_seed$EXE"
if [ "$SEED_OBJ" -eq 1 ]; then
  "$QBE" -t "$QBE_TARGET" --obj -o "$TMP_DIR/seed.o" "$TMP_DIR/seed.ssa"
else
  "$QBE" -t "$QBE_TARGET" -o "$TMP_DIR/seed.s" "$TMP_DIR/seed.ssa"
  # shellcheck disable=SC2086
  "$CC" $SEED_ASFLAGS -c "$TMP_DIR/seed.s" -o "$TMP_DIR/seed.o"
fi
# shellcheck disable=SC2086
"$CC" "$TMP_DIR/seed.o" "$RT_CLI_LIB" $LINK_LIBS -o "$SEED_BIN"
"$SEED_BIN" --version

export PION_QBE="$QBE"
export PION_RT_LIB="$RT_CLI_LIB"
unset PION_TARGET PION_SRC PION_REGISTRY || true
cd "$ROOT_DIR"

echo "=== [4/5] Stage 1: seed -> pionc_s1$EXE (this tree, dev build) ==="
S1_BIN="$TMP_DIR/pionc_s1$EXE"
T0=$(now_ms)
if [ "$STAGE1_SPLIT_LINK" -eq 1 ]; then
  # The seed's driver predates amd64_win linking (no -lws2_32 / --stack): stop at
  # the object and link it here, exactly like scripts/test-windows.sh Stage 3.
  PION_TARGET="$STAGE1_TARGET" PION_CACHE_DIR="$TMP_DIR/cas_s1" "$SEED_BIN" build \
    --emit-obj "$TMP_DIR/pionc_s1.o" compiler/src/core compiler/src/cli/main.pion
  # shellcheck disable=SC2086
  "$CC" "$TMP_DIR/pionc_s1.o" "$RT_CLI_LIB" $LINK_LIBS -o "$S1_BIN"
elif [ -n "$STAGE1_TARGET" ]; then
  PION_TARGET="$STAGE1_TARGET" PION_CACHE_DIR="$TMP_DIR/cas_s1" "$SEED_BIN" build \
    -o "$S1_BIN" compiler/src/core compiler/src/cli/main.pion
else
  PION_CACHE_DIR="$TMP_DIR/cas_s1" "$SEED_BIN" build \
    -o "$S1_BIN" compiler/src/core compiler/src/cli/main.pion
fi
echo "stage 1: $(( $(now_ms) - T0 )) ms, $(wc -c < "$S1_BIN" | tr -d ' ') bytes"
"$S1_BIN" --version

echo "=== [5/5] Stage 2: pionc_s1 --release -> out/pionc_release$EXE, then --release self-rebuild fixed point ==="
T0=$(now_ms)
PION_CACHE_DIR="$TMP_DIR/cas_rel" "$S1_BIN" build --release \
  --emit-ssa "$TMP_DIR/release_a.ssa" -o "$RELEASE_BIN" compiler/src/core compiler/src/cli/main.pion
echo "pionc_release: $(( $(now_ms) - T0 )) ms, $(wc -c < "$RELEASE_BIN" | tr -d ' ') bytes"
"$RELEASE_BIN" --version
T0=$(now_ms)
PION_CACHE_DIR="$TMP_DIR/cas_rel2" "$RELEASE_BIN" build --release \
  --emit-ssa "$TMP_DIR/release_b.ssa" -o "$TMP_DIR/pionc_release_b$EXE" compiler/src/core compiler/src/cli/main.pion
echo "pionc_release self-rebuild: $(( $(now_ms) - T0 )) ms"
if ! cmp "$TMP_DIR/release_a.ssa" "$TMP_DIR/release_b.ssa"; then
  echo "FAIL: the --release pionc emits different SSA for compiler/src than the dev stage 1" >&2
  exit 1
fi
echo "[PASS] --release fixed point: stage 1 and pionc_release emit bit-identical --release SSA"

DOC_JSON=$(PION_RT_LIB="$RT_LIB" PION_CACHE_DIR="$TMP_DIR/cas_doc" "$RELEASE_BIN" doctor --json | tr -d '\r')
printf '%s\n' "$DOC_JSON"
printf '%s' "$DOC_JSON" | grep -q '"ok":true' || {
  echo "FAIL: pionc_release doctor --json is not ok" >&2
  exit 1
}
echo "Release toolchain ready: $RELEASE_BIN, $QBE, $RT_LIB (${LIB_SIZE} B)"
