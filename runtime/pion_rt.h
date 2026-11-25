#ifndef PION_RT_H
#define PION_RT_H

#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
#include <atomic>
typedef std::atomic<uint32_t> pion_atomic_u32;
#else
#include <stdatomic.h>
typedef _Atomic uint32_t pion_atomic_u32;
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*PionDropFn)(void *payload);

typedef enum PionTag {
    PION_TAG_STRING  = 1,
    PION_TAG_BYTES   = 2,
    PION_TAG_ARRAY   = 3,
    PION_TAG_STRUCT  = 4,
    PION_TAG_ENUM    = 5,
    PION_TAG_CLOSURE = 6,
    PION_TAG_MAP     = 7,
    PION_TAG_CHANNEL = 8,
    PION_TAG_MUTEX   = 9,
    PION_TAG_ATOMIC  = 10,
    PION_TAG_STRBUF  = 11,
    PION_TAG_SCOPE   = 12,
    PION_TAG_WORLD   = 13
} PionTag;

#define PION_FLAG_FROZEN      ((uint16_t)1u)
#define PION_FLAG_IMMORTAL    ((uint16_t)2u)
#define PION_FLAG_SLAB        ((uint16_t)4u)
#define PION_FLAG_DEEP_FROZEN ((uint16_t)8u)
#define PION_FLAG_SLAB_CLS_SHIFT 4u
#define PION_FLAG_SLAB_CLS_MASK  ((uint16_t)0xFu)

typedef struct PionHeader {
    uint32_t owner_tid;         /* Thread ID of creator; 0 = FROZEN/SHARED (atomic mode) */
    uint32_t local_rc;          /* Non-atomic RC used while owner_tid == current_tid */
    pion_atomic_u32 shared_rc;  /* Atomic RC used once owner_tid == 0 (or cross-thread dec) */
    uint16_t type_tag;          /* PionTag */
    uint16_t flags;             /* bit 0: FROZEN, bit 1: IMMORTAL, bit 2: SLAB, bit 3: DEEP_FROZEN, bits 4..7: slab cls */
    PionDropFn drop_fn;         /* Nullable destructor for releasing child pointers */
} PionHeader;                   /* Total: 24 bytes (clean 8-byte alignment on arm64/x64) */

#ifdef __cplusplus
static_assert(sizeof(PionHeader) == 24, "PionHeader must be exactly 24 bytes");
#else
_Static_assert(sizeof(PionHeader) == 24, "PionHeader must be exactly 24 bytes");
#endif

typedef struct PionString {
    int64_t len;
    char data[];
} PionString;

typedef struct PionBytes {
    int64_t len;
    int64_t cap;
    uint8_t *data;
} PionBytes;

typedef struct PionStrBuf {
    int64_t len;
    int64_t cap;
    char *data;
} PionStrBuf;

typedef struct PionArray {
    int64_t len;
    int64_t cap;
    int32_t elem_is_obj;
    int32_t elem_stride; /* 0/8 = 8B slots; 1 = 1B Bool/Byte/Int8; 4 = 4B Int/UInt/Char/Float; 16/24/32+ = flat POD struct */
    int64_t *data;
} PionArray;

typedef struct PionMapEntry {
    PionString *key;
    uint64_t hash;
    int64_t val;
    uint8_t state; /* 0 = empty, 1 = occupied */
} PionMapEntry;

typedef struct PionMap {
    int64_t len;
    int64_t cap;
    int32_t val_is_obj;
    int32_t key_is_int;
    PionMapEntry *entries;
} PionMap;

/* Helper macro for defining static immortal string literals in C tests */
#define PION_STATIC_STRING_DEF(sym, str_lit)                                     \
    static const struct {                                                      \
        PionHeader hdr;                                                          \
        int64_t len;                                                           \
        char data[sizeof(str_lit)];                                            \
    } sym##_storage = {                                                        \
        { 0, 0, 1, PION_TAG_STRING, (PION_FLAG_FROZEN | PION_FLAG_IMMORTAL),   \
          NULL },                                                              \
        (int64_t)(sizeof(str_lit) - 1),                                        \
        str_lit                                                                \
    };                                                                         \
    static void *const sym = (void *)&sym##_storage.len

/* Memory & Biased RC */
#if (defined(__GNUC__) || defined(__clang__)) && !defined(_WIN32)
#define PION_HIDDEN __attribute__((visibility("hidden")))
#else
#define PION_HIDDEN
#endif
extern PION_HIDDEN uint32_t pion_mt_flag;
void     pion_enter_mt(void);
void     pion_once_call(uint32_t *guard, void (*init_fn)(void));
uint64_t pion_cur_tid(void);
void*    pion_alloc(uint32_t payload_size, uint16_t type_tag, PionDropFn drop_fn);
void*    pion_alloc_uninit(uint32_t payload_size, uint16_t type_tag, PionDropFn drop_fn);
void     pion_rc_inc(void *obj);
void     pion_rc_dec(void *obj);
void     pion_destroy_obj(void *obj);
void     pion_rc_freeze(void *obj);
void     pion_rc_immortalize(void *obj);
void     pion_panic(const char *msg, const char *file, int32_t line) __attribute__((noreturn));
void     pion_panic_oob(int64_t idx, int64_t len) __attribute__((noreturn));
void     pion_debug_assert(int32_t cond, void *msg_str, const char *file, int32_t line);

/* Math */
double   pion_math_sqrt(double x);
double   pion_math_abs(double x);
double   pion_math_floor(double x);
double   pion_math_ceil(double x);
double   pion_math_sin(double x);
double   pion_math_cos(double x);
double   pion_math_pow(double x, double y);

/* String */
void*    pion_str_from_cstr(const char *s, int64_t len);
int64_t  pion_str_len(void *s);
int32_t  pion_str_byte_at(void *s, int64_t idx);
void*    pion_str_concat(void *a, void *b);
void*    pion_str_concat_n(int64_t n, void **parts);
int32_t  pion_str_eq(void *a, void *b);
int32_t  pion_str_cmp(void *a, void *b);
void*    pion_str_slice(void *s, int64_t start, int64_t end);
void*    pion_int_to_str(int64_t v);
void*    pion_double_to_str(double v);
int64_t  pion_str_to_int(void *s, int32_t *ok_out);
double   pion_str_to_double(void *s, int32_t *ok_out);
int32_t  pion_str_starts_with(void *s, void *prefix);
int32_t  pion_str_ends_with(void *s, void *suffix);
int32_t  pion_str_contains(void *s, void *needle);
int64_t  pion_str_index_of(void *s, void *needle);
void*    pion_str_trim(void *s);
void*    pion_str_split(void *s, void *sep);
void*    pion_str_replace(void *s, void *from, void *to);
void*    pion_str_to_bytes(void *s);
void*    pion_bytes_to_str(void *b);

/* Bytes */
void*    pion_bytes_new(int64_t len);
int64_t  pion_bytes_len(void *b);
int32_t  pion_bytes_get(void *b, int64_t idx);
void     pion_bytes_set(void *b, int64_t idx, int32_t val);
void*    pion_bytes_slice(void *b, int64_t start, int64_t end);
void*    pion_bytes_concat(void *a, void *b);
void*    pion_bytes_from_ptr(void *p, int64_t len);
void     pion_bytes_copy_to_ptr(void *b_ptr, int64_t src_off, void *dst, int64_t len);

/* StringBuilder */
void*    pion_strbuf_new(int64_t cap);
void     pion_strbuf_push_str(void *sb, void *s);
void     pion_strbuf_push_slice(void *sb, void *s, int64_t start, int64_t end);
void     pion_strbuf_push_byte(void *sb, int32_t b);
void     pion_strbuf_push_char(void *sb, int32_t cp);
void     pion_strbuf_push_int(void *sb, int64_t v);
void     pion_strbuf_reset(void *sb);
void*    pion_strbuf_to_str(void *sb);

/* Array (flags: 0 = 8B scalar, 1 = 8B RC obj, 2 = 1B compact Bool/Byte, >2 = flat stride) */
void*    pion_arr_new(int64_t cap, int32_t elem_flags);
int64_t  pion_arr_len(void *a);
void     pion_arr_push(void *a, int64_t val);
void     pion_arr_push_owned(void *a, int64_t val);
void*    pion_arr_push_flat_grow(void *a);
int64_t  pion_arr_get(void *a, int64_t idx);
void     pion_arr_set(void *a, int64_t idx, int64_t val);
int64_t  pion_arr_pop(void *a);
void*    pion_arr_copy(void *a);
void     pion_arr_clear(void *a);
void     pion_arr_truncate(void *a, int64_t new_len);
void     pion_arr_reverse(void *a);
void*    pion_arr_join(void *a, void *sep);
void     pion_arr_sort_int(void *a);
void     pion_arr_sort_str(void *a);

/* Hash Map (String or Int/Int64 keys) */
void*    pion_map_new(int32_t val_is_obj);
void*    pion_map_new_int(int32_t val_is_obj);
int64_t  pion_map_len(void *m);
/* Keep one copy of shared fast-path primitives in size-optimized builds.
 * Speed builds retain the optimizer's original inlining policy. */
#if defined(__OPTIMIZE_SIZE__) && !defined(__clang__)
#define PION_SIZE_SHARED PION_NOINLINE
#define PION_SIZE_EQ PION_NOINLINE
#else
#define PION_SIZE_SHARED inline
#define PION_SIZE_EQ inline __attribute__((always_inline))
#endif

typedef struct PionStrSpan { const char *data; int64_t len; } PionStrSpan;
const char *pion_str_slice_data(const PionString *s, int64_t lo, int64_t hi);
void *pion_str_concat_spans(int64_t count, const PionStrSpan *parts);
int64_t *pion_map_scalar_entry(PionMap *m, const char *data, int64_t len, PionString *whole);
void     pion_map_set(void *m, void *key_str, int64_t val);
int32_t  pion_map_has(void *m, void *key_str);
int64_t  pion_map_get(void *m, void *key_str);
int32_t  pion_map_try_get(void *m_ptr, void *key_str, int64_t *out_val);
void     pion_map_remove(void *m, void *key_str);
void     pion_map_clear(void *m);
void*    pion_map_copy(void *m);
void*    pion_map_keys(void *m);

/* Concurrency */
void*    pion_scope_begin(void);
void     pion_scope_spawn(void *scope, void (*fn)(void *env), void *env);
void     pion_scope_end(void *scope);
void*    pion_chan_new(int64_t cap, int32_t elem_is_obj);
int32_t  pion_chan_send(void *ch, int64_t val);
int32_t  pion_chan_recv(void *ch, int64_t *out_val);
void     pion_chan_close(void *ch);
void*    pion_mutex_new(int64_t init_val, int32_t val_is_obj);
int64_t  pion_mutex_lock(void *m);
void     pion_mutex_set(void *m, int64_t new_val);
void     pion_mutex_set_and_unlock(void *m, int64_t new_val);
void     pion_mutex_unlock(void *m);
void*    pion_atomic_new(int64_t init_val);
int64_t  pion_atomic_load(void *a);
void     pion_atomic_store(void *a, int64_t val);
int64_t  pion_atomic_fetch_add(void *a, int64_t delta);

/* World Capabilities */
void*    pion_world_init(int argc, char **argv);
int64_t  pion_world_argc(void *w);
void*    pion_world_argv(void *w, int64_t idx);
void*    pion_world_args(void *w);
void     pion_world_print(void *w, void *s);
void     pion_world_println(void *w, void *s);
void     pion_world_eprintln(void *w, void *s);
void*    pion_world_read_line(void *w, int32_t *ok_out);
void*    pion_world_fs_read(void *w, void *path_str, int32_t *ok_out);
int32_t  pion_world_fs_write(void *w, void *path_str, void *content_str);
void*    pion_world_fs_read_bytes(void *w, void *path_str, int32_t *ok_out);
int32_t  pion_world_fs_write_bytes(void *w, void *path_str, void *bytes_obj);
int32_t  pion_world_fs_append(void *w, void *path_str, void *content_str);
int64_t  pion_world_fs_mtime_ms(void *w, void *path_str);
int32_t  pion_world_fs_exists(void *w, void *path_str);
int32_t  pion_world_fs_is_dir(void *w, void *path_str);
int32_t  pion_world_fs_mkdir_p(void *w, void *path_str);
/* `data` if its first `len` bytes are non-empty and NUL-free, else NULL. Only
 * those bytes are checked: the caller guarantees `data[len]` is a readable
 * terminating NUL (as in a Pion String) and keeps the owner alive until the
 * `const char *` consumer it feeds returns. In libpionrt.a (it backs every
 * runtime file API's path gate); its `const char *` consumers are pionc's
 * libpionrt_cli.a helpers below (pion_fs_mkdir_excl / pion_fs_rmdir /
 * pion_fs_trylock / pion_fs_lock / pion_fs_canon_path). */
const char* pion_fs_cpath(const char *data, int64_t len);
/* CLI-only host helpers: defined in runtime/pion_cli.c and archived only into
 * libpionrt_cli.a (pionc + test_rt), never into libpionrt.a. */
int32_t  pion_fs_mkdir_excl(const char *path);
int32_t  pion_fs_mkdir_excl_status(const char *path);
int32_t  pion_fs_rmdir(const char *path);
int64_t  pion_fs_trylock(const char *path);
int64_t  pion_fs_lock(const char *path);
void     pion_fs_unlock(int64_t handle);
char*    pion_fs_canon_path(const char *path);
int64_t  pion_cli_getpid(void);
int64_t  pion_cli_next_seq(void);
int32_t  pion_cli_is_windows(void);
int32_t  pion_fs_lstat_kind(const char *path);
void*    pion_world_fs_list_dir(void *w, void *path_str);
int32_t  pion_world_fs_remove(void *w, void *path_str);
int32_t  pion_world_fs_rename(void *w, void *old_path, void *new_path);
int64_t  pion_world_fs_size(void *w, void *path_str);
void*    pion_world_fs_lstat(void *w, void *path_str, int32_t *ok_out);
void*    pion_world_fs_readlink(void *w, void *path_str, int32_t *ok_out);
int32_t  pion_world_fs_symlink(void *w, void *target_str, void *linkpath_str);
int32_t  pion_world_fs_chmod(void *w, void *path_str, int32_t mode);
void*    pion_world_fs_read_range_nofollow(void *w, void *path_str, int64_t offset, int64_t length, int64_t expected_size, int32_t *ok_out);
void*    pion_world_env_get(void *w, void *name_str, int32_t *ok_out);
int64_t  pion_world_clock_ms(void *w);
int32_t  pion_world_exec(void *w, void *argv_arr);
void*    pion_world_exec_capture(void *w, void *argv_arr, int32_t *exit_code_out);
void*    pion_world_exec_capture_bytes(void *w, void *argv_arr, int32_t *exit_code_out);
void*    pion_sha256_hex(void *s);

/* Library-Mode Fine-Grained OS Primitives (No World Required) */
void*    pion_fs_mmap_ro(void *path_str, int32_t *ok_out);
int64_t  pion_clock_monotonic_us(void);
int32_t  pion_fs_write_atomic_bytes(void *path_str, void *bytes_obj);

/* FFI Raw Pointers & CStr */
void*    pion_ptr_alloc(int64_t bytes);
void     pion_ptr_free(void *p);
void*    pion_ptr_offset(void *p, int64_t byte_off);
void*    pion_ptr_read_ptr(void *p, int64_t byte_off);
void     pion_ptr_write_ptr(void *p, int64_t byte_off, void *v);
int32_t  pion_ptr_read_u8(void *p, int64_t byte_off);
void     pion_ptr_write_u8(void *p, int64_t byte_off, int32_t v);
int32_t  pion_ptr_read_i32(void *p, int64_t byte_off);
void     pion_ptr_write_i32(void *p, int64_t byte_off, int32_t v);
int64_t  pion_ptr_read_i64(void *p, int64_t byte_off);
void     pion_ptr_write_i64(void *p, int64_t byte_off, int64_t v);
void*    pion_cstr_to_str(void *cstr);

/* POSIX TCP Socket & Time */
int32_t  pion_tcp_listen(void *w_ptr, void *host_str, int32_t port);
int32_t  pion_tcp_listen_reuse(void *w_ptr, void *host_str, int32_t port);
int32_t  pion_tcp_local_port(void *w_ptr, int32_t fd);
int32_t  pion_tcp_accept(void *w_ptr, int32_t listen_fd);
int32_t  pion_tcp_connect(void *w_ptr, void *host_str, int32_t port);
void*    pion_tcp_read(void *w_ptr, int32_t fd, int32_t max_bytes);
int32_t  pion_tcp_write(void *w_ptr, int32_t fd, void *data_str);
void     pion_tcp_close(void *w_ptr, int32_t fd);
void     pion_sleep_ms(void *w_ptr, int32_t ms);

/* Non-blocking sockets & readiness polling (kqueue on macOS, epoll on Linux).
 * IO returns >= 0 bytes/fd, -2 (would block) or -1 (error); poll masks are
 * 1 READ | 2 WRITE | 4 ERR/HUP/EOF; poll_ctl op is 1 ADD, 2 MOD, 3 DEL. */
int32_t  pion_tcp_set_nonblock(void *w_ptr, int32_t fd, int32_t enable);
int32_t  pion_tcp_accept_nb(void *w_ptr, int32_t listen_fd);
int32_t  pion_tcp_read_nb(void *w_ptr, int32_t fd, void *sb_ptr, int32_t max_bytes);
int32_t  pion_tcp_write_nb(void *w_ptr, int32_t fd, void *data_str, int32_t offset);
int32_t  pion_poll_create(void *w_ptr);
int32_t  pion_poll_ctl(void *w_ptr, int32_t pfd, int32_t op, int32_t fd, int32_t events);
int32_t  pion_poll_wait(void *w_ptr, int32_t pfd, void *out_fds, void *out_events,
                        int32_t max_events, int32_t timeout_ms);
void     pion_poll_close(void *w_ptr, int32_t pfd);

/* Portable SIMD Vector & Quantized INT8 Matvec Primitives (P75-B, 3-entrypoint ABI) */
int32_t  pion_simd_i8_dot(void *a, int32_t a_is_bytes, int32_t a_off, void *b, int32_t b_off, int32_t len);
void     pion_simd_i8_mv(void *out, int32_t out_off, void *w, int32_t w_is_bytes, int32_t w_off,
                         void *x, int32_t x_off, void *sc, int32_t s_off,
                         float x_scale, int32_t rows, int32_t cols);
float    pion_simd_f32(int32_t op, void *dst, int32_t d_off, void *a, int32_t a_off,
                       void *b, int32_t b_off, float alpha, int32_t len);

#ifdef __cplusplus
}
#endif

#endif /* PION_RT_H */
