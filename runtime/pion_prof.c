/* pion_prof.c — Native built-in profiler runtime for Pion.
 * Compiled into libpionrt_prof.a with -DPION_PROF=1 -fno-omit-frame-pointer.
 * Never linked into regular libpionrt.a (zero bytes in normal builds). */

#ifndef _WIN32
#if defined(__linux__)
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#elif defined(__APPLE__)
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#else
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#endif
#endif

#include "pion_prof.h"

#include <errno.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
__attribute__((noinline, used))
#endif
void pion_prof_anchor(void) {
    static volatile int sink = 0;
    sink = sink + 1;
}

#if (defined(__GNUC__) || defined(__clang__)) && !defined(_WIN32)
__attribute__((weak))
#endif
uint32_t pion_prof_build_modes = PION_PROF_ALL;

#ifdef _WIN32
/* Phase 1: native profiling on Windows is unsupported at CLI level;
 * provide clean -Werror-free stubs so cross-platform builds always succeed. */
void pion_prof_init(void) {}
void pion_prof_flush(void) {}
void pion_prof_pause(void) {}
void pion_prof_resume(void) {}
void pion_prof_reset(void) {}
void pion_prof_thread_init(void) {}
void pion_prof_on_alloc(void *obj, uint32_t payload_size, size_t alloc_bytes,
                        uint16_t type_tag, void *drop_fn, int is_large) {
    (void)obj; (void)payload_size; (void)alloc_bytes;
    (void)type_tag; (void)drop_fn; (void)is_large;
}
void pion_prof_on_retire(void *obj, size_t alloc_bytes, uint16_t type_tag,
                         void *drop_fn, int is_large) {
    (void)obj; (void)alloc_bytes; (void)type_tag;
    (void)drop_fn; (void)is_large;
}
void pion_prof_on_backing_alloc(void *ptr, size_t bytes) { (void)ptr; (void)bytes; }
void pion_prof_on_backing_free(void *ptr, size_t bytes) { (void)ptr; (void)bytes; }
void pion_prof_on_backing_realloc(int had_old, size_t old_bytes,
                                  void *new_ptr, size_t new_bytes) {
    (void)had_old; (void)old_bytes; (void)new_ptr; (void)new_bytes;
}
void pion_prof_on_reserved_add(size_t bytes) { (void)bytes; }
void pion_prof_on_reserved_sub(size_t bytes) { (void)bytes; }
void pion_prof_on_rc_inc(uint16_t type_tag, int is_atomic, int is_immortal) {
    (void)type_tag; (void)is_atomic; (void)is_immortal;
}
void pion_prof_on_rc_dec(uint16_t type_tag, int is_atomic, int is_immortal) {
    (void)type_tag; (void)is_atomic; (void)is_immortal;
}
void pion_prof_on_rc_destroy(uint16_t type_tag) { (void)type_tag; }
void pion_prof_on_rc_freeze(uint16_t type_tag, int is_immortal) {
    (void)type_tag; (void)is_immortal;
}

#else /* POSIX (Linux / macOS) */

#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/ucontext.h>
#include <mach-o/dyld.h>
#include <limits.h>
#else
#include <ucontext.h>
#endif

/* ============================================================================
 * Configuration & Globals
 * ============================================================================ */

#define PION_PROF_MAX_TAGS      32u
#define PION_PROF_CPU_SLOTS     65536u
#define PION_PROF_CPU_MASK      (PION_PROF_CPU_SLOTS - 1u)
#define PION_PROF_CPU_PROBE     32u
#define PION_PROF_TYPE_SLOTS    4096u
#define PION_PROF_TYPE_MASK     (PION_PROF_TYPE_SLOTS - 1u)
#define PION_PROF_MAX_FRAMES    32u
#define PION_PROF_MAX_STACKS    65536u
#define PION_PROF_MAX_RETAINED  1048576u

typedef enum {
    PION_STACK_ALLOC   = 1,
    PION_STACK_RC      = 2,
    PION_STACK_BACKING = 3
} PionProfStackKind;

typedef struct {
    _Atomic uintptr_t pc;
    _Atomic uint64_t count;
} PionProfCpuSlot;

typedef struct {
    _Atomic uint64_t alloc_count;
    _Atomic uint64_t alloc_bytes;
    _Atomic uint64_t free_count;
    _Atomic uint64_t free_bytes;
    _Atomic uint64_t rc_inc;
    _Atomic uint64_t rc_dec;
    _Atomic uint64_t rc_atomic_inc;
    _Atomic uint64_t rc_atomic_dec;
    _Atomic uint64_t rc_destroy;
    _Atomic uint64_t rc_immortal;
} PionProfTagStats;

typedef struct {
    _Atomic uint32_t state; /* 0 = empty, 1 = claiming, 2 = ready */
    uint16_t type_tag;
    uintptr_t drop_fn;
    _Atomic uint64_t alloc_count;
    _Atomic uint64_t alloc_bytes;
    _Atomic uint64_t free_count;
    _Atomic uint64_t free_bytes;
} PionProfTypeSlot;

typedef struct {
    uint64_t hash;
    uint32_t kind;
    uint16_t tag_id;
    uint16_t depth;
    uint64_t count;
    uint64_t bytes;
    uintptr_t frames[PION_PROF_MAX_FRAMES];
} PionProfStackEntry;

typedef struct {
    void *ptr;
    size_t size;
    uint8_t state; /* 0 = empty, 1 = occupied, 2 = tombstone */
} PionProfLargeSlot;

typedef struct {
    void *ptr;
    size_t size;
    uint16_t tag_id;
    uint32_t stack_id; /* 1-based index into g_stacks, or 0 if unsampled */
    uint8_t state;     /* 0 = empty, 1 = occupied, 2 = tombstone */
} PionProfRetainedSlot;

/* Static lock-free CPU sample table (touched from SIGPROF handler) */
static PionProfCpuSlot g_cpu_table[PION_PROF_CPU_SLOTS];
static _Atomic uint64_t g_cpu_dropped = 0;
static _Atomic int g_prof_active = 0;
static _Atomic int g_in_handler = 0;

/* Configuration */
static _Atomic int g_init_done = 0;
static _Atomic int g_enabled = 0;
static _Atomic int g_paused = 0;
static _Atomic int g_flushed = 0;
static int g_cpu_installed = 0;
static struct sigaction g_old_sigprof;

static uint32_t g_modes = 0;
static uint32_t g_hz = 997;
static uint64_t g_sample_rate = 1;
static int g_retained_enabled = 0;
static char g_out_path[4096];

/* Timing */
static uint64_t g_wall_start_us = 0;
static uint64_t g_cpu_start_us = 0;
static uint64_t g_wall_accum_us = 0;
static uint64_t g_cpu_accum_us = 0;
static int g_flush_done = 0;
static pthread_mutex_t g_ctrl_mu = PTHREAD_MUTEX_INITIALIZER;

/* Exact per-tag and per-type counters */
static PionProfTagStats g_tags[PION_PROF_MAX_TAGS];
static PionProfTypeSlot g_types[PION_PROF_TYPE_SLOTS];

/* Exact backing & reserved counters */
static _Atomic uint64_t g_backing_alloc_bytes = 0;
static _Atomic uint64_t g_backing_alloc_count = 0;
static _Atomic uint64_t g_backing_free_bytes = 0;
static _Atomic uint64_t g_reserved_bytes = 0;
static _Atomic uint64_t g_peak_reserved_bytes = 0;

/* Deterministic 1-in-N sampling counters & drop counters */
static _Atomic uint64_t g_alloc_seq = 0;
static _Atomic uint64_t g_rc_seq = 0;
static _Atomic uint64_t g_backing_seq = 0;
static _Atomic uint64_t g_dropped_alloc = 0;
static _Atomic uint64_t g_dropped_rc = 0;
static _Atomic int g_retained_truncated = 0;

/* Large-object side table (ptr -> alloc_bytes) */
static pthread_mutex_t g_large_mu = PTHREAD_MUTEX_INITIALIZER;
static PionProfLargeSlot *g_large_tab = NULL;
static size_t g_large_cap = 0;
static size_t g_large_len = 0;
static size_t g_large_used = 0;

/* Stack aggregation table */
static pthread_mutex_t g_stack_mu = PTHREAD_MUTEX_INITIALIZER;
static PionProfStackEntry *g_stacks = NULL;
static uint32_t g_stacks_len = 0;
static uint32_t g_stacks_cap = 0;
static uint32_t *g_stack_buckets = NULL;
static size_t g_stack_bucket_cap = 0;

/* Retained live-object table */
static pthread_mutex_t g_retained_mu = PTHREAD_MUTEX_INITIALIZER;
static PionProfRetainedSlot *g_retained_tab = NULL;
static size_t g_retained_cap = 0;
static size_t g_retained_len = 0;
static size_t g_retained_used = 0;

/* Per-thread stack bounds & re-entrancy guard (NEVER touched in signal handler) */
static _Thread_local uintptr_t tls_stack_lo = 0;
static _Thread_local uintptr_t tls_stack_hi = 0;
static _Thread_local int tls_stack_ready = 0;
static _Thread_local int tls_prof_in_hook = 0;

/* ============================================================================
 * Helpers (hashing, PAC strip, time, platform target)
 * ============================================================================ */

static inline uintptr_t pion_prof_strip_pac(uintptr_t addr) {
#if defined(__aarch64__) && defined(__has_feature) && defined(__has_builtin)
#if __has_feature(ptrauth_calls) && __has_builtin(__builtin_ptrauth_strip)
    return (uintptr_t)__builtin_ptrauth_strip((void *)addr, 0);
#endif
#endif
#if defined(__aarch64__) && (defined(__GNUC__) || defined(__clang__))
    register uintptr_t x30 __asm__("x30") = addr;
    __asm__ volatile("hint #7" : "+r"(x30));
    return x30;
#endif
    return addr;
}

static inline uint64_t pion_prof_mix64(uint64_t x) {
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

static uint64_t pion_prof_now_wall_us(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)(ts.tv_nsec / 1000L);
}

static uint64_t pion_prof_now_cpu_us(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)(ts.tv_nsec / 1000L);
}

static uint64_t pion_prof_peak_rss_kb(void) {
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
#if defined(__APPLE__)
    return (uint64_t)ru.ru_maxrss / 1024ULL;
#else
    return (uint64_t)ru.ru_maxrss;
#endif
}

static const char *pion_prof_target_name(void) {
#if defined(__APPLE__) && defined(__aarch64__)
    return "arm64_apple";
#elif defined(__APPLE__) && defined(__x86_64__)
    return "amd64_apple";
#elif defined(__linux__) && defined(__x86_64__)
    return "amd64_sysv";
#elif defined(__linux__) && defined(__aarch64__)
    return "arm64";
#else
    return "unknown";
#endif
}

static void pion_prof_self_exe(char *buf, size_t cap) {
    if (cap == 0) return;
    buf[0] = '\0';
#if defined(__linux__)
    ssize_t n = readlink("/proc/self/exe", buf, cap - 1);
    if (n > 0) buf[n] = '\0';
#elif defined(__APPLE__)
    uint32_t sz = (uint32_t)cap;
    char raw[PATH_MAX];
    uint32_t rsz = (uint32_t)sizeof(raw);
    if (_NSGetExecutablePath(raw, &rsz) == 0) {
        char resolved[PATH_MAX];
        if (realpath(raw, resolved) != NULL) {
            snprintf(buf, cap, "%s", resolved);
        } else {
            snprintf(buf, cap, "%s", raw);
        }
    }
    (void)sz;
#endif
}

/* ============================================================================
 * Signal-Safe PC-Only CPU Sampler
 * ============================================================================ */

static inline uintptr_t pion_prof_extract_pc(const ucontext_t *uc) {
    uintptr_t pc = 0;
#if defined(__linux__) && defined(__x86_64__)
    pc = (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
#elif defined(__linux__) && defined(__aarch64__)
    pc = (uintptr_t)uc->uc_mcontext.pc;
#elif defined(__APPLE__) && defined(__aarch64__)
    pc = (uintptr_t)uc->uc_mcontext->__ss.__pc;
#elif defined(__APPLE__) && defined(__x86_64__)
    pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
#else
    (void)uc;
#endif
    return pion_prof_strip_pac(pc);
}

static void pion_prof_sigprof_handler(int sig, siginfo_t *info, void *uctx) {
    (void)sig;
    (void)info;
    int saved_errno = errno;
    atomic_fetch_add_explicit(&g_in_handler, 1, memory_order_acq_rel);
    if (!atomic_load_explicit(&g_prof_active, memory_order_acquire) || !uctx) {
        atomic_fetch_sub_explicit(&g_in_handler, 1, memory_order_release);
        errno = saved_errno;
        return;
    }
    uintptr_t pc = pion_prof_extract_pc((const ucontext_t *)uctx);
    if (pc != 0) {
        uint32_t idx = (uint32_t)pion_prof_mix64((uint64_t)pc) & PION_PROF_CPU_MASK;
        int stored = 0;
        for (uint32_t step = 0; step < PION_PROF_CPU_PROBE; step++) {
            uint32_t slot = (idx + step) & PION_PROF_CPU_MASK;
            uintptr_t cur = atomic_load_explicit(&g_cpu_table[slot].pc, memory_order_relaxed);
            if (cur == pc) {
                atomic_fetch_add_explicit(&g_cpu_table[slot].count, 1, memory_order_relaxed);
                stored = 1;
                break;
            }
            if (cur == 0) {
                uintptr_t expected = 0;
                if (atomic_compare_exchange_strong_explicit(
                        &g_cpu_table[slot].pc, &expected, pc,
                        memory_order_acq_rel, memory_order_relaxed)) {
                    atomic_fetch_add_explicit(&g_cpu_table[slot].count, 1, memory_order_relaxed);
                    stored = 1;
                    break;
                }
                if (expected == pc) {
                    atomic_fetch_add_explicit(&g_cpu_table[slot].count, 1, memory_order_relaxed);
                    stored = 1;
                    break;
                }
            }
        }
        if (!stored) {
            atomic_fetch_add_explicit(&g_cpu_dropped, 1, memory_order_relaxed);
        }
    }
    atomic_fetch_sub_explicit(&g_in_handler, 1, memory_order_release);
    errno = saved_errno;
}

static void pion_prof_timer_arm(uint32_t hz) {
    if (hz == 0) hz = 997;
    long usec = 1000000L / (long)hz;
    if (usec < 100) usec = 100;
    struct itimerval it;
    it.it_interval.tv_sec = usec / 1000000L;
    it.it_interval.tv_usec = usec % 1000000L;
    it.it_value = it.it_interval;
    (void)setitimer(ITIMER_PROF, &it, NULL);
}

static void pion_prof_timer_disarm(void) {
    struct itimerval zero;
    memset(&zero, 0, sizeof(zero));
    (void)setitimer(ITIMER_PROF, &zero, NULL);
}

static void pion_prof_cpu_start(void) {
    if (!(g_modes & PION_PROF_CPU)) return;
    struct itimerval cur_it;
    if (getitimer(ITIMER_PROF, &cur_it) == 0 &&
        (cur_it.it_value.tv_sec != 0 || cur_it.it_value.tv_usec != 0 ||
         cur_it.it_interval.tv_sec != 0 || cur_it.it_interval.tv_usec != 0)) {
        fprintf(stderr, "pion_prof: ITIMER_PROF already in use by host; preserving host timer and skipping CPU sampling\n");
        return;
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = pion_prof_sigprof_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGPROF, &sa, &g_old_sigprof) == 0) {
        g_cpu_installed = 1;
        atomic_store_explicit(&g_prof_active, 1, memory_order_release);
        pion_prof_timer_arm(g_hz);
    }
}

static void pion_prof_cpu_stop_locked(void) {
    if (!g_cpu_installed) return;
    pion_prof_timer_disarm();
    atomic_store_explicit(&g_prof_active, 0, memory_order_release);
    /* Wait for any already-entered SIGPROF handler to finish.
     * If the previous disposition was SIG_DFL, keep our no-op handler installed
     * rather than restoring SIG_DFL so a queued pending SIGPROF cannot kill
     * the process during shutdown. */
    while (atomic_load_explicit(&g_in_handler, memory_order_acquire) != 0) {
        sched_yield();
    }
    if ((g_old_sigprof.sa_flags & SA_SIGINFO) != 0 ||
        (g_old_sigprof.sa_handler != SIG_DFL && g_old_sigprof.sa_handler != SIG_ERR)) {
        (void)sigaction(SIGPROF, &g_old_sigprof, NULL);
    }
    g_cpu_installed = 0;
}

/* ============================================================================
 * Synchronous Stack Capture (Alloc / RC / Backing ONLY — never in signal!)
 * ============================================================================ */

void pion_prof_thread_init(void) {
#if defined(__linux__)
    pthread_attr_t attr;
    if (pthread_getattr_np(pthread_self(), &attr) == 0) {
        void *addr = NULL;
        size_t sz = 0;
        if (pthread_attr_getstack(&attr, &addr, &sz) == 0 && addr != NULL && sz > 0) {
            tls_stack_lo = (uintptr_t)addr;
            tls_stack_hi = tls_stack_lo + (uintptr_t)sz;
        }
        pthread_attr_destroy(&attr);
    }
#elif defined(__APPLE__)
    pthread_t self = pthread_self();
    void *top = pthread_get_stackaddr_np(self);
    size_t sz = pthread_get_stacksize_np(self);
    if (top != NULL && sz > 0) {
        tls_stack_hi = (uintptr_t)top;
        tls_stack_lo = tls_stack_hi - (uintptr_t)sz;
    }
#endif
    tls_stack_ready = 1;
}

static uint16_t pion_prof_capture_stack(uintptr_t *out, uint16_t max_frames, int skip) {
    if (!tls_stack_ready) {
        pion_prof_thread_init();
    }
    uintptr_t lo = tls_stack_lo;
    uintptr_t hi = tls_stack_hi;
    if (lo == 0 || hi <= lo || hi - lo < 2u * sizeof(uintptr_t)) {
        return 0;
    }
    uintptr_t hi_lim = hi - 2u * sizeof(uintptr_t);
#if defined(__GNUC__) || defined(__clang__)
    uintptr_t fp = (uintptr_t)__builtin_frame_address(0);
#else
    uintptr_t fp = 0;
#endif
    uint16_t count = 0;
    int step = 0;
    while (fp != 0 && count < max_frames && step < (int)max_frames + skip + 8) {
        if ((fp & (sizeof(uintptr_t) - 1u)) != 0) break;
        if (fp < lo || fp > hi_lim) break;
        const uintptr_t *pair = (const uintptr_t *)fp;
        uintptr_t next_fp = pair[0];
        uintptr_t lr = pion_prof_strip_pac(pair[1]);
        if (lr == 0) break;
        if (step >= skip) {
            out[count++] = lr > 1u ? (lr - 1u) : lr;
        }
        if (next_fp <= fp) break;
        fp = next_fp;
        step++;
    }
    return count;
}

/* ============================================================================
 * Large-Object Side Table (ptr -> alloc_bytes)
 * ============================================================================ */

static void pion_prof_large_grow_locked(size_t new_cap) {
    PionProfLargeSlot *nt = (PionProfLargeSlot *)calloc(new_cap, sizeof(PionProfLargeSlot));
    if (!nt) return;
    size_t mask = new_cap - 1u;
    for (size_t i = 0; i < g_large_cap; i++) {
        if (g_large_tab[i].state == 1u) {
            size_t idx = (size_t)pion_prof_mix64((uint64_t)(uintptr_t)g_large_tab[i].ptr) & mask;
            while (nt[idx].state == 1u) idx = (idx + 1u) & mask;
            nt[idx] = g_large_tab[i];
        }
    }
    free(g_large_tab);
    g_large_tab = nt;
    g_large_cap = new_cap;
    g_large_used = g_large_len;
}

static void pion_prof_large_put(void *ptr, size_t size) {
    pthread_mutex_lock(&g_large_mu);
    if (g_large_cap == 0) {
        pion_prof_large_grow_locked(256u);
    } else if ((g_large_used + 1u) * 10u >= g_large_cap * 7u) {
        size_t ncap = (g_large_len * 2u >= g_large_cap) ? g_large_cap * 2u : g_large_cap;
        pion_prof_large_grow_locked(ncap);
    }
    if (g_large_cap > 0) {
        size_t mask = g_large_cap - 1u;
        size_t idx = (size_t)pion_prof_mix64((uint64_t)(uintptr_t)ptr) & mask;
        size_t first_tomb = SIZE_MAX;
        int inserted = 0;
        for (size_t step = 0; step < g_large_cap; step++) {
            uint8_t st = g_large_tab[idx].state;
            if (st == 0u) {
                size_t dst = (first_tomb != SIZE_MAX) ? first_tomb : idx;
                if (first_tomb == SIZE_MAX) g_large_used++;
                g_large_tab[dst].ptr = ptr;
                g_large_tab[dst].size = size;
                g_large_tab[dst].state = 1u;
                g_large_len++;
                inserted = 1;
                break;
            }
            if (st == 1u && g_large_tab[idx].ptr == ptr) {
                g_large_tab[idx].size = size;
                inserted = 1;
                break;
            }
            if (st == 2u && first_tomb == SIZE_MAX) {
                first_tomb = idx;
            }
            idx = (idx + 1u) & mask;
        }
        if (!inserted) {
            if (first_tomb != SIZE_MAX) {
                g_large_tab[first_tomb].ptr = ptr;
                g_large_tab[first_tomb].size = size;
                g_large_tab[first_tomb].state = 1u;
                g_large_len++;
            } else {
                atomic_fetch_add_explicit(&g_dropped_alloc, 1, memory_order_relaxed);
            }
        }
    } else {
        atomic_fetch_add_explicit(&g_dropped_alloc, 1, memory_order_relaxed);
    }
    pthread_mutex_unlock(&g_large_mu);
}

static size_t pion_prof_large_take(void *ptr) {
    size_t sz = 0;
    pthread_mutex_lock(&g_large_mu);
    if (g_large_cap > 0) {
        size_t mask = g_large_cap - 1u;
        size_t idx = (size_t)pion_prof_mix64((uint64_t)(uintptr_t)ptr) & mask;
        for (size_t step = 0; step < g_large_cap; step++) {
            uint8_t st = g_large_tab[idx].state;
            if (st == 0u) break;
            if (st == 1u && g_large_tab[idx].ptr == ptr) {
                sz = g_large_tab[idx].size;
                g_large_tab[idx].state = 2u;
                g_large_tab[idx].ptr = NULL;
                g_large_len--;
                break;
            }
            idx = (idx + 1u) & mask;
        }
    }
    pthread_mutex_unlock(&g_large_mu);
    return sz;
}

/* ============================================================================
 * Per-(type_tag, drop_fn) Lock-Free Table
 * ============================================================================ */

static PionProfTypeSlot *pion_prof_type_slot(uint16_t type_tag, uintptr_t drop_fn) {
    uint64_t h = pion_prof_mix64(((uint64_t)type_tag << 48) ^ (uint64_t)drop_fn);
    uint32_t idx = (uint32_t)h & PION_PROF_TYPE_MASK;
    for (uint32_t step = 0; step < PION_PROF_TYPE_SLOTS; step++) {
        uint32_t s = (idx + step) & PION_PROF_TYPE_MASK;
        uint32_t st = atomic_load_explicit(&g_types[s].state, memory_order_acquire);
        if (st == 2u) {
            if (g_types[s].type_tag == type_tag && g_types[s].drop_fn == drop_fn) {
                return &g_types[s];
            }
            continue;
        }
        if (st == 0u) {
            uint32_t expected = 0u;
            if (atomic_compare_exchange_strong_explicit(
                    &g_types[s].state, &expected, 1u,
                    memory_order_acq_rel, memory_order_acquire)) {
                g_types[s].type_tag = type_tag;
                g_types[s].drop_fn = drop_fn;
                atomic_store_explicit(&g_types[s].state, 2u, memory_order_release);
                return &g_types[s];
            }
        }
        /* Spin briefly if another thread is finishing initialization of this slot */
        while (atomic_load_explicit(&g_types[s].state, memory_order_acquire) == 1u) {
            sched_yield();
        }
        if (atomic_load_explicit(&g_types[s].state, memory_order_acquire) == 2u &&
            g_types[s].type_tag == type_tag && g_types[s].drop_fn == drop_fn) {
            return &g_types[s];
        }
    }
    return NULL;
}

/* ============================================================================
 * Stack Aggregation Table
 * ============================================================================ */

static uint64_t pion_prof_stack_hash(uint32_t kind, uint16_t tag_id,
                                     const uintptr_t *frames, uint16_t depth) {
    uint64_t h = pion_prof_mix64(((uint64_t)kind << 32) | (uint64_t)tag_id);
    for (uint16_t i = 0; i < depth; i++) {
        h = pion_prof_mix64(h ^ (uint64_t)frames[i]);
    }
    return h ? h : 1ULL;
}

static void pion_prof_stack_rehash_locked(size_t new_bcap) {
    uint32_t *nb = (uint32_t *)calloc(new_bcap, sizeof(uint32_t));
    if (!nb) return;
    size_t mask = new_bcap - 1u;
    for (uint32_t i = 0; i < g_stacks_len; i++) {
        size_t idx = (size_t)g_stacks[i].hash & mask;
        while (nb[idx] != 0u) idx = (idx + 1u) & mask;
        nb[idx] = i + 1u;
    }
    free(g_stack_buckets);
    g_stack_buckets = nb;
    g_stack_bucket_cap = new_bcap;
}

/* Returns 1-based stack_id, or 0 if dropped/OOM. */
static uint32_t pion_prof_record_stack(uint32_t kind, uint16_t tag_id,
                                       uint64_t add_count, uint64_t add_bytes,
                                       const uintptr_t *frames, uint16_t depth) {
    uint64_t h = pion_prof_stack_hash(kind, tag_id, frames, depth);
    uint32_t stack_id = 0;
    pthread_mutex_lock(&g_stack_mu);
    if (g_stack_bucket_cap == 0) {
        pion_prof_stack_rehash_locked(1024u);
    } else if ((size_t)(g_stacks_len + 1u) * 10u >= g_stack_bucket_cap * 7u) {
        pion_prof_stack_rehash_locked(g_stack_bucket_cap * 2u);
    }
    if (g_stack_bucket_cap > 0) {
        size_t mask = g_stack_bucket_cap - 1u;
        size_t idx = (size_t)h & mask;
        int handled = 0;
        for (size_t step = 0; step < g_stack_bucket_cap; step++) {
            uint32_t id = g_stack_buckets[idx];
            if (id == 0u) {
                if (g_stacks_len >= PION_PROF_MAX_STACKS) {
                    if (kind == PION_STACK_RC) {
                        atomic_fetch_add_explicit(&g_dropped_rc, 1, memory_order_relaxed);
                    } else {
                        atomic_fetch_add_explicit(&g_dropped_alloc, 1, memory_order_relaxed);
                    }
                    handled = 1;
                    break;
                }
                if (g_stacks_len == g_stacks_cap) {
                    uint32_t ncap = g_stacks_cap ? g_stacks_cap * 2u : 512u;
                    if (ncap > PION_PROF_MAX_STACKS) ncap = PION_PROF_MAX_STACKS;
                    PionProfStackEntry *ns = (PionProfStackEntry *)realloc(
                        g_stacks, (size_t)ncap * sizeof(PionProfStackEntry));
                    if (!ns) break;
                    g_stacks = ns;
                    g_stacks_cap = ncap;
                }
                PionProfStackEntry *e = &g_stacks[g_stacks_len];
                e->hash = h;
                e->kind = kind;
                e->tag_id = tag_id;
                e->depth = depth;
                e->count = add_count;
                e->bytes = add_bytes;
                if (depth > 0) {
                    memcpy(e->frames, frames, (size_t)depth * sizeof(uintptr_t));
                }
                stack_id = ++g_stacks_len;
                g_stack_buckets[idx] = stack_id;
                handled = 1;
                break;
            }
            PionProfStackEntry *e = &g_stacks[id - 1u];
            if (e->hash == h && e->kind == kind && e->tag_id == tag_id &&
                e->depth == depth &&
                (depth == 0 || memcmp(e->frames, frames, (size_t)depth * sizeof(uintptr_t)) == 0)) {
                e->count += add_count;
                e->bytes += add_bytes;
                stack_id = id;
                handled = 1;
                break;
            }
            idx = (idx + 1u) & mask;
        }
        if (!handled) {
            if (kind == PION_STACK_RC) {
                atomic_fetch_add_explicit(&g_dropped_rc, 1, memory_order_relaxed);
            } else {
                atomic_fetch_add_explicit(&g_dropped_alloc, 1, memory_order_relaxed);
            }
        }
    } else {
        if (kind == PION_STACK_RC) {
            atomic_fetch_add_explicit(&g_dropped_rc, 1, memory_order_relaxed);
        } else {
            atomic_fetch_add_explicit(&g_dropped_alloc, 1, memory_order_relaxed);
        }
    }
    pthread_mutex_unlock(&g_stack_mu);
    return stack_id;
}

/* ============================================================================
 * Retained Live-Object Table (PION_PROF_RETAINED=1)
 * ============================================================================ */

static void pion_prof_retained_grow_locked(size_t new_cap) {
    PionProfRetainedSlot *nt = (PionProfRetainedSlot *)calloc(new_cap, sizeof(PionProfRetainedSlot));
    if (!nt) return;
    size_t mask = new_cap - 1u;
    for (size_t i = 0; i < g_retained_cap; i++) {
        if (g_retained_tab[i].state == 1u) {
            size_t idx = (size_t)pion_prof_mix64((uint64_t)(uintptr_t)g_retained_tab[i].ptr) & mask;
            while (nt[idx].state == 1u) idx = (idx + 1u) & mask;
            nt[idx] = g_retained_tab[i];
        }
    }
    free(g_retained_tab);
    g_retained_tab = nt;
    g_retained_cap = new_cap;
    g_retained_used = g_retained_len;
}

static void pion_prof_retained_put(void *ptr, size_t size, uint16_t tag_id, uint32_t stack_id) {
    pthread_mutex_lock(&g_retained_mu);
    if (g_retained_len >= PION_PROF_MAX_RETAINED) {
        atomic_store_explicit(&g_retained_truncated, 1, memory_order_relaxed);
        pthread_mutex_unlock(&g_retained_mu);
        return;
    }
    if (g_retained_cap == 0) {
        pion_prof_retained_grow_locked(1024u);
    } else if ((g_retained_used + 1u) * 10u >= g_retained_cap * 7u) {
        size_t ncap = (g_retained_len * 2u >= g_retained_cap) ? g_retained_cap * 2u : g_retained_cap;
        pion_prof_retained_grow_locked(ncap);
    }
    if (g_retained_cap > 0) {
        size_t mask = g_retained_cap - 1u;
        size_t idx = (size_t)pion_prof_mix64((uint64_t)(uintptr_t)ptr) & mask;
        size_t first_tomb = SIZE_MAX;
        int inserted = 0;
        for (size_t step = 0; step < g_retained_cap; step++) {
            uint8_t st = g_retained_tab[idx].state;
            if (st == 0u) {
                size_t dst = (first_tomb != SIZE_MAX) ? first_tomb : idx;
                if (first_tomb == SIZE_MAX) g_retained_used++;
                g_retained_tab[dst].ptr = ptr;
                g_retained_tab[dst].size = size;
                g_retained_tab[dst].tag_id = tag_id;
                g_retained_tab[dst].stack_id = stack_id;
                g_retained_tab[dst].state = 1u;
                g_retained_len++;
                inserted = 1;
                break;
            }
            if (st == 1u && g_retained_tab[idx].ptr == ptr) {
                g_retained_tab[idx].size = size;
                g_retained_tab[idx].tag_id = tag_id;
                g_retained_tab[idx].stack_id = stack_id;
                inserted = 1;
                break;
            }
            if (st == 2u && first_tomb == SIZE_MAX) {
                first_tomb = idx;
            }
            idx = (idx + 1u) & mask;
        }
        if (!inserted) {
            if (first_tomb != SIZE_MAX) {
                g_retained_tab[first_tomb].ptr = ptr;
                g_retained_tab[first_tomb].size = size;
                g_retained_tab[first_tomb].tag_id = tag_id;
                g_retained_tab[first_tomb].stack_id = stack_id;
                g_retained_tab[first_tomb].state = 1u;
                g_retained_len++;
            } else {
                atomic_store_explicit(&g_retained_truncated, 1, memory_order_relaxed);
            }
        }
    } else {
        atomic_store_explicit(&g_retained_truncated, 1, memory_order_relaxed);
    }
    pthread_mutex_unlock(&g_retained_mu);
}

static void pion_prof_retained_del(void *ptr) {
    pthread_mutex_lock(&g_retained_mu);
    if (g_retained_cap > 0) {
        size_t mask = g_retained_cap - 1u;
        size_t idx = (size_t)pion_prof_mix64((uint64_t)(uintptr_t)ptr) & mask;
        for (size_t step = 0; step < g_retained_cap; step++) {
            uint8_t st = g_retained_tab[idx].state;
            if (st == 0u) break;
            if (st == 1u && g_retained_tab[idx].ptr == ptr) {
                g_retained_tab[idx].state = 2u;
                g_retained_tab[idx].ptr = NULL;
                g_retained_len--;
                break;
            }
            idx = (idx + 1u) & mask;
        }
    }
    pthread_mutex_unlock(&g_retained_mu);
}

/* ============================================================================
 * Runtime Hooks
 * ============================================================================ */

static inline int pion_prof_should_record(uint32_t mode_bit) {
    return atomic_load_explicit(&g_enabled, memory_order_acquire) &&
           !atomic_load_explicit(&g_paused, memory_order_acquire) &&
           (g_modes & mode_bit) != 0 &&
           !tls_prof_in_hook;
}

void pion_prof_on_reserved_add(size_t bytes) {
    if (!atomic_load_explicit(&g_enabled, memory_order_acquire) || tls_prof_in_hook) return;
    uint64_t cur = atomic_fetch_add_explicit(&g_reserved_bytes, (uint64_t)bytes, memory_order_relaxed) + (uint64_t)bytes;
    uint64_t peak = atomic_load_explicit(&g_peak_reserved_bytes, memory_order_relaxed);
    while (cur > peak) {
        if (atomic_compare_exchange_weak_explicit(&g_peak_reserved_bytes, &peak, cur,
                                                  memory_order_relaxed, memory_order_relaxed)) {
            break;
        }
    }
}

void pion_prof_on_reserved_sub(size_t bytes) {
    if (!atomic_load_explicit(&g_enabled, memory_order_acquire) || tls_prof_in_hook) return;
    uint64_t cur = atomic_load_explicit(&g_reserved_bytes, memory_order_relaxed);
    for (;;) {
        uint64_t next = (cur >= (uint64_t)bytes) ? (cur - (uint64_t)bytes) : 0ULL;
        if (atomic_compare_exchange_weak_explicit(&g_reserved_bytes, &cur, next,
                                                  memory_order_relaxed, memory_order_relaxed)) {
            break;
        }
    }
}

void pion_prof_on_alloc(void *obj, uint32_t payload_size, size_t alloc_bytes,
                        uint16_t type_tag, void *drop_fn, int is_large) {
    (void)payload_size;
    if (!atomic_load_explicit(&g_enabled, memory_order_acquire) || tls_prof_in_hook) return;
    tls_prof_in_hook = 1;
    if (is_large) {
        pion_prof_large_put(obj, alloc_bytes);
    }
    if (!atomic_load_explicit(&g_paused, memory_order_acquire) && (g_modes & PION_PROF_ALLOC)) {
        uint16_t tid = (type_tag < PION_PROF_MAX_TAGS) ? type_tag : 0u;
        atomic_fetch_add_explicit(&g_tags[tid].alloc_count, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&g_tags[tid].alloc_bytes, (uint64_t)alloc_bytes, memory_order_relaxed);

        PionProfTypeSlot *ts = pion_prof_type_slot(type_tag, (uintptr_t)drop_fn);
        if (ts) {
            atomic_fetch_add_explicit(&ts->alloc_count, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&ts->alloc_bytes, (uint64_t)alloc_bytes, memory_order_relaxed);
        }

        uint32_t stack_id = 0;
        uint64_t seq = atomic_fetch_add_explicit(&g_alloc_seq, 1, memory_order_relaxed);
        if (g_sample_rate <= 1 || (seq % g_sample_rate) == 0) {
            uintptr_t frames[PION_PROF_MAX_FRAMES];
            uint16_t depth = pion_prof_capture_stack(frames, PION_PROF_MAX_FRAMES, 1);
            stack_id = pion_prof_record_stack(PION_STACK_ALLOC, tid, 1, (uint64_t)alloc_bytes, frames, depth);
        }
        if (g_retained_enabled) {
            pion_prof_retained_put(obj, alloc_bytes, tid, stack_id);
        }
    }
    tls_prof_in_hook = 0;
}

void pion_prof_on_retire(void *obj, size_t alloc_bytes, uint16_t type_tag,
                         void *drop_fn, int is_large) {
    if (!atomic_load_explicit(&g_enabled, memory_order_acquire) || tls_prof_in_hook) return;
    tls_prof_in_hook = 1;
    if (is_large) {
        size_t tracked = pion_prof_large_take(obj);
        if (tracked > 0) {
            alloc_bytes = tracked;
            uint64_t cur = atomic_load_explicit(&g_reserved_bytes, memory_order_relaxed);
            for (;;) {
                uint64_t next = (cur >= (uint64_t)tracked) ? (cur - (uint64_t)tracked) : 0ULL;
                if (atomic_compare_exchange_weak_explicit(&g_reserved_bytes, &cur, next,
                                                          memory_order_relaxed, memory_order_relaxed)) {
                    break;
                }
            }
        }
    }
    if (g_retained_enabled) {
        pion_prof_retained_del(obj);
    }
    if (!atomic_load_explicit(&g_paused, memory_order_acquire) && (g_modes & PION_PROF_ALLOC)) {
        uint16_t tid = (type_tag < PION_PROF_MAX_TAGS) ? type_tag : 0u;
        atomic_fetch_add_explicit(&g_tags[tid].free_count, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&g_tags[tid].free_bytes, (uint64_t)alloc_bytes, memory_order_relaxed);

        PionProfTypeSlot *ts = pion_prof_type_slot(type_tag, (uintptr_t)drop_fn);
        if (ts) {
            atomic_fetch_add_explicit(&ts->free_count, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&ts->free_bytes, (uint64_t)alloc_bytes, memory_order_relaxed);
        }
    }
    tls_prof_in_hook = 0;
}

void pion_prof_on_backing_alloc(void *ptr, size_t bytes) {
    (void)ptr;
    if (!pion_prof_should_record(PION_PROF_ALLOC)) return;
    tls_prof_in_hook = 1;
    atomic_fetch_add_explicit(&g_backing_alloc_count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_backing_alloc_bytes, (uint64_t)bytes, memory_order_relaxed);
    uint64_t seq = atomic_fetch_add_explicit(&g_backing_seq, 1, memory_order_relaxed);
    if (g_sample_rate <= 1 || (seq % g_sample_rate) == 0) {
        uintptr_t frames[PION_PROF_MAX_FRAMES];
        uint16_t depth = pion_prof_capture_stack(frames, PION_PROF_MAX_FRAMES, 1);
        (void)pion_prof_record_stack(PION_STACK_BACKING, 0u, 1, (uint64_t)bytes, frames, depth);
    }
    tls_prof_in_hook = 0;
}

void pion_prof_on_backing_free(void *ptr, size_t bytes) {
    (void)ptr;
    if (!pion_prof_should_record(PION_PROF_ALLOC)) return;
    atomic_fetch_add_explicit(&g_backing_free_bytes, (uint64_t)bytes, memory_order_relaxed);
}

void pion_prof_on_backing_realloc(int had_old, size_t old_bytes,
                                  void *new_ptr, size_t new_bytes) {
    (void)new_ptr;
    if (!atomic_load_explicit(&g_enabled, memory_order_acquire) || tls_prof_in_hook) return;
    if (!had_old) {
        pion_prof_on_reserved_add(new_bytes);
    } else if (new_bytes > old_bytes) {
        pion_prof_on_reserved_add(new_bytes - old_bytes);
    } else if (old_bytes > new_bytes) {
        pion_prof_on_reserved_sub(old_bytes - new_bytes);
    }
    if (!pion_prof_should_record(PION_PROF_ALLOC)) return;
    tls_prof_in_hook = 1;
    if (had_old && old_bytes > 0) {
        atomic_fetch_add_explicit(&g_backing_free_bytes, (uint64_t)old_bytes, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&g_backing_alloc_count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_backing_alloc_bytes, (uint64_t)new_bytes, memory_order_relaxed);
    uint64_t seq = atomic_fetch_add_explicit(&g_backing_seq, 1, memory_order_relaxed);
    if (g_sample_rate <= 1 || (seq % g_sample_rate) == 0) {
        uintptr_t frames[PION_PROF_MAX_FRAMES];
        uint16_t depth = pion_prof_capture_stack(frames, PION_PROF_MAX_FRAMES, 1);
        (void)pion_prof_record_stack(PION_STACK_BACKING, 0u, 1, (uint64_t)new_bytes, frames, depth);
    }
    tls_prof_in_hook = 0;
}

void pion_prof_on_rc_inc(uint16_t type_tag, int is_atomic, int is_immortal) {
    if (!pion_prof_should_record(PION_PROF_RC)) return;
    uint16_t tid = (type_tag < PION_PROF_MAX_TAGS) ? type_tag : 0u;
    if (is_immortal) {
        atomic_fetch_add_explicit(&g_tags[tid].rc_immortal, 1, memory_order_relaxed);
        return;
    }
    if (is_atomic) {
        atomic_fetch_add_explicit(&g_tags[tid].rc_atomic_inc, 1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&g_tags[tid].rc_inc, 1, memory_order_relaxed);
    }
    tls_prof_in_hook = 1;
    uint64_t seq = atomic_fetch_add_explicit(&g_rc_seq, 1, memory_order_relaxed);
    if (g_sample_rate <= 1 || (seq % g_sample_rate) == 0) {
        uintptr_t frames[PION_PROF_MAX_FRAMES];
        uint16_t depth = pion_prof_capture_stack(frames, PION_PROF_MAX_FRAMES, 1);
        (void)pion_prof_record_stack(PION_STACK_RC, tid, 1, 0, frames, depth);
    }
    tls_prof_in_hook = 0;
}

void pion_prof_on_rc_dec(uint16_t type_tag, int is_atomic, int is_immortal) {
    if (!pion_prof_should_record(PION_PROF_RC)) return;
    uint16_t tid = (type_tag < PION_PROF_MAX_TAGS) ? type_tag : 0u;
    if (is_immortal) {
        atomic_fetch_add_explicit(&g_tags[tid].rc_immortal, 1, memory_order_relaxed);
        return;
    }
    if (is_atomic) {
        atomic_fetch_add_explicit(&g_tags[tid].rc_atomic_dec, 1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&g_tags[tid].rc_dec, 1, memory_order_relaxed);
    }
    tls_prof_in_hook = 1;
    uint64_t seq = atomic_fetch_add_explicit(&g_rc_seq, 1, memory_order_relaxed);
    if (g_sample_rate <= 1 || (seq % g_sample_rate) == 0) {
        uintptr_t frames[PION_PROF_MAX_FRAMES];
        uint16_t depth = pion_prof_capture_stack(frames, PION_PROF_MAX_FRAMES, 1);
        (void)pion_prof_record_stack(PION_STACK_RC, tid, 1, 0, frames, depth);
    }
    tls_prof_in_hook = 0;
}

void pion_prof_on_rc_destroy(uint16_t type_tag) {
    if (!pion_prof_should_record(PION_PROF_RC)) return;
    uint16_t tid = (type_tag < PION_PROF_MAX_TAGS) ? type_tag : 0u;
    atomic_fetch_add_explicit(&g_tags[tid].rc_destroy, 1, memory_order_relaxed);
}

void pion_prof_on_rc_freeze(uint16_t type_tag, int is_immortal) {
    if (!pion_prof_should_record(PION_PROF_RC)) return;
    uint16_t tid = (type_tag < PION_PROF_MAX_TAGS) ? type_tag : 0u;
    if (is_immortal) {
        atomic_fetch_add_explicit(&g_tags[tid].rc_immortal, 1, memory_order_relaxed);
    }
}

/* ============================================================================
 * Lifecycle: Init, Pause, Resume, Reset, Flush
 * ============================================================================ */

static void pion_prof_atexit_cb(void) {
    pion_prof_flush();
}

__attribute__((constructor))
void pion_prof_init(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&g_init_done, &expected, 1,
                                                 memory_order_acq_rel, memory_order_acquire)) {
        return;
    }
    tls_prof_in_hook = 1;
    pion_prof_thread_init();

    const char *out = getenv("PION_PROF_OUT");
    const char *modes_s = getenv("PION_PROF_MODES");
    const char *hz_s = getenv("PION_PROF_HZ");
    const char *sr_s = getenv("PION_PROF_SAMPLE_RATE");
    const char *ret_s = getenv("PION_PROF_RETAINED");
    const char *inh_s = getenv("PION_PROF_INHERIT");

    int inherit = (inh_s && strcmp(inh_s, "1") == 0);
    int have_out = (out && out[0] != '\0');
    if (have_out) {
        snprintf(g_out_path, sizeof(g_out_path), "%s", out);
        uint32_t modes = PION_PROF_CPU | PION_PROF_ALLOC;
        if (modes_s && modes_s[0] != '\0') {
            long m = strtol(modes_s, NULL, 10);
            if (m >= 1 && m <= 7) modes = (uint32_t)m;
        }
        g_modes = modes;
        if (hz_s && hz_s[0] != '\0') {
            long h = strtol(hz_s, NULL, 10);
            if (h >= 10 && h <= 10000) g_hz = (uint32_t)h;
        }
        if (sr_s && sr_s[0] != '\0') {
            long sr = strtol(sr_s, NULL, 10);
            if (sr >= 1) g_sample_rate = (uint64_t)sr;
        }
        g_retained_enabled = (ret_s && strcmp(ret_s, "1") == 0) ? 1 : 0;
    }

    if (!inherit) {
        unsetenv("PION_PROF_OUT");
        unsetenv("PION_PROF_MODES");
        unsetenv("PION_PROF_HZ");
        unsetenv("PION_PROF_SAMPLE_RATE");
        unsetenv("PION_PROF_RETAINED");
        unsetenv("PION_PROF_INHERIT");
    }

    if (have_out) {
        g_wall_start_us = pion_prof_now_wall_us();
        g_cpu_start_us = pion_prof_now_cpu_us();
        atomic_store_explicit(&g_paused, 0, memory_order_release);
        atomic_store_explicit(&g_flushed, 0, memory_order_release);
        atomic_store_explicit(&g_enabled, 1, memory_order_release);
        pion_prof_cpu_start();
        atexit(pion_prof_atexit_cb);
    }

    tls_prof_in_hook = 0;
}

void pion_prof_pause(void) {
    if (!atomic_load_explicit(&g_enabled, memory_order_acquire)) return;
    pthread_mutex_lock(&g_ctrl_mu);
    if (!atomic_load_explicit(&g_paused, memory_order_acquire)) {
        atomic_store_explicit(&g_paused, 1, memory_order_release);
        atomic_store_explicit(&g_prof_active, 0, memory_order_release);
        if (g_cpu_installed) {
            pion_prof_timer_disarm();
            while (atomic_load_explicit(&g_in_handler, memory_order_acquire) != 0) {
                sched_yield();
            }
        }
        uint64_t nw = pion_prof_now_wall_us();
        uint64_t nc = pion_prof_now_cpu_us();
        if (nw >= g_wall_start_us) g_wall_accum_us += (nw - g_wall_start_us);
        if (nc >= g_cpu_start_us) g_cpu_accum_us += (nc - g_cpu_start_us);
    }
    pthread_mutex_unlock(&g_ctrl_mu);
}

void pion_prof_resume(void) {
    if (!atomic_load_explicit(&g_enabled, memory_order_acquire)) return;
    pthread_mutex_lock(&g_ctrl_mu);
    if (!g_flush_done && atomic_load_explicit(&g_paused, memory_order_acquire)) {
        g_wall_start_us = pion_prof_now_wall_us();
        g_cpu_start_us = pion_prof_now_cpu_us();
        atomic_store_explicit(&g_paused, 0, memory_order_release);
        if (g_cpu_installed) {
            atomic_store_explicit(&g_prof_active, 1, memory_order_release);
            pion_prof_timer_arm(g_hz);
        }
    }
    pthread_mutex_unlock(&g_ctrl_mu);
}

void pion_prof_reset(void) {
    if (!atomic_load_explicit(&g_enabled, memory_order_acquire)) return;
    int was_paused = atomic_load_explicit(&g_paused, memory_order_acquire);
    pion_prof_pause();

    pthread_mutex_lock(&g_ctrl_mu);
    tls_prof_in_hook = 1;
    for (uint32_t i = 0; i < PION_PROF_CPU_SLOTS; i++) {
        atomic_store_explicit(&g_cpu_table[i].pc, 0, memory_order_relaxed);
        atomic_store_explicit(&g_cpu_table[i].count, 0, memory_order_relaxed);
    }
    atomic_store_explicit(&g_cpu_dropped, 0, memory_order_relaxed);

    for (uint32_t i = 0; i < PION_PROF_MAX_TAGS; i++) {
        atomic_store_explicit(&g_tags[i].alloc_count, 0, memory_order_relaxed);
        atomic_store_explicit(&g_tags[i].alloc_bytes, 0, memory_order_relaxed);
        atomic_store_explicit(&g_tags[i].free_count, 0, memory_order_relaxed);
        atomic_store_explicit(&g_tags[i].free_bytes, 0, memory_order_relaxed);
        atomic_store_explicit(&g_tags[i].rc_inc, 0, memory_order_relaxed);
        atomic_store_explicit(&g_tags[i].rc_dec, 0, memory_order_relaxed);
        atomic_store_explicit(&g_tags[i].rc_atomic_inc, 0, memory_order_relaxed);
        atomic_store_explicit(&g_tags[i].rc_atomic_dec, 0, memory_order_relaxed);
        atomic_store_explicit(&g_tags[i].rc_destroy, 0, memory_order_relaxed);
        atomic_store_explicit(&g_tags[i].rc_immortal, 0, memory_order_relaxed);
    }
    for (uint32_t i = 0; i < PION_PROF_TYPE_SLOTS; i++) {
        atomic_store_explicit(&g_types[i].alloc_count, 0, memory_order_relaxed);
        atomic_store_explicit(&g_types[i].alloc_bytes, 0, memory_order_relaxed);
        atomic_store_explicit(&g_types[i].free_count, 0, memory_order_relaxed);
        atomic_store_explicit(&g_types[i].free_bytes, 0, memory_order_relaxed);
    }

    atomic_store_explicit(&g_backing_alloc_bytes, 0, memory_order_relaxed);
    atomic_store_explicit(&g_backing_alloc_count, 0, memory_order_relaxed);
    atomic_store_explicit(&g_backing_free_bytes, 0, memory_order_relaxed);
    atomic_store_explicit(&g_peak_reserved_bytes,
                          atomic_load_explicit(&g_reserved_bytes, memory_order_relaxed),
                          memory_order_relaxed);
    atomic_store_explicit(&g_alloc_seq, 0, memory_order_relaxed);
    atomic_store_explicit(&g_rc_seq, 0, memory_order_relaxed);
    atomic_store_explicit(&g_backing_seq, 0, memory_order_relaxed);
    atomic_store_explicit(&g_dropped_alloc, 0, memory_order_relaxed);
    atomic_store_explicit(&g_dropped_rc, 0, memory_order_relaxed);
    atomic_store_explicit(&g_retained_truncated, 0, memory_order_relaxed);

    pthread_mutex_lock(&g_stack_mu);
    g_stacks_len = 0;
    if (g_stack_buckets && g_stack_bucket_cap > 0) {
        memset(g_stack_buckets, 0, g_stack_bucket_cap * sizeof(uint32_t));
    }
    pthread_mutex_unlock(&g_stack_mu);

    pthread_mutex_lock(&g_retained_mu);
    g_retained_len = 0;
    g_retained_used = 0;
    if (g_retained_tab && g_retained_cap > 0) {
        memset(g_retained_tab, 0, g_retained_cap * sizeof(PionProfRetainedSlot));
    }
    pthread_mutex_unlock(&g_retained_mu);

    g_wall_accum_us = 0;
    g_cpu_accum_us = 0;
    g_wall_start_us = pion_prof_now_wall_us();
    g_cpu_start_us = pion_prof_now_cpu_us();
    g_flush_done = 0;
    atomic_store_explicit(&g_flushed, 0, memory_order_release);
    tls_prof_in_hook = 0;
    pthread_mutex_unlock(&g_ctrl_mu);

    if (!was_paused) {
        pion_prof_resume();
    }
}

static void pion_prof_write_frames(FILE *f, const uintptr_t *frames, uint16_t depth) {
    if (depth == 0) {
        fputs("0x0", f);
        return;
    }
    for (uint16_t i = 0; i < depth; i++) {
        if (i > 0) fputc(',', f);
        fprintf(f, "0x%" PRIxPTR, frames[i]);
    }
}

typedef struct {
    uint16_t tag_id;
    uint32_t stack_id;
    uint64_t count;
    uint64_t bytes;
} PionProfInuseAgg;

void pion_prof_flush(void) {
    if (tls_prof_in_hook) return;
    if (!atomic_load_explicit(&g_enabled, memory_order_acquire)) return;
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&g_flushed, &expected, 1,
                                                 memory_order_acq_rel, memory_order_acquire)) {
        return;
    }

    tls_prof_in_hook = 1;

    pthread_mutex_lock(&g_ctrl_mu);
    g_flush_done = 1;
    pion_prof_cpu_stop_locked();
    uint64_t wall_us = g_wall_accum_us;
    uint64_t cpu_us = g_cpu_accum_us;
    if (!atomic_load_explicit(&g_paused, memory_order_acquire)) {
        uint64_t nw = pion_prof_now_wall_us();
        uint64_t nc = pion_prof_now_cpu_us();
        if (nw >= g_wall_start_us) wall_us += (nw - g_wall_start_us);
        if (nc >= g_cpu_start_us) cpu_us += (nc - g_cpu_start_us);
    }
    atomic_store_explicit(&g_paused, 1, memory_order_release);
    pthread_mutex_unlock(&g_ctrl_mu);

    char tmp_path[4160];
    int fd = -1;
    for (unsigned attempt = 0; attempt < 32u; attempt++) {
        snprintf(tmp_path, sizeof(tmp_path), "%s.tmp.%ld.%u",
                 g_out_path, (long)getpid(), attempt);
        int flags = O_WRONLY | O_CREAT | O_EXCL;
#ifdef O_NOFOLLOW
        flags |= O_NOFOLLOW;
#endif
        fd = open(tmp_path, flags, 0600);
        if (fd >= 0) break;
        if (errno != EEXIST) break;
    }
    if (fd < 0) {
        fprintf(stderr, "pion_prof: failed to create temp file for %s: %s\n",
                g_out_path, strerror(errno));
        tls_prof_in_hook = 0;
        return;
    }
    FILE *f = fdopen(fd, "wb");
    if (!f) {
        close(fd);
        (void)unlink(tmp_path);
        fprintf(stderr, "pion_prof: fdopen failed for %s\n", g_out_path);
        tls_prof_in_hook = 0;
        return;
    }

    uint64_t peak_rss_kb = pion_prof_peak_rss_kb();
    uint64_t dropped_cpu = atomic_load_explicit(&g_cpu_dropped, memory_order_relaxed);
    uint64_t dropped_alloc = atomic_load_explicit(&g_dropped_alloc, memory_order_relaxed);
    uint64_t dropped_rc = atomic_load_explicit(&g_dropped_rc, memory_order_relaxed);
    int ret_trunc = atomic_load_explicit(&g_retained_truncated, memory_order_relaxed);

    uint64_t res_bytes = atomic_load_explicit(&g_reserved_bytes, memory_order_relaxed);
    uint64_t peak_res_bytes = atomic_load_explicit(&g_peak_reserved_bytes, memory_order_relaxed);
    uint64_t b_alloc_bytes = atomic_load_explicit(&g_backing_alloc_bytes, memory_order_relaxed);
    uint64_t b_alloc_count = atomic_load_explicit(&g_backing_alloc_count, memory_order_relaxed);
    uint64_t b_free_bytes = atomic_load_explicit(&g_backing_free_bytes, memory_order_relaxed);
    uint64_t b_inuse_bytes = (b_alloc_bytes >= b_free_bytes) ? (b_alloc_bytes - b_free_bytes) : 0ULL;

    fprintf(f, "PIONPROF 1\n");
    fprintf(f,
            "META target=%s modes=%" PRIu32 " build_modes=%" PRIu32
            " cpu_stack_mode=pc_only sample_rate=%" PRIu64 " hz=%" PRIu32
            " retained=%d wall_us=%" PRIu64 " cpu_us=%" PRIu64
            " peak_rss_kb=%" PRIu64 " dropped_cpu=%" PRIu64
            " dropped_alloc=%" PRIu64 " dropped_rc=%" PRIu64
            " retained_truncated=%d\n",
            pion_prof_target_name(), g_modes, pion_prof_build_modes,
            g_sample_rate, g_hz, g_retained_enabled,
            wall_us, cpu_us, peak_rss_kb,
            dropped_cpu, dropped_alloc, dropped_rc, ret_trunc);
    fprintf(f,
            "META reserved_bytes=%" PRIu64 " peak_reserved_bytes=%" PRIu64
            " backing_alloc_bytes=%" PRIu64 " backing_alloc_count=%" PRIu64
            " backing_free_bytes=%" PRIu64 " backing_inuse_bytes=%" PRIu64 "\n",
            res_bytes, peak_res_bytes,
            b_alloc_bytes, b_alloc_count, b_free_bytes, b_inuse_bytes);
    fprintf(f, "ANCHOR 0x%" PRIxPTR " pion_prof_anchor\n", (uintptr_t)&pion_prof_anchor);

    char exe_path[4096];
    pion_prof_self_exe(exe_path, sizeof(exe_path));
    fprintf(f, "BIN %s\n", exe_path[0] ? exe_path : "<unknown>");

    for (uint32_t i = 0; i < PION_PROF_MAX_TAGS; i++) {
        uint64_t ac = atomic_load_explicit(&g_tags[i].alloc_count, memory_order_relaxed);
        uint64_t ab = atomic_load_explicit(&g_tags[i].alloc_bytes, memory_order_relaxed);
        uint64_t fc = atomic_load_explicit(&g_tags[i].free_count, memory_order_relaxed);
        uint64_t fb = atomic_load_explicit(&g_tags[i].free_bytes, memory_order_relaxed);
        uint64_t ri = atomic_load_explicit(&g_tags[i].rc_inc, memory_order_relaxed);
        uint64_t rd = atomic_load_explicit(&g_tags[i].rc_dec, memory_order_relaxed);
        uint64_t rai = atomic_load_explicit(&g_tags[i].rc_atomic_inc, memory_order_relaxed);
        uint64_t rad = atomic_load_explicit(&g_tags[i].rc_atomic_dec, memory_order_relaxed);
        uint64_t rdes = atomic_load_explicit(&g_tags[i].rc_destroy, memory_order_relaxed);
        uint64_t rimm = atomic_load_explicit(&g_tags[i].rc_immortal, memory_order_relaxed);
        if (ac || ab || fc || fb || ri || rd || rai || rad || rdes || rimm) {
            uint64_t ic = (ac >= fc) ? (ac - fc) : 0ULL;
            uint64_t ib = (ab >= fb) ? (ab - fb) : 0ULL;
            fprintf(f,
                    "TAG %" PRIu32 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64
                    " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64
                    " %" PRIu64 " %" PRIu64 " %" PRIu64 "\n",
                    i, ac, ab, fc, fb, ic, ib, ri, rd, rai, rad, rdes, rimm);
        }
    }

    for (uint32_t i = 0; i < PION_PROF_TYPE_SLOTS; i++) {
        if (atomic_load_explicit(&g_types[i].state, memory_order_acquire) != 2u) continue;
        uint64_t ac = atomic_load_explicit(&g_types[i].alloc_count, memory_order_relaxed);
        uint64_t ab = atomic_load_explicit(&g_types[i].alloc_bytes, memory_order_relaxed);
        uint64_t fc = atomic_load_explicit(&g_types[i].free_count, memory_order_relaxed);
        uint64_t fb = atomic_load_explicit(&g_types[i].free_bytes, memory_order_relaxed);
        if (ac || ab || fc || fb) {
            uint64_t ic = (ac >= fc) ? (ac - fc) : 0ULL;
            uint64_t ib = (ab >= fb) ? (ab - fb) : 0ULL;
            fprintf(f,
                    "TYPE %" PRIu16 " 0x%" PRIxPTR " %" PRIu64 " %" PRIu64
                    " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 "\n",
                    g_types[i].type_tag, g_types[i].drop_fn, ac, ab, fc, fb, ic, ib);
        }
    }

    for (uint32_t i = 0; i < PION_PROF_CPU_SLOTS; i++) {
        uintptr_t pc = atomic_load_explicit(&g_cpu_table[i].pc, memory_order_relaxed);
        uint64_t cnt = atomic_load_explicit(&g_cpu_table[i].count, memory_order_relaxed);
        if (pc != 0 && cnt > 0) {
            fprintf(f, "CPU_PC 0x%" PRIxPTR " %" PRIu64 "\n", pc, cnt);
        }
    }

    pthread_mutex_lock(&g_stack_mu);
    for (uint32_t i = 0; i < g_stacks_len; i++) {
        const PionProfStackEntry *e = &g_stacks[i];
        const char *kname = (e->kind == PION_STACK_ALLOC) ? "alloc"
                          : (e->kind == PION_STACK_RC) ? "rc"
                          : "backing";
        fprintf(f, "STACK %s %" PRIu16 " %" PRIu64 " %" PRIu64 " ",
                kname, e->tag_id, e->count, e->bytes);
        pion_prof_write_frames(f, e->frames, e->depth);
        fputc('\n', f);
    }

    if (g_retained_enabled) {
        pthread_mutex_lock(&g_retained_mu);
        if (g_retained_len > 0 && g_retained_cap > 0) {
            /* Aggregate retained live objects by (tag_id, stack_id) */
            size_t agg_cap = 256u;
            while (agg_cap < g_retained_len * 2u && agg_cap < 131072u) agg_cap *= 2u;
            PionProfInuseAgg *agg = (PionProfInuseAgg *)calloc(agg_cap, sizeof(PionProfInuseAgg));
            if (agg) {
                size_t amask = agg_cap - 1u;
                for (size_t i = 0; i < g_retained_cap; i++) {
                    if (g_retained_tab[i].state != 1u) continue;
                    uint16_t tid = g_retained_tab[i].tag_id;
                    uint32_t sid = g_retained_tab[i].stack_id;
                    uint64_t h = pion_prof_mix64(((uint64_t)tid << 32) | (uint64_t)sid);
                    size_t idx = (size_t)h & amask;
                    for (size_t probe = 0; probe < agg_cap; probe++) {
                        size_t s = (idx + probe) & amask;
                        if (agg[s].count == 0) {
                            agg[s].tag_id = tid;
                            agg[s].stack_id = sid;
                            agg[s].count = 1;
                            agg[s].bytes = (uint64_t)g_retained_tab[i].size;
                            break;
                        }
                        if (agg[s].tag_id == tid && agg[s].stack_id == sid) {
                            agg[s].count += 1;
                            agg[s].bytes += (uint64_t)g_retained_tab[i].size;
                            break;
                        }
                    }
                }
                for (size_t i = 0; i < agg_cap; i++) {
                    if (agg[i].count == 0) continue;
                    fprintf(f, "STACK inuse %" PRIu16 " %" PRIu64 " %" PRIu64 " ",
                            agg[i].tag_id, agg[i].count, agg[i].bytes);
                    if (agg[i].stack_id > 0 && agg[i].stack_id <= g_stacks_len) {
                        const PionProfStackEntry *se = &g_stacks[agg[i].stack_id - 1u];
                        pion_prof_write_frames(f, se->frames, se->depth);
                    } else {
                        fputs("0x0", f);
                    }
                    fputc('\n', f);
                }
                free(agg);
            }
        }
        pthread_mutex_unlock(&g_retained_mu);
    }
    pthread_mutex_unlock(&g_stack_mu);

    int write_err = ferror(f) != 0;
    if (fflush(f) != 0) write_err = 1;
    if (fclose(f) != 0) write_err = 1;
    if (write_err) {
        (void)unlink(tmp_path);
        fprintf(stderr, "pion_prof: failed to write %s\n", g_out_path);
    } else if (rename(tmp_path, g_out_path) != 0) {
        int saved_e = errno;
        (void)unlink(tmp_path);
        fprintf(stderr, "pion_prof: failed to rename temp file to %s: %s\n",
                g_out_path, strerror(saved_e));
    }
    tls_prof_in_hook = 0;
}

#endif /* _WIN32 */
