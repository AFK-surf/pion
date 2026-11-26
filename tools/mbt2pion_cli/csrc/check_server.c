/* Bidirectional POSIX NDJSON client for long-lived `pionc check --server`.
 * On Windows (_WIN32), exports safe stubs that return unavailable so the CLI
 * transparently falls back to one-shot `pionc check --json`.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32

int mbt_check_server_start(const char *pionc_bin, const char *scratch_dir) {
    (void)pionc_bin;
    (void)scratch_dir;
    return -1;
}

int mbt_check_server_rpc(int handle, const char *req, int req_len) {
    (void)handle;
    (void)req;
    (void)req_len;
    return -1;
}

const char *mbt_check_server_last_resp(int handle) {
    (void)handle;
    return "";
}

void mbt_check_server_stop(int handle) {
    (void)handle;
}

#else

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MBT_MAX_SERVERS 4
#define MBT_SERVER_MAX_LINE (64u * 1024u * 1024u)

typedef struct {
    int in_use;
    pid_t pid;
    int to_child;
    int from_child;
    char *resp_buf;
    size_t resp_cap;
    char rbuf[8192];
    size_t rbuf_pos;
    size_t rbuf_len;
} MbtCheckServer;

static MbtCheckServer g_servers[MBT_MAX_SERVERS];
static int g_atexit_registered = 0;

static void set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags >= 0) {
        (void)fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
    }
}

static int write_all_fd(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        off += (size_t)n;
    }
    return 0;
}

static void mbt_check_server_cleanup_slot(int idx) {
    if (idx < 0 || idx >= MBT_MAX_SERVERS) return;
    MbtCheckServer *s = &g_servers[idx];
    if (!s->in_use) return;

    if (s->to_child >= 0) {
        const char quit_msg[] = "{\"quit\":true}\n";
        (void)write_all_fd(s->to_child, quit_msg, sizeof(quit_msg) - 1);
        close(s->to_child);
        s->to_child = -1;
    }
    if (s->from_child >= 0) {
        close(s->from_child);
        s->from_child = -1;
    }
    if (s->pid > 0) {
        int status = 0;
        int reaped = 0;
        for (int i = 0; i < 40; i++) {
            pid_t r = waitpid(s->pid, &status, WNOHANG);
            if (r == s->pid || (r < 0 && errno == ECHILD)) {
                reaped = 1;
                break;
            }
            struct timespec ts;
            ts.tv_sec = 0;
            ts.tv_nsec = 5 * 1000 * 1000; /* 5ms */
            (void)nanosleep(&ts, NULL);
        }
        if (!reaped) {
            (void)kill(s->pid, SIGKILL);
            while (waitpid(s->pid, &status, 0) < 0 && errno == EINTR) {
            }
        }
        s->pid = -1;
    }
    free(s->resp_buf);
    s->resp_buf = NULL;
    s->resp_cap = 0;
    s->rbuf_pos = 0;
    s->rbuf_len = 0;
    s->in_use = 0;
}

static void mbt_check_server_atexit(void) {
    for (int i = 0; i < MBT_MAX_SERVERS; i++) {
        if (g_servers[i].in_use) {
            mbt_check_server_cleanup_slot(i);
        }
    }
}

int mbt_check_server_start(const char *pionc_bin, const char *scratch_dir) {
    if (!pionc_bin || !pionc_bin[0] || !scratch_dir || !scratch_dir[0]) {
        return -1;
    }
    int slot = -1;
    for (int i = 0; i < MBT_MAX_SERVERS; i++) {
        if (!g_servers[i].in_use) {
            slot = i;
            break;
        }
    }
    if (slot < 0) return -1;

    (void)signal(SIGPIPE, SIG_IGN);
    if (!g_atexit_registered) {
        g_atexit_registered = 1;
        (void)atexit(mbt_check_server_atexit);
    }

    int p_in[2] = {-1, -1};
    int p_out[2] = {-1, -1};
    if (pipe(p_in) != 0) return -1;
    if (pipe(p_out) != 0) {
        close(p_in[0]);
        close(p_in[1]);
        return -1;
    }
    set_cloexec(p_in[1]);
    set_cloexec(p_out[0]);

    pid_t pid = fork();
    if (pid < 0) {
        close(p_in[0]);
        close(p_in[1]);
        close(p_out[0]);
        close(p_out[1]);
        return -1;
    }
    if (pid == 0) {
        (void)dup2(p_in[0], STDIN_FILENO);
        (void)dup2(p_out[1], STDOUT_FILENO);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            (void)dup2(devnull, STDERR_FILENO);
            if (devnull > STDERR_FILENO) close(devnull);
        }
        close(p_in[0]);
        close(p_in[1]);
        close(p_out[0]);
        close(p_out[1]);

        char *const argv[] = {
            (char *)pionc_bin,
            (char *)"check",
            (char *)"--server",
            (char *)scratch_dir,
            NULL
        };
        execvp(pionc_bin, argv);
        _exit(127);
    }

    close(p_in[0]);
    close(p_out[1]);

    MbtCheckServer *s = &g_servers[slot];
    memset(s, 0, sizeof(*s));
    s->in_use = 1;
    s->pid = pid;
    s->to_child = p_in[1];
    s->from_child = p_out[0];
    return slot;
}

int mbt_check_server_rpc(int handle, const char *req, int req_len) {
    if (handle < 0 || handle >= MBT_MAX_SERVERS || !req || req_len < 0) {
        return -1;
    }
    MbtCheckServer *s = &g_servers[handle];
    if (!s->in_use || s->to_child < 0 || s->from_child < 0) {
        return -1;
    }

    if (write_all_fd(s->to_child, req, (size_t)req_len) != 0) {
        return -1;
    }
    if (write_all_fd(s->to_child, "\n", 1) != 0) {
        return -1;
    }

    size_t out_len = 0;
    for (;;) {
        if (s->rbuf_pos >= s->rbuf_len) {
            ssize_t n;
            do {
                n = read(s->from_child, s->rbuf, sizeof(s->rbuf));
            } while (n < 0 && errno == EINTR);
            if (n <= 0) {
                return -1;
            }
            s->rbuf_pos = 0;
            s->rbuf_len = (size_t)n;
        }
        char *nl = (char *)memchr(s->rbuf + s->rbuf_pos, '\n', s->rbuf_len - s->rbuf_pos);
        size_t chunk = nl ? (size_t)(nl - (s->rbuf + s->rbuf_pos)) : (s->rbuf_len - s->rbuf_pos);
        if (out_len + chunk > MBT_SERVER_MAX_LINE) {
            return -1;
        }
        if (out_len + chunk + 1 > s->resp_cap) {
            size_t new_cap = s->resp_cap ? s->resp_cap : 4096;
            while (new_cap < out_len + chunk + 1) {
                new_cap *= 2;
            }
            char *nb = (char *)realloc(s->resp_buf, new_cap);
            if (!nb) return -1;
            s->resp_buf = nb;
            s->resp_cap = new_cap;
        }
        if (chunk > 0) {
            memcpy(s->resp_buf + out_len, s->rbuf + s->rbuf_pos, chunk);
            out_len += chunk;
        }
        s->rbuf_pos += chunk;
        if (nl) {
            s->rbuf_pos += 1; /* consume '\n' */
            if (out_len > 0 && s->resp_buf[out_len - 1] == '\r') {
                out_len--;
            }
            s->resp_buf[out_len] = '\0';
            return (int)out_len;
        }
    }
}

const char *mbt_check_server_last_resp(int handle) {
    if (handle < 0 || handle >= MBT_MAX_SERVERS) return "";
    MbtCheckServer *s = &g_servers[handle];
    if (!s->in_use || !s->resp_buf) return "";
    return s->resp_buf;
}

void mbt_check_server_stop(int handle) {
    mbt_check_server_cleanup_slot(handle);
}

#endif
