#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *key;
    size_t key_len;
    uint64_t hash;
    int val;
    int used;
} Entry;

typedef struct {
    Entry *entries;
    size_t cap;
    size_t len;
} StrMap;

static uint64_t fnv1a(const char *s, size_t len) {
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= (unsigned char)s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static void map_init(StrMap *m, size_t cap) {
    m->cap = cap;
    m->len = 0;
    m->entries = (Entry *)calloc(cap, sizeof(Entry));
}

static void map_grow(StrMap *m) {
    size_t new_cap = m->cap * 2;
    Entry *ne = (Entry *)calloc(new_cap, sizeof(Entry));
    size_t mask = new_cap - 1;
    for (size_t i = 0; i < m->cap; i++) {
        if (m->entries[i].used) {
            size_t idx = (size_t)(m->entries[i].hash & mask);
            while (ne[idx].used) {
                idx = (idx + 1) & mask;
            }
            ne[idx] = m->entries[i];
        }
    }
    free(m->entries);
    m->entries = ne;
    m->cap = new_cap;
}

static void map_set(StrMap *m, const char *key, size_t key_len, int val) {
    if ((m->len + 1) * 10 >= m->cap * 7) {
        map_grow(m);
    }
    uint64_t h = fnv1a(key, key_len);
    size_t mask = m->cap - 1;
    size_t idx = (size_t)(h & mask);
    while (m->entries[idx].used) {
        if (m->entries[idx].hash == h &&
            m->entries[idx].key_len == key_len &&
            memcmp(m->entries[idx].key, key, key_len) == 0) {
            m->entries[idx].val = val;
            return;
        }
        idx = (idx + 1) & mask;
    }
    char *copy = (char *)malloc(key_len + 1);
    memcpy(copy, key, key_len);
    copy[key_len] = '\0';
    m->entries[idx].key = copy;
    m->entries[idx].key_len = key_len;
    m->entries[idx].hash = h;
    m->entries[idx].val = val;
    m->entries[idx].used = 1;
    m->len++;
}

static int map_get(const StrMap *m, const char *key, size_t key_len, int *out) {
    uint64_t h = fnv1a(key, key_len);
    size_t mask = m->cap - 1;
    size_t idx = (size_t)(h & mask);
    while (m->entries[idx].used) {
        if (m->entries[idx].hash == h &&
            m->entries[idx].key_len == key_len &&
            memcmp(m->entries[idx].key, key, key_len) == 0) {
            *out = m->entries[idx].val;
            return 1;
        }
        idx = (idx + 1) & mask;
    }
    return 0;
}

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} StrBuf;

static void sb_init(StrBuf *sb) {
    sb->cap = 1024;
    sb->len = 0;
    sb->data = (char *)malloc(sb->cap);
}

static void sb_push(StrBuf *sb, const char *s, size_t n) {
    if (sb->len + n > sb->cap) {
        while (sb->len + n > sb->cap) {
            sb->cap *= 2;
        }
        sb->data = (char *)realloc(sb->data, sb->cap);
    }
    memcpy(sb->data + sb->len, s, n);
    sb->len += n;
}

int main(int argc, char **argv) {
    int n = (argc > 1) ? atoi(argv[1]) : 100000;
    StrMap m;
    map_init(&m, 16);

    char kbuf[64];
    for (int i = 0; i < n; i++) {
        int tag = (i * 2654435) & 0xffff;
        int klen = snprintf(kbuf, sizeof(kbuf), "k_%d_%d", i, tag);
        int val = (i * 7 + 13) & 0x3fffffff;
        map_set(&m, kbuf, (size_t)klen, val);
    }

    int hits = 0;
    int val_sum = 0;
    for (int round = 0; round < 2; round++) {
        for (int i = 0; i < n; i++) {
            int tag = (i * 2654435) & 0xffff;
            int klen = snprintf(kbuf, sizeof(kbuf), "k_%d_%d", i, tag);
            int v = 0;
            if (map_get(&m, kbuf, (size_t)klen, &v)) {
                hits++;
                val_sum = (val_sum + v) & 0x3fffffff;
            }
            int mlen = snprintf(kbuf, sizeof(kbuf), "miss_%d", i);
            if (map_get(&m, kbuf, (size_t)mlen, &v)) {
                hits++;
                val_sum = (val_sum + v) & 0x3fffffff;
            }
        }
    }

    StrBuf sb;
    sb_init(&sb);
    char vbuf[64];
    for (int i = 0; i < n; i += 10) {
        int tag = (i * 2654435) & 0xffff;
        int klen = snprintf(kbuf, sizeof(kbuf), "k_%d_%d", i, tag);
        int v = 0;
        if (map_get(&m, kbuf, (size_t)klen, &v)) {
            sb_push(&sb, kbuf, (size_t)klen);
            int vlen = snprintf(vbuf, sizeof(vbuf), "=%d;", v);
            sb_push(&sb, vbuf, (size_t)vlen);
        }
    }

    int sb_hash = 0;
    for (size_t i = 0; i < sb.len; i++) {
        sb_hash = ((sb_hash * 31) + (unsigned char)sb.data[i]) & 0x3fffffff;
    }

    printf("%d %d %zu %d\n", hits, val_sum, sb.len, sb_hash);

    free(sb.data);
    for (size_t i = 0; i < m.cap; i++) {
        if (m.entries[i].used) {
            free(m.entries[i].key);
        }
    }
    free(m.entries);
    return 0;
}
