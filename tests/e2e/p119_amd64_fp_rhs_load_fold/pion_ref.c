/* P119: C reference for p119.pion (same values, same operations, same lines). */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static const uint64_t DB[13] = {
  0x0000000000000000ULL, 0x8000000000000000ULL, 0x0000000000000001ULL, 0x800fffffffffffffULL,
  0x0010000000000000ULL, 0x3ff0000000000000ULL, 0xbff8000000000000ULL, 0x3fd5555555555555ULL,
  0x400921fb54442d18ULL, 0x7fefffffffffffffULL, 0x7ff0000000000000ULL, 0xfff0000000000000ULL,
  0x7ff8000000000123ULL,
};
static const uint32_t FB[13] = {
  0x00000000, 0x80000000, 0x00000001, 0x807fffff, 0x00800000, 0x3f800000, 0xbfc00000,
  0x3eaaaaab, 0x40490fdb, 0x7f7fffff, 0x7f800000, 0xff800000, 0x7fc00123,
};

static volatile double vd[13];
static volatile float vf[13];

static void dres(double x) {
  if (x != x) {
    fputs("nan", stdout);
  } else {
    int64_t b;
    memcpy(&b, &x, 8);
    printf("%" PRId64, b);
  }
}

static void fres(float x) {
  if (x != x) {
    fputs("nan", stdout);
  } else {
    int32_t b;
    memcpy(&b, &x, 4);
    printf("%" PRId32, b);
  }
}

int main(void) {
  for (int i = 0; i < 13; i++) {
    double d;
    float f;
    memcpy(&d, &DB[i], 8);
    memcpy(&f, &FB[i], 4);
    vd[i] = d;
    vf[i] = f;
  }
  for (int i = 0; i < 13; i++) {
    printf("subd %d", i);
    for (int j = 0; j < 13; j++) { putchar(' '); dres(vd[i] - vd[j]); }
    printf("\ndivd %d", i);
    for (int j = 0; j < 13; j++) { putchar(' '); dres(vd[i] / vd[j]); }
    printf("\nsubs %d", i);
    for (int j = 0; j < 13; j++) { putchar(' '); fres(vf[i] - vf[j]); }
    printf("\ndivs %d", i);
    for (int j = 0; j < 13; j++) { putchar(' '); fres(vf[i] / vf[j]); }
    putchar('\n');
  }
  double bx[6], by[6];
  float bm[6];
  for (int k = 0; k < 6; k++) {
    bx[k] = vd[k + 3];
    by[k] = vd[(k * 5 + 1) % 12];
    bm[k] = vf[(k * 7 + 2) % 12];
  }
  fputs("pairs", stdout);
  for (int i = 0; i < 6; i++)
    for (int j = 0; j < 6; j++) {
      volatile double dx = bx[i] - bx[j], dy = by[i] / by[j];
      volatile float dm = bm[i] - bm[j];
      putchar(' '); dres(dx); putchar(','); dres(dy); putchar(','); fres(dm);
    }
  putchar('\n');
  return 0;
}
