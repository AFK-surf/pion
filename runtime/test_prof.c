/* test_prof.c — Comprehensive C unit & stress tests for Pion native profiler runtime. */
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif

#include "pion_rt.h"
#include "pion_prof.h"

#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
int main(void) {
    pion_prof_anchor();
    pion_prof_init();
    pion_prof_pause();
    pion_prof_resume();
    pion_prof_reset();
    pion_prof_flush();
    printf("test_prof (win32 stub): PASS\n");
    return 0;
}
#else

#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* ============================================================================
 * Helpers for parsing PIONPROF 1 files
 * ============================================================================ */

typedef struct {
    int saw_header;
    int saw_meta1;
    int saw_meta2;
    int saw_anchor;
    int saw_bin;
    uintptr_t anchor_addr;
    uint64_t reserved_bytes;
    uint64_t peak_reserved_bytes;
    uint64_t backing_alloc_bytes;
    uint64_t backing_alloc_count;
    uint64_t backing_free_bytes;
    uint64_t backing_inuse_bytes;
    uint64_t cpu_samples;
    uint64_t cpu_pc_lines;
    uint64_t stack_alloc_lines;
    uint64_t stack_rc_lines;
    uint64_t stack_backing_lines;
    uint64_t stack_inuse_lines;
    uint64_t stack_inuse_count;
    uint64_t stack_inuse_bytes;
    int tag_seen[32];
    uint64_t tag_alloc_cnt[32];
    uint64_t tag_alloc_bytes[32];
    uint64_t tag_free_cnt[32];
    uint64_t tag_free_bytes[32];
    uint64_t tag_inuse_cnt[32];
    uint64_t tag_inuse_bytes[32];
    uint64_t tag_rc_inc[32];
    uint64_t tag_rc_dec[32];
    uint64_t tag_rc_atomic_inc[32];
    uint64_t tag_rc_atomic_dec[32];
    uint64_t tag_rc_destroy[32];
    uint64_t tag_rc_immortal[32];
    int type_lines;
    int type_mismatch;
    int saw_custom_drop_type;
} ParsedProf;

static int parse_u64_kv(const char *line, const char *key, uint64_t *out) {
    const char *p = strstr(line, key);
    if (!p) return 0;
    p += strlen(key);
    char *end = NULL;
    unsigned long long v = strtoull(p, &end, 10);
    if (end == p) return 0;
    *out = (uint64_t)v;
    return 1;
}

static void parse_prof_file(const char *path, ParsedProf *out) {
    memset(out, 0, sizeof(*out));
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "FAIL: cannot open profile file: %s\n", path);
        exit(1);
    }
    char line[8192];
    int lineno = 0;
    while (fgets(line, sizeof(line), f)) {
        lineno++;
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
            line[--len] = '\0';
        }
        if (lineno == 1) {
            if (strcmp(line, "PIONPROF 1") == 0) out->saw_header = 1;
            continue;
        }
        if (strncmp(line, "META target=", 12) == 0) {
            out->saw_meta1 = 1;
            assert(strstr(line, "cpu_stack_mode=pc_only") != NULL);
            assert(strstr(line, "wall_us=") != NULL);
            assert(strstr(line, "cpu_us=") != NULL);
            assert(strstr(line, "peak_rss_kb=") != NULL);
            assert(strstr(line, "dropped_cpu=") != NULL);
            assert(strstr(line, "dropped_alloc=") != NULL);
            assert(strstr(line, "dropped_rc=") != NULL);
            assert(strstr(line, "retained_truncated=") != NULL);
        } else if (strncmp(line, "META reserved_bytes=", 20) == 0) {
            out->saw_meta2 = 1;
            assert(parse_u64_kv(line, "reserved_bytes=", &out->reserved_bytes));
            assert(parse_u64_kv(line, "peak_reserved_bytes=", &out->peak_reserved_bytes));
            assert(parse_u64_kv(line, "backing_alloc_bytes=", &out->backing_alloc_bytes));
            assert(parse_u64_kv(line, "backing_alloc_count=", &out->backing_alloc_count));
            assert(parse_u64_kv(line, "backing_free_bytes=", &out->backing_free_bytes));
            assert(parse_u64_kv(line, "backing_inuse_bytes=", &out->backing_inuse_bytes));
        } else if (strncmp(line, "ANCHOR ", 7) == 0) {
            unsigned long long addr = 0;
            char sym[128] = {0};
            if (sscanf(line + 7, "0x%llx %127s", &addr, sym) == 2 &&
                strcmp(sym, "pion_prof_anchor") == 0 && addr != 0) {
                out->saw_anchor = 1;
                out->anchor_addr = (uintptr_t)addr;
            }
        } else if (strncmp(line, "BIN ", 4) == 0) {
            if (line[4] != '\0') out->saw_bin = 1;
        } else if (strncmp(line, "TAG ", 4) == 0) {
            unsigned tid = 0;
            unsigned long long ac, ab, fc, fb, ic, ib, ri, rd, rai, rad, rdes, rimm;
            int n = sscanf(line + 4,
                           "%u %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
                           &tid, &ac, &ab, &fc, &fb, &ic, &ib, &ri, &rd, &rai, &rad, &rdes, &rimm);
            assert(n == 13);
            if (tid < 32) {
                out->tag_seen[tid] = 1;
                out->tag_alloc_cnt[tid] = (uint64_t)ac;
                out->tag_alloc_bytes[tid] = (uint64_t)ab;
                out->tag_free_cnt[tid] = (uint64_t)fc;
                out->tag_free_bytes[tid] = (uint64_t)fb;
                out->tag_inuse_cnt[tid] = (uint64_t)ic;
                out->tag_inuse_bytes[tid] = (uint64_t)ib;
                out->tag_rc_inc[tid] = (uint64_t)ri;
                out->tag_rc_dec[tid] = (uint64_t)rd;
                out->tag_rc_atomic_inc[tid] = (uint64_t)rai;
                out->tag_rc_atomic_dec[tid] = (uint64_t)rad;
                out->tag_rc_destroy[tid] = (uint64_t)rdes;
                out->tag_rc_immortal[tid] = (uint64_t)rimm;
            }
        } else if (strncmp(line, "TYPE ", 5) == 0) {
            unsigned tid = 0;
            unsigned long long drop_pc = 0, ac = 0, ab = 0, fc = 0, fb = 0, ic = 0, ib = 0;
            int n = sscanf(line + 5, "%u 0x%llx %llu %llu %llu %llu %llu %llu",
                           &tid, &drop_pc, &ac, &ab, &fc, &fb, &ic, &ib);
            assert(n == 8);
            out->type_lines++;
            if (ac != fc || ab != fb || ic != 0 || ib != 0) {
                out->type_mismatch = 1;
            }
            if (tid == PION_TAG_STRUCT && drop_pc != 0) {
                out->saw_custom_drop_type = 1;
            }
        } else if (strncmp(line, "CPU_PC ", 7) == 0) {
            unsigned long long pc = 0, cnt = 0;
            assert(sscanf(line + 7, "0x%llx %llu", &pc, &cnt) == 2);
            assert(pc != 0 && cnt > 0);
            out->cpu_pc_lines++;
            out->cpu_samples += (uint64_t)cnt;
        } else if (strncmp(line, "STACK ", 6) == 0) {
            char kind[32] = {0};
            unsigned tid = 0;
            unsigned long long cnt = 0, bytes = 0;
            assert(sscanf(line + 6, "%31s %u %llu %llu", kind, &tid, &cnt, &bytes) == 4);
            if (strcmp(kind, "alloc") == 0) out->stack_alloc_lines++;
            else if (strcmp(kind, "rc") == 0) out->stack_rc_lines++;
            else if (strcmp(kind, "backing") == 0) out->stack_backing_lines++;
            else if (strcmp(kind, "inuse") == 0) {
                out->stack_inuse_lines++;
                out->stack_inuse_count += (uint64_t)cnt;
                out->stack_inuse_bytes += (uint64_t)bytes;
            }
        }
    }
    fclose(f);
}

/* ============================================================================
 * Sub-test 1: Full Conservation (all bypasses, deep tree, realloc, Map, MT)
 * ============================================================================ */

typedef struct TreeNode {
    struct TreeNode *next;
    int64_t id;
} TreeNode;

static void tree_node_drop(void *payload) {
    TreeNode *n = (TreeNode *)payload;
    if (n->next) {
        pion_rc_dec(n->next);
        n->next = NULL;
    }
}

typedef struct MtEnv {
    void *shared_str;
    void *shared_arr;
} MtEnv;

static void mt_env_drop(void *payload) {
    MtEnv *e = (MtEnv *)payload;
    if (e->shared_str) pion_rc_dec(e->shared_str);
    if (e->shared_arr) pion_rc_dec(e->shared_arr);
}

static void mt_worker(void *env_ptr) {
    MtEnv *e = (MtEnv *)env_ptr;
    pion_rc_inc(e->shared_str);
    pion_rc_dec(e->shared_str);
    for (int i = 0; i < 64; i++) {
        void *s = pion_int_to_str(i * 1000 + 7);
        void *a = pion_arr_new(4, 1);
        pion_arr_push_owned(a, (int64_t)(uintptr_t)s);
        pion_rc_dec(a);
    }
    void *big = pion_alloc(300000u, PION_TAG_STRUCT, NULL);
    pion_rc_dec(big);
}

PION_STATIC_STRING_DEF(k_immortal, "immortal_literal");

static int run_sub_conservation(void) {
    /* 1. Short-string split + pion_arr_drop */
    void *csv = pion_str_from_cstr("a,bb,ccc,dddd,eeeee,ffffff,ggggggg,hhhhhhhh,1,2,3,4,5,6,7", 56);
    void *sep = pion_str_from_cstr(",", 1);
    void *parts = pion_str_split(csv, sep);
    pion_rc_dec(parts);
    pion_rc_dec(sep);
    pion_rc_dec(csv);

    /* 2. pion_read_file_obj (small + large > 256 KB) */
    char tmpf[256];
    snprintf(tmpf, sizeof(tmpf), "/tmp/pion_prof_test_file_%ld.txt", (long)getpid());
    FILE *fp = fopen(tmpf, "wb");
    assert(fp != NULL);
    char block[1024];
    memset(block, 'x', sizeof(block));
    for (int i = 0; i < 300; i++) {
        assert(fwrite(block, 1, sizeof(block), fp) == sizeof(block));
    }
    fclose(fp);
    void *path_str = pion_str_from_cstr(tmpf, (int64_t)strlen(tmpf));
    int32_t ok = 0;
    void *fcontent = pion_world_fs_read(NULL, path_str, &ok);
    assert(ok == 1 && pion_str_len(fcontent) == 300 * 1024);
    pion_rc_dec(fcontent);
    pion_rc_dec(path_str);
    unlink(tmpf);

    /* 3. Deep recursive tree (depth = 120 > 64 worklist threshold) */
    TreeNode *head = NULL;
    for (int i = 0; i < 120; i++) {
        TreeNode *node = (TreeNode *)pion_alloc((uint32_t)sizeof(TreeNode), PION_TAG_STRUCT, tree_node_drop);
        node->next = head;
        node->id = i;
        head = node;
    }
    pion_rc_dec(head);

    /* 4. Container realloc growth past PION_MED_MAX_BYTES (262144 B) */
    void *sb = pion_strbuf_new(32);
    void *chunk = pion_str_from_cstr(block, 1024);
    for (int i = 0; i < 600; i++) {
        pion_strbuf_push_str(sb, chunk);
    }
    pion_rc_dec(chunk);
    pion_rc_dec(sb);

    void *big_arr = pion_arr_new(8, 0);
    for (int64_t i = 0; i < 70000; i++) {
        pion_arr_push(big_arr, i);
    }
    pion_rc_dec(big_arr);

    /* 5. Map rehash + copy + remove + drop */
    void *m = pion_map_new(1);
    for (int i = 0; i < 400; i++) {
        void *k = pion_int_to_str(i);
        void *v = pion_int_to_str(i * 3);
        pion_map_set(m, k, (int64_t)(uintptr_t)v);
        pion_rc_dec(k);
        pion_rc_dec(v);
    }
    void *m2 = pion_map_copy(m);
    for (int i = 0; i < 200; i++) {
        void *k = pion_int_to_str(i);
        pion_map_remove(m, k);
        pion_rc_dec(k);
    }
    pion_rc_dec(m2);
    pion_rc_dec(m);

    /* 6. Immortal RC ops */
    pion_rc_inc(k_immortal);
    pion_rc_dec(k_immortal);
    pion_rc_freeze(k_immortal);

    /* 7. Large managed object + med-cache managed object */
    void *med = pion_alloc(4096u, PION_TAG_STRUCT, NULL);
    void *large = pion_alloc(300000u, PION_TAG_STRUCT, NULL);
    pion_rc_dec(med);
    pion_rc_dec(large);

    /* 8. Multithreaded scope/spawn cross-thread alloc/free & address reuse */
    void *scope = pion_scope_begin();
    MtEnv *env = (MtEnv *)pion_alloc((uint32_t)sizeof(MtEnv), PION_TAG_STRUCT, mt_env_drop);
    env->shared_str = pion_str_from_cstr("shared_mt_string", 16);
    env->shared_arr = pion_arr_new(4, 0);
    pion_arr_push(env->shared_arr, 42);
    pion_rc_freeze(env->shared_str);
    pion_rc_freeze(env->shared_arr);
    for (int t = 0; t < 4; t++) {
        pion_scope_spawn(scope, mt_worker, env);
    }
    pion_scope_end(scope);
    pion_rc_dec(env);
    pion_rc_dec(scope);

    return 0;
}

/* ============================================================================
 * Sub-test 2: Retained live objects
 * ============================================================================ */

static int run_sub_retained(void) {
    void *kept[3];
    for (int i = 0; i < 10; i++) {
        void *s = pion_str_from_cstr("retained_payload_test", 21);
        if (i < 3) {
            kept[i] = s;
        } else {
            pion_rc_dec(s);
        }
    }
    /* Intentionally flush while 3 strings are still live, then clean up */
    pion_prof_flush();
    for (int i = 0; i < 3; i++) {
        pion_rc_dec(kept[i]);
    }
    return 0;
}

/* ============================================================================
 * Sub-test 3: CPU SIGPROF stress inside libc qsort / memcpy
 * ============================================================================ */

static int cmp_i32(const void *a, const void *b) {
    int va = *(const int *)a;
    int vb = *(const int *)b;
    return (va > vb) - (va < vb);
}

static int run_sub_cpu(void) {
    const size_t N = 16384;
    int *buf1 = (int *)malloc(N * sizeof(int));
    int *buf2 = (int *)malloc(N * sizeof(int));
    assert(buf1 && buf2);
    uint64_t t0 = (uint64_t)pion_clock_monotonic_us();
    uint32_t seed = 0x12345678u;
    int rounds = 0;
    while ((uint64_t)pion_clock_monotonic_us() - t0 < 120000ULL || rounds < 20) {
        for (size_t i = 0; i < N; i++) {
            seed = seed * 1664525u + 1013904223u;
            buf1[i] = (int)seed;
        }
        memcpy(buf2, buf1, N * sizeof(int));
        qsort(buf2, N, sizeof(int), cmp_i32);
        rounds++;
    }
    free(buf1);
    free(buf2);
    return 0;
}

/* ============================================================================
 * Sub-test 4: Window control (pause / resume / reset)
 * ============================================================================ */

static int run_sub_window(void) {
    for (int i = 0; i < 5; i++) {
        void *s = pion_str_from_cstr("before_reset", 12);
        pion_rc_dec(s);
    }
    pion_prof_reset();

    pion_prof_pause();
    for (int i = 0; i < 20; i++) {
        void *s = pion_str_from_cstr("paused_1", 8);
        pion_rc_dec(s);
    }

    pion_prof_resume();
    for (int i = 0; i < 3; i++) {
        void *s = pion_str_from_cstr("active_window", 13);
        pion_rc_dec(s);
    }

    pion_prof_pause();
    for (int i = 0; i < 15; i++) {
        void *s = pion_str_from_cstr("paused_2", 8);
        pion_rc_dec(s);
    }

    pion_prof_flush();
    return 0;
}

/* ============================================================================
 * Sub-test 5: Environment unsetenv isolation
 * ============================================================================ */

static int run_sub_env(void) {
    assert(getenv("PION_PROF_OUT") == NULL);
    assert(getenv("PION_PROF_MODES") == NULL);
    assert(getenv("PION_PROF_HZ") == NULL);
    assert(getenv("PION_PROF_SAMPLE_RATE") == NULL);
    assert(getenv("PION_PROF_RETAINED") == NULL);
    assert(getenv("PION_PROF_INHERIT") == NULL);
    return 0;
}

/* ============================================================================
 * Sub-test 6: pion_panic flushes before abort()
 * ============================================================================ */

static int run_sub_panic(void) {
    void *s1 = pion_str_from_cstr("before_panic_1", 14);
    void *s2 = pion_str_from_cstr("before_panic_2", 14);
    (void)s1;
    (void)s2;
    pion_panic("expected_test_panic", "test_prof.c", 1);
}

/* ============================================================================
 * Subprocess runner
 * ============================================================================ */

static int run_child(const char *self, const char *sub,
                     const char *out_path, const char *modes,
                     const char *hz, const char *sr, const char *ret,
                     int expect_signal) {
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        setenv("PION_PROF_OUT", out_path, 1);
        if (modes) setenv("PION_PROF_MODES", modes, 1);
        if (hz) setenv("PION_PROF_HZ", hz, 1);
        if (sr) setenv("PION_PROF_SAMPLE_RATE", sr, 1);
        if (ret) setenv("PION_PROF_RETAINED", ret, 1);
        unsetenv("PION_PROF_INHERIT");
        if (expect_signal) {
            /* Silence expected panic message on stderr */
            FILE *dn = freopen("/dev/null", "wb", stderr);
            (void)dn;
        }
        char *argv_child[3];
        argv_child[0] = (char *)self;
        argv_child[1] = (char *)sub;
        argv_child[2] = NULL;
        execv(self, argv_child);
        _exit(127);
    }
    int status = 0;
    assert(waitpid(pid, &status, 0) == pid);
    if (expect_signal) {
        assert(WIFSIGNALED(status) && WTERMSIG(status) == expect_signal);
        return 0;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "FAIL: child %s exited abnormally (status=0x%x)\n", sub, status);
        exit(1);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2) {
        if (strcmp(argv[1], "--sub-conservation") == 0) return run_sub_conservation();
        if (strcmp(argv[1], "--sub-retained") == 0) return run_sub_retained();
        if (strcmp(argv[1], "--sub-cpu") == 0) return run_sub_cpu();
        if (strcmp(argv[1], "--sub-window") == 0) return run_sub_window();
        if (strcmp(argv[1], "--sub-env") == 0) return run_sub_env();
        if (strcmp(argv[1], "--sub-panic") == 0) return run_sub_panic();
        return 2;
    }

    char path[256];
    ParsedProf p;

    /* 1. Exact conservation test */
    snprintf(path, sizeof(path), "/tmp/pion_prof_t1_%ld.raw", (long)getpid());
    unlink(path);
    run_child(argv[0], "--sub-conservation", path, "7", "997", "1", "1", 0);
    parse_prof_file(path, &p);
    assert(p.saw_header && p.saw_meta1 && p.saw_meta2 && p.saw_anchor && p.saw_bin);
    assert(p.backing_alloc_count > 0);
    assert(p.backing_alloc_bytes == p.backing_free_bytes);
    assert(p.backing_inuse_bytes == 0);
    assert(p.peak_reserved_bytes > 0);
    assert(p.tag_seen[PION_TAG_STRING]);
    assert(p.tag_seen[PION_TAG_ARRAY]);
    assert(p.tag_seen[PION_TAG_STRUCT]);
    assert(p.tag_seen[PION_TAG_MAP]);
    assert(p.tag_seen[PION_TAG_STRBUF]);
    assert(p.tag_seen[PION_TAG_SCOPE]);
    assert(p.tag_rc_immortal[PION_TAG_STRING] >= 3);
    assert(p.tag_rc_atomic_inc[PION_TAG_STRING] > 0);
    assert(p.tag_rc_atomic_dec[PION_TAG_STRING] > 0);
    for (int t = 0; t < 32; t++) {
        if (!p.tag_seen[t]) continue;
        assert(p.tag_alloc_cnt[t] == p.tag_free_cnt[t]);
        assert(p.tag_alloc_bytes[t] == p.tag_free_bytes[t]);
        assert(p.tag_inuse_cnt[t] == 0);
        assert(p.tag_inuse_bytes[t] == 0);
    }
    assert(p.type_lines > 0 && p.type_mismatch == 0);
    assert(p.saw_custom_drop_type == 1);
    assert(p.stack_alloc_lines > 0 && p.stack_rc_lines > 0 && p.stack_backing_lines > 0);
    assert(p.stack_inuse_lines == 0);
    unlink(path);
    printf("[1/6] exact conservation (split, arr_drop, read_file, tree d>64, realloc, map, MT): PASS\n");

    /* 2. Retained live-object test */
    snprintf(path, sizeof(path), "/tmp/pion_prof_t2_%ld.raw", (long)getpid());
    unlink(path);
    run_child(argv[0], "--sub-retained", path, "2", "997", "1", "1", 0);
    parse_prof_file(path, &p);
    assert(p.saw_header && p.saw_anchor);
    assert(p.tag_alloc_cnt[PION_TAG_STRING] == 10);
    assert(p.tag_free_cnt[PION_TAG_STRING] == 7);
    assert(p.tag_inuse_cnt[PION_TAG_STRING] == 3);
    assert(p.tag_inuse_bytes[PION_TAG_STRING] > 0);
    assert(p.stack_inuse_count == 3);
    assert(p.stack_inuse_bytes == p.tag_inuse_bytes[PION_TAG_STRING]);
    unlink(path);
    printf("[2/6] retained live-object tracking (inuse_count=3 exact): PASS\n");

    /* 3. CPU SIGPROF stress inside qsort/memcpy */
    snprintf(path, sizeof(path), "/tmp/pion_prof_t3_%ld.raw", (long)getpid());
    unlink(path);
    run_child(argv[0], "--sub-cpu", path, "1", "1000", "1", "0", 0);
    parse_prof_file(path, &p);
    assert(p.saw_header && p.saw_anchor);
    assert(p.cpu_pc_lines >= 1 && p.cpu_samples >= 1);
    unlink(path);
    printf("[3/6] CPU SIGPROF stress in qsort/memcpy (samples=%" PRIu64 ", pcs=%" PRIu64 "): PASS\n",
           p.cpu_samples, p.cpu_pc_lines);

    /* 4. Window control (pause/resume/reset) */
    snprintf(path, sizeof(path), "/tmp/pion_prof_t4_%ld.raw", (long)getpid());
    unlink(path);
    run_child(argv[0], "--sub-window", path, "7", "997", "1", "0", 0);
    parse_prof_file(path, &p);
    assert(p.saw_header);
    assert(p.tag_alloc_cnt[PION_TAG_STRING] == 3);
    assert(p.tag_free_cnt[PION_TAG_STRING] == 3);
    assert(p.tag_inuse_cnt[PION_TAG_STRING] == 0);
    unlink(path);
    printf("[4/6] pause/resume/reset window isolation (exact count=3): PASS\n");

    /* 5. Environment unsetenv isolation */
    snprintf(path, sizeof(path), "/tmp/pion_prof_t5_%ld.raw", (long)getpid());
    unlink(path);
    run_child(argv[0], "--sub-env", path, "3", "997", "1", "0", 0);
    parse_prof_file(path, &p);
    assert(p.saw_header && p.saw_anchor);
    unlink(path);
    printf("[5/6] child env unsetenv isolation: PASS\n");

    /* 6. pion_panic flush before abort() */
    snprintf(path, sizeof(path), "/tmp/pion_prof_t6_%ld.raw", (long)getpid());
    unlink(path);
    run_child(argv[0], "--sub-panic", path, "2", "997", "1", "0", SIGABRT);
    parse_prof_file(path, &p);
    assert(p.saw_header && p.saw_anchor);
    assert(p.tag_alloc_cnt[PION_TAG_STRING] == 2);
    assert(p.tag_inuse_cnt[PION_TAG_STRING] == 2);
    unlink(path);
    printf("[6/6] pion_panic pre-abort flush: PASS\n");

    printf("ALL 6/6 test_prof CHECKS PASSED\n");
    return 0;
}

#endif /* _WIN32 */
