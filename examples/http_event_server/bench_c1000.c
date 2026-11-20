/* bench_c1000: event-driven keep-alive load client for http_event_server.
 *
 *   bench_c1000 <port> [conns=1000] [reqs_per_conn=40] [threads=4]
 *
 * Opens <conns> TCP connections to 127.0.0.1:<port> spread over <threads>
 * threads and keeps every one of them open until the whole run is over (all
 * connections are established before the first request is sent). Each thread
 * multiplexes its connections with poll(2); every connection sends its
 * requests one after another on the same HTTP/1.1 keep-alive socket:
 *   request 0         PUT /kv/c<i>        {"value":"v<i>"}       -> 200
 *   odd requests      GET /kv/c<i>        (hit, body checked)    -> 200
 *   even requests > 0 GET /kv/m<i>-<j>    (miss)                 -> 404
 * Then one GET /stats on a fresh connection must report exactly the expected
 * counters. Prints one JSON line (QPS, P50/P99/max latency, errors) and exits
 * non-zero on any error or counter mismatch.
 */
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define BUF_CAP 8192
#define IO_TIMEOUT_MS 15000

typedef struct {
    int fd;
    int id;          /* global connection index */
    int next;        /* next request index to send */
    int done;        /* responses received */
    char out[256];
    int out_len, out_off;
    char in[BUF_CAP];
    int in_len;
    uint64_t t_sent;
} Conn;

typedef struct {
    int first, count;
    Conn *conns;
    uint64_t *lat;   /* count * reqs latencies (ns) */
    long nlat;
    long errors;
    long connected;
} Worker;

static int g_port, g_conns, g_reqs, g_threads;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static int g_ready = 0, g_go = 0;
static uint64_t g_t0;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int connect_lo(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)g_port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int rc;
    do {
        rc = connect(fd, (struct sockaddr *)&a, sizeof(a));
    } while (rc < 0 && errno == EINTR);
    if (rc != 0) {
        close(fd);
        return -1;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return fd;
}

static void build_request(Conn *c) {
    int j = c->next;
    if (j == 0) {
        char body[64];
        int bl = snprintf(body, sizeof(body), "{\"value\":\"v%d\"}", c->id);
        c->out_len = snprintf(c->out, sizeof(c->out),
                              "PUT /kv/c%d HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s",
                              c->id, bl, body);
    } else if (j % 2 == 1) {
        c->out_len = snprintf(c->out, sizeof(c->out), "GET /kv/c%d HTTP/1.1\r\nHost: x\r\n\r\n", c->id);
    } else {
        c->out_len = snprintf(c->out, sizeof(c->out), "GET /kv/m%d-%d HTTP/1.1\r\nHost: x\r\n\r\n",
                              c->id, j);
    }
    c->out_off = 0;
}

/* Length of the complete response at the front of c->in, 0 if incomplete, -1 if malformed. */
static int response_len(Conn *c, int *status) {
    c->in[c->in_len] = '\0';
    char *he = strstr(c->in, "\r\n\r\n");
    if (!he) return c->in_len >= BUF_CAP - 1 ? -1 : 0;
    if (strncmp(c->in, "HTTP/1.1 ", 9) != 0) return -1;
    *status = atoi(c->in + 9);
    char *cl = strstr(c->in, "Content-Length: ");
    if (!cl || cl > he) return -1;
    int body = atoi(cl + 16);
    int total = (int)(he - c->in) + 4 + body;
    if (total >= BUF_CAP) return -1;
    return c->in_len >= total ? total : 0;
}

static int check_response(Conn *c, int status, int total) {
    int j = c->done;
    if (j == 0) return status == 200;
    if (j % 2 == 0) return status == 404;
    if (status != 200) return 0;
    char want[48];
    snprintf(want, sizeof(want), "\"value\":\"v%d\"}", c->id);
    c->in[total] = '\0';
    return strstr(c->in, want) != NULL;
}

/* Sends what the socket takes; returns -1 on error. */
static int pump_out(Conn *c) {
    while (c->out_off < c->out_len) {
        ssize_t n = send(c->fd, c->out + c->out_off, (size_t)(c->out_len - c->out_off), 0);
        if (n > 0) {
            c->out_off += (int)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            return 0;
        } else {
            return -1;
        }
    }
    return 0;
}

static void *worker_main(void *arg) {
    Worker *w = (Worker *)arg;
    for (int i = 0; i < w->count; i++) {
        Conn *c = &w->conns[i];
        memset(c, 0, sizeof(*c));
        c->id = w->first + i;
        c->fd = connect_lo();
        if (c->fd < 0) {
            fprintf(stderr, "connect %d failed: %s\n", c->id, strerror(errno));
            w->errors++;
            continue;
        }
        w->connected++;
        fcntl(c->fd, F_SETFL, fcntl(c->fd, F_GETFL, 0) | O_NONBLOCK);
    }
    /* Every connection of every thread is open before the first request. */
    pthread_mutex_lock(&g_mu);
    g_ready++;
    if (g_ready == g_threads) {
        g_t0 = now_ns();
        g_go = 1;
        pthread_cond_broadcast(&g_cv);
    }
    while (!g_go) pthread_cond_wait(&g_cv, &g_mu);
    pthread_mutex_unlock(&g_mu);

    struct pollfd *pfds = calloc((size_t)w->count, sizeof(*pfds));
    int *idx = calloc((size_t)w->count, sizeof(int));
    int active = 0;
    for (int i = 0; i < w->count; i++) {
        Conn *c = &w->conns[i];
        if (c->fd < 0) continue;
        build_request(c);
        c->t_sent = now_ns();
        c->next = 1;
        if (pump_out(c) < 0) {
            w->errors++;
            close(c->fd);
            c->fd = -1;
            continue;
        }
        active++;
    }
    while (active > 0) {
        int n = 0;
        for (int i = 0; i < w->count; i++) {
            Conn *c = &w->conns[i];
            if (c->fd < 0 || c->done >= g_reqs) continue;
            pfds[n].fd = c->fd;
            pfds[n].events = (short)(POLLIN | (c->out_off < c->out_len ? POLLOUT : 0));
            pfds[n].revents = 0;
            idx[n++] = i;
        }
        int pr = poll(pfds, (nfds_t)n, IO_TIMEOUT_MS);
        if (pr < 0 && errno == EINTR) continue;
        if (pr <= 0) {
            fprintf(stderr, "poll %s with %d connections waiting\n", pr == 0 ? "timed out" : "failed", n);
            w->errors += n;
            break;
        }
        for (int k = 0; k < n; k++) {
            if (!pfds[k].revents) continue;
            Conn *c = &w->conns[idx[k]];
            if ((pfds[k].revents & POLLOUT) && pump_out(c) < 0) goto fail;
            if (!(pfds[k].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            for (;;) {
                ssize_t r = recv(c->fd, c->in + c->in_len, (size_t)(BUF_CAP - 1 - c->in_len), 0);
                if (r > 0) {
                    c->in_len += (int)r;
                    if (c->in_len >= BUF_CAP - 1) break;
                    continue;
                }
                if (r < 0 && errno == EINTR) continue;
                if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
                goto fail; /* EOF or error mid-run */
            }
            for (;;) {
                int status = 0;
                int total = response_len(c, &status);
                if (total < 0) goto fail;
                if (total == 0) break;
                if (!check_response(c, status, total)) {
                    fprintf(stderr, "conn %d req %d: unexpected response: %.120s\n", c->id, c->done, c->in);
                    w->errors++;
                }
                w->lat[w->nlat++] = now_ns() - c->t_sent;
                memmove(c->in, c->in + total, (size_t)(c->in_len - total));
                c->in_len -= total;
                c->done++;
                if (c->done >= g_reqs) {
                    active--; /* stays open until every thread is done */
                    break;
                }
                build_request(c);
                c->next++;
                c->t_sent = now_ns();
                if (pump_out(c) < 0) goto fail;
            }
            continue;
        fail:
            fprintf(stderr, "conn %d failed after %d responses (errno %d)\n", c->id, c->done, errno);
            w->errors += g_reqs - c->done;
            close(c->fd);
            c->fd = -1;
            active--;
        }
    }
    free(pfds);
    free(idx);
    return NULL;
}

static long json_field(const char *s, const char *name) {
    char key[64];
    snprintf(key, sizeof(key), "\"%s\":", name);
    const char *p = strstr(s, key);
    return p ? atol(p + strlen(key)) : -1;
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: bench_c1000 <port> [conns=1000] [reqs_per_conn=40] [threads=4]\n");
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    g_port = atoi(argv[1]);
    g_conns = argc > 2 ? atoi(argv[2]) : 1000;
    g_reqs = argc > 3 ? atoi(argv[3]) : 40;
    g_threads = argc > 4 ? atoi(argv[4]) : 4;
    if (g_conns < 1 || g_reqs < 1 || g_threads < 1 || g_threads > g_conns) return 2;

    Worker *ws = calloc((size_t)g_threads, sizeof(Worker));
    pthread_t *ts = calloc((size_t)g_threads, sizeof(pthread_t));
    int first = 0;
    for (int t = 0; t < g_threads; t++) {
        ws[t].first = first;
        ws[t].count = g_conns / g_threads + (t < g_conns % g_threads ? 1 : 0);
        first += ws[t].count;
        ws[t].conns = calloc((size_t)ws[t].count, sizeof(Conn));
        ws[t].lat = calloc((size_t)ws[t].count * (size_t)g_reqs, sizeof(uint64_t));
        pthread_create(&ts[t], NULL, worker_main, &ws[t]);
    }
    long errors = 0, nlat = 0, connected = 0;
    for (int t = 0; t < g_threads; t++) {
        pthread_join(ts[t], NULL);
        errors += ws[t].errors;
        nlat += ws[t].nlat;
        connected += ws[t].connected;
    }
    uint64_t elapsed = now_ns() - g_t0;
    uint64_t *all = calloc((size_t)(nlat > 0 ? nlat : 1), sizeof(uint64_t));
    long k = 0;
    for (int t = 0; t < g_threads; t++) {
        memcpy(all + k, ws[t].lat, (size_t)ws[t].nlat * sizeof(uint64_t));
        k += ws[t].nlat;
    }
    qsort(all, (size_t)nlat, sizeof(uint64_t), cmp_u64);
    double p50 = nlat ? all[(nlat - 1) * 50 / 100] / 1000.0 : 0;
    double p99 = nlat ? all[(nlat - 1) * 99 / 100] / 1000.0 : 0;
    double pmax = nlat ? all[nlat - 1] / 1000.0 : 0;
    /* Close every keep-alive connection only now: all were open for the whole run. */
    for (int t = 0; t < g_threads; t++) {
        for (int i = 0; i < ws[t].count; i++) {
            if (ws[t].conns[i].fd >= 0) close(ws[t].conns[i].fd);
        }
    }

    long hits_per = g_reqs / 2;                 /* odd j in 1..reqs-1 */
    long miss_per = (g_reqs - 1) - hits_per;    /* even j in 2..reqs-1 */
    long want_total = (long)g_conns * g_reqs + 1;
    char stats[2048] = {0};
    int sfd = connect_lo();
    int stats_ok = 0;
    if (sfd >= 0) {
        const char *req = "GET /stats HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
        if (send(sfd, req, strlen(req), 0) == (ssize_t)strlen(req)) {
            size_t got = 0;
            ssize_t r;
            while (got < sizeof(stats) - 1 && (r = recv(sfd, stats + got, sizeof(stats) - 1 - got, 0)) > 0) {
                got += (size_t)r;
            }
            stats[got] = '\0';
        }
        close(sfd);
    }
    const char *body = strstr(stats, "\r\n\r\n");
    body = body ? body + 4 : "";
    long s_total = json_field(body, "total_reqs"), s_keys = json_field(body, "keys");
    long s_hits = json_field(body, "hits"), s_miss = json_field(body, "misses");
    long s_puts = json_field(body, "puts"), s_bad = json_field(body, "bad_requests");
    long s_acc = json_field(body, "accepted");
    stats_ok = s_total == want_total && s_keys == g_conns && s_puts == g_conns &&
               s_hits == (long)g_conns * hits_per && s_miss == (long)g_conns * miss_per && s_bad == 0 &&
               s_acc == (long)g_conns + 1;
    double secs = (double)elapsed / 1e9;
    printf("{\"conns\":%d,\"concurrent_open\":%ld,\"threads\":%d,\"reqs_per_conn\":%d,\"requests\":%ld,"
           "\"errors\":%ld,\"elapsed_ms\":%.1f,\"qps\":%.0f,\"p50_us\":%.1f,\"p99_us\":%.1f,\"max_us\":%.1f,"
           "\"stats_ok\":%s,\"stats\":%s}\n",
           g_conns, connected, g_threads, g_reqs, nlat, errors, secs * 1000.0, nlat / secs, p50, p99, pmax,
           stats_ok ? "true" : "false", body[0] ? body : "null");
    if (!stats_ok) {
        fprintf(stderr, "stats mismatch: want total_reqs=%ld keys=%d puts=%d hits=%ld misses=%ld accepted=%d\n",
                want_total, g_conns, g_conns, (long)g_conns * hits_per, (long)g_conns * miss_per, g_conns + 1);
    }
    return errors == 0 && connected == g_conns && nlat == (long)g_conns * g_reqs && stats_ok ? 0 : 1;
}
