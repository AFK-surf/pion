#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/out"
RT_DIR="$ROOT_DIR/runtime"
CC="${CC:-clang}"

mkdir -p "$OUT_DIR"

echo "=== 1. Build libpionrt.a (-O2 -fno-asynchronous-unwind-tables -Wall -Wextra -Werror) ==="
"$CC" -std=c11 -O2 -fno-asynchronous-unwind-tables -Wall -Wextra -Werror -c "$RT_DIR/pion_rt.c" -o "$OUT_DIR/pion_rt.o"
if command -v strip >/dev/null 2>&1; then
    if [ "$(uname -s)" = "Darwin" ]; then
        strip -x "$OUT_DIR/pion_rt.o"
    else
        strip --strip-unneeded "$OUT_DIR/pion_rt.o"
    fi
fi
rm -f "$OUT_DIR/libpionrt.a"
ar rcs "$OUT_DIR/libpionrt.a" "$OUT_DIR/pion_rt.o"
LIB_SIZE="$(wc -c < "$OUT_DIR/libpionrt.a" | tr -d ' ')"
echo "libpionrt.a size: $LIB_SIZE bytes"
if [ "$LIB_SIZE" -ge 65536 ]; then
    echo "FAIL: libpionrt.a ($LIB_SIZE bytes) exceeds 64 KB budget (65536 bytes)" >&2
    exit 1
fi
"$CC" -std=c11 -O2 -fno-asynchronous-unwind-tables -Wall -Wextra -Werror -c "$RT_DIR/pion_cli.c" -o "$OUT_DIR/pion_cli.o"
rm -f "$OUT_DIR/libpionrt_cli.a"
ar rcs "$OUT_DIR/libpionrt_cli.a" "$OUT_DIR/pion_rt.o" "$OUT_DIR/pion_cli.o"

echo "=== 2. Run unit + MT + 4-core speedup benchmark (-O2) ==="
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -I"$RT_DIR" \
    "$RT_DIR/test_rt.c" "$RT_DIR/pion_cli.c" "$OUT_DIR/libpionrt.a" -lm -lpthread -o "$OUT_DIR/test_rt_o2"
"$OUT_DIR/test_rt_o2" --bench

echo "=== 3. Run ThreadSanitizer (-fsanitize=thread) ==="
"$CC" -std=c11 -O1 -g -fsanitize=thread -Wall -Wextra -Werror -I"$RT_DIR" \
    "$RT_DIR/pion_rt.c" "$RT_DIR/pion_cli.c" "$RT_DIR/test_rt.c" -lm -lpthread -o "$OUT_DIR/test_rt_tsan"
"$OUT_DIR/test_rt_tsan"

echo "=== 4. Run AddressSanitizer (-fsanitize=address) ==="
"$CC" -std=c11 -O1 -g -fsanitize=address -Wall -Wextra -Werror -I"$RT_DIR" \
    "$RT_DIR/pion_rt.c" "$RT_DIR/pion_cli.c" "$RT_DIR/test_rt.c" -lm -lpthread -o "$OUT_DIR/test_rt_asan"
"$OUT_DIR/test_rt_asan"

echo "=== 5. QBE arm64_apple End-to-End ABI Smoke Test ==="
if [ ! -x "$OUT_DIR/qbe" ]; then
    sh "$ROOT_DIR/scripts/build-qbe.sh" "$OUT_DIR/qbe"
fi

cat > "$OUT_DIR/smoke_qbe.ssa" <<'EOF'
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

T0="$(python3 -c 'import time; print(int(time.time()*1000))')"
"$OUT_DIR/qbe" -t arm64_apple -o "$OUT_DIR/smoke_qbe.s" "$OUT_DIR/smoke_qbe.ssa"
as -o "$OUT_DIR/smoke_qbe.o" "$OUT_DIR/smoke_qbe.s"
"$CC" "$OUT_DIR/smoke_qbe.o" "$OUT_DIR/libpionrt.a" -lpthread -o "$OUT_DIR/smoke_qbe"
T1="$(python3 -c 'import time; print(int(time.time()*1000))')"

SMOKE_SIZE="$(wc -c < "$OUT_DIR/smoke_qbe" | tr -d ' ')"
SMOKE_OUT="$("$OUT_DIR/smoke_qbe")"
echo "QBE smoke compile time: $((T1 - T0)) ms, binary size: $SMOKE_SIZE bytes"
echo "QBE smoke output:"
echo "$SMOKE_OUT"

EXPECTED_OUT="$(printf 'hello from qbe+pionrt\n42\n42')"
if [ "$SMOKE_OUT" != "$EXPECTED_OUT" ]; then
    echo "FAIL: QBE smoke output mismatch! Expected:" >&2
    echo "$EXPECTED_OUT" >&2
    exit 1
fi

echo "Checking QBE hardware sqrt emission:"
grep -n 'fsqrt' "$OUT_DIR/smoke_qbe.s" || {
    echo "FAIL: expected hardware fsqrt in arm64_apple assembly" >&2
    exit 1
}
if command -v otool >/dev/null 2>&1; then
    otool -tV "$OUT_DIR/smoke_qbe" | grep 'fsqrt' || {
        echo "FAIL: expected hardware fsqrt in otool disassembly" >&2
        exit 1
    }
fi
"$OUT_DIR/qbe" -t amd64_sysv -o "$OUT_DIR/smoke_qbe_x64.s" "$OUT_DIR/smoke_qbe.ssa"
grep -n 'sqrtsd' "$OUT_DIR/smoke_qbe_x64.s" || {
    echo "FAIL: expected hardware sqrtsd in amd64_sysv assembly" >&2
    exit 1
}
"$OUT_DIR/qbe" -t rv64 -o "$OUT_DIR/smoke_qbe_rv64.s" "$OUT_DIR/smoke_qbe.ssa"
grep -n 'fsqrt\.d' "$OUT_DIR/smoke_qbe_rv64.s" || {
    echo "FAIL: expected hardware fsqrt.d in rv64 assembly" >&2
    exit 1
}
echo "[PASS] QBE arm64_apple/amd64_sysv/rv64 end-to-end ABI & hardware sqrt smoke test"
