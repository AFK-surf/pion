#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
PIONC="${PIONC:-$ROOT_DIR/out/pionc2}"
CC="${CC:-cc}"

if [ ! -x "$PIONC" ]; then
    echo "FAIL: pionc binary not found at $PIONC" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Pion E2E overflow tests (must panic cleanly via abort/SIGABRT, never SIGSEGV 139, stderr has "exceeds maximum")
cat > "$TMP_DIR/overflow.pion" <<'EOF'
pub fn main(w: World) -> Int {
  let args = args_get(w)
  let mode = if args.length() > 1 { args[1] } else { "" }
  if mode == "replace" {
    let mut a = "a"
    let mut i = 0
    while i < 16 {
      a = a + a
      i = i + 1
    }
    let b = a + "b"
    let r = a.replace("a", b)
    io_println(w, r.length().to_string())
  } else if mode == "join" {
    let mut s = "x"
    let mut i = 0
    while i < 16 {
      s = s + s
      i = i + 1
    }
    let arr: Array[String] = Array::with_capacity(65537)
    let mut j = 0
    while j < 65537 {
      arr.push(s)
      j = j + 1
    }
    let r = arr.join("")
    io_println(w, r.length().to_string())
  } else if mode == "strbuf_cap" {
    let sb = StringBuilder::with_capacity(2147483647)
    io_println(w, sb.to_string())
  } else if mode == "bytes_new" {
    let b = Bytes::new(2147483647)
    io_println(w, b.length().to_string())
  } else if mode == "arr_cap" {
    let a: Array[Int] = Array::with_capacity(2147483647)
    io_println(w, a.length().to_string())
  } else {
    io_println(w, "unknown")
  }
  0
}
EOF

PION_CACHE_DIR="$TMP_DIR/cas" "$PIONC" build --release -o "$TMP_DIR/overflow" "$TMP_DIR/overflow.pion"

for mode in replace join strbuf_cap bytes_new arr_cap; do
    set +e
    "$TMP_DIR/overflow" "$mode" > "$TMP_DIR/$mode.out" 2> "$TMP_DIR/$mode.err"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 139 ]; then
        echo "FAIL: pion e2e mode=$mode unexpected rc=$rc (stderr: $(cat "$TMP_DIR/$mode.err"))" >&2
        exit 1
    fi
    if ! grep -q "exceeds maximum" "$TMP_DIR/$mode.err"; then
        echo "FAIL: pion e2e mode=$mode stderr missing 'exceeds maximum': $(cat "$TMP_DIR/$mode.err")" >&2
        exit 1
    fi
    echo "p54b pion e2e $mode: clean panic rc=$rc ($(tr -d '\n' < "$TMP_DIR/$mode.err"))"
done

# 2. C whitebox fork() assertions linked directly against out/libpionrt.a
cat > "$TMP_DIR/whitebox.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>
#include "pion_rt.h"

#define PION_MAX_CONTAINER_LEN ((int64_t)0x7FFFFFFF - 16)

static void expect_clean_panic(const char *name, void (*fn)(void)) {
    int pfd[2];
    if (pipe(pfd) != 0) {
        perror("pipe");
        exit(1);
    }
    fflush(stdout);
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        exit(1);
    }
    if (pid == 0) {
        close(pfd[0]);
        dup2(pfd[1], STDERR_FILENO);
        close(pfd[1]);
        fn();
        _exit(0);
    }
    close(pfd[1]);
    char errbuf[512];
    size_t off = 0;
    while (off + 1 < sizeof(errbuf)) {
        ssize_t n = read(pfd[0], errbuf + off, sizeof(errbuf) - 1 - off);
        if (n <= 0) break;
        off += (size_t)n;
    }
    close(pfd[0]);
    errbuf[off] = '\0';

    int st = 0;
    if (waitpid(pid, &st, 0) < 0) {
        perror("waitpid");
        exit(1);
    }
    int ok_status = (WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT) ||
                    (WIFEXITED(st) && WEXITSTATUS(st) != 0);
    if (!ok_status || (WIFSIGNALED(st) && WTERMSIG(st) == SIGSEGV)) {
        fprintf(stderr, "FAIL %s: bad status=0x%x err=%s\n", name, st, errbuf);
        exit(1);
    }
    if (!strstr(errbuf, "exceeds maximum")) {
        fprintf(stderr, "FAIL %s: stderr missing 'exceeds maximum': %s\n", name, errbuf);
        exit(1);
    }
    printf("p54b whitebox %s: clean panic (OK)\n", name);
}

static void case_strbuf_push_overflow(void) {
    PionStrBuf sb = { PION_MAX_CONTAINER_LEN - 4, PION_MAX_CONTAINER_LEN - 4, NULL };
    void *s = pion_str_from_cstr("123456", 6);
    pion_strbuf_push_str(&sb, s);
}

static void case_strbuf_to_str_trunc(void) {
    PionStrBuf sb = { (int64_t)0x100000005LL, (int64_t)0x100000005LL, NULL };
    (void)pion_strbuf_to_str(&sb);
}

static void case_str_concat_overflow(void) {
    struct {
        int64_t len;
        char data[8];
    } fake_a = { (int64_t)0x7FFFFFF0LL, "a" };
    struct {
        int64_t len;
        char data[8];
    } fake_b = { (int64_t)0x7FFFFFF0LL, "b" };
    (void)pion_str_concat(&fake_a, &fake_b);
}

static void case_str_from_cstr_trunc(void) {
    (void)pion_str_from_cstr("x", (int64_t)0x100000005LL);
}

int main(void) {
    expect_clean_panic("strbuf_push_overflow", case_strbuf_push_overflow);
    expect_clean_panic("strbuf_to_str_trunc", case_strbuf_to_str_trunc);
    expect_clean_panic("str_concat_overflow", case_str_concat_overflow);
    expect_clean_panic("str_from_cstr_trunc", case_str_from_cstr_trunc);
    return 0;
}
EOF

"$CC" -std=c11 -O2 -I"$ROOT_DIR/runtime" "$TMP_DIR/whitebox.c" "$ROOT_DIR/out/libpionrt.a" -lm -lpthread -o "$TMP_DIR/whitebox"
"$TMP_DIR/whitebox"

echo "PASS: p54b_container_overflow"
