#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE 0x00020016
#endif

typedef void *PionHPCON;
typedef HRESULT (WINAPI *PionCreatePseudoConsoleFn)(COORD, HANDLE, HANDLE, DWORD, PionHPCON *);
typedef HRESULT (WINAPI *PionResizePseudoConsoleFn)(PionHPCON, COORD);
typedef void (WINAPI *PionClosePseudoConsoleFn)(PionHPCON);

#define PION_PROC_MAX_SLOTS 1024

typedef struct {
    CRITICAL_SECTION cs;
    LONG refcnt;
    DWORD pid;
    HANDLE h_proc;
    HANDLE h_job;
    HANDLE h_stdin;
    HANDLE h_stdout;
    HANDLE h_stderr;
    PionHPCON h_pty;
    int is_pty;
    int reaped;
    int exit_kind;
    int exit_code;
} PionProc;

typedef struct {
    uint32_t gen;
    PionProc *proc;
} PionProcSlot;

static INIT_ONCE g_init_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION g_table_cs;
static PionProcSlot g_slots[PION_PROC_MAX_SLOTS];
static volatile LONG g_pipe_seq = 0;

static PionCreatePseudoConsoleFn g_create_conpty = NULL;
static PionResizePseudoConsoleFn g_resize_conpty = NULL;
static PionClosePseudoConsoleFn g_close_conpty = NULL;

static BOOL CALLBACK pion_proc_win_init(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once; (void)param; (void)ctx;
    InitializeCriticalSection(&g_table_cs);
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    if (k32) {
        g_create_conpty = (PionCreatePseudoConsoleFn)(void *)GetProcAddress(k32, "CreatePseudoConsole");
        g_resize_conpty = (PionResizePseudoConsoleFn)(void *)GetProcAddress(k32, "ResizePseudoConsole");
        g_close_conpty = (PionClosePseudoConsoleFn)(void *)GetProcAddress(k32, "ClosePseudoConsole");
    }
    return TRUE;
}

static void ensure_init(void) {
    InitOnceExecuteOnce(&g_init_once, pion_proc_win_init, NULL, NULL);
}

static void set_err(char *buf, int32_t cap, const char *msg) {
    if (!buf || cap <= 0) return;
    snprintf(buf, (size_t)cap, "%s", msg ? msg : "unknown error");
}

static void set_win_err(char *buf, int32_t cap, const char *ctx, DWORD err) {
    if (!buf || cap <= 0) return;
    WCHAR wmsg[256];
    DWORD n = FormatMessageW(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL, err, 0, wmsg, (DWORD)(sizeof(wmsg) / sizeof(wmsg[0])), NULL);
    while (n > 0 && (wmsg[n - 1] == L'\r' || wmsg[n - 1] == L'\n' || wmsg[n - 1] == L' ')) {
        wmsg[--n] = L'\0';
    }
    char umsg[512];
    if (n > 0 && WideCharToMultiByte(CP_UTF8, 0, wmsg, -1, umsg, (int)sizeof(umsg), NULL, NULL) > 0) {
        snprintf(buf, (size_t)cap, "%s (winerr=%lu): %s", ctx, (unsigned long)err, umsg);
    } else {
        snprintf(buf, (size_t)cap, "%s (winerr=%lu)", ctx, (unsigned long)err);
    }
}

static WCHAR *utf8_to_wide(const char *s) {
    if (!s) s = "";
    int needed = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (needed <= 0) return NULL;
    WCHAR *w = (WCHAR *)malloc((size_t)needed * sizeof(WCHAR));
    if (!w) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, needed) <= 0) {
        free(w);
        return NULL;
    }
    return w;
}

static void *slot_register(PionProc *p) {
    ensure_init();
    EnterCriticalSection(&g_table_cs);
    for (uint32_t i = 0; i < PION_PROC_MAX_SLOTS; i++) {
        if (g_slots[i].proc == NULL) {
            g_slots[i].gen++;
            if (g_slots[i].gen == 0) g_slots[i].gen = 1;
            g_slots[i].proc = p;
            uint64_t handle = ((uint64_t)g_slots[i].gen << 16) | (uint64_t)(i + 1u);
            LeaveCriticalSection(&g_table_cs);
            return (void *)(uintptr_t)handle;
        }
    }
    LeaveCriticalSection(&g_table_cs);
    return NULL;
}

static PionProc *slot_acquire(void *h) {
    ensure_init();
    uintptr_t raw = (uintptr_t)h;
    if (raw == 0) return NULL;
    uint32_t idx1 = (uint32_t)(raw & 0xFFFFu);
    uint32_t gen = (uint32_t)((uint64_t)raw >> 16);
    if (idx1 == 0 || idx1 > PION_PROC_MAX_SLOTS) return NULL;
    uint32_t idx = idx1 - 1u;

    EnterCriticalSection(&g_table_cs);
    PionProc *p = NULL;
    if (g_slots[idx].proc != NULL && g_slots[idx].gen == gen) {
        p = g_slots[idx].proc;
        InterlockedIncrement(&p->refcnt);
    }
    LeaveCriticalSection(&g_table_cs);
    return p;
}

static void proc_release(PionProc *p) {
    if (!p) return;
    if (InterlockedDecrement(&p->refcnt) == 0) {
        DeleteCriticalSection(&p->cs);
        free(p);
    }
}

typedef struct {
    WCHAR *data;
    size_t len;
    size_t cap;
} WBuf;

static int wbuf_push(WBuf *b, WCHAR c) {
    if (b->len + 1 >= b->cap) {
        size_t ncap = b->cap ? b->cap * 2 : 128;
        WCHAR *nd = (WCHAR *)realloc(b->data, ncap * sizeof(WCHAR));
        if (!nd) return 0;
        b->data = nd;
        b->cap = ncap;
    }
    b->data[b->len++] = c;
    b->data[b->len] = L'\0';
    return 1;
}

static int wbuf_push_str(WBuf *b, const WCHAR *s) {
    for (size_t i = 0; s[i] != L'\0'; i++) {
        if (!wbuf_push(b, s[i])) return 0;
    }
    return 1;
}

/* Standard Win32 CommandLineToArgvW quoting */
static int append_win32_arg(WBuf *b, const WCHAR *arg) {
    int need_quote = (arg[0] == L'\0');
    for (size_t i = 0; arg[i] != L'\0'; i++) {
        if (arg[i] == L' ' || arg[i] == L'\t' || arg[i] == L'"') {
            need_quote = 1;
            break;
        }
    }
    if (!need_quote) return wbuf_push_str(b, arg);
    if (!wbuf_push(b, L'"')) return 0;
    size_t bs = 0;
    for (size_t i = 0; arg[i] != L'\0'; i++) {
        if (arg[i] == L'\\') {
            bs++;
        } else if (arg[i] == L'"') {
            for (size_t j = 0; j < bs * 2 + 1; j++) {
                if (!wbuf_push(b, L'\\')) return 0;
            }
            if (!wbuf_push(b, L'"')) return 0;
            bs = 0;
        } else {
            for (size_t j = 0; j < bs; j++) {
                if (!wbuf_push(b, L'\\')) return 0;
            }
            bs = 0;
            if (!wbuf_push(b, arg[i])) return 0;
        }
    }
    for (size_t j = 0; j < bs * 2; j++) {
        if (!wbuf_push(b, L'\\')) return 0;
    }
    return wbuf_push(b, L'"');
}

/* Escape cmd.exe metacharacters when invoking .cmd/.bat via cmd.exe /d /s /c "..." */
static int append_cmd_arg(WBuf *b, const WCHAR *arg) {
    WBuf tmp = {0, 0, 0};
    if (!append_win32_arg(&tmp, arg)) {
        free(tmp.data);
        return 0;
    }
    const WCHAR *s = tmp.data ? tmp.data : L"";
    int in_quotes = 0;
    size_t backslashes = 0;
    for (size_t i = 0; s[i] != L'\0'; i++) {
        WCHAR c = s[i];
        if (c == L'"' && (backslashes & 1u) == 0) {
            in_quotes = !in_quotes;
        }
        if (!in_quotes &&
            (c == L'&' || c == L'|' || c == L'<' || c == L'>' ||
             c == L'^' || c == L'(' || c == L')')) {
            if (!wbuf_push(b, L'^')) { free(tmp.data); return 0; }
        }
        if (!wbuf_push(b, c)) { free(tmp.data); return 0; }
        backslashes = (c == L'\\') ? (backslashes + 1u) : 0u;
    }
    free(tmp.data);
    return 1;
}

static int ends_with_ci(const WCHAR *s, const WCHAR *suffix) {
    size_t sl = wcslen(s), sufl = wcslen(suffix);
    if (sl < sufl) return 0;
    return _wcsicmp(s + sl - sufl, suffix) == 0;
}

static int is_batch_script(const WCHAR *path) {
    return ends_with_ci(path, L".cmd") || ends_with_ci(path, L".bat");
}

static int file_exists_non_dir(const WCHAR *path) {
    DWORD attr = GetFileAttributesW(path);
    return (attr != INVALID_FILE_ATTRIBUTES) && ((attr & FILE_ATTRIBUTE_DIRECTORY) == 0);
}

typedef struct {
    WCHAR *key;
    WCHAR *entry;
} WEnvItem;

static int cmp_wenv(const void *a, const void *b) {
    const WEnvItem *ea = (const WEnvItem *)a;
    const WEnvItem *eb = (const WEnvItem *)b;
    return _wcsicmp(ea->key, eb->key);
}

static int wkey_in_list(const WCHAR *key, WCHAR **list, int32_t count) {
    for (int32_t i = 0; i < count; i++) {
        if (list[i] && _wcsicmp(key, list[i]) == 0) return 1;
    }
    return 0;
}

static WCHAR *build_win_env_block(
    const char *const *env_set_keys, const char *const *env_set_vals, int32_t env_set_count,
    const char *const *env_unset_keys, int32_t env_unset_count,
    int32_t clear_env,
    WCHAR **out_path, WCHAR **out_pathext,
    char *err_buf, int32_t err_cap) {

    *out_path = NULL;
    *out_pathext = NULL;

    WCHAR **w_unset = NULL;
    if (env_unset_count > 0) {
        w_unset = (WCHAR **)calloc((size_t)env_unset_count, sizeof(WCHAR *));
        if (!w_unset) { set_err(err_buf, err_cap, "out of memory"); return NULL; }
        for (int32_t i = 0; i < env_unset_count; i++) {
            w_unset[i] = utf8_to_wide(env_unset_keys[i]);
        }
    }
    WCHAR **w_set_k = NULL;
    WCHAR **w_set_v = NULL;
    if (env_set_count > 0) {
        w_set_k = (WCHAR **)calloc((size_t)env_set_count, sizeof(WCHAR *));
        w_set_v = (WCHAR **)calloc((size_t)env_set_count, sizeof(WCHAR *));
        if (!w_set_k || !w_set_v) {
            free(w_set_k); free(w_set_v);
            if (w_unset) { for (int32_t i = 0; i < env_unset_count; i++) free(w_unset[i]); free(w_unset); }
            set_err(err_buf, err_cap, "out of memory");
            return NULL;
        }
        for (int32_t i = 0; i < env_set_count; i++) {
            w_set_k[i] = utf8_to_wide(env_set_keys[i]);
            w_set_v[i] = utf8_to_wide(env_set_vals[i]);
        }
    }

    size_t cap = (size_t)(env_set_count > 0 ? env_set_count : 0) + 64u;
    WEnvItem *items = (WEnvItem *)calloc(cap, sizeof(WEnvItem));
    size_t n = 0;
    if (!items) {
        set_err(err_buf, err_cap, "out of memory");
        goto fail;
    }

    if (!clear_env) {
        LPWCH env_block = GetEnvironmentStringsW();
        if (env_block) {
            for (const WCHAR *cur = env_block; *cur != L'\0'; cur += wcslen(cur) + 1) {
                const WCHAR *eq = wcschr(cur, L'=');
                if (!eq || eq == cur) continue;
                size_t kl = (size_t)(eq - cur);
                WCHAR *k = (WCHAR *)malloc((kl + 1) * sizeof(WCHAR));
                if (!k) { FreeEnvironmentStringsW(env_block); goto fail; }
                memcpy(k, cur, kl * sizeof(WCHAR));
                k[kl] = L'\0';
                if (wkey_in_list(k, w_unset, env_unset_count) ||
                    wkey_in_list(k, w_set_k, env_set_count)) {
                    free(k);
                    continue;
                }
                if (n >= cap) {
                    cap *= 2;
                    WEnvItem *ni = (WEnvItem *)realloc(items, cap * sizeof(WEnvItem));
                    if (!ni) { free(k); FreeEnvironmentStringsW(env_block); goto fail; }
                    items = ni;
                }
                size_t el = wcslen(cur);
                WCHAR *e = (WCHAR *)malloc((el + 1) * sizeof(WCHAR));
                if (!e) { free(k); FreeEnvironmentStringsW(env_block); goto fail; }
                memcpy(e, cur, (el + 1) * sizeof(WCHAR));
                items[n].key = k;
                items[n].entry = e;
                n++;
            }
            FreeEnvironmentStringsW(env_block);
        }
    }

    for (int32_t i = 0; i < env_set_count; i++) {
        if (!w_set_k[i] || w_set_k[i][0] == L'\0') continue;
        if (n >= cap) {
            cap *= 2;
            WEnvItem *ni = (WEnvItem *)realloc(items, cap * sizeof(WEnvItem));
            if (!ni) goto fail;
            items = ni;
        }
        size_t kl = wcslen(w_set_k[i]);
        size_t vl = w_set_v[i] ? wcslen(w_set_v[i]) : 0;
        WCHAR *k = (WCHAR *)malloc((kl + 1) * sizeof(WCHAR));
        WCHAR *e = (WCHAR *)malloc((kl + 1 + vl + 1) * sizeof(WCHAR));
        if (!k || !e) { free(k); free(e); goto fail; }
        memcpy(k, w_set_k[i], (kl + 1) * sizeof(WCHAR));
        memcpy(e, w_set_k[i], kl * sizeof(WCHAR));
        e[kl] = L'=';
        if (vl > 0) memcpy(e + kl + 1, w_set_v[i], vl * sizeof(WCHAR));
        e[kl + 1 + vl] = L'\0';
        items[n].key = k;
        items[n].entry = e;
        n++;
    }

    if (n > 1) qsort(items, n, sizeof(WEnvItem), cmp_wenv);

    size_t total = 2; /* at least \0\0 */
    for (size_t i = 0; i < n; i++) {
        total += wcslen(items[i].entry) + 1;
        if (_wcsicmp(items[i].key, L"PATH") == 0) {
            const WCHAR *eq = wcschr(items[i].entry, L'=');
            if (eq) {
                free(*out_path);
                *out_path = _wcsdup(eq + 1);
            }
        } else if (_wcsicmp(items[i].key, L"PATHEXT") == 0) {
            const WCHAR *eq = wcschr(items[i].entry, L'=');
            if (eq) {
                free(*out_pathext);
                *out_pathext = _wcsdup(eq + 1);
            }
        }
    }

    WCHAR *block = (WCHAR *)calloc(total, sizeof(WCHAR));
    if (!block) goto fail;
    size_t pos = 0;
    for (size_t i = 0; i < n; i++) {
        size_t el = wcslen(items[i].entry);
        memcpy(block + pos, items[i].entry, (el + 1) * sizeof(WCHAR));
        pos += el + 1;
    }
    block[pos] = L'\0';

    for (size_t i = 0; i < n; i++) { free(items[i].key); free(items[i].entry); }
    free(items);
    if (w_unset) { for (int32_t i = 0; i < env_unset_count; i++) free(w_unset[i]); free(w_unset); }
    if (w_set_k) { for (int32_t i = 0; i < env_set_count; i++) free(w_set_k[i]); free(w_set_k); }
    if (w_set_v) { for (int32_t i = 0; i < env_set_count; i++) free(w_set_v[i]); free(w_set_v); }
    return block;

fail:
    if (items) {
        for (size_t i = 0; i < n; i++) { free(items[i].key); free(items[i].entry); }
        free(items);
    }
    if (w_unset) { for (int32_t i = 0; i < env_unset_count; i++) free(w_unset[i]); free(w_unset); }
    if (w_set_k) { for (int32_t i = 0; i < env_set_count; i++) free(w_set_k[i]); free(w_set_k); }
    if (w_set_v) { for (int32_t i = 0; i < env_set_count; i++) free(w_set_v[i]); free(w_set_v); }
    free(*out_path); *out_path = NULL;
    free(*out_pathext); *out_pathext = NULL;
    return NULL;
}

static WCHAR *resolve_win_program(const WCHAR *prog, const WCHAR *path_env, const WCHAR *pathext_env) {
    if (!prog || prog[0] == L'\0') return NULL;
    int has_sep = (wcschr(prog, L'\\') != NULL || wcschr(prog, L'/') != NULL || wcschr(prog, L':') != NULL);
    const WCHAR *exts = (pathext_env && pathext_env[0] != L'\0') ? pathext_env : L".COM;.EXE;.BAT;.CMD";

    if (has_sep) {
        if (file_exists_non_dir(prog)) return _wcsdup(prog);
        const WCHAR *cur = exts;
        while (*cur != L'\0') {
            const WCHAR *semi = wcschr(cur, L';');
            size_t el = semi ? (size_t)(semi - cur) : wcslen(cur);
            if (el > 0) {
                WBuf b = {0, 0, 0};
                wbuf_push_str(&b, prog);
                for (size_t i = 0; i < el; i++) wbuf_push(&b, cur[i]);
                if (b.data && file_exists_non_dir(b.data)) return b.data;
                free(b.data);
            }
            if (!semi) break;
            cur = semi + 1;
        }
        return NULL;
    }

    if (!path_env || path_env[0] == L'\0') return NULL;
    const WCHAR *pcur = path_env;
    while (*pcur != L'\0') {
        const WCHAR *psemi = wcschr(pcur, L';');
        size_t dl = psemi ? (size_t)(psemi - pcur) : wcslen(pcur);
        if (dl > 0) {
            WBuf base = {0, 0, 0};
            for (size_t i = 0; i < dl; i++) wbuf_push(&base, pcur[i]);
            if (base.len > 0 && base.data[base.len - 1] != L'\\' && base.data[base.len - 1] != L'/') {
                wbuf_push(&base, L'\\');
            }
            wbuf_push_str(&base, prog);
            if (base.data && file_exists_non_dir(base.data)) return base.data;
            const WCHAR *ecur = exts;
            while (*ecur != L'\0') {
                const WCHAR *esemi = wcschr(ecur, L';');
                size_t el = esemi ? (size_t)(esemi - ecur) : wcslen(ecur);
                if (el > 0) {
                    WBuf cand = {0, 0, 0};
                    wbuf_push_str(&cand, base.data);
                    for (size_t i = 0; i < el; i++) wbuf_push(&cand, ecur[i]);
                    if (cand.data && file_exists_non_dir(cand.data)) {
                        free(base.data);
                        return cand.data;
                    }
                    free(cand.data);
                }
                if (!esemi) break;
                ecur = esemi + 1;
            }
            free(base.data);
        }
        if (!psemi) break;
        pcur = psemi + 1;
    }
    return NULL;
}

static int build_win_cmdline(const WCHAR *resolved_exe, WCHAR **wargv, int32_t argc,
                             WCHAR **out_app, WCHAR **out_cmd) {
    WBuf cmd = {0, 0, 0};
    if (is_batch_script(resolved_exe)) {
        WCHAR sysroot[MAX_PATH];
        DWORD sr = GetEnvironmentVariableW(L"SystemRoot", sysroot, MAX_PATH);
        WBuf cmd_exe = {0, 0, 0};
        if (sr > 0 && sr < MAX_PATH - 32) {
            wbuf_push_str(&cmd_exe, sysroot);
            wbuf_push_str(&cmd_exe, L"\\System32\\cmd.exe");
        } else {
            wbuf_push_str(&cmd_exe, L"cmd.exe");
        }
        *out_app = cmd_exe.data;
        append_win32_arg(&cmd, cmd_exe.data);
        wbuf_push_str(&cmd, L" /d /s /c \"");
        append_cmd_arg(&cmd, resolved_exe);
        for (int32_t i = 1; i < argc; i++) {
            wbuf_push(&cmd, L' ');
            append_cmd_arg(&cmd, wargv[i]);
        }
        wbuf_push(&cmd, L'"');
        *out_cmd = cmd.data;
        return (*out_app != NULL && *out_cmd != NULL);
    }

    *out_app = _wcsdup(resolved_exe);
    append_win32_arg(&cmd, wargv[0]);
    for (int32_t i = 1; i < argc; i++) {
        wbuf_push(&cmd, L' ');
        append_win32_arg(&cmd, wargv[i]);
    }
    *out_cmd = cmd.data;
    return (*out_app != NULL && *out_cmd != NULL);
}

/* Create an overlapped parent-read / inheritable-child-write named pipe pair */
static int create_overlapped_read_pipe(HANDLE *parent_read, HANDLE *child_write,
                                       char *err_buf, int32_t err_cap) {
    LONG seq = InterlockedIncrement(&g_pipe_seq);
    WCHAR name[128];
    swprintf(name, 128, L"\\\\.\\pipe\\pion-proc-%lu-%ld",
             (unsigned long)GetCurrentProcessId(), (long)seq);

    HANDLE rd = CreateNamedPipeW(
        name,
        PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_WAIT,
        1, 65536, 65536, 0, NULL);
    if (rd == INVALID_HANDLE_VALUE) {
        set_win_err(err_buf, err_cap, "CreateNamedPipeW failed", GetLastError());
        return 0;
    }

    SECURITY_ATTRIBUTES sa;
    memset(&sa, 0, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    HANDLE wr = CreateFileW(
        name, GENERIC_WRITE, 0, &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (wr == INVALID_HANDLE_VALUE) {
        DWORD e = GetLastError();
        CloseHandle(rd);
        set_win_err(err_buf, err_cap, "CreateFileW pipe client failed", e);
        return 0;
    }

    *parent_read = rd;
    *child_write = wr;
    return 1;
}

static HANDLE create_kill_job(void) {
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (!job) return NULL;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    memset(&info, 0, sizeof(info));
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info))) {
        CloseHandle(job);
        return NULL;
    }
    return job;
}

void *pion_proc_spawn(
    const char *const *argv, int32_t argc,
    const char *cwd,
    const char *const *env_set_keys, const char *const *env_set_vals, int32_t env_set_count,
    const char *const *env_unset_keys, int32_t env_unset_count,
    int32_t clear_env,
    char *err_buf, int32_t err_cap) {

    ensure_init();
    if (!argv || argc <= 0) {
        set_err(err_buf, err_cap, "argv must not be empty");
        return NULL;
    }

    WCHAR **wargv = (WCHAR **)calloc((size_t)argc, sizeof(WCHAR *));
    if (!wargv) { set_err(err_buf, err_cap, "out of memory"); return NULL; }
    for (int32_t i = 0; i < argc; i++) {
        wargv[i] = utf8_to_wide(argv[i]);
        if (!wargv[i]) {
            for (int32_t j = 0; j < i; j++) free(wargv[j]);
            free(wargv);
            set_err(err_buf, err_cap, "invalid UTF-8 in argv");
            return NULL;
        }
    }

    WCHAR *path_env = NULL, *pathext_env = NULL;
    WCHAR *env_block = build_win_env_block(
        env_set_keys, env_set_vals, env_set_count,
        env_unset_keys, env_unset_count, clear_env,
        &path_env, &pathext_env, err_buf, err_cap);
    if (!env_block) {
        for (int32_t i = 0; i < argc; i++) free(wargv[i]);
        free(wargv);
        return NULL;
    }

    WCHAR *resolved = resolve_win_program(wargv[0], path_env, pathext_env);
    free(path_env);
    free(pathext_env);
    if (!resolved) {
        free(env_block);
        for (int32_t i = 0; i < argc; i++) free(wargv[i]);
        free(wargv);
        snprintf(err_buf, (size_t)err_cap, "executable not found: %s", argv[0]);
        return NULL;
    }

    WCHAR *app_name = NULL, *cmd_line = NULL;
    if (!build_win_cmdline(resolved, wargv, argc, &app_name, &cmd_line)) {
        free(resolved); free(env_block); free(app_name); free(cmd_line);
        for (int32_t i = 0; i < argc; i++) free(wargv[i]);
        free(wargv);
        set_err(err_buf, err_cap, "out of memory building command line");
        return NULL;
    }
    free(resolved);
    for (int32_t i = 0; i < argc; i++) free(wargv[i]);
    free(wargv);

    WCHAR *wcwd = (cwd && cwd[0] != '\0') ? utf8_to_wide(cwd) : NULL;

    SECURITY_ATTRIBUTES sa_inh;
    memset(&sa_inh, 0, sizeof(sa_inh));
    sa_inh.nLength = sizeof(sa_inh);
    sa_inh.bInheritHandle = TRUE;

    HANDLE in_rd = NULL, in_wr = NULL;
    HANDLE out_rd = NULL, out_wr = NULL;
    HANDLE err_rd = NULL, err_wr = NULL;

    if (!CreatePipe(&in_rd, &in_wr, &sa_inh, 0) ||
        !SetHandleInformation(in_wr, HANDLE_FLAG_INHERIT, 0) ||
        !create_overlapped_read_pipe(&out_rd, &out_wr, err_buf, err_cap) ||
        !create_overlapped_read_pipe(&err_rd, &err_wr, err_buf, err_cap)) {
        if (err_buf && err_buf[0] == '\0') set_win_err(err_buf, err_cap, "pipe setup failed", GetLastError());
        if (in_rd) CloseHandle(in_rd); if (in_wr) CloseHandle(in_wr);
        if (out_rd) CloseHandle(out_rd); if (out_wr) CloseHandle(out_wr);
        if (err_rd) CloseHandle(err_rd); if (err_wr) CloseHandle(err_wr);
        free(wcwd); free(app_name); free(cmd_line); free(env_block);
        return NULL;
    }

    STARTUPINFOW si;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_rd;
    si.hStdOutput = out_wr;
    si.hStdError = err_wr;

    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof(pi));

    DWORD flags = CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED | CREATE_NO_WINDOW;
    BOOL ok = CreateProcessW(app_name, cmd_line, NULL, NULL, TRUE, flags, env_block, wcwd, &si, &pi);
    DWORD ce = ok ? 0 : GetLastError();

    CloseHandle(in_rd);
    CloseHandle(out_wr);
    CloseHandle(err_wr);
    free(wcwd); free(app_name); free(cmd_line); free(env_block);

    if (!ok) {
        CloseHandle(in_wr); CloseHandle(out_rd); CloseHandle(err_rd);
        set_win_err(err_buf, err_cap, "CreateProcessW failed", ce);
        return NULL;
    }

    HANDLE job = create_kill_job();
    if (job) {
        if (!AssignProcessToJobObject(job, pi.hProcess)) {
            /* Graceful fallback when parent is in a non-nested job */
            CloseHandle(job);
            job = NULL;
        }
    }
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);

    PionProc *p = (PionProc *)calloc(1, sizeof(PionProc));
    if (!p) {
        if (job) { TerminateJobObject(job, 137); CloseHandle(job); }
        else TerminateProcess(pi.hProcess, 137);
        CloseHandle(pi.hProcess);
        CloseHandle(in_wr); CloseHandle(out_rd); CloseHandle(err_rd);
        set_err(err_buf, err_cap, "out of memory");
        return NULL;
    }
    InitializeCriticalSection(&p->cs);
    p->refcnt = 1;
    p->pid = pi.dwProcessId;
    p->h_proc = pi.hProcess;
    p->h_job = job;
    p->h_stdin = in_wr;
    p->h_stdout = out_rd;
    p->h_stderr = err_rd;
    p->is_pty = 0;

    void *handle = slot_register(p);
    if (!handle) {
        if (job) { TerminateJobObject(job, 137); CloseHandle(job); }
        else TerminateProcess(pi.hProcess, 137);
        CloseHandle(pi.hProcess);
        CloseHandle(in_wr); CloseHandle(out_rd); CloseHandle(err_rd);
        DeleteCriticalSection(&p->cs);
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

    ensure_init();
    if (!argv || argc <= 0) {
        set_err(err_buf, err_cap, "argv must not be empty");
        return NULL;
    }
    if (cols <= 0 || rows <= 0 || cols > 32767 || rows > 32767) {
        set_err(err_buf, err_cap, "pty cols and rows must be > 0");
        return NULL;
    }
    if (!g_create_conpty || !g_resize_conpty || !g_close_conpty) {
        set_err(err_buf, err_cap, "Windows ConPTY API is unavailable on this OS version");
        return NULL;
    }

    WCHAR **wargv = (WCHAR **)calloc((size_t)argc, sizeof(WCHAR *));
    if (!wargv) { set_err(err_buf, err_cap, "out of memory"); return NULL; }
    for (int32_t i = 0; i < argc; i++) {
        wargv[i] = utf8_to_wide(argv[i]);
        if (!wargv[i]) {
            for (int32_t j = 0; j < i; j++) free(wargv[j]);
            free(wargv);
            set_err(err_buf, err_cap, "invalid UTF-8 in argv");
            return NULL;
        }
    }

    WCHAR *path_env = NULL, *pathext_env = NULL;
    WCHAR *env_block = build_win_env_block(
        env_set_keys, env_set_vals, env_set_count,
        env_unset_keys, env_unset_count, clear_env,
        &path_env, &pathext_env, err_buf, err_cap);
    if (!env_block) {
        for (int32_t i = 0; i < argc; i++) free(wargv[i]);
        free(wargv);
        return NULL;
    }

    WCHAR *resolved = resolve_win_program(wargv[0], path_env, pathext_env);
    free(path_env);
    free(pathext_env);
    if (!resolved) {
        free(env_block);
        for (int32_t i = 0; i < argc; i++) free(wargv[i]);
        free(wargv);
        snprintf(err_buf, (size_t)err_cap, "executable not found: %s", argv[0]);
        return NULL;
    }

    WCHAR *app_name = NULL, *cmd_line = NULL;
    if (!build_win_cmdline(resolved, wargv, argc, &app_name, &cmd_line)) {
        free(resolved); free(env_block); free(app_name); free(cmd_line);
        for (int32_t i = 0; i < argc; i++) free(wargv[i]);
        free(wargv);
        set_err(err_buf, err_cap, "out of memory building command line");
        return NULL;
    }
    free(resolved);
    for (int32_t i = 0; i < argc; i++) free(wargv[i]);
    free(wargv);

    WCHAR *wcwd = (cwd && cwd[0] != '\0') ? utf8_to_wide(cwd) : NULL;

    HANDLE pty_in_rd = NULL, pty_in_wr = NULL;
    HANDLE pty_out_rd = NULL, pty_out_wr = NULL;
    if (!CreatePipe(&pty_in_rd, &pty_in_wr, NULL, 0) ||
        !create_overlapped_read_pipe(&pty_out_rd, &pty_out_wr, err_buf, err_cap)) {
        if (err_buf && err_buf[0] == '\0') set_win_err(err_buf, err_cap, "conpty pipe failed", GetLastError());
        if (pty_in_rd) CloseHandle(pty_in_rd); if (pty_in_wr) CloseHandle(pty_in_wr);
        if (pty_out_rd) CloseHandle(pty_out_rd); if (pty_out_wr) CloseHandle(pty_out_wr);
        free(wcwd); free(app_name); free(cmd_line); free(env_block);
        return NULL;
    }

    COORD size;
    size.X = (SHORT)cols;
    size.Y = (SHORT)rows;
    PionHPCON hpc = NULL;
    HRESULT hr = g_create_conpty(size, pty_in_rd, pty_out_wr, 0, &hpc);
    CloseHandle(pty_in_rd);
    CloseHandle(pty_out_wr);
    if (FAILED(hr) || !hpc) {
        CloseHandle(pty_in_wr); CloseHandle(pty_out_rd);
        free(wcwd); free(app_name); free(cmd_line); free(env_block);
        snprintf(err_buf, (size_t)err_cap, "CreatePseudoConsole failed (hr=0x%08lx)", (unsigned long)hr);
        return NULL;
    }

    SIZE_T attr_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    LPPROC_THREAD_ATTRIBUTE_LIST attr_list = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attr_size);
    if (!attr_list || !InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) ||
        !UpdateProcThreadAttribute(attr_list, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   hpc, sizeof(hpc), NULL, NULL)) {
        DWORD e = GetLastError();
        if (attr_list) { DeleteProcThreadAttributeList(attr_list); free(attr_list); }
        g_close_conpty(hpc);
        CloseHandle(pty_in_wr); CloseHandle(pty_out_rd);
        free(wcwd); free(app_name); free(cmd_line); free(env_block);
        set_win_err(err_buf, err_cap, "ConPTY attribute list failed", e);
        return NULL;
    }

    STARTUPINFOEXW siex;
    memset(&siex, 0, sizeof(siex));
    siex.StartupInfo.cb = sizeof(siex);
    siex.lpAttributeList = attr_list;

    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof(pi));

    DWORD flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED;
    BOOL ok = CreateProcessW(app_name, cmd_line, NULL, NULL, FALSE, flags,
                             env_block, wcwd, &siex.StartupInfo, &pi);
    DWORD ce = ok ? 0 : GetLastError();

    DeleteProcThreadAttributeList(attr_list);
    free(attr_list);
    free(wcwd); free(app_name); free(cmd_line); free(env_block);

    if (!ok) {
        g_close_conpty(hpc);
        CloseHandle(pty_in_wr); CloseHandle(pty_out_rd);
        set_win_err(err_buf, err_cap, "CreateProcessW (ConPTY) failed", ce);
        return NULL;
    }

    HANDLE job = create_kill_job();
    if (job) {
        if (!AssignProcessToJobObject(job, pi.hProcess)) {
            CloseHandle(job);
            job = NULL;
        }
    }
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);

    PionProc *p = (PionProc *)calloc(1, sizeof(PionProc));
    if (!p) {
        if (job) { TerminateJobObject(job, 137); CloseHandle(job); }
        else TerminateProcess(pi.hProcess, 137);
        CloseHandle(pi.hProcess);
        g_close_conpty(hpc);
        CloseHandle(pty_in_wr); CloseHandle(pty_out_rd);
        set_err(err_buf, err_cap, "out of memory");
        return NULL;
    }
    InitializeCriticalSection(&p->cs);
    p->refcnt = 1;
    p->pid = pi.dwProcessId;
    p->h_proc = pi.hProcess;
    p->h_job = job;
    p->h_stdin = pty_in_wr;
    p->h_stdout = pty_out_rd;
    p->h_stderr = NULL;
    p->h_pty = hpc;
    p->is_pty = 1;

    void *handle = slot_register(p);
    if (!handle) {
        if (job) { TerminateJobObject(job, 137); CloseHandle(job); }
        else TerminateProcess(pi.hProcess, 137);
        CloseHandle(pi.hProcess);
        g_close_conpty(hpc);
        CloseHandle(pty_in_wr); CloseHandle(pty_out_rd);
        DeleteCriticalSection(&p->cs);
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

    EnterCriticalSection(&p->cs);
    HANDLE fh = (p->is_pty || stream == 0) ? p->h_stdout : p->h_stderr;
    LeaveCriticalSection(&p->cs);

    if (!fh) {
        proc_release(p);
        return 0;
    }

    HANDLE ev = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ev) {
        set_win_err(err_buf, err_cap, "CreateEventW failed", GetLastError());
        proc_release(p);
        return -2;
    }

    OVERLAPPED ov;
    memset(&ov, 0, sizeof(ov));
    ov.hEvent = ev;

    DWORD nread = 0;
    BOOL ok = ReadFile(fh, buf, (DWORD)max_bytes, &nread, &ov);
    if (ok) {
        CloseHandle(ev);
        proc_release(p);
        return (int32_t)nread;
    }

    DWORD err = GetLastError();
    if (err == ERROR_BROKEN_PIPE || err == ERROR_HANDLE_EOF) {
        CloseHandle(ev);
        proc_release(p);
        return 0; /* EOF */
    }
    if (err != ERROR_IO_PENDING) {
        CloseHandle(ev);
        set_win_err(err_buf, err_cap, "ReadFile failed", err);
        proc_release(p);
        return -2;
    }

    DWORD wait_ms = (timeout_ms < 0) ? INFINITE : (DWORD)timeout_ms;
    DWORD wr = WaitForSingleObject(ev, wait_ms);
    if (wr == WAIT_TIMEOUT) {
        CancelIoEx(fh, &ov);
        if (GetOverlappedResult(fh, &ov, &nread, TRUE)) {
            CloseHandle(ev);
            proc_release(p);
            return (int32_t)nread;
        }
        DWORD ce = GetLastError();
        CloseHandle(ev);
        proc_release(p);
        if (ce == ERROR_BROKEN_PIPE || ce == ERROR_HANDLE_EOF) return 0;
        return -1; /* Timeout */
    }

    if (GetOverlappedResult(fh, &ov, &nread, FALSE)) {
        CloseHandle(ev);
        proc_release(p);
        return (int32_t)nread;
    }
    DWORD ge = GetLastError();
    CloseHandle(ev);
    proc_release(p);
    if (ge == ERROR_BROKEN_PIPE || ge == ERROR_HANDLE_EOF) return 0;
    set_win_err(err_buf, err_cap, "GetOverlappedResult failed", ge);
    return -2;
}

int32_t pion_proc_write(void *h, const uint8_t *buf, int32_t len,
                        char *err_buf, int32_t err_cap) {
    if (len < 0) { set_err(err_buf, err_cap, "negative write length"); return -1; }
    if (len == 0) return 0;
    if (!buf) { set_err(err_buf, err_cap, "null write buffer"); return -1; }

    PionProc *p = slot_acquire(h);
    if (!p) { set_err(err_buf, err_cap, "process handle is closed"); return -1; }

    EnterCriticalSection(&p->cs);
    HANDLE fh = p->h_stdin;
    LeaveCriticalSection(&p->cs);

    if (!fh) {
        set_err(err_buf, err_cap, "stdin is closed");
        proc_release(p);
        return -1;
    }
    DWORD written = 0;
    if (!WriteFile(fh, buf, (DWORD)len, &written, NULL)) {
        set_win_err(err_buf, err_cap, "WriteFile failed", GetLastError());
        proc_release(p);
        return -1;
    }
    proc_release(p);
    return (int32_t)written;
}

void pion_proc_close_stdin(void *h) {
    PionProc *p = slot_acquire(h);
    if (!p) return;
    EnterCriticalSection(&p->cs);
    HANDLE fh = p->is_pty ? NULL : p->h_stdin;
    if (!p->is_pty) p->h_stdin = NULL;
    LeaveCriticalSection(&p->cs);
    if (fh) CloseHandle(fh);
    proc_release(p);
}

int32_t pion_proc_pty_resize(void *h, int32_t cols, int32_t rows,
                             char *err_buf, int32_t err_cap) {
    if (cols <= 0 || rows <= 0 || cols > 32767 || rows > 32767) {
        set_err(err_buf, err_cap, "pty cols and rows must be > 0");
        return -1;
    }
    PionProc *p = slot_acquire(h);
    if (!p) { set_err(err_buf, err_cap, "pty handle is closed"); return -1; }

    EnterCriticalSection(&p->cs);
    PionHPCON hpc = p->is_pty ? p->h_pty : NULL;
    LeaveCriticalSection(&p->cs);

    if (!hpc || !g_resize_conpty) {
        set_err(err_buf, err_cap, "pty is closed");
        proc_release(p);
        return -1;
    }
    COORD sz;
    sz.X = (SHORT)cols;
    sz.Y = (SHORT)rows;
    HRESULT hr = g_resize_conpty(hpc, sz);
    proc_release(p);
    if (FAILED(hr)) {
        snprintf(err_buf, (size_t)err_cap, "ResizePseudoConsole failed (hr=0x%08lx)", (unsigned long)hr);
        return -1;
    }
    return 0;
}

int32_t pion_proc_wait(void *h, int32_t block, int32_t *out_kind, int32_t *out_code,
                       char *err_buf, int32_t err_cap) {
    PionProc *p = slot_acquire(h);
    if (!p) { set_err(err_buf, err_cap, "process handle is closed"); return -1; }

    EnterCriticalSection(&p->cs);
    if (p->reaped) {
        if (out_kind) *out_kind = p->exit_kind;
        if (out_code) *out_code = p->exit_code;
        LeaveCriticalSection(&p->cs);
        proc_release(p);
        return 1;
    }
    HANDLE h_proc = p->h_proc;
    LeaveCriticalSection(&p->cs);

    DWORD wr = WaitForSingleObject(h_proc, block ? INFINITE : 0);
    if (wr == WAIT_TIMEOUT) {
        proc_release(p);
        return 0;
    }
    if (wr != WAIT_OBJECT_0) {
        set_win_err(err_buf, err_cap, "WaitForSingleObject failed", GetLastError());
        proc_release(p);
        return -1;
    }
    DWORD code = 0;
    if (!GetExitCodeProcess(h_proc, &code)) {
        set_win_err(err_buf, err_cap, "GetExitCodeProcess failed", GetLastError());
        proc_release(p);
        return -1;
    }
    EnterCriticalSection(&p->cs);
    p->reaped = 1;
    p->exit_kind = 0;
    p->exit_code = (int)code;
    if (out_kind) *out_kind = p->exit_kind;
    if (out_code) *out_code = p->exit_code;
    LeaveCriticalSection(&p->cs);
    proc_release(p);
    return 1;
}

int32_t pion_proc_signal_tree(void *h, int32_t force, char *err_buf, int32_t err_cap) {
    (void)force;
    PionProc *p = slot_acquire(h);
    if (!p) return 0;

    EnterCriticalSection(&p->cs);
    int reaped = p->reaped;
    HANDLE h_job = p->h_job;
    HANDLE h_proc = p->h_proc;
    LeaveCriticalSection(&p->cs);

    if (reaped) {
        proc_release(p);
        return 0;
    }
    BOOL ok = h_job ? TerminateJobObject(h_job, 137) : TerminateProcess(h_proc, 137);
    if (!ok) {
        DWORD e = GetLastError();
        if (e != ERROR_ACCESS_DENIED) {
            set_win_err(err_buf, err_cap, "terminate process tree failed", e);
            proc_release(p);
            return -1;
        }
    }
    proc_release(p);
    return 0;
}

void pion_proc_close(void *h) {
    ensure_init();
    uintptr_t raw = (uintptr_t)h;
    if (raw == 0) return;
    uint32_t idx1 = (uint32_t)(raw & 0xFFFFu);
    uint32_t gen = (uint32_t)((uint64_t)raw >> 16);
    if (idx1 == 0 || idx1 > PION_PROC_MAX_SLOTS) return;
    uint32_t idx = idx1 - 1u;

    EnterCriticalSection(&g_table_cs);
    PionProc *p = NULL;
    if (g_slots[idx].proc != NULL && g_slots[idx].gen == gen) {
        p = g_slots[idx].proc;
        g_slots[idx].proc = NULL;
        g_slots[idx].gen++;
        if (g_slots[idx].gen == 0) g_slots[idx].gen = 1;
    }
    LeaveCriticalSection(&g_table_cs);
    if (!p) return;

    EnterCriticalSection(&p->cs);
    HANDLE h_in = p->h_stdin; p->h_stdin = NULL;
    HANDLE h_out = p->h_stdout; p->h_stdout = NULL;
    HANDLE h_err = p->h_stderr; p->h_stderr = NULL;
    HANDLE h_job = p->h_job; p->h_job = NULL;
    HANDLE h_proc = p->h_proc; p->h_proc = NULL;
    PionHPCON h_pty = p->h_pty; p->h_pty = NULL;
    LeaveCriticalSection(&p->cs);

    if (h_pty && g_close_conpty) g_close_conpty(h_pty);
    if (h_in) CloseHandle(h_in);
    if (h_out) CloseHandle(h_out);
    if (h_err) CloseHandle(h_err);
    if (h_job) CloseHandle(h_job);
    if (h_proc) CloseHandle(h_proc);

    proc_release(p);
}

int32_t pion_proc_is_windows(void) {
    return 1;
}

#endif /* _WIN32 */
