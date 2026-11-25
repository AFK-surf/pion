/* P113: bit-exact checks of fixture.ssa against C (linked once with the
 * direct `qbe --obj` ELF object and once with the `qbe` + `as` object).
 * Prints one `<group> <ok>/<total>` line per group; exit 1 on a mismatch. */
#include <float.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

double second_d(double, double);
float second_s(float, float);
double swap_sel(double, double, int32_t);
void mem_copy(const void *, void *);
double neg_d(double, double);
float neg_s(float, float);
double div_ab(double, double);
double div_ba(double, double);
double div_xx(double);
float div_ab_s(float, float);
float div_ba_s(float, float);
float div_xx_s(float);
double iso_wd(int32_t);
double iso_ld(int64_t);
float iso_ws(int32_t);
float iso_ls(int64_t);
void grouped(void *, int32_t, int32_t, int64_t, int64_t);
void pressure_grouped(void *, const int64_t *);
void pressure_iso(void *, const int64_t *);
void pressure_iso_s(void *, const int64_t *);
double slot_gld(int64_t);
float slot_gls(int64_t);
double slot_gwd(int32_t);
float slot_gws(int32_t);
double slot_ild(int64_t);
float slot_ils(int64_t);
double slot_iwd(int32_t);
float slot_iws(int32_t);


static uint64_t db(double x) { uint64_t u; memcpy(&u, &x, 8); return u; }
static uint32_t fb(float x) { uint32_t u; memcpy(&u, &x, 4); return u; }
static double dv(uint64_t u) { double x; memcpy(&x, &u, 8); return x; }
static float fv(uint32_t u) { float x; memcpy(&x, &u, 4); return x; }

static int fails;
static int ok, total;

static void group_end(const char *name) {
  printf("%s %d/%d\n", name, ok, total);
  if (total == 0 || ok != total)
    fails++;
  ok = total = 0;
}

/* Operation results: exact bits, or both NaN (payload not portable). */
static void cd(const char *what, double got, double want) {
  total++;
  if (db(got) == db(want) || (isnan(got) && isnan(want))) {
    ok++;
    return;
  }
  printf("  MISMATCH %s: got %016" PRIx64 " want %016" PRIx64 "\n", what, db(got), db(want));
}

static void cf(const char *what, float got, float want) {
  total++;
  if (fb(got) == fb(want) || (isnan(got) && isnan(want))) {
    ok++;
    return;
  }
  printf("  MISMATCH %s: got %08" PRIx32 " want %08" PRIx32 "\n", what, fb(got), fb(want));
}

/* Copies are bit moves: NaN payloads included. */
static void bd(const char *what, double got, double want) {
  total++;
  if (db(got) == db(want)) {
    ok++;
    return;
  }
  printf("  MISMATCH %s: got %016" PRIx64 " want %016" PRIx64 "\n", what, db(got), db(want));
}

static void bf(const char *what, float got, float want) {
  total++;
  if (fb(got) == fb(want)) {
    ok++;
    return;
  }
  printf("  MISMATCH %s: got %08" PRIx32 " want %08" PRIx32 "\n", what, fb(got), fb(want));
}

static const uint64_t DS[] = {
  0x0000000000000000ull, 0x8000000000000000ull, 0x0000000000000001ull,
  0x800fffffffffffffull, 0x3ff0000000000000ull, 0xc004000000000000ull,
  0x7fefffffffffffffull, 0x7ff0000000000000ull, 0xfff0000000000000ull,
  0x7ff8000000000123ull, 0xfff4000000000001ull, 0x4008000000000000ull,
};
static const uint32_t FS[] = {
  0x00000000u, 0x80000000u, 0x00000001u, 0x807fffffu, 0x3f800000u, 0xc0200000u,
  0x7f7fffffu, 0x7f800000u, 0xff800000u, 0x7fc00123u, 0xffa00001u, 0x40400000u,
};
#define N(a) (sizeof(a) / sizeof((a)[0]))

static const int32_t WS[] = {INT32_MIN, INT32_MAX, -1, 0, 1, 16777217, -16777217, 123456789};
static const int64_t LS[] = {
  INT64_MIN, INT64_MAX, -1, 0, 1, 4294967297LL, -4294967297LL, 9007199254740993LL,
  -9007199254740993LL, 2147483648LL, -2147483649LL, 16777217LL, INT32_MIN, INT32_MAX,
  4294967296LL, -4294967296LL,
};

int main(void) {
  volatile double vd;
  volatile float vf;

  for (unsigned i = 0; i < N(DS); i++)
    for (unsigned j = 0; j < N(DS); j++) {
      double a = dv(DS[i]), b = dv(DS[j]);
      bd("second_d", second_d(a, b), b);
      cd("swap_sel0", swap_sel(a, b, 0), (vd = a - b, vd));
      cd("swap_sel1", swap_sel(a, b, 1), (vd = b - a, vd));
      bd("neg_d", neg_d(a, b), dv(DS[j] ^ 0x8000000000000000ull));
      cd("div_ab", div_ab(a, b), (vd = a / b, vd));
      cd("div_ba", div_ba(a, b), (vd = b / a, vd));
    }
  for (unsigned i = 0; i < N(DS); i++) {
    double a = dv(DS[i]);
    cd("div_xx", div_xx(a), (vd = a / a, vd));
  }
  group_end("double_copy_neg_div");

  for (unsigned i = 0; i < N(FS); i++)
    for (unsigned j = 0; j < N(FS); j++) {
      float a = fv(FS[i]), b = fv(FS[j]);
      bf("second_s", second_s(a, b), b);
      bf("neg_s", neg_s(a, b), fv(FS[j] ^ 0x80000000u));
      cf("div_ab_s", div_ab_s(a, b), (vf = a / b, vf));
      cf("div_ba_s", div_ba_s(a, b), (vf = b / a, vf));
    }
  for (unsigned i = 0; i < N(FS); i++) {
    float a = fv(FS[i]);
    cf("div_xx_s", div_xx_s(a), (vf = a / a, vf));
  }
  group_end("float_copy_neg_div");

  for (unsigned i = 0; i < N(DS); i++) {
    struct { double d; float s; } src = {dv(DS[i]), fv(FS[i])}, dst;
    memset(&dst, 0x5a, sizeof dst);
    mem_copy(&src, &dst);
    bd("mem_copy.d", dst.d, src.d);
    bf("mem_copy.s", dst.s, src.s);
  }
  group_end("mem_copy");

  for (unsigned i = 0; i < N(WS); i++) {
    cd("iso_wd", iso_wd(WS[i]), (double)WS[i]);
    cf("iso_ws", iso_ws(WS[i]), (float)WS[i]);
  }
  for (unsigned i = 0; i < N(LS); i++) {
    cd("iso_ld", iso_ld(LS[i]), (double)LS[i]);
    cf("iso_ls", iso_ls(LS[i]), (float)LS[i]);
  }
  /* Pinned values: the text path used to read the low dword only. */
  cd("iso_ld(2^32+1)", iso_ld(4294967297LL), 4294967297.0);
  cd("iso_ld(-(2^32+1))", iso_ld(-4294967297LL), -4294967297.0);
  cd("iso_ld(INT64_MIN)", iso_ld(INT64_MIN), -9223372036854775808.0);
  cd("iso_ld(INT64_MAX)", iso_ld(INT64_MAX), 9223372036854775808.0);
  cf("iso_ls(2^32+1)", iso_ls(4294967297LL), 4294967296.0f);
  group_end("isolated_cvt");

  for (unsigned i = 0; i < N(LS); i++) {
    struct { double d[4]; float s[4]; } out;
    int32_t a = WS[i % N(WS)], b = WS[(i + 3) % N(WS)];
    int64_t c = LS[i], d = LS[(i + 5) % N(LS)];
    memset(&out, 0x5a, sizeof out);
    grouped(&out, a, b, c, d);
    cd("grouped.d0", out.d[0], (double)a);
    cd("grouped.d1", out.d[1], (double)b);
    cd("grouped.d2", out.d[2], (double)c);
    cd("grouped.d3", out.d[3], (double)d);
    cf("grouped.s0", out.s[0], (float)a);
    cf("grouped.s1", out.s[1], (float)b);
    cf("grouped.s2", out.s[2], (float)c);
    cf("grouped.s3", out.s[3], (float)d);
  }
  group_end("grouped_cvt");

  for (unsigned r = 0; r < N(LS); r++) {
    int64_t v[16];
    uint64_t x = 0, y = 0, z = ~(uint64_t)0;
    for (unsigned k = 0; k < 16; k++)
      v[k] = LS[(r + k) % N(LS)];
    for (unsigned k = 0; k < 14; k++) {
      x ^= (uint64_t)v[k];
      y |= (uint64_t)v[k];
      z &= (uint64_t)v[k];
    }
    struct { double d; float s; uint32_t pad; uint64_t x, y, z; } g;
    struct { double d; uint64_t x, y, z; } i;
    struct { float s; uint32_t pad; uint64_t x, y, z; } is;
    memset(&g, 0x5a, sizeof g);
    memset(&i, 0x5a, sizeof i);
    memset(&is, 0x5a, sizeof is);
    pressure_grouped(&g, v);
    pressure_iso(&i, v);
    pressure_iso_s(&is, v);
    cd("pressure_grouped.d", g.d, (double)v[14]);
    cf("pressure_grouped.s", g.s, (float)v[15]);
    cd("pressure_iso.d", i.d, (double)v[14]);
    cf("pressure_iso_s.s", is.s, (float)v[14]);
    total += 3;
    ok += g.x == x && g.y == y && g.z == z;
    ok += i.x == x && i.y == y && i.z == z;
    ok += is.x == x && is.y == y && is.z == z;
  }
  {
    /* Pinned values (also through the slot conversions below). */
    static const int64_t pin[] = {4294967297LL, -4294967297LL, INT64_MIN, INT64_MAX};
    static const double wd[] = {4294967297.0, -4294967297.0, -9223372036854775808.0, 9223372036854775808.0};
    static const float wf[] = {4294967296.0f, -4294967296.0f, -9223372036854775808.0f, 9223372036854775808.0f};
    for (unsigned k = 0; k < 4; k++) {
      int64_t v[16] = {0};
      struct { double d; float s; uint32_t pad; uint64_t x, y, z; } g;
      struct { double d; uint64_t x, y, z; } i;
      struct { float s; uint32_t pad; uint64_t x, y, z; } is;
      v[14] = pin[k];
      v[15] = pin[k];
      pressure_grouped(&g, v);
      pressure_iso(&i, v);
      pressure_iso_s(&is, v);
      cd("pin pressure_grouped.d", g.d, wd[k]);
      cf("pin pressure_grouped.s", g.s, wf[k]);
      cd("pin pressure_iso.d", i.d, wd[k]);
      cf("pin pressure_iso_s.s", is.s, wf[k]);
    }
  }
  group_end("pressure_cvt");

  /* Conversions whose integer source is a stack slot (slots.ssa). Before
   * the fix the text path read the low dword of an i64 slot:
   * 4294967297 -> 1.0. */
  for (unsigned i = 0; i < N(LS); i++) {
    int64_t x = LS[i];
    cd("slot_gld", slot_gld(x), (double)x);
    cf("slot_gls", slot_gls(x), (float)x);
    cd("slot_ild", slot_ild(x), (double)x);
    cf("slot_ils", slot_ils(x), (float)x);
  }
  for (unsigned i = 0; i < N(WS); i++) {
    int32_t x = WS[i];
    cd("slot_gwd", slot_gwd(x), (double)x);
    cf("slot_gws", slot_gws(x), (float)x);
    cd("slot_iwd", slot_iwd(x), (double)x);
    cf("slot_iws", slot_iws(x), (float)x);
  }
  cd("slot_ild(2^32+1)", slot_ild(4294967297LL), 4294967297.0);
  cd("slot_gld(2^32+1)", slot_gld(4294967297LL), 4294967297.0);
  cd("slot_ild(-(2^32+1))", slot_ild(-4294967297LL), -4294967297.0);
  cd("slot_ild(INT64_MIN)", slot_ild(INT64_MIN), -9223372036854775808.0);
  cd("slot_ild(INT64_MAX)", slot_ild(INT64_MAX), 9223372036854775808.0);
  cf("slot_ils(2^32+1)", slot_ils(4294967297LL), 4294967296.0f);
  cf("slot_gls(INT64_MIN)", slot_gls(INT64_MIN), -9223372036854775808.0f);
  cf("slot_gls(INT64_MAX)", slot_gls(INT64_MAX), 9223372036854775808.0f);
  group_end("slot_cvt");

  return fails ? 1 : 0;
}
