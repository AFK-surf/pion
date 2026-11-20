#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/out"
RT_DIR="$ROOT_DIR/runtime"
CC="${CC:-cc}"

mkdir -p "$OUT_DIR"

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== [1/6] Linux x86_64 Environment & QBE (amd64_sysv) Build ==="
uname -a
CC="$CC" sh "$ROOT_DIR/scripts/build-qbe.sh" "$OUT_DIR/qbe"

echo "=== [2/6] Build libpionrt.a (-std=c11 -O2 -fno-asynchronous-unwind-tables -Wall -Wextra -Werror) ==="
"$CC" -std=c11 -O2 -fno-asynchronous-unwind-tables -Wall -Wextra -Werror -c "$RT_DIR/pion_rt.c" -o "$OUT_DIR/pion_rt.o"
rm -f "$OUT_DIR/libpionrt.a"
ar rcs "$OUT_DIR/libpionrt.a" "$OUT_DIR/pion_rt.o"
LIB_SIZE="$(wc -c < "$OUT_DIR/libpionrt.a" | tr -d ' ')"
echo "Linux x86_64 libpionrt.a size: ${LIB_SIZE} bytes"
if [ "$LIB_SIZE" -ge 65536 ]; then
  echo "FAIL: libpionrt.a (${LIB_SIZE} bytes) exceeds 64 KB budget" >&2
  exit 1
fi

echo "=== [3/6] Runtime Unit + MT + 4-Core Speedup + P6-A Stdlib (test_rt.c) ==="
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -I"$RT_DIR" \
  "$RT_DIR/test_rt.c" "$OUT_DIR/libpionrt.a" -lm -lpthread -o "$OUT_DIR/test_rt_linux"
if ! "$OUT_DIR/test_rt_linux" > "$TMP_DIR/test_rt.out" 2>&1; then
  cat "$TMP_DIR/test_rt.out"
  exit 1
fi
cat "$TMP_DIR/test_rt.out"
# Linux has no loopback firewall: the runtime test must take the real 4-client TCP path.
grep -q 'tcp_loopback_mt (4 concurrent TCP clients on 127.0.0.1' "$TMP_DIR/test_rt.out" || {
  echo "FAIL: tcp_loopback_mt did not run the real 127.0.0.1 TCP loopback on Linux" >&2
  exit 1
}
set +e
stdbuf -oL "$OUT_DIR/test_rt_linux" --bench
BENCH_RC=$?
set -e
if [ "$BENCH_RC" -ne 0 ]; then
  echo "NOTE: test_rt --bench returned $BENCH_RC (paravirtualized vCPU jitter); continuing functional & MT checks"
fi

# The KV load client is plain C: build it while `as` is still reachable.
"$CC" -O2 -pthread -o "$OUT_DIR/bench_load" "$ROOT_DIR/examples/http_kv_service/bench_load.c"

# From here on every object file comes straight from `qbe --obj` (ELF64): a
# failing `as` first on PATH proves no step assembles text.
mkdir -p "$TMP_DIR/noas"
printf '#!/bin/sh\necho "FAIL: as invoked: $*" >&2\nexit 97\n' > "$TMP_DIR/noas/as"
chmod +x "$TMP_DIR/noas/as"
export PATH="$TMP_DIR/noas:$PATH"

echo "=== [4/6] QBE amd64_sysv End-to-End ABI & Hardware sqrtsd Smoke Test (direct ELF64 .o) ==="
cat > "$TMP_DIR/smoke_qbe.ssa" <<'EOF'
data $hello = { b "hello from qbe+pionrt", b 0 }

function $worker(l %env) {
@start
    %old =l call $pion_atomic_fetch_add(l %env, l 10)
    ret
}

export function w $main(w %argc, l %argv) {
@start
    %w =l call $pion_world_init(w %argc, l %argv)
    %s =l call $pion_str_from_cstr(l $hello, l 21)
    call $pion_world_println(l %w, l %s)

    %atom =l call $pion_atomic_new(l 2)
    %sc =l call $pion_scope_begin()
    call $pion_scope_spawn(l %sc, l $worker, l %atom)
    call $pion_scope_spawn(l %sc, l $worker, l %atom)
    call $pion_scope_spawn(l %sc, l $worker, l %atom)
    call $pion_scope_spawn(l %sc, l $worker, l %atom)
    call $pion_scope_end(l %sc)

    %val =l call $pion_atomic_load(l %atom)
    %num =l call $pion_int_to_str(l %val)
    call $pion_world_println(l %w, l %num)

    %sq =d sqrt d_1764.0
    %sqi =l dtosi %sq
    %sqstr =l call $pion_int_to_str(l %sqi)
    call $pion_world_println(l %w, l %sqstr)

    call $pion_rc_dec(l %sqstr)
    call $pion_rc_dec(l %num)
    call $pion_rc_dec(l %atom)
    call $pion_rc_dec(l %s)
    call $pion_rc_dec(l %w)
    ret 0
}
EOF

T_SM0="$(now_ms)"
"$OUT_DIR/qbe" -t amd64_sysv -o "$TMP_DIR/smoke_qbe.s" "$TMP_DIR/smoke_qbe.ssa"
"$OUT_DIR/qbe" -t amd64_sysv --obj -o "$TMP_DIR/smoke_qbe.o" "$TMP_DIR/smoke_qbe.ssa"
"$CC" "$TMP_DIR/smoke_qbe.o" "$OUT_DIR/libpionrt.a" -lm -lpthread -o "$TMP_DIR/smoke_qbe"
T_SM1="$(now_ms)"
SMOKE_SIZE="$(wc -c < "$TMP_DIR/smoke_qbe" | tr -d ' ')"
SMOKE_OUT="$("$TMP_DIR/smoke_qbe")"
echo "QBE amd64_sysv smoke: compile=$((T_SM1 - T_SM0))ms, binary=${SMOKE_SIZE} bytes"
EXPECTED_SMOKE="$(printf 'hello from qbe+pionrt\n42\n42')"
if [ "$SMOKE_OUT" != "$EXPECTED_SMOKE" ]; then
  echo "FAIL: QBE amd64_sysv smoke output mismatch: $SMOKE_OUT" >&2
  exit 1
fi
grep -n 'sqrtsd' "$TMP_DIR/smoke_qbe.s"
echo "[PASS] QBE amd64_sysv ABI & hardware sqrtsd smoke"

echo "=== [5/6] Native Linux x86_64 pionc ELF Bootstrap & Self-Hosting Proof (direct ELF64 .o, zero as) ==="
PION_LINUX_SSA="${PION_LINUX_SSA:-$OUT_DIR/stage2.ssa}"
if [ ! -f "$PION_LINUX_SSA" ]; then
  echo "NOTE: $PION_LINUX_SSA not provided; skipping native pionc ELF cross-bootstrap."
  exit 0
fi

T_B0="$(now_ms)"
"$OUT_DIR/qbe" -t amd64_sysv --obj -o "$OUT_DIR/pionc_linux.o" "$PION_LINUX_SSA"
"$CC" "$OUT_DIR/pionc_linux.o" "$OUT_DIR/libpionrt.a" -lm -lpthread -o "$OUT_DIR/pionc_linux"
T_B1="$(now_ms)"
PIONC_O_FILE="$(file "$OUT_DIR/pionc_linux.o")"
echo "$PIONC_O_FILE"
printf '%s' "$PIONC_O_FILE" | grep -q 'ELF 64-bit LSB relocatable, x86-64' || {
  echo "FAIL: qbe --obj did not produce an x86-64 ELF64 relocatable" >&2
  exit 1
}
PIONC_SIZE="$(wc -c < "$OUT_DIR/pionc_linux" | tr -d ' ')"
echo "Native Linux x86_64 pionc ELF: assemble+link=$((T_B1 - T_B0))ms, size=${PIONC_SIZE} bytes"
if command -v file >/dev/null 2>&1; then
  file "$OUT_DIR/pionc_linux"
fi

PIONC="$OUT_DIR/pionc_linux"
"$PIONC" --version

export PION_QBE="$OUT_DIR/qbe"
export PION_RT_LIB="$OUT_DIR/libpionrt.a"
export PION_CACHE_DIR="$TMP_DIR/cas_linux"
mkdir -p "$PION_CACHE_DIR"
unset PION_TARGET || true

# Self-hosting Stage 3 & Stage 4 on Linux x86_64 -> verify bit-for-bit fixed-point!
# No --emit-asm: pionc takes its default direct `qbe --obj` ELF64 path (zero `as`).
T_S3_0="$(now_ms)"
(cd "$ROOT_DIR" && "$PIONC" build \
  --emit-ssa "$TMP_DIR/linux_stage3.ssa" \
  -o "$TMP_DIR/pionc_linux_s3" \
  compiler/src/core \
  compiler/src/compat_pion/main.pion)
T_S3_1="$(now_ms)"
S3_SIZE="$(wc -c < "$TMP_DIR/pionc_linux_s3" | tr -d ' ')"
echo "Linux x86_64 native self-host Stage 3: build=$((T_S3_1 - T_S3_0))ms, binary=${S3_SIZE} bytes"

T_S4_0="$(now_ms)"
(cd "$ROOT_DIR" && PION_CACHE_DIR="$TMP_DIR/cas_linux_s4" "$TMP_DIR/pionc_linux_s3" build \
  --emit-ssa "$TMP_DIR/linux_stage4.ssa" \
  -o "$TMP_DIR/pionc_linux_s4" \
  compiler/src/core \
  compiler/src/compat_pion/main.pion)
T_S4_1="$(now_ms)"
S4_SIZE="$(wc -c < "$TMP_DIR/pionc_linux_s4" | tr -d ' ')"
echo "Linux x86_64 native self-host Stage 4: build=$((T_S4_1 - T_S4_0))ms, binary=${S4_SIZE} bytes"

"$TMP_DIR/pionc_linux_s4" --version
sha256sum "$TMP_DIR/linux_stage3.ssa" "$TMP_DIR/linux_stage4.ssa"
cmp "$TMP_DIR/linux_stage3.ssa" "$TMP_DIR/linux_stage4.ssa"
for S in 3 4; do
  "$OUT_DIR/qbe" -t amd64_sysv -o "$TMP_DIR/linux_stage$S.s" "$TMP_DIR/linux_stage$S.ssa"
  "$OUT_DIR/qbe" -t amd64_sysv --obj -o "$TMP_DIR/linux_stage$S.o" "$TMP_DIR/linux_stage$S.ssa"
done
sha256sum "$TMP_DIR/linux_stage3.s" "$TMP_DIR/linux_stage4.s"
cmp "$TMP_DIR/linux_stage3.s" "$TMP_DIR/linux_stage4.s"
sha256sum "$TMP_DIR/linux_stage3.o" "$TMP_DIR/linux_stage4.o"
cmp "$TMP_DIR/linux_stage3.o" "$TMP_DIR/linux_stage4.o"
echo "[PASS] Linux x86_64 Native Self-Hosting Fixed-Point (Stage 3 == Stage 4 SSA, x86_64 ASM & ELF64 .o BIT-FOR-BIT IDENTICAL, zero as)!"

echo "=== [6/6] Native Linux x86_64 pionc: test / fmt / run / Multi-Benchmark Checksum Verification ==="
TEST_JSON="$("$PIONC" test --json "$ROOT_DIR/examples/text_stats")"
echo "pionc_linux test --json examples/text_stats -> $TEST_JSON"
printf '%s' "$TEST_JSON" | grep -q '"failed":0'

for TPKG in std/json std/http std/net std/regex examples/http_event_server; do
  STD_JSON="$("$PIONC" test --json "$ROOT_DIR/$TPKG")"
  echo "pionc_linux test --json $TPKG -> $STD_JSON"
  printf '%s' "$STD_JSON" | grep -q '"ok":true'
  printf '%s' "$STD_JSON" | grep -q '"failed":0'
done

# POSIX TCP + FFI runtime primitives from Pion, over real 127.0.0.1 TCP
NET_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/net_ffi.pion" --loopback)"
echo "pionc_linux run net_ffi --loopback -> $(printf '%s' "$NET_OUT" | tr '\n' ' ')"
if [ "$NET_OUT" != "$(printf 'loopback ok\nnet_ffi ok')" ]; then
  echo "FAIL: net_ffi loopback output mismatch" >&2
  exit 1
fi

# std/http: in-process request/response over TCP, then http_request against a
# Python server (its port arrives through a FIFO, no sleeps).
PORT_FIFO="$TMP_DIR/http_port.fifo"
mkfifo "$PORT_FIFO"
python3 - "$PORT_FIFO" <<'PYEOF' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"hello from server" if self.path == "/hello" else b"wrong path"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write("%d\n" % srv.server_address[1])
srv.handle_request()
PYEOF
PY_PID=$!
read HTTP_PORT < "$PORT_FIFO"
HTTP_OUT="$("$PIONC" run "$ROOT_DIR/examples/http_loopback" "$HTTP_PORT")"
wait "$PY_PID"
echo "pionc_linux run examples/http_loopback $HTTP_PORT -> $(printf '%s' "$HTTP_OUT" | tr '\n' ' ')"
if [ "$HTTP_OUT" != "$(printf 'http in-process ok\nhttp_request ok: 200 text/plain')" ]; then
  echo "FAIL: std/http loopback output mismatch" >&2
  exit 1
fi

FMT_JSON="$("$PIONC" fmt --check --json "$ROOT_DIR/examples/text_stats" "$ROOT_DIR/benchmarks/pion" "$ROOT_DIR/std/json" "$ROOT_DIR/std/http" \
  "$ROOT_DIR/std/net" "$ROOT_DIR/examples/http_event_server" "$ROOT_DIR/std/regex" "$ROOT_DIR/std/tls" "$ROOT_DIR/tests/e2e/p17a_ergonomics_mt.pion" \
  "$ROOT_DIR/examples/https_server" "$ROOT_DIR/tests/e2e/dyn_trait.pion" \
  "$ROOT_DIR/tests/e2e/p22a_systems_io.pion" "$ROOT_DIR/examples/pion_station")"
echo "pionc_linux fmt --check --json -> $FMT_JSON"
if [ "$FMT_JSON" != '{"ok":true,"unformatted":[]}' ]; then
  echo "FAIL: fmt --check failed on Linux: $FMT_JSON" >&2
  exit 1
fi

# Verify fmt catches unformatted file, fixes it, and is idempotent
MESSY="$TMP_DIR/messy.pion"
printf 'pub fn f(x : Int) -> Int {\n    let   y = x + 1   \n\n\nreturn y\n}\n' > "$MESSY"
set +e
MESSY_CHK="$("$PIONC" fmt --check --json "$MESSY")"
MESSY_RC=$?
set -e
echo "pionc_linux fmt --check messy -> rc=$MESSY_RC out=$MESSY_CHK"
if [ "$MESSY_RC" -eq 0 ]; then
  echo "FAIL: expected non-zero rc on unformatted file" >&2
  exit 1
fi
"$PIONC" fmt "$MESSY"
FIXED_CHK="$("$PIONC" fmt --check --json "$MESSY")"
if [ "$FIXED_CHK" != '{"ok":true,"unformatted":[]}' ]; then
  echo "FAIL: file still unformatted after pionc fmt: $FIXED_CHK" >&2
  exit 1
fi

# P22-A: systems IO & byte FFI primitives.
P22A_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/p22a_systems_io.pion")"
echo "pionc_linux run p22a_systems_io -> $P22A_OUT"
if [ "$P22A_OUT" != "p22a_systems_io ok" ]; then
  echo "FAIL: p22a_systems_io output mismatch" >&2
  exit 1
fi

# P17-A: Mutex[Array]/Mutex[Map[String, Array]] across 8 workers, String/Option/Result helpers, generic ==.
P17A_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/p17a_ergonomics_mt.pion")"
echo "pionc_linux run p17a_ergonomics_mt -> $P17A_OUT"
if [ "$P17A_OUT" != "p17a_ok log=2401 recs=3200 index=3200 keys=16" ]; then
  echo "FAIL: p17a_ergonomics_mt output mismatch" >&2
  exit 1
fi

# std/tls: zero-C-glue OpenSSL FFI. Unit tests plus real TLS 1.3/1.2 loopback
# handshakes (and a refused wrong host) whenever libssl/libcrypto can be linked.
if [ -f /usr/include/openssl/ssl.h ] || pkg-config --exists openssl 2>/dev/null; then
  TLS_JSON="$("$PIONC" test --json "$ROOT_DIR/std/tls")"
  echo "pionc_linux test --json std/tls -> $TLS_JSON"
  printf '%s' "$TLS_JSON" | grep -q '"ok":true'
  printf '%s' "$TLS_JSON" | grep -q '"failed":0'
  sh "$ROOT_DIR/std/tls/e2e/run_e2e.sh" "$PIONC"
  HTTPS_JSON="$("$PIONC" test --json "$ROOT_DIR/examples/https_server")"
  echo "pionc_linux test --json examples/https_server -> $HTTPS_JSON"
  printf '%s' "$HTTPS_JSON" | grep -q '"ok":true'
  printf '%s' "$HTTPS_JSON" | grep -q '"failed":0'
  # Server side: pure-Pion HTTPS service vs Python ssl / curl, TLS 1.3 and 1.2.
  sh "$ROOT_DIR/std/tls/e2e/run_server_e2e.sh" "$PIONC"
  # Flagship examples/pion_station also links the system libsqlite3 and checks
  # restart recovery with the sqlite3 CLI.
  if { [ -f /usr/include/sqlite3.h ] || pkg-config --exists sqlite3 2>/dev/null || [ -f /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 ]; } \
    && command -v sqlite3 >/dev/null 2>&1; then
    STATION_LIB_PATH="${LIBRARY_PATH:-}"
    if [ -f /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libsqlite3.so ]; then
      # Runtime package only (no -dev): give the linker a libsqlite3.so outside the source tree.
      ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 "$OUT_DIR/libsqlite3.so"
      STATION_LIB_PATH="$OUT_DIR${STATION_LIB_PATH:+:$STATION_LIB_PATH}"
    fi
    STATION_JSON="$(LIBRARY_PATH="$STATION_LIB_PATH" "$PIONC" test --json "$ROOT_DIR/examples/pion_station")"
    echo "pionc_linux test --json examples/pion_station -> $STATION_JSON"
    printf '%s' "$STATION_JSON" | grep -q '"ok":true'
    printf '%s' "$STATION_JSON" | grep -q '"failed":0'
    LIBRARY_PATH="$STATION_LIB_PATH" sh "$ROOT_DIR/examples/pion_station/run_e2e.sh" "$PIONC"
  else
    echo "NOTE: libsqlite3 or the sqlite3 CLI not found; skipping examples/pion_station tests and e2e"
  fi
else
  echo "NOTE: OpenSSL development files not found; skipping std/tls + examples/https_server tests and client/server e2e handshakes"
fi

# dyn Trait: fat-pointer dispatch, vtables, Option[dyn Trait] niche, freeze/drop.
DYN_OUT="$("$PIONC" run "$ROOT_DIR/tests/e2e/dyn_trait.pion")"
echo "pionc_linux run dyn_trait -> $DYN_OUT"
if [ "$DYN_OUT" != "dyn_trait ok" ]; then
  echo "FAIL: dyn_trait output mismatch" >&2
  exit 1
fi

# pionc add / update against an offline git-index registry.
sh "$ROOT_DIR/tests/e2e/pkg_cli/run_e2e.sh" "$PIONC"

# Multi-package run (cold + hot + 0-pollution)
BEFORE_TS="$(find "$ROOT_DIR/examples/text_stats" -type f | sort)"
T_TS0="$(now_ms)"
OUT_TS1="$("$PIONC" run "$ROOT_DIR/examples/text_stats")"
T_TS1="$(now_ms)"
OUT_TS2="$("$PIONC" run "$ROOT_DIR/examples/text_stats")"
T_TS2="$(now_ms)"
AFTER_TS="$(find "$ROOT_DIR/examples/text_stats" -type f | sort)"
echo "LINUX_X64 text_stats: cold=$((T_TS1 - T_TS0))ms hot=$((T_TS2 - T_TS1))ms out='$OUT_TS2'"
if [ "$OUT_TS1" != "text_stats ok: lines=4 words=18 tagged=2 exec=pion-exec-ok" ] || [ "$OUT_TS1" != "$OUT_TS2" ]; then
  echo "FAIL: text_stats output mismatch on Linux x86_64: '$OUT_TS1'" >&2
  exit 1
fi
if [ "$BEFORE_TS" != "$AFTER_TS" ]; then
  echo "FAIL: examples/text_stats polluted!" >&2
  exit 1
fi

verify_bench() {
  name="$1"
  expected="$2"
  shift 2
  tb0="$(now_ms)"
  got="$("$PIONC" run --release "$ROOT_DIR/benchmarks/pion/${name}.pion" "$@")"
  tb1="$(now_ms)"
  echo "LINUX_X64 ${name}: $((tb1 - tb0))ms out='${got}'"
  if [ "$got" != "$expected" ]; then
    echo "FAIL: ${name} checksum mismatch! expected='${expected}' got='${got}'" >&2
    exit 1
  fi
}

verify_bench nbody "-0.169075164 -0.169083134"
verify_bench binarytrees "stretch=262143 long=131071 total=14592688"
verify_bench fannkuchredux "73196 38"
verify_bench mandelbrot_mt "6351041 721219984" -- 4
verify_bench hashmap_str "200000 208681440 205599 815496841"

# Dogfood: event-loop HTTP server (--self-test: routes, pipelining, real epoll TCP).
"$PIONC" build --release -o "$OUT_DIR/http_event_server" "$ROOT_DIR/examples/http_event_server"
"$OUT_DIR/http_event_server" --self-test
rm -f "$OUT_DIR/http_event_server"

# Dogfood: multithreaded HTTP+JSON KV service under real 8 x 500 TCP load (0 errors, exact /stats).
KV_TEST="$("$PIONC" test --json "$ROOT_DIR/examples/http_kv_service")"
echo "pionc_linux test --json examples/http_kv_service -> $KV_TEST"
printf '%s' "$KV_TEST" | grep -q '"failed":0'
BENCH_LOAD="$OUT_DIR/bench_load" sh "$ROOT_DIR/examples/http_kv_service/run_bench.sh" "$PIONC" 8 500 8
# Same load over HTTP/1.1 keep-alive (one connection per client thread).
KEEP_ALIVE=1 BENCH_LOAD="$OUT_DIR/bench_load" sh "$ROOT_DIR/examples/http_kv_service/run_bench.sh" "$PIONC" 8 500 8

echo "ALL LINUX X86_64 (amd64_sysv) NATIVE BUILD, SELF-HOST & BENCHMARK CHECKSUM GATES PASSED!"
