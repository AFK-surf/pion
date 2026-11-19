/*
 * High-precision macOS/POSIX benchmark measurement runner (zero Python).
 *
 * Modes:
 *   bench_measure exec <warmup> <runs> -- <cmd> [args...]
 *     Runs <warmup> unmeasured iterations, then <runs> measured iterations
 *     via `/usr/bin/time -l`, capturing CLOCK_MONOTONIC wall ms, Peak RSS (bytes -> MB),
 *     instructions retired, and stdout checksum. Verifies stdout is identical across runs.
 *     Outputs one tab-separated line:
 *       <median_ms>\t<min_ms>\t<max_ms>\t<peak_rss_mb>\t<instructions_retired>\t<stdout_trimmed>
 *
 *   bench_measure once -- <cmd> [args...]
 *     Runs <cmd> once with CLOCK_MONOTONIC and prints:
 *       <wall_ms>
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    double wall_ms;
    long long max_rss_bytes;
    long long instructions_retired;
    char stdout_buf[1024];
} RunResult;

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static void trim_trailing(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ' || s[n - 1] == '\t')) {
        s[--n] = '\0';
    }
}

static int run_one(char **cmd_argv, int cmd_argc, int use_time_l, RunResult *res) {
    memset(res, 0, sizeof(*res));

    int out_pipe[2], err_pipe[2];
    if (pipe(out_pipe) != 0 || pipe(err_pipe) != 0) {
        perror("pipe");
        return -1;
    }

    double t0 = now_ms();
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return -1;
    }
    if (pid == 0) {
        dup2(out_pipe[1], STDOUT_FILENO);
        dup2(err_pipe[1], STDERR_FILENO);
        close(out_pipe[0]);
        close(out_pipe[1]);
        close(err_pipe[0]);
        close(err_pipe[1]);

        if (use_time_l) {
            char **argv2 = (char **)malloc((size_t)(cmd_argc + 3) * sizeof(char *));
            argv2[0] = "/usr/bin/time";
            argv2[1] = "-l";
            for (int i = 0; i < cmd_argc; i++) argv2[i + 2] = cmd_argv[i];
            argv2[cmd_argc + 2] = NULL;
            execv("/usr/bin/time", argv2);
            perror("execv /usr/bin/time");
            _exit(127);
        } else {
            execvp(cmd_argv[0], cmd_argv);
            perror("execvp");
            _exit(127);
        }
    }

    close(out_pipe[1]);
    close(err_pipe[1]);

    /* Read stdout */
    size_t out_len = 0;
    ssize_t r;
    while ((r = read(out_pipe[0], res->stdout_buf + out_len,
                     sizeof(res->stdout_buf) - 1 - out_len)) > 0) {
        out_len += (size_t)r;
        if (out_len >= sizeof(res->stdout_buf) - 1) break;
    }
    /* Drain remaining stdout if any */
    char drain[256];
    while (read(out_pipe[0], drain, sizeof(drain)) > 0) {}
    close(out_pipe[0]);
    res->stdout_buf[out_len] = '\0';
    trim_trailing(res->stdout_buf);

    /* Read stderr (contains /usr/bin/time -l output) */
    char err_buf[8192];
    size_t err_len = 0;
    while ((r = read(err_pipe[0], err_buf + err_len,
                     sizeof(err_buf) - 1 - err_len)) > 0) {
        err_len += (size_t)r;
        if (err_len >= sizeof(err_buf) - 1) break;
    }
    while (read(err_pipe[0], drain, sizeof(drain)) > 0) {}
    close(err_pipe[0]);
    err_buf[err_len] = '\0';

    int status = 0;
    waitpid(pid, &status, 0);
    double t1 = now_ms();
    res->wall_ms = t1 - t0;

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "command failed (status=%d): %s\nstderr:\n%s\n", status, cmd_argv[0], err_buf);
        return -1;
    }

    if (use_time_l) {
        char *line = err_buf;
        while (*line) {
            char *nl = strchr(line, '\n');
            if (nl) *nl = '\0';
            if (strstr(line, "maximum resident set size")) {
                res->max_rss_bytes = strtoll(line, NULL, 10);
            } else if (strstr(line, "instructions retired")) {
                res->instructions_retired = strtoll(line, NULL, 10);
            }
            if (!nl) break;
            line = nl + 1;
        }
    }

    return 0;
}

static int cmp_double(const void *a, const void *b) {
    double da = *(const double *)a;
    double db = *(const double *)b;
    return (da > db) - (da < db);
}

static int cmp_ll(const void *a, const void *b) {
    long long la = *(const long long *)a;
    long long lb = *(const long long *)b;
    return (la > lb) - (la < lb);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s exec <warmup> <runs> -- <cmd> [args...]\n"
                        "       %s once -- <cmd> [args...]\n", argv[0], argv[0]);
        return 2;
    }

    if (strcmp(argv[1], "once") == 0) {
        if (strcmp(argv[2], "--") != 0 || argc < 4) return 2;
        RunResult r;
        if (run_one(&argv[3], argc - 3, 0, &r) != 0) return 1;
        printf("%.2f\n", r.wall_ms);
        return 0;
    }

    if (strcmp(argv[1], "exec") == 0) {
        if (argc < 6 || strcmp(argv[4], "--") != 0) return 2;
        int warmup = atoi(argv[2]);
        int runs = atoi(argv[3]);
        if (runs < 1 || runs > 64) return 2;
        char **cmd = &argv[5];
        int cmd_argc = argc - 5;

        RunResult r;
        for (int i = 0; i < warmup; i++) {
            if (run_one(cmd, cmd_argc, 0, &r) != 0) return 1;
        }

        double times[64];
        long long rss[64];
        long long instrs[64];
        char first_out[1024];
        first_out[0] = '\0';

        for (int i = 0; i < runs; i++) {
            if (run_one(cmd, cmd_argc, 1, &r) != 0) return 1;
            if (i == 0) {
                snprintf(first_out, sizeof(first_out), "%s", r.stdout_buf);
            } else if (strcmp(first_out, r.stdout_buf) != 0) {
                fprintf(stderr, "non-deterministic stdout: '%s' vs '%s'\n", first_out, r.stdout_buf);
                return 1;
            }
            times[i] = r.wall_ms;
            rss[i] = r.max_rss_bytes;
            instrs[i] = r.instructions_retired;
        }

        qsort(times, (size_t)runs, sizeof(double), cmp_double);
        qsort(rss, (size_t)runs, sizeof(long long), cmp_ll);
        qsort(instrs, (size_t)runs, sizeof(long long), cmp_ll);

        int mid = runs / 2;
        double med_ms = times[mid];
        double min_ms = times[0];
        double max_ms = times[runs - 1];
        double rss_mb = (double)rss[mid] / (1024.0 * 1024.0);
        long long med_instr = instrs[mid];

        printf("%.2f\t%.2f\t%.2f\t%.2f\t%lld\t%s\n",
               med_ms, min_ms, max_ms, rss_mb, med_instr, first_out);
        return 0;
    }

    return 2;
}
