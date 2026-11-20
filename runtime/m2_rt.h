#ifndef M2_RT_H
#define M2_RT_H

#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*M2DropFn)(void *payload);

typedef enum M2Tag {
    M2_TAG_STRING  = 1,
    M2_TAG_BYTES   = 2,
    M2_TAG_ARRAY   = 3,
    M2_TAG_STRUCT  = 4,
    M2_TAG_ENUM    = 5,
    M2_TAG_CLOSURE = 6,
    M2_TAG_MAP     = 7,
    M2_TAG_CHANNEL = 8,
    M2_TAG_MUTEX   = 9,
    M2_TAG_ATOMIC  = 10,
    M2_TAG_STRBUF  = 11,
    M2_TAG_SCOPE   = 12,
    M2_TAG_WORLD   = 13
} M2Tag;

#define M2_FLAG_FROZEN   ((uint16_t)1u)
#define M2_FLAG_IMMORTAL ((uint16_t)2u)
#define M2_FLAG_SLAB     ((uint16_t)4u)
#define M2_FLAG_SLAB_CLS_SHIFT 4u
#define M2_FLAG_SLAB_CLS_MASK  ((uint16_t)0x7u)

typedef struct M2Header {
    uint64_t owner_tid;         /* Thread ID of creator; 0 = FROZEN/SHARED (atomic mode) */
    uint32_t local_rc;          /* Non-atomic RC used while owner_tid == current_tid */
    _Atomic uint32_t shared_rc; /* Atomic RC used once owner_tid == 0 (or cross-thread dec) */
    uint16_t type_tag;          /* M2Tag */
    uint16_t flags;             /* bit 0: M2_FLAG_FROZEN, bit 1: M2_FLAG_IMMORTAL */
    uint32_t payload_size;      /* Byte size of payload */
    M2DropFn drop_fn;           /* Nullable destructor for releasing child pointers */
} M2Header;                     /* Total: 32 bytes (clean 8-byte alignment on arm64/x64) */

_Static_assert(sizeof(M2Header) == 32, "M2Header must be exactly 32 bytes");

typedef struct M2String {
    int64_t len;
    char data[];
} M2String;

typedef struct M2Bytes {
    int64_t len;
    int64_t cap;
    uint8_t *data;
} M2Bytes;

typedef struct M2StrBuf {
    int64_t len;
    int64_t cap;
    char *data;
} M2StrBuf;

typedef struct M2Array {
    int64_t len;
    int64_t cap;
    int32_t elem_is_obj;
    int32_t _pad;
    int64_t *data;
} M2Array;

typedef struct M2MapEntry {
    M2String *key;
    uint64_t hash;
    int64_t val;
    uint8_t state; /* 0 = empty, 1 = occupied */
} M2MapEntry;

typedef struct M2Map {
    int64_t len;
    int64_t cap;
    int32_t val_is_obj;
    int32_t _pad;
    M2MapEntry *entries;
} M2Map;

/* Helper macro for defining static immortal string literals in C tests */
#define M2_STATIC_STRING_DEF(sym, str_lit)                                     \
    static const struct {                                                      \
        M2Header hdr;                                                          \
        int64_t len;                                                           \
        char data[sizeof(str_lit)];                                            \
    } sym##_storage = {                                                        \
        { 0, 0, 1, M2_TAG_STRING, (M2_FLAG_FROZEN | M2_FLAG_IMMORTAL),         \
          (uint32_t)(sizeof(int64_t) + sizeof(str_lit)), NULL },               \
        (int64_t)(sizeof(str_lit) - 1),                                        \
        str_lit                                                                \
    };                                                                         \
    static void *const sym = (void *)&sym##_storage.len

/* Memory & Biased RC */
uint64_t m2_cur_tid(void);
void*    m2_alloc(uint32_t payload_size, uint16_t type_tag, M2DropFn drop_fn);
void*    m2_alloc_uninit(uint32_t payload_size, uint16_t type_tag, M2DropFn drop_fn);
void     m2_rc_inc(void *obj);
void     m2_rc_dec(void *obj);
void     m2_rc_freeze(void *obj);
void     m2_panic(const char *msg, const char *file, int32_t line) __attribute__((noreturn));
void     m2_panic_oob(int64_t idx, int64_t len) __attribute__((noreturn));
void     m2_debug_assert(int32_t cond, void *msg_str, const char *file, int32_t line);

/* Math */
double   m2_math_sqrt(double x);
double   m2_math_abs(double x);
double   m2_math_floor(double x);
double   m2_math_ceil(double x);
double   m2_math_sin(double x);
double   m2_math_cos(double x);
double   m2_math_pow(double x, double y);

/* String */
void*    m2_str_from_cstr(const char *s, int64_t len);
int64_t  m2_str_len(void *s);
int32_t  m2_str_byte_at(void *s, int64_t idx);
void*    m2_str_concat(void *a, void *b);
int32_t  m2_str_eq(void *a, void *b);
int32_t  m2_str_cmp(void *a, void *b);
void*    m2_str_slice(void *s, int64_t start, int64_t end);
void*    m2_int_to_str(int64_t v);
void*    m2_double_to_str(double v);
int64_t  m2_str_to_int(void *s, int32_t *ok_out);
int32_t  m2_str_starts_with(void *s, void *prefix);
int32_t  m2_str_ends_with(void *s, void *suffix);
int32_t  m2_str_contains(void *s, void *needle);
int64_t  m2_str_index_of(void *s, void *needle);
void*    m2_str_trim(void *s);
void*    m2_str_split(void *s, void *sep);
void*    m2_str_replace(void *s, void *from, void *to);
void*    m2_str_to_bytes(void *s);
void*    m2_bytes_to_str(void *b);

/* Bytes */
void*    m2_bytes_new(int64_t len);
int64_t  m2_bytes_len(void *b);
int32_t  m2_bytes_get(void *b, int64_t idx);
void     m2_bytes_set(void *b, int64_t idx, int32_t val);
void*    m2_bytes_slice(void *b, int64_t start, int64_t end);
void*    m2_bytes_concat(void *a, void *b);

/* StringBuilder */
void*    m2_strbuf_new(int64_t cap);
void     m2_strbuf_push_str(void *sb, void *s);
void     m2_strbuf_push_byte(void *sb, int32_t b);
void     m2_strbuf_push_char(void *sb, int32_t cp);
void     m2_strbuf_push_int(void *sb, int64_t v);
void     m2_strbuf_reset(void *sb);
void*    m2_strbuf_to_str(void *sb);

/* Array */
void*    m2_arr_new(int64_t cap, int32_t elem_is_obj);
int64_t  m2_arr_len(void *a);
void     m2_arr_push(void *a, int64_t val);
void     m2_arr_push_owned(void *a, int64_t val);
int64_t  m2_arr_get(void *a, int64_t idx);
void     m2_arr_set(void *a, int64_t idx, int64_t val);
int64_t  m2_arr_pop(void *a);
void*    m2_arr_copy(void *a);
void     m2_arr_clear(void *a);
void     m2_arr_reverse(void *a);
void*    m2_arr_join(void *a, void *sep);
void     m2_arr_sort_int(void *a);
void     m2_arr_sort_str(void *a);

/* String-Keyed Hash Map */
void*    m2_map_new(int32_t val_is_obj);
int64_t  m2_map_len(void *m);
void     m2_map_set(void *m, void *key_str, int64_t val);
int32_t  m2_map_has(void *m, void *key_str);
int64_t  m2_map_get(void *m, void *key_str);
int32_t  m2_map_try_get(void *m_ptr, void *key_str, int64_t *out_val);
void     m2_map_remove(void *m, void *key_str);
void*    m2_map_copy(void *m);
void*    m2_map_keys(void *m);

/* Concurrency */
void*    m2_scope_begin(void);
void     m2_scope_spawn(void *scope, void (*fn)(void *env), void *env);
void     m2_scope_end(void *scope);
void*    m2_chan_new(int64_t cap, int32_t elem_is_obj);
int32_t  m2_chan_send(void *ch, int64_t val);
int32_t  m2_chan_recv(void *ch, int64_t *out_val);
void     m2_chan_close(void *ch);
void*    m2_mutex_new(int64_t init_val, int32_t val_is_obj);
int64_t  m2_mutex_lock(void *m);
void     m2_mutex_set(void *m, int64_t new_val);
void     m2_mutex_set_and_unlock(void *m, int64_t new_val);
void     m2_mutex_unlock(void *m);
void*    m2_atomic_new(int64_t init_val);
int64_t  m2_atomic_load(void *a);
void     m2_atomic_store(void *a, int64_t val);
int64_t  m2_atomic_fetch_add(void *a, int64_t delta);

/* World Capabilities */
void*    m2_world_init(int argc, char **argv);
int64_t  m2_world_argc(void *w);
void*    m2_world_argv(void *w, int64_t idx);
void*    m2_world_args(void *w);
void     m2_world_print(void *w, void *s);
void     m2_world_println(void *w, void *s);
void     m2_world_eprintln(void *w, void *s);
void*    m2_world_fs_read(void *w, void *path_str, int32_t *ok_out);
int32_t  m2_world_fs_write(void *w, void *path_str, void *content_str);
void*    m2_world_fs_read_bytes(void *w, void *path_str, int32_t *ok_out);
int32_t  m2_world_fs_write_bytes(void *w, void *path_str, void *bytes_obj);
int32_t  m2_world_fs_append(void *w, void *path_str, void *content_str);
int64_t  m2_world_fs_mtime_ms(void *w, void *path_str);
int32_t  m2_world_fs_exists(void *w, void *path_str);
int32_t  m2_world_fs_is_dir(void *w, void *path_str);
int32_t  m2_world_fs_mkdir_p(void *w, void *path_str);
void*    m2_world_fs_list_dir(void *w, void *path_str);
int32_t  m2_world_fs_remove(void *w, void *path_str);
int32_t  m2_world_fs_rename(void *w, void *old_path, void *new_path);
int64_t  m2_world_fs_size(void *w, void *path_str);
void*    m2_world_env_get(void *w, void *name_str, int32_t *ok_out);
int64_t  m2_world_clock_ms(void *w);
int32_t  m2_world_exec(void *w, void *argv_arr);
void*    m2_world_exec_capture(void *w, void *argv_arr, int32_t *exit_code_out);
void*    m2_sha256_hex(void *s);

#ifdef __cplusplus
}
#endif

#endif /* M2_RT_H */
