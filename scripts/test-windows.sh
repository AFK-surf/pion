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
MSVC_CSTUB_PID=""
cleanup() {
  bg_kill "$RT_PID" "$P98_PID" "$FP_ASM_PID" "$CORE_PID" "$TLS_PID" "$MSVC_CSTUB_PID"
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

# Overlap LLVM clang/clang++ + VS MSVC parallel cstub CAS E2E with the rest of [5/5]
# so cold MSVC compilation has the full parallel window without extending CI duration.
cat <<'MSVCEOF' > "$TMP_DIR/run_msvc_cstub_job.sh"
#!/bin/sh
set -eu
TMP_DIR="$1"
ROOT_DIR="$2"
PIONC="$3"
PION_QBE="$4"

VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
VS_PATH_U=""
VS_VCVARS_POSIX=""
if [ -x "$VSWHERE" ]; then
  VS_PATH="$("$VSWHERE" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>/dev/null | tr -d '\r' || true)"
  if [ -n "$VS_PATH" ]; then
    VS_PATH_U="$(cygpath -u "$VS_PATH")"
    if [ -f "$VS_PATH_U/VC/Auxiliary/Build/vcvars64.bat" ]; then
      VS_VCVARS_POSIX="$VS_PATH_U/VC/Auxiliary/Build/vcvars64.bat"
    fi
  fi
fi
LLVM_BIN_POSIX=""
if [ -x "/c/Program Files/LLVM/bin/clang.exe" ] && [ -x "/c/Program Files/LLVM/bin/clang++.exe" ]; then
  LLVM_BIN_POSIX="/c/Program Files/LLVM/bin"
elif [ -n "$VS_PATH_U" ] && [ -x "$VS_PATH_U/VC/Tools/Llvm/x64/bin/clang.exe" ] && [ -x "$VS_PATH_U/VC/Tools/Llvm/x64/bin/clang++.exe" ]; then
  LLVM_BIN_POSIX="$VS_PATH_U/VC/Tools/Llvm/x64/bin"
fi
if [ -z "$LLVM_BIN_POSIX" ] || [ -z "$VS_VCVARS_POSIX" ]; then
  if [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "FAIL: Windows CI requires LLVM clang/clang++ and VS vcvars64.bat (llvm_bin=${LLVM_BIN_POSIX:-none} vcvars=${VS_VCVARS_POSIX:-none} vs_path=${VS_PATH_U:-none})" >&2
    exit 1
  fi
  echo "[SKIP] Windows parallel cstub CAS (LLVM clang/clang++ MSVC not installed on this host)"
  exit 0
fi

MSVC_CS_WS="$TMP_DIR/win_msvc_cstub_ws"
MSVC_CS_CAS="$TMP_DIR/cas_win_msvc_cstub"
mkdir -p "$MSVC_CS_WS/msvc_host/src" "$MSVC_CS_WS/msvc_host/compat" "$MSVC_CS_WS/msvc_host/native" \
         "$MSVC_CS_WS/msvc_app/src" "$MSVC_CS_CAS"
cat <<'EOF' > "$MSVC_CS_WS/msvc_host/compat/compat_hdr.h"
#define COMPAT_BASE 100
EOF
cat <<'EOF' > "$MSVC_CS_WS/msvc_host/native/native_hdr.h"
#define NATIVE_BASE 200
EOF
cat <<'EOF' > "$MSVC_CS_WS/msvc_host/compat/c1.c"
#include <stdint.h>
#include "pion_rt.h"
#include "compat_hdr.h"
int32_t msvc_c1(void) { return COMPAT_BASE + 1; }
EOF
cat <<'EOF' > "$MSVC_CS_WS/msvc_host/native/m1.cpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <vector>
#include <cstdint>
#include "compat_hdr.h"
#include "native_hdr.h"
extern "C" int32_t msvc_p1(void) {
  D3D11_VIEWPORT vp = {};
  vp.Width = (float)(NATIVE_BASE + 10);
  std::vector<int32_t> v;
  v.push_back((int32_t)vp.Width);
  v.push_back(GetCurrentProcessId() != 0 ? 1 : 0);
  return v[0] + v[1];
}
EOF
cat <<'EOF' > "$MSVC_CS_WS/msvc_host/native/m2.cpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <vector>
#include <cstdint>
#include "native_hdr.h"
extern "C" int32_t msvc_p2(void) {
  std::vector<int32_t> v;
  v.push_back(NATIVE_BASE);
  v.push_back(20);
  v.push_back(2);
  return v[0] + v[1] + v[2];
}
EOF
cat <<'EOF' > "$MSVC_CS_WS/msvc_host/native/m3.c"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include "compat_hdr.h"
#include "native_hdr.h"
int32_t msvc_c3(void) {
  return COMPAT_BASE + NATIVE_BASE + (GetCurrentProcessId() != 0 ? 3 : 0);
}
EOF
cat <<'EOF' > "$MSVC_CS_WS/msvc_host/pion.toml"
[package]
name = "msvc_host"
version = "0.1.0"

[link.windows]
c_sources = ["compat/c1.c", "native/m1.cpp", "native/m2.cpp", "native/m3.c"]
cc_flags = ["-O2", "-Icompat", "-Inative", "-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH"]
EOF
cat <<'EOF' > "$MSVC_CS_WS/msvc_host/src/lib.pion"
extern "C" fn msvc_c1() -> Int = "msvc_c1"
extern "C" fn msvc_p1() -> Int = "msvc_p1"
extern "C" fn msvc_p2() -> Int = "msvc_p2"
extern "C" fn msvc_c3() -> Int = "msvc_c3"

pub fn host_sum() -> Int {
  msvc_c1() + msvc_p1() + msvc_p2() + msvc_c3()
}
EOF
cat <<'EOF' > "$MSVC_CS_WS/msvc_app/app_c.c"
#include <stdint.h>
int32_t msvc_app_c(void) { return 99; }
EOF
cat <<'EOF' > "$MSVC_CS_WS/msvc_app/pion.toml"
[package]
name = "msvc_app"
version = "0.1.0"

[dependencies]
msvc_host = { path = "../msvc_host" }

[link]
c_sources = ["app_c.c"]
cc_flags = ["-O2"]
EOF
cat <<'EOF' > "$MSVC_CS_WS/msvc_app/src/main.pion"
import "msvc_host"

extern "C" fn msvc_app_c() -> Int = "msvc_app_c"

pub fn msvc_total() -> Int {
  msvc_host::host_sum() + msvc_app_c()
}

pub fn main(w : World) -> Int {
  io_println(w, "msvc_cstub=" + msvc_total().to_string())
  0
}
EOF
cat <<'EOF' > "$MSVC_CS_WS/msvc_app/src/msvc_test.pion"
test "msvc_cstub_ok" {
  debug_assert(msvc_total() == 936, "msvc_cstub_ok")
}
EOF

VCVARS_WIN="$(cygpath -w "$VS_VCVARS_POSIX")"
LLVM_BIN_WIN="$(cygpath -w "$LLVM_BIN_POSIX")"
RT_DIR_WIN="$(cygpath -w "$ROOT_DIR/runtime")"
PIONC_WIN="$(cygpath -w "$PIONC")"
QBE_WIN="$(cygpath -w "$PION_QBE")"
MSVC_CAS_WIN="$(cygpath -w "$MSVC_CS_CAS")"
MSVC_APP_WIN="$(cygpath -w "$MSVC_CS_WS/msvc_app")"
MSVC_EXE1_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_1.exe")"
MSVC_EXE2_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_2.exe")"
MSVC_EXE3_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_3.exe")"
MSVC_EXE4_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_4.exe")"
MSVC_EXE5_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_5.exe")"
MSVC_TR1_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_1.trace")"
MSVC_TR2_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_2.trace")"
MSVC_TR3_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_3.trace")"
MSVC_TR4_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_4.trace")"
MSVC_TR5_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_5.trace")"
MSVC_TRT_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_test.trace")"
MSVC_TOUT_WIN="$(cygpath -w "$TMP_DIR/win_msvc_cstub_test.out")"
CUSTOM_LIB_DIR="$TMP_DIR/custom_win_lib"
mkdir -p "$CUSTOM_LIB_DIR"
CUSTOM_LIB_WIN="$(cygpath -w "$CUSTOM_LIB_DIR")"
MSVC_BAT="$TMP_DIR/run_msvc_cstub.bat"
cat <<EOF > "$MSVC_BAT"
@echo off
echo [MSVC_TIMER] start %TIME%
call "${VCVARS_WIN}" >nul || exit /b 1
echo [MSVC_TIMER] after_vcvars %TIME%
set "ORIG_LIB=%LIB%"
set "PATH=${LLVM_BIN_WIN};%PATH%"
set "CC=${LLVM_BIN_WIN}\clang.exe"
set "CXX=${LLVM_BIN_WIN}\clang++.exe"
set "PION_WIN_ABI=msvc"
set "CPATH=${RT_DIR_WIN}"
set "PION_CAS_TRACE=1"
set "PION_CACHE_DIR=${MSVC_CAS_WIN}"
set "PION_QBE=${QBE_WIN}"
set "PION_RT_LIB="
"${PIONC_WIN}" build --jobs 2 -o "${MSVC_EXE1_WIN}" "${MSVC_APP_WIN}" 2>"${MSVC_TR1_WIN}" || exit /b 11
echo [MSVC_TIMER] after_build1 %TIME%
"${PIONC_WIN}" build --jobs 2 -o "${MSVC_EXE2_WIN}" "${MSVC_APP_WIN}" 2>"${MSVC_TR2_WIN}" || exit /b 12
echo [MSVC_TIMER] after_build2 %TIME%
"${PIONC_WIN}" test "${MSVC_APP_WIN}" >"${MSVC_TOUT_WIN}" 2>"${MSVC_TRT_WIN}" || exit /b 13
echo [MSVC_TIMER] after_test %TIME%
set "LIB=${CUSTOM_LIB_WIN};%ORIG_LIB%"
"${PIONC_WIN}" build --jobs 2 -o "${MSVC_EXE3_WIN}" "${MSVC_APP_WIN}" 2>"${MSVC_TR3_WIN}" || exit /b 14
echo [MSVC_TIMER] after_build3_custom_lib %TIME%
set "LIB=%ORIG_LIB%"
set "_LINK_=/NOLOGO"
"${PIONC_WIN}" build --jobs 2 -o "${MSVC_EXE4_WIN}" "${MSVC_APP_WIN}" 2>"${MSVC_TR4_WIN}" || exit /b 15
echo [MSVC_TIMER] after_build4_link_env %TIME%
set "_LINK_="
set "LIB=%ORIG_LIB%;C:\Program Files\LLVM\lib_winlib_miss_probe"
"${PIONC_WIN}" build --jobs 2 -o "${MSVC_EXE5_WIN}" "${MSVC_APP_WIN}" 2>"${MSVC_TR5_WIN}" || exit /b 16
echo [MSVC_TIMER] after_build5_winlib_miss %TIME%
EOF
MSVC_BAT_WIN="$(cygpath -w "$MSVC_BAT")"
MSVC_RC=0
MSYS_NO_PATHCONV=1 cmd.exe /c "$MSVC_BAT_WIN" || MSVC_RC=$?
echo "=== [WIN_CSTUB_PAR MSVC] cold build trace ==="
cat "$TMP_DIR/win_msvc_cstub_1.trace" 2>/dev/null || true
echo "=== [WIN_CSTUB_PAR MSVC] warm build trace ==="
cat "$TMP_DIR/win_msvc_cstub_2.trace" 2>/dev/null || true
echo "=== [WIN_CSTUB_PAR MSVC] warm test trace ==="
cat "$TMP_DIR/win_msvc_cstub_test.trace" 2>/dev/null || true
echo "=== [WIN_CSTUB_PAR MSVC] custom LIB build trace ==="
cat "$TMP_DIR/win_msvc_cstub_3.trace" 2>/dev/null || true
echo "=== [WIN_CSTUB_PAR MSVC] _LINK_ env build trace ==="
cat "$TMP_DIR/win_msvc_cstub_4.trace" 2>/dev/null || true
echo "=== [WIN_CSTUB_PAR MSVC] switched whitelisted LIB build trace ==="
cat "$TMP_DIR/win_msvc_cstub_5.trace" 2>/dev/null || true
echo "=== [WIN_CSTUB_PAR MSVC] CAS obj/ ==="
ls -lh "$MSVC_CS_CAS/obj" 2>/dev/null || true
echo "=== [WIN_CSTUB_PAR MSVC] CAS bin/ ==="
ls -lh "$MSVC_CS_CAS/bin" 2>/dev/null || true
if [ "$MSVC_RC" -ne 0 ]; then
  echo "FAIL: WIN_CSTUB_PAR MSVC bat exited with rc=$MSVC_RC" >&2
  cat "$TMP_DIR/win_msvc_cstub_test.out" >&2 2>/dev/null || true
  exit 1
fi
MSVC_OUT1="$("$TMP_DIR/win_msvc_cstub_1.exe" | tr -d '\r')"
[ "$MSVC_OUT1" = "msvc_cstub=936" ] || { echo "FAIL: WIN_CSTUB_PAR MSVC output mismatch: '$MSVC_OUT1'" >&2; exit 1; }
MSVC_OUT2="$("$TMP_DIR/win_msvc_cstub_2.exe" | tr -d '\r')"
[ "$MSVC_OUT2" = "msvc_cstub=936" ] || { echo "FAIL: WIN_CSTUB_PAR MSVC warm output mismatch: '$MSVC_OUT2'" >&2; exit 1; }
MSVC_OUT3="$("$TMP_DIR/win_msvc_cstub_3.exe" | tr -d '\r')"
[ "$MSVC_OUT3" = "msvc_cstub=936" ] || { echo "FAIL: WIN_CSTUB_PAR MSVC custom-LIB output mismatch: '$MSVC_OUT3'" >&2; exit 1; }
MSVC_OUT4="$("$TMP_DIR/win_msvc_cstub_4.exe" | tr -d '\r')"
[ "$MSVC_OUT4" = "msvc_cstub=936" ] || { echo "FAIL: WIN_CSTUB_PAR MSVC _LINK_-env output mismatch: '$MSVC_OUT4'" >&2; exit 1; }
MSVC_OUT5="$("$TMP_DIR/win_msvc_cstub_5.exe" | tr -d '\r')"
[ "$MSVC_OUT5" = "msvc_cstub=936" ] || { echo "FAIL: WIN_CSTUB_PAR MSVC switched-LIB output mismatch: '$MSVC_OUT5'" >&2; exit 1; }
for _tr in "$TMP_DIR/win_msvc_cstub_1.trace" "$TMP_DIR/win_msvc_cstub_2.trace" "$TMP_DIR/win_msvc_cstub_test.trace"; do
  if grep -q "(local:" "$_tr"; then
    echo "FAIL: WIN_CSTUB_PAR MSVC fell back to local in $_tr" >&2
    exit 1
  fi
done
MSVC_OBJS_1="$(find "$MSVC_CS_CAS/obj" -maxdepth 1 -name 'cstub_*.o' | wc -l | tr -d ' ')"
if [ "$MSVC_OBJS_1" != "5" ]; then
  echo "FAIL: WIN_CSTUB_PAR MSVC expected 5 cstub_*.o, got $MSVC_OBJS_1" >&2
  exit 1
fi
MSVC_HITS_2="$(grep -c '\[cas\] cstub=.* HIT ' "$TMP_DIR/win_msvc_cstub_2.trace" || true)"
if [ "$MSVC_HITS_2" != "5" ] || grep -q '\[cas\] cstub=.* MISS ' "$TMP_DIR/win_msvc_cstub_2.trace"; then
  echo "FAIL: WIN_CSTUB_PAR MSVC warm build expected 5 HIT and 0 MISS (got hits=$MSVC_HITS_2)" >&2
  exit 1
fi
MSVC_HITS_T="$(grep -c '\[cas\] cstub=.* HIT ' "$TMP_DIR/win_msvc_cstub_test.trace" || true)"
if [ "$MSVC_HITS_T" != "5" ] || grep -q '\[cas\] cstub=.* MISS ' "$TMP_DIR/win_msvc_cstub_test.trace"; then
  echo "FAIL: WIN_CSTUB_PAR MSVC warm test expected 5 HIT and 0 MISS (got hits=$MSVC_HITS_T)" >&2
  exit 1
fi
grep -q '\[cas\] bin=msvc_app MISS' "$TMP_DIR/win_msvc_cstub_1.trace" || { echo "FAIL: WIN_CSTUB_PAR MSVC cold build missing '[cas] bin=msvc_app MISS'" >&2; exit 1; }
grep -q '\[cas\] bin=msvc_app HIT' "$TMP_DIR/win_msvc_cstub_2.trace" || { echo "FAIL: WIN_CSTUB_PAR MSVC warm build missing '[cas] bin=msvc_app HIT'" >&2; exit 1; }
if grep -q '\[cas\] bin=msvc_app HIT' "$TMP_DIR/win_msvc_cstub_3.trace" || grep -q '\[cas\] bin=msvc_app MISS' "$TMP_DIR/win_msvc_cstub_3.trace"; then
  echo "FAIL: WIN_CSTUB_PAR MSVC custom LIB must bypass nativebin CAS!" >&2
  exit 1
fi
if grep -q '\[cas\] bin=msvc_app HIT' "$TMP_DIR/win_msvc_cstub_4.trace" || grep -q '\[cas\] bin=msvc_app MISS' "$TMP_DIR/win_msvc_cstub_4.trace"; then
  echo "FAIL: WIN_CSTUB_PAR MSVC _LINK_ env must bypass nativebin CAS!" >&2
  exit 1
fi
grep -q '\[cas\] bin=msvc_app MISS' "$TMP_DIR/win_msvc_cstub_5.trace" || { echo "FAIL: WIN_CSTUB_PAR MSVC switched whitelisted LIB must MISS nativebin CAS!" >&2; exit 1; }
MSVC_BINS_ALL="$(find "$MSVC_CS_CAS/bin" -maxdepth 1 -name 'msvc_app_*.exe' | wc -l | tr -d ' ')"
if [ "$MSVC_BINS_ALL" != "2" ]; then
  echo "FAIL: WIN_CSTUB_PAR MSVC expected 2 msvc_app_*.exe in CAS bin/ (orig LIB + switched LIB), got $MSVC_BINS_ALL" >&2
  exit 1
fi
echo "[PASS] Windows parallel cstub + nativebin CAS (LLVM clang/clang++ MSVC: cold MISS -> warm HIT -> warm test HIT + custom LIB/_LINK_ fail-closed + winlib switch MISS)"
MSVCEOF
bg_start "$TMP_DIR/msvc_cstub.log" sh -eu "$TMP_DIR/run_msvc_cstub_job.sh" "$TMP_DIR" "$ROOT_DIR" "$PIONC" "$PION_QBE"
MSVC_CSTUB_PID="$BG_PID"

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

# Lightweight Windows cstub CAS (cold -> warm HIT with 0 obj/ bloat -> header edit MISS) + extern "C" fn value smoke (< 3s)
WIN_CSTUB_WS="$TMP_DIR/win_cstub_ws"
WIN_CSTUB_CAS="$TMP_DIR/cas_win_cstub"
mkdir -p "$WIN_CSTUB_WS/pkg/src" "$WIN_CSTUB_WS/pkg/csrc" "$WIN_CSTUB_CAS"
cat <<'EOF' > "$WIN_CSTUB_WS/pkg/csrc/win_hdr.h"
#define WIN_CSTUB_BASE 100
EOF
cat <<'EOF' > "$WIN_CSTUB_WS/pkg/csrc/win_stub.c"
#include <stdint.h>
#include "win_hdr.h"
static int32_t g_win_acc = 0;
int32_t win_cstub_base(void) { return WIN_CSTUB_BASE; }
int32_t win_add_i32(int32_t a, int32_t b) { return a + b; }
void win_bump_void(int32_t d) { g_win_acc += d; }
int32_t win_get_acc(void) { return g_win_acc; }
double win_half_f64(double x) { return x * 0.5; }
EOF
cat <<'EOF' > "$WIN_CSTUB_WS/pkg/pion.toml"
[package]
name = "win_cstub_pkg"
version = "0.1.0"

[link]
c_sources = ["csrc/win_stub.c"]
EOF
cat <<'EOF' > "$WIN_CSTUB_WS/pkg/src/main.pion"
extern "C" fn win_cstub_base() -> Int = "win_cstub_base"
extern "C" fn win_add_i32(a : Int, b : Int) -> Int = "win_add_i32"
extern "C" fn win_bump_void(d : Int) -> Unit = "win_bump_void"
extern "C" fn win_get_acc() -> Int = "win_get_acc"
extern "C" fn win_half_f64(x : Double) -> Double = "win_half_f64"

fn apply2(f : (Int, Int) -> Int, a : Int, b : Int) -> Int { f(a, b) }
fn apply_v(f : (Int) -> Unit, d : Int) -> Unit { f(d) }

pub fn main(w : World) -> Int {
  let f_add : (Int, Int) -> Int = win_add_i32
  let f_half : (Double) -> Double = win_half_f64
  apply_v(win_bump_void, 7)
  let sum = apply2(f_add, win_cstub_base(), win_get_acc())
  let h = f_half(10.0)
  io_println(w, "win_cstub=" + sum.to_string() + ",half=" + h.to_int().to_string())
  0
}
EOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$WIN_CSTUB_CAS" "$PIONC" build -o "$TMP_DIR/win_cstub_1.exe" "$WIN_CSTUB_WS/pkg" 2>"$TMP_DIR/win_cstub_1.trace"
WIN_CSTUB_OUT1="$("$TMP_DIR/win_cstub_1.exe" | tr -d '\r')"
[ "$WIN_CSTUB_OUT1" = "win_cstub=107,half=5" ] || { echo "FAIL: Windows cstub cold output mismatch: '$WIN_CSTUB_OUT1'" >&2; exit 1; }
if grep -q "(local:" "$TMP_DIR/win_cstub_1.trace"; then
  echo "FAIL: Windows cstub cold build fell back to local:" >&2
  cat "$TMP_DIR/win_cstub_1.trace" >&2
  exit 1
fi
WIN_CSTUB_OBJS_1="$(find "$WIN_CSTUB_CAS/obj" -maxdepth 1 -name 'cstub_*.o' | wc -l | tr -d ' ')"
[ "$WIN_CSTUB_OBJS_1" = "1" ] || { echo "FAIL: Windows cstub cold expected 1 cstub_*.o, got $WIN_CSTUB_OBJS_1" >&2; exit 1; }

PION_CAS_TRACE=1 PION_CACHE_DIR="$WIN_CSTUB_CAS" "$PIONC" build -o "$TMP_DIR/win_cstub_2.exe" "$WIN_CSTUB_WS/pkg" 2>"$TMP_DIR/win_cstub_2.trace"
grep -q "cstub=.*win_stub\.c HIT key=" "$TMP_DIR/win_cstub_2.trace" || { echo "FAIL: Windows cstub warm build did not HIT:" >&2; cat "$TMP_DIR/win_cstub_2.trace" >&2; exit 1; }
WIN_CSTUB_OBJS_2="$(find "$WIN_CSTUB_CAS/obj" -maxdepth 1 -name 'cstub_*.o' | wc -l | tr -d ' ')"
[ "$WIN_CSTUB_OBJS_2" = "1" ] || { echo "FAIL: Windows cstub warm build bloated obj/ ($WIN_CSTUB_OBJS_1 -> $WIN_CSTUB_OBJS_2)" >&2; exit 1; }

cat <<'EOF' > "$WIN_CSTUB_WS/pkg/csrc/win_hdr.h"
#define WIN_CSTUB_BASE 200
EOF
PION_CAS_TRACE=1 PION_CACHE_DIR="$WIN_CSTUB_CAS" "$PIONC" build -o "$TMP_DIR/win_cstub_3.exe" "$WIN_CSTUB_WS/pkg" 2>"$TMP_DIR/win_cstub_3.trace"
grep -q "cstub=.*win_stub\.c MISS key=" "$TMP_DIR/win_cstub_3.trace" || { echo "FAIL: Windows cstub header-edit build did not MISS:" >&2; cat "$TMP_DIR/win_cstub_3.trace" >&2; exit 1; }
WIN_CSTUB_OUT3="$("$TMP_DIR/win_cstub_3.exe" | tr -d '\r')"
[ "$WIN_CSTUB_OUT3" = "win_cstub=207,half=5" ] || { echo "FAIL: Windows cstub header-edit output mismatch: '$WIN_CSTUB_OUT3'" >&2; exit 1; }
echo "[PASS] Windows cstub CAS (cold -> warm HIT -> header edit MISS) + extern \"C\" fn value smoke"

# Multi-file parallel (--jobs 2) Windows cstub CAS E2E (< 15s):
#   1) MSYS2 gcc/g++: par_lib (2 .c + 2 .cpp + par_hdr.h) + par_app (1 .c + test)
#   2) LLVM clang.exe/clang++.exe + VS2022 MSVC (when installed, e.g. GitHub Actions windows-latest)
WIN_CSTUB_PAR_WS="$TMP_DIR/win_cstub_par_ws"
WIN_CSTUB_PAR_CAS="$TMP_DIR/cas_win_cstub_par"
mkdir -p "$WIN_CSTUB_PAR_WS/par_lib/src" "$WIN_CSTUB_PAR_WS/par_lib/csrc" \
         "$WIN_CSTUB_PAR_WS/par_app/src" "$WIN_CSTUB_PAR_WS/par_app/csrc" \
         "$WIN_CSTUB_PAR_CAS"
cat <<'EOF' > "$WIN_CSTUB_PAR_WS/par_lib/csrc/par_hdr.h"
#define PAR_BASE 100
EOF
cat <<'EOF' > "$WIN_CSTUB_PAR_WS/par_lib/csrc/c1.c"
#include <stdint.h>
#include "par_hdr.h"
int32_t par_c1(void) { return PAR_BASE + 1; }
EOF
cat <<'EOF' > "$WIN_CSTUB_PAR_WS/par_lib/csrc/c2.c"
#include <stdint.h>
#include "par_hdr.h"
int32_t par_c2(void) { return PAR_BASE + 2; }
EOF
cat <<'EOF' > "$WIN_CSTUB_PAR_WS/par_lib/csrc/p1.cpp"
#include <cstdint>
#include "par_hdr.h"
extern "C" int32_t par_p1(void) { return PAR_BASE + 3; }
EOF
cat <<'EOF' > "$WIN_CSTUB_PAR_WS/par_lib/csrc/p2.cpp"
#include <cstdint>
#include "par_hdr.h"
extern "C" int32_t par_p2(void) { return PAR_BASE + 4; }
EOF
cat <<'EOF' > "$WIN_CSTUB_PAR_WS/par_lib/pion.toml"
[package]
name = "par_lib"
version = "0.1.0"

[link]
c_sources = ["csrc/c1.c", "csrc/c2.c", "csrc/p1.cpp", "csrc/p2.cpp"]
EOF
cat <<'EOF' > "$WIN_CSTUB_PAR_WS/par_lib/src/lib.pion"
extern "C" fn par_c1() -> Int = "par_c1"
extern "C" fn par_c2() -> Int = "par_c2"
extern "C" fn par_p1() -> Int = "par_p1"
extern "C" fn par_p2() -> Int = "par_p2"

pub fn lib_sum() -> Int {
  par_c1() + par_c2() + par_p1() + par_p2()
}
EOF
cat <<'EOF' > "$WIN_CSTUB_PAR_WS/par_app/csrc/app_c.c"
#include <stdint.h>
int32_t par_app_c(void) { return 12; }
EOF
cat <<'EOF' > "$WIN_CSTUB_PAR_WS/par_app/pion.toml"
[package]
name = "par_app"
version = "0.1.0"

[dependencies]
par_lib = { path = "../par_lib" }

[link]
c_sources = ["csrc/app_c.c"]
EOF
cat <<'EOF' > "$WIN_CSTUB_PAR_WS/par_app/src/main.pion"
import "par_lib"

extern "C" fn par_app_c() -> Int = "par_app_c"

pub fn par_total() -> Int {
  par_lib::lib_sum() + par_app_c()
}

pub fn main(w : World) -> Int {
  io_println(w, "par_cstub=" + par_total().to_string())
  0
}
EOF
cat <<'EOF' > "$WIN_CSTUB_PAR_WS/par_app/src/app_test.pion"
test "par_cstub_ok" {
  debug_assert(par_total() == 422, "par_cstub_ok")
}
EOF

PION_CAS_TRACE=1 PION_CACHE_DIR="$WIN_CSTUB_PAR_CAS" "$PIONC" build --jobs 2 -o "$TMP_DIR/win_cstub_par_1.exe" "$WIN_CSTUB_PAR_WS/par_app" 2>"$TMP_DIR/win_cstub_par_1.trace"
WIN_PAR_CS_OUT1="$("$TMP_DIR/win_cstub_par_1.exe" | tr -d '\r')"
[ "$WIN_PAR_CS_OUT1" = "par_cstub=422" ] || { echo "FAIL: WIN_CSTUB_PAR cold output mismatch: '$WIN_PAR_CS_OUT1'" >&2; cat "$TMP_DIR/win_cstub_par_1.trace" >&2; exit 1; }
if grep -q "(local:" "$TMP_DIR/win_cstub_par_1.trace"; then
  echo "FAIL: WIN_CSTUB_PAR cold build fell back to local:" >&2
  cat "$TMP_DIR/win_cstub_par_1.trace" >&2
  exit 1
fi
WIN_PAR_CS_OBJS_1="$(find "$WIN_CSTUB_PAR_CAS/obj" -maxdepth 1 -name 'cstub_*.o' | wc -l | tr -d ' ')"
if [ "$WIN_PAR_CS_OBJS_1" != "5" ]; then
  echo "FAIL: WIN_CSTUB_PAR cold expected 5 cstub_*.o, got $WIN_PAR_CS_OBJS_1" >&2
  cat "$TMP_DIR/win_cstub_par_1.trace" >&2
  exit 1
fi

PION_CAS_TRACE=1 PION_CACHE_DIR="$WIN_CSTUB_PAR_CAS" "$PIONC" build --jobs 2 -o "$TMP_DIR/win_cstub_par_2.exe" "$WIN_CSTUB_PAR_WS/par_app" 2>"$TMP_DIR/win_cstub_par_2.trace"
WIN_PAR_CS_HITS_2="$(grep -c '\[cas\] cstub=.* HIT ' "$TMP_DIR/win_cstub_par_2.trace" || true)"
if [ "$WIN_PAR_CS_HITS_2" != "5" ] || grep -q '\[cas\] cstub=.* MISS ' "$TMP_DIR/win_cstub_par_2.trace" || grep -q "(local:" "$TMP_DIR/win_cstub_par_2.trace"; then
  echo "FAIL: WIN_CSTUB_PAR warm build expected 5 HIT and 0 MISS/local (got hits=$WIN_PAR_CS_HITS_2):" >&2
  cat "$TMP_DIR/win_cstub_par_2.trace" >&2
  exit 1
fi
WIN_PAR_CS_OBJS_2="$(find "$WIN_CSTUB_PAR_CAS/obj" -maxdepth 1 -name 'cstub_*.o' | wc -l | tr -d ' ')"
if [ "$WIN_PAR_CS_OBJS_2" != "5" ]; then
  echo "FAIL: WIN_CSTUB_PAR warm build bloated obj/ ($WIN_PAR_CS_OBJS_1 -> $WIN_PAR_CS_OBJS_2)" >&2
  cat "$TMP_DIR/win_cstub_par_2.trace" >&2
  exit 1
fi

PION_CAS_TRACE=1 PION_CACHE_DIR="$WIN_CSTUB_PAR_CAS" "$PIONC" test --jobs 2 "$WIN_CSTUB_PAR_WS/par_app" > "$TMP_DIR/win_cstub_par_test.out" 2>"$TMP_DIR/win_cstub_par_test.trace"
WIN_PAR_CS_HITS_T="$(grep -c '\[cas\] cstub=.* HIT ' "$TMP_DIR/win_cstub_par_test.trace" || true)"
if [ "$WIN_PAR_CS_HITS_T" != "5" ] || grep -q '\[cas\] cstub=.* MISS ' "$TMP_DIR/win_cstub_par_test.trace" || grep -q "(local:" "$TMP_DIR/win_cstub_par_test.trace"; then
  echo "FAIL: WIN_CSTUB_PAR warm test expected 5 HIT and 0 MISS/local (got hits=$WIN_PAR_CS_HITS_T):" >&2
  cat "$TMP_DIR/win_cstub_par_test.trace" >&2
  exit 1
fi
echo "[PASS] Windows parallel cstub CAS (MSYS2 --jobs 2: 2 .c + 2 .cpp + app .c, cold -> warm build HIT -> warm test HIT)"

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
if [ -n "$MSVC_CSTUB_PID" ]; then
  bg_finish "WIN_CSTUB_PAR MSVC" "$MSVC_CSTUB_PID" "$TMP_DIR/msvc_cstub.log"
  MSVC_CSTUB_PID=""
fi

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
