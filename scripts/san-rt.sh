#!/bin/sh
# Sanitizer build of the runtime for E2E suites:
#
#   sh scripts/san-rt.sh <address|thread> <out.a>
#
# Writes <out.a>, runtime/pion_rt.c built by ${CC:-cc} with -fsanitize=<kind>.
# verify-all.sh / test-linux.sh build each archive once and export its path as
# PION_ASAN_RT_LIB / PION_TSAN_RT_LIB; then this only copies it (dozens of suites
# would otherwise each recompile the same file). Without them it builds it here,
# so every suite also runs on its own.
#
# Exits 77 when the toolchain cannot compile and link -fsanitize=<kind>
# (e.g. MSYS2 UCRT64 GCC compiles -fsanitize=address but ships no -lasan).
set -eu

KIND="${1:?usage: san-rt.sh <address|thread> <out.a>}"
OUT="${2:?usage: san-rt.sh <address|thread> <out.a>}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CC="${CC:-cc}"

case "$KIND" in
  address) PREBUILT="${PION_ASAN_RT_LIB:-}" ;;
  thread) PREBUILT="${PION_TSAN_RT_LIB:-}" ;;
  *) echo "san-rt.sh: unknown sanitizer '$KIND'" >&2; exit 2 ;;
esac
# $PREBUILT.cc names the compiler that built it: never link another compiler's
# sanitizer ABI (gcc libasan vs clang compiler-rt).
if [ -n "$PREBUILT" ] && [ -s "$PREBUILT" ] &&
  { [ ! -f "$PREBUILT.cc" ] || [ "$(cat "$PREBUILT.cc")" = "$CC" ]; }; then
  cp "$PREBUILT" "$OUT"
  exit 0
fi

rm -f "$OUT"
printf 'int main(void){return 0;}\n' | "$CC" -x c - "-fsanitize=$KIND" -o "$OUT.probe" 2>/dev/null || exit 77
rm -f "$OUT.probe"
# No -Werror: sanitizer instrumentation makes some GCC versions warn spuriously;
# the plain runtime builds (test_rt, libpionrt.a) already gate warnings.
"$CC" -std=c11 -O1 -g "-fsanitize=$KIND" -fno-omit-frame-pointer -Wall -Wextra \
  -c "$ROOT_DIR/runtime/pion_rt.c" -o "$OUT.o"
ar rcs "$OUT" "$OUT.o"
rm -f "$OUT.o"
