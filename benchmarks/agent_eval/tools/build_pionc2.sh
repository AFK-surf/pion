#!/bin/sh
# Minimal pionc0 -> pionc1 -> pionc2 bootstrap for the agent_eval suite (no runtime
# sanitizer gates; scripts/bootstrap.sh is the full proof). Outputs land in
# <repo>/out (git-ignored).
set -eu
export PATH="$HOME/.moon/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT_DIR="$ROOT_DIR/out"
mkdir -p "$OUT_DIR"
CC="${CC:-clang}"
if [ ! -x "$OUT_DIR/qbe" ]; then
  sh "$ROOT_DIR/scripts/build-qbe.sh" "$OUT_DIR/qbe"
fi
if [ ! -f "$OUT_DIR/libpionrt.a" ]; then
  "$CC" -std=c11 -O2 -fno-asynchronous-unwind-tables -Wall -Wextra -Werror -c "$ROOT_DIR/runtime/pion_rt.c" -o "$OUT_DIR/pion_rt.o"
  ar rcs "$OUT_DIR/libpionrt.a" "$OUT_DIR/pion_rt.o"
fi
export PION_QBE="$OUT_DIR/qbe"
export PION_RT_LIB="$OUT_DIR/libpionrt.a"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
(cd "$ROOT_DIR/compiler" && moon build --target native --release)
cp "$ROOT_DIR/compiler/_build/native/release/build/compat_moon/compat_moon.exe" "$OUT_DIR/pionc0"
PION_CACHE_DIR="$TMP/c1" "$OUT_DIR/pionc0" build -o "$OUT_DIR/pionc1" "$ROOT_DIR/compiler/src/core" "$ROOT_DIR/compiler/src/compat_pion/main.pion"
PION_CACHE_DIR="$TMP/c2" "$OUT_DIR/pionc1" build -o "$OUT_DIR/pionc2" "$ROOT_DIR/compiler/src/core" "$ROOT_DIR/compiler/src/compat_pion/main.pion"
echo "built $OUT_DIR/pionc2 ($(wc -c < "$OUT_DIR/pionc2" | tr -d ' ') bytes)"
