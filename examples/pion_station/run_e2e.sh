#!/bin/sh
# End-to-end verification & benchmark script for examples/pion_station:
#   1. Release cold build timing + stripped binary size (< 250 KB)
#   2. Incremental single-Handler edit -> `pionc test --json` timing
#   3. --self-test (4 concurrent pure-Pion std/tls clients, 40 jobs, SSE, wrong-host rejection)
#   4. Crash/restart SQLite persistence recovery + cross-check with `sqlite3` CLI (100% row-for-row match)
#   5. Concurrent HTTPS + SQLite + job scheduling load test (4 threads, QPS, P50/P99, 0 errors, Peak RSS < 30 MB)
#
# Usage:
#   sh examples/pion_station/run_e2e.sh <pionc>
set -eu

PIONC="$1"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$HERE/../.." && pwd)"
PYTHON="${PYTHON:-python3}"

now_ms() {
  "$PYTHON" -c 'import time; print(int(time.time()*1000))'
}

TMP="$(mktemp -d)"
SRV1_PID=""
SRV2_PID=""
cleanup() {
  if [ -n "$SRV1_PID" ]; then kill "$SRV1_PID" 2>/dev/null || true; fi
  if [ -n "$SRV2_PID" ]; then kill "$SRV2_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "=== [1/5] Release Cold Build & Stripped Binary Size ==="
COLD_CAS="$TMP/cas_cold"
mkdir -p "$COLD_CAS"
T0="$(now_ms)"
PION_CACHE_DIR="$COLD_CAS" "$PIONC" build --release -o "$TMP/pion_station" "$HERE"
T1="$(now_ms)"
COLD_MS=$((T1 - T0))
cp "$TMP/pion_station" "$TMP/pion_station.stripped"
strip "$TMP/pion_station.stripped" 2>/dev/null || true
RAW_BYTES="$(wc -c < "$TMP/pion_station" | tr -d ' ')"
STRIPPED_BYTES="$(wc -c < "$TMP/pion_station.stripped" | tr -d ' ')"
echo "release cold build: ${COLD_MS} ms | raw=${RAW_BYTES} B | stripped=${STRIPPED_BYTES} B"

echo "=== [2/5] Incremental Single-Handler Body Edit -> pionc test --json ==="
# Work on a temporary copy of pion_station so the source tree is never touched.
INC_ROOT="$TMP/inc_workspace"
mkdir -p "$INC_ROOT/examples" "$INC_ROOT/std"
cp -R "$HERE" "$INC_ROOT/examples/pion_station"
ln -s "$ROOT/std/tls" "$INC_ROOT/std/tls"
ln -s "$ROOT/std/http" "$INC_ROOT/std/http"
ln -s "$ROOT/std/json" "$INC_ROOT/std/json"
ln -s "$ROOT/std/regex" "$INC_ROOT/std/regex"
INC_CAS="$TMP/cas_inc"
mkdir -p "$INC_CAS"
# Warm the incremental cache first
WARM_OUT="$(PION_CACHE_DIR="$INC_CAS" "$PIONC" test --deps --json "$INC_ROOT/examples/pion_station")"
printf '%s' "$WARM_OUT" | grep -q '"ok":true'
printf '%s' "$WARM_OUT" | grep -q '"failed":0'
# Edit one Handler function body (HealthHandler::name in router) -> targeted package incremental test
"$PYTHON" - "$INC_ROOT/examples/pion_station/packages/router/src/router.pion" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
assert '    "health"\n' in s
open(p, "w").write(s.replace('    "health"\n', '    "health_v2"\n', 1))
PYEOF
TR0="$(now_ms)"
INC_ROUTER_OUT="$(PION_CACHE_DIR="$INC_CAS" "$PIONC" test --json --package router "$INC_ROOT/examples/pion_station")"
TR1="$(now_ms)"
INC_ROUTER_MS=$((TR1 - TR0))
echo "incremental handler-edit test (--package router): ${INC_ROUTER_MS} ms -> $INC_ROUTER_OUT"
printf '%s' "$INC_ROUTER_OUT" | grep -q '"ok":true'
printf '%s' "$INC_ROUTER_OUT" | grep -q '"failed":0'

# Edit one Handler function body (StationInfoHandler::name in root) -> full 7-package workspace test
"$PYTHON" - "$INC_ROOT/examples/pion_station/src/worker.pion" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
assert '    "station_info"\n' in s
open(p, "w").write(s.replace('    "station_info"\n', '    "station_info_v2"\n', 1))
PYEOF
TI0="$(now_ms)"
INC_OUT="$(PION_CACHE_DIR="$INC_CAS" "$PIONC" test --deps --json "$INC_ROOT/examples/pion_station")"
TI1="$(now_ms)"
INC_MS=$((TI1 - TI0))
echo "incremental handler-edit test (all 7 workspace pkgs): ${INC_MS} ms -> $INC_OUT"
printf '%s' "$INC_OUT" | grep -q '"ok":true'
printf '%s' "$INC_OUT" | grep -q '"failed":0'

echo "=== [3/5] Self-Signed Cert & --self-test (4 TLS Clients + 40 Jobs + SSE) ==="
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost -addext extendedKeyUsage=serverAuth \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
SSL_CERT_FILE="$TMP/cert.pem" "$TMP/pion_station" --self-test \
  --cert "$TMP/cert.pem" --key "$TMP/key.pem" --db "$TMP/selftest.db" --expect-proto TLSv1.3

echo "=== [4/5] Restart Persistence Recovery & sqlite3 CLI Cross-Check ==="
PERSIST_DB="$TMP/persist.db"
mkfifo "$TMP/port1.fifo"
"$TMP/pion_station" --cert "$TMP/cert.pem" --key "$TMP/key.pem" --db "$PERSIST_DB" \
  --workers 4 --port 0 --port-file "$TMP/port1.fifo" > "$TMP/srv1.out" 2> "$TMP/srv1.err" &
SRV1_PID=$!
read PORT1 < "$TMP/port1.fifo"

"$PYTHON" - "$PORT1" "$TMP/cert.pem" <<'PYEOF'
import concurrent.futures, json, socket, ssl, sys

port, cafile = int(sys.argv[1]), sys.argv[2]

def req(method, path, body=b""):
    ctx = ssl.create_default_context(cafile=cafile)
    with socket.create_connection(("127.0.0.1", port)) as raw:
        with ctx.wrap_socket(raw, server_hostname="localhost") as s:
            hdr = f"{method} {path} HTTP/1.1\r\nHost: localhost:{port}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
            s.sendall(hdr + body)
            data = b""
            while True:
                c = s.recv(65536)
                if not c:
                    break
                data += c
            head, _, payload = data.partition(b"\r\n\r\n")
            st = int(head.split(b" ")[1])
            return st, json.loads(payload.decode())

# Open SSE stream waiting for 12 jobs
sse_events = []
sse_ready = []
def read_sse():
    ctx = ssl.create_default_context(cafile=cafile)
    with socket.create_connection(("127.0.0.1", port)) as raw:
        with ctx.wrap_socket(raw, server_hostname="localhost") as s:
            s.sendall(f"GET /events?limit=12 HTTP/1.1\r\nHost: localhost:{port}\r\nConnection: close\r\n\r\n".encode())
            buf = b""
            while True:
                c = s.recv(4096)
                if not c:
                    break
                buf += c
            return buf.decode()

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
    sse_fut = ex.submit(read_sse)
    for i in range(4):
        st, d = req("POST", "/sessions", json.dumps({"id": f"p-sess-{i}", "title": f"Persist {i}"}).encode())
        assert st == 201, (st, d)
        for m in range(2):
            st, d = req("POST", f"/sessions/p-sess-{i}/messages", json.dumps({"role": "user", "body": f"hello-{i}-{m}"}).encode())
            assert st == 201, (st, d)
    for j in range(12):
        st, d = req("POST", "/jobs", json.dumps({"id": f"p-job-{j}", "session_id": f"p-sess-{j%4}", "kind": "hash", "payload": f"p-{j}"}).encode())
        assert st == 202, (st, d)
    sse_text = sse_fut.result(timeout=15)
    assert sse_text.count("event: job_done") == 12, sse_text

st, stats1 = req("GET", "/stats")
assert st == 200 and stats1["sessions"] == 4 and stats1["messages"] == 8 and stats1["jobs_done"] == 12 and stats1["jobs_total"] == 12, stats1
print("instance 1 stats:", json.dumps(stats1))
st, q = req("POST", "/quit")
assert st == 200 and q.get("quit") is True
PYEOF

wait "$SRV1_PID"
SRV1_PID=""

# Restart instance 2 on the EXACT same SQLite DB file
mkfifo "$TMP/port2.fifo"
"$TMP/pion_station" --cert "$TMP/cert.pem" --key "$TMP/key.pem" --db "$PERSIST_DB" \
  --workers 4 --port 0 --port-file "$TMP/port2.fifo" > "$TMP/srv2.out" 2> "$TMP/srv2.err" &
SRV2_PID=$!
read PORT2 < "$TMP/port2.fifo"

"$PYTHON" - "$PORT2" "$TMP/cert.pem" <<'PYEOF'
import json, socket, ssl, sys

port, cafile = int(sys.argv[1]), sys.argv[2]

def req(method, path, body=b""):
    ctx = ssl.create_default_context(cafile=cafile)
    with socket.create_connection(("127.0.0.1", port)) as raw:
        with ctx.wrap_socket(raw, server_hostname="localhost") as s:
            hdr = f"{method} {path} HTTP/1.1\r\nHost: localhost:{port}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
            s.sendall(hdr + body)
            data = b""
            while True:
                c = s.recv(65536)
                if not c:
                    break
                data += c
            head, _, payload = data.partition(b"\r\n\r\n")
            st = int(head.split(b" ")[1])
            return st, json.loads(payload.decode())

st, stats2 = req("GET", "/stats")
assert st == 200 and stats2["sessions"] == 4 and stats2["messages"] == 8 and stats2["jobs_done"] == 12 and stats2["jobs_total"] == 12, stats2
st, sl = req("GET", "/sessions")
assert st == 200 and sl["count"] == 4, sl
for i in range(4):
    st, ml = req("GET", f"/sessions/p-sess-{i}/messages")
    assert st == 200 and ml["count"] == 2, ml
for j in range(12):
    st, jr = req("GET", f"/jobs/p-job-{j}")
    assert st == 200 and jr["status"] == "done" and len(jr["result"]) == 64, jr
print("instance 2 recovered stats:", json.dumps(stats2))
st, q = req("POST", "/quit")
assert st == 200 and q.get("quit") is True
PYEOF

wait "$SRV2_PID"
SRV2_PID=""

# Cross-check with system sqlite3 CLI
SQL_COUNTS="$(sqlite3 "$PERSIST_DB" "SELECT (SELECT COUNT(*) FROM sessions), (SELECT COUNT(*) FROM messages), (SELECT COUNT(*) FROM jobs WHERE status='done'), (SELECT COUNT(*) FROM jobs);")"
echo "sqlite3 CLI cross-check (sessions|messages|jobs_done|jobs_total): $SQL_COUNTS"
if [ "$SQL_COUNTS" != "4|8|12|12" ]; then
  echo "FAIL: sqlite3 CLI counts mismatch: $SQL_COUNTS (want 4|8|12|12)" >&2
  exit 1
fi

echo "=== [5/5] Concurrent Load Test (4 Clients x HTTPS + SQLite + Jobs, Peak RSS) ==="
LOAD_DB="$TMP/load.db"
mkfifo "$TMP/port_load.fifo"
"$PYTHON" - "$TMP/rss" "$TMP/pion_station" --cert "$TMP/cert.pem" --key "$TMP/key.pem" \
  --db "$LOAD_DB" --workers 4 --port 0 --port-file "$TMP/port_load.fifo" \
  > "$TMP/load_srv.out" 2> "$TMP/load_srv.err" <<'PYEOF' &
import resource, subprocess, sys
rc = subprocess.call(sys.argv[2:])
kb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
if sys.platform == "darwin":
    kb //= 1024
open(sys.argv[1], "w").write("%d %d\n" % (rc, kb))
PYEOF
LOAD_PID=$!
read LOAD_PORT < "$TMP/port_load.fifo"

"$PYTHON" - "$LOAD_PORT" "$TMP/cert.pem" <<'PYEOF'
import concurrent.futures, json, socket, ssl, sys, time

port, cafile = int(sys.argv[1]), sys.argv[2]
THREADS = 4
ROUNDS = 25

def call(ctx, method, path, body=b""):
    t0 = time.perf_counter()
    with socket.create_connection(("127.0.0.1", port)) as raw:
        with ctx.wrap_socket(raw, server_hostname="localhost") as s:
            hdr = f"{method} {path} HTTP/1.1\r\nHost: localhost:{port}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
            s.sendall(hdr + body)
            data = b""
            while True:
                c = s.recv(65536)
                if not c:
                    break
                data += c
            head, _, payload = data.partition(b"\r\n\r\n")
            st = int(head.split(b" ")[1])
            return st, payload, (time.perf_counter() - t0) * 1000.0

def worker(tid):
    ctx = ssl.create_default_context(cafile=cafile)
    lats = []
    errs = 0
    sid = f"load-s-{tid}"
    st, _, ms = call(ctx, "POST", "/sessions", json.dumps({"id": sid, "title": f"Load {tid}"}).encode())
    lats.append(ms)
    if st != 201: errs += 1
    for r in range(ROUNDS):
        st, _, ms = call(ctx, "POST", f"/sessions/{sid}/messages", json.dumps({"role": "user", "body": f"m-{tid}-{r}"}).encode())
        lats.append(ms)
        if st != 201: errs += 1
        st, _, ms = call(ctx, "POST", "/jobs", json.dumps({"id": f"lj-{tid}-{r}", "session_id": sid, "kind": "hash", "payload": f"p-{tid}-{r}"}).encode())
        lats.append(ms)
        if st != 202: errs += 1
        st, _, ms = call(ctx, "GET", f"/sessions/{sid}/messages")
        lats.append(ms)
        if st != 200: errs += 1
    return lats, errs

t_start = time.perf_counter()
all_lats = []
total_errs = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=THREADS) as ex:
    futs = [ex.submit(worker, t) for t in range(THREADS)]
    for f in futs:
        l, e = f.result()
        all_lats.extend(l)
        total_errs += e
elapsed = time.perf_counter() - t_start

ctx = ssl.create_default_context(cafile=cafile)
st, qbody, _ = call(ctx, "POST", "/quit")
assert st == 200, (st, qbody)

all_lats.sort()
n = len(all_lats)
p50 = all_lats[n // 2]
p99 = all_lats[min(n - 1, int(n * 0.99))]
qps = n / elapsed
print(f"load: reqs={n} errs={total_errs} elapsed={elapsed:.3f}s qps={qps:.1f} p50={p50:.2f}ms p99={p99:.2f}ms")
assert total_errs == 0, f"errors={total_errs}"
PYEOF

wait "$LOAD_PID"
read LOAD_RC RSS_KB < "$TMP/rss"
RSS_MB="$("$PYTHON" -c "print('%.2f' % ($RSS_KB / 1024.0))")"
echo "load server final stats: $(cat "$TMP/load_srv.out")"
echo "load server: rc=$LOAD_RC peak_rss_kb=$RSS_KB peak_rss_mb=${RSS_MB} MB"
if [ "$LOAD_RC" -ne 0 ]; then
  cat "$TMP/load_srv.err" >&2
  exit 1
fi
echo "ALL PION_STATION E2E CHECKS PASSED!"
