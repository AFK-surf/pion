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
