/* P117 independent C oracle for loops.ssa (wrapping uint32_t arithmetic;
 * signed tests compare through int32_t / int64_t like the QBE comparisons). */
#include <stdint.h>

uint32_t
p117_helper(uint32_t a, uint32_t i)
{
	return a * 5u + (i ^ 0x55u);
}

uint32_t o_up4(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 0u, next, m;
	for (;;) {
		uint32_t a = *src;
		uint32_t v = a + i;
		m = v * 3u;
		*dst = m;
		next = i + 1u;
		if (!((int32_t)next < 4))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint32_t o_down4(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 8u, next, m;
	for (;;) {
		uint32_t a = *src;
		uint32_t v = a + i;
		m = v * 3u;
		*dst = m;
		next = i - 2u;
		if (!((int32_t)next > 1))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint32_t o_falseback5(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 0u, next, m;
	for (;;) {
		uint32_t a = *src;
		uint32_t v = a + i;
		m = v * 3u;
		*dst = m;
		next = i + 1u;
		if (!(next != 5u))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint32_t o_wrap3(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 4294967294u, next, m;
	for (;;) {
		uint32_t a = *src;
		uint32_t v = a + i;
		m = v * 3u;
		*dst = m;
		next = i + 1u;
		if (!(next != 1u))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint32_t o_signcross2(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 2147483646u, next, m;
	for (;;) {
		uint32_t a = *src;
		uint32_t v = a + i;
		m = v * 3u;
		*dst = m;
		next = i + 1u;
		if (!((int32_t)next >= 0))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint32_t o_udown4(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 0u, next, m;
	for (;;) {
		uint32_t a = *src;
		uint32_t v = a + i;
		m = v * 3u;
		*dst = m;
		next = i + (uint32_t)-1;
		if (!(next > 4294967292u))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint32_t o_extsw5(uint32_t *dst, uint32_t *src)
{
	uint32_t i = (uint32_t)-3, next, m;
	for (;;) {
		uint32_t a = *src;
		uint32_t v = a + i;
		m = v * 3u;
		*dst = m;
		next = i + 1u;
		if (!((int64_t)(int32_t)next < 2))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint32_t o_extuw3(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 4294967293u, next, m;
	for (;;) {
		uint32_t a = *src;
		uint32_t v = a + i;
		m = v * 3u;
		*dst = m;
		next = i + 1u;
		if (!((uint64_t)next > 4294967280u))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint32_t o_once1(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 5u, next, m;
	for (;;) {
		uint32_t a = *src;
		uint32_t v = a + i;
		m = v * 3u;
		*dst = m;
		next = i + 1u;
		if (!((int32_t)next < 0))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint32_t o_eight8(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 0u, next, m;
	for (;;) {
		uint32_t a = *src;
		uint32_t v = a + i;
		m = v * 3u;
		*dst = m;
		next = i + 1u;
		if (!((int32_t)next < 8))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint32_t o_nine9(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 0u, next, m;
	for (;;) {
		uint32_t a = *src;
		uint32_t v = a + i;
		m = v * 3u;
		*dst = m;
		next = i + 1u;
		if (!((int32_t)next < 9))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint64_t o_long7(uint32_t *dst, uint32_t *src)
{
	uint64_t i = 0, next, m;
	for (;;) {
		uint64_t e = *src;
		uint64_t v = e + i;
		m = v * 3u;
		*dst = (uint32_t)m;
		next = i + 3u;
		if (!((int64_t)next < 20))
			break;
		i = next;
	}
	return (m ^ i) + next;
}

uint32_t o_alias6(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 0, next, s;
	for (;;) {
		uint32_t x = dst[i], y = src[i];
		s = x * 3u + y;
		dst[i + 1] = s;
		next = i + 1;
		if (!((int32_t)next < 6))
			break;
		i = next;
	}
	return s + next;
}

uint32_t o_multi(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 1, ni, v, base, j = 10, nj, w2, k = 0, nk, f;
	for (;;) {
		v = *src + i;
		*src = v;
		ni = i + 2;
		if (!((int32_t)ni < 9))
			break;
		i = ni;
	}
	base = i + ni;
	for (;;) {
		w2 = *dst + j + v;
		*dst = w2;
		nj = j - 3;
		if (!((int32_t)nj > -5))
			break;
		j = nj;
	}
	for (;;) {
		f = dst[1] + k + w2;
		dst[1] = f;
		nk = k + 1;
		if (!((int32_t)nk < 9))
			break;
		k = nk;
	}
	return w2 + base + j + f + nk;
}

uint32_t o_nested(uint32_t *dst, uint32_t *src)
{
	uint32_t o = 0, no, v = 0;
	for (;;) {
		for (uint32_t k = 0; ; ) {
			uint32_t a = *dst;
			uint32_t t2 = k + o + *src;
			v = a + t2;
			*dst = v;
			uint32_t nk = k + 1;
			if (!((int32_t)nk < 3))
				break;
			k = nk;
		}
		no = o + 1;
		if (!((int32_t)no < 2))
			break;
		o = no;
	}
	return v + no;
}

uint32_t o_callbody(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 0, next, h;
	for (;;) {
		h = p117_helper(*src, i);
		*dst = h;
		next = i + 1;
		if (!((int32_t)next < 4))
			break;
		i = next;
	}
	return h + next;
}

uint32_t o_divbody(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 0, next, v;
	for (;;) {
		v = *src / 3u + i;
		*dst = v;
		next = i + 1;
		if (!((int32_t)next < 4))
			break;
		i = next;
	}
	return v + next;
}

uint32_t o_varstart(uint32_t *dst, uint32_t *src)
{
	uint32_t i = *src, next, v;
	for (;;) {
		v = *dst + i;
		*dst = v;
		next = i + 1;
		if (!(next < 4u))
			break;
		i = next;
	}
	return v + next;
}

uint32_t o_twophi(uint32_t *dst, uint32_t *src)
{
	uint32_t i = 0, next, acc = 7, v;
	for (;;) {
		acc = acc + *src;
		v = acc + i;
		*dst = v;
		next = i + 1;
		if (!((int32_t)next < 4))
			break;
		i = next;
	}
	return v + acc;
}

uint32_t o_overbudget(uint32_t *dst, uint32_t *src)
{
	uint32_t i, next, m = 0, acc = 0;
	int k;

	for (k = 0; k < 5; k++) {
		for (i = 0; ; ) {
			uint32_t v = *src + i;
			m = v * (uint32_t)(k + 3);
			*dst = m;
			next = i + 1;
			if (!((int32_t)next < 8))
				break;
			i = next;
		}
		acc = acc + m + next;
	}
	return acc;
}
