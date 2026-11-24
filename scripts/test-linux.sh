#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/out"
RT_DIR="$ROOT_DIR/runtime"
CC="${CC:-cc}"

# Helper sub-commands invoked inside run-e2e-parallel.sh (each uses its own
# mktemp -d + PION_CACHE_DIR and writes nothing to shared out/ or source tree).
if [ "${1:-}" = "--group" ]; then
  GROUP="$2"
  PIONC="${PIONC:-$OUT_DIR/pionc_linux}"
  G_TMP="$(mktemp -d)"
  trap 'rm -rf "$G_TMP"' EXIT
  export PION_CACHE_DIR="$G_TMP/cas"
  mkdir -p "$PION_CACHE_DIR"
  case "$GROUP" in
    mbt_tests)
      for TPKG in tools/mbt_compat tools/mbt2pion; do
        STD_JSON="$("$PIONC" test --json "$ROOT_DIR/$TPKG")"
        echo "pionc_linux test --json $TPKG -> $STD_JSON"
        printf '%s' "$STD_JSON" | grep -q '"ok":true'
        printf '%s' "$STD_JSON" | grep -q '"failed":0'
      done
      # tools/mbt2pion_cli compiles c_sources (csrc/atomic_fs.c), which needs real `as` via ORIG_PATH under GCC.
      MBT2PION_CLI_JSON="$(PATH="$ORIG_PATH" "$PIONC" test --json "$ROOT_DIR/tools/mbt2pion_cli")"
      echo "pionc_linux test --json tools/mbt2pion_cli -> $MBT2PION_CLI_JSON"
      printf '%s' "$MBT2PION_CLI_JSON" | grep -q '"ok":true'
      printf '%s' "$MBT2PION_CLI_JSON" | grep -q '"failed":0'
      echo "[SUMMARY] mbt_tests (mbt_compat, mbt2pion, mbt2pion_cli): OK"
      ;;
    std_tests)
      TEST_JSON="$("$PIONC" test --deps --json "$ROOT_DIR/examples/text_stats")"
      echo "pionc_linux test --deps --json examples/text_stats -> $TEST_JSON"
      printf '%s' "$TEST_JSON" | grep -q '"failed":0'
      for TPKG in std/json std/http std/net std/regex examples/http_event_server; do
        STD_JSON="$("$PIONC" test --json "$ROOT_DIR/$TPKG")"
        echo "pionc_linux test --json $TPKG -> $STD_JSON"
        printf '%s' "$STD_JSON" | grep -q '"ok":true'
        printf '%s' "$STD_JSON" | grep -q '"failed":0'
      done
      # std/proc: streaming subprocess + cross-platform PTY (c_sources needs real `as` via ORIG_PATH).
      PROC_JSON="$(PATH="$ORIG_PATH" "$PIONC" test --json "$ROOT_DIR/std/proc")"
      echo "pionc_linux test --json std/proc -> $PROC_JSON"
      printf '%s' "$PROC_JSON" | grep -q '"ok":true'
      printf '%s' "$PROC_JSON" | grep -q '"failed":0'
      echo "[SUMMARY] std_tests (text_stats, std/*, http_event_server): OK"
      ;;
    standalone_e2e)
      # P22-A, P25-A, P27-A, P17-A, dyn_trait, Wave J2 (under zero-`as` PATH on x86_64).
      P22A_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/p22a_systems_io.pion")"
      echo "pionc_linux run p22a_systems_io -> $P22A_OUT"
      [ "$P22A_OUT" = "p22a_systems_io ok" ] || { echo "FAIL: p22a_systems_io output mismatch" >&2; exit 1; }
      P25A_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/p25a_c_varargs.pion")"
      echo "pionc_linux run p25a_c_varargs -> $P25A_OUT"
      [ "$P25A_OUT" = "a=42 b=-7 c=3.25" ] || { echo "FAIL: p25a_c_varargs output mismatch" >&2; exit 1; }
      P27A_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/p27a_ergonomics_bug4.pion")"
      echo "pionc_linux run p27a_ergonomics_bug4 -> $P27A_OUT"
      [ "$P27A_OUT" = "p27a_ergonomics_bug4 ok" ] || { echo "FAIL: p27a_ergonomics_bug4 output mismatch" >&2; exit 1; }
      P17A_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/p17a_ergonomics_mt.pion")"
      echo "pionc_linux run p17a_ergonomics_mt -> $P17A_OUT"
      [ "$P17A_OUT" = "p17a_ok log=2401 recs=3200 index=3200 keys=16" ] || { echo "FAIL: p17a_ergonomics_mt output mismatch" >&2; exit 1; }
      DYN_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/dyn_trait.pion")"
      echo "pionc_linux run dyn_trait -> $DYN_OUT"
      [ "$DYN_OUT" = "dyn_trait ok" ] || { echo "FAIL: dyn_trait output mismatch" >&2; exit 1; }
      J2_DEV_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/wave_j2_rc_elision.pion")"
      "$PIONC" build --release -o "$G_TMP/wave_j2_rel" "$ROOT_DIR/tests/e2e/wave_j2_rc_elision.pion"
      J2_REL_OUT="$("$G_TMP/wave_j2_rel")"
      echo "pionc_linux run wave_j2_rc_elision -> dev=$J2_DEV_OUT release=$J2_REL_OUT"
      case "$J2_DEV_OUT" in
        wave_j2_ok:*) ;;
        *) echo "FAIL: wave_j2_rc_elision bad dev output ($J2_DEV_OUT)" >&2; exit 1 ;;
      esac
      [ "$J2_DEV_OUT" = "$J2_REL_OUT" ] || {
        echo "FAIL: wave_j2_rc_elision dev/release mismatch (dev=$J2_DEV_OUT release=$J2_REL_OUT)" >&2
        exit 1
      }
      "$PIONC" build --release -o "$G_TMP/wave_j2_st_rel" "$ROOT_DIR/tests/e2e/wave_j2_rc_elision_st.pion"
      J2_ST_NAT="$("$G_TMP/wave_j2_st_rel")"
      case "$J2_ST_NAT" in
        wave_j2_st_ok:*) ;;
        *) echo "FAIL: wave_j2_rc_elision_st bad native output ($J2_ST_NAT)" >&2; exit 1 ;;
      esac
      if command -v node >/dev/null 2>&1; then
        "$PIONC" build --release --target wasm32 -o "$G_TMP/wave_j2_st.wasm" "$ROOT_DIR/tests/e2e/wave_j2_rc_elision_st.pion"
        J2_ST_WASM="$(node "$ROOT_DIR/runtime/pion_wasm_rt.mjs" "$G_TMP/wave_j2_st.wasm")"
        echo "wave_j2_rc_elision_st -> native=$J2_ST_NAT wasm32=$J2_ST_WASM"
        [ "$J2_ST_NAT" = "$J2_ST_WASM" ] || {
          echo "FAIL: wave_j2_rc_elision_st native/wasm32 mismatch (native=$J2_ST_NAT wasm32=$J2_ST_WASM)" >&2
          exit 1
        }
      fi
      echo "[SUMMARY] standalone_e2e (p22a, p25a, p27a, p17a, dyn_trait, wave_j2): OK"
      ;;
    tls_client)
      TLS_JSON="$(PATH="$ORIG_PATH" "$PIONC" test --json "$ROOT_DIR/std/tls")"
      echo "pionc_linux test --json std/tls -> $TLS_JSON"
      printf '%s' "$TLS_JSON" | grep -q '"ok":true'
      printf '%s' "$TLS_JSON" | grep -q '"failed":0'
      PATH="$ORIG_PATH" sh "$ROOT_DIR/std/tls/e2e/run_e2e.sh" "$PIONC"
      echo "[SUMMARY] tls_client (std/tls unit + e2e): OK"
      ;;
    https_server)
      HTTPS_JSON="$(PATH="$ORIG_PATH" "$PIONC" test --json "$ROOT_DIR/examples/https_server")"
      echo "pionc_linux test --json examples/https_server -> $HTTPS_JSON"
      printf '%s' "$HTTPS_JSON" | grep -q '"ok":true'
      printf '%s' "$HTTPS_JSON" | grep -q '"failed":0'
      PATH="$ORIG_PATH" sh "$ROOT_DIR/std/tls/e2e/run_server_e2e.sh" "$PIONC"
      echo "[SUMMARY] https_server (examples/https_server unit + run_server_e2e): OK"
      ;;
    pion_station)
      STATION_JSON="$(PATH="$ORIG_PATH" LIBRARY_PATH="${STATION_LIB_PATH:-}" "$PIONC" test --deps --json "$ROOT_DIR/examples/pion_station")"
      echo "pionc_linux test --deps --json examples/pion_station -> $STATION_JSON"
      printf '%s' "$STATION_JSON" | grep -q '"ok":true'
      printf '%s' "$STATION_JSON" | grep -q '"failed":0'
      PATH="$ORIG_PATH" LIBRARY_PATH="${STATION_LIB_PATH:-}" sh "$ROOT_DIR/examples/pion_station/run_e2e.sh" "$PIONC"
      echo "[SUMMARY] pion_station (examples/pion_station unit + run_e2e): OK"
      ;;
    *)
      echo "FAIL: unknown test-linux group: $GROUP" >&2
      exit 2
      ;;
  esac
  exit 0
fi

mkdir -p "$OUT_DIR"

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

TMP_DIR="$(mktemp -d)"
. "$ROOT_DIR/scripts/bg-lib.sh"
P98_PID=""
FP_ASM_PID=""
CORE_PID=""
cleanup() {
  bg_kill "$P98_PID" "$FP_ASM_PID" "$CORE_PID"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

UNAME_M="$(uname -m)"
if [ "$UNAME_M" = "x86_64" ]; then
  LINUX_TARGET="amd64_sysv"
  LINUX_ARCH_LABEL="x86_64"
  USE_DIRECT_OBJ=1
  EXPECTED_OBJ_FILE="ELF 64-bit LSB relocatable, x86-64"
  EXPECTED_SQRT_INSN="sqrtsd"
elif [ "$UNAME_M" = "aarch64" ] || [ "$UNAME_M" = "arm64" ]; then
  LINUX_TARGET="arm64"
  LINUX_ARCH_LABEL="aarch64"
  USE_DIRECT_OBJ=0
  EXPECTED_OBJ_FILE="ELF 64-bit LSB relocatable, ARM aarch64"
  EXPECTED_SQRT_INSN="fsqrt"
elif [ "$UNAME_M" = "riscv64" ]; then
  LINUX_TARGET="rv64"
  LINUX_ARCH_LABEL="riscv64"
  USE_DIRECT_OBJ=0
  EXPECTED_OBJ_FILE="ELF 64-bit LSB relocatable, UCB RISC-V"
  EXPECTED_SQRT_INSN="fsqrt.d"
else
  echo "FAIL: unsupported Linux arch $UNAME_M" >&2
  exit 1
fi
MULTIARCH_LIB_DIR="/usr/lib/${UNAME_M}-linux-gnu"

echo "=== [1/6] Linux ${LINUX_ARCH_LABEL} Environment & QBE (${LINUX_TARGET}) Build ==="
uname -a
CC="$CC" sh "$ROOT_DIR/scripts/build-qbe.sh" "$OUT_DIR/qbe"

if [ "$UNAME_M" = "aarch64" ] || [ "$UNAME_M" = "arm64" ]; then
  RT_OPT="-Os"
  RT_EXTRA="-mbranch-protection=none -fno-stack-protector"
else
  RT_OPT="-O2"
  RT_EXTRA=""
fi
echo "=== [2/6] Build libpionrt.a (-std=c11 ${RT_OPT} ${RT_EXTRA} -fPIC -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident -Wall -Wextra -Werror) ==="
"$CC" -std=c11 "$RT_OPT" $RT_EXTRA -fPIC -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident -Wall -Wextra -Werror -c "$RT_DIR/pion_rt.c" -o "$OUT_DIR/pion_rt.o"
if command -v strip >/dev/null 2>&1; then
  strip --strip-unneeded "$OUT_DIR/pion_rt.o"
fi
rm -f "$OUT_DIR/libpionrt.a"
ar rcs "$OUT_DIR/libpionrt.a" "$OUT_DIR/pion_rt.o"
LIB_SIZE="$(wc -c < "$OUT_DIR/libpionrt.a" | tr -d ' ')"
echo "Linux ${LINUX_ARCH_LABEL} libpionrt.a size: ${LIB_SIZE} bytes"
if [ "$LIB_SIZE" -ge 65536 ]; then
  echo "FAIL: libpionrt.a (${LIB_SIZE} bytes) exceeds 64 KB budget" >&2
  exit 1
fi
"$CC" -std=c11 "$RT_OPT" $RT_EXTRA -fPIC -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident -Wall -Wextra -Werror -c "$RT_DIR/pion_cli.c" -o "$OUT_DIR/pion_cli.o"
rm -f "$OUT_DIR/libpionrt_cli.a"
ar rcs "$OUT_DIR/libpionrt_cli.a" "$OUT_DIR/pion_rt.o" "$OUT_DIR/pion_cli.o"

echo "=== [3/6] Runtime Unit + MT + 4-Core Speedup + P6-A Stdlib (test_rt.c) ==="
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -I"$RT_DIR" \
  "$RT_DIR/test_rt.c" "$RT_DIR/pion_cli.c" "$OUT_DIR/libpionrt.a" -lm -lpthread -o "$OUT_DIR/test_rt_linux"
if ! "$OUT_DIR/test_rt_linux" > "$TMP_DIR/test_rt.out" 2>&1; then
  cat "$TMP_DIR/test_rt.out"
  exit 1
fi
cat "$TMP_DIR/test_rt.out"
# Linux has no loopback firewall: the runtime test must take the real 4-client TCP path.
grep -q 'tcp_loopback_mt (4 concurrent TCP clients on 127.0.0.1' "$TMP_DIR/test_rt.out" || {
  echo "FAIL: tcp_loopback_mt did not run the real 127.0.0.1 TCP loopback on Linux" >&2
  exit 1
}
# spawn workers keep their explicit 8 MiB stacks under a 1 MiB RLIMIT_STACK
# (glibc would otherwise size thread stacks from it).
(ulimit -s 1024 && "$OUT_DIR/test_rt_linux" --spawn-stack)
set +e
stdbuf -oL "$OUT_DIR/test_rt_linux" --bench
BENCH_RC=$?
set -e
if [ "$BENCH_RC" -ne 0 ]; then
  echo "NOTE: test_rt --bench returned $BENCH_RC (paravirtualized vCPU jitter); continuing functional & MT checks"
fi

# One ASan/TSan build of the runtime for all E2E suites (see scripts/san-rt.sh),
# while `as` is still reachable.
. "$ROOT_DIR/scripts/san-rt-env.sh"

# The KV load client is plain C: build it while `as` is still reachable.
"$CC" -O2 -pthread -o "$OUT_DIR/bench_load" "$ROOT_DIR/examples/http_kv_service/bench_load.c"

# On x86_64 (`amd64_sysv`), every object file comes straight from `qbe --obj` (ELF64):
# a failing `as` first on PATH proves no step assembles text. On aarch64/riscv64,
# QBE emits text assembly and `cc -c` assembles it.
ORIG_PATH="$PATH"
if [ "$USE_DIRECT_OBJ" -eq 1 ]; then
  mkdir -p "$TMP_DIR/noas"
  printf '#!/bin/sh\necho "FAIL: as invoked: $*" >&2\nexit 97\n' > "$TMP_DIR/noas/as"
  chmod +x "$TMP_DIR/noas/as"
  export PATH="$TMP_DIR/noas:$PATH"
fi

echo "=== [4/6] QBE ${LINUX_TARGET} End-to-End ABI & Hardware ${EXPECTED_SQRT_INSN} Smoke Test ==="
cat > "$TMP_DIR/smoke_qbe.ssa" <<'EOF'
data $hello = { b "hello from qbe+pionrt", b 0 }

function $worker(l %env) {
@start
    %old =l call $pion_atomic_fetch_add(l %env, l 10)
    ret
}

export function w $main(w %argc, l %argv) {
@start
    %w =l call $pion_world_init(w %argc, l %argv)
    %s =l call $pion_str_from_cstr(l $hello, l 21)
    call $pion_world_println(l %w, l %s)

    %atom =l call $pion_atomic_new(l 2)
    %sc =l call $pion_scope_begin()
    call $pion_scope_spawn(l %sc, l $worker, l %atom)
    call $pion_scope_spawn(l %sc, l $worker, l %atom)
    call $pion_scope_spawn(l %sc, l $worker, l %atom)
    call $pion_scope_spawn(l %sc, l $worker, l %atom)
    call $pion_scope_end(l %sc)

    %val =l call $pion_atomic_load(l %atom)
    %num =l call $pion_int_to_str(l %val)
    call $pion_world_println(l %w, l %num)

    %sq =d sqrt d_1764.0
    %sqi =l dtosi %sq
    %sqstr =l call $pion_int_to_str(l %sqi)
    call $pion_world_println(l %w, l %sqstr)

    call $pion_rc_dec(l %sqstr)
    call $pion_rc_dec(l %num)
    call $pion_rc_dec(l %atom)
    call $pion_rc_dec(l %s)
    call $pion_rc_dec(l %w)
    ret 0
}
EOF

T_SM0="$(now_ms)"
"$OUT_DIR/qbe" -t "$LINUX_TARGET" -o "$TMP_DIR/smoke_qbe.s" "$TMP_DIR/smoke_qbe.ssa"
if [ "$USE_DIRECT_OBJ" -eq 1 ]; then
  "$OUT_DIR/qbe" -t "$LINUX_TARGET" --obj -o "$TMP_DIR/smoke_qbe.o" "$TMP_DIR/smoke_qbe.ssa"
else
  "$CC" -c "$TMP_DIR/smoke_qbe.s" -o "$TMP_DIR/smoke_qbe.o"
fi
"$CC" "$TMP_DIR/smoke_qbe.o" "$OUT_DIR/libpionrt.a" -lm -lpthread -o "$TMP_DIR/smoke_qbe"
T_SM1="$(now_ms)"
SMOKE_SIZE="$(wc -c < "$TMP_DIR/smoke_qbe" | tr -d ' ')"
SMOKE_OUT="$("$TMP_DIR/smoke_qbe")"
echo "QBE ${LINUX_TARGET} smoke: compile=$((T_SM1 - T_SM0))ms, binary=${SMOKE_SIZE} bytes"
EXPECTED_SMOKE="$(printf 'hello from qbe+pionrt\n42\n42')"
if [ "$SMOKE_OUT" != "$EXPECTED_SMOKE" ]; then
  echo "FAIL: QBE ${LINUX_TARGET} smoke output mismatch: $SMOKE_OUT" >&2
  exit 1
fi
grep -n "$EXPECTED_SQRT_INSN" "$TMP_DIR/smoke_qbe.s"
echo "[PASS] QBE ${LINUX_TARGET} ABI & hardware ${EXPECTED_SQRT_INSN} smoke"

echo "=== [5/6] Native Linux ${LINUX_ARCH_LABEL} pionc ELF Bootstrap & Self-Hosting Proof ==="
if [ -z "${PION_LINUX_SSA:-}" ]; then
  if [ -f "$OUT_DIR/stage2.ssa" ]; then
    PION_LINUX_SSA="$OUT_DIR/stage2.ssa"
  elif [ -f "$ROOT_DIR/bootstrap/pionc-seed.ssa.gz" ]; then
    PION_LINUX_SSA="$TMP_DIR/pionc-seed.ssa"
    gzip -dc "$ROOT_DIR/bootstrap/pionc-seed.ssa.gz" > "$PION_LINUX_SSA"
    echo "Using standalone bootstrap seed: bootstrap/pionc-seed.ssa.gz"
  else
    echo "FAIL: neither PION_LINUX_SSA, out/stage2.ssa, nor bootstrap/pionc-seed.ssa.gz exists" >&2
    exit 1
  fi
fi
if [ ! -f "$PION_LINUX_SSA" ]; then
  echo "FAIL: PION_LINUX_SSA not found: $PION_LINUX_SSA" >&2
  exit 1
fi

T_B0="$(now_ms)"
if [ "$USE_DIRECT_OBJ" -eq 1 ]; then
  "$OUT_DIR/qbe" -t "$LINUX_TARGET" --obj -o "$OUT_DIR/pionc_linux.o" "$PION_LINUX_SSA"
else
  "$OUT_DIR/qbe" -t "$LINUX_TARGET" -o "$TMP_DIR/pionc_linux.s" "$PION_LINUX_SSA"
  "$CC" -c "$TMP_DIR/pionc_linux.s" -o "$OUT_DIR/pionc_linux.o"
fi
"$CC" "$OUT_DIR/pionc_linux.o" "$OUT_DIR/libpionrt_cli.a" -lm -lpthread -o "$OUT_DIR/pionc_linux"
T_B1="$(now_ms)"
PIONC_O_FILE="$(file "$OUT_DIR/pionc_linux.o")"
echo "$PIONC_O_FILE"
printf '%s' "$PIONC_O_FILE" | grep -q "$EXPECTED_OBJ_FILE" || {
  echo "FAIL: pionc_linux.o did not match expected ELF64 relocatable ($EXPECTED_OBJ_FILE)" >&2
  exit 1
}
PIONC_SIZE="$(wc -c < "$OUT_DIR/pionc_linux" | tr -d ' ')"
echo "Native Linux ${LINUX_ARCH_LABEL} pionc ELF: assemble+link=$((T_B1 - T_B0))ms, size=${PIONC_SIZE} bytes"
if command -v file >/dev/null 2>&1; then
  file "$OUT_DIR/pionc_linux"
fi

PIONC="$OUT_DIR/pionc_linux"
"$PIONC" --version

export PION_QBE="$OUT_DIR/qbe"
export PION_RT_LIB="$OUT_DIR/libpionrt.a"
export PION_CACHE_DIR="$TMP_DIR/cas_linux"
mkdir -p "$PION_CACHE_DIR"
unset PION_TARGET || true

# Self-hosting Stage 3 & Stage 4 on Linux -> verify bit-for-bit fixed-point!
# Note: on x86_64, no --emit-asm so pionc takes its direct `qbe --obj` ELF64 path (zero `as`).
# When booting from an older seed on aarch64, pass PION_TARGET="$LINUX_TARGET" for Stage 3
# so Stage 3 emits the right target even if the seed predates uname auto-detection; Stage 4
# runs with PION_TARGET unset to prove pionc_linux_s3 auto-detects its own host arch!
T_S3_0="$(now_ms)"
if [ "$USE_DIRECT_OBJ" -eq 1 ]; then
  (cd "$ROOT_DIR" && PION_RT_LIB="$OUT_DIR/libpionrt_cli.a" PION_CACHE_DIR="$TMP_DIR/cas_linux_s3" "$PIONC" build \
    --emit-ssa "$TMP_DIR/linux_stage3.ssa" \
    -o "$TMP_DIR/pionc_linux_s3" \
    compiler/src/core \
    compiler/src/cli/main.pion)
else
  (cd "$ROOT_DIR" && PION_RT_LIB="$OUT_DIR/libpionrt_cli.a" PION_CACHE_DIR="$TMP_DIR/cas_linux_s3" PION_TARGET="$LINUX_TARGET" "$PIONC" build \
    --emit-ssa "$TMP_DIR/linux_stage3.ssa" \
    -o "$TMP_DIR/pionc_linux_s3" \
    compiler/src/core \
    compiler/src/cli/main.pion)
fi
T_S3_1="$(now_ms)"
S3_SIZE="$(wc -c < "$TMP_DIR/pionc_linux_s3" | tr -d ' ')"
echo "Linux ${LINUX_ARCH_LABEL} native self-host Stage 3: build=$((T_S3_1 - T_S3_0))ms, binary=${S3_SIZE} bytes"

T_S4_0="$(now_ms)"
(cd "$ROOT_DIR" && PION_RT_LIB="$OUT_DIR/libpionrt_cli.a" PION_CACHE_DIR="$TMP_DIR/cas_linux_s4" "$TMP_DIR/pionc_linux_s3" build \
  --emit-ssa "$TMP_DIR/linux_stage4.ssa" \
  -o "$TMP_DIR/pionc_linux_s4" \
  compiler/src/core \
  compiler/src/cli/main.pion)
T_S4_1="$(now_ms)"
S4_SIZE="$(wc -c < "$TMP_DIR/pionc_linux_s4" | tr -d ' ')"
echo "Linux ${LINUX_ARCH_LABEL} native self-host Stage 4: build=$((T_S4_1 - T_S4_0))ms, binary=${S4_SIZE} bytes"

"$TMP_DIR/pionc_linux_s4" --version
FP_A=3
FP_B=4
if ! cmp -s "$TMP_DIR/linux_stage3.ssa" "$TMP_DIR/linux_stage4.ssa"; then
  echo "Stage 3 (seed) != Stage 4 (new codegen); running Stage 5 (pionc_linux_s4 -> pionc_linux_s5) to verify Stage 4 == Stage 5 fixed-point"
  T_S5_0="$(now_ms)"
  (cd "$ROOT_DIR" && PION_RT_LIB="$OUT_DIR/libpionrt_cli.a" PION_CACHE_DIR="$TMP_DIR/cas_linux_s5" "$TMP_DIR/pionc_linux_s4" build \
    --emit-ssa "$TMP_DIR/linux_stage5.ssa" \
    -o "$TMP_DIR/pionc_linux_s5" \
    compiler/src/core \
    compiler/src/cli/main.pion)
  T_S5_1="$(now_ms)"
  S5_SIZE="$(wc -c < "$TMP_DIR/pionc_linux_s5" | tr -d ' ')"
  echo "Linux ${LINUX_ARCH_LABEL} native self-host Stage 5: build=$((T_S5_1 - T_S5_0))ms, binary=${S5_SIZE} bytes"
  FP_A=4
  FP_B=5
fi
sha256sum "$TMP_DIR/linux_stage${FP_A}.ssa" "$TMP_DIR/linux_stage${FP_B}.ssa"
cmp "$TMP_DIR/linux_stage${FP_A}.ssa" "$TMP_DIR/linux_stage${FP_B}.ssa"
# The objects the two stages really compiled and linked (each in its own fresh CAS).
stage_obj_sha() {
  (cd "$TMP_DIR/cas_linux_s$1/obj" && for O in *.o; do sha256sum < "$O"; done | sort)
}
FP_OBJ_A="$(stage_obj_sha "$FP_A")"
FP_OBJ_B="$(stage_obj_sha "$FP_B")"
echo "Stage ${FP_A} / Stage ${FP_B} .o: $(printf '%s' "$FP_OBJ_A" | tr -s ' \n-' ' ') / $(printf '%s' "$FP_OBJ_B" | tr -s ' \n-' ' ')"
if [ -z "$FP_OBJ_A" ] || [ "$FP_OBJ_A" != "$FP_OBJ_B" ]; then
  echo "FAIL: Stage ${FP_A} and Stage ${FP_B} object files differ" >&2
  exit 1
fi
echo "[PASS] Linux ${LINUX_ARCH_LABEL} (${LINUX_TARGET}) Native Self-Hosting Fixed-Point (Stage ${FP_A} == Stage ${FP_B} SSA & ELF64 .o BIT-FOR-BIT IDENTICAL)!"
# The text assembly of both stages must be identical too: two more QBE runs over
# the whole compiler, overlapped with [6/6] and joined after the E2E pool.
bg_start "$TMP_DIR/fp_asm.log" sh -euc '
  "$1" -t "$2" -o "$3.s" "$3.ssa" &
  PA=$!
  "$1" -t "$2" -o "$4.s" "$4.ssa" &
  PB=$!
  wait "$PA"
  wait "$PB"
  sha256sum "$3.s" "$4.s"
  test -s "$3.s"
  cmp "$3.s" "$4.s"
' fp_asm "$OUT_DIR/qbe" "$LINUX_TARGET" "$TMP_DIR/linux_stage${FP_A}" "$TMP_DIR/linux_stage${FP_B}"
FP_ASM_PID="$BG_PID"
# Keep the fixed-point SSA: CI compares it byte-for-byte with the macOS ARM64 out/stage2.ssa.
cp "$TMP_DIR/linux_stage${FP_B}.ssa" "$OUT_DIR/linux_stage.ssa"
# [6/6] must test the compiler built from this tree, not the (possibly older) seed.
cp "$TMP_DIR/pionc_linux_s4" "$OUT_DIR/pionc_linux"
PIONC="$OUT_DIR/pionc_linux"
# Wave K1-A (p98) is the longest E2E suite (two >65,279-section COFF big-obj
# assemblies when mingw-w64 is installed). It is independent of everything below
# (own mktemp -d + CAS, nothing written to the tree), so it starts now, overlaps
# [6/6], and is joined right after the E2E pool, before any wall-clock check.
bg_start "$TMP_DIR/p98.log" env PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p98_section_gc/run_e2e.sh" "$PIONC"
P98_PID="$BG_PID"
T_P98_0="$(now_ms)"

echo "=== [6/6] Native Linux ${LINUX_ARCH_LABEL} pionc: test / fmt / run / Multi-Benchmark Checksum Verification ==="
# One long single-threaded build: overlapped, joined after the E2E pool.
bg_start "$TMP_DIR/core_test.log" env PION_CACHE_DIR="$TMP_DIR/cas_core" \
  sh "$ROOT_DIR/scripts/core-test.sh" "$PIONC"
CORE_PID="$BG_PID"

# POSIX TCP + FFI runtime primitives from Pion, over real 127.0.0.1 TCP
NET_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/net_ffi.pion" --loopback)"
echo "pionc_linux run net_ffi --loopback -> $(printf '%s' "$NET_OUT" | tr '\n' ' ')"
if [ "$NET_OUT" != "$(printf 'loopback ok\nnet_ffi ok')" ]; then
  echo "FAIL: net_ffi loopback output mismatch" >&2
  exit 1
fi

# std/http: in-process request/response over TCP, then http_request against a
# Python server (its port arrives through a FIFO, no sleeps).
PORT_FIFO="$TMP_DIR/http_port.fifo"
mkfifo "$PORT_FIFO"
python3 - "$PORT_FIFO" <<'PYEOF' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"hello from server" if self.path == "/hello" else b"wrong path"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write("%d\n" % srv.server_address[1])
srv.handle_request()
PYEOF
PY_PID=$!
read HTTP_PORT < "$PORT_FIFO"
HTTP_OUT="$("$PIONC" run "$ROOT_DIR/examples/http_loopback" "$HTTP_PORT")"
wait "$PY_PID"
echo "pionc_linux run examples/http_loopback $HTTP_PORT -> $(printf '%s' "$HTTP_OUT" | tr '\n' ' ')"
if [ "$HTTP_OUT" != "$(printf 'http in-process ok\nhttp_request ok: 200 text/plain')" ]; then
  echo "FAIL: std/http loopback output mismatch" >&2
  exit 1
fi

FMT_JSON="$("$PIONC" fmt --check --json "$ROOT_DIR/examples/text_stats" "$ROOT_DIR/benchmarks/pion" "$ROOT_DIR/std/json" "$ROOT_DIR/std/http" \
  "$ROOT_DIR/std/net" "$ROOT_DIR/examples/http_event_server" "$ROOT_DIR/std/regex" "$ROOT_DIR/std/proc" "$ROOT_DIR/std/tls" "$ROOT_DIR/tests/e2e/p17a_ergonomics_mt.pion" \
  "$ROOT_DIR/examples/https_server" "$ROOT_DIR/tests/e2e/dyn_trait.pion" \
  "$ROOT_DIR/tests/e2e/p22a_systems_io.pion" "$ROOT_DIR/tests/e2e/p25a_c_varargs.pion" "$ROOT_DIR/examples/pion_station" \
  "$ROOT_DIR/tools/mbt_compat" "$ROOT_DIR/tools/mbt2pion" "$ROOT_DIR/tools/mbt2pion_cli")"
echo "pionc_linux fmt --check --json -> $FMT_JSON"
if [ "$FMT_JSON" != '{"ok":true,"unformatted":[]}' ]; then
  echo "FAIL: fmt --check failed on Linux: $FMT_JSON" >&2
  exit 1
fi

# Verify fmt catches unformatted file, fixes it, and is idempotent
MESSY="$TMP_DIR/messy.pion"
printf 'pub fn f(x : Int) -> Int {\n    let   y = x + 1   \n\n\nreturn y\n}\n' > "$MESSY"
set +e
MESSY_CHK="$("$PIONC" fmt --check --json "$MESSY")"
MESSY_RC=$?
set -e
echo "pionc_linux fmt --check messy -> rc=$MESSY_RC out=$MESSY_CHK"
if [ "$MESSY_RC" -eq 0 ]; then
  echo "FAIL: expected non-zero rc on unformatted file" >&2
  exit 1
fi
"$PIONC" fmt "$MESSY"
FIXED_CHK="$("$PIONC" fmt --check --json "$MESSY")"
if [ "$FIXED_CHK" != '{"ok":true,"unformatted":[]}' ]; then
  echo "FAIL: file still unformatted after pionc fmt: $FIXED_CHK" >&2
  exit 1
fi

# Build the parallel E2E pool command list (slowest & folded [6/6] suites first).
# Lines without PATH="$ORIG_PATH" keep the failing-`as` PATH of this gate.
E2E_CMDS="$TMP_DIR/e2e_cmds.txt"
: > "$E2E_CMDS"
STATION_LIB_PATH="${LIBRARY_PATH:-}"
if [ -f /usr/include/openssl/ssl.h ] || pkg-config --exists openssl 2>/dev/null; then
  printf '%s\n' 'sh "$ROOT_DIR/scripts/test-linux.sh" --group tls_client' >> "$E2E_CMDS"
  printf '%s\n' 'sh "$ROOT_DIR/scripts/test-linux.sh" --group https_server' >> "$E2E_CMDS"
  if { [ -f /usr/include/sqlite3.h ] || pkg-config --exists sqlite3 2>/dev/null || [ -f "${MULTIARCH_LIB_DIR}/libsqlite3.so.0" ]; } \
    && command -v sqlite3 >/dev/null 2>&1; then
    if [ -f "${MULTIARCH_LIB_DIR}/libsqlite3.so.0" ] && [ ! -e "${MULTIARCH_LIB_DIR}/libsqlite3.so" ]; then
      # Runtime package only (no -dev): give the linker a libsqlite3.so outside the source tree.
      ln -sf "${MULTIARCH_LIB_DIR}/libsqlite3.so.0" "$OUT_DIR/libsqlite3.so"
      STATION_LIB_PATH="$OUT_DIR${STATION_LIB_PATH:+:$STATION_LIB_PATH}"
    fi
    printf '%s\n' 'sh "$ROOT_DIR/scripts/test-linux.sh" --group pion_station' >> "$E2E_CMDS"
  else
    echo "NOTE: libsqlite3 or the sqlite3 CLI not found; skipping examples/pion_station tests and e2e"
  fi
else
  echo "NOTE: OpenSSL development files not found; skipping std/tls + examples/https_server tests and client/server e2e handshakes"
fi
cat >> "$E2E_CMDS" <<'E2E'
sh "$ROOT_DIR/scripts/test-linux.sh" --group mbt_tests
sh "$ROOT_DIR/scripts/test-linux.sh" --group std_tests
sh "$ROOT_DIR/scripts/test-linux.sh" --group standalone_e2e
# Slowest suites first so the pool packs well.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p90_qbe_far_branch_rega/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p87_st_frozen_rc/run_e2e.sh" "$PIONC"
# P29-C: zero-toolchain WebAssembly (--target wasm32 + runtime/pion_wasm_rt.mjs + 4 V1 benchmarks in Node.js).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p29c_wasm32/run_e2e.sh" "$PIONC"
# pionc add / update against an offline git-index registry.
sh "$ROOT_DIR/tests/e2e/pkg_cli/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tools/mbt2pion_cli/tests/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/wave_j4b_pkg_alias/run_e2e.sh" "$PIONC"
# P94: Wave J3 — first-class immutable Send sequence type ImmArray[T].
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p94_imm_array/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p76_value_key_map/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p77_views_and_lib_os/run_e2e.sh" "$PIONC"
# P30-H: cross-pkg generic Mutex[Array[Ev]] / Channel[Cmd] deep-freeze under real OS threads (release + ASan + TSan).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p30h_crosspkg_mt_deep_freeze/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p91_test_runner_cli/run_e2e.sh" "$PIONC"
# P96: stack-promoted POD structs & StrView/BytesView carry 24B immortal PionHeader across multi-hop RC calls.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p96_pod_stack_rc_soundness/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p85_bytes_bce/run_e2e.sh" "$PIONC"
# P97: per-process unique output staging directories (`test --jobs 4` race, same-pid leftovers, fail-fast mkdir errors).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p97_stage_dir_race/run_e2e.sh" "$PIONC"
# P99: anonymous struct literals without a struct context fail closed in check (no NULL-struct SIGSEGV); legal contexts Native == Wasm32.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p99_anon_struct_lit/run_e2e.sh" "$PIONC"
# P27-B: Bug #5 cyclic graph deep freeze (PION_FLAG_DEEP_FROZEN) + named & optional default parameters (same-pkg & cross-pkg).
sh "$ROOT_DIR/tests/e2e/p27b_freeze_named_args/run_e2e.sh" "$PIONC"
# P27-C1: Bug #6 cross-pkg mono private lookups + Bug #7 generic closure %tp_T capture + native Map[Int/Int64, V] + #derive(Eq) + ASan/LSan.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p27c1_crosspkg_clo_intmap_eq/run_e2e.sh" "$PIONC"
# P27-C2: Float (IEEE-754 f32), UInt/UInt64 (unsigned 32/64-bit), FixedArray[T] + Array::make + C FFI + ASan/LSan (0 runtime bytes).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p27c2_float_uint_fixedarray/run_e2e.sh" "$PIONC"
# std/proc: streaming subprocess + cross-platform PTY (native + ASan).
PATH="$ORIG_PATH" sh "$ROOT_DIR/std/proc/e2e/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p101_map_init_arg_order/run_e2e.sh" "$PIONC"
# P26-A: native link (c_sources .c/.cc invoke system cc/c++ which need real `as`).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/native_link/run_e2e.sh" "$PIONC"
# P26-B: C callbacks, zero-copy FFI/math/StringBuilder, cross-pkg generic Option mono & private exports.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p26b_ffi_generics/run_e2e.sh" "$PIONC"
# P29-A: multi-target (--target all 9 POSIX/mobile targets, --emit-asm, --emit-staticlib, --emit-cdylib C host calls).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p29a_multi_target/run_e2e.sh" "$PIONC"
# P30-A: Bugs #9-#13 (Array/FixedArray::contains, tuple-Option-if match, E_CAPTURE_MUT_ASSIGN, Float bare lits, \u{...} escapes; native + ASan + Wasm32).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p30a_bugs9_to_13/run_e2e.sh" "$PIONC"
# P30-B: single-thread RC fast path, borrow RC elision + adversarial ASan/LSan, Bug #15 unannotated closure param infer.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p30b_rc_borrow_perf/run_e2e.sh" "$PIONC"
# P30-C: Bugs #16a & #16b (generic higher-order closure return infer + struct method own tparam unification; native + ASan + Wasm32).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p30c_generic_infer/run_e2e.sh" "$PIONC"
# P31-A: -> Unit tail discard, struct TFn field direct call, local closure let mut auto-boxing, Array/Map::with_capacity (native + ASan/LSan + Wasm32).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p31a_ergonomics/run_e2e.sh" "$PIONC"
# P31-C: leading-dot .Variant inference + pure compile-time desugared Pion-JSX + pionc fmt (native + ASan/LSan + Wasm32).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p31c_jsx_dot/run_e2e.sh" "$PIONC"
# P32-A: relocatable zero-env toolchain, default ".", --help/--version, check --fix, doctor, cache/clean, remove, package-release.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p32a_toolchain/run_e2e.sh" "$PIONC"
# P32-B: multi-package virtual [workspace], [workspace.dependencies], { workspace = true }, shared pion.lock, CLI --package/-p.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p32b_workspace/run_e2e.sh" "$PIONC"
# P32-C: amd64_sysv direct ELF64 XMM stack-arg encoding (>8 Double/Float + mixed GPR/XMM).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p32c_abi_fp_stack/run_e2e.sh" "$PIONC"
# P33-B: multi-package incremental CAS for `pionc check` (.pionsig/.pionstub) & `pionc build --target wasm32` (.ssa/.wasm).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p33b_incremental_cas/run_e2e.sh" "$PIONC"
# P35-A: second-class `mut` parameters, `mut self`, `#verify` rules and runtime checks (native + ASan/LSan + Wasm32, cross-package `[verify]`).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p35a_verify_mut/run_e2e.sh" "$PIONC"
# P68-B: QBE load.c/fold.c CAddr cross-type cast regression (enum String vs Double dead branch + direct cast).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p68b_qbe_caddr_cast/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p71a_staticlib_android/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p71b_invar_fixes/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p72b_lang_cli/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p73_deep_rc_drop/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p74a_topo_init_and_variant/run_e2e.sh" "$PIONC"
# P75-A: Signed Int8 + compact 1B/4B arrays + Float32 alias + Bytes::read_i8/read_f32_le (native + ASan + Wasm32 + SSA + RSS).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p75a_compact_i8_f32/run_e2e.sh" "$PIONC"
# P75-B: Portable SIMD vector primitives + 4-row tiled INT8 matvec (native + ASan + Wasm32 + OOB + speedup).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p75b_simd_primitives/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p72a_flat_pod_opt/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p106_flat_array_field_proj/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p74c_licm_alias_soundness/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p74d_float_to_int_sat/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p74f_xpkg_pod_borrow_soundness/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p74e_cli_cas_hygiene/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p79_qbe_fcsel/run_e2e.sh" "$PIONC"
# P100: QBE soundness (copy.c dwl phi retry/cycle, gvn.c usecls jnz vs 64-bit ret, load.c shifted-store mask, mem.c 4-byte slot l extension, copyref cnew width).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p100_qbe_soundness/run_e2e.sh" "$PIONC"
# P102: QBE codegen optimizations (test %r,%r, SIB shl folding + disp32/CAddr guards, short rel8, multi-byte NOP, acc imm32, arm64 stp/ldp).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p102_qbe_codegen_opts/run_e2e.sh" "$PIONC"
# P103: Wave L0 — nested tuple patterns, Array::is_empty/truncate, Double::is_nan/compare/reinterpret_as_int64 + Hash -0.0, Int::lnot.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p103_wave_l0_stdlib_tuple/run_e2e.sh" "$PIONC"
# P105: AArch64 private spill-slot stp/ldp pairing (arm64_slotpair unit test, text asm, qemu / native Mach-O --obj).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p105_arm64_spill_pairs/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p82a_wasm_arr_clear_f32_push/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p85_enum_sroa/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/query_analyze/run_e2e.sh" "$PIONC"
# P108: QbeReadPair hoisted pair headers/bounds & bounded memchr byte scan.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p108_read_pair_and_byte_scan/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p_into_callsite/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p85_ror_bitops/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p85_compact_4b_arr/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p86_qbe_rss_budget/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p88_borrow_moveout/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p89_unit_enum/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p91_data_ptr_safety/run_e2e.sh" "$PIONC"
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p92_math_wasm_paths/run_e2e.sh" "$PIONC"
# P93: symlinked pionc self-location + atomic (temp + rename) native/Wasm32 link publishing.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p93_cli_link_symlink/run_e2e.sh" "$PIONC"
# P95: Wasm32 nested-loop outlining writes back inner-loop-only read+write slots (Native == Wasm32, Debug + --release).
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p95_wasm_nested_loop_liveout/run_e2e.sh" "$PIONC"
# Translation validation of QBE's SSA optimisations (tools/qbe_tv) on this target.
# Real `as`: its [5/5] builds the tests/tv/qbe_bugs reproducers through QBE text
# assembly (and cc compiles their C driver) besides `--obj`.
PATH="$ORIG_PATH" sh "$ROOT_DIR/scripts/test-tv.sh" "$PIONC" "$OUT_DIR/qbe"
E2E
export ROOT_DIR PIONC ORIG_PATH OUT_DIR STATION_LIB_PATH
sh "$ROOT_DIR/scripts/run-e2e-parallel.sh" < "$E2E_CMDS"
# Join p98 (started before [6/6]); reap any straggling descendants in its session.
P98_RC=0
wait "$P98_PID" || P98_RC=$?
if kill -0 -"$P98_PID" 2>/dev/null; then
  echo "[WARN] test-linux: reaping straggler process(es) in p98 pgid $P98_PID" >&2
  bg_kill "$P98_PID"
fi
P98_PID=""
if [ "$P98_RC" -eq 0 ]; then
  echo "[PASS] tests/e2e/p98_section_gc/run_e2e.sh (overlapped, $(( $(now_ms) - T_P98_0 )) ms since start)"
else
  cat "$TMP_DIR/p98.log"
  echo "FAIL: tests/e2e/p98_section_gc/run_e2e.sh" >&2
  exit 1
fi
if bg_join "$CORE_PID" "$TMP_DIR/core_test.log"; then
  CORE_PID=""
else
  CORE_PID=""
  exit 1
fi
if bg_join "$FP_ASM_PID" "$TMP_DIR/fp_asm.log"; then
  FP_ASM_PID=""
  echo "[PASS] Linux ${LINUX_ARCH_LABEL} (${LINUX_TARGET}) Stage ${FP_A} == Stage ${FP_B} ASM BIT-FOR-BIT IDENTICAL"
else
  FP_ASM_PID=""
  echo "FAIL: Stage ${FP_A} and Stage ${FP_B} assembly differ (or QBE failed)" >&2
  exit 1
fi
# P71-C asserts wall-clock HashDoS budgets: run it alone, never next to the pool.
PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p71c_hashdos_bytes/run_e2e.sh" "$PIONC"

# Multi-package run (cold + hot + 0-pollution)
BEFORE_TS="$(find "$ROOT_DIR/examples/text_stats" -type f | sort)"
T_TS0="$(now_ms)"
OUT_TS1="$("$PIONC" run "$ROOT_DIR/examples/text_stats")"
T_TS1="$(now_ms)"
OUT_TS2="$("$PIONC" run "$ROOT_DIR/examples/text_stats")"
T_TS2="$(now_ms)"
AFTER_TS="$(find "$ROOT_DIR/examples/text_stats" -type f | sort)"
echo "LINUX_X64 text_stats: cold=$((T_TS1 - T_TS0))ms hot=$((T_TS2 - T_TS1))ms out='$OUT_TS2'"
if [ "$OUT_TS1" != "text_stats ok: lines=4 words=18 tagged=2 exec=pion-exec-ok" ] || [ "$OUT_TS1" != "$OUT_TS2" ]; then
  echo "FAIL: text_stats output mismatch on Linux x86_64: '$OUT_TS1'" >&2
  exit 1
fi
if [ "$BEFORE_TS" != "$AFTER_TS" ]; then
  echo "FAIL: examples/text_stats polluted!" >&2
  exit 1
fi

verify_bench() {
  name="$1"
  expected="$2"
  shift 2
  tb0="$(now_ms)"
  got="$("$PIONC" run --release "$ROOT_DIR/benchmarks/pion/${name}.pion" "$@")"
  tb1="$(now_ms)"
  echo "LINUX_X64 ${name}: $((tb1 - tb0))ms out='${got}'"
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

# Dogfood: event-loop HTTP server (--self-test: routes, pipelining, real epoll TCP).
"$PIONC" build --release -o "$OUT_DIR/http_event_server" "$ROOT_DIR/examples/http_event_server"
"$OUT_DIR/http_event_server" --self-test
rm -f "$OUT_DIR/http_event_server"

# Dogfood: multithreaded HTTP+JSON KV service under real 8 x 500 TCP load (0 errors, exact /stats).
KV_TEST="$("$PIONC" test --json "$ROOT_DIR/examples/http_kv_service")"
echo "pionc_linux test --json examples/http_kv_service -> $KV_TEST"
printf '%s' "$KV_TEST" | grep -q '"failed":0'
BENCH_LOAD="$OUT_DIR/bench_load" sh "$ROOT_DIR/examples/http_kv_service/run_bench.sh" "$PIONC" 8 500 8
# Same load over HTTP/1.1 keep-alive (one connection per client thread).
KEEP_ALIVE=1 BENCH_LOAD="$OUT_DIR/bench_load" sh "$ROOT_DIR/examples/http_kv_service/run_bench.sh" "$PIONC" 8 500 8

echo "ALL LINUX ${LINUX_ARCH_LABEL} (${LINUX_TARGET}) NATIVE BUILD, SELF-HOST & BENCHMARK CHECKSUM GATES PASSED!"
