#!/bin/sh
# Wave H-1 Track H2 + inline_rc upgrade (P87):
#   1. Single-threaded frozen objects (global array pion_adopt -> pion_rc_freeze):
#      - dev vs release bit-for-bit identical output
#      - release SSA of hot_frozen_loop contains phi-merged shared_rc fast path (-16)
#      - release disassembly of hot_frozen_loop has 0 atomic RMW (lock xadd / ldadd)
#        and retains the inlined fast path (references pion_mt_flag)
#      - ASan + LSan: 0 leaks, 0 UAF, 0 errors
#   2. C FFI extern "C" serial handoff + opaque unfrozen handle + post-handoff scope/spawn:
#      - Thread A (ST, tid=1, mt=0) creates unfrozen Array[Payload] handle and hands to Thread B
#      - Thread B stays ST (tid=1, mt=0), reads unfrozen handle (inc/dec, 0 UAF),
#        then launches Pion scope/spawn on B reading the handle across spawned threads
#      - Verified natively AND under ASan + LSan (0 UAF, 0 leaks)
#   3. Host pion_enter_mt() + 8-thread concurrent FIRST-ENTRY module init (pion_once_call):
#      - No main-thread warmup call! All 8 threads race simultaneously into extern "C"
#        to trigger module-level constant init via pion_once_call
#      - Exact per-seed alloc_sum and read_sum assertions + unique worker TIDs (>= 2)
#      - Verified natively AND under TSan (0 data races)
set -eu

PIONC="${1:?usage: run_e2e.sh <pionc>}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
CAS_DIR="$TMP_DIR/cas"
mkdir -p "$CAS_DIR"
CC_BIN="${CC:-cc}"
# Native runtime for the C hosts below: the gate's archive, or the source itself.
RT_NATIVE="${PION_RT_LIB:-$ROOT_DIR/runtime/pion_rt.c}"
ASAN_RT="$TMP_DIR/libpionrt_asan.a"
TSAN_RT="$TMP_DIR/libpionrt_tsan.a"
HAVE_ASAN=0
HAVE_TSAN=0
if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" address "$ASAN_RT"; then HAVE_ASAN=1; fi
if CC="$CC_BIN" sh "$ROOT_DIR/scripts/san-rt.sh" thread "$TSAN_RT"; then HAVE_TSAN=1; fi

echo "=== P87 [1/3] Single-threaded frozen object RC + disassembly + ASan ==="
cat > "$TMP_DIR/st_frozen.pion" <<'PION'
pub struct Item {
  pub id : Int
  pub label : String
}

let g_cache : Array[Item] = []

fn hot_frozen_loop(n : Int) -> Int {
  let mut acc = 0
  let mut i = 0
  while i < n {
    let it = g_cache[i % 4]
    acc = acc + it.id + it.label.length()
    i = i + 1
  }
  acc
}

fn main(w : World) -> Int {
  g_cache.push(Item::{ id: 10, label: "alpha_" + (1).to_string() })
  g_cache.push(Item::{ id: 20, label: "beta_" + (2).to_string() })
  g_cache.push(Item::{ id: 30, label: "gamma_" + (3).to_string() })
  g_cache.push(Item::{ id: 40, label: "delta_" + (4).to_string() })
  let sum = hot_frozen_loop(1000)
  let extra = match g_cache.pop() {
    Some(tail) => tail.id + tail.label.length()
    None => 0
  }
  g_cache.clear()
  io_println(w, "sum=" + sum.to_string() + " extra=" + extra.to_string())
  0
}
PION

DEV_BIN="$TMP_DIR/st_frozen_dev"
REL_BIN="$TMP_DIR/st_frozen_rel"
REL_SSA="$TMP_DIR/st_frozen_rel.ssa"
REL_OBJ="$TMP_DIR/st_frozen_rel.o"

PION_CACHE_DIR="$CAS_DIR" "$PIONC" build -o "$DEV_BIN" "$TMP_DIR/st_frozen.pion"
PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --release -o "$REL_BIN" --emit-ssa "$REL_SSA" "$TMP_DIR/st_frozen.pion"
PION_CACHE_DIR="$CAS_DIR" "$PIONC" build --release --emit-obj "$REL_OBJ" "$TMP_DIR/st_frozen.pion"

DEV_OUT="$("$DEV_BIN")"
REL_OUT="$("$REL_BIN")"
echo "  dev=$DEV_OUT rel=$REL_OUT"
if [ "$DEV_OUT" != "$REL_OUT" ]; then
  echo "FAIL: dev vs release output mismatch: '$DEV_OUT' vs '$REL_OUT'" >&2
  exit 1
fi
if [ "$DEV_OUT" != "sum=31750 extra=47" ]; then
  echo "FAIL: unexpected output: '$DEV_OUT'" >&2
  exit 1
fi

# Verify hot_frozen_loop function body itself has phi-merged shared_rc (-16) fast path
HOT_SSA="$(awk '/function .*hot_frozen_loop/{f=1} f{print} f && /^}/{exit}' "$REL_SSA")"
if [ -z "$HOT_SSA" ]; then
  echo "FAIL: could not extract hot_frozen_loop from $REL_SSA" >&2
  exit 1
fi
printf '%s\n' "$HOT_SSA" | grep -qE 'phi @_rc[id]_st_' || {
  echo "FAIL: hot_frozen_loop SSA missing phi-merged shared_rc fast path" >&2
  printf '%s\n' "$HOT_SSA" >&2
  exit 1
}
printf '%s\n' "$HOT_SSA" | grep -q 'loaduw \$pion_mt_flag' || {
  echo "FAIL: hot_frozen_loop SSA missing inlined pion_mt_flag check" >&2
  exit 1
}

# Verify disassembly of hot_frozen_loop has ZERO atomic RMW instructions and has inlined fast path
if command -v objdump >/dev/null 2>&1; then
  DISASM="$(objdump -d -r "$REL_OBJ" | awk '/<.*hot_frozen_loop>:/{f=1;next} /^$/{if(f)exit} f{print}')"
  if [ -z "$DISASM" ]; then
    echo "FAIL: could not extract hot_frozen_loop disassembly from $REL_OBJ" >&2
    exit 1
  fi
  if printf '%s\n' "$DISASM" | grep -qiE 'lock[[:space:]]+xadd|ldadd|casal'; then
    echo "FAIL: hot_frozen_loop contains atomic RMW in single-threaded release build!" >&2
    printf '%s\n' "$DISASM" >&2
    exit 1
  fi
  if ! printf '%s\n' "$DISASM" | grep -q 'pion_mt_flag'; then
    echo "FAIL: hot_frozen_loop disassembly missing inlined pion_mt_flag fast path!" >&2
    printf '%s\n' "$DISASM" >&2
    exit 1
  fi
  echo "  disasm hot_frozen_loop: 0 atomic RMW instructions + inlined pion_mt_flag fast path (OK)"
fi

# ASan + LSan check on single-threaded frozen object lifecycle
ASAN_OBJ="$TMP_DIR/st_frozen_asan.o"
PION_CACHE_DIR="$CAS_DIR/asan" "$PIONC" build --release --emit-obj "$ASAN_OBJ" "$TMP_DIR/st_frozen.pion"
if [ "$HAVE_ASAN" = 1 ] && "$CC_BIN" -O1 -g -fsanitize=address -fno-omit-frame-pointer \
    -I"$ROOT_DIR/runtime" "$ASAN_OBJ" "$ASAN_RT" -lm -lpthread \
    -o "$TMP_DIR/st_frozen_asan" 2>/dev/null; then
  ASAN_OUT="$("$TMP_DIR/st_frozen_asan")"
  if [ "$ASAN_OUT" != "$REL_OUT" ]; then
    echo "FAIL: ASan output mismatch: '$ASAN_OUT'" >&2
    exit 1
  fi
  echo "  ASan+LSan st_frozen: OK"
else
  echo "  NOTE: ASan unavailable on this toolchain; skipped"
fi

echo "=== P87 [2/3] C FFI serial handoff (A->B->A) + opaque unfrozen handle + scope/spawn (ASan) ==="
cat > "$TMP_DIR/ffi_handoff.pion" <<'PION'
pub struct Payload {
  pub tag : Int
  pub text : String
}

let g_const_items : Array[Payload] = [
  Payload::{ tag: 11, text: "one_1" },
  Payload::{ tag: 22, text: "two_2" },
  Payload::{ tag: 33, text: "three_3" },
  Payload::{ tag: 44, text: "four_4" },
]

pub extern "C" fn ffi_create_unfrozen() -> Array[Payload] = "pion_p87_create_unfrozen" {
  let arr : Array[Payload] = []
  arr.push(Payload::{ tag: 100, text: "unfrozen_a_" + (1).to_string() })
  arr.push(Payload::{ tag: 200, text: "unfrozen_b_" + (2).to_string() })
  arr.push(Payload::{ tag: 300, text: "unfrozen_c_" + (3).to_string() })
  arr
}

pub extern "C" fn ffi_read_unfrozen(arr : Array[Payload]) -> Int = "pion_p87_read_unfrozen" {
  let mut acc = 0
  let mut i = 0
  while i < arr.length() {
    let p = arr[i]
    acc = acc + p.tag + p.text.length()
    i = i + 1
  }
  acc
}

pub extern "C" fn ffi_read_const(iters : Int) -> Int = "pion_p87_read_const" {
  let mut sum = 0
  let mut i = 0
  while i < iters {
    let p = g_const_items[i % 4]
    sum = sum + p.tag + p.text.length()
    i = i + 1
  }
  sum
}

pub extern "C" fn ffi_spawn_with_handle(w : World, arr : Array[Payload]) -> Int = "pion_p87_spawn_with_handle" {
  let total = AtomicInt::new(0)
  let p0 = arr[0]
  let p1 = arr[1]
  let p2 = arr[2]
  scope(w, fn(s : Scope) -> Unit {
    let mut k = 0
    while k < 4 {
      spawn(s, fn() -> Unit {
        let local_sum = p0.tag + p0.text.length() + p1.tag + p1.text.length() + p2.tag + p2.text.length()
        let _ = total.fetch_add(local_sum)
      })
      k = k + 1
    }
  })
  total.load()
}
PION

HANDOFF_OBJ="$TMP_DIR/ffi_handoff.o"
HANDOFF_SSA="$TMP_DIR/ffi_handoff.ssa"
PION_CACHE_DIR="$CAS_DIR/handoff" "$PIONC" build --release --no-main --emit-obj "$HANDOFF_OBJ" --emit-ssa "$HANDOFF_SSA" "$TMP_DIR/ffi_handoff.pion"

# Verify native module init uses pion_once_call and does NOT emit pion_ffi_enter
grep -q 'call \$pion_once_call(' "$HANDOFF_SSA" || {
  echo "FAIL: native extern \"C\" module init missing call \$pion_once_call(" >&2
  exit 1
}
if grep -q 'pion_ffi_enter\|pion_main_enter' "$HANDOFF_SSA"; then
  echo "FAIL: removed pion_ffi_enter/pion_main_enter still present in SSA" >&2
  exit 1
fi

cat > "$TMP_DIR/handoff_host.c" <<'EOF'
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "pion_rt.h"

extern void *pion_p87_create_unfrozen(void);
extern int32_t pion_p87_read_unfrozen(void *arr);
extern int32_t pion_p87_read_const(int32_t iters);
extern int32_t pion_p87_spawn_with_handle(void *w, void *arr);

typedef struct {
    void *unfrozen_handle;
    void *world;
    uint64_t tid_before_spawn;
    uint32_t mt_before_spawn;
    int32_t read_unfrozen_sum;
    int32_t read_const_sum;
    int32_t spawn_sum;
    uint32_t mt_after_spawn;
} WorkerBRes;

static void *worker_b(void *arg) {
    WorkerBRes *r = (WorkerBRes *)arg;
    /* Serial handoff A -> B: B stays in ST mode (tid=1, mt=0) and safely inc/decs unfrozen handle */
    r->read_unfrozen_sum = pion_p87_read_unfrozen(r->unfrozen_handle);
    r->read_const_sum = pion_p87_read_const(400);
    r->tid_before_spawn = pion_cur_tid();
    r->mt_before_spawn = pion_mt_flag;

    /* Now B launches scope/spawn using the unfrozen handle -> promotes to MT cleanly (B owns tid=1). */
    r->spawn_sum = pion_p87_spawn_with_handle(r->world, r->unfrozen_handle);
    r->mt_after_spawn = pion_mt_flag;
    /* Per MT contract: before handing an unfrozen handle back to another thread after MT begins, freeze it. */
    pion_rc_freeze(r->unfrozen_handle);
    return NULL;
}

int main(int argc, char **argv) {
    void *w = pion_world_init(argc, argv);

    /* Phase A1: Thread A creates unfrozen handle in ST mode */
    void *handle = pion_p87_create_unfrozen();
    int32_t unf_a1 = pion_p87_read_unfrozen(handle);
    int32_t const_a1 = pion_p87_read_const(400);
    uint64_t tid_a1 = pion_cur_tid();
    if (tid_a1 != 1u || pion_mt_flag != 0u) {
        fprintf(stderr, "FAIL: A1 expected tid=1 mt=0, got tid=%llu mt=%u\n",
                (unsigned long long)tid_a1, pion_mt_flag);
        return 1;
    }

    /* Phase B: serial handoff A -> B (B reads unfrozen handle in ST, then runs scope/spawn) */
    WorkerBRes res_b = {0};
    res_b.unfrozen_handle = handle;
    res_b.world = w;
    pthread_t th;
    if (pthread_create(&th, NULL, worker_b, &res_b) != 0) { perror("pthread_create"); return 1; }
    if (pthread_join(th, NULL) != 0) { perror("pthread_join"); return 1; }

    if (res_b.tid_before_spawn != 1u) {
        fprintf(stderr, "FAIL: serial handoff B expected tid=1, got %llu\n",
                (unsigned long long)res_b.tid_before_spawn);
        return 1;
    }
    if (res_b.mt_before_spawn != 0u) {
        fprintf(stderr, "FAIL: serial handoff B expected mt=0 before spawn, got %u\n",
                res_b.mt_before_spawn);
        return 1;
    }
    if (res_b.read_unfrozen_sum != unf_a1 || res_b.read_const_sum != const_a1) {
        fprintf(stderr, "FAIL: B read mismatch: %d/%d vs %d/%d\n",
                res_b.read_unfrozen_sum, res_b.read_const_sum, unf_a1, const_a1);
        return 1;
    }
    if (res_b.spawn_sum != unf_a1 * 4 || res_b.mt_after_spawn != 1u) {
        fprintf(stderr, "FAIL: B spawn_sum=%d expected=%d mt_after=%u\n",
                res_b.spawn_sum, unf_a1 * 4, res_b.mt_after_spawn);
        return 1;
    }

    /* Phase A2: back to Thread A, release frozen handle & world cleanly */
    int32_t unf_a2 = pion_p87_read_unfrozen(handle);
    if (unf_a2 != unf_a1) {
        fprintf(stderr, "FAIL: A2 unfrozen handle mismatch: %d vs %d\n", unf_a2, unf_a1);
        return 1;
    }
    pion_rc_dec(handle);
    pion_rc_dec(w);

    printf("handoff_ok tid_b=%llu mt_b=%u unf=%d spawn=%d\n",
           (unsigned long long)res_b.tid_before_spawn, res_b.mt_before_spawn,
           unf_a2, res_b.spawn_sum);
    return 0;
}
EOF

"$CC_BIN" -O2 -I"$ROOT_DIR/runtime" "$TMP_DIR/handoff_host.c" "$HANDOFF_OBJ" "$RT_NATIVE" \
    -lm -lpthread -o "$TMP_DIR/handoff_host"
HANDOFF_OUT="$("$TMP_DIR/handoff_host")"
echo "  native: $HANDOFF_OUT"

if [ "$HAVE_ASAN" = 1 ] && "$CC_BIN" -O1 -g -fsanitize=address -fno-omit-frame-pointer \
    -I"$ROOT_DIR/runtime" "$TMP_DIR/handoff_host.c" "$HANDOFF_OBJ" "$ASAN_RT" \
    -lm -lpthread -o "$TMP_DIR/handoff_host_asan" 2>/dev/null; then
  HANDOFF_ASAN_OUT="$("$TMP_DIR/handoff_host_asan")"
  if [ "$HANDOFF_ASAN_OUT" != "$HANDOFF_OUT" ]; then
    echo "FAIL: handoff ASan output mismatch: '$HANDOFF_ASAN_OUT'" >&2
    exit 1
  fi
  echo "  ASan+LSan handoff+unfrozen+spawn: OK"
else
  echo "  NOTE: ASan unavailable on this toolchain; skipped"
fi

echo "=== P87 [3/3] Host pion_enter_mt() + 8-thread concurrent FIRST-ENTRY pion_once_call + TSan ==="
cat > "$TMP_DIR/ffi_mt.pion" <<'PION'
pub struct Payload {
  pub tag : Int
  pub text : String
}

let g_const_items : Array[Payload] = [
  Payload::{ tag: 11, text: "one_" + (1).to_string() },
  Payload::{ tag: 22, text: "two_" + (2).to_string() },
  Payload::{ tag: 33, text: "three_" + (3).to_string() },
  Payload::{ tag: 44, text: "four_" + (4).to_string() },
]

pub extern "C" fn ffi_mt_read(iters : Int) -> Int = "pion_p87_mt_read" {
  let mut sum = 0
  let mut i = 0
  while i < iters {
    let p = g_const_items[i % 4]
    sum = sum + p.tag + p.text.length()
    i = i + 1
  }
  sum
}

pub extern "C" fn ffi_mt_alloc(seed : Int) -> Int = "pion_p87_mt_alloc" {
  let arr : Array[Payload] = []
  let mut i = 0
  while i < 64 {
    arr.push(Payload::{ tag: seed + i, text: "item_" + (seed + i).to_string() })
    i = i + 1
  }
  let mut acc = 0
  i = 0
  while i < arr.length() {
    let p = arr[i]
    acc = acc + p.tag + p.text.length()
    i = i + 1
  }
  acc
}
PION

MT_OBJ="$TMP_DIR/ffi_mt.o"
PION_CACHE_DIR="$CAS_DIR/mt" "$PIONC" build --release --no-main --emit-obj "$MT_OBJ" "$TMP_DIR/ffi_mt.pion"

cat > "$TMP_DIR/mt_stress_host.c" <<'EOF'
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "pion_rt.h"

extern int32_t pion_p87_mt_read(int32_t iters);
extern int32_t pion_p87_mt_alloc(int32_t seed);

#define NTHREADS 8
#define NITERS 400

static pthread_mutex_t g_bar_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_bar_cv = PTHREAD_COND_INITIALIZER;
static int g_bar_count = 0;

static void portable_barrier_wait(void) {
    pthread_mutex_lock(&g_bar_mu);
    g_bar_count++;
    if (g_bar_count >= NTHREADS) {
        pthread_cond_broadcast(&g_bar_cv);
    } else {
        while (g_bar_count < NTHREADS) {
            pthread_cond_wait(&g_bar_cv, &g_bar_mu);
        }
    }
    pthread_mutex_unlock(&g_bar_mu);
}

typedef struct {
    int id;
    uint64_t tid;
    int32_t read_sum;
    int32_t alloc_sum;
} StressArg;

static int32_t expected_alloc_once(int seed) {
    int32_t acc = 0;
    for (int i = 0; i < 64; i++) {
        int v = seed + i;
        int digits = (v < 10) ? 1 : ((v < 100) ? 2 : 3);
        acc += v + (5 + digits); /* "item_" has length 5 */
    }
    return acc;
}

static void *stress_worker(void *p) {
    StressArg *a = (StressArg *)p;
    /* Synchronize all 8 workers so they hit first-entry pion_once_call concurrently! */
    portable_barrier_wait();
    int32_t rtotal = 0;
    int32_t atotal = 0;
    for (int i = 0; i < NITERS; i++) {
        rtotal += pion_p87_mt_read(20);
        atotal += pion_p87_mt_alloc(a->id);
    }
    a->tid = pion_cur_tid();
    a->read_sum = rtotal;
    a->alloc_sum = atotal;
    return NULL;
}

int main(void) {
    /* Host explicitly calls pion_enter_mt() BEFORE any FFI call — NO main-thread warmup! */
    pion_enter_mt();
    if (pion_mt_flag != 1u) { fprintf(stderr, "FAIL: pion_enter_mt did not set flag\n"); return 1; }
    uint64_t main_tid = pion_cur_tid();
    if (main_tid != 1u) { fprintf(stderr, "FAIL: main_tid=%llu\n", (unsigned long long)main_tid); return 1; }

    pthread_t th[NTHREADS];
    StressArg args[NTHREADS];
    for (int i = 0; i < NTHREADS; i++) {
        args[i].id = i + 1;
        args[i].tid = 0;
        args[i].read_sum = 0;
        args[i].alloc_sum = 0;
        if (pthread_create(&th[i], NULL, stress_worker, &args[i]) != 0) {
            perror("pthread_create");
            return 1;
        }
    }
    for (int i = 0; i < NTHREADS; i++) {
        pthread_join(th[i], NULL);
    }

    /* Expected read per 20 iters = 5 * ((11+5) + (22+5) + (33+7) + (44+6)) = 5 * 133 = 665 */
    int32_t expected_read = 665 * NITERS;

    for (int i = 0; i < NTHREADS; i++) {
        if (args[i].tid < 2u) {
            fprintf(stderr, "FAIL: worker %d got invalid tid %llu\n", i, (unsigned long long)args[i].tid);
            return 1;
        }
        if (args[i].read_sum != expected_read) {
            fprintf(stderr, "FAIL: worker %d read_sum=%d expected=%d\n",
                    i, args[i].read_sum, expected_read);
            return 1;
        }
        int32_t exp_alloc = expected_alloc_once(args[i].id) * NITERS;
        if (args[i].alloc_sum != exp_alloc) {
            fprintf(stderr, "FAIL: worker %d (seed=%d) alloc_sum=%d expected=%d\n",
                    i, args[i].id, args[i].alloc_sum, exp_alloc);
            return 1;
        }
        for (int j = i + 1; j < NTHREADS; j++) {
            if (args[i].tid == args[j].tid) {
                fprintf(stderr, "FAIL: duplicate worker tid %llu\n", (unsigned long long)args[i].tid);
                return 1;
            }
        }
    }

    printf("mt_stress_ok threads=%d main_tid=%llu read=%d alloc0=%d\n",
           NTHREADS, (unsigned long long)main_tid, expected_read, args[0].alloc_sum);
    return 0;
}
EOF

"$CC_BIN" -O2 -I"$ROOT_DIR/runtime" "$TMP_DIR/mt_stress_host.c" "$MT_OBJ" "$RT_NATIVE" \
    -lm -lpthread -o "$TMP_DIR/mt_stress_host"
STRESS_OUT="$("$TMP_DIR/mt_stress_host")"
echo "  native: $STRESS_OUT"

# TSan check if supported
if [ "$HAVE_TSAN" = 1 ] && "$CC_BIN" -O1 -g -fsanitize=thread -I"$ROOT_DIR/runtime" \
    "$TMP_DIR/mt_stress_host.c" "$MT_OBJ" "$TSAN_RT" \
    -lm -lpthread -o "$TMP_DIR/mt_stress_tsan" 2>/dev/null; then
  TSAN_OUT="$("$TMP_DIR/mt_stress_tsan")"
  if [ "$TSAN_OUT" != "$STRESS_OUT" ]; then
    echo "FAIL: TSan output mismatch: '$TSAN_OUT'" >&2
    exit 1
  fi
  echo "  TSan: $TSAN_OUT (0 data races)"
else
  echo "  NOTE: TSan unavailable on this toolchain; skipped"
fi

# 4. Real multi-file unit-mode (2 source files, NO pion.toml, NO --emit-staticlib)
#    same-thread reentrant callback during const init:
#    a.pion defines X = host_eval_x(), b.pion defines Y = X + 100 and exports ping()/get_y().
#    host_eval_x() synchronously calls ping() before returning 42; package-level pion_once_call
#    must skip re-entering b.pion's init so Y is computed AFTER X = 42 -> Y == 142.
echo "--- [4] Unit-mode 2-file reentrant callback const-init order ---"
REENT_DIR="$TMP_DIR/reent_units"
mkdir -p "$REENT_DIR"

cat > "$REENT_DIR/a.pion" <<'EOF'
extern "C" fn host_eval_x() -> Int

pub let X : Int = host_eval_x()
EOF

cat > "$REENT_DIR/b.pion" <<'EOF'
pub let Y : Int = X + 100

pub extern "C" fn ping() -> Int {
  7
}

pub extern "C" fn get_y() -> Int {
  Y
}
EOF

REENT_CAS="$CAS_DIR/reent_units"
rm -rf "$REENT_CAS"
PION_CACHE_DIR="$REENT_CAS" "$PIONC" build --release --no-main "$REENT_DIR/a.pion" "$REENT_DIR/b.pion" >/dev/null

UNIT_SSA_COUNT=$(ls -1 "$REENT_CAS/ssa/"*.ssa | wc -l | tr -d ' ')
UNIT_OBJ_COUNT=$(ls -1 "$REENT_CAS/obj/"*.o | wc -l | tr -d ' ')
if [ "$UNIT_SSA_COUNT" != "2" ] || [ "$UNIT_OBJ_COUNT" != "2" ]; then
  echo "FAIL: expected 2 unit .ssa and 2 unit .o files, got ssa=$UNIT_SSA_COUNT obj=$UNIT_OBJ_COUNT" >&2
  exit 1
fi

WRAP_DEF_COUNT=$(grep -c 'export function \$pion_unit_init_all_' "$REENT_CAS/ssa/"*.ssa | awk -F: '{s+=$2} END{print s+0}')
GUARD_DEF_COUNT=$(grep -c 'data \$pion_unit_init_all_.*_guard =' "$REENT_CAS/ssa/"*.ssa | awk -F: '{s+=$2} END{print s+0}')
if [ "$WRAP_DEF_COUNT" != "1" ] || [ "$GUARD_DEF_COUNT" != "1" ]; then
  echo "FAIL: expected exactly 1 pkg-level once wrapper & guard across unit SSAs, got wrap=$WRAP_DEF_COUNT guard=$GUARD_DEF_COUNT" >&2
  exit 1
fi

PING_SSA=$(grep -l 'export function w \$ping(' "$REENT_CAS/ssa/"*.ssa)
if [ -z "$PING_SSA" ] || ! grep -q 'call \$pion_unit_init_all_' "$PING_SSA"; then
  echo "FAIL: unit defining ping() must call \$pion_unit_init_all_" >&2
  exit 1
fi
if grep -q 'export function \$pion_unit_init_all_' "$PING_SSA" || grep -q 'call \$pion_init_consts_0(' "$PING_SSA"; then
  echo "FAIL: unit B must neither redefine \$pion_unit_init_all_ nor directly call \$pion_init_consts_0" >&2
  exit 1
fi

cat > "$TMP_DIR/reent_host.c" <<'EOF'
#include <stdio.h>
#include <stdint.h>

extern int32_t ping(void);
extern int32_t get_y(void);

static int g_ping_seen = 0;

int32_t host_eval_x(void) {
    g_ping_seen = ping();
    return 42;
}

int main(void) {
    int32_t y = get_y();
    if (g_ping_seen != 7 || y != 142) {
        fprintf(stderr, "FAIL: expected ping=7 y=142, got ping=%d y=%d\n", g_ping_seen, y);
        return 1;
    }
    printf("unit_reent_ok ping=%d y=%d\n", g_ping_seen, y);
    return 0;
}
EOF

"$CC_BIN" -O2 "$TMP_DIR/reent_host.c" "$REENT_CAS/obj/"*.o "$RT_NATIVE" \
    -lm -lpthread -o "$TMP_DIR/reent_host"
REENT_OUT="$("$TMP_DIR/reent_host")"
echo "  unit_reent: $REENT_OUT (units=2, wrap_defs=$WRAP_DEF_COUNT)"
if [ "$REENT_OUT" != "unit_reent_ok ping=7 y=142" ]; then
  echo "FAIL: unit_reent output mismatch: '$REENT_OUT'" >&2
  exit 1
fi

echo "=== P87 ALL PASSED ==="
