#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
#endif

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/syscall.h>
#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE (1 << 1)
#endif
#endif

/* Atomically swap two existing directories with zero ENOENT window.
 * Returns 0 on success, -1 on failure (leaving both paths untouched).
 */
int mbt_atomic_swap_dir(const char *a, const char *b) {
    if (!a || !b) {
        errno = EINVAL;
        return -1;
    }
#ifdef __APPLE__
    return renamex_np(a, b, RENAME_SWAP);
#elif defined(__linux__)
#if defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 28))
    return renameat2(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE);
#elif defined(SYS_renameat2)
    return (int)syscall(SYS_renameat2, AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE);
#else
    errno = ENOSYS;
    return -1;
#endif
#else
    errno = ENOSYS;
    return -1;
#endif
}

/* Return st_mode & 07777 via lstat (does not follow symlinks), or -1 on error. */
int mbt_fs_lstat_mode(const char *path) {
    if (!path) {
        errno = EINVAL;
        return -1;
    }
    struct stat st;
    if (lstat(path, &st) != 0) {
        return -1;
    }
    return (int)(st.st_mode & 07777);
}

/* Create a hard link without requiring read permission on oldpath.
 * Returns 0 on success, -1 on error.
 */
int mbt_fs_hardlink(const char *oldpath, const char *newpath) {
    if (!oldpath || !newpath) {
        errno = EINVAL;
        return -1;
    }
    return link(oldpath, newpath);
}

/* Check whether a directory can be opened for reading.
 * Returns 1 if readable, 0 otherwise.
 */
int mbt_fs_dir_readable(const char *path) {
    if (!path) {
        return 0;
    }
    DIR *d = opendir(path);
    if (!d) {
        return 0;
    }
    closedir(d);
    return 1;
}

/* Resolve canonical path via POSIX realpath (normalizing /tmp -> /private/tmp, etc.).
 * Writes NUL-terminated result into out[0..cap-1] and returns length >= 0, or -1 on error.
 */
int mbt_fs_realpath(const char *path, char *out, int cap) {
    if (!path || !out || cap <= 1) {
        errno = EINVAL;
        return -1;
    }
    char buf[PATH_MAX];
    if (!realpath(path, buf)) {
        return -1;
    }
    size_t len = strlen(buf);
    if (len >= (size_t)cap) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(out, buf, len + 1);
    return (int)len;
}

/* Return 1 if paths `a` and `b` resolve via stat() to the exact same (st_dev, st_ino), 0 otherwise. */
int mbt_fs_same_inode(const char *a, const char *b) {
    if (!a || !b) {
        return 0;
    }
    struct stat sa, sb;
    if (stat(a, &sa) != 0 || stat(b, &sb) != 0) {
        return 0;
    }
    return (sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino) ? 1 : 0;
}

/* Return 1 if paths `a` and `b` reside on the same filesystem device (st_dev), 0 otherwise. */
int mbt_fs_same_dev(const char *a, const char *b) {
    if (!a || !b) {
        return 0;
    }
    struct stat sa, sb;
    if (stat(a, &sa) != 0 || stat(b, &sb) != 0) {
        return 0;
    }
    return (sa.st_dev == sb.st_dev) ? 1 : 0;
}

/* Return 1 if directory `path` is writable and searchable by the current user, 0 otherwise. */
int mbt_fs_dir_writable(const char *path) {
    if (!path || !*path) {
        return 0;
    }
    return (access(path, W_OK | X_OK) == 0) ? 1 : 0;
}

/* Kernel-truth check whether two filenames (`name_a`, `name_b`, basenames only) collide on the
 * filesystem volume backing `dir` (covers ASCII case-folding, Unicode État/état, APFS NFC/NFD, etc.).
 * Returns 1 if colliding, 0 if distinct, -1 on error (e.g. unwritable dir). Always cleans up.
 */
int mbt_fs_names_collide_in_dir(const char *dir, const char *name_a, const char *name_b) {
    if (!dir || !name_a || !name_b || !*dir || !*name_a || !*name_b) {
        errno = EINVAL;
        return -1;
    }
    if (strchr(name_a, '/') || strchr(name_b, '/') ||
        strcmp(name_a, ".") == 0 || strcmp(name_a, "..") == 0 ||
        strcmp(name_b, ".") == 0 || strcmp(name_b, "..") == 0) {
        errno = EINVAL;
        return -1;
    }
    if (strcmp(name_a, name_b) == 0) {
        return 1;
    }
    char probe_dir[PATH_MAX];
    int created = 0;
    long pid = (long)getpid();
    for (int seq = 0; seq < 64; seq++) {
        int n = snprintf(probe_dir, sizeof(probe_dir), "%s/.m2pvp.%ld.%d", dir, pid, seq);
        if (n < 0 || (size_t)n >= sizeof(probe_dir)) {
            errno = ENAMETOOLONG;
            return -1;
        }
        if (mkdir(probe_dir, 0700) == 0) {
            created = 1;
            break;
        }
        if (errno != EEXIST) {
            return -1;
        }
    }
    if (!created) {
        errno = EEXIST;
        return -1;
    }
    char path_a[PATH_MAX];
    char path_b[PATH_MAX];
    int na = snprintf(path_a, sizeof(path_a), "%s/%s", probe_dir, name_a);
    int nb = snprintf(path_b, sizeof(path_b), "%s/%s", probe_dir, name_b);
    if (na < 0 || (size_t)na >= sizeof(path_a) || nb < 0 || (size_t)nb >= sizeof(path_b)) {
        rmdir(probe_dir);
        errno = ENAMETOOLONG;
        return -1;
    }
    int res = -1;
    int fda = open(path_a, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (fda >= 0) {
        close(fda);
        int fdb = open(path_b, O_CREAT | O_EXCL | O_WRONLY, 0600);
        if (fdb >= 0) {
            close(fdb);
            res = 0;
        } else if (errno == EEXIST) {
            res = 1;
        } else {
            res = -1;
        }
        unlink(path_b);
        unlink(path_a);
    }
    rmdir(probe_dir);
    return res;
}
