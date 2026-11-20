/* Load generator for examples/http_kv_service (POSIX C, pthreads).
 *
 *   cc -O2 -pthread bench_load.c -o bench_load
 *   ./bench_load [--keep-alive] <port> <conns> <reqs_per_conn>
 *
 * Each of <conns> threads issues <reqs_per_conn> real HTTP/1.1 requests, by
 * default one TCP connection per request (`Connection: close`); with
 * --keep-alive each thread opens one connection and sends all its requests on
 * it (`Connection: keep-alive`, responses framed by Content-Length). Requests
 * follow a repeating 5-step cycle on the thread's own keys and every status
 * and body is checked:
 *   PUT /items/c<i>-k<j> {"value":"值-<i>-<j>"} -> 200 {"ok":true,...}
 *   GET    -> 200 {"key":...,"value":...}
 *   DELETE -> 200 {"deleted":true}
 *   GET    -> 404 {"error":"not found"}
 *   GET /stats -> 200
 * Then one final GET /stats (its own short connection) must report exact
 * counters. Prints one JSON line with totals, errors, QPS and P50/P99 latency;
 * exits 0 only with 0 errors. The server sees <conns> * <reqs_per_conn> + 1
 * connections by default, <conns> + 1 with --keep-alive.
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int g_port;
static int g_reqs;
static int g_keep_alive;

/* One persistent keep-alive connection and the bytes read past the last
 * response (none expected, but never dropped). */
typedef struct {
    int fd;
    size_t len;
    char buf[16384];
} Conn;

typedef struct {
    int id;
    int errors;
    double *lat_ms;
    Conn conn;
    char first_error[256];
} Worker;

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static int connect_loopback(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((unsigned short)g_port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
        close(fd);
        return -1;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    return fd;
}

static int write_all(int fd, const char *p, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, p + off, n - off);
        if (w <= 0) return -1;
        off += (size_t)w;
    }
    return 0;
}

/* Sends one request on the worker's keep-alive connection (opened on first
 * use) and reads exactly one Content-Length-framed response; returns the status
 * (or -1, closing the connection) and copies the body into `body`. */
static int http_call_ka(Conn *c, const char *method, const char *path, const char *payload,
                        char *body, size_t body_cap) {
    if (c->fd < 0) {
        c->fd = connect_loopback();
        c->len = 0;
        if (c->fd < 0) return -1;
    }
    char req[1024];
    size_t plen = payload ? strlen(payload) : 0;
    int n = snprintf(req, sizeof req,
                     "%s %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Type: application/json\r\n"
                     "Content-Length: %zu\r\nConnection: keep-alive\r\n\r\n%s",
                     method, path, g_port, plen, payload ? payload : "");
    if (n <= 0 || (size_t)n >= sizeof req || write_all(c->fd, req, (size_t)n) != 0) goto fail;
    char *head_end;
    for (;;) {
        c->buf[c->len] = 0;
        head_end = strstr(c->buf, "\r\n\r\n");
        if (head_end) break;
        if (c->len >= sizeof c->buf - 1) goto fail;
        ssize_t r = read(c->fd, c->buf + c->len, sizeof c->buf - 1 - c->len);
        if (r <= 0) goto fail;
        c->len += (size_t)r;
    }
    int status = 0;
    if (sscanf(c->buf, "HTTP/1.1 %d", &status) != 1) goto fail;
    const char *cl = strstr(c->buf, "Content-Length: ");
    if (!cl || cl > head_end) goto fail;
    size_t clen = (size_t)strtoul(cl + 16, NULL, 10);
    size_t need = (size_t)(head_end - c->buf) + 4 + clen;
    if (need >= sizeof c->buf) goto fail;
    while (c->len < need) {
        ssize_t r = read(c->fd, c->buf + c->len, sizeof c->buf - 1 - c->len);
        if (r <= 0) goto fail;
        c->len += (size_t)r;
    }
    snprintf(body, body_cap, "%.*s", (int)clen, head_end + 4);
    memmove(c->buf, c->buf + need, c->len - need);
    c->len -= need;
    return status;
fail:
    close(c->fd);
    c->fd = -1;
    c->len = 0;
    return -1;
}

/* Sends one request on a fresh connection; returns the status (or -1) and
 * copies the body into `body`. */
static int http_call(const char *method, const char *path, const char *payload, char *body,
                     size_t body_cap) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((unsigned short)g_port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
        close(fd);
        return -1;
    }
    char req[1024];
    size_t plen = payload ? strlen(payload) : 0;
    int n = snprintf(req, sizeof req,
                     "%s %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Type: application/json\r\n"
                     "Content-Length: %zu\r\nConnection: close\r\n\r\n%s",
                     method, path, g_port, plen, payload ? payload : "");
    if (n <= 0 || (size_t)n >= sizeof req) {
        close(fd);
        return -1;
    }
    size_t off = 0;
    while (off < (size_t)n) {
        ssize_t w = write(fd, req + off, (size_t)n - off);
        if (w <= 0) {
            close(fd);
            return -1;
        }
        off += (size_t)w;
    }
    char resp[4096];
    size_t got = 0;
    for (;;) {
        ssize_t r = read(fd, resp + got, sizeof resp - 1 - got);
        if (r < 0) {
            close(fd);
            return -1;
        }
        if (r == 0) break;
        got += (size_t)r;
        if (got >= sizeof resp - 1) break;
    }
    close(fd);
    resp[got] = 0;
    int status = 0;
    if (sscanf(resp, "HTTP/1.1 %d", &status) != 1) return -1;
    const char *b = strstr(resp, "\r\n\r\n");
    if (!b) return -1;
    snprintf(body, body_cap, "%s", b + 4);
    return status;
}

static void fail(Worker *w, const char *what, int status, const char *body) {
    if (w->errors++ == 0) {
        snprintf(w->first_error, sizeof w->first_error, "%.40s -> %d %.200s", what, status, body);
    }
}

/* One request of a worker: on its keep-alive connection or a fresh one. */
static int worker_call(Worker *w, const char *method, const char *path, const char *payload,
                       char *body, size_t body_cap) {
    if (g_keep_alive) return http_call_ka(&w->conn, method, path, payload, body, body_cap);
    return http_call(method, path, payload, body, body_cap);
}

static void *run_worker(void *arg) {
    Worker *w = (Worker *)arg;
    char path[128], payload[256], want[512], body[2048];
    w->conn.fd = -1;
    w->conn.len = 0;
    for (int r = 0; r < g_reqs; r++) {
        int j = r / 5;
        int step = r % 5;
        snprintf(path, sizeof path, "/items/c%d-k%d", w->id, j);
        double t0 = now_ms();
        int st;
        if (step == 0) {
            snprintf(payload, sizeof payload, "{\"value\":\"\xe5\x80\xbc-%d-%d\"}", w->id, j);
            st = worker_call(w, "PUT", path, payload, body, sizeof body);
            snprintf(want, sizeof want, "{\"ok\":true,\"key\":\"c%d-k%d\",\"value\":\"\xe5\x80\xbc-%d-%d\"}",
                     w->id, j, w->id, j);
            if (st != 200 || strcmp(body, want) != 0) fail(w, "PUT", st, body);
        } else if (step == 1) {
            st = worker_call(w, "GET", path, NULL, body, sizeof body);
            snprintf(want, sizeof want, "{\"key\":\"c%d-k%d\",\"value\":\"\xe5\x80\xbc-%d-%d\"}", w->id, j,
                     w->id, j);
            if (st != 200 || strcmp(body, want) != 0) fail(w, "GET hit", st, body);
        } else if (step == 2) {
            st = worker_call(w, "DELETE", path, NULL, body, sizeof body);
            if (st != 200 || strcmp(body, "{\"deleted\":true}") != 0) fail(w, "DELETE", st, body);
        } else if (step == 3) {
            st = worker_call(w, "GET", path, NULL, body, sizeof body);
            if (st != 404 || strcmp(body, "{\"error\":\"not found\"}") != 0) fail(w, "GET miss", st, body);
        } else {
            st = worker_call(w, "GET", "/stats", NULL, body, sizeof body);
            if (st != 200 || strstr(body, "\"total_reqs\":") == NULL) fail(w, "STATS", st, body);
        }
        w->lat_ms[r] = now_ms() - t0;
    }
    if (w->conn.fd >= 0) {
        if (w->conn.len != 0) fail(w, "KEEP-ALIVE residue", (int)w->conn.len, "unexpected bytes");
        close(w->conn.fd);
    }
    return NULL;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    int a = 1;
    if (argc == 5 && strcmp(argv[1], "--keep-alive") == 0) {
        g_keep_alive = 1;
        a = 2;
    }
    if (argc - a != 3) {
        fprintf(stderr, "usage: %s [--keep-alive] <port> <conns> <reqs_per_conn>\n", argv[0]);
        return 2;
    }
    g_port = atoi(argv[a]);
    int conns = atoi(argv[a + 1]);
    g_reqs = atoi(argv[a + 2]);
    if (g_port <= 0 || conns <= 0 || g_reqs <= 0 || g_reqs % 5 != 0) {
        fprintf(stderr, "need port > 0, conns > 0 and reqs_per_conn a positive multiple of 5\n");
        return 2;
    }
    Worker *ws = calloc((size_t)conns, sizeof *ws);
    pthread_t *th = calloc((size_t)conns, sizeof *th);
    double *lat = calloc((size_t)conns * (size_t)g_reqs, sizeof *lat);
    if (!ws || !th || !lat) return 2;
    double t0 = now_ms();
    for (int i = 0; i < conns; i++) {
        ws[i].id = i;
        ws[i].lat_ms = lat + (size_t)i * (size_t)g_reqs;
        if (pthread_create(&th[i], NULL, run_worker, &ws[i]) != 0) return 2;
    }
    int errors = 0;
    for (int i = 0; i < conns; i++) {
        pthread_join(th[i], NULL);
        errors += ws[i].errors;
        if (ws[i].errors) fprintf(stderr, "conn %d: %d error(s), first: %s\n", i, ws[i].errors, ws[i].first_error);
    }
    double wall = now_ms() - t0;
    long total = (long)conns * g_reqs;

    /* Exact server-side counters (this request is number total + 1). */
    char body[2048], want[512];
    int st = http_call("GET", "/stats", NULL, body, sizeof body);
    long per_op = total / 5;
    snprintf(want, sizeof want,
             "{\"total_reqs\":%ld,\"keys\":0,\"hits\":%ld,\"misses\":%ld,\"puts\":%ld,\"deletes\":%ld}",
             total + 1, per_op, per_op, per_op, per_op);
    int stats_ok = st == 200 && strcmp(body, want) == 0;
    if (!stats_ok) {
        fprintf(stderr, "final /stats mismatch: got %d %s want %s\n", st, body, want);
        errors++;
    }

    qsort(lat, (size_t)total, sizeof *lat, cmp_double);
    double p50 = lat[(size_t)(total * 50 / 100)];
    double p99 = lat[(size_t)(total * 99 / 100)];
    printf("{\"keep_alive\":%s,\"conns\":%d,\"reqs_per_conn\":%d,\"total_reqs\":%ld,\"errors\":%d,\"stats_exact\":%s,"
           "\"wall_ms\":%.1f,\"qps\":%.0f,\"p50_ms\":%.3f,\"p99_ms\":%.3f,\"final_stats\":%s}\n",
           g_keep_alive ? "true" : "false", conns, g_reqs, total, errors, stats_ok ? "true" : "false", wall, (double)total * 1000.0 / wall,
           p50, p99, st == 200 ? body : "null");
    free(lat);
    free(th);
    free(ws);
    return errors == 0 ? 0 : 1;
}
