/* Exact-result checks for tests/tv/qbe_bugs/qbe_bugs.ssa (B1-B12). */
#include <stdint.h>
#include <stdio.h>

int64_t bug1_dedupjmp_lowbits(void);
int64_t bug2_phi_class(int32_t, int64_t, int64_t);
int32_t bug3_dwl_shr32(int64_t);
int32_t bug4a_amd64_jnz_l_and(int64_t);
int32_t bug4b_amd64_jnz_l_neg(int64_t);
int32_t bug4c_amd64_sel_l_and(int64_t, int64_t, int32_t, int32_t);
int32_t bug5_amd64_shift_zflag(int32_t, int32_t, int64_t);
int64_t bug6_amd64_shift_imm(int64_t, int32_t);
int32_t bug7_dwl_phi_retry(int32_t, int32_t, int32_t);
int32_t bug8_dwl_phi_cycle(int32_t, int32_t, int32_t);
int64_t bug9_gvn_jnz_retl(int64_t);
int32_t bug10_load_shr_mask(int32_t);
int64_t bug11a_promote_loadsw(int64_t);
int64_t bug11b_promote_loaduw(int64_t);
int64_t bug11c_promote_s_loadsw(int32_t);
int64_t bug11d_promote_s_loaduw(int32_t);
int64_t bug12_cnew_l_result(int32_t);

static int fails;

static void
check(const char *what, int64_t want, int64_t got)
{
	if (want != got) {
		printf("FAIL %s: want %lld (0x%llx), got %lld (0x%llx)\n", what,
		       (long long)want, (unsigned long long)want,
		       (long long)got, (unsigned long long)got);
		fails++;
	}
}

static int64_t
b6(int64_t c, int32_t a)
{
	uint64_t r0 = (uint64_t)c << 63;
	uint64_t r1 = (uint64_t)c;          /* shr by 64: count 0 */
	int32_t r2 = a >> 1;                /* sar w by -31: count 1 */
	return (int64_t)(r0 ^ r1 ^ (uint64_t)(int64_t)r2);
}

int
main(void)
{
	static const int64_t ls[] = {
		0, 1, -1, 2, 5, 0x7fffffff, 0x80000000LL, 0xffffffffLL,
		0x100000000LL, 0x100000005LL, 0x123456789abcdefLL,
		-0x100000000LL, INT64_MIN, INT64_MAX,
	};
	const int n = sizeof ls / sizeof ls[0];
	char what[96];
	int i, j;

	check("bug1_dedupjmp_lowbits()", 2, bug1_dedupjmp_lowbits());

	for (i = 0; i < n; i++)
		for (j = 0; j < n; j++) {
			snprintf(what, sizeof what, "bug2_phi_class(1, %lld, %lld)",
			         (long long)ls[i], (long long)ls[j]);
			check(what, (int64_t)(0 - (uint64_t)ls[i]),
			      bug2_phi_class(1, ls[i], ls[j]));
			snprintf(what, sizeof what, "bug2_phi_class(0, %lld, %lld)",
			         (long long)ls[i], (long long)ls[j]);
			check(what, (int64_t)(0 - (uint64_t)ls[j]),
			      bug2_phi_class(0, ls[i], ls[j]));
		}

	for (i = 0; i < n; i++) {
		int64_t c = ls[i];
		uint32_t lo = (uint32_t)c;

		snprintf(what, sizeof what, "bug3_dwl_shr32(%lld)", (long long)c);
		check(what, (uint16_t)c & 3, bug3_dwl_shr32(c));
		snprintf(what, sizeof what, "bug4a_amd64_jnz_l_and(%lld)", (long long)c);
		check(what, 2, bug4a_amd64_jnz_l_and(c));
		snprintf(what, sizeof what, "bug4b_amd64_jnz_l_neg(%lld)", (long long)c);
		check(what, (uint32_t)(0u - lo) ? 1 : 2, bug4b_amd64_jnz_l_neg(c));
		for (j = 0; j < n; j++) {
			int64_t m = ls[j];
			snprintf(what, sizeof what, "bug4c_amd64_sel_l_and(%lld, %lld)",
			         (long long)c, (long long)m);
			check(what, (uint32_t)(c & m) ? 10 : 20,
			      bug4c_amd64_sel_l_and(c, m, 10, 20));
			snprintf(what, sizeof what, "bug6_amd64_shift_imm(%lld, %d)",
			         (long long)c, (int32_t)m);
			check(what, b6(c, (int32_t)m), bug6_amd64_shift_imm(c, (int32_t)m));
		}
	}

	{
		static const int32_t as[] = { 0, 1, -1, 0x40000000, 7 };
		static const int64_t ks[] = { 0, 32, 64, 96, 0x100000020LL, 1, 33 };
		int na = sizeof as / sizeof as[0], nk = sizeof ks / sizeof ks[0];
		for (i = 0; i < na; i++)
			for (j = 0; j < nk; j++) {
				int32_t k = (int32_t)ks[j];
				uint32_t s = (uint32_t)as[i] << (k & 31);
				snprintf(what, sizeof what,
				         "bug5_amd64_shift_zflag(%d, %d, %lld)",
				         as[i], k, (long long)ks[j]);
				check(what, s ? 1 : 2, bug5_amd64_shift_zflag(as[i], k, ks[j]));
			}
	}

	for (i = 0; i < n; i++) {
		int64_t c = ls[i];
		int32_t lo = (int32_t)(uint32_t)c;
		int32_t y = (int32_t)(uint32_t)ls[(i + 1) % n];

		snprintf(what, sizeof what, "bug7_dwl_phi_retry(1, %d, %d)", lo, y);
		check(what, (uint16_t)lo, bug7_dwl_phi_retry(1, lo, y));
		snprintf(what, sizeof what, "bug7_dwl_phi_retry(0, %d, %d)", lo, y);
		check(what, (uint16_t)y, bug7_dwl_phi_retry(0, lo, y));
		snprintf(what, sizeof what, "bug8_dwl_phi_cycle(1, 0, %d)", lo);
		check(what, (uint16_t)lo, bug8_dwl_phi_cycle(1, 0, lo));
		snprintf(what, sizeof what, "bug8_dwl_phi_cycle(0, 0, %d)", lo);
		check(what, (uint16_t)(lo & 1), bug8_dwl_phi_cycle(0, 0, lo));
		snprintf(what, sizeof what, "bug9_gvn_jnz_retl(%lld)", (long long)c);
		check(what, (uint32_t)c ? 7 : c, bug9_gvn_jnz_retl(c));
		snprintf(what, sizeof what, "bug10_load_shr_mask(%d)", lo);
		check(what, ((uint32_t)lo >> 8) & 0xff, bug10_load_shr_mask(lo));
		snprintf(what, sizeof what, "bug11a_promote_loadsw(%lld)", (long long)c);
		check(what, (int64_t)lo, bug11a_promote_loadsw(c));
		snprintf(what, sizeof what, "bug11b_promote_loaduw(%lld)", (long long)c);
		check(what, (int64_t)(uint32_t)lo, bug11b_promote_loaduw(c));
		snprintf(what, sizeof what, "bug11c_promote_s_loadsw(%d)", lo);
		check(what, (int64_t)lo, bug11c_promote_s_loadsw(lo));
		snprintf(what, sizeof what, "bug11d_promote_s_loaduw(%d)", lo);
		check(what, (int64_t)(uint32_t)lo, bug11d_promote_s_loaduw(lo));
		snprintf(what, sizeof what, "bug12_cnew_l_result(%d)", lo);
		check(what, lo < 0, bug12_cnew_l_result(lo));
	}

	if (fails) {
		printf("qbe_bugs: %d check(s) failed\n", fails);
		return 1;
	}
	printf("qbe_bugs: all checks passed\n");
	return 0;
}
