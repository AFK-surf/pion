#include "moonbit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

moonbit_bytes_t m2_v2_read_file(moonbit_bytes_t path_b) {
  int32_t plen = Moonbit_array_length(path_b);
  char *path = (char *)malloc((size_t)plen + 1);
  if (!path) return moonbit_make_bytes(0, 0);
  if (plen > 0) memcpy(path, path_b, (size_t)plen);
  path[plen] = '\0';
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
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)sz, 0);
  if (sz > 0) {
    size_t n = fread(out, 1, (size_t)sz, f);
    (void)n;
  }
  fclose(f);
  return out;
}
