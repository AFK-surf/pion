#ifndef PION_RT_H
#define PION_RT_H

#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>

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

#define PION_FLAG_FROZEN   ((uint16_t)1u)
#define PION_FLAG_IMMORTAL ((uint16_t)2u)
#define PION_FLAG_SLAB     ((uint16_t)4u)
#define PION_FLAG_SLAB_CLS_SHIFT 4u
#define PION_FLAG_SLAB_CLS_MASK  ((uint16_t)0x7u)

typedef struct PionHeader {
    uint64_t owner_tid;         /* Thread ID of creator; 0 = FROZEN/SHARED (atomic mode) */
    uint32_t local_rc;          /* Non-atomic RC used while owner_tid == current_tid */
    _Atomic uint32_t shared_rc; /* Atomic RC used once owner_tid == 0 (or cross-thread dec) */
    uint16_t type_tag;          /* PionTag */
    uint16_t flags;             /* bit 0: PION_FLAG_FROZEN, bit 1: PION_FLAG_IMMORTAL */
    uint32_t payload_size;      /* Byte size of payload */
    PionDropFn drop_fn;           /* Nullable destructor for releasing child pointers */
} PionHeader;                     /* Total: 32 bytes (clean 8-byte alignment on arm64/x64) */

_Static_assert(sizeof(PionHeader) == 32, "PionHeader must be exactly 32 bytes");

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
    int32_t _pad;
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
    int32_t _pad;
    PionMapEntry *entries;
} PionMap;

/* Helper macro for defining static immortal string literals in C tests */
#define PION_STATIC_STRING_DEF(sym, str_lit)                                     \
    static const struct {                                                      \
        PionHeader hdr;                                                          \
        int64_t len;                                                           \
        char data[sizeof(str_lit)];                                            \
    } sym##_storage = {                                                        \
        { 0, 0, 1, PION_TAG_STRING, (PION_FLAG_FROZEN | PION_FLAG_IMMORTAL),         \
          (uint32_t)(sizeof(int64_t) + sizeof(str_lit)), NULL },               \
        (int64_t)(sizeof(str_lit) - 1),                                        \
        str_lit                                                                \
    };                                                                         \
    static void *const sym = (void *)&sym##_storage.len

/* Memory & Biased RC */
uint64_t pion_cur_tid(void);
void*    pion_alloc(uint32_t payload_size, uint16_t type_tag, PionDropFn drop_fn);
void*    pion_alloc_uninit(uint32_t payload_size, uint16_t type_tag, PionDropFn drop_fn);
void     pion_rc_inc(void *obj);
void     pion_rc_dec(void *obj);
void     pion_rc_freeze(void *obj);
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

/* StringBuilder */
void*    pion_strbuf_new(int64_t cap);
void     pion_strbuf_push_str(void *sb, void *s);
void     pion_strbuf_push_byte(void *sb, int32_t b);
void     pion_strbuf_push_char(void *sb, int32_t cp);
void     pion_strbuf_push_int(void *sb, int64_t v);
void     pion_strbuf_reset(void *sb);
void*    pion_strbuf_to_str(void *sb);

/* Array */
void*    pion_arr_new(int64_t cap, int32_t elem_is_obj);
int64_t  pion_arr_len(void *a);
void     pion_arr_push(void *a, int64_t val);
void     pion_arr_push_owned(void *a, int64_t val);
int64_t  pion_arr_get(void *a, int64_t idx);
void     pion_arr_set(void *a, int64_t idx, int64_t val);
int64_t  pion_arr_pop(void *a);
void*    pion_arr_copy(void *a);
void     pion_arr_clear(void *a);
void     pion_arr_reverse(void *a);
void*    pion_arr_join(void *a, void *sep);
void     pion_arr_sort_int(void *a);
void     pion_arr_sort_str(void *a);

/* String-Keyed Hash Map */
void*    pion_map_new(int32_t val_is_obj);
int64_t  pion_map_len(void *m);
void     pion_map_set(void *m, void *key_str, int64_t val);
int32_t  pion_map_has(void *m, void *key_str);
int64_t  pion_map_get(void *m, void *key_str);
int32_t  pion_map_try_get(void *m_ptr, void *key_str, int64_t *out_val);
void     pion_map_remove(void *m, void *key_str);
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
void*    pion_world_fs_read(void *w, void *path_str, int32_t *ok_out);
int32_t  pion_world_fs_write(void *w, void *path_str, void *content_str);
void*    pion_world_fs_read_bytes(void *w, void *path_str, int32_t *ok_out);
int32_t  pion_world_fs_write_bytes(void *w, void *path_str, void *bytes_obj);
int32_t  pion_world_fs_append(void *w, void *path_str, void *content_str);
int64_t  pion_world_fs_mtime_ms(void *w, void *path_str);
int32_t  pion_world_fs_exists(void *w, void *path_str);
int32_t  pion_world_fs_is_dir(void *w, void *path_str);
int32_t  pion_world_fs_mkdir_p(void *w, void *path_str);
void*    pion_world_fs_list_dir(void *w, void *path_str);
int32_t  pion_world_fs_remove(void *w, void *path_str);
int32_t  pion_world_fs_rename(void *w, void *old_path, void *new_path);
int64_t  pion_world_fs_size(void *w, void *path_str);
void*    pion_world_env_get(void *w, void *name_str, int32_t *ok_out);
int64_t  pion_world_clock_ms(void *w);
int32_t  pion_world_exec(void *w, void *argv_arr);
void*    pion_world_exec_capture(void *w, void *argv_arr, int32_t *exit_code_out);
void*    pion_sha256_hex(void *s);

/* FFI Raw Pointers & CStr */
void*    pion_ptr_alloc(int64_t bytes);
void     pion_ptr_free(void *p);
void*    pion_ptr_offset(void *p, int64_t byte_off);
void*    pion_ptr_read_ptr(void *p, int64_t byte_off);
void     pion_ptr_write_ptr(void *p, int64_t byte_off, void *v);
int32_t  pion_ptr_read_i32(void *p, int64_t byte_off);
void     pion_ptr_write_i32(void *p, int64_t byte_off, int32_t v);
int64_t  pion_ptr_read_i64(void *p, int64_t byte_off);
void     pion_ptr_write_i64(void *p, int64_t byte_off, int64_t v);
void*    pion_cstr_to_str(void *cstr);

/* POSIX TCP Socket & Time */
int32_t  pion_tcp_listen(void *w_ptr, void *host_str, int32_t port);
int32_t  pion_tcp_local_port(void *w_ptr, int32_t fd);
int32_t  pion_tcp_accept(void *w_ptr, int32_t listen_fd);
int32_t  pion_tcp_connect(void *w_ptr, void *host_str, int32_t port);
void*    pion_tcp_read(void *w_ptr, int32_t fd, int32_t max_bytes);
int32_t  pion_tcp_write(void *w_ptr, int32_t fd, void *data_str);
void     pion_tcp_close(void *w_ptr, int32_t fd);
void     pion_sleep_ms(void *w_ptr, int32_t ms);

#ifdef __cplusplus
}
#endif

#endif /* PION_RT_H */
