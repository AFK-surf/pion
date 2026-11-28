#!/bin/sh
# P97 end-to-end regression suite: output staging directories
# (`<dir>/.pion_ld.<pid>.<seq>`, `drv_make_out_stage`) under concurrency.
#   1) Leftovers named like this process's own staging directories (a crashed
#      earlier process with the same pid: directories with content and a plain
#      file) are skipped, never touched or removed, and `pionc build -o` /
#      `pionc test` still publish. The leftovers are created by the shell that
#      then `exec`s pionc, so they carry pionc's own pid.
#   2) An 8-package workspace under `pionc test --jobs 4` (cold CAS, several
#      rounds) passes every round, leaves no `.pion_ld.*` behind, and every
#      link of one process used a distinct staging directory: `seq` comes from
#      a process-wide counter, so a name is never reused by another thread
#      after its owner removed it (the old per-call `0..4096` scan reused
#      `.pion_ld.<pid>.0`, and one thread's "is it gone" check could see the
#      next thread's fresh directory: `failed to remove staging directory`).
#      A wrapper `CC` logs the staging directory of every link step.
#   3) A non-EEXIST failure (read-only output directory, a file as the output
#      directory) fails at once with the path it tried, never after scanning
#      4096 names.
#   4) Interleaving inside one `pionc test --jobs 4`: package A's link is
#      paused (FIFO) inside its staging directory (with a sentinel file) while
#      package B's link fails in a sibling staging directory of the same
#      parent; B's directory is removed while A's (and the sentinel) stay
#      intact, then A is released and publishes a runnable binary. The command
#      fails reporting the link error, no `.pion_ld.*` is left, and a second
#      run of A alone is a CAS hit on that very binary and passes.
# Case 4 is driven by a small python3 coordinator (FIFOs + `select` against
# one deadline, the run in its own process group that is always killed and
# checked gone); it also checks its own failure paths (pionc exiting early,
# a failed assertion while A is paused). No `sleep` is used to order events
# (only a 10 ms backoff while polling for B's directory removal).
# Usage: sh tests/e2e/p97_stage_dir_race/run_e2e.sh <pionc>
set -eu

PIONC=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
REAL_CC="${CC:-cc}"

W=$(mktemp -d)
trap 'chmod -R u+w "$W" 2>/dev/null || true; rm -rf "$W"' EXIT
fail() {
  echo "FAIL (p97_stage_dir_race): $*" >&2
  exit 1
}
expect() {
  printf '%s' "$1" | grep -q -- "$2" || fail "$3: expected '$2' in '$1'"
}
# Every `.pion_ld.*` under $1 except the planted leftovers (owner file "planted").
stray_stages() {
  find "$1" -name '.pion_ld.*' 2>/dev/null | while IFS= read -r p; do
    if [ -f "$p/owner" ] && [ "$(cat "$p/owner")" = "planted" ]; then continue; fi
    if [ -f "$p" ] && [ "$(cat "$p")" = "planted-file" ]; then continue; fi
    echo "$p"
  done
}

cat > "$W/fakecc" <<'EOF'
#!/bin/sh
# Link steps (an `-o`, no -c/-S/-E) append the output's directory to
# $FAKE_LD_LOG (one short O_APPEND line per link), then run the real compiler.
# With $P97_IL set (case 4), the link carrying `-L.../p97_role_a` writes a
# sentinel into its staging directory, reports on $P97_IL/a_ready and waits
# for `go` on $P97_IL/a_go; the one carrying `-L.../p97_role_b` writes a
# partial output and a side file, reports on $P97_IL/b_ready, waits on
# $P97_IL/b_go and only then fails.
out=""; link=1; prev=""; role=""
for a in "$@"; do
  case "$a" in
    -c|-S|-E) link=0 ;;
    -L*/p97_role_a) role=a ;;
    -L*/p97_role_b) role=b ;;
  esac
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
if [ "$link" = 1 ] && [ -n "$out" ] && [ -n "${FAKE_LD_LOG:-}" ]; then
  echo "$(dirname "$out")" >> "$FAKE_LD_LOG"
fi
if [ "$link" = 1 ] && [ -n "$out" ] && [ -n "${P97_IL:-}" ]; then
  stage=$(dirname "$out")
  case "$role" in
    a)
      echo a > "$stage/.sentinel_a"
      echo "$out" > "$P97_IL/a.out"
      echo $$ > "$P97_IL/a.pid"
      echo ready > "$P97_IL/a_ready"
      read go < "$P97_IL/a_go"
      [ "$go" = go ] || exit 3
      ;;
    b)
      printf partial > "$out"
      echo b > "$stage/.side_b"
      echo "$out" > "$P97_IL/b.out"
      echo $$ > "$P97_IL/b.pid"
      echo ready > "$P97_IL/b_ready"
      read go < "$P97_IL/b_go"
      [ "$go" = fail ] || exit 3
      exit 1
      ;;
  esac
fi
exec "$FAKE_REAL_CC" "$@"
EOF
chmod +x "$W/fakecc"
export FAKE_REAL_CC="$REAL_CC"

# --- 8-package workspace (alpha <- beta, gamma, ...) ---------------------------
WS="$W/ws"
mkdir -p "$WS"
cat > "$WS/pion.toml" <<'EOF'
[workspace]
members = ["pkgs/*"]
EOF
NPKG=8
i=0
for name in p0 p1 p2 p3 p4 p5 p6 p7; do
  mkdir -p "$WS/pkgs/$name/src"
  if [ "$name" = "p0" ]; then
    cat > "$WS/pkgs/p0/pion.toml" <<'EOF'
[package]
name = "p0"
version = "0.1.0"

[link]
search_paths = ["."]
EOF
    cat > "$WS/pkgs/p0/src/lib.pion" <<'EOF'
pub fn base() -> Int { 7 }
EOF
  else
    cat > "$WS/pkgs/$name/pion.toml" <<EOF
[package]
name = "$name"
version = "0.1.0"

[dependencies]
p0 = { path = "../p0" }

[link]
search_paths = ["."]
EOF
    cat > "$WS/pkgs/$name/src/lib.pion" <<EOF
import "p0"
pub fn pval() -> Int { p0::base() * $i }
EOF
  fi
  if [ "$name" = "p0" ]; then
    cat > "$WS/pkgs/p0/src/p0_test.pion" <<'EOF'
test "p0_base" {
  debug_assert(base() == 7, "p0_base")
}
EOF
  else
    cat > "$WS/pkgs/$name/src/${name}_test.pion" <<EOF
test "${name}_val" {
  debug_assert(pval() == 7 * $i, "${name}_val")
}
EOF
  fi
  i=$((i + 1))
done

# Runs "$@" (a pionc command) from a shell that first plants leftovers named
# after its own pid in $1 (`.pion_ld.<pid>.0..63` directories holding a file,
# `.pion_ld.<pid>.64` a regular file) and then `exec`s the command, which keeps
# the pid. Prints the pid.
with_leftovers() {
  sh -c '
    d=$1; shift
    mkdir -p "$d"
    k=0
    while [ $k -lt 64 ]; do
      mkdir "$d/.pion_ld.$$.$k"
      echo planted > "$d/.pion_ld.$$.$k/owner"
      k=$((k + 1))
    done
    echo planted-file > "$d/.pion_ld.$$.64"
    echo $$ > "$d/../planted.pid"
    exec "$@" > "$d/../cmd.out" 2>&1
  ' sh "$@"
}
check_leftovers() {
  d=$1; pid=$2
  k=0
  while [ $k -lt 64 ]; do
    [ "$(cat "$d/.pion_ld.$pid.$k/owner" 2>/dev/null)" = planted ] || fail "$3: leftover $d/.pion_ld.$pid.$k was touched"
    [ "$(ls -A "$d/.pion_ld.$pid.$k")" = owner ] || fail "$3: leftover $d/.pion_ld.$pid.$k gained entries"
    k=$((k + 1))
  done
  [ -f "$d/.pion_ld.$pid.64" ] && [ "$(cat "$d/.pion_ld.$pid.64")" = planted-file ] || fail "$3: leftover file .pion_ld.$pid.64 was touched"
  left=$(stray_stages "$d")
  [ -z "$left" ] || fail "$3: staging directories left behind: $left"
}

# --- 1) Leftovers with pionc's own pid are skipped and kept -------------------
mkdir -p "$W/app"
cat > "$W/app/main.pion" <<'EOF'
pub fn main(world : World) -> Int {
  io_println(world, "p97 ok")
  0
}
EOF
OUT1="$W/o1/bin"
PION_CACHE_DIR="$W/cas_o" with_leftovers "$OUT1" "$PIONC" build -o "$OUT1/app" "$W/app/main.pion" \
  || { cat "$W/o1/cmd.out"; fail "build -o next to leftovers"; }
[ "$("$OUT1/app")" = "p97 ok" ] || fail "build -o next to leftovers: wrong output"
check_leftovers "$OUT1" "$(cat "$W/o1/planted.pid")" "build -o"
echo "p97 build -o skips 65 same-pid leftovers and keeps them: OK"

CAS1="$W/cas_t1"
PION_CACHE_DIR="$CAS1" with_leftovers "$CAS1/testbin" "$PIONC" test --jobs 4 --json "$WS" \
  || { cat "$CAS1/cmd.out"; fail "test --jobs 4 next to leftovers"; }
T1=$(cat "$CAS1/cmd.out")
echo "p97 test with leftovers -> $T1"
expect "$T1" '"failed":0' "test --jobs 4 next to leftovers"
expect "$T1" "\"passed\":$NPKG" "test --jobs 4 next to leftovers"
check_leftovers "$CAS1/testbin" "$(cat "$CAS1/planted.pid")" "test --jobs 4"
echo "p97 test --jobs 4 skips 65 same-pid leftovers in testbin/ and keeps them: OK"

# --- 2) test --jobs 4, cold CAS, several rounds --------------------------------
ROUNDS=6
r=0
while [ $r -lt $ROUNDS ]; do
  CAS="$W/cas_r$r"
  LOG="$W/ld_r$r.log"
  : > "$LOG"
  if ! OUT=$(FAKE_LD_LOG="$LOG" CC="$W/fakecc" PION_CACHE_DIR="$CAS" "$PIONC" test --jobs 4 --json "$WS" 2>&1); then
    fail "round $r: pionc test --jobs 4 failed: $OUT"
  fi
  expect "$OUT" '"failed":0' "round $r"
  expect "$OUT" "\"passed\":$NPKG" "round $r"
  left=$(find "$CAS" "$WS" -name '.pion_ld.*' 2>/dev/null || true)
  [ -z "$left" ] || fail "round $r: staging directories left behind: $left"
  links=$(grep -c '/\.pion_ld\.' "$LOG" || true)
  [ "$links" -ge "$NPKG" ] || fail "round $r: expected >= $NPKG staged links, logged $links: $(cat "$LOG")"
  dups=$(grep '/\.pion_ld\.' "$LOG" | sort | uniq -d)
  [ -z "$dups" ] || fail "round $r: a staging directory name was used twice in one process: $dups"
  r=$((r + 1))
done
echo "p97 8-package test --jobs 4 x $ROUNDS cold rounds: all pass, distinct staging names, no leftovers: OK"

# --- 3) A real error fails at once -----------------------------------------------
mkdir -p "$W/ro"
chmod 0555 "$W/ro"
if [ "$(id -u)" != 0 ]; then
  if PION_CACHE_DIR="$W/cas_o" "$PIONC" build -o "$W/ro/app" "$W/app/main.pion" > "$W/ro.out" 2>&1; then
    fail "build -o into a read-only directory succeeded"
  fi
  RO=$(cat "$W/ro.out")
  expect "$RO" "cannot create a staging directory in $W/ro ($W/ro/.pion_ld\." "read-only output directory"
  if printf '%s' "$RO" | grep -q 'names taken'; then fail "read-only output directory: retried instead of failing: $RO"; fi
  [ -z "$(ls -A "$W/ro")" ] || fail "read-only output directory: something was created: $(ls -A "$W/ro")"
  echo "p97 read-only output directory fails at once (EACCES, no retries): OK"
else
  echo "NOTE: running as root; skipping the read-only output directory check"
fi
chmod 0755 "$W/ro"
echo "not a dir" > "$W/plain"
if PION_CACHE_DIR="$W/cas_o" "$PIONC" build -o "$W/plain/app" "$W/app/main.pion" > "$W/nd.out" 2>&1; then
  fail "build -o under a regular file succeeded"
fi
ND=$(cat "$W/nd.out")
if printf '%s' "$ND" | grep -q 'names taken'; then fail "file as output directory: retried instead of failing: $ND"; fi
[ "$(cat "$W/plain")" = "not a dir" ] || fail "file as output directory: the file was changed"
echo "p97 file as output directory fails at once (no retries): OK"

# --- 4) One `test --jobs 4`: A paused mid-link, B fails and is cleaned up ----
WS2="$W/ws2"
mkdir -p "$WS2"
cat > "$WS2/pion.toml" <<'EOF'
[workspace]
members = ["pkgs/*"]
EOF
for role in a b; do
  # `p97_role_<x>` exists so the extra `-L` is a real directory; the fake CC
  # tells the two links apart by it.
  mkdir -p "$WS2/pkgs/$role/src" "$WS2/pkgs/$role/p97_role_$role"
  cat > "$WS2/pkgs/$role/pion.toml" <<EOF
[package]
name = "il_$role"
version = "0.1.0"

[link]
search_paths = [".", "p97_role_$role"]
EOF
  cat > "$WS2/pkgs/$role/src/lib.pion" <<EOF
pub fn ${role}_num() -> Int { 41 }
EOF
  cat > "$WS2/pkgs/$role/src/${role}_test.pion" <<EOF
test "il_${role}_ok" {
  debug_assert(${role}_num() + 1 == 42, "il_${role}_ok")
}
EOF
done

# Coordinator: runs the command in its own session / process group, holds the
# four FIFOs open read-write and non-blocking (so neither side's open ever
# blocks), and waits on them with `select` against one overall deadline while
# watching `proc.poll()`, so a pionc that exits early fails at once. Every
# exit path (assertion, timeout, success) ends in `finally`: SIGTERM, then
# SIGKILL, to the whole group, and a bounded check that pionc and both paused
# fake linkers (pids in a.pid / b.pid) are gone. Both links are held at once
# before B is released to fail, so B's cleanup provably overlaps A's stage. Modes: `full` (the real case), `early`
# (the command must exit before A arrives), `bad_sentinel` (A's sentinel is
# removed while A is paused, so the sentinel assertion must fail).
# Exit: 0 all coordinated assertions held (pionc's rc in pionc.rc), 3 an
# assertion or the deadline failed, 4 a process of the group outlived it.
cat > "$W/il_coord.py" <<'PYEOF'
import os, select, signal, subprocess, sys, time

il, mode, timeout_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
cmd = sys.argv[4:]


def p(name):
    return os.path.join(il, name)


class Fail(Exception):
    pass


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


fds = {n: os.open(p(n), os.O_RDWR | os.O_NONBLOCK) for n in ("a_ready", "a_go", "b_ready", "b_go")}
out_f = open(p("test.out"), "wb")
err_f = open(p("test.err"), "wb")
proc = subprocess.Popen(cmd, stdout=out_f, stderr=err_f, start_new_session=True)
deadline = time.monotonic() + timeout_s


def wait_line(name):
    buf = b""
    while b"\n" not in buf:
        rem = deadline - time.monotonic()
        if rem <= 0:
            raise Fail("timed out waiting for " + name)
        r, _, _ = select.select([fds[name]], [], [], min(rem, 0.25))
        if r:
            try:
                buf += os.read(fds[name], 4096)
            except BlockingIOError:
                pass
            continue
        if proc.poll() is not None:
            raise Fail("pionc exited (rc=%d) before %s" % (proc.returncode, name))
    return buf.split(b"\n", 1)[0].decode("utf-8", "replace").strip()


def read_path(name):
    with open(p(name)) as f:
        return f.read().strip()


code = 0
try:
    try:
        if wait_line("a_ready") != "ready":
            raise Fail("package A's link never reached the linker")
        a_stage = os.path.dirname(read_path("a.out"))
        if wait_line("b_ready") != "ready":
            raise Fail("package B's link never reached the linker")
        b_out = read_path("b.out")
        b_stage = os.path.dirname(b_out)
        if os.path.dirname(a_stage) != os.path.dirname(b_stage):
            raise Fail("A (%s) and B (%s) stage under different parents" % (a_stage, b_stage))
        if a_stage == b_stage:
            raise Fail("A and B share the staging directory " + a_stage)
        for st in (a_stage, b_stage):
            if not os.path.basename(st).startswith(".pion_ld."):
                raise Fail("link output is not staged: " + st)
        sentinel = os.path.join(a_stage, ".sentinel_a")
        # Both links are paused inside their own stages right now.
        for f in (sentinel, os.path.join(b_stage, ".side_b"), b_out):
            if not os.path.isfile(f):
                raise Fail("both links paused, but %s is missing" % f)
        # Release B to fail; pionc then removes B's staging directory while
        # A is still paused in its own (bounded by the deadline).
        os.write(fds["b_go"], b"fail\n")
        while os.path.exists(b_stage):
            if time.monotonic() > deadline:
                raise Fail("B's staging directory %s was never removed" % b_stage)
            time.sleep(0.01)  # poll backoff only, not synchronization
        if mode == "bad_sentinel":
            os.remove(sentinel)
        if not os.path.isdir(a_stage):
            raise Fail("A's staging directory %s vanished while A was paused" % a_stage)
        try:
            with open(sentinel) as f:
                ok = f.read().strip() == "a"
        except FileNotFoundError:
            ok = False
        if not ok:
            raise Fail("A's sentinel was removed or changed while B was cleaned up")
        os.write(fds["a_go"], b"go\n")
        try:
            rc = proc.wait(timeout=max(deadline - time.monotonic(), 0.1))
        except subprocess.TimeoutExpired:
            raise Fail("pionc did not finish after A was released")
        with open(p("pionc.rc"), "w") as f:
            f.write("%d\n" % rc)
    except Fail as e:
        print("coordinator (%s): %s" % (mode, e), file=sys.stderr)
        code = 3
finally:
    # The whole group: pionc and every linker / fake CC it started.
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    proc.wait()
    for fd in fds.values():
        os.close(fd)
    out_f.close()
    err_f.close()
    pids = [proc.pid]
    for name in ("a.pid", "b.pid"):
        if os.path.exists(p(name)):
            pids.append(int(read_path(name)))
    reap_end = time.monotonic() + 5
    while any(alive(x) for x in pids):
        if time.monotonic() > reap_end:
            left = [x for x in pids if alive(x)]
            print("coordinator (%s): processes still alive: %s" % (mode, left), file=sys.stderr)
            code = 4
            break
sys.exit(code)
PYEOF

IL="$W/il"
CAS_IL="$W/cas_il"
mkdir -p "$IL"
mkfifo "$IL/a_ready" "$IL/a_go" "$IL/b_ready" "$IL/b_go"
IL_RC=0
P97_IL="$IL" CC="$W/fakecc" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_IL" \
  python3 "$W/il_coord.py" "$IL" full 60 "$PIONC" test --jobs 4 --json "$WS2" 2> "$IL/coord.err" || IL_RC=$?
[ "$IL_RC" = 0 ] || fail "interleave: coordinator rc=$IL_RC: $(cat "$IL/coord.err")"
A_OUT=$(cat "$IL/a.out")
B_OUT=$(cat "$IL/b.out")
A_STAGE=$(dirname "$A_OUT")
PIONC_RC=$(cat "$IL/pionc.rc")
IL_OUT="$(cat "$IL/test.out") $(cat "$IL/test.err")"
echo "p97 interleave: pionc test --jobs 4 rc=$PIONC_RC -> $(cat "$IL/test.out") $(grep -v '^\[' "$IL/test.err" || true)"
[ "$PIONC_RC" != 0 ] || fail "interleave: pionc test succeeded although B's link failed: $IL_OUT"
expect "$IL_OUT" 'linker failed with exit code 1' "interleave: B's link failure is reported"
expect "$IL_OUT" '\[cas\] test=il_b MISS' "interleave: B was linked in this run"
A_BIN="$CAS_IL/testbin/$(basename "$A_OUT")"
B_BIN="$CAS_IL/testbin/$(basename "$B_OUT")"
[ -f "$A_BIN" ] && [ -x "$A_BIN" ] && [ -s "$A_BIN" ] || fail "interleave: A's binary $A_BIN was not published"
"$A_BIN" 0 > "$IL/a_run.out" 2>&1 || fail "interleave: A's published binary fails its test: $(cat "$IL/a_run.out")"
[ ! -e "$B_BIN" ] || fail "interleave: B's failed link published $B_BIN"
[ ! -e "$A_STAGE" ] || fail "interleave: A's staging directory $A_STAGE was left behind"
left=$(find "$CAS_IL" "$WS2" -name '.pion_ld.*' 2>/dev/null || true)
[ -z "$left" ] || fail "interleave: staging directories left behind: $left"
A_KEY=$(printf '%s\n' "$IL_OUT" | sed -n 's/.*\[cas\] test=il_a MISS bin=\([0-9a-f]*\).*/\1/p' | head -n 1)
[ -n "$A_KEY" ] || fail "interleave: no MISS trace for A: $IL_OUT"
case "$(basename "$A_OUT")" in "$A_KEY"*) ;; *) fail "interleave: A's staged name $(basename "$A_OUT") is not its bin key $A_KEY" ;; esac
# Same CC and link options, A alone: its published binary is a CAS hit and passes.
A2=$(CC="$W/fakecc" PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_IL" "$PIONC" test --jobs 4 --json "$WS2/pkgs/a" 2>&1) \
  || fail "interleave: A alone after the interleaved run failed: $A2"
expect "$A2" "\\[cas\\] test=il_a HIT bin=$A_KEY" "interleave: A's published binary is reused"
expect "$A2" '"passed":1' "interleave: A's test passes"
expect "$A2" '"failed":0' "interleave: A's test passes"
echo "p97 interleave: A paused in its stage, B failed + removed from a sibling stage, then A published (runs; CAS hit passes); 0 leftovers: OK"

# Coordinator failure paths (5 s deadline): they must fail fast and leave no
# process of the run behind.
# (a) pionc exits before A ever reaches the linker (no such project).
ILE="$W/il_early"
mkdir -p "$ILE"
mkfifo "$ILE/a_ready" "$ILE/a_go" "$ILE/b_ready" "$ILE/b_go"
E_RC=0
P97_IL="$ILE" CC="$W/fakecc" PION_CACHE_DIR="$W/cas_il_early" \
  python3 "$W/il_coord.py" "$ILE" early 5 "$PIONC" test --jobs 4 --json "$W/no_such_project" 2> "$ILE/coord.err" || E_RC=$?
[ "$E_RC" = 3 ] || fail "coordinator early exit: expected rc 3, got $E_RC: $(cat "$ILE/coord.err")"
expect "$(cat "$ILE/coord.err")" 'pionc exited (rc=[1-9][0-9]*) before a_ready' "coordinator early exit"
echo "p97 coordinator: pionc exiting before A arrives fails at once (rc=$E_RC): OK"
# (b) the sentinel assertion fails while A's fake linker is paused on a_go.
ILS="$W/il_sentinel"
mkdir -p "$ILS"
mkfifo "$ILS/a_ready" "$ILS/a_go" "$ILS/b_ready" "$ILS/b_go"
S_RC=0
P97_IL="$ILS" CC="$W/fakecc" PION_CACHE_DIR="$W/cas_il_sentinel" \
  python3 "$W/il_coord.py" "$ILS" bad_sentinel 5 "$PIONC" test --jobs 4 --json "$WS2" 2> "$ILS/coord.err" || S_RC=$?
[ "$S_RC" = 3 ] || fail "coordinator sentinel failure: expected rc 3, got $S_RC: $(cat "$ILS/coord.err")"
expect "$(cat "$ILS/coord.err")" "A's sentinel was removed" "coordinator sentinel failure"
A_PID=$(cat "$ILS/a.pid")
B_PID=$(cat "$ILS/b.pid")
for pid in "$A_PID" "$B_PID"; do
  if kill -0 "$pid" 2>/dev/null; then
    fail "coordinator sentinel failure: a fake linker (pid $pid) outlived the coordinator"
  fi
done
echo "p97 coordinator: failed sentinel assertion with A paused fails at once and reaps A's fake linker (pid $A_PID): OK"

echo "p97_stage_dir_race: all OK"
