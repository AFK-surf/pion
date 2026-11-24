#include <stdio.h>
#include <stdint.h>
extern int64_t spill_l(int64_t);
extern uint32_t spill_w(uint32_t);
extern int64_t many_l(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
extern uint32_t many_w(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
extern int64_t bigframe(int64_t);
extern int64_t user_alloc(int64_t, int64_t);
extern int64_t vsum(int64_t, ...);
extern int64_t dyn(int64_t, int64_t);
int main(void) {
	int64_t A = 0x1234567;
	uint32_t W = 0x89abcdefu;
	int64_t l[8];
	uint32_t w[8];
	for (int k = 0; k < 8; k++) {
		l[k] = 3 + (int64_t)k * 1000003;
		w[k] = 0xfedcba98u + (uint32_t)k * 977u;
	}
	printf("spill_l=%llx spill_w=%x many_l=%llx many_w=%x bigframe=%llx user_alloc=%llx vsum=%llx dyn=%llx\n",
		(unsigned long long)spill_l(A), spill_w(W),
		(unsigned long long)many_l(l[0], l[1], l[2], l[3], l[4], l[5], l[6], l[7]),
		many_w(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]),
		(unsigned long long)bigframe(A), (unsigned long long)user_alloc(A, 77),
		(unsigned long long)vsum(2, A, (int64_t)99), (unsigned long long)dyn(A, 64));
	return 0;
}
