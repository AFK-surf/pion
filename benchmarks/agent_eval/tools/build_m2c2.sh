#!/bin/sh
# Minimal m2c0 -> m2c1 -> m2c2 bootstrap for the agent_eval suite (no runtime
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
if [ ! -f "$OUT_DIR/libm2rt.a" ]; then
  "$CC" -std=c11 -O2 -Wall -Wextra -Werror -c "$ROOT_DIR/runtime/m2_rt.c" -o "$OUT_DIR/m2_rt.o"
  ar rcs "$OUT_DIR/libm2rt.a" "$OUT_DIR/m2_rt.o"
fi
export M2_QBE="$OUT_DIR/qbe"
export M2_RT_LIB="$OUT_DIR/libm2rt.a"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
(cd "$ROOT_DIR/compiler" && moon build --target native --release)
cp "$ROOT_DIR/compiler/_build/native/release/build/compat_moon/compat_moon.exe" "$OUT_DIR/m2c0"
M2_CACHE_DIR="$TMP/c1" "$OUT_DIR/m2c0" build -o "$OUT_DIR/m2c1" "$ROOT_DIR/compiler/src/core" "$ROOT_DIR/compiler/src/compat_m2/main.m2"
M2_CACHE_DIR="$TMP/c2" "$OUT_DIR/m2c1" build -o "$OUT_DIR/m2c2" "$ROOT_DIR/compiler/src/core" "$ROOT_DIR/compiler/src/compat_m2/main.m2"
echo "built $OUT_DIR/m2c2 ($(wc -c < "$OUT_DIR/m2c2" | tr -d ' ') bytes)"
