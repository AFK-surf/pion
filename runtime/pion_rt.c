#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include "pion_rt.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <direct.h>
#include <errno.h>
#include <inttypes.h>
#include <io.h>
#include <limits.h>
#include <math.h>
#include <process.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#else
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE /* kqueue's <sys/event.h> and SO_REUSEPORT need the BSD types */
#endif

#include "pion_rt.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if (defined(__APPLE__) && defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE) || \
    (defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 28))
#define PION_NO_SPAWN 1
#else
#define PION_NO_SPAWN 0
#include <spawn.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/event.h>
#elif defined(__linux__)
#include <sys/epoll.h>
#if !defined(__ANDROID__)
#include <sys/random.h>
#endif
/* glibc hides SO_REUSEPORT under _POSIX_C_SOURCE; 15 is the asm-generic value. */
#if !defined(SO_REUSEPORT) && (defined(__x86_64__) || defined(__aarch64__) || defined(__riscv) || \
                               defined(__i386__) || defined(__arm__) || defined(__powerpc__))
#define SO_REUSEPORT 15
#endif
#endif

#if !PION_NO_SPAWN
extern char **environ;
#endif
#endif /* _WIN32 */

#if defined(__clang__)
#define PION_MINSIZE __attribute__((minsize))
#define PION_HOT
/* C never unwinds: drop per-function unwind entries (Darwin arm64 emits 32 B of
 * __compact_unwind per function even with -fno-asynchronous-unwind-tables, ~8 KB
 * here). Backtraces (lldb, ASan/TSan) walk frame pointers, which arm64 always keeps. */
#pragma clang attribute push (__attribute__((nouwtable)), apply_to = hasType(functionType))
#else
#define PION_MINSIZE __attribute__((optimize("Os")))
#if defined(__OPTIMIZE_SIZE__)
#define PION_HOT __attribute__((optimize("O2")))
#else
#define PION_HOT
#endif
#endif

#if defined(__clang__)
#define PION_NOINLINE __attribute__((noinline))
#define PION_COLD __attribute__((cold))
#elif defined(__GNUC__)
#define PION_NOINLINE __attribute__((noinline))
#define PION_COLD
#else
#define PION_NOINLINE
#define PION_COLD
#endif

/* ============================================================================
 * 1. Memory & Biased RC
 * ============================================================================ */

PION_HIDDEN uint32_t pion_mt_flag = 0;
static _Atomic uint32_t g_pion_mt = 0;
static _Atomic uint32_t g_next_tid = 2;
static _Thread_local uint32_t tls_tid = 0;

static PION_COLD PION_MINSIZE uint32_t pion_cur_tid_slow(void) {
    uint32_t t = atomic_fetch_add_explicit(&g_next_tid, 1, memory_order_relaxed);
    tls_tid = t;
    return t;
}

static inline uint32_t pion_cur_tid_mt(void) {
    uint32_t t = tls_tid;
    if (__builtin_expect(t == 0, 0)) {
        return pion_cur_tid_slow();
    }
    return t;
}

static inline uint32_t pion_cur_tid_fast(void) {
    if (__builtin_expect(!atomic_load_explicit(&g_pion_mt, memory_order_relaxed), 1)) {
        return 1u;
    }
    return pion_cur_tid_mt();
}

PION_MINSIZE uint64_t pion_cur_tid(void) {
    return (uint64_t)pion_cur_tid_fast();
}

static inline PionHeader *pion_hdr(void *obj) {
    return ((PionHeader *)obj) - 1;
}

PION_MINSIZE void pion_panic(const char *msg, const char *file, int32_t line) {
    fprintf(stderr, "pion panic at %s:%d: %s\n",
            file ? file : "<unknown>", (int)line, msg ? msg : "");
    fflush(stderr);
    abort();
}

static _Noreturn PION_NOINLINE PION_MINSIZE void pion_oom(void) {
    pion_panic("out of memory", __FILE__, __LINE__);
}

static _Noreturn PION_NOINLINE PION_MINSIZE void pion_die(const char *msg) {
    pion_panic(msg, __FILE__, __LINE__);
}

PION_MINSIZE void pion_panic_oob(int64_t idx, int64_t len) {
    fprintf(stderr, "pion panic: index %" PRId64 " out of bounds (len %" PRId64 ")\n", idx, len);
    fflush(stderr);
    abort();
}

PION_MINSIZE void pion_debug_assert(int32_t cond, void *msg_str, const char *file, int32_t line) {
    if (__builtin_expect(!cond, 0)) {
        const char *msg = msg_str ? ((PionString *)msg_str)->data : "assertion failed";
        pion_panic(msg, file, line);
    }
}

PION_MINSIZE double pion_math_sqrt(double x) {
    return sqrt(x);
}

PION_MINSIZE double pion_math_abs(double x) {
    return fabs(x);
}

PION_MINSIZE double pion_math_floor(double x) {
    return floor(x);
}

PION_MINSIZE double pion_math_ceil(double x) {
    return ceil(x);
}

PION_MINSIZE double pion_math_sin(double x) {
    return sin(x);
}

PION_MINSIZE double pion_math_cos(double x) {
    return cos(x);
}

PION_MINSIZE double pion_math_pow(double x, double y) {
    return pow(x, y);
}

#if defined(__SANITIZE_ADDRESS__)
#define PION_USE_SLAB 0
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define PION_USE_SLAB 0
#else
#define PION_USE_SLAB 1
#endif
#else
#define PION_USE_SLAB 1
#endif

#if PION_USE_SLAB

#define PION_SLAB_CLASSES      16u
#define PION_SLAB_MAX_TOTAL    1024u
#define PION_SLAB_MAX_PAYLOAD  (PION_SLAB_MAX_TOTAL - (uint32_t)sizeof(PionHeader))
#define PION_SLAB_CHUNK_BYTES  262144u
#define PION_SLAB_REMOTE_BATCH 32u

/* 6-tier per-thread medium-block cache (2K / 4K / 8K / 16K / 32K / 64K).
 * Tiers 0..3 (2K..16K) cache up to 16 blocks each; tiers 4..5 (32K/64K) cache up to 4 blocks each.
 * Uses unused high bits of PionHeader.flags (bit 8 = flag, bits 9..11 = tier 0..5). */
#define PION_FLAG_MED_CACHE     ((uint16_t)256u)
#define PION_FLAG_MED_CLS_SHIFT 9u
#define PION_FLAG_MED_CLS_MASK  ((uint16_t)7u)
#define PION_MED_CLASSES        6u
#define PION_MED_MAX_BYTES      65536u
#define PION_MED_MAX_PAYLOAD    (PION_MED_MAX_BYTES - (uint32_t)sizeof(PionHeader))

static inline uint32_t pion_med_cls_for(size_t total) {
#if defined(__clang__) || defined(__GNUC__)
    if (total <= 2048u) return 0u;
    return (uint32_t)(53 - __builtin_clzll((unsigned long long)(total - 1u)));
#else
    if (total <= 2048u) return 0u;
    if (total <= 4096u) return 1u;
    if (total <= 8192u) return 2u;
    if (total <= 16384u) return 3u;
    if (total <= 32768u) return 4u;
    return 5u;
#endif
}

typedef struct PionSlabTLS {
    void *local_free[PION_SLAB_CLASSES];
    void *remote_head[PION_SLAB_CLASSES];
    void *remote_tail[PION_SLAB_CLASSES];
    uint32_t remote_count[PION_SLAB_CLASSES];
    void *med_free[PION_MED_CLASSES];
    uint8_t med_count[PION_MED_CLASSES];
    char *chunk_cur;
    char *chunk_end;
} PionSlabTLS;

static const uint16_t pion_slab_sizes[PION_SLAB_CLASSES] = {
    32u, 40u, 48u, 56u, 64u, 80u, 96u, 112u, 128u, 160u, 192u, 256u,
    320u, 384u, 512u, 1024u
};

/* Maps ((total + 7) >> 3) in [0..32] to slab class [0..11] */
static const uint8_t pion_slab_cls_lut[33] = {
    0, 0, 0, 0, 0,
    1,
    2,
    3,
    4,
    5, 5,
    6, 6,
    7, 7,
    8, 8,
    9, 9, 9, 9,
    10, 10, 10, 10,
    11, 11, 11, 11, 11, 11, 11, 11
};

static inline uint32_t pion_slab_cls_for(size_t total) {
    if (__builtin_expect(total <= 256u, 1)) {
        return pion_slab_cls_lut[(total + 7u) >> 3];
    }
    if (total <= 320u) return 12u;
    if (total <= 384u) return 13u;
    if (total <= 512u) return 14u;
    return 15u;
}

static PionSlabTLS g_main_slab;
static _Thread_local PionSlabTLS *tls_slab = NULL;
static _Atomic(void *) g_slab_remote[PION_SLAB_CLASSES];

static PION_NOINLINE PION_COLD PION_MINSIZE PionSlabTLS *pion_slab_cur_mt(void) {
    return tls_slab;
}

static inline PionSlabTLS *pion_slab_cur(void) {
    if (__builtin_expect(!atomic_load_explicit(&g_pion_mt, memory_order_relaxed), 1)) {
        return &g_main_slab;
    }
    return pion_slab_cur_mt();
}
#ifdef _WIN32
static INIT_ONCE g_slab_fls_once = INIT_ONCE_STATIC_INIT;
static DWORD g_slab_fls_idx = FLS_OUT_OF_INDEXES;
#else
static pthread_once_t g_slab_key_once = PTHREAD_ONCE_INIT;
static pthread_key_t g_slab_key;
#endif

/* Strict-aliasing-safe intrusive freelist link (lives at offset 0 of free slot) */
static inline void *pion_slab_get_next(void *slot) {
    void *next;
    memcpy(&next, slot, sizeof(next));
    return next;
}

static inline void pion_slab_set_next(void *slot, void *next) {
    memcpy(slot, &next, sizeof(next));
}

static PION_COLD PION_MINSIZE void pion_slab_push_remote_list(uint32_t cls, void *head, void *tail) {
    void *cur = atomic_load_explicit(&g_slab_remote[cls], memory_order_relaxed);
    do {
        pion_slab_set_next(tail, cur);
    } while (!atomic_compare_exchange_weak_explicit(
        &g_slab_remote[cls], &cur, head,
        memory_order_release, memory_order_relaxed));
}

PION_MINSIZE static void pion_slab_thread_cleanup(void *arg) {
    tls_slab = NULL;
    PionSlabTLS *s = (PionSlabTLS *)arg;
    if (!s) return;
    for (uint32_t cls = 0; cls < PION_SLAB_CLASSES; cls++) {
        void *head = s->local_free[cls];
        if (head) {
            void *tail = head, *nxt;
            while ((nxt = pion_slab_get_next(tail)) != NULL) tail = nxt;
            pion_slab_push_remote_list(cls, head, tail);
        }
        if (s->remote_head[cls]) {
            pion_slab_push_remote_list(cls, s->remote_head[cls], s->remote_tail[cls]);
        }
    }
    for (uint32_t mcls = 0; mcls < PION_MED_CLASSES; mcls++) {
        void *mcur = s->med_free[mcls];
        while (mcur) {
            void *mnxt = pion_slab_get_next(mcur);
            free(mcur);
            mcur = mnxt;
        }
    }
    if (s != &g_main_slab) {
        free(s);
    } else {
        memset(s, 0, sizeof(*s));
    }
}

#ifdef _WIN32
static VOID WINAPI pion_slab_fls_cleanup(PVOID arg) {
    pion_slab_thread_cleanup(arg);
}

static BOOL CALLBACK pion_slab_fls_init(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once;
    (void)param;
    (void)ctx;
    g_slab_fls_idx = FlsAlloc(pion_slab_fls_cleanup);
    return TRUE;
}
#else
static PION_COLD PION_MINSIZE void pion_slab_key_init(void) {
    (void)pthread_key_create(&g_slab_key, pion_slab_thread_cleanup);
}
#endif

static PION_NOINLINE PION_COLD PION_MINSIZE PionHeader *pion_slab_alloc_slow(PionSlabTLS *s, uint32_t cls) {
    if (__builtin_expect(!s, 0)) {
        s = (PionSlabTLS *)calloc(1, sizeof(PionSlabTLS));
        if (__builtin_expect(!s, 0)) {
            pion_oom();
        }
#ifdef _WIN32
        InitOnceExecuteOnce(&g_slab_fls_once, pion_slab_fls_init, NULL, NULL);
        if (g_slab_fls_idx != FLS_OUT_OF_INDEXES) {
            (void)FlsSetValue(g_slab_fls_idx, s);
        }
#else
        pthread_once(&g_slab_key_once, pion_slab_key_init);
        (void)pthread_setspecific(g_slab_key, s);
#endif
        tls_slab = s;
    }
    if (__builtin_expect(atomic_load_explicit(&g_pion_mt, memory_order_relaxed) != 0, 0)) {
        void *remote = atomic_exchange_explicit(&g_slab_remote[cls], NULL, memory_order_acquire);
        if (remote) {
            s->local_free[cls] = pion_slab_get_next(remote);
            return (PionHeader *)remote;
        }
    }
    uint32_t slot_sz = pion_slab_sizes[cls];
    if (__builtin_expect((uintptr_t)s->chunk_end - (uintptr_t)s->chunk_cur < slot_sz, 0)) {
        char *chunk = (char *)malloc(PION_SLAB_CHUNK_BYTES);
        if (__builtin_expect(!chunk, 0)) {
            pion_oom();
        }
        s->chunk_cur = chunk;
        s->chunk_end = chunk + PION_SLAB_CHUNK_BYTES;
    }
    PionHeader *hdr = (PionHeader *)s->chunk_cur;
    s->chunk_cur += slot_sz;
    return hdr;
}

static PION_NOINLINE PION_COLD PION_MINSIZE void pion_slab_free_remote(void *ptr, uint32_t cls) {
    PionSlabTLS *s = pion_slab_cur();
    if (__builtin_expect(s != NULL, 1)) {
        void *head = s->remote_head[cls];
        pion_slab_set_next(ptr, head);
        s->remote_head[cls] = ptr;
        if (!head) {
            s->remote_tail[cls] = ptr;
        }
        if (++s->remote_count[cls] >= PION_SLAB_REMOTE_BATCH) {
            void *tail = s->remote_tail[cls];
            s->remote_head[cls] = NULL;
            s->remote_tail[cls] = NULL;
            s->remote_count[cls] = 0;
            pion_slab_push_remote_list(cls, ptr, tail);
        }
        return;
    }
    pion_slab_push_remote_list(cls, ptr, ptr);
}

static PION_NOINLINE PION_COLD PION_MINSIZE void *pion_med_alloc(uint32_t mcls) {
    PionSlabTLS *s = pion_slab_cur();
    if (__builtin_expect(s != NULL && s->med_free[mcls] != NULL, 1)) {
        void *node = s->med_free[mcls];
        s->med_free[mcls] = pion_slab_get_next(node);
        s->med_count[mcls]--;
        return node;
    }
    void *mp = malloc((size_t)2048u << mcls);
    if (__builtin_expect(!mp, 0)) {
        pion_oom();
    }
    return mp;
}

static PION_NOINLINE PION_COLD PION_MINSIZE void pion_med_free(void *ptr, uint32_t mcls, int is_frozen) {
    int mt = atomic_load_explicit(&g_pion_mt, memory_order_relaxed);
    if (__builtin_expect(!mt || !is_frozen, 1)) {
        PionSlabTLS *s = mt ? pion_slab_cur_mt() : &g_main_slab;
        uint8_t max_c = (mcls < 4u) ? 16u : 4u;
        if (__builtin_expect(s != NULL && s->med_count[mcls] < max_c, 1)) {
            pion_slab_set_next(ptr, s->med_free[mcls]);
            s->med_free[mcls] = ptr;
            s->med_count[mcls]++;
            return;
        }
    }
    free(ptr);
}

#endif /* PION_USE_SLAB */

static PION_NOINLINE PION_COLD PION_MINSIZE void *pion_slab_raw_alloc_slow(size_t bytes) {
#if PION_USE_SLAB
    int mt = atomic_load_explicit(&g_pion_mt, memory_order_relaxed);
    if (bytes <= PION_SLAB_MAX_TOTAL) {
        uint32_t cls = pion_slab_cls_for(bytes);
        if (__builtin_expect(!mt, 1)) {
            return (void *)pion_slab_alloc_slow(&g_main_slab, cls);
        }
        PionSlabTLS *s = pion_slab_cur_mt();
        if (s != NULL && s->local_free[cls] != NULL) {
            void *node = s->local_free[cls];
            s->local_free[cls] = pion_slab_get_next(node);
            return node;
        }
        return (void *)pion_slab_alloc_slow(s, cls);
    }
    if (bytes <= PION_MED_MAX_BYTES) {
        return pion_med_alloc(pion_med_cls_for(bytes));
    }
#endif
    void *p = malloc(bytes);
    if (__builtin_expect(!p, 0)) {
        pion_oom();
    }
    return p;
}

static PION_NOINLINE PION_HOT void *pion_slab_raw_alloc(size_t bytes) {
#if PION_USE_SLAB
    if (__builtin_expect(
            !atomic_load_explicit(&g_pion_mt, memory_order_relaxed) &&
            bytes <= PION_SLAB_MAX_TOTAL, 1)) {
        uint32_t cls = pion_slab_cls_for(bytes);
        void *node = g_main_slab.local_free[cls];
        if (__builtin_expect(node != NULL, 1)) {
            g_main_slab.local_free[cls] = pion_slab_get_next(node);
            return node;
        }
        uint32_t slot_sz = pion_slab_sizes[cls];
        char *cur = g_main_slab.chunk_cur;
        if (__builtin_expect((uintptr_t)g_main_slab.chunk_end - (uintptr_t)cur >= slot_sz, 1)) {
            g_main_slab.chunk_cur = cur + slot_sz;
            return (void *)cur;
        }
    }
#endif
    return pion_slab_raw_alloc_slow(bytes);
}

static PION_NOINLINE PION_COLD PION_MINSIZE void pion_slab_raw_free_slow(void *ptr, size_t bytes, int is_frozen) {
#if PION_USE_SLAB
    if (bytes <= PION_SLAB_MAX_TOTAL) {
        uint32_t cls = pion_slab_cls_for(bytes);
        int mt = atomic_load_explicit(&g_pion_mt, memory_order_relaxed);
        PionSlabTLS *s = mt ? pion_slab_cur_mt() : &g_main_slab;
        if ((!mt || !is_frozen) && s != NULL) {
            pion_slab_set_next(ptr, s->local_free[cls]);
            s->local_free[cls] = ptr;
            return;
        }
        pion_slab_free_remote(ptr, cls);
        return;
    }
    if (bytes <= PION_MED_MAX_BYTES) {
        pion_med_free(ptr, pion_med_cls_for(bytes), is_frozen);
        return;
    }
#else
    (void)bytes;
    (void)is_frozen;
#endif
    free(ptr);
}

static PION_NOINLINE PION_HOT void pion_slab_raw_free(void *ptr, size_t bytes, int is_frozen) {
    if (!ptr) return;
#if PION_USE_SLAB
    if (__builtin_expect(
            !atomic_load_explicit(&g_pion_mt, memory_order_relaxed) &&
            bytes <= PION_SLAB_MAX_TOTAL, 1)) {
        uint32_t cls = pion_slab_cls_for(bytes);
        pion_slab_set_next(ptr, g_main_slab.local_free[cls]);
        g_main_slab.local_free[cls] = ptr;
        return;
    }
#endif
    pion_slab_raw_free_slow(ptr, bytes, is_frozen);
}

static PION_NOINLINE PION_MINSIZE void *pion_alloc_uninit_slow(
    uint32_t payload_size, uint16_t type_tag, PionDropFn drop_fn) {
    PionHeader *hdr;
    uint16_t flags = 0;
    int mt = atomic_load_explicit(&g_pion_mt, memory_order_relaxed);
#if PION_USE_SLAB
    if (__builtin_expect(payload_size <= PION_SLAB_MAX_PAYLOAD, 1)) {
        uint32_t cls = pion_slab_cls_for((uint32_t)sizeof(PionHeader) + payload_size);
        PionSlabTLS *s = mt ? pion_slab_cur_mt() : &g_main_slab;
        if (mt && s != NULL && s->local_free[cls] != NULL) {
            void *node = s->local_free[cls];
            s->local_free[cls] = pion_slab_get_next(node);
            hdr = (PionHeader *)node;
        } else {
            hdr = pion_slab_alloc_slow(s, cls);
        }
        flags = (uint16_t)(PION_FLAG_SLAB | (cls << PION_FLAG_SLAB_CLS_SHIFT));
    } else if (payload_size <= PION_MED_MAX_PAYLOAD) {
        uint32_t total = (uint32_t)sizeof(PionHeader) + payload_size;
        uint32_t mcls = pion_med_cls_for(total);
        hdr = (PionHeader *)pion_med_alloc(mcls);
        flags = (uint16_t)(PION_FLAG_MED_CACHE | (mcls << PION_FLAG_MED_CLS_SHIFT));
    } else
#endif
    {
        size_t total = sizeof(PionHeader) + (size_t)payload_size;
        hdr = (PionHeader *)malloc(total);
        if (__builtin_expect(!hdr, 0)) {
            pion_oom();
        }
    }
    hdr->owner_tid = mt ? pion_cur_tid_mt() : 1u;
    hdr->local_rc = 1;
    atomic_init(&hdr->shared_rc, 0);
    hdr->type_tag = type_tag;
    hdr->flags = flags;
    hdr->drop_fn = drop_fn;
    return (void *)(hdr + 1);
}

static inline void *pion_alloc_raw_fast(uint32_t payload_size, uint16_t type_tag, PionDropFn drop_fn) {
#if PION_USE_SLAB
    if (__builtin_expect(
            !atomic_load_explicit(&g_pion_mt, memory_order_relaxed) &&
            payload_size <= PION_SLAB_MAX_PAYLOAD, 1)) {
        uint32_t cls = pion_slab_cls_for((uint32_t)sizeof(PionHeader) + payload_size);
        PionHeader *hdr = (PionHeader *)g_main_slab.local_free[cls];
        if (__builtin_expect(hdr != NULL, 1)) {
            g_main_slab.local_free[cls] = pion_slab_get_next(hdr);
        } else {
            uint32_t slot_sz = pion_slab_sizes[cls];
            char *cur = g_main_slab.chunk_cur;
            if (__builtin_expect((uintptr_t)g_main_slab.chunk_end - (uintptr_t)cur < slot_sz, 0)) {
                return pion_alloc_uninit_slow(payload_size, type_tag, drop_fn);
            }
            g_main_slab.chunk_cur = cur + slot_sz;
            hdr = (PionHeader *)cur;
        }
        hdr->owner_tid = 1u;
        hdr->local_rc = 1;
        atomic_init(&hdr->shared_rc, 0);
        hdr->type_tag = type_tag;
        hdr->flags = (uint16_t)(PION_FLAG_SLAB | (cls << PION_FLAG_SLAB_CLS_SHIFT));
        hdr->drop_fn = drop_fn;
        return (void *)(hdr + 1);
    }
#endif
    return pion_alloc_uninit_slow(payload_size, type_tag, drop_fn);
}

PION_NOINLINE PION_HOT void *pion_alloc_uninit(uint32_t payload_size, uint16_t type_tag, PionDropFn drop_fn) {
    return pion_alloc_raw_fast(payload_size, type_tag, drop_fn);
}

#define pion_alloc_raw pion_alloc_uninit

void *pion_alloc(uint32_t payload_size, uint16_t type_tag, PionDropFn drop_fn) {
    void *payload = pion_alloc_uninit(payload_size, type_tag, drop_fn);
    if (payload_size > 0) {
        memset(payload, 0, payload_size);
    }
    return payload;
}

typedef struct {
    void **q;
    uint32_t depth;
    uint32_t len;
    uint32_t cap;
} PionDropTLS;

static PionDropTLS g_main_drop;
static _Thread_local PionDropTLS tls_drop;

static PION_NOINLINE PION_COLD PION_MINSIZE PionDropTLS *pion_drop_cur_mt(void) {
    return &tls_drop;
}

static PION_NOINLINE void pion_destroy(PionHeader *hdr, void *obj);

static PION_COLD PION_NOINLINE PION_MINSIZE void pion_drop_worklist(PionDropTLS *td, void *obj) {
    if (obj) {
        if (td->len == td->cap) {
            uint32_t ncap = td->cap ? td->cap * 2u : 256u;
            void **nq = (void **)realloc(td->q, (size_t)ncap * sizeof(void *));
            if (!nq) pion_oom();
            td->q = nq;
            td->cap = ncap;
        }
        td->q[td->len++] = obj;
        return;
    }
    td->depth = 1u;
    while (td->len > 0u) {
        void *x = td->q[--td->len];
        pion_destroy(pion_hdr(x), x);
    }
    td->depth = 0u;
    free(td->q);
    td->q = NULL;
    td->cap = 0u;
}

static PION_NOINLINE PION_COLD PION_MINSIZE void pion_destroy_free_slow(PionHeader *hdr) {
#if PION_USE_SLAB
    uint16_t flags = hdr->flags;
    if (__builtin_expect((flags & PION_FLAG_SLAB) != 0, 1)) {
        uint32_t cls = (uint32_t)((flags >> PION_FLAG_SLAB_CLS_SHIFT) & PION_FLAG_SLAB_CLS_MASK);
        PionSlabTLS *s = pion_slab_cur_mt();
        if (__builtin_expect((flags & PION_FLAG_FROZEN) == 0 && s != NULL, 1)) {
            pion_slab_set_next(hdr, s->local_free[cls]);
            s->local_free[cls] = hdr;
        } else {
            pion_slab_free_remote(hdr, cls);
        }
        return;
    }
    if (__builtin_expect((flags & PION_FLAG_MED_CACHE) != 0, 0)) {
        uint32_t mcls = (uint32_t)((flags >> PION_FLAG_MED_CLS_SHIFT) & PION_FLAG_MED_CLS_MASK);
        pion_med_free(hdr, mcls, (flags & PION_FLAG_FROZEN) != 0);
        return;
    }
#endif
    free(hdr);
}

static struct {
    const PionMap *map;
    const void *key;
    PionMapEntry *entry;
    uint64_t hash;
} g_map_hint;

static PION_NOINLINE void pion_destroy(PionHeader *hdr, void *obj) {
    int mt = atomic_load_explicit(&g_pion_mt, memory_order_relaxed);
    if (__builtin_expect(!mt && obj == g_map_hint.key, 0)) {
        g_map_hint.map = NULL;
    }
    PionDropFn drop = hdr->drop_fn;
    PionDropTLS *td = NULL;
    uint32_t d = 0u;
    if (drop) {
        td = __builtin_expect(!mt, 1) ? &g_main_drop : pion_drop_cur_mt();
        d = td->depth;
        if (__builtin_expect(d >= 64u, 0)) {
            pion_drop_worklist(td, obj);
            return;
        }
        td->depth = d + 1u;
        drop(obj);
        td->depth = d;
    }
#if PION_USE_SLAB
    uint16_t flags = hdr->flags;
    if (__builtin_expect(!mt && (flags & PION_FLAG_SLAB) != 0, 1)) {
        uint32_t cls = (uint32_t)((flags >> PION_FLAG_SLAB_CLS_SHIFT) & PION_FLAG_SLAB_CLS_MASK);
        pion_slab_set_next(hdr, g_main_slab.local_free[cls]);
        g_main_slab.local_free[cls] = hdr;
    } else
#endif
    {
        pion_destroy_free_slow(hdr);
    }
    if (__builtin_expect(td != NULL && d == 0u && td->len != 0u, 0)) {
        pion_drop_worklist(td, NULL);
    }
}

PION_MINSIZE void pion_destroy_obj(void *obj) {
    pion_destroy(pion_hdr(obj), obj);
}

PION_NOINLINE PION_HOT void pion_rc_inc(void *obj) {
    if (!obj) return;
    PionHeader *hdr = pion_hdr(obj);
    if (hdr->flags & PION_FLAG_IMMORTAL) return;
    if (__builtin_expect(!atomic_load_explicit(&g_pion_mt, memory_order_relaxed), 1)) {
        if (__builtin_expect(hdr->owner_tid != 0, 1)) {
            hdr->local_rc++;
            return;
        }
    } else if (__builtin_expect(hdr->owner_tid == pion_cur_tid_mt(), 1)) {
        hdr->local_rc++;
        return;
    }
    atomic_fetch_add_explicit(&hdr->shared_rc, 1, memory_order_relaxed);
}

PION_NOINLINE PION_HOT void pion_rc_dec(void *obj) {
    if (!obj) return;
    PionHeader *hdr = pion_hdr(obj);
    if (hdr->flags & PION_FLAG_IMMORTAL) return;
    if (__builtin_expect(!atomic_load_explicit(&g_pion_mt, memory_order_relaxed), 1)) {
        if (__builtin_expect(hdr->owner_tid != 0, 1)) {
            if (--hdr->local_rc == 0) {
                pion_destroy(hdr, obj);
            }
            return;
        }
    } else if (__builtin_expect(hdr->owner_tid == pion_cur_tid_mt(), 1)) {
        if (--hdr->local_rc == 0) {
            if (atomic_load_explicit(&hdr->shared_rc, memory_order_acquire) == 0) {
                pion_destroy(hdr, obj);
            }
        }
        return;
    }
    if (atomic_fetch_sub_explicit(&hdr->shared_rc, 1, memory_order_acq_rel) == 1) {
        pion_destroy(hdr, obj);
    }
}

PION_MINSIZE static void pion_enter_mt(void) {
    if (__builtin_expect(atomic_load_explicit(&g_pion_mt, memory_order_relaxed) == 0, 0)) {
        if (tls_tid == 0) tls_tid = 1u;
#if PION_USE_SLAB
        if (tls_slab == NULL) tls_slab = &g_main_slab;
#endif
        pion_mt_flag = 1u;
        atomic_store_explicit(&g_pion_mt, 1u, memory_order_release);
    }
}

static PION_NOINLINE PION_MINSIZE void pion_arr_foreach_obj(PionArray *a, void (*fn)(void *));

static PION_NOINLINE PION_MINSIZE void pion_map_foreach_obj(PionMap *m, void (*fn)(void *)) {
    for (int64_t i = 0; i < m->cap; i++) {
        if (m->entries[i].state == 1) {
            if (!m->key_is_int) fn(m->entries[i].key);
            if (m->val_is_obj) fn((void *)(uintptr_t)m->entries[i].val);
        }
    }
}

PION_COLD PION_MINSIZE void pion_rc_freeze(void *obj) {
    if (!obj) return;
    PionHeader *hdr = pion_hdr(obj);
    if ((hdr->flags & PION_FLAG_IMMORTAL) || hdr->owner_tid == 0) return;
    if (hdr->owner_tid != pion_cur_tid_fast()) {
        pion_die("pion_rc_freeze called from non-owning thread");
    }
    uint32_t rc = hdr->local_rc;
    hdr->local_rc = 0;
    atomic_fetch_add_explicit(&hdr->shared_rc, rc, memory_order_relaxed);
    hdr->flags |= PION_FLAG_FROZEN;
    hdr->owner_tid = 0;
    if (hdr->type_tag == PION_TAG_MAP) {
        pion_map_foreach_obj((PionMap *)obj, pion_rc_freeze);
    } else if (hdr->type_tag == PION_TAG_ARRAY) {
        pion_arr_foreach_obj((PionArray *)obj, pion_rc_freeze);
    }
}

PION_MINSIZE void pion_rc_immortalize(void *obj) {
    if (!obj) return;
    PionHeader *hdr = pion_hdr(obj);
    if (hdr->flags & PION_FLAG_IMMORTAL) return;
    hdr->owner_tid = 0;
    hdr->local_rc = 0;
    hdr->flags |= (PION_FLAG_FROZEN | PION_FLAG_IMMORTAL);
    if (hdr->type_tag == PION_TAG_ARRAY) {
        pion_arr_foreach_obj((PionArray *)obj, pion_rc_immortalize);
    } else if (hdr->type_tag == PION_TAG_MAP) {
        pion_map_foreach_obj((PionMap *)obj, pion_rc_immortalize);
    }
}

static inline void pion_adopt(void *container, int64_t val) {
    if (__builtin_expect(pion_hdr(container)->owner_tid == 0, 0)) {
        pion_rc_freeze((void *)(uintptr_t)val);
    }
}

/* ============================================================================
 * 2. String
 * ============================================================================ */

static const char pion_digits200[201] =
    "0001020304050607080910111213141516171819"
    "2021222324252627282930313233343536373839"
    "4041424344454647484950515253545556575859"
    "6061626364656667686970717273747576777879"
    "8081828384858687888990919293949596979899";

static PION_NOINLINE char *pion_fmt_i64_end(int64_t v, char *end) {
    char *p = end;
    int neg = v < 0;
    uint64_t u = neg ? ((uint64_t)(-(v + 1)) + 1ULL) : (uint64_t)v;
    while (u >= 100ULL) {
        uint64_t q = u / 100ULL;
        uint32_t r = (uint32_t)(u - q * 100ULL) * 2u;
        u = q;
        p -= 2;
        p[0] = pion_digits200[r];
        p[1] = pion_digits200[r + 1];
    }
    if (u >= 10ULL) {
        uint32_t r = (uint32_t)u * 2u;
        p -= 2;
        p[0] = pion_digits200[r];
        p[1] = pion_digits200[r + 1];
    } else {
        *--p = (char)('0' + u);
    }
    if (neg) {
        *--p = '-';
    }
    return p;
}

static inline void pion_copy_short(char *dst, const char *src, size_t n) {
    if (__builtin_expect(n <= 16, 1)) {
        if (n >= 8) {
            uint64_t a, b;
            memcpy(&a, src, 8);
            memcpy(&b, src + n - 8, 8);
            memcpy(dst, &a, 8);
            memcpy(dst + n - 8, &b, 8);
        } else if (n >= 4) {
            uint32_t a, b;
            memcpy(&a, src, 4);
            memcpy(&b, src + n - 4, 4);
            memcpy(dst, &a, 4);
            memcpy(dst + n - 4, &b, 4);
        } else if (n >= 2) {
            uint16_t a, b;
            memcpy(&a, src, 2);
            memcpy(&b, src + n - 2, 2);
            memcpy(dst, &a, 2);
            memcpy(dst + n - 2, &b, 2);
        } else if (n == 1) {
            dst[0] = src[0];
        }
        return;
    }
    memcpy(dst, src, n);
}

#define PION_MAX_CONTAINER_LEN ((int64_t)0x7FFFFFFF - 16)

static _Noreturn PION_NOINLINE PION_MINSIZE void pion_die_len(void) {
    pion_die("container length exceeds maximum");
}

static PION_NOINLINE PION_MINSIZE PionString *pion_str_alloc_checked(int64_t len) {
    if (__builtin_expect((uint64_t)len > (uint64_t)PION_MAX_CONTAINER_LEN, 0)) {
        pion_die_len();
    }
    PionString *out = (PionString *)pion_alloc_uninit(
        (uint32_t)(sizeof(PionString) + (size_t)len + 1), PION_TAG_STRING, NULL);
    out->len = len;
    out->data[len] = '\0';
    return out;
}

PION_NOINLINE PION_HOT void *pion_str_from_cstr(const char *s, int64_t len) {
    if (!s) {
        len = 0;
    } else if (len < 0) {
        len = (int64_t)strlen(s);
    }
    if (__builtin_expect((uint64_t)len > (uint64_t)PION_MAX_CONTAINER_LEN, 0)) {
        pion_die_len();
    }
    uint32_t payload_size = (uint32_t)(sizeof(PionString) + (size_t)len + 1);
    PionString *str = (PionString *)pion_alloc_uninit(payload_size, PION_TAG_STRING, NULL);
    str->len = len;
    if (len > 0 && s) {
        pion_copy_short(str->data, s, (size_t)len);
    }
    str->data[len] = '\0';
    return str;
}

static PION_NOINLINE PION_MINSIZE void *pion_empty_str(void) {
    return pion_str_from_cstr("", 0);
}

PION_MINSIZE int64_t pion_str_len(void *s) {
    if (!s) return 0;
    return ((PionString *)s)->len;
}

PION_MINSIZE int32_t pion_str_byte_at(void *s, int64_t idx) {
    PionString *str = (PionString *)s;
    if (__builtin_expect(!str || idx < 0 || idx >= str->len, 0)) {
        pion_die("string index out of bounds");
    }
    return (int32_t)(unsigned char)str->data[idx];
}

static PION_NOINLINE PION_HOT void pion_copy_small(char *dst, const char *src, size_t n) {
    pion_copy_short(dst, src, n);
}

PION_HOT void *pion_str_concat(void *a, void *b) {
    PionString *sa = (PionString *)a;
    PionString *sb = (PionString *)b;
    int64_t la = sa ? sa->len : 0;
    int64_t lb = sb ? sb->len : 0;
    if (__builtin_expect((uint64_t)la > (uint64_t)PION_MAX_CONTAINER_LEN ||
                         (uint64_t)lb > (uint64_t)(PION_MAX_CONTAINER_LEN - la), 0)) {
        pion_die_len();
    }
    int64_t total = la + lb;
    PionString *out = (PionString *)pion_alloc_uninit(
        (uint32_t)(sizeof(PionString) + (size_t)total + 1), PION_TAG_STRING, NULL);
    out->len = total;
    if (la > 0) pion_copy_small(out->data, sa->data, (size_t)la);
    if (lb > 0) pion_copy_small(out->data + la, sb->data, (size_t)lb);
    out->data[total] = '\0';
    return out;
}

PION_MINSIZE void *pion_str_concat_n(int64_t n, void **parts) {
    int64_t total = 0;
    for (int64_t i = 0; i < n; i++) {
        PionString *s = (PionString *)parts[i];
        if (s) {
            if ((uint64_t)s->len > (uint64_t)(PION_MAX_CONTAINER_LEN - total)) {
                pion_die_len();
            }
            total += s->len;
        }
    }
    PionString *out = pion_str_alloc_checked(total);
    char *dst = out->data;
    for (int64_t i = 0; i < n; i++) {
        PionString *s = (PionString *)parts[i];
        if (s && s->len > 0) {
            memcpy(dst, s->data, (size_t)s->len);
            dst += s->len;
        }
    }
    return out;
}

static inline __attribute__((always_inline)) int32_t pion_str_eq_fast(const PionString *sa, const PionString *sb) {
    if (sa == sb) return 1;
    if (!sa || !sb) return 0;
    int64_t len = sa->len;
    if (len != sb->len) return 0;
    if (len == 0) return 1;
    size_t n = (size_t)len;
    const char *a = sa->data;
    const char *b = sb->data;
    if (__builtin_expect(n <= 16, 1)) {
        if (n >= 8) {
            uint64_t a0, b0, a1, b1;
            memcpy(&a0, a, 8);
            memcpy(&b0, b, 8);
            memcpy(&a1, a + n - 8, 8);
            memcpy(&b1, b + n - 8, 8);
            return ((a0 ^ b0) | (a1 ^ b1)) == 0 ? 1 : 0;
        }
        if (n >= 4) {
            uint32_t a0, b0, a1, b1;
            memcpy(&a0, a, 4);
            memcpy(&b0, b, 4);
            memcpy(&a1, a + n - 4, 4);
            memcpy(&b1, b + n - 4, 4);
            return ((a0 ^ b0) | (a1 ^ b1)) == 0 ? 1 : 0;
        }
        if (n >= 2) {
            uint16_t a0, b0, a1, b1;
            memcpy(&a0, a, 2);
            memcpy(&b0, b, 2);
            memcpy(&a1, a + n - 2, 2);
            memcpy(&b1, b + n - 2, 2);
            return ((a0 ^ b0) | (a1 ^ b1)) == 0 ? 1 : 0;
        }
        return a[0] == b[0] ? 1 : 0;
    }
    uint64_t a0, b0;
    memcpy(&a0, a, 8);
    memcpy(&b0, b, 8);
    if (a0 != b0) return 0;
    return memcmp(a + 8, b + 8, n - 8) == 0 ? 1 : 0;
}

PION_NOINLINE PION_HOT int32_t pion_str_eq(void *a, void *b) {
    return pion_str_eq_fast((const PionString *)a, (const PionString *)b);
}

PION_MINSIZE int32_t pion_str_cmp(void *a, void *b) {
    if (a == b) return 0;
    PionString *sa = (PionString *)a;
    PionString *sb = (PionString *)b;
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

PION_HOT void *pion_str_slice(void *s, int64_t start, int64_t end) {
    PionString *str = (PionString *)s;
    if (__builtin_expect(!str || start < 0 || end < start || end > str->len, 0)) {
        pion_die("string slice out of bounds");
    }
    return pion_str_from_cstr(str->data + start, end - start);
}

PION_HOT void *pion_int_to_str(int64_t v) {
    char tmp[24];
    char *end = tmp + sizeof(tmp);
    char *p = pion_fmt_i64_end(v, end);
    return pion_str_from_cstr(p, (int64_t)(end - p));
}

PION_MINSIZE void *pion_double_to_str(double v) {
    char buf[64];
    int n = 0;
    for (int prec = 15; prec <= 17; prec++) {
        n = snprintf(buf, sizeof(buf), "%.*g", prec, v);
        if (!isfinite(v) || prec == 17 || (n > 0 && strtod(buf, NULL) == v)) break;
    }
    if (n < 0) return pion_empty_str();
    if (n >= (int)sizeof(buf)) n = (int)sizeof(buf) - 1;
    return pion_str_from_cstr(buf, (int64_t)n);
}

static inline int pion_is_ascii_ws(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

PION_MINSIZE int64_t pion_str_to_int(void *s, int32_t *ok_out) {
    if (ok_out) *ok_out = 0;
    PionString *str = (PionString *)s;
    if (!str || str->len <= 0 || pion_is_ascii_ws(str->data[0])) return 0;
    errno = 0;
    char *end = NULL;
    long long v = strtoll(str->data, &end, 10);
    if (errno == ERANGE || end != str->data + str->len) return 0;
    if (ok_out) *ok_out = 1;
    return (int64_t)v;
}

PION_MINSIZE double pion_str_to_double(void *s, int32_t *ok_out) {
    PionString *str = (PionString *)s;
    *ok_out = 0;
    if (!str || str->len <= 0) return 0.0;
    const char *p = str->data;
    char c = p[(p[0] == '-' || p[0] == '+') ? 1 : 0];
    /* Plain decimal text only: no leading whitespace, no `inf`/`nan` words. */
    if (!((c >= '0' && c <= '9') || c == '.')) return 0.0;
    char *end = NULL;
    double v = strtod(p, &end);
    if (end != p + str->len) return 0.0;
    *ok_out = 1;
    return v;
}

PION_NOINLINE PION_MINSIZE static const char *pion_memmem(const char *hay, int64_t hlen, const char *ndl, int64_t nlen) {
    if (nlen == 0) return hay;
    if (nlen > hlen) return NULL;
    if (nlen == 1) return (const char *)memchr(hay, (unsigned char)ndl[0], (size_t)hlen);
    const char *cur = hay;
    const char *last = hay + (hlen - nlen);
    unsigned char first = (unsigned char)ndl[0];
    while (cur <= last) {
        const char *hit = (const char *)memchr(cur, first, (size_t)(last - cur + 1));
        if (!hit) return NULL;
        if (memcmp(hit + 1, ndl + 1, (size_t)(nlen - 1)) == 0) return hit;
        cur = hit + 1;
    }
    return NULL;
}

static PION_NOINLINE PION_MINSIZE int32_t pion_str_affix(void *s, void *a, int at_end) {
    PionString *ss = (PionString *)s;
    PionString *sa = (PionString *)a;
    int64_t sl = ss ? ss->len : 0;
    int64_t al = sa ? sa->len : 0;
    if (al == 0) return 1;
    if (al > sl) return 0;
    return memcmp(ss->data + (at_end ? sl - al : 0), sa->data, (size_t)al) == 0 ? 1 : 0;
}

PION_MINSIZE int32_t pion_str_starts_with(void *s, void *prefix) {
    return pion_str_affix(s, prefix, 0);
}

PION_MINSIZE int32_t pion_str_ends_with(void *s, void *suffix) {
    return pion_str_affix(s, suffix, 1);
}

PION_MINSIZE int64_t pion_str_index_of(void *s, void *needle) {
    PionString *ss = (PionString *)s;
    PionString *sn = (PionString *)needle;
    int64_t sl = ss ? ss->len : 0;
    int64_t nl = sn ? sn->len : 0;
    if (nl == 0) return 0;
    if (nl > sl) return -1;
    const char *hit = pion_memmem(ss->data, sl, sn->data, nl);
    return hit ? (int64_t)(hit - ss->data) : -1;
}

PION_MINSIZE int32_t pion_str_contains(void *s, void *needle) {
    return pion_str_index_of(s, needle) >= 0 ? 1 : 0;
}

PION_MINSIZE void *pion_str_trim(void *s) {
    PionString *str = (PionString *)s;
    if (!str || str->len == 0) return pion_empty_str();
    int64_t lo = 0;
    int64_t hi = str->len;
    while (lo < hi && pion_is_ascii_ws(str->data[lo])) lo++;
    while (hi > lo && pion_is_ascii_ws(str->data[hi - 1])) hi--;
    return pion_str_from_cstr(str->data + lo, hi - lo);
}

static PION_NOINLINE PION_MINSIZE void pion_arr_grow(PionArray *a);

static PION_NOINLINE PION_MINSIZE void pion_split_emit(PionArray *a, const char *s, int64_t len) {
    if (__builtin_expect(a->len == a->cap, 0)) pion_arr_grow(a);
    a->data[a->len++] = (int64_t)(uintptr_t)pion_str_from_cstr(s, len);
}

static PION_NOINLINE PION_MINSIZE void *pion_str_split_cold(
    PionString *ss, PionString *sp, int64_t sl, int64_t pl) {
    PionArray *arr = (PionArray *)pion_arr_new(8, 1);
    if (pl == 0) {
        for (int64_t i = 0; i < sl; i++) {
            pion_split_emit(arr, ss->data + i, 1);
        }
        return arr;
    }
    if (!ss || sl == 0) {
        pion_split_emit(arr, "", 0);
        return arr;
    }
    int64_t pos = 0;
    while (pos <= sl) {
        const char *hit = pion_memmem(ss->data + pos, sl - pos, sp->data, pl);
        if (!hit) {
            pion_split_emit(arr, ss->data + pos, sl - pos);
            break;
        }
        int64_t off = (int64_t)(hit - ss->data);
        pion_split_emit(arr, ss->data + pos, off - pos);
        pos = off + pl;
    }
    return arr;
}

static PION_NOINLINE PION_MINSIZE int64_t pion_split_est_cap(const char *base, int64_t sl, int sep_ch) {
    uint64_t sample_cnt = 0;
    for (int i = 0; i < 4096; i++) {
        if ((unsigned char)base[i] == (unsigned char)sep_ch) sample_cnt++;
    }
    uint64_t est = ((uint64_t)sl / 4096u) * (sample_cnt + 1u) + 64u;
    if (est > 16777216u) est = 16777216u;
    if (est > (uint64_t)sl + 1u) est = (uint64_t)sl + 1u;
    return (int64_t)est;
}

/* Splits s by sep into PionArray of PionString*.
 * Empty sep splits into individual bytes (empty string -> empty array). */
void *pion_str_split(void *s, void *sep) {
    PionString *ss = (PionString *)s;
    PionString *sp = (PionString *)sep;
    int64_t sl = ss ? ss->len : 0;
    int64_t pl = sp ? sp->len : 0;
    if (__builtin_expect(pl != 1 || !ss || sl == 0, 0)) {
        return pion_str_split_cold(ss, sp, sl, pl);
    }
    int sep_ch = (unsigned char)sp->data[0];
    const char *base = ss->data;
    int64_t init_cap = 8;
    if (sl >= 4096) {
        init_cap = pion_split_est_cap(base, sl, sep_ch);
    } else if (sl >= 256) {
        init_cap = sl / 6;
    }
    PionArray *arr = (PionArray *)pion_arr_new(init_cap, 1);
    int64_t pos = 0;
    const char *lim = base + sl;
#if PION_USE_SLAB
    int mt = atomic_load_explicit(&g_pion_mt, memory_order_relaxed);
#endif
    while (pos <= sl) {
        const char *p = base + pos;
        const char *fast_lim = (lim - p > 16) ? p + 16 : lim;
#if defined(__clang__)
#pragma clang loop unroll(disable) vectorize(disable)
#endif
        while (p < fast_lim && (unsigned char)*p != (unsigned char)sep_ch) {
            p++;
        }
        const char *hit;
        if (p < fast_lim) {
            hit = p;
        } else if (p < lim) {
            hit = (const char *)memchr(p, sep_ch, (size_t)(lim - p));
        } else {
            hit = NULL;
        }
        int64_t end = hit ? (int64_t)(hit - base) : sl;
        int64_t tok_len = end - pos;
        void *part;
#if PION_USE_SLAB
        if (__builtin_expect(!mt && tok_len <= 7, 1)) {
            PionHeader *hdr = (PionHeader *)g_main_slab.local_free[1];
            if (__builtin_expect(hdr != NULL, 0)) {
                g_main_slab.local_free[1] = pion_slab_get_next(hdr);
            } else {
                char *cur = g_main_slab.chunk_cur;
                if (__builtin_expect((uintptr_t)g_main_slab.chunk_end - (uintptr_t)cur >= 40u, 1)) {
                    g_main_slab.chunk_cur = cur + 40u;
                    hdr = (PionHeader *)cur;
                }
            }
            if (__builtin_expect(hdr != NULL, 1)) {
                hdr->owner_tid = 1u;
                hdr->local_rc = 1;
                atomic_init(&hdr->shared_rc, 0);
                hdr->type_tag = PION_TAG_STRING;
                hdr->flags = (uint16_t)(PION_FLAG_SLAB | (1u << PION_FLAG_SLAB_CLS_SHIFT));
                hdr->drop_fn = NULL;
                PionString *str = (PionString *)(hdr + 1);
                str->len = tok_len;
                const char *src = base + pos;
                char *dst = str->data;
                if (__builtin_expect(tok_len >= 4, 1)) {
                    uint32_t w0, w1;
                    memcpy(&w0, src, 4);
                    memcpy(&w1, src + tok_len - 4, 4);
                    memcpy(dst, &w0, 4);
                    memcpy(dst + tok_len - 4, &w1, 4);
                } else if (tok_len >= 2) {
                    uint16_t h0;
                    memcpy(&h0, src, 2);
                    memcpy(dst, &h0, 2);
                    dst[tok_len - 1] = src[tok_len - 1];
                } else if (tok_len == 1) {
                    dst[0] = src[0];
                }
                dst[tok_len] = '\0';
                part = str;
                goto push_part;
            }
        }
#endif
        part = pion_str_from_cstr(base + pos, tok_len);
#if PION_USE_SLAB
    push_part:
#endif
        if (__builtin_expect(arr->len == arr->cap, 0)) pion_arr_grow(arr);
        arr->data[arr->len++] = (int64_t)(uintptr_t)part;
        if (!hit) break;
        pos = end + 1;
    }
    return arr;
}

PION_MINSIZE void *pion_str_replace(void *s, void *from, void *to) {
    PionString *ss = (PionString *)s;
    if (!ss) return pion_empty_str();
    PionString *sf = (PionString *)from;
    int64_t sl = ss->len, fl = sf ? sf->len : 0;
    if (fl == 0 || fl > sl) {
        pion_rc_inc(ss);
        return ss;
    }
    const char *hit = pion_memmem(ss->data, sl, sf->data, fl);
    if (!hit) {
        pion_rc_inc(ss);
        return ss;
    }
    void *sb = pion_strbuf_new(sl);
    int64_t pos = 0;
    do {
        int64_t off = (int64_t)(hit - ss->data);
        if (off > pos) pion_strbuf_push_slice(sb, ss, pos, off);
        if (to) pion_strbuf_push_str(sb, to);
        pos = off + fl;
        hit = (pos <= sl - fl) ? pion_memmem(ss->data + pos, sl - pos, sf->data, fl) : NULL;
    } while (hit);
    if (pos < sl) pion_strbuf_push_slice(sb, ss, pos, sl);
    void *out = pion_strbuf_to_str(sb);
    pion_rc_dec(sb);
    return out;
}

/* ============================================================================
 * 2b. Bytes
 * ============================================================================ */

PION_MINSIZE static void pion_bytes_drop(void *payload) {
    PionBytes *b = (PionBytes *)payload;
    free(b->data);
    b->data = NULL;
}

static __attribute__((noinline)) PION_MINSIZE PionBytes *pion_bytes_alloc_uninit(int64_t len) {
    if (__builtin_expect((uint64_t)len > (uint64_t)PION_MAX_CONTAINER_LEN, 0)) {
        pion_die_len();
    }
    PionBytes *b = (PionBytes *)pion_alloc_raw((uint32_t)sizeof(PionBytes), PION_TAG_BYTES, pion_bytes_drop);
    b->len = len;
    b->cap = len;
    if (len > 0) {
        b->data = (uint8_t *)malloc((size_t)len);
        if (!b->data) pion_oom();
    } else {
        b->data = NULL;
    }
    return b;
}

PION_MINSIZE void *pion_bytes_new(int64_t len) {
    if (__builtin_expect(len < 0, 0)) {
        pion_die("negative bytes length");
    }
    PionBytes *b = pion_bytes_alloc_uninit(len);
    if (len > 0) {
        memset(b->data, 0, (size_t)len);
    }
    return b;
}

PION_MINSIZE int64_t pion_bytes_len(void *b) {
    return b ? ((PionBytes *)b)->len : 0;
}

PION_MINSIZE int32_t pion_bytes_get(void *b_ptr, int64_t idx) {
    PionBytes *b = (PionBytes *)b_ptr;
    if (__builtin_expect(!b || idx < 0 || idx >= b->len, 0)) {
        pion_panic_oob(idx, b ? b->len : 0);
    }
    return (int32_t)b->data[idx];
}

PION_MINSIZE void pion_bytes_set(void *b_ptr, int64_t idx, int32_t val) {
    PionBytes *b = (PionBytes *)b_ptr;
    if (__builtin_expect(!b || idx < 0 || idx >= b->len, 0)) {
        pion_panic_oob(idx, b ? b->len : 0);
    }
    b->data[idx] = (uint8_t)(val & 0xFF);
}

PION_MINSIZE void *pion_bytes_from_ptr(void *p, int64_t len) {
    if (len <= 0 || !p) return pion_bytes_alloc_uninit(0);
    PionBytes *out = pion_bytes_alloc_uninit(len);
    memcpy(out->data, p, (size_t)len);
    return out;
}

PION_MINSIZE void *pion_bytes_slice(void *b_ptr, int64_t start, int64_t end) {
    PionBytes *b = (PionBytes *)b_ptr;
    int64_t len = b ? b->len : 0;
    if (start < 0) start = 0;
    if (start > len) start = len;
    if (end < start) end = start;
    if (end > len) end = len;
    return pion_bytes_from_ptr(b ? b->data + start : NULL, end - start);
}

PION_MINSIZE void *pion_bytes_concat(void *a_ptr, void *b_ptr) {
    PionBytes *a = (PionBytes *)a_ptr;
    PionBytes *b = (PionBytes *)b_ptr;
    int64_t la = a ? a->len : 0;
    int64_t lb = b ? b->len : 0;
    PionBytes *out = pion_bytes_alloc_uninit(la + lb);
    if (la > 0) memcpy(out->data, a->data, (size_t)la);
    if (lb > 0) memcpy(out->data + la, b->data, (size_t)lb);
    return out;
}

PION_MINSIZE void *pion_str_to_bytes(void *s) {
    PionString *str = (PionString *)s;
    return pion_bytes_from_ptr(str ? str->data : NULL, str ? str->len : 0);
}

PION_MINSIZE void *pion_bytes_to_str(void *b_ptr) {
    PionBytes *b = (PionBytes *)b_ptr;
    if (!b || b->len == 0) return pion_empty_str();
    return pion_str_from_cstr((const char *)b->data, b->len);
}

PION_MINSIZE void pion_bytes_copy_to_ptr(void *b_ptr, int64_t src_off, void *dst, int64_t len) {
    PionBytes *b = (PionBytes *)b_ptr;
    int64_t blen = b ? b->len : 0;
    if (src_off < 0 || len < 0 || src_off > blen || len > blen - src_off) {
        pion_panic_oob(src_off + len, blen);
    }
    if (len > 0) {
        if (!dst) pion_die("null dst in bytes_copy_to_ptr");
        memcpy(dst, b->data + src_off, (size_t)len);
    }
}

/* ============================================================================
 * 3. StringBuilder
 * ============================================================================ */

static PION_MINSIZE void pion_strbuf_drop(void *payload) {
    PionStrBuf *sb = (PionStrBuf *)payload;
    free(sb->data);
    sb->data = NULL;
}

static __attribute__((noinline)) PION_MINSIZE void pion_strbuf_grow(PionStrBuf *sb, int64_t need) {
    int64_t max_cap = PION_MAX_CONTAINER_LEN + 1;
    if (__builtin_expect((uint64_t)need > (uint64_t)max_cap, 0)) {
        pion_die_len();
    }
    int64_t ncap = sb->cap > 0 ? sb->cap : 32;
    while (ncap < need) {
        if (ncap >= max_cap / 2) {
            ncap = max_cap;
            break;
        }
        ncap *= 2;
    }
    char *nd = (char *)realloc(sb->data, (size_t)ncap);
    if (!nd) pion_oom();
    sb->data = nd;
    sb->cap = ncap;
}

static inline void pion_strbuf_reserve(PionStrBuf *sb, int64_t add) {
    int64_t need = sb->len + add + 1;
    if (__builtin_expect(need > sb->cap, 0)) {
        pion_strbuf_grow(sb, need);
    }
}

PION_MINSIZE void *pion_strbuf_new(int64_t cap) {
    if (__builtin_expect(cap > PION_MAX_CONTAINER_LEN, 0)) {
        pion_die_len();
    }
    PionStrBuf *sb = (PionStrBuf *)pion_alloc_uninit((uint32_t)sizeof(PionStrBuf), PION_TAG_STRBUF, pion_strbuf_drop);
    int64_t init_cap = cap > 32 ? cap : 32;
    sb->data = (char *)malloc((size_t)init_cap);
    if (!sb->data) pion_oom();
    sb->data[0] = '\0';
    sb->len = 0;
    sb->cap = init_cap;
    return sb;
}

void pion_strbuf_push_str(void *sb_ptr, void *s_ptr) {
    PionStrBuf *sb = (PionStrBuf *)sb_ptr;
    PionString *s = (PionString *)s_ptr;
    if (__builtin_expect(!sb || !s || s->len == 0, 0)) return;
    int64_t slen = s->len;
    pion_strbuf_reserve(sb, slen);
    pion_copy_short(sb->data + sb->len, s->data, (size_t)slen);
    sb->len += slen;
    sb->data[sb->len] = '\0';
}

void pion_strbuf_push_slice(void *sb_ptr, void *s_ptr, int64_t start, int64_t end) {
    PionStrBuf *sb = (PionStrBuf *)sb_ptr;
    PionString *s = (PionString *)s_ptr;
    if (__builtin_expect(!sb || !s, 0)) return;
    int64_t slen = s->len;
    if (start < 0) start = 0;
    if (end > slen) end = slen;
    if (start >= end) return;
    int64_t n = end - start;
    pion_strbuf_reserve(sb, n);
    memcpy(sb->data + sb->len, s->data + start, (size_t)n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

void pion_strbuf_push_byte(void *sb_ptr, int32_t b) {
    PionStrBuf *sb = (PionStrBuf *)sb_ptr;
    if (__builtin_expect(!sb, 0)) return;
    pion_strbuf_reserve(sb, 1);
    sb->data[sb->len++] = (char)(b & 0xFF);
    sb->data[sb->len] = '\0';
}

PION_MINSIZE void pion_strbuf_push_char(void *sb_ptr, int32_t cp) {
    if (__builtin_expect((uint32_t)cp < 0x80u, 1)) {
        pion_strbuf_push_byte(sb_ptr, cp);
        return;
    }
    PionStrBuf *sb = (PionStrBuf *)sb_ptr;
    if (!sb || cp < 0 || cp > 0x10FFFF) return;
    char buf[4];
    int n = 0;
    if (cp < 0x800) {
        buf[n++] = (char)(0xC0 | (cp >> 6));
    } else if (cp < 0x10000) {
        buf[n++] = (char)(0xE0 | (cp >> 12));
        buf[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
    } else {
        buf[n++] = (char)(0xF0 | (cp >> 18));
        buf[n++] = (char)(0x80 | ((cp >> 12) & 0x3F));
        buf[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
    }
    buf[n++] = (char)(0x80 | (cp & 0x3F));
    pion_strbuf_reserve(sb, n);
    memcpy(sb->data + sb->len, buf, (size_t)n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

void pion_strbuf_push_int(void *sb_ptr, int64_t v) {
    PionStrBuf *sb = (PionStrBuf *)sb_ptr;
    if (!sb) return;
    char tmp[24];
    char *end = tmp + sizeof(tmp);
    char *p = pion_fmt_i64_end(v, end);
    size_t n = (size_t)(end - p);
    pion_strbuf_reserve(sb, (int64_t)n);
    pion_copy_short(sb->data + sb->len, p, n);
    sb->len += (int64_t)n;
    sb->data[sb->len] = '\0';
}

PION_MINSIZE void pion_strbuf_reset(void *sb_ptr) {
    PionStrBuf *sb = (PionStrBuf *)sb_ptr;
    if (!sb) return;
    sb->len = 0;
    if (sb->data) sb->data[0] = '\0';
}

PION_MINSIZE void *pion_strbuf_to_str(void *sb_ptr) {
    PionStrBuf *sb = (PionStrBuf *)sb_ptr;
    int64_t len = sb ? sb->len : 0;
    PionString *out = pion_str_alloc_checked(len);
    if (len > 0) {
        memcpy(out->data, sb->data, (size_t)len);
    }
    return out;
}

/* ============================================================================
 * 4. Array
 * ============================================================================ */

static inline size_t pion_arr_stride(const PionArray *a) {
    return a->elem_stride ? (size_t)a->elem_stride : sizeof(int64_t);
}

static PION_NOINLINE PION_MINSIZE void pion_arr_foreach_obj(PionArray *a, void (*fn)(void *)) {
    if (!a->elem_is_obj || a->len <= 0) return;
    size_t words = a->elem_stride > 8 ? ((size_t)a->elem_stride >> 3) : 1;
    uint32_t mask = (uint32_t)a->elem_is_obj;
    int64_t *slot = a->data;
    for (int64_t i = 0; i < a->len; i++, slot += words) {
        for (uint32_t m = mask, k = 0; m; m >>= 1, k++) {
            if (m & 1u) fn((void *)(uintptr_t)slot[k]);
        }
    }
}

static void pion_arr_drop(void *payload) {
    PionArray *a = (PionArray *)payload;
    if (a->elem_is_obj == 1 && a->elem_stride <= 8 && a->len > 0 &&
        __builtin_expect(!atomic_load_explicit(&g_pion_mt, memory_order_relaxed), 1)) {
        g_map_hint.map = NULL;
        int64_t *data = a->data;
        int64_t n = a->len;
#if defined(__clang__)
#pragma clang loop unroll(disable) vectorize(disable)
#endif
        for (int64_t i = 0; i < n; i++) {
            void *e = (void *)(uintptr_t)data[i];
            if (!e) continue;
            PionHeader *h = pion_hdr(e);
            uint16_t flags = h->flags;
            if (__builtin_expect((flags & PION_FLAG_IMMORTAL) != 0, 0)) continue;
            if (__builtin_expect(h->owner_tid != 0, 1)) {
                if (--h->local_rc == 0) {
#if PION_USE_SLAB
                    if (__builtin_expect(h->drop_fn == NULL && (flags & PION_FLAG_SLAB) != 0, 1)) {
                        uint32_t cls = (uint32_t)((flags >> PION_FLAG_SLAB_CLS_SHIFT) & PION_FLAG_SLAB_CLS_MASK);
                        pion_slab_set_next(h, g_main_slab.local_free[cls]);
                        g_main_slab.local_free[cls] = h;
                    } else
#endif
                    {
                        pion_destroy(h, e);
                    }
                }
            } else {
                pion_rc_dec(e);
            }
        }
    } else {
        pion_arr_foreach_obj(a, pion_rc_dec);
    }
    if (a->data) {
        pion_slab_raw_free(a->data, (size_t)a->cap * pion_arr_stride(a),
                           (pion_hdr(a)->flags & PION_FLAG_FROZEN) != 0);
        a->data = NULL;
    }
}

static PION_NOINLINE PION_MINSIZE void pion_arr_grow(PionArray *a) {
    size_t stride = pion_arr_stride(a);
    if (__builtin_expect(a->len >= PION_MAX_CONTAINER_LEN, 0)) {
        pion_die_len();
    }
    int64_t ocap = a->cap;
    int64_t ncap = ocap > 0 ? (ocap >= PION_MAX_CONTAINER_LEN / 2 ? PION_MAX_CONTAINER_LEN : ocap * 2) : 4;
    if (__builtin_expect(ncap <= a->len || (sizeof(size_t) < 8 && (size_t)ncap > SIZE_MAX / stride), 0)) {
        pion_die_len();
    }
    size_t new_bytes = (size_t)ncap * stride;
    int64_t *nd;
#if PION_USE_SLAB
    size_t old_bytes = (size_t)ocap * stride;
    if (old_bytes > PION_MED_MAX_BYTES && new_bytes > PION_MED_MAX_BYTES) {
        nd = (int64_t *)realloc(a->data, new_bytes);
        if (!nd) pion_oom();
    } else {
        nd = (int64_t *)pion_slab_raw_alloc(new_bytes);
        if (a->len > 0) {
            memcpy(nd, a->data, (size_t)a->len * stride);
        }
        if (a->data) {
            pion_slab_raw_free(a->data, old_bytes,
                               (pion_hdr(a)->flags & PION_FLAG_FROZEN) != 0);
        }
    }
#else
    nd = (int64_t *)realloc(a->data, new_bytes);
    if (!nd) pion_oom();
#endif
    a->data = nd;
    a->cap = ncap;
}

PION_HOT void *pion_arr_new(int64_t cap, int32_t elem_flags) {
    int32_t elem_stride = (elem_flags == 2) ? 1 : ((elem_flags > 2) ? (elem_flags & 0xFF) : 0);
    size_t stride = elem_stride ? (size_t)elem_stride : sizeof(int64_t);
    if (__builtin_expect(cap > PION_MAX_CONTAINER_LEN || (sizeof(size_t) < 8 && cap > 0 && (size_t)cap > SIZE_MAX / stride), 0)) {
        pion_die_len();
    }
    PionArray *a = (PionArray *)pion_alloc_uninit((uint32_t)sizeof(PionArray), PION_TAG_ARRAY, pion_arr_drop);
    a->len = 0;
    a->elem_is_obj = (elem_flags > 2) ? (elem_flags >> 8) : ((elem_flags == 1) ? 1 : 0);
    a->elem_stride = elem_stride;
    if (cap > 0) {
        a->data = (int64_t *)pion_slab_raw_alloc((size_t)cap * stride);
        a->cap = cap;
    } else {
        a->data = NULL;
        a->cap = 0;
    }
    return a;
}

PION_NOINLINE PION_MINSIZE void *pion_arr_push_flat_grow(void *a_ptr) {
    PionArray *a = (PionArray *)a_ptr;
    pion_arr_grow(a);
    return (char *)a->data + (size_t)a->len * pion_arr_stride(a);
}

PION_MINSIZE int64_t pion_arr_len(void *a_ptr) {
    if (!a_ptr) return 0;
    return ((PionArray *)a_ptr)->len;
}

PION_HOT void pion_arr_push(void *a_ptr, int64_t val) {
    PionArray *a = (PionArray *)a_ptr;
    if (__builtin_expect(a->len == a->cap, 0)) {
        pion_arr_grow(a);
    }
    if (__builtin_expect(a->elem_stride == 1, 0)) {
        ((uint8_t *)a->data)[a->len++] = (uint8_t)val;
        return;
    }
    if (a->elem_is_obj) {
        pion_adopt(a, val);
        pion_rc_inc((void *)(uintptr_t)val);
    }
    a->data[a->len++] = val;
}

void pion_arr_push_owned(void *a_ptr, int64_t val) {
    PionArray *a = (PionArray *)a_ptr;
    if (__builtin_expect(a->len == a->cap, 0)) {
        pion_arr_grow(a);
    }
    if (__builtin_expect(a->elem_stride == 1, 0)) {
        ((uint8_t *)a->data)[a->len++] = (uint8_t)val;
        return;
    }
    if (a->elem_is_obj) {
        pion_adopt(a, val);
    }
    a->data[a->len++] = val;
}

PION_MINSIZE int64_t pion_arr_get(void *a_ptr, int64_t idx) {
    PionArray *a = (PionArray *)a_ptr;
    if (!a || idx < 0 || idx >= a->len) {
        pion_die("array index out of bounds");
    }
    if (a->elem_stride == 1) {
        return (int64_t)((uint8_t *)a->data)[idx];
    }
    return a->data[idx];
}

PION_MINSIZE void pion_arr_set(void *a_ptr, int64_t idx, int64_t val) {
    PionArray *a = (PionArray *)a_ptr;
    if (!a || idx < 0 || idx >= a->len) {
        pion_die("array set index out of bounds");
    }
    if (a->elem_stride == 1) {
        ((uint8_t *)a->data)[idx] = (uint8_t)val;
        return;
    }
    if (a->elem_is_obj) {
        pion_adopt(a, val);
        pion_rc_inc((void *)(uintptr_t)val);
        pion_rc_dec((void *)(uintptr_t)a->data[idx]);
    }
    a->data[idx] = val;
}

PION_MINSIZE int64_t pion_arr_pop(void *a_ptr) {
    PionArray *a = (PionArray *)a_ptr;
    if (!a || a->len <= 0) {
        pion_die("array pop on empty array");
    }
    if (__builtin_expect(a->elem_stride == 1, 0)) {
        return (int64_t)((uint8_t *)a->data)[--a->len];
    }
    /* Transfers slot ownership to caller (no RC dec) */
    return a->data[--a->len];
}

PION_MINSIZE void *pion_arr_copy(void *a_ptr) {
    PionArray *a = (PionArray *)a_ptr;
    if (!a) return pion_arr_new(0, 0);
    int32_t flags = (a->elem_stride > 1) ? (a->elem_stride | (a->elem_is_obj << 8))
                                         : (a->elem_stride == 1 ? 2 : a->elem_is_obj);
    PionArray *cp = (PionArray *)pion_arr_new(a->len, flags);
    if (a->len > 0) {
        memcpy(cp->data, a->data, (size_t)a->len * pion_arr_stride(a));
        cp->len = a->len;
        pion_arr_foreach_obj(cp, pion_rc_inc);
    }
    return cp;
}

PION_MINSIZE void pion_arr_clear(void *a_ptr) {
    PionArray *a = (PionArray *)a_ptr;
    if (!a || a->len <= 0) return;
    pion_arr_foreach_obj(a, pion_rc_dec);
    a->len = 0;
}

PION_MINSIZE void pion_arr_reverse(void *a_ptr) {
    PionArray *a = (PionArray *)a_ptr;
    if (!a || a->len <= 1) return;
    size_t stride = pion_arr_stride(a);
    int64_t i = 0;
    int64_t j = a->len - 1;
    uint8_t tmp[64];
    uint8_t *base = (uint8_t *)a->data;
    while (i < j) {
        uint8_t *pi = base + (size_t)i * stride;
        uint8_t *pj = base + (size_t)j * stride;
        memcpy(tmp, pi, stride);
        memcpy(pi, pj, stride);
        memcpy(pj, tmp, stride);
        i++;
        j--;
    }
}

PION_MINSIZE void *pion_arr_join(void *a_ptr, void *sep_ptr) {
    PionArray *a = (PionArray *)a_ptr;
    if (!a || a->len <= 0) return pion_empty_str();
    void *sb = pion_strbuf_new(64);
    for (int64_t i = 0; i < a->len; i++) {
        if (i > 0 && sep_ptr) pion_strbuf_push_str(sb, sep_ptr);
        void *s = (void *)(uintptr_t)a->data[i];
        if (s) pion_strbuf_push_str(sb, s);
    }
    void *out = pion_strbuf_to_str(sb);
    pion_rc_dec(sb);
    return out;
}

static PION_MINSIZE int pion_cmp_i64_qsort(const void *pa, const void *pb) {
    int64_t a = *(const int64_t *)pa;
    int64_t b = *(const int64_t *)pb;
    return (a > b) - (a < b);
}

static PION_MINSIZE int pion_cmp_u8_qsort(const void *pa, const void *pb) {
    uint8_t a = *(const uint8_t *)pa;
    uint8_t b = *(const uint8_t *)pb;
    return (int)a - (int)b;
}

PION_MINSIZE void pion_arr_sort_int(void *a_ptr) {
    PionArray *a = (PionArray *)a_ptr;
    if (!a || a->len <= 1) return;
    if (a->elem_stride == 1) {
        qsort(a->data, (size_t)a->len, 1, pion_cmp_u8_qsort);
        return;
    }
    qsort(a->data, (size_t)a->len, sizeof(int64_t), pion_cmp_i64_qsort);
}

static PION_MINSIZE int pion_cmp_str_qsort(const void *pa, const void *pb) {
    void *sa = (void *)(uintptr_t)(*(const int64_t *)pa);
    void *sb = (void *)(uintptr_t)(*(const int64_t *)pb);
    return (int)pion_str_cmp(sa, sb);
}

PION_MINSIZE void pion_arr_sort_str(void *a_ptr) {
    PionArray *a = (PionArray *)a_ptr;
    if (!a || a->len <= 1) return;
    qsort(a->data, (size_t)a->len, sizeof(int64_t), pion_cmp_str_qsort);
}

/* ============================================================================
 * 5. String-Keyed Hash Map (Open Addressing, 64-bit Block Hash)
 * ============================================================================ */

static uint64_t g_pion_hash_seed = 0;
static uint64_t g_pion_hash_seed2 = 0;

static PION_NOINLINE PION_MINSIZE uint64_t pion_splitmix64(uint64_t x) {
    x += 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

static inline uint64_t pion_wymix(uint64_t a, uint64_t b) {
#if defined(_MSC_VER) && !defined(__clang__)
    uint64_t hi;
    uint64_t lo = _umul128(a, b, &hi);
    return lo ^ hi;
#else
    __uint128_t r = (__uint128_t)a * (__uint128_t)b;
    return (uint64_t)r ^ (uint64_t)(r >> 64);
#endif
}

#if defined(__GNUC__) || defined(__clang__)
static PION_MINSIZE __attribute__((constructor)) void pion_rt_init_hash_seed(void) {
    const char *env = getenv("PION_HASH_SEED");
    if (env && env[0] != '\0') {
        uint64_t s1 = (uint64_t)strtoull(env, NULL, 0);
        g_pion_hash_seed = s1;
        g_pion_hash_seed2 = pion_splitmix64(s1 ^ 0x9e3779b97f4a7c15ULL);
        return;
    }
    uint64_t seeds[2] = {0, 0};
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) || defined(__ANDROID__)
    arc4random_buf(seeds, sizeof(seeds));
#elif defined(__linux__)
    if (getrandom(seeds, sizeof(seeds), 0) != (ssize_t)sizeof(seeds)) {
        seeds[0] = (uint64_t)time(NULL) ^ ((uint64_t)getpid() << 32) ^ (uint64_t)(uintptr_t)&g_pion_hash_seed;
        seeds[1] = pion_splitmix64(seeds[0] ^ (uint64_t)(uintptr_t)&g_pion_hash_seed2);
    }
#elif defined(_WIN32)
    seeds[0] = (uint64_t)GetTickCount64() ^ ((uint64_t)GetCurrentProcessId() << 32) ^ (uint64_t)(uintptr_t)&g_pion_hash_seed;
    seeds[1] = pion_splitmix64(seeds[0] ^ (uint64_t)(uintptr_t)&g_pion_hash_seed2);
#else
    seeds[0] = (uint64_t)time(NULL) ^ (uint64_t)(uintptr_t)&g_pion_hash_seed;
    seeds[1] = pion_splitmix64(seeds[0] ^ (uint64_t)(uintptr_t)&g_pion_hash_seed2);
#endif
    g_pion_hash_seed = seeds[0];
    g_pion_hash_seed2 = seeds[1];
}
#endif

static inline uint64_t pion_str_hash(const PionString *s) {
    const unsigned char *p = (const unsigned char *)s->data;
    size_t len = (size_t)s->len;
    size_t orig_len = len;
    uint64_t s1 = g_pion_hash_seed ^ 0x517cc1b727220a95ULL;
    uint64_t s2 = g_pion_hash_seed2 ^ 0x9e3779b97f4a7c15ULL;
    uint64_t h = s1 ^ ((uint64_t)orig_len * 0x9e3779b97f4a7c15ULL);
    while (__builtin_expect(len > 8, 0)) {
        uint64_t w;
        memcpy(&w, p, 8);
        h = pion_wymix(w ^ s1, h ^ s2);
        p += 8;
        len -= 8;
    }
    uint64_t tail = 0;
    if (__builtin_expect(len >= 4, 1)) {
        uint32_t lo, hi;
        memcpy(&lo, p, 4);
        memcpy(&hi, p + len - 4, 4);
        tail = (uint64_t)lo | ((uint64_t)hi << 32);
    } else if (len >= 2) {
        uint16_t w2;
        memcpy(&w2, p, 2);
        tail = (uint64_t)w2 | ((uint64_t)p[len - 1] << 16);
    } else if (len == 1) {
        tail = (uint64_t)p[0];
    }
    h = pion_wymix(tail ^ s1, h ^ s2);
    h = pion_wymix(h ^ (uint64_t)orig_len, s2 ^ 0x94d049bb133111ebULL);
    if (!h) h = 1;
    return h;
}

/* Merged key-hash + linear-probe hot path: returns matching occupied slot or first empty slot.
 * Caller must ensure m->cap > 0, m->entries != NULL, and (m->key_is_int || k != NULL). */
static PION_NOINLINE PION_HOT PionMapEntry *pion_map_find(
    const PionMap *m, const void *k, uint64_t *out_h) {
    uint64_t h;
    if (m->key_is_int) {
        uint64_t x = (uint64_t)(uintptr_t)k;
        uint64_t s1 = g_pion_hash_seed ^ 0x517cc1b727220a95ULL;
        uint64_t s2 = g_pion_hash_seed2 ^ 0x9e3779b97f4a7c15ULL;
        h = pion_wymix(x ^ s1, s2);
        if (!h) h = 1;
    } else {
        h = pion_str_hash((const PionString *)k);
    }
    if (out_h) *out_h = h;
    uint64_t mask = (uint64_t)(m->cap - 1);
    uint64_t idx = h & mask;
    PionMapEntry *entries = m->entries;
    for (;;) {
        PionMapEntry *e = &entries[idx];
        if (e->state == 0) {
            return e;
        }
        if (m->key_is_int) {
            if (e->key == (const PionString *)k) {
                return e;
            }
        } else if (e->hash == h && pion_str_eq_fast(e->key, (const PionString *)k)) {
            return e;
        }
        idx = (idx + 1) & mask;
    }
}

static PION_NOINLINE PION_MINSIZE void pion_map_hint_invalidate(const PionMap *m) {
    if (!atomic_load_explicit(&g_pion_mt, memory_order_relaxed) && g_map_hint.map == m) {
        g_map_hint.map = NULL;
    }
}

PION_MINSIZE static void pion_map_drop(void *payload) {
    PionMap *m = (PionMap *)payload;
    pion_map_hint_invalidate(m);
    if (m->entries) {
        pion_map_foreach_obj(m, pion_rc_dec);
        pion_slab_raw_free(m->entries, (size_t)m->cap * sizeof(PionMapEntry),
                           (pion_hdr(m)->flags & PION_FLAG_FROZEN) != 0);
        m->entries = NULL;
    }
}

static PION_NOINLINE PION_MINSIZE void pion_map_grow(PionMap *m, int64_t new_cap) {
    pion_map_hint_invalidate(m);
    size_t new_bytes = (size_t)new_cap * sizeof(PionMapEntry);
    PionMapEntry *ne = (PionMapEntry *)pion_slab_raw_alloc(new_bytes);
    memset(ne, 0, new_bytes);
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
    if (m->entries) {
        pion_slab_raw_free(m->entries, (size_t)m->cap * sizeof(PionMapEntry),
                           (pion_hdr(m)->flags & PION_FLAG_FROZEN) != 0);
    }
    m->entries = ne;
    m->cap = new_cap;
}

PION_MINSIZE void *pion_map_new(int32_t val_is_obj) {
    PionMap *m = (PionMap *)pion_alloc((uint32_t)sizeof(PionMap), PION_TAG_MAP, pion_map_drop);
    m->val_is_obj = val_is_obj ? 1 : 0;
    return m;
}

PION_MINSIZE void *pion_map_new_int(int32_t val_is_obj) {
    PionMap *m = (PionMap *)pion_map_new(val_is_obj);
    m->key_is_int = 1;
    return m;
}

PION_MINSIZE int64_t pion_map_len(void *m_ptr) {
    if (!m_ptr) return 0;
    return ((PionMap *)m_ptr)->len;
}

PION_HOT void pion_map_set(void *m_ptr, void *key_str, int64_t val) {
    PionMap *m = (PionMap *)m_ptr;
    PionString *k = (PionString *)key_str;
    if (__builtin_expect(!m || (!m->key_is_int && !k), 0)) pion_die("null map or key");
    int mt = atomic_load_explicit(&g_pion_mt, memory_order_relaxed);
    PionMapEntry *e;
    uint64_t h;
    if (__builtin_expect(!mt && g_map_hint.map == m && g_map_hint.key == k, 1)) {
        e = g_map_hint.entry;
        if (__builtin_expect(e->state == 1, 1)) {
            goto update_existing;
        }
        if (__builtin_expect(m->cap > 0 && (m->len + 1) * 10 < m->cap * 7, 1)) {
            h = g_map_hint.hash;
            goto insert_new;
        }
    }
    if (__builtin_expect(m->cap == 0, 0)) {
        pion_map_grow(m, 16);
    } else if (__builtin_expect((m->len + 1) * 10 >= m->cap * 7, 0)) {
        pion_map_grow(m, m->cap * 2);
    }
    e = pion_map_find(m, k, &h);
    if (e->state == 1) {
    update_existing:
        if (m->val_is_obj) {
            pion_adopt(m, val);
            pion_rc_inc((void *)(uintptr_t)val);
            int64_t old_val = e->val;
            e->val = val;
            pion_rc_dec((void *)(uintptr_t)old_val);
        } else {
            e->val = val;
        }
        return;
    }
insert_new:
    if (!mt && g_map_hint.map == m) {
        g_map_hint.map = NULL;
    }
    if (!m->key_is_int) {
        pion_adopt(m, (int64_t)(uintptr_t)k);
        pion_rc_inc(k);
    }
    if (m->val_is_obj) {
        pion_adopt(m, val);
        pion_rc_inc((void *)(uintptr_t)val);
    }
    e->key = k;
    e->hash = h;
    e->val = val;
    e->state = 1;
    m->len++;
}

PION_HOT int32_t pion_map_try_get(void *m_ptr, void *key_str, int64_t *out_val) {
    PionMap *m = (PionMap *)m_ptr;
    PionString *k = (PionString *)key_str;
    if (__builtin_expect(!m || (!m->key_is_int && !k) || m->len == 0, 0)) return 0;
    uint64_t h;
    PionMapEntry *e = pion_map_find(m, k, &h);
    if (__builtin_expect(!atomic_load_explicit(&g_pion_mt, memory_order_relaxed), 1)) {
        g_map_hint.map = m;
        g_map_hint.key = k;
        g_map_hint.entry = e;
        g_map_hint.hash = h;
    }
    if (e->state == 1) {
        if (out_val) *out_val = e->val;
        return 1;
    }
    return 0;
}

int32_t pion_map_has(void *m_ptr, void *key_str) {
    return pion_map_try_get(m_ptr, key_str, NULL);
}

PION_HOT int64_t pion_map_get(void *m_ptr, void *key_str) {
    PionMap *m = (PionMap *)m_ptr;
    PionString *k = (PionString *)key_str;
    if (__builtin_expect(!m || (!m->key_is_int && !k) || m->len == 0, 0)) {
        pion_die("map key not found");
    }
    if (__builtin_expect(!atomic_load_explicit(&g_pion_mt, memory_order_relaxed) &&
                         g_map_hint.map == m && g_map_hint.key == k &&
                         g_map_hint.entry->state == 1, 0)) {
        return g_map_hint.entry->val;
    }
    PionMapEntry *e = pion_map_find(m, k, NULL);
    if (__builtin_expect(e->state == 1, 1)) {
        return e->val;
    }
    pion_die("map key not found");
}

PION_MINSIZE void pion_map_remove(void *m_ptr, void *key_str) {
    PionMap *m = (PionMap *)m_ptr;
    PionString *k = (PionString *)key_str;
    if (!m || (!m->key_is_int && !k) || m->len == 0 || m->cap == 0) return;
    PionMapEntry *e = pion_map_find(m, k, NULL);
    if (e->state == 0) return;
    pion_map_hint_invalidate(m);
    uint64_t mask = (uint64_t)(m->cap - 1);
    uint64_t idx = (uint64_t)(e - m->entries);
    if (!m->key_is_int) {
        pion_rc_dec(e->key);
    }
    if (m->val_is_obj) {
        pion_rc_dec((void *)(uintptr_t)e->val);
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
    memset(&m->entries[hole], 0, sizeof(PionMapEntry));
}

PION_MINSIZE void pion_map_clear(void *m_ptr) {
    PionMap *m = (PionMap *)m_ptr;
    if (!m || m->len == 0 || !m->entries) return;
    pion_map_hint_invalidate(m);
    pion_map_foreach_obj(m, pion_rc_dec);
    memset(m->entries, 0, (size_t)m->cap * sizeof(PionMapEntry));
    m->len = 0;
}

PION_MINSIZE void *pion_map_copy(void *m_ptr) {
    PionMap *m = (PionMap *)m_ptr;
    if (!m) return pion_map_new(0);
    PionMap *cp = (PionMap *)(m->key_is_int ? pion_map_new_int(m->val_is_obj) : pion_map_new(m->val_is_obj));
    if (m->cap > 0 && m->entries) {
        size_t bytes = (size_t)m->cap * sizeof(PionMapEntry);
        cp->entries = (PionMapEntry *)pion_slab_raw_alloc(bytes);
        memcpy(cp->entries, m->entries, bytes);
        cp->cap = m->cap;
        cp->len = m->len;
        pion_map_foreach_obj(cp, pion_rc_inc);
    }
    return cp;
}

PION_MINSIZE void *pion_map_keys(void *m_ptr) {
    PionMap *m = (PionMap *)m_ptr;
    int64_t n = m ? m->len : 0;
    void *arr = pion_arr_new(n, (m && m->key_is_int) ? 0 : 1);
    if (!m || !m->entries) return arr;
    for (int64_t i = 0; i < m->cap; i++) {
        if (m->entries[i].state == 1) {
            pion_arr_push(arr, (int64_t)(uintptr_t)m->entries[i].key);
        }
    }
    return arr;
}

/* ============================================================================
 * 6. Concurrency (pthread / Win32 SRWLOCK+CONDITION_VARIABLE)
 * ============================================================================ */

#ifdef _WIN32
typedef SRWLOCK pion_mu_t;
typedef CONDITION_VARIABLE pion_cv_t;
typedef HANDLE pion_thread_t;
#define pion_mu_init(m)      InitializeSRWLock(m)
#define pion_mu_destroy(m)   ((void)(m))
#define pion_mu_lock(m)      AcquireSRWLockExclusive(m)
#define pion_mu_unlock(m)    ReleaseSRWLockExclusive(m)
#define pion_cv_init(c)      InitializeConditionVariable(c)
#define pion_cv_destroy(c)   ((void)(c))
#define pion_cv_wait(c, m)   SleepConditionVariableSRW((c), (m), INFINITE, 0)
#define pion_cv_signal(c)    WakeConditionVariable(c)
#define pion_cv_broadcast(c) WakeAllConditionVariable(c)
#else
typedef pthread_mutex_t pion_mu_t;
typedef pthread_cond_t pion_cv_t;
typedef pthread_t pion_thread_t;
#define pion_mu_init(m)      pthread_mutex_init((m), NULL)
#define pion_mu_destroy(m)   pthread_mutex_destroy(m)
#define pion_mu_lock(m)      pthread_mutex_lock(m)
#define pion_mu_unlock(m)    pthread_mutex_unlock(m)
#define pion_cv_init(c)      pthread_cond_init((c), NULL)
#define pion_cv_destroy(c)   pthread_cond_destroy(c)
#define pion_cv_wait(c, m)   pthread_cond_wait((c), (m))
#define pion_cv_signal(c)    pthread_cond_signal(c)
#define pion_cv_broadcast(c) pthread_cond_broadcast(c)
#endif

typedef struct PionScope {
    pion_mu_t mu;
    pion_thread_t *threads;
    size_t len;
    size_t cap;
} PionScope;

typedef struct PionSpawnTask {
    void (*fn)(void *env);
    void *env;
} PionSpawnTask;

#ifdef _WIN32
static unsigned __stdcall pion_spawn_trampoline(void *arg) {
    PionSpawnTask *task = (PionSpawnTask *)arg;
    void (*fn)(void *) = task->fn;
    void *env = task->env;
    free(task);
    fn(env);
    if (env) {
        pion_rc_dec(env);
    }
    return 0;
}
#else
static PION_COLD PION_MINSIZE void *pion_spawn_trampoline(void *arg) {
    PionSpawnTask *task = (PionSpawnTask *)arg;
    void (*fn)(void *) = task->fn;
    void *env = task->env;
    free(task);
    fn(env);
    if (env) {
        pion_rc_dec(env);
    }
    return NULL;
}
#endif

PION_MINSIZE static void pion_scope_drop(void *payload) {
    PionScope *s = (PionScope *)payload;
    pion_mu_destroy(&s->mu);
    free(s->threads);
    s->threads = NULL;
}

PION_MINSIZE void *pion_scope_begin(void) {
    PionScope *s = (PionScope *)pion_alloc((uint32_t)sizeof(PionScope), PION_TAG_SCOPE, pion_scope_drop);
    pion_mu_init(&s->mu);
    pion_rc_freeze(s);
    return s;
}

PION_MINSIZE void pion_scope_spawn(void *scope_ptr, void (*fn)(void *env), void *env) {
    pion_enter_mt();
    PionScope *s = (PionScope *)scope_ptr;
    if (!s || !fn) pion_die("invalid scope_spawn");
    if (env) {
        pion_rc_freeze(env);
        pion_rc_inc(env);
    }
    PionSpawnTask *task = (PionSpawnTask *)malloc(sizeof(PionSpawnTask));
    if (!task) pion_oom();
    task->fn = fn;
    task->env = env;

    pion_thread_t th;
#ifdef _WIN32
    uintptr_t h = _beginthreadex(NULL, 8u * 1024u * 1024u, pion_spawn_trampoline, task, 0, NULL);
    if (h == 0) pion_die("_beginthreadex failed");
    th = (HANDLE)h;
#else
    if (pthread_create(&th, NULL, pion_spawn_trampoline, task) != 0) pion_die("pthread_create failed");
#endif

    pion_mu_lock(&s->mu);
    if (s->len == s->cap) {
        size_t ncap = s->cap > 0 ? s->cap * 2 : 8;
        pion_thread_t *nt = (pion_thread_t *)realloc(s->threads, ncap * sizeof(pion_thread_t));
        if (!nt) pion_oom();
        s->threads = nt;
        s->cap = ncap;
    }
    s->threads[s->len++] = th;
    pion_mu_unlock(&s->mu);
}

PION_MINSIZE void pion_scope_end(void *scope_ptr) {
    PionScope *s = (PionScope *)scope_ptr;
    if (!s) return;
    for (;;) {
        pion_mu_lock(&s->mu);
        if (s->len == 0) {
            pion_mu_unlock(&s->mu);
            break;
        }
        pion_thread_t *batch = s->threads;
        size_t n = s->len;
        s->threads = NULL;
        s->len = 0;
        s->cap = 0;
        pion_mu_unlock(&s->mu);
        for (size_t i = 0; i < n; i++) {
#ifdef _WIN32
            WaitForSingleObject(batch[i], INFINITE);
            CloseHandle(batch[i]);
#else
            pthread_join(batch[i], NULL);
#endif
        }
        free(batch);
    }
    pion_rc_dec(s);
}

/* Channel */
typedef struct PionChannel {
    pion_mu_t mu;
    pion_cv_t not_empty;
    pion_cv_t not_full;
    int64_t *buf;
    int64_t cap;
    int64_t head;
    int64_t count;
    int32_t bounded;
    int32_t closed;
    int32_t elem_is_obj;
    int32_t recv_waiters;
    int32_t send_waiters;
} PionChannel;

PION_MINSIZE static void pion_chan_drop(void *payload) {
    PionChannel *c = (PionChannel *)payload;
    if (c->elem_is_obj && c->buf) {
        for (int64_t i = 0; i < c->count; i++) {
            int64_t pos = (c->head + i) % c->cap;
            pion_rc_dec((void *)(uintptr_t)c->buf[pos]);
        }
    }
    free(c->buf);
    pion_cv_destroy(&c->not_empty);
    pion_cv_destroy(&c->not_full);
    pion_mu_destroy(&c->mu);
}

PION_MINSIZE void *pion_chan_new(int64_t cap, int32_t elem_is_obj) {
    PionChannel *c = (PionChannel *)pion_alloc((uint32_t)sizeof(PionChannel), PION_TAG_CHANNEL, pion_chan_drop);
    pion_mu_init(&c->mu);
    pion_cv_init(&c->not_empty);
    pion_cv_init(&c->not_full);
    c->bounded = cap > 0 ? 1 : 0;
    c->cap = cap > 0 ? cap : 16;
    c->buf = (int64_t *)malloc((size_t)c->cap * sizeof(int64_t));
    if (!c->buf) pion_oom();
    c->elem_is_obj = elem_is_obj ? 1 : 0;
    pion_rc_freeze(c);
    return c;
}

PION_COLD PION_MINSIZE int32_t pion_chan_send(void *ch_ptr, int64_t val) {
    PionChannel *c = (PionChannel *)ch_ptr;
    if (c->elem_is_obj && val != 0) {
        pion_rc_freeze((void *)(uintptr_t)val);
    }
    pion_mu_lock(&c->mu);
    while (c->bounded && c->count == c->cap && !c->closed) {
        c->send_waiters++;
        pion_cv_wait(&c->not_full, &c->mu);
        c->send_waiters--;
    }
    if (__builtin_expect(c->closed, 0)) {
        pion_mu_unlock(&c->mu);
        return 0;
    }
    if (__builtin_expect(!c->bounded && c->count == c->cap, 0)) {
        int64_t ncap = c->cap * 2;
        int64_t *nb = (int64_t *)malloc((size_t)ncap * sizeof(int64_t));
        if (!nb) pion_oom();
        for (int64_t i = 0; i < c->count; i++) {
            nb[i] = c->buf[(c->head + i) % c->cap];
        }
        free(c->buf);
        c->buf = nb;
        c->head = 0;
        c->cap = ncap;
    }
    if (c->elem_is_obj && val != 0) {
        pion_rc_inc((void *)(uintptr_t)val);
    }
    c->buf[(c->head + c->count) % c->cap] = val;
    c->count++;
    if (c->recv_waiters > 0) {
        pion_cv_signal(&c->not_empty);
    }
    pion_mu_unlock(&c->mu);
    return 1;
}

PION_COLD PION_MINSIZE int32_t pion_chan_recv(void *ch_ptr, int64_t *out_val) {
    PionChannel *c = (PionChannel *)ch_ptr;
    pion_mu_lock(&c->mu);
    while (c->count == 0 && !c->closed) {
        c->recv_waiters++;
        pion_cv_wait(&c->not_empty, &c->mu);
        c->recv_waiters--;
    }
    if (__builtin_expect(c->count == 0 && c->closed, 0)) {
        pion_mu_unlock(&c->mu);
        return 0;
    }
    int64_t v = c->buf[c->head];
    if (++c->head == c->cap) c->head = 0;
    c->count--;
    if (c->send_waiters > 0) {
        pion_cv_signal(&c->not_full);
    }
    pion_mu_unlock(&c->mu);
    if (out_val) *out_val = v;
    return 1;
}

PION_MINSIZE void pion_chan_close(void *ch_ptr) {
    PionChannel *c = (PionChannel *)ch_ptr;
    pion_mu_lock(&c->mu);
    c->closed = 1;
    pion_cv_broadcast(&c->not_empty);
    pion_cv_broadcast(&c->not_full);
    pion_mu_unlock(&c->mu);
}

/* Mutex */
typedef struct PionMutex {
    pion_mu_t mu;
    int64_t val;
    int32_t val_is_obj;
} PionMutex;

PION_MINSIZE static void pion_mutex_drop(void *payload) {
    PionMutex *m = (PionMutex *)payload;
    if (m->val_is_obj && m->val != 0) {
        pion_rc_dec((void *)(uintptr_t)m->val);
    }
    pion_mu_destroy(&m->mu);
}

PION_MINSIZE void *pion_mutex_new(int64_t init_val, int32_t val_is_obj) {
    PionMutex *m = (PionMutex *)pion_alloc((uint32_t)sizeof(PionMutex), PION_TAG_MUTEX, pion_mutex_drop);
    pion_mu_init(&m->mu);
    m->val_is_obj = val_is_obj ? 1 : 0;
    if (m->val_is_obj && init_val != 0) {
        pion_rc_freeze((void *)(uintptr_t)init_val);
        pion_rc_inc((void *)(uintptr_t)init_val);
    }
    m->val = init_val;
    pion_rc_freeze(m);
    return m;
}

PION_MINSIZE int64_t pion_mutex_lock(void *m_ptr) {
    PionMutex *m = (PionMutex *)m_ptr;
    pion_mu_lock(&m->mu);
    return m->val;
}

PION_MINSIZE void pion_mutex_set(void *m_ptr, int64_t new_val) {
    PionMutex *m = (PionMutex *)m_ptr;
    int64_t old_val = 0;
    if (m->val_is_obj) {
        if (new_val != 0) {
            pion_rc_freeze((void *)(uintptr_t)new_val);
            pion_rc_inc((void *)(uintptr_t)new_val);
        }
        old_val = m->val;
    }
    m->val = new_val;
    if (m->val_is_obj && old_val != 0) {
        pion_rc_dec((void *)(uintptr_t)old_val);
    }
}

PION_MINSIZE void pion_mutex_set_and_unlock(void *m_ptr, int64_t new_val) {
    PionMutex *m = (PionMutex *)m_ptr;
    int64_t old_val = 0;
    if (m->val_is_obj) {
        if (new_val != 0) {
            pion_rc_freeze((void *)(uintptr_t)new_val);
            pion_rc_inc((void *)(uintptr_t)new_val);
        }
        old_val = m->val;
    }
    m->val = new_val;
    pion_mu_unlock(&m->mu);
    if (m->val_is_obj && old_val != 0) {
        pion_rc_dec((void *)(uintptr_t)old_val);
    }
}

PION_MINSIZE void pion_mutex_unlock(void *m_ptr) {
    PionMutex *m = (PionMutex *)m_ptr;
    pion_mu_unlock(&m->mu);
}

/* AtomicInt */
typedef struct PionAtomic {
    _Atomic int64_t val;
} PionAtomic;

PION_MINSIZE void *pion_atomic_new(int64_t init_val) {
    PionAtomic *a = (PionAtomic *)pion_alloc((uint32_t)sizeof(PionAtomic), PION_TAG_ATOMIC, NULL);
    atomic_init(&a->val, init_val);
    pion_rc_freeze(a);
    return a;
}

PION_MINSIZE int64_t pion_atomic_load(void *a_ptr) {
    return atomic_load_explicit(&((PionAtomic *)a_ptr)->val, memory_order_seq_cst);
}

PION_MINSIZE void pion_atomic_store(void *a_ptr, int64_t val) {
    atomic_store_explicit(&((PionAtomic *)a_ptr)->val, val, memory_order_seq_cst);
}

PION_MINSIZE int64_t pion_atomic_fetch_add(void *a_ptr, int64_t delta) {
    return atomic_fetch_add_explicit(&((PionAtomic *)a_ptr)->val, delta, memory_order_seq_cst);
}

/* ============================================================================
 * 7. World Capabilities & Pure C SHA-256
 * ============================================================================ */

typedef struct PionWorld {
    int argc;
    char **argv;
} PionWorld;

PION_MINSIZE void *pion_world_init(int argc, char **argv) {
    PionWorld *w = (PionWorld *)pion_alloc((uint32_t)sizeof(PionWorld), PION_TAG_WORLD, NULL);
    w->argc = argc;
    w->argv = argv;
    pion_rc_freeze(w);
    return w;
}

PION_MINSIZE int64_t pion_world_argc(void *w_ptr) {
    PionWorld *w = (PionWorld *)w_ptr;
    return w ? (int64_t)w->argc : 0;
}

PION_MINSIZE void *pion_world_argv(void *w_ptr, int64_t idx) {
    PionWorld *w = (PionWorld *)w_ptr;
    if (!w || idx < 0 || idx >= w->argc) {
        pion_die("argv index out of bounds");
    }
    const char *arg = w->argv[idx] ? w->argv[idx] : "";
    return pion_str_from_cstr(arg, (int64_t)strlen(arg));
}

PION_MINSIZE void *pion_world_args(void *w_ptr) {
    PionWorld *w = (PionWorld *)w_ptr;
    int64_t n = w ? (int64_t)w->argc : 0;
    void *arr = pion_arr_new(n, 1);
    for (int64_t i = 0; i < n; i++) {
        pion_arr_push_owned(arr, (int64_t)(uintptr_t)pion_world_argv(w_ptr, i));
    }
    return arr;
}

static PION_NOINLINE PION_MINSIZE void pion_write_stream(FILE *f, void *s_ptr, int nl) {
    PionString *s = (PionString *)s_ptr;
    if (s && s->len > 0) fwrite(s->data, 1, (size_t)s->len, f);
    if (nl) fputc('\n', f);
    fflush(f);
}

PION_MINSIZE void pion_world_print(void *w_ptr, void *s_ptr) {
    (void)w_ptr;
    pion_write_stream(stdout, s_ptr, 0);
}

PION_MINSIZE void pion_world_println(void *w_ptr, void *s_ptr) {
    (void)w_ptr;
    pion_write_stream(stdout, s_ptr, 1);
}

PION_MINSIZE void pion_world_eprintln(void *w_ptr, void *s_ptr) {
    (void)w_ptr;
    pion_write_stream(stderr, s_ptr, 1);
}

PION_MINSIZE void *pion_world_read_line(void *w_ptr, int32_t *ok_out) {
    (void)w_ptr;
#ifdef _WIN32
    size_t cap = 128;
    size_t len = 0;
    char *line = (char *)malloc(cap);
    if (!line) {
        if (ok_out) *ok_out = 0;
        return pion_empty_str();
    }
    int ch;
    while ((ch = fgetc(stdin)) != EOF) {
        if (len + 1 >= cap) {
            cap *= 2;
            char *nl = (char *)realloc(line, cap);
            if (!nl) {
                free(line);
                if (ok_out) *ok_out = 0;
                return pion_empty_str();
            }
            line = nl;
        }
        line[len++] = (char)ch;
        if (ch == '\n') break;
    }
    if (len == 0 && ch == EOF) {
        free(line);
        if (ok_out) *ok_out = 0;
        return pion_empty_str();
    }
    if (len > 0 && line[len - 1] == '\n') len--;
    if (len > 0 && line[len - 1] == '\r') len--;
    void *out = pion_str_from_cstr(line, (int64_t)len);
    free(line);
    if (ok_out) *ok_out = 1;
    return out;
#else
    char *line = NULL;
    size_t cap = 0;
    ssize_t n = getline(&line, &cap, stdin);
    if (ok_out) *ok_out = (n >= 0);
    if (n < 0) {
        free(line);
        return pion_empty_str();
    }
    if (n > 0 && line[n - 1] == '\n') n--;
    if (n > 0 && line[n - 1] == '\r') n--;
    void *out = pion_str_from_cstr(line, (int64_t)n);
    free(line);
    return out;
#endif
}

static PION_NOINLINE PION_MINSIZE void *pion_read_file_obj(void *path_str, int as_bytes, int32_t *ok_out) {
    if (ok_out) *ok_out = 0;
    PionString *path = (PionString *)path_str;
    FILE *f = path ? fopen(path->data, "rb") : NULL;
    char *buf = NULL;
    long sz = -1;
    if (f) {
        if (fseek(f, 0, SEEK_END) == 0 && (sz = ftell(f)) >= 0 && fseek(f, 0, SEEK_SET) == 0) {
            buf = (char *)malloc((size_t)sz + 1);
            if (buf && sz > 0 && fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
                free(buf);
                buf = NULL;
            }
        }
        fclose(f);
    }
    if (!buf) return as_bytes ? pion_bytes_alloc_uninit(0) : pion_empty_str();
    void *out = as_bytes ? pion_bytes_from_ptr(buf, (int64_t)sz) : pion_str_from_cstr(buf, (int64_t)sz);
    free(buf);
    if (ok_out) *ok_out = 1;
    return out;
}

PION_MINSIZE void *pion_world_fs_read(void *w_ptr, void *path_str, int32_t *ok_out) {
    (void)w_ptr;
    return pion_read_file_obj(path_str, 0, ok_out);
}

static PION_NOINLINE PION_MINSIZE int32_t pion_write_file_raw(void *path_str, const char *mode,
                                                const void *data, int64_t len) {
    PionString *path = (PionString *)path_str;
    if (!path) return 0;
    FILE *f = fopen(path->data, mode);
    if (!f) return 0;
    size_t written = len > 0 ? fwrite(data, 1, (size_t)len, f) : 0;
    return (fclose(f) == 0 && written == (size_t)len) ? 1 : 0;
}

PION_MINSIZE int32_t pion_world_fs_write(void *w_ptr, void *path_str, void *content_str) {
    (void)w_ptr;
    PionString *c = (PionString *)content_str;
    return c ? pion_write_file_raw(path_str, "wb", c->data, c->len) : 0;
}

PION_MINSIZE void *pion_world_fs_read_bytes(void *w_ptr, void *path_str, int32_t *ok_out) {
    (void)w_ptr;
    return pion_read_file_obj(path_str, 1, ok_out);
}

PION_MINSIZE int32_t pion_world_fs_write_bytes(void *w_ptr, void *path_str, void *bytes_obj) {
    (void)w_ptr;
    PionBytes *b = (PionBytes *)bytes_obj;
    return b ? pion_write_file_raw(path_str, "wb", b->data, b->len) : 0;
}

PION_MINSIZE int32_t pion_world_fs_append(void *w_ptr, void *path_str, void *content_str) {
    (void)w_ptr;
    PionString *c = (PionString *)content_str;
    return c ? pion_write_file_raw(path_str, "ab", c->data, c->len) : 0;
}

#ifdef _WIN32
PION_MINSIZE static int64_t pion_win_filetime_to_ms(FILETIME ft) {
    uint64_t t = ((uint64_t)ft.dwHighDateTime << 32) | (uint64_t)ft.dwLowDateTime;
    return (int64_t)((t - 116444736000000000ULL) / 10000ULL);
}
#endif

#ifndef _WIN32
static PION_NOINLINE PION_MINSIZE int pion_stat_path(void *path_str, struct stat *st) {
    PionString *path = (PionString *)path_str;
    return path && path->len > 0 && stat(path->data, st) == 0;
}

static inline int64_t pion_stat_mtime_ms(const struct stat *st) {
#if defined(__APPLE__) && defined(_POSIX_C_SOURCE) && !defined(_DARWIN_C_SOURCE)
    return (int64_t)st->st_mtime * 1000 + (int64_t)(st->st_mtimensec / 1000000);
#elif defined(__APPLE__)
    return (int64_t)st->st_mtimespec.tv_sec * 1000 + (int64_t)(st->st_mtimespec.tv_nsec / 1000000);
#else
    return (int64_t)st->st_mtim.tv_sec * 1000 + (int64_t)(st->st_mtim.tv_nsec / 1000000);
#endif
}
#endif

PION_MINSIZE int64_t pion_world_fs_mtime_ms(void *w_ptr, void *path_str) {
    (void)w_ptr;
#ifdef _WIN32
    PionString *path = (PionString *)path_str;
    if (!path || path->len == 0) return -1;
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExA(path->data, GetFileExInfoStandard, &fad)) return -1;
    return pion_win_filetime_to_ms(fad.ftLastWriteTime);
#else
    struct stat st;
    return pion_stat_path(path_str, &st) ? pion_stat_mtime_ms(&st) : -1;
#endif
}

PION_MINSIZE int32_t pion_world_fs_exists(void *w_ptr, void *path_str) {
    (void)w_ptr;
    PionString *path = (PionString *)path_str;
    if (!path) return 0;
#ifdef _WIN32
    return GetFileAttributesA(path->data) != INVALID_FILE_ATTRIBUTES ? 1 : 0;
#else
    return access(path->data, F_OK) == 0 ? 1 : 0;
#endif
}

PION_MINSIZE int32_t pion_world_fs_is_dir(void *w_ptr, void *path_str) {
    (void)w_ptr;
#ifdef _WIN32
    PionString *path = (PionString *)path_str;
    if (!path || path->len == 0) return 0;
    DWORD attr = GetFileAttributesA(path->data);
    return (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY)) ? 1 : 0;
#else
    struct stat st;
    return pion_stat_path(path_str, &st) && S_ISDIR(st.st_mode) ? 1 : 0;
#endif
}

PION_MINSIZE int32_t pion_world_fs_mkdir_p(void *w_ptr, void *path_str) {
    (void)w_ptr;
    PionString *path = (PionString *)path_str;
    if (!path || path->len == 0) return 0;
    char *tmp = (char *)malloc((size_t)path->len + 1);
    if (!tmp) return 0;
    memcpy(tmp, path->data, (size_t)path->len + 1);
    size_t len = (size_t)path->len;
#ifdef _WIN32
    while (len > 1 && (tmp[len - 1] == '/' || tmp[len - 1] == '\\')) {
        if (len == 3 && tmp[1] == ':') break;
        tmp[--len] = '\0';
    }
    size_t start = (len >= 2 && tmp[1] == ':') ? 3u : 1u;
    for (size_t i = start; i < len; i++) {
        if (tmp[i] == '/' || tmp[i] == '\\') {
            char saved = tmp[i];
            tmp[i] = '\0';
            if (_mkdir(tmp) != 0 && errno != EEXIST) {
                free(tmp);
                return 0;
            }
            tmp[i] = saved;
        }
    }
    int ok = 1;
    if (_mkdir(tmp) != 0) {
        DWORD attr = GetFileAttributesA(tmp);
        if (errno != EEXIST || attr == INVALID_FILE_ATTRIBUTES || !(attr & FILE_ATTRIBUTE_DIRECTORY)) {
            ok = 0;
        }
    }
#else
    while (len > 1 && tmp[len - 1] == '/') {
        tmp[--len] = '\0';
    }
    int ok = 1;
    for (char *p = tmp + 1; ; p++) {
        if (*p == '/' || *p == '\0') {
            char sv = *p;
            *p = '\0';
            if (mkdir(tmp, 0755) != 0) {
                struct stat st;
                if (errno != EEXIST || (sv == '\0' && (stat(tmp, &st) != 0 || !S_ISDIR(st.st_mode)))) {
                    ok = 0;
                    break;
                }
            }
            *p = sv;
            if (!sv) break;
        }
    }
#endif
    free(tmp);
    return ok;
}

PION_MINSIZE static int pion_str_slot_cmp(const void *a, const void *b) {
    void *sa = (void *)(uintptr_t)(*(const int64_t *)a);
    void *sb = (void *)(uintptr_t)(*(const int64_t *)b);
    return (int)pion_str_cmp(sa, sb);
}

PION_MINSIZE void *pion_world_fs_list_dir(void *w_ptr, void *path_str) {
    (void)w_ptr;
    PionString *path = (PionString *)path_str;
    void *arr = pion_arr_new(8, 1);
    if (!path) return arr;
#ifdef _WIN32
    size_t plen = (size_t)path->len;
    char *pat = (char *)malloc(plen + 3);
    if (!pat) return arr;
    memcpy(pat, path->data, plen);
    if (plen > 0 && pat[plen - 1] != '/' && pat[plen - 1] != '\\') {
        pat[plen++] = '\\';
    }
    pat[plen++] = '*';
    pat[plen] = '\0';
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pat, &fd);
    free(pat);
    if (h == INVALID_HANDLE_VALUE) return arr;
    do {
        if (strcmp(fd.cFileName, ".") == 0 || strcmp(fd.cFileName, "..") == 0) {
            continue;
        }
        void *name = pion_str_from_cstr(fd.cFileName, (int64_t)strlen(fd.cFileName));
        pion_arr_push(arr, (int64_t)(uintptr_t)name);
        pion_rc_dec(name);
    } while (FindNextFileA(h, &fd));
    FindClose(h);
#else
    DIR *d = opendir(path->data);
    if (!d) return arr;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        const char *dn = ent->d_name;
        if (dn[0] == '.' && (dn[1] == '\0' || (dn[1] == '.' && dn[2] == '\0'))) {
            continue;
        }
        pion_arr_push_owned(arr, (int64_t)(uintptr_t)pion_str_from_cstr(dn, (int64_t)strlen(dn)));
    }
    closedir(d);
#endif
    PionArray *a = (PionArray *)arr;
    if (a->len > 1) {
        qsort(a->data, (size_t)a->len, sizeof(int64_t), pion_str_slot_cmp);
    }
    return arr;
}

PION_MINSIZE int32_t pion_world_fs_remove(void *w_ptr, void *path_str) {
    (void)w_ptr;
    PionString *path = (PionString *)path_str;
    if (!path || path->len == 0) return 0;
#ifdef _WIN32
    return DeleteFileA(path->data) != 0 ? 1 : 0;
#else
    return unlink(path->data) == 0 ? 1 : 0;
#endif
}

PION_MINSIZE int32_t pion_world_fs_rename(void *w_ptr, void *old_path, void *new_path) {
    (void)w_ptr;
    PionString *op = (PionString *)old_path;
    PionString *np = (PionString *)new_path;
    if (!op || !np || op->len == 0 || np->len == 0) return 0;
#ifdef _WIN32
    return MoveFileExA(op->data, np->data, MOVEFILE_REPLACE_EXISTING) != 0 ? 1 : 0;
#else
    return rename(op->data, np->data) == 0 ? 1 : 0;
#endif
}

PION_MINSIZE int64_t pion_world_fs_size(void *w_ptr, void *path_str) {
    (void)w_ptr;
#ifdef _WIN32
    PionString *path = (PionString *)path_str;
    if (!path || path->len == 0) return -1;
    struct __stat64 st;
    if (_stat64(path->data, &st) != 0) return -1;
    return (int64_t)st.st_size;
#else
    struct stat st;
    return pion_stat_path(path_str, &st) ? (int64_t)st.st_size : -1;
#endif
}

static PION_NOINLINE PION_MINSIZE void *pion_errno_str(int err) {
    char errbuf[96];
#ifdef _WIN32
    if (strerror_s(errbuf, sizeof(errbuf), err) != 0) {
        snprintf(errbuf, sizeof(errbuf), "errno %d", err);
    }
#else
    if (strerror_r(err, errbuf, sizeof(errbuf)) != 0) {
        snprintf(errbuf, sizeof(errbuf), "errno %d", err);
    }
#endif
    return pion_str_from_cstr(errbuf, (int64_t)strlen(errbuf));
}

PION_MINSIZE void *pion_world_fs_lstat(void *w_ptr, void *path_str, int32_t *ok_out) {
    (void)w_ptr;
    if (ok_out) *ok_out = 0;
    PionString *path = (PionString *)path_str;
    if (!path || path->len == 0) return pion_errno_str(EINVAL);
#ifdef _WIN32
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExA(path->data, GetFileExInfoStandard, &fad)) {
        return pion_errno_str(ENOENT);
    }
    const char *kind = (fad.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ? "link"
                     : (fad.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? "dir"
                     : "file";
    int64_t fsz = ((int64_t)fad.nFileSizeHigh << 32) | (int64_t)fad.nFileSizeLow;
    int64_t mtime_ms = pion_win_filetime_to_ms(fad.ftLastWriteTime);
    char buf[128];
    int n = snprintf(buf, sizeof(buf), "%s|%lld|0|%lld|0",
                     kind, (long long)fsz, (long long)mtime_ms);
    if (ok_out) *ok_out = 1;
    return pion_str_from_cstr(buf, n > 0 ? (int64_t)n : 0);
#else
    struct stat st;
    if (lstat(path->data, &st) != 0) return pion_errno_str(errno);
    const char *kind = S_ISREG(st.st_mode) ? "file"
                     : S_ISDIR(st.st_mode) ? "dir"
                     : S_ISLNK(st.st_mode) ? "link"
                     : "other";
    char buf[128];
    int n = snprintf(buf, sizeof(buf), "%s|%lld|%d|%lld|%lld",
                     kind, (long long)st.st_size, (st.st_mode & 0111) != 0,
                     (long long)pion_stat_mtime_ms(&st), (long long)st.st_dev);
    if (ok_out) *ok_out = 1;
    return pion_str_from_cstr(buf, n > 0 ? (int64_t)n : 0);
#endif
}

PION_MINSIZE void *pion_world_fs_readlink(void *w_ptr, void *path_str, int32_t *ok_out) {
    (void)w_ptr;
    if (ok_out) *ok_out = 0;
#ifdef _WIN32
    (void)path_str;
    return pion_errno_str(ENOSYS);
#else
    PionString *path = (PionString *)path_str;
    int err = EINVAL;
    char *buf = NULL;
    if (path && path->len > 0) {
        for (size_t cap = 256; ; cap *= 2) {
            char *nb = (char *)realloc(buf, cap);
            if (!nb) { err = ENOMEM; break; }
            buf = nb;
            ssize_t n = readlink(path->data, buf, cap);
            if (n < 0) { err = errno; break; }
            if ((size_t)n < cap) {
                void *out = pion_str_from_cstr(buf, (int64_t)n);
                free(buf);
                if (ok_out) *ok_out = 1;
                return out;
            }
            if (cap >= (1u << 20)) { err = ENAMETOOLONG; break; }
        }
    }
    free(buf);
    return pion_errno_str(err);
#endif
}

PION_MINSIZE int32_t pion_world_fs_symlink(void *w_ptr, void *target_str, void *linkpath_str) {
    (void)w_ptr;
    PionString *target = (PionString *)target_str;
    PionString *linkpath = (PionString *)linkpath_str;
    if (!target || !linkpath || target->len == 0 || linkpath->len == 0) return 0;
#ifdef _WIN32
    return 0;
#else
    return symlink(target->data, linkpath->data) == 0 ? 1 : 0;
#endif
}

PION_MINSIZE int32_t pion_world_fs_chmod(void *w_ptr, void *path_str, int32_t mode) {
    (void)w_ptr;
    PionString *path = (PionString *)path_str;
    if (!path || path->len == 0) return 0;
#ifdef _WIN32
    return _chmod(path->data, (mode & 0200) ? (_S_IREAD | _S_IWRITE) : _S_IREAD) == 0 ? 1 : 0;
#else
    return chmod(path->data, (mode_t)mode) == 0 ? 1 : 0;
#endif
}

#ifndef _WIN32
static inline int pion_stat_is_reg_size(const struct stat *st, int64_t expected_size) {
    return S_ISREG(st->st_mode) && (int64_t)st->st_size == expected_size;
}
#endif

PION_MINSIZE void *pion_world_fs_read_range_nofollow(void *w_ptr, void *path_str,
                                                     int64_t offset, int64_t length,
                                                     int64_t expected_size, int32_t *ok_out) {
    (void)w_ptr;
    if (ok_out) *ok_out = 0;
    PionString *path = (PionString *)path_str;
    PionBytes *out = NULL;
#ifdef _WIN32
    if (!path || path->len == 0 || offset < 0 || length < 0 || expected_size < 0 ||
        offset > expected_size || length > expected_size - offset) {
        return pion_str_from_cstr("changed", 7);
    }
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExA(path->data, GetFileExInfoStandard, &fad) ||
        (fad.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
        return pion_str_from_cstr("changed", 7);
    }
    int64_t fsz = ((int64_t)fad.nFileSizeHigh << 32) | (int64_t)fad.nFileSizeLow;
    if (fsz != expected_size) return pion_str_from_cstr("changed", 7);
    HANDLE h = CreateFileA(path->data, GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (h == INVALID_HANDLE_VALUE) return pion_str_from_cstr("changed", 7);
    LARGE_INTEGER li_sz;
    LARGE_INTEGER li_off;
    li_off.QuadPart = offset;
    if (!GetFileSizeEx(h, &li_sz) || li_sz.QuadPart != expected_size ||
        !SetFilePointerEx(h, li_off, NULL, FILE_BEGIN)) {
        CloseHandle(h);
        return pion_str_from_cstr("changed", 7);
    }
    out = pion_bytes_alloc_uninit(length);
    for (int64_t got = 0; got < length; ) {
        DWORD chunk = (length - got) > 0x7fffffffLL ? 0x7fffffffu : (DWORD)(length - got);
        DWORD n = 0;
        if (!ReadFile(h, out->data + got, chunk, &n, NULL) || n == 0) {
            CloseHandle(h);
            pion_rc_dec(out);
            return pion_str_from_cstr("changed", 7);
        }
        got += (int64_t)n;
    }
    CloseHandle(h);
    if (ok_out) *ok_out = 1;
    return out;
#else
    int fd = -1;
    struct stat st;
    if (!path || path->len == 0 || offset < 0 || length < 0 || expected_size < 0 ||
        offset > expected_size || length > expected_size - offset ||
        lstat(path->data, &st) != 0 || !pion_stat_is_reg_size(&st, expected_size)) {
        goto changed;
    }
    fd = open(path->data, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0 || fstat(fd, &st) != 0 || !pion_stat_is_reg_size(&st, expected_size)) {
        goto changed;
    }
    out = pion_bytes_alloc_uninit(length);
    for (int64_t got = 0; got < length; ) {
        ssize_t n = pread(fd, out->data + got, (size_t)(length - got), (off_t)(offset + got));
        if (n > 0) {
            got += (int64_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            goto changed;
        }
    }
    close(fd);
    if (ok_out) *ok_out = 1;
    return out;
changed:
    if (fd >= 0) close(fd);
    if (out) pion_rc_dec(out);
    return pion_str_from_cstr("changed", 7);
#endif
}

PION_MINSIZE void *pion_world_env_get(void *w_ptr, void *name_str, int32_t *ok_out) {
    (void)w_ptr;
    if (ok_out) *ok_out = 0;
    PionString *name = (PionString *)name_str;
    const char *v = name ? getenv(name->data) : NULL;
    if (!v) return pion_empty_str();
    if (ok_out) *ok_out = 1;
    return pion_str_from_cstr(v, (int64_t)strlen(v));
}

PION_MINSIZE int64_t pion_world_clock_ms(void *w_ptr) {
    (void)w_ptr;
#ifdef _WIN32
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    return pion_win_filetime_to_ms(ft);
#else
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
#endif
}

#ifdef _WIN32
PION_MINSIZE static void pion_win_sb_append(char **buf, size_t *len, size_t *cap, char ch) {
    if (*len + 2 > *cap) {
        size_t ncap = (*cap == 0) ? 256u : (*cap * 2u);
        char *nb = (char *)realloc(*buf, ncap);
        if (!nb) pion_oom();
        *buf = nb;
        *cap = ncap;
    }
    (*buf)[(*len)++] = ch;
    (*buf)[*len] = '\0';
}

PION_MINSIZE static char *pion_win_build_cmdline(PionArray *arr) {
    char *buf = NULL;
    size_t len = 0;
    size_t cap = 0;
    for (int64_t i = 0; i < arr->len; i++) {
        if (i > 0) pion_win_sb_append(&buf, &len, &cap, ' ');
        PionString *s = (PionString *)(uintptr_t)arr->data[i];
        const char *arg = s ? s->data : "";
        size_t alen = s ? (size_t)s->len : 0u;
        int need_q = (alen == 0);
        for (size_t j = 0; j < alen && !need_q; j++) {
            char c = arg[j];
            if (c == ' ' || c == '\t' || c == '"' || c == '\n' || c == '\r') need_q = 1;
        }
        if (!need_q) {
            for (size_t j = 0; j < alen; j++) pion_win_sb_append(&buf, &len, &cap, arg[j]);
            continue;
        }
        pion_win_sb_append(&buf, &len, &cap, '"');
        size_t bs = 0;
        for (size_t j = 0; j < alen; j++) {
            if (arg[j] == '\\') {
                bs++;
            } else if (arg[j] == '"') {
                for (size_t k = 0; k < bs * 2 + 1; k++) pion_win_sb_append(&buf, &len, &cap, '\\');
                bs = 0;
                pion_win_sb_append(&buf, &len, &cap, '"');
            } else {
                for (size_t k = 0; k < bs; k++) pion_win_sb_append(&buf, &len, &cap, '\\');
                bs = 0;
                pion_win_sb_append(&buf, &len, &cap, arg[j]);
            }
        }
        for (size_t k = 0; k < bs * 2; k++) pion_win_sb_append(&buf, &len, &cap, '\\');
        pion_win_sb_append(&buf, &len, &cap, '"');
    }
    if (!buf) {
        buf = (char *)calloc(1, 1);
    }
    return buf;
}
#endif

#if !defined(_WIN32) && !PION_NO_SPAWN
static PION_NOINLINE PION_MINSIZE char **pion_posix_build_argv(PionArray *arr) {
    if (!arr || arr->len <= 0) return NULL;
    char **argv = (char **)malloc(((size_t)arr->len + 1) * sizeof(char *));
    if (!argv) return NULL;
    for (int64_t i = 0; i < arr->len; i++) {
        PionString *s = (PionString *)(uintptr_t)arr->data[i];
        argv[i] = s ? s->data : (char *)"";
    }
    argv[arr->len] = NULL;
    return argv;
}

static PION_NOINLINE PION_MINSIZE int32_t pion_posix_wait_pid(pid_t pid) {
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
#endif

PION_MINSIZE int32_t pion_world_exec(void *w_ptr, void *argv_arr) {
    (void)w_ptr;
#ifdef _WIN32
    PionArray *arr = (PionArray *)argv_arr;
    if (!arr || arr->len <= 0) return -1;
    char *cmdline = pion_win_build_cmdline(arr);
    if (!cmdline) return -1;
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    memset(&pi, 0, sizeof(pi));
    si.cb = (DWORD)sizeof(si);
    BOOL ok = CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
    free(cmdline);
    if (!ok) return 127;
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    (void)GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int32_t)code;
#elif PION_NO_SPAWN
    (void)argv_arr;
    errno = ENOSYS;
    return -1;
#else
    char **argv = pion_posix_build_argv((PionArray *)argv_arr);
    if (!argv) return -1;
    pid_t pid = 0;
    int rc = posix_spawnp(&pid, argv[0], NULL, NULL, argv, environ);
    free(argv);
    if (rc != 0) return 127;
    return pion_posix_wait_pid(pid);
#endif
}

static PION_MINSIZE char *pion_exec_capture_raw(void *argv_arr, int silence_stderr,
                                                size_t *out_len, int32_t *exit_code_out) {
    if (out_len) *out_len = 0;
    if (exit_code_out) *exit_code_out = -1;
#ifdef _WIN32
    PionArray *arr = (PionArray *)argv_arr;
    if (!arr || arr->len <= 0) return NULL;
    char *cmdline = pion_win_build_cmdline(arr);
    if (!cmdline) return NULL;
    SECURITY_ATTRIBUTES sa;
    sa.nLength = (DWORD)sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = TRUE;
    HANDLE rd = NULL, wr = NULL;
    if (!CreatePipe(&rd, &wr, &sa, 0)) {
        free(cmdline);
        return NULL;
    }
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
    HANDLE nul_h = INVALID_HANDLE_VALUE;
    if (silence_stderr) {
        nul_h = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                            &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    }
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    memset(&pi, 0, sizeof(pi));
    si.cb = (DWORD)sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = wr;
    si.hStdError = (silence_stderr && nul_h != INVALID_HANDLE_VALUE) ? nul_h : GetStdHandle(STD_ERROR_HANDLE);
    BOOL ok = CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
    free(cmdline);
    CloseHandle(wr);
    if (nul_h != INVALID_HANDLE_VALUE) CloseHandle(nul_h);
    if (!ok) {
        CloseHandle(rd);
        if (exit_code_out) *exit_code_out = 127;
        return NULL;
    }
    size_t cap = 4096;
    size_t len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) {
        CloseHandle(rd);
        WaitForSingleObject(pi.hProcess, INFINITE);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return NULL;
    }
    for (;;) {
        if (len + 4096 > cap) {
            cap *= 2;
            char *nb = (char *)realloc(buf, cap);
            if (!nb) {
                free(buf);
                CloseHandle(rd);
                WaitForSingleObject(pi.hProcess, INFINITE);
                CloseHandle(pi.hProcess);
                CloseHandle(pi.hThread);
                return NULL;
            }
            buf = nb;
        }
        DWORD n = 0;
        if (!ReadFile(rd, buf + len, (DWORD)(cap - len), &n, NULL) || n == 0) {
            break;
        }
        len += (size_t)n;
    }
    CloseHandle(rd);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    (void)GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    if (exit_code_out) *exit_code_out = (int32_t)code;
    if (out_len) *out_len = len;
    return buf;
#elif PION_NO_SPAWN
    (void)argv_arr;
    (void)silence_stderr;
    errno = ENOSYS;
    return NULL;
#else
    char **argv = pion_posix_build_argv((PionArray *)argv_arr);
    if (!argv) return NULL;

    int pfd[2];
    if (pipe(pfd) != 0) {
        free(argv);
        return NULL;
    }
    (void)fcntl(pfd[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(pfd[1], F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        free(argv);
        close(pfd[0]);
        close(pfd[1]);
        return NULL;
    }
    (void)posix_spawn_file_actions_adddup2(&actions, pfd[1], STDOUT_FILENO);
    if (silence_stderr) {
        (void)posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    }

    pid_t pid = 0;
    int rc = posix_spawnp(&pid, argv[0], &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    free(argv);
    close(pfd[1]);

    if (rc != 0) {
        close(pfd[0]);
        if (exit_code_out) *exit_code_out = 127;
        return NULL;
    }

    size_t cap = 4096, len = 0;
    char *buf = (char *)malloc(cap);
    while (buf) {
        if (len + 4096 > cap) {
            cap *= 2;
            char *nb = (char *)realloc(buf, cap);
            if (!nb) { free(buf); buf = NULL; break; }
            buf = nb;
        }
        ssize_t n = read(pfd[0], buf + len, cap - len);
        if (n > 0) len += (size_t)n;
        else if (n == 0 || errno != EINTR) break;
    }
    close(pfd[0]);
    int32_t code = pion_posix_wait_pid(pid);
    if (!buf) return NULL;
    if (exit_code_out) *exit_code_out = code;
    *out_len = len;
    return buf;
#endif
}

static PION_NOINLINE PION_MINSIZE void *pion_exec_capture_obj(void *argv_arr, int as_bytes,
                                                              int32_t *exit_code_out) {
    size_t len = 0;
    char *buf = pion_exec_capture_raw(argv_arr, as_bytes, &len, exit_code_out);
    void *out = as_bytes ? pion_bytes_from_ptr(buf, (int64_t)len)
                         : pion_str_from_cstr(buf ? buf : "", (int64_t)len);
    free(buf);
    return out;
}

PION_MINSIZE void *pion_world_exec_capture(void *w_ptr, void *argv_arr, int32_t *exit_code_out) {
    (void)w_ptr;
    return pion_exec_capture_obj(argv_arr, 0, exit_code_out);
}

PION_MINSIZE void *pion_world_exec_capture_bytes(void *w_ptr, void *argv_arr, int32_t *exit_code_out) {
    (void)w_ptr;
    return pion_exec_capture_obj(argv_arr, 1, exit_code_out);
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

static PION_NOINLINE PION_MINSIZE void sha256_transform(uint32_t st[8], const uint8_t blk[64]) {
    uint32_t w[16], v[8];
    memcpy(v, st, sizeof(v));
    for (int i = 0; i < 64; i++) {
        uint32_t wi;
        if (i < 16) {
            wi = ((uint32_t)blk[i * 4] << 24) | ((uint32_t)blk[i * 4 + 1] << 16) |
                 ((uint32_t)blk[i * 4 + 2] << 8) | (uint32_t)blk[i * 4 + 3];
        } else {
            uint32_t a15 = w[(i - 15) & 15], a2 = w[(i - 2) & 15];
            uint32_t s0 = rotr32(a15, 7) ^ rotr32(a15, 18) ^ (a15 >> 3);
            uint32_t s1 = rotr32(a2, 17) ^ rotr32(a2, 19) ^ (a2 >> 10);
            wi = w[i & 15] + s0 + w[(i - 7) & 15] + s1;
        }
        w[i & 15] = wi;
        uint32_t S1 = rotr32(v[4], 6) ^ rotr32(v[4], 11) ^ rotr32(v[4], 25);
        uint32_t ch = (v[4] & v[5]) ^ ((~v[4]) & v[6]);
        uint32_t t1 = v[7] + S1 + ch + sha256_k[i] + wi;
        uint32_t S0 = rotr32(v[0], 2) ^ rotr32(v[0], 13) ^ rotr32(v[0], 22);
        uint32_t maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
        v[7] = v[6]; v[6] = v[5]; v[5] = v[4]; v[4] = v[3] + t1;
        v[3] = v[2]; v[2] = v[1]; v[1] = v[0]; v[0] = t1 + S0 + maj;
    }
    for (int i = 0; i < 8; i++) st[i] += v[i];
}

PION_MINSIZE void *pion_sha256_hex(void *s_ptr) {
    static const uint32_t iv[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
    };
    PionString *s = (PionString *)s_ptr;
    const uint8_t *data = s ? (const uint8_t *)s->data : (const uint8_t *)"";
    uint64_t len = s ? (uint64_t)s->len : 0;
    uint32_t st[8];
    memcpy(st, iv, sizeof(st));

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
    size_t pad_bytes = (rem + 9 <= 64) ? 64u : 128u;
    uint64_t bit_len = len * 8u;
    for (int i = 0; i < 8; i++) {
        tail[pad_bytes - 8 + (size_t)i] = (uint8_t)(bit_len >> (56 - i * 8));
    }
    for (size_t b = 0; b < pad_bytes; b += 64) {
        sha256_transform(st, tail + b);
    }

    static const char hex[] = "0123456789abcdef";
    char out[64];
    for (int i = 0; i < 64; i++) {
        out[i] = hex[(st[i >> 3] >> (28 - (i & 7) * 4)) & 0xFu];
    }
    return pion_str_from_cstr(out, 64);
}

/* ============================================================================
 * 8. FFI Raw Pointers & CStr Helpers
 * ============================================================================ */

PION_MINSIZE void *pion_ptr_alloc(int64_t bytes) {
    size_t sz = bytes > 0 ? (size_t)bytes : 1u;
    void *p = calloc(1u, sz);
    if (!p) pion_oom();
    return p;
}

PION_MINSIZE void pion_ptr_free(void *p) {
    free(p);
}

PION_MINSIZE void *pion_ptr_offset(void *p, int64_t byte_off) {
    if (!p) return NULL;
    return (void *)((char *)p + byte_off);
}

PION_MINSIZE void *pion_ptr_read_ptr(void *p, int64_t byte_off) {
    void *v = NULL;
    memcpy(&v, (const char *)p + byte_off, sizeof(v));
    return v;
}

PION_MINSIZE void pion_ptr_write_ptr(void *p, int64_t byte_off, void *v) {
    memcpy((char *)p + byte_off, &v, sizeof(v));
}

PION_MINSIZE int32_t pion_ptr_read_u8(void *p, int64_t byte_off) {
    return (int32_t)((const uint8_t *)p)[byte_off];
}

PION_MINSIZE void pion_ptr_write_u8(void *p, int64_t byte_off, int32_t v) {
    ((uint8_t *)p)[byte_off] = (uint8_t)v;
}

PION_MINSIZE int32_t pion_ptr_read_i32(void *p, int64_t byte_off) {
    int32_t v = 0;
    memcpy(&v, (const char *)p + byte_off, sizeof(v));
    return v;
}

PION_MINSIZE void pion_ptr_write_i32(void *p, int64_t byte_off, int32_t v) {
    memcpy((char *)p + byte_off, &v, sizeof(v));
}

PION_MINSIZE int64_t pion_ptr_read_i64(void *p, int64_t byte_off) {
    int64_t v = 0;
    memcpy(&v, (const char *)p + byte_off, sizeof(v));
    return v;
}

PION_MINSIZE void pion_ptr_write_i64(void *p, int64_t byte_off, int64_t v) {
    memcpy((char *)p + byte_off, &v, sizeof(v));
}

PION_MINSIZE void *pion_cstr_to_str(void *cstr) {
    if (!cstr) return pion_empty_str();
    const char *s = (const char *)cstr;
    return pion_str_from_cstr(s, (int64_t)strlen(s));
}

/* ============================================================================
 * 9. TCP Socket & Time Helpers (POSIX / Win32 Winsock2)
 * ============================================================================ */

#ifdef _WIN32

static INIT_ONCE g_wsa_once = INIT_ONCE_STATIC_INIT;

PION_MINSIZE static BOOL CALLBACK pion_wsa_init_cb(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once;
    (void)param;
    (void)ctx;
    WSADATA wsa;
    (void)WSAStartup(MAKEWORD(2, 2), &wsa);
    return TRUE;
}

PION_MINSIZE static void pion_net_init(void) {
    InitOnceExecuteOnce(&g_wsa_once, pion_wsa_init_cb, NULL, NULL);
}

static inline SOCKET pion_to_sock(int32_t fd) {
    return (SOCKET)(uintptr_t)(uint32_t)fd;
}

PION_MINSIZE static int pion_parse_ipv4_addr(void *host_str, int32_t port, int allow_any,
                                             struct sockaddr_in *addr) {
    memset(addr, 0, sizeof(*addr));
    addr->sin_family = AF_INET;
    addr->sin_port = htons((uint16_t)port);
    PionString *h = (PionString *)host_str;
    const char *hs = (h && h->len > 0) ? h->data : "";
    if (allow_any && (hs[0] == '\0' || strcmp(hs, "0.0.0.0") == 0)) {
        addr->sin_addr.s_addr = htonl(INADDR_ANY);
        return 1;
    }
    if (hs[0] == '\0') return 0;
    if (strcmp(hs, "localhost") == 0) hs = "127.0.0.1";
    return inet_pton(AF_INET, hs, &addr->sin_addr) == 1;
}

static PION_NOINLINE PION_MINSIZE int32_t pion_tcp_listen_impl(void *host_str, int32_t port, int reuse_port) {
    pion_net_init();
    if (port < 0 || port > 65535) return -1;
    struct sockaddr_in addr;
    if (!pion_parse_ipv4_addr(host_str, port, 1, &addr)) return -1;
    SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
    if (s == INVALID_SOCKET) return -1;
    int yes = 1;
    if (reuse_port) {
        (void)setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, (int)sizeof(yes));
    } else {
        (void)setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&yes, (int)sizeof(yes));
    }
    if (bind(s, (struct sockaddr *)&addr, (int)sizeof(addr)) != 0 ||
        listen(s, 1024) != 0) {
        int werr = WSAGetLastError();
        closesocket(s);
        errno = (werr == WSAEADDRINUSE || werr == WSAEACCES) ? EADDRINUSE : EIO;
        return -1;
    }
    return (int32_t)s;
}

PION_MINSIZE int32_t pion_tcp_listen(void *w_ptr, void *host_str, int32_t port) {
    (void)w_ptr;
    return pion_tcp_listen_impl(host_str, port, 0);
}

PION_MINSIZE int32_t pion_tcp_listen_reuse(void *w_ptr, void *host_str, int32_t port) {
    (void)w_ptr;
    return pion_tcp_listen_impl(host_str, port, 1);
}

PION_MINSIZE int32_t pion_tcp_local_port(void *w_ptr, int32_t fd) {
    (void)w_ptr;
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    int len = (int)sizeof(addr);
    memset(&addr, 0, sizeof(addr));
    if (getsockname(pion_to_sock(fd), (struct sockaddr *)&addr, &len) != 0) return -1;
    return (int32_t)ntohs(addr.sin_port);
}

PION_MINSIZE int32_t pion_tcp_accept(void *w_ptr, int32_t listen_fd) {
    (void)w_ptr;
    if (listen_fd < 0) return -1;
    SOCKET cfd;
    do {
        cfd = accept(pion_to_sock(listen_fd), NULL, NULL);
    } while (cfd == INVALID_SOCKET && WSAGetLastError() == WSAEINTR);
    return cfd != INVALID_SOCKET ? (int32_t)cfd : -1;
}

PION_MINSIZE int32_t pion_tcp_connect(void *w_ptr, void *host_str, int32_t port) {
    (void)w_ptr;
    pion_net_init();
    if (port <= 0 || port > 65535) return -1;
    struct sockaddr_in addr;
    if (!pion_parse_ipv4_addr(host_str, port, 0, &addr)) return -1;
    SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
    if (s == INVALID_SOCKET) return -1;
    int rc;
    do {
        rc = connect(s, (struct sockaddr *)&addr, (int)sizeof(addr));
    } while (rc == SOCKET_ERROR && WSAGetLastError() == WSAEINTR);
    if (rc != 0) {
        closesocket(s);
        errno = ECONNREFUSED;
        return -1;
    }
    return (int32_t)s;
}

PION_MINSIZE void *pion_tcp_read(void *w_ptr, int32_t fd, int32_t max_bytes) {
    (void)w_ptr;
    if (fd < 0) return pion_empty_str();
    size_t cap = max_bytes <= 0 ? 4096u : (size_t)max_bytes;
    if (cap > (size_t)(4 * 1024 * 1024)) cap = (size_t)(4 * 1024 * 1024);
    char stack_buf[4096];
    char *buf = cap <= sizeof(stack_buf) ? stack_buf : (char *)malloc(cap);
    if (!buf) return pion_empty_str();
    int n;
    do {
        n = recv(pion_to_sock(fd), buf, (int)cap, 0);
    } while (n == SOCKET_ERROR && WSAGetLastError() == WSAEINTR);
    void *out = pion_str_from_cstr(buf, n > 0 ? (int64_t)n : 0);
    if (buf != stack_buf) free(buf);
    return out;
}

PION_MINSIZE int32_t pion_tcp_write(void *w_ptr, int32_t fd, void *data_str) {
    (void)w_ptr;
    if (fd < 0) return -1;
    PionString *s = (PionString *)data_str;
    if (!s || s->len <= 0) return 0;
    size_t total = (size_t)s->len;
    size_t sent = 0;
    while (sent < total) {
        int chunk = (total - sent) > (size_t)INT32_MAX ? INT32_MAX : (int)(total - sent);
        int n = send(pion_to_sock(fd), s->data + sent, chunk, 0);
        if (n > 0) {
            sent += (size_t)n;
        } else if (n == SOCKET_ERROR && WSAGetLastError() == WSAEINTR) {
            continue;
        } else {
            return -1;
        }
    }
    return (int32_t)sent;
}

PION_MINSIZE void pion_tcp_close(void *w_ptr, int32_t fd) {
    (void)w_ptr;
    if (fd >= 0) closesocket(pion_to_sock(fd));
}

#define PION_IO_AGAIN (-2)
#define PION_EV_READ 1
#define PION_EV_WRITE 2
#define PION_EV_ERR 4
#define PION_POLL_MAX 256
#define PION_WIN_POLL_SLOTS 64

PION_MINSIZE static int pion_io_would_block(void) {
    int e = WSAGetLastError();
    return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS;
}

PION_MINSIZE static int pion_fd_set_nonblock(int32_t fd, int enable) {
    u_long mode = enable ? 1UL : 0UL;
    return ioctlsocket(pion_to_sock(fd), FIONBIO, &mode) == 0;
}

PION_MINSIZE int32_t pion_tcp_set_nonblock(void *w_ptr, int32_t fd, int32_t enable) {
    (void)w_ptr;
    return fd >= 0 && pion_fd_set_nonblock(fd, enable != 0);
}

PION_MINSIZE int32_t pion_tcp_accept_nb(void *w_ptr, int32_t listen_fd) {
    (void)w_ptr;
    if (listen_fd < 0) return -1;
    SOCKET cfd;
    do {
        cfd = accept(pion_to_sock(listen_fd), NULL, NULL);
    } while (cfd == INVALID_SOCKET && WSAGetLastError() == WSAEINTR);
    if (cfd == INVALID_SOCKET) {
        int e = WSAGetLastError();
        return (e == WSAEWOULDBLOCK || e == WSAECONNRESET) ? PION_IO_AGAIN : -1;
    }
    int yes = 1;
    (void)setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, (const char *)&yes, (int)sizeof(yes));
    if (!pion_fd_set_nonblock((int32_t)cfd, 1)) {
        closesocket(cfd);
        return -1;
    }
    return (int32_t)cfd;
}

PION_MINSIZE int32_t pion_tcp_read_nb(void *w_ptr, int32_t fd, void *sb_ptr, int32_t max_bytes) {
    (void)w_ptr;
    PionStrBuf *sb = (PionStrBuf *)sb_ptr;
    if (fd < 0 || !sb) return -1;
    char buf[16384];
    int cap = max_bytes <= 0 || max_bytes > (int32_t)sizeof(buf) ? (int)sizeof(buf) : (int)max_bytes;
    int n;
    do {
        n = recv(pion_to_sock(fd), buf, cap, 0);
    } while (n == SOCKET_ERROR && WSAGetLastError() == WSAEINTR);
    if (n > 0) {
        pion_strbuf_reserve(sb, (int64_t)n);
        memcpy(sb->data + sb->len, buf, (size_t)n);
        sb->len += (int64_t)n;
        sb->data[sb->len] = '\0';
        return (int32_t)n;
    }
    if (n == 0) return 0;
    return pion_io_would_block() ? PION_IO_AGAIN : -1;
}

PION_MINSIZE int32_t pion_tcp_write_nb(void *w_ptr, int32_t fd, void *data_str, int32_t offset) {
    (void)w_ptr;
    PionString *s = (PionString *)data_str;
    if (fd < 0 || !s || offset < 0) return -1;
    if ((int64_t)offset >= s->len) return 0;
    size_t len = (size_t)(s->len - offset);
    if (len > (size_t)INT32_MAX) len = (size_t)INT32_MAX;
    int n;
    do {
        n = send(pion_to_sock(fd), s->data + offset, (int)len, 0);
    } while (n == SOCKET_ERROR && WSAGetLastError() == WSAEINTR);
    if (n >= 0) return (int32_t)n;
    return pion_io_would_block() ? PION_IO_AGAIN : -1;
}

typedef struct PionWinPoll {
    int in_use;
    int count;
    WSAPOLLFD fds[PION_POLL_MAX];
} PionWinPoll;

static SRWLOCK g_win_poll_mu = SRWLOCK_INIT;
static PionWinPoll g_win_polls[PION_WIN_POLL_SLOTS];

PION_MINSIZE int32_t pion_poll_create(void *w_ptr) {
    (void)w_ptr;
    pion_net_init();
    AcquireSRWLockExclusive(&g_win_poll_mu);
    for (int i = 0; i < PION_WIN_POLL_SLOTS; i++) {
        if (!g_win_polls[i].in_use) {
            g_win_polls[i].in_use = 1;
            g_win_polls[i].count = 0;
            ReleaseSRWLockExclusive(&g_win_poll_mu);
            return (int32_t)i;
        }
    }
    ReleaseSRWLockExclusive(&g_win_poll_mu);
    return -1;
}

PION_MINSIZE int32_t pion_poll_ctl(void *w_ptr, int32_t pfd, int32_t op, int32_t fd, int32_t events) {
    (void)w_ptr;
    if (pfd < 0 || pfd >= PION_WIN_POLL_SLOTS || fd < 0 || op < 1 || op > 3) return 0;
    SOCKET s = pion_to_sock(fd);
    SHORT wev = (SHORT)(((events & PION_EV_READ) ? POLLRDNORM : 0) |
                        ((events & PION_EV_WRITE) ? POLLWRNORM : 0));
    AcquireSRWLockExclusive(&g_win_poll_mu);
    PionWinPoll *p = &g_win_polls[pfd];
    if (!p->in_use) {
        ReleaseSRWLockExclusive(&g_win_poll_mu);
        return 0;
    }
    int idx = -1;
    for (int i = 0; i < p->count; i++) {
        if (p->fds[i].fd == s) {
            idx = i;
            break;
        }
    }
    int ok = 1;
    if (op == 1) {
        if (idx >= 0) {
            p->fds[idx].events = wev;
        } else if (p->count < PION_POLL_MAX) {
            p->fds[p->count].fd = s;
            p->fds[p->count].events = wev;
            p->fds[p->count].revents = 0;
            p->count++;
        } else {
            ok = 0;
        }
    } else if (op == 2) {
        if (idx >= 0) {
            p->fds[idx].events = wev;
        } else {
            ok = 0;
        }
    } else {
        if (idx >= 0) {
            p->fds[idx] = p->fds[p->count - 1];
            p->count--;
        }
    }
    ReleaseSRWLockExclusive(&g_win_poll_mu);
    return ok;
}

PION_MINSIZE int32_t pion_poll_wait(void *w_ptr, int32_t pfd, void *out_fds, void *out_events,
                                    int32_t max_events, int32_t timeout_ms) {
    (void)w_ptr;
    pion_arr_clear(out_fds);
    pion_arr_clear(out_events);
    if (pfd < 0 || pfd >= PION_WIN_POLL_SLOTS || !out_fds || !out_events) return -1;
    WSAPOLLFD local[PION_POLL_MAX];
    int count = 0;
    AcquireSRWLockExclusive(&g_win_poll_mu);
    PionWinPoll *p = &g_win_polls[pfd];
    if (!p->in_use) {
        ReleaseSRWLockExclusive(&g_win_poll_mu);
        return -1;
    }
    count = p->count;
    if (count > 0) {
        memcpy(local, p->fds, (size_t)count * sizeof(WSAPOLLFD));
    }
    ReleaseSRWLockExclusive(&g_win_poll_mu);
    if (count == 0) {
        if (timeout_ms > 0) Sleep((DWORD)timeout_ms);
        return 0;
    }
    int n = WSAPoll(local, (ULONG)count, timeout_ms < 0 ? -1 : (int)timeout_ms);
    if (n == SOCKET_ERROR) return -1;
    if (n == 0) return 0;
    int cap = max_events <= 0 || max_events > PION_POLL_MAX ? PION_POLL_MAX : (int)max_events;
    int m = 0;
    for (int i = 0; i < count && m < cap; i++) {
        SHORT r = local[i].revents;
        if (r == 0) continue;
        int mask = 0;
        if (r & (POLLRDNORM | POLLIN)) mask |= PION_EV_READ;
        if (r & (POLLWRNORM | POLLOUT)) mask |= PION_EV_WRITE;
        if (r & (POLLERR | POLLHUP | POLLNVAL)) mask |= PION_EV_ERR;
        if (r & POLLHUP) mask |= PION_EV_READ;
        pion_arr_push(out_fds, (int64_t)(int32_t)local[i].fd);
        pion_arr_push(out_events, (int64_t)mask);
        m++;
    }
    return (int32_t)m;
}

PION_MINSIZE void pion_poll_close(void *w_ptr, int32_t pfd) {
    (void)w_ptr;
    if (pfd < 0 || pfd >= PION_WIN_POLL_SLOTS) return;
    AcquireSRWLockExclusive(&g_win_poll_mu);
    g_win_polls[pfd].in_use = 0;
    g_win_polls[pfd].count = 0;
    ReleaseSRWLockExclusive(&g_win_poll_mu);
}

PION_MINSIZE void pion_sleep_ms(void *w_ptr, int32_t ms) {
    (void)w_ptr;
    if (ms <= 0) return;
    Sleep((DWORD)ms);
}

#else

static pthread_once_t g_sigpipe_once = PTHREAD_ONCE_INIT;

PION_MINSIZE static void pion_ignore_sigpipe_init(void) {
    (void)signal(SIGPIPE, SIG_IGN);
}

static PION_NOINLINE PION_MINSIZE int pion_parse_ipv4_addr(void *host_str, int32_t port, int allow_any,
                                         struct sockaddr_in *addr) {
    memset(addr, 0, sizeof(*addr));
#ifdef __APPLE__
    addr->sin_len = (uint8_t)sizeof(*addr);
#endif
    addr->sin_family = AF_INET;
    addr->sin_port = htons((uint16_t)port);
    PionString *h = (PionString *)host_str;
    const char *hs = (h && h->len > 0) ? h->data : "";
    if (allow_any && (hs[0] == '\0' || strcmp(hs, "0.0.0.0") == 0)) {
        addr->sin_addr.s_addr = htonl(INADDR_ANY);
        return 1;
    }
    if (hs[0] == '\0') return 0;
    if (strcmp(hs, "localhost") == 0) hs = "127.0.0.1";
    return inet_pton(AF_INET, hs, &addr->sin_addr) == 1;
}

static PION_NOINLINE PION_MINSIZE int32_t pion_tcp_listen_impl(void *host_str, int32_t port, int reuse_port) {
    pthread_once(&g_sigpipe_once, pion_ignore_sigpipe_init);
    if (port < 0 || port > 65535) return -1;
    struct sockaddr_in addr;
    if (!pion_parse_ipv4_addr(host_str, port, 1, &addr)) return -1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, (socklen_t)sizeof(yes));
#ifdef SO_REUSEPORT
    if (reuse_port) (void)setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, (socklen_t)sizeof(yes));
#else
    (void)reuse_port;
#endif
    if (bind(fd, (struct sockaddr *)&addr, (socklen_t)sizeof(addr)) != 0 ||
        listen(fd, 1024) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return (int32_t)fd;
}

PION_MINSIZE int32_t pion_tcp_listen(void *w_ptr, void *host_str, int32_t port) {
    (void)w_ptr;
    return pion_tcp_listen_impl(host_str, port, 0);
}

PION_MINSIZE int32_t pion_tcp_listen_reuse(void *w_ptr, void *host_str, int32_t port) {
    (void)w_ptr;
    return pion_tcp_listen_impl(host_str, port, 1);
}

PION_MINSIZE int32_t pion_tcp_local_port(void *w_ptr, int32_t fd) {
    (void)w_ptr;
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    socklen_t len = (socklen_t)sizeof(addr);
    memset(&addr, 0, sizeof(addr));
    if (getsockname(fd, (struct sockaddr *)&addr, &len) != 0) return -1;
    return (int32_t)ntohs(addr.sin_port);
}

PION_MINSIZE int32_t pion_tcp_accept(void *w_ptr, int32_t listen_fd) {
    (void)w_ptr;
    if (listen_fd < 0) return -1;
    int cfd;
    do {
        cfd = accept(listen_fd, NULL, NULL);
    } while (cfd < 0 && errno == EINTR);
    return cfd >= 0 ? (int32_t)cfd : -1;
}

PION_MINSIZE int32_t pion_tcp_connect(void *w_ptr, void *host_str, int32_t port) {
    (void)w_ptr;
    pthread_once(&g_sigpipe_once, pion_ignore_sigpipe_init);
    if (port <= 0 || port > 65535) return -1;
    struct sockaddr_in addr;
    if (!pion_parse_ipv4_addr(host_str, port, 0, &addr)) return -1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int rc;
    do {
        rc = connect(fd, (struct sockaddr *)&addr, (socklen_t)sizeof(addr));
    } while (rc < 0 && errno == EINTR);
    if (rc != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return (int32_t)fd;
}

PION_MINSIZE void *pion_tcp_read(void *w_ptr, int32_t fd, int32_t max_bytes) {
    (void)w_ptr;
    if (fd < 0) return pion_empty_str();
    size_t cap = max_bytes <= 0 ? 4096u : (size_t)max_bytes;
    if (cap > (size_t)(4 * 1024 * 1024)) cap = (size_t)(4 * 1024 * 1024);
    char stack_buf[4096];
    char *buf = cap <= sizeof(stack_buf) ? stack_buf : (char *)malloc(cap);
    if (!buf) return pion_empty_str();
    ssize_t n;
    do {
        n = recv(fd, buf, cap, 0);
    } while (n < 0 && errno == EINTR);
    void *out = pion_str_from_cstr(buf, n > 0 ? (int64_t)n : 0);
    if (buf != stack_buf) free(buf);
    return out;
}

PION_MINSIZE int32_t pion_tcp_write(void *w_ptr, int32_t fd, void *data_str) {
    if (fd < 0) return -1;
    PionString *s = (PionString *)data_str;
    if (!s || s->len <= 0) return 0;
    int32_t sent = 0;
    while ((int64_t)sent < s->len) {
        int32_t n = pion_tcp_write_nb(w_ptr, fd, data_str, sent);
        if (n <= 0) return -1;
        sent += n;
    }
    return sent;
}

PION_MINSIZE void pion_tcp_close(void *w_ptr, int32_t fd) {
    (void)w_ptr;
    if (fd >= 0) close(fd);
}

/* ============================================================================
 * 10. Non-blocking sockets & kqueue/epoll readiness polling (level-triggered)
 * ============================================================================ */

#define PION_IO_AGAIN (-2)
#define PION_EV_READ 1
#define PION_EV_WRITE 2
#define PION_EV_ERR 4
#define PION_POLL_MAX 256

PION_MINSIZE static int pion_io_would_block(void) {
    return errno == EAGAIN || errno == EWOULDBLOCK;
}

static PION_NOINLINE PION_MINSIZE int pion_fd_set_nonblock(int fd, int enable) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0) return 0;
    int nfl = enable ? (fl | O_NONBLOCK) : (fl & ~O_NONBLOCK);
    return nfl == fl || fcntl(fd, F_SETFL, nfl) == 0;
}

PION_MINSIZE int32_t pion_tcp_set_nonblock(void *w_ptr, int32_t fd, int32_t enable) {
    (void)w_ptr;
    return fd >= 0 && pion_fd_set_nonblock(fd, enable != 0);
}

PION_MINSIZE int32_t pion_tcp_accept_nb(void *w_ptr, int32_t listen_fd) {
    int cfd = (int)pion_tcp_accept(w_ptr, listen_fd);
    if (cfd < 0) return listen_fd >= 0 && (pion_io_would_block() || errno == ECONNABORTED) ? PION_IO_AGAIN : -1;
    int yes = 1;
    (void)setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &yes, (socklen_t)sizeof(yes));
#ifdef SO_NOSIGPIPE
    (void)setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &yes, (socklen_t)sizeof(yes));
#endif
    (void)fcntl(cfd, F_SETFD, FD_CLOEXEC);
    if (!pion_fd_set_nonblock(cfd, 1)) {
        close(cfd);
        return -1;
    }
    return (int32_t)cfd;
}

/* One recv into a 16 KB stack buffer, then appends exactly the bytes read (an
 * idle connection's StringBuilder never grows to the read window). */
PION_MINSIZE int32_t pion_tcp_read_nb(void *w_ptr, int32_t fd, void *sb_ptr, int32_t max_bytes) {
    (void)w_ptr;
    PionStrBuf *sb = (PionStrBuf *)sb_ptr;
    if (fd < 0 || !sb) return -1;
    char buf[16384];
    size_t cap = max_bytes <= 0 || max_bytes > (int32_t)sizeof(buf) ? sizeof(buf) : (size_t)max_bytes;
    ssize_t n;
    do {
        n = recv(fd, buf, cap, 0);
    } while (n < 0 && errno == EINTR);
    if (n > 0) {
        pion_strbuf_reserve(sb, (int64_t)n);
        memcpy(sb->data + sb->len, buf, (size_t)n);
        sb->len += (int64_t)n;
        sb->data[sb->len] = '\0';
        return (int32_t)n;
    }
    if (n == 0) return 0;
    return pion_io_would_block() ? PION_IO_AGAIN : -1;
}

/* One send of data[offset..]: partial writes resume from a new offset, no slicing. */
PION_MINSIZE int32_t pion_tcp_write_nb(void *w_ptr, int32_t fd, void *data_str, int32_t offset) {
    (void)w_ptr;
    PionString *s = (PionString *)data_str;
    if (fd < 0 || !s || offset < 0) return -1;
    if ((int64_t)offset >= s->len) return 0;
    size_t len = (size_t)(s->len - offset);
    if (len > (size_t)INT32_MAX) len = (size_t)INT32_MAX;
    int flags = 0;
#ifdef MSG_NOSIGNAL
    flags = MSG_NOSIGNAL;
#endif
    ssize_t n;
    do {
        n = send(fd, s->data + offset, len, flags);
    } while (n < 0 && errno == EINTR);
    if (n >= 0) return (int32_t)n;
    return pion_io_would_block() ? PION_IO_AGAIN : -1;
}

PION_MINSIZE int32_t pion_poll_create(void *w_ptr) {
    (void)w_ptr;
#if defined(__APPLE__)
    int pfd = kqueue();
    if (pfd >= 0) (void)fcntl(pfd, F_SETFD, FD_CLOEXEC);
    return pfd >= 0 ? (int32_t)pfd : -1;
#elif defined(__linux__)
    int pfd = epoll_create1(EPOLL_CLOEXEC);
    return pfd >= 0 ? (int32_t)pfd : -1;
#else
    errno = ENOSYS;
    return -1;
#endif
}

/* op: 1 ADD, 2 MOD, 3 DEL; events: 1 READ | 2 WRITE. Level-triggered on both
 * backends. kqueue registers both filters on ADD/MOD (enabled or disabled), so a
 * MOD never deletes a filter that was not registered. */
PION_MINSIZE int32_t pion_poll_ctl(void *w_ptr, int32_t pfd, int32_t op, int32_t fd, int32_t events) {
    (void)w_ptr;
    if (pfd < 0 || fd < 0 || op < 1 || op > 3) return 0;
#if defined(__APPLE__)
    struct kevent ch[2];
    struct kevent res[2];
    for (int i = 0; i < 2; i++) {
        int16_t filt = i == 0 ? EVFILT_READ : EVFILT_WRITE;
        int on = (events & (i == 0 ? PION_EV_READ : PION_EV_WRITE)) != 0;
        uint16_t fl = op == 3 ? EV_DELETE : (uint16_t)(EV_ADD | (on ? EV_ENABLE : EV_DISABLE));
        EV_SET(&ch[i], (uintptr_t)fd, filt, (uint16_t)(fl | EV_RECEIPT), 0, 0, NULL);
    }
    int n;
    do {
        n = kevent(pfd, ch, 2, res, 2, NULL);
    } while (n < 0 && errno == EINTR);
    if (n < 0) return 0;
    for (int i = 0; i < n; i++) {
        if ((res[i].flags & EV_ERROR) && res[i].data != 0 &&
            !(op == 3 && res[i].data == ENOENT)) {
            errno = (int)res[i].data;
            return 0;
        }
    }
    return 1;
#elif defined(__linux__)
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = ((events & PION_EV_READ) ? EPOLLIN : 0u) | ((events & PION_EV_WRITE) ? EPOLLOUT : 0u);
    ev.data.fd = fd;
    int eop = op == 1 ? EPOLL_CTL_ADD : (op == 2 ? EPOLL_CTL_MOD : EPOLL_CTL_DEL);
    return epoll_ctl(pfd, eop, fd, &ev) == 0;
#else
    (void)events;
    errno = ENOSYS;
    return 0;
#endif
}

/* Fills out_fds/out_events (cleared first) with one entry per ready fd, its mask
 * 1 READ | 2 WRITE | 4 ERR/HUP/EOF; kqueue's per-filter events are merged by fd. */
PION_MINSIZE int32_t pion_poll_wait(void *w_ptr, int32_t pfd, void *out_fds, void *out_events,
                                    int32_t max_events, int32_t timeout_ms) {
    (void)w_ptr;
    pion_arr_clear(out_fds);
    pion_arr_clear(out_events);
    if (pfd < 0 || !out_fds || !out_events) return -1;
    int cap = max_events <= 0 || max_events > PION_POLL_MAX ? PION_POLL_MAX : (int)max_events;
#if defined(__APPLE__)
    int fds[PION_POLL_MAX];
    int masks[PION_POLL_MAX];
    int m = 0;
    struct kevent evs[PION_POLL_MAX];
    struct timespec ts;
    ts.tv_sec = (time_t)(timeout_ms / 1000);
    ts.tv_nsec = (long)(timeout_ms % 1000) * 1000000L;
    int n;
    do {
        n = kevent(pfd, NULL, 0, evs, cap, timeout_ms < 0 ? NULL : &ts);
    } while (n < 0 && errno == EINTR);
    if (n < 0) return -1;
    for (int i = 0; i < n; i++) {
        int fd = (int)evs[i].ident;
        int mask = evs[i].filter == EVFILT_READ ? PION_EV_READ : PION_EV_WRITE;
        if (evs[i].flags & (EV_EOF | EV_ERROR)) mask |= PION_EV_ERR;
        int j = 0;
        while (j < m && fds[j] != fd) j++;
        if (j == m) {
            fds[m] = fd;
            masks[m++] = 0;
        }
        masks[j] |= mask;
    }
    for (int i = 0; i < m; i++) {
        pion_arr_push(out_fds, (int64_t)fds[i]);
        pion_arr_push(out_events, (int64_t)masks[i]);
    }
    return (int32_t)m;
#elif defined(__linux__)
    struct epoll_event evs[PION_POLL_MAX];
    int n;
    do {
        n = epoll_wait(pfd, evs, cap, timeout_ms < 0 ? -1 : (int)timeout_ms);
    } while (n < 0 && errno == EINTR);
    if (n < 0) return -1;
    for (int i = 0; i < n; i++) {
        uint32_t e = evs[i].events;
        int mask = ((e & EPOLLIN) ? PION_EV_READ : 0) | ((e & EPOLLOUT) ? PION_EV_WRITE : 0) |
                   ((e & (EPOLLERR | EPOLLHUP)) ? PION_EV_ERR : 0);
        pion_arr_push(out_fds, (int64_t)evs[i].data.fd);
        pion_arr_push(out_events, (int64_t)mask);
    }
    return (int32_t)n;
#else
    (void)cap;
    (void)timeout_ms;
    errno = ENOSYS;
    return -1;
#endif
}

PION_MINSIZE void pion_poll_close(void *w_ptr, int32_t pfd) {
    pion_tcp_close(w_ptr, pfd);
}

PION_MINSIZE void pion_sleep_ms(void *w_ptr, int32_t ms) {
    (void)w_ptr;
    if (ms <= 0) return;
    struct timespec req;
    req.tv_sec = (time_t)(ms / 1000);
    req.tv_nsec = (long)(ms % 1000) * 1000000L;
    struct timespec rem;
    while (nanosleep(&req, &rem) < 0 && errno == EINTR) {
        req = rem;
    }
}

#endif /* _WIN32 */

#if defined(__clang__)
#pragma clang attribute pop
#endif
