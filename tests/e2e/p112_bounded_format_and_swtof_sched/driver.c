/* P112: bit-for-bit C reference for sched.ssa (vendor/qbe/gcm.c
 * `groupconverts`). Build with -ffp-contract=off so no multiply-add is
 * fused: every function performs its double operations in source order. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern double conv2(int32_t, int32_t, int32_t, int32_t);
extern double conv3(int32_t, int32_t, int32_t, int32_t);
extern double conv4(int32_t, int32_t, int32_t, int32_t);
extern double neg_store(int32_t, int32_t, int32_t, int32_t, int32_t *);
extern double neg_call(int32_t, int32_t, int32_t, int32_t);
extern double neg_load(int32_t, const int32_t *, int32_t, int32_t);
extern double neg_cmp(int32_t, int32_t, int32_t, int32_t);
extern double neg_five(int32_t, int32_t, int32_t, int32_t);

static int32_t wrap(uint32_t v) {
	int32_t r;
	memcpy(&r, &v, sizeof r);
	return r;
}

int32_t p112_mul3(int32_t b) {
	return wrap((uint32_t)b * 3u);
}

enum { C2, C3, C4, STORE, CALL, LOAD, CMP, FIVE, NKIND };
static const char *names[NKIND] = {
	"conv2", "conv3", "conv4", "neg_store", "neg_call", "neg_load", "neg_cmp", "neg_five",
};

static double ref(int k, int32_t a, int32_t b, int32_t c0, int32_t d, int32_t *last) {
	double s = 0;
	for (uint32_t i = 0; i < 3; i++) {
		int32_t x1 = wrap((uint32_t)a + i);
		double s1 = s + (double)x1;
		*last = x1;
		int32_t m2 = p112_mul3(b);
		int32_t x2 = k == CMP ? (m2 < (int32_t)i) : wrap((uint32_t)m2 + i);
		double s2 = s1 - (double)x2;
		if (k == C2) {
			s = s2 + 0.25;
			continue;
		}
		int32_t x3 = wrap((uint32_t)c0 - i);
		double s3 = s2 * 0.5;
		double s4 = s3 + (double)x3;
		if (k == C3) {
			s = s4 + 0.25;
			continue;
		}
		int32_t x4 = wrap((uint32_t)d ^ (i << 30));
		double s5 = s4 * (double)x4;
		s = k == FIVE ? s5 + (double)wrap((uint32_t)x4 + (uint32_t)x1) : s5 + 0.25;
	}
	return s;
}

static double run(int k, int32_t a, int32_t b, int32_t c0, int32_t d, int32_t *slot) {
	switch (k) {
	case C2: return conv2(a, b, c0, d);
	case C3: return conv3(a, b, c0, d);
	case C4: return conv4(a, b, c0, d);
	case STORE: return neg_store(a, b, c0, d, slot);
	case CALL: return neg_call(a, b, c0, d);
	case LOAD: return neg_load(a, &b, c0, d);
	case CMP: return neg_cmp(a, b, c0, d);
	default: return neg_five(a, b, c0, d);
	}
}

int main(void) {
	static const int32_t vals[5] = {0, 1, -1, INT32_MIN, INT32_MAX};
	int bad = 0;
	for (int k = 0; k < NKIND; k++) {
		int ok = 0;
		for (int n = 0; n < 625; n++) {
			int32_t a = vals[n % 5], b = vals[n / 5 % 5], c0 = vals[n / 25 % 5], d = vals[n / 125];
			int32_t want_slot = 0, slot = 0x5a5a5a5a;
			double want = ref(k, a, b, c0, d, &want_slot);
			double got = run(k, a, b, c0, d, &slot);
			uint64_t wb, gb;
			memcpy(&wb, &want, 8);
			memcpy(&gb, &got, 8);
			if (wb == gb && (k != STORE || slot == want_slot))
				ok++;
			else if (bad++ < 8)
				printf("MISMATCH %s(%d, %d, %d, %d): got %016llx want %016llx\n", names[k], a, b, c0, d,
					(unsigned long long)gb, (unsigned long long)wb);
		}
		printf("%s %d/625\n", names[k], ok);
	}
	return bad != 0;
}
