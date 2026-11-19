#define _POSIX_C_SOURCE 200809L

#include "m2_rt.h"

#include <assert.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* ============================================================================
 * Helpers & Tracking Destructor
 * ============================================================================ */

static _Atomic int64_t g_drop_count = 0;

typedef struct TestNode {
    int64_t id;
    void *child;
} TestNode;

static void test_node_drop(void *payload) {
    TestNode *n = (TestNode *)payload;
    if (n->child) {
        m2_rc_dec(n->child);
    }
    atomic_fetch_add_explicit(&g_drop_count, 1, memory_order_seq_cst);
}

static void *test_node_new(int64_t id, void *child) {
    TestNode *n = (TestNode *)m2_alloc((uint32_t)sizeof(TestNode), M2_TAG_STRUCT, test_node_drop);
    n->id = id;
    if (child) {
        m2_rc_inc(child);
    }
    n->child = child;
    return n;
}

M2_STATIC_STRING_DEF(kImmortalHello, "hello immortal");
M2_STATIC_STRING_DEF(kImmortalEmpty, "");

/* ============================================================================
 * 1. Unit Tests
 * ============================================================================ */

static void test_biased_rc_and_immortal(void) {
    atomic_store(&g_drop_count, 0);

    /* Immortal static string: inc/dec/freeze are no-ops */
    for (int i = 0; i < 100; i++) {
        m2_rc_inc(kImmortalHello);
        m2_rc_dec(kImmortalHello);
    }
    m2_rc_freeze(kImmortalHello);
    assert(m2_str_len(kImmortalHello) == 14);
    assert(m2_str_len(kImmortalEmpty) == 0);
    assert(m2_str_byte_at(kImmortalHello, 0) == 'h');

    /* Local biased RC lifecycle + nested drop */
    void *leaf = test_node_new(1, NULL);
    void *parent = test_node_new(2, leaf);
    m2_rc_inc(parent);
    m2_rc_dec(leaf);   /* leaf still held by parent */
    assert(atomic_load(&g_drop_count) == 0);
    m2_rc_dec(parent); /* rc 2 -> 1 */
    assert(atomic_load(&g_drop_count) == 0);
    m2_rc_dec(parent); /* rc 1 -> 0, drops parent and leaf */
    assert(atomic_load(&g_drop_count) == 2);

    /* NULL safety */
    m2_rc_inc(NULL);
    m2_rc_dec(NULL);
    m2_rc_freeze(NULL);

    /* debug_assert true path */
    m2_debug_assert(1, kImmortalHello, __FILE__, __LINE__);
    printf("[PASS] biased_rc_and_immortal\n");
}

static void test_string_and_strbuf(void) {
    void *a = m2_str_from_cstr("hello", 5);
    void *b = m2_str_from_cstr(", m2!", -1);
    void *c = m2_str_concat(a, b);
    assert(m2_str_len(c) == 10);
    assert(m2_str_byte_at(c, 7) == 'm');

    void *expected = m2_str_from_cstr("hello, m2!", 10);
    assert(m2_str_eq(c, expected) == 1);
    assert(m2_str_cmp(c, expected) == 0);
    assert(m2_str_cmp(a, c) < 0);
    assert(m2_str_cmp(c, a) > 0);

    void *sl = m2_str_slice(c, 7, 9);
    void *m2s = m2_str_from_cstr("m2", 2);
    assert(m2_str_eq(sl, m2s) == 1);

    void *num_s = m2_int_to_str(-9876543210LL);
    int32_t ok = 0;
    assert(m2_str_to_int(num_s, &ok) == -9876543210LL && ok == 1);

    void *bad = m2_str_from_cstr("123abc", 6);
    assert(m2_str_to_int(bad, &ok) == 0 && ok == 0);
    void *ws = m2_str_from_cstr(" 42", 3);
    assert(m2_str_to_int(ws, &ok) == 0 && ok == 0);

    /* StringBuilder */
    void *sb = m2_strbuf_new(4);
    m2_strbuf_push_str(sb, a);
    m2_strbuf_push_byte(sb, ':');
    m2_strbuf_push_int(sb, 42);
    for (int i = 0; i < 40; i++) {
        m2_strbuf_push_byte(sb, 'x');
    }
    void *built = m2_strbuf_to_str(sb);
    assert(m2_str_len(built) == 5 + 1 + 2 + 40);
    assert(m2_str_byte_at(built, 5) == ':');
    assert(m2_str_byte_at(built, 6) == '4');
    assert(m2_str_byte_at(built, 7) == '2');

    m2_rc_dec(a);
    m2_rc_dec(b);
    m2_rc_dec(c);
    m2_rc_dec(expected);
    m2_rc_dec(sl);
    m2_rc_dec(m2s);
    m2_rc_dec(num_s);
    m2_rc_dec(bad);
    m2_rc_dec(ws);
    m2_rc_dec(sb);
    m2_rc_dec(built);
    printf("[PASS] string_and_strbuf\n");
}

static void test_array_and_map(void) {
    /* Primitive Array */
    void *arr = m2_arr_new(2, 0);
    for (int64_t i = 0; i < 100; i++) {
        m2_arr_push(arr, i * 3);
    }
    assert(m2_arr_len(arr) == 100);
    assert(m2_arr_get(arr, 50) == 150);
    m2_arr_set(arr, 50, 999);
    assert(m2_arr_get(arr, 50) == 999);
    assert(m2_arr_pop(arr) == 297);
    assert(m2_arr_len(arr) == 99);
    m2_rc_dec(arr);

    /* Object Array RC verification */
    atomic_store(&g_drop_count, 0);
    void *oarr = m2_arr_new(0, 1);
    for (int64_t i = 0; i < 20; i++) {
        void *n = test_node_new(i, NULL);
        m2_arr_push(oarr, (int64_t)(uintptr_t)n);
        m2_rc_dec(n);
    }
    void *rep = test_node_new(999, NULL);
    m2_arr_set(oarr, 5, (int64_t)(uintptr_t)rep);
    m2_rc_dec(rep);
    assert(atomic_load(&g_drop_count) == 1);
    void *popped = (void *)(uintptr_t)m2_arr_pop(oarr);
    assert(((TestNode *)popped)->id == 19);
    m2_rc_dec(popped);
    assert(atomic_load(&g_drop_count) == 2);
    m2_rc_dec(oarr);
    assert(atomic_load(&g_drop_count) == 21);

    /* Map (primitive + object values + growth) */
    atomic_store(&g_drop_count, 0);
    void *map = m2_map_new(1);
    for (int64_t i = 0; i < 128; i++) {
        void *k = m2_int_to_str(i);
        void *v = test_node_new(i * 10, NULL);
        m2_map_set(map, k, (int64_t)(uintptr_t)v);
        m2_rc_dec(k);
        m2_rc_dec(v);
    }
    assert(m2_map_len(map) == 128);
    void *k42 = m2_str_from_cstr("42", 2);
    void *kmiss = m2_str_from_cstr("missing", 7);
    assert(m2_map_has(map, k42) == 1);
    assert(m2_map_has(map, kmiss) == 0);
    TestNode *v42 = (TestNode *)(uintptr_t)m2_map_get(map, k42);
    assert(v42->id == 420);

    /* Overwrite existing key releases old value */
    void *vnew = test_node_new(4242, NULL);
    m2_map_set(map, k42, (int64_t)(uintptr_t)vnew);
    m2_rc_dec(vnew);
    assert(atomic_load(&g_drop_count) == 1);
    assert(m2_map_len(map) == 128);

    void *keys = m2_map_keys(map);
    assert(m2_arr_len(keys) == 128);
    m2_rc_dec(keys);
    m2_rc_dec(k42);
    m2_rc_dec(kmiss);
    m2_rc_dec(map);
    assert(atomic_load(&g_drop_count) == 129);

    printf("[PASS] array_and_map\n");
}

static void test_sha256(void) {
    struct {
        const char *in;
        const char *hex;
    } vecs[] = {
        {"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
        {"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
        {"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
        {"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
         "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"}
    };
    for (size_t i = 0; i < sizeof(vecs) / sizeof(vecs[0]); i++) {
        void *s = m2_str_from_cstr(vecs[i].in, -1);
        void *h = m2_sha256_hex(s);
        void *exp = m2_str_from_cstr(vecs[i].hex, 64);
        assert(m2_str_eq(h, exp) == 1);
        m2_rc_dec(s);
        m2_rc_dec(h);
        m2_rc_dec(exp);
    }
    printf("[PASS] sha256\n");
}

static void test_world(int argc, char **argv) {
    void *w = m2_world_init(argc, argv);
    assert(m2_world_argc(w) == argc);
    if (argc > 0) {
        void *a0 = m2_world_argv(w, 0);
        assert(m2_str_len(a0) > 0);
        m2_rc_dec(a0);
    }

    int64_t t0 = m2_world_clock_ms(w);
    assert(t0 > 1700000000000LL);

    /* env_get */
    void *path_key = m2_str_from_cstr("PATH", 4);
    int32_t ok = 0;
    void *path_val = m2_world_env_get(w, path_key, &ok);
    assert(ok == 1 && m2_str_len(path_val) > 0);
    m2_rc_dec(path_key);
    m2_rc_dec(path_val);

    void *missing_key = m2_str_from_cstr("M2_NONEXISTENT_ENV_VAR_XYZ", -1);
    void *missing_val = m2_world_env_get(w, missing_key, &ok);
    assert(ok == 0 && m2_str_len(missing_val) == 0);
    m2_rc_dec(missing_key);
    m2_rc_dec(missing_val);

    /* fs_mkdir_p / fs_write / fs_exists / fs_read / fs_list_dir */
    char dir_buf[128];
    snprintf(dir_buf, sizeof(dir_buf), "/tmp/m2_rt_test_%d/sub", (int)getpid());
    void *dir_s = m2_str_from_cstr(dir_buf, -1);
    assert(m2_world_fs_mkdir_p(w, dir_s) == 1);
    assert(m2_world_fs_exists(w, dir_s) == 1);

    char file_buf[160];
    snprintf(file_buf, sizeof(file_buf), "%s/hello.txt", dir_buf);
    void *file_s = m2_str_from_cstr(file_buf, -1);
    void *content = m2_str_from_cstr("m2 world fs payload\n", -1);
    assert(m2_world_fs_write(w, file_s, content) == 1);
    assert(m2_world_fs_exists(w, file_s) == 1);

    void *read_back = m2_world_fs_read(w, file_s, &ok);
    assert(ok == 1 && m2_str_eq(read_back, content) == 1);

    void *entries = m2_world_fs_list_dir(w, dir_s);
    assert(m2_arr_len(entries) == 1);
    void *hello_name = m2_str_from_cstr("hello.txt", -1);
    assert(m2_str_eq((void *)(uintptr_t)m2_arr_get(entries, 0), hello_name) == 1);

    /* exec */
    void *cmd = m2_arr_new(3, 1);
    void *sh = m2_str_from_cstr("/bin/sh", -1);
    void *flag = m2_str_from_cstr("-c", -1);
    void *script = m2_str_from_cstr("exit 42", -1);
    m2_arr_push(cmd, (int64_t)(uintptr_t)sh);
    m2_arr_push(cmd, (int64_t)(uintptr_t)flag);
    m2_arr_push(cmd, (int64_t)(uintptr_t)script);
    assert(m2_world_exec(w, cmd) == 42);

    /* cleanup temp files */
    unlink(file_buf);
    rmdir(dir_buf);
    snprintf(dir_buf, sizeof(dir_buf), "/tmp/m2_rt_test_%d", (int)getpid());
    rmdir(dir_buf);

    m2_rc_dec(sh);
    m2_rc_dec(flag);
    m2_rc_dec(script);
    m2_rc_dec(cmd);
    m2_rc_dec(hello_name);
    m2_rc_dec(entries);
    m2_rc_dec(read_back);
    m2_rc_dec(content);
    m2_rc_dec(file_s);
    m2_rc_dec(dir_s);
    m2_rc_dec(w);
    printf("[PASS] world_capabilities\n");
}

/* ============================================================================
 * 2. Multithreaded Stress Tests (TSan / ASan clean)
 * ============================================================================ */

typedef struct SharedRcEnv {
    void *str;
    void *node;
    void *counter;
} SharedRcEnv;

static void shared_rc_env_drop(void *p) {
    SharedRcEnv *e = (SharedRcEnv *)p;
    m2_rc_dec(e->str);
    m2_rc_dec(e->node);
    m2_rc_dec(e->counter);
}

static void shared_rc_worker(void *arg) {
    SharedRcEnv *e = (SharedRcEnv *)arg;
    for (int i = 0; i < 2000; i++) {
        m2_rc_inc(e->str);
        m2_rc_inc(e->node);
        assert(m2_str_len(e->str) == 13);
        assert(((TestNode *)e->node)->id == 777);
        m2_rc_dec(e->node);
        m2_rc_dec(e->str);
    }
    m2_atomic_fetch_add(e->counter, 1);
}

static void test_mt_shared_rc(void) {
    atomic_store(&g_drop_count, 0);
    void *str = m2_str_from_cstr("frozen-string", 13);
    void *node = test_node_new(777, NULL);
    void *counter = m2_atomic_new(0);
    m2_rc_freeze(str);
    m2_rc_freeze(node);

    SharedRcEnv *env = (SharedRcEnv *)m2_alloc((uint32_t)sizeof(SharedRcEnv),
                                               M2_TAG_STRUCT, shared_rc_env_drop);
    m2_rc_inc(str);
    m2_rc_inc(node);
    m2_rc_inc(counter);
    env->str = str;
    env->node = node;
    env->counter = counter;

    void *sc = m2_scope_begin();
    for (int i = 0; i < 8; i++) {
        m2_scope_spawn(sc, shared_rc_worker, env);
    }
    m2_scope_end(sc);

    assert(m2_atomic_load(counter) == 8);
    m2_rc_dec(env);
    m2_rc_dec(str);
    m2_rc_dec(node);
    m2_rc_dec(counter);
    assert(atomic_load(&g_drop_count) == 1);
    printf("[PASS] mt_shared_rc (8 threads)\n");
}

typedef struct ChanEnv {
    void *ch;
    void *sum_atomic;
    void *cnt_atomic;
    int64_t start;
    int64_t count;
} ChanEnv;

static void chan_env_drop(void *p) {
    ChanEnv *e = (ChanEnv *)p;
    m2_rc_dec(e->ch);
    m2_rc_dec(e->sum_atomic);
    m2_rc_dec(e->cnt_atomic);
}

static void chan_producer(void *arg) {
    ChanEnv *e = (ChanEnv *)arg;
    for (int64_t i = 0; i < e->count; i++) {
        void *n = test_node_new(e->start + i, NULL);
        int32_t ok = m2_chan_send(e->ch, (int64_t)(uintptr_t)n);
        assert(ok == 1);
        m2_rc_dec(n);
    }
}

static void chan_consumer(void *arg) {
    ChanEnv *e = (ChanEnv *)arg;
    int64_t local_sum = 0;
    int64_t local_cnt = 0;
    int64_t val = 0;
    while (m2_chan_recv(e->ch, &val)) {
        TestNode *n = (TestNode *)(uintptr_t)val;
        local_sum += n->id;
        local_cnt++;
        m2_rc_dec(n);
    }
    m2_atomic_fetch_add(e->sum_atomic, local_sum);
    m2_atomic_fetch_add(e->cnt_atomic, local_cnt);
}

static void test_mt_channel_10k(void) {
    atomic_store(&g_drop_count, 0);
    const int64_t total_msgs = 10000;
    const int n_prod = 4;
    const int n_cons = 4;
    const int64_t per_prod = total_msgs / n_prod;

    void *ch = m2_chan_new(64, 1); /* bounded MPMC channel of frozen objects */
    void *sum_a = m2_atomic_new(0);
    void *cnt_a = m2_atomic_new(0);

    void *cons_scope = m2_scope_begin();
    for (int i = 0; i < n_cons; i++) {
        ChanEnv *e = (ChanEnv *)m2_alloc((uint32_t)sizeof(ChanEnv), M2_TAG_STRUCT, chan_env_drop);
        m2_rc_inc(ch); m2_rc_inc(sum_a); m2_rc_inc(cnt_a);
        e->ch = ch; e->sum_atomic = sum_a; e->cnt_atomic = cnt_a;
        m2_scope_spawn(cons_scope, chan_consumer, e);
        m2_rc_dec(e);
    }

    void *prod_scope = m2_scope_begin();
    for (int i = 0; i < n_prod; i++) {
        ChanEnv *e = (ChanEnv *)m2_alloc((uint32_t)sizeof(ChanEnv), M2_TAG_STRUCT, chan_env_drop);
        m2_rc_inc(ch); m2_rc_inc(sum_a); m2_rc_inc(cnt_a);
        e->ch = ch; e->sum_atomic = sum_a; e->cnt_atomic = cnt_a;
        e->start = i * per_prod + 1;
        e->count = per_prod;
        m2_scope_spawn(prod_scope, chan_producer, e);
        m2_rc_dec(e);
    }
    m2_scope_end(prod_scope);
    m2_chan_close(ch);
    m2_scope_end(cons_scope);

    int64_t expected_sum = total_msgs * (total_msgs + 1) / 2;
    assert(m2_atomic_load(cnt_a) == total_msgs);
    assert(m2_atomic_load(sum_a) == expected_sum);
    assert(m2_chan_send(ch, 0) == 0); /* closed channel rejects sends */

    m2_rc_dec(ch);
    m2_rc_dec(sum_a);
    m2_rc_dec(cnt_a);
    assert(atomic_load(&g_drop_count) == total_msgs);
    printf("[PASS] mt_channel_10k (4P4C, 10000 msgs, 0 leaks)\n");
}

typedef struct SyncEnv {
    void *mu_int;
    void *mu_obj;
    void *atom;
} SyncEnv;

static void sync_env_drop(void *p) {
    SyncEnv *e = (SyncEnv *)p;
    m2_rc_dec(e->mu_int);
    m2_rc_dec(e->mu_obj);
    m2_rc_dec(e->atom);
}

static void sync_worker(void *arg) {
    SyncEnv *e = (SyncEnv *)arg;
    for (int i = 0; i < 5000; i++) {
        int64_t v = m2_mutex_lock(e->mu_int);
        m2_mutex_set_and_unlock(e->mu_int, v + 1);
        m2_atomic_fetch_add(e->atom, 1);
    }
    for (int i = 0; i < 200; i++) {
        void *old_ptr = (void *)(uintptr_t)m2_mutex_lock(e->mu_obj);
        int64_t next_id = ((TestNode *)old_ptr)->id + 1;
        void *next_node = test_node_new(next_id, NULL);
        m2_mutex_set_and_unlock(e->mu_obj, (int64_t)(uintptr_t)next_node);
        m2_rc_dec(next_node);
    }
}

static void test_mt_mutex_and_atomic(void) {
    atomic_store(&g_drop_count, 0);
    void *mu_int = m2_mutex_new(0, 0);
    void *init_node = test_node_new(0, NULL);
    void *mu_obj = m2_mutex_new((int64_t)(uintptr_t)init_node, 1);
    m2_rc_dec(init_node);
    void *atom = m2_atomic_new(0);

    SyncEnv *env = (SyncEnv *)m2_alloc((uint32_t)sizeof(SyncEnv), M2_TAG_STRUCT, sync_env_drop);
    m2_rc_inc(mu_int); m2_rc_inc(mu_obj); m2_rc_inc(atom);
    env->mu_int = mu_int; env->mu_obj = mu_obj; env->atom = atom;

    void *sc = m2_scope_begin();
    for (int i = 0; i < 8; i++) {
        m2_scope_spawn(sc, sync_worker, env);
    }
    m2_scope_end(sc);

    int64_t final_int = m2_mutex_lock(mu_int);
    m2_mutex_unlock(mu_int);
    assert(final_int == 8 * 5000);
    assert(m2_atomic_load(atom) == 8 * 5000);

    TestNode *final_node = (TestNode *)(uintptr_t)m2_mutex_lock(mu_obj);
    assert(final_node->id == 8 * 200);
    m2_mutex_unlock(mu_obj);

    m2_rc_dec(env);
    m2_rc_dec(mu_int);
    m2_rc_dec(mu_obj);
    m2_rc_dec(atom);
    assert(atomic_load(&g_drop_count) == 1 + 8 * 200);
    printf("[PASS] mt_mutex_and_atomic (8 threads)\n");
}

static void nested_leaf(void *arg) {
    m2_atomic_fetch_add(arg, 1);
}

static void nested_mid(void *arg) {
    void *inner = m2_scope_begin();
    for (int i = 0; i < 2; i++) {
        m2_scope_spawn(inner, nested_leaf, arg);
    }
    m2_scope_end(inner);
}

static void test_mt_nested_scope(void) {
    void *atom = m2_atomic_new(0);
    void *outer = m2_scope_begin();
    for (int i = 0; i < 4; i++) {
        m2_scope_spawn(outer, nested_mid, atom);
    }
    m2_scope_end(outer);
    assert(m2_atomic_load(atom) == 8);
    m2_rc_dec(atom);
    printf("[PASS] mt_nested_scope (4x2 threads)\n");
}

/* ============================================================================
 * 3. Multi-Core Speedup Benchmark (4 cores vs 1 core)
 * ============================================================================ */

static double monotonic_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

typedef struct BenchChunk {
    uint64_t seed;
    uint64_t iters;
    void *acc_atomic;
} BenchChunk;

static void bench_chunk_drop(void *p) {
    BenchChunk *b = (BenchChunk *)p;
    m2_rc_dec(b->acc_atomic);
}

static uint64_t cpu_work(uint64_t seed, uint64_t iters) {
    uint64_t x = seed ^ 0x9e3779b97f4a7c15ULL;
    for (uint64_t i = 0; i < iters; i++) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x += 0x2545F4914F6CDD1DULL;
    }
    return x;
}

static void bench_worker(void *arg) {
    BenchChunk *b = (BenchChunk *)arg;
    uint64_t r = cpu_work(b->seed, b->iters);
    m2_atomic_fetch_add(b->acc_atomic, (int64_t)(r & 0xFFFFFFFFULL));
}

static void run_multicore_bench(void) {
    const int n_chunks = 4;
    const uint64_t iters = 120000000ULL;

    /* Warm up CPU clock before timing */
    volatile uint64_t warm = cpu_work(1ULL, 10000000ULL);
    (void)warm;

    /* 1-core sequential */
    double t0 = monotonic_sec();
    int64_t seq_sum = 0;
    for (int i = 0; i < n_chunks; i++) {
        seq_sum += (int64_t)(cpu_work((uint64_t)(i + 1) * 12345ULL, iters) & 0xFFFFFFFFULL);
    }
    double t1 = monotonic_sec();
    double seq_ms = (t1 - t0) * 1000.0;

    /* 4-core parallel via m2_scope_begin/spawn/end */
    void *par_acc = m2_atomic_new(0);
    double t2 = monotonic_sec();
    void *sc = m2_scope_begin();
    for (int i = 0; i < n_chunks; i++) {
        BenchChunk *b = (BenchChunk *)m2_alloc((uint32_t)sizeof(BenchChunk), M2_TAG_STRUCT, bench_chunk_drop);
        b->seed = (uint64_t)(i + 1) * 12345ULL;
        b->iters = iters;
        m2_rc_inc(par_acc);
        b->acc_atomic = par_acc;
        m2_scope_spawn(sc, bench_worker, b);
        m2_rc_dec(b);
    }
    m2_scope_end(sc);
    double t3 = monotonic_sec();
    double par_ms = (t3 - t2) * 1000.0;

    int64_t par_sum = m2_atomic_load(par_acc);
    m2_rc_dec(par_acc);
    assert(par_sum == seq_sum);

    double speedup = seq_ms / par_ms;
    printf("[BENCH] 1-core: %.2f ms, 4-core: %.2f ms, speedup: %.2fx (checksum=%" PRId64 ")\n",
           seq_ms, par_ms, speedup, par_sum);
    assert(speedup > 3.0);
}

int main(int argc, char **argv) {
    int run_bench = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--bench") == 0) {
            run_bench = 1;
        }
    }

    test_biased_rc_and_immortal();
    test_string_and_strbuf();
    test_array_and_map();
    test_sha256();
    test_world(argc, argv);

    test_mt_shared_rc();
    test_mt_channel_10k();
    test_mt_mutex_and_atomic();
    test_mt_nested_scope();

    if (run_bench) {
        run_multicore_bench();
    }

    printf("ALL RUNTIME TESTS PASSED\n");
    return 0;
}
