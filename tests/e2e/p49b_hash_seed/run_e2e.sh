#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
PIONC="${PIONC:-$ROOT_DIR/out/pionc2}"
CC="${CC:-cc}"

if [ ! -x "$PIONC" ]; then
    echo "FAIL: pionc binary not found at $PIONC" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/hash_seed.pion" <<'EOF'
pub fn main(w: World) -> Int {
  let m: Map[String, Int] = Map::new()
  let mut i = 0
  while i < 32 {
    m.set("key_" + i.to_string(), i)
    i = i + 1
  }
  let ks = m.keys()
  let sb = StringBuilder::new()
  let mut j = 0
  while j < ks.length() {
    if j > 0 {
      sb.write_string(",")
    }
    sb.write_string(ks[j])
    j = j + 1
  }
  io_println(w, sb.to_string())
  0
}
EOF

PION_CACHE_DIR="$TMP_DIR/cas" "$PIONC" build --release -o "$TMP_DIR/hash_seed" "$TMP_DIR/hash_seed.pion"

# 1. 5 consecutive runs without PION_HASH_SEED -> must observe >= 2 distinct orders
: > "$TMP_DIR/rand_orders.txt"
for _ in 1 2 3 4 5; do
    env -u PION_HASH_SEED "$TMP_DIR/hash_seed" >> "$TMP_DIR/rand_orders.txt"
done
UNIQ_RAND="$(sort -u "$TMP_DIR/rand_orders.txt" | wc -l | tr -d ' ')"
if [ "$UNIQ_RAND" -lt 2 ]; then
    echo "FAIL: expected >= 2 distinct key orders across 5 unseeded runs, got $UNIQ_RAND" >&2
    cat "$TMP_DIR/rand_orders.txt" >&2
    exit 1
fi
echo "p49b_hash_seed random: $UNIQ_RAND/5 distinct key orders (OK)"

# 2. PION_HASH_SEED=42 x 3 runs -> 100% identical
O1="$(PION_HASH_SEED=42 "$TMP_DIR/hash_seed")"
O2="$(PION_HASH_SEED=42 "$TMP_DIR/hash_seed")"
O3="$(PION_HASH_SEED=42 "$TMP_DIR/hash_seed")"
if [ "$O1" != "$O2" ] || [ "$O1" != "$O3" ]; then
    echo "FAIL: PION_HASH_SEED=42 not deterministic!" >&2
    exit 1
fi
echo "p49b_hash_seed deterministic (seed=42): 3/3 identical (OK)"

# 3. PION_HASH_SEED=0 vs PION_HASH_SEED=12345 -> different orders
S0="$(PION_HASH_SEED=0 "$TMP_DIR/hash_seed")"
S1="$(PION_HASH_SEED=12345 "$TMP_DIR/hash_seed")"
if [ "$S0" = "$S1" ]; then
    echo "FAIL: PION_HASH_SEED=0 and PION_HASH_SEED=12345 produced identical key order!" >&2
    exit 1
fi
echo "p49b_hash_seed distinct seeds (0 vs 12345): distinct orders (OK)"

# 4. ASan + TSan concurrent MT Map[String, Int] read/write stress test
cat > "$TMP_DIR/mt_hash_test.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "pion_rt.h"

typedef struct {
    void *mtx;
    int tid;
} WorkerEnv;

static void worker_fn(void *raw) {
    WorkerEnv *env = (WorkerEnv *)raw;
    char buf[32];
    for (int i = 0; i < 200; i++) {
        int n = snprintf(buf, sizeof(buf), "t%d_k%d", env->tid, i);
        void *k = pion_str_from_cstr(buf, n);
        void *m = (void *)(uintptr_t)pion_mutex_lock(env->mtx);
        pion_map_set(m, k, (int64_t)(env->tid * 1000 + i));
        int64_t v = 0;
        int32_t ok = pion_map_try_get(m, k, &v);
        assert(ok == 1 && v == (int64_t)(env->tid * 1000 + i));
        pion_mutex_unlock(env->mtx);
        pion_rc_dec(k);
    }
}

int main(void) {
    void *m = pion_map_new(0);
    void *mtx = pion_mutex_new((int64_t)(uintptr_t)m, 1);
    pion_rc_dec(m);
    void *sc = pion_scope_begin();
    WorkerEnv *envs[4];
    for (int t = 0; t < 4; t++) {
        envs[t] = (WorkerEnv *)pion_alloc((uint32_t)sizeof(WorkerEnv), PION_TAG_STRUCT, NULL);
        envs[t]->mtx = mtx;
        envs[t]->tid = t;
        pion_scope_spawn(sc, worker_fn, envs[t]);
    }
    pion_scope_end(sc);
    for (int t = 0; t < 4; t++) {
        pion_rc_dec(envs[t]);
    }
    void *m_final = (void *)(uintptr_t)pion_mutex_lock(mtx);
    assert(pion_map_len(m_final) == 800);
    pion_mutex_unlock(mtx);
    pion_rc_dec(mtx);
    printf("mt_hash_test ok (4 threads x 200 keys = 800)\n");
    return 0;
}
EOF

CC="$CC" sh "$ROOT_DIR/scripts/san-rt.sh" address "$TMP_DIR/libpionrt_asan.a"
"$CC" -std=c11 -O1 -g -fsanitize=address -Wall -Wextra -Werror -I"$ROOT_DIR/runtime" \
    "$TMP_DIR/mt_hash_test.c" "$TMP_DIR/libpionrt_asan.a" -lm -lpthread -o "$TMP_DIR/mt_hash_asan"
"$TMP_DIR/mt_hash_asan"

CC="$CC" sh "$ROOT_DIR/scripts/san-rt.sh" thread "$TMP_DIR/libpionrt_tsan.a"
"$CC" -std=c11 -O1 -g -fsanitize=thread -Wall -Wextra -Werror -I"$ROOT_DIR/runtime" \
    "$TMP_DIR/mt_hash_test.c" "$TMP_DIR/libpionrt_tsan.a" -lm -lpthread -o "$TMP_DIR/mt_hash_tsan"
"$TMP_DIR/mt_hash_tsan"

echo "PASS: p49b_hash_seed"
