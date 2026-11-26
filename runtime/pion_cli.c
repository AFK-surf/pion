/* pion_cli.c — CLI-only native host helpers linked exclusively into `pionc`
 * (and runtime tests), never into `libpionrt.a` so user binaries pay 0 bytes. */

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include "pion_rt.h"
#include <windows.h>
#include <direct.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifndef WC_ERR_INVALID_CHARS
#define WC_ERR_INVALID_CHARS 0x80
#endif
#ifndef ERROR_CANT_RESOLVE_FILENAME
#define ERROR_CANT_RESOLVE_FILENAME 1921
#endif

static wchar_t *pion_cli_utf8_to_wide(const char *data, size_t len) {
    if (!data || len == 0 || len > (size_t)INT_MAX ||
        memchr(data, '\0', len) != NULL) {
        return NULL;
    }
    int wlen = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                   data, (int)len, NULL, 0);
    if (wlen <= 0) return NULL;
    wchar_t *wp = (wchar_t *)malloc(((size_t)wlen + 1) * sizeof(wchar_t));
    if (!wp) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                            data, (int)len, wp, wlen) != wlen) {
        free(wp);
        return NULL;
    }
    wp[wlen] = L'\0';
    return wp;
}

static wchar_t *pion_cli_final_path(HANDLE h, wchar_t **src_out, DWORD *slen_out) {
    DWORD cap = 260;
    wchar_t *wbuf = NULL;
    DWORD n = 0;
    for (;;) {
        wchar_t *nb = (wchar_t *)realloc(wbuf, (size_t)cap * sizeof(wchar_t));
        if (!nb) { free(wbuf); return NULL; }
        wbuf = nb;
        n = GetFinalPathNameByHandleW(h, wbuf, cap, FILE_NAME_NORMALIZED);
        if (n == 0) { free(wbuf); return NULL; }
        if (n < cap) break;
        if (n > (1u << 20)) { free(wbuf); return NULL; }
        cap = n + 1;
    }
    wchar_t *src = wbuf;
    DWORD slen = n;
    if (slen >= 8 && memcmp(src, L"\\\\?\\UNC\\", 8 * sizeof(wchar_t)) == 0) {
        src += 6;
        slen -= 6;
        src[0] = L'\\';
    } else if (slen >= 4 && memcmp(src, L"\\\\?\\", 4 * sizeof(wchar_t)) == 0) {
        src += 4;
        slen -= 4;
    }
    if (slen == 0 || slen > (DWORD)INT_MAX) { free(wbuf); return NULL; }
    *src_out = src;
    *slen_out = slen;
    return wbuf;
}

static char *pion_cli_wide_to_cstr(const wchar_t *src, DWORD slen) {
    if (slen == 0 || slen > (DWORD)INT_MAX) return NULL;
    int u8len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                    src, (int)slen, NULL, 0, NULL, NULL);
    if (u8len <= 0) return NULL;
    char *u8buf = (char *)malloc((size_t)u8len + 1);
    if (!u8buf) return NULL;
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                            src, (int)slen, u8buf, u8len, NULL, NULL) != u8len) {
        free(u8buf);
        return NULL;
    }
    u8buf[u8len] = '\0';
    return u8buf;
}

char *pion_fs_canon_path(const char *path) {
    if (!path || path[0] == '\0') return NULL;
    wchar_t *wp = pion_cli_utf8_to_wide(path, strlen(path));
    if (!wp) return NULL;
    DWORD fcap = GetFullPathNameW(wp, 0, NULL, NULL);
    if (fcap == 0 || fcap > (1u << 20)) { free(wp); return NULL; }
    wchar_t *full = (wchar_t *)malloc(((size_t)fcap + 1) * sizeof(wchar_t));
    if (!full) { free(wp); return NULL; }
    DWORD flen = GetFullPathNameW(wp, fcap, full, NULL);
    free(wp);
    if (flen == 0 || flen >= fcap) { free(full); return NULL; }
    full[flen] = L'\0';
    DWORD cut = flen;
    char *out = NULL;
    for (;;) {
        wchar_t saved = full[cut];
        full[cut] = L'\0';
        HANDLE h = CreateFileW(full, 0,
                               FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                               NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
        if (h != INVALID_HANDLE_VALUE) {
            full[cut] = saved;
            wchar_t *src = NULL;
            DWORD slen = 0;
            wchar_t *wbuf = pion_cli_final_path(h, &src, &slen);
            CloseHandle(h);
            if (!wbuf) { free(full); return NULL; }
            DWORD tail_off = cut;
            while (tail_off < flen && full[tail_off] == L'\\') tail_off++;
            DWORD tail_len = flen - tail_off;
            if (tail_len == 0) {
                out = pion_cli_wide_to_cstr(src, slen);
            } else {
                int need_sep = (slen > 0 && src[slen - 1] != L'\\') ? 1 : 0;
                DWORD total = slen + (DWORD)need_sep + tail_len;
                wchar_t *comb = (wchar_t *)malloc((size_t)total * sizeof(wchar_t));
                if (comb) {
                    memcpy(comb, src, (size_t)slen * sizeof(wchar_t));
                    if (need_sep) comb[slen] = L'\\';
                    memcpy(comb + slen + need_sep, full + tail_off, (size_t)tail_len * sizeof(wchar_t));
                    out = pion_cli_wide_to_cstr(comb, total);
                    free(comb);
                }
            }
            free(wbuf);
            free(full);
            return out;
        }
        DWORD gle = GetLastError();
        DWORD attr = GetFileAttributesW(full);
        full[cut] = saved;
        if (gle == ERROR_CANT_RESOLVE_FILENAME) { free(full); return NULL; }
        /* Reject dangling reparse points (symlink/junction whose target does not exist). */
        if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_REPARSE_POINT)) {
            free(full);
            return NULL;
        }
        if (cut == 0 || (cut == 3 && full[1] == L':' && full[2] == L'\\')) break;
        DWORD prev = cut;
        while (prev > 0 && full[prev - 1] == L'\\') prev--;
        while (prev > 0 && full[prev - 1] != L'\\') prev--;
        if (prev == 0) break;
        if (prev == 3 && full[1] == L':' && full[2] == L'\\') {
            cut = 3;
        } else {
            cut = prev - 1;
            if (cut == 2 && full[1] == L':') cut = 3;
            else if (cut == 0) break;
        }
    }
    out = pion_cli_wide_to_cstr(full, flen);
    free(full);
    return out;
}

/* Exclusive single-directory create (no shell, no parents): 0 if this call
 * created `path`, -1 if it already exists or cannot be created. */
int32_t pion_fs_mkdir_excl(const char *path) {
    wchar_t *wp = path ? pion_cli_utf8_to_wide(path, strlen(path)) : NULL;
    int32_t rc = (wp && _wmkdir(wp) == 0) ? 0 : -1;
    free(wp);
    return rc;
}

/* Like pion_fs_mkdir_excl, but tells a taken name apart: 0 if this call
 * created `path`, 1 if something already exists there
 * (ERROR_ALREADY_EXISTS), -1 on any other failure (NULL / empty / invalid
 * UTF-8 path, missing parent, access denied, ...). */
int32_t pion_fs_mkdir_excl_status(const char *path) {
    if (!path || !*path) return -1;
    wchar_t *wp = pion_cli_utf8_to_wide(path, strlen(path));
    if (!wp) return -1;
    int32_t rc = 0;
    if (!CreateDirectoryW(wp, NULL)) {
        rc = GetLastError() == ERROR_ALREADY_EXISTS ? 1 : -1;
    }
    free(wp);
    return rc;
}

/* Single empty-directory remove (no shell): 0 on success, -1 on error. */
int32_t pion_fs_rmdir(const char *path) {
    wchar_t *wp = path ? pion_cli_utf8_to_wide(path, strlen(path)) : NULL;
    int32_t rc = (wp && _wrmdir(wp) == 0) ? 0 : -1;
    free(wp);
    return rc;
}

/* Non-blocking exclusive lock on `path` (created if missing, never removed):
 * a handle >= 0, or -1 when another process holds it. The kernel drops the
 * lock when the holder exits or is killed. */
int64_t pion_fs_trylock(const char *path) {
    wchar_t *wp = path ? pion_cli_utf8_to_wide(path, strlen(path)) : NULL;
    HANDLE h = wp ? CreateFileW(wp, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL)
                  : INVALID_HANDLE_VALUE;
    free(wp);
    if (h == INVALID_HANDLE_VALUE) return -1;
    OVERLAPPED ov;
    memset(&ov, 0, sizeof ov);
    if (!LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov)) {
        CloseHandle(h);
        return -1;
    }
    return (int64_t)(uintptr_t)h & INT64_MAX;
}

/* Blocking exclusive lock on `path` (created if missing, never removed):
 * waits until no other holder remains; a handle >= 0, or -1 on error.
 * Released with pion_fs_unlock. */
int64_t pion_fs_lock(const char *path) {
    wchar_t *wp = path ? pion_cli_utf8_to_wide(path, strlen(path)) : NULL;
    HANDLE h = wp ? CreateFileW(wp, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL)
                  : INVALID_HANDLE_VALUE;
    free(wp);
    if (h == INVALID_HANDLE_VALUE) return -1;
    OVERLAPPED ov;
    memset(&ov, 0, sizeof ov);
    if (!LockFileEx(h, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &ov)) {
        CloseHandle(h);
        return -1;
    }
    return (int64_t)(uintptr_t)h & INT64_MAX;
}

/* Releases a `pion_fs_trylock` / `pion_fs_lock` handle (the lock file stays). */
void pion_fs_unlock(int64_t handle) {
    if (handle < 0) return;
    HANDLE h = (HANDLE)(uintptr_t)handle;
    OVERLAPPED ov;
    memset(&ov, 0, sizeof ov);
    UnlockFileEx(h, 0, 1, 0, &ov);
    CloseHandle(h);
}

/* This process's id (unique among live processes; `pionc` temp-file names). */
int64_t pion_cli_getpid(void) {
    return (int64_t)GetCurrentProcessId();
}

int64_t pion_cli_getppid(void) {
    return 0;
}

/* Process-wide monotonically increasing sequence (0, 1, 2, ...), safe across
 * threads: every call returns a value no other call in this process got. */
int64_t pion_cli_next_seq(void) {
    static volatile LONG64 s_seq = 0;
    return (int64_t)(InterlockedIncrement64(&s_seq) - 1);
}

/* 1 on a Windows host build of pionc (host path rules), else 0. */
int32_t pion_cli_is_windows(void) {
    return 1;
}

int32_t pion_cli_cpu_count(void) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    DWORD n = si.dwNumberOfProcessors;
    if (n < 1) return 1;
    if (n > 1024) return 1024;
    return (int32_t)n;
}

int32_t pion_cli_pid_alive(int64_t pid) {
    if (pid <= 0 || pid > (int64_t)UINT32_MAX) return 0;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
    if (!h) {
        return GetLastError() == ERROR_INVALID_PARAMETER ? 0 : 1;
    }
    DWORD code = 0;
    BOOL ok = GetExitCodeProcess(h, &code);
    CloseHandle(h);
    if (!ok) return 1; /* conservative: query failure never means dead */
    return code == STILL_ACTIVE ? 1 : 0;
}

static DWORD WINAPI pion_cli_win_parent_watch_thread(LPVOID arg) {
    HANDLE h = (HANDLE)arg;
    WaitForSingleObject(h, INFINITE);
    CloseHandle(h);
    TerminateProcess(GetCurrentProcess(), 1);
    return 0;
}

int32_t pion_cli_watch_parent(int64_t expected_ppid) {
    if (expected_ppid <= 0 || expected_ppid > (int64_t)UINT32_MAX) return -1;
    HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)expected_ppid);
    if (!h) {
        if (GetLastError() == ERROR_INVALID_PARAMETER) {
            TerminateProcess(GetCurrentProcess(), 1);
        }
        return -1;
    }
    HANDLE th = CreateThread(NULL, 0, pion_cli_win_parent_watch_thread, (LPVOID)h, 0, NULL);
    if (!th) {
        CloseHandle(h);
        return -1;
    }
    CloseHandle(th);
    return 0;
}

static wchar_t *pion_cli_win_self_exe_wide(DWORD *len_out) {
    DWORD cap = 260;
    wchar_t *wbuf = NULL;
    for (;;) {
        wchar_t *nb = (wchar_t *)realloc(wbuf, (size_t)cap * sizeof(wchar_t));
        if (!nb) { free(wbuf); return NULL; }
        wbuf = nb;
        SetLastError(0);
        DWORD n = GetModuleFileNameW(NULL, wbuf, cap);
        if (n == 0) { free(wbuf); return NULL; }
        if (n < cap && GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
            wbuf[n] = L'\0';
            if (len_out) *len_out = n;
            return wbuf;
        }
        if (cap >= (1u << 20)) { free(wbuf); return NULL; }
        cap *= 2;
    }
}

char *pion_cli_self_exe_path(void) {
    DWORD n = 0;
    wchar_t *wbuf = pion_cli_win_self_exe_wide(&n);
    if (!wbuf) return NULL;
    char *out = pion_cli_wide_to_cstr(wbuf, n);
    free(wbuf);
    return out;
}

static char *pion_cli_compute_image_id(void) {
    HMODULE mod = GetModuleHandleW(NULL);
    if (!mod) return NULL;
    const uint8_t *base = (const uint8_t *)mod;
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0) return NULL;
    const IMAGE_NT_HEADERS *nt = (const IMAGE_NT_HEADERS *)(base + (size_t)dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return NULL;
    uint32_t ts = (uint32_t)nt->FileHeader.TimeDateStamp;
    uint32_t sz = (uint32_t)nt->OptionalHeader.SizeOfImage;
    uint32_t cs = (uint32_t)nt->OptionalHeader.CheckSum;
    char buf[160];
    int pos = snprintf(buf, sizeof(buf), "pe-img:%08lx:%08lx:%08lx",
                       (unsigned long)ts, (unsigned long)sz, (unsigned long)cs);
    if (pos <= 0 || (size_t)pos >= sizeof(buf)) return NULL;
    int has_cv = 0;
    const IMAGE_DATA_DIRECTORY *dd =
        &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DEBUG];
    if (dd->VirtualAddress > 0 && dd->Size >= sizeof(IMAGE_DEBUG_DIRECTORY) &&
        dd->VirtualAddress < sz && dd->Size <= sz - dd->VirtualAddress) {
        size_t count = dd->Size / sizeof(IMAGE_DEBUG_DIRECTORY);
        const IMAGE_DEBUG_DIRECTORY *dirs =
            (const IMAGE_DEBUG_DIRECTORY *)(base + dd->VirtualAddress);
        static const char hex[] = "0123456789abcdef";
        for (size_t i = 0; i < count; i++) {
            if (dirs[i].Type == IMAGE_DEBUG_TYPE_CODEVIEW &&
                dirs[i].AddressOfRawData > 0 &&
                dirs[i].SizeOfData >= 24 &&
                dirs[i].AddressOfRawData < sz &&
                dirs[i].SizeOfData <= sz - dirs[i].AddressOfRawData) {
                const uint8_t *cv = base + dirs[i].AddressOfRawData;
                if (cv[0] == 'R' && cv[1] == 'S' && cv[2] == 'D' && cv[3] == 'S') {
                    uint32_t age = 0;
                    memcpy(&age, cv + 20, 4);
                    char ghex[33];
                    for (int b = 0; b < 16; b++) {
                        ghex[b * 2] = hex[(cv[4 + b] >> 4) & 15u];
                        ghex[b * 2 + 1] = hex[cv[4 + b] & 15u];
                    }
                    ghex[32] = '\0';
                    int extra = snprintf(buf + pos, sizeof(buf) - (size_t)pos,
                                         ":cv:%s-%08lx", ghex, (unsigned long)age);
                    if (extra > 0 && (size_t)(pos + extra) < sizeof(buf)) {
                        pos += extra;
                        has_cv = 1;
                    }
                    break;
                }
            }
        }
    }
    if (!has_cv) {
        DWORD wlen = 0;
        wchar_t *wexe = pion_cli_win_self_exe_wide(&wlen);
        if (wexe) {
            WIN32_FILE_ATTRIBUTE_DATA fad;
            if (GetFileAttributesExW(wexe, GetFileExInfoStandard, &fad)) {
                unsigned long long fsz =
                    (((unsigned long long)fad.nFileSizeHigh) << 32) |
                    (unsigned long long)fad.nFileSizeLow;
                int extra = snprintf(buf + pos, sizeof(buf) - (size_t)pos,
                                     ":stat:%llx:%lx:%lx",
                                     fsz,
                                     (unsigned long)fad.ftLastWriteTime.dwHighDateTime,
                                     (unsigned long)fad.ftLastWriteTime.dwLowDateTime);
                if (extra > 0 && (size_t)(pos + extra) < sizeof(buf)) {
                    pos += extra;
                }
            }
            free(wexe);
        }
    }
    char *out = (char *)malloc((size_t)pos + 1);
    if (!out) return NULL;
    memcpy(out, buf, (size_t)pos + 1);
    return out;
}

char *pion_cli_self_image_id(void) {
    static volatile LONG s_state = 0; /* 0 = uninit, 1 = initing, 2 = ready */
    static char s_id[160];
    if (InterlockedCompareExchange(&s_state, 0, 0) != 2) {
        if (InterlockedCompareExchange(&s_state, 1, 0) == 0) {
            char *tmp = pion_cli_compute_image_id();
            if (tmp) {
                size_t n = strlen(tmp);
                if (n < sizeof(s_id)) memcpy(s_id, tmp, n + 1);
                free(tmp);
            }
            InterlockedExchange(&s_state, 2);
        } else {
            while (InterlockedCompareExchange(&s_state, 0, 0) != 2) {
                SwitchToThread();
            }
        }
    }
    if (s_id[0] == '\0') return NULL;
    size_t n = strlen(s_id);
    char *out = (char *)malloc(n + 1);
    if (out) memcpy(out, s_id, n + 1);
    return out;
}

/* Single-threaded async worker subprocess launcher & reaper (keeps parent
 * pionc in ST biased-RC mode without entering pion_enter_mt()). */
static HANDLE  g_ws_win_handles[64];
static int64_t g_ws_win_ids[64];
static int     g_ws_win_count = 0;
static int64_t g_ws_win_next_id = 1;
static int32_t g_ws_win_last_rc = -1;

static int pion_cli_win_append_quoted(wchar_t **buf, size_t *len, size_t *cap, const wchar_t *arg) {
    size_t alen = wcslen(arg);
    size_t need = *len + alen * 2 + 4;
    if (need > *cap) {
        size_t ncap = (*cap ? *cap * 2 : 256);
        while (ncap < need) ncap *= 2;
        wchar_t *nb = (wchar_t *)realloc(*buf, ncap * sizeof(wchar_t));
        if (!nb) return -1;
        *buf = nb;
        *cap = ncap;
    }
    if (*len > 0) (*buf)[(*len)++] = L' ';
    (*buf)[(*len)++] = L'"';
    size_t bs = 0;
    for (size_t i = 0; i < alen; i++) {
        wchar_t c = arg[i];
        if (c == L'\\') {
            bs++;
        } else if (c == L'"') {
            for (size_t k = 0; k < bs * 2 + 1; k++) (*buf)[(*len)++] = L'\\';
            (*buf)[(*len)++] = L'"';
            bs = 0;
        } else {
            for (size_t k = 0; k < bs; k++) (*buf)[(*len)++] = L'\\';
            bs = 0;
            (*buf)[(*len)++] = c;
        }
    }
    for (size_t k = 0; k < bs * 2; k++) (*buf)[(*len)++] = L'\\';
    (*buf)[(*len)++] = L'"';
    (*buf)[*len] = L'\0';
    return 0;
}

int64_t pion_cli_spawn_ws_worker(const char *exe, const char *spec_path,
                                 const char *res_path, const char *expected_fp,
                                 const char *parent_pid_str) {
    if (!exe || !spec_path || !res_path || !expected_fp || !parent_pid_str) return -1;
    if (g_ws_win_count >= 64) return -1;
    const char *args[10] = {
        exe, "--internal-ws-pkg-worker",
        "--spec", spec_path,
        "--result", res_path,
        "--expected-fp", expected_fp,
        "--parent-pid", parent_pid_str
    };
    wchar_t *wexe = pion_cli_utf8_to_wide(exe, strlen(exe));
    if (!wexe) return -1;
    wchar_t *cmd = NULL;
    size_t clen = 0, ccap = 0;
    for (int i = 0; i < 10; i++) {
        wchar_t *wa = pion_cli_utf8_to_wide(args[i], strlen(args[i]));
        if (!wa || pion_cli_win_append_quoted(&cmd, &clen, &ccap, wa) != 0) {
            free(wa);
            free(cmd);
            free(wexe);
            return -1;
        }
        free(wa);
    }
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));
    BOOL ok = CreateProcessW(wexe, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi);
    free(cmd);
    free(wexe);
    if (!ok) return -1;
    CloseHandle(pi.hThread);
    int64_t id = g_ws_win_next_id++;
    g_ws_win_handles[g_ws_win_count] = pi.hProcess;
    g_ws_win_ids[g_ws_win_count] = id;
    g_ws_win_count++;
    return id;
}

int64_t pion_cli_wait_any_ws_worker(void) {
    if (g_ws_win_count <= 0) return -1;
    DWORD r = WaitForMultipleObjects((DWORD)g_ws_win_count, g_ws_win_handles, FALSE, INFINITE);
    if (r >= WAIT_OBJECT_0 + (DWORD)g_ws_win_count) return -1;
    int idx = (int)(r - WAIT_OBJECT_0);
    HANDLE h = g_ws_win_handles[idx];
    int64_t id = g_ws_win_ids[idx];
    DWORD code = 1;
    if (!GetExitCodeProcess(h, &code)) code = 1;
    CloseHandle(h);
    g_ws_win_count--;
    g_ws_win_handles[idx] = g_ws_win_handles[g_ws_win_count];
    g_ws_win_ids[idx] = g_ws_win_ids[g_ws_win_count];
    g_ws_win_last_rc = (int32_t)code;
    return id;
}

int32_t pion_cli_last_ws_worker_rc(void) {
    return g_ws_win_last_rc;
}

int32_t pion_cli_can_reap_children(void) {
    return 1;
}

/* lstat kind without following links: 0 confirmed missing, 1 regular file,
 * 2 directory, 3 symlink / reparse point (junction), 4 other, -1 when the
 * query itself fails (access denied, I/O, invalid path) — never "missing". */
int32_t pion_fs_lstat_kind(const char *path) {
    wchar_t *wp = path ? pion_cli_utf8_to_wide(path, strlen(path)) : NULL;
    if (!wp) return -1;
    DWORD a = GetFileAttributesW(wp);
    DWORD err = a == INVALID_FILE_ATTRIBUTES ? GetLastError() : 0;
    free(wp);
    if (a == INVALID_FILE_ATTRIBUTES) {
        return (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) ? 0 : -1;
    }
    if (a & FILE_ATTRIBUTE_REPARSE_POINT) return 3;
    if (a & FILE_ATTRIBUTE_DIRECTORY) return 2;
    return 1;
}

int64_t pion_cli_path_change_ms(const char *path) {
    if (!path || !*path) return -1;
    wchar_t *wp = pion_cli_utf8_to_wide(path, strlen(path));
    if (!wp) return -1;
    struct _stat64 st;
    int rc = _wstat64(wp, &st);
    free(wp);
    if (rc != 0) return -1;
    int64_t m = (int64_t)st.st_mtime * 1000LL;
    int64_t c = (int64_t)st.st_ctime * 1000LL;
    return m >= c ? m : c;
}

int64_t pion_cli_lpath_change_ms(const char *path) {
    return pion_cli_path_change_ms(path);
}

#else /* POSIX */

#ifdef __linux__
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#endif
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE /* flock() in <sys/file.h> */
#define _DEFAULT_SOURCE  /* flock() on glibc / musl */

#include "pion_rt.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
#ifdef __linux__
#include <elf.h>
#include <link.h>
#include <sys/prctl.h>
#endif
#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <mach-o/ldsyms.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <sys/event.h>
#endif

static char *pion_cli_strdup(const char *s) {
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (p) memcpy(p, s, n + 1);
    return p;
}

static char *pion_cli_readlink(const char *path) {
    char *buf = NULL;
    for (size_t cap = 256; ; cap *= 2) {
        char *nb = (char *)realloc(buf, cap);
        if (!nb) { free(buf); return NULL; }
        buf = nb;
        ssize_t n = readlink(path, buf, cap);
        if (n < 0) { free(buf); return NULL; }
        if ((size_t)n < cap) {
            buf[n] = '\0';
            return buf;
        }
        if (cap >= (1u << 20)) { free(buf); return NULL; }
    }
}

static char *pion_cli_join_norm(const char *base, const char *tail) {
    size_t rlen = strlen(base);
    size_t tlen = tail ? strlen(tail) : 0;
    char *buf = (char *)malloc(rlen + tlen + 2);
    if (!buf) return NULL;
    memcpy(buf, base, rlen);
    size_t out_len = rlen;
    while (out_len > 1 && buf[out_len - 1] == '/') out_len--;
    const char *p = tail ? tail : "";
    int missing_depth = 0;
    int left_existing = 0;
    while (*p) {
        while (*p == '/') p++;
        if (!*p) break;
        if (left_existing && missing_depth == 0) {
            /* Returned to an existing directory after canceling missing segment(s):
             * append remaining tail verbatim so the outer loop resolves any symlinks
             * (e.g. dir/nope/../hop/../out.mjs) before folding subsequent `..`. */
            size_t rem = strlen(p);
            if (out_len == 0 || buf[out_len - 1] != '/') buf[out_len++] = '/';
            memcpy(buf + out_len, p, rem);
            out_len += rem;
            break;
        }
        const char *seg = p;
        while (*p && *p != '/') p++;
        size_t slen = (size_t)(p - seg);
        if (slen == 1 && seg[0] == '.') continue;
        if (slen == 2 && seg[0] == '.' && seg[1] == '.') {
            while (out_len > 1 && buf[out_len - 1] != '/') out_len--;
            if (out_len > 1) out_len--;
            if (missing_depth > 0) missing_depth--;
            else left_existing = 1;
            continue;
        }
        if (out_len == 0 || buf[out_len - 1] != '/') buf[out_len++] = '/';
        memcpy(buf + out_len, seg, slen);
        out_len += slen;
        missing_depth++;
        left_existing = 1;
    }
    buf[out_len] = '\0';
    return buf;
}

static char *pion_cli_splice_symlink(const char *prefix, const char *tgt, const char *tail) {
    size_t tlen = strlen(tgt);
    size_t tail_len = tail ? strlen(tail) : 0;
    if (tgt[0] == '/') {
        size_t need = tlen + (tail_len > 0 ? 1 + tail_len : 0) + 1;
        char *out = (char *)malloc(need);
        if (!out) return NULL;
        memcpy(out, tgt, tlen);
        size_t pos = tlen;
        if (tail_len > 0) {
            if (pos == 0 || out[pos - 1] != '/') out[pos++] = '/';
            memcpy(out + pos, tail, tail_len);
            pos += tail_len;
        }
        out[pos] = '\0';
        return out;
    }
    const char *last_slash = strrchr(prefix, '/');
    const char *dir = ".";
    size_t dlen = 1;
    if (last_slash) {
        if (last_slash == prefix) {
            dir = "/";
            dlen = 1;
        } else {
            dir = prefix;
            dlen = (size_t)(last_slash - prefix);
        }
    }
    size_t need = dlen + 1 + tlen + (tail_len > 0 ? 1 + tail_len : 0) + 1;
    char *out = (char *)malloc(need);
    if (!out) return NULL;
    memcpy(out, dir, dlen);
    size_t pos = dlen;
    if (pos == 0 || out[pos - 1] != '/') out[pos++] = '/';
    memcpy(out + pos, tgt, tlen);
    pos += tlen;
    if (tail_len > 0) {
        if (pos == 0 || out[pos - 1] != '/') out[pos++] = '/';
        memcpy(out + pos, tail, tail_len);
        pos += tail_len;
    }
    out[pos] = '\0';
    return out;
}

char *pion_fs_canon_path(const char *path) {
    if (!path || path[0] == '\0') return NULL;
    char *cur = pion_cli_strdup(path);
    if (!cur) return NULL;
    int hops = 0;
    for (;;) {
        char *rp = realpath(cur, NULL);
        if (rp) {
            free(cur);
            return rp;
        }
        if (errno == ELOOP) {
            free(cur);
            return NULL;
        }
        size_t clen = strlen(cur);
        char *work = (char *)malloc(clen + 1);
        if (!work) { free(cur); return NULL; }
        memcpy(work, cur, clen + 1);

        const char *prefix = NULL;
        const char *tail = "";
        struct stat st;
        int is_sym = 0;

        if (lstat(work, &st) == 0) {
            prefix = work;
            tail = "";
            is_sym = S_ISLNK(st.st_mode);
        } else {
            size_t cut = clen;
            while (cut > 0) {
                size_t s = cut;
                while (s > 0 && work[s - 1] != '/') s--;
                if (s == 0) {
                    prefix = ".";
                    tail = cur;
                    is_sym = 0;
                    break;
                }
                size_t slash = s - 1;
                if (slash == 0) {
                    prefix = "/";
                    tail = cur + 1;
                    is_sym = 0;
                    break;
                }
                work[slash] = '\0';
                if (lstat(work, &st) == 0) {
                    prefix = work;
                    tail = cur + slash + 1;
                    is_sym = S_ISLNK(st.st_mode);
                    break;
                }
                if (errno == ELOOP) {
                    free(work);
                    free(cur);
                    return NULL;
                }
                cut = slash;
            }
        }

        if (!prefix) {
            free(work);
            free(cur);
            return NULL;
        }

        if (is_sym) {
            if (++hops > 32) {
                free(work);
                free(cur);
                return NULL;
            }
            char *tgt = pion_cli_readlink(prefix);
            if (!tgt) {
                free(work);
                free(cur);
                return NULL;
            }
            char *next = pion_cli_splice_symlink(prefix, tgt, tail);
            free(tgt);
            free(work);
            free(cur);
            if (!next) return NULL;
            cur = next;
            continue;
        }

        rp = realpath(prefix, NULL);
        free(work);
        if (!rp) {
            free(cur);
            return NULL;
        }
        char *collapsed = pion_cli_join_norm(rp, tail);
        free(rp);
        if (!collapsed) {
            free(cur);
            return NULL;
        }
        if (strcmp(collapsed, cur) != 0) {
            if (++hops > 32) {
                free(collapsed);
                free(cur);
                return NULL;
            }
            free(cur);
            cur = collapsed;
            continue;
        }
        free(cur);
        return collapsed;
    }
}

/* Exclusive single-directory create (no shell, no parents): 0 if this call
 * created `path`, -1 if it already exists or cannot be created. */
int32_t pion_fs_mkdir_excl(const char *path) {
    return (path && *path && mkdir(path, 0700) == 0) ? 0 : -1;
}

/* Like pion_fs_mkdir_excl, but tells a taken name apart: 0 if this call
 * created `path`, 1 if something already exists there (EEXIST), -1 on any
 * other failure (NULL / empty path, missing parent, EACCES, ENOSPC, ...). */
int32_t pion_fs_mkdir_excl_status(const char *path) {
    if (!path || !*path) return -1;
    if (mkdir(path, 0700) == 0) return 0;
    return errno == EEXIST ? 1 : -1;
}

/* Single empty-directory remove (no shell): 0 on success, -1 on error. */
int32_t pion_fs_rmdir(const char *path) {
    return (path && *path && rmdir(path) == 0) ? 0 : -1;
}

/* Non-blocking exclusive lock on `path` (created if missing, never removed):
 * a handle >= 0, or -1 when another process holds it. The lock lives on the
 * open file description (close-on-exec, not inherited), so the kernel drops
 * it when the holder exits or is killed. */
int64_t pion_fs_trylock(const char *path) {
    if (!path || !*path) return -1;
    int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        return -1;
    }
    return (int64_t)fd;
}

/* Blocking exclusive lock on `path` (created if missing, never removed):
 * waits until no other holder remains; a handle >= 0, or -1 on error.
 * Released with pion_fs_unlock; the kernel drops it if the holder dies. */
int64_t pion_fs_lock(const char *path) {
    if (!path || !*path) return -1;
    int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    int rc;
    do {
        rc = flock(fd, LOCK_EX);
    } while (rc != 0 && errno == EINTR);
    if (rc != 0) {
        close(fd);
        return -1;
    }
    return (int64_t)fd;
}

/* Releases a `pion_fs_trylock` / `pion_fs_lock` handle (the lock file stays). */
void pion_fs_unlock(int64_t handle) {
    if (handle >= 0) close((int)handle);
}

/* This process's id (unique among live processes; `pionc` temp-file names). */
int64_t pion_cli_getpid(void) {
    return (int64_t)getpid();
}

int64_t pion_cli_getppid(void) {
    return (int64_t)getppid();
}

/* Process-wide monotonically increasing sequence (0, 1, 2, ...), safe across
 * threads: every call returns a value no other call in this process got. */
int64_t pion_cli_next_seq(void) {
    static _Atomic uint64_t s_seq = 0;
    return (int64_t)atomic_fetch_add_explicit(&s_seq, 1, memory_order_relaxed);
}

/* 1 on a Windows host build of pionc (host path rules), else 0. */
int32_t pion_cli_is_windows(void) {
    return 0;
}

int32_t pion_cli_cpu_count(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 1) return 1;
    if (n > 1024) return 1024;
    return (int32_t)n;
}

int32_t pion_cli_pid_alive(int64_t pid) {
    if (pid <= 0) return 0;
    pid_t p = (pid_t)pid;
    if ((int64_t)p != pid || p <= 0) return 0;
    if (kill(p, 0) == 0) return 1;
    if (errno == ESRCH) return 0;
    return 1;
}

#ifdef __APPLE__
struct pion_cli_kqueue_watch_arg {
    int kq;
    int64_t expected_ppid;
};

static void *pion_cli_macos_parent_watch_thread(void *raw) {
    struct pion_cli_kqueue_watch_arg *arg = (struct pion_cli_kqueue_watch_arg *)raw;
    int kq = arg->kq;
    int64_t expected_ppid = arg->expected_ppid;
    free(arg);
    if ((int64_t)getppid() != expected_ppid) {
        close(kq);
        _exit(1);
    }
    struct kevent ev;
    for (;;) {
        int n = kevent(kq, NULL, 0, &ev, 1, NULL);
        if (n > 0) {
            close(kq);
            _exit(1);
        }
        if (n < 0 && errno == EINTR) continue;
        if ((int64_t)getppid() != expected_ppid) {
            close(kq);
            _exit(1);
        }
        break;
    }
    close(kq);
    return NULL;
}
#endif

int32_t pion_cli_watch_parent(int64_t expected_ppid) {
    if (expected_ppid <= 1) return -1;
#ifdef __linux__
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0) return -1;
    if ((int64_t)getppid() != expected_ppid) _exit(1);
    return 0;
#elif defined(__APPLE__)
    int kq = kqueue();
    if (kq < 0) return -1;
    (void)fcntl(kq, F_SETFD, FD_CLOEXEC);
    struct kevent kev;
    EV_SET(&kev, (uintptr_t)expected_ppid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(kq, &kev, 1, NULL, 0, NULL) != 0) {
        close(kq);
        if ((int64_t)getppid() != expected_ppid) _exit(1);
        return -1;
    }
    if ((int64_t)getppid() != expected_ppid) {
        close(kq);
        _exit(1);
    }
    struct pion_cli_kqueue_watch_arg *arg =
        (struct pion_cli_kqueue_watch_arg *)malloc(sizeof(*arg));
    if (!arg) {
        close(kq);
        return -1;
    }
    arg->kq = kq;
    arg->expected_ppid = expected_ppid;
    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&th, &attr, pion_cli_macos_parent_watch_thread, arg);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        free(arg);
        close(kq);
        return -1;
    }
    return 0;
#else
    if ((int64_t)getppid() != expected_ppid) _exit(1);
    return 0;
#endif
}

char *pion_cli_self_exe_path(void) {
#ifdef __linux__
    char *p = pion_cli_readlink("/proc/self/exe");
    if (!p) return NULL;
    struct stat st;
    if (lstat(p, &st) != 0 || !S_ISREG(st.st_mode)) {
        free(p);
        return NULL;
    }
    return p;
#elif defined(__APPLE__)
    uint32_t sz = 0;
    (void)_NSGetExecutablePath(NULL, &sz);
    if (sz == 0 || sz > (1u << 20)) return NULL;
    char *buf = (char *)malloc((size_t)sz + 1);
    if (!buf) return NULL;
    if (_NSGetExecutablePath(buf, &sz) != 0) {
        free(buf);
        return NULL;
    }
    buf[sz] = '\0';
    char *rp = realpath(buf, NULL);
    free(buf);
    return rp;
#else
    return NULL;
#endif
}

#ifdef __linux__
struct pion_cli_elf_bid_ctx {
    char out[160];
    int found;
};

static int pion_cli_elf_bid_cb(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    struct pion_cli_elf_bid_ctx *ctx = (struct pion_cli_elf_bid_ctx *)data;
    if (ctx->found) return 1;
    /* Main executable always has an empty dlpi_name. */
    if (info->dlpi_name && info->dlpi_name[0] != '\0') return 0;
    static const char hex[] = "0123456789abcdef";
    for (ElfW(Half) i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_NOTE || ph->p_memsz < sizeof(ElfW(Nhdr))) continue;
        const uint8_t *p = (const uint8_t *)(uintptr_t)(info->dlpi_addr + ph->p_vaddr);
        const uint8_t *end = p + ph->p_memsz;
        size_t align = (ph->p_align == 8) ? 8 : 4;
        while (p + sizeof(ElfW(Nhdr)) <= end) {
            ElfW(Nhdr) nh;
            memcpy(&nh, p, sizeof(nh));
            const uint8_t *name = p + sizeof(nh);
            size_t name_sz = (size_t)nh.n_namesz;
            size_t name_pad = (name_sz + align - 1) & ~(align - 1);
            if (name_pad > (size_t)(end - name)) break;
            const uint8_t *desc = name + name_pad;
            size_t desc_sz = (size_t)nh.n_descsz;
            size_t desc_pad = (desc_sz + align - 1) & ~(align - 1);
            if (desc_sz > (size_t)(end - desc)) break;
            if (nh.n_type == NT_GNU_BUILD_ID && name_sz == 4 &&
                memcmp(name, "GNU\0", 4) == 0 && desc_sz > 0 && desc_sz <= 64) {
                memcpy(ctx->out, "elf-bid:", 8);
                for (size_t b = 0; b < desc_sz; b++) {
                    ctx->out[8 + b * 2] = hex[(desc[b] >> 4) & 15u];
                    ctx->out[8 + b * 2 + 1] = hex[desc[b] & 15u];
                }
                ctx->out[8 + desc_sz * 2] = '\0';
                ctx->found = 1;
                return 1;
            }
            if (desc_pad > (size_t)(end - desc)) break;
            p = desc + desc_pad;
        }
    }
    return 1;
}
#endif

static void pion_cli_compute_image_id_posix(char out[160]) {
    out[0] = '\0';
#ifdef __APPLE__
    static const char hex[] = "0123456789abcdef";
    const struct mach_header_64 *mh = &_mh_execute_header;
    const uint8_t *cmdp = (const uint8_t *)(mh + 1);
    const uint8_t *end = cmdp + mh->sizeofcmds;
    for (uint32_t i = 0; i < mh->ncmds && cmdp + sizeof(struct load_command) <= end; i++) {
        const struct load_command *lc = (const struct load_command *)cmdp;
        if (lc->cmdsize < sizeof(struct load_command) || lc->cmdsize > (uint32_t)(end - cmdp)) break;
        if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uc = (const struct uuid_command *)cmdp;
            memcpy(out, "macho-uuid:", 11);
            for (int b = 0; b < 16; b++) {
                out[11 + b * 2] = hex[(uc->uuid[b] >> 4) & 15u];
                out[11 + b * 2 + 1] = hex[uc->uuid[b] & 15u];
            }
            out[11 + 32] = '\0';
            return;
        }
        cmdp += lc->cmdsize;
    }
#elif defined(__linux__)
    struct pion_cli_elf_bid_ctx ctx;
    ctx.out[0] = '\0';
    ctx.found = 0;
    dl_iterate_phdr(pion_cli_elf_bid_cb, &ctx);
    if (ctx.found) {
        memcpy(out, ctx.out, strlen(ctx.out) + 1);
        return;
    }
    struct stat st;
    if (stat("/proc/self/exe", &st) == 0) {
        snprintf(out, 160, "proc-exe:%llx:%llx:%llx:%llx:%llx",
                 (unsigned long long)st.st_dev,
                 (unsigned long long)st.st_ino,
                 (unsigned long long)st.st_size,
                 (unsigned long long)st.st_mtim.tv_sec,
                 (unsigned long long)st.st_mtim.tv_nsec);
    }
#endif
}

char *pion_cli_self_image_id(void) {
    static _Atomic int s_state = 0; /* 0 = uninit, 1 = initing, 2 = ready */
    static char s_id[160];
    int cur = atomic_load_explicit(&s_state, memory_order_acquire);
    if (cur != 2) {
        int expected = 0;
        if (atomic_compare_exchange_strong_explicit(
                &s_state, &expected, 1, memory_order_acq_rel, memory_order_acquire)) {
            pion_cli_compute_image_id_posix(s_id);
            atomic_store_explicit(&s_state, 2, memory_order_release);
        } else {
            while (atomic_load_explicit(&s_state, memory_order_acquire) != 2) {
                /* spin briefly while initializing thread finishes (<0.05ms) */
            }
        }
    }
    if (s_id[0] == '\0') return NULL;
    return pion_cli_strdup(s_id);
}

/* Single-threaded async worker subprocess launcher & reaper (keeps parent
 * pionc in ST biased-RC mode without entering pion_enter_mt()). */
static pid_t   g_ws_posix_pids[128];
static int     g_ws_posix_count = 0;
static int32_t g_ws_posix_last_rc = -1;

int64_t pion_cli_spawn_ws_worker(const char *exe, const char *spec_path,
                                 const char *res_path, const char *expected_fp,
                                 const char *parent_pid_str) {
    if (!exe || !*exe || !spec_path || !res_path || !expected_fp || !parent_pid_str) return -1;
    if (g_ws_posix_count >= 128) return -1;
    char *argv[11];
    argv[0] = (char *)exe;
    argv[1] = (char *)"--internal-ws-pkg-worker";
    argv[2] = (char *)"--spec";
    argv[3] = (char *)spec_path;
    argv[4] = (char *)"--result";
    argv[5] = (char *)res_path;
    argv[6] = (char *)"--expected-fp";
    argv[7] = (char *)expected_fp;
    argv[8] = (char *)"--parent-pid";
    argv[9] = (char *)parent_pid_str;
    argv[10] = NULL;
    pid_t pid = 0;
    int err = posix_spawn(&pid, exe, NULL, NULL, argv, environ);
    if (err != 0 || pid <= 0) return -1;
    g_ws_posix_pids[g_ws_posix_count++] = pid;
    return (int64_t)pid;
}

int64_t pion_cli_wait_any_ws_worker(void) {
    if (g_ws_posix_count <= 0) return -1;
    for (;;) {
        int status = 0;
        pid_t w = waitpid(-1, &status, 0);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        for (int i = 0; i < g_ws_posix_count; i++) {
            if (g_ws_posix_pids[i] == w) {
                g_ws_posix_count--;
                g_ws_posix_pids[i] = g_ws_posix_pids[g_ws_posix_count];
                if (WIFEXITED(status)) {
                    g_ws_posix_last_rc = (int32_t)WEXITSTATUS(status);
                } else if (WIFSIGNALED(status)) {
                    g_ws_posix_last_rc = (int32_t)(128 + WTERMSIG(status));
                } else {
                    g_ws_posix_last_rc = 1;
                }
                return (int64_t)w;
            }
        }
    }
}

int32_t pion_cli_last_ws_worker_rc(void) {
    return g_ws_posix_last_rc;
}

int32_t pion_cli_can_reap_children(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    if (sigaction(SIGCHLD, NULL, &sa) != 0) return 1;
    if (sa.sa_handler == SIG_IGN) return 0;
#ifdef SA_NOCLDWAIT
    if ((sa.sa_flags & SA_NOCLDWAIT) != 0) return 0;
#endif
    return 1;
}

/* lstat kind without following links: 0 confirmed missing (ENOENT), 1
 * regular file, 2 directory, 3 symlink, 4 other (FIFO, socket, device), -1
 * when the query itself fails (EACCES, ENOTDIR, EIO, ...) — never "missing". */
int32_t pion_fs_lstat_kind(const char *path) {
    if (!path || !*path) return -1;
    struct stat st;
    if (lstat(path, &st) != 0) return errno == ENOENT ? 0 : -1;
    if (S_ISREG(st.st_mode)) return 1;
    if (S_ISDIR(st.st_mode)) return 2;
    if (S_ISLNK(st.st_mode)) return 3;
    return 4;
}

static int64_t pion_cli_stat_change_ms(const struct stat *st) {
#ifdef __APPLE__
    int64_t m = (int64_t)st->st_mtimespec.tv_sec * 1000LL +
                (int64_t)(st->st_mtimespec.tv_nsec / 1000000L);
    int64_t c = (int64_t)st->st_ctimespec.tv_sec * 1000LL +
                (int64_t)(st->st_ctimespec.tv_nsec / 1000000L);
#else
    int64_t m = (int64_t)st->st_mtim.tv_sec * 1000LL +
                (int64_t)(st->st_mtim.tv_nsec / 1000000L);
    int64_t c = (int64_t)st->st_ctim.tv_sec * 1000LL +
                (int64_t)(st->st_ctim.tv_nsec / 1000000L);
#endif
    return m >= c ? m : c;
}

int64_t pion_cli_path_change_ms(const char *path) {
    if (!path || !*path) return -1;
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    return pion_cli_stat_change_ms(&st);
}

int64_t pion_cli_lpath_change_ms(const char *path) {
    if (!path || !*path) return -1;
    struct stat st;
    if (lstat(path, &st) != 0) return -1;
    return pion_cli_stat_change_ms(&st);
}

#endif /* _WIN32 */

/* Streaming SHA-256 of any file on disk (64 KiB buffer, O(1) memory, raw bytes).
 * Returns a heap-allocated 64-char lowercase hex C string (caller frees via free),
 * or NULL on open/read error or if `path` is a directory. */
static const uint32_t PION_CLI_SHA256_K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

static inline uint32_t pion_cli_rotr32(uint32_t x, unsigned n) {
    return (x >> n) | (x << (32u - n));
}

static void pion_cli_sha256_block(uint32_t st[8], const uint8_t blk[64]) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)blk[i * 4] << 24) |
               ((uint32_t)blk[i * 4 + 1] << 16) |
               ((uint32_t)blk[i * 4 + 2] << 8) |
               (uint32_t)blk[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = pion_cli_rotr32(w[i - 15], 7) ^ pion_cli_rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = pion_cli_rotr32(w[i - 2], 17) ^ pion_cli_rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = st[0], b = st[1], c = st[2], d = st[3];
    uint32_t e = st[4], f = st[5], g = st[6], h = st[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = pion_cli_rotr32(e, 6) ^ pion_cli_rotr32(e, 11) ^ pion_cli_rotr32(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + S1 + ch + PION_CLI_SHA256_K[i] + w[i];
        uint32_t S0 = pion_cli_rotr32(a, 2) ^ pion_cli_rotr32(a, 13) ^ pion_cli_rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    st[0] += a; st[1] += b; st[2] += c; st[3] += d;
    st[4] += e; st[5] += f; st[6] += g; st[7] += h;
}

char *pion_cli_sha256_file(const char *path) {
    if (!path || !*path) return NULL;
#ifdef _WIN32
    wchar_t *wp = pion_cli_utf8_to_wide(path, strlen(path));
    if (!wp) return NULL;
    DWORD attr = GetFileAttributesW(wp);
    if (attr == INVALID_FILE_ATTRIBUTES || (attr & FILE_ATTRIBUTE_DIRECTORY)) {
        free(wp);
        return NULL;
    }
    FILE *fp = _wfopen(wp, L"rb");
    free(wp);
    if (!fp) return NULL;
#else
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat st_buf;
    if (fstat(fd, &st_buf) != 0 || S_ISDIR(st_buf.st_mode)) {
        close(fd);
        return NULL;
    }
    FILE *fp = fdopen(fd, "rb");
    if (!fp) {
        close(fd);
        return NULL;
    }
#endif
    uint8_t *io_buf = (uint8_t *)malloc(65536);
    if (!io_buf) {
        fclose(fp);
        return NULL;
    }
    uint32_t state[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
    };
    uint8_t tail[64];
    size_t tail_len = 0;
    uint64_t total_bytes = 0;
    for (;;) {
        size_t n = fread(io_buf, 1, 65536, fp);
        if (n > 0) {
            total_bytes += (uint64_t)n;
            size_t off = 0;
            if (tail_len > 0) {
                size_t need = 64 - tail_len;
                size_t take = n < need ? n : need;
                memcpy(tail + tail_len, io_buf, take);
                tail_len += take;
                off += take;
                if (tail_len == 64) {
                    pion_cli_sha256_block(state, tail);
                    tail_len = 0;
                }
            }
            while (off + 64 <= n) {
                pion_cli_sha256_block(state, io_buf + off);
                off += 64;
            }
            if (off < n) {
                tail_len = n - off;
                memcpy(tail, io_buf + off, tail_len);
            }
        }
        if (n < 65536) {
            if (ferror(fp)) {
                free(io_buf);
                fclose(fp);
                return NULL;
            }
            break;
        }
    }
    free(io_buf);
    fclose(fp);

    uint64_t bit_len = total_bytes * 8ULL;
    tail[tail_len++] = 0x80u;
    if (tail_len > 56) {
        memset(tail + tail_len, 0, 64 - tail_len);
        pion_cli_sha256_block(state, tail);
        tail_len = 0;
    }
    memset(tail + tail_len, 0, 56 - tail_len);
    for (int i = 0; i < 8; i++) {
        tail[56 + i] = (uint8_t)((bit_len >> (56 - i * 8)) & 0xFFu);
    }
    pion_cli_sha256_block(state, tail);

    char *out = (char *)malloc(65);
    if (!out) return NULL;
    static const char HEX[] = "0123456789abcdef";
    for (int i = 0; i < 8; i++) {
        uint32_t w = state[i];
        for (int j = 0; j < 8; j++) {
            out[i * 8 + j] = HEX[(w >> (28 - j * 4)) & 0xFu];
        }
    }
    out[64] = '\0';
    return out;
}

#include <stdio.h>

#ifdef _WIN32
#define PION_CLI_GETC(fp) fgetc(fp)
#else
#define PION_CLI_GETC(fp) getc_unlocked(fp)
#endif

/* Compiler-only bounded line reader (used by `pionc check --server`).
 * Reads one line from `fp` up to `max_bytes` payload bytes (strictly capping
 * heap allocation at `max_bytes + 1` for NUL termination). Strips trailing
 * '\n' or "\r\n" and handles a final line without trailing '\n'.
 * When a line exceeds `max_bytes`, stops buffering immediately, frees the
 * buffer, and drains remaining bytes through '\n' or EOF so the next frame
 * stays cleanly framed.
 * Returns:
 *   0 = OK (*out_buf_slot = heap NUL-terminated buffer or NULL if len==0,
 *           *out_len_slot = payload byte length)
 *   1 = clean EOF (0 bytes read, !ferror(fp))
 *   2 = line exceeded `max_bytes`
 *   3 = I/O read error (ferror(fp)) or allocation failure */
int32_t pion_cli_read_line_bounded_fp(FILE *fp, int64_t max_bytes,
                                      void *out_buf_slot, void *out_len_slot) {
    char **buf_out = (char **)out_buf_slot;
    int64_t *len_out = (int64_t *)out_len_slot;
    if (buf_out) *buf_out = NULL;
    if (len_out) *len_out = 0;
    if (!fp || max_bytes < 0) return 3;

    size_t limit = (size_t)max_bytes;
    char *buf = NULL;
    size_t cap = 0;
    size_t len = 0;
    int saw_any = 0;
    int exceeded = 0;
    int pending_cr = 0;
    int oom = 0;

    for (;;) {
        int c = PION_CLI_GETC(fp);
        if (c == EOF) {
            if (ferror(fp) || oom) {
                free(buf);
                return 3;
            }
            if (exceeded || pending_cr) {
                free(buf);
                return 2;
            }
            if (!saw_any) {
                free(buf);
                return 1;
            }
            if (buf) buf[len] = '\0';
            if (buf_out) *buf_out = buf;
            else free(buf);
            if (len_out) *len_out = (int64_t)len;
            return 0;
        }
        saw_any = 1;
        if (c == '\n') {
            if (oom) {
                free(buf);
                return 3;
            }
            if (exceeded) {
                free(buf);
                return 2;
            }
            if (!pending_cr && len > 0 && buf[len - 1] == '\r') {
                len--;
            }
            if (len == 0) {
                free(buf);
                buf = NULL;
            } else if (buf) {
                buf[len] = '\0';
            }
            if (buf_out) *buf_out = buf;
            else free(buf);
            if (len_out) *len_out = (int64_t)len;
            return 0;
        }
        if (exceeded || oom) {
            continue;
        }
        if (pending_cr) {
            free(buf);
            buf = NULL;
            cap = 0;
            len = 0;
            pending_cr = 0;
            exceeded = 1;
            continue;
        }
        if (len == limit) {
            if (c == '\r') {
                pending_cr = 1;
            } else {
                free(buf);
                buf = NULL;
                cap = 0;
                len = 0;
                exceeded = 1;
            }
            continue;
        }
        /* Buffer holds up to `limit` payload bytes plus 1 byte for trailing NUL
         * (total allocation <= limit + 1). */
        if (len == cap) {
            size_t new_cap = cap ? cap * 2 : 4096;
            if (new_cap < len + 1) new_cap = len + 1;
            if (new_cap > limit) new_cap = limit;
            char *nb = (char *)realloc(buf, new_cap + 1);
            if (!nb) {
                free(buf);
                buf = NULL;
                cap = 0;
                len = 0;
                oom = 1;
                continue;
            }
            buf = nb;
            cap = new_cap;
        }
        buf[len++] = (char)c;
    }
}

int32_t pion_cli_read_line_bounded(int64_t max_bytes,
                                   void *out_buf_slot, void *out_len_slot) {
    return pion_cli_read_line_bounded_fp(stdin, max_bytes, out_buf_slot, out_len_slot);
}

void pion_cli_free_buf(void *buf) {
    free(buf);
}

/* Writes a single complete JSON-lines frame with one fwrite + '\n' + one fflush.
 * Returns 0 on success, -1 on I/O error. */
int32_t pion_cli_write_line_fp(FILE *fp, const char *data, int64_t len) {
    if (!fp || len < 0) return -1;
    if (len > 0) {
        if (!data) return -1;
        if (fwrite(data, 1, (size_t)len, fp) != (size_t)len) return -1;
    }
    if (fputc('\n', fp) == EOF) return -1;
    if (fflush(fp) != 0) return -1;
    return 0;
}

int32_t pion_cli_write_line(const char *data, int64_t len) {
    return pion_cli_write_line_fp(stdout, data, len);
}
