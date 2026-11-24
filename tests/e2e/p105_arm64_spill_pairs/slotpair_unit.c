#include "arm64/all.h"

Target T;
char debug['Z'+1];

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static Ins ld(int cls, int r, int s) { return (Ins){.op = Oload, .cls = cls, .to = TMP(r), .arg = {SLOT(s), R}}; }
static Ins cpld(int cls, int r, int s) { return (Ins){.op = Ocopy, .cls = cls, .to = TMP(r), .arg = {SLOT(s), R}}; }
static Ins st(int cls, int r, int s) { return (Ins){.op = cls == Kl ? Ostorel : Ostorew, .cls = Kw, .to = R, .arg = {TMP(r), SLOT(s)}}; }
static Ins cpst(int cls, int r, int s) { return (Ins){.op = Ocopy, .cls = cls, .to = SLOT(s), .arg = {TMP(r), R}}; }

static int pr(Ins a, Ins b, uint pad, int first, ArmSlotPair *p) { Ins v[2] = {a, b}; return arm64_slotpair(v, pad, first, p); }

int
main(void)
{
	ArmSlotPair p;
	/* 64-bit reload pair, descending program order: low slot is Rt */
	CHECK(pr(ld(Kl, R1, 6), ld(Kl, R0, 4), 0, 4, &p));
	CHECK(p.load == 1 && p.cls == Kl && p.lo == R0 && p.hi == R1 && p.offset == 16 + 16);
	CHECK(rsval(p.slot) == 4);
	/* ascending order, copy-form reload, padding counted */
	CHECK(pr(cpld(Kl, R2, 4), ld(Kl, R3, 6), 8, 4, &p));
	CHECK(p.lo == R2 && p.hi == R3 && p.offset == 16 + 8 + 16);
	/* 32-bit spill stores (store + copy-to-slot) on adjacent 4-byte slots */
	CHECK(pr(st(Kw, R5, 9), cpst(Kw, R4, 8), 0, 8, &p));
	CHECK(p.load == 0 && p.cls == Kw && p.lo == R4 && p.hi == R5 && p.offset == 16 + 32);
	/* stores may use the same source register twice */
	CHECK(pr(st(Kl, R7, 4), st(Kl, R7, 6), 0, 4, &p) && p.lo == R7 && p.hi == R7);
	/* ldp with Rt == Rt2 is UNPREDICTABLE: rejected */
	CHECK(!pr(ld(Kl, R1, 4), ld(Kl, R1, 6), 0, 4, &p));
	CHECK(!pr(ld(Kw, R1, 4), cpld(Kw, R1, 5), 0, 4, &p));
	/* user alloc slots (below firstspill) are never paired, nor straddling ones */
	CHECK(!pr(ld(Kl, R1, 0), ld(Kl, R2, 2), 0, 4, &p));
	CHECK(!pr(st(Kl, R1, 2), st(Kl, R2, 4), 0, 4, &p));
	/* incoming stack arguments (negative slots) */
	CHECK(!pr(ld(Kl, R1, -2), ld(Kl, R2, -4), 0, 0, &p));
	/* mixed load/store, mixed width, FP classes */
	CHECK(!pr(ld(Kl, R1, 4), st(Kl, R2, 6), 0, 4, &p));
	CHECK(!pr(ld(Kl, R1, 4), ld(Kw, R2, 6), 0, 4, &p));
	CHECK(!pr(ld(Kd, V1, 4), ld(Kd, V2, 6), 0, 4, &p));
	/* not adjacent / overlapping */
	CHECK(!pr(ld(Kl, R1, 4), ld(Kl, R2, 8), 0, 4, &p));
	CHECK(!pr(ld(Kl, R1, 4), ld(Kl, R2, 4), 0, 4, &p));
	CHECK(!pr(ld(Kw, R1, 4), ld(Kw, R2, 6), 0, 4, &p));
	/* misaligned 8-byte pair: offset 16 + 4*5 = 36 */
	CHECK(!pr(ld(Kl, R1, 5), ld(Kl, R2, 7), 0, 4, &p));
	/* imm7 range: offset/w <= 63 only */
	CHECK(pr(ld(Kl, R1, 122), ld(Kl, R2, 124), 0, 4, &p) && p.offset == 504);
	CHECK(!pr(ld(Kl, R1, 124), ld(Kl, R2, 126), 0, 4, &p));
	CHECK(pr(ld(Kw, R1, 59), ld(Kw, R2, 60), 0, 4, &p) && p.offset == 252);
	CHECK(!pr(ld(Kw, R1, 60), ld(Kw, R2, 61), 0, 4, &p));
	CHECK(!pr(ld(Kl, R1, 4), ld(Kl, R2, 6), 0xfffffff0u, 4, &p));
	/* fp, lr, sp, zero register constants and virtual temps */
	CHECK(!pr(ld(Kl, FP, 4), ld(Kl, R2, 6), 0, 4, &p));
	CHECK(!pr(st(Kl, LR, 4), st(Kl, R2, 6), 0, 4, &p));
	CHECK(!pr(st(Kl, SP, 4), st(Kl, R2, 6), 0, 4, &p));
	{
		Ins v[2] = {st(Kl, R1, 4), st(Kl, R2, 6)};
		v[0].arg[0] = CON_Z;
		CHECK(!arm64_slotpair(v, 0, 4, &p));
	}
	/* another op in the window */
	{
		Ins v[2] = {ld(Kl, R1, 4), {.op = Oadd, .cls = Kl, .to = TMP(R2), .arg = {TMP(R1), TMP(R1)}}};
		CHECK(!arm64_slotpair(v, 0, 4, &p));
	}
	printf(fails ? "slotpair unit: %d FAIL\n" : "slotpair unit: OK%.0d\n", fails);
	return fails != 0;
}
