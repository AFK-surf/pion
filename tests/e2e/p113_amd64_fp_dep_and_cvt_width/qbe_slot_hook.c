/* P113 test-only QBE hook. QBE never leaves a spilled `swtof` / `sltof`
 * source in its stack slot (`amd64_op[].nmem` is 0 for both, so spill.c
 * reloads it), so the memory-operand forms are reached here directly: after
 * register allocation, the body of each `slot_*` function of slots.ssa is
 * replaced by a store of its integer argument to SLOT(0) followed by one or
 * two conversions reading that slot. Both emitters (`--obj` and text) then
 * encode `cvtsi2{ss,sd}{l,q} off(%rsp), %xmmN` from the same instructions. */
#include <string.h>
#include "amd64/all.h"

void p113_simpljmp(Fn *);

static void
inject(Fn *fn)
{
	static Ins ops[3];
	int k, op, n;

	if (strncmp(fn->name, "slot_", 5) != 0)
		return;
	/* slot_<g|i><w|l><d|s>: grouped (two conversions) or isolated. */
	if (strlen(fn->name) != 8)
		die("p113 hook: bad function name %s", fn->name);
	op = fn->name[6] == 'l' ? Osltof : Oswtof;
	k = fn->name[7] == 'd' ? Kd : Ks;
	n = 0;
	fn->slot = 8;
	ops[n++] = (Ins){op == Osltof ? Ostorel : Ostorew, Kw, R, {TMP(RDI), SLOT(0)}};
	if (fn->name[5] == 'g')
		ops[n++] = (Ins){op, k, TMP(XMM1), {SLOT(0), R}};
	ops[n++] = (Ins){op, k, TMP(XMM0), {SLOT(0), R}};
	fn->start->ins = ops;
	fn->start->nins = n;
}

void
p113_simpljmp(Fn *fn)
{
	simpljmp(fn);
	inject(fn);
}
