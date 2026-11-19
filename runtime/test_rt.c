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

static double monotonic_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

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

static void test_alloc_uninit(void) {
    atomic_store(&g_drop_count, 0);

    /* Slab-sized object with destructor + nested child */
    TestNode *leaf = (TestNode *)m2_alloc_uninit((uint32_t)sizeof(TestNode), M2_TAG_STRUCT, test_node_drop);
    leaf->id = 101;
    leaf->child = NULL;

    TestNode *parent = (TestNode *)m2_alloc_uninit((uint32_t)sizeof(TestNode), M2_TAG_STRUCT, test_node_drop);
    parent->id = 202;
    m2_rc_inc(leaf);
    parent->child = leaf;

    assert(parent->id == 202);
    assert(((TestNode *)parent->child)->id == 101);

    m2_rc_dec(leaf);
    assert(atomic_load(&g_drop_count) == 0);
    m2_rc_inc(parent);
    m2_rc_dec(parent);
    assert(atomic_load(&g_drop_count) == 0);
    m2_rc_dec(parent);
    assert(atomic_load(&g_drop_count) == 2);

    /* Large (> slab max) uninitialized allocation + full write/read + release */
    uint64_t *big = (uint64_t *)m2_alloc_uninit(512u, M2_TAG_STRUCT, NULL);
    for (int i = 0; i < 64; i++) {
        big[i] = (uint64_t)(i * 131 + 7);
    }
    for (int i = 0; i < 64; i++) {
        assert(big[i] == (uint64_t)(i * 131 + 7));
    }
    m2_rc_dec(big);

    /* Zero-byte uninitialized allocation */
    void *empty = m2_alloc_uninit(0u, M2_TAG_ENUM, NULL);
    assert(empty != NULL);
    m2_rc_dec(empty);

    printf("[PASS] alloc_uninit\n");
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

    /* Fast int-to-str edge cases (0, small, 2-digit, 3-digit, INT64_MAX, INT64_MIN) */
    const int64_t edge_vals[] = {
        0LL, 1LL, -1LL, 9LL, -9LL, 10LL, -10LL, 99LL, -99LL, 100LL, -100LL,
        9223372036854775807LL, (-9223372036854775807LL - 1LL)
    };
    const char *edge_strs[] = {
        "0", "1", "-1", "9", "-9", "10", "-10", "99", "-99", "100", "-100",
        "9223372036854775807", "-9223372036854775808"
    };
    for (size_t i = 0; i < sizeof(edge_vals) / sizeof(edge_vals[0]); i++) {
        void *es = m2_int_to_str(edge_vals[i]);
        void *ex = m2_str_from_cstr(edge_strs[i], -1);
        assert(m2_str_eq(es, ex) == 1);
        void *esb = m2_strbuf_new(8);
        m2_strbuf_push_int(esb, edge_vals[i]);
        void *esb_s = m2_strbuf_to_str(esb);
        assert(m2_str_eq(esb_s, ex) == 1);
        m2_rc_dec(es);
        m2_rc_dec(ex);
        m2_rc_dec(esb);
        m2_rc_dec(esb_s);
    }

    /* C ABI math sqrt fallback */
    assert(m2_math_sqrt(1764.0) == 42.0);
    assert(m2_math_sqrt(0.0) == 0.0);

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

    /* StringBuilder reset + UTF-8 push_char */
    m2_strbuf_reset(sb);
    m2_strbuf_push_char(sb, 'A');       /* 1 byte */
    m2_strbuf_push_char(sb, 0x00E9);    /* é: 2 bytes */
    m2_strbuf_push_char(sb, 0x4E2D);    /* 中: 3 bytes */
    m2_strbuf_push_char(sb, 0x1F600);   /* 😀: 4 bytes */
    void *utf8_s = m2_strbuf_to_str(sb);
    assert(m2_str_len(utf8_s) == 10);
    assert(m2_str_byte_at(utf8_s, 0) == 'A');
    assert(m2_str_byte_at(utf8_s, 1) == 0xC3);
    assert(m2_str_byte_at(utf8_s, 2) == 0xA9);
    assert(m2_str_byte_at(utf8_s, 3) == 0xE4);
    assert(m2_str_byte_at(utf8_s, 6) == 0xF0);

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
    m2_rc_dec(utf8_s);
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

    /* m2_arr_copy retains object elements independently */
    void *oarr_cp = m2_arr_copy(oarr);
    assert(m2_arr_len(oarr_cp) == 19);
    assert(((TestNode *)(uintptr_t)m2_arr_get(oarr_cp, 5))->id == 999);
    m2_rc_dec(oarr);
    assert(atomic_load(&g_drop_count) == 2); /* elements still alive in copy */
    m2_rc_dec(oarr_cp);
    assert(atomic_load(&g_drop_count) == 21);

    /* Map (primitive + object values + growth + remove + copy) */
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

    /* Map copy + remove half the keys + re-verify remaining + re-insert */
    void *map_cp = m2_map_copy(map);
    assert(m2_map_len(map_cp) == 128);
    for (int64_t i = 0; i < 64; i++) {
        void *k = m2_int_to_str(i * 2);
        m2_map_remove(map, k);
        assert(m2_map_has(map, k) == 0);
        assert(m2_map_has(map_cp, k) == 1);
        m2_rc_dec(k);
    }
    assert(m2_map_len(map) == 64);
    for (int64_t i = 0; i < 64; i++) {
        void *k = m2_int_to_str(i * 2 + 1);
        assert(m2_map_has(map, k) == 1);
        assert(((TestNode *)(uintptr_t)m2_map_get(map, k))->id == (i * 2 + 1) * 10);
        m2_rc_dec(k);
    }
    m2_map_remove(map, kmiss); /* removing non-existent key is a no-op */
    assert(m2_map_len(map) == 64);

    void *keys = m2_map_keys(map_cp);
    assert(m2_arr_len(keys) == 128);
    m2_rc_dec(keys);
    m2_rc_dec(k42);
    m2_rc_dec(kmiss);
    m2_rc_dec(map);
    m2_rc_dec(map_cp);
    assert(atomic_load(&g_drop_count) == 129);

    printf("[PASS] array_and_map\n");
}

static void test_map_try_get_and_100k(void) {
    /* Edge cases: NULL map, NULL key, empty map, NULL out_val */
    int64_t out = -999;
    void *k0 = m2_str_from_cstr("a", 1);
    assert(m2_map_try_get(NULL, k0, &out) == 0 && out == -999);
    void *empty_map = m2_map_new(0);
    assert(m2_map_try_get(empty_map, NULL, &out) == 0 && out == -999);
    assert(m2_map_try_get(empty_map, k0, &out) == 0 && out == -999);
    assert(m2_map_try_get(empty_map, k0, NULL) == 0);
    m2_rc_dec(k0);
    m2_rc_dec(empty_map);

    /* Hash length coverage (0..32 bytes: all tail branches + multi-block) + overwrite + remove */
    atomic_store(&g_drop_count, 0);
    void *omap = m2_map_new(1);
    const char *sample_keys[] = {
        "", "a", "ab", "abc", "abcd", "abcde", "abcdef", "abcdefg",
        "abcdefgh", "abcdefghi", "0123456789abcde", "0123456789abcdef",
        "0123456789abcdefX", "0123456789abcdef0123456789abcdef"
    };
    const size_t n_samples = sizeof(sample_keys) / sizeof(sample_keys[0]);
    for (size_t i = 0; i < n_samples; i++) {
        void *k = m2_str_from_cstr(sample_keys[i], -1);
        void *v = test_node_new((int64_t)(i + 1), NULL);
        m2_map_set(omap, k, (int64_t)(uintptr_t)v);
        m2_rc_dec(k);
        m2_rc_dec(v);
    }
    for (size_t i = 0; i < n_samples; i++) {
        void *k = m2_str_from_cstr(sample_keys[i], -1);
        int64_t val = 0;
        assert(m2_map_try_get(omap, k, &val) == 1);
        assert(((TestNode *)(uintptr_t)val)->id == (int64_t)(i + 1));
        assert(m2_map_try_get(omap, k, NULL) == 1);
        m2_rc_dec(k);
    }
    /* Overwrite & remove */
    void *k_ov = m2_str_from_cstr("abcde", 5);
    void *v_ov = test_node_new(9999, NULL);
    m2_map_set(omap, k_ov, (int64_t)(uintptr_t)v_ov);
    m2_rc_dec(v_ov);
    assert(atomic_load(&g_drop_count) == 1);
    int64_t ov_out = 0;
    assert(m2_map_try_get(omap, k_ov, &ov_out) == 1);
    assert(((TestNode *)(uintptr_t)ov_out)->id == 9999);

    m2_map_remove(omap, k_ov);
    ov_out = -777;
    assert(m2_map_try_get(omap, k_ov, &ov_out) == 0 && ov_out == -777);
    m2_rc_dec(k_ov);
    m2_rc_dec(omap);
    assert(atomic_load(&g_drop_count) == (int64_t)(n_samples + 1));

    /* 100k keys insert + growth + try_get verification + remove + throughput timing */
    const int64_t N = 100000;
    void **keys = (void **)malloc((size_t)N * sizeof(void *));
    assert(keys != NULL);
    void *big_map = m2_map_new(0);
    char kbuf[32];
    for (int64_t i = 0; i < N; i++) {
        int n = snprintf(kbuf, sizeof(kbuf), "m2_key_%06" PRId64, i);
        keys[i] = m2_str_from_cstr(kbuf, n);
        m2_map_set(big_map, keys[i], i * 7 + 3);
    }
    assert(m2_map_len(big_map) == N);

    /* Timed 100k m2_map_try_get lookups */
    double t0 = monotonic_sec();
    int64_t checksum = 0;
    for (int64_t i = 0; i < N; i++) {
        int64_t v = 0;
        int32_t hit = m2_map_try_get(big_map, keys[i], &v);
        assert(hit == 1);
        assert(v == i * 7 + 3);
        checksum += v;
    }
    double t1 = monotonic_sec();
    double ms = (t1 - t0) * 1000.0;
    assert(checksum == (N * (N - 1) / 2) * 7 + N * 3);

    /* Verify misses */
    for (int64_t i = 0; i < 1000; i++) {
        int n = snprintf(kbuf, sizeof(kbuf), "miss_key_%06" PRId64, i);
        void *mk = m2_str_from_cstr(kbuf, n);
        int64_t v = -1;
        assert(m2_map_try_get(big_map, mk, &v) == 0 && v == -1);
        m2_rc_dec(mk);
    }

    /* Remove every 4th key and re-verify hit/miss */
    for (int64_t i = 0; i < N; i += 4) {
        m2_map_remove(big_map, keys[i]);
    }
    assert(m2_map_len(big_map) == (N * 3) / 4);
    for (int64_t i = 0; i < N; i++) {
        int64_t v = 0;
        int32_t hit = m2_map_try_get(big_map, keys[i], &v);
        if ((i & 3) == 0) {
            assert(hit == 0);
        } else {
            assert(hit == 1 && v == i * 7 + 3);
        }
    }

    for (int64_t i = 0; i < N; i++) {
        m2_rc_dec(keys[i]);
    }
    free(keys);
    m2_rc_dec(big_map);

    printf("[PASS] map_try_get_100k (100k lookups: %.2f ms, %.1f ns/op)\n",
           ms, (ms * 1e6) / (double)N);
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

    /* fs_mkdir_p / fs_write / fs_exists / fs_size / fs_read / fs_rename / fs_list_dir / fs_remove */
    char dir_buf[128];
    snprintf(dir_buf, sizeof(dir_buf), "/tmp/m2_rt_test_%d/sub", (int)getpid());
    void *dir_s = m2_str_from_cstr(dir_buf, -1);
    assert(m2_world_fs_mkdir_p(w, dir_s) == 1);
    assert(m2_world_fs_exists(w, dir_s) == 1);

    char file_buf[160];
    snprintf(file_buf, sizeof(file_buf), "%s/zeta.tmp", dir_buf);
    void *file_tmp = m2_str_from_cstr(file_buf, -1);
    void *content = m2_str_from_cstr("m2 world fs payload\n", -1);
    assert(m2_world_fs_write(w, file_tmp, content) == 1);
    assert(m2_world_fs_exists(w, file_tmp) == 1);
    assert(m2_world_fs_size(w, file_tmp) == 20);

    /* Atomic rename */
    char file_zeta[160];
    snprintf(file_zeta, sizeof(file_zeta), "%s/zeta.txt", dir_buf);
    void *zeta_s = m2_str_from_cstr(file_zeta, -1);
    assert(m2_world_fs_rename(w, file_tmp, zeta_s) == 1);
    assert(m2_world_fs_exists(w, file_tmp) == 0);
    assert(m2_world_fs_size(w, file_tmp) == -1);
    assert(m2_world_fs_exists(w, zeta_s) == 1);
    assert(m2_world_fs_size(w, zeta_s) == 20);

    void *read_back = m2_world_fs_read(w, zeta_s, &ok);
    assert(ok == 1 && m2_str_eq(read_back, content) == 1);

    /* Write unsorted filenames and verify deterministic lexicographical order */
    const char *extra_names[] = {"mid.txt", "alpha.txt", "beta.txt"};
    char extra_paths[3][160];
    for (int i = 0; i < 3; i++) {
        snprintf(extra_paths[i], sizeof(extra_paths[i]), "%s/%s", dir_buf, extra_names[i]);
        void *ps = m2_str_from_cstr(extra_paths[i], -1);
        assert(m2_world_fs_write(w, ps, content) == 1);
        m2_rc_dec(ps);
    }

    void *entries = m2_world_fs_list_dir(w, dir_s);
    assert(m2_world_fs_is_dir(w, dir_s) == 1);
    assert(m2_world_fs_is_dir(w, zeta_s) == 0);
    assert(m2_arr_len(entries) == 4);
    const char *sorted_expected[] = {"alpha.txt", "beta.txt", "mid.txt", "zeta.txt"};
    for (int i = 0; i < 4; i++) {
        void *exp = m2_str_from_cstr(sorted_expected[i], -1);
        assert(m2_str_eq((void *)(uintptr_t)m2_arr_get(entries, i), exp) == 1);
        m2_rc_dec(exp);
    }

    /* fs_remove */
    assert(m2_world_fs_remove(w, zeta_s) == 1);
    assert(m2_world_fs_exists(w, zeta_s) == 0);
    assert(m2_world_fs_remove(w, zeta_s) == 0);

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
    for (int i = 0; i < 3; i++) {
        unlink(extra_paths[i]);
    }
    rmdir(dir_buf);
    snprintf(dir_buf, sizeof(dir_buf), "/tmp/m2_rt_test_%d", (int)getpid());
    rmdir(dir_buf);

    m2_rc_dec(sh);
    m2_rc_dec(flag);
    m2_rc_dec(script);
    m2_rc_dec(cmd);
    m2_rc_dec(entries);
    m2_rc_dec(read_back);
    m2_rc_dec(content);
    m2_rc_dec(zeta_s);
    m2_rc_dec(file_tmp);
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

typedef struct ParentScopeEnv {
    void *parent_scope;
    void *atom;
} ParentScopeEnv;

static void parent_scope_env_drop(void *p) {
    ParentScopeEnv *e = (ParentScopeEnv *)p;
    m2_rc_dec(e->parent_scope);
    m2_rc_dec(e->atom);
}

static void child_spawning_into_parent(void *arg) {
    ParentScopeEnv *e = (ParentScopeEnv *)arg;
    for (int i = 0; i < 3; i++) {
        m2_scope_spawn(e->parent_scope, nested_leaf, e->atom);
    }
}

static void test_mt_nested_scope(void) {
    void *atom = m2_atomic_new(0);
    void *outer = m2_scope_begin();
    for (int i = 0; i < 4; i++) {
        m2_scope_spawn(outer, nested_mid, atom);
    }
    m2_scope_end(outer);
    assert(m2_atomic_load(atom) == 8);

    /* Child threads capturing parent scope & spawning into it concurrently */
    void *shared_scope = m2_scope_begin();
    ParentScopeEnv *penv = (ParentScopeEnv *)m2_alloc(
        (uint32_t)sizeof(ParentScopeEnv), M2_TAG_STRUCT, parent_scope_env_drop);
    m2_rc_inc(shared_scope);
    m2_rc_inc(atom);
    penv->parent_scope = shared_scope;
    penv->atom = atom;
    for (int i = 0; i < 4; i++) {
        m2_scope_spawn(shared_scope, child_spawning_into_parent, penv);
    }
    m2_rc_dec(penv);
    m2_scope_end(shared_scope);
    assert(m2_atomic_load(atom) == 8 + 4 * 3);

    m2_rc_dec(atom);
    printf("[PASS] mt_nested_scope (4x2 nested + 4x3 parent-scope spawn)\n");
}

typedef struct SlabStressEnv {
    void *ch;
    int64_t count;
    int64_t tid_idx;
} SlabStressEnv;

static void slab_stress_env_drop(void *p) {
    SlabStressEnv *e = (SlabStressEnv *)p;
    m2_rc_dec(e->ch);
}

static void slab_obj_drop(void *payload) {
    (void)payload;
    atomic_fetch_add_explicit(&g_drop_count, 1, memory_order_relaxed);
}

static void slab_producer_worker(void *arg) {
    SlabStressEnv *e = (SlabStressEnv *)arg;
    /* Mix all 7 slab size classes (payload 0..224) + large (>224) */
    const uint32_t sizes[8] = { 8u, 16u, 32u, 64u, 96u, 160u, 224u, 512u };
    for (int64_t i = 0; i < e->count; i++) {
        /* Local alloc/free burst */
        uint32_t lsz = sizes[(size_t)(i + e->tid_idx) & 7u];
        int64_t *loc = (int64_t *)m2_alloc(lsz, M2_TAG_STRUCT, slab_obj_drop);
        assert(loc[0] == 0); /* Verify zero-initialization */
        loc[0] = i + 1;
        m2_rc_dec(loc);

        /* Cross-thread alloc -> freeze -> send -> remote free */
        uint32_t rsz = sizes[(size_t)i & 7u];
        int64_t *rem = (int64_t *)m2_alloc(rsz, M2_TAG_STRUCT, slab_obj_drop);
        assert(rem[0] == 0);
        rem[0] = (e->tid_idx << 32) | i;
        assert(m2_chan_send(e->ch, (int64_t)(uintptr_t)rem) == 1);
        m2_rc_dec(rem);
    }
}

static void slab_consumer_worker(void *arg) {
    SlabStressEnv *e = (SlabStressEnv *)arg;
    int64_t val = 0;
    while (m2_chan_recv(e->ch, &val)) {
        int64_t *obj = (int64_t *)(uintptr_t)val;
        assert(obj[0] >= 0);
        /* Also allocate locally to trigger draining g_slab_remote */
        int64_t *tmp = (int64_t *)m2_alloc(32u, M2_TAG_STRUCT, slab_obj_drop);
        assert(tmp[0] == 0);
        tmp[0] = obj[0];
        m2_rc_dec(tmp);
        m2_rc_dec(obj);
    }
}

static void test_mt_slab_stress(void) {
    atomic_store(&g_drop_count, 0);
    const int n_prod = 4;
    const int n_cons = 4;
    const int64_t per_prod = 5000;

    void *ch = m2_chan_new(128, 1);

    void *cons_scope = m2_scope_begin();
    for (int i = 0; i < n_cons; i++) {
        SlabStressEnv *e = (SlabStressEnv *)m2_alloc((uint32_t)sizeof(SlabStressEnv),
                                                     M2_TAG_STRUCT, slab_stress_env_drop);
        m2_rc_inc(ch);
        e->ch = ch;
        e->count = per_prod;
        e->tid_idx = i;
        m2_scope_spawn(cons_scope, slab_consumer_worker, e);
        m2_rc_dec(e);
    }

    void *prod_scope = m2_scope_begin();
    for (int i = 0; i < n_prod; i++) {
        SlabStressEnv *e = (SlabStressEnv *)m2_alloc((uint32_t)sizeof(SlabStressEnv),
                                                     M2_TAG_STRUCT, slab_stress_env_drop);
        m2_rc_inc(ch);
        e->ch = ch;
        e->count = per_prod;
        e->tid_idx = i;
        m2_scope_spawn(prod_scope, slab_producer_worker, e);
        m2_rc_dec(e);
    }

    m2_scope_end(prod_scope);
    m2_chan_close(ch);
    m2_scope_end(cons_scope);
    m2_rc_dec(ch);

    /* Expected drops: per producer: 1 local + 1 remote; per remote: 1 consumer local = 3 * n_prod * per_prod */
    int64_t expected_drops = 3LL * n_prod * per_prod;
    assert(atomic_load(&g_drop_count) == expected_drops);
    printf("[PASS] mt_slab_stress (8 threads, %" PRId64 " slab/large alloc+free, 0 leaks)\n", expected_drops);
}

typedef struct ExecStressEnv {
    void *world;
    void *done_cnt;
    int iters;
} ExecStressEnv;

static void exec_stress_env_drop(void *p) {
    ExecStressEnv *e = (ExecStressEnv *)p;
    m2_rc_dec(e->world);
    m2_rc_dec(e->done_cnt);
}

static void exec_stress_worker(void *arg) {
    ExecStressEnv *e = (ExecStressEnv *)arg;
    void *cmd_true = m2_arr_new(1, 1);
    void *s_true = m2_str_from_cstr("/usr/bin/true", -1);
    m2_arr_push(cmd_true, (int64_t)(uintptr_t)s_true);

    void *cmd_missing = m2_arr_new(1, 1);
    void *s_missing = m2_str_from_cstr("/nonexistent_m2_exec_cmd_xyz_999", -1);
    m2_arr_push(cmd_missing, (int64_t)(uintptr_t)s_missing);

    for (int i = 0; i < e->iters; i++) {
        assert(m2_world_exec(e->world, cmd_true) == 0);
        assert(m2_world_exec(e->world, cmd_missing) == 127);
    }

    m2_rc_dec(s_true);
    m2_rc_dec(cmd_true);
    m2_rc_dec(s_missing);
    m2_rc_dec(cmd_missing);
    m2_atomic_fetch_add(e->done_cnt, 1);
}

static void test_mt_world_exec(int argc, char **argv) {
    void *w = m2_world_init(argc, argv);
    void *done_cnt = m2_atomic_new(0);

    void *sc = m2_scope_begin();
    for (int i = 0; i < 8; i++) {
        ExecStressEnv *e = (ExecStressEnv *)m2_alloc_uninit(
            (uint32_t)sizeof(ExecStressEnv), M2_TAG_STRUCT, exec_stress_env_drop);
        m2_rc_inc(w);
        m2_rc_inc(done_cnt);
        e->world = w;
        e->done_cnt = done_cnt;
        e->iters = 4;
        m2_scope_spawn(sc, exec_stress_worker, e);
        m2_rc_dec(e);
    }
    m2_scope_end(sc);

    assert(m2_atomic_load(done_cnt) == 8);
    m2_rc_dec(done_cnt);
    m2_rc_dec(w);
    printf("[PASS] mt_world_exec (8 threads concurrent posix_spawnp)\n");
}

static void run_slab_bench(void) {
    const int64_t N = 1000000;
    void *ring[64];
    memset(ring, 0, sizeof(ring));

    /* Warmup */
    for (int i = 0; i < 10000; i++) {
        void *p = m2_alloc(24u, M2_TAG_STRUCT, NULL);
        m2_rc_dec(p);
    }

    double t0 = monotonic_sec();
    for (int64_t i = 0; i < N; i++) {
        int slot = (int)(i & 63);
        if (ring[slot]) {
            m2_rc_dec(ring[slot]);
        }
        int64_t *node = (int64_t *)m2_alloc(24u, M2_TAG_STRUCT, NULL);
        node[0] = i;
        ring[slot] = node;
    }
    for (int i = 0; i < 64; i++) {
        if (ring[i]) {
            m2_rc_dec(ring[i]);
            ring[i] = NULL;
        }
    }
    double t1 = monotonic_sec();
    double ms = (t1 - t0) * 1000.0;
    printf("[BENCH] slab 1M m2_alloc+free (24B payload / 64B class): %.2f ms (%.1f ns/op)\n",
           ms, (ms * 1e6) / (double)N);

    double t2 = monotonic_sec();
    for (int64_t i = 0; i < N; i++) {
        int slot = (int)(i & 63);
        if (ring[slot]) {
            m2_rc_dec(ring[slot]);
        }
        int64_t *node = (int64_t *)m2_alloc_uninit(24u, M2_TAG_STRUCT, NULL);
        node[0] = i;
        ring[slot] = node;
    }
    for (int i = 0; i < 64; i++) {
        if (ring[i]) {
            m2_rc_dec(ring[i]);
            ring[i] = NULL;
        }
    }
    double t3 = monotonic_sec();
    double ms_uninit = (t3 - t2) * 1000.0;
    printf("[BENCH] slab 1M m2_alloc_uninit+free (24B payload / 64B class): %.2f ms (%.1f ns/op)\n",
           ms_uninit, (ms_uninit * 1e6) / (double)N);
}

/* ============================================================================
 * 3. Multi-Core Speedup Benchmark (4 cores vs 1 core)
 * ============================================================================ */

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
    test_alloc_uninit();
    test_string_and_strbuf();
    test_array_and_map();
    test_map_try_get_and_100k();
    test_sha256();
    test_world(argc, argv);

    test_mt_shared_rc();
    test_mt_channel_10k();
    test_mt_mutex_and_atomic();
    test_mt_nested_scope();
    test_mt_slab_stress();
    test_mt_world_exec(argc, argv);

    if (run_bench) {
        run_slab_bench();
        run_multicore_bench();
    }

    printf("ALL RUNTIME TESTS PASSED\n");
    return 0;
}
