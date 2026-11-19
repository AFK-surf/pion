#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
QBE_DIR="$ROOT_DIR/vendor/qbe"
OUT_BIN="${1:-$ROOT_DIR/out/qbe}"
BUILD_DIR="$ROOT_DIR/out/qbe-build"

mkdir -p "$(dirname -- "$OUT_BIN")" "$BUILD_DIR"

# Generate config.h outside vendor/qbe so the source tree stays clean
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
    *Darwin*)
        case "$ARCH" in
            *arm64*) DEFTGT="T_arm64_apple" ;;
            *)       DEFTGT="T_amd64_apple" ;;
        esac
        ;;
    *)
        case "$ARCH" in
            *aarch64*|*arm64*) DEFTGT="T_arm64" ;;
            *riscv64*)         DEFTGT="T_rv64" ;;
            *)                 DEFTGT="T_amd64_sysv" ;;
        esac
        ;;
esac
printf '#define Deftgt %s\n' "$DEFTGT" > "$BUILD_DIR/config.h"

CC="${CC:-clang}"
T0="$(python3 -c 'import time; print(int(time.time()*1000))')"

SRCS="main util parse abi cfg mem ssa alias load copy fold gvn gcm simpl ifopt live spill rega emit \
amd64/targ amd64/sysv amd64/isel amd64/emit amd64/winabi \
arm64/targ arm64/abi arm64/isel arm64/emit arm64/macho \
rv64/targ rv64/abi rv64/isel rv64/emit"

mkdir -p "$BUILD_DIR/amd64" "$BUILD_DIR/arm64" "$BUILD_DIR/rv64"

PIDS=""
OBJS=""
for s in $SRCS; do
    obj="$BUILD_DIR/$s.o"
    OBJS="$OBJS $obj"
    "$CC" -std=c99 -O2 -I"$BUILD_DIR" -I"$QBE_DIR" -c "$QBE_DIR/$s.c" -o "$obj" &
    PIDS="$PIDS $!"
done
for pid in $PIDS; do
    wait "$pid"
done

"$CC" -O2 $OBJS -o "$OUT_BIN"

T1="$(python3 -c 'import time; print(int(time.time()*1000))')"
SIZE="$(wc -c < "$OUT_BIN" | tr -d ' ')"
echo "Built $OUT_BIN (default target: $DEFTGT) in $((T1 - T0)) ms, size: $SIZE bytes"
