#!/bin/sh
# Run independent E2E commands concurrently, one `sh -c` per stdin line.
#
#   sh scripts/run-e2e-parallel.sh [-j N] <<'EOF'
#   sh "$ROOT_DIR/tests/e2e/p30a_bugs9_to_13/run_e2e.sh" "$PIONC"
#   PATH="$ORIG_PATH" sh "$ROOT_DIR/tests/e2e/p31a_ergonomics/run_e2e.sh" "$PIONC"
#   EOF
#
# Each line runs in its own `sh -c` (so `$VAR` expands there: export what the
# lines use) and its own process group, with stdout+stderr captured to a
# private file. A finished command prints `[PASS] <name> (<s>s)` plus the
# `[SUMMARY] ...` lines of its log; a failed one
# prints `[FAIL] <name> (exit <rc>, <s>s)` followed by its full log. Every line
# runs even after a failure; the exit status is 1 if any failed. Blank lines and
# `#` comments are skipped. Put the slowest commands first (better packing).
#
# Jobs: -j N, else $PION_E2E_JOBS, else min(usable CPUs, 8).
# PION_E2E_VERBOSE=1 also prints the log of passing commands.
#
# Only put commands here that are independent of each other: each must work in
# its own mktemp -d / CAS, write nothing shared in the source tree or out/, and
# use ephemeral ports. Anything else stays serial in the calling script.
set -eu

JOBS="${PION_E2E_JOBS:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="$2"; shift 2 ;;
    -j*) JOBS="${1#-j}"; shift ;;
    *) echo "usage: run-e2e-parallel.sh [-j N] < commands" >&2; exit 2 ;;
  esac
done

exec python3 -c '
import os, re, shutil, signal, subprocess, sys, tempfile, threading, time
from concurrent.futures import ThreadPoolExecutor

def usable_cpus():
    try:
        n = len(os.sched_getaffinity(0))
    except AttributeError:
        n = os.cpu_count() or 1
    # cgroup v2 CPU quota (containers / CI runners)
    try:
        q, p = open("/sys/fs/cgroup/cpu.max").read().split()[:2]
        if q != "max":
            n = min(n, max(1, int(q) // int(p)))
    except (OSError, ValueError):
        pass
    return max(1, n)

jobs_arg = sys.argv[1]
jobs = int(jobs_arg) if jobs_arg else min(usable_cpus(), 8)
if jobs < 1:
    sys.exit("run-e2e-parallel: -j must be >= 1")
verbose = os.environ.get("PION_E2E_VERBOSE") == "1"

cmds = [l.strip() for l in sys.stdin.read().splitlines()]
cmds = [c for c in cmds if c and not c.startswith("#")]

def name_of(cmd):
    m = re.search(r"([A-Za-z0-9_.-]+/(?:e2e|tests)/[A-Za-z0-9_.-]+/run_[A-Za-z0-9_]+\.sh|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/run_[A-Za-z0-9_]+\.sh|scripts/[A-Za-z0-9_.-]+\.sh)", cmd)
    return m.group(1) if m else cmd[:80]

procs = set()
proc_lock = threading.Lock()  # guards procs + the stopping check before each Popen
stopping = threading.Event()  # set by SIGINT/SIGTERM: start nothing new
out_lock = threading.Lock()
log_dir = tempfile.mkdtemp(prefix="pion-e2e-par-")

def run(idx_cmd):
    idx, cmd = idx_cmd
    log_path = os.path.join(log_dir, "%03d.log" % idx)
    t0 = time.time()
    with open(log_path, "wb") as log:
        with proc_lock:
            if stopping.is_set():
                return (cmd, 130, 0.0)
            child_env = dict(os.environ)
            child_env["PION_BG_INHERIT_PG"] = "1"
            p = subprocess.Popen(["sh", "-c", cmd], stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=subprocess.STDOUT,
                                 env=child_env,
                                 start_new_session=True)
            procs.add(p)
        rc = p.wait()
        # Reap any straggling descendants (incl. reparented grandchildren) still
        # left in the isolated session after the leader exits.
        if pg_alive(p.pid):
            with out_lock:
                print("[WARN] %s: reaping straggler process(es) in pgid %d" % (name_of(cmd), p.pid), file=sys.stderr, flush=True)
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except OSError:
                pass
            reap_deadline = time.time() + 0.3
            while time.time() < reap_deadline and pg_alive(p.pid):
                time.sleep(0.02)
            if pg_alive(p.pid):
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass
                kill_deadline = time.time() + 0.5
                while time.time() < kill_deadline and pg_alive(p.pid):
                    time.sleep(0.02)
        with proc_lock:
            procs.discard(p)
    if stopping.is_set():
        return (cmd, rc, time.time() - t0)  # interrupted: kill_all reports and exits
    dt = time.time() - t0
    with open(log_path, "rb") as f:
        text = f.read().decode("utf-8", "replace")
    os.unlink(log_path)
    with out_lock:
        if rc == 0:
            print("[PASS] %s (%.1fs)" % (name_of(cmd), dt), flush=True)
            if verbose:
                sys.stdout.write(text)
            else:
                for line in text.splitlines():
                    if line.startswith("[SUMMARY] "):
                        print("  " + line, flush=True)
        else:
            print("[FAIL] %s (exit %d, %.1fs)\n--- command: %s\n--- log:" % (name_of(cmd), rc, dt, cmd), flush=True)
            sys.stdout.write(text)
            print("--- end of %s" % name_of(cmd), flush=True)
    return (cmd, rc, dt)

def pg_alive(pid):
    # Probe the process group, not p.poll(): the worker thread blocked in
    # p.wait() holds the Popen _waitpid_lock, so poll() here would report
    # "running" until the whole grace period has passed.
    try:
        os.killpg(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False

def kill_all(signum, _frame):
    # Never start queued commands, give running ones SIGTERM (their own
    # `trap ... EXIT` cleanups run), SIGKILL what is left after ~0.5 s, and
    # exit at once without waiting for the pool.
    stopping.set()
    with proc_lock:
        running = list(procs)
    for p in running:
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.time() + 0.5
    while time.time() < deadline and any(pg_alive(p.pid) for p in running):
        time.sleep(0.02)
    for p in running:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
    shutil.rmtree(log_dir, ignore_errors=True)
    sys.stdout.flush()
    os._exit(128 + signum)

signal.signal(signal.SIGINT, kill_all)
signal.signal(signal.SIGTERM, kill_all)

t0 = time.time()
print("run-e2e-parallel: %d command(s), -j %d" % (len(cmds), jobs), flush=True)
with ThreadPoolExecutor(max_workers=jobs) as pool:
    results = list(pool.map(run, enumerate(cmds)))
os.rmdir(log_dir)
failed = [r for r in results if r[1] != 0]
print("run-e2e-parallel: %d passed, %d failed, wall %.1fs (serial sum %.1fs)" % (
    len(results) - len(failed), len(failed), time.time() - t0, sum(r[2] for r in results)), flush=True)
for cmd, rc, _ in failed:
    print("FAIL: %s (exit %d)" % (name_of(cmd), rc), file=sys.stderr)
sys.exit(1 if failed else 0)
' "$JOBS"
