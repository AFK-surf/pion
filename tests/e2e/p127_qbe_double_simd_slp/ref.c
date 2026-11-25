/* P127 reference: the kernels of p127.pion in strict C (built with
 * -O0 -ffp-contract=off), printing the "V" lines with every result as its
 * signed 64-bit IEEE-754 bit pattern. Which payload wins when both operands
 * of one operation are NaNs is target-defined, so check.py compares a NaN
 * result here only by being a NaN; the exact payloads are pinned by the
 * vector / scalar comparison of the Pion program itself. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
  double x, y;
} Vec2;

typedef struct {
  double x, y, vx, vy;
} Body;

static double drift(Body *b, double dt, int n) {
  double e = 0.0;
  while (n > 0) {
    b->vx = b->vx + b->x * dt;
    b->vy = b->vy + b->y * dt;
    b->x = b->x + b->vx * dt;
    b->y = b->y + b->vy * dt;
    e = e + (b->vx * b->vx + b->vy * b->vy);
    n = n - 1;
  }
  return e;
}

static double shear(Vec2 *p, Vec2 *v, double dt, int n) {
  double e = 0.0;
  while (n > 0) {
    v->x = v->x + p->x * dt;
    v->y = v->y + p->y * dt;
    p->x = p->x + v->x * dt;
    p->y = p->y + v->y * dt;
    e = e + (v->x * v->x + v->y * v->y);
    n = n - 1;
  }
  return e;
}

static double orbit(Vec2 *p, Vec2 *v, double dt, int n) {
  double px = p->x, py = p->y, vx = v->x, vy = v->y;
  while (n > 0) {
    vx = vx - px * dt;
    vy = vy - py * dt;
    px = px + vx * dt;
    py = py + vy * dt;
    n = n - 1;
  }
  p->x = px;
  p->y = py;
  v->x = vx;
  v->y = vy;
  return px * px + py * py;
}

static void kick(Vec2 *p, Vec2 *v, double dt) {
  double nx = p->x * dt + v->x;
  double ny = p->y * dt + v->y;
  p->x = nx;
  p->y = ny;
}

static long long bits(double d) {
  int64_t b;
  memcpy(&b, &d, 8);
  return (long long)b;
}

static void show(const Vec2 *p) { printf(" %lld %lld", bits(p->x), bits(p->y)); }

int main(void) {
  static const int64_t dbits[] = {
      0, INT64_MIN, 4607182418800017408LL, -4613937818241073152LL,
      4591870180066957722LL, 4616189618054758400LL, 4614256656552045848LL, 1,
      4503599627370495LL, 4503599627370496LL, 9218868437227405311LL,
      9218868437227405312LL, -4503599627370496LL, 9221120237041090561LL,
      -2251799813682500LL, 9218868437227408301LL,
  };
  enum { N = sizeof dbits / sizeof dbits[0] };
  double ds[N];
  for (int i = 0; i < N; i++)
    memcpy(&ds[i], &dbits[i], 8);
  for (int i = 0; i < N; i++)
    for (int j = 0; j < N; j++) {
      double a = ds[i], b = ds[j], c = ds[(i + 3) % N], d = ds[(j * 5 + 1) % N];
      double dt = ds[(i + j * 7) % N];
      printf("V %d %d", i, j);
      Body body = {a, b, c, d};
      double e = drift(&body, dt, 3);
      printf(" drift %lld %lld %lld %lld %lld", bits(body.x), bits(body.y), bits(body.vx),
             bits(body.vy), bits(e));
      Vec2 p = {a, b}, v = {c, d};
      double e1 = shear(&p, &v, dt, 3);
      printf(" shear");
      show(&p);
      show(&v);
      printf(" %lld", bits(e1));
      Vec2 q = {a, b};
      double e2 = shear(&q, &q, dt, 3);
      printf(" shear_alias");
      show(&q);
      printf(" %lld", bits(e2));
      Vec2 r = {a, b}, s = {c, d};
      double e3 = orbit(&r, &s, dt, 3);
      printf(" orbit");
      show(&r);
      show(&s);
      printf(" %lld", bits(e3));
      Vec2 t = {a, b};
      double e4 = orbit(&t, &t, dt, 3);
      printf(" orbit_alias");
      show(&t);
      printf(" %lld", bits(e4));
      Vec2 k = {a, b}, kv = {c, d};
      for (int step = 0; step < 3; step++)
        kick(&k, &kv, dt);
      printf(" kick");
      show(&k);
      Vec2 ka = {a, b};
      kick(&ka, &ka, dt);
      printf(" kick_alias");
      show(&ka);
      printf("\n");
    }
  return 0;
}
