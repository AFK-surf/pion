#!/bin/sh
# C1000 keep-alive load test of http_event_server: builds the server (--release)
# and bench_c1000.c, starts <workers> event-loop threads on an ephemeral
# 127.0.0.1 port (handed over through a FIFO, no sleeps), keeps <conns>
# keep-alive connections open from <threads> client threads while they send
# <conns> x <reqs> requests, then reports the client JSON (QPS, P50/P99, exact
# /stats check), the server's peak RSS and the stripped binary size.
#
#   sh examples/http_event_server/run_bench.sh <pionc> [conns=1000] [reqs=40] [workers=4] [threads=4]
#
# ASAN=1 links the server against an AddressSanitizer + LeakSanitizer build of
# the runtime (PION_RT_LIB is rebuilt from runtime/pion_rt.c with
# -fsanitize=address) and fails on any ASan/LSan report.
set -eu
PIONC="$1"
CONNS="${2:-1000}"
REQS="${3:-40}"
WORKERS="${4:-4}"
THREADS="${5:-4}"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$HERE/../.." && pwd)"
CC="${CC:-cc}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1,000 sockets per process need more than the common 1024 soft limit.
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
echo "open files limit: $(ulimit -n)"

if [ "${ASAN:-0}" = "1" ]; then
  "$CC" -std=c11 -O1 -g -fno-omit-frame-pointer -fsanitize=address -c "$ROOT/runtime/pion_rt.c" -o "$TMP/pion_rt_asan.o"
  ar rcs "$TMP/libpionrt_asan.a" "$TMP/pion_rt_asan.o"
  printf '#!/bin/sh\nexec %s -fsanitize=address "$@"\n' "$CC" > "$TMP/cc_asan"
  chmod +x "$TMP/cc_asan"
  export PION_RT_LIB="$TMP/libpionrt_asan.a"
  export CC="$TMP/cc_asan"
  export ASAN_OPTIONS="detect_leaks=1:abort_on_error=0:exitcode=23"
fi

T0="$(python3 -c 'import time; print(int(time.time()*1000))')"
"$PIONC" build --release -o "$TMP/http_event_server" "$HERE"
T1="$(python3 -c 'import time; print(int(time.time()*1000))')"
strip -o "$TMP/http_event_server.stripped" "$TMP/http_event_server" 2>/dev/null || cp "$TMP/http_event_server" "$TMP/http_event_server.stripped"
cc -O2 -pthread -o "$TMP/bench_c1000" "$HERE/bench_c1000.c"

TOTAL=$((CONNS * REQS + 1))
mkfifo "$TMP/port.fifo"
# Peak RSS of the server process (ru_maxrss: KiB on Linux, bytes on macOS).
python3 - "$TMP/rss" "$TMP/http_event_server" --port 0 --workers "$WORKERS" --max-reqs "$TOTAL" \
  --port-file "$TMP/port.fifo" > "$TMP/server.out" 2> "$TMP/server.err" <<'PYEOF' &
import resource, subprocess, sys
rc = subprocess.call(sys.argv[2:])
kb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
if sys.platform == "darwin":
    kb //= 1024
open(sys.argv[1], "w").write("%d %d\n" % (rc, kb))
PYEOF
SRV=$!
read PORT < "$TMP/port.fifo"
set +e
"$TMP/bench_c1000" "$PORT" "$CONNS" "$REQS" "$THREADS" > "$TMP/client.json"
CLIENT_RC=$?
set -e
wait "$SRV"
read SRV_RC RSS_KB < "$TMP/rss"
echo "client: $(cat "$TMP/client.json")"
echo "server final stats: $(cat "$TMP/server.out")"
echo "server stderr:"
sed 's/^/  /' "$TMP/server.err" | head -60
echo "server: rc=$SRV_RC workers=$WORKERS peak_rss_kb=$RSS_KB peak_rss_mb=$(python3 -c "print('%.2f' % ($RSS_KB/1024))")"
echo "binary: build_ms=$((T1 - T0)) size=$(wc -c < "$TMP/http_event_server" | tr -d ' ') stripped=$(wc -c < "$TMP/http_event_server.stripped" | tr -d ' ')"
if grep -q 'ERROR: \(AddressSanitizer\|LeakSanitizer\)' "$TMP/server.err"; then
  echo "FAIL: sanitizer report" >&2
  exit 1
fi
if [ "$CLIENT_RC" -ne 0 ] || [ "$SRV_RC" -ne 0 ]; then
  echo "FAIL: http_event_server load test (client rc=$CLIENT_RC, server rc=$SRV_RC)" >&2
  exit 1
fi
echo "PASS: $CONNS concurrent keep-alive connections x $REQS requests on $WORKERS event-loop workers"
