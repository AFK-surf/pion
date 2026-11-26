# Sourced by verify-all.sh / test-linux.sh (needs ROOT_DIR and OUT_DIR): builds
# the sanitizer runtimes and ASan+UBSan QBE once and exports
# PION_ASAN_RT_LIB / PION_RT_ASAN_LIB / PION_TSAN_RT_LIB / PION_QBE_SAN_DIR /
# PION_QBE_SAN, with the compiler's name in <artifact>.cc. Where the toolchain
# has no such sanitizer (exit 77) the variable stays unset and the suites skip
# those steps, unless PION_REQUIRE_SANITIZERS=1 (CI): then, like any other
# failure, it fails the gate.
unset PION_ASAN_RT_LIB PION_RT_ASAN_LIB PION_TSAN_RT_LIB PION_QBE_SAN_DIR PION_QBE_SAN
san_rt_unsupported() {
  if [ "${PION_REQUIRE_SANITIZERS:-0}" = "1" ]; then
    echo "FAIL: PION_REQUIRE_SANITIZERS=1 but ${CC:-cc} cannot link -fsanitize=$1" >&2
    exit 1
  fi
  echo "NOTE: no -fsanitize=$1 toolchain; its steps will be skipped"
}
sh "$ROOT_DIR/scripts/san-rt.sh" address "$OUT_DIR/libpionrt_asan.a" &
SAN_ASAN_PID=$!
sh "$ROOT_DIR/scripts/san-rt.sh" thread "$OUT_DIR/libpionrt_tsan.a" &
SAN_TSAN_PID=$!
sh "$ROOT_DIR/scripts/build-qbe-san.sh" "$OUT_DIR/qbe-san" &
SAN_QBE_PID=$!
SAN_RC=0
wait "$SAN_ASAN_PID" || SAN_RC=$?
case "$SAN_RC" in
  0)
    printf '%s\n' "${CC:-cc}" > "$OUT_DIR/libpionrt_asan.a.cc"
    export PION_ASAN_RT_LIB="$OUT_DIR/libpionrt_asan.a"
    export PION_RT_ASAN_LIB="$OUT_DIR/libpionrt_asan.a"
    ;;
  77) san_rt_unsupported address ;;
  *) echo "FAIL: ASan runtime build (exit $SAN_RC)" >&2; exit 1 ;;
esac
SAN_RC=0
wait "$SAN_TSAN_PID" || SAN_RC=$?
case "$SAN_RC" in
  0)
    printf '%s\n' "${CC:-cc}" > "$OUT_DIR/libpionrt_tsan.a.cc"
    export PION_TSAN_RT_LIB="$OUT_DIR/libpionrt_tsan.a"
    ;;
  77) san_rt_unsupported thread ;;
  *) echo "FAIL: TSan runtime build (exit $SAN_RC)" >&2; exit 1 ;;
esac
SAN_RC=0
wait "$SAN_QBE_PID" || SAN_RC=$?
case "$SAN_RC" in
  0)
    export PION_QBE_SAN_DIR="$OUT_DIR/qbe-san"
    export PION_QBE_SAN="$OUT_DIR/qbe-san/qbe"
    ;;
  77) san_rt_unsupported address,undefined ;;
  *) echo "FAIL: ASan+UBSan QBE build (exit $SAN_RC)" >&2; exit 1 ;;
esac
