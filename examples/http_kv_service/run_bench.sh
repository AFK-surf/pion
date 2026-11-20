#!/bin/sh
# Real-TCP load test of http_kv_service: builds the service (--release) and
# bench_load.c, starts the server on an ephemeral 127.0.0.1 port (handed over
# through a FIFO, no sleeps), runs <conns> x <reqs> requests, then reports the
# client JSON plus the server's peak RSS and stripped binary size.
#
#   [BENCH_LOAD=<prebuilt client>] sh examples/http_kv_service/run_bench.sh <pionc> [conns=8] [reqs=500] [workers=8]
set -eu
PIONC="$1"
CONNS="${2:-8}"
REQS="${3:-500}"
WORKERS="${4:-8}"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CC="${CC:-cc}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

T0="$(python3 -c 'import time; print(int(time.time()*1000))')"
"$PIONC" build --release -o "$TMP/http_kv_service" "$HERE"
T1="$(python3 -c 'import time; print(int(time.time()*1000))')"
strip -o "$TMP/http_kv_service.stripped" "$TMP/http_kv_service" 2>/dev/null || cp "$TMP/http_kv_service" "$TMP/http_kv_service.stripped"
# BENCH_LOAD: a prebuilt client (e.g. built before `as` is masked off PATH).
if [ -n "${BENCH_LOAD:-}" ]; then
  cp "$BENCH_LOAD" "$TMP/bench_load"
else
  "$CC" -O2 -pthread -o "$TMP/bench_load" "$HERE/bench_load.c"
fi

TOTAL=$((CONNS * REQS + 1))
mkfifo "$TMP/port.fifo"
# Peak RSS of the server process (ru_maxrss: KiB on Linux, bytes on macOS).
python3 - "$TMP/rss" "$TMP/http_kv_service" --port 0 --workers "$WORKERS" --max-reqs "$TOTAL" \
  --port-file "$TMP/port.fifo" > "$TMP/server.out" <<'PYEOF' &
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
"$TMP/bench_load" "$PORT" "$CONNS" "$REQS" > "$TMP/client.json"
CLIENT_RC=$?
set -e
wait "$SRV"
read SRV_RC RSS_KB < "$TMP/rss"
echo "client: $(cat "$TMP/client.json")"
echo "server final stats: $(cat "$TMP/server.out")"
echo "server: rc=$SRV_RC peak_rss_kb=$RSS_KB peak_rss_mb=$(python3 -c "print('%.2f' % ($RSS_KB/1024))")"
echo "binary: build_ms=$((T1 - T0)) size=$(wc -c < "$TMP/http_kv_service" | tr -d ' ') stripped=$(wc -c < "$TMP/http_kv_service.stripped" | tr -d ' ')"
if [ "$CLIENT_RC" -ne 0 ] || [ "$SRV_RC" -ne 0 ]; then
  echo "FAIL: http_kv_service load test (client rc=$CLIENT_RC, server rc=$SRV_RC)" >&2
  exit 1
fi
