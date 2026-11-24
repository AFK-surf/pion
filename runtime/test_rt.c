#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include "pion_rt.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <assert.h>
#include <direct.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <io.h>
#include <math.h>
#include <process.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define pion_test_getpid() ((int)_getpid())
#define pion_test_unlink(p) _unlink(p)
#define pion_test_rmdir(p) _rmdir(p)
static int pion_test_rmdir_u8(const char *p) {
    wchar_t w[1024];
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, p, -1, w, 1024) <= 0) return -1;
    return RemoveDirectoryW(w) ? 0 : -1;
}
#define PION_TEST_SH "sh"
#define PION_TEST_TRUE "true"
static const char *pion_test_tmpdir(void) {
    const char *t = getenv("TEMP");
    if (!t || !t[0]) t = getenv("TMP");
    return (t && t[0]) ? t : ".";
}
#else
#ifdef __linux__
#define _GNU_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif

#include "pion_rt.h"

#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#ifdef __linux__
#include <sched.h>
#include <sys/stat.h>
#endif
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#define pion_test_getpid() ((int)getpid())
#define pion_test_unlink(p) unlink(p)
#define pion_test_rmdir(p) rmdir(p)
#define pion_test_rmdir_u8(p) rmdir(p)
#define PION_TEST_SH "/bin/sh"
#define PION_TEST_TRUE "/usr/bin/true"
static const char *pion_test_tmpdir(void) {
    return "/tmp";
}
#endif

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
        pion_rc_dec(n->child);
    }
    atomic_fetch_add_explicit(&g_drop_count, 1, memory_order_seq_cst);
}

static void *test_node_new(int64_t id, void *child) {
    TestNode *n = (TestNode *)pion_alloc((uint32_t)sizeof(TestNode), PION_TAG_STRUCT, test_node_drop);
    n->id = id;
    if (child) {
        pion_rc_inc(child);
    }
    n->child = child;
    return n;
}

PION_STATIC_STRING_DEF(kImmortalHello, "hello immortal");
PION_STATIC_STRING_DEF(kImmortalEmpty, "");

static double monotonic_sec(void) {
#ifdef _WIN32
    LARGE_INTEGER freq, cnt;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&cnt);
    return (double)cnt.QuadPart / (double)freq.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
#endif
}

/* ============================================================================
 * 1. Unit Tests
 * ============================================================================ */

static void test_biased_rc_and_immortal(void) {
    atomic_store(&g_drop_count, 0);

    /* Immortal static string: inc/dec/freeze are no-ops */
    for (int i = 0; i < 100; i++) {
        pion_rc_inc(kImmortalHello);
        pion_rc_dec(kImmortalHello);
    }
    pion_rc_freeze(kImmortalHello);
    assert(pion_str_len(kImmortalHello) == 14);
    assert(pion_str_len(kImmortalEmpty) == 0);
    assert(pion_str_byte_at(kImmortalHello, 0) == 'h');

    /* Local biased RC lifecycle + nested drop */
    void *leaf = test_node_new(1, NULL);
    void *parent = test_node_new(2, leaf);
    pion_rc_inc(parent);
    pion_rc_dec(leaf);   /* leaf still held by parent */
    assert(atomic_load(&g_drop_count) == 0);
    pion_rc_dec(parent); /* rc 2 -> 1 */
    assert(atomic_load(&g_drop_count) == 0);
    pion_rc_dec(parent); /* rc 1 -> 0, drops parent and leaf */
    assert(atomic_load(&g_drop_count) == 2);

    /* NULL safety */
    pion_rc_inc(NULL);
    pion_rc_dec(NULL);
    pion_rc_freeze(NULL);

    /* debug_assert true path */
    pion_debug_assert(1, kImmortalHello, __FILE__, __LINE__);
    printf("[PASS] biased_rc_and_immortal\n");
}

static void test_alloc_uninit(void) {
    atomic_store(&g_drop_count, 0);

    /* Slab-sized object with destructor + nested child */
    TestNode *leaf = (TestNode *)pion_alloc_uninit((uint32_t)sizeof(TestNode), PION_TAG_STRUCT, test_node_drop);
    leaf->id = 101;
    leaf->child = NULL;

    TestNode *parent = (TestNode *)pion_alloc_uninit((uint32_t)sizeof(TestNode), PION_TAG_STRUCT, test_node_drop);
    parent->id = 202;
    pion_rc_inc(leaf);
    parent->child = leaf;

    assert(parent->id == 202);
    assert(((TestNode *)parent->child)->id == 101);

    pion_rc_dec(leaf);
    assert(atomic_load(&g_drop_count) == 0);
    pion_rc_inc(parent);
    pion_rc_dec(parent);
    assert(atomic_load(&g_drop_count) == 0);
    pion_rc_dec(parent);
    assert(atomic_load(&g_drop_count) == 2);

    /* Large (> slab max) uninitialized allocation + full write/read + release */
    uint64_t *big = (uint64_t *)pion_alloc_uninit(512u, PION_TAG_STRUCT, NULL);
    for (int i = 0; i < 64; i++) {
        big[i] = (uint64_t)(i * 131 + 7);
    }
    for (int i = 0; i < 64; i++) {
        assert(big[i] == (uint64_t)(i * 131 + 7));
    }
    pion_rc_dec(big);

    /* Zero-byte uninitialized allocation */
    void *empty = pion_alloc_uninit(0u, PION_TAG_ENUM, NULL);
    assert(empty != NULL);
    pion_rc_dec(empty);

    printf("[PASS] alloc_uninit\n");
}

static void test_string_and_strbuf(void) {
    void *a = pion_str_from_cstr("hello", 5);
    void *b = pion_str_from_cstr(", pion!", -1);
    void *c = pion_str_concat(a, b);
    assert(pion_str_len(c) == 12);
    assert(pion_str_byte_at(c, 7) == 'p');

    void *expected = pion_str_from_cstr("hello, pion!", 12);
    assert(pion_str_eq(c, expected) == 1);
    assert(pion_str_cmp(c, expected) == 0);
    assert(pion_str_cmp(a, c) < 0);
    assert(pion_str_cmp(c, a) > 0);

    void *sl = pion_str_slice(c, 7, 11);
    void *pions = pion_str_from_cstr("pion", 4);
    assert(pion_str_eq(sl, pions) == 1);

    void *num_s = pion_int_to_str(-9876543210LL);
    int32_t ok = 0;
    assert(pion_str_to_int(num_s, &ok) == -9876543210LL && ok == 1);

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
        void *es = pion_int_to_str(edge_vals[i]);
        void *ex = pion_str_from_cstr(edge_strs[i], -1);
        assert(pion_str_eq(es, ex) == 1);
        void *esb = pion_strbuf_new(8);
        pion_strbuf_push_int(esb, edge_vals[i]);
        void *esb_s = pion_strbuf_to_str(esb);
        assert(pion_str_eq(esb_s, ex) == 1);
        pion_rc_dec(es);
        pion_rc_dec(ex);
        pion_rc_dec(esb);
        pion_rc_dec(esb_s);
    }

    /* C ABI math sqrt fallback */
    assert(pion_math_sqrt(1764.0) == 42.0);
    assert(pion_math_sqrt(0.0) == 0.0);

    void *bad = pion_str_from_cstr("123abc", 6);
    assert(pion_str_to_int(bad, &ok) == 0 && ok == 0);
    void *ws = pion_str_from_cstr(" 42", 3);
    assert(pion_str_to_int(ws, &ok) == 0 && ok == 0);

    /* StringBuilder */
    void *sb = pion_strbuf_new(4);
    pion_strbuf_push_str(sb, a);
    pion_strbuf_push_byte(sb, ':');
    pion_strbuf_push_int(sb, 42);
    for (int i = 0; i < 40; i++) {
        pion_strbuf_push_byte(sb, 'x');
    }
    void *built = pion_strbuf_to_str(sb);
    assert(pion_str_len(built) == 5 + 1 + 2 + 40);
    assert(pion_str_byte_at(built, 5) == ':');
    assert(pion_str_byte_at(built, 6) == '4');
    assert(pion_str_byte_at(built, 7) == '2');

    /* StringBuilder reset + UTF-8 push_char */
    pion_strbuf_reset(sb);
    pion_strbuf_push_char(sb, 'A');       /* 1 byte */
    pion_strbuf_push_char(sb, 0x00E9);    /* é: 2 bytes */
    pion_strbuf_push_char(sb, 0x4E2D);    /* 中: 3 bytes */
    pion_strbuf_push_char(sb, 0x1F600);   /* 😀: 4 bytes */
    void *utf8_s = pion_strbuf_to_str(sb);
    assert(pion_str_len(utf8_s) == 10);
    assert(pion_str_byte_at(utf8_s, 0) == 'A');
    assert(pion_str_byte_at(utf8_s, 1) == 0xC3);
    assert(pion_str_byte_at(utf8_s, 2) == 0xA9);
    assert(pion_str_byte_at(utf8_s, 3) == 0xE4);
    assert(pion_str_byte_at(utf8_s, 6) == 0xF0);

    pion_rc_dec(a);
    pion_rc_dec(b);
    pion_rc_dec(c);
    pion_rc_dec(expected);
    pion_rc_dec(sl);
    pion_rc_dec(pions);
    pion_rc_dec(num_s);
    pion_rc_dec(bad);
    pion_rc_dec(ws);
    pion_rc_dec(sb);
    pion_rc_dec(built);
    pion_rc_dec(utf8_s);
    printf("[PASS] string_and_strbuf\n");
}

static void test_stdlib_string_bytes_math(void) {
    /* Math */
    assert(pion_math_abs(-3.5) == 3.5);
    assert(pion_math_abs(0.0) == 0.0);
    assert(pion_math_abs(7.25) == 7.25);
    assert(pion_math_floor(2.9) == 2.0);
    assert(pion_math_floor(-2.1) == -3.0);
    assert(pion_math_ceil(2.1) == 3.0);
    assert(pion_math_ceil(-2.9) == -2.0);
    assert(fabs(pion_math_sin(0.0)) < 1e-12);
    assert(fabs(pion_math_cos(0.0) - 1.0) < 1e-12);
    assert(fabs(pion_math_pow(2.0, 10.0) - 1024.0) < 1e-12);
    assert(fabs(pion_math_pow(9.0, 0.5) - 3.0) < 1e-12);

    /* starts_with / ends_with / contains / index_of */
    void *s = pion_str_from_cstr("hello, 世界! hello", -1);
    void *empty = pion_str_from_cstr("", 0);
    void *p_hello = pion_str_from_cstr("hello", -1);
    void *p_world = pion_str_from_cstr("世界", -1);
    void *p_bang = pion_str_from_cstr("!", 1);
    void *p_long = pion_str_from_cstr("hello, 世界! hello world", -1);
    void *p_miss = pion_str_from_cstr("xyz", 3);

    assert(pion_str_starts_with(s, p_hello) == 1);
    assert(pion_str_starts_with(s, empty) == 1);
    assert(pion_str_starts_with(s, p_long) == 0);
    assert(pion_str_starts_with(empty, empty) == 1);
    assert(pion_str_starts_with(empty, p_bang) == 0);
    assert(pion_str_starts_with(NULL, NULL) == 1);

    assert(pion_str_ends_with(s, p_hello) == 1);
    assert(pion_str_ends_with(s, empty) == 1);
    assert(pion_str_ends_with(s, p_long) == 0);
    assert(pion_str_ends_with(empty, p_bang) == 0);

    assert(pion_str_index_of(s, empty) == 0);
    assert(pion_str_index_of(empty, empty) == 0);
    assert(pion_str_index_of(s, p_hello) == 0);
    assert(pion_str_index_of(s, p_world) == 7);
    assert(pion_str_index_of(s, p_bang) == 13);
    assert(pion_str_index_of(s, p_miss) == -1);
    assert(pion_str_index_of(s, p_long) == -1);
    assert(pion_str_contains(s, p_world) == 1);
    assert(pion_str_contains(s, p_miss) == 0);
    assert(pion_str_contains(empty, empty) == 1);

    /* trim */
    void *ws1 = pion_str_from_cstr(" \t\r\n  hi \t there \r\n ", -1);
    void *tr1 = pion_str_trim(ws1);
    void *exp_tr1 = pion_str_from_cstr("hi \t there", -1);
    assert(pion_str_eq(tr1, exp_tr1) == 1);

    void *ws_all = pion_str_from_cstr(" \t\r\n ", -1);
    void *tr_all = pion_str_trim(ws_all);
    assert(pion_str_len(tr_all) == 0);

    void *tr_empty = pion_str_trim(empty);
    assert(pion_str_len(tr_empty) == 0);
    void *tr_null = pion_str_trim(NULL);
    assert(pion_str_len(tr_null) == 0);

    /* split */
    void *csv = pion_str_from_cstr(",a,,b,", -1);
    void *comma = pion_str_from_cstr(",", 1);
    void *parts = pion_str_split(csv, comma);
    assert(pion_arr_len(parts) == 5);
    const char *exp_parts[] = {"", "a", "", "b", ""};
    for (int i = 0; i < 5; i++) {
        void *ep = pion_str_from_cstr(exp_parts[i], -1);
        assert(pion_str_eq((void *)(uintptr_t)pion_arr_get(parts, i), ep) == 1);
        pion_rc_dec(ep);
    }

    /* split empty string with non-empty sep -> [""] */
    void *parts_empty = pion_str_split(empty, comma);
    assert(pion_arr_len(parts_empty) == 1);
    assert(pion_str_len((void *)(uintptr_t)pion_arr_get(parts_empty, 0)) == 0);

    /* split with empty sep -> per-byte (empty -> []) */
    void *abc = pion_str_from_cstr("abc", 3);
    void *parts_bytes = pion_str_split(abc, empty);
    assert(pion_arr_len(parts_bytes) == 3);
    assert(pion_str_byte_at((void *)(uintptr_t)pion_arr_get(parts_bytes, 0), 0) == 'a');
    assert(pion_str_byte_at((void *)(uintptr_t)pion_arr_get(parts_bytes, 2), 0) == 'c');
    void *parts_ee = pion_str_split(empty, empty);
    assert(pion_arr_len(parts_ee) == 0);

    /* split overlapping pattern */
    void *aaa = pion_str_from_cstr("aaa", 3);
    void *aa = pion_str_from_cstr("aa", 2);
    void *parts_ov = pion_str_split(aaa, aa);
    assert(pion_arr_len(parts_ov) == 2);
    assert(pion_str_len((void *)(uintptr_t)pion_arr_get(parts_ov, 0)) == 0);
    assert(pion_str_byte_at((void *)(uintptr_t)pion_arr_get(parts_ov, 1), 0) == 'a');

    /* replace */
    void *rep_grow = pion_str_replace(s, p_hello, p_world);
    void *exp_grow = pion_str_from_cstr("世界, 世界! 世界", -1);
    assert(pion_str_eq(rep_grow, exp_grow) == 1);

    void *rep_del = pion_str_replace(s, p_hello, empty);
    void *exp_del = pion_str_from_cstr(", 世界! ", -1);
    assert(pion_str_eq(rep_del, exp_del) == 1);

    /* replace empty from -> retain original without infinite loop */
    void *rep_empty_from = pion_str_replace(s, empty, p_bang);
    assert(rep_empty_from == s);
    assert(pion_str_eq(rep_empty_from, s) == 1);

    /* replace miss -> retain original */
    void *rep_miss = pion_str_replace(s, p_miss, p_bang);
    assert(rep_miss == s);

    /* Bytes: new / len / get / set / slice (clamped) / concat / str<->bytes */
    void *b0 = pion_bytes_new(0);
    assert(pion_bytes_len(b0) == 0);
    assert(pion_bytes_len(NULL) == 0);

    void *b = pion_bytes_new(6);
    assert(pion_bytes_len(b) == 6);
    for (int64_t i = 0; i < 6; i++) {
        assert(pion_bytes_get(b, i) == 0);
        pion_bytes_set(b, i, (int32_t)(i * 40 + 5));
    }
    pion_bytes_set(b, 5, 0x1AB); /* wraps to 0xAB */
    assert(pion_bytes_get(b, 0) == 5);
    assert(pion_bytes_get(b, 5) == 0xAB);

    void *bsl1 = pion_bytes_slice(b, -10, 3);
    assert(pion_bytes_len(bsl1) == 3);
    assert(pion_bytes_get(bsl1, 0) == 5 && pion_bytes_get(bsl1, 2) == 85);

    void *bsl2 = pion_bytes_slice(b, 4, 999);
    assert(pion_bytes_len(bsl2) == 2);
    assert(pion_bytes_get(bsl2, 0) == 165 && pion_bytes_get(bsl2, 1) == 0xAB);

    void *bsl3 = pion_bytes_slice(b, 5, 2); /* start > end -> empty */
    assert(pion_bytes_len(bsl3) == 0);
    void *bsl4 = pion_bytes_slice(b, 99, 100); /* start > len -> empty */
    assert(pion_bytes_len(bsl4) == 0);

    void *bcat = pion_bytes_concat(bsl1, bsl2);
    assert(pion_bytes_len(bcat) == 5);
    assert(pion_bytes_get(bcat, 0) == 5);
    assert(pion_bytes_get(bcat, 3) == 165);
    assert(pion_bytes_get(bcat, 4) == 0xAB);

    /* str <-> bytes roundtrip (including embedded NUL) */
    const char raw_nul[5] = {'a', '\0', 'b', (char)0xE4, 'z'};
    void *s_nul = pion_str_from_cstr(raw_nul, 5);
    void *b_nul = pion_str_to_bytes(s_nul);
    assert(pion_bytes_len(b_nul) == 5);
    assert(pion_bytes_get(b_nul, 1) == 0);
    assert(pion_bytes_get(b_nul, 3) == 0xE4);
    void *s_rt = pion_bytes_to_str(b_nul);
    assert(pion_str_eq(s_rt, s_nul) == 1);
    assert(((PionString *)s_rt)->data[5] == '\0');

    void *s_from_b0 = pion_bytes_to_str(b0);
    assert(pion_str_len(s_from_b0) == 0);

    pion_rc_dec(s); pion_rc_dec(empty); pion_rc_dec(p_hello); pion_rc_dec(p_world);
    pion_rc_dec(p_bang); pion_rc_dec(p_long); pion_rc_dec(p_miss);
    pion_rc_dec(ws1); pion_rc_dec(tr1); pion_rc_dec(exp_tr1);
    pion_rc_dec(ws_all); pion_rc_dec(tr_all); pion_rc_dec(tr_empty); pion_rc_dec(tr_null);
    pion_rc_dec(csv); pion_rc_dec(comma); pion_rc_dec(parts); pion_rc_dec(parts_empty);
    pion_rc_dec(abc); pion_rc_dec(parts_bytes); pion_rc_dec(parts_ee);
    pion_rc_dec(aaa); pion_rc_dec(aa); pion_rc_dec(parts_ov);
    pion_rc_dec(rep_grow); pion_rc_dec(exp_grow); pion_rc_dec(rep_del); pion_rc_dec(exp_del);
    pion_rc_dec(rep_empty_from); pion_rc_dec(rep_miss);
    pion_rc_dec(b0); pion_rc_dec(b); pion_rc_dec(bsl1); pion_rc_dec(bsl2);
    pion_rc_dec(bsl3); pion_rc_dec(bsl4); pion_rc_dec(bcat);
    pion_rc_dec(s_nul); pion_rc_dec(b_nul); pion_rc_dec(s_rt); pion_rc_dec(s_from_b0);
    printf("[PASS] stdlib_string_bytes_math\n");
}

static void test_array_and_map(void) {
    /* Primitive Array */
    void *arr = pion_arr_new(2, 0);
    for (int64_t i = 0; i < 100; i++) {
        pion_arr_push(arr, i * 3);
    }
    assert(pion_arr_len(arr) == 100);
    assert(pion_arr_get(arr, 50) == 150);
    pion_arr_set(arr, 50, 999);
    assert(pion_arr_get(arr, 50) == 999);
    assert(pion_arr_pop(arr) == 297);
    assert(pion_arr_len(arr) == 99);
    pion_rc_dec(arr);

    /* Object Array RC verification */
    atomic_store(&g_drop_count, 0);
    void *oarr = pion_arr_new(0, 1);
    for (int64_t i = 0; i < 20; i++) {
        void *n = test_node_new(i, NULL);
        pion_arr_push(oarr, (int64_t)(uintptr_t)n);
        pion_rc_dec(n);
    }
    void *rep = test_node_new(999, NULL);
    pion_arr_set(oarr, 5, (int64_t)(uintptr_t)rep);
    pion_rc_dec(rep);
    assert(atomic_load(&g_drop_count) == 1);
    void *popped = (void *)(uintptr_t)pion_arr_pop(oarr);
    assert(((TestNode *)popped)->id == 19);
    pion_rc_dec(popped);
    assert(atomic_load(&g_drop_count) == 2);

    /* pion_arr_copy retains object elements independently */
    void *oarr_cp = pion_arr_copy(oarr);
    assert(pion_arr_len(oarr_cp) == 19);
    assert(((TestNode *)(uintptr_t)pion_arr_get(oarr_cp, 5))->id == 999);
    pion_rc_dec(oarr);
    assert(atomic_load(&g_drop_count) == 2); /* elements still alive in copy */
    pion_rc_dec(oarr_cp);
    assert(atomic_load(&g_drop_count) == 21);

    /* Map (primitive + object values + growth + remove + copy) */
    atomic_store(&g_drop_count, 0);
    void *map = pion_map_new(1);
    for (int64_t i = 0; i < 128; i++) {
        void *k = pion_int_to_str(i);
        void *v = test_node_new(i * 10, NULL);
        pion_map_set(map, k, (int64_t)(uintptr_t)v);
        pion_rc_dec(k);
        pion_rc_dec(v);
    }
    assert(pion_map_len(map) == 128);
    void *k42 = pion_str_from_cstr("42", 2);
    void *kmiss = pion_str_from_cstr("missing", 7);
    assert(pion_map_has(map, k42) == 1);
    assert(pion_map_has(map, kmiss) == 0);
    TestNode *v42 = (TestNode *)(uintptr_t)pion_map_get(map, k42);
    assert(v42->id == 420);

    /* Overwrite existing key releases old value */
    void *vnew = test_node_new(4242, NULL);
    pion_map_set(map, k42, (int64_t)(uintptr_t)vnew);
    pion_rc_dec(vnew);
    assert(atomic_load(&g_drop_count) == 1);
    assert(pion_map_len(map) == 128);

    /* Map copy + remove half the keys + re-verify remaining + re-insert */
    void *map_cp = pion_map_copy(map);
    assert(pion_map_len(map_cp) == 128);
    for (int64_t i = 0; i < 64; i++) {
        void *k = pion_int_to_str(i * 2);
        pion_map_remove(map, k);
        assert(pion_map_has(map, k) == 0);
        assert(pion_map_has(map_cp, k) == 1);
        pion_rc_dec(k);
    }
    assert(pion_map_len(map) == 64);
    for (int64_t i = 0; i < 64; i++) {
        void *k = pion_int_to_str(i * 2 + 1);
        assert(pion_map_has(map, k) == 1);
        assert(((TestNode *)(uintptr_t)pion_map_get(map, k))->id == (i * 2 + 1) * 10);
        pion_rc_dec(k);
    }
    pion_map_remove(map, kmiss); /* removing non-existent key is a no-op */
    assert(pion_map_len(map) == 64);

    void *keys = pion_map_keys(map_cp);
    assert(pion_arr_len(keys) == 128);
    pion_rc_dec(keys);
    pion_rc_dec(k42);
    pion_rc_dec(kmiss);
    pion_rc_dec(map);
    pion_rc_dec(map_cp);
    assert(atomic_load(&g_drop_count) == 129);

    printf("[PASS] array_and_map\n");
}

static void test_map_try_get_and_100k(void) {
    /* Edge cases: NULL map, NULL key, empty map, NULL out_val */
    int64_t out = -999;
    void *k0 = pion_str_from_cstr("a", 1);
    assert(pion_map_try_get(NULL, k0, &out) == 0 && out == -999);
    void *empty_map = pion_map_new(0);
    assert(pion_map_try_get(empty_map, NULL, &out) == 0 && out == -999);
    assert(pion_map_try_get(empty_map, k0, &out) == 0 && out == -999);
    assert(pion_map_try_get(empty_map, k0, NULL) == 0);
    pion_rc_dec(k0);
    pion_rc_dec(empty_map);

    /* Hash length coverage (0..32 bytes: all tail branches + multi-block) + overwrite + remove */
    atomic_store(&g_drop_count, 0);
    void *omap = pion_map_new(1);
    const char *sample_keys[] = {
        "", "a", "ab", "abc", "abcd", "abcde", "abcdef", "abcdefg",
        "abcdefgh", "abcdefghi", "0123456789abcde", "0123456789abcdef",
        "0123456789abcdefX", "0123456789abcdef0123456789abcdef"
    };
    const size_t n_samples = sizeof(sample_keys) / sizeof(sample_keys[0]);
    for (size_t i = 0; i < n_samples; i++) {
        void *k = pion_str_from_cstr(sample_keys[i], -1);
        void *v = test_node_new((int64_t)(i + 1), NULL);
        pion_map_set(omap, k, (int64_t)(uintptr_t)v);
        pion_rc_dec(k);
        pion_rc_dec(v);
    }
    for (size_t i = 0; i < n_samples; i++) {
        void *k = pion_str_from_cstr(sample_keys[i], -1);
        int64_t val = 0;
        assert(pion_map_try_get(omap, k, &val) == 1);
        assert(((TestNode *)(uintptr_t)val)->id == (int64_t)(i + 1));
        assert(pion_map_try_get(omap, k, NULL) == 1);
        pion_rc_dec(k);
    }
    /* Overwrite & remove */
    void *k_ov = pion_str_from_cstr("abcde", 5);
    void *v_ov = test_node_new(9999, NULL);
    pion_map_set(omap, k_ov, (int64_t)(uintptr_t)v_ov);
    pion_rc_dec(v_ov);
    assert(atomic_load(&g_drop_count) == 1);
    int64_t ov_out = 0;
    assert(pion_map_try_get(omap, k_ov, &ov_out) == 1);
    assert(((TestNode *)(uintptr_t)ov_out)->id == 9999);

    pion_map_remove(omap, k_ov);
    ov_out = -777;
    assert(pion_map_try_get(omap, k_ov, &ov_out) == 0 && ov_out == -777);
    pion_rc_dec(k_ov);
    pion_rc_dec(omap);
    assert(atomic_load(&g_drop_count) == (int64_t)(n_samples + 1));

    /* 100k keys insert + growth + try_get verification + remove + throughput timing */
    const int64_t N = 100000;
    void **keys = (void **)malloc((size_t)N * sizeof(void *));
    assert(keys != NULL);
    void *big_map = pion_map_new(0);
    char kbuf[32];
    for (int64_t i = 0; i < N; i++) {
        int n = snprintf(kbuf, sizeof(kbuf), "pion_key_%06" PRId64, i);
        keys[i] = pion_str_from_cstr(kbuf, n);
        pion_map_set(big_map, keys[i], i * 7 + 3);
    }
    assert(pion_map_len(big_map) == N);

    /* Timed 100k pion_map_try_get lookups */
    double t0 = monotonic_sec();
    int64_t checksum = 0;
    for (int64_t i = 0; i < N; i++) {
        int64_t v = 0;
        int32_t hit = pion_map_try_get(big_map, keys[i], &v);
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
        void *mk = pion_str_from_cstr(kbuf, n);
        int64_t v = -1;
        assert(pion_map_try_get(big_map, mk, &v) == 0 && v == -1);
        pion_rc_dec(mk);
    }

    /* Remove every 4th key and re-verify hit/miss */
    for (int64_t i = 0; i < N; i += 4) {
        pion_map_remove(big_map, keys[i]);
    }
    assert(pion_map_len(big_map) == (N * 3) / 4);
    for (int64_t i = 0; i < N; i++) {
        int64_t v = 0;
        int32_t hit = pion_map_try_get(big_map, keys[i], &v);
        if ((i & 3) == 0) {
            assert(hit == 0);
        } else {
            assert(hit == 1 && v == i * 7 + 3);
        }
    }

    for (int64_t i = 0; i < N; i++) {
        pion_rc_dec(keys[i]);
    }
    free(keys);
    pion_rc_dec(big_map);

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
        void *s = pion_str_from_cstr(vecs[i].in, -1);
        void *h = pion_sha256_hex(s);
        void *exp = pion_str_from_cstr(vecs[i].hex, 64);
        assert(pion_str_eq(h, exp) == 1);
        pion_rc_dec(s);
        pion_rc_dec(h);
        pion_rc_dec(exp);
    }
    printf("[PASS] sha256\n");
}

static void test_world(int argc, char **argv) {
    void *w = pion_world_init(argc, argv);
    assert(pion_world_argc(w) == argc);
    if (argc > 0) {
        void *a0 = pion_world_argv(w, 0);
        assert(pion_str_len(a0) > 0);
        pion_rc_dec(a0);
    }

    int64_t t0 = pion_world_clock_ms(w);
    assert(t0 > 1700000000000LL);

    /* env_get */
    void *path_key = pion_str_from_cstr("PATH", 4);
    int32_t ok = 0;
    void *path_val = pion_world_env_get(w, path_key, &ok);
    assert(ok == 1 && pion_str_len(path_val) > 0);
    pion_rc_dec(path_key);
    pion_rc_dec(path_val);

    void *missing_key = pion_str_from_cstr("PION_NONEXISTENT_ENV_VAR_XYZ", -1);
    void *missing_val = pion_world_env_get(w, missing_key, &ok);
    assert(ok == 0 && pion_str_len(missing_val) == 0);
    pion_rc_dec(missing_key);
    pion_rc_dec(missing_val);

    /* fs_mkdir_p / fs_write / fs_exists / fs_size / fs_read / fs_rename / fs_list_dir / fs_remove */
    char dir_buf[256];
    snprintf(dir_buf, sizeof(dir_buf), "%s/pion_rt_test_%d/sub", pion_test_tmpdir(), pion_test_getpid());
    void *dir_s = pion_str_from_cstr(dir_buf, -1);
    assert(pion_world_fs_mkdir_p(w, dir_s) == 1);
    assert(pion_world_fs_exists(w, dir_s) == 1);

    char file_buf[300];
    snprintf(file_buf, sizeof(file_buf), "%s/zeta.tmp", dir_buf);
    void *file_tmp = pion_str_from_cstr(file_buf, -1);
    void *content = pion_str_from_cstr("pion world fs payload\n", -1);
    assert(pion_world_fs_write(w, file_tmp, content) == 1);
    assert(pion_world_fs_exists(w, file_tmp) == 1);
    assert(pion_world_fs_size(w, file_tmp) == 22);

    /* Atomic rename */
    char file_zeta[300];
    snprintf(file_zeta, sizeof(file_zeta), "%s/zeta.txt", dir_buf);
    void *zeta_s = pion_str_from_cstr(file_zeta, -1);
    assert(pion_world_fs_rename(w, file_tmp, zeta_s) == 1);
    assert(pion_world_fs_exists(w, file_tmp) == 0);
    assert(pion_world_fs_size(w, file_tmp) == -1);
    assert(pion_world_fs_exists(w, zeta_s) == 1);
    assert(pion_world_fs_size(w, zeta_s) == 22);

    void *read_back = pion_world_fs_read(w, zeta_s, &ok);
    assert(ok == 1 && pion_str_eq(read_back, content) == 1);

    /* Write unsorted filenames and verify deterministic lexicographical order */
    const char *extra_names[] = {"mid.txt", "alpha.txt", "beta.txt"};
    char extra_paths[3][300];
    for (int i = 0; i < 3; i++) {
        snprintf(extra_paths[i], sizeof(extra_paths[i]), "%s/%s", dir_buf, extra_names[i]);
        void *ps = pion_str_from_cstr(extra_paths[i], -1);
        assert(pion_world_fs_write(w, ps, content) == 1);
        pion_rc_dec(ps);
    }

    void *entries = pion_world_fs_list_dir(w, dir_s);
    assert(pion_world_fs_is_dir(w, dir_s) == 1);
    assert(pion_world_fs_is_dir(w, zeta_s) == 0);
    assert(pion_arr_len(entries) == 4);
    const char *sorted_expected[] = {"alpha.txt", "beta.txt", "mid.txt", "zeta.txt"};
    for (int i = 0; i < 4; i++) {
        void *exp = pion_str_from_cstr(sorted_expected[i], -1);
        assert(pion_str_eq((void *)(uintptr_t)pion_arr_get(entries, i), exp) == 1);
        pion_rc_dec(exp);
    }

    /* fs_remove */
    assert(pion_world_fs_remove(w, zeta_s) == 1);
    assert(pion_world_fs_exists(w, zeta_s) == 0);
    assert(pion_world_fs_remove(w, zeta_s) == 0);

    /* exec */
    void *cmd = pion_arr_new(3, 1);
    void *sh = pion_str_from_cstr(PION_TEST_SH, -1);
    void *flag = pion_str_from_cstr("-c", -1);
    void *script = pion_str_from_cstr("exit 42", -1);
    pion_arr_push(cmd, (int64_t)(uintptr_t)sh);
    pion_arr_push(cmd, (int64_t)(uintptr_t)flag);
    pion_arr_push(cmd, (int64_t)(uintptr_t)script);
    assert(pion_world_exec(w, cmd) == 42);

    /* fs_read_bytes / fs_write_bytes / fs_append / fs_mtime_ms */
    char bin_path_buf[300];
    snprintf(bin_path_buf, sizeof(bin_path_buf), "%s/bin.dat", dir_buf);
    void *bin_path = pion_str_from_cstr(bin_path_buf, -1);
    assert(pion_world_fs_mtime_ms(w, bin_path) == -1);
    void *raw_b = pion_bytes_new(256);
    for (int i = 0; i < 256; i++) {
        pion_bytes_set(raw_b, i, i);
    }
    assert(pion_world_fs_write_bytes(w, bin_path, raw_b) == 1);
    int64_t mtime = pion_world_fs_mtime_ms(w, bin_path);
    assert(mtime > 1700000000000LL);
    void *read_b = pion_world_fs_read_bytes(w, bin_path, &ok);
    assert(ok == 1 && pion_bytes_len(read_b) == 256);
    for (int i = 0; i < 256; i++) {
        assert(pion_bytes_get(read_b, i) == i);
    }
    void *missing_b_path = pion_str_from_cstr("/nonexistent_pion_bytes_file_xyz", -1);
    void *missing_b = pion_world_fs_read_bytes(w, missing_b_path, &ok);
    assert(ok == 0 && pion_bytes_len(missing_b) == 0);
    pion_test_unlink(bin_path_buf);

    /* fs_append */
    char app_path_buf[300];
    snprintf(app_path_buf, sizeof(app_path_buf), "%s/app.log", dir_buf);
    void *app_path = pion_str_from_cstr(app_path_buf, -1);
    void *line1 = pion_str_from_cstr("first\n", -1);
    void *line2 = pion_str_from_cstr("second\n", -1);
    assert(pion_world_fs_append(w, app_path, line1) == 1);
    assert(pion_world_fs_append(w, app_path, line2) == 1);
    void *app_read = pion_world_fs_read(w, app_path, &ok);
    void *app_exp = pion_str_from_cstr("first\nsecond\n", -1);
    assert(ok == 1 && pion_str_eq(app_read, app_exp) == 1);
    pion_test_unlink(app_path_buf);

    /* exec_capture: normal, non-zero exit, missing binary, and >64KB stdout (no pipe deadlock) */
    int32_t cap_code = -1;
    void *cap_cmd1 = pion_arr_new(3, 1);
    void *cap_s1 = pion_str_from_cstr("printf 'hello-capture'; exit 7", -1);
    pion_arr_push(cap_cmd1, (int64_t)(uintptr_t)sh);
    pion_arr_push(cap_cmd1, (int64_t)(uintptr_t)flag);
    pion_arr_push(cap_cmd1, (int64_t)(uintptr_t)cap_s1);
    void *cap_out1 = pion_world_exec_capture(w, cap_cmd1, &cap_code);
    void *cap_exp1 = pion_str_from_cstr("hello-capture", -1);
    assert(cap_code == 7 && pion_str_eq(cap_out1, cap_exp1) == 1);

    /* Large stdout (>128 KB, well over OS 64KB pipe buffer) */
    void *cap_cmd_big = pion_arr_new(3, 1);
    void *cap_s_big = pion_str_from_cstr("head -c 131072 /dev/zero | tr '\\0' 'A'", -1);
    pion_arr_push(cap_cmd_big, (int64_t)(uintptr_t)sh);
    pion_arr_push(cap_cmd_big, (int64_t)(uintptr_t)flag);
    pion_arr_push(cap_cmd_big, (int64_t)(uintptr_t)cap_s_big);
    void *cap_out_big = pion_world_exec_capture(w, cap_cmd_big, &cap_code);
    assert(cap_code == 0 && pion_str_len(cap_out_big) == 131072);
    assert(pion_str_byte_at(cap_out_big, 0) == 'A' && pion_str_byte_at(cap_out_big, 131071) == 'A');

    /* Missing binary -> exit 127 */
    void *cap_cmd_miss = pion_arr_new(1, 1);
    void *cap_s_miss = pion_str_from_cstr("/nonexistent_pion_cap_cmd_xyz", -1);
    pion_arr_push(cap_cmd_miss, (int64_t)(uintptr_t)cap_s_miss);
    void *cap_out_miss = pion_world_exec_capture(w, cap_cmd_miss, &cap_code);
    assert(cap_code == 127 && pion_str_len(cap_out_miss) == 0);

    pion_rc_dec(bin_path); pion_rc_dec(raw_b); pion_rc_dec(read_b);
    pion_rc_dec(missing_b_path); pion_rc_dec(missing_b);
    pion_rc_dec(app_path); pion_rc_dec(line1); pion_rc_dec(line2);
    pion_rc_dec(app_read); pion_rc_dec(app_exp);
    pion_rc_dec(cap_cmd1); pion_rc_dec(cap_s1); pion_rc_dec(cap_out1); pion_rc_dec(cap_exp1);
    pion_rc_dec(cap_cmd_big); pion_rc_dec(cap_s_big); pion_rc_dec(cap_out_big);
    pion_rc_dec(cap_cmd_miss); pion_rc_dec(cap_s_miss); pion_rc_dec(cap_out_miss);

    /* cleanup temp files */
    for (int i = 0; i < 3; i++) {
        pion_test_unlink(extra_paths[i]);
    }
    pion_test_rmdir(dir_buf);
    snprintf(dir_buf, sizeof(dir_buf), "%s/pion_rt_test_%d", pion_test_tmpdir(), pion_test_getpid());
    pion_test_rmdir(dir_buf);

    pion_rc_dec(sh);
    pion_rc_dec(flag);
    pion_rc_dec(script);
    pion_rc_dec(cmd);
    pion_rc_dec(entries);
    pion_rc_dec(read_back);
    pion_rc_dec(content);
    pion_rc_dec(zeta_s);
    pion_rc_dec(file_tmp);
    pion_rc_dec(dir_s);
    pion_rc_dec(w);
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
    pion_rc_dec(e->str);
    pion_rc_dec(e->node);
    pion_rc_dec(e->counter);
}

static void shared_rc_worker(void *arg) {
    SharedRcEnv *e = (SharedRcEnv *)arg;
    for (int i = 0; i < 2000; i++) {
        pion_rc_inc(e->str);
        pion_rc_inc(e->node);
        assert(pion_str_len(e->str) == 13);
        assert(((TestNode *)e->node)->id == 777);
        pion_rc_dec(e->node);
        pion_rc_dec(e->str);
    }
    pion_atomic_fetch_add(e->counter, 1);
}

static void test_mt_shared_rc(void) {
    atomic_store(&g_drop_count, 0);
    void *str = pion_str_from_cstr("frozen-string", 13);
    void *node = test_node_new(777, NULL);
    void *counter = pion_atomic_new(0);
    pion_rc_freeze(str);
    pion_rc_freeze(node);

    SharedRcEnv *env = (SharedRcEnv *)pion_alloc((uint32_t)sizeof(SharedRcEnv),
                                               PION_TAG_STRUCT, shared_rc_env_drop);
    pion_rc_inc(str);
    pion_rc_inc(node);
    pion_rc_inc(counter);
    env->str = str;
    env->node = node;
    env->counter = counter;

    void *sc = pion_scope_begin();
    for (int i = 0; i < 8; i++) {
        pion_scope_spawn(sc, shared_rc_worker, env);
    }
    pion_scope_end(sc);

    assert(pion_atomic_load(counter) == 8);
    pion_rc_dec(env);
    pion_rc_dec(str);
    pion_rc_dec(node);
    pion_rc_dec(counter);
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
    pion_rc_dec(e->ch);
    pion_rc_dec(e->sum_atomic);
    pion_rc_dec(e->cnt_atomic);
}

static void chan_producer(void *arg) {
    ChanEnv *e = (ChanEnv *)arg;
    for (int64_t i = 0; i < e->count; i++) {
        void *n = test_node_new(e->start + i, NULL);
        int32_t ok = pion_chan_send(e->ch, (int64_t)(uintptr_t)n);
        assert(ok == 1);
        pion_rc_dec(n);
    }
}

static void chan_consumer(void *arg) {
    ChanEnv *e = (ChanEnv *)arg;
    int64_t local_sum = 0;
    int64_t local_cnt = 0;
    int64_t val = 0;
    while (pion_chan_recv(e->ch, &val)) {
        TestNode *n = (TestNode *)(uintptr_t)val;
        local_sum += n->id;
        local_cnt++;
        pion_rc_dec(n);
    }
    pion_atomic_fetch_add(e->sum_atomic, local_sum);
    pion_atomic_fetch_add(e->cnt_atomic, local_cnt);
}

static void test_mt_channel_10k(void) {
    atomic_store(&g_drop_count, 0);
    const int64_t total_msgs = 10000;
    const int n_prod = 4;
    const int n_cons = 4;
    const int64_t per_prod = total_msgs / n_prod;

    void *ch = pion_chan_new(64, 1); /* bounded MPMC channel of frozen objects */
    void *sum_a = pion_atomic_new(0);
    void *cnt_a = pion_atomic_new(0);

    void *cons_scope = pion_scope_begin();
    for (int i = 0; i < n_cons; i++) {
        ChanEnv *e = (ChanEnv *)pion_alloc((uint32_t)sizeof(ChanEnv), PION_TAG_STRUCT, chan_env_drop);
        pion_rc_inc(ch); pion_rc_inc(sum_a); pion_rc_inc(cnt_a);
        e->ch = ch; e->sum_atomic = sum_a; e->cnt_atomic = cnt_a;
        pion_scope_spawn(cons_scope, chan_consumer, e);
        pion_rc_dec(e);
    }

    void *prod_scope = pion_scope_begin();
    for (int i = 0; i < n_prod; i++) {
        ChanEnv *e = (ChanEnv *)pion_alloc((uint32_t)sizeof(ChanEnv), PION_TAG_STRUCT, chan_env_drop);
        pion_rc_inc(ch); pion_rc_inc(sum_a); pion_rc_inc(cnt_a);
        e->ch = ch; e->sum_atomic = sum_a; e->cnt_atomic = cnt_a;
        e->start = i * per_prod + 1;
        e->count = per_prod;
        pion_scope_spawn(prod_scope, chan_producer, e);
        pion_rc_dec(e);
    }
    pion_scope_end(prod_scope);
    pion_chan_close(ch);
    pion_scope_end(cons_scope);

    int64_t expected_sum = total_msgs * (total_msgs + 1) / 2;
    assert(pion_atomic_load(cnt_a) == total_msgs);
    assert(pion_atomic_load(sum_a) == expected_sum);
    assert(pion_chan_send(ch, 0) == 0); /* closed channel rejects sends */

    pion_rc_dec(ch);
    pion_rc_dec(sum_a);
    pion_rc_dec(cnt_a);
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
    pion_rc_dec(e->mu_int);
    pion_rc_dec(e->mu_obj);
    pion_rc_dec(e->atom);
}

static void sync_worker(void *arg) {
    SyncEnv *e = (SyncEnv *)arg;
    for (int i = 0; i < 5000; i++) {
        int64_t v = pion_mutex_lock(e->mu_int);
        pion_mutex_set_and_unlock(e->mu_int, v + 1);
        pion_atomic_fetch_add(e->atom, 1);
    }
    for (int i = 0; i < 200; i++) {
        void *old_ptr = (void *)(uintptr_t)pion_mutex_lock(e->mu_obj);
        int64_t next_id = ((TestNode *)old_ptr)->id + 1;
        void *next_node = test_node_new(next_id, NULL);
        pion_mutex_set_and_unlock(e->mu_obj, (int64_t)(uintptr_t)next_node);
        pion_rc_dec(next_node);
    }
}

static void test_mt_mutex_and_atomic(void) {
    atomic_store(&g_drop_count, 0);
    void *mu_int = pion_mutex_new(0, 0);
    void *init_node = test_node_new(0, NULL);
    void *mu_obj = pion_mutex_new((int64_t)(uintptr_t)init_node, 1);
    pion_rc_dec(init_node);
    void *atom = pion_atomic_new(0);

    SyncEnv *env = (SyncEnv *)pion_alloc((uint32_t)sizeof(SyncEnv), PION_TAG_STRUCT, sync_env_drop);
    pion_rc_inc(mu_int); pion_rc_inc(mu_obj); pion_rc_inc(atom);
    env->mu_int = mu_int; env->mu_obj = mu_obj; env->atom = atom;

    void *sc = pion_scope_begin();
    for (int i = 0; i < 8; i++) {
        pion_scope_spawn(sc, sync_worker, env);
    }
    pion_scope_end(sc);

    int64_t final_int = pion_mutex_lock(mu_int);
    pion_mutex_unlock(mu_int);
    assert(final_int == 8 * 5000);
    assert(pion_atomic_load(atom) == 8 * 5000);

    TestNode *final_node = (TestNode *)(uintptr_t)pion_mutex_lock(mu_obj);
    assert(final_node->id == 8 * 200);
    pion_mutex_unlock(mu_obj);

    pion_rc_dec(env);
    pion_rc_dec(mu_int);
    pion_rc_dec(mu_obj);
    pion_rc_dec(atom);
    assert(atomic_load(&g_drop_count) == 1 + 8 * 200);
    printf("[PASS] mt_mutex_and_atomic (8 threads)\n");
}

/* P17-A: `Mutex[Array[String]]` and `Mutex[Map[String, Array[String]]]`.
 * Freezing a container freezes its elements recursively; every object stored
 * into a frozen container later (push / push_owned / set / map_set) is frozen
 * too, so strings created on one worker and released on another keep a
 * correct atomic RC (ASan/LSan: no leak, no double free; TSan: no race). */
typedef struct DeepEnv {
    void *mu_arr;
    void *mu_map;
} DeepEnv;

static void deep_env_drop(void *p) {
    DeepEnv *e = (DeepEnv *)p;
    pion_rc_dec(e->mu_arr);
    pion_rc_dec(e->mu_map);
}

static int is_frozen_obj(void *obj) {
    return ((PionHeader *)obj - 1)->owner_tid == 0;
}

static _Atomic int64_t g_deep_seq = 0;

static void deep_worker(void *arg) {
    DeepEnv *e = (DeepEnv *)arg;
    PION_STATIC_STRING_DEF(kKeyPrefix, "k");
    for (int i = 0; i < 2000; i++) {
        int64_t seq = atomic_fetch_add_explicit(&g_deep_seq, 1, memory_order_relaxed);
        void *s = pion_int_to_str(seq);
        void *arr = (void *)(uintptr_t)pion_mutex_lock(e->mu_arr);
        assert(is_frozen_obj(arr));
        if ((i & 3) == 3 && pion_arr_len(arr) > 0) {
            /* Release (on this thread) a string another worker created. */
            void *popped = (void *)(uintptr_t)pion_arr_pop(arr);
            assert(is_frozen_obj(popped));
            pion_rc_dec(popped);
        } else {
            if ((i & 7) == 5 && pion_arr_len(arr) > 0) {
                pion_arr_set(arr, 0, (int64_t)(uintptr_t)s);
            } else if ((i & 1) == 0) {
                pion_rc_inc(s);
                pion_arr_push_owned(arr, (int64_t)(uintptr_t)s);
            } else {
                pion_arr_push(arr, (int64_t)(uintptr_t)s);
            }
            assert(is_frozen_obj(s));
        }
        pion_mutex_unlock(e->mu_arr);
        pion_rc_dec(s);

        void *num = pion_int_to_str(i & 15);
        void *key = pion_str_concat(kKeyPrefix, num);
        pion_rc_dec(num);
        void *m = (void *)(uintptr_t)pion_mutex_lock(e->mu_map);
        int64_t got = 0;
        void *bucket;
        if (pion_map_try_get(m, key, &got)) {
            bucket = (void *)(uintptr_t)got;
        } else {
            void *fresh = pion_arr_new(0, 1);
            pion_map_set(m, key, (int64_t)(uintptr_t)fresh);
            assert(is_frozen_obj(fresh));
            pion_rc_dec(fresh);
            bucket = fresh;
        }
        void *v = pion_int_to_str(seq);
        pion_arr_push(bucket, (int64_t)(uintptr_t)v);
        assert(is_frozen_obj(v));
        pion_mutex_unlock(e->mu_map);
        pion_rc_dec(v);
        pion_rc_dec(key);
    }
}

static void test_mt_mutex_deep_containers(void) {
    void *arr0 = pion_arr_new(0, 1);
    void *a = pion_int_to_str(-1);
    void *b = pion_int_to_str(-2);
    pion_arr_push(arr0, (int64_t)(uintptr_t)a);
    pion_arr_push(arr0, (int64_t)(uintptr_t)b);
    void *map0 = pion_map_new(1);
    void *inner = pion_arr_new(0, 1);
    pion_arr_push(inner, (int64_t)(uintptr_t)a);
    PION_STATIC_STRING_DEF(kSeed, "seed");
    pion_map_set(map0, kSeed, (int64_t)(uintptr_t)inner);
    void *mu_arr = pion_mutex_new((int64_t)(uintptr_t)arr0, 1);
    void *mu_map = pion_mutex_new((int64_t)(uintptr_t)map0, 1);
    /* Recursive freeze reaches array elements and map -> array -> string. */
    assert(is_frozen_obj(arr0) && is_frozen_obj(a) && is_frozen_obj(b));
    assert(is_frozen_obj(map0) && is_frozen_obj(inner));
    pion_rc_dec(a);
    pion_rc_dec(b);
    pion_rc_dec(inner);
    pion_rc_dec(arr0);
    pion_rc_dec(map0);

    DeepEnv *env = (DeepEnv *)pion_alloc((uint32_t)sizeof(DeepEnv), PION_TAG_STRUCT, deep_env_drop);
    pion_rc_inc(mu_arr);
    pion_rc_inc(mu_map);
    env->mu_arr = mu_arr;
    env->mu_map = mu_map;
    void *sc = pion_scope_begin();
    for (int t = 0; t < 8; t++) {
        pion_scope_spawn(sc, deep_worker, env);
    }
    pion_scope_end(sc);

    void *arr = (void *)(uintptr_t)pion_mutex_lock(mu_arr);
    int64_t n = pion_arr_len(arr);
    for (int64_t i = 0; i < n; i++) {
        assert(is_frozen_obj((void *)(uintptr_t)pion_arr_get(arr, i)));
    }
    pion_mutex_unlock(mu_arr);
    /* Per worker: 2000 ops, 1/4 pops (when non-empty), 1/8 sets, rest pushes. */
    assert(n > 0 && n <= 2 + 8 * 2000);
    void *m = (void *)(uintptr_t)pion_mutex_lock(mu_map);
    int64_t total = 0;
    void *keys = pion_map_keys(m);
    for (int64_t i = 0; i < pion_arr_len(keys); i++) {
        void *bucket = (void *)(uintptr_t)pion_map_get(m, (void *)(uintptr_t)pion_arr_get(keys, i));
        assert(is_frozen_obj(bucket));
        total += pion_arr_len(bucket);
    }
    pion_rc_dec(keys);
    pion_mutex_unlock(mu_map);
    assert(total == 1 + 8 * 2000);
    pion_rc_dec(env);
    pion_rc_dec(mu_arr);
    pion_rc_dec(mu_map);
    printf("[PASS] mt_mutex_deep_containers (8 threads, Mutex[Array[String]] n=%" PRId64
           ", Mutex[Map[String, Array[String]]] total=%" PRId64 ")\n", n, total);
}

static void test_str_to_double(void) {
    int32_t ok = 7;
    PION_STATIC_STRING_DEF(kD1, "3.25");
    PION_STATIC_STRING_DEF(kD2, "-1e3");
    PION_STATIC_STRING_DEF(kD3, "+.5");
    PION_STATIC_STRING_DEF(kBad1, "");
    PION_STATIC_STRING_DEF(kBad2, " 1.0");
    PION_STATIC_STRING_DEF(kBad3, "1.5x");
    PION_STATIC_STRING_DEF(kBad4, "-inf");
    PION_STATIC_STRING_DEF(kBad5, "nan");
    assert(pion_str_to_double(kD1, &ok) == 3.25 && ok == 1);
    assert(pion_str_to_double(kD2, &ok) == -1000.0 && ok == 1);
    assert(pion_str_to_double(kD3, &ok) == 0.5 && ok == 1);
    void *bads[] = { kBad1, kBad2, kBad3, kBad4, kBad5 };
    for (int i = 0; i < 5; i++) {
        ok = 7;
        assert(pion_str_to_double(bads[i], &ok) == 0.0 && ok == 0);
    }
    printf("[PASS] str_to_double\n");
}

static void nested_leaf(void *arg) {
    pion_atomic_fetch_add(arg, 1);
}

static void nested_mid(void *arg) {
    void *inner = pion_scope_begin();
    for (int i = 0; i < 2; i++) {
        pion_scope_spawn(inner, nested_leaf, arg);
    }
    pion_scope_end(inner);
}

typedef struct ParentScopeEnv {
    void *parent_scope;
    void *atom;
} ParentScopeEnv;

static void parent_scope_env_drop(void *p) {
    ParentScopeEnv *e = (ParentScopeEnv *)p;
    pion_rc_dec(e->parent_scope);
    pion_rc_dec(e->atom);
}

static void child_spawning_into_parent(void *arg) {
    ParentScopeEnv *e = (ParentScopeEnv *)arg;
    for (int i = 0; i < 3; i++) {
        pion_scope_spawn(e->parent_scope, nested_leaf, e->atom);
    }
}

static void test_mt_nested_scope(void) {
    void *atom = pion_atomic_new(0);
    void *outer = pion_scope_begin();
    for (int i = 0; i < 4; i++) {
        pion_scope_spawn(outer, nested_mid, atom);
    }
    pion_scope_end(outer);
    assert(pion_atomic_load(atom) == 8);

    /* Child threads capturing parent scope & spawning into it concurrently */
    void *shared_scope = pion_scope_begin();
    ParentScopeEnv *penv = (ParentScopeEnv *)pion_alloc(
        (uint32_t)sizeof(ParentScopeEnv), PION_TAG_STRUCT, parent_scope_env_drop);
    pion_rc_inc(shared_scope);
    pion_rc_inc(atom);
    penv->parent_scope = shared_scope;
    penv->atom = atom;
    for (int i = 0; i < 4; i++) {
        pion_scope_spawn(shared_scope, child_spawning_into_parent, penv);
    }
    pion_rc_dec(penv);
    pion_scope_end(shared_scope);
    assert(pion_atomic_load(atom) == 8 + 4 * 3);

    pion_rc_dec(atom);
    printf("[PASS] mt_nested_scope (4x2 nested + 4x3 parent-scope spawn)\n");
}

/* A 3 MiB stack frame, every page written then read back: needs spawn
 * threads' 8 MiB stacks (macOS secondary pthreads default to 512 KiB and
 * would hit the guard page with SIGBUS). */
#if defined(__GNUC__) || defined(__clang__)
__attribute__((noinline))
#endif
static int64_t deep_stack_frame(int64_t seed) {
    volatile unsigned char buf[3u * 1024u * 1024u];
    for (size_t i = 0; i < sizeof(buf); i += 4096) buf[i] = (unsigned char)(seed + (int64_t)(i >> 12));
    buf[sizeof(buf) - 1] = (unsigned char)seed;
    int64_t sum = 0;
    for (size_t i = 0; i < sizeof(buf); i += 4096) sum += buf[i];
    return sum + buf[sizeof(buf) - 1];
}

static void deep_stack_worker(void *arg) {
    pion_atomic_fetch_add(arg, deep_stack_frame(7));
}

static void test_mt_spawn_stack_8mib(void) {
    int64_t want = 0;
    for (size_t i = 0; i < 3u * 1024u * 1024u; i += 4096) want += (unsigned char)(7 + (int64_t)(i >> 12));
    want += 7;
    void *atom = pion_atomic_new(0);
    void *sc = pion_scope_begin();
    for (int i = 0; i < 4; i++) pion_scope_spawn(sc, deep_stack_worker, atom);
    pion_scope_end(sc);
    assert(pion_atomic_load(atom) == 4 * want);
    pion_rc_dec(atom);
    printf("[PASS] mt_spawn_stack_8mib (4 spawn threads x 3 MiB stack frame)\n");
}

typedef struct SlabStressEnv {
    void *ch;
    int64_t count;
    int64_t tid_idx;
} SlabStressEnv;

static void slab_stress_env_drop(void *p) {
    SlabStressEnv *e = (SlabStressEnv *)p;
    pion_rc_dec(e->ch);
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
        int64_t *loc = (int64_t *)pion_alloc(lsz, PION_TAG_STRUCT, slab_obj_drop);
        assert(loc[0] == 0); /* Verify zero-initialization */
        loc[0] = i + 1;
        pion_rc_dec(loc);

        /* Cross-thread alloc -> freeze -> send -> remote free */
        uint32_t rsz = sizes[(size_t)i & 7u];
        int64_t *rem = (int64_t *)pion_alloc(rsz, PION_TAG_STRUCT, slab_obj_drop);
        assert(rem[0] == 0);
        rem[0] = (e->tid_idx << 32) | i;
        assert(pion_chan_send(e->ch, (int64_t)(uintptr_t)rem) == 1);
        pion_rc_dec(rem);
    }
}

static void slab_consumer_worker(void *arg) {
    SlabStressEnv *e = (SlabStressEnv *)arg;
    int64_t val = 0;
    while (pion_chan_recv(e->ch, &val)) {
        int64_t *obj = (int64_t *)(uintptr_t)val;
        assert(obj[0] >= 0);
        /* Also allocate locally to trigger draining g_slab_remote */
        int64_t *tmp = (int64_t *)pion_alloc(32u, PION_TAG_STRUCT, slab_obj_drop);
        assert(tmp[0] == 0);
        tmp[0] = obj[0];
        pion_rc_dec(tmp);
        pion_rc_dec(obj);
    }
}

static void test_mt_slab_stress(void) {
    atomic_store(&g_drop_count, 0);
    const int n_prod = 4;
    const int n_cons = 4;
    const int64_t per_prod = 5000;

    void *ch = pion_chan_new(128, 1);

    void *cons_scope = pion_scope_begin();
    for (int i = 0; i < n_cons; i++) {
        SlabStressEnv *e = (SlabStressEnv *)pion_alloc((uint32_t)sizeof(SlabStressEnv),
                                                     PION_TAG_STRUCT, slab_stress_env_drop);
        pion_rc_inc(ch);
        e->ch = ch;
        e->count = per_prod;
        e->tid_idx = i;
        pion_scope_spawn(cons_scope, slab_consumer_worker, e);
        pion_rc_dec(e);
    }

    void *prod_scope = pion_scope_begin();
    for (int i = 0; i < n_prod; i++) {
        SlabStressEnv *e = (SlabStressEnv *)pion_alloc((uint32_t)sizeof(SlabStressEnv),
                                                     PION_TAG_STRUCT, slab_stress_env_drop);
        pion_rc_inc(ch);
        e->ch = ch;
        e->count = per_prod;
        e->tid_idx = i;
        pion_scope_spawn(prod_scope, slab_producer_worker, e);
        pion_rc_dec(e);
    }

    pion_scope_end(prod_scope);
    pion_chan_close(ch);
    pion_scope_end(cons_scope);
    pion_rc_dec(ch);

    /* Expected drops: per producer: 1 local + 1 remote; per remote: 1 consumer local = 3 * n_prod * per_prod */
    int64_t expected_drops = 3LL * n_prod * per_prod;
    assert(atomic_load(&g_drop_count) == expected_drops);
    printf("[PASS] mt_slab_stress (8 threads, %" PRId64 " slab/large alloc+free, 0 leaks)\n", expected_drops);
}

static void med_frozen_env_drop(void *p) {
    void **env = (void **)p;
    pion_rc_dec(*env);
}

static void med_frozen_worker(void *env) {
    void *ch = *(void **)env;
    int64_t v = 0;
    while (pion_chan_recv(ch, &v)) {
        void *obj = (void *)(uintptr_t)v;
        /* Verify payload integrity across threads before freeing */
        uint8_t *bytes = (uint8_t *)obj;
        assert(bytes[0] == 0x5A);
        pion_rc_dec(obj);
    }
}

static void test_med_cache_and_mt_frozen(void) {
    /* 1. Single-thread 6-tier medium-block object cache (2K / 4K / 8K / 16K / 32K / 64K) */
    const uint32_t tiers[6] = { 1500u, 3000u, 7000u, 15000u, 30000u, 60000u };
    for (int t = 0; t < 6; t++) {
        uint32_t psz = tiers[t];
        /* Allocate > tier cap (16 for 2K..16K, 4 for 32K/64K) to exercise hit + overflow free() */
        int cnt = (t < 4) ? 20 : 8;
        void *ptrs[20];
        for (int i = 0; i < cnt; i++) {
            ptrs[i] = pion_alloc_uninit(psz, PION_TAG_STRUCT, NULL);
            memset(ptrs[i], (int)(0xA0 + i), psz);
        }
        for (int i = 0; i < cnt; i++) {
            assert(((uint8_t *)ptrs[i])[0] == (uint8_t)(0xA0 + i));
            assert(((uint8_t *)ptrs[i])[psz - 1] == (uint8_t)(0xA0 + i));
            pion_rc_dec(ptrs[i]);
        }
        /* Repeated alloc/free should hit TLS cache without corruption */
        for (int r = 0; r < 64; r++) {
            void *p = pion_alloc_uninit(psz, PION_TAG_STRUCT, NULL);
            ((uint8_t *)p)[0] = (uint8_t)r;
            ((uint8_t *)p)[psz - 1] = (uint8_t)(r ^ 0xFF);
            assert(((uint8_t *)p)[0] == (uint8_t)r);
            assert(((uint8_t *)p)[psz - 1] == (uint8_t)(r ^ 0xFF));
            pion_rc_dec(p);
        }
    }

    /* 2. Single-thread burst allocation of 10,000 new 48B objects spanning multiple 256 KB chunks */
    {
        const int burst_n = 10000;
        void **burst = (void **)malloc((size_t)burst_n * sizeof(void *));
        assert(burst != NULL);
        for (int i = 0; i < burst_n; i++) {
            int64_t *obj = (int64_t *)pion_alloc_uninit(48u, PION_TAG_STRUCT, NULL);
            obj[0] = (int64_t)i;
            obj[5] = (int64_t)(i * 7 + 13);
            burst[i] = obj;
        }
        for (int i = 0; i < burst_n; i++) {
            int64_t *obj = (int64_t *)burst[i];
            assert(obj[0] == (int64_t)i);
            assert(obj[5] == (int64_t)(i * 7 + 13));
            pion_rc_dec(obj);
        }
        free(burst);
    }

    /* 3. Array and Map growth across 1K -> 2K -> 4K -> 8K -> 16K -> 32K -> 64K boundaries */
    for (int rep = 0; rep < 12; rep++) {
        void *arr = pion_arr_new(0, 0);
        for (int64_t i = 0; i < 9000; i++) {
            pion_arr_push(arr, i * 3 + rep);
        }
        assert(pion_arr_len(arr) == 9000);
        assert(pion_arr_get(arr, 0) == rep);
        assert(pion_arr_get(arr, 8999) == 8999 * 3 + rep);
        pion_rc_dec(arr);

        void *mp = pion_map_new_int(0);
        for (int64_t i = 0; i < 2100; i++) {
            pion_map_set(mp, (void *)(uintptr_t)(i + 1), i * 7 + rep);
        }
        assert(pion_map_len(mp) == 2100);
        assert(pion_map_get(mp, (void *)(uintptr_t)2100) == 2099 * 7 + rep);
        pion_rc_dec(mp);
    }

    /* 4. Cross-thread frozen medium-block release across all 6 tiers (TSan/ASan stress) */
    void *ch = pion_chan_new(32, 1);
    void *sc = pion_scope_begin();
    for (int w = 0; w < 4; w++) {
        void **env = (void **)pion_alloc((uint32_t)sizeof(void *), PION_TAG_STRUCT, med_frozen_env_drop);
        pion_rc_inc(ch);
        *env = ch;
        pion_scope_spawn(sc, med_frozen_worker, env);
        pion_rc_dec(env);
    }
    for (int i = 0; i < 120; i++) {
        uint32_t psz = tiers[i % 6];
        void *obj = pion_alloc_uninit(psz, PION_TAG_STRUCT, NULL);
        ((uint8_t *)obj)[0] = 0x5A;
        ((uint8_t *)obj)[psz - 1] = (uint8_t)i;
        pion_chan_send(ch, (int64_t)(uintptr_t)obj);
        pion_rc_dec(obj);
    }
    pion_chan_close(ch);
    pion_scope_end(sc);
    pion_rc_dec(ch);
    printf("[PASS] med_cache_and_mt_frozen (2K..64K 6-tier TLS cache + 10k burst + Array/Map + MT frozen)\n");
}

typedef struct ExecStressEnv {
    void *world;
    void *done_cnt;
    int iters;
} ExecStressEnv;

static void exec_stress_env_drop(void *p) {
    ExecStressEnv *e = (ExecStressEnv *)p;
    pion_rc_dec(e->world);
    pion_rc_dec(e->done_cnt);
}

static void exec_stress_worker(void *arg) {
    ExecStressEnv *e = (ExecStressEnv *)arg;
    void *cmd_true = pion_arr_new(1, 1);
    void *s_true = pion_str_from_cstr(PION_TEST_TRUE, -1);
    pion_arr_push(cmd_true, (int64_t)(uintptr_t)s_true);

    void *cmd_missing = pion_arr_new(1, 1);
    void *s_missing = pion_str_from_cstr("/nonexistent_pion_exec_cmd_xyz_999", -1);
    pion_arr_push(cmd_missing, (int64_t)(uintptr_t)s_missing);

    void *cmd_cap = pion_arr_new(3, 1);
    void *s_sh = pion_str_from_cstr(PION_TEST_SH, -1);
    void *s_c = pion_str_from_cstr("-c", -1);
    void *s_echo = pion_str_from_cstr("printf 'mt-ok'", -1);
    pion_arr_push(cmd_cap, (int64_t)(uintptr_t)s_sh);
    pion_arr_push(cmd_cap, (int64_t)(uintptr_t)s_c);
    pion_arr_push(cmd_cap, (int64_t)(uintptr_t)s_echo);
    void *exp_ok = pion_str_from_cstr("mt-ok", -1);

    for (int i = 0; i < e->iters; i++) {
        assert(pion_world_exec(e->world, cmd_true) == 0);
        assert(pion_world_exec(e->world, cmd_missing) == 127);
        int32_t code = -1;
        void *out = pion_world_exec_capture(e->world, cmd_cap, &code);
        assert(code == 0 && pion_str_eq(out, exp_ok) == 1);
        pion_rc_dec(out);
    }

    pion_rc_dec(s_sh);
    pion_rc_dec(s_c);
    pion_rc_dec(s_echo);
    pion_rc_dec(cmd_cap);
    pion_rc_dec(exp_ok);
    pion_rc_dec(s_true);
    pion_rc_dec(cmd_true);
    pion_rc_dec(s_missing);
    pion_rc_dec(cmd_missing);
    pion_atomic_fetch_add(e->done_cnt, 1);
}

static void test_mt_world_exec(int argc, char **argv) {
    void *w = pion_world_init(argc, argv);
    void *done_cnt = pion_atomic_new(0);

    void *sc = pion_scope_begin();
    for (int i = 0; i < 8; i++) {
        ExecStressEnv *e = (ExecStressEnv *)pion_alloc_uninit(
            (uint32_t)sizeof(ExecStressEnv), PION_TAG_STRUCT, exec_stress_env_drop);
        pion_rc_inc(w);
        pion_rc_inc(done_cnt);
        e->world = w;
        e->done_cnt = done_cnt;
        e->iters = 4;
        pion_scope_spawn(sc, exec_stress_worker, e);
        pion_rc_dec(e);
    }
    pion_scope_end(sc);

    assert(pion_atomic_load(done_cnt) == 8);
    pion_rc_dec(done_cnt);
    pion_rc_dec(w);
    printf("[PASS] mt_world_exec (8 threads concurrent posix_spawnp)\n");
}

static void run_slab_bench(void) {
    const int64_t N = 1000000;
    void *ring[64];
    memset(ring, 0, sizeof(ring));

    /* Warmup */
    for (int i = 0; i < 10000; i++) {
        void *p = pion_alloc(24u, PION_TAG_STRUCT, NULL);
        pion_rc_dec(p);
    }

    double t0 = monotonic_sec();
    for (int64_t i = 0; i < N; i++) {
        int slot = (int)(i & 63);
        if (ring[slot]) {
            pion_rc_dec(ring[slot]);
        }
        int64_t *node = (int64_t *)pion_alloc(24u, PION_TAG_STRUCT, NULL);
        node[0] = i;
        ring[slot] = node;
    }
    for (int i = 0; i < 64; i++) {
        if (ring[i]) {
            pion_rc_dec(ring[i]);
            ring[i] = NULL;
        }
    }
    double t1 = monotonic_sec();
    double ms = (t1 - t0) * 1000.0;
    printf("[BENCH] slab 1M pion_alloc+free (24B payload / 64B class): %.2f ms (%.1f ns/op)\n",
           ms, (ms * 1e6) / (double)N);

    double t2 = monotonic_sec();
    for (int64_t i = 0; i < N; i++) {
        int slot = (int)(i & 63);
        if (ring[slot]) {
            pion_rc_dec(ring[slot]);
        }
        int64_t *node = (int64_t *)pion_alloc_uninit(24u, PION_TAG_STRUCT, NULL);
        node[0] = i;
        ring[slot] = node;
    }
    for (int i = 0; i < 64; i++) {
        if (ring[i]) {
            pion_rc_dec(ring[i]);
            ring[i] = NULL;
        }
    }
    double t3 = monotonic_sec();
    double ms_uninit = (t3 - t2) * 1000.0;
    printf("[BENCH] slab 1M pion_alloc_uninit+free (24B payload / 64B class): %.2f ms (%.1f ns/op)\n",
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
    pion_rc_dec(b->acc_atomic);
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
    pion_atomic_fetch_add(b->acc_atomic, (int64_t)(r & 0xFFFFFFFFULL));
}

static int pion_test_parse_pos_int(const char *s) {
    if (!s || !s[0]) return 0;
    long v = 0;
    for (const char *p = s; *p; p++) {
        if (*p < '0' || *p > '9') return 0;
        if (v < 1000000L) {
            v = v * 10L + (*p - '0');
            if (v > 1000000L) v = 1000000L;
        }
    }
    return (v > 0) ? (int)v : 0;
}

#ifdef __linux__
static int pion_test_cgroup_cpu_quota(const char *root_dir, const char *rel_path) {
    int best = 0;
    char cur[1024];
    if (!rel_path || rel_path[0] == '\0' || strcmp(rel_path, "/") == 0) {
        snprintf(cur, sizeof(cur), "%s", root_dir);
    } else if (rel_path[0] == '/') {
        snprintf(cur, sizeof(cur), "%s%s", root_dir, rel_path);
    } else {
        snprintf(cur, sizeof(cur), "%s/%s", root_dir, rel_path);
    }
    size_t root_len = strlen(root_dir);
    for (;;) {
        char path[1100];
        snprintf(path, sizeof(path), "%s/cpu.max", cur);
        FILE *f = fopen(path, "r");
        if (f) {
            long long quota = 0, period = 0;
            if (fscanf(f, "%lld %lld", &quota, &period) == 2 && quota > 0 && period > 0) {
                long long q = quota / period;
                if (q < 1) q = 1;
                if (q > 1000000) q = 1000000;
                if (best == 0 || (int)q < best) best = (int)q;
            }
            fclose(f);
        }
        if (strlen(cur) <= root_len) break;
        char *slash = strrchr(cur, '/');
        if (!slash || (size_t)(slash - cur) < root_len) break;
        *slash = '\0';
    }
    return best;
}

static int pion_test_linux_cgroup_cpus(void) {
    const char *cg_root = getenv("PION_TEST_CGROUP_ROOT");
    if (!cg_root || !cg_root[0]) cg_root = "/sys/fs/cgroup";
    const char *cg_file = getenv("PION_TEST_PROC_CGROUP");
    if (!cg_file || !cg_file[0]) cg_file = "/proc/self/cgroup";
    char rel[512] = "";
    FILE *pf = fopen(cg_file, "r");
    if (pf) {
        char line[600];
        while (fgets(line, sizeof(line), pf)) {
            if (strncmp(line, "0::", 3) == 0) {
                char *p = line + 3;
                size_t len = strcspn(p, "\r\n");
                if (len >= sizeof(rel)) len = sizeof(rel) - 1;
                memcpy(rel, p, len);
                rel[len] = '\0';
                break;
            }
        }
        fclose(pf);
    }
    return pion_test_cgroup_cpu_quota(cg_root, rel);
}
#endif

static int pion_test_avail_cpus(void) {
    int ov = pion_test_parse_pos_int(getenv("PION_BENCH_NCPUS"));
    if (ov > 0) return ov;
    int n = 1;
#ifdef _WIN32
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    if (si.dwNumberOfProcessors > 0) n = (int)si.dwNumberOfProcessors;
#else
    long sc = sysconf(_SC_NPROCESSORS_ONLN);
    if (sc > 0) n = (int)sc;
#ifdef __linux__
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set) == 0) {
        int aff = CPU_COUNT(&set);
        if (aff > 0 && aff < n) n = aff;
    }
    int cg = pion_test_linux_cgroup_cpus();
    if (cg > 0 && cg < n) n = cg;
#endif
#endif
    return n;
}

static void test_avail_cpu_parsing_and_cgroup(void) {
    assert(pion_test_parse_pos_int("02") == 2);
    assert(pion_test_parse_pos_int("8") == 8);
    assert(pion_test_parse_pos_int("10000010") == 1000000);
    assert(pion_test_parse_pos_int("10000010x") == 0);
    assert(pion_test_parse_pos_int("0") == 0);
    assert(pion_test_parse_pos_int("-2") == 0);
    assert(pion_test_parse_pos_int("2x") == 0);
    assert(pion_test_parse_pos_int("") == 0);
    assert(pion_test_parse_pos_int(NULL) == 0);
#ifdef __linux__
    char base[256];
    snprintf(base, sizeof(base), "%s/pion_cg_test_%d", pion_test_tmpdir(), pion_test_getpid());
    char child[320];
    snprintf(child, sizeof(child), "%s/sub", base);
    char root_f[352], child_f[352];
    snprintf(root_f, sizeof(root_f), "%s/cpu.max", base);
    snprintf(child_f, sizeof(child_f), "%s/cpu.max", child);
    (void)mkdir(base, 0700);
    (void)mkdir(child, 0700);
    FILE *f = fopen(root_f, "w");
    assert(f != NULL);
    fputs("max 100000\n", f);
    fclose(f);
    /* 1.1 CPUs (110000/100000) must floor conservatively to 1, not ceil to 2 */
    f = fopen(child_f, "w");
    assert(f != NULL);
    fputs("110000 100000\n", f);
    fclose(f);
    assert(pion_test_cgroup_cpu_quota(base, "/sub") == 1);
    /* Ancestor 2.9 CPUs vs child 3.5 CPUs -> min(floor(2.9), floor(3.5)) == 2 */
    f = fopen(root_f, "w");
    assert(f != NULL);
    fputs("290000 100000\n", f);
    fclose(f);
    f = fopen(child_f, "w");
    assert(f != NULL);
    fputs("350000 100000\n", f);
    fclose(f);
    assert(pion_test_cgroup_cpu_quota(base, "/sub") == 2);
    /* Strict 1-core child under max root -> 1 */
    f = fopen(root_f, "w");
    assert(f != NULL);
    fputs("max 100000\n", f);
    fclose(f);
    f = fopen(child_f, "w");
    assert(f != NULL);
    fputs("100000 100000\n", f);
    fclose(f);
    assert(pion_test_cgroup_cpu_quota(base, "/sub") == 1);
    pion_test_unlink(child_f);
    pion_test_unlink(root_f);
    pion_test_rmdir(child);
    pion_test_rmdir(base);
#endif
}

static void run_multicore_bench(void) {
    test_avail_cpu_parsing_and_cgroup();
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

    /* 4-core parallel via pion_scope_begin/spawn/end */
    void *par_acc = pion_atomic_new(0);
    double t2 = monotonic_sec();
    void *sc = pion_scope_begin();
    for (int i = 0; i < n_chunks; i++) {
        BenchChunk *b = (BenchChunk *)pion_alloc((uint32_t)sizeof(BenchChunk), PION_TAG_STRUCT, bench_chunk_drop);
        b->seed = (uint64_t)(i + 1) * 12345ULL;
        b->iters = iters;
        pion_rc_inc(par_acc);
        b->acc_atomic = par_acc;
        pion_scope_spawn(sc, bench_worker, b);
        pion_rc_dec(b);
    }
    pion_scope_end(sc);
    double t3 = monotonic_sec();
    double par_ms = (t3 - t2) * 1000.0;

    int64_t par_sum = pion_atomic_load(par_acc);
    pion_rc_dec(par_acc);
    assert(par_sum == seq_sum);

    double speedup = seq_ms / par_ms;
    const char *strict_env = getenv("PION_STRICT_PERF");
    const char *ci_env = getenv("CI");
    int strict = (strict_env && strcmp(strict_env, "1") == 0);
    int is_ci = (ci_env && ci_env[0] != '\0');
    int ncpus = pion_test_avail_cpus();
    printf("[BENCH] 1-core: %.2f ms, 4-core: %.2f ms, speedup: %.2fx (ncpus=%d, ci=%d, strict=%d, checksum=%" PRId64 ")\n",
           seq_ms, par_ms, speedup, ncpus, is_ci, strict, par_sum);
    fflush(stdout);
    if (strict) {
        assert(speedup > 3.0);
    } else if (ncpus <= 1) {
        /* 1-CPU host/container: correctness & checksum verified above. */
    } else if (is_ci) {
        assert(speedup > 1.2);
    } else if (ncpus < 4) {
        double min_sp = (double)ncpus * 0.6;
        assert(speedup > min_sp);
    } else {
        assert(speedup > 3.0);
    }
}

static void test_arr_ergonomics_and_double_to_str(void) {
    /* pion_double_to_str */
    void *d1 = pion_double_to_str(3.14);
    void *d2 = pion_double_to_str(0.0);
    void *d3 = pion_double_to_str(-42.5);
    void *e1 = pion_str_from_cstr("3.14", -1);
    void *e2 = pion_str_from_cstr("0", -1);
    void *e3 = pion_str_from_cstr("-42.5", -1);
    assert(pion_str_eq(d1, e1) == 1);
    assert(pion_str_eq(d2, e2) == 1);
    assert(pion_str_eq(d3, e3) == 1);
    pion_rc_dec(d1); pion_rc_dec(d2); pion_rc_dec(d3);
    pion_rc_dec(e1); pion_rc_dec(e2); pion_rc_dec(e3);

    /* pion_arr_sort_int + pion_arr_reverse + pion_arr_clear (non-obj) */
    void *ai = pion_arr_new(8, 0);
    pion_arr_push(ai, 30);
    pion_arr_push(ai, -5);
    pion_arr_push(ai, 100);
    pion_arr_push(ai, 0);
    pion_arr_push(ai, 42);
    pion_arr_sort_int(ai);
    assert(pion_arr_get(ai, 0) == -5);
    assert(pion_arr_get(ai, 1) == 0);
    assert(pion_arr_get(ai, 2) == 30);
    assert(pion_arr_get(ai, 3) == 42);
    assert(pion_arr_get(ai, 4) == 100);
    pion_arr_reverse(ai);
    assert(pion_arr_get(ai, 0) == 100);
    assert(pion_arr_get(ai, 1) == 42);
    assert(pion_arr_get(ai, 2) == 30);
    assert(pion_arr_get(ai, 3) == 0);
    assert(pion_arr_get(ai, 4) == -5);
    pion_arr_clear(ai);
    assert(pion_arr_len(ai) == 0);
    pion_arr_reverse(ai);
    pion_arr_sort_int(ai);
    pion_rc_dec(ai);

    /* pion_arr_sort_int on compact 4B int32 array (incl. INT32_MIN / INT32_MAX overflow safety) */
    void *ai4 = pion_arr_new(8, 4);
    pion_arr_push(ai4, (int64_t)(uint32_t)2147483647);
    pion_arr_push(ai4, (int64_t)(uint32_t)(-1));
    pion_arr_push(ai4, (int64_t)(uint32_t)(-2147483647 - 1));
    pion_arr_push(ai4, 0);
    pion_arr_push(ai4, 42);
    pion_arr_sort_int(ai4);
    assert((int32_t)pion_arr_get(ai4, 0) == (-2147483647 - 1));
    assert((int32_t)pion_arr_get(ai4, 1) == -1);
    assert((int32_t)pion_arr_get(ai4, 2) == 0);
    assert((int32_t)pion_arr_get(ai4, 3) == 42);
    assert((int32_t)pion_arr_get(ai4, 4) == 2147483647);
    pion_rc_dec(ai4);

    /* pion_arr_sort_str + pion_arr_join + pion_arr_reverse + pion_arr_clear (obj RC safety) */
    void *as = pion_arr_new(4, 1);
    void *s_c = pion_str_from_cstr("cherry", -1);
    void *s_a = pion_str_from_cstr("apple", -1);
    void *s_b = pion_str_from_cstr("banana", -1);
    pion_arr_push(as, (int64_t)(uintptr_t)s_c);
    pion_arr_push(as, (int64_t)(uintptr_t)s_a);
    pion_arr_push(as, (int64_t)(uintptr_t)s_b);
    pion_rc_dec(s_c); pion_rc_dec(s_a); pion_rc_dec(s_b);

    pion_arr_sort_str(as);
    void *sep = pion_str_from_cstr(", ", -1);
    void *joined = pion_arr_join(as, sep);
    void *exp_j = pion_str_from_cstr("apple, banana, cherry", -1);
    assert(pion_str_eq(joined, exp_j) == 1);
    pion_rc_dec(joined);
    pion_rc_dec(exp_j);

    pion_arr_reverse(as);
    void *joined_rev = pion_arr_join(as, sep);
    void *exp_rev = pion_str_from_cstr("cherry, banana, apple", -1);
    assert(pion_str_eq(joined_rev, exp_rev) == 1);
    pion_rc_dec(joined_rev);
    pion_rc_dec(exp_rev);

    /* clear releases all object elements cleanly (verified by ASan) */
    pion_arr_clear(as);
    assert(pion_arr_len(as) == 0);
    void *empty_j = pion_arr_join(as, sep);
    void *exp_empty = pion_str_from_cstr("", -1);
    assert(pion_str_eq(empty_j, exp_empty) == 1);
    pion_rc_dec(empty_j);
    pion_rc_dec(exp_empty);
    pion_rc_dec(sep);
    pion_rc_dec(as);

    printf("[PASS] arr_ergonomics_and_double_to_str\n");
}

static void test_slab_48b_and_arr_growth(void) {
    /* 1. Empty array zero-overhead creation + 0 -> 4 -> 8 -> 16 -> 32 growth */
    PionArray *a = (PionArray *)pion_arr_new(0, 0);
    assert(a->len == 0 && a->cap == 0 && a->data == NULL);

    for (int64_t i = 0; i < 4; i++) {
        pion_arr_push(a, i * 11 + 1);
        assert(a->len == i + 1);
        assert(a->cap == 4);
    }
    for (int64_t i = 4; i < 8; i++) {
        pion_arr_push(a, i * 11 + 1);
        assert(a->len == i + 1);
        assert(a->cap == 8);
    }
    for (int64_t i = 8; i < 16; i++) {
        pion_arr_push(a, i * 11 + 1);
        assert(a->len == i + 1);
        assert(a->cap == 16);
    }
    pion_arr_push(a, 16 * 11 + 1);
    assert(a->len == 17 && a->cap == 32);
    for (int64_t i = 0; i < 17; i++) {
        assert(pion_arr_get(a, i) == i * 11 + 1);
    }
    pion_rc_dec(a);

    /* Empty object array dropped without pushing */
    PionArray *empty_obj_arr = (PionArray *)pion_arr_new(0, 1);
    assert(empty_obj_arr->len == 0 && empty_obj_arr->cap == 0 && empty_obj_arr->data == NULL);
    pion_rc_dec(empty_obj_arr);

    /* 2. 24B PionHeader + 16-class Slab (32B..1024B, 16B payload -> 40B class 1) */
    assert(sizeof(PionHeader) == 24);
    const uint32_t payloads[] = {
        0u, 8u, 9u, 16u, 17u, 24u, 25u, 32u, 33u, 40u, 41u, 56u, 57u, 72u, 73u,
        88u, 89u, 104u, 105u, 136u, 137u, 168u, 169u, 232u, 233u,
        296u, 297u, 360u, 361u, 488u, 489u, 1000u, 1001u
    };
    const size_t n_payloads = sizeof(payloads) / sizeof(payloads[0]);
    void *ptrs[sizeof(payloads) / sizeof(payloads[0])];
    for (size_t i = 0; i < n_payloads; i++) {
        uint32_t sz = payloads[i];
        uint8_t *p = (uint8_t *)pion_alloc(sz, PION_TAG_STRUCT, NULL);
        assert(p != NULL);
        if (sz > 0) {
            assert(p[0] == 0 && p[sz - 1] == 0);
            p[0] = (uint8_t)(i + 1);
            p[sz - 1] = (uint8_t)(0xA0u + i);
        }
        PionHeader *hdr = ((PionHeader *)p) - 1;
        if (hdr->flags & PION_FLAG_SLAB) {
            uint32_t cls = (uint32_t)((hdr->flags >> PION_FLAG_SLAB_CLS_SHIFT) & PION_FLAG_SLAB_CLS_MASK);
            if (sz <= 8u) {
                assert(cls == 0u);  /* 32B class */
            } else if (sz <= 16u) {
                assert(cls == 1u);  /* 40B class */
            } else if (sz <= 24u) {
                assert(cls == 2u);  /* 48B class */
            } else if (sz <= 32u) {
                assert(cls == 3u);  /* 56B class */
            } else if (sz <= 40u) {
                assert(cls == 4u);  /* 64B class */
            } else if (sz <= 56u) {
                assert(cls == 5u);  /* 80B class */
            } else if (sz <= 72u) {
                assert(cls == 6u);  /* 96B class */
            } else if (sz <= 88u) {
                assert(cls == 7u);  /* 112B class */
            } else if (sz <= 104u) {
                assert(cls == 8u);  /* 128B class */
            } else if (sz <= 136u) {
                assert(cls == 9u);  /* 160B class */
            } else if (sz <= 168u) {
                assert(cls == 10u); /* 192B class */
            } else if (sz <= 232u) {
                assert(cls == 11u); /* 256B class */
            } else if (sz <= 296u) {
                assert(cls == 12u); /* 320B class */
            } else if (sz <= 360u) {
                assert(cls == 13u); /* 384B class */
            } else if (sz <= 488u) {
                assert(cls == 14u); /* 512B class */
            } else {
                assert(sz <= 1000u && cls == 15u); /* 1024B class */
            }
        } else {
            assert(sz > 1000u || 1); /* ASan disables slab */
        }
        ptrs[i] = p;
    }
    for (size_t i = 0; i < n_payloads; i++) {
        uint32_t sz = payloads[i];
        uint8_t *p = (uint8_t *)ptrs[i];
        if (sz > 0) {
            assert(p[0] == (uint8_t)(i + 1));
            assert(p[sz - 1] == (uint8_t)(0xA0u + i));
        }
        pion_rc_dec(p);
    }

    /* Short strings (0..7 bytes -> 24B hdr + 8B len + <=8B = <=40B -> class 1) + concat_n */
    const char *keys[] = { "", "id", "role", "tags", "note", "metrics", "latency_ms", "user_00001_ap-northeast-1" };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        size_t klen = strlen(keys[i]);
        void *s = pion_str_from_cstr(keys[i], (int64_t)klen);
        PionHeader *shdr = ((PionHeader *)s) - 1;
        if ((shdr->flags & PION_FLAG_SLAB) && klen <= 7) {
            uint32_t cls = (uint32_t)((shdr->flags >> PION_FLAG_SLAB_CLS_SHIFT) & PION_FLAG_SLAB_CLS_MASK);
            assert(cls == 1u); /* 24B header + 8B len + (1..8B) data+NUL -> 40B class */
        }
        void *sl = pion_str_slice(s, 0, (int64_t)klen);
        assert(pion_str_eq(s, sl) == 1);
        void *sb = pion_strbuf_new(0);
        for (size_t j = 0; j < klen; j++) {
            pion_strbuf_push_char(sb, (unsigned char)keys[i][j]);
        }
        void *from_sb = pion_strbuf_to_str(sb);
        assert(pion_str_eq(s, from_sb) == 1);
        pion_rc_dec(s);
        pion_rc_dec(sl);
        pion_rc_dec(sb);
        pion_rc_dec(from_sb);
    }

    /* pion_str_concat_n: 0 parts, NULL/empty parts, multi-part */
    {
        void *c0 = pion_str_concat_n(0, NULL);
        assert(pion_str_len(c0) == 0);
        pion_rc_dec(c0);

        void *p0 = pion_str_from_cstr("ALERT|", 6);
        void *p1 = pion_str_from_cstr("auth", 4);
        void *p2 = pion_str_from_cstr("|", 1);
        void *p3 = pion_str_from_cstr("", 0);
        void *p4 = pion_str_from_cstr("ERR", 3);
        void *p5 = pion_str_from_cstr("|523|timeout", 12);
        void *parts[7] = { p0, p1, p2, NULL, p3, p4, p5 };
        void *joined = pion_str_concat_n(7, parts);
        void *want = pion_str_from_cstr("ALERT|auth|ERR|523|timeout", 26);
        assert(pion_str_len(joined) == 26);
        assert(pion_str_eq(joined, want) == 1);
        pion_rc_dec(joined);
        pion_rc_dec(want);
        pion_rc_dec(p0);
        pion_rc_dec(p1);
        pion_rc_dec(p2);
        pion_rc_dec(p3);
        pion_rc_dec(p4);
        pion_rc_dec(p5);
    }

    /* Verify pion_arr_push_owned transfers ownership without incrementing RC */
    void *owned_arr = pion_arr_new(0, 1);
    for (int i = 0; i < 16; i++) {
        void *s = pion_int_to_str((int64_t)i);
        PionHeader *sh = ((PionHeader *)s) - 1;
        assert(sh->local_rc == 1);
        pion_arr_push_owned(owned_arr, (int64_t)(uintptr_t)s);
        assert(sh->local_rc == 1);
    }
    assert(pion_arr_len(owned_arr) == 16);
    for (int i = 0; i < 16; i++) {
        void *s = (void *)(uintptr_t)pion_arr_get(owned_arr, (int64_t)i);
        void *exp = pion_int_to_str((int64_t)i);
        assert(pion_str_eq(s, exp) == 1);
        pion_rc_dec(exp);
    }
    pion_rc_dec(owned_arr);

    printf("[PASS] slab_48b_and_arr_growth\n");
}

static void test_ffi_ptr_and_cstr(void) {
    /* Zero-initialized allocation + typed read/write + offset + unaligned safety */
    void *p = pion_ptr_alloc(48);
    assert(p != NULL);
    assert(pion_ptr_read_i64(p, 0) == 0);
    assert(pion_ptr_read_i64(p, 40) == 0);

    pion_ptr_write_i32(p, 0, -123456789);
    pion_ptr_write_i32(p, 4, 0x7fffffff);
    assert(pion_ptr_read_i32(p, 0) == -123456789);
    assert(pion_ptr_read_i32(p, 4) == 0x7fffffff);

    /* Offset + i64 */
    void *p16 = pion_ptr_offset(p, 16);
    assert(p16 == (void *)((char *)p + 16));
    pion_ptr_write_i64(p16, 0, -987654321012345LL);
    assert(pion_ptr_read_i64(p, 16) == -987654321012345LL);

    /* Unaligned offset i32/i64 (memcpy alignment-safe) */
    pion_ptr_write_i32(p, 9, 0x12345678);
    assert(pion_ptr_read_i32(p, 9) == 0x12345678);
    pion_ptr_write_i64(p, 25, 0x1122334455667788LL);
    assert(pion_ptr_read_i64(p, 25) == 0x1122334455667788LL);

    /* Pointer roundtrip */
    pion_ptr_write_ptr(p, 32, p16);
    assert(pion_ptr_read_ptr(p, 32) == p16);
    assert(pion_ptr_offset(NULL, 8) == NULL);

    /* Zero-size alloc + NULL free safety */
    void *p0 = pion_ptr_alloc(0);
    assert(p0 != NULL);
    pion_ptr_free(p0);
    pion_ptr_free(NULL);
    pion_ptr_free(p);

    /* pion_cstr_to_str: NULL and non-NULL */
    void *s_null = pion_cstr_to_str(NULL);
    assert(pion_str_len(s_null) == 0);
    const char *raw = "hello ffi \xE4\xB8\x96\xE7\x95\x8C";
    void *s_raw = pion_cstr_to_str((void *)raw);
    void *s_exp = pion_str_from_cstr(raw, -1);
    assert(pion_str_eq(s_raw, s_exp) == 1);

    pion_rc_dec(s_null);
    pion_rc_dec(s_raw);
    pion_rc_dec(s_exp);
    printf("[PASS] ffi_ptr_and_cstr\n");
}

typedef struct TcpServerEnv {
    void *w;
    int32_t listen_fd; /* >= 0: accept n_clients connections; < 0: serve fixed_fd */
    int32_t fixed_fd;
    int32_t n_clients;
    void *handled_cnt;
} TcpServerEnv;

typedef struct TcpClientEnv {
    void *w;
    int32_t port;      /* > 0: pion_tcp_connect to 127.0.0.1/localhost; 0: use fixed_fd */
    int32_t fixed_fd;
    int32_t client_id;
    void *ok_cnt;
} TcpClientEnv;

/* Reads a 15-byte request, replies "echo:<req>" and closes (EOF for the peer). */
static void tcp_echo_serve(void *w, int32_t cfd) {
    void *sb = pion_strbuf_new(32);
    int64_t got = 0;
    while (got < 15) {
        void *chunk = pion_tcp_read(w, cfd, 64);
        int64_t clen = pion_str_len(chunk);
        if (clen == 0) {
            pion_rc_dec(chunk);
            break;
        }
        pion_strbuf_push_str(sb, chunk);
        got += clen;
        pion_rc_dec(chunk);
    }
    void *req = pion_strbuf_to_str(sb);
    pion_rc_dec(sb);
    void *prefix = pion_str_from_cstr("echo:", 5);
    void *resp = pion_str_concat(prefix, req);
    int32_t nw = pion_tcp_write(w, cfd, resp);
    assert(nw == (int32_t)pion_str_len(resp));
    pion_tcp_close(w, cfd);
    pion_rc_dec(req);
    pion_rc_dec(prefix);
    pion_rc_dec(resp);
}

static void tcp_server_worker(void *env_ptr) {
    TcpServerEnv *env = (TcpServerEnv *)env_ptr;
    if (env->listen_fd < 0) {
        tcp_echo_serve(env->w, env->fixed_fd);
        pion_atomic_fetch_add(env->handled_cnt, 1);
        return;
    }
    for (int32_t i = 0; i < env->n_clients; i++) {
        int32_t cfd = pion_tcp_accept(env->w, env->listen_fd);
        assert(cfd >= 0);
        tcp_echo_serve(env->w, cfd);
        pion_atomic_fetch_add(env->handled_cnt, 1);
    }
}

static void tcp_client_worker(void *env_ptr) {
    TcpClientEnv *env = (TcpClientEnv *)env_ptr;
    int32_t fd = env->fixed_fd;
    if (env->port > 0) {
        void *host = pion_str_from_cstr((env->client_id & 1) ? "localhost" : "127.0.0.1", -1);
        fd = pion_tcp_connect(env->w, host, env->port);
        int err = errno;
        pion_rc_dec(host);
        if (fd < 0) {
            fprintf(stderr, "tcp_client_worker %d: connect failed errno=%d (%s)\n",
                    (int)env->client_id, err, strerror(err));
        }
    }
    assert(fd >= 0);

    char msg_buf[32];
    snprintf(msg_buf, sizeof(msg_buf), "ping-%d-hello-pion", (int)env->client_id);
    void *req = pion_str_from_cstr(msg_buf, 17);
    int32_t nw = pion_tcp_write(env->w, fd, req);
    assert(nw == 17);

    void *sb = pion_strbuf_new(32);
    for (;;) {
        void *chunk = pion_tcp_read(env->w, fd, 64);
        if (pion_str_len(chunk) == 0) {
            pion_rc_dec(chunk);
            break;
        }
        pion_strbuf_push_str(sb, chunk);
        pion_rc_dec(chunk);
    }
    void *resp = pion_strbuf_to_str(sb);
    void *prefix = pion_str_from_cstr("echo:", 5);
    void *exp = pion_str_concat(prefix, req);
    assert(pion_str_eq(resp, exp) == 1);

    pion_tcp_close(env->w, fd);
    pion_rc_dec(req);
    pion_rc_dec(sb);
    pion_rc_dec(resp);
    pion_rc_dec(prefix);
    pion_rc_dec(exp);
    pion_atomic_fetch_add(env->ok_cnt, 1);
}

/* Probes a 127.0.0.1 TCP connection to `port` with a 200 ms non-blocking connect.
 * Returns 0 when connected (the probe is accepted and closed on lfd), or the errno
 * that stopped it (ETIMEDOUT when nothing answered within 200 ms). */
static int tcp_loopback_probe(void *w, int32_t lfd, int32_t port) {
#ifdef _WIN32
    (void)w;
    (void)lfd;
    (void)port;
    return 0;
#else
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(fd >= 0);
    int fl = fcntl(fd, F_GETFL, 0);
    assert(fl >= 0 && fcntl(fd, F_SETFL, fl | O_NONBLOCK) == 0);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
#ifdef __APPLE__
    addr.sin_len = (uint8_t)sizeof(addr);
#endif
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    assert(inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1);
    int err = 0;
    if (connect(fd, (struct sockaddr *)&addr, (socklen_t)sizeof(addr)) != 0) {
        err = errno;
        if (err == EINPROGRESS) {
            struct pollfd pfd;
            pfd.fd = fd;
            pfd.events = POLLOUT;
            pfd.revents = 0;
            int pr;
            do {
                pr = poll(&pfd, 1, 200);
            } while (pr < 0 && errno == EINTR);
            if (pr == 0) {
                err = ETIMEDOUT;
            } else {
                socklen_t len = (socklen_t)sizeof(err);
                assert(pr > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0);
            }
        }
    }
    close(fd);
    if (err == 0) {
        int32_t pfd = pion_tcp_accept(w, lfd);
        assert(pfd >= 0);
        pion_tcp_close(w, pfd);
    }
    return err;
#endif
}

static void test_tcp_loopback_mt(int argc, char **argv) {
    void *w = pion_world_init(argc, argv);

    /* Error path checks */
    assert(pion_tcp_local_port(w, -1) == -1);
    assert(pion_tcp_accept(w, -1) == -1);
    void *bad_host = pion_str_from_cstr("999.999.999.999", -1);
    assert(pion_tcp_connect(w, bad_host, 80) == -1);
    assert(pion_tcp_listen(w, bad_host, 0) == -1);
    pion_rc_dec(bad_host);
    void *lo_host = pion_str_from_cstr("127.0.0.1", 9);
    assert(pion_tcp_listen(w, lo_host, 70000) == -1);
    assert(pion_tcp_connect(w, lo_host, 0) == -1);
    pion_tcp_close(w, -1);
    pion_sleep_ms(w, 0);
    pion_sleep_ms(w, 1);

    /* Bind ephemeral port on 127.0.0.1 */
    int32_t lfd = pion_tcp_listen(w, lo_host, 0);
    assert(lfd >= 0);
    int32_t port = pion_tcp_local_port(w, lfd);
    assert(port > 0 && port <= 65535);

    /* Binding the same port again without SO_REUSEPORT must fail with errno preserved. */
    errno = 0;
    assert(pion_tcp_listen(w, lo_host, port) == -1);
    assert(errno == EADDRINUSE);
    pion_rc_dec(lo_host);

    const int32_t N_CLIENTS = 4;
    int probe_err = tcp_loopback_probe(w, lfd, port);
    int use_tcp = probe_err == 0;
    if (!use_tcp) {
        if (probe_err != ETIMEDOUT && probe_err != EPERM && probe_err != EACCES) {
            fprintf(stderr, "FAIL: 127.0.0.1:%d loopback probe errno=%d (%s)\n", (int)port,
                    probe_err, strerror(probe_err));
            assert(0 && "unexpected loopback TCP error");
        }
        printf("NOTE: host firewall blocks 127.0.0.1 TCP for this unsigned binary "
               "(probe errno=%d %s); running the 4-way concurrent read/write/close "
               "test over socketpair(AF_UNIX) instead\n",
               probe_err, strerror(probe_err));
    }

    int sv[4][2];
    void *handled_cnt = pion_atomic_new(0);
    void *ok_cnt = pion_atomic_new(0);
    TcpServerEnv *senvs[4];
    TcpClientEnv *cenvs[4];
    int32_t n_servers = use_tcp ? 1 : N_CLIENTS;
    for (int32_t i = 0; i < n_servers; i++) {
#ifndef _WIN32
        if (!use_tcp) {
            assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv[i]) == 0);
        }
#else
        sv[i][0] = -1;
        sv[i][1] = -1;
#endif
        senvs[i] = (TcpServerEnv *)pion_alloc((uint32_t)sizeof(TcpServerEnv), PION_TAG_STRUCT, NULL);
        senvs[i]->w = w;
        senvs[i]->listen_fd = use_tcp ? lfd : -1;
        senvs[i]->fixed_fd = use_tcp ? -1 : (int32_t)sv[i][0];
        senvs[i]->n_clients = N_CLIENTS;
        senvs[i]->handled_cnt = handled_cnt;
    }

    void *scope = pion_scope_begin();
    for (int32_t i = 0; i < n_servers; i++) {
        pion_scope_spawn(scope, tcp_server_worker, senvs[i]);
    }
    for (int32_t i = 0; i < N_CLIENTS; i++) {
        cenvs[i] = (TcpClientEnv *)pion_alloc((uint32_t)sizeof(TcpClientEnv), PION_TAG_STRUCT, NULL);
        cenvs[i]->w = w;
        cenvs[i]->port = use_tcp ? port : 0;
        cenvs[i]->fixed_fd = use_tcp ? -1 : (int32_t)sv[i][1];
        cenvs[i]->client_id = i;
        cenvs[i]->ok_cnt = ok_cnt;
        pion_scope_spawn(scope, tcp_client_worker, cenvs[i]);
    }
    pion_scope_end(scope);

    assert(pion_atomic_load(handled_cnt) == N_CLIENTS);
    assert(pion_atomic_load(ok_cnt) == N_CLIENTS);

    pion_tcp_close(w, lfd);
    for (int32_t i = 0; i < n_servers; i++) {
        pion_rc_dec(senvs[i]);
    }
    for (int32_t i = 0; i < N_CLIENTS; i++) {
        pion_rc_dec(cenvs[i]);
    }
    pion_rc_dec(handled_cnt);
    pion_rc_dec(ok_cnt);
    pion_rc_dec(w);
    if (use_tcp) {
        printf("[PASS] tcp_loopback_mt (%d concurrent TCP clients on 127.0.0.1:%d)\n",
               (int)N_CLIENTS, (int)port);
    } else {
        printf("[PASS] tcp_loopback_mt (socketpair fallback: %d concurrent read/write/close pairs)\n",
               (int)N_CLIENTS);
    }
}

/* ============================================================================
 * Non-blocking IO + kqueue/epoll event loop (deterministic: socketpair always,
 * real 127.0.0.1 TCP when the host lets this binary reach loopback)
 * ============================================================================ */

static int32_t poll_one(void *w, int32_t pfd, void *fds, void *evs, int32_t timeout_ms,
                        int32_t want_fd, int32_t *mask_out) {
    int32_t n = pion_poll_wait(w, pfd, fds, evs, 64, timeout_ms);
    assert(n >= 0 && pion_arr_len(fds) == n && pion_arr_len(evs) == n);
    *mask_out = 0;
    for (int32_t i = 0; i < n; i++) {
        if ((int32_t)pion_arr_get(fds, i) == want_fd) {
            /* kqueue's READ and WRITE filters must come back merged into one entry */
            assert(*mask_out == 0);
            *mask_out = (int32_t)pion_arr_get(evs, i);
        }
    }
    return n;
}

static void test_event_loop_nb(int argc, char **argv) {
    void *w = pion_world_init(argc, argv);
    void *fds = pion_arr_new(0, 0);
    void *evs = pion_arr_new(0, 0);
    void *sb = pion_strbuf_new(16);
    int32_t mask = 0;

    /* Error paths */
    assert(pion_poll_ctl(w, -1, 1, 0, 1) == 0);
    assert(pion_poll_wait(w, -1, fds, evs, 8, 0) == -1);
    assert(pion_tcp_set_nonblock(w, -1, 1) == 0);
    assert(pion_tcp_accept_nb(w, -1) == -1);
    assert(pion_tcp_read_nb(w, -1, sb, 16) == -1);
    void *hello = pion_str_from_cstr("hello", 5);
    assert(pion_tcp_write_nb(w, -1, hello, 0) == -1);
    pion_poll_close(w, -1);

    int32_t pfd = pion_poll_create(w);
    assert(pfd >= 0);
    assert(pion_poll_ctl(w, pfd, 9, 0, 1) == 0);

    /* 1. connected pair: EAGAIN, readiness, read into StringBuilder */
#ifdef _WIN32
    void *pair_lo = pion_str_from_cstr("127.0.0.1", 9);
    int32_t plfd = pion_tcp_listen(w, pair_lo, 0);
    assert(plfd >= 0);
    int32_t pport = pion_tcp_local_port(w, plfd);
    int32_t a = pion_tcp_connect(w, pair_lo, pport);
    int32_t b = pion_tcp_accept(w, plfd);
    assert(a >= 0 && b >= 0);
    pion_tcp_close(w, plfd);
    pion_rc_dec(pair_lo);
    assert(pion_tcp_set_nonblock(w, a, 1) == 1 && pion_tcp_set_nonblock(w, b, 1) == 1);
    assert(pion_tcp_set_nonblock(w, a, 0) == 1);
    assert(pion_tcp_set_nonblock(w, a, 1) == 1);
#else
    int sv[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    int32_t a = sv[0], b = sv[1];
    assert(pion_tcp_set_nonblock(w, a, 1) == 1 && pion_tcp_set_nonblock(w, b, 1) == 1);
    assert((fcntl(a, F_GETFL, 0) & O_NONBLOCK) != 0);
    assert(pion_tcp_set_nonblock(w, a, 0) == 1 && (fcntl(a, F_GETFL, 0) & O_NONBLOCK) == 0);
    assert(pion_tcp_set_nonblock(w, a, 1) == 1);
#endif
    assert(pion_tcp_write_nb(w, b, hello, 5) == 0);
    assert(pion_tcp_write_nb(w, b, hello, -1) == -1);
    assert(pion_poll_ctl(w, pfd, 1, a, 1) == 1);
    assert(poll_one(w, pfd, fds, evs, 0, a, &mask) == 0);
    assert(pion_tcp_read_nb(w, a, sb, 16) == -2);
    assert(pion_tcp_write_nb(w, b, hello, 0) == 5);
    assert(poll_one(w, pfd, fds, evs, -1, a, &mask) == 1 && (mask & 1));
    assert(pion_tcp_read_nb(w, a, sb, 0) == 5);
    assert(pion_tcp_read_nb(w, a, sb, 0) == -2);
    assert(((PionStrBuf *)sb)->len == 5 && memcmp(((PionStrBuf *)sb)->data, "hello", 5) == 0);
    assert(pion_tcp_write_nb(w, b, hello, 3) == 2); /* resume mid-string */
    assert(pion_tcp_read_nb(w, a, sb, 1) == 1 && pion_tcp_read_nb(w, a, sb, 16) == 1);
    assert(((PionStrBuf *)sb)->len == 7 && memcmp(((PionStrBuf *)sb)->data, "hellolo", 7) == 0);

    /* 2. MOD to READ|WRITE: writable, not readable */
    assert(pion_poll_ctl(w, pfd, 2, a, 3) == 1);
    assert(poll_one(w, pfd, fds, evs, -1, a, &mask) == 1 && mask == 2);

    /* 3. Partial writes of 4 MiB drained through EV_WRITE, interleaved with reads */
    const int64_t big_len = 4 * 1024 * 1024;
    char *raw = (char *)malloc((size_t)big_len);
    assert(raw);
    for (int64_t i = 0; i < big_len; i++) raw[i] = (char)('a' + (i * 7) % 26);
    void *big = pion_str_from_cstr(raw, big_len);
    void *rsb = pion_strbuf_new(64);
    int32_t off = 0;
    int partial = 0, again = 0;
    assert(pion_poll_ctl(w, pfd, 1, b, 1) == 1);
    while (off < big_len || ((PionStrBuf *)rsb)->len < big_len) {
        int32_t n = pion_poll_wait(w, pfd, fds, evs, 64, -1);
        assert(n > 0);
        for (int32_t i = 0; i < n; i++) {
            int32_t fd = (int32_t)pion_arr_get(fds, i);
            int32_t m = (int32_t)pion_arr_get(evs, i);
            if (fd == a && (m & 2) && off < big_len) {
                int32_t wr = pion_tcp_write_nb(w, a, big, off);
                assert(wr > 0 || wr == -2);
                if (wr > 0) {
                    off += wr;
                    if (off < big_len) partial++;
                } else {
                    again++;
                }
                if (off == big_len) assert(pion_poll_ctl(w, pfd, 2, a, 1) == 1);
            }
            if (fd == b && (m & 1)) {
                int32_t rd;
                while ((rd = pion_tcp_read_nb(w, b, rsb, 16384)) > 0) {
                }
                assert(rd == -2);
            }
        }
    }
#ifndef _WIN32
    assert(partial > 0);
#endif
    assert(pion_tcp_write_nb(w, a, big, off) == 0);
    assert(((PionStrBuf *)rsb)->len == big_len && memcmp(((PionStrBuf *)rsb)->data, raw, (size_t)big_len) == 0);

    /* 4. DEL, then peer close: EOF reads 0, writes fail with -1 (no SIGPIPE) */
    assert(pion_poll_ctl(w, pfd, 3, b, 0) == 1);
    assert(pion_poll_ctl(w, pfd, 2, a, 1) == 1);
    pion_tcp_close(w, b);
    assert(poll_one(w, pfd, fds, evs, -1, a, &mask) == 1 && (mask & 1));
    assert(pion_tcp_read_nb(w, a, sb, 16) == 0);
#ifndef _WIN32
    assert(pion_tcp_write_nb(w, a, hello, 0) == -1);
#endif
    assert(pion_poll_ctl(w, pfd, 3, a, 0) == 1);
    assert(poll_one(w, pfd, fds, evs, 0, a, &mask) == 0);
    pion_tcp_close(w, a);

    /* 5. TCP: SO_REUSEPORT listeners, non-blocking accept, TCP_NODELAY */
    void *lo = pion_str_from_cstr("127.0.0.1", 9);
    int32_t lfd = pion_tcp_listen_reuse(w, lo, 0);
    assert(lfd >= 0);
    int32_t port = pion_tcp_local_port(w, lfd);
    assert(port > 0);
    int32_t lfd2 = pion_tcp_listen_reuse(w, lo, port);
    assert(lfd2 >= 0 && pion_tcp_local_port(w, lfd2) == port);
    pion_tcp_close(w, lfd2);
    errno = 0;
    assert(pion_tcp_listen(w, lo, port) == -1 && errno == EADDRINUSE);
    int use_tcp = tcp_loopback_probe(w, lfd, port) == 0;
    assert(pion_tcp_set_nonblock(w, lfd, 1) == 1);
    assert(pion_tcp_accept_nb(w, lfd) == -2);
    if (use_tcp) {
        assert(pion_poll_ctl(w, pfd, 1, lfd, 1) == 1);
        int32_t cfd = pion_tcp_connect(w, lo, port);
        assert(cfd >= 0);
        assert(poll_one(w, pfd, fds, evs, -1, lfd, &mask) == 1 && (mask & 1));
        int32_t afd = pion_tcp_accept_nb(w, lfd);
        assert(afd >= 0);
        assert(pion_tcp_accept_nb(w, lfd) == -2);
#ifndef _WIN32
        assert((fcntl(afd, F_GETFL, 0) & O_NONBLOCK) != 0);
        int nd = 0;
        socklen_t ndl = (socklen_t)sizeof(nd);
        assert(getsockopt(afd, IPPROTO_TCP, TCP_NODELAY, &nd, &ndl) == 0 && nd != 0);
#endif
        assert(pion_poll_ctl(w, pfd, 1, afd, 1) == 1);
        void *ping = pion_str_from_cstr("ping", 4);
        assert(pion_tcp_write(w, cfd, ping) == 4);
        assert(poll_one(w, pfd, fds, evs, -1, afd, &mask) == 1 && (mask & 1));
        pion_strbuf_reset(sb);
        assert(pion_tcp_read_nb(w, afd, sb, 0) == 4);
        assert(memcmp(((PionStrBuf *)sb)->data, "ping", 4) == 0);
        assert(pion_tcp_write_nb(w, afd, hello, 0) == 5);
        void *got = pion_tcp_read(w, cfd, 64);
        assert(pion_str_eq(got, hello) == 1);
        pion_tcp_close(w, cfd);
        assert(poll_one(w, pfd, fds, evs, -1, afd, &mask) == 1 && (mask & 1));
        assert(pion_tcp_read_nb(w, afd, sb, 0) == 0);
        assert(pion_poll_ctl(w, pfd, 3, afd, 0) == 1);
        pion_tcp_close(w, afd);
        pion_rc_dec(got);
        pion_rc_dec(ping);
    }
    pion_tcp_close(w, lfd);
    pion_poll_close(w, pfd);

    free(raw);
    pion_rc_dec(big);
    pion_rc_dec(rsb);
    pion_rc_dec(lo);
    pion_rc_dec(hello);
    pion_rc_dec(sb);
    pion_rc_dec(evs);
    pion_rc_dec(fds);
    pion_rc_dec(w);
    printf("[PASS] event_loop_nb (%s; socketpair EAGAIN/merge/%d partial writes/EOF%s)\n",
#if defined(_WIN32)
           "WSAPoll",
#elif defined(__APPLE__)
           "kqueue",
#else
           "epoll",
#endif
           partial, use_tcp ? "; 127.0.0.1 TCP accept_nb/TCP_NODELAY" : "; TCP blocked by host firewall");
    (void)again;
}

static void test_short_str_and_hash_edges(void) {
    /* Exhaustively test boundary lengths 0..32 (incl. 0,1,7,8,9,15,16,17,32) across
     * slice (unaligned offsets), from_cstr, concat_n, str_eq (first/mid/last diff),
     * and map set/try_get under heavy key overlap. */
    const char *base = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_";
    void *base_s = pion_str_from_cstr(base, 64);
    const int64_t lens[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 15, 16, 17, 24, 31, 32};
    const int64_t offs[] = {0, 1, 3, 7, 8, 15};
    void *m = pion_map_new(0);
    int64_t seq = 1;

    for (size_t oi = 0; oi < sizeof(offs) / sizeof(offs[0]); oi++) {
        int64_t off = offs[oi];
        for (size_t li = 0; li < sizeof(lens) / sizeof(lens[0]); li++) {
            int64_t len = lens[li];
            void *sl = pion_str_slice(base_s, off, off + len);
            void *fc = pion_str_from_cstr(base + off, len);
            assert(pion_str_len(sl) == len);
            assert(pion_str_eq(sl, fc) == 1);
            assert(((PionString *)sl)->data[len] == '\0');
            assert(((PionString *)fc)->data[len] == '\0');
            if (len > 0) {
                char buf[40];
                memcpy(buf, base + off, (size_t)len);
                /* Differ at first byte */
                buf[0] ^= 1;
                void *d0 = pion_str_from_cstr(buf, len);
                assert(pion_str_eq(sl, d0) == 0);
                pion_rc_dec(d0);
                buf[0] ^= 1;
                /* Differ at last byte */
                buf[len - 1] ^= 1;
                void *d1 = pion_str_from_cstr(buf, len);
                assert(pion_str_eq(sl, d1) == 0);
                pion_rc_dec(d1);
                buf[len - 1] ^= 1;
                /* Differ at middle byte */
                buf[len / 2] ^= 1;
                void *d2 = pion_str_from_cstr(buf, len);
                assert(pion_str_eq(sl, d2) == 0);
                pion_rc_dec(d2);
            }
            /* Test concat_n with 3 short parts */
            void *parts[3] = {sl, fc, sl};
            void *cat = pion_str_concat_n(3, parts);
            assert(pion_str_len(cat) == len * 3);
            if (len > 0) {
                void *mid = pion_str_slice(cat, len, len * 2);
                assert(pion_str_eq(mid, fc) == 1);
                pion_rc_dec(mid);
            }
            pion_rc_dec(cat);

            /* Map insert & lookup */
            pion_map_set(m, sl, seq);
            int64_t got = -1;
            assert(pion_map_try_get(m, fc, &got) == 1 && got == seq);
            seq++;
            pion_rc_dec(sl);
            pion_rc_dec(fc);
        }
    }
    pion_rc_dec(m);
    pion_rc_dec(base_s);
    printf("[PASS] short_str_and_hash_edges\n");
}

static void test_p22a_systems_io(int argc, char **argv) {
    void *w = pion_world_init(argc, argv);

    /* 1. ptr_read_u8 / ptr_write_u8 / bytes_from_ptr / bytes_copy_to_ptr */
    void *p = pion_ptr_alloc(16);
    pion_ptr_write_u8(p, 0, 0);
    pion_ptr_write_u8(p, 1, 127);
    pion_ptr_write_u8(p, 2, 128);
    pion_ptr_write_u8(p, 3, 255);
    assert(pion_ptr_read_u8(p, 0) == 0);
    assert(pion_ptr_read_u8(p, 1) == 127);
    assert(pion_ptr_read_u8(p, 2) == 128);
    assert(pion_ptr_read_u8(p, 3) == 255);

    void *b = pion_bytes_from_ptr(p, 4);
    assert(pion_bytes_len(b) == 4);
    assert(pion_bytes_get(b, 0) == 0);
    assert(pion_bytes_get(b, 1) == 127);
    assert(pion_bytes_get(b, 2) == 128);
    assert(pion_bytes_get(b, 3) == 255);

    void *b0 = pion_bytes_from_ptr(p, 0);
    assert(pion_bytes_len(b0) == 0);
    pion_rc_dec(b0);

    void *dst = pion_ptr_alloc(16);
    pion_bytes_copy_to_ptr(b, 1, dst, 2);
    assert(pion_ptr_read_u8(dst, 0) == 127);
    assert(pion_ptr_read_u8(dst, 1) == 128);
    pion_ptr_free(dst);
    pion_ptr_free(p);
    pion_rc_dec(b);

    /* 2. fs_symlink / fs_lstat / fs_readlink / fs_chmod / fs_read_range_nofollow */
    char dirbuf[256];
    snprintf(dirbuf, sizeof(dirbuf), "%s/pion_rt_p22a_%lld_%lld",
             pion_test_tmpdir(), (long long)pion_test_getpid(), (long long)pion_world_clock_ms(w));
    void *dir_s = pion_str_from_cstr(dirbuf, (int64_t)strlen(dirbuf));
    assert(pion_world_fs_mkdir_p(w, dir_s) == 1);

    char fbuf[300], lbuf[300], sbuf[300];
    snprintf(fbuf, sizeof(fbuf), "%s/data.bin", dirbuf);
    snprintf(lbuf, sizeof(lbuf), "%s/sym.bin", dirbuf);
    snprintf(sbuf, sizeof(sbuf), "%s/sub", dirbuf);
    void *f_s = pion_str_from_cstr(fbuf, (int64_t)strlen(fbuf));
    void *l_s = pion_str_from_cstr(lbuf, (int64_t)strlen(lbuf));
    void *sub_s = pion_str_from_cstr(sbuf, (int64_t)strlen(sbuf));
    void *content = pion_str_from_cstr("0123456789abcdefghij", 20);
    assert(pion_world_fs_write(w, f_s, content) == 1);
    assert(pion_world_fs_mkdir_p(w, sub_s) == 1);
    assert(pion_world_fs_chmod(w, f_s, 0644) == 1);

    int32_t ok = 0;
    void *ls_file = pion_world_fs_lstat(w, f_s, &ok);
    assert(ok == 1);
    assert(strncmp(((PionString *)ls_file)->data, "file|20|0|", 10) == 0);
    pion_rc_dec(ls_file);

#ifndef _WIN32
    assert(pion_world_fs_chmod(w, f_s, 0755) == 1);
    void *ls_exec = pion_world_fs_lstat(w, f_s, &ok);
    assert(ok == 1);
    assert(strncmp(((PionString *)ls_exec)->data, "file|20|1|", 10) == 0);
    pion_rc_dec(ls_exec);
#endif

    void *ls_dir = pion_world_fs_lstat(w, sub_s, &ok);
    assert(ok == 1);
    assert(strncmp(((PionString *)ls_dir)->data, "dir|", 4) == 0);
    pion_rc_dec(ls_dir);

    void *tgt_s = pion_str_from_cstr("data.bin", 8);
#ifndef _WIN32
    assert(pion_world_fs_symlink(w, tgt_s, l_s) == 1);
    void *ls_lnk = pion_world_fs_lstat(w, l_s, &ok);
    assert(ok == 1);
    assert(strncmp(((PionString *)ls_lnk)->data, "link|", 5) == 0);
    pion_rc_dec(ls_lnk);

    void *rl = pion_world_fs_readlink(w, l_s, &ok);
    assert(ok == 1 && pion_str_eq(rl, tgt_s) == 1);
    pion_rc_dec(rl);

    /* pion_fs_canon_path: symlink, dangling symlink, nonexistent dir + '..', cycle -> NULL & empty */
    char *cp_f = pion_fs_canon_path(fbuf);
    char *cp_l = pion_fs_canon_path(lbuf);
    assert(cp_f != NULL && cp_l != NULL && strcmp(cp_f, cp_l) == 0);
    free(cp_f);
    free(cp_l);
    assert(pion_fs_canon_path("") == NULL);

    char dlink[320], dne[320], bypass[340], cyca[320], cycb[320];
    snprintf(dlink, sizeof(dlink), "%s/dlink.mjs", dirbuf);
    snprintf(dne, sizeof(dne), "%s/nonexistent.mjs", dirbuf);
    assert(symlink("nonexistent.mjs", dlink) == 0);
    char *cp_dl = pion_fs_canon_path(dlink);
    char *cp_dne = pion_fs_canon_path(dne);
    assert(cp_dl != NULL && cp_dne != NULL && strcmp(cp_dl, cp_dne) == 0);
    free(cp_dl);
    free(cp_dne);

    snprintf(bypass, sizeof(bypass), "%s/nope/../sym.bin", dirbuf);
    char *cp_bp = pion_fs_canon_path(bypass);
    char *cp_real_f = pion_fs_canon_path(fbuf);
    assert(cp_bp != NULL && cp_real_f != NULL && strcmp(cp_bp, cp_real_f) == 0);
    free(cp_bp);
    free(cp_real_f);

    /* Non-existent dir + '..' followed by directory symlink + '..' must resolve the symlink first */
    char hop_sub[340], hop_lnk[340], hop_in[380], hop_exp[340];
    snprintf(hop_sub, sizeof(hop_sub), "%s/sub/inner", dirbuf);
    void *hop_sub_s = pion_str_from_cstr(hop_sub, (int64_t)strlen(hop_sub));
    assert(pion_world_fs_mkdir_p(w, hop_sub_s) == 1);
    pion_rc_dec(hop_sub_s);
    snprintf(hop_lnk, sizeof(hop_lnk), "%s/hop", dirbuf);
    assert(symlink(hop_sub, hop_lnk) == 0);
    snprintf(hop_in, sizeof(hop_in), "%s/nope/../hop/../out.mjs", dirbuf);
    snprintf(hop_exp, sizeof(hop_exp), "%s/sub/out.mjs", dirbuf);
    char *cp_hop_in = pion_fs_canon_path(hop_in);
    char *cp_hop_exp = pion_fs_canon_path(hop_exp);
    assert(cp_hop_in != NULL && cp_hop_exp != NULL && strcmp(cp_hop_in, cp_hop_exp) == 0);
    free(cp_hop_in);
    free(cp_hop_exp);
    assert(unlink(hop_lnk) == 0);
    assert(rmdir(hop_sub) == 0);

    snprintf(cyca, sizeof(cyca), "%s/cyc_a", dirbuf);
    snprintf(cycb, sizeof(cycb), "%s/cyc_b", dirbuf);
    assert(symlink("cyc_b", cyca) == 0);
    assert(symlink("cyc_a", cycb) == 0);
    assert(pion_fs_canon_path(cyca) == NULL);
    assert(unlink(dlink) == 0);
    assert(unlink(cyca) == 0);
    assert(unlink(cycb) == 0);
#else
    char jbuf[320], jcmd[768];
    snprintf(jbuf, sizeof(jbuf), "%s\\junc_sub", dirbuf);
    for (char *q = jbuf; *q; q++) {
        if (*q == '/') *q = '\\';
    }
    char sub_win[300];
    snprintf(sub_win, sizeof(sub_win), "%s", sbuf);
    for (char *q = sub_win; *q; q++) {
        if (*q == '/') *q = '\\';
    }
    snprintf(jcmd, sizeof(jcmd), "cmd /c mklink /J \"%s\" \"%s\" >nul 2>&1", jbuf, sub_win);
    assert(system(jcmd) == 0);
    void *j_s = pion_str_from_cstr(jbuf, (int64_t)strlen(jbuf));
    void *rl_j = pion_world_fs_readlink(w, j_s, &ok);
    assert(ok == 1 && pion_str_len(rl_j) > 0);
    assert(strstr(((PionString *)rl_j)->data, "sub") != NULL);
    pion_rc_dec(rl_j);
    void *rl_dir = pion_world_fs_readlink(w, sub_s, &ok);
    assert(ok == 0 && pion_str_len(rl_dir) > 0);
    pion_rc_dec(rl_dir);

    /* Short-name parent must NOT make ordinary dir look like a reparse point,
       while pion_fs_canon_path must canonicalize short-name, junction, relative & drive-root paths identically */
    wchar_t sub_w[320], short_w[320];
    int sub_wl = MultiByteToWideChar(CP_UTF8, 0, sub_win, -1, sub_w, 320);
    if (sub_wl > 0) {
        DWORD swl = GetShortPathNameW(sub_w, short_w, 320);
        if (swl > 0 && swl < 320) {
            char short_u8[320];
            int su8 = WideCharToMultiByte(CP_UTF8, 0, short_w, (int)swl, short_u8, 319, NULL, NULL);
            if (su8 > 0) {
                short_u8[su8] = '\0';
                void *short_s = pion_str_from_cstr(short_u8, (int64_t)su8);
                void *rl_short = pion_world_fs_readlink(w, short_s, &ok);
                assert(ok == 0);
                pion_rc_dec(rl_short);
                char *cp_short = pion_fs_canon_path(short_u8);
                char *cp_sub = pion_fs_canon_path(sub_win);
                assert(cp_short != NULL && cp_sub != NULL && strcmp(cp_short, cp_sub) == 0);
                free(cp_short);
                free(cp_sub);
                pion_rc_dec(short_s);
            }
        }
    }
    char *cp_junc = pion_fs_canon_path(jbuf);
    char *cp_real = pion_fs_canon_path(sub_win);
    assert(cp_junc != NULL && cp_real != NULL && strcmp(cp_junc, cp_real) == 0);
    if (strlen(cp_real) >= 3 && cp_real[1] == ':') {
        char *cp_drel = pion_fs_canon_path(cp_real + 2);
        assert(cp_drel != NULL && strlen(cp_drel) > 0);
        free(cp_drel);
    }
    free(cp_junc);
    free(cp_real);
    pion_rc_dec(j_s);
    snprintf(jcmd, sizeof(jcmd), "cmd /c rmdir \"%s\" >nul 2>&1", jbuf);
    (void)system(jcmd);
#endif

    void *rl_err = pion_world_fs_readlink(w, f_s, &ok);
    assert(ok == 0 && pion_str_len(rl_err) > 0);
    pion_rc_dec(rl_err);

    /* fs_read_range_nofollow: normal, symlink reject, wrong size reject */
    void *rng = pion_world_fs_read_range_nofollow(w, f_s, 5, 10, 20, &ok);
    assert(ok == 1 && pion_bytes_len(rng) == 10);
    void *rng_s = pion_bytes_to_str(rng);
    void *want_s = pion_str_from_cstr("56789abcde", 10);
    assert(pion_str_eq(rng_s, want_s) == 1);
    pion_rc_dec(want_s);
    pion_rc_dec(rng_s);
    pion_rc_dec(rng);

#ifndef _WIN32
    void *rng_sym = pion_world_fs_read_range_nofollow(w, l_s, 0, 4, 20, &ok);
    assert(ok == 0 && strcmp(((PionString *)rng_sym)->data, "changed") == 0);
    pion_rc_dec(rng_sym);
#endif

    void *rng_sz = pion_world_fs_read_range_nofollow(w, f_s, 0, 4, 19, &ok);
    assert(ok == 0 && strcmp(((PionString *)rng_sz)->data, "changed") == 0);
    pion_rc_dec(rng_sz);

    /* 3. pion_world_exec_capture_bytes with NUL bytes and silenced stderr */
    void *argv_arr = pion_arr_new(4, 1);
    void *a0 = pion_str_from_cstr(PION_TEST_SH, (int64_t)strlen(PION_TEST_SH));
    void *a1 = pion_str_from_cstr("-c", 2);
    void *a2 = pion_str_from_cstr("printf 'a\\000b\\377'; echo err >&2", 33);
    pion_arr_push(argv_arr, (int64_t)(uintptr_t)a0);
    pion_arr_push(argv_arr, (int64_t)(uintptr_t)a1);
    pion_arr_push(argv_arr, (int64_t)(uintptr_t)a2);
    int32_t ec = -1;
    void *cap_b = pion_world_exec_capture_bytes(w, argv_arr, &ec);
    assert(ec == 0 && pion_bytes_len(cap_b) == 4);
    assert(pion_bytes_get(cap_b, 0) == 'a');
    assert(pion_bytes_get(cap_b, 1) == 0);
    assert(pion_bytes_get(cap_b, 2) == 'b');
    assert(pion_bytes_get(cap_b, 3) == 255);
    pion_rc_dec(cap_b);
    pion_rc_dec(a0);
    pion_rc_dec(a1);
    pion_rc_dec(a2);
    pion_rc_dec(argv_arr);

    /* 4. pion_world_read_line via redirected stdin pipe (CRLF, empty line, long line, EOF) */
#ifdef _WIN32
    int saved_stdin = _dup(0);
    assert(saved_stdin >= 0);
    int rpipe[2];
    assert(_pipe(rpipe, 8192, _O_BINARY) == 0);
    const char *p1 = "hello\r\n\n";
    assert(_write(rpipe[1], p1, (unsigned int)strlen(p1)) == (int)strlen(p1));
    char longbuf[5000];
    memset(longbuf, 'x', sizeof(longbuf));
    assert(_write(rpipe[1], longbuf, (unsigned int)sizeof(longbuf)) == (int)sizeof(longbuf));
    _close(rpipe[1]);
    assert(_dup2(rpipe[0], 0) >= 0);
    _close(rpipe[0]);
#else
    int saved_stdin = dup(STDIN_FILENO);
    assert(saved_stdin >= 0);
    int rpipe[2];
    assert(pipe(rpipe) == 0);
    const char *p1 = "hello\r\n\n";
    assert(write(rpipe[1], p1, strlen(p1)) == (ssize_t)strlen(p1));
    char longbuf[5000];
    memset(longbuf, 'x', sizeof(longbuf));
    assert(write(rpipe[1], longbuf, sizeof(longbuf)) == (ssize_t)sizeof(longbuf));
    close(rpipe[1]);
    assert(dup2(rpipe[0], STDIN_FILENO) >= 0);
    close(rpipe[0]);
#endif
    clearerr(stdin);

    void *ln1 = pion_world_read_line(w, &ok);
    assert(ok == 1 && pion_str_len(ln1) == 5 && strcmp(((PionString *)ln1)->data, "hello") == 0);
    pion_rc_dec(ln1);

    void *ln2 = pion_world_read_line(w, &ok);
    assert(ok == 1 && pion_str_len(ln2) == 0);
    pion_rc_dec(ln2);

    void *ln3 = pion_world_read_line(w, &ok);
    assert(ok == 1 && pion_str_len(ln3) == 5000);
    pion_rc_dec(ln3);

    void *ln4 = pion_world_read_line(w, &ok);
    assert(ok == 0 && pion_str_len(ln4) == 0);
    pion_rc_dec(ln4);

#ifdef _WIN32
    assert(_dup2(saved_stdin, 0) >= 0);
    _close(saved_stdin);
#else
    assert(dup2(saved_stdin, STDIN_FILENO) >= 0);
    close(saved_stdin);
#endif
    clearerr(stdin);

#ifndef _WIN32
    assert(pion_world_fs_remove(w, l_s) == 1);
#endif
    assert(pion_world_fs_remove(w, f_s) == 1);
    assert(pion_test_rmdir(sbuf) == 0);
    assert(pion_test_rmdir(dirbuf) == 0);
    pion_rc_dec(tgt_s);
    pion_rc_dec(content);
    pion_rc_dec(sub_s);
    pion_rc_dec(l_s);
    pion_rc_dec(f_s);
    pion_rc_dec(dir_s);
    pion_rc_dec(w);
    printf("[PASS] p22a_systems_io\n");
}

static void st_frozen_mt_worker(void *arg) {
    void *ch = *(void **)arg;
    int64_t v = 0;
    while (pion_chan_recv(ch, &v)) {
        void *obj = (void *)(uintptr_t)v;
        assert(((uint64_t *)obj)[0] == 0xCAFEBABEULL);
        pion_rc_dec(obj);
    }
}

static void st_frozen_mt_env_drop(void *p) {
    void **env = (void **)p;
    pion_rc_dec(*env);
}

static void record_unique_ptr(void **seen, int *count, int max_seen, void *p) {
    int limit = (*count < max_seen) ? *count : max_seen;
    for (int k = 0; k < limit; k++) {
        if (seen[k] == p) return;
    }
    if (*count < max_seen) {
        seen[*count] = p;
    }
    (*count)++;
}

static void test_st_frozen_slab_recycle(void) {
    /* Must run while still in single-thread mode (g_pion_mt == 0) */
    assert(pion_mt_flag == 0);

    void *obj_seen[8];
    void *arr_seen[8];
    void *med_seen[8];
    int obj_uniq = 0, arr_uniq = 0, med_uniq = 0;

    for (int i = 0; i < 50000; i++) {
        void *obj = pion_alloc_uninit(48u, PION_TAG_STRUCT, NULL);
        ((uint64_t *)obj)[0] = (uint64_t)i;
        void *arr = pion_arr_new(8, 0);
        pion_arr_push(arr, (int64_t)i);
        void *med = pion_arr_new(4096, 0); /* 32 KB backing buffer */
        pion_arr_push(med, (int64_t)i);

        if (i >= 10) {
            record_unique_ptr(obj_seen, &obj_uniq, 8, obj);
            record_unique_ptr(arr_seen, &arr_uniq, 8, ((PionArray *)arr)->data);
            record_unique_ptr(med_seen, &med_uniq, 8, ((PionArray *)med)->data);
        }

        pion_rc_freeze(obj);
        pion_rc_freeze(arr);
        pion_rc_freeze(med);

        pion_rc_dec(obj);
        pion_rc_dec(arr);
        pion_rc_dec(med);
    }

#if !defined(__SANITIZE_ADDRESS__)
#if defined(__has_feature)
#if !__has_feature(address_sanitizer)
    assert(obj_uniq >= 1 && obj_uniq <= 4);
    assert(arr_uniq >= 1 && arr_uniq <= 4);
    assert(med_uniq >= 1 && med_uniq <= 4);
#endif
#else
    assert(obj_uniq >= 1 && obj_uniq <= 4);
    assert(arr_uniq >= 1 && arr_uniq <= 4);
    assert(med_uniq >= 1 && med_uniq <= 4);
#endif
#endif

    /* Transition ST -> MT (g_pion_mt = 1) right after ST frozen slab recycling
     * and verify cross-thread frozen slab release under ASan + TSan. */
    void *pre_objs[32];
    for (int i = 0; i < 32; i++) {
        pre_objs[i] = pion_alloc_uninit(48u, PION_TAG_STRUCT, NULL);
        ((uint64_t *)pre_objs[i])[0] = 0xCAFEBABEULL;
        pion_rc_freeze(pre_objs[i]);
    }
    void *ch = pion_chan_new(64, 1);
    void *sc = pion_scope_begin();
    void **env = (void **)pion_alloc((uint32_t)sizeof(void *), PION_TAG_STRUCT, st_frozen_mt_env_drop);
    pion_rc_inc(ch);
    *env = ch;
    pion_scope_spawn(sc, st_frozen_mt_worker, env);
    pion_rc_dec(env);
    for (int i = 0; i < 32; i++) {
        pion_chan_send(ch, (int64_t)(uintptr_t)pre_objs[i]);
        pion_rc_dec(pre_objs[i]);
    }
    for (int i = 0; i < 32; i++) {
        void *mt_obj = pion_alloc_uninit(48u, PION_TAG_STRUCT, NULL);
        ((uint64_t *)mt_obj)[0] = 0xCAFEBABEULL;
        pion_chan_send(ch, (int64_t)(uintptr_t)mt_obj);
        pion_rc_dec(mt_obj);
    }
    pion_chan_close(ch);
    pion_scope_end(sc);
    pion_rc_dec(ch);
    printf("[PASS] st_frozen_slab_recycle (50k ST frozen uniq: slab=%d arr=%d med32k=%d + ST->MT handoff)\n",
           obj_uniq, arr_uniq, med_uniq);
}

static void test_p57b_hot_str_and_split(void) {
    /* 1. pion_str_slice: 0B / 1B / 2..16B / >16B */
    void *base = pion_str_from_cstr("abcdefghijklmnopqrstuvwxyz0123456789", 36);
    void *s0 = pion_str_slice(base, 5, 5);
    assert(pion_str_len(s0) == 0 && strcmp(((PionString *)s0)->data, "") == 0);
    void *s1 = pion_str_slice(base, 3, 4);
    assert(pion_str_len(s1) == 1 && strcmp(((PionString *)s1)->data, "d") == 0);
    for (int len = 2; len <= 16; len++) {
        void *sk = pion_str_slice(base, 2, 2 + len);
        assert(pion_str_len(sk) == len);
        assert(memcmp(((PionString *)sk)->data, "cdefghijklmnopqrstuvwxyz", (size_t)len) == 0);
        assert(((PionString *)sk)->data[len] == '\0');
        pion_rc_dec(sk);
    }
    void *slong = pion_str_slice(base, 0, 26);
    assert(pion_str_len(slong) == 26 && strcmp(((PionString *)slong)->data, "abcdefghijklmnopqrstuvwxyz") == 0);
    pion_rc_dec(s0);
    pion_rc_dec(s1);
    pion_rc_dec(slong);
    pion_rc_dec(base);

    /* 2. pion_int_to_str: 0 / single digit / negative / INT64_MIN / INT64_MAX */
    struct { int64_t v; const char *exp; } icases[] = {
        { 0, "0" },
        { 7, "7" },
        { -9, "-9" },
        { -123456, "-123456" },
        { INT64_MIN, "-9223372036854775808" },
        { INT64_MAX, "9223372036854775807" },
    };
    for (size_t i = 0; i < sizeof(icases) / sizeof(icases[0]); i++) {
        void *si = pion_int_to_str(icases[i].v);
        assert(strcmp(((PionString *)si)->data, icases[i].exp) == 0);
        assert(pion_str_len(si) == (int64_t)strlen(icases[i].exp));
        pion_rc_dec(si);
    }

    /* 3. pion_str_concat: empty / NULL / short / long */
    void *emp = pion_str_from_cstr("", 0);
    void *sh1 = pion_str_from_cstr("foo", 3);
    void *sh2 = pion_str_from_cstr("bar!", 4);
    void *lg1 = pion_str_from_cstr("0123456789abcdef0123456789abcdef", 32);
    void *c_null = pion_str_concat(NULL, NULL);
    assert(pion_str_len(c_null) == 0 && strcmp(((PionString *)c_null)->data, "") == 0);
    void *c_emp = pion_str_concat(emp, sh1);
    assert(strcmp(((PionString *)c_emp)->data, "foo") == 0);
    void *c_sh = pion_str_concat(sh1, sh2);
    assert(strcmp(((PionString *)c_sh)->data, "foobar!") == 0);
    void *c_lg = pion_str_concat(lg1, sh2);
    assert(pion_str_len(c_lg) == 36 && strcmp(((PionString *)c_lg)->data, "0123456789abcdef0123456789abcdefbar!") == 0);
    pion_rc_dec(c_null);
    pion_rc_dec(c_emp);
    pion_rc_dec(c_sh);
    pion_rc_dec(c_lg);
    pion_rc_dec(emp);
    pion_rc_dec(sh1);
    pion_rc_dec(sh2);
    pion_rc_dec(lg1);

    /* 4. pion_str_split: >8KB multi-separator & >8KB zero-separator */
    size_t big_n = 12000;
    char *buf = (char *)malloc(big_n);
    assert(buf != NULL);
    for (size_t i = 0; i < big_n; i++) {
        buf[i] = (i % 5 == 4) ? ',' : (char)('a' + (i % 26));
    }
    void *big_multi = pion_str_from_cstr(buf, (int64_t)big_n);
    void *sep_comma = pion_str_from_cstr(",", 1);
    void *parts_multi = pion_str_split(big_multi, sep_comma);
    assert(pion_arr_len(parts_multi) == (int64_t)(big_n / 5 + 1));
    assert(((PionArray *)parts_multi)->cap >= pion_arr_len(parts_multi));
    pion_rc_dec(parts_multi);
    pion_rc_dec(big_multi);

    memset(buf, 'z', big_n);
    void *big_none = pion_str_from_cstr(buf, (int64_t)big_n);
    void *parts_none = pion_str_split(big_none, sep_comma);
    assert(pion_arr_len(parts_none) == 1);
    void *only = (void *)(uintptr_t)pion_arr_get(parts_none, 0);
    assert(pion_str_len(only) == (int64_t)big_n);
    pion_rc_dec(parts_none);
    pion_rc_dec(big_none);
    pion_rc_dec(sep_comma);
    free(buf);

    /* 5. pion_arr_new slab bump & recycle */
    void *arrs[64];
    for (int i = 0; i < 64; i++) {
        arrs[i] = pion_arr_new(4, 0);
        pion_arr_push(arrs[i], (int64_t)i * 3);
        assert(pion_arr_get(arrs[i], 0) == (int64_t)i * 3);
    }
    for (int i = 0; i < 64; i++) {
        pion_rc_dec(arrs[i]);
    }
    for (int i = 0; i < 64; i++) {
        void *a = pion_arr_new(4, 0);
        pion_arr_push(a, (int64_t)i + 100);
        assert(pion_arr_get(a, 0) == (int64_t)i + 100);
        pion_rc_dec(a);
    }
    printf("[PASS] p57b_hot_str_and_split\n");
}

static void test_p61b_map_hint_hit_miss_aba(void) {
    /* 1. try_get hit -> set in-place update (Int and String obj RC) */
    void *mi = pion_map_new(0);
    void *k1 = pion_str_from_cstr("w12345", 6);
    pion_map_set(mi, k1, 10);
    int64_t v = 0;
    assert(pion_map_try_get(mi, k1, &v) == 1 && v == 10);
    pion_map_set(mi, k1, 42);
    assert(pion_map_get(mi, k1) == 42);
    assert(pion_map_len(mi) == 1);

    void *ms = pion_map_new(1);
    void *v1 = pion_str_from_cstr("val_one", 7);
    void *v2 = pion_str_from_cstr("val_two", 7);
    pion_map_set(ms, k1, (int64_t)(uintptr_t)v1);
    assert(pion_map_try_get(ms, k1, &v) == 1 && (void *)(uintptr_t)v == v1);
    pion_map_set(ms, k1, (int64_t)(uintptr_t)v2);
    assert((void *)(uintptr_t)pion_map_get(ms, k1) == v2);
    pion_rc_dec(v1);
    pion_rc_dec(v2);
    pion_rc_dec(ms);

    /* 2. try_get miss -> immediate set insert across grow boundary (cap=16 -> 32 -> 64) */
    char kbuf[32];
    for (int i = 0; i < 40; i++) {
        int n = snprintf(kbuf, sizeof(kbuf), "k_%02d", i);
        void *ki = pion_str_from_cstr(kbuf, n);
        assert(pion_map_try_get(mi, ki, &v) == 0);
        pion_map_set(mi, ki, (int64_t)(i * 7 + 1));
        assert(pion_map_get(mi, ki) == (int64_t)(i * 7 + 1));
        pion_rc_dec(ki);
    }
    assert(pion_map_len(mi) == 41);

    /* 3. ABA stress: try_get(m, s1), destroy s1, reallocate same-size s2 (reusing slab addr) */
    void *s1_orig = pion_str_from_cstr("alpha7", 6);
    pion_map_set(mi, s1_orig, 111);
    pion_rc_dec(s1_orig);

    int reused_addr = 0;
    for (int iter = 0; iter < 64; iter++) {
        void *s1 = pion_str_from_cstr("alpha7", 6);
        uintptr_t addr1 = (uintptr_t)s1;
        assert(pion_map_try_get(mi, s1, &v) == 1 && v == 111);
        pion_rc_dec(s1); /* triggers pion_destroy -> must invalidate g_map_hint */

        int n = snprintf(kbuf, sizeof(kbuf), "beta%02d", iter);
        void *s2 = pion_str_from_cstr(kbuf, n);
        if ((uintptr_t)s2 == addr1) reused_addr++;
        pion_map_set(mi, s2, 999 + iter);
        assert(pion_map_get(mi, s2) == 999 + iter);

        void *s1_copy = pion_str_from_cstr("alpha7", 6);
        assert(pion_map_get(mi, s1_copy) == 111);
        pion_rc_dec(s1_copy);
        pion_rc_dec(s2);
    }
    (void)reused_addr;

    /* 4. remove / clear followed immediately by set / get must not use stale hint */
    void *kr = pion_str_from_cstr("rmkey", 5);
    pion_map_set(mi, kr, 77);
    assert(pion_map_try_get(mi, kr, &v) == 1 && v == 77);
    pion_map_remove(mi, kr);
    assert(pion_map_try_get(mi, kr, &v) == 0);
    pion_map_set(mi, kr, 88);
    assert(pion_map_get(mi, kr) == 88);

    assert(pion_map_try_get(mi, kr, &v) == 1 && v == 88);
    pion_map_clear(mi);
    assert(pion_map_len(mi) == 0);
    assert(pion_map_try_get(mi, kr, &v) == 0);
    pion_map_set(mi, kr, 99);
    assert(pion_map_get(mi, kr) == 99);

    pion_rc_dec(kr);
    pion_rc_dec(k1);
    pion_rc_dec(mi);
    printf("[PASS] p61b_map_hint_hit_miss_aba\n");
}

static void test_p71c_hashdos_bit63_noncollision(void) {
    /* Construct 4096 bit-63 multi-collision keys (k=12 pairs of 16-byte blocks = 192B each).
     * Under the old `h ^= w; h *= K; h ^= h >> 32`, all 4096 keys had the exact same hash
     * regardless of random seed. With 128-bit dual-secret wymix, they distribute uniformly. */
    void *m = pion_map_new(0);
    const int k = 12;
    const int n = 1 << k;
    char buf[12 * 16 + 1];
    buf[k * 16] = '\0';
    double t0 = monotonic_sec();
    for (int idx = 0; idx < n; idx++) {
        for (int i = 0; i < k; i++) {
            int base = i * 16;
            for (int j = 0; j < 16; j++) {
                buf[base + j] = (char)('A' + ((i + j) % 26));
            }
            if ((idx >> i) & 1) {
                buf[base + 7] = (char)((unsigned char)buf[base + 7] ^ 0x80u);
                buf[base + 11] = (char)((unsigned char)buf[base + 11] ^ 0x80u);
                buf[base + 15] = (char)((unsigned char)buf[base + 15] ^ 0x80u);
            }
        }
        void *ks = pion_str_from_cstr(buf, (int64_t)(k * 16));
        pion_map_set(m, ks, (int64_t)(idx * 7 + 3));
        pion_rc_dec(ks);
    }
    assert(pion_map_len(m) == n);
    for (int idx = 0; idx < n; idx++) {
        for (int i = 0; i < k; i++) {
            int base = i * 16;
            for (int j = 0; j < 16; j++) {
                buf[base + j] = (char)('A' + ((i + j) % 26));
            }
            if ((idx >> i) & 1) {
                buf[base + 7] = (char)((unsigned char)buf[base + 7] ^ 0x80u);
                buf[base + 11] = (char)((unsigned char)buf[base + 11] ^ 0x80u);
                buf[base + 15] = (char)((unsigned char)buf[base + 15] ^ 0x80u);
            }
        }
        void *ks = pion_str_from_cstr(buf, (int64_t)(k * 16));
        int64_t out = 0;
        assert(pion_map_try_get(m, ks, &out) == 1);
        assert(out == (int64_t)(idx * 7 + 3));
        pion_rc_dec(ks);
    }
    double dt = (monotonic_sec() - t0) * 1000.0;
    pion_rc_dec(m);
    printf("[PASS] p71c_hashdos_bit63_noncollision (%d bit-63 attack keys insert+lookup: %.2f ms)\n", n, dt);
}

/* UTF-8 paths through every runtime file API (UTF-16 wide APIs on Windows),
 * and paths with an embedded NUL refused while their length is still known:
 * `<prefix>\0<suffix>` must fail and never touch `<prefix>` on disk. */
static void *u8s(const char *a, const char *b) {
    char buf[1400];
    int n = snprintf(buf, sizeof(buf), "%s%s", a, b);
    assert(n > 0 && (size_t)n < sizeof(buf));
    return pion_str_from_cstr(buf, n);
}

static void *u8s_nul(const char *prefix, const char *suffix) {
    char buf[1400];
    size_t pl = strlen(prefix), sl = strlen(suffix);
    assert(pl + 1 + sl < sizeof(buf));
    memcpy(buf, prefix, pl);
    buf[pl] = '\0';
    memcpy(buf + pl + 1, suffix, sl);
    return pion_str_from_cstr(buf, (int64_t)(pl + 1 + sl));
}

static int u8_str_is(void *s, const char *want) {
    void *w = pion_str_from_cstr(want, -1);
    int eq = pion_str_eq(s, w) == 1;
    pion_rc_dec(w);
    return eq;
}

/* pion_fs_lstat_kind: 0 missing, 1 file, 2 dir, 3 symlink, -1 query error
 * (never "missing"): NULL/empty paths, and on POSIX a path below a 0000
 * directory (EACCES; as root, checked in a child running as nobody). */
static void test_fs_lstat_kind(void) {
    char base[600], missing[700], file[700], below[700];
    snprintf(base, sizeof(base), "%s/pion_lk_%d", pion_test_tmpdir(), pion_test_getpid());
    snprintf(missing, sizeof(missing), "%s/missing", base);
    snprintf(file, sizeof(file), "%s/file", base);
    snprintf(below, sizeof(below), "%s/file/below", base);
    assert(pion_fs_lstat_kind(NULL) == -1 && pion_fs_lstat_kind("") == -1);
    assert(pion_fs_mkdir_excl(base) == 0);
    assert(pion_fs_lstat_kind(base) == 2);
    assert(pion_fs_lstat_kind(missing) == 0);
    FILE *f = fopen(file, "w");
    assert(f);
    fputs("x", f);
    fclose(f);
    assert(pion_fs_lstat_kind(file) == 1);
#ifndef _WIN32
    char link[700], locked[700], hidden[700];
    snprintf(link, sizeof(link), "%s/link", base);
    snprintf(locked, sizeof(locked), "%s/locked", base);
    snprintf(hidden, sizeof(hidden), "%s/locked/hidden", base);
    assert(pion_fs_lstat_kind(below) == -1); /* ENOTDIR, not "missing" */
    assert(symlink("missing", link) == 0);
    assert(pion_fs_lstat_kind(link) == 3); /* dangling: the link itself */
    assert(chmod(base, 0755) == 0);
    assert(mkdir(locked, 0700) == 0);
    f = fopen(hidden, "w");
    assert(f);
    fclose(f);
    assert(chmod(locked, 0000) == 0);
    if (geteuid() != 0) {
        assert(pion_fs_lstat_kind(hidden) == -1); /* EACCES */
    } else {
        pid_t pid = fork();
        assert(pid >= 0);
        if (pid == 0) {
            if (setgid(65534) != 0 || setuid(65534) != 0) _exit(2);
            _exit(pion_fs_lstat_kind(hidden) == -1 ? 0 : 1);
        }
        int st = 0;
        assert(waitpid(pid, &st, 0) == pid);
        assert(WIFEXITED(st) && WEXITSTATUS(st) == 0);
    }
    assert(chmod(locked, 0700) == 0);
    assert(unlink(hidden) == 0 && rmdir(locked) == 0 && unlink(link) == 0);
#else
    (void)below;
#endif
    assert(remove(file) == 0);
    assert(pion_fs_rmdir(base) == 0);
    assert(pion_fs_lstat_kind(base) == 0);
    printf("[PASS] fs_lstat_kind (missing / file / dir / symlink / query errors)\n");
}

static const char *g_lock_path;
static atomic_int g_lock_started;
static atomic_int g_lock_released;
static atomic_int g_lock_saw_released;

static void lock_waiter(void *env) {
    (void)env;
    atomic_store(&g_lock_started, 1);
    int64_t h = pion_fs_lock(g_lock_path);
    assert(h >= 0);
    /* Only granted once the main thread has released its lock. */
    atomic_store(&g_lock_saw_released, atomic_load(&g_lock_released));
    pion_fs_unlock(h);
}

/* The blocking lock excludes trylock and a second blocking locker until it
 * is released (a spawn worker takes it after the main thread). This checks
 * mutual exclusion and acquisition after release deterministically; with no
 * sleep it does not force the worker to be blocked inside flock first, so it
 * does not measure blocking timing. Runs with the MT tests: spawning
 * switches the runtime to multi-threaded mode. */
static void test_fs_lock_blocking(void) {
    char path[700];
    snprintf(path, sizeof(path), "%s/pion_lock_%d.flock", pion_test_tmpdir(), pion_test_getpid());
    g_lock_path = path;
    atomic_store(&g_lock_started, 0);
    atomic_store(&g_lock_released, 0);
    atomic_store(&g_lock_saw_released, 0);
    int64_t h = pion_fs_lock(path);
    assert(h >= 0);
    assert(pion_fs_trylock(path) == -1);
    void *sc = pion_scope_begin();
    pion_scope_spawn(sc, lock_waiter, NULL);
    while (!atomic_load(&g_lock_started)) {
    }
    atomic_store(&g_lock_released, 1);
    pion_fs_unlock(h);
    pion_scope_end(sc);
    assert(atomic_load(&g_lock_saw_released) == 1);
    int64_t t = pion_fs_trylock(path);
    assert(t >= 0);
    pion_fs_unlock(t);
    remove(path);
    printf("[PASS] fs_lock_blocking (pion_fs_lock excludes trylock and a waiting locker)\n");
}

static void test_utf8_paths_and_embedded_nul(int argc, char **argv) {
    void *w = pion_world_init(argc, argv);
    int32_t ok = 0;
    char root[600];
    snprintf(root, sizeof(root), "%s/pion_u8_%d", pion_test_tmpdir(), pion_test_getpid());
#ifdef _WIN32
    /* Exercise drive-letter paths spelled with forward slashes (C:/...). */
    if (root[0] && root[1] == ':') {
        for (char *q = root; *q; q++) if (*q == '\\') *q = '/';
    }
#endif
    /* Chinese, a space and a non-BMP emoji (a UTF-16 surrogate pair). */
    char dir[700];
    snprintf(dir, sizeof(dir), "%s/中文 目录 \xF0\x9F\x9A\x80", root);
    void *dir_s = pion_str_from_cstr(dir, -1);
    void *sub_s = u8s(dir, "/子目录");
    assert(pion_world_fs_mkdir_p(w, sub_s) == 1);
    assert(pion_world_fs_mkdir_p(w, sub_s) == 1);
    assert(pion_world_fs_is_dir(w, dir_s) == 1 && pion_world_fs_is_dir(w, sub_s) == 1);
    assert(pion_world_fs_exists(w, sub_s) == 1);

    /* File named with CJK Extension B U+20000 (also a surrogate pair). */
    char file[800];
    snprintf(file, sizeof(file), "%s/文件 \xF0\xA0\x80\x80.txt", dir);
    void *file_s = pion_str_from_cstr(file, -1);
    void *body = pion_str_from_cstr("héllo 🚀 world\n", -1);
    int64_t blen = pion_str_len(body);
    assert(pion_world_fs_mtime_ms(w, file_s) == -1);
    assert(pion_world_fs_write(w, file_s, body) == 1);
    assert(pion_world_fs_exists(w, file_s) == 1 && pion_world_fs_is_dir(w, file_s) == 0);
    assert(pion_world_fs_size(w, file_s) == blen);
    assert(pion_world_fs_mtime_ms(w, file_s) > 1700000000000LL);
    void *rd = pion_world_fs_read(w, file_s, &ok);
    assert(ok == 1 && pion_str_eq(rd, body) == 1);
    pion_rc_dec(rd);
    assert(pion_world_fs_append(w, file_s, body) == 1);
    assert(pion_world_fs_size(w, file_s) == 2 * blen);
    void *ls = pion_world_fs_lstat(w, file_s, &ok);
    assert(ok == 1 && strncmp(((PionString *)ls)->data, "file|", 5) == 0);
    pion_rc_dec(ls);
    ls = pion_world_fs_lstat(w, dir_s, &ok);
    assert(ok == 1 && strncmp(((PionString *)ls)->data, "dir|", 4) == 0);
    pion_rc_dec(ls);
    assert(pion_world_fs_chmod(w, file_s, 0644) == 1);

    /* Bytes, atomic replace, nofollow range read and read-only map. */
    void *bytes = pion_bytes_new(6);
    for (int i = 0; i < 6; i++) pion_bytes_set(bytes, i, 'A' + i);
    assert(pion_world_fs_write_bytes(w, file_s, bytes) == 1);
    void *rb = pion_world_fs_read_bytes(w, file_s, &ok);
    assert(ok == 1 && pion_bytes_len(rb) == 6 && pion_bytes_get(rb, 5) == 'F');
    pion_rc_dec(rb);
    for (int i = 0; i < 6; i++) pion_bytes_set(bytes, i, 'a' + i);
    assert(pion_fs_write_atomic_bytes(file_s, bytes) == 1);
    assert(pion_fs_write_atomic_bytes(file_s, bytes) == 1);
    void *rng = pion_world_fs_read_range_nofollow(w, file_s, 2, 3, 6, &ok);
    assert(ok == 1 && pion_bytes_len(rng) == 3 && pion_bytes_get(rng, 0) == 'c' &&
           pion_bytes_get(rng, 2) == 'e');
    pion_rc_dec(rng);
    void *mm = pion_fs_mmap_ro(file_s, &ok);
    assert(ok == 1 && pion_bytes_len(mm) == 6 && pion_bytes_get(mm, 1) == 'b');
    pion_rc_dec(mm);

    /* Listing converts names back to UTF-8 and sorts them by bytes. */
    const char *names[] = {"c.txt", "b-\xC3\xA9.txt", "a-\xF0\x9F\x9A\x80.txt"};
    for (int i = 0; i < 3; i++) {
        char nb[16];
        snprintf(nb, sizeof(nb), "/%s", names[i]);
        void *ps = u8s(dir, nb);
        assert(pion_world_fs_write(w, ps, body) == 1);
        pion_rc_dec(ps);
    }
    const char *sorted[] = {"a-\xF0\x9F\x9A\x80.txt", "b-\xC3\xA9.txt", "c.txt",
                            "子目录", "文件 \xF0\xA0\x80\x80.txt"};
#ifdef _WIN32
    /* An entry that is not valid UTF-16 (unpaired surrogate) is omitted. */
    wchar_t lone[1024];
    int wl = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, dir, -1, lone, 1000);
    assert(wl > 0);
    lone[wl - 1] = L'/';
    lone[wl] = L'x';
    lone[wl + 1] = (wchar_t)0xD800;
    lone[wl + 2] = L'\0';
    HANDLE lh = CreateFileW(lone, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (lh != INVALID_HANDLE_VALUE) CloseHandle(lh);
#endif
    void *ents = pion_world_fs_list_dir(w, dir_s);
    assert(pion_arr_len(ents) == 5);
    for (int i = 0; i < 5; i++) {
        assert(u8_str_is((void *)(uintptr_t)pion_arr_get(ents, i), sorted[i]));
    }
    pion_rc_dec(ents);
#ifdef _WIN32
    if (lh != INVALID_HANDLE_VALUE) assert(DeleteFileW(lone));
#endif

    /* Exclusive mkdir, rmdir and the kernel file lock on UTF-8 names. */
    char excl[800], excl_rm[800], lockp[800];
    snprintf(excl, sizeof(excl), "%s/独占 \xF0\x9F\x94\x92", dir);
    snprintf(excl_rm, sizeof(excl_rm), "%s/删目录 \xF0\x9F\x94\x92", dir);
    snprintf(lockp, sizeof(lockp), "%s/锁 \xF0\x9F\x94\x92.flock", dir);
    assert(pion_fs_mkdir_excl(excl) == 0);
    assert(pion_fs_mkdir_excl(excl) == -1);
    void *excl_s = pion_str_from_cstr(excl, -1);
    assert(pion_world_fs_is_dir(w, excl_s) == 1);
    assert(pion_fs_mkdir_excl(excl_rm) == 0);
    void *excl_rm_s = pion_str_from_cstr(excl_rm, -1);
    assert(pion_world_fs_is_dir(w, excl_rm_s) == 1);
    assert(pion_fs_rmdir(excl_rm) == 0);
    assert(pion_fs_rmdir(excl_rm) == -1);
    assert(pion_world_fs_exists(w, excl_rm_s) == 0);
    pion_rc_dec(excl_rm_s);
    int64_t lk = pion_fs_trylock(lockp);
    assert(lk >= 0);
    assert(pion_fs_trylock(lockp) == -1);
    pion_fs_unlock(lk);
    lk = pion_fs_trylock(lockp);
    assert(lk >= 0);
    pion_fs_unlock(lk);
    void *lock_s = pion_str_from_cstr(lockp, -1);
    assert(pion_world_fs_exists(w, lock_s) == 1);
    /* NULL / empty paths never reach the OS; the pid names pionc temp files. */
    assert(pion_fs_mkdir_excl(NULL) == -1 && pion_fs_mkdir_excl("") == -1);
    assert(pion_fs_rmdir(NULL) == -1 && pion_fs_rmdir("") == -1);
    assert(pion_fs_trylock(NULL) == -1 && pion_fs_trylock("") == -1);
    pion_fs_unlock(-1);
    assert(pion_fs_lock(NULL) == -1 && pion_fs_lock("") == -1);
    assert(pion_cli_getpid() > 0);
#ifdef _WIN32
    assert(pion_cli_is_windows() == 1);
#else
    assert(pion_cli_is_windows() == 0);
#endif

    /* Rename between UTF-8 names (replacing an existing target), then delete. */
    void *moved_s = u8s(dir, "/移动 \xF0\x9F\x9A\x80.bin");
    assert(pion_world_fs_write(w, moved_s, body) == 1);
    assert(pion_world_fs_rename(w, file_s, moved_s) == 1);
    assert(pion_world_fs_exists(w, file_s) == 0 && pion_world_fs_size(w, moved_s) == 6);

    /* Embedded NUL: refused, and `<prefix>` is never created, read or removed. */
    void *real_s = u8s(dir, "/real");
    assert(pion_world_fs_write(w, real_s, body) == 1);
    char realp[800], ghost[800];
    snprintf(realp, sizeof(realp), "%s/real", dir);
    snprintf(ghost, sizeof(ghost), "%s/ghost", dir);
    void *ghost_s = pion_str_from_cstr(ghost, -1);
    void *real_nul = u8s_nul(realp, "junk");
    void *ghost_nul = u8s_nul(ghost, "x/y");
    void *dir_nul = u8s_nul(dir, "zz");
    assert(pion_world_fs_exists(w, real_nul) == 0);
    assert(pion_world_fs_is_dir(w, dir_nul) == 0);
    assert(pion_world_fs_size(w, real_nul) == -1);
    assert(pion_world_fs_mtime_ms(w, real_nul) == -1);
    void *r = pion_world_fs_read(w, real_nul, &ok);
    assert(ok == 0);
    pion_rc_dec(r);
    r = pion_world_fs_read_bytes(w, real_nul, &ok);
    assert(ok == 0);
    pion_rc_dec(r);
    r = pion_world_fs_lstat(w, real_nul, &ok);
    assert(ok == 0);
    pion_rc_dec(r);
    r = pion_world_fs_readlink(w, real_nul, &ok);
    assert(ok == 0);
    pion_rc_dec(r);
    r = pion_world_fs_read_range_nofollow(w, real_nul, 0, 1, blen, &ok);
    assert(ok == 0);
    pion_rc_dec(r);
    r = pion_fs_mmap_ro(real_nul, &ok);
    assert(ok == 0);
    pion_rc_dec(r);
    r = pion_world_fs_list_dir(w, dir_nul);
    assert(pion_arr_len(r) == 0);
    pion_rc_dec(r);
    assert(pion_world_fs_chmod(w, real_nul, 0644) == 0);
    assert(pion_world_fs_remove(w, real_nul) == 0);
    assert(pion_world_fs_exists(w, real_s) == 1);
    assert(pion_world_fs_rename(w, real_nul, ghost_s) == 0);
    assert(pion_world_fs_rename(w, real_s, ghost_nul) == 0);
    assert(pion_world_fs_exists(w, real_s) == 1);
    assert(pion_world_fs_write(w, ghost_nul, body) == 0);
    assert(pion_world_fs_write_bytes(w, ghost_nul, bytes) == 0);
    assert(pion_world_fs_append(w, ghost_nul, body) == 0);
    assert(pion_fs_write_atomic_bytes(ghost_nul, bytes) == 0);
    assert(pion_world_fs_mkdir_p(w, ghost_nul) == 0);
    assert(pion_world_fs_symlink(w, real_s, ghost_nul) == 0);
    assert(pion_world_fs_symlink(w, real_nul, ghost_s) == 0);
    /* The `const char *` entries are fed through pion_fs_cpath, which refuses
     * the NUL path; both entries refuse NULL. */
    PionString *gn = (PionString *)ghost_nul;
    PionString *gs = (PionString *)ghost_s;
    assert(pion_fs_cpath(gn->data, gn->len) == NULL);
    assert(pion_fs_cpath(gs->data, gs->len) == gs->data);
    assert(pion_fs_cpath(gs->data, 0) == NULL && pion_fs_cpath(NULL, 4) == NULL);
    assert(pion_fs_mkdir_excl(pion_fs_cpath(gn->data, gn->len)) == -1);
    assert(pion_fs_rmdir(pion_fs_cpath(gn->data, gn->len)) == -1);
    assert(pion_fs_trylock(pion_fs_cpath(gn->data, gn->len)) == -1);
    assert(pion_fs_canon_path(pion_fs_cpath(gn->data, gn->len)) == NULL);
    assert(pion_world_fs_exists(w, ghost_s) == 0);
    ls = pion_world_fs_lstat(w, ghost_s, &ok);
    assert(ok == 0);
    pion_rc_dec(ls);
    ents = pion_world_fs_list_dir(w, dir_s);
    for (int64_t i = 0; i < pion_arr_len(ents); i++) {
        void *e = (void *)(uintptr_t)pion_arr_get(ents, i);
        assert(!u8_str_is(e, "ghost"));
        assert(strncmp(((PionString *)e)->data, "ghost.piontmp", 13) != 0);
    }
    pion_rc_dec(ents);

#ifdef _WIN32
    /* Invalid UTF-8 never reaches the OS (no U+FFFD substitution). */
    const char *bad[] = {"/bad\xFF\xFE.txt", "/cesu\xED\xA0\x80.txt", "/over\xC0\xAF.txt",
                         "/cut\xF0\x9F\x9A.txt"};
    for (int i = 0; i < 4; i++) {
        void *bs = u8s(dir, bad[i]);
        assert(pion_world_fs_write(w, bs, body) == 0);
        assert(pion_world_fs_mkdir_p(w, bs) == 0);
        assert(pion_world_fs_exists(w, bs) == 0);
        pion_rc_dec(bs);
    }
    char badc[800];
    snprintf(badc, sizeof(badc), "%s/bad\xFF", dir);
    assert(pion_fs_mkdir_excl(badc) == -1);
    assert(pion_fs_rmdir(badc) == -1);
    assert(pion_fs_trylock(badc) == -1);
    assert(pion_fs_canon_path(badc) == NULL);
    ents = pion_world_fs_list_dir(w, dir_s);
    assert(pion_arr_len(ents) == 8);
    pion_rc_dec(ents);
#endif

#ifdef _WIN32
    /* UNC paths: mkdir_p starts after `\\server\share\` (either slash) and
     * accepts the share itself. The local admin share needs the runner to
     * expose it, so whether it ran is printed; PION_REQUIRE_WIN_UNC=1 makes
     * any skip (including a non-drive temp dir) a hard failure. */
    {
        const char *req = getenv("PION_REQUIRE_WIN_UNC");
        int require_unc = req && strcmp(req, "1") == 0;
        int unc_exercised = 0;
        if (dir[1] == ':') {
            char share[24], share_sl[32], probe[900], unc[960], local[960];
            snprintf(share, sizeof(share), "//127.0.0.1/%c$", dir[0]);
            snprintf(share_sl, sizeof(share_sl), "%s/", share);
            snprintf(probe, sizeof(probe), "%s%s", share, dir + 2);
            snprintf(unc, sizeof(unc), "%s/unc 目录/a/b", probe);
            snprintf(local, sizeof(local), "%s/unc 目录/a/b", dir);
            void *probe_s = pion_str_from_cstr(probe, -1);
            if (pion_world_fs_is_dir(w, probe_s)) {
                const char *roots[] = {share, share_sl};
                for (int i = 0; i < 2; i++) {
                    void *rs = pion_str_from_cstr(roots[i], -1);
                    assert(pion_world_fs_mkdir_p(w, rs) == 1);
                    pion_rc_dec(rs);
                }
                const char *missing[] = {"//127.0.0.1/__pion_no_such_share__",
                                         "//127.0.0.1/__pion_no_such_share__/", "//127.0.0.1", "//"};
                for (int i = 0; i < 4; i++) {
                    void *ms = pion_str_from_cstr(missing[i], -1);
                    assert(pion_world_fs_mkdir_p(w, ms) == 0);
                    pion_rc_dec(ms);
                }
                void *unc_s = pion_str_from_cstr(unc, -1);
                assert(pion_world_fs_mkdir_p(w, unc_s) == 1);
                assert(pion_world_fs_mkdir_p(w, unc_s) == 1);
                void *local_s = pion_str_from_cstr(local, -1);
                assert(pion_world_fs_is_dir(w, local_s) == 1);
                for (int i = 0; i < 3; i++) {
                    assert(pion_test_rmdir_u8(local) == 0);
                    *strrchr(local, '/') = '\0';
                }
                pion_rc_dec(local_s);
                pion_rc_dec(unc_s);
                unc_exercised = 1;
                printf("  utf8_paths: UNC mkdir_p via %s ok\n", share_sl);
            } else {
                printf("  utf8_paths: UNC path %s not reachable, UNC mkdir_p skipped\n", probe);
            }
            pion_rc_dec(probe_s);
        } else {
            printf("  utf8_paths: temp dir '%s' has no drive prefix, UNC mkdir_p skipped\n", dir);
        }
        if (require_unc && !unc_exercised) {
            fprintf(stderr, "FAIL: PION_REQUIRE_WIN_UNC=1 but UNC mkdir_p assertions did not run\n");
            exit(1);
        }
    }

    /* nofollow range read checks the opened object: a junction (a reparse
     * point, creatable without admin rights) is refused even for 0 bytes. */
    {
        char jp[800], jt[800];
        snprintf(jp, sizeof(jp), "%s/junc", dir);
        snprintf(jt, sizeof(jt), "%s/子目录", dir);
        wchar_t wj[1024], wt[1024], cmd[2200];
        assert(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, jp, -1, wj, 1024) > 0);
        assert(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, jt, -1, wt, 1024) > 0);
        for (wchar_t *q = wj; *q; q++) if (*q == L'/') *q = L'\\';
        for (wchar_t *q = wt; *q; q++) if (*q == L'/') *q = L'\\';
        swprintf(cmd, 2200, L"cmd /c mklink /J \"%ls\" \"%ls\" >NUL", wj, wt);
        assert(_wsystem(cmd) == 0);
        DWORD ja = GetFileAttributesW(wj);
        assert(ja != INVALID_FILE_ATTRIBUTES && (ja & FILE_ATTRIBUTE_REPARSE_POINT));
        void *j_s = pion_str_from_cstr(jp, -1);
        void *jr = pion_world_fs_read_range_nofollow(w, j_s, 0, 0, 0, &ok);
        assert(ok == 0);
        pion_rc_dec(jr);
        pion_rc_dec(j_s);
        assert(RemoveDirectoryW(wj));
    }
#endif

    /* A 0-byte regular file reads back as 0 bytes. */
    {
        void *z_s = u8s(dir, "/零.bin");
        void *zb = pion_bytes_new(0);
        assert(pion_world_fs_write_bytes(w, z_s, zb) == 1);
        void *zr = pion_world_fs_read_range_nofollow(w, z_s, 0, 0, 0, &ok);
        assert(ok == 1 && pion_bytes_len(zr) == 0);
        pion_rc_dec(zr);
        zr = pion_world_fs_read_range_nofollow(w, z_s, 0, 0, 1, &ok);
        assert(ok == 0);
        pion_rc_dec(zr);
        assert(pion_world_fs_remove(w, z_s) == 1);
        pion_rc_dec(zb);
        pion_rc_dec(z_s);
    }

    /* Atomic write never truncates or removes a file that already holds a
     * candidate temporary name (`<path>.piontmp.<pid>.<seq>`): sentinels
     * cover seq 0..63, so the first calls collide until a free name. */
    {
        char tgt[800], sen[900];
        snprintf(tgt, sizeof(tgt), "%s/atomic \xF0\x9F\x9A\x80.bin", dir);
        void *tgt_s = pion_str_from_cstr(tgt, -1);
        void *sent = pion_str_from_cstr("SENTINEL", 8);
        for (int i = 0; i < 64; i++) {
            snprintf(sen, sizeof(sen), "%s.piontmp.%d.%d", tgt, pion_test_getpid(), i);
            void *ss = pion_str_from_cstr(sen, -1);
            assert(pion_world_fs_write(w, ss, sent) == 1);
            pion_rc_dec(ss);
        }
        int wrote = 0;
        for (int tries = 0; tries < 80 && !wrote; tries++) {
            wrote = pion_fs_write_atomic_bytes(tgt_s, bytes);
        }
        assert(wrote == 1);
        void *tb = pion_world_fs_read_bytes(w, tgt_s, &ok);
        assert(ok == 1 && pion_bytes_len(tb) == 6 && pion_bytes_get(tb, 0) == 'a');
        pion_rc_dec(tb);
        for (int i = 0; i < 64; i++) {
            snprintf(sen, sizeof(sen), "%s.piontmp.%d.%d", tgt, pion_test_getpid(), i);
            void *ss = pion_str_from_cstr(sen, -1);
            void *sr = pion_world_fs_read(w, ss, &ok);
            assert(ok == 1 && pion_str_eq(sr, sent) == 1);
            pion_rc_dec(sr);
            assert(pion_world_fs_remove(w, ss) == 1);
            pion_rc_dec(ss);
        }
        ents = pion_world_fs_list_dir(w, dir_s);
        for (int64_t i = 0; i < pion_arr_len(ents); i++) {
            const char *en = ((PionString *)(uintptr_t)pion_arr_get(ents, i))->data;
            assert(strstr(en, ".piontmp.") == NULL);
        }
        pion_rc_dec(ents);
        assert(pion_world_fs_remove(w, tgt_s) == 1);
        pion_rc_dec(sent);
        pion_rc_dec(tgt_s);
    }

    /* A path longer than the stack conversion buffer (heap fallback), while
     * staying under macOS PATH_MAX (1024 bytes): 6 components of 88 ASCII +
     * 1 CJK char -> > 512 UTF-16 units (~540 + dir) and ~600-660 UTF-8 bytes. */
    char deep[1400];
    int dl = snprintf(deep, sizeof(deep), "%s", dir);
    for (int i = 0; i < 6; i++) {
        deep[dl++] = '/';
        memset(deep + dl, 'a', 88);
        dl += 88;
        memcpy(deep + dl, "\xE9\x95\xBF", 3);
        dl += 3;
    }
    deep[dl] = '\0';
    void *deep_s = pion_str_from_cstr(deep, dl);
    int deep_ok = pion_world_fs_mkdir_p(w, deep_s);
#ifndef _WIN32
    assert(deep_ok == 1);
#endif
    assert(pion_world_fs_is_dir(w, deep_s) == deep_ok);
    /* Windows without long-path support may stop part way: remove what exists. */
    while (dl > (int)strlen(dir)) {
        int rc = pion_test_rmdir_u8(deep);
#ifndef _WIN32
        assert(rc == 0);
#else
        (void)rc;
#endif
        while (deep[--dl] != '/') {}
        deep[dl] = '\0';
    }
    pion_rc_dec(deep_s);

    /* Cleanup. */
    assert(pion_world_fs_remove(w, moved_s) == 1);
    assert(pion_world_fs_exists(w, moved_s) == 0);
    assert(pion_world_fs_remove(w, real_s) == 1);
    assert(pion_world_fs_remove(w, lock_s) == 1);
    for (int i = 0; i < 3; i++) {
        char nb[16];
        snprintf(nb, sizeof(nb), "/%s", names[i]);
        void *ps = u8s(dir, nb);
        assert(pion_world_fs_remove(w, ps) == 1);
        pion_rc_dec(ps);
    }
    assert(pion_test_rmdir_u8(excl) == 0);
    char subp[800];
    snprintf(subp, sizeof(subp), "%s/子目录", dir);
    assert(pion_test_rmdir_u8(subp) == 0);
    assert(pion_test_rmdir_u8(dir) == 0);
    assert(pion_test_rmdir_u8(root) == 0);

    void *objs[] = {dir_s, sub_s, file_s, body, bytes, excl_s, lock_s, moved_s, real_s,
                    ghost_s, real_nul, ghost_nul, dir_nul};
    for (size_t i = 0; i < sizeof(objs) / sizeof(objs[0]); i++) pion_rc_dec(objs[i]);
    pion_rc_dec(w);
    printf("[PASS] utf8_paths_and_embedded_nul\n");
}

int main(int argc, char **argv) {
    int run_bench = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--bench") == 0) {
            run_bench = 1;
        } else if (strcmp(argv[i], "--spawn-stack") == 0) {
            /* Run under a small RLIMIT_STACK (`ulimit -s 1024`): spawn
             * workers must still get their explicit 8 MiB stacks. */
            test_mt_spawn_stack_8mib();
            return 0;
        }
    }

    test_biased_rc_and_immortal();
    test_alloc_uninit();
    test_string_and_strbuf();
    test_short_str_and_hash_edges();
    test_stdlib_string_bytes_math();
    test_array_and_map();
    test_arr_ergonomics_and_double_to_str();
    test_slab_48b_and_arr_growth();
    test_map_try_get_and_100k();
    test_sha256();
    test_world(argc, argv);
    test_p22a_systems_io(argc, argv);
    test_utf8_paths_and_embedded_nul(argc, argv);
    test_fs_lstat_kind();
    test_ffi_ptr_and_cstr();
    test_str_to_double();
    test_p57b_hot_str_and_split();
    test_p61b_map_hint_hit_miss_aba();
    test_p71c_hashdos_bit63_noncollision();

    test_st_frozen_slab_recycle();
    test_mt_shared_rc();
    test_mt_channel_10k();
    test_mt_mutex_and_atomic();
    test_mt_mutex_deep_containers();
    test_mt_nested_scope();
    test_mt_spawn_stack_8mib();
    test_fs_lock_blocking();
    test_mt_slab_stress();
    test_med_cache_and_mt_frozen();
    test_mt_world_exec(argc, argv);
    test_tcp_loopback_mt(argc, argv);
    test_event_loop_nb(argc, argv);

    if (run_bench) {
        run_slab_bench();
        run_multicore_bench();
    }

    printf("ALL RUNTIME TESTS PASSED\n");
    return 0;
}
