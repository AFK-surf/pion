#define _POSIX_C_SOURCE 200809L

#include "m2_rt.h"

#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

/* ============================================================================
 * 1. Memory & Biased RC
 * ============================================================================ */

static _Atomic uint64_t g_next_tid = 1;
static _Thread_local uint64_t tls_tid = 0;

static uint64_t m2_cur_tid_slow(void) {
    uint64_t t = atomic_fetch_add_explicit(&g_next_tid, 1, memory_order_relaxed);
    tls_tid = t;
    return t;
}

static inline uint64_t m2_cur_tid_fast(void) {
    uint64_t t = tls_tid;
    if (__builtin_expect(t == 0, 0)) {
        return m2_cur_tid_slow();
    }
    return t;
}

uint64_t m2_cur_tid(void) {
    return m2_cur_tid_fast();
}

static inline M2Header *m2_hdr(void *obj) {
    return ((M2Header *)obj) - 1;
}

void m2_panic(const char *msg, const char *file, int32_t line) {
    fprintf(stderr, "m2 panic at %s:%d: %s\n",
            file ? file : "<unknown>", (int)line, msg ? msg : "");
    fflush(stderr);
    abort();
}

void m2_panic_oob(int64_t idx, int64_t len) {
    fprintf(stderr, "m2 panic: index %" PRId64 " out of bounds (len %" PRId64 ")\n", idx, len);
    fflush(stderr);
    abort();
}

void m2_debug_assert(int32_t cond, void *msg_str, const char *file, int32_t line) {
    if (__builtin_expect(!cond, 0)) {
        const char *msg = msg_str ? ((M2String *)msg_str)->data : "assertion failed";
        m2_panic(msg, file, line);
    }
}

double m2_math_sqrt(double x) {
    return sqrt(x);
}

#if defined(__SANITIZE_ADDRESS__)
#define M2_USE_SLAB 0
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define M2_USE_SLAB 0
#else
#define M2_USE_SLAB 1
#endif
#else
#define M2_USE_SLAB 1
#endif

#if M2_USE_SLAB

#define M2_SLAB_CLASSES     7u
#define M2_SLAB_MAX_TOTAL   256u
#define M2_SLAB_MAX_PAYLOAD (M2_SLAB_MAX_TOTAL - (uint32_t)sizeof(M2Header))
#define M2_SLAB_CHUNK_BYTES 65536u

typedef struct M2SlabTLS {
    void *local_free[M2_SLAB_CLASSES];
    char *chunk_cur;
    char *chunk_end;
} M2SlabTLS;

static const uint16_t m2_slab_sizes[M2_SLAB_CLASSES] = {
    32u, 48u, 64u, 96u, 128u, 192u, 256u
};

/* Maps ((total + 15) >> 4) in [2..16] to slab class [0..6] */
static const uint8_t m2_slab_cls_lut[17] = {
    0, 0, 0, 1, 2, 3, 3, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6
};

static _Thread_local M2SlabTLS *tls_slab = NULL;
static _Atomic(void *) g_slab_remote[M2_SLAB_CLASSES];
static pthread_once_t g_slab_key_once = PTHREAD_ONCE_INIT;
static pthread_key_t g_slab_key;

/* Strict-aliasing-safe intrusive freelist link (lives at offset 0 of free slot) */
static inline void *m2_slab_get_next(void *slot) {
    void *next;
    memcpy(&next, slot, sizeof(next));
    return next;
}

static inline void m2_slab_set_next(void *slot, void *next) {
    memcpy(slot, &next, sizeof(next));
}

static void m2_slab_push_remote_list(uint32_t cls, void *head, void *tail) {
    void *cur = atomic_load_explicit(&g_slab_remote[cls], memory_order_relaxed);
    do {
        m2_slab_set_next(tail, cur);
    } while (!atomic_compare_exchange_weak_explicit(
        &g_slab_remote[cls], &cur, head,
        memory_order_release, memory_order_relaxed));
}

static void m2_slab_thread_cleanup(void *arg) {
    tls_slab = NULL;
    M2SlabTLS *s = (M2SlabTLS *)arg;
    if (!s) return;
    for (uint32_t cls = 0; cls < M2_SLAB_CLASSES; cls++) {
        void *head = s->local_free[cls];
        if (!head) continue;
        s->local_free[cls] = NULL;
        void *tail = head;
        void *nxt;
        while ((nxt = m2_slab_get_next(tail)) != NULL) {
            tail = nxt;
        }
        m2_slab_push_remote_list(cls, head, tail);
    }
    free(s);
}

static void m2_slab_key_init(void) {
    (void)pthread_key_create(&g_slab_key, m2_slab_thread_cleanup);
}

static M2Header *m2_slab_alloc_slow(M2SlabTLS *s, uint32_t cls) {
    if (__builtin_expect(!s, 0)) {
        s = (M2SlabTLS *)calloc(1, sizeof(M2SlabTLS));
        if (__builtin_expect(!s, 0)) {
            m2_panic("out of memory", __FILE__, __LINE__);
        }
        pthread_once(&g_slab_key_once, m2_slab_key_init);
        (void)pthread_setspecific(g_slab_key, s);
        tls_slab = s;
    }
    void *remote = atomic_exchange_explicit(&g_slab_remote[cls], NULL, memory_order_acquire);
    if (remote) {
        s->local_free[cls] = m2_slab_get_next(remote);
        return (M2Header *)remote;
    }
    uint32_t slot_sz = m2_slab_sizes[cls];
    if (__builtin_expect(!s->chunk_cur || (size_t)(s->chunk_end - s->chunk_cur) < slot_sz, 0)) {
        char *chunk = (char *)malloc(M2_SLAB_CHUNK_BYTES);
        if (__builtin_expect(!chunk, 0)) {
            m2_panic("out of memory", __FILE__, __LINE__);
        }
        s->chunk_cur = chunk;
        s->chunk_end = chunk + M2_SLAB_CHUNK_BYTES;
    }
    M2Header *hdr = (M2Header *)s->chunk_cur;
    s->chunk_cur += slot_sz;
    return hdr;
}

#endif /* M2_USE_SLAB */

static inline void *m2_alloc_raw(uint32_t payload_size, uint16_t type_tag, M2DropFn drop_fn) {
    M2Header *hdr;
    uint16_t flags = 0;
#if M2_USE_SLAB
    if (__builtin_expect(payload_size <= M2_SLAB_MAX_PAYLOAD, 1)) {
        uint32_t total = (uint32_t)sizeof(M2Header) + payload_size;
        uint32_t cls = m2_slab_cls_lut[(total + 15u) >> 4];
        M2SlabTLS *s = tls_slab;
        if (__builtin_expect(s != NULL, 1)) {
            void *node = s->local_free[cls];
            if (__builtin_expect(node != NULL, 1)) {
                s->local_free[cls] = m2_slab_get_next(node);
                hdr = (M2Header *)node;
            } else {
                hdr = m2_slab_alloc_slow(s, cls);
            }
        } else {
            hdr = m2_slab_alloc_slow(NULL, cls);
        }
        flags = (uint16_t)(M2_FLAG_SLAB | (cls << M2_FLAG_SLAB_CLS_SHIFT));
    } else
#endif
    {
        size_t total = sizeof(M2Header) + (size_t)payload_size;
        hdr = (M2Header *)malloc(total);
        if (__builtin_expect(!hdr, 0)) {
            m2_panic("out of memory", __FILE__, __LINE__);
        }
    }
    hdr->owner_tid = m2_cur_tid_fast();
    hdr->local_rc = 1;
    atomic_init(&hdr->shared_rc, 0);
    hdr->type_tag = type_tag;
    hdr->flags = flags;
    hdr->payload_size = payload_size;
    hdr->drop_fn = drop_fn;
    return (void *)(hdr + 1);
}

void *m2_alloc(uint32_t payload_size, uint16_t type_tag, M2DropFn drop_fn) {
    void *payload = m2_alloc_raw(payload_size, type_tag, drop_fn);
    if (payload_size > 0) {
        memset(payload, 0, payload_size);
    }
    return payload;
}

void *m2_alloc_uninit(uint32_t payload_size, uint16_t type_tag, M2DropFn drop_fn) {
    return m2_alloc_raw(payload_size, type_tag, drop_fn);
}

static void m2_destroy(M2Header *hdr, void *obj) {
    if (hdr->drop_fn) {
        hdr->drop_fn(obj);
    }
#if M2_USE_SLAB
    uint16_t flags = hdr->flags;
    if (__builtin_expect((flags & M2_FLAG_SLAB) != 0, 1)) {
        uint32_t cls = (uint32_t)((flags >> M2_FLAG_SLAB_CLS_SHIFT) & M2_FLAG_SLAB_CLS_MASK);
        if (__builtin_expect((flags & M2_FLAG_FROZEN) == 0, 1)) {
            M2SlabTLS *s = tls_slab;
            if (__builtin_expect(s != NULL, 1)) {
                m2_slab_set_next(hdr, s->local_free[cls]);
                s->local_free[cls] = hdr;
                return;
            }
        }
        m2_slab_push_remote_list(cls, hdr, hdr);
        return;
    }
#endif
    free(hdr);
}

void m2_rc_inc(void *obj) {
    if (!obj) return;
    M2Header *hdr = m2_hdr(obj);
    if (hdr->flags & M2_FLAG_IMMORTAL) return;
    if (__builtin_expect(hdr->owner_tid == m2_cur_tid_fast(), 1)) {
        hdr->local_rc++;
    } else {
        atomic_fetch_add_explicit(&hdr->shared_rc, 1, memory_order_relaxed);
    }
}

void m2_rc_dec(void *obj) {
    if (!obj) return;
    M2Header *hdr = m2_hdr(obj);
    if (hdr->flags & M2_FLAG_IMMORTAL) return;
    if (__builtin_expect(hdr->owner_tid == m2_cur_tid_fast(), 1)) {
        if (--hdr->local_rc == 0) {
            if (atomic_load_explicit(&hdr->shared_rc, memory_order_acquire) == 0) {
                m2_destroy(hdr, obj);
            }
        }
    } else {
        if (atomic_fetch_sub_explicit(&hdr->shared_rc, 1, memory_order_acq_rel) == 1) {
            m2_destroy(hdr, obj);
        }
    }
}

void m2_rc_freeze(void *obj) {
    if (!obj) return;
    M2Header *hdr = m2_hdr(obj);
    if ((hdr->flags & M2_FLAG_IMMORTAL) || hdr->owner_tid == 0) return;
    if (hdr->owner_tid != m2_cur_tid_fast()) {
        m2_panic("m2_rc_freeze called from non-owning thread", __FILE__, __LINE__);
    }
    uint32_t rc = hdr->local_rc;
    hdr->local_rc = 0;
    atomic_fetch_add_explicit(&hdr->shared_rc, rc, memory_order_relaxed);
    hdr->flags |= M2_FLAG_FROZEN;
    hdr->owner_tid = 0;
}

/* ============================================================================
 * 2. String
 * ============================================================================ */

static const char m2_digits200[201] =
    "0001020304050607080910111213141516171819"
    "2021222324252627282930313233343536373839"
    "4041424344454647484950515253545556575859"
    "6061626364656667686970717273747576777879"
    "8081828384858687888990919293949596979899";

static inline char *m2_fmt_i64_end(int64_t v, char *end) {
    char *p = end;
    int neg = v < 0;
    uint64_t u = neg ? ((uint64_t)(-(v + 1)) + 1ULL) : (uint64_t)v;
    while (u >= 100ULL) {
        uint64_t q = u / 100ULL;
        uint32_t r = (uint32_t)(u - q * 100ULL) * 2u;
        u = q;
        p -= 2;
        p[0] = m2_digits200[r];
        p[1] = m2_digits200[r + 1];
    }
    if (u >= 10ULL) {
        uint32_t r = (uint32_t)u * 2u;
        p -= 2;
        p[0] = m2_digits200[r];
        p[1] = m2_digits200[r + 1];
    } else {
        *--p = (char)('0' + u);
    }
    if (neg) {
        *--p = '-';
    }
    return p;
}

void *m2_str_from_cstr(const char *s, int64_t len) {
    if (!s) {
        len = 0;
    } else if (len < 0) {
        len = (int64_t)strlen(s);
    }
    uint32_t payload_size = (uint32_t)(sizeof(M2String) + (size_t)len + 1);
    M2String *str = (M2String *)m2_alloc_raw(payload_size, M2_TAG_STRING, NULL);
    str->len = len;
    if (len > 0 && s) {
        memcpy(str->data, s, (size_t)len);
    }
    str->data[len] = '\0';
    return str;
}

int64_t m2_str_len(void *s) {
    if (!s) return 0;
    return ((M2String *)s)->len;
}

int32_t m2_str_byte_at(void *s, int64_t idx) {
    M2String *str = (M2String *)s;
    if (!str || idx < 0 || idx >= str->len) {
        m2_panic("string index out of bounds", __FILE__, __LINE__);
    }
    return (int32_t)(unsigned char)str->data[idx];
}

void *m2_str_concat(void *a, void *b) {
    M2String *sa = (M2String *)a;
    M2String *sb = (M2String *)b;
    int64_t la = sa ? sa->len : 0;
    int64_t lb = sb ? sb->len : 0;
    int64_t total = la + lb;
    M2String *out = (M2String *)m2_alloc_raw((uint32_t)(sizeof(M2String) + (size_t)total + 1),
                                             M2_TAG_STRING, NULL);
    out->len = total;
    if (la > 0) memcpy(out->data, sa->data, (size_t)la);
    if (lb > 0) memcpy(out->data + la, sb->data, (size_t)lb);
    out->data[total] = '\0';
    return out;
}

static inline int32_t m2_str_eq_fast(const M2String *sa, const M2String *sb) {
    if (sa == sb) return 1;
    if (!sa || !sb) return 0;
    int64_t len = sa->len;
    if (len != sb->len) return 0;
    if (len == 0) return 1;
    return memcmp(sa->data, sb->data, (size_t)len) == 0 ? 1 : 0;
}

int32_t m2_str_eq(void *a, void *b) {
    return m2_str_eq_fast((const M2String *)a, (const M2String *)b);
}

int32_t m2_str_cmp(void *a, void *b) {
    if (a == b) return 0;
    M2String *sa = (M2String *)a;
    M2String *sb = (M2String *)b;
    int64_t la = sa ? sa->len : 0;
    int64_t lb = sb ? sb->len : 0;
    int64_t min_len = la < lb ? la : lb;
    if (min_len > 0) {
        int r = memcmp(sa->data, sb->data, (size_t)min_len);
        if (r != 0) return r < 0 ? -1 : 1;
    }
    if (la < lb) return -1;
    if (la > lb) return 1;
    return 0;
}

void *m2_str_slice(void *s, int64_t start, int64_t end) {
    M2String *str = (M2String *)s;
    if (!str || start < 0 || end < start || end > str->len) {
        m2_panic("string slice out of bounds", __FILE__, __LINE__);
    }
    return m2_str_from_cstr(str->data + start, end - start);
}

void *m2_int_to_str(int64_t v) {
    char tmp[24];
    char *end = tmp + sizeof(tmp);
    char *p = m2_fmt_i64_end(v, end);
    size_t n = (size_t)(end - p);
    M2String *str = (M2String *)m2_alloc_raw((uint32_t)(sizeof(M2String) + n + 1),
                                             M2_TAG_STRING, NULL);
    str->len = (int64_t)n;
    memcpy(str->data, p, n);
    str->data[n] = '\0';
    return str;
}

int64_t m2_str_to_int(void *s, int32_t *ok_out) {
    M2String *str = (M2String *)s;
    if (!str || str->len <= 0) {
        if (ok_out) *ok_out = 0;
        return 0;
    }
    const char *p = str->data;
    if (p[0] == ' ' || p[0] == '\t' || p[0] == '\n' || p[0] == '\r') {
        if (ok_out) *ok_out = 0;
        return 0;
    }
    errno = 0;
    char *end = NULL;
    long long v = strtoll(p, &end, 10);
    if (errno == ERANGE || end != p + str->len) {
        if (ok_out) *ok_out = 0;
        return 0;
    }
    if (ok_out) *ok_out = 1;
    return (int64_t)v;
}

/* ============================================================================
 * 3. StringBuilder
 * ============================================================================ */

static void m2_strbuf_drop(void *payload) {
    M2StrBuf *sb = (M2StrBuf *)payload;
    free(sb->data);
    sb->data = NULL;
}

static void m2_strbuf_reserve(M2StrBuf *sb, int64_t add) {
    int64_t need = sb->len + add + 1;
    if (need <= sb->cap) return;
    int64_t ncap = sb->cap > 0 ? sb->cap * 2 : 32;
    while (ncap < need) ncap *= 2;
    char *nd = (char *)realloc(sb->data, (size_t)ncap);
    if (!nd) m2_panic("out of memory in strbuf", __FILE__, __LINE__);
    sb->data = nd;
    sb->cap = ncap;
}

void *m2_strbuf_new(int64_t cap) {
    M2StrBuf *sb = (M2StrBuf *)m2_alloc((uint32_t)sizeof(M2StrBuf), M2_TAG_STRBUF, m2_strbuf_drop);
    int64_t init_cap = cap > 16 ? cap : 16;
    sb->data = (char *)malloc((size_t)init_cap);
    if (!sb->data) m2_panic("out of memory in strbuf_new", __FILE__, __LINE__);
    sb->data[0] = '\0';
    sb->len = 0;
    sb->cap = init_cap;
    return sb;
}

void m2_strbuf_push_str(void *sb_ptr, void *s_ptr) {
    M2StrBuf *sb = (M2StrBuf *)sb_ptr;
    M2String *s = (M2String *)s_ptr;
    if (!sb || !s || s->len == 0) return;
    m2_strbuf_reserve(sb, s->len);
    memcpy(sb->data + sb->len, s->data, (size_t)s->len);
    sb->len += s->len;
    sb->data[sb->len] = '\0';
}

void m2_strbuf_push_byte(void *sb_ptr, int32_t b) {
    M2StrBuf *sb = (M2StrBuf *)sb_ptr;
    if (!sb) return;
    m2_strbuf_reserve(sb, 1);
    sb->data[sb->len++] = (char)(b & 0xFF);
    sb->data[sb->len] = '\0';
}

void m2_strbuf_push_char(void *sb_ptr, int32_t cp) {
    M2StrBuf *sb = (M2StrBuf *)sb_ptr;
    if (!sb || cp < 0 || cp > 0x10FFFF) return;
    char buf[4];
    int n = 0;
    if (cp < 0x80) {
        buf[n++] = (char)cp;
    } else if (cp < 0x800) {
        buf[n++] = (char)(0xC0 | (cp >> 6));
        buf[n++] = (char)(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        buf[n++] = (char)(0xE0 | (cp >> 12));
        buf[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
        buf[n++] = (char)(0x80 | (cp & 0x3F));
    } else {
        buf[n++] = (char)(0xF0 | (cp >> 18));
        buf[n++] = (char)(0x80 | ((cp >> 12) & 0x3F));
        buf[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
        buf[n++] = (char)(0x80 | (cp & 0x3F));
    }
    m2_strbuf_reserve(sb, n);
    memcpy(sb->data + sb->len, buf, (size_t)n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

void m2_strbuf_push_int(void *sb_ptr, int64_t v) {
    M2StrBuf *sb = (M2StrBuf *)sb_ptr;
    if (!sb) return;
    char tmp[24];
    char *end = tmp + sizeof(tmp);
    char *p = m2_fmt_i64_end(v, end);
    size_t n = (size_t)(end - p);
    m2_strbuf_reserve(sb, (int64_t)n);
    memcpy(sb->data + sb->len, p, n);
    sb->len += (int64_t)n;
    sb->data[sb->len] = '\0';
}

void m2_strbuf_reset(void *sb_ptr) {
    M2StrBuf *sb = (M2StrBuf *)sb_ptr;
    if (!sb) return;
    sb->len = 0;
    if (sb->data) sb->data[0] = '\0';
}

void *m2_strbuf_to_str(void *sb_ptr) {
    M2StrBuf *sb = (M2StrBuf *)sb_ptr;
    if (!sb) return m2_str_from_cstr("", 0);
    return m2_str_from_cstr(sb->data, sb->len);
}

/* ============================================================================
 * 4. Array
 * ============================================================================ */

static void m2_arr_drop(void *payload) {
    M2Array *a = (M2Array *)payload;
    if (a->elem_is_obj) {
        for (int64_t i = 0; i < a->len; i++) {
            m2_rc_dec((void *)(uintptr_t)a->data[i]);
        }
    }
    free(a->data);
    a->data = NULL;
}

void *m2_arr_new(int64_t cap, int32_t elem_is_obj) {
    M2Array *a = (M2Array *)m2_alloc((uint32_t)sizeof(M2Array), M2_TAG_ARRAY, m2_arr_drop);
    a->len = 0;
    a->elem_is_obj = elem_is_obj ? 1 : 0;
    if (cap > 0) {
        a->data = (int64_t *)malloc((size_t)cap * sizeof(int64_t));
        if (!a->data) m2_panic("out of memory in arr_new", __FILE__, __LINE__);
        a->cap = cap;
    } else {
        a->data = NULL;
        a->cap = 0;
    }
    return a;
}

int64_t m2_arr_len(void *a_ptr) {
    if (!a_ptr) return 0;
    return ((M2Array *)a_ptr)->len;
}

void m2_arr_push(void *a_ptr, int64_t val) {
    M2Array *a = (M2Array *)a_ptr;
    if (a->len == a->cap) {
        int64_t ncap = a->cap > 0 ? a->cap * 2 : 8;
        int64_t *nd = (int64_t *)realloc(a->data, (size_t)ncap * sizeof(int64_t));
        if (!nd) m2_panic("out of memory in arr_push", __FILE__, __LINE__);
        a->data = nd;
        a->cap = ncap;
    }
    if (a->elem_is_obj) {
        m2_rc_inc((void *)(uintptr_t)val);
    }
    a->data[a->len++] = val;
}

int64_t m2_arr_get(void *a_ptr, int64_t idx) {
    M2Array *a = (M2Array *)a_ptr;
    if (!a || idx < 0 || idx >= a->len) {
        m2_panic("array index out of bounds", __FILE__, __LINE__);
    }
    return a->data[idx];
}

void m2_arr_set(void *a_ptr, int64_t idx, int64_t val) {
    M2Array *a = (M2Array *)a_ptr;
    if (!a || idx < 0 || idx >= a->len) {
        m2_panic("array set index out of bounds", __FILE__, __LINE__);
    }
    if (a->elem_is_obj) {
        m2_rc_inc((void *)(uintptr_t)val);
        m2_rc_dec((void *)(uintptr_t)a->data[idx]);
    }
    a->data[idx] = val;
}

int64_t m2_arr_pop(void *a_ptr) {
    M2Array *a = (M2Array *)a_ptr;
    if (!a || a->len <= 0) {
        m2_panic("array pop on empty array", __FILE__, __LINE__);
    }
    /* Transfers slot ownership to caller (no RC dec) */
    return a->data[--a->len];
}

void *m2_arr_copy(void *a_ptr) {
    M2Array *a = (M2Array *)a_ptr;
    if (!a) return m2_arr_new(0, 0);
    M2Array *cp = (M2Array *)m2_arr_new(a->len, a->elem_is_obj);
    if (a->len > 0) {
        memcpy(cp->data, a->data, (size_t)a->len * sizeof(int64_t));
        cp->len = a->len;
        if (a->elem_is_obj) {
            for (int64_t i = 0; i < a->len; i++) {
                m2_rc_inc((void *)(uintptr_t)cp->data[i]);
            }
        }
    }
    return cp;
}

/* ============================================================================
 * 5. String-Keyed Hash Map (Open Addressing, 64-bit Block Hash)
 * ============================================================================ */

static inline uint64_t m2_str_hash(const M2String *s) {
    const unsigned char *p = (const unsigned char *)s->data;
    size_t len = (size_t)s->len;
    uint64_t h = 0x517cc1b727220a95ULL ^ ((uint64_t)len * 0x9e3779b97f4a7c15ULL);
    while (len >= 8) {
        uint64_t w;
        memcpy(&w, p, 8);
        h ^= w;
        h *= 0x9e3779b97f4a7c15ULL;
        h ^= h >> 32;
        p += 8;
        len -= 8;
    }
    uint64_t tail = 0;
    if (len >= 4) {
        uint32_t w4;
        memcpy(&w4, p, 4);
        tail = (uint64_t)w4;
        p += 4;
        len -= 4;
        if (len >= 2) {
            uint16_t w2;
            memcpy(&w2, p, 2);
            tail |= ((uint64_t)w2) << 32;
            p += 2;
            len -= 2;
        }
        if (len == 1) {
            tail |= ((uint64_t)p[0]) << 48;
        }
    } else {
        if (len >= 2) {
            uint16_t w2;
            memcpy(&w2, p, 2);
            tail = (uint64_t)w2;
            p += 2;
            len -= 2;
        }
        if (len == 1) {
            tail |= ((uint64_t)p[0]) << 16;
        }
    }
    h ^= tail;
    h *= 0xbf58476d1ce4e5b9ULL;
    h ^= h >> 27;
    h *= 0x94d049bb133111ebULL;
    h ^= h >> 31;
    return h;
}

/* Shared inline linear-probe hot path: returns matching occupied slot or first empty slot.
 * Caller must ensure m->cap > 0, m->entries != NULL, and k != NULL. */
static inline M2MapEntry *m2_map_probe(const M2Map *m, const M2String *k, uint64_t h) {
    uint64_t mask = (uint64_t)(m->cap - 1);
    uint64_t idx = h & mask;
    M2MapEntry *entries = m->entries;
    for (;;) {
        M2MapEntry *e = &entries[idx];
        if (e->state == 0) {
            return e;
        }
        if (e->hash == h && m2_str_eq_fast(e->key, k)) {
            return e;
        }
        idx = (idx + 1) & mask;
    }
}

static void m2_map_drop(void *payload) {
    M2Map *m = (M2Map *)payload;
    if (m->entries) {
        for (int64_t i = 0; i < m->cap; i++) {
            if (m->entries[i].state == 1) {
                m2_rc_dec(m->entries[i].key);
                if (m->val_is_obj) {
                    m2_rc_dec((void *)(uintptr_t)m->entries[i].val);
                }
            }
        }
        free(m->entries);
        m->entries = NULL;
    }
}

static void m2_map_grow(M2Map *m, int64_t new_cap) {
    M2MapEntry *ne = (M2MapEntry *)calloc((size_t)new_cap, sizeof(M2MapEntry));
    if (!ne) m2_panic("out of memory in map_grow", __FILE__, __LINE__);
    uint64_t mask = (uint64_t)(new_cap - 1);
    for (int64_t i = 0; i < m->cap; i++) {
        if (m->entries[i].state == 1) {
            uint64_t idx = m->entries[i].hash & mask;
            while (ne[idx].state == 1) {
                idx = (idx + 1) & mask;
            }
            ne[idx] = m->entries[i];
        }
    }
    free(m->entries);
    m->entries = ne;
    m->cap = new_cap;
}

void *m2_map_new(int32_t val_is_obj) {
    M2Map *m = (M2Map *)m2_alloc((uint32_t)sizeof(M2Map), M2_TAG_MAP, m2_map_drop);
    m->val_is_obj = val_is_obj ? 1 : 0;
    m->len = 0;
    m->cap = 0;
    m->entries = NULL;
    return m;
}

int64_t m2_map_len(void *m_ptr) {
    if (!m_ptr) return 0;
    return ((M2Map *)m_ptr)->len;
}

void m2_map_set(void *m_ptr, void *key_str, int64_t val) {
    M2Map *m = (M2Map *)m_ptr;
    M2String *k = (M2String *)key_str;
    if (__builtin_expect(!m || !k, 0)) m2_panic("null map or key", __FILE__, __LINE__);
    if (__builtin_expect(m->cap == 0, 0)) {
        m2_map_grow(m, 16);
    } else if (__builtin_expect((m->len + 1) * 10 >= m->cap * 7, 0)) {
        m2_map_grow(m, m->cap * 2);
    }
    uint64_t h = m2_str_hash(k);
    M2MapEntry *e = m2_map_probe(m, k, h);
    if (e->state == 1) {
        if (m->val_is_obj) {
            m2_rc_inc((void *)(uintptr_t)val);
            m2_rc_dec((void *)(uintptr_t)e->val);
        }
        e->val = val;
        return;
    }
    m2_rc_inc(k);
    if (m->val_is_obj) {
        m2_rc_inc((void *)(uintptr_t)val);
    }
    e->key = k;
    e->hash = h;
    e->val = val;
    e->state = 1;
    m->len++;
}

int32_t m2_map_try_get(void *m_ptr, void *key_str, int64_t *out_val) {
    M2Map *m = (M2Map *)m_ptr;
    M2String *k = (M2String *)key_str;
    if (__builtin_expect(!m || !k || m->len == 0, 0)) return 0;
    uint64_t h = m2_str_hash(k);
    M2MapEntry *e = m2_map_probe(m, k, h);
    if (e->state == 1) {
        if (out_val) *out_val = e->val;
        return 1;
    }
    return 0;
}

int32_t m2_map_has(void *m_ptr, void *key_str) {
    M2Map *m = (M2Map *)m_ptr;
    M2String *k = (M2String *)key_str;
    if (__builtin_expect(!m || !k || m->len == 0, 0)) return 0;
    uint64_t h = m2_str_hash(k);
    M2MapEntry *e = m2_map_probe(m, k, h);
    return e->state == 1 ? 1 : 0;
}

int64_t m2_map_get(void *m_ptr, void *key_str) {
    M2Map *m = (M2Map *)m_ptr;
    M2String *k = (M2String *)key_str;
    if (__builtin_expect(!m || !k || m->len == 0, 0)) {
        m2_panic("map key not found", __FILE__, __LINE__);
    }
    uint64_t h = m2_str_hash(k);
    M2MapEntry *e = m2_map_probe(m, k, h);
    if (__builtin_expect(e->state == 1, 1)) {
        return e->val;
    }
    m2_panic("map key not found", __FILE__, __LINE__);
}

void m2_map_remove(void *m_ptr, void *key_str) {
    M2Map *m = (M2Map *)m_ptr;
    M2String *k = (M2String *)key_str;
    if (!m || !k || m->len == 0 || m->cap == 0) return;
    uint64_t h = m2_str_hash(k);
    M2MapEntry *e = m2_map_probe(m, k, h);
    if (e->state == 0) return;
    uint64_t mask = (uint64_t)(m->cap - 1);
    uint64_t idx = (uint64_t)(e - m->entries);
    m2_rc_dec(e->key);
    if (m->val_is_obj) {
        m2_rc_dec((void *)(uintptr_t)e->val);
    }
    m->len--;
    /* Backward-shift deletion to keep probe chains intact without tombstones */
    uint64_t hole = idx;
    uint64_t cur = (idx + 1) & mask;
    while (m->entries[cur].state == 1) {
        uint64_t home = m->entries[cur].hash & mask;
        if (((hole - home) & mask) < ((cur - home) & mask)) {
            m->entries[hole] = m->entries[cur];
            hole = cur;
        }
        cur = (cur + 1) & mask;
    }
    m->entries[hole].state = 0;
    m->entries[hole].key = NULL;
    m->entries[hole].val = 0;
    m->entries[hole].hash = 0;
}

void *m2_map_copy(void *m_ptr) {
    M2Map *m = (M2Map *)m_ptr;
    if (!m) return m2_map_new(0);
    M2Map *cp = (M2Map *)m2_map_new(m->val_is_obj);
    if (m->cap > 0 && m->entries) {
        cp->entries = (M2MapEntry *)malloc((size_t)m->cap * sizeof(M2MapEntry));
        if (!cp->entries) m2_panic("out of memory in map_copy", __FILE__, __LINE__);
        memcpy(cp->entries, m->entries, (size_t)m->cap * sizeof(M2MapEntry));
        cp->cap = m->cap;
        cp->len = m->len;
        for (int64_t i = 0; i < cp->cap; i++) {
            if (cp->entries[i].state == 1) {
                m2_rc_inc(cp->entries[i].key);
                if (cp->val_is_obj) {
                    m2_rc_inc((void *)(uintptr_t)cp->entries[i].val);
                }
            }
        }
    }
    return cp;
}

void *m2_map_keys(void *m_ptr) {
    M2Map *m = (M2Map *)m_ptr;
    int64_t n = m ? m->len : 0;
    void *arr = m2_arr_new(n, 1);
    if (!m || !m->entries) return arr;
    for (int64_t i = 0; i < m->cap; i++) {
        if (m->entries[i].state == 1) {
            m2_arr_push(arr, (int64_t)(uintptr_t)m->entries[i].key);
        }
    }
    return arr;
}

/* ============================================================================
 * 6. Concurrency (pthread-backed Scope, Channel, Mutex, AtomicInt)
 * ============================================================================ */

typedef struct M2Scope {
    pthread_mutex_t mu;
    pthread_t *threads;
    size_t len;
    size_t cap;
} M2Scope;

typedef struct M2SpawnTask {
    void (*fn)(void *env);
    void *env;
} M2SpawnTask;

static void *m2_spawn_trampoline(void *arg) {
    M2SpawnTask *task = (M2SpawnTask *)arg;
    void (*fn)(void *) = task->fn;
    void *env = task->env;
    free(task);
    fn(env);
    if (env) {
        m2_rc_dec(env);
    }
    return NULL;
}

static void m2_scope_drop(void *payload) {
    M2Scope *s = (M2Scope *)payload;
    pthread_mutex_destroy(&s->mu);
    free(s->threads);
    s->threads = NULL;
}

void *m2_scope_begin(void) {
    M2Scope *s = (M2Scope *)m2_alloc((uint32_t)sizeof(M2Scope), M2_TAG_SCOPE, m2_scope_drop);
    pthread_mutex_init(&s->mu, NULL);
    s->threads = NULL;
    s->len = 0;
    s->cap = 0;
    m2_rc_freeze(s);
    return s;
}

void m2_scope_spawn(void *scope_ptr, void (*fn)(void *env), void *env) {
    M2Scope *s = (M2Scope *)scope_ptr;
    if (!s || !fn) m2_panic("invalid scope_spawn", __FILE__, __LINE__);
    if (env) {
        m2_rc_freeze(env);
        m2_rc_inc(env);
    }
    M2SpawnTask *task = (M2SpawnTask *)malloc(sizeof(M2SpawnTask));
    if (!task) {
        if (env) m2_rc_dec(env);
        m2_panic("out of memory in scope_spawn", __FILE__, __LINE__);
    }
    task->fn = fn;
    task->env = env;

    pthread_t th;
    int rc = pthread_create(&th, NULL, m2_spawn_trampoline, task);
    if (rc != 0) {
        free(task);
        if (env) m2_rc_dec(env);
        m2_panic("pthread_create failed", __FILE__, __LINE__);
    }

    pthread_mutex_lock(&s->mu);
    if (s->len == s->cap) {
        size_t ncap = s->cap > 0 ? s->cap * 2 : 8;
        pthread_t *nt = (pthread_t *)realloc(s->threads, ncap * sizeof(pthread_t));
        if (!nt) {
            pthread_mutex_unlock(&s->mu);
            m2_panic("out of memory growing scope threads", __FILE__, __LINE__);
        }
        s->threads = nt;
        s->cap = ncap;
    }
    s->threads[s->len++] = th;
    pthread_mutex_unlock(&s->mu);
}

void m2_scope_end(void *scope_ptr) {
    M2Scope *s = (M2Scope *)scope_ptr;
    if (!s) return;
    for (;;) {
        pthread_mutex_lock(&s->mu);
        if (s->len == 0) {
            pthread_mutex_unlock(&s->mu);
            break;
        }
        pthread_t *batch = s->threads;
        size_t n = s->len;
        s->threads = NULL;
        s->len = 0;
        s->cap = 0;
        pthread_mutex_unlock(&s->mu);
        for (size_t i = 0; i < n; i++) {
            pthread_join(batch[i], NULL);
        }
        free(batch);
    }
    m2_rc_dec(s);
}

/* Channel */
typedef struct M2Channel {
    pthread_mutex_t mu;
    pthread_cond_t not_empty;
    pthread_cond_t not_full;
    int64_t *buf;
    int64_t cap;
    int64_t head;
    int64_t count;
    int32_t bounded;
    int32_t closed;
    int32_t elem_is_obj;
} M2Channel;

static void m2_chan_drop(void *payload) {
    M2Channel *c = (M2Channel *)payload;
    if (c->elem_is_obj && c->buf) {
        for (int64_t i = 0; i < c->count; i++) {
            int64_t pos = (c->head + i) % c->cap;
            m2_rc_dec((void *)(uintptr_t)c->buf[pos]);
        }
    }
    free(c->buf);
    pthread_cond_destroy(&c->not_empty);
    pthread_cond_destroy(&c->not_full);
    pthread_mutex_destroy(&c->mu);
}

void *m2_chan_new(int64_t cap, int32_t elem_is_obj) {
    M2Channel *c = (M2Channel *)m2_alloc((uint32_t)sizeof(M2Channel), M2_TAG_CHANNEL, m2_chan_drop);
    pthread_mutex_init(&c->mu, NULL);
    pthread_cond_init(&c->not_empty, NULL);
    pthread_cond_init(&c->not_full, NULL);
    c->bounded = cap > 0 ? 1 : 0;
    c->cap = cap > 0 ? cap : 16;
    c->buf = (int64_t *)malloc((size_t)c->cap * sizeof(int64_t));
    if (!c->buf) m2_panic("out of memory in chan_new", __FILE__, __LINE__);
    c->head = 0;
    c->count = 0;
    c->closed = 0;
    c->elem_is_obj = elem_is_obj ? 1 : 0;
    m2_rc_freeze(c);
    return c;
}

int32_t m2_chan_send(void *ch_ptr, int64_t val) {
    M2Channel *c = (M2Channel *)ch_ptr;
    if (c->elem_is_obj && val != 0) {
        m2_rc_freeze((void *)(uintptr_t)val);
    }
    pthread_mutex_lock(&c->mu);
    if (c->bounded) {
        while (c->count == c->cap && !c->closed) {
            pthread_cond_wait(&c->not_full, &c->mu);
        }
    }
    if (c->closed) {
        pthread_mutex_unlock(&c->mu);
        return 0;
    }
    if (!c->bounded && c->count == c->cap) {
        int64_t ncap = c->cap * 2;
        int64_t *nb = (int64_t *)malloc((size_t)ncap * sizeof(int64_t));
        if (!nb) {
            pthread_mutex_unlock(&c->mu);
            m2_panic("out of memory growing unbounded channel", __FILE__, __LINE__);
        }
        for (int64_t i = 0; i < c->count; i++) {
            nb[i] = c->buf[(c->head + i) % c->cap];
        }
        free(c->buf);
        c->buf = nb;
        c->head = 0;
        c->cap = ncap;
    }
    if (c->elem_is_obj && val != 0) {
        m2_rc_inc((void *)(uintptr_t)val);
    }
    int64_t tail = (c->head + c->count) % c->cap;
    c->buf[tail] = val;
    c->count++;
    pthread_cond_signal(&c->not_empty);
    pthread_mutex_unlock(&c->mu);
    return 1;
}

int32_t m2_chan_recv(void *ch_ptr, int64_t *out_val) {
    M2Channel *c = (M2Channel *)ch_ptr;
    pthread_mutex_lock(&c->mu);
    while (c->count == 0 && !c->closed) {
        pthread_cond_wait(&c->not_empty, &c->mu);
    }
    if (c->count == 0 && c->closed) {
        pthread_mutex_unlock(&c->mu);
        return 0;
    }
    int64_t v = c->buf[c->head];
    c->head = (c->head + 1) % c->cap;
    c->count--;
    if (c->bounded) {
        pthread_cond_signal(&c->not_full);
    }
    pthread_mutex_unlock(&c->mu);
    if (out_val) *out_val = v;
    return 1;
}

void m2_chan_close(void *ch_ptr) {
    M2Channel *c = (M2Channel *)ch_ptr;
    pthread_mutex_lock(&c->mu);
    c->closed = 1;
    pthread_cond_broadcast(&c->not_empty);
    pthread_cond_broadcast(&c->not_full);
    pthread_mutex_unlock(&c->mu);
}

/* Mutex */
typedef struct M2Mutex {
    pthread_mutex_t mu;
    int64_t val;
    int32_t val_is_obj;
} M2Mutex;

static void m2_mutex_drop(void *payload) {
    M2Mutex *m = (M2Mutex *)payload;
    if (m->val_is_obj && m->val != 0) {
        m2_rc_dec((void *)(uintptr_t)m->val);
    }
    pthread_mutex_destroy(&m->mu);
}

void *m2_mutex_new(int64_t init_val, int32_t val_is_obj) {
    M2Mutex *m = (M2Mutex *)m2_alloc((uint32_t)sizeof(M2Mutex), M2_TAG_MUTEX, m2_mutex_drop);
    pthread_mutex_init(&m->mu, NULL);
    m->val_is_obj = val_is_obj ? 1 : 0;
    if (m->val_is_obj && init_val != 0) {
        m2_rc_freeze((void *)(uintptr_t)init_val);
        m2_rc_inc((void *)(uintptr_t)init_val);
    }
    m->val = init_val;
    m2_rc_freeze(m);
    return m;
}

int64_t m2_mutex_lock(void *m_ptr) {
    M2Mutex *m = (M2Mutex *)m_ptr;
    pthread_mutex_lock(&m->mu);
    return m->val;
}

void m2_mutex_set(void *m_ptr, int64_t new_val) {
    M2Mutex *m = (M2Mutex *)m_ptr;
    int64_t old_val = 0;
    if (m->val_is_obj) {
        if (new_val != 0) {
            m2_rc_freeze((void *)(uintptr_t)new_val);
            m2_rc_inc((void *)(uintptr_t)new_val);
        }
        old_val = m->val;
    }
    m->val = new_val;
    if (m->val_is_obj && old_val != 0) {
        m2_rc_dec((void *)(uintptr_t)old_val);
    }
}

void m2_mutex_set_and_unlock(void *m_ptr, int64_t new_val) {
    M2Mutex *m = (M2Mutex *)m_ptr;
    int64_t old_val = 0;
    if (m->val_is_obj) {
        if (new_val != 0) {
            m2_rc_freeze((void *)(uintptr_t)new_val);
            m2_rc_inc((void *)(uintptr_t)new_val);
        }
        old_val = m->val;
    }
    m->val = new_val;
    pthread_mutex_unlock(&m->mu);
    if (m->val_is_obj && old_val != 0) {
        m2_rc_dec((void *)(uintptr_t)old_val);
    }
}

void m2_mutex_unlock(void *m_ptr) {
    M2Mutex *m = (M2Mutex *)m_ptr;
    pthread_mutex_unlock(&m->mu);
}

/* AtomicInt */
typedef struct M2Atomic {
    _Atomic int64_t val;
} M2Atomic;

void *m2_atomic_new(int64_t init_val) {
    M2Atomic *a = (M2Atomic *)m2_alloc((uint32_t)sizeof(M2Atomic), M2_TAG_ATOMIC, NULL);
    atomic_init(&a->val, init_val);
    m2_rc_freeze(a);
    return a;
}

int64_t m2_atomic_load(void *a_ptr) {
    return atomic_load_explicit(&((M2Atomic *)a_ptr)->val, memory_order_seq_cst);
}

void m2_atomic_store(void *a_ptr, int64_t val) {
    atomic_store_explicit(&((M2Atomic *)a_ptr)->val, val, memory_order_seq_cst);
}

int64_t m2_atomic_fetch_add(void *a_ptr, int64_t delta) {
    return atomic_fetch_add_explicit(&((M2Atomic *)a_ptr)->val, delta, memory_order_seq_cst);
}

/* ============================================================================
 * 7. World Capabilities & Pure C SHA-256
 * ============================================================================ */

typedef struct M2World {
    int argc;
    char **argv;
} M2World;

void *m2_world_init(int argc, char **argv) {
    M2World *w = (M2World *)m2_alloc((uint32_t)sizeof(M2World), M2_TAG_WORLD, NULL);
    w->argc = argc;
    w->argv = argv;
    m2_rc_freeze(w);
    return w;
}

int64_t m2_world_argc(void *w_ptr) {
    M2World *w = (M2World *)w_ptr;
    return w ? (int64_t)w->argc : 0;
}

void *m2_world_argv(void *w_ptr, int64_t idx) {
    M2World *w = (M2World *)w_ptr;
    if (!w || idx < 0 || idx >= w->argc) {
        m2_panic("argv index out of bounds", __FILE__, __LINE__);
    }
    const char *arg = w->argv[idx] ? w->argv[idx] : "";
    return m2_str_from_cstr(arg, (int64_t)strlen(arg));
}

void *m2_world_args(void *w_ptr) {
    M2World *w = (M2World *)w_ptr;
    int64_t n = w ? (int64_t)w->argc : 0;
    void *arr = m2_arr_new(n, 1);
    for (int64_t i = 0; i < n; i++) {
        void *s = m2_world_argv(w_ptr, i);
        m2_arr_push(arr, (int64_t)(uintptr_t)s);
        m2_rc_dec(s);
    }
    return arr;
}

void m2_world_print(void *w_ptr, void *s_ptr) {
    (void)w_ptr;
    M2String *s = (M2String *)s_ptr;
    if (s && s->len > 0) {
        fwrite(s->data, 1, (size_t)s->len, stdout);
    }
    fflush(stdout);
}

void m2_world_println(void *w_ptr, void *s_ptr) {
    (void)w_ptr;
    M2String *s = (M2String *)s_ptr;
    if (s && s->len > 0) {
        fwrite(s->data, 1, (size_t)s->len, stdout);
    }
    fputc('\n', stdout);
    fflush(stdout);
}

void m2_world_eprintln(void *w_ptr, void *s_ptr) {
    (void)w_ptr;
    M2String *s = (M2String *)s_ptr;
    if (s && s->len > 0) {
        fwrite(s->data, 1, (size_t)s->len, stderr);
    }
    fputc('\n', stderr);
    fflush(stderr);
}

void *m2_world_fs_read(void *w_ptr, void *path_str, int32_t *ok_out) {
    (void)w_ptr;
    M2String *path = (M2String *)path_str;
    if (!path) {
        if (ok_out) *ok_out = 0;
        return m2_str_from_cstr("", 0);
    }
    FILE *f = fopen(path->data, "rb");
    if (!f) {
        if (ok_out) *ok_out = 0;
        return m2_str_from_cstr("", 0);
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        if (ok_out) *ok_out = 0;
        return m2_str_from_cstr("", 0);
    }
    long sz = ftell(f);
    if (sz < 0 || fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        if (ok_out) *ok_out = 0;
        return m2_str_from_cstr("", 0);
    }
    M2String *out = (M2String *)m2_alloc_raw((uint32_t)(sizeof(M2String) + (size_t)sz + 1),
                                             M2_TAG_STRING, NULL);
    out->len = (int64_t)sz;
    if (sz > 0) {
        size_t got = fread(out->data, 1, (size_t)sz, f);
        if (got != (size_t)sz) {
            fclose(f);
            m2_rc_dec(out);
            if (ok_out) *ok_out = 0;
            return m2_str_from_cstr("", 0);
        }
    }
    out->data[sz] = '\0';
    fclose(f);
    if (ok_out) *ok_out = 1;
    return out;
}

int32_t m2_world_fs_write(void *w_ptr, void *path_str, void *content_str) {
    (void)w_ptr;
    M2String *path = (M2String *)path_str;
    M2String *content = (M2String *)content_str;
    if (!path || !content) return 0;
    FILE *f = fopen(path->data, "wb");
    if (!f) return 0;
    size_t written = 0;
    if (content->len > 0) {
        written = fwrite(content->data, 1, (size_t)content->len, f);
    }
    int close_ok = (fclose(f) == 0);
    return (written == (size_t)content->len && close_ok) ? 1 : 0;
}

int32_t m2_world_fs_exists(void *w_ptr, void *path_str) {
    (void)w_ptr;
    M2String *path = (M2String *)path_str;
    if (!path) return 0;
    return access(path->data, F_OK) == 0 ? 1 : 0;
}

int32_t m2_world_fs_is_dir(void *w_ptr, void *path_str) {
    (void)w_ptr;
    M2String *path = (M2String *)path_str;
    if (!path || path->len == 0) return 0;
    struct stat st;
    if (stat(path->data, &st) != 0) return 0;
    return S_ISDIR(st.st_mode) ? 1 : 0;
}

int32_t m2_world_fs_mkdir_p(void *w_ptr, void *path_str) {
    (void)w_ptr;
    M2String *path = (M2String *)path_str;
    if (!path || path->len == 0) return 0;
    char *tmp = (char *)malloc((size_t)path->len + 1);
    if (!tmp) return 0;
    memcpy(tmp, path->data, (size_t)path->len + 1);
    size_t len = (size_t)path->len;
    while (len > 1 && tmp[len - 1] == '/') {
        tmp[--len] = '\0';
    }
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
                free(tmp);
                return 0;
            }
            *p = '/';
        }
    }
    int ok = 1;
    if (mkdir(tmp, 0755) != 0) {
        struct stat st;
        if (errno != EEXIST || stat(tmp, &st) != 0 || !S_ISDIR(st.st_mode)) {
            ok = 0;
        }
    }
    free(tmp);
    return ok;
}

static int m2_str_slot_cmp(const void *a, const void *b) {
    void *sa = (void *)(uintptr_t)(*(const int64_t *)a);
    void *sb = (void *)(uintptr_t)(*(const int64_t *)b);
    return (int)m2_str_cmp(sa, sb);
}

void *m2_world_fs_list_dir(void *w_ptr, void *path_str) {
    (void)w_ptr;
    M2String *path = (M2String *)path_str;
    void *arr = m2_arr_new(8, 1);
    if (!path) return arr;
    DIR *d = opendir(path->data);
    if (!d) return arr;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
            continue;
        }
        void *name = m2_str_from_cstr(ent->d_name, (int64_t)strlen(ent->d_name));
        m2_arr_push(arr, (int64_t)(uintptr_t)name);
        m2_rc_dec(name);
    }
    closedir(d);
    M2Array *a = (M2Array *)arr;
    if (a->len > 1) {
        qsort(a->data, (size_t)a->len, sizeof(int64_t), m2_str_slot_cmp);
    }
    return arr;
}

int32_t m2_world_fs_remove(void *w_ptr, void *path_str) {
    (void)w_ptr;
    M2String *path = (M2String *)path_str;
    if (!path || path->len == 0) return 0;
    return unlink(path->data) == 0 ? 1 : 0;
}

int32_t m2_world_fs_rename(void *w_ptr, void *old_path, void *new_path) {
    (void)w_ptr;
    M2String *op = (M2String *)old_path;
    M2String *np = (M2String *)new_path;
    if (!op || !np || op->len == 0 || np->len == 0) return 0;
    return rename(op->data, np->data) == 0 ? 1 : 0;
}

int64_t m2_world_fs_size(void *w_ptr, void *path_str) {
    (void)w_ptr;
    M2String *path = (M2String *)path_str;
    if (!path || path->len == 0) return -1;
    struct stat st;
    if (stat(path->data, &st) != 0) return -1;
    return (int64_t)st.st_size;
}

void *m2_world_env_get(void *w_ptr, void *name_str, int32_t *ok_out) {
    (void)w_ptr;
    M2String *name = (M2String *)name_str;
    if (!name) {
        if (ok_out) *ok_out = 0;
        return m2_str_from_cstr("", 0);
    }
    const char *v = getenv(name->data);
    if (!v) {
        if (ok_out) *ok_out = 0;
        return m2_str_from_cstr("", 0);
    }
    if (ok_out) *ok_out = 1;
    return m2_str_from_cstr(v, (int64_t)strlen(v));
}

int64_t m2_world_clock_ms(void *w_ptr) {
    (void)w_ptr;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

int32_t m2_world_exec(void *w_ptr, void *argv_arr) {
    (void)w_ptr;
    M2Array *arr = (M2Array *)argv_arr;
    if (!arr || arr->len <= 0) return -1;
    char **argv = (char **)malloc(((size_t)arr->len + 1) * sizeof(char *));
    if (!argv) return -1;
    for (int64_t i = 0; i < arr->len; i++) {
        M2String *s = (M2String *)(uintptr_t)arr->data[i];
        argv[i] = s ? s->data : (char *)"";
    }
    argv[arr->len] = NULL;

    pid_t pid = 0;
    int rc = posix_spawnp(&pid, argv[0], NULL, NULL, argv, environ);
    free(argv);
    if (rc != 0) {
        return 127;
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

/* Pure C SHA-256 (FIPS 180-4) */
static const uint32_t sha256_k[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u, 0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

static inline uint32_t rotr32(uint32_t x, uint32_t n) {
    return (x >> n) | (x << (32u - n));
}

static void sha256_transform(uint32_t st[8], const uint8_t blk[64]) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)blk[i * 4] << 24) | ((uint32_t)blk[i * 4 + 1] << 16) |
               ((uint32_t)blk[i * 4 + 2] << 8) | (uint32_t)blk[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = st[0], b = st[1], c = st[2], d = st[3];
    uint32_t e = st[4], f = st[5], g = st[6], h = st[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + S1 + ch + sha256_k[i] + w[i];
        uint32_t S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    st[0] += a; st[1] += b; st[2] += c; st[3] += d;
    st[4] += e; st[5] += f; st[6] += g; st[7] += h;
}

void *m2_sha256_hex(void *s_ptr) {
    M2String *s = (M2String *)s_ptr;
    const uint8_t *data = s ? (const uint8_t *)s->data : (const uint8_t *)"";
    uint64_t len = s ? (uint64_t)s->len : 0;

    uint32_t st[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
    };

    uint64_t off = 0;
    while (off + 64 <= len) {
        sha256_transform(st, data + off);
        off += 64;
    }

    uint8_t tail[128];
    memset(tail, 0, sizeof(tail));
    uint64_t rem = len - off;
    if (rem > 0) memcpy(tail, data + off, (size_t)rem);
    tail[rem] = 0x80u;
    size_t pad_blocks = (rem + 9 <= 64) ? 1 : 2;
    uint64_t bit_len = len * 8u;
    size_t len_pos = pad_blocks * 64 - 8;
    for (int i = 0; i < 8; i++) {
        tail[len_pos + (size_t)i] = (uint8_t)(bit_len >> (56 - i * 8));
    }
    sha256_transform(st, tail);
    if (pad_blocks == 2) {
        sha256_transform(st, tail + 64);
    }

    static const char hex[] = "0123456789abcdef";
    char out[64];
    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 8; j++) {
            out[i * 8 + j] = hex[(st[i] >> (28 - j * 4)) & 0xFu];
        }
    }
    return m2_str_from_cstr(out, 64);
}
