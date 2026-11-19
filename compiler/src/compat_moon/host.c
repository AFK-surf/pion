#include "moonbit.h"
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static char *bytes_to_cstr(moonbit_bytes_t b) {
  int32_t len = Moonbit_array_length(b);
  char *s = (char *)malloc((size_t)len + 1);
  if (!s) return NULL;
  if (len > 0) memcpy(s, b, (size_t)len);
  s[len] = '\0';
  return s;
}

static moonbit_bytes_t cbuf_to_bytes(const char *buf, size_t len) {
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)len, 0);
  if (len > 0) memcpy(out, buf, len);
  return out;
}

int32_t m2_host_file_exists(moonbit_bytes_t path_b) {
  char *path = bytes_to_cstr(path_b);
  if (!path) return 0;
  struct stat st;
  int ok = (stat(path, &st) == 0);
  free(path);
  return ok ? 1 : 0;
}

int32_t m2_host_is_dir(moonbit_bytes_t path_b) {
  char *path = bytes_to_cstr(path_b);
  if (!path) return 0;
  struct stat st;
  int ok = (stat(path, &st) == 0 && S_ISDIR(st.st_mode));
  free(path);
  return ok ? 1 : 0;
}

moonbit_bytes_t m2_host_read_file(moonbit_bytes_t path_b) {
  char *path = bytes_to_cstr(path_b);
  if (!path) return moonbit_make_bytes(0, 0);
  FILE *f = fopen(path, "rb");
  free(path);
  if (!f) return moonbit_make_bytes(0, 0);
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return moonbit_make_bytes(0, 0);
  }
  long sz = ftell(f);
  if (sz < 0) sz = 0;
  rewind(f);
  char *buf = (char *)malloc((size_t)sz + 1);
  if (!buf) {
    fclose(f);
    return moonbit_make_bytes(0, 0);
  }
  size_t n = fread(buf, 1, (size_t)sz, f);
  fclose(f);
  moonbit_bytes_t out = cbuf_to_bytes(buf, n);
  free(buf);
  return out;
}

static int ends_with(const char *s, const char *suf) {
  size_t sl = strlen(s);
  size_t sufl = strlen(suf);
  if (sl < sufl) return 0;
  return strcmp(s + sl - sufl, suf) == 0;
}

static int cmp_cstr_ptr(const void *a, const void *b) {
  const char *sa = *(const char *const *)a;
  const char *sb = *(const char *const *)b;
  return strcmp(sa, sb);
}

moonbit_bytes_t m2_host_list_sources(moonbit_bytes_t dir_b) {
  char *dir = bytes_to_cstr(dir_b);
  if (!dir) return moonbit_make_bytes(0, 0);
  DIR *d = opendir(dir);
  if (!d) {
    free(dir);
    return moonbit_make_bytes(0, 0);
  }
  size_t cap = 32;
  size_t cnt = 0;
  char **items = (char **)malloc(cap * sizeof(char *));
  struct dirent *ent;
  while ((ent = readdir(d)) != NULL) {
    const char *name = ent->d_name;
    if (name[0] == '.') continue;
    int is_src = ends_with(name, ".m2") || ends_with(name, ".mbt");
    int is_test = ends_with(name, "_test.m2") || ends_with(name, "_test.mbt");
    if (!is_src || is_test) continue;
    size_t dlen = strlen(dir);
    size_t nlen = strlen(name);
    int need_slash = (dlen > 0 && dir[dlen - 1] != '/');
    char *full = (char *)malloc(dlen + (size_t)need_slash + nlen + 1);
    memcpy(full, dir, dlen);
    size_t off = dlen;
    if (need_slash) full[off++] = '/';
    memcpy(full + off, name, nlen + 1);
    if (cnt == cap) {
      cap *= 2;
      items = (char **)realloc(items, cap * sizeof(char *));
    }
    items[cnt++] = full;
  }
  closedir(d);
  free(dir);
  if (cnt > 1) {
    qsort(items, cnt, sizeof(char *), cmp_cstr_ptr);
  }
  size_t total = 0;
  for (size_t i = 0; i < cnt; i++) {
    total += strlen(items[i]) + 1;
  }
  char *joined = (char *)malloc(total + 1);
  size_t pos = 0;
  for (size_t i = 0; i < cnt; i++) {
    size_t l = strlen(items[i]);
    memcpy(joined + pos, items[i], l);
    pos += l;
    joined[pos++] = '\n';
    free(items[i]);
  }
  free(items);
  moonbit_bytes_t out = cbuf_to_bytes(joined, pos);
  free(joined);
  return out;
}

void m2_host_write_stdout(moonbit_bytes_t data) {
  int32_t len = Moonbit_array_length(data);
  if (len > 0) fwrite(data, 1, (size_t)len, stdout);
  fflush(stdout);
}

void m2_host_write_stderr(moonbit_bytes_t data) {
  int32_t len = Moonbit_array_length(data);
  if (len > 0) fwrite(data, 1, (size_t)len, stderr);
  fflush(stderr);
}

void m2_host_exit(int32_t code) {
  exit(code);
}
