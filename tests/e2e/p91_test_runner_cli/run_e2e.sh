#!/usr/bin/env sh
# Wave I1 E2E gate:
#   (a) Single-package `pionc test` defaults to testing only the package itself,
#       reporting `deps_skipped > 0` in `--json` and a clear note in human output.
#   (b) Explicit `--deps` recursively tests local path dependencies (`deps_skipped == 0`);
#       `--no-deps` / `--only-pkg` remain compatibility aliases; mutual exclusion guards work.
#   (c) `[workspace]` root defaults to testing all workspace members.
#   (d) `--filter` filters tests across packages.
#   (e) `--jobs 1` vs `--jobs 4` produce byte-for-byte identical `--json` output.
#   (f) Multi-package parallel C stub compilation:
#       - two packages with colliding `csrc/stub.c` names compile & link deterministically;
#       - an intentionally broken C stub propagates a non-zero exit code + error (never swallowed).
#   (g) `pionc --version` and `pionc --version --json` expose `version`, `target`, and `abi_rev`.
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc-bin>}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== P91 E2E: pionc test single-pkg default / deps_skipped / parallel build / --version abi_rev ==="

# ----------------------------------------------------------------------------
# (g) pionc --version and pionc --version --json expose version, target, abi_rev
# ----------------------------------------------------------------------------
VER_TEXT="$("$PIONC" --version)"
VER_JSON="$("$PIONC" --version --json)"
echo "(g) --version -> $VER_TEXT"
echo "(g) --version --json -> $VER_JSON"

python3 - "$VER_TEXT" "$VER_JSON" <<'PYEOF'
import json, sys
ver_text, ver_json = sys.argv[1], sys.argv[2]
d = json.loads(ver_json)
assert d.get("version") == "0.1.0", f"bad version: {d}"
assert isinstance(d.get("target"), str) and len(d["target"]) > 0, f"bad target: {d}"
abi = d.get("abi_rev")
assert isinstance(abi, str) and abi.startswith("pionc-v"), f"bad abi_rev: {d}"
assert abi in ver_text, f"abi_rev {abi!r} missing from text: {ver_text!r}"
assert d["target"] in ver_text, f"target missing from text: {ver_text!r}"
PYEOF
echo "(g) --version / --version --json -> OK"

# ----------------------------------------------------------------------------
# (a) & (b) Single-package default + deps_skipped (JSON + human) + --deps + aliases
# ----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/sp/dep_a/src" "$TMP_DIR/sp/dep_b/src" "$TMP_DIR/sp/app/src"

cat > "$TMP_DIR/sp/dep_a/pion.toml" <<'EOF'
[package]
name = "dep_a"
version = "0.1.0"
EOF
cat > "$TMP_DIR/sp/dep_a/src/lib.pion" <<'EOF'
pub fn val_a() -> Int { 10 }
EOF
cat > "$TMP_DIR/sp/dep_a/src/dep_a_test.pion" <<'EOF'
test "dep_a_ok" {
  debug_assert(val_a() == 10, "dep_a_ok")
}
EOF

cat > "$TMP_DIR/sp/dep_b/pion.toml" <<'EOF'
[package]
name = "dep_b"
version = "0.1.0"
EOF
cat > "$TMP_DIR/sp/dep_b/src/lib.pion" <<'EOF'
pub fn val_b() -> Int { 32 }
EOF
cat > "$TMP_DIR/sp/dep_b/src/dep_b_test.pion" <<'EOF'
test "dep_b_fail" {
  debug_assert(1 == 2, "dep_b_fail")
}
EOF

cat > "$TMP_DIR/sp/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
dep_a = { path = "../dep_a" }
dep_b = { path = "../dep_b" }
EOF
cat > "$TMP_DIR/sp/app/src/lib.pion" <<'EOF'
import "dep_a"
import "dep_b"

pub fn total_val() -> Int { dep_a::val_a() + dep_b::val_b() }
EOF
cat > "$TMP_DIR/sp/app/src/app_test.pion" <<'EOF'
test "app_sum" {
  debug_assert(total_val() == 42, "app_sum")
}
EOF

# (a1) Default JSON: only runs app_sum, succeeds, deps_skipped == 2
SP_JSON="$("$PIONC" test --json "$TMP_DIR/sp/app")"
echo "(a) single-pkg default JSON -> $SP_JSON"
python3 - "$SP_JSON" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
assert d["ok"] is True, d
assert d["total"] == 1 and d["passed"] == 1 and d["failed"] == 0, d
assert d["deps_skipped"] == 2, f"expected deps_skipped=2, got {d}"
assert d["packages"] == ["app"], d
assert d["tests"] == [{"pkg": "app", "name": "app_sum", "ok": True}], d
PYEOF

# (a2) Default human output: prints explicit note about skipped deps
SP_HUMAN="$("$PIONC" test "$TMP_DIR/sp/app")"
echo "(a) single-pkg default human -> $SP_HUMAN"
printf '%s\n' "$SP_HUMAN" | grep -q "note: skipped 2 local path dependency package(s); pass --deps to also test them"

# (b1) Explicit --deps: runs dep_a, dep_b (fails!), and app; deps_skipped == 0
if "$PIONC" test --deps --json "$TMP_DIR/sp/app" > "$TMP_DIR/sp/deps.json" 2>"$TMP_DIR/sp/deps.err"; then
  echo "FAIL: --deps should have run dep_b_fail and exited non-zero" >&2
  exit 1
fi
SP_DEPS_JSON="$(cat "$TMP_DIR/sp/deps.json")"
echo "(b) --deps JSON -> $SP_DEPS_JSON"
python3 - "$SP_DEPS_JSON" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
assert d["ok"] is False, d
assert d["total"] == 3 and d["passed"] == 2 and d["failed"] == 1, d
assert d["deps_skipped"] == 0, f"expected deps_skipped=0, got {d}"
names = {(t["pkg"], t["name"]): t["ok"] for t in d["tests"]}
assert names == {("dep_a", "dep_a_ok"): True, ("dep_b", "dep_b_fail"): False, ("app", "app_sum"): True}, names
PYEOF

# (b2) --no-deps and --only-pkg compatibility aliases
SP_ND="$("$PIONC" test --no-deps --json "$TMP_DIR/sp/app")"
[ "$SP_ND" = "$SP_JSON" ]
SP_OP="$("$PIONC" test --only-pkg --json "$TMP_DIR/sp/app")"
[ "$SP_OP" = "$SP_JSON" ]

# (b3) Mutual exclusion guards
if "$PIONC" test --deps --no-deps --json "$TMP_DIR/sp/app" > "$TMP_DIR/sp/m1.out" 2>&1; then
  echo "FAIL: --deps --no-deps should fail" >&2
  exit 1
fi
grep -q "mutually exclusive" "$TMP_DIR/sp/m1.out"
if "$PIONC" test --deps -p app --json "$TMP_DIR/sp/app" > "$TMP_DIR/sp/m2.out" 2>&1; then
  echo "FAIL: --deps -p should fail" >&2
  exit 1
fi
grep -q "mutually exclusive" "$TMP_DIR/sp/m2.out"
echo "(a)-(b) single-pkg default, deps_skipped, --deps & aliases -> OK"

# ----------------------------------------------------------------------------
# (c), (d), (e) [workspace] root default + --filter + --jobs 1 vs --jobs 4 byte-identical JSON
# ----------------------------------------------------------------------------
WS="$TMP_DIR/ws"
mkdir -p "$WS/pkgs/alpha/src" "$WS/pkgs/beta/src" "$WS/pkgs/gamma/src" "$WS/pkgs/delta/src"

cat > "$WS/pion.toml" <<'EOF'
[workspace]
members = ["pkgs/*"]
EOF

cat > "$WS/pkgs/alpha/pion.toml" <<'EOF'
[package]
name = "alpha"
version = "0.1.0"
EOF
cat > "$WS/pkgs/alpha/src/lib.pion" <<'EOF'
pub fn a_num() -> Int { 11 }
EOF
cat > "$WS/pkgs/alpha/src/alpha_test.pion" <<'EOF'
test "alpha_basic" {
  debug_assert(a_num() == 11, "alpha_basic")
}
test "alpha_shared_tag" {
  debug_assert(a_num() + 1 == 12, "alpha_shared_tag")
}
EOF

cat > "$WS/pkgs/beta/pion.toml" <<'EOF'
[package]
name = "beta"
version = "0.1.0"

[dependencies]
alpha = { path = "../alpha" }
EOF
cat > "$WS/pkgs/beta/src/lib.pion" <<'EOF'
import "alpha"
pub fn b_num() -> Int { alpha::a_num() * 2 }
EOF
cat > "$WS/pkgs/beta/src/beta_test.pion" <<'EOF'
test "beta_basic" {
  debug_assert(b_num() == 22, "beta_basic")
}
test "beta_shared_tag" {
  debug_assert(b_num() + 2 == 24, "beta_shared_tag")
}
EOF

cat > "$WS/pkgs/gamma/pion.toml" <<'EOF'
[package]
name = "gamma"
version = "0.1.0"

[dependencies]
alpha = { path = "../alpha" }
EOF
cat > "$WS/pkgs/gamma/src/lib.pion" <<'EOF'
import "alpha"
pub fn g_num() -> Int { alpha::a_num() * 3 }
EOF
cat > "$WS/pkgs/gamma/src/gamma_test.pion" <<'EOF'
test "gamma_basic" {
  debug_assert(g_num() == 33, "gamma_basic")
}
EOF

cat > "$WS/pkgs/delta/pion.toml" <<'EOF'
[package]
name = "delta"
version = "0.1.0"

[dependencies]
beta = { path = "../beta" }
gamma = { path = "../gamma" }
EOF
cat > "$WS/pkgs/delta/src/lib.pion" <<'EOF'
import "beta"
import "gamma"
pub fn d_num() -> Int { beta::b_num() + gamma::g_num() }
EOF
cat > "$WS/pkgs/delta/src/delta_test.pion" <<'EOF'
test "delta_shared_tag" {
  debug_assert(d_num() == 55, "delta_shared_tag")
}
EOF

# (c) Workspace root default runs all 4 members (6 tests), deps_skipped == 0
CAS_J1="$TMP_DIR/cas_j1"
CAS_J4="$TMP_DIR/cas_j4"
mkdir -p "$CAS_J1" "$CAS_J4"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_J1" "$PIONC" test --jobs 1 --json "$WS" > "$TMP_DIR/ws_j1.json" 2>"$TMP_DIR/ws_j1.trace"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_J4" "$PIONC" test --jobs 4 --json "$WS" > "$TMP_DIR/ws_j4.json" 2>"$TMP_DIR/ws_j4.trace"
echo "(c)/(e) workspace --jobs 1 -> $(cat "$TMP_DIR/ws_j1.json")"

# (e) Byte-for-byte identical JSON AND identical testobj CAS keys between --jobs 1 and --jobs 4
if ! cmp -s "$TMP_DIR/ws_j1.json" "$TMP_DIR/ws_j4.json"; then
  echo "FAIL: --jobs 1 and --jobs 4 JSON outputs differ!" >&2
  diff -u "$TMP_DIR/ws_j1.json" "$TMP_DIR/ws_j4.json" >&2 || true
  exit 1
fi

python3 - "$TMP_DIR/ws_j1.json" "$TMP_DIR/ws_j1.trace" "$TMP_DIR/ws_j4.trace" "$CAS_J1/testbin" "$CAS_J4/testbin" <<'PYEOF'
import json, os, re, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True, d
assert d["total"] == 6 and d["passed"] == 6 and d["failed"] == 0, d
assert d["deps_skipped"] == 0, d
assert len(d["packages"]) == 4, d

def parse_okeys(path):
    res = {}
    for line in open(path):
        m = re.search(r"\[cas\] test=(\S+) MISS bin=\S+ okey=(\S+)", line)
        if m:
            res[m.group(1)] = m.group(2)
    return res

ok1 = parse_okeys(sys.argv[2])
ok4 = parse_okeys(sys.argv[3])
assert len(ok1) == 4, f"expected 4 testobj keys in j1 trace, got {ok1}"
assert ok1 == ok4, f"testobj keys differ between --jobs 1 ({ok1}) and --jobs 4 ({ok4})"
o1 = sorted(f for f in os.listdir(sys.argv[4]) if f.endswith(".o"))
o4 = sorted(f for f in os.listdir(sys.argv[5]) if f.endswith(".o"))
assert len(o1) == 4 and o1 == o4, f"testbin/*.o mismatch: j1={o1} j4={o4}"
for f in o1:
    b1 = open(os.path.join(sys.argv[4], f), "rb").read()
    b4 = open(os.path.join(sys.argv[5], f), "rb").read()
    assert len(b1) > 0 and b1 == b4, f"testbin/{f} byte content differs between --jobs 1 and --jobs 4"
PYEOF

# (d) --filter across workspace members
FLT_JSON="$(PION_CACHE_DIR="$CAS_J4" "$PIONC" test --jobs 4 --filter shared_tag --json "$WS")"
echo "(d) --filter shared_tag -> $FLT_JSON"
python3 - "$FLT_JSON" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
assert d["ok"] is True, d
assert d["total"] == 3 and d["passed"] == 3 and d["failed"] == 0, d
names = [t["name"] for t in d["tests"]]
assert all("shared_tag" in n for n in names), names
PYEOF
echo "(c)-(e) workspace default, --filter, --jobs 1 vs 4 byte-identical -> OK"

# ----------------------------------------------------------------------------
# (f) Multi-package parallel C stub compilation:
#     1) colliding `csrc/stub.c` filenames across packages, deterministic link order
#     2) failing C stub propagates non-zero exit + error
# ----------------------------------------------------------------------------
CS="$TMP_DIR/cstub_ws"
mkdir -p "$CS/lib_a/src" "$CS/lib_a/csrc" "$CS/lib_b/src" "$CS/lib_b/csrc" "$CS/app/src"

cat > "$CS/pion.toml" <<'EOF'
[workspace]
members = ["lib_a", "lib_b", "app"]
EOF

cat > "$CS/lib_a/pion.toml" <<'EOF'
[package]
name = "lib_a"
version = "0.1.0"

[link]
c_sources = ["csrc/stub.c"]
EOF
cat > "$CS/lib_a/csrc/stub.c" <<'EOF'
#include <stdint.h>
int64_t p91_stub_a_val(void) { return 100; }
EOF
cat > "$CS/lib_a/src/lib.pion" <<'EOF'
extern "C" fn p91_stub_a_val() -> Int64
pub fn get_a() -> Int64 { p91_stub_a_val() }
EOF
cat > "$CS/lib_a/src/lib_a_test.pion" <<'EOF'
test "cstub_a" {
  debug_assert(get_a() == 100L, "cstub_a")
}
EOF

cat > "$CS/lib_b/pion.toml" <<'EOF'
[package]
name = "lib_b"
version = "0.1.0"

[link]
c_sources = ["csrc/stub.c"]
EOF
cat > "$CS/lib_b/csrc/stub.c" <<'EOF'
#include <stdint.h>
int64_t p91_stub_b_val(void) { return 23; }
EOF
cat > "$CS/lib_b/src/lib.pion" <<'EOF'
extern "C" fn p91_stub_b_val() -> Int64
pub fn get_b() -> Int64 { p91_stub_b_val() }
EOF
cat > "$CS/lib_b/src/lib_b_test.pion" <<'EOF'
test "cstub_b" {
  debug_assert(get_b() == 23L, "cstub_b")
}
EOF

cat > "$CS/app/pion.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"

[dependencies]
lib_a = { path = "../lib_a" }
lib_b = { path = "../lib_b" }

[link]
search_paths = ["."]
EOF
cat > "$CS/app/src/lib.pion" <<'EOF'
import "lib_a"
import "lib_b"
pub fn get_both() -> Int64 { lib_a::get_a() + lib_b::get_b() }
EOF
cat > "$CS/app/src/app_test.pion" <<'EOF'
test "cstub_both" {
  debug_assert(get_both() == 123L, "cstub_both")
}
EOF

# Custom CC wrapper supporting:
#   - deterministic per-worker FIFO arrival/release barrier (zero sleep),
#   - adversarial output modes (`empty` 0-byte file, `symlink` relative symlink),
#   - cross-process same-key race roles (`good` pauses after staging lib_a; `bad` fails lib_b).
CC_WRAP="$TMP_DIR/cc_wrap.sh"
cat > "$CC_WRAP" <<'EOF'
#!/usr/bin/env sh
set -eu
REAL="${REAL_CC:-cc}"
IS_COMPILE=0
TAG=""
OUT_FILE=""
PREV_O=0
for arg in "$@"; do
  if [ "$PREV_O" = "1" ]; then
    OUT_FILE="$arg"
    PREV_O=0
    continue
  fi
  if [ "$arg" = "-o" ]; then
    PREV_O=1
    continue
  fi
  if [ "$arg" = "-c" ]; then
    IS_COMPILE=1
  fi
  case "$arg" in
    *lib_a/csrc/stub.c) TAG="lib_a" ;;
    *lib_b/csrc/stub.c) TAG="lib_b" ;;
  esac
done
if [ "$IS_COMPILE" = "1" ] && [ -n "$TAG" ]; then
  if [ -n "${P91_CC_LOG:-}" ]; then
    printf 'START %s\n' "$TAG" >> "$P91_CC_LOG"
  fi
  if [ "${P91_MODE:-}" = "empty" ] && [ "$TAG" = "lib_b" ] && [ -n "$OUT_FILE" ]; then
    : > "$OUT_FILE"
    exit 0
  fi
  if [ "${P91_MODE:-}" = "symlink" ] && [ "$TAG" = "lib_b" ] && [ -n "$OUT_FILE" ]; then
    OUT_DIR="$(dirname "$OUT_FILE")"
    printf 'dummy_object_bytes\n' > "$OUT_DIR/rel_target.bin"
    ln -sf "rel_target.bin" "$OUT_FILE"
    exit 0
  fi
  if [ "${P91_PROC_ROLE:-}" = "bad" ] && [ "$TAG" = "lib_b" ]; then
    if [ -n "${P91_B_INJECTED_MARKER:-}" ]; then
      printf 'injected\n' > "$P91_B_INJECTED_MARKER"
    fi
    echo "injected bad stub compile failure" >&2
    exit 1
  fi
  if [ -n "${P91_ARRIVE_FIFO:-}" ]; then
    REL_FIFO=""
    if [ "$TAG" = "lib_a" ]; then
      REL_FIFO="${P91_RELEASE_A_FIFO:-}"
    elif [ "$TAG" = "lib_b" ]; then
      REL_FIFO="${P91_RELEASE_B_FIFO:-}"
    fi
    if [ -n "$REL_FIFO" ]; then
      printf '%s\n' "$TAG" > "$P91_ARRIVE_FIFO"
      IFS= read -r _ < "$REL_FIFO"
    fi
  fi
  "$REAL" "$@"
  RC=$?
  if [ "$RC" = "0" ] && [ "${P91_PROC_ROLE:-}" = "good" ] && [ "$TAG" = "lib_a" ] && [ -n "${P91_A_READY_FIFO:-}" ] && [ -n "${P91_A_GO_FIFO:-}" ]; then
    printf '%s\n' "$OUT_FILE" > "${P91_A_TMP_RECORD}"
    printf 'ready\n' > "$P91_A_READY_FIFO"
    IFS= read -r _ < "$P91_A_GO_FIFO"
  fi
  if [ -n "${P91_CC_LOG:-}" ]; then
    printf 'END %s\n' "$TAG" >> "$P91_CC_LOG"
  fi
  exit "$RC"
else
  if [ -n "${P91_CC_LOG:-}" ]; then
    # One file per link: `--jobs 4` links lib_a, lib_b and app concurrently and
    # a LINK line is > 1 KiB, which a shell's `printf >>` need not write in one
    # write(2), so lines appended to one shared log may interleave.
    LINK_F=$(mktemp "$P91_CC_LOG.link.XXXXXX")
    printf 'LINK %s\n' "$*" > "$LINK_F"
  fi
  exec "$REAL" "$@"
fi
EOF
chmod +x "$CC_WRAP"

# Coordinator-owned process-group FIFO barrier helper (zero sleep, separate
# per-worker release FIFOs, bounded timeout with SIGKILL on the process group).
# Distinguishes early child exit (rc=125) from genuine post-first-arrival
# timeout (rc=124) and writes the observed arrival count to `arrived_path`.
FIFO_COORD="$TMP_DIR/fifo_barrier_run.py"
cat > "$FIFO_COORD" <<'PYEOF'
import os, select, signal, subprocess, sys, time

arr_path, rel_a_path, rel_b_path, ok_path, arrived_path, timeout_s, out_path, err_path = sys.argv[1:9]
sep_idx = sys.argv.index("--")
cmd = sys.argv[sep_idx + 1:]
timeout_s = float(timeout_s)
startup_s = max(15.0, timeout_s)

arr_fd = os.open(arr_path, os.O_RDWR)
rel_a_fd = os.open(rel_a_path, os.O_RDWR)
rel_b_fd = os.open(rel_b_path, os.O_RDWR)
out_f = open(out_path, "wb")
err_f = open(err_path, "wb")
proc = subprocess.Popen(cmd, stdout=out_f, stderr=err_f, start_new_session=True)
try:
    buf = b""
    seen = set()
    deadline = time.monotonic() + startup_s
    while len(seen) < 2:
        if proc.poll() is not None:
            open(arrived_path, "w").write(f"{len(seen)}\n")
            sys.exit(125)
        rem = deadline - time.monotonic()
        if rem <= 0:
            open(arrived_path, "w").write(f"{len(seen)}\n")
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            sys.exit(124)
        wait_slice = min(rem, 0.25)
        r, _, _ = select.select([arr_fd], [], [], wait_slice)
        if r:
            chunk = os.read(arr_fd, 4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                tag = line.decode("utf-8", "replace").strip()
                if tag in ("lib_a", "lib_b"):
                    prev_n = len(seen)
                    seen.add(tag)
                    if prev_n == 0 and len(seen) == 1:
                        # Start the bounded second-arrival countdown only once
                        # the first worker has genuinely arrived.
                        deadline = time.monotonic() + timeout_s
    open(arrived_path, "w").write(f"{len(seen)}\n")
    open(ok_path, "w").write("ok\n")
    os.write(rel_a_fd, b"go\n")
    os.write(rel_b_fd, b"go\n")
    try:
        rc = proc.wait(timeout=max(10.0, timeout_s))
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        sys.exit(124)
    sys.exit(rc)
finally:
    for fd in (arr_fd, rel_a_fd, rel_b_fd):
        try:
            os.close(fd)
        except OSError:
            pass
    out_f.close()
    err_f.close()
PYEOF

REAL_CC_BIN="${CC:-cc}"
REAL_CC_ABS="$(command -v "$REAL_CC_BIN")"
CAS_CS1="$TMP_DIR/cas_cs1"
CAS_CS4="$TMP_DIR/cas_cs4"
BARRIER_DIR="$TMP_DIR/barrier"
CCLOG_DIR="$TMP_DIR/cclogs"
mkdir -p "$CAS_CS1" "$CAS_CS4" "$BARRIER_DIR" "$CCLOG_DIR"

# --jobs 1 cold run (no barrier): strict non-overlapping cstub compiles
REAL_CC="$REAL_CC_ABS" CC="$CC_WRAP" P91_CC_LOG="$CCLOG_DIR/cc_j1.log" P91_ARRIVE_FIFO="" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_CS1" "$PIONC" test --jobs 1 --json "$CS" \
  > "$TMP_DIR/cs_j1.json" 2>"$TMP_DIR/cs_j1.trace"

# --jobs 4 cold run (coordinator-owned process-group FIFO barrier): proves concurrent overlap
ARRIVE_FIFO="$BARRIER_DIR/arrive.fifo"
REL_A_FIFO="$BARRIER_DIR/release_lib_a.fifo"
REL_B_FIFO="$BARRIER_DIR/release_lib_b.fifo"
mkfifo "$ARRIVE_FIFO" "$REL_A_FIFO" "$REL_B_FIFO"

REAL_CC="$REAL_CC_ABS" CC="$CC_WRAP" P91_CC_LOG="$CCLOG_DIR/cc_j4.log" \
  P91_ARRIVE_FIFO="$ARRIVE_FIFO" P91_RELEASE_A_FIFO="$REL_A_FIFO" P91_RELEASE_B_FIFO="$REL_B_FIFO" \
  PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_CS4" \
  python3 "$FIFO_COORD" "$ARRIVE_FIFO" "$REL_A_FIFO" "$REL_B_FIFO" "$BARRIER_DIR/overlap_ok" "$BARRIER_DIR/arrived.txt" 10 \
  "$TMP_DIR/cs_j4.json" "$TMP_DIR/cs_j4.trace" -- "$PIONC" test --jobs 4 --json "$CS"

echo "(f1) cstub colliding stub.c --jobs 4 -> $(cat "$TMP_DIR/cs_j4.json")"
if ! cmp -s "$TMP_DIR/cs_j1.json" "$TMP_DIR/cs_j4.json"; then
  echo "FAIL: cstub --jobs 1 vs --jobs 4 JSON mismatch!" >&2
  exit 1
fi
if [ ! -f "$BARRIER_DIR/overlap_ok" ] || [ "$(cat "$BARRIER_DIR/arrived.txt")" != "2" ]; then
  echo "FAIL: expected FIFO overlap barrier to succeed with 2 arrivals under --jobs 4!" >&2
  exit 1
fi

# Bounded timeout self-check: running --jobs 1 against the same 2-worker barrier
# must observe 1 worker arrival, then terminate the process group cleanly with
# exit 124 (never hang and never false-pass on early exit).
BARRIER_TO="$TMP_DIR/barrier_to"
CAS_TO="$TMP_DIR/cas_to"
mkdir -p "$BARRIER_TO" "$CAS_TO"
mkfifo "$BARRIER_TO/arrive.fifo" "$BARRIER_TO/rel_a.fifo" "$BARRIER_TO/rel_b.fifo"
set +e
REAL_CC="$REAL_CC_ABS" CC="$CC_WRAP" \
  P91_ARRIVE_FIFO="$BARRIER_TO/arrive.fifo" P91_RELEASE_A_FIFO="$BARRIER_TO/rel_a.fifo" P91_RELEASE_B_FIFO="$BARRIER_TO/rel_b.fifo" \
  PION_CACHE_DIR="$CAS_TO" \
  python3 "$FIFO_COORD" "$BARRIER_TO/arrive.fifo" "$BARRIER_TO/rel_a.fifo" "$BARRIER_TO/rel_b.fifo" "$BARRIER_TO/overlap_ok" "$BARRIER_TO/arrived.txt" 1 \
  "$TMP_DIR/to.out" "$TMP_DIR/to.err" -- "$PIONC" test --jobs 1 --json "$CS"
TO_RC=$?
set -e
if [ "$TO_RC" -ne 124 ] || [ -f "$BARRIER_TO/overlap_ok" ] || [ "$(cat "$BARRIER_TO/arrived.txt")" != "1" ]; then
  echo "FAIL: expected bounded FIFO barrier timeout rc=124 with arrived=1 and no overlap_ok, got rc=$TO_RC arrived=$(cat "$BARRIER_TO/arrived.txt" 2>/dev/null || true)" >&2
  exit 1
fi

python3 - "$TMP_DIR/cs_j4.json" "$CCLOG_DIR/cc_j1.log" "$CCLOG_DIR/cc_j4.log" "$TMP_DIR/cs_j1.trace" "$TMP_DIR/cs_j4.trace" <<'PYEOF'
import glob, json, re, sys

d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["total"] == 3 and d["passed"] == 3 and d["failed"] == 0, d

# Verify strict non-overlap in --jobs 1 log: START X, END X, START Y, END Y
j1_events = [l.strip() for l in open(sys.argv[2]) if l.startswith(("START ", "END "))]
assert len(j1_events) == 4, f"expected 4 compile events in j1, got {j1_events}"
assert j1_events[0].startswith("START ") and j1_events[1] == "END " + j1_events[0].split()[1], j1_events
assert j1_events[2].startswith("START ") and j1_events[3] == "END " + j1_events[2].split()[1], j1_events

def map_cstub_keys(trace_path):
    txt = open(trace_path).read()
    assert "(local:" not in txt, f"unexpected local fallback in {trace_path}:\n{txt}"
    m = {}
    for line in txt.splitlines():
        hit = re.search(r"\[cas\] cstub=(\S+) MISS key=([0-9a-f]+)", line)
        if hit:
            src, prefix = hit.group(1), hit.group(2)
            if "lib_a/csrc/stub.c" in src:
                m[prefix] = "lib_a"
            elif "lib_b/csrc/stub.c" in src:
                m[prefix] = "lib_b"
    assert set(m.values()) == {"lib_a", "lib_b"}, f"missing cstub trace map: {m}"
    return m

def link_lines(cc_log):
    for path in sorted(glob.glob(cc_log + ".link.*")):
        yield from open(path)

def extract_app_cstub_order(cc_log, key_map):
    for line in link_lines(cc_log):
        if not line.startswith("LINK "):
            continue
        objs = re.findall(r"cstub_([0-9a-f]+)\.o", line)
        if len(objs) == 2:
            seq = []
            for h in objs:
                matched = [tag for pref, tag in key_map.items() if h.startswith(pref)]
                assert len(matched) == 1, f"unmapped cstub hash {h} in {key_map}"
                seq.append(matched[0])
            return seq
    raise AssertionError(f"no app LINK line with 2 cstub_*.o found in {cc_log}")

seq1 = extract_app_cstub_order(sys.argv[3 - 1], map_cstub_keys(sys.argv[4]))
seq4 = extract_app_cstub_order(sys.argv[3], map_cstub_keys(sys.argv[5]))
assert seq1 == ["lib_a", "lib_b"], f"unexpected j1 link order: {seq1}"
assert seq4 == seq1, f"link order mismatch: j1={seq1} vs j4={seq4}"
print(f"(f1) verified overlap (--jobs 4), non-overlap (--jobs 1), and deterministic link order {seq4}")
PYEOF

# (f2) Break lib_b/csrc/stub.c: parallel compile fails loudly AND leaves 0 orphan
#      cstub_*.o / *.tmp.* in CAS_CS_FAIL/obj/; after fixing, same CAS succeeds
#      and records both cstub_*.o in CAS index.tsv.
cat > "$CS/lib_b/csrc/stub.c" <<'EOF'
#include <stdint.h>
int64_t p91_stub_b_val(void) { THIS IS A SYNTAX ERROR; }
EOF
CAS_CS_FAIL="$TMP_DIR/cas_cs_fail"
mkdir -p "$CAS_CS_FAIL"
if PION_CACHE_DIR="$CAS_CS_FAIL" "$PIONC" test --jobs 4 --json "$CS" > "$TMP_DIR/cs_fail.out" 2>&1; then
  echo "FAIL: broken C stub must fail pionc test!" >&2
  exit 1
fi
grep -q "failed to compile c_source" "$TMP_DIR/cs_fail.out"

python3 - "$CAS_CS_FAIL/obj" <<'PYEOF'
import os, sys
obj_dir = sys.argv[1]
if os.path.isdir(obj_dir):
    bad = [f for f in os.listdir(obj_dir) if f.startswith("cstub_") or ".tmp." in f]
    assert len(bad) == 0, f"orphan cstub/tmp/stage files left after failed batch: {bad}"
PYEOF

# Repair lib_b/csrc/stub.c and re-run against the SAME CAS_CS_FAIL
cat > "$CS/lib_b/csrc/stub.c" <<'EOF'
#include <stdint.h>
int64_t p91_stub_b_val(void) { return 23; }
EOF
PION_CACHE_DIR="$CAS_CS_FAIL" "$PIONC" test --jobs 4 --json "$CS" > "$TMP_DIR/cs_recover.json"
python3 - "$TMP_DIR/cs_recover.json" "$CAS_CS_FAIL/obj" "$CAS_CS_FAIL/index.tsv" <<'PYEOF'
import json, os, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["total"] == 3 and d["passed"] == 3 and d["failed"] == 0, d
cstubs = sorted(f for f in os.listdir(sys.argv[2]) if f.startswith("cstub_") and f.endswith(".o"))
assert len(cstubs) == 2, f"expected 2 published cstub_*.o after recovery, got {cstubs}"
tmps = [f for f in os.listdir(sys.argv[2]) if ".tmp." in f or f.startswith("cstub_stage")]
assert len(tmps) == 0, f"unexpected leftover tmp/stage entries: {tmps}"
idx_txt = open(sys.argv[3]).read()
for f in cstubs:
    key = f[:-2]  # strip .o -> cstub_<hex>
    assert key in idx_txt, f"published {key} missing from CAS index.tsv"
PYEOF

# (f3) Directory occupying lib_b's final cstub_<key>.o path must NEVER be treated
#      as a cache hit or concurrent-publish winner: Phase 2 fails loudly on lib_b,
#      lib_a is already published & indexed in index.tsv, staging dir is cleaned up,
#      and removing the placeholder dir lets the same CAS succeed on retry.
# Obtain exact lib_a & lib_b cstub object names under default CC via PION_CAS_TRACE=1
CAS_PROBE="$TMP_DIR/cas_probe"
mkdir -p "$CAS_PROBE"
PION_CAS_TRACE=1 PION_CACHE_DIR="$CAS_PROBE" "$PIONC" test --jobs 4 --json "$CS" > /dev/null 2>"$TMP_DIR/probe.trace"
eval "$(python3 - "$CAS_PROBE/obj" "$TMP_DIR/probe.trace" <<'PYEOF'
import os, re, sys
objs = [f for f in os.listdir(sys.argv[1]) if f.startswith("cstub_") and f.endswith(".o")]
pref_a = pref_b = None
for line in open(sys.argv[2]):
    m = re.search(r"\[cas\] cstub=(\S+) MISS key=([0-9a-f]+)", line)
    if m:
        if "lib_a/csrc/stub.c" in m.group(1):
            pref_a = m.group(2)
        elif "lib_b/csrc/stub.c" in m.group(1):
            pref_b = m.group(2)
obj_a = [f for f in objs if f.startswith("cstub_" + pref_a)][0]
obj_b = [f for f in objs if f.startswith("cstub_" + pref_b)][0]
print(f'OBJ_A="{obj_a}"')
print(f'OBJ_B="{obj_b}"')
PYEOF
)"

CAS_DIR_COLL="$TMP_DIR/cas_dir_coll"
mkdir -p "$CAS_DIR_COLL/obj/$OBJ_B"
if PION_CACHE_DIR="$CAS_DIR_COLL" "$PIONC" test --jobs 4 --json "$CS" > "$TMP_DIR/dir_coll.out" 2>&1; then
  echo "FAIL: directory at cstub target path must fail publish!" >&2
  exit 1
fi
grep -q "failed to publish c_source object" "$TMP_DIR/dir_coll.out"

python3 - "$CAS_DIR_COLL/obj" "$CAS_DIR_COLL/index.tsv" "$OBJ_A" "$OBJ_B" <<'PYEOF'
import os, sys
obj_dir, idx_path, obj_a, obj_b = sys.argv[1:5]
pa = os.path.join(obj_dir, obj_a)
assert os.path.isfile(pa) and os.path.getsize(pa) > 0, f"expected {obj_a} published as regular file"
assert os.path.isdir(os.path.join(obj_dir, obj_b)), f"expected placeholder dir {obj_b} untouched"
idx_txt = open(idx_path).read()
assert obj_a[:-2] in idx_txt, f"{obj_a[:-2]} missing from index.tsv after partial Phase-2 failure"
leftovers = [f for f in os.listdir(obj_dir) if f.startswith("cstub_stage") or ".tmp." in f]
assert len(leftovers) == 0, f"leftover staging entries after publish failure: {leftovers}"
PYEOF

rmdir "$CAS_DIR_COLL/obj/$OBJ_B"
PION_CACHE_DIR="$CAS_DIR_COLL" "$PIONC" test --jobs 4 --json "$CS" > "$TMP_DIR/dir_coll_ok.json"
python3 - "$TMP_DIR/dir_coll_ok.json" "$CAS_DIR_COLL/obj" "$CAS_DIR_COLL/index.tsv" "$OBJ_A" "$OBJ_B" <<'PYEOF'
import json, os, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["total"] == 3 and d["passed"] == 3 and d["failed"] == 0, d
obj_dir, idx_path, obj_a, obj_b = sys.argv[2:6]
idx_txt = open(idx_path).read()
for f in (obj_a, obj_b):
    p = os.path.join(obj_dir, f)
    assert os.path.isfile(p) and os.path.getsize(p) > 0, f"missing regular file {f}"
    assert f[:-2] in idx_txt, f"{f[:-2]} missing from index.tsv"
PYEOF

# (f4) Adversarial 0-byte file and relative symlink produced in staging dir must
#      be rejected by `lstat`, never indexed in index.tsv, leave 0 staging dirs,
#      and recover cleanly when re-run with the real compiler on the same CAS.
CAS_BAD_OUT="$TMP_DIR/cas_bad_out"
mkdir -p "$CAS_BAD_OUT"
for BAD_MODE in empty symlink; do
  if REAL_CC="$REAL_CC_ABS" CC="$CC_WRAP" P91_MODE="$BAD_MODE" PION_CACHE_DIR="$CAS_BAD_OUT" \
      "$PIONC" test --jobs 4 --json "$CS" > "$TMP_DIR/bad_${BAD_MODE}.out" 2>&1; then
    echo "FAIL: P91_MODE=$BAD_MODE must be rejected!" >&2
    exit 1
  fi
  grep -q "empty or invalid c_source object" "$TMP_DIR/bad_${BAD_MODE}.out"
  python3 - "$CAS_BAD_OUT/obj" "$CAS_BAD_OUT/index.tsv" "$TMP_DIR/cs_j4.trace" <<'PYEOF'
import os, re, sys
obj_dir, idx_path, trace_path = sys.argv[1:4]
leftovers = [f for f in os.listdir(obj_dir) if f.startswith("cstub_stage") or ".tmp." in f]
assert len(leftovers) == 0, f"leftover staging entries: {leftovers}"
pref_b = None
for line in open(trace_path):
    m = re.search(r"\[cas\] cstub=(\S+) MISS key=([0-9a-f]+)", line)
    if m and "lib_b/csrc/stub.c" in m.group(1):
        pref_b = m.group(2)
assert pref_b is not None
if os.path.exists(idx_path):
    idx_txt = open(idx_path).read()
    assert ("cstub_" + pref_b) not in idx_txt, f"rejected lib_b key {pref_b} leaked into index.tsv"
PYEOF
done
REAL_CC="$REAL_CC_ABS" CC="$CC_WRAP" P91_MODE="" PION_CACHE_DIR="$CAS_BAD_OUT" \
  "$PIONC" test --jobs 4 --json "$CS" > "$TMP_DIR/bad_recover.json"
python3 - "$TMP_DIR/bad_recover.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["total"] == 3 and d["passed"] == 3 and d["failed"] == 0, d
PYEOF

# (f5) Cross-platform staging cleanup with ZERO `rm`/`chmod` on PATH (both
#      success path and compile-failure path must leave 0 `cstub_stage*` dirs).
MIN_PATH="$TMP_DIR/min_path"
mkdir -p "$MIN_PATH"
for tool in cc gcc clang ld ld.lld lld as ar nm objcopy strip sh uname; do
  tp="$(command -v "$tool" 2>/dev/null || true)"
  if [ -n "$tp" ]; then
    ln -sf "$tp" "$MIN_PATH/$tool"
  fi
done
if env PATH="$MIN_PATH" sh -c 'command -v rm >/dev/null 2>&1 || command -v chmod >/dev/null 2>&1'; then
  echo "FAIL: MIN_PATH unexpectedly contains rm or chmod" >&2
  exit 1
fi
CAS_MIN_OK="$TMP_DIR/cas_min_ok"
CAS_MIN_FAIL="$TMP_DIR/cas_min_fail"
mkdir -p "$CAS_MIN_OK" "$CAS_MIN_FAIL"
PATH="$MIN_PATH" CC="$REAL_CC_ABS" PION_CACHE_DIR="$CAS_MIN_OK" \
  "$PIONC" test --jobs 4 --json "$CS" > "$TMP_DIR/min_ok.json"
CS_BAD="$TMP_DIR/cstub_ws_bad"
cp -R "$CS" "$CS_BAD"
cat > "$CS_BAD/lib_b/csrc/stub.c" <<'EOF'
#include <stdint.h>
int64_t p91_stub_b_val(void) { BROKEN SYNTAX HERE; }
EOF
if PATH="$MIN_PATH" CC="$REAL_CC_ABS" PION_CACHE_DIR="$CAS_MIN_FAIL" \
    "$PIONC" test --jobs 4 --json "$CS_BAD" > "$TMP_DIR/min_fail.out" 2>&1; then
  echo "FAIL: expected broken stub failure under MIN_PATH" >&2
  exit 1
fi
grep -q "failed to compile c_source" "$TMP_DIR/min_fail.out"
python3 - "$TMP_DIR/min_ok.json" "$CAS_MIN_OK/obj" "$CAS_MIN_FAIL/obj" <<'PYEOF'
import json, os, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True and d["total"] == 3 and d["passed"] == 3 and d["failed"] == 0, d
for obj_dir in sys.argv[2:4]:
    if os.path.isdir(obj_dir):
        left = [f for f in os.listdir(obj_dir) if f.startswith("cstub_stage") or ".tmp." in f]
        assert len(left) == 0, f"staging dirs left under MIN_PATH in {obj_dir}: {left}"
PYEOF

# (f6) True cross-process same-source-tree, same-CC-path, same-object-key race:
#      Process A (good) stages lib_a's `.o` and pauses before publish; Process B
#      (bad) runs on the EXACT same `$CS`, `$CC_WRAP`, and `$CAS_CONC`, fails on
#      lib_b and cleans up its own staging dir; coordinator verifies Process A's
#      staged `.o` is untouched, then releases Process A to succeed with 0 leftovers.
CAS_CONC="$TMP_DIR/cas_conc"
RACE_DIR="$TMP_DIR/race"
mkdir -p "$CAS_CONC" "$RACE_DIR"
mkfifo "$RACE_DIR/a_ready.fifo" "$RACE_DIR/a_go.fifo"

python3 - "$PIONC" "$CS" "$CC_WRAP" "$REAL_CC_ABS" "$CAS_CONC" "$RACE_DIR" <<'PYEOF'
import json, os, select, signal, subprocess, sys, time

pionc, cs_dir, cc_wrap, real_cc, cas_dir, race_dir = sys.argv[1:7]
ready_fifo = os.path.join(race_dir, "a_ready.fifo")
go_fifo = os.path.join(race_dir, "a_go.fifo")
tmp_rec = os.path.join(race_dir, "a_staged_path.txt")
a_out = os.path.join(race_dir, "a.json")
a_err = os.path.join(race_dir, "a.err")
b_out = os.path.join(race_dir, "b.out")
b_marker = os.path.join(race_dir, "b_injected.marker")

ready_fd = os.open(ready_fifo, os.O_RDWR)
go_fd = os.open(go_fifo, os.O_RDWR)

env_a = os.environ.copy()
env_a.update({
    "REAL_CC": real_cc,
    "CC": cc_wrap,
    "PION_CACHE_DIR": cas_dir,
    "P91_PROC_ROLE": "good",
    "P91_A_READY_FIFO": ready_fifo,
    "P91_A_GO_FIFO": go_fifo,
    "P91_A_TMP_RECORD": tmp_rec,
})
env_b = os.environ.copy()
env_b.update({
    "REAL_CC": real_cc,
    "CC": cc_wrap,
    "PION_CACHE_DIR": cas_dir,
    "P91_PROC_ROLE": "bad",
    "P91_B_INJECTED_MARKER": b_marker,
})

fa_out = open(a_out, "wb")
fa_err = open(a_err, "wb")
proc_a = subprocess.Popen(
    [pionc, "test", "--jobs", "4", "--json", cs_dir],
    env=env_a, stdout=fa_out, stderr=fa_err, start_new_session=True,
)
proc_b = None
try:
    r, _, _ = select.select([ready_fd], [], [], 10.0)
    assert r, "timed out waiting for Process A to stage lib_a"
    _ = os.read(ready_fd, 64)
    staged_a = open(tmp_rec).read().strip()
    assert os.path.isfile(staged_a) and os.path.getsize(staged_a) > 0, f"missing Process A staged obj: {staged_a}"

    with open(b_out, "wb") as fb:
        proc_b = subprocess.Popen(
            [pionc, "test", "--jobs", "4", "--json", cs_dir],
            env=env_b, stdout=fb, stderr=subprocess.STDOUT, start_new_session=True,
        )
        rc_b = proc_b.wait(timeout=10.0)
    assert rc_b != 0, "Process B (bad) unexpectedly succeeded"
    assert os.path.isfile(b_marker), f"Process B failed before hitting lib_b fault injection: {open(b_out).read()}"

    # Process B's failure cleanup MUST NOT delete Process A's staged object!
    assert os.path.isfile(staged_a) and os.path.getsize(staged_a) > 0, (
        f"Process B cleanup clobbered Process A staged obj {staged_a}!"
    )

    os.write(go_fd, b"go\n")
    rc_a = proc_a.wait(timeout=15.0)
    assert rc_a == 0, f"Process A failed rc={rc_a}: {open(a_err).read()}"
    d = json.load(open(a_out))
    assert d["ok"] is True and d["total"] == 3 and d["passed"] == 3 and d["failed"] == 0, d
    left = [f for f in os.listdir(os.path.join(cas_dir, "obj")) if f.startswith("cstub_stage") or ".tmp." in f]
    assert len(left) == 0, f"leftover staging dirs after concurrent race: {left}"
finally:
    for p in (proc_a, proc_b):
        if p is not None and p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait()
    for fd in (ready_fd, go_fd):
        try:
            os.close(fd)
        except OSError:
            pass
    fa_out.close()
    fa_err.close()
PYEOF
echo "(f) parallel C stub FIFO overlap + timeout + link order + lstat + no-rm PATH + same-key race -> OK"

echo "PASS: p91_test_runner_cli"
