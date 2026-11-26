#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/out"
RT_DIR="$ROOT_DIR/runtime"
CC="${CC:-gcc}"

mkdir -p "$OUT_DIR"

MODE="full"
while [ $# -gt 0 ]; do
  case "$1" in
    --bootstrap-only) MODE="bootstrap"; shift ;;
    --e2e-only) MODE="e2e"; shift ;;
    *) echo "usage: test-windows.sh [--bootstrap-only | --e2e-only]" >&2; exit 2 ;;
  esac
done

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}
T_GATE_START="$(now_ms)"

TMP_DIR="$(mktemp -d)"
. "$ROOT_DIR/scripts/bg-lib.sh"
RT_PID=""
P98_PID=""
FP_ASM_PID=""
CORE_PID=""
TLS_PID=""
cleanup() {
  bg_kill "$RT_PID" "$P98_PID" "$FP_ASM_PID" "$CORE_PID" "$TLS_PID"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# bg_finish <name> <pid> <log>: join a background step and fail the gate if it failed.
bg_finish() {
  if ! bg_join "$2" "$3"; then
    echo "FAIL: $1" >&2
    exit 1
  fi
}

# Verify Windows Job Object cleanup and fail-closed startup gates:
# 1. A failing wrapper that leaves a detached native child must propagate
#    failure through bg_finish AND leave the child dead.
# 2. EOF on child_code's release pipe must exit non-zero without starting the workload.
# 3. AssignProcessToJobObject failure in a normal-env bg_start must fail closed,
#    preserve the Win32 error, and never start the workload.
verify_bg_win_job() {
  _job_pid_file="$TMP_DIR/job_probe_child.pid"
  _job_log="$TMP_DIR/job_probe.log"
  rm -f "$_job_pid_file"
  _job_rc=0
  (
    bg_start "$_job_log" python3 -c '
import os, subprocess, sys
child = subprocess.Popen(
    [sys.executable, "-c", "import os, sys, time; print(os.getpid(), flush=True); time.sleep(30)"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
pid_line = child.stdout.readline().decode("ascii").strip()
with open(sys.argv[1], "w") as f:
    f.write(pid_line)
os._exit(1)
' "$_job_pid_file"
    bg_finish "bg-lib job probe" "$BG_PID" "$_job_log"
  ) >/dev/null 2>&1 || _job_rc=$?
  if [ "$_job_rc" -eq 0 ]; then
    echo "FAIL: bg_finish unexpectedly succeeded for failing job probe" >&2
    cat "$_job_log" >&2 || true
    exit 1
  fi
  if [ ! -s "$_job_pid_file" ]; then
    echo "FAIL: bg-lib job probe did not write native child PID" >&2
    cat "$_job_log" >&2 || true
    exit 1
  fi
  python3 - "$_job_pid_file" "$ROOT_DIR/scripts/bg-lib.sh" <<'PYEOF'
import ast, ctypes, ctypes.wintypes as w, re, subprocess, sys

# 1. Reparented native child must be dead after bg_finish.
pid = int(open(sys.argv[1]).read().strip())
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
k32.OpenProcess.restype = w.HANDLE
k32.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
k32.WaitForSingleObject.restype = w.DWORD
k32.CloseHandle.argtypes = [w.HANDLE]
k32.CloseHandle.restype = w.BOOL
h = k32.OpenProcess(0x00100000, False, pid)
if h:
    res = k32.WaitForSingleObject(h, 0)
    k32.CloseHandle(h)
    assert res == 0, f"FAIL: native child PID {pid} still alive after bg_finish (wait={res})"

# 2. EOF on child_code release pipe must NOT start the workload.
txt = open(sys.argv[2]).read()
m = re.search(r"_bg_py='\n(.*?)\n'\n", txt, re.S)
assert m, "missing _bg_py"
tree = ast.parse(m.group(1))
child_src = None
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and getattr(node.targets[0], "id", "") == "child_code":
        child_src = ast.literal_eval(node.value)
        break
assert child_src, "missing child_code"
r_eof = subprocess.run(
    [sys.executable, "-c", child_src, "sh", "-c", "echo WORKLOAD_STARTED"],
    input=b"",
    capture_output=True,
)
assert r_eof.returncode != 0, f"FAIL: child_code succeeded on EOF (rc={r_eof.returncode})"
assert b"WORKLOAD_STARTED" not in r_eof.stdout, f"FAIL: workload started on EOF: {r_eof.stdout!r}"
print(f"[PASS] bg-lib Windows Job Object reparented-child cleanup & EOF fail-closed verified (child pid={pid} exited, eof_rc={r_eof.returncode})")
PYEOF

  # 3. Normal-env AssignProcessToJobObject failure must fail closed with Win32 error and never run workload.
  _inj_dir="$TMP_DIR/win_job_inject"
  _inj_marker="$TMP_DIR/win_job_inject.marker"
  _inj_log="$TMP_DIR/win_job_inject.log"
  mkdir -p "$_inj_dir"
  rm -f "$_inj_marker" "$_inj_log"
  cat > "$_inj_dir/sitecustomize.py" <<'PYEOF'
import ctypes
_orig_windll = ctypes.WinDLL
class _FailAssign:
    def __init__(self, inner):
        self._inner = inner
    def __getattr__(self, name):
        if name == "AssignProcessToJobObject":
            class _Fn:
                argtypes = None
                restype = None
                def __call__(self, _job, _proc):
                    ctypes.set_last_error(5)
                    return 0
            return _Fn()
        return getattr(self._inner, name)
def _patched_windll(name, *args, **kwargs):
    dll = _orig_windll(name, *args, **kwargs)
    if str(name).lower().startswith("kernel32"):
        return _FailAssign(dll)
    return dll
ctypes.WinDLL = _patched_windll
PYEOF
  _inj_rc=0
  (
    export PYTHONPATH="$(cygpath -w "$_inj_dir")${PYTHONPATH:+;$PYTHONPATH}"
    bg_start "$_inj_log" sh -c 'echo WORKLOAD_STARTED > "$1"' _ "$_inj_marker"
    bg_finish "bg-lib assign-fail probe" "$BG_PID" "$_inj_log"
  ) >/dev/null 2>&1 || _inj_rc=$?
  if [ "$_inj_rc" -eq 0 ]; then
    echo "FAIL: bg_finish unexpectedly succeeded when AssignProcessToJobObject failed" >&2
    cat "$_inj_log" >&2 || true
    exit 1
  fi
  if [ -e "$_inj_marker" ]; then
    echo "FAIL: workload started despite AssignProcessToJobObject failure" >&2
    exit 1
  fi
  if ! grep -q "winerr=5" "$_inj_log"; then
    echo "FAIL: missing preserved Win32 error (winerr=5) in job failure log:" >&2
    cat "$_inj_log" >&2 || true
    exit 1
  fi
  echo "[PASS] bg-lib Windows Job Object assign-failure fail-closed verified (rc=$_inj_rc, winerr=5, workload not started)"
}
if [ "$MODE" != "e2e" ]; then
verify_bg_win_job

echo "=== [1/5] Windows x86_64 Environment & QBE (T_amd64_win) Build ==="
uname -a
"$CC" --version | head -n 1
CC="$CC" sh "$ROOT_DIR/scripts/build-qbe.sh" "$OUT_DIR/qbe.exe"

echo "=== [2/5] Build Win32 libpionrt.a & Run test_rt.c ==="
"$CC" -std=c11 -O2 -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident \
  -Wall -Wextra -Werror -c "$RT_DIR/pion_rt.c" -o "$OUT_DIR/pion_rt.o"
rm -f "$OUT_DIR/libpionrt.a"
ar rcs "$OUT_DIR/libpionrt.a" "$OUT_DIR/pion_rt.o"
LIB_SIZE="$(wc -c < "$OUT_DIR/libpionrt.a" | tr -d ' ')"
echo "Windows x86_64 libpionrt.a size: ${LIB_SIZE} bytes"
if [ "$LIB_SIZE" -ge 65536 ]; then
  echo "FAIL: libpionrt.a (${LIB_SIZE} bytes) exceeds 64 KB budget" >&2
  exit 1
fi
"$CC" -std=c11 -O2 -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-ident \
  -Wall -Wextra -Werror -c "$RT_DIR/pion_cli.c" -o "$OUT_DIR/pion_cli.o"
rm -f "$OUT_DIR/libpionrt_cli.a"
ar rcs "$OUT_DIR/libpionrt_cli.a" "$OUT_DIR/pion_rt.o" "$OUT_DIR/pion_cli.o"

# test_rt only depends on libpionrt.a: overlap it with the Stage 0 bootstrap below.
bg_start "$TMP_DIR/test_rt.log" sh -euc '
  CC="$1"
  RT_DIR="$2"
  OUT_DIR="$3"
  TMP_DIR="$4"
  "$CC" -std=c11 -O2 -Wall -Wextra -Werror -I"$RT_DIR" \
    "$RT_DIR/test_rt.c" "$RT_DIR/pion_cli.c" "$OUT_DIR/libpionrt.a" -lm -lws2_32 -o "$OUT_DIR/test_rt_win.exe"
  if ! "$OUT_DIR/test_rt_win.exe" > "$TMP_DIR/test_rt.out" 2>&1; then
    cat "$TMP_DIR/test_rt.out"
    exit 1
  fi
  cat "$TMP_DIR/test_rt.out"
  grep -q "tcp_loopback_mt (4 concurrent TCP clients on 127.0.0.1" "$TMP_DIR/test_rt.out" || {
    echo "FAIL: tcp_loopback_mt did not run the real 127.0.0.1 TCP loopback on Windows" >&2
    exit 1
  }
' test_rt "$CC" "$RT_DIR" "$OUT_DIR" "$TMP_DIR"
RT_PID="$BG_PID"

echo "=== [3/5] Native Windows x86_64 pionc Bootstrap from bootstrap/pionc-seed.ssa.gz ==="
SEED_SSA="$TMP_DIR/pionc-seed.ssa"
gzip -dc "$ROOT_DIR/bootstrap/pionc-seed.ssa.gz" > "$SEED_SSA"

T_B0="$(now_ms)"
"$OUT_DIR/qbe.exe" -t amd64_win -o "$TMP_DIR/pionc_win.s" "$SEED_SSA"
"$CC" -Wa,-mbig-obj -c "$TMP_DIR/pionc_win.s" -o "$OUT_DIR/pionc_win.o"
"$CC" "$OUT_DIR/pionc_win.o" "$OUT_DIR/libpionrt_cli.a" -lm -lws2_32 -Wl,--stack,16777216 -o "$OUT_DIR/pionc_win.exe"
T_B1="$(now_ms)"
PIONC_SIZE="$(wc -c < "$OUT_DIR/pionc_win.exe" | tr -d ' ')"
echo "Native Windows x86_64 pionc_win.exe: assemble+link=$((T_B1 - T_B0))ms, size=${PIONC_SIZE} bytes"
"$OUT_DIR/pionc_win.exe" --version
bg_finish "test_rt (runtime unit + MT + TCP loopback)" "$RT_PID" "$TMP_DIR/test_rt.log"
RT_PID=""

export PION_QBE="$OUT_DIR/qbe.exe"
export PION_RT_LIB="$OUT_DIR/libpionrt.a"
export PION_CACHE_DIR="$TMP_DIR/cas_win"
mkdir -p "$PION_CACHE_DIR"

echo "=== [3.5/5] Windows single-file smoke (check) before Stage 3 ==="
# Only `check` here: the seed's driver links without `-lws2_32`, so its `run`
# cannot link on Windows; `run` is exercised with the Stage 3 binary below.
"$OUT_DIR/pionc_win.exe" check --json "$ROOT_DIR/tests/frontend/ok_full.pion"
echo

echo "=== [4/5] Windows Native Self-Hosting Fixed-Point (Stage 3 == Stage 4) ==="
# The seed's driver predates amd64_win linking (it links `-lm -lpthread`, no
# `-lws2_32`, no `--stack`), so Stage 3 stops at the object and links it here with
# the same flags this tree's driver uses for amd64_win; Stage 4 links itself.
T_S3_0="$(now_ms)"
(cd "$ROOT_DIR" && PION_TARGET="amd64_win" "$OUT_DIR/pionc_win.exe" build \
  --emit-ssa "$TMP_DIR/win_stage3.ssa" \
  --emit-obj "$TMP_DIR/pionc_win_s3.o" \
  compiler/src/core \
  compiler/src/cli/main.pion)
"$CC" "$TMP_DIR/pionc_win_s3.o" "$OUT_DIR/libpionrt_cli.a" -lm -lws2_32 -Wl,--stack,16777216 \
  -o "$TMP_DIR/pionc_win_s3.exe"
T_S3_1="$(now_ms)"
S3_SIZE="$(wc -c < "$TMP_DIR/pionc_win_s3.exe" | tr -d ' ')"
echo "Windows x86_64 native self-host Stage 3: build=$((T_S3_1 - T_S3_0))ms, binary=${S3_SIZE} bytes"

# This tree's driver links amd64_win with `-lws2_32 -Wl,--stack,16777216`: prove `run` end to end.
HELLO_OUT="$("$TMP_DIR/pionc_win_s3.exe" run "$ROOT_DIR/tests/e2e/hello.pion" | tr -d '\r')"
echo "pionc_win_s3 run hello -> $HELLO_OUT"
case "$HELLO_OUT" in
  *hello*) ;;
  *) echo "FAIL: pionc_win_s3 run hello.pion output mismatch: '$HELLO_OUT'" >&2; exit 1 ;;
esac

# Stage 4 runs with PION_TARGET unset to prove pionc_win_s3 auto-detects Windows -> amd64_win!
unset PION_TARGET || true
T_S4_0="$(now_ms)"
(cd "$ROOT_DIR" && PION_RT_LIB="$OUT_DIR/libpionrt_cli.a" PION_CACHE_DIR="$TMP_DIR/cas_win_s4" "$TMP_DIR/pionc_win_s3.exe" build \
  --emit-ssa "$TMP_DIR/win_stage4.ssa" \
  -o "$TMP_DIR/pionc_win_s4.exe" \
  compiler/src/core \
  compiler/src/cli/main.pion)
T_S4_1="$(now_ms)"
S4_SIZE="$(wc -c < "$TMP_DIR/pionc_win_s4.exe" | tr -d ' ')"
echo "Windows x86_64 native self-host Stage 4: build=$((T_S4_1 - T_S4_0))ms, binary=${S4_SIZE} bytes"

"$TMP_DIR/pionc_win_s4.exe" --version
FP_A=3
FP_B=4
if ! cmp -s "$TMP_DIR/win_stage3.ssa" "$TMP_DIR/win_stage4.ssa"; then
  echo "Stage 3 (seed) != Stage 4 (new codegen); running Stage 5 (pionc_win_s4.exe -> pionc_win_s5.exe) to verify Stage 4 == Stage 5 fixed-point"
  (cd "$ROOT_DIR" && PION_RT_LIB="$OUT_DIR/libpionrt_cli.a" PION_CACHE_DIR="$TMP_DIR/cas_win_s5" "$TMP_DIR/pionc_win_s4.exe" build \
    --emit-ssa "$TMP_DIR/win_stage5.ssa" \
    -o "$TMP_DIR/pionc_win_s5.exe" \
    compiler/src/core \
    compiler/src/cli/main.pion)
  FP_A=4
  FP_B=5
fi
cmp "$TMP_DIR/win_stage${FP_A}.ssa" "$TMP_DIR/win_stage${FP_B}.ssa"
echo "[PASS] Windows x86_64 (amd64_win) Native Self-Hosting Fixed-Point (Stage ${FP_A} == Stage ${FP_B} SSA BIT-FOR-BIT IDENTICAL)!"
# The text assembly of both stages must be identical too: two more QBE runs over
# the whole compiler, overlapped with [5/5] and joined at its end.
bg_start "$TMP_DIR/fp_asm.log" sh -euc '
  "$1" -t amd64_win -o "$2.s" "$2.ssa" &
  PA=$!
  "$1" -t amd64_win -o "$3.s" "$3.ssa" &
  PB=$!
  wait "$PA"
  wait "$PB"
  test -s "$2.s"
  cmp "$2.s" "$3.s"
' fp_asm "$OUT_DIR/qbe.exe" "$TMP_DIR/win_stage${FP_A}" "$TMP_DIR/win_stage${FP_B}"
FP_ASM_PID="$BG_PID"

cp "$TMP_DIR/pionc_win_s4.exe" "$OUT_DIR/pionc_win.exe"
PIONC="$OUT_DIR/pionc_win.exe"

if [ "$MODE" = "bootstrap" ]; then
  bg_finish "Stage ${FP_A} == Stage ${FP_B} assembly" "$FP_ASM_PID" "$TMP_DIR/fp_asm.log"
  FP_ASM_PID=""
  echo "[PASS] Windows x86_64 (amd64_win) Stage ${FP_A} == Stage ${FP_B} ASM BIT-FOR-BIT IDENTICAL"
  echo "ALL WINDOWS X86_64 (amd64_win) BOOTSTRAP GATES PASSED!"
  GATE_ELAPSED_S=$(( ($(now_ms) - T_GATE_START) / 1000 ))
  echo "test-windows.sh --bootstrap-only duration: ${GATE_ELAPSED_S}s"
  if [ "$GATE_ELAPSED_S" -gt 60 ]; then
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      echo "::warning title=CI duration > 60s::test-windows.sh --bootstrap-only took ${GATE_ELAPSED_S}s (target <= 60s, hard timeout 180s)"
    fi
    echo "[WARN] test-windows.sh --bootstrap-only took ${GATE_ELAPSED_S}s (> 60s target)"
  fi
  exit 0
fi
else
  PIONC="$OUT_DIR/pionc_win.exe"
  [ -x "$PIONC" ] || { echo "FAIL: --e2e-only requires prebuilt $PIONC" >&2; exit 1; }
  [ -x "$OUT_DIR/qbe.exe" ] || { echo "FAIL: --e2e-only requires prebuilt $OUT_DIR/qbe.exe" >&2; exit 1; }
  export PION_QBE="$OUT_DIR/qbe.exe"
  export PION_RT_LIB="$OUT_DIR/libpionrt.a"
  export PION_CACHE_DIR="$TMP_DIR/cas_win"
  mkdir -p "$PION_CACHE_DIR"
fi

echo "=== [5/5] Native Windows x86_64 pionc: core / std / e2e / V1 Benchmark Checksums ==="
# The long, independent steps (each with its own CAS) overlap the rest of [5/5]:
# p98 (two >65,279-section COFF big-obj assemblies), the core unit tests and the
# std/tls handshakes; all are joined before the benchmarks.
bg_start "$TMP_DIR/p98.log" sh "$ROOT_DIR/tests/e2e/p98_section_gc/run_e2e.sh" "$PIONC"
P98_PID="$BG_PID"
bg_start "$TMP_DIR/core_test.log" env PION_CACHE_DIR="$TMP_DIR/cas_core" \
  sh "$ROOT_DIR/scripts/core-test.sh" "$PIONC"
CORE_PID="$BG_PID"
if command -v openssl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  bg_start "$TMP_DIR/tls.log" env PION_CACHE_DIR="$TMP_DIR/cas_tls" \
    sh "$ROOT_DIR/std/tls/e2e/run_e2e.sh" "$PIONC"
  TLS_PID="$BG_PID"
fi

for TPKG in examples/text_stats std/json std/http std/regex std/proc std/tls; do
  PKG_JSON="$("$PIONC" test --json "$ROOT_DIR/$TPKG")"
  echo "pionc_win test --json $TPKG -> $PKG_JSON"
  printf '%s' "$PKG_JSON" | grep -q '"ok":true'
  printf '%s' "$PKG_JSON" | grep -q '"failed":0'
done

P27A_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/p27a_ergonomics_bug4.pion" | tr -d '\r')"
echo "pionc_win run p27a_ergonomics_bug4 -> $P27A_OUT"
if [ "$P27A_OUT" != "p27a_ergonomics_bug4 ok" ]; then
  echo "FAIL: p27a_ergonomics_bug4 output mismatch: '$P27A_OUT'" >&2
  exit 1
fi

sh "$ROOT_DIR/tests/e2e/p27c2_float_uint_fixedarray/run_e2e.sh" "$PIONC"
# P120: Win64 nonvolatile xmm6..xmm15 save/restore, executed natively (harness.S + driver.c).
if [ "${CI:-}" = "true" ] || [ "${CI:-}" = "1" ]; then
  PION_REQUIRE_COFF=1 PION_REQUIRE_PE_LINK=1 sh "$ROOT_DIR/tests/e2e/p120_win64_xmm_callee_saved/run_e2e.sh" "$PIONC"
else
  sh "$ROOT_DIR/tests/e2e/p120_win64_xmm_callee_saved/run_e2e.sh" "$PIONC"
fi

# Windows directory junction collision regression for --emit-web-rt
JUNC_BASE="$TMP_DIR/junc_web_rt"
JUNC_REAL="$JUNC_BASE/real"
JUNC_LINK="$JUNC_BASE/junc"
mkdir -p "$JUNC_REAL"
printf 'pub fn main() -> Int { 0 }\n' > "$JUNC_BASE/main.pion"
printf 'SENTINEL_WIN_MJS\n' > "$JUNC_REAL/out.mjs"
if command -v cygpath >/dev/null 2>&1; then
  JUNC_REAL_WIN="$(cygpath -w "$JUNC_REAL")"
  JUNC_LINK_WIN="$(cygpath -w "$JUNC_LINK")"
else
  JUNC_REAL_WIN="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$JUNC_REAL")"
  JUNC_LINK_WIN="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$JUNC_LINK")"
fi
MSYS_NO_PATHCONV=1 cmd /c mklink /J "$JUNC_LINK_WIN" "$JUNC_REAL_WIN" >/dev/null
JUNC_ERR="$TMP_DIR/junc_err.txt"
if "$PIONC" build --target wasm32 -o "$JUNC_LINK_WIN\\out.mjs" --emit-web-rt="$JUNC_REAL_WIN\\out.mjs" "$JUNC_BASE/main.pion" 2>"$JUNC_ERR"; then
  echo "FAIL: Windows junction existing-file collision should fail" >&2
  MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true
  exit 1
fi
grep -qi 'collides' "$JUNC_ERR" || { echo "FAIL: Windows junction existing-file error missing 'collides': $(cat "$JUNC_ERR")" >&2; MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true; exit 1; }
if [ "$(cat "$JUNC_REAL/out.mjs" | tr -d '\r')" != "SENTINEL_WIN_MJS" ]; then
  echo "FAIL: Windows junction collision overwrote real/out.mjs" >&2
  MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true
  exit 1
fi
if "$PIONC" build --target wasm32 -o "$JUNC_LINK_WIN\\new.mjs" --emit-web-rt="$JUNC_REAL_WIN\\new.mjs" "$JUNC_BASE/main.pion" 2>"$JUNC_ERR"; then
  echo "FAIL: Windows junction non-existent-file collision should fail" >&2
  MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true
  exit 1
fi
grep -qi 'collides' "$JUNC_ERR" || { echo "FAIL: Windows junction non-existent-file error missing 'collides': $(cat "$JUNC_ERR")" >&2; MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true; exit 1; }
if [ -e "$JUNC_REAL/new.mjs" ]; then
  echo "FAIL: Windows junction collision created real/new.mjs" >&2
  MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true
  exit 1
fi

# Relative path (out.mjs vs C:\...\out.mjs) and drive-root path (\...\out.mjs vs C:\...\out.mjs) collisions
if (cd "$JUNC_REAL" && "$PIONC" build --target wasm32 -o "out.mjs" --emit-web-rt="$JUNC_REAL_WIN\\out.mjs" "$JUNC_BASE/main.pion" 2>"$JUNC_ERR"); then
  echo "FAIL: Windows relative-vs-abs collision should fail" >&2
  MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true
  exit 1
fi
grep -qi 'collides' "$JUNC_ERR" || { echo "FAIL: Windows relative-vs-abs error missing 'collides': $(cat "$JUNC_ERR")" >&2; MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true; exit 1; }
if [ "$(cat "$JUNC_REAL/out.mjs" | tr -d '\r')" != "SENTINEL_WIN_MJS" ]; then
  echo "FAIL: Windows relative-vs-abs collision overwrote real/out.mjs" >&2
  MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true
  exit 1
fi
JUNC_DRV_ROOT_WIN="${JUNC_REAL_WIN#?:}"
if (cd "$JUNC_REAL" && MSYS_NO_PATHCONV=1 "$PIONC" build --target wasm32 -o "${JUNC_DRV_ROOT_WIN}\\new.mjs" --emit-web-rt="$JUNC_REAL_WIN\\new.mjs" "$JUNC_BASE/main.pion" 2>"$JUNC_ERR"); then
  echo "FAIL: Windows drive-root-vs-abs collision should fail" >&2
  MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true
  exit 1
fi
grep -qi 'collides' "$JUNC_ERR" || { echo "FAIL: Windows drive-root-vs-abs error missing 'collides': $(cat "$JUNC_ERR")" >&2; MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true; exit 1; }
if [ -e "$JUNC_REAL/new.mjs" ]; then
  echo "FAIL: Windows drive-root-vs-abs collision created real/new.mjs" >&2
  MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true
  exit 1
fi
MSYS_NO_PATHCONV=1 cmd /c rmdir "$JUNC_LINK_WIN" >/dev/null 2>&1 || true
echo "[PASS] Windows directory junction, relative & drive-root --emit-web-rt collision guards verified"

# Lightweight Windows parallel workspace build smoke test (exercises CreateProcessW / WaitForMultipleObjects)
WIN_PAR_WS="$TMP_DIR/win_par_ws"
mkdir -p "$WIN_PAR_WS/lib_a/src" "$WIN_PAR_WS/lib_b/src" "$WIN_PAR_WS/app/src"
cat <<'EOF' > "$WIN_PAR_WS/lib_a/pion.toml"
[package]
name = "lib_a"
version = "0.1.0"
EOF
cat <<'EOF' > "$WIN_PAR_WS/lib_a/src/lib.pion"
pub fn val_a() -> Int { 19 }
EOF
cat <<'EOF' > "$WIN_PAR_WS/lib_b/pion.toml"
[package]
name = "lib_b"
version = "0.1.0"
EOF
cat <<'EOF' > "$WIN_PAR_WS/lib_b/src/lib.pion"
pub fn val_b() -> Int { 23 }
EOF
cat <<'EOF' > "$WIN_PAR_WS/app/pion.toml"
[package]
name = "win_par_app"
version = "0.1.0"

[dependencies]
lib_a = { path = "../lib_a" }
lib_b = { path = "../lib_b" }
EOF
cat <<'EOF' > "$WIN_PAR_WS/app/src/main.pion"
import "lib_a"
import "lib_b"

pub fn main(w : World) -> Int {
  let v = lib_a::val_a() + lib_b::val_b()
  io_println(w, "winpar=" + v.to_string())
  0
}
EOF
mkdir -p "$TMP_DIR/cas_winpar_1" "$TMP_DIR/cas_winpar_4"
PION_WS_PAR_MIN_PKG_BYTES=1 PION_CACHE_DIR="$TMP_DIR/cas_winpar_1" "$PIONC" build --jobs 1 -o "$TMP_DIR/winpar_j1.exe" "$WIN_PAR_WS/app"
PION_WS_PAR_MIN_PKG_BYTES=1 PION_CACHE_DIR="$TMP_DIR/cas_winpar_4" "$PIONC" build --jobs 4 -o "$TMP_DIR/winpar_j4.exe" "$WIN_PAR_WS/app"
WINPAR_OUT1="$("$TMP_DIR/winpar_j1.exe" | tr -d '\r')"
WINPAR_OUT4="$("$TMP_DIR/winpar_j4.exe" | tr -d '\r')"
if [ "$WINPAR_OUT1" != "winpar=42" ] || [ "$WINPAR_OUT4" != "winpar=42" ]; then
  echo "FAIL: Windows parallel workspace smoke mismatch: j1='$WINPAR_OUT1' j4='$WINPAR_OUT4'" >&2
  exit 1
fi
echo "[PASS] Windows multi-package parallel build smoke (--jobs 1 vs --jobs 4)"

verify_bench() {
  name="$1"
  expected="$2"
  shift 2
  tb0="$(now_ms)"
  got="$("$PIONC" run --release "$ROOT_DIR/benchmarks/pion/${name}.pion" "$@" | tr -d '\r')"
  tb1="$(now_ms)"
  echo "WINDOWS_X64 ${name}: $((tb1 - tb0))ms out='${got}'"
  if [ "$got" != "$expected" ]; then
    echo "FAIL: ${name} checksum mismatch! expected='${expected}' got='${got}'" >&2
    exit 1
  fi
}

# Join the overlapped steps before the timed benchmarks.
if [ -n "$TLS_PID" ]; then
  bg_finish "std/tls e2e" "$TLS_PID" "$TMP_DIR/tls.log"
  TLS_PID=""
fi
bg_finish "compiler core unit tests" "$CORE_PID" "$TMP_DIR/core_test.log"
CORE_PID=""
if [ -n "$FP_ASM_PID" ]; then
  bg_finish "Stage ${FP_A} == Stage ${FP_B} assembly" "$FP_ASM_PID" "$TMP_DIR/fp_asm.log"
  FP_ASM_PID=""
  echo "[PASS] Windows x86_64 (amd64_win) Stage ${FP_A} == Stage ${FP_B} ASM BIT-FOR-BIT IDENTICAL"
fi
bg_finish "tests/e2e/p98_section_gc/run_e2e.sh" "$P98_PID" "$TMP_DIR/p98.log"
P98_PID=""

verify_bench nbody "-0.169075164 -0.169083134"
verify_bench binarytrees "stretch=262143 long=131071 total=14592688"
verify_bench fannkuchredux "73196 38"
verify_bench mandelbrot_mt "6351041 721219984" -- 4
verify_bench hashmap_str "200000 208681440 205599 815496841"

echo "ALL WINDOWS X86_64 (amd64_win) NATIVE BUILD, SELF-HOST & BENCHMARK CHECKSUM GATES PASSED!"
GATE_ELAPSED_S=$(( ($(now_ms) - T_GATE_START) / 1000 ))
echo "test-windows.sh total duration: ${GATE_ELAPSED_S}s"
if [ "$GATE_ELAPSED_S" -gt 60 ]; then
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::warning title=CI duration > 60s::test-windows.sh took ${GATE_ELAPSED_S}s (target <= 60s, hard timeout 300s)"
  fi
  echo "[WARN] test-windows.sh took ${GATE_ELAPSED_S}s (> 60s target)"
fi
