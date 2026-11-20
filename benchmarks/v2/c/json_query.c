/*
 * V2 Benchmark 1: json_query (C reference, hand-written lexer + recursive-descent AST)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    J_NULL = 0,
    J_BOOL = 1,
    J_INT  = 2,
    J_STR  = 3,
    J_ARR  = 4,
    J_OBJ  = 5
} JsonTag;

typedef struct JsonValue JsonValue;

typedef struct {
    char *key;
    size_t key_len;
    JsonValue *val;
} JsonEntry;

struct JsonValue {
    JsonTag tag;
    union {
        int b;
        int32_t i;
        struct { char *ptr; size_t len; } s;
        struct { JsonValue **items; size_t len; size_t cap; } arr;
        struct { JsonEntry *items; size_t len; size_t cap; } obj;
    } u;
};

static JsonValue *j_new(JsonTag tag) {
    JsonValue *v = (JsonValue *)calloc(1, sizeof(JsonValue));
    v->tag = tag;
    return v;
}

static void j_free(JsonValue *v) {
    if (!v) return;
    switch (v->tag) {
        case J_STR:
            free(v->u.s.ptr);
            break;
        case J_ARR:
            for (size_t i = 0; i < v->u.arr.len; i++) j_free(v->u.arr.items[i]);
            free(v->u.arr.items);
            break;
        case J_OBJ:
            for (size_t i = 0; i < v->u.obj.len; i++) {
                free(v->u.obj.items[i].key);
                j_free(v->u.obj.items[i].val);
            }
            free(v->u.obj.items);
            break;
        default:
            break;
    }
    free(v);
}

typedef struct {
    const char *src;
    size_t len;
    size_t pos;
} Parser;

static void skip_ws(Parser *p) {
    while (p->pos < p->len) {
        char c = p->src[p->pos];
        if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
            p->pos++;
        } else {
            break;
        }
    }
}

static char *parse_string_raw(Parser *p, size_t *out_len) {
    if (p->pos >= p->len || p->src[p->pos] != '"') {
        fprintf(stderr, "parse error: expected '\"' at %zu\n", p->pos);
        exit(1);
    }
    p->pos++;
    size_t cap = 32;
    size_t len = 0;
    char *buf = (char *)malloc(cap);
    while (p->pos < p->len) {
        char c = p->src[p->pos++];
        if (c == '"') {
            buf[len] = '\0';
            *out_len = len;
            return buf;
        }
        if (c == '\\' && p->pos < p->len) {
            char e = p->src[p->pos++];
            switch (e) {
                case '"':  c = '"';  break;
                case '\\': c = '\\'; break;
                case '/':  c = '/';  break;
                case 'b':  c = '\b'; break;
                case 'f':  c = '\f'; break;
                case 'n':  c = '\n'; break;
                case 'r':  c = '\r'; break;
                case 't':  c = '\t'; break;
                default:   c = e;    break;
            }
        }
        if (len + 2 > cap) {
            cap *= 2;
            buf = (char *)realloc(buf, cap);
        }
        buf[len++] = c;
    }
    fprintf(stderr, "parse error: unterminated string\n");
    exit(1);
}

static JsonValue *parse_value(Parser *p);

static JsonValue *parse_array(Parser *p) {
    p->pos++; /* '[' */
    JsonValue *v = j_new(J_ARR);
    skip_ws(p);
    if (p->pos < p->len && p->src[p->pos] == ']') {
        p->pos++;
        return v;
    }
    while (p->pos < p->len) {
        JsonValue *elem = parse_value(p);
        if (v->u.arr.len == v->u.arr.cap) {
            size_t nc = v->u.arr.cap ? v->u.arr.cap * 2 : 4;
            v->u.arr.items = (JsonValue **)realloc(v->u.arr.items, nc * sizeof(JsonValue *));
            v->u.arr.cap = nc;
        }
        v->u.arr.items[v->u.arr.len++] = elem;
        skip_ws(p);
        if (p->pos < p->len && p->src[p->pos] == ',') {
            p->pos++;
            skip_ws(p);
        } else if (p->pos < p->len && p->src[p->pos] == ']') {
            p->pos++;
            return v;
        } else {
            fprintf(stderr, "parse error: expected ',' or ']' at %zu\n", p->pos);
            exit(1);
        }
    }
    fprintf(stderr, "parse error: unterminated array\n");
    exit(1);
}

static JsonValue *parse_object(Parser *p) {
    p->pos++; /* '{' */
    JsonValue *v = j_new(J_OBJ);
    skip_ws(p);
    if (p->pos < p->len && p->src[p->pos] == '}') {
        p->pos++;
        return v;
    }
    while (p->pos < p->len) {
        skip_ws(p);
        size_t klen = 0;
        char *key = parse_string_raw(p, &klen);
        skip_ws(p);
        if (p->pos >= p->len || p->src[p->pos] != ':') {
            fprintf(stderr, "parse error: expected ':' at %zu\n", p->pos);
            exit(1);
        }
        p->pos++;
        JsonValue *val = parse_value(p);
        if (v->u.obj.len == v->u.obj.cap) {
            size_t nc = v->u.obj.cap ? v->u.obj.cap * 2 : 4;
            v->u.obj.items = (JsonEntry *)realloc(v->u.obj.items, nc * sizeof(JsonEntry));
            v->u.obj.cap = nc;
        }
        v->u.obj.items[v->u.obj.len].key = key;
        v->u.obj.items[v->u.obj.len].key_len = klen;
        v->u.obj.items[v->u.obj.len].val = val;
        v->u.obj.len++;
        skip_ws(p);
        if (p->pos < p->len && p->src[p->pos] == ',') {
            p->pos++;
            skip_ws(p);
        } else if (p->pos < p->len && p->src[p->pos] == '}') {
            p->pos++;
            return v;
        } else {
            fprintf(stderr, "parse error: expected ',' or '}' at %zu\n", p->pos);
            exit(1);
        }
    }
    fprintf(stderr, "parse error: unterminated object\n");
    exit(1);
}

static JsonValue *parse_value(Parser *p) {
    skip_ws(p);
    if (p->pos >= p->len) {
        fprintf(stderr, "parse error: unexpected EOF\n");
        exit(1);
    }
    char c = p->src[p->pos];
    if (c == '{') return parse_object(p);
    if (c == '[') return parse_array(p);
    if (c == '"') {
        JsonValue *v = j_new(J_STR);
        v->u.s.ptr = parse_string_raw(p, &v->u.s.len);
        return v;
    }
    if (c == 't') {
        p->pos += 4;
        JsonValue *v = j_new(J_BOOL);
        v->u.b = 1;
        return v;
    }
    if (c == 'f') {
        p->pos += 5;
        JsonValue *v = j_new(J_BOOL);
        v->u.b = 0;
        return v;
    }
    if (c == 'n') {
        p->pos += 4;
        return j_new(J_NULL);
    }
    int neg = 0;
    if (c == '-') {
        neg = 1;
        p->pos++;
    }
    int32_t acc = 0;
    while (p->pos < p->len) {
        char d = p->src[p->pos];
        if (d >= '0' && d <= '9') {
            acc = acc * 10 + (d - '0');
            p->pos++;
        } else {
            break;
        }
    }
    JsonValue *v = j_new(J_INT);
    v->u.i = neg ? -acc : acc;
    return v;
}

static JsonValue *obj_get(const JsonValue *obj, const char *key, size_t klen) {
    if (!obj || obj->tag != J_OBJ) return NULL;
    for (size_t i = 0; i < obj->u.obj.len; i++) {
        if (obj->u.obj.items[i].key_len == klen &&
            memcmp(obj->u.obj.items[i].key, key, klen) == 0) {
            return obj->u.obj.items[i].val;
        }
    }
    return NULL;
}

/* Open-addressing FNV-1a HashMap (String -> int32_t) */
typedef struct {
    char *key;
    size_t key_len;
    uint64_t hash;
    int32_t val;
    int used;
} MapEntry;

typedef struct {
    MapEntry *entries;
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
    m->entries = (MapEntry *)calloc(cap, sizeof(MapEntry));
}

static void map_grow(StrMap *m) {
    size_t nc = m->cap * 2;
    MapEntry *ne = (MapEntry *)calloc(nc, sizeof(MapEntry));
    size_t mask = nc - 1;
    for (size_t i = 0; i < m->cap; i++) {
        if (m->entries[i].used) {
            size_t idx = (size_t)(m->entries[i].hash & mask);
            while (ne[idx].used) idx = (idx + 1) & mask;
            ne[idx] = m->entries[i];
        }
    }
    free(m->entries);
    m->entries = ne;
    m->cap = nc;
}

static void map_inc(StrMap *m, const char *key, size_t klen) {
    if ((m->len + 1) * 10 >= m->cap * 7) map_grow(m);
    uint64_t h = fnv1a(key, klen);
    size_t mask = m->cap - 1;
    size_t idx = (size_t)(h & mask);
    while (m->entries[idx].used) {
        if (m->entries[idx].hash == h &&
            m->entries[idx].key_len == klen &&
            memcmp(m->entries[idx].key, key, klen) == 0) {
            m->entries[idx].val++;
            return;
        }
        idx = (idx + 1) & mask;
    }
    char *copy = (char *)malloc(klen + 1);
    memcpy(copy, key, klen);
    copy[klen] = '\0';
    m->entries[idx].key = copy;
    m->entries[idx].key_len = klen;
    m->entries[idx].hash = h;
    m->entries[idx].val = 1;
    m->entries[idx].used = 1;
    m->len++;
}

static void map_free(StrMap *m) {
    for (size_t i = 0; i < m->cap; i++) {
        if (m->entries[i].used) free(m->entries[i].key);
    }
    free(m->entries);
}

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} StrBuf;

static void sb_init(StrBuf *sb) {
    sb->cap = 4096;
    sb->len = 0;
    sb->data = (char *)malloc(sb->cap);
}

static void sb_reserve(StrBuf *sb, size_t add) {
    if (sb->len + add > sb->cap) {
        while (sb->len + add > sb->cap) sb->cap *= 2;
        sb->data = (char *)realloc(sb->data, sb->cap);
    }
}

static void sb_push(StrBuf *sb, const char *s, size_t n) {
    sb_reserve(sb, n);
    memcpy(sb->data + sb->len, s, n);
    sb->len += n;
}

static void sb_push_char(StrBuf *sb, char c) {
    sb_reserve(sb, 1);
    sb->data[sb->len++] = c;
}

static void sb_push_int(StrBuf *sb, int32_t v) {
    char tmp[32];
    int n = snprintf(tmp, sizeof(tmp), "%d", v);
    sb_push(sb, tmp, (size_t)n);
}

static void sb_push_json_escaped(StrBuf *sb, const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (c == '"') {
            sb_push(sb, "\\\"", 2);
        } else if (c == '\\') {
            sb_push(sb, "\\\\", 2);
        } else if (c == '\n') {
            sb_push(sb, "\\n", 2);
        } else if (c == '\r') {
            sb_push(sb, "\\r", 2);
        } else if (c == '\t') {
            sb_push(sb, "\\t", 2);
        } else {
            sb_push_char(sb, c);
        }
    }
}

static int32_t poly_hash(const char *s, size_t len) {
    int32_t h = 0;
    for (size_t i = 0; i < len; i++) {
        h = (int32_t)(((uint32_t)h * 31U + (unsigned char)s[i]) & 0x3fffffffU);
    }
    return h;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <dataset.json>\n", argv[0]);
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror("fopen");
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long fsz = ftell(f);
    rewind(f);
    char *src = (char *)malloc((size_t)fsz + 1);
    size_t nread = fread(src, 1, (size_t)fsz, f);
    src[nread] = '\0';
    fclose(f);

    Parser p = { src, nread, 0 };
    JsonValue *root = parse_value(&p);

    JsonValue *records = obj_get(root, "records", 7);
    if (!records || records->tag != J_ARR) {
        fprintf(stderr, "missing records array\n");
        return 1;
    }

    StrMap role_counts, tag_counts;
    map_init(&role_counts, 16);
    map_init(&tag_counts, 16);

    StrBuf out;
    sb_init(&out);

    int32_t total = 0;
    int32_t matched = 0;
    int32_t sum_lat = 0;

    for (size_t i = 0; i < records->u.arr.len; i++) {
        total++;
        JsonValue *rec = records->u.arr.items[i];
        JsonValue *user = obj_get(rec, "user", 4);
        JsonValue *metrics = obj_get(rec, "metrics", 7);
        JsonValue *note = obj_get(rec, "note", 4);

        JsonValue *id_v = obj_get(user, "id", 2);
        JsonValue *role_v = obj_get(user, "role", 4);
        JsonValue *active_v = obj_get(user, "active", 6);
        JsonValue *lat_v = obj_get(metrics, "latency_ms", 10);
        JsonValue *tags_v = obj_get(metrics, "tags", 4);

        map_inc(&role_counts, role_v->u.s.ptr, role_v->u.s.len);

        int has_prod = 0;
        for (size_t t = 0; t < tags_v->u.arr.len; t++) {
            JsonValue *tv = tags_v->u.arr.items[t];
            map_inc(&tag_counts, tv->u.s.ptr, tv->u.s.len);
            if (tv->u.s.len == 4 && memcmp(tv->u.s.ptr, "prod", 4) == 0) {
                has_prod = 1;
            }
        }

        if (active_v->u.b && lat_v->u.i >= 150 && has_prod) {
            matched++;
            sum_lat += lat_v->u.i;
            sb_push(&out, "{\"id\":", 6);
            sb_push_int(&out, id_v->u.i);
            sb_push(&out, ",\"role\":\"", 9);
            sb_push_json_escaped(&out, role_v->u.s.ptr, role_v->u.s.len);
            sb_push(&out, "\",\"lat\":", 8);
            sb_push_int(&out, lat_v->u.i);
            sb_push(&out, ",\"note\":\"", 9);
            sb_push_json_escaped(&out, note->u.s.ptr, note->u.s.len);
            sb_push(&out, "\"}\n", 3);
        }
    }

    int32_t role_tag_hash = 0;
    for (size_t i = 0; i < role_counts.cap; i++) {
        if (role_counts.entries[i].used) {
            int32_t kh = poly_hash(role_counts.entries[i].key, role_counts.entries[i].key_len);
            int32_t eh = (int32_t)((((uint32_t)kh * 17U + (uint32_t)role_counts.entries[i].val) ^ 0x13579U) & 0x3fffffffU);
            role_tag_hash ^= eh;
        }
    }
    for (size_t i = 0; i < tag_counts.cap; i++) {
        if (tag_counts.entries[i].used) {
            int32_t kh = poly_hash(tag_counts.entries[i].key, tag_counts.entries[i].key_len);
            int32_t eh = (int32_t)((((uint32_t)kh * 29U + (uint32_t)tag_counts.entries[i].val) ^ 0x2468aU) & 0x3fffffffU);
            role_tag_hash ^= eh;
        }
    }

    int32_t out_hash = poly_hash(out.data, out.len);
    printf("%d %d %d %d %zu %d\n", total, matched, sum_lat, role_tag_hash, out.len, out_hash);

    free(out.data);
    map_free(&role_counts);
    map_free(&tag_counts);
    j_free(root);
    free(src);
    return 0;
}
