#!/bin/sh
# Server side of std/tls end to end: the pure-Pion HTTPS service
# `examples/https_server` (tls_listen / tls_accept over the system OpenSSL) with
# a throw-away self-signed RSA-2048 certificate whose only name is
# `subjectAltName=DNS:localhost`, trusted by clients through SSL_CERT_FILE.
#
#   1. --self-test: in-process server thread + 4 concurrent pure-Pion clients
#      (tls::https_request, verify on): TLS 1.3 both ways, GET /health,
#      POST /echo JSON round trips, exact /stats counters, 127.0.0.1 refused
#      by verification (the certificate names only localhost).
#   2. --check-config error paths: a key that does not match the certificate
#      and a missing certificate file are refused with OpenSSL's reason.
#   3. Server mode against standard clients: Python `ssl` (TLS 1.3, then a
#      client capped at TLS 1.2, then a wrong-host client that must fail) and,
#      when present, curl (TLS 1.3 and --tls-max 1.2), then POST /quit; the
#      server's final /stats must match the requests made.
#
# The server's ephemeral port arrives through a FIFO (no sleeps).
#
#   [PYTHON=python3] [PION_ASAN_RT=<asan libpionrt.a>] sh std/tls/e2e/run_server_e2e.sh <pionc>
#
# macOS: export CC=cc LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib first (see std/tls).
# PION_ASAN_RT (Linux): additionally build the service against an ASan+LSan
# instrumented runtime and run the self-test under detect_leaks=1.
set -eu
PIONC="$1"
PYTHON="${PYTHON:-python3}"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
SRV_PID=""
cleanup() {
  if [ -n "$SRV_PID" ]; then
    kill "$SRV_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/other_key.pem" 2>/dev/null
"$PIONC" build -o "$TMP/https_server" "$ROOT/examples/https_server"
echo "server binary: $(wc -c < "$TMP/https_server" | tr -d ' ') bytes"

echo "=== [1/3] https_server --self-test (4 concurrent verified pure-Pion clients) ==="
SSL_CERT_FILE="$TMP/cert.pem" "$TMP/https_server" --self-test --cert "$TMP/cert.pem" --key "$TMP/key.pem" \
  --expect-proto TLSv1.3

echo "=== [2/3] --check-config error paths ==="
"$TMP/https_server" --check-config --cert "$TMP/cert.pem" --key "$TMP/key.pem"
expect_refused() {
  WHAT="$1"
  WANT="$2"
  shift 2
  set +e
  ERR="$("$TMP/https_server" --check-config "$@" 2>&1)"
  RC=$?
  set -e
  echo "$WHAT -> rc=$RC: $ERR"
  if [ "$RC" -eq 0 ] || ! printf '%s' "$ERR" | grep -Eq "$WANT"; then
    echo "FAIL: $WHAT was not refused with \"$WANT\"" >&2
    exit 1
  fi
}
# OpenSSL refuses a mismatched key while loading it (`key values mismatch`) or,
# for key types it cannot compare there, in SSL_CTX_check_private_key.
expect_refused "mismatched key" "private key .*(mismatch|does not match)" --cert "$TMP/cert.pem" --key "$TMP/other_key.pem"
expect_refused "missing certificate" "loading certificate chain" --cert "$TMP/missing.pem" --key "$TMP/key.pem"
expect_refused "key as certificate" "loading certificate chain" --cert "$TMP/key.pem" --key "$TMP/key.pem"

echo "=== [3/3] server mode vs standard clients ($("$PYTHON" -c 'import ssl; print(ssl.OPENSSL_VERSION)')) ==="
HAS13="$("$PYTHON" -c 'import ssl; print(1 if ssl.HAS_TLSv1_3 else 0)')"
mkfifo "$TMP/port.fifo"
"$TMP/https_server" --cert "$TMP/cert.pem" --key "$TMP/key.pem" --port-file "$TMP/port.fifo" \
  > "$TMP/server.out" 2> "$TMP/server.err" &
SRV_PID=$!
read PORT < "$TMP/port.fifo"
echo "pion-https on port $PORT"

cat > "$TMP/client.py" <<'PYEOF'
import json, socket, ssl, sys
port, cafile, has13 = int(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"

def call(method, path, body=b"", host="localhost", maxver=None):
    ctx = ssl.create_default_context(cafile=cafile)
    if maxver is not None:
        ctx.maximum_version = maxver
    with socket.create_connection(("127.0.0.1", port)) as raw:
        with ctx.wrap_socket(raw, server_hostname=host) as s:
            s.sendall(("%s %s HTTP/1.1\r\nHost: %s:%d\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                       % (method, path, host, port, len(body))).encode() + body)
            data = b""
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                data += chunk
            head, _, payload = data.partition(b"\r\n\r\n")
            status = int(head.split(b" ")[1])
            return s.version(), status, payload

made = {"health": 0, "echo": 0}
want = "TLSv1.3" if has13 else "TLSv1.2"
ver, st, body = call("GET", "/health")
made["health"] += 1
info = json.loads(body)
assert st == 200 and ver == want and info["protocol"] == want and info["sni"] == "localhost", (ver, st, body)
print("python default client: %s, server saw %s sni=%s" % (ver, info["protocol"], info["sni"]))

ver, st, body = call("GET", "/health", maxver=ssl.TLSVersion.TLSv1_2)
made["health"] += 1
info = json.loads(body)
assert st == 200 and ver == "TLSv1.2" and info["protocol"] == "TLSv1.2", (ver, st, body)
print("python client capped at TLS 1.2: %s, server saw %s" % (ver, info["protocol"]))

payload = json.dumps({"from": "python", "n": 7, "s": "值 🚀"}, ensure_ascii=False, separators=(",", ":")).encode()
ver, st, body = call("POST", "/echo", payload)
made["echo"] += 1
assert st == 200 and json.loads(body) == json.loads(payload), (st, body)
print("python POST /echo: %d, %d bytes round-tripped" % (st, len(body)))

try:
    call("GET", "/health", host="pion-wrong-host.example")
    raise SystemExit("FAIL: wrong host name accepted")
except ssl.SSLCertVerificationError as e:
    print("python wrong host refused: %s" % e.verify_message)
print(json.dumps(made))
PYEOF

set +e
PY_OUT="$("$PYTHON" "$TMP/client.py" "$PORT" "$TMP/cert.pem" "$HAS13")"
PY_RC=$?
set -e
echo "$PY_OUT"
if [ "$PY_RC" -ne 0 ]; then
  echo "FAIL: python client rc=$PY_RC" >&2
  cat "$TMP/server.err" >&2
  exit 1
fi
HEALTH=2
ECHO=1
FAILS=1
if command -v curl >/dev/null 2>&1; then
  for MAX in default 1.2; do
    if [ "$MAX" = default ]; then
      OUT="$(curl -sS --cacert "$TMP/cert.pem" --resolve "localhost:$PORT:127.0.0.1" "https://localhost:$PORT/health")"
    else
      OUT="$(curl -sS --tlsv1.2 --tls-max 1.2 --cacert "$TMP/cert.pem" --resolve "localhost:$PORT:127.0.0.1" "https://localhost:$PORT/health")"
    fi
    echo "curl ($MAX): $OUT"
    HEALTH=$((HEALTH + 1))
    case "$OUT" in
      *'"ok":true'*) ;;
      *) echo "FAIL: curl ($MAX) got $OUT" >&2; exit 1 ;;
    esac
    if [ "$MAX" = 1.2 ] && ! printf '%s' "$OUT" | grep -q '"protocol":"TLSv1.2"'; then
      echo "FAIL: curl --tls-max 1.2 did not negotiate TLS 1.2" >&2
      exit 1
    fi
  done
else
  echo "NOTE: curl not found; Python is the only external client"
fi

QUIT="$("$PYTHON" -c '
import socket, ssl, sys
ctx = ssl.create_default_context(cafile=sys.argv[2])
with ctx.wrap_socket(socket.create_connection(("127.0.0.1", int(sys.argv[1]))), server_hostname="localhost") as s:
    s.sendall(b"POST /quit HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    data = b""
    while True:
        c = s.recv(4096)
        if not c:
            break
        data += c
print(data.split(b"\r\n\r\n", 1)[1].decode())
' "$PORT" "$TMP/cert.pem")"
echo "POST /quit -> $QUIT"
set +e
wait "$SRV_PID"
SRV_RC=$?
set -e
SRV_PID=""
STATS="$(cat "$TMP/server.out")"
echo "server stderr:"
sed 's/^/  /' "$TMP/server.err"
echo "server final stats: $STATS"
WANT_STATS="{\"total\":$((HEALTH + ECHO + 1)),\"health\":$HEALTH,\"echo\":$ECHO,\"stats\":0,\"bad\":0,\"handshake_failures\":$FAILS}"
if [ "$SRV_RC" -ne 0 ] || [ "$STATS" != "$WANT_STATS" ]; then
  echo "FAIL: server rc=$SRV_RC stats=$STATS (want $WANT_STATS)" >&2
  exit 1
fi

if [ -n "${PION_ASAN_RT:-}" ]; then
  echo "=== [asan] https_server --self-test against an ASan+LSan runtime ==="
  printf '#!/bin/sh\nexec %s -fsanitize=address "$@"\n' "${CC:-cc}" > "$TMP/cc-asan"
  chmod +x "$TMP/cc-asan"
  CC="$TMP/cc-asan" PION_RT_LIB="$PION_ASAN_RT" PION_CACHE_DIR="$TMP/cas_asan" \
    "$PIONC" build -o "$TMP/https_server_asan" "$ROOT/examples/https_server"
  ASAN_OPTIONS="detect_leaks=1:abort_on_error=0:halt_on_error=1" SSL_CERT_FILE="$TMP/cert.pem" \
    "$TMP/https_server_asan" --self-test --cert "$TMP/cert.pem" --key "$TMP/key.pem"
  echo "[asan] self-test clean under ASan + LSan"
fi
echo "std/tls server e2e PASSED"
