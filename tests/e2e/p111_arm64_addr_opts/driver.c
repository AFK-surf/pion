#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern int64_t local_struct(int64_t);
extern int32_t local_array(int32_t);
extern int64_t bigframe(int64_t);
extern int64_t unaligned(int64_t);
extern int64_t sub_mid(int64_t);
extern uint32_t hdr_w(void *);
extern int64_t neg_loads(void *);
extern void neg_stores(void *, uint32_t, int64_t, float, double);
extern int64_t neg_257(void *);
extern int64_t neg_twice(void *);

/* The escaped address is the object the slot-folded accesses use: bump the
 * 32-bit cell at +4, which every caller reads back after the call. */
void touch(void *p) {
	uint32_t v;
	memcpy(&v, (char *)p + 4, 4);
	v += 1;
	memcpy((char *)p + 4, &v, 4);
}

static uint64_t fnv(const unsigned char *b, size_t n) {
	uint64_t h = 1469598103934665603ull;
	for (size_t i = 0; i < n; i++)
		h = (h ^ b[i]) * 1099511628211ull;
	return h;
}

int main(void) {
	static unsigned char buf[1024];
	unsigned char *p = buf + 512;
	for (int i = 0; i < 1024; i++)
		buf[i] = (unsigned char)(i * 37 + 11);
	float f = 3.25f;
	double d = -12.5;
	memcpy(p - 64, &f, 4);
	memcpy(p - 72, &d, 8);
	uint32_t hw = 0x5eed1234u;
	memcpy(p - 24, &hw, 4);
	printf("local_struct=%llx local_array=%x bigframe=%llx unaligned=%llx sub_mid=%llx\n",
		(unsigned long long)local_struct(0x123456789), (unsigned)local_array(1000),
		(unsigned long long)bigframe(0x1020304050), (unsigned long long)unaligned(0x100000001),
		(unsigned long long)sub_mid(42));
	printf("hdr_w=%x neg_loads=%llx", hdr_w(p), (unsigned long long)neg_loads(p));
	neg_stores(p, 0xa1b2c3d4u, 0x0102030405060708ll, -7.75f, 1e100);
	printf(" neg_257=%llx", (unsigned long long)neg_257(p));
	printf(" neg_twice=%llx", (unsigned long long)neg_twice(p));
	printf(" mem=%llx\n", (unsigned long long)fnv(buf, sizeof buf));
	return 0;
}
