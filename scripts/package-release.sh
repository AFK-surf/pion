#!/bin/sh
# Assemble, package, and self-test a relocatable Pion toolchain archive:
#   pion-<version>-<os>-<arch>/{bin/{pionc,qbe},lib/libpionrt.a,share/pion/{pion_wasm_rt.mjs,runtime/pion_rt.{c,h},licenses/QBE-LICENSE},README.md,LICENSE,THIRD_PARTY_NOTICES.md}
# Usage: sh scripts/package-release.sh [out_dir]
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT_DIR="$ROOT_DIR/out"
DIST_DIR="${1:-$ROOT_DIR/dist}"
VERSION="${PION_VERSION:-0.1.0}"

case "$VERSION" in
  ""|*[!0-9A-Za-z.-]*)
    echo "error: invalid PION_VERSION (must be single-line ASCII semver): $VERSION" >&2
    exit 1
    ;;
esac
if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
  echo "error: invalid PION_VERSION (expected X.Y.Z or X.Y.Z-pre): $VERSION" >&2
  exit 1
fi

UNAME_S=$(uname -s)
UNAME_M=$(uname -m)
EXE_EXT=""
IS_WIN=0
case "$UNAME_S" in
  Darwin) OS_NAME="darwin" ;;
  Linux)  OS_NAME="linux" ;;
  MINGW*|MSYS*|CYGWIN*) OS_NAME="windows"; EXE_EXT=".exe"; IS_WIN=1 ;;
  *) echo "FAIL: unsupported OS $UNAME_S" >&2; exit 1 ;;
esac

case "$UNAME_M" in
  arm64|aarch64) ARCH_NAME="arm64" ;;
  x86_64|amd64)  ARCH_NAME="x86_64" ;;
  riscv64)       ARCH_NAME="riscv64" ;;
  *) echo "FAIL: unsupported arch $UNAME_M" >&2; exit 1 ;;
esac

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  for cand in \
    "$OUT_DIR/pionc2${EXE_EXT}" \
    "$OUT_DIR/pionc_linux" \
    "$OUT_DIR/pionc_win.exe" \
    "$OUT_DIR/pionc${EXE_EXT}"; do
    if [ -f "$cand" ]; then
      PIONC_BIN="$cand"
      break
    fi
  done
fi
if [ -z "$PIONC_BIN" ] || [ ! -f "$PIONC_BIN" ]; then
  echo "FAIL: pionc binary not found in $OUT_DIR (run scripts/bootstrap.sh first or set PIONC=...)" >&2
  exit 1
fi

QBE_BIN="${PION_QBE:-$OUT_DIR/qbe${EXE_EXT}}"
if [ ! -f "$QBE_BIN" ] && [ -f "$OUT_DIR/qbe" ]; then
  QBE_BIN="$OUT_DIR/qbe"
fi
RT_LIB="${PION_RT_LIB:-$OUT_DIR/libpionrt.a}"
WASM_RT="$ROOT_DIR/runtime/pion_wasm_rt.mjs"
WASM_WEB_RT="$ROOT_DIR/runtime/pion_wasm_rt_web.mjs"
RT_C="$ROOT_DIR/runtime/pion_rt.c"
RT_H="$ROOT_DIR/runtime/pion_rt.h"
LICENSE_FILE="$ROOT_DIR/LICENSE"
NOTICES_FILE="$ROOT_DIR/THIRD_PARTY_NOTICES.md"
QBE_LICENSE="$ROOT_DIR/vendor/qbe/LICENSE"

for req in "$QBE_BIN" "$RT_LIB" "$WASM_RT" "$WASM_WEB_RT" "$RT_C" "$RT_H" "$LICENSE_FILE" "$NOTICES_FILE" "$QBE_LICENSE"; do
  if [ ! -s "$req" ]; then
    echo "FAIL: missing or empty required release file: $req" >&2
    exit 1
  fi
done

PKG_NAME="pion-${VERSION}-${OS_NAME}-${ARCH_NAME}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

STAGE="$TMP_DIR/$PKG_NAME"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share/pion/runtime" "$STAGE/share/pion/licenses"
cp "$PIONC_BIN" "$STAGE/bin/pionc${EXE_EXT}"
cp "$QBE_BIN" "$STAGE/bin/qbe${EXE_EXT}"
chmod +x "$STAGE/bin/pionc${EXE_EXT}" "$STAGE/bin/qbe${EXE_EXT}"
cp "$RT_LIB" "$STAGE/lib/libpionrt.a"
cp "$WASM_RT" "$STAGE/share/pion/pion_wasm_rt.mjs"
cp "$WASM_WEB_RT" "$STAGE/share/pion/pion_wasm_rt_web.mjs"
cp "$RT_C" "$STAGE/share/pion/runtime/pion_rt.c"
cp "$RT_H" "$STAGE/share/pion/runtime/pion_rt.h"
cp "$QBE_LICENSE" "$STAGE/share/pion/licenses/QBE-LICENSE"
[ -f "$ROOT_DIR/README.md" ] && cp "$ROOT_DIR/README.md" "$STAGE/README.md"
cp "$LICENSE_FILE" "$STAGE/LICENSE"
cp "$NOTICES_FILE" "$STAGE/THIRD_PARTY_NOTICES.md"

mkdir -p "$DIST_DIR"
DIST_ABS=$(CDPATH= cd -- "$DIST_DIR" && pwd)

if [ "$IS_WIN" -eq 1 ]; then
  ARCHIVE="$DIST_ABS/${PKG_NAME}.zip"
  rm -f "$ARCHIVE"
  (cd "$TMP_DIR" && python3 -c '
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for dirpath, _, filenames in os.walk(root):
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            zf.write(full, os.path.relpath(full, "."))
' "$PKG_NAME" "$ARCHIVE")
else
  ARCHIVE="$DIST_ABS/${PKG_NAME}.tar.gz"
  rm -f "$ARCHIVE"
  tar -czf "$ARCHIVE" -C "$TMP_DIR" "$PKG_NAME"
fi

SHA_FILE="${ARCHIVE}.sha256"
if command -v shasum >/dev/null 2>&1; then
  (cd "$DIST_ABS" && shasum -a 256 "$(basename -- "$ARCHIVE")" > "$SHA_FILE")
else
  (cd "$DIST_ABS" && sha256sum "$(basename -- "$ARCHIVE")" > "$SHA_FILE")
fi

# --- Mandatory zero-env relocatable self-check --------------------------------
VERIFY_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR" "$VERIFY_DIR"' EXIT

if [ "$IS_WIN" -eq 1 ]; then
  python3 -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "r") as zf:
    zf.extractall(sys.argv[2])
' "$ARCHIVE" "$VERIFY_DIR"
else
  tar -xzf "$ARCHIVE" -C "$VERIFY_DIR"
fi

EXTRACTED="$VERIFY_DIR/$PKG_NAME"
for lic in \
  "$EXTRACTED/LICENSE" \
  "$EXTRACTED/THIRD_PARTY_NOTICES.md" \
  "$EXTRACTED/share/pion/licenses/QBE-LICENSE"; do
  if [ ! -s "$lic" ]; then
    echo "FAIL: missing or empty license file in archive: $lic" >&2
    exit 1
  fi
done

# Windows: the shipped executables may import only Windows system DLLs (no
# libgcc_s_seh-1.dll / libwinpthread-1.dll / libstdc++-6.dll from MinGW).
if [ "$IS_WIN" -eq 1 ]; then
  if command -v objdump >/dev/null 2>&1; then
    for exe in pionc.exe qbe.exe; do
      DLLS=$(objdump -p "$EXTRACTED/bin/$exe" | tr -d '\r' | sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p')
      if [ -z "$DLLS" ]; then
        echo "FAIL: objdump found no DLL imports in $exe" >&2
        exit 1
      fi
      for dll in $DLLS; do
        case "$(printf '%s' "$dll" | tr 'A-Z' 'a-z')" in
          kernel32.dll|ws2_32.dll|advapi32.dll|ntdll.dll|msvcrt.dll|ucrtbase.dll|api-ms-win-*.dll|\
          crypt32.dll|secur32.dll|bcrypt.dll|user32.dll|shell32.dll|ole32.dll|shlwapi.dll|userenv.dll) ;;
          *)
            echo "FAIL: $exe imports non-system DLL $dll (all imports: $(echo $DLLS))" >&2
            exit 1
            ;;
        esac
      done
      echo "$exe imports only system DLLs: $(echo $DLLS)"
    done
  elif [ "${PION_REQUIRE_DLL_CHECK:-0}" = "1" ]; then
    echo "FAIL: PION_REQUIRE_DLL_CHECK=1 but objdump not found" >&2
    exit 1
  else
    echo "NOTE: objdump not found; skipped the Windows system-DLL import check" >&2
  fi
fi

WORK="$VERIFY_DIR/work"
mkdir -p "$WORK"

(
  unset PION_QBE PION_RT_LIB PION_WASM_RT PION_SRC PION_TARGET PION_REGISTRY || true
  export PION_CACHE_DIR="$VERIFY_DIR/cas"
  export PATH="$EXTRACTED/bin:$PATH"
  cd "$WORK"

  # The archive name must not claim a release the packaged compiler does not
  # report: X.Y.Z of PION_VERSION (any -pre suffix aside) == `pionc --version`.
  VER_JSON=$(pionc --version --json | tr -d '\r')
  PIONC_VER=$(printf '%s' "$VER_JSON" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  CORE_VER=$(printf '%s\n' "$VERSION" | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+')
  if [ "$PIONC_VER" != "$CORE_VER" ]; then
    echo "FAIL: PION_VERSION=$VERSION but the packaged pionc reports version '$PIONC_VER' ($VER_JSON); bump the compiler version first" >&2
    exit 1
  fi

  DOC_JSON=$(pionc doctor --json)
  printf '%s' "$DOC_JSON" | grep -q '"ok":true' || {
    echo "FAIL: packaged pionc doctor failed: $DOC_JSON" >&2
    exit 1
  }

  pionc init demo >/dev/null
  cd demo
  CHK_JSON=$(pionc check)
  printf '%s' "$CHK_JSON" | grep -q '"ok":true' || {
    echo "FAIL: packaged pionc check failed: $CHK_JSON" >&2
    exit 1
  }

  pionc run >/dev/null
  pionc build --target wasm32 -o "$VERIFY_DIR/demo.wasm"
  if [ ! -s "$VERIFY_DIR/demo.wasm" ]; then
    echo "FAIL: packaged pionc build --target wasm32 produced no output" >&2
    exit 1
  fi
)

echo "Packaged and self-checked: $ARCHIVE"
cat "$SHA_FILE"
