#!/bin/sh
# Real TLS 1.3 and TLS 1.2 handshakes of std/tls against a local Python
# `ssl.SSLContext` HTTPS server with a throw-away self-signed `localhost`
# certificate. The server prints its ephemeral port as its first line into a
# pipe the client side reads (no sleeps; a server that dies early ends the pipe
# and fails the run). The client trusts the certificate through SSL_CERT_FILE.
#
#   [PYTHON=python3] [TLS_VERSIONS="1.3 1.2"] sh std/tls/e2e/run_e2e.sh <pionc>
#
# TLS_VERSIONS lists the server's maximum protocol per round; a server Python
# whose ssl module lacks TLS 1.3 (macOS /usr/bin/python3 uses LibreSSL 2.8)
# can only run the 1.2 round.
# macOS: export CC=cc LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib first (see std/tls).
set -eu
PIONC="$1"
PYTHON="${PYTHON:-python3}"
TLS_VERSIONS="${TLS_VERSIONS:-1.3 1.2}"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj /CN=localhost -addext subjectAltName=DNS:localhost \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
"$PIONC" build -o "$TMP/tls_e2e" "$HERE"

cat > "$TMP/server.py" <<'PYEOF'
import json, socket, ssl, sys
cert, key, maxver, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
if maxver == "1.2":
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
seen = {"sni": ""}
def on_sni(sslobj, name, c):
    seen["sni"] = name or ""
ctx.sni_callback = on_sni
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(8)
# Only a failure path waits this long: a client that died early sends no more
# connections, and the server must not block the run forever.
srv.settimeout(60)
print(srv.getsockname()[1], flush=True)
handshake_failures = 0
for _ in range(count):
    try:
        raw, _ = srv.accept()
    except socket.timeout:
        print("server: no further client connection", flush=True)
        sys.exit(1)
    raw.settimeout(None)
    seen["sni"] = ""
    try:
        s = ctx.wrap_socket(raw, server_side=True)
    except (ssl.SSLError, OSError) as e:
        handshake_failures += 1
        print("server: handshake refused by client: %s" % e, flush=True)
        raw.close()
        continue
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    method, path, _ = lines[0].split(" ")
    clen = 0
    for ln in lines[1:]:
        k, _, v = ln.partition(":")
        if k.strip().lower() == "content-length":
            clen = int(v.strip())
    while len(body) < clen:
        body += s.recv(65536)
    if path == "/echo" and method == "POST":
        out = body
    else:
        out = json.dumps({"version": s.version(), "sni": seen["sni"], "cipher": s.cipher()[0]}).encode()
    s.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(out) + out)
    try:
        s.unwrap()
    except (ssl.SSLError, OSError):
        pass
    s.close()
print("server: done, handshake_failures=%d" % handshake_failures, flush=True)
sys.exit(0 if handshake_failures == 1 else 1)
PYEOF

echo "server: $("$PYTHON" -c 'import ssl; print(ssl.OPENSSL_VERSION)')"
for VER in $TLS_VERSIONS; do
  echo "=== std/tls e2e: server max TLS $VER ==="
  rm -f "$TMP/server.rc" "$TMP/client.rc"
  { "$PYTHON" "$TMP/server.py" "$TMP/cert.pem" "$TMP/key.pem" "$VER" 4; echo $? > "$TMP/server.rc"; } | {
    if read PORT && [ -n "$PORT" ]; then
      set +e
      SSL_CERT_FILE="$TMP/cert.pem" "$TMP/tls_e2e" "$PORT" "TLSv$VER"
      echo $? > "$TMP/client.rc"
      set -e
    else
      echo "FAIL: server did not report a port" >&2
    fi
    cat
  }
  SRV_RC="$(cat "$TMP/server.rc" 2>/dev/null || echo missing)"
  CLI_RC="$(cat "$TMP/client.rc" 2>/dev/null || echo missing)"
  if [ "$SRV_RC" != 0 ] || [ "$CLI_RC" != 0 ]; then
    echo "FAIL: std/tls e2e against TLS $VER server (client rc=$CLI_RC, server rc=$SRV_RC)" >&2
    exit 1
  fi
done
echo "std/tls e2e PASSED (server max TLS: $TLS_VERSIONS)"
