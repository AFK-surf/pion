#include "all.h"
#include "config.h"
#include <ctype.h>
#include <getopt.h>

Target T;

char debug['Z'+1] = {
	['P'] = 0, /* parsing */
	['M'] = 0, /* memory optimization */
	['N'] = 0, /* ssa construction */
	['C'] = 0, /* copy elimination */
	['G'] = 0, /* gvn/gcm */
	['K'] = 0, /* if-conversion */
	['A'] = 0, /* abi lowering */
	['I'] = 0, /* instruction selection */
	['L'] = 0, /* liveness */
	['S'] = 0, /* spilling */
	['R'] = 0, /* reg. allocation */
};

extern Target T_amd64_sysv;
extern Target T_amd64_apple;
extern Target T_amd64_win;
extern Target T_arm64;
extern Target T_arm64_apple;
extern Target T_rv64;

static Target *tlist[] = {
	&T_amd64_sysv,
	&T_amd64_apple,
	&T_amd64_win,
	&T_arm64,
	&T_arm64_apple,
	&T_rv64,
	0
};
static FILE *outf;
static int dbg;
static int objmode;
static int objbatch;

static uint32_t
parse_macos_ver(const char *s)
{
	uint32_t maj = 15, min = 0, pat = 0;
	unsigned long v;
	char *end;

	if (!s || !*s)
		return (15u << 16);
	v = strtoul(s, &end, 10);
	if (end != s) {
		maj = (uint32_t)(v & 0xffffu);
		if (*end == '.') {
			s = end + 1;
			v = strtoul(s, &end, 10);
			if (end != s) {
				min = (uint32_t)(v & 0xffu);
				if (*end == '.') {
					s = end + 1;
					v = strtoul(s, &end, 10);
					if (end != s)
						pat = (uint32_t)(v & 0xffu);
				}
			}
		}
	}
	return (maj << 16) | (min << 8) | pat;
}

static void
data(Dat *d)
{
	if (dbg)
		return;
	if (objmode) {
		if (strcmp(T.name, "arm64_apple") == 0)
			arm64_macho_dat(d);
		else
			amd64_elf_dat(d);
		if (d->type == DEnd)
			freeall();
		return;
	}
	emitdat(d, outf);
	if (d->type == DEnd) {
		fputs("/* end data */\n\n", outf);
		freeall();
	}
}

static int
is_cold_rc_or_hlt(const Blk *b)
{
	if (b->jmp.type == Jhlt)
		return 1;
	if (!b->name)
		return 0;
	return strncmp(b->name, "_rci_slow_", 10) == 0
		|| strncmp(b->name, "_rcd_slow_", 10) == 0
		|| strncmp(b->name, "_rcd_drop_", 10) == 0;
}

static int
is_cold_block(const Blk *b)
{
	if (is_cold_rc_or_hlt(b))
		return 1;
	if (b->istramp && b->jmp.type == Jjmp && b->s1 && is_cold_rc_or_hlt(b->s1))
		return 1;
	return 0;
}

static void
layout_cold_blocks(Fn *fn)
{
	Blk *hot_head, *hot_tail, *cold_head, *cold_tail, *b, *next;

	/* Only enable on arm64/amd64; rv64 conditional branches have +-4KB range. */
	if (strncmp(T.name, "arm64", 5) != 0 && strncmp(T.name, "amd64", 5) != 0)
		return;
	if (!fn->start || !fn->start->link)
		return;
	hot_head = hot_tail = 0;
	cold_head = cold_tail = 0;
	for (b = fn->start->link; b; b = next) {
		next = b->link;
		b->link = 0;
		if (is_cold_block(b)) {
			if (cold_tail)
				cold_tail->link = b;
			else
				cold_head = b;
			cold_tail = b;
		} else {
			if (hot_tail)
				hot_tail->link = b;
			else
				hot_head = b;
			hot_tail = b;
		}
	}
	if (hot_head) {
		fn->start->link = hot_head;
		hot_tail->link = cold_head;
	} else {
		fn->start->link = cold_head;
	}
}

/* Give frequently revisited switch arms separate indirect branch sites.
 * A hot loop-internal predecessor (b->loop >= head->loop, not only a strict
 * back edge) that jumps to a short guard whose one side is a private short
 * jump table takes the guard and its own copy of the table block. The copy
 * branches to exactly the same arms and default. Work after allocation: the
 * incoming edge has already reconciled registers. */
enum { MaxSites = 24, MaxTable = 32 };

static int
shortdispatchblock(Blk *b)
{
	uint j;

	if (b->nins > 16)
		return 0;
	for (j=0; j<b->nins; j++)
		if (b->ins[j].op == Ocall || b->ins[j].op == Odbgloc)
			return 0;
	return 1;
}

static int
guardedtable(Blk *head, Blk *t)
{
	return t && t->jmp.type == Jjtbl && t->npred == 1 && t->pred[0] == head
		&& !t->phi && t->njtbl <= MaxTable && shortdispatchblock(t);
}

static void
replicatedispatch(Fn *fn)
{
	Blk *b, *head, *table, *other, *clone;
	Ins *seq;
	uint n, sites = 0;

	for (n=0; n<fn->nblk && sites<MaxSites; n++) {
		b = fn->rpo[n];
		head = b->s1;
		if (b->jmp.type != Jjmp || !head || b == head
		|| head->loop <= 1 || b->loop < head->loop
		|| head->npred < 3 || head->phi || !shortdispatchblock(head)
		|| !head->s1 || !head->s2)
			continue;
		/* Either side may be the table; check both in full. */
		if (guardedtable(head, head->s1))
			table = head->s1;
		else if (guardedtable(head, head->s2))
			table = head->s2;
		else
			continue;
		clone = newblk();
		clone->name = strf(PFn, "dispatch.%u", sites++);
		/* ARM64 text emission may lower instructions in place. */
		idup(clone, table->ins, table->nins);
		clone->jmp = table->jmp;
		clone->s1 = table->s1;
		clone->jtbl = table->jtbl;
		clone->njtbl = table->njtbl;
		clone->loop = table->loop;
		clone->link = b->link;
		b->link = clone;
		if (b->nins + head->nins > 0) {
			seq = alloc((b->nins + head->nins) * sizeof *seq);
			icpy(icpy(seq, b->ins, b->nins), head->ins, head->nins);
			b->ins = seq;
			b->nins += head->nins;
		}
		b->jmp = head->jmp;
		b->s1 = head->s1 == table ? clone : head->s1;
		b->s2 = head->s2 == table ? clone : head->s2;
		/* The other side gained b as a predecessor: keep a table there
		 * from passing as private until fillcfg recounts. */
		other = table == head->s1 ? head->s2 : head->s1;
		if (other != table)
			other->npred++;
	}
	if (sites)
		fillcfg(fn);
}

/* Counted-loop expansion. A single-block loop whose only phi is an integer
 * induction variable with a constant start, a constant add/sub stride and an
 * exit test against a constant (optionally through extsw/extuw) is evaluated
 * at compile time; when it leaves after 1..MaxTrips iterations, its body is
 * replaced by that many straight-line copies (in order, so loads and stores
 * keep their sequence) and the back edge is dropped. Only the induction and
 * its exit test are simulated: the body may touch memory. The last copy keeps
 * the original SSA names, so uses outside the loop need no rewriting; the phi
 * becomes a copy of the last entry value.
 * Every fold result is checked to be a CBits constant, physical registers
 * (< Tmp0) are never renamed or relied on, and the rename map is bounded by
 * the temporary count it was allocated for. */
enum { MaxTrips = 8, MaxExpanded = 96 };

static Ref
subst(Ref r, Ref *map, uint mapcap)
{
	if (rtype(r) == RTmp && (uint)r.val < mapcap && !req(map[r.val], R))
		return map[r.val];
	return r;
}

static int
constantbits(Fn *fn, Ref r)
{
	return rtype(r) == RCon && fn->con[r.val].type == CBits;
}

static int
virtualtmp(Ref r)
{
	return rtype(r) != RTmp || r.val >= Tmp0;
}

/* Number of iterations (1..MaxTrips) of the counted loop b, with the entry
 * value of the induction variable of each iteration in inputs; 0 when b is
 * not such a loop or runs longer. */
static int
trips(Fn *fn, Blk *b, Ref inputs[MaxTrips])
{
	Phi *p = b->phi;
	Ins *inc, *cmp, *ext = 0, i;
	Ref next, r, iv, test;
	int n, k, back;

	if (b->jmp.type != Jjnz || (b->s1 == b) == (b->s2 == b)
	|| !p || p->link || p->narg != 2 || KBASE(p->cls)
	|| p->blk[0] == p->blk[1])
		return 0;
	back = p->blk[1] == b;
	if (p->blk[back] != b)
		return 0;
	iv = p->arg[!back];
	next = p->arg[back];
	if (!constantbits(fn, iv) || rtype(next) != RTmp
	|| rtype(b->jmp.arg) != RTmp || rtype(p->to) != RTmp
	|| p->to.val < Tmp0 || next.val < Tmp0 || b->jmp.arg.val < Tmp0)
		return 0;
	inc = fn->tmp[next.val].def;
	cmp = fn->tmp[b->jmp.arg.val].def;
	if (!inc || !cmp || fn->tmp[next.val].bid != b->id
	|| fn->tmp[b->jmp.arg.val].bid != b->id || inc->cls != p->cls
	|| (inc->op != Oadd && inc->op != Osub)
	|| !req(inc->arg[0], p->to) || !constantbits(fn, inc->arg[1])
	|| !INRANGE(cmp->op, Ocmpw, Ocmpl1))
		return 0;
	k = constantbits(fn, cmp->arg[0]);
	r = cmp->arg[k];
	if (!constantbits(fn, cmp->arg[!k]))
		return 0;
	if (!req(r, next)) {
		if (rtype(r) != RTmp || r.val < Tmp0
		|| fn->tmp[r.val].bid != b->id
		|| !(ext = fn->tmp[r.val].def)
		|| (ext->op != Oextsw && ext->op != Oextuw)
		|| !req(ext->arg[0], next))
			return 0;
	}
	for (n=0; n<MaxTrips; n++) {
		inputs[n] = iv;
		i = *inc;
		i.arg[0] = iv;
		iv = foldref(fn, &i);
		if (!constantbits(fn, iv))
			return 0;
		test = iv;
		if (ext) {
			i = *ext;
			i.arg[0] = iv;
			test = foldref(fn, &i);
			if (!constantbits(fn, test))
				return 0;
		}
		i = *cmp;
		i.arg[k] = test;
		r = foldref(fn, &i);
		if (!constantbits(fn, r))
			return 0;
		if ((fn->con[r.val].bits.i != 0) != (b->s1 == b))
			return n + 1;
	}
	return 0;
}

static int
expandable(Ins *i)
{
	int o = i->op;

	if (!isload(o) && !isstore(o) && !isext(o)
	&& !INRANGE(o, Ocmpw, Ocmpl1) && o != Ocopy
	&& o != Oadd && o != Osub && o != Oshl && o != Omul)
		return 0;
	return virtualtmp(i->to) && virtualtmp(i->arg[0])
		&& virtualtmp(i->arg[1]);
}

/* budget: the expanded instructions the function may still spend, shared
 * by both rounds. */
static int
expandloops(Fn *fn, int *budget)
{
	Blk *b;
	Ins *dst, op;
	Ref *map = 0, orig, iv[MaxTrips];
	uint n, j, mapcap = 0;
	int t, count, changed = 0;

	for (b=fn->start; b; b=b->link) {
		if (b->nins > MaxExpanded || !(count = trips(fn, b, iv))
		|| b->nins * count > MaxExpanded || *budget <= 0
		|| b->nins * count > (uint)*budget)
			continue;
		for (n=0; n<b->nins; n++)
			if (!expandable(&b->ins[n]))
				break;
		if (n != b->nins)
			continue;
		if (!map) {
			mapcap = (uint)fn->ntmp;
			map = alloc(mapcap * sizeof *map);
			for (n=0; n<mapcap; n++)
				map[n] = R;
		}
		dst = vnew(1 + b->nins * count, sizeof *dst, PFn);
		dst[0] = (Ins){.op=Ocopy, .cls=b->phi->cls, .to=b->phi->to,
			.arg={iv[count-1], R}};
		j = 1;
		for (t=0; t<count; t++) {
			if ((uint)b->phi->to.val < mapcap)
				map[b->phi->to.val] = iv[t];
			for (n=0; n<b->nins; n++) {
				op = b->ins[n];
				op.arg[0] = subst(op.arg[0], map, mapcap);
				op.arg[1] = subst(op.arg[1], map, mapcap);
				if (rtype(op.to) == RTmp) {
					orig = op.to;
					if (t+1 != count)
						op.to = newtmp("unroll", op.cls, fn);
					if ((uint)orig.val < mapcap)
						map[orig.val] = op.to;
				}
				dst[j++] = op;
			}
		}
		if ((uint)b->phi->to.val < mapcap)
			map[b->phi->to.val] = R;
		for (n=0; n<b->nins; n++)
			if (rtype(b->ins[n].to) == RTmp
			&& (uint)b->ins[n].to.val < mapcap)
				map[b->ins[n].to.val] = R;
		if (debug['G'])
			fprintf(stderr, "\n> Expanded counted loop @%s: %d trips, %u ins\n",
				b->name, count, j - 1);
		*budget -= (int)(j - 1);
		b->phi = 0;
		b->ins = dst;
		b->nins = j;
		b->s1 = b->s1 == b ? b->s2 : b->s1;
		b->s2 = 0;
		b->jmp.type = Jjmp;
		b->jmp.arg = R;
		changed = 1;
	}
	return changed;
}

typedef struct DivKey DivKey;
struct DivKey {
	Ref x;
	int64_t d;
	int cls;
	int used;
};

static inline Ref
canon_copy_ref(Ref *cval, int ntmp, Ref r)
{
	if (rtype(r) == RTmp && r.val < ntmp)
		return cval[r.val];
	return r;
}

static int
const_divrem_val(Fn *fn, Ref cr, int k, int64_t *out_d)
{
	if (KBASE(k) != 0 || rtype(cr) != RCon || fn->con[cr.val].type != CBits)
		return 0;
	int64_t d = KWIDE(k) ? fn->con[cr.val].bits.i
		: (int64_t)(int32_t)fn->con[cr.val].bits.i;
	int64_t min_d = KWIDE(k) ? INT64_MIN : (int64_t)INT32_MIN;
	if (d == min_d || (d > -2 && d < 2))
		return 0;
	uint64_t ad = d < 0 ? (uint64_t)(0ULL - (uint64_t)d) : (uint64_t)d;
	if ((ad & (ad - 1ULL)) == 0)
		return 0;
	*out_d = d;
	return 1;
}

static uint64_t
divkey_hash(Ref x, int64_t d, int cls)
{
	uint64_t h = ((uint64_t)x.type << 32) ^ (uint64_t)x.val;
	h ^= (uint64_t)d * 11400714819323198485ULL;
	h ^= (uint64_t)cls * 2654435761ULL;
	h ^= h >> 33;
	return h;
}

/* Rewrite signed integer `rem x, d` with non-power-of-two constant `d`
 * (excluding 0, +/-1, INT_MIN) into `q = div x, d; p = mul q, d; r = sub x, p`
 * ONLY when a matching `div x, d` (same canonical dividend, divisor and class)
 * exists in the same basic block. Runs after loadopt/coalesce and before GVN so
 * it stays inside qbe_tv's validation window, shares one magic multiply / div
 * across all targets, keeps standalone `remw`/`rem` on RV64 (including mutually
 * exclusive sibling branches), and preserves arm64 `rem +/-2^k == 0 -> tst`. */
static void
rewrite_const_rem(Fn *fn)
{
	Blk *b;
	Ins *i, *dst;
	Ref *cval;
	DivKey stk_ht[64], *ht;
	uint bi, n, extra, j, ndiv, nrem, cap, mask;
	int t, changed = 0;

	/* Linear single-pass RPO Ocopy chain folding. */
	cval = vnew(fn->ntmp, sizeof *cval, PFn);
	for (t = 0; t < fn->ntmp; t++)
		cval[t] = TMP(t);
	for (bi = 0; bi < fn->nblk; bi++) {
		b = fn->rpo[bi];
		for (n = 0; n < b->nins; n++) {
			i = &b->ins[n];
			if (i->op == Ocopy && rtype(i->to) == RTmp && i->to.val < fn->ntmp)
				cval[i->to.val] = canon_copy_ref(cval, fn->ntmp, i->arg[0]);
		}
	}

	for (bi = 0; bi < fn->nblk; bi++) {
		b = fn->rpo[bi];
		ndiv = 0;
		nrem = 0;
		for (n = 0; n < b->nins; n++) {
			int64_t d;
			i = &b->ins[n];
			if ((i->op == Odiv || i->op == Orem)
			&& const_divrem_val(fn, canon_copy_ref(cval, fn->ntmp, i->arg[1]), i->cls, &d)) {
				if (i->op == Odiv) {
					if (rtype(i->to) == RTmp && i->to.val < fn->ntmp && fn->tmp[i->to.val].nuse > 0)
						ndiv++;
				} else {
					nrem++;
				}
			}
		}
		if (ndiv == 0 || nrem == 0)
			continue;

		cap = 16;
		while (cap < ndiv * 2)
			cap <<= 1;
		mask = cap - 1;
		ht = (cap <= 64) ? stk_ht : alloc(cap * sizeof *ht);
		memset(ht, 0, cap * sizeof *ht);

		for (n = 0; n < b->nins; n++) {
			int64_t d;
			i = &b->ins[n];
			if (i->op != Odiv
			|| rtype(i->to) != RTmp || i->to.val >= fn->ntmp || fn->tmp[i->to.val].nuse == 0)
				continue;
			Ref cr = canon_copy_ref(cval, fn->ntmp, i->arg[1]);
			if (!const_divrem_val(fn, cr, i->cls, &d))
				continue;
			Ref cx = canon_copy_ref(cval, fn->ntmp, i->arg[0]);
			uint idx = (uint)divkey_hash(cx, d, i->cls) & mask;
			for (;;) {
				if (!ht[idx].used) {
					ht[idx] = (DivKey){.x = cx, .d = d, .cls = i->cls, .used = 1};
					break;
				}
				if (req(ht[idx].x, cx) && ht[idx].d == d && ht[idx].cls == i->cls)
					break;
				idx = (idx + 1) & mask;
			}
		}

		extra = 0;
		for (n = 0; n < b->nins; n++) {
			int64_t d;
			i = &b->ins[n];
			if (i->op != Orem)
				continue;
			Ref cr = canon_copy_ref(cval, fn->ntmp, i->arg[1]);
			if (!const_divrem_val(fn, cr, i->cls, &d))
				continue;
			Ref cx = canon_copy_ref(cval, fn->ntmp, i->arg[0]);
			uint idx = (uint)divkey_hash(cx, d, i->cls) & mask;
			while (ht[idx].used) {
				if (req(ht[idx].x, cx) && ht[idx].d == d && ht[idx].cls == i->cls) {
					extra++;
					break;
				}
				idx = (idx + 1) & mask;
			}
		}
		if (extra == 0)
			continue;
		dst = vnew(b->nins + extra * 2, sizeof *dst, PFn);
		j = 0;
		for (n = 0; n < b->nins; n++) {
			int64_t d;
			i = &b->ins[n];
			if (i->op == Orem) {
				Ref cr = canon_copy_ref(cval, fn->ntmp, i->arg[1]);
				if (const_divrem_val(fn, cr, i->cls, &d)) {
					Ref cx = canon_copy_ref(cval, fn->ntmp, i->arg[0]);
					uint idx = (uint)divkey_hash(cx, d, i->cls) & mask;
					int found = 0;
					while (ht[idx].used) {
						if (req(ht[idx].x, cx) && ht[idx].d == d && ht[idx].cls == i->cls) {
							found = 1;
							break;
						}
						idx = (idx + 1) & mask;
					}
					if (found) {
						int k = i->cls;
						Ref q = newtmp("rem", k, fn);
						Ref p = newtmp("rem", k, fn);
						dst[j++] = (Ins){.op = Odiv, .cls = k, .to = q, .arg = {i->arg[0], cr}};
						dst[j++] = (Ins){.op = Omul, .cls = k, .to = p, .arg = {q, cr}};
						dst[j++] = (Ins){.op = Osub, .cls = k, .to = i->to, .arg = {i->arg[0], p}};
						changed = 1;
						continue;
					}
				}
			}
			dst[j++] = *i;
		}
		b->ins = dst;
		b->nins = j;
	}
	if (changed) {
		filluse(fn);
		ssacheck(fn);
	}
}

#include "slp.h"

static void
func(Fn *fn)
{
	uint n;

	if (dbg)
		fprintf(stderr, "**** Function %s ****", fn->name);
	if (debug['P']) {
		fprintf(stderr, "\n> After parsing:\n");
		printfn(fn, stderr);
	}
	T.abi0(fn);
	fillcfg(fn);
	filluse(fn);
	promote(fn);
	filluse(fn);
	ssa(fn);
	filluse(fn);
	ssacheck(fn);
	fillalias(fn);
	loadopt(fn);
	filluse(fn);
	fillalias(fn);
	coalesce(fn);
	filluse(fn);
	filldom(fn);
	ssacheck(fn);
	rewrite_const_rem(fn);
	gvn(fn);
	fillcfg(fn);
	simplcfg(fn);
	filluse(fn);
	filldom(fn);
	gcm(fn);
	filluse(fn);
	ssacheck(fn);
	/* At most two rounds (a nested loop can become a single block after
	 * the first), sharing one budget of 2 * MaxExpanded instructions. */
	int budget = 2 * MaxExpanded;
	for (int round=0; round<2 && budget > 0 && expandloops(fn, &budget); round++) {
		fillcfg(fn);
		filluse(fn);
		filldom(fn);
		gvn(fn);
		fillcfg(fn);
		simplcfg(fn);
		filluse(fn);
		filldom(fn);
		gcm(fn);
		filluse(fn);
		ssacheck(fn);
	}
	if (T.cansel) {
		ifconvert(fn);
		fillcfg(fn);
		filluse(fn);
		filldom(fn);
		ssacheck(fn);
	}
	T.abi1(fn);
	simpl(fn);
	fillcfg(fn);
	filluse(fn);
	T.isel(fn);
	fillcfg(fn);
	/* Constant hoisting and SLP scheduling move instructions, preserving
	 * the selected CFG and its loop weights through liveness. */
	fillloop(fn);
	if (strncmp(T.name, "arm64", 5) == 0) {
		filldom(fn);
		arm64_hoist_consts(fn);
	} else if (strncmp(T.name, "amd64", 5) == 0) {
		filldom(fn);
		amd64_hoist_consts(fn);
	}
	Fn *packet = slpsnapshot(fn);
	filllive(fn);
	fillcost(fn);
	spill(fn);
	rega(fn);
	signed char *order = slporder;
	slporder = 0;
	if (packet && slpbuild(packet, order)) {
		filllive(packet);
		fillcost(packet);
		spill(packet);
		rega(packet);
		int supported = 1;
		/* pmrec widens a parallel-copy cycle to its largest class. A
		 * narrower stack home in a mixed cycle must never be widened. */
		for (Blk *b = packet->start; b; b = b->link)
			for (uint j = 0; j < b->nins; j++) {
				Ins i = b->ins[j];
				if (i.op == Oswap && i.cls == Kv2d &&
				    (!isreg(i.arg[0]) || !isreg(i.arg[1])))
					supported = 0;
			}
		if (supported && !slpchangesenv(packet))
			fn = slpversion(fn, packet);
	}
	fillcfg(fn);
	simpljmp(fn);
	fillcfg(fn);
	if (strcmp(T.name, "arm64_apple") == 0)
		replicatedispatch(fn);
	assert(fn->rpo[0] == fn->start);
	for (n=0;; n++)
		if (n == fn->nblk-1) {
			fn->rpo[n]->link = 0;
			break;
		} else
			fn->rpo[n]->link = fn->rpo[n+1];
	layout_cold_blocks(fn);
	if (!dbg) {
		if (objmode) {
			if (strcmp(T.name, "arm64_apple") == 0)
				arm64_macho_fn(fn);
			else
				amd64_elf_fn(fn);
		} else {
			T.emitfn(fn, outf);
			fprintf(outf, "/* end function %s */\n\n", fn->name);
		}
	} else
		fprintf(stderr, "\n");
	freeall();
}

static void
dbgfile(char *fn)
{
	if (objmode)
		return;
	emitdbgfile(fn, outf);
}

static void
usage(FILE *hf, char *prog)
{
	Target **t;
	char *sep;

	fprintf(hf, "%s [OPTIONS] {file.ssa, -}\n", prog);
	fprintf(hf, "\t%-18s prints this help\n", "-h");
	fprintf(hf, "\t%-18s output to file\n", "-o file");
	fprintf(hf, "\t%-18s emit .o directly (arm64_apple Mach-O / amd64_sysv ELF64)\n", "--obj");
	fprintf(hf, "\t%-18s batch emit .o pairs <in.ssa> <out.o>...\n", "--obj-batch");
	fprintf(hf, "\t%-18s amd64_win: Microsoft x64 unwind info (.seh_*)\n", "--seh");
	fprintf(hf, "\t%-18s macOS platform version (e.g. 15.0)\n", "--macos-ver <ver>");
	fprintf(hf, "\t%-18s generate for a target among:\n", "-t <target>");
	fprintf(hf, "\t%-18s ", "");
	for (t=tlist, sep=""; *t; t++, sep=", ") {
		fprintf(hf, "%s%s", sep, (*t)->name);
		if (*t == &Deftgt)
			fputs(" (default)", hf);
	}
	fprintf(hf, "\n");
	fprintf(hf, "\t%-18s dump debug information\n", "-d <flags>");
}

/* A short write (full disk, RLIMIT_FSIZE) may only surface when the
 * buffer is flushed: fail instead of leaving a truncated output behind
 * an exit status of 0. */
static void
closeout(FILE *f, char *path)
{
	int err;

	err = fflush(f) != 0;
	err |= ferror(f) != 0;
	if (f != stdout)
		err |= fclose(f) != 0;
	if (err) {
		fprintf(stderr, "error writing '%s'\n", path);
		exit(1);
	}
}

int
main(int ac, char *av[])
{
	Target **t;
	FILE *inf;
	char *f, *outpath, *arg;
	uint32_t macos_ver;
	int i, nfiles;
	char **files;

	T = Deftgt;
	outf = stdout;
	outpath = 0;
	macos_ver = (15u << 16);
	{
		const char *sj = getenv("PION_QBE_STRICT_JNZ");
		if (sj && strcmp(sj, "1") == 0)
			strict_jnz = 1;
	}
	files = emalloc((size_t)(ac + 1) * sizeof *files);
	nfiles = 0;

	for (i = 1; i < ac; i++) {
		arg = av[i];
		if (strcmp(arg, "--") == 0) {
			for (i++; i < ac; i++)
				files[nfiles++] = av[i];
			break;
		}
		if (strcmp(arg, "--obj") == 0 || strcmp(arg, "-O") == 0) {
			objmode = 1;
		} else if (strcmp(arg, "--obj-batch") == 0) {
			objmode = 1;
			objbatch = 1;
		} else if (strcmp(arg, "--strict-jnz") == 0 || strcmp(arg, "-strict-jnz") == 0) {
			strict_jnz = 1;
		} else if (strcmp(arg, "--seh") == 0) {
			win_seh = 1;
		} else if (strcmp(arg, "--macos-ver") == 0) {
			if (i + 1 >= ac) {
				usage(stderr, av[0]);
				exit(1);
			}
			macos_ver = parse_macos_ver(av[++i]);
		} else if (strncmp(arg, "--macos-ver=", 12) == 0) {
			macos_ver = parse_macos_ver(arg + 12);
		} else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
			usage(stdout, av[0]);
			exit(0);
		} else if (arg[0] == '-' && arg[1] != '\0') {
			char opt = arg[1];
			char *val = arg[2] ? arg + 2 : 0;
			switch (opt) {
			case 'd':
				if (!val) {
					if (i + 1 >= ac) { usage(stderr, av[0]); exit(1); }
					val = av[++i];
				}
				for (; *val; val++)
					if (isalpha((unsigned char)*val)) {
						debug[toupper((unsigned char)*val)] = 1;
						dbg = 1;
					}
				break;
			case 'o':
				if (!val) {
					if (i + 1 >= ac) { usage(stderr, av[0]); exit(1); }
					val = av[++i];
				}
				outpath = val;
				break;
			case 't':
				if (!val) {
					if (i + 1 >= ac) { usage(stderr, av[0]); exit(1); }
					val = av[++i];
				}
				if (strcmp(val, "?") == 0) {
					puts(T.name);
					exit(0);
				}
				for (t=tlist;; t++) {
					if (!*t) {
						fprintf(stderr, "unknown target '%s'\n", val);
						exit(1);
					}
					if (strcmp(val, (*t)->name) == 0) {
						T = **t;
						break;
					}
				}
				break;
			default:
				usage(stderr, av[0]);
				exit(1);
			}
		} else {
			files[nfiles++] = arg;
		}
	}

	int is_arm64_macho = (strcmp(T.name, "arm64_apple") == 0);
	int is_amd64_elf = (strcmp(T.name, "amd64_sysv") == 0);

	if (objmode && !is_arm64_macho && !is_amd64_elf) {
		fprintf(stderr, "--obj is only supported for targets arm64_apple and amd64_sysv\n");
		exit(1);
	}

	if (objbatch) {
		if (nfiles == 0 || (nfiles & 1) != 0) {
			fprintf(stderr, "--obj-batch requires pairs of <in.ssa> <out.o>\n");
			exit(1);
		}
		if (outpath) {
			fprintf(stderr, "--obj-batch cannot be combined with -o\n");
			exit(1);
		}
		for (i = 0; i < nfiles; i += 2) {
			char *in_p = files[i];
			char *out_p = files[i + 1];
			inf = fopen(in_p, "r");
			if (!inf) {
				fprintf(stderr, "cannot open '%s'\n", in_p);
				exit(1);
			}
			outf = fopen(out_p, "wb");
			if (!outf) {
				fclose(inf);
				fprintf(stderr, "cannot open '%s'\n", out_p);
				exit(1);
			}
			emit_reset();
			util_reset();
			if (!dbg) {
				if (is_arm64_macho)
					arm64_macho_begin(macos_ver);
				else
					amd64_elf_begin();
			}
			parse(inf, in_p, dbgfile, data, func);
			fclose(inf);
			if (!dbg) {
				if (is_arm64_macho)
					arm64_macho_finish(outf);
				else
					amd64_elf_finish(outf);
			}
			closeout(outf, out_p);
			outf = stdout;
		}
		free(files);
		exit(0);
	}

	if (outpath && strcmp(outpath, "-") != 0) {
		outf = fopen(outpath, objmode ? "wb" : "w");
		if (!outf) {
			fprintf(stderr, "cannot open '%s'\n", outpath);
			exit(1);
		}
	}

	if (objmode && !dbg) {
		if (is_arm64_macho)
			arm64_macho_begin(macos_ver);
		else
			amd64_elf_begin();
	}

	if (nfiles == 0)
		files[nfiles++] = "-";

	for (i = 0; i < nfiles; i++) {
		f = files[i];
		if (!f || strcmp(f, "-") == 0) {
			inf = stdin;
			f = "-";
		} else {
			inf = fopen(f, "r");
			if (!inf) {
				fprintf(stderr, "cannot open '%s'\n", f);
				exit(1);
			}
		}
		parse(inf, f, dbgfile, data, func);
		if (inf != stdin)
			fclose(inf);
	}

	if (!dbg) {
		if (objmode) {
			if (is_arm64_macho)
				arm64_macho_finish(outf);
			else
				amd64_elf_finish(outf);
		} else
			T.emitfin(outf);
	}

	closeout(outf, outf == stdout ? "<stdout>" : outpath);
	free(files);
	exit(0);
}
