#!/bin/sh
# Install the relocatable Pion toolchain to PREFIX (default: $HOME/.pion).
# Usage: sh scripts/install.sh [--prefix <dir>] [--no-bootstrap]
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="$ROOT_DIR/out"
PREFIX="${HOME:-/tmp}/.pion"
NO_BOOTSTRAP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      [ $# -ge 2 ] || { echo "error: --prefix requires a directory" >&2; exit 1; }
      PREFIX="$2"
      shift 2
      ;;
    --prefix=*)
      PREFIX="${1#--prefix=}"
      shift
      ;;
    --no-bootstrap)
      NO_BOOTSTRAP=1
      shift
      ;;
    -h|--help)
      echo "usage: sh scripts/install.sh [--prefix <dir>] [--no-bootstrap]"
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

UNAME_S=$(uname -s)
EXE_EXT=""
case "$UNAME_S" in
  MINGW*|MSYS*|CYGWIN*) EXE_EXT=".exe" ;;
esac

find_pionc() {
  for cand in \
    "$OUT_DIR/pionc2${EXE_EXT}" \
    "$OUT_DIR/pionc_linux" \
    "$OUT_DIR/pionc_win.exe" \
    "$OUT_DIR/pionc${EXE_EXT}"; do
    if [ -f "$cand" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

PIONC_BIN=""
if ! PIONC_BIN=$(find_pionc); then
  if [ "$NO_BOOTSTRAP" -eq 1 ]; then
    echo "FAIL: no built pionc found in $OUT_DIR and --no-bootstrap was set" >&2
    exit 1
  fi
  echo "Bootstrapping pionc..."
  if [ "$UNAME_S" = "Linux" ]; then
    mkdir -p "$OUT_DIR"
    CC_BIN="${CC:-cc}"
    "$CC_BIN" -std=c11 -O2 -fPIC -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident \
      -Wall -Wextra -Werror -c "$ROOT_DIR/runtime/pion_rt.c" -o "$OUT_DIR/pion_rt.o"
    if command -v strip >/dev/null 2>&1; then
      strip --strip-unneeded "$OUT_DIR/pion_rt.o"
    fi
    rm -f "$OUT_DIR/libpionrt.a"
    ar rcs "$OUT_DIR/libpionrt.a" "$OUT_DIR/pion_rt.o"
    PION_SKIP_RT_TEST=1 CC="$CC_BIN" sh "$ROOT_DIR/scripts/bootstrap.sh"
  else
    sh "$ROOT_DIR/scripts/bootstrap.sh"
  fi
  PIONC_BIN=$(find_pionc)
fi

QBE_BIN="$OUT_DIR/qbe${EXE_EXT}"
[ -f "$QBE_BIN" ] || QBE_BIN="$OUT_DIR/qbe"
RT_LIB="$OUT_DIR/libpionrt.a"

for req in "$PIONC_BIN" "$QBE_BIN" "$RT_LIB" \
  "$ROOT_DIR/runtime/pion_wasm_rt.mjs" \
  "$ROOT_DIR/runtime/pion_rt.c" \
  "$ROOT_DIR/runtime/pion_rt.h"; do
  if [ ! -f "$req" ]; then
    echo "FAIL: missing required artifact: $req" >&2
    exit 1
  fi
done

mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/share/pion/runtime"
cp "$PIONC_BIN" "$PREFIX/bin/pionc${EXE_EXT}"
cp "$QBE_BIN" "$PREFIX/bin/qbe${EXE_EXT}"
chmod +x "$PREFIX/bin/pionc${EXE_EXT}" "$PREFIX/bin/qbe${EXE_EXT}"
cp "$RT_LIB" "$PREFIX/lib/libpionrt.a"
cp "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$PREFIX/share/pion/pion_wasm_rt.mjs"
cp "$ROOT_DIR/runtime/pion_rt.c" "$PREFIX/share/pion/runtime/pion_rt.c"
cp "$ROOT_DIR/runtime/pion_rt.h" "$PREFIX/share/pion/runtime/pion_rt.h"

echo "Installed Pion toolchain to $PREFIX"
(
  unset PION_QBE PION_RT_LIB PION_WASM_RT PION_SRC PION_TARGET || true
  "$PREFIX/bin/pionc${EXE_EXT}" doctor
)
echo ""
echo "Add Pion to your PATH:"
echo "  export PATH=\"$PREFIX/bin:\$PATH\""
