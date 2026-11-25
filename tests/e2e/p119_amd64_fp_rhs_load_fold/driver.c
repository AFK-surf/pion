/* P119 IEEE-754 bit and exception-flag differential for fold.ssa.
 *
 * Every function of fold.ssa runs over
 *   4 rounding modes x 16 x 16 boundary values (left operand x memory operand)
 *   x 2 misaligned memory offsets (+1, +3)
 * and is compared with an independent C reference: the exact result bits
 * (uint32_t / uint64_t, NaN sign and payload included), every byte the
 * function writes, and fetestexcept(FE_ALL_EXCEPT) right after the call.
 * Memory operands are built with memcpy at misaligned addresses (no C
 * misaligned access); the QBE code loads them directly. One line per call
 * goes to stdout so that the text-assembly and direct-object routes can be
 * compared byte for byte; mismatches (the first 40) and the summary go to
 * stderr, and any mismatch makes the exit status 1.
 *
 * Every comparison is exact except one: n_const_subd (`1.5 - [p]`), which
 * QBE lowers, unchanged by the fold, as `neg; add`. That equals the
 * subtraction in IEEE-754 except for the sign of a NaN result, which
 * IEEE-754 leaves unspecified, so there a NaN result only has to be a NaN
 * (flags and memory are still exact). The folded functions, including
 * p_sub<k>_dst whose unfolded allocation took that `neg; add` path, are
 * compared bit for bit with direct subs<k> / divs<k> C code.
 *
 * Build with -ffp-contract=off -frounding-math (and -fsignaling-nans with
 * GCC); the reference operations read volatile operands and store a volatile
 * result before the flags are sampled.
 */
#include <fenv.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma STDC FENV_ACCESS ON

typedef float F;
typedef double D;

#define NHP 19
extern F p_subs_ptr(F, const void *), p_divs_ptr(F, const void *);
extern D p_subd_ptr(D, const void *), p_divd_ptr(D, const void *);
extern F p_subs_off(F, const void *), p_divs_off(F, const void *);
extern D p_subd_off(D, const void *), p_divd_off(D, const void *);
extern F p_subs_idx(F, const void *, long), p_divs_idx(F, const void *, long);
extern D p_subd_idx(D, const void *, long), p_divd_idx(D, const void *, long);
extern F p_subs_slot(F, const void *, long, long), p_divs_slot(F, const void *, long, long);
extern D p_subd_slot(D, const void *, long, long), p_divd_slot(D, const void *, long, long);
extern F p_subs_hp(const void *, const void *, void *), p_divs_hp(const void *, const void *, void *);
extern D p_subd_hp(const void *, const void *, void *), p_divd_hp(const void *, const void *, void *);
extern D n_side0_subd(D, D, const void *);
extern F n_side0_divs(F, F, const void *);
extern D p_subd_dst(D, D, const void *);
extern F p_subs_dst(F, F, const void *);
extern D n_const_subd(const void *);
extern D n_self_subd(D, const void *);
extern F n_multi_divs(F, const void *, void *);
extern D n_store_subd(D, void *, D);
extern F n_store_divs(F, void *, F);
extern D n_call_divd(D, void *);
extern F n_call_subs(F, void *);
extern D n_width_sd(D, const void *);
extern F n_width_ds(F, const void *);
extern F n_const_divs(const void *);

/* Called by n_call_*: overwrites the 8 bytes at p (the loaded operand). */
void p119_clobber(void *p) { memset(p, 0x5a, 8); }

static const uint64_t DV[16] = {
  0x0000000000000000ULL, 0x8000000000000000ULL, /* +-0 */
  0x0000000000000001ULL, 0x800fffffffffffffULL, /* min / -max subnormal */
  0x0010000000000000ULL, 0x8010000000000000ULL, /* +-min normal */
  0x7fefffffffffffffULL, 0xffefffffffffffffULL, /* +-max normal */
  0x3ff0000000000000ULL, 0xbff8000000000000ULL, /* 1, -1.5 */
  0x3fd5555555555555ULL, 0x400921fb54442d18ULL, /* 1/3, pi */
  0x7ff0000000000000ULL, 0xfff0000000000000ULL, /* +-Inf */
  0x7ff8000000000123ULL, 0xfff4000000000abcULL, /* qNaN, -sNaN (payloads) */
};
static const uint32_t SV[16] = {
  0x00000000, 0x80000000, 0x00000001, 0x807fffff, 0x00800000, 0x80800000,
  0x7f7fffff, 0xff7fffff, 0x3f800000, 0xbfc00000, 0x3eaaaaab, 0x40490fdb,
  0x7f800000, 0xff800000, 0x7fc00123, 0xffa00abc,
};
static const int MODES[4] = {FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO};
static const char *MODE_NAMES[4] = {"rn", "rd", "ru", "rz"};

/* ---- C reference ---- */
static __attribute__((noinline)) F rsub_s(F a, F b) { volatile F x = a, y = b; volatile F r = x - y; return r; }
static __attribute__((noinline)) F rdiv_s(F a, F b) { volatile F x = a, y = b; volatile F r = x / y; return r; }
static __attribute__((noinline)) D rsub_d(D a, D b) { volatile D x = a, y = b; volatile D r = x - y; return r; }
static __attribute__((noinline)) D rdiv_d(D a, D b) { volatile D x = a, y = b; volatile D r = x / y; return r; }
static __attribute__((noinline)) D rexts(F a) { volatile F x = a; volatile D r = (D)x; return r; }
static __attribute__((noinline)) F rtruncd(D a) { volatile D x = a; volatile F r = (F)x; return r; }

static F fs(uint32_t b) { F f; memcpy(&f, &b, 4); return f; }
static D fd(uint64_t b) { D d; memcpy(&d, &b, 8); return d; }
static uint32_t bs(F f) { uint32_t b; memcpy(&b, &f, 4); return b; }
static uint64_t bd(D d) { uint64_t b; memcpy(&b, &d, 8); return b; }

static unsigned long calls, bad;

/* One observation: result bits, flags, and a digest of written memory. */
typedef struct { uint64_t bits; int flags; uint64_t mem; } Obs;

static uint64_t digest(const unsigned char *p, size_t n) {
  uint64_t h = 1469598103934665603ULL;
  for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ULL;
  return h;
}

static void report(const char *fn, int m, unsigned i, unsigned j, unsigned off, Obs q, Obs c) {
  calls++;
  printf("%s %s %u %u %u %016" PRIx64 " %02x %016" PRIx64 "\n", fn, MODE_NAMES[m], i, j, off,
         q.bits, q.flags, q.mem);
  if (q.bits != c.bits || q.flags != c.flags || q.mem != c.mem) {
    if (++bad > 40) return;
    fprintf(stderr, "MISMATCH %s %s x#%u m#%u +%u: qbe %016" PRIx64 " flags %02x mem %016" PRIx64
            " / C %016" PRIx64 " flags %02x mem %016" PRIx64 "\n", fn, MODE_NAMES[m], i, j, off,
            q.bits, q.flags, q.mem, c.bits, c.flags, c.mem);
  }
}

#define FLAGS() fetestexcept(FE_ALL_EXCEPT)
#define CLR() feclearexcept(FE_ALL_EXCEPT)

/* Backing store: operands live at misaligned addresses inside it. */
static unsigned char buf[1024], ref[1024];

static void run_d(int m, unsigned i, unsigned j, unsigned off, uint64_t xb, uint64_t mb) {
  D x = fd(xb);
  D mv = fd(mb);
  Obs q, c;
  unsigned char *p = buf + off;
#define PUT(at) do { memset(buf, 0xcc, sizeof buf); memcpy(p + (at), &mb, 8); } while (0)
#define CASE(name, call, refexpr, at) do { \
    PUT(at); CLR(); D r_ = call; q.flags = FLAGS(); q.bits = bd(r_); q.mem = digest(buf, sizeof buf); \
    PUT(at); CLR(); D c_ = refexpr; c.flags = FLAGS(); c.bits = bd(c_); c.mem = digest(buf, sizeof buf); \
    report(name, m, i, j, off, q, c); } while (0)
  CASE("p_subd_ptr", p_subd_ptr(x, p), rsub_d(x, mv), 0);
  CASE("p_divd_ptr", p_divd_ptr(x, p), rdiv_d(x, mv), 0);
  CASE("p_subd_off", p_subd_off(x, p), rsub_d(x, mv), 24);
  CASE("p_divd_off", p_divd_off(x, p), rdiv_d(x, mv), 24);
  CASE("p_subd_idx", p_subd_idx(x, p, 3), rsub_d(x, mv), 3 * 8 + 8);
  CASE("p_divd_idx", p_divd_idx(x, p, 3), rdiv_d(x, mv), 3 * 8 + 8);
  CASE("p_subd_slot", p_subd_slot(x, p, 2, 2), rsub_d(x, mv), 0);
  CASE("p_divd_slot", p_divd_slot(x, p, 2, 2), rdiv_d(x, mv), 0);
  /* y (unused) differs from [p], so a dropped load changes the result. */
  CASE("n_side0_subd", n_side0_subd(fd(DV[(j + 7) % 16]), x, p), rsub_d(mv, x), 0);
  CASE("p_subd_dst", p_subd_dst(fd(DV[(j + 7) % 16]), x, p), rsub_d(x, mv), 0);
  {
    /* n_const_subd: 1.5 - [p]; a NaN result only has to be a NaN. */
    PUT(0); CLR(); D r = n_const_subd(p); q.flags = FLAGS(); q.bits = bd(r); q.mem = digest(buf, sizeof buf);
    PUT(0); CLR(); D cr = rsub_d(1.5, mv); c.flags = FLAGS(); c.bits = bd(cr); c.mem = digest(buf, sizeof buf);
    if (r != r && cr != cr) c.bits = q.bits;
    report("n_const_subd", m, i, j, off, q, c);
  }
  CASE("n_self_subd", n_self_subd(x, p), rsub_d(mv, mv), 0);
  {
    /* n_width_sd: x - (double)[p as float], over the f32 grid. */
    uint32_t nb = SV[j];
    memset(buf, 0xcc, sizeof buf); memcpy(p, &nb, 4);
    uint64_t before = digest(buf, sizeof buf);
    CLR(); D r = n_width_sd(x, p); q.flags = FLAGS(); q.bits = bd(r); q.mem = digest(buf, sizeof buf);
    CLR(); D cr = rsub_d(x, rexts(fs(nb))); c.flags = FLAGS(); c.bits = bd(cr); c.mem = before;
    report("n_width_sd", m, i, j, off, q, c);
  }
  /* n_store_subd: x - old [p], then [p] = y (the y operand is x's neighbour). */
  {
    D y = fd(DV[(i + 5) % 16]);
    PUT(0); CLR(); D r = n_store_subd(x, p, y); q.flags = FLAGS(); q.bits = bd(r); q.mem = digest(buf, sizeof buf);
    PUT(0); CLR(); D cr = rsub_d(x, mv); c.flags = FLAGS(); memcpy(p, &y, 8); c.bits = bd(cr); c.mem = digest(buf, sizeof buf);
    report("n_store_subd", m, i, j, off, q, c);
  }
  /* n_call_divd: x / old [p]; the call overwrites [p] in between. */
  {
    PUT(0); CLR(); D r = n_call_divd(x, p); q.flags = FLAGS(); q.bits = bd(r); q.mem = digest(buf, sizeof buf);
    PUT(0); CLR(); D cr = rdiv_d(x, mv); c.flags = FLAGS(); p119_clobber(p); c.bits = bd(cr); c.mem = digest(buf, sizeof buf);
    report("n_call_divd", m, i, j, off, q, c);
  }
  /* High XMM pressure: in[0] = x, in[1..19] = other grid values, q = [mem]. */
  for (int op = 0; op < 2; op++) {
    unsigned char *in = buf + off, *qq = buf + 200 + off, *out = buf + 240 + off;
    unsigned char *rin = ref + off, *rout = ref + 240 + off;
    memset(buf, 0xcc, sizeof buf);
    memcpy(in, &xb, 8);
    for (int k = 1; k <= NHP; k++) memcpy(in + 8 * k, &DV[(i + j + k) % 16], 8);
    memcpy(qq, &mb, 8);
    memcpy(ref, buf, sizeof buf);
    CLR();
    D r = op ? p_divd_hp(in, qq, out) : p_subd_hp(in, qq, out);
    q.flags = FLAGS(); q.bits = bd(r); q.mem = digest(buf, sizeof buf);
    CLR();
    D cr = op ? rdiv_d(x, mv) : rsub_d(x, mv);
    c.flags = FLAGS();
    for (int k = 1; k <= NHP; k++) {
      memcpy(rout + 8 * k, rin + 8 * k, 8);
      memcpy(rout + 8 * (NHP + k), rin + 8 * k, 8);
    }
    c.bits = bd(cr); c.mem = digest(ref, sizeof ref);
    report(op ? "p_divd_hp" : "p_subd_hp", m, i, j, off, q, c);
  }
#undef PUT
#undef CASE
}

static void run_s(int m, unsigned i, unsigned j, unsigned off, uint32_t xb, uint32_t mb) {
  F x = fs(xb);
  F mv = fs(mb);
  Obs q, c;
  unsigned char *p = buf + off;
#define PUT(at) do { memset(buf, 0xcc, sizeof buf); memcpy(p + (at), &mb, 4); } while (0)
#define CASE(name, call, refexpr, at) do { \
    PUT(at); CLR(); F r_ = call; q.flags = FLAGS(); q.bits = bs(r_); q.mem = digest(buf, sizeof buf); \
    PUT(at); CLR(); F c_ = refexpr; c.flags = FLAGS(); c.bits = bs(c_); c.mem = digest(buf, sizeof buf); \
    report(name, m, i, j, off, q, c); } while (0)
  CASE("p_subs_ptr", p_subs_ptr(x, p), rsub_s(x, mv), 0);
  CASE("p_divs_ptr", p_divs_ptr(x, p), rdiv_s(x, mv), 0);
  CASE("p_subs_off", p_subs_off(x, p), rsub_s(x, mv), 24);
  CASE("p_divs_off", p_divs_off(x, p), rdiv_s(x, mv), 24);
  CASE("p_subs_idx", p_subs_idx(x, p, 5), rsub_s(x, mv), 5 * 4 + 8);
  CASE("p_divs_idx", p_divs_idx(x, p, 5), rdiv_s(x, mv), 5 * 4 + 8);
  CASE("p_subs_slot", p_subs_slot(x, p, 3, 3), rsub_s(x, mv), 0);
  CASE("p_divs_slot", p_divs_slot(x, p, 3, 3), rdiv_s(x, mv), 0);
  CASE("n_side0_divs", n_side0_divs(fs(SV[(j + 7) % 16]), x, p), rdiv_s(mv, x), 0);
  CASE("p_subs_dst", p_subs_dst(fs(SV[(j + 7) % 16]), x, p), rsub_s(x, mv), 0);
  CASE("n_const_divs", n_const_divs(p), rdiv_s(3.0f, mv), 0);
  {
    /* n_width_ds: x / (float)[p as double]; the double is built from the f32
     * grid value so that every class (NaN payloads included) is covered. */
    D wide = fd(DV[j]);
    memset(buf, 0xcc, sizeof buf); memcpy(p, &wide, 8);
    uint64_t before = digest(buf, sizeof buf);
    CLR(); F r = n_width_ds(x, p); q.flags = FLAGS(); q.bits = bs(r); q.mem = digest(buf, sizeof buf);
    CLR(); F cr = rdiv_s(x, rtruncd(wide)); c.flags = FLAGS(); c.bits = bs(cr); c.mem = before;
    report("n_width_ds", m, i, j, off, q, c);
  }
  {
    /* n_multi_divs: x / [p], and [p]'s bits are stored to [q]. */
    unsigned char *qq = buf + 100 + off;
    PUT(0); CLR(); F r = n_multi_divs(x, p, qq); q.flags = FLAGS(); q.bits = bs(r); q.mem = digest(buf, sizeof buf);
    PUT(0); CLR(); F cr = rdiv_s(x, mv); c.flags = FLAGS(); memcpy(qq, &mb, 4); c.bits = bs(cr); c.mem = digest(buf, sizeof buf);
    report("n_multi_divs", m, i, j, off, q, c);
  }
  {
    F y = fs(SV[(i + 5) % 16]);
    PUT(0); CLR(); F r = n_store_divs(x, p, y); q.flags = FLAGS(); q.bits = bs(r); q.mem = digest(buf, sizeof buf);
    PUT(0); CLR(); F cr = rdiv_s(x, mv); c.flags = FLAGS(); memcpy(p, &y, 4); c.bits = bs(cr); c.mem = digest(buf, sizeof buf);
    report("n_store_divs", m, i, j, off, q, c);
  }
  {
    PUT(0); CLR(); F r = n_call_subs(x, p); q.flags = FLAGS(); q.bits = bs(r); q.mem = digest(buf, sizeof buf);
    PUT(0); CLR(); F cr = rsub_s(x, mv); c.flags = FLAGS(); p119_clobber(p); c.bits = bs(cr); c.mem = digest(buf, sizeof buf);
    report("n_call_subs", m, i, j, off, q, c);
  }
  for (int op = 0; op < 2; op++) {
    unsigned char *in = buf + off, *qq = buf + 200 + off, *out = buf + 240 + off;
    unsigned char *rin = ref + off, *rout = ref + 240 + off;
    memset(buf, 0xcc, sizeof buf);
    memcpy(in, &xb, 4);
    for (int k = 1; k <= NHP; k++) memcpy(in + 4 * k, &SV[(i + j + k) % 16], 4);
    memcpy(qq, &mb, 4);
    memcpy(ref, buf, sizeof buf);
    CLR();
    F r = op ? p_divs_hp(in, qq, out) : p_subs_hp(in, qq, out);
    q.flags = FLAGS(); q.bits = bs(r); q.mem = digest(buf, sizeof buf);
    CLR();
    F cr = op ? rdiv_s(x, mv) : rsub_s(x, mv);
    c.flags = FLAGS();
    for (int k = 1; k <= NHP; k++) {
      memcpy(rout + 4 * k, rin + 4 * k, 4);
      memcpy(rout + 4 * (NHP + k), rin + 4 * k, 4);
    }
    c.bits = bs(cr); c.mem = digest(ref, sizeof ref);
    report(op ? "p_divs_hp" : "p_subs_hp", m, i, j, off, q, c);
  }
#undef PUT
#undef CASE
}

int main(void) {
  for (int m = 0; m < 4; m++) {
    if (fesetround(MODES[m]) != 0) {
      fprintf(stderr, "fesetround(%s) failed\n", MODE_NAMES[m]);
      return 2;
    }
    for (unsigned i = 0; i < 16; i++)
      for (unsigned j = 0; j < 16; j++)
        for (unsigned off = 1; off <= 3; off += 2) {
          run_d(m, i, j, off, DV[i], DV[j]);
          run_s(m, i, j, off, SV[i], SV[j]);
        }
  }
  fesetround(FE_TONEAREST);
  fprintf(stderr, "p119 IEEE differential: %lu calls, %lu mismatches\n", calls, bad);
  return bad ? 1 : 0;
}
