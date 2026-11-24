/* pion_cli.c — CLI-only native host helpers linked exclusively into `pionc`
 * (and runtime tests), never into `libpionrt.a` so user binaries pay 0 bytes. */

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include "pion_rt.h"
#include <windows.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

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

#else /* POSIX */

#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700

#include "pion_rt.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

#endif /* _WIN32 */
