// Copies zlibVersion()'s `const char*` into MoonBit-owned Bytes.
#include <string.h>
#include <zlib.h>
#include "moonbit.h"

moonbit_bytes_t ae_zlib_version(void) {
  const char *v = zlibVersion();
  int32_t n = (int32_t)strlen(v);
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  memcpy(out, v, (size_t)n);
  return out;
}
