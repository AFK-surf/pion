/* p120 driver: runs every Win64 function of fixture.ssa (compiled with
 * `qbe -t amd64_win`) through harness.S and checks, per call:
 *   - the result, bit for bit, against gen_il.py's Python reference;
 *   - all 128 bits of xmm6..xmm15 (160 bytes, both halves of every
 *     register non-zero and distinct) are unchanged;
 *   - rbx rbp rdi rsi r12..r15 and %rsp are unchanged.
 * Alignment cases (p120_align, p120_dynpush*, p120_rsp*) fold `addr & 15`
 * and the callee's entry %rsp mod 16 into their result.
 * Each case runs with 3 different register pattern seeds. Prints
 * `p120 calls N bad 0` on success, exits 1 on any mismatch. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct p120_case {
	const char *name;
	void *fn;
	int nstack;
	uint64_t args[4];
	uint64_t stack[8];
	char kind;
	uint64_t bits;
};

#include "cases.h"

struct p120_ctx {
	void *fn;
	uint64_t nstack;
	uint64_t args[4];
	uint64_t stack[8];
	uint64_t gpr_in[8];
	uint64_t gpr_out[8];
	uint64_t xmm_in[10][2];
	uint64_t xmm_out[10][2];
	uint64_t rax_out;
	uint64_t xmm0_out[2];
	uint64_t rsp_in;
	uint64_t rsp_out;
};

#define OFF_OK(f, o) (offsetof(struct p120_ctx, f) == (o))
typedef char p120_layout[(OFF_OK(args, 16) && OFF_OK(stack, 48) &&
	OFF_OK(gpr_in, 112) && OFF_OK(gpr_out, 176) && OFF_OK(xmm_in, 240) &&
	OFF_OK(xmm_out, 400) && OFF_OK(rax_out, 560) && OFF_OK(xmm0_out, 568) &&
	OFF_OK(rsp_in, 584) && OFF_OK(rsp_out, 592)) ? 1 : -1];

#if defined(__x86_64__) && defined(_WIN32)
#define P120_SYSV __attribute__((sysv_abi))
#else
#define P120_SYSV
#endif
P120_SYSV void p120_call(struct p120_ctx *c);

static const char *GPR[8] = {"rbx", "rbp", "rdi", "rsi", "r12", "r13", "r14", "r15"};

static uint64_t
mix(uint64_t x)
{
	x ^= x >> 33;
	x *= 0xff51afd7ed558ccdull;
	x ^= x >> 33;
	x *= 0xc4ceb9fe1a85ec53ull;
	x ^= x >> 33;
	return x | 0x0100000000000001ull; /* never zero in either half */
}

int
main(void)
{
	size_t n = sizeof P120_CASES / sizeof P120_CASES[0];
	unsigned calls = 0, bad = 0;

	for (size_t k = 0; k < n; k++) {
		const struct p120_case *t = &P120_CASES[k];
		for (uint64_t seed = 1; seed <= 3; seed++) {
			struct p120_ctx c;
			uint64_t got;
			int r;

			memset(&c, 0, sizeof c);
			c.fn = t->fn;
			c.nstack = (uint64_t)t->nstack;
			memcpy(c.args, t->args, sizeof c.args);
			memcpy(c.stack, t->stack, sizeof c.stack);
			for (r = 0; r < 8; r++)
				c.gpr_in[r] = mix(seed * 1000 + (uint64_t)r);
			for (r = 0; r < 10; r++) {
				c.xmm_in[r][0] = mix(seed * 2000 + 2 * (uint64_t)r);
				c.xmm_in[r][1] = mix(seed * 2000 + 2 * (uint64_t)r + 1);
			}
			p120_call(&c);
			calls++;
			got = t->kind == 'd' ? c.xmm0_out[0] : c.rax_out;
			if (got != t->bits) {
				printf("BAD %s seed %u: result 0x%016llx want 0x%016llx\n",
					t->name, (unsigned)seed, (unsigned long long)got,
					(unsigned long long)t->bits);
				bad++;
			}
			for (r = 0; r < 10; r++)
				if (c.xmm_out[r][0] != c.xmm_in[r][0]
				|| c.xmm_out[r][1] != c.xmm_in[r][1]) {
					printf("BAD %s seed %u: xmm%d %016llx:%016llx want %016llx:%016llx\n",
						t->name, (unsigned)seed, r + 6,
						(unsigned long long)c.xmm_out[r][1],
						(unsigned long long)c.xmm_out[r][0],
						(unsigned long long)c.xmm_in[r][1],
						(unsigned long long)c.xmm_in[r][0]);
					bad++;
				}
			for (r = 0; r < 8; r++)
				if (c.gpr_out[r] != c.gpr_in[r]) {
					printf("BAD %s seed %u: %s 0x%016llx want 0x%016llx\n",
						t->name, (unsigned)seed, GPR[r],
						(unsigned long long)c.gpr_out[r],
						(unsigned long long)c.gpr_in[r]);
					bad++;
				}
			if (c.rsp_out != c.rsp_in) {
				printf("BAD %s seed %u: rsp moved\n", t->name, (unsigned)seed);
				bad++;
			}
		}
	}
	if (calls != P120_NCALLS) {
		printf("BAD made %u calls, want %u\n", calls, (unsigned)P120_NCALLS);
		bad++;
	}
	printf("p120 calls %u bad %u\n", calls, bad);
	return bad != 0;
}
