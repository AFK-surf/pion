# Sourced by verify-all.sh / test-linux.sh / test-windows.sh / p98: overlapped
# background gate steps (do not source in a shell with `set -m`).
#
#   bg_start <log> <cmd...>   start <cmd> with output in <log>; its pid is $BG_PID
#   bg_kill <pid>...          stop steps that are still running (empty pid: none)
#   bg_join <pid> <log>       wait for a step, print its log, return its status
#
# Top-level callers start each step in its own session (via `setsid`, or
# `python3` `os.setsid()` on macOS) and export PION_BG_INHERIT_PG=1 to the
# child. Nested bg_start calls inside an already-isolated session (e.g. p98
# inside run-e2e-parallel.sh or test-linux.sh) stay in that session so an outer
# process-group cancellation (SIGTERM/SIGKILL to -pgid) reaps every descendant.
# On Windows (MSYS2/Cygwin), each bg_start runs inside a Win32 Job Object with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE (nested jobs are native on Win8+), so both
# normal/failed exit and outer cancellation reap every native descendant even
# after the wrapper exits.
_bg_start_win_job() {
  _bg_wlog="$1"
  shift
  _bg_py='
import ctypes, ctypes.wintypes as w, os, shutil, subprocess, sys, time

if sys.platform != "win32":
    sys.stderr.write("FAIL: bg-lib requires native Win32 Python for Windows Job Object isolation (got %s)\n" % sys.platform)
    sys.exit(97)

class _BASIC(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_longlong),
        ("PerJobUserTimeLimit", ctypes.c_longlong),
        ("LimitFlags", w.DWORD),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", w.DWORD),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", w.DWORD),
        ("SchedulingClass", w.DWORD),
    ]

class _IO(ctypes.Structure):
    _fields_ = [
        ("ReadOperationCount", ctypes.c_ulonglong),
        ("WriteOperationCount", ctypes.c_ulonglong),
        ("OtherOperationCount", ctypes.c_ulonglong),
        ("ReadTransferCount", ctypes.c_ulonglong),
        ("WriteTransferCount", ctypes.c_ulonglong),
        ("OtherTransferCount", ctypes.c_ulonglong),
    ]

class _EXT(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", _BASIC),
        ("IoInfo", _IO),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]

class _ACCT(ctypes.Structure):
    _fields_ = [
        ("TotalUserTime", ctypes.c_longlong),
        ("TotalKernelTime", ctypes.c_longlong),
        ("ThisPeriodTotalUserTime", ctypes.c_longlong),
        ("ThisPeriodTotalKernelTime", ctypes.c_longlong),
        ("TotalPageFaultCount", w.DWORD),
        ("TotalProcesses", w.DWORD),
        ("ActiveProcesses", w.DWORD),
        ("TotalTerminatedProcesses", w.DWORD),
    ]

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.CreateJobObjectW.argtypes = [w.LPVOID, w.LPCWSTR]
k32.CreateJobObjectW.restype = w.HANDLE
k32.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, w.LPVOID, w.DWORD]
k32.SetInformationJobObject.restype = w.BOOL
k32.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
k32.AssignProcessToJobObject.restype = w.BOOL
k32.TerminateJobObject.argtypes = [w.HANDLE, w.UINT]
k32.TerminateJobObject.restype = w.BOOL
k32.QueryInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, w.LPVOID, w.DWORD, ctypes.POINTER(w.DWORD)]
k32.QueryInformationJobObject.restype = w.BOOL
k32.CloseHandle.argtypes = [w.HANDLE]
k32.CloseHandle.restype = w.BOOL

child_env = dict(os.environ)
orig_npc = child_env.pop("_PION_BG_ORIG_NPC", None)
if orig_npc is None:
    child_env.pop("MSYS_NO_PATHCONV", None)
else:
    child_env["MSYS_NO_PATHCONV"] = orig_npc

job = k32.CreateJobObjectW(None, None)
if not job:
    err = ctypes.get_last_error()
    sys.stderr.write("FAIL: bg-lib CreateJobObjectW failed (winerr=%d)\n" % err)
    sys.exit(97)
ext = _EXT()
ext.BasicLimitInformation.LimitFlags = 0x2000
if not k32.SetInformationJobObject(job, 9, ctypes.byref(ext), ctypes.sizeof(ext)):
    err = ctypes.get_last_error()
    k32.CloseHandle(job)
    sys.stderr.write("FAIL: bg-lib SetInformationJobObject failed (winerr=%d)\n" % err)
    sys.exit(97)

child_code = (
    "import shutil, subprocess, sys\n"
    "if sys.stdin.buffer.read(1) != b\"1\":\n"
    "    sys.exit(98)\n"
    "cmd = sys.argv[1:]\n"
    "sh = shutil.which(\"sh\")\n"
    "if sh:\n"
    "    rc = subprocess.call([sh, \"-c\", \"exec \" + chr(34) + \"$@\" + chr(34), \"bg\"] + cmd, stdin=subprocess.DEVNULL)\n"
    "else:\n"
    "    exe = shutil.which(cmd[0]) or cmd[0]\n"
    "    rc = subprocess.call([exe] + cmd[1:], stdin=subprocess.DEVNULL)\n"
    "sys.exit(rc)\n"
)

p = subprocess.Popen(
    [sys.executable, "-c", child_code] + sys.argv[1:],
    stdin=subprocess.PIPE,
    env=child_env,
)
if not k32.AssignProcessToJobObject(job, int(p._handle)):
    err = ctypes.get_last_error()
    try:
        p.stdin.close()
    except OSError:
        pass
    p.kill()
    p.wait()
    k32.CloseHandle(job)
    sys.stderr.write("FAIL: bg-lib AssignProcessToJobObject failed (winerr=%d)\n" % err)
    sys.exit(97)
try:
    p.stdin.write(b"1")
    p.stdin.flush()
    p.stdin.close()
except OSError:
    p.kill()
    p.wait()
    k32.TerminateJobObject(job, 1)
    k32.CloseHandle(job)
    sys.stderr.write("FAIL: bg-lib failed to signal child after job assignment\n")
    sys.exit(97)
rc = p.wait()
acct = _ACCT()
if k32.QueryInformationJobObject(job, 1, ctypes.byref(acct), ctypes.sizeof(acct), None) and acct.ActiveProcesses > 0:
    sys.stderr.write("[WARN] bg-lib: reaping %d straggler Windows job process(es)\n" % acct.ActiveProcesses)
k32.TerminateJobObject(job, 1)
deadline = time.time() + 2.0
while time.time() < deadline:
    if not k32.QueryInformationJobObject(job, 1, ctypes.byref(acct), ctypes.sizeof(acct), None):
        break
    if acct.ActiveProcesses == 0:
        break
    time.sleep(0.02)
k32.CloseHandle(job)
sys.exit(rc)
'
  if [ "${MSYS_NO_PATHCONV+x}" = "x" ]; then
    _PION_BG_ORIG_NPC="$MSYS_NO_PATHCONV" MSYS_NO_PATHCONV=1 python3 -c "$_bg_py" "$@" > "$_bg_wlog" 2>&1 &
  else
    MSYS_NO_PATHCONV=1 python3 -c "$_bg_py" "$@" > "$_bg_wlog" 2>&1 &
  fi
  BG_PID=$!
}

bg_start() {
  BG_LOG="$1"
  shift
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*)
      if command -v python3 >/dev/null 2>&1; then
        _bg_start_win_job "$BG_LOG" "$@"
        return 0
      fi
      ( echo "FAIL: bg-lib requires python3 on Windows for Job Object isolation" >&2; exit 97 ) > "$BG_LOG" 2>&1 &
      BG_PID=$!
      return 0
      ;;
  esac
  if [ "${PION_BG_INHERIT_PG:-0}" = "1" ]; then
    "$@" > "$BG_LOG" 2>&1 &
  elif command -v setsid >/dev/null 2>&1; then
    setsid env PION_BG_INHERIT_PG=1 "$@" > "$BG_LOG" 2>&1 &
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; os.setsid(); os.environ["PION_BG_INHERIT_PG"] = "1"; os.execvp(sys.argv[1], sys.argv[1:])' "$@" > "$BG_LOG" 2>&1 &
  else
    env PION_BG_INHERIT_PG=1 "$@" > "$BG_LOG" 2>&1 &
  fi
  BG_PID=$!
}

_bg_descendants() {
  # Print all PIDs in the subtrees rooted at "$@" (roots included), exact PPID walk.
  # On POSIX where `ps -eo pid=,ppid=` is unavailable, still prints the roots.
  _ps_out="$(ps -eo pid=,ppid= 2>/dev/null || true)"
  if [ -z "$_ps_out" ]; then
    for _r in "$@"; do
      [ -n "$_r" ] && printf '%s\n' "$_r"
    done
    return 0
  fi
  printf '%s\n' "$_ps_out" | awk -v roots="$*" '
    BEGIN {
      n = split(roots, r, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (r[i] != "") want[r[i]] = 1
    }
    { pid[NR] = $1; ppid[NR] = $2 }
    END {
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= NR; i++) {
          if ((ppid[i] in want) && !(pid[i] in want)) {
            want[pid[i]] = 1
            changed = 1
          }
        }
      }
      for (p in want) print p
    }
  '
}

_bg_kill_win_trees() {
  # MSYS2/Cygwin: `ps -eo` is unsupported; kill each root's entire Win32 process
  # tree via `/proc/<pid>/winpid` + `taskkill /F /T /PID`, plus POSIX fallback.
  for _p in "$@"; do
    if [ -r "/proc/$_p/winpid" ]; then
      _wpid="$(tr -d '\r\n ' < "/proc/$_p/winpid" 2>/dev/null || true)"
      if [ -n "$_wpid" ]; then
        MSYS_NO_PATHCONV=1 taskkill /F /T /PID "$_wpid" >/dev/null 2>&1 || true
      fi
    fi
    kill -KILL "$_p" 2>/dev/null || true
  done
}

bg_kill() {
  _bg_roots=""
  for BG_P in "$@"; do
    [ -n "$BG_P" ] || continue
    _bg_roots="${_bg_roots:+$_bg_roots }$BG_P"
  done
  [ -n "$_bg_roots" ] || return 0

  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*)
      _bg_kill_win_trees $_bg_roots
      for BG_P in $_bg_roots; do
        wait "$BG_P" 2>/dev/null || true
      done
      return 0
      ;;
  esac

  if [ "${PION_BG_INHERIT_PG:-0}" = "1" ]; then
    # Running inside an outer-owned process group: signal all roots and their
    # exact descendant subtrees in parallel (never killpg our shared outer group).
    # Any already-reparented grandchild in the outer session is reaped by the
    # outer supervisor (run-e2e-parallel.sh or top-level bg_join/bg_kill).
    _bg_seen="$(_bg_descendants $_bg_roots)"
    for _p in $_bg_seen; do
      kill -TERM "$_p" 2>/dev/null || true
    done
    _bg_i=0
    while [ "$_bg_i" -lt 6 ]; do
      _bg_alive=0
      for _p in $_bg_seen; do
        if kill -0 "$_p" 2>/dev/null; then
          _bg_alive=1
          break
        fi
      done
      [ "$_bg_alive" -eq 0 ] && break
      sleep 0.05 2>/dev/null || sleep 1
      _bg_i=$((_bg_i + 1))
    done
    _bg_now="$(_bg_descendants $_bg_roots)"
    for _p in $_bg_seen $_bg_now; do
      kill -KILL "$_p" 2>/dev/null || true
    done
    for BG_P in $_bg_roots; do
      wait "$BG_P" 2>/dev/null || true
    done
    _bg_i=0
    while [ "$_bg_i" -lt 10 ]; do
      _bg_alive=0
      for _p in $_bg_seen $_bg_now; do
        if kill -0 "$_p" 2>/dev/null; then
          _bg_alive=1
          break
        fi
      done
      [ "$_bg_alive" -eq 0 ] && break
      sleep 0.05 2>/dev/null || sleep 1
      _bg_i=$((_bg_i + 1))
    done
    return 0
  fi

  # Top-level session owner: TERM all process groups in parallel first, then one
  # shared ~0.3s grace window, then parallel SIGKILL + wait + bounded confirm.
  for BG_P in $_bg_roots; do
    kill -TERM -"$BG_P" 2>/dev/null || kill -TERM "$BG_P" 2>/dev/null || true
  done
  _bg_i=0
  while [ "$_bg_i" -lt 6 ]; do
    _bg_alive=0
    for BG_P in $_bg_roots; do
      if kill -0 -"$BG_P" 2>/dev/null || kill -0 "$BG_P" 2>/dev/null; then
        _bg_alive=1
        break
      fi
    done
    [ "$_bg_alive" -eq 0 ] && break
    sleep 0.05 2>/dev/null || sleep 1
    _bg_i=$((_bg_i + 1))
  done
  for BG_P in $_bg_roots; do
    if kill -0 -"$BG_P" 2>/dev/null || kill -0 "$BG_P" 2>/dev/null; then
      kill -KILL -"$BG_P" 2>/dev/null || kill -KILL "$BG_P" 2>/dev/null || true
    fi
  done
  for BG_P in $_bg_roots; do
    wait "$BG_P" 2>/dev/null || true
  done
  _bg_i=0
  while [ "$_bg_i" -lt 10 ]; do
    _bg_alive=0
    for BG_P in $_bg_roots; do
      if kill -0 -"$BG_P" 2>/dev/null; then
        _bg_alive=1
        break
      fi
    done
    [ "$_bg_alive" -eq 0 ] && break
    sleep 0.05 2>/dev/null || sleep 1
    _bg_i=$((_bg_i + 1))
  done
}

bg_join() {
  BG_RC=0
  wait "$1" || BG_RC=$?
  # Reap any reparented stragglers still alive in this isolated session before
  # returning (0-ms no-op on the normal path when the group is already empty).
  if [ "${PION_BG_INHERIT_PG:-0}" != "1" ]; then
    case "$(uname -s 2>/dev/null || true)" in
      MINGW*|MSYS*|CYGWIN*) ;;
      *)
        if kill -0 -"$1" 2>/dev/null; then
          echo "[WARN] bg_join: reaping straggler process(es) in pgid $1" >&2
          bg_kill "$1"
        fi
        ;;
    esac
  fi
  cat "$2"
  return "$BG_RC"
}
