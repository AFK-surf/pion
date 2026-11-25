/* P128: pooled runtime diagnostics, called through the public runtime ABI of
 * libpionrt.a. argv[1] selects the trap; each case must abort with exactly
 * `pion panic at pion_rt.c:<line>: <message>`. 15 cases reach 14 of the 16
 * pooled texts; not reachable from a single-threaded harness: the
 * non-owning-thread freeze and a failing thread creation. */
#include "pion_rt.h"
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int32_t ok = 0;
    const char *c = argv[1];
    void *s = pion_str_from_cstr("abc", 3);
    void *key = pion_str_from_cstr("key", 3);
    void *arr = pion_arr_new(0, 0);
    if (!strcmp(c, "str_index")) pion_str_byte_at(s, 3);
    else if (!strcmp(c, "slice")) pion_str_slice_data((const PionString *)s, 2, 9);
    else if (!strcmp(c, "bytes_length")) pion_bytes_new(-1);
    else if (!strcmp(c, "bytes_dest")) pion_bytes_copy_to_ptr(pion_bytes_new(4), 0, NULL, 2);
    else if (!strcmp(c, "arr_get")) pion_arr_get(arr, 0);
    else if (!strcmp(c, "arr_set")) pion_arr_set(arr, 1, 5);
    else if (!strcmp(c, "arr_pop")) pion_arr_pop(arr);
    else if (!strcmp(c, "map_null")) pion_map_set(NULL, key, 1);
    else if (!strcmp(c, "map_empty")) pion_map_get(pion_map_new(0), key);
    else if (!strcmp(c, "map_miss")) {
        void *m = pion_map_new(0);
        pion_map_set(m, pion_str_from_cstr("other", 5), 7);
        pion_map_get(m, key);
    } else if (!strcmp(c, "spawn")) pion_scope_spawn(NULL, NULL, NULL);
    else if (!strcmp(c, "argv_index")) pion_world_argv(NULL, 0);
    else if (!strcmp(c, "length")) pion_arr_new((int64_t)1 << 40, 0);
    else if (!strcmp(c, "stride")) pion_simd_i8_dot(arr, 0, 0, arr, 0, 0);
    else if (!strcmp(c, "mmap_write")) {
        /* The harness executable itself is a non-empty readable file. */
        void *b = pion_fs_mmap_ro(pion_str_from_cstr(argv[0], (int64_t)strlen(argv[0])), &ok);
        if (!ok || pion_bytes_len(b) <= 0) return 4;
        pion_bytes_set(b, 0, 1);
    }
    else if (!strcmp(c, "ok")) {
        /* The same calls in bounds return normally. */
        void *m = pion_map_new(0);
        pion_map_set(m, key, 42);
        pion_arr_push(arr, 9);
        int byte = pion_str_byte_at(s, 2);
        long long got = (long long)pion_map_get(m, key);
        long long first = (long long)pion_arr_get(arr, 0);
        long long popped = (long long)pion_arr_pop(arr);
        printf("ok %d %lld %lld %lld\n", byte, got, first, popped);
        pion_rc_dec(m);
        pion_rc_dec(arr);
        pion_rc_dec(key);
        pion_rc_dec(s);
        return 0;
    }
    return 3;
}
