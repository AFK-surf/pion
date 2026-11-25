/* Calls mix.ssa's $mix over 8 x 8 x 8 single-precision inputs (quiet NaNs
 * with different payloads and signs, a signalling NaN, 1, -2.5, +Inf), once
 * with all exceptions masked (packed arm) and once with only the
 * divide-by-zero trap enabled (scalar arm; fpmode.c), and requires the same
 * result bits and stored Doubles from both. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

float mix(double *p, float a, float unused, float b, float c, double d0, double d1,
          double d2, double d3);
int32_t p127_fp_scalar_mode(int32_t on);

static uint32_t fbits(float f) {
  uint32_t u;
  memcpy(&u, &f, 4);
  return u;
}

int main(void) {
  static const uint32_t in[] = {0x7fc00001u, 0x7fc00003u, 0x7fc00004u, 0xffc00005u,
                                0x3f800000u, 0xc0200000u, 0x7f800000u, 0x7f800badu};
  float f[8];
  memcpy(f, in, sizeof f);
  int rows = 0, nan = 0;
  for (int i = 0; i < 8; i++)
    for (int j = 0; j < 8; j++)
      for (int k = 0; k < 8; k++) {
        double pv[2], ps[2];
        float rv = mix(pv, f[i], f[(i + j + k) % 8], f[j], f[k], 1.0, 2.0, 3.0, 4.0);
        if (!p127_fp_scalar_mode(1)) {
          fprintf(stderr, "FAIL: p127 mixdrv: cannot enable the divide-by-zero trap\n");
          return 1;
        }
        float rs = mix(ps, f[i], f[(i + j + k) % 8], f[j], f[k], 1.0, 2.0, 3.0, 4.0);
        if (!p127_fp_scalar_mode(0)) {
          fprintf(stderr, "FAIL: p127 mixdrv: cannot restore the FP mode\n");
          return 1;
        }
        if (fbits(rv) != fbits(rs) || memcmp(pv, ps, sizeof pv) != 0 || pv[0] != 5.0 ||
            pv[1] != 5.0) {
          fprintf(stderr,
                  "FAIL: p127 mixdrv a=%08x b=%08x c=%08x: packed arm %08x, scalar arm %08x\n",
                  in[i], in[j], in[k], fbits(rv), fbits(rs));
          return 1;
        }
        nan += rv != rv;
        rows++;
      }
  printf("%d rows, %d NaN results, packed arm == scalar arm\n", rows, nan);
  return 0;
}
