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

NEED_BOOTSTRAP=0
PIONC_BIN=""
if ! PIONC_BIN=$(find_pionc); then
  if [ "$NO_BOOTSTRAP" -eq 1 ]; then
    echo "FAIL: no built pionc found in $OUT_DIR and --no-bootstrap was set" >&2
    exit 1
  fi
  NEED_BOOTSTRAP=1
elif [ "$NO_BOOTSTRAP" -eq 0 ]; then
  if _cur_rev="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null)"; then
    _built_rev=""
    if [ -f "$OUT_DIR/.built-rev" ]; then
      _built_rev="$(tr -d ' \t\r\n' < "$OUT_DIR/.built-rev" 2>/dev/null || true)"
    fi
    _dirty="$(git -C "$ROOT_DIR" status --porcelain -- compiler runtime scripts 2>/dev/null || true)"
    if [ "$_built_rev" != "$_cur_rev" ]; then
      echo "Cached $PIONC_BIN is stale (built='${_built_rev:-unknown}', HEAD='$_cur_rev'); re-bootstrapping..."
      NEED_BOOTSTRAP=1
    elif [ -n "$_dirty" ]; then
      echo "Working tree has uncommitted changes in compiler/runtime/scripts; re-bootstrapping..."
      NEED_BOOTSTRAP=1
    fi
  fi
fi

if [ "$NEED_BOOTSTRAP" -eq 1 ]; then
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
    "$CC_BIN" -std=c11 -O2 -fPIC -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident \
      -Wall -Wextra -Werror -c "$ROOT_DIR/runtime/pion_cli.c" -o "$OUT_DIR/pion_cli.o"
    rm -f "$OUT_DIR/libpionrt_cli.a"
    ar rcs "$OUT_DIR/libpionrt_cli.a" "$OUT_DIR/pion_rt.o" "$OUT_DIR/pion_cli.o"
    PROF_FP_FLAGS="-fno-omit-frame-pointer"
    if "$CC_BIN" -mno-omit-leaf-frame-pointer -x c -c /dev/null -o /dev/null 2>/dev/null; then
      PROF_FP_FLAGS="$PROF_FP_FLAGS -mno-omit-leaf-frame-pointer"
    fi
    if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
      if [ "$(uname -s)" = "Linux" ]; then
        PROF_FP_FLAGS="$PROF_FP_FLAGS -mbranch-protection=none"
      fi
    fi
    if "$CC_BIN" -std=c11 -O2 -DPION_PROF=1 $PROF_FP_FLAGS -fPIC -Wall -Wextra -Werror \
        -c "$ROOT_DIR/runtime/pion_rt.c" -o "$OUT_DIR/pion_rt_prof.o" && \
       "$CC_BIN" -std=c11 -O2 -DPION_PROF=1 $PROF_FP_FLAGS -fPIC -Wall -Wextra -Werror \
        -c "$ROOT_DIR/runtime/pion_prof.c" -o "$OUT_DIR/pion_prof.o"; then
      rm -f "$OUT_DIR/libpionrt_prof.a" "$OUT_DIR/libpionrt_cli_prof.a"
      ar rcs "$OUT_DIR/libpionrt_prof.a" "$OUT_DIR/pion_rt_prof.o" "$OUT_DIR/pion_prof.o"
      ar rcs "$OUT_DIR/libpionrt_cli_prof.a" "$OUT_DIR/pion_rt_prof.o" "$OUT_DIR/pion_prof.o" "$OUT_DIR/pion_cli.o"
    else
      echo "warning: optional libpionrt_prof.a build failed; --profile will build on demand" >&2
    fi
    PION_SKIP_RT_TEST=1 CC="$CC_BIN" sh "$ROOT_DIR/scripts/bootstrap.sh" --no-bench
  else
    sh "$ROOT_DIR/scripts/bootstrap.sh" --no-bench
    if [ "$EXE_EXT" = "" ]; then
      CC_BIN="${CC:-cc}"
      PROF_FP_FLAGS="-fno-omit-frame-pointer"
      if "$CC_BIN" -mno-omit-leaf-frame-pointer -x c -c /dev/null -o /dev/null 2>/dev/null; then
        PROF_FP_FLAGS="$PROF_FP_FLAGS -mno-omit-leaf-frame-pointer"
      fi
      if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
        if [ "$(uname -s)" = "Linux" ]; then
          PROF_FP_FLAGS="$PROF_FP_FLAGS -mbranch-protection=none"
        fi
      fi
      if "$CC_BIN" -std=c11 -O2 -DPION_PROF=1 $PROF_FP_FLAGS -fPIC -Wall -Wextra -Werror \
          -c "$ROOT_DIR/runtime/pion_rt.c" -o "$OUT_DIR/pion_rt_prof.o" && \
         "$CC_BIN" -std=c11 -O2 -DPION_PROF=1 $PROF_FP_FLAGS -fPIC -Wall -Wextra -Werror \
          -c "$ROOT_DIR/runtime/pion_prof.c" -o "$OUT_DIR/pion_prof.o"; then
        rm -f "$OUT_DIR/libpionrt_prof.a" "$OUT_DIR/libpionrt_cli_prof.a"
        ar rcs "$OUT_DIR/libpionrt_prof.a" "$OUT_DIR/pion_rt_prof.o" "$OUT_DIR/pion_prof.o"
        if [ -f "$OUT_DIR/pion_cli.o" ]; then
          ar rcs "$OUT_DIR/libpionrt_cli_prof.a" "$OUT_DIR/pion_rt_prof.o" "$OUT_DIR/pion_prof.o" "$OUT_DIR/pion_cli.o"
        fi
      else
        echo "warning: optional libpionrt_prof.a build failed; --profile will build on demand" >&2
      fi
    fi
  fi
  PIONC_BIN=$(find_pionc)
fi

QBE_BIN="$OUT_DIR/qbe${EXE_EXT}"
[ -f "$QBE_BIN" ] || QBE_BIN="$OUT_DIR/qbe"
RT_LIB="$OUT_DIR/libpionrt.a"

for req in "$PIONC_BIN" "$QBE_BIN" "$RT_LIB" \
  "$ROOT_DIR/runtime/pion_wasm_rt.mjs" \
  "$ROOT_DIR/runtime/pion_wasm_rt_web.mjs" \
  "$ROOT_DIR/runtime/pion_rt.c" \
  "$ROOT_DIR/runtime/pion_rt.h" \
  "$ROOT_DIR/runtime/pion_prof.c" \
  "$ROOT_DIR/runtime/pion_prof.h"; do
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
if [ -s "$OUT_DIR/libpionrt_prof.a" ]; then
  cp "$OUT_DIR/libpionrt_prof.a" "$PREFIX/lib/libpionrt_prof.a"
fi
cp "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$PREFIX/share/pion/pion_wasm_rt.mjs"
cp "$ROOT_DIR/runtime/pion_wasm_rt_web.mjs" "$PREFIX/share/pion/pion_wasm_rt_web.mjs"
cp "$ROOT_DIR/runtime/pion_rt.c" "$PREFIX/share/pion/runtime/pion_rt.c"
cp "$ROOT_DIR/runtime/pion_rt.h" "$PREFIX/share/pion/runtime/pion_rt.h"
cp "$ROOT_DIR/runtime/pion_prof.c" "$PREFIX/share/pion/runtime/pion_prof.c"
cp "$ROOT_DIR/runtime/pion_prof.h" "$PREFIX/share/pion/runtime/pion_prof.h"

echo "Installed Pion toolchain to $PREFIX"
(
  unset PION_QBE PION_RT_LIB PION_WASM_RT PION_SRC PION_TARGET || true
  "$PREFIX/bin/pionc${EXE_EXT}" doctor
)
echo ""
echo "Add Pion to your PATH:"
echo "  export PATH=\"$PREFIX/bin:\$PATH\""
