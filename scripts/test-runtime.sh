#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/out"
RT_DIR="$ROOT_DIR/runtime"
CC="${CC:-clang}"

mkdir -p "$OUT_DIR"

echo "=== 1. Build libm2rt.a (-O2 -Wall -Wextra -Werror) ==="
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -c "$RT_DIR/m2_rt.c" -o "$OUT_DIR/m2_rt.o"
rm -f "$OUT_DIR/libm2rt.a"
ar rcs "$OUT_DIR/libm2rt.a" "$OUT_DIR/m2_rt.o"
LIB_SIZE="$(wc -c < "$OUT_DIR/libm2rt.a" | tr -d ' ')"
echo "libm2rt.a size: $LIB_SIZE bytes"
if [ "$LIB_SIZE" -ge 40960 ]; then
    echo "FAIL: libm2rt.a ($LIB_SIZE bytes) exceeds 40 KB budget (40960 bytes)" >&2
    exit 1
fi

echo "=== 2. Run unit + MT + 4-core speedup benchmark (-O2) ==="
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -I"$RT_DIR" \
    "$RT_DIR/test_rt.c" "$OUT_DIR/libm2rt.a" -lpthread -o "$OUT_DIR/test_rt_o2"
"$OUT_DIR/test_rt_o2" --bench

echo "=== 3. Run ThreadSanitizer (-fsanitize=thread) ==="
"$CC" -std=c11 -O1 -g -fsanitize=thread -Wall -Wextra -Werror -I"$RT_DIR" \
    "$RT_DIR/m2_rt.c" "$RT_DIR/test_rt.c" -lpthread -o "$OUT_DIR/test_rt_tsan"
"$OUT_DIR/test_rt_tsan"

echo "=== 4. Run AddressSanitizer (-fsanitize=address) ==="
"$CC" -std=c11 -O1 -g -fsanitize=address -Wall -Wextra -Werror -I"$RT_DIR" \
    "$RT_DIR/m2_rt.c" "$RT_DIR/test_rt.c" -lpthread -o "$OUT_DIR/test_rt_asan"
"$OUT_DIR/test_rt_asan"

echo "=== 5. QBE arm64_apple End-to-End ABI Smoke Test ==="
if [ ! -x "$OUT_DIR/qbe" ]; then
    sh "$ROOT_DIR/scripts/build-qbe.sh" "$OUT_DIR/qbe"
fi

cat > "$OUT_DIR/smoke_qbe.ssa" <<'EOF'
data $hello = { b "hello from qbe+m2rt", b 0 }

function $worker(l %env) {
@start
    %old =l call $m2_atomic_fetch_add(l %env, l 10)
    ret
}

export function w $main(w %argc, l %argv) {
@start
    %w =l call $m2_world_init(w %argc, l %argv)
    %s =l call $m2_str_from_cstr(l $hello, l 19)
    call $m2_world_println(l %w, l %s)

    %atom =l call $m2_atomic_new(l 2)
    %sc =l call $m2_scope_begin()
    call $m2_scope_spawn(l %sc, l $worker, l %atom)
    call $m2_scope_spawn(l %sc, l $worker, l %atom)
    call $m2_scope_spawn(l %sc, l $worker, l %atom)
    call $m2_scope_spawn(l %sc, l $worker, l %atom)
    call $m2_scope_end(l %sc)

    %val =l call $m2_atomic_load(l %atom)
    %num =l call $m2_int_to_str(l %val)
    call $m2_world_println(l %w, l %num)

    call $m2_rc_dec(l %num)
    call $m2_rc_dec(l %atom)
    call $m2_rc_dec(l %s)
    call $m2_rc_dec(l %w)
    ret 0
}
EOF

T0="$(python3 -c 'import time; print(int(time.time()*1000))')"
"$OUT_DIR/qbe" -t arm64_apple -o "$OUT_DIR/smoke_qbe.s" "$OUT_DIR/smoke_qbe.ssa"
as -o "$OUT_DIR/smoke_qbe.o" "$OUT_DIR/smoke_qbe.s"
"$CC" "$OUT_DIR/smoke_qbe.o" "$OUT_DIR/libm2rt.a" -lpthread -o "$OUT_DIR/smoke_qbe"
T1="$(python3 -c 'import time; print(int(time.time()*1000))')"

SMOKE_SIZE="$(wc -c < "$OUT_DIR/smoke_qbe" | tr -d ' ')"
SMOKE_OUT="$("$OUT_DIR/smoke_qbe")"
echo "QBE smoke compile time: $((T1 - T0)) ms, binary size: $SMOKE_SIZE bytes"
echo "QBE smoke output:"
echo "$SMOKE_OUT"

EXPECTED_OUT="$(printf 'hello from qbe+m2rt\n42')"
if [ "$SMOKE_OUT" != "$EXPECTED_OUT" ]; then
    echo "FAIL: QBE smoke output mismatch! Expected:" >&2
    echo "$EXPECTED_OUT" >&2
    exit 1
fi
echo "[PASS] QBE arm64_apple end-to-end ABI smoke test"
