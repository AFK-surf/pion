/* P117 driver: every function of loops.ssa against its oracle.c twin on the
 * same memory (separate, identical, and shifted-by-one-word dst/src), with
 * the return value and the whole buffer compared after each call. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define WFUNCS(X) X(up4) X(down4) X(falseback5) X(wrap3) X(signcross2) \
	X(udown4) X(extsw5) X(extuw3) X(once1) X(eight8) X(nine9) X(alias6) \
	X(multi) X(nested) X(callbody) X(divbody) X(varstart) X(twophi)

#define DECL(n) uint32_t n(uint32_t *, uint32_t *); \
	uint32_t o_##n(uint32_t *, uint32_t *); \
	static uint64_t q_##n(uint32_t *d, uint32_t *s) { return n(d, s); } \
	static uint64_t r_##n(uint32_t *d, uint32_t *s) { return o_##n(d, s); }
WFUNCS(DECL)
uint64_t long7(uint32_t *, uint32_t *);
uint64_t o_long7(uint32_t *, uint32_t *);

typedef uint64_t (*fn_t)(uint32_t *, uint32_t *);
static const struct { const char *name; fn_t q, o; } tab[] = {
#define ROW(n) { #n, q_##n, r_##n },
	WFUNCS(ROW)
	{ "long7", long7, o_long7 },
};

static const uint32_t seeds[] = {
	0, 1, 3, 9, 12345678u, 0x9581cu, 0x7fffffffu, 0x80000000u,
	0xfffffffeu, 0xffffffffu,
};

int
main(void)
{
	unsigned long total = 0, bad = 0;
	size_t f, s;
	int mode, k;

	for (f = 0; f < sizeof tab / sizeof tab[0]; f++) {
		int n = 0;
		for (s = 0; s < sizeof seeds / sizeof seeds[0]; s++)
			for (mode = 0; mode < 4; mode++) {
				uint32_t a[48], b[48];
				static const int off[4][2] = {{16, 32}, {16, 16}, {16, 17}, {17, 16}};
				uint64_t rq, ro;
				for (k = 0; k < 48; k++)
					a[k] = seeds[s] + (uint32_t)k * 0x9e3779b9u;
				memcpy(b, a, sizeof a);
				rq = tab[f].q(a + off[mode][0], a + off[mode][1]);
				ro = tab[f].o(b + off[mode][0], b + off[mode][1]);
				if (rq != ro || memcmp(a, b, sizeof a) != 0) {
					printf("MISMATCH %s seed=%#x mode=%d ret=%#llx want=%#llx\n",
						tab[f].name, seeds[s], mode,
						(unsigned long long)rq, (unsigned long long)ro);
					bad++;
				}
				n++;
				total++;
			}
		printf("%s %d\n", tab[f].name, n);
	}
	printf("total %lu bad %lu\n", total, bad);
	return bad != 0;
}
