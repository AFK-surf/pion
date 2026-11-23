#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#endif

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <crt_externs.h>
#endif

#define PION_PROC_MAX_SLOTS 1024

typedef struct {
    pthread_mutex_t mu;
    int refcnt;
    pid_t pid;
    pid_t pgid;
    int is_pty;
    int stdin_fd;
    int stdout_fd;
    int stderr_fd;
    int pty_fd;
    int reaped;
    int exit_kind; /* 0 = exited, 1 = signaled */
    int exit_code;
    int closed;
} PionProc;

typedef struct {
    uint32_t gen;
    PionProc *proc;
} PionProcSlot;

static pthread_mutex_t g_table_mu = PTHREAD_MUTEX_INITIALIZER;
static PionProcSlot g_slots[PION_PROC_MAX_SLOTS];
static pthread_once_t g_sigpipe_once = PTHREAD_ONCE_INIT;

#ifndef __linux__
static pthread_mutex_t g_ptsname_mu = PTHREAD_MUTEX_INITIALIZER;
#endif

static void pion_proc_ignore_sigpipe(void) {
    (void)signal(SIGPIPE, SIG_IGN);
}

static void set_err(char *buf, int32_t cap, const char *msg) {
    if (!buf || cap <= 0) return;
    snprintf(buf, (size_t)cap, "%s", msg ? msg : "unknown error");
}

static void set_errno_err(char *buf, int32_t cap, const char *ctx, int err) {
    if (!buf || cap <= 0) return;
    snprintf(buf, (size_t)cap, "%s: %s", ctx, strerror(err));
}

static int set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int make_pipe_cloexec(int fds[2]) {
    if (pipe(fds) != 0) return -1;
    if (set_cloexec(fds[0]) != 0 || set_cloexec(fds[1]) != 0) {
        int e = errno;
        close(fds[0]);
        close(fds[1]);
        errno = e;
        return -1;
    }
    return 0;
}

static char **get_host_environ(void) {
#ifdef __APPLE__
    char ***ep = _NSGetEnviron();
    return ep ? *ep : NULL;
#else
    extern char **environ;
    return environ;
#endif
}

static void *slot_register(PionProc *p) {
    pthread_mutex_lock(&g_table_mu);
    for (uint32_t i = 0; i < PION_PROC_MAX_SLOTS; i++) {
        if (g_slots[i].proc == NULL) {
            g_slots[i].gen++;
            if (g_slots[i].gen == 0) g_slots[i].gen = 1;
            g_slots[i].proc = p;
            uint64_t handle = ((uint64_t)g_slots[i].gen << 16) | (uint64_t)(i + 1u);
            pthread_mutex_unlock(&g_table_mu);
            return (void *)(uintptr_t)handle;
        }
    }
    pthread_mutex_unlock(&g_table_mu);
    return NULL;
}

static PionProc *slot_acquire(void *h) {
    uintptr_t raw = (uintptr_t)h;
    if (raw == 0) return NULL;
    uint32_t idx1 = (uint32_t)(raw & 0xFFFFu);
    uint32_t gen = (uint32_t)((uint64_t)raw >> 16);
    if (idx1 == 0 || idx1 > PION_PROC_MAX_SLOTS) return NULL;
    uint32_t idx = idx1 - 1u;

    pthread_mutex_lock(&g_table_mu);
    PionProc *p = NULL;
    if (g_slots[idx].proc != NULL && g_slots[idx].gen == gen) {
        p = g_slots[idx].proc;
        pthread_mutex_lock(&p->mu);
        p->refcnt++;
        pthread_mutex_unlock(&p->mu);
    }
    pthread_mutex_unlock(&g_table_mu);
    return p;
}

static void proc_release(PionProc *p) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    p->refcnt--;
    int last = (p->refcnt == 0);
    pthread_mutex_unlock(&p->mu);
    if (last) {
        pthread_mutex_destroy(&p->mu);
        free(p);
    }
}

static void free_str_vec(char **vec) {
    if (!vec) return;
    for (size_t i = 0; vec[i] != NULL; i++) {
        free(vec[i]);
    }
    free(vec);
}

static int key_matches_list(const char *entry, size_t klen,
                            const char *const *keys, int32_t count) {
    for (int32_t i = 0; i < count; i++) {
        if (keys[i] && strlen(keys[i]) == klen && memcmp(entry, keys[i], klen) == 0) {
            return 1;
        }
    }
    return 0;
}

static char **build_envp(
    const char *const *env_set_keys, const char *const *env_set_vals, int32_t env_set_count,
    const char *const *env_unset_keys, int32_t env_unset_count,
    int32_t clear_env,
    char *err_buf, int32_t err_cap) {

    size_t cap = (size_t)(env_set_count > 0 ? env_set_count : 0) + 64u;
    char **out = (char **)calloc(cap + 1u, sizeof(char *));
    if (!out) {
        set_err(err_buf, err_cap, "out of memory building envp");
        return NULL;
    }
    size_t n = 0;

    if (!clear_env) {
        char **env = get_host_environ();
        if (env) {
            for (size_t i = 0; env[i] != NULL; i++) {
                const char *eq = strchr(env[i], '=');
                size_t klen = eq ? (size_t)(eq - env[i]) : strlen(env[i]);
                if (key_matches_list(env[i], klen, env_unset_keys, env_unset_count)) continue;
                if (key_matches_list(env[i], klen, env_set_keys, env_set_count)) continue;
                if (n >= cap) {
                    size_t ncap = cap * 2u;
                    char **tmp = (char **)realloc(out, (ncap + 1u) * sizeof(char *));
                    if (!tmp) {
                        out[n] = NULL;
                        free_str_vec(out);
                        set_err(err_buf, err_cap, "out of memory growing envp");
                        return NULL;
                    }
                    out = tmp;
                    cap = ncap;
                }
                size_t elen = strlen(env[i]);
                char *dup = (char *)malloc(elen + 1u);
                if (!dup) {
                    out[n] = NULL;
                    free_str_vec(out);
                    set_err(err_buf, err_cap, "out of memory copying env entry");
                    return NULL;
                }
                memcpy(dup, env[i], elen + 1u);
                out[n++] = dup;
            }
        }
    }

    for (int32_t i = 0; i < env_set_count; i++) {
        const char *k = env_set_keys[i] ? env_set_keys[i] : "";
        const char *v = env_set_vals[i] ? env_set_vals[i] : "";
        size_t kl = strlen(k);
        size_t vl = strlen(v);
        if (n >= cap) {
            size_t ncap = cap * 2u;
            char **tmp = (char **)realloc(out, (ncap + 1u) * sizeof(char *));
            if (!tmp) {
                out[n] = NULL;
                free_str_vec(out);
                set_err(err_buf, err_cap, "out of memory growing envp");
                return NULL;
            }
            out = tmp;
            cap = ncap;
        }
        char *kv = (char *)malloc(kl + 1u + vl + 1u);
        if (!kv) {
            out[n] = NULL;
            free_str_vec(out);
            set_err(err_buf, err_cap, "out of memory formatting env entry");
            return NULL;
        }
        memcpy(kv, k, kl);
        kv[kl] = '=';
        memcpy(kv + kl + 1u, v, vl + 1u);
        out[n++] = kv;
    }

    out[n] = NULL;
    return out;
}

static const char *find_env_val(char *const *envp, const char *key) {
    size_t kl = strlen(key);
    for (size_t i = 0; envp && envp[i] != NULL; i++) {
        if (strncmp(envp[i], key, kl) == 0 && envp[i][kl] == '=') {
            return envp[i] + kl + 1u;
        }
    }
    return NULL;
}

static int is_exec_file(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    if (S_ISDIR(st.st_mode)) return 0;
    return access(path, X_OK) == 0;
}

static char *resolve_exec_path(const char *prog, char *const *envp, int32_t clear_env,
                               char *err_buf, int32_t err_cap) {
    if (!prog || prog[0] == '\0') {
        set_err(err_buf, err_cap, "empty executable name");
        return NULL;
    }
    if (strchr(prog, '/') != NULL) {
        size_t len = strlen(prog);
        char *copy = (char *)malloc(len + 1u);
        if (!copy) {
            set_err(err_buf, err_cap, "out of memory");
            return NULL;
        }
        memcpy(copy, prog, len + 1u);
        return copy;
    }
    const char *path_env = find_env_val(envp, "PATH");
    if (!path_env && !clear_env) {
        path_env = "/usr/bin:/bin";
    }
    if (!path_env || path_env[0] == '\0') {
        snprintf(err_buf, (size_t)err_cap, "executable not found (empty PATH): %s", prog);
        return NULL;
    }
    size_t prog_len = strlen(prog);
    const char *cur = path_env;
    while (1) {
        const char *colon = strchr(cur, ':');
        size_t dlen = colon ? (size_t)(colon - cur) : strlen(cur);
        const char *dir = dlen > 0 ? cur : ".";
        size_t eff_dlen = dlen > 0 ? dlen : 1u;
        char *cand = (char *)malloc(eff_dlen + 1u + prog_len + 1u);
        if (!cand) {
            set_err(err_buf, err_cap, "out of memory");
            return NULL;
        }
        memcpy(cand, dir, eff_dlen);
        cand[eff_dlen] = '/';
        memcpy(cand + eff_dlen + 1u, prog, prog_len + 1u);
        if (is_exec_file(cand)) {
            return cand;
        }
        free(cand);
        if (!colon) break;
        cur = colon + 1;
    }
    snprintf(err_buf, (size_t)err_cap, "executable not found in PATH: %s", prog);
    return NULL;
}

static char **dup_argv(const char *const *argv, int32_t argc, char *err_buf, int32_t err_cap) {
    char **out = (char **)calloc((size_t)argc + 1u, sizeof(char *));
    if (!out) {
        set_err(err_buf, err_cap, "out of memory building argv");
        return NULL;
    }
    for (int32_t i = 0; i < argc; i++) {
        const char *s = argv[i] ? argv[i] : "";
        size_t len = strlen(s);
        char *dup = (char *)malloc(len + 1u);
        if (!dup) {
            free_str_vec(out);
            set_err(err_buf, err_cap, "out of memory copying argv");
            return NULL;
        }
        memcpy(dup, s, len + 1u);
        out[i] = dup;
    }
    out[argc] = NULL;
    return out;
}

static int64_t monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000L);
}

static void record_wait_status(PionProc *p, int status) {
    p->reaped = 1;
    if (WIFEXITED(status)) {
        p->exit_kind = 0;
        p->exit_code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        p->exit_kind = 1;
        p->exit_code = WTERMSIG(status);
    } else {
        p->exit_kind = 0;
        p->exit_code = 1;
    }
}

void *pion_proc_spawn(
    const char *const *argv, int32_t argc,
    const char *cwd,
    const char *const *env_set_keys, const char *const *env_set_vals, int32_t env_set_count,
    const char *const *env_unset_keys, int32_t env_unset_count,
    int32_t clear_env,
    char *err_buf, int32_t err_cap) {

    pthread_once(&g_sigpipe_once, pion_proc_ignore_sigpipe);
    if (!argv || argc <= 0) {
        set_err(err_buf, err_cap, "argv must not be empty");
        return NULL;
    }

    char **c_argv = dup_argv(argv, argc, err_buf, err_cap);
    if (!c_argv) return NULL;

    char **c_envp = build_envp(env_set_keys, env_set_vals, env_set_count,
                               env_unset_keys, env_unset_count, clear_env,
                               err_buf, err_cap);
    if (!c_envp) {
        free_str_vec(c_argv);
        return NULL;
    }

    char *exec_path = resolve_exec_path(c_argv[0], c_envp, clear_env, err_buf, err_cap);
    if (!exec_path) {
        free_str_vec(c_envp);
        free_str_vec(c_argv);
        return NULL;
    }

    int in_p[2] = {-1, -1}, out_p[2] = {-1, -1}, err_p[2] = {-1, -1}, ctl_p[2] = {-1, -1};
    if (make_pipe_cloexec(in_p) != 0 || make_pipe_cloexec(out_p) != 0 ||
        make_pipe_cloexec(err_p) != 0 || make_pipe_cloexec(ctl_p) != 0) {
        set_errno_err(err_buf, err_cap, "pipe failed", errno);
        if (in_p[0] >= 0) { close(in_p[0]); close(in_p[1]); }
        if (out_p[0] >= 0) { close(out_p[0]); close(out_p[1]); }
        if (err_p[0] >= 0) { close(err_p[0]); close(err_p[1]); }
        if (ctl_p[0] >= 0) { close(ctl_p[0]); close(ctl_p[1]); }
        free(exec_path);
        free_str_vec(c_envp);
        free_str_vec(c_argv);
        return NULL;
    }

    const char *child_cwd = (cwd && cwd[0] != '\0') ? cwd : NULL;

    pid_t pid = fork();
    if (pid < 0) {
        set_errno_err(err_buf, err_cap, "fork failed", errno);
        close(in_p[0]); close(in_p[1]);
        close(out_p[0]); close(out_p[1]);
        close(err_p[0]); close(err_p[1]);
        close(ctl_p[0]); close(ctl_p[1]);
        free(exec_path);
        free_str_vec(c_envp);
        free_str_vec(c_argv);
        return NULL;
    }

    if (pid == 0) {
        /* Child: strictly async-signal-safe calls only */
        (void)setpgid(0, 0);
        (void)signal(SIGPIPE, SIG_DFL);
        close(in_p[1]);
        close(out_p[0]);
        close(err_p[0]);
        close(ctl_p[0]);

        if (dup2(in_p[0], STDIN_FILENO) < 0 ||
            dup2(out_p[1], STDOUT_FILENO) < 0 ||
            dup2(err_p[1], STDERR_FILENO) < 0) {
            int e = errno;
            (void)write(ctl_p[1], &e, sizeof(e));
            _exit(127);
        }
        if (in_p[0] > 2) close(in_p[0]);
        if (out_p[1] > 2) close(out_p[1]);
        if (err_p[1] > 2) close(err_p[1]);

        if (child_cwd && chdir(child_cwd) != 0) {
            int e = errno;
            (void)write(ctl_p[1], &e, sizeof(e));
            _exit(127);
        }

        execve(exec_path, c_argv, c_envp);
        int e = errno;
        (void)write(ctl_p[1], &e, sizeof(e));
        _exit(127);
    }

    /* Parent */
    (void)setpgid(pid, pid);
    close(in_p[0]);
    close(out_p[1]);
    close(err_p[1]);
    close(ctl_p[1]);

    free(exec_path);
    free_str_vec(c_envp);
    free_str_vec(c_argv);

    int child_err = 0;
    ssize_t got = 0;
    while (got < (ssize_t)sizeof(child_err)) {
        ssize_t r = read(ctl_p[0], ((char *)&child_err) + got, sizeof(child_err) - (size_t)got);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (r == 0) break;
        got += r;
    }
    close(ctl_p[0]);

    if (got == (ssize_t)sizeof(child_err)) {
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        close(in_p[1]);
        close(out_p[0]);
        close(err_p[0]);
        set_errno_err(err_buf, err_cap, "spawn failed", child_err);
        return NULL;
    }

    PionProc *p = (PionProc *)calloc(1, sizeof(PionProc));
    if (!p) {
        (void)kill(-pid, SIGKILL);
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        close(in_p[1]);
        close(out_p[0]);
        close(err_p[0]);
        set_err(err_buf, err_cap, "out of memory");
        return NULL;
    }
    pthread_mutex_init(&p->mu, NULL);
    p->refcnt = 1;
    p->pid = pid;
    p->pgid = pid;
    p->is_pty = 0;
    p->stdin_fd = in_p[1];
    p->stdout_fd = out_p[0];
    p->stderr_fd = err_p[0];
    p->pty_fd = -1;

    void *handle = slot_register(p);
    if (!handle) {
        (void)kill(-pid, SIGKILL);
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        close(in_p[1]);
        close(out_p[0]);
        close(err_p[0]);
        pthread_mutex_destroy(&p->mu);
        free(p);
        set_err(err_buf, err_cap, "too many active child processes");
        return NULL;
    }
    return handle;
}

void *pion_proc_pty_spawn(
    const char *const *argv, int32_t argc,
    int32_t cols, int32_t rows,
    const char *cwd,
    const char *const *env_set_keys, const char *const *env_set_vals, int32_t env_set_count,
    const char *const *env_unset_keys, int32_t env_unset_count,
    int32_t clear_env,
    char *err_buf, int32_t err_cap) {

    pthread_once(&g_sigpipe_once, pion_proc_ignore_sigpipe);
    if (!argv || argc <= 0) {
        set_err(err_buf, err_cap, "argv must not be empty");
        return NULL;
    }
    if (cols <= 0 || rows <= 0 || cols > 65535 || rows > 65535) {
        set_err(err_buf, err_cap, "pty cols and rows must be > 0");
        return NULL;
    }

    char **c_argv = dup_argv(argv, argc, err_buf, err_cap);
    if (!c_argv) return NULL;

    char **c_envp = build_envp(env_set_keys, env_set_vals, env_set_count,
                               env_unset_keys, env_unset_count, clear_env,
                               err_buf, err_cap);
    if (!c_envp) {
        free_str_vec(c_argv);
        return NULL;
    }

    char *exec_path = resolve_exec_path(c_argv[0], c_envp, clear_env, err_buf, err_cap);
    if (!exec_path) {
        free_str_vec(c_envp);
        free_str_vec(c_argv);
        return NULL;
    }

    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) {
        set_errno_err(err_buf, err_cap, "posix_openpt failed", errno);
        free(exec_path);
        free_str_vec(c_envp);
        free_str_vec(c_argv);
        return NULL;
    }
    if (set_cloexec(master) != 0 || grantpt(master) != 0 || unlockpt(master) != 0) {
        set_errno_err(err_buf, err_cap, "pty setup failed", errno);
        close(master);
        free(exec_path);
        free_str_vec(c_envp);
        free_str_vec(c_argv);
        return NULL;
    }

    char slave_path[256];
#ifdef __linux__
    if (ptsname_r(master, slave_path, sizeof(slave_path)) != 0) {
        set_errno_err(err_buf, err_cap, "ptsname_r failed", errno);
        close(master);
        free(exec_path);
        free_str_vec(c_envp);
        free_str_vec(c_argv);
        return NULL;
    }
#else
    pthread_mutex_lock(&g_ptsname_mu);
    const char *pts = ptsname(master);
    if (!pts) {
        int e = errno;
        pthread_mutex_unlock(&g_ptsname_mu);
        set_errno_err(err_buf, err_cap, "ptsname failed", e);
        close(master);
        free(exec_path);
        free_str_vec(c_envp);
        free_str_vec(c_argv);
        return NULL;
    }
    snprintf(slave_path, sizeof(slave_path), "%s", pts);
    pthread_mutex_unlock(&g_ptsname_mu);
#endif

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short)cols;
    ws.ws_row = (unsigned short)rows;
    (void)ioctl(master, TIOCSWINSZ, &ws);

    int ctl_p[2] = {-1, -1};
    if (make_pipe_cloexec(ctl_p) != 0) {
        set_errno_err(err_buf, err_cap, "pipe failed", errno);
        close(master);
        free(exec_path);
        free_str_vec(c_envp);
        free_str_vec(c_argv);
        return NULL;
    }

    const char *child_cwd = (cwd && cwd[0] != '\0') ? cwd : NULL;

    pid_t pid = fork();
    if (pid < 0) {
        set_errno_err(err_buf, err_cap, "fork failed", errno);
        close(ctl_p[0]); close(ctl_p[1]);
        close(master);
        free(exec_path);
        free_str_vec(c_envp);
        free_str_vec(c_argv);
        return NULL;
    }

    if (pid == 0) {
        /* Child: strictly async-signal-safe calls only */
        (void)signal(SIGPIPE, SIG_DFL);
        close(ctl_p[0]);
        close(master);

        if (setsid() < 0) {
            int e = errno;
            (void)write(ctl_p[1], &e, sizeof(e));
            _exit(127);
        }
        int slave = open(slave_path, O_RDWR);
        if (slave < 0) {
            int e = errno;
            (void)write(ctl_p[1], &e, sizeof(e));
            _exit(127);
        }
        (void)ioctl(slave, TIOCSCTTY, 0);
        (void)ioctl(slave, TIOCSWINSZ, &ws);
        if (dup2(slave, STDIN_FILENO) < 0 ||
            dup2(slave, STDOUT_FILENO) < 0 ||
            dup2(slave, STDERR_FILENO) < 0) {
            int e = errno;
            (void)write(ctl_p[1], &e, sizeof(e));
            _exit(127);
        }
        if (slave > 2) close(slave);

        if (child_cwd && chdir(child_cwd) != 0) {
            int e = errno;
            (void)write(ctl_p[1], &e, sizeof(e));
            _exit(127);
        }

        execve(exec_path, c_argv, c_envp);
        int e = errno;
        (void)write(ctl_p[1], &e, sizeof(e));
        _exit(127);
    }

    /* Parent */
    close(ctl_p[1]);
    free(exec_path);
    free_str_vec(c_envp);
    free_str_vec(c_argv);

    int child_err = 0;
    ssize_t got = 0;
    while (got < (ssize_t)sizeof(child_err)) {
        ssize_t r = read(ctl_p[0], ((char *)&child_err) + got, sizeof(child_err) - (size_t)got);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (r == 0) break;
        got += r;
    }
    close(ctl_p[0]);

    if (got == (ssize_t)sizeof(child_err)) {
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        close(master);
        set_errno_err(err_buf, err_cap, "pty_spawn failed", child_err);
        return NULL;
    }

    PionProc *p = (PionProc *)calloc(1, sizeof(PionProc));
    if (!p) {
        (void)kill(-pid, SIGKILL);
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        close(master);
        set_err(err_buf, err_cap, "out of memory");
        return NULL;
    }
    pthread_mutex_init(&p->mu, NULL);
    p->refcnt = 1;
    p->pid = pid;
    p->pgid = pid;
    p->is_pty = 1;
    p->stdin_fd = -1;
    p->stdout_fd = -1;
    p->stderr_fd = -1;
    p->pty_fd = master;

    void *handle = slot_register(p);
    if (!handle) {
        (void)kill(-pid, SIGKILL);
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        close(master);
        pthread_mutex_destroy(&p->mu);
        free(p);
        set_err(err_buf, err_cap, "too many active child processes");
        return NULL;
    }
    return handle;
}

int32_t pion_proc_pid(void *h) {
    PionProc *p = slot_acquire(h);
    if (!p) return -1;
    int32_t pid = (int32_t)p->pid;
    proc_release(p);
    return pid;
}

int32_t pion_proc_read(void *h, int32_t stream, uint8_t *buf, int32_t max_bytes,
                       int32_t timeout_ms, char *err_buf, int32_t err_cap) {
    if (!buf || max_bytes <= 0) {
        set_err(err_buf, err_cap, "max_bytes must be > 0");
        return -2;
    }
    PionProc *p = slot_acquire(h);
    if (!p) {
        set_err(err_buf, err_cap, "process handle is closed");
        return -2;
    }

    pthread_mutex_lock(&p->mu);
    int fd = -1;
    int is_pty = p->is_pty;
    if (is_pty) {
        fd = p->pty_fd;
    } else if (stream == 0) {
        fd = p->stdout_fd;
    } else if (stream == 1) {
        fd = p->stderr_fd;
    }
    pthread_mutex_unlock(&p->mu);

    if (fd < 0) {
        proc_release(p);
        return 0; /* EOF on closed stream */
    }

    int64_t deadline = timeout_ms > 0 ? (monotonic_ms() + (int64_t)timeout_ms) : 0;

    while (1) {
        if (timeout_ms >= 0) {
            int rem = 0;
            if (timeout_ms > 0) {
                int64_t left = deadline - monotonic_ms();
                if (left <= 0) {
                    proc_release(p);
                    return -1; /* Timeout */
                }
                rem = left > (int64_t)INT_MAX ? INT_MAX : (int)left;
            }
            struct pollfd pfd;
            pfd.fd = fd;
            pfd.events = POLLIN;
            pfd.revents = 0;
            int pr = poll(&pfd, 1, rem);
            if (pr < 0) {
                if (errno == EINTR) continue;
                set_errno_err(err_buf, err_cap, "poll failed", errno);
                proc_release(p);
                return -2;
            }
            if (pr == 0) {
                proc_release(p);
                return -1; /* Timeout */
            }
            if (!(pfd.revents & POLLIN) && (pfd.revents & (POLLHUP | POLLERR | POLLNVAL))) {
                proc_release(p);
                return 0; /* EOF */
            }
        }

        ssize_t n = read(fd, buf, (size_t)max_bytes);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (is_pty && errno == EIO) {
                proc_release(p);
                return 0; /* Linux PTY slave closed -> clean EOF */
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (timeout_ms == 0) {
                    proc_release(p);
                    return -1;
                }
                continue;
            }
            set_errno_err(err_buf, err_cap, "read failed", errno);
            proc_release(p);
            return -2;
        }
        proc_release(p);
        return (int32_t)n;
    }
}

int32_t pion_proc_write(void *h, const uint8_t *buf, int32_t len,
                        char *err_buf, int32_t err_cap) {
    pthread_once(&g_sigpipe_once, pion_proc_ignore_sigpipe);
    if (len < 0) {
        set_err(err_buf, err_cap, "negative write length");
        return -1;
    }
    if (len == 0) return 0;
    if (!buf) {
        set_err(err_buf, err_cap, "null write buffer");
        return -1;
    }

    PionProc *p = slot_acquire(h);
    if (!p) {
        set_err(err_buf, err_cap, "process handle is closed");
        return -1;
    }

    pthread_mutex_lock(&p->mu);
    int fd = p->is_pty ? p->pty_fd : p->stdin_fd;
    pthread_mutex_unlock(&p->mu);

    if (fd < 0) {
        set_err(err_buf, err_cap, "stdin is closed");
        proc_release(p);
        return -1;
    }

    while (1) {
        ssize_t n = write(fd, buf, (size_t)len);
        if (n < 0) {
            if (errno == EINTR) continue;
            set_errno_err(err_buf, err_cap, "write failed", errno);
            proc_release(p);
            return -1;
        }
        proc_release(p);
        return (int32_t)n;
    }
}

void pion_proc_close_stdin(void *h) {
    PionProc *p = slot_acquire(h);
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    int fd = p->stdin_fd;
    p->stdin_fd = -1;
    pthread_mutex_unlock(&p->mu);
    if (fd >= 0) close(fd);
    proc_release(p);
}

int32_t pion_proc_pty_resize(void *h, int32_t cols, int32_t rows,
                             char *err_buf, int32_t err_cap) {
    if (cols <= 0 || rows <= 0 || cols > 65535 || rows > 65535) {
        set_err(err_buf, err_cap, "pty cols and rows must be > 0");
        return -1;
    }
    PionProc *p = slot_acquire(h);
    if (!p) {
        set_err(err_buf, err_cap, "pty handle is closed");
        return -1;
    }
    pthread_mutex_lock(&p->mu);
    int fd = p->is_pty ? p->pty_fd : -1;
    pthread_mutex_unlock(&p->mu);
    if (fd < 0) {
        set_err(err_buf, err_cap, "pty is closed");
        proc_release(p);
        return -1;
    }
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short)cols;
    ws.ws_row = (unsigned short)rows;
    if (ioctl(fd, TIOCSWINSZ, &ws) != 0) {
        set_errno_err(err_buf, err_cap, "TIOCSWINSZ failed", errno);
        proc_release(p);
        return -1;
    }
    proc_release(p);
    return 0;
}

int32_t pion_proc_wait(void *h, int32_t block, int32_t *out_kind, int32_t *out_code,
                       char *err_buf, int32_t err_cap) {
    PionProc *p = slot_acquire(h);
    if (!p) {
        set_err(err_buf, err_cap, "process handle is closed");
        return -1;
    }

    pthread_mutex_lock(&p->mu);
    if (p->reaped) {
        if (out_kind) *out_kind = p->exit_kind;
        if (out_code) *out_code = p->exit_code;
        pthread_mutex_unlock(&p->mu);
        proc_release(p);
        return 1;
    }
    pid_t pid = p->pid;
    pthread_mutex_unlock(&p->mu);

    int status = 0;
    pid_t r;
    do {
        r = waitpid(pid, &status, block ? 0 : WNOHANG);
    } while (r < 0 && errno == EINTR);

    if (r == 0) {
        proc_release(p);
        return 0; /* still running */
    }
    if (r < 0) {
        /* Could have been reaped concurrently by another thread */
        pthread_mutex_lock(&p->mu);
        if (p->reaped) {
            if (out_kind) *out_kind = p->exit_kind;
            if (out_code) *out_code = p->exit_code;
            pthread_mutex_unlock(&p->mu);
            proc_release(p);
            return 1;
        }
        pthread_mutex_unlock(&p->mu);
        set_errno_err(err_buf, err_cap, "waitpid failed", errno);
        proc_release(p);
        return -1;
    }

    pthread_mutex_lock(&p->mu);
    if (!p->reaped) {
        record_wait_status(p, status);
    }
    if (out_kind) *out_kind = p->exit_kind;
    if (out_code) *out_code = p->exit_code;
    pthread_mutex_unlock(&p->mu);
    proc_release(p);
    return 1;
}

int32_t pion_proc_signal_tree(void *h, int32_t force, char *err_buf, int32_t err_cap) {
    PionProc *p = slot_acquire(h);
    if (!p) {
        return 0; /* already closed */
    }
    pthread_mutex_lock(&p->mu);
    int reaped = p->reaped;
    pid_t pgid = p->pgid;
    pthread_mutex_unlock(&p->mu);

    if (reaped || pgid <= 0) {
        proc_release(p);
        return 0;
    }
    int sig = force ? SIGKILL : SIGTERM;
    if (kill(-pgid, sig) != 0) {
        if (errno != ESRCH) {
            set_errno_err(err_buf, err_cap, "kill process group failed", errno);
            proc_release(p);
            return -1;
        }
    }
    proc_release(p);
    return 0;
}

void pion_proc_close(void *h) {
    uintptr_t raw = (uintptr_t)h;
    if (raw == 0) return;
    uint32_t idx1 = (uint32_t)(raw & 0xFFFFu);
    uint32_t gen = (uint32_t)((uint64_t)raw >> 16);
    if (idx1 == 0 || idx1 > PION_PROC_MAX_SLOTS) return;
    uint32_t idx = idx1 - 1u;

    pthread_mutex_lock(&g_table_mu);
    PionProc *p = NULL;
    if (g_slots[idx].proc != NULL && g_slots[idx].gen == gen) {
        p = g_slots[idx].proc;
        g_slots[idx].proc = NULL;
        g_slots[idx].gen++;
        if (g_slots[idx].gen == 0) g_slots[idx].gen = 1;
    }
    pthread_mutex_unlock(&g_table_mu);
    if (!p) return; /* idempotent */

    pthread_mutex_lock(&p->mu);
    int in_fd = p->stdin_fd; p->stdin_fd = -1;
    int out_fd = p->stdout_fd; p->stdout_fd = -1;
    int err_fd = p->stderr_fd; p->stderr_fd = -1;
    int pty_fd = p->pty_fd; p->pty_fd = -1;
    int reaped = p->reaped;
    pid_t pid = p->pid;
    p->closed = 1;
    pthread_mutex_unlock(&p->mu);

    if (in_fd >= 0) close(in_fd);
    if (out_fd >= 0) close(out_fd);
    if (err_fd >= 0) close(err_fd);
    if (pty_fd >= 0) close(pty_fd);

    if (!reaped && pid > 0) {
        int st = 0;
        pid_t r = waitpid(pid, &st, WNOHANG);
        if (r == pid) {
            pthread_mutex_lock(&p->mu);
            if (!p->reaped) record_wait_status(p, st);
            pthread_mutex_unlock(&p->mu);
        }
    }

    proc_release(p);
}

int32_t pion_proc_is_windows(void) {
    return 0;
}
