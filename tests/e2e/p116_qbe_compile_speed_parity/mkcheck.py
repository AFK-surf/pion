"""Write a test-only *checking* copy of vendor/qbe (never part of out/qbe).

usage: python3 -E mkcheck.py VENDOR_QBE_DIR OUT_DIR

The copy is the real source plus three in-process oracles; any disagreement
prints `p116 check FAIL ...` and aborts. With P116_STATS=<file>, every process
appends one line of counters to <file> at exit.

  live.c    `filllive` (worklist: a block is revisited only when a successor
            input changed) is renamed; the public `filllive` first runs a copy
            with the dirty-block skip removed (a full sweep every round), then
            the real one, and compares in / out / gen word for word and
            nlive[0..1] for every block. Also counts skipped visits.
  ssa.c     `phiins(fn, philive(fn))`: after the sparse candidate liveness,
            the general `filllive` runs and every candidate bit of every
            block's in and out must equal the general bit of its temporary.
            With P116_FALLBACK=1 phi placement then uses the general sets
            (the `General:` path) instead of the projection.
  arm64/macho.c
            `me_compute_gpr_out` (per-block keep / gen masks) is compared, block
            for block, with the instruction-by-instruction reverse scan it
            replaced.
"""
import shutil
import sys
from pathlib import Path


def once(text, old, new, what):
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"FAIL: p116 mkcheck: {what}: pattern found {n} times (want 1)")
    return text.replace(old, new)


STATS = r'''
#include <stdlib.h>
long p116_live_calls, p116_live_blocks, p116_live_skips;
long p116_phi_fns, p116_phi_general, p116_phi_bits, p116_phi_cands;
long p116_gpr_fns, p116_gpr_blocks;
static void
p116_dump(void)
{
	char *p = getenv("P116_STATS");
	FILE *f;

	if (!p || !(f = fopen(p, "a")))
		return;
	fprintf(f, "live_calls %ld live_blocks %ld live_skips %ld phi_fns %ld phi_general %ld "
		"phi_cands %ld phi_bits %ld gpr_fns %ld gpr_blocks %ld\n",
		p116_live_calls, p116_live_blocks, p116_live_skips, p116_phi_fns,
		p116_phi_general, p116_phi_cands, p116_phi_bits, p116_gpr_fns, p116_gpr_blocks);
	fclose(f);
}
void
p116_init(void)
{
	static int done;

	if (!done) {
		done = 1;
		atexit(p116_dump);
	}
}
'''

LIVE_CHECK = r'''
void
filllive(Fn *f)
{
	Blk *b;
	BSet *in, *out, *gen;
	int (*nl)[2];

	p116_init();
	p116_filllive_full(f);
	in = alloc(f->nblk * sizeof *in);
	out = alloc(f->nblk * sizeof *out);
	gen = alloc(f->nblk * sizeof *gen);
	nl = alloc(f->nblk * sizeof *nl);
	for (b=f->start; b; b=b->link) {
		in[b->id] = *b->in;
		out[b->id] = *b->out;
		gen[b->id] = *b->gen;
		nl[b->id][0] = b->nlive[0];
		nl[b->id][1] = b->nlive[1];
	}
	p116_filllive_fast(f);
	p116_live_calls++;
	for (b=f->start; b; b=b->link) {
		BSet *x[3] = {b->in, b->out, b->gen}, *y[3] = {&in[b->id], &out[b->id], &gen[b->id]};
		for (int k=0; k<3; k++)
			if (x[k]->nt != y[k]->nt
			|| memcmp(x[k]->t, y[k]->t, x[k]->nt * sizeof x[k]->t[0]) != 0) {
				fprintf(stderr, "p116 check FAIL: filllive %s block %s set %d differs from a full sweep\n",
					f->name, b->name, k);
				abort();
			}
		if (b->nlive[0] != nl[b->id][0] || b->nlive[1] != nl[b->id][1]) {
			fprintf(stderr, "p116 check FAIL: filllive %s block %s nlive differs from a full sweep\n",
				f->name, b->name);
			abort();
		}
		p116_live_blocks++;
	}
}
'''

SSA_CHECK = r'''
static int *
p116_philive(Fn *f)
{
	extern long p116_phi_fns, p116_phi_general, p116_phi_bits, p116_phi_cands;
	extern void p116_init(void);
	int *ti;
	BSet *in, *out;
	Blk *b;
	int t;

	p116_init();
	p116_phi_fns++;
	ti = philive(f);
	if (!ti) {
		p116_phi_general++;
		return 0;
	}
	in = alloc(f->nblk * sizeof *in);
	out = alloc(f->nblk * sizeof *out);
	for (b=f->start; b; b=b->link) {
		in[b->id] = *b->in;
		out[b->id] = *b->out;
	}
	filllive(f);
	for (t=Tmp0; t<f->ntmp; t++) {
		if (!ti[t])
			continue;
		p116_phi_cands++;
		for (b=f->start; b; b=b->link) {
			if (!!bshas(b->in, t) != !!bshas(&in[b->id], ti[t])
			|| !!bshas(b->out, t) != !!bshas(&out[b->id], ti[t])) {
				fprintf(stderr, "p116 check FAIL: philive %s block %s temporary %%%s differs from filllive\n",
					f->name, b->name, f->tmp[t].name);
				abort();
			}
			p116_phi_bits += 2;
		}
	}
	if (getenv("P116_FALLBACK"))
		return 0;
	return philive(f);
}
'''

GPR_REF = r'''
/* The reverse instruction scan that me_compute_gpr_out replaced. */
static uint64_t *
p116_gpr_ref(Fn *fn)
{
	uint64_t *in = alloc(fn->nblk * sizeof *in);
	uint64_t *out = alloc(fn->nblk * sizeof *out);
	uint64_t call_pres = 0, all_reg = 0;
	for (int r = R19; r <= LR; r++)
		call_pres |= BIT(r);
	call_pres |= BIT(SP);
	for (int r = V8; r <= V15; r++)
		call_pres |= BIT(r);
	for (int r = R0; r <= LR; r++)
		all_reg |= BIT(r);
	all_reg |= BIT(SP);
	for (int r = V0; r <= V30; r++)
		all_reg |= BIT(r);
	int changed;
	do {
		changed = 0;
		for (Blk *b = fn->start; b; b = b->link) {
			uint64_t live = 0;
			if (b->jmp.type == Jret0) {
				live = call_pres;
				if (rtype(b->jmp.arg) == RCall)
					live |= arm64_retregs(b->jmp.arg, 0) & all_reg;
				else
					live |= BIT(R0) | BIT(R1) | BIT(V0) | BIT(V1) | BIT(V2) | BIT(V3);
			} else if (b->jmp.type == Jhlt) {
				live = 0;
			} else if (b->jmp.type == Jjtbl) {
				if (b->s1)
					live |= in[b->s1->id];
				for (uint32_t j = 0; j < b->njtbl; j++)
					live |= in[b->jtbl[j]->id];
			} else {
				if (b->s1)
					live |= in[b->s1->id];
				if (b->s2)
					live |= in[b->s2->id];
			}
			if (isreg(b->jmp.arg) && (all_reg & BIT(b->jmp.arg.val)))
				live |= BIT(b->jmp.arg.val);
			out[b->id] = live;
			for (Ins *ins = &b->ins[b->nins]; ins > b->ins;) {
				--ins;
				if (ins->op == Ocall) {
					live &= call_pres;
					if (rtype(ins->arg[1]) == RCall)
						live |= arm64_argregs(ins->arg[1], 0) & all_reg;
					else
						live |= BIT(R0) | BIT(R1) | BIT(R2) | BIT(R3) | BIT(R4) | BIT(R5) | BIT(R6) | BIT(R7) | BIT(R8)
							| BIT(V0) | BIT(V1) | BIT(V2) | BIT(V3) | BIT(V4) | BIT(V5) | BIT(V6) | BIT(V7);
					if (isreg(ins->arg[0]) && (all_reg & BIT(ins->arg[0].val)))
						live |= BIT(ins->arg[0].val);
					continue;
				}
				if (isreg(ins->to) && (all_reg & BIT(ins->to.val))
				&& ins->op != Osel0 && !isxsel(ins->op))
					live &= ~BIT(ins->to.val);
				for (int j = 0; j < 2; j++) {
					Ref a = ins->arg[j];
					if (isreg(a) && (all_reg & BIT(a.val)))
						live |= BIT(a.val);
					else if (rtype(a) == RMem) {
						Mem *m = &fn->mem[a.val];
						if (isreg(m->base) && (all_reg & BIT(m->base.val)))
							live |= BIT(m->base.val);
						if (isreg(m->index) && (all_reg & BIT(m->index.val)))
							live |= BIT(m->index.val);
					}
				}
			}
			if (live != in[b->id]) {
				in[b->id] = live;
				changed = 1;
			}
		}
	} while (changed);
	return out;
}

static uint64_t *
me_compute_gpr_out(Fn *fn)
{
	extern long p116_gpr_fns, p116_gpr_blocks;
	extern void p116_init(void);
	uint64_t *ref, *fast;

	p116_init();
	ref = p116_gpr_ref(fn);
	fast = p116_gpr_fast(fn);
	p116_gpr_fns++;
	for (Blk *b = fn->start; b; b = b->link) {
		if (ref[b->id] != fast[b->id]) {
			fprintf(stderr, "p116 check FAIL: me_compute_gpr_out %s block %s: %llx != reference %llx\n",
				fn->name, b->name, (unsigned long long)fast[b->id], (unsigned long long)ref[b->id]);
			abort();
		}
		p116_gpr_blocks++;
	}
	return fast;
}
'''


def main():
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(src, out)

    live = (out / 'live.c').read_text()
    head = 'void\nfilllive(Fn *f)\n{'
    k = live.find(head)
    if k < 0 or live.count(head) != 1:
        raise SystemExit("FAIL: p116 mkcheck: live.c has no single `filllive` definition")
    body = live[k:]
    skip = '\t\tif (!first && !dirty[b->id])\n\t\t\tcontinue;\n'
    fast = once(body, skip, '\t\tif (!first && !dirty[b->id]) {\n\t\t\tp116_live_skips++;\n\t\t\tcontinue;\n\t\t}\n',
                'filllive dirty skip')
    full = once(body, skip, '', 'filllive dirty skip (full sweep)')
    fast = fast.replace(head, 'static void\np116_filllive_fast(Fn *f)\n{', 1)
    full = full.replace(head, 'static void\np116_filllive_full(Fn *f)\n{', 1)
    live = live[:k] + STATS + '\n' + full + '\n' + fast + '\n' + LIVE_CHECK
    (out / 'live.c').write_text(live)

    ssa = (out / 'ssa.c').read_text()
    ssa = once(ssa, '#include "all.h"\n', '#include "all.h"\n#include <stdlib.h>\nstatic int *p116_philive(Fn *);\n',
               'ssa.c include')
    ssa = once(ssa, 'phiins(fn, philive(fn));', 'phiins(fn, p116_philive(fn));', 'ssa() phi placement call')
    (out / 'ssa.c').write_text(ssa + SSA_CHECK)

    macho = (out / 'arm64' / 'macho.c').read_text()
    macho = once(macho, 'static uint64_t *\nme_compute_gpr_out(Fn *fn)\n{',
                 'static uint64_t *me_compute_gpr_out(Fn *);\nstatic uint64_t *\np116_gpr_fast(Fn *fn)\n{',
                 'me_compute_gpr_out definition')
    (out / 'arm64' / 'macho.c').write_text(macho + GPR_REF)
    print(f"p116 checking QBE sources in {out}")


if __name__ == '__main__':
    main()
