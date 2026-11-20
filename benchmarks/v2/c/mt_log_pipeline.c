/*
 * V2 Benchmark 3: mt_log_pipeline (C reference, pthreads + bounded channels)
 * Usage: mt_log_pipeline <logs.txt> [1|4]
 */
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *data;
    size_t len;
} HeapStr;

typedef struct {
    HeapStr *buf;
    int cap;
    int head;
    int tail;
    int count;
    int closed;
    pthread_mutex_t mu;
    pthread_cond_t not_empty;
    pthread_cond_t not_full;
} StrChan;

static void chan_init(StrChan *ch, int cap) {
    ch->buf = (HeapStr *)calloc((size_t)cap, sizeof(HeapStr));
    ch->cap = cap;
    ch->head = ch->tail = ch->count = ch->closed = 0;
    pthread_mutex_init(&ch->mu, NULL);
    pthread_cond_init(&ch->not_empty, NULL);
    pthread_cond_init(&ch->not_full, NULL);
}

static void chan_destroy(StrChan *ch) {
    free(ch->buf);
    pthread_mutex_destroy(&ch->mu);
    pthread_cond_destroy(&ch->not_empty);
    pthread_cond_destroy(&ch->not_full);
}

static int chan_send(StrChan *ch, HeapStr s) {
    pthread_mutex_lock(&ch->mu);
    while (ch->count == ch->cap && !ch->closed) {
        pthread_cond_wait(&ch->not_full, &ch->mu);
    }
    if (ch->closed) {
        pthread_mutex_unlock(&ch->mu);
        return 0;
    }
    ch->buf[ch->tail] = s;
    ch->tail = (ch->tail + 1) % ch->cap;
    ch->count++;
    pthread_cond_signal(&ch->not_empty);
    pthread_mutex_unlock(&ch->mu);
    return 1;
}

static int chan_recv(StrChan *ch, HeapStr *out) {
    pthread_mutex_lock(&ch->mu);
    while (ch->count == 0 && !ch->closed) {
        pthread_cond_wait(&ch->not_empty, &ch->mu);
    }
    if (ch->count == 0 && ch->closed) {
        pthread_mutex_unlock(&ch->mu);
        return 0;
    }
    *out = ch->buf[ch->head];
    ch->head = (ch->head + 1) % ch->cap;
    ch->count--;
    pthread_cond_signal(&ch->not_full);
    pthread_mutex_unlock(&ch->mu);
    return 1;
}

static void chan_close(StrChan *ch) {
    pthread_mutex_lock(&ch->mu);
    ch->closed = 1;
    pthread_cond_broadcast(&ch->not_empty);
    pthread_cond_broadcast(&ch->not_full);
    pthread_mutex_unlock(&ch->mu);
}

/* Worker-local String -> int64_t map */
typedef struct {
    char *key;
    size_t key_len;
    uint64_t hash;
    int64_t val;
    int used;
} SvcEntry;

typedef struct {
    SvcEntry *entries;
    size_t cap;
    size_t len;
} SvcMap;

static uint64_t fnv1a(const char *s, size_t len) {
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= (unsigned char)s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static void svc_map_init(SvcMap *m, size_t cap) {
    m->cap = cap;
    m->len = 0;
    m->entries = (SvcEntry *)calloc(cap, sizeof(SvcEntry));
}

static void svc_map_add(SvcMap *m, const char *key, size_t klen, int64_t delta) {
    if ((m->len + 1) * 10 >= m->cap * 7) {
        size_t nc = m->cap * 2;
        SvcEntry *ne = (SvcEntry *)calloc(nc, sizeof(SvcEntry));
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
    uint64_t h = fnv1a(key, klen);
    size_t mask = m->cap - 1;
    size_t idx = (size_t)(h & mask);
    while (m->entries[idx].used) {
        if (m->entries[idx].hash == h &&
            m->entries[idx].key_len == klen &&
            memcmp(m->entries[idx].key, key, klen) == 0) {
            m->entries[idx].val += delta;
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
    m->entries[idx].val = delta;
    m->entries[idx].used = 1;
    m->len++;
}

static void svc_map_free(SvcMap *m) {
    for (size_t i = 0; i < m->cap; i++) {
        if (m->entries[i].used) free(m->entries[i].key);
    }
    free(m->entries);
}

static int32_t poly_hash(const char *s, size_t len) {
    int32_t h = 0;
    for (size_t i = 0; i < len; i++) {
        h = (int32_t)(((uint32_t)h * 31U + (unsigned char)s[i]) & 0x3fffffffU);
    }
    return h;
}

typedef struct {
    int32_t lines;
    int32_t errs;
    int32_t slow;
    int64_t sum_lat;
    int64_t svc_sum;
    int32_t msg_xor;
} WorkerStats;

typedef struct {
    const char *src;
    size_t src_len;
    StrChan *work_ch;
} ProducerArg;

typedef struct {
    StrChan *work_ch;
    StrChan *alert_ch;
    atomic_int *active_workers;
    WorkerStats stats;
} WorkerArg;

static void *producer_fn(void *arg) {
    ProducerArg *pa = (ProducerArg *)arg;
    const char *s = pa->src;
    size_t n = pa->src_len;
    size_t pos = 0;
    while (pos < n) {
        size_t start = pos;
        int nl_count = 0;
        while (pos < n && nl_count < 10) {
            if (s[pos] == '\n') nl_count++;
            pos++;
        }
        size_t clen = pos - start;
        char *buf = (char *)malloc(clen + 1);
        memcpy(buf, s + start, clen);
        buf[clen] = '\0';
        HeapStr hs = { buf, clen };
        chan_send(pa->work_ch, hs);
    }
    chan_close(pa->work_ch);
    return NULL;
}

static void *worker_fn(void *arg) {
    WorkerArg *wa = (WorkerArg *)arg;
    SvcMap svc_lat;
    svc_map_init(&svc_lat, 16);

    int32_t lines = 0, errs = 0, slow = 0, msg_xor = 0;
    int64_t sum_lat = 0;

    HeapStr chunk;
    while (chan_recv(wa->work_ch, &chunk)) {
        const char *s = chunk.data;
        size_t n = chunk.len;
        size_t i = 0;
        while (i < n) {
            size_t line_start = i;
            while (i < n && s[i] != '\n') i++;
            size_t line_end = i;
            if (i < n && s[i] == '\n') i++;
            if (line_end <= line_start) continue;

            lines++;
            /* Format: ts=<n> level=<LVL> svc=<SVC> lat=<n> msg=<MSG> */
            size_t p = line_start;
            while (p < line_end && s[p] != ' ') p++; /* skip ts=... */
            if (p < line_end) p++;
            /* level= */
            p += 6;
            size_t lvl_s = p;
            while (p < line_end && s[p] != ' ') p++;
            size_t lvl_len = p - lvl_s;
            if (p < line_end) p++;
            /* svc= */
            p += 4;
            size_t svc_s = p;
            while (p < line_end && s[p] != ' ') p++;
            size_t svc_len = p - svc_s;
            if (p < line_end) p++;
            /* lat= */
            p += 4;
            int32_t lat = 0;
            while (p < line_end && s[p] != ' ') {
                lat = lat * 10 + (s[p] - '0');
                p++;
            }
            if (p < line_end) p++;
            /* msg= */
            p += 4;
            size_t msg_s = p;
            size_t msg_len = (line_end > msg_s) ? (line_end - msg_s) : 0;

            sum_lat += lat;
            svc_map_add(&svc_lat, s + svc_s, svc_len, lat);
            msg_xor ^= poly_hash(s + msg_s, msg_len);

            int is_err = (lvl_len == 3 && s[lvl_s] == 'E' && s[lvl_s + 1] == 'R' && s[lvl_s + 2] == 'R');
            int is_slow = (lat >= 500);
            if (is_err) errs++;
            if (is_slow) slow++;
            if (is_err || is_slow) {
                char lat_buf[32];
                int lat_len = snprintf(lat_buf, sizeof(lat_buf), "%d", lat);
                size_t alen = 6 + svc_len + 1 + lvl_len + 1 + (size_t)lat_len + 1 + msg_len;
                char *abuf = (char *)malloc(alen + 1);
                size_t off = 0;
                memcpy(abuf + off, "ALERT|", 6); off += 6;
                memcpy(abuf + off, s + svc_s, svc_len); off += svc_len;
                abuf[off++] = '|';
                memcpy(abuf + off, s + lvl_s, lvl_len); off += lvl_len;
                abuf[off++] = '|';
                memcpy(abuf + off, lat_buf, (size_t)lat_len); off += (size_t)lat_len;
                abuf[off++] = '|';
                memcpy(abuf + off, s + msg_s, msg_len); off += msg_len;
                abuf[off] = '\0';
                HeapStr ahs = { abuf, alen };
                chan_send(wa->alert_ch, ahs);
            }
        }
        free(chunk.data);
    }

    int64_t svc_sum = 0;
    for (size_t k = 0; k < svc_lat.cap; k++) {
        if (svc_lat.entries[k].used) svc_sum += svc_lat.entries[k].val;
    }
    svc_map_free(&svc_lat);

    wa->stats.lines = lines;
    wa->stats.errs = errs;
    wa->stats.slow = slow;
    wa->stats.sum_lat = sum_lat;
    wa->stats.svc_sum = svc_sum;
    wa->stats.msg_xor = msg_xor;

    if (atomic_fetch_sub(wa->active_workers, 1) == 1) {
        chan_close(wa->alert_ch);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <logs.txt> [1|4]\n", argv[0]);
        return 2;
    }
    int nworkers = (argc >= 3) ? atoi(argv[2]) : 1;
    if (nworkers < 1) nworkers = 1;
    if (nworkers > 16) nworkers = 16;

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

    StrChan work_ch, alert_ch;
    chan_init(&work_ch, 64);
    chan_init(&alert_ch, 256);

    atomic_int active_workers;
    atomic_init(&active_workers, nworkers);

    ProducerArg parg = { src, nread, &work_ch };
    pthread_t prod_th;
    pthread_create(&prod_th, NULL, producer_fn, &parg);

    WorkerArg wargs[16];
    pthread_t wths[16];
    for (int t = 0; t < nworkers; t++) {
        memset(&wargs[t], 0, sizeof(WorkerArg));
        wargs[t].work_ch = &work_ch;
        wargs[t].alert_ch = &alert_ch;
        wargs[t].active_workers = &active_workers;
        pthread_create(&wths[t], NULL, worker_fn, &wargs[t]);
    }

    int32_t alert_cnt = 0;
    int64_t alert_len_sum = 0;
    int32_t alert_xor = 0;
    HeapStr alert;
    while (chan_recv(&alert_ch, &alert)) {
        alert_cnt++;
        alert_len_sum += (int64_t)alert.len;
        alert_xor ^= poly_hash(alert.data, alert.len);
        free(alert.data);
    }

    pthread_join(prod_th, NULL);
    int32_t lines = 0, errs = 0, slow = 0, msg_xor = 0;
    int64_t sum_lat = 0, svc_sum = 0;
    for (int t = 0; t < nworkers; t++) {
        pthread_join(wths[t], NULL);
        lines += wargs[t].stats.lines;
        errs += wargs[t].stats.errs;
        slow += wargs[t].stats.slow;
        sum_lat += wargs[t].stats.sum_lat;
        svc_sum += wargs[t].stats.svc_sum;
        msg_xor ^= wargs[t].stats.msg_xor;
    }

    if (svc_sum != sum_lat) {
        fprintf(stderr, "svc_sum mismatch: %lld vs %lld\n", (long long)svc_sum, (long long)sum_lat);
        return 1;
    }

    printf("%d %d %d %lld %d %d %lld %d\n",
           lines, errs, slow, (long long)sum_lat, msg_xor,
           alert_cnt, (long long)alert_len_sum, alert_xor);

    chan_destroy(&work_ch);
    chan_destroy(&alert_ch);
    free(src);
    return 0;
}
