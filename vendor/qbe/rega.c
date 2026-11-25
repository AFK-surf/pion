#include "all.h"

#ifdef TEST_PMOV
	#undef assert
	#define assert(x) assert_test(#x, x)
#endif

typedef struct RMap RMap;

struct RMap {
	int t[Tmp0];
	int r[Tmp0];
	int w[Tmp0];   /* wait list, for unmatched hints */
	BSet b[1];
	int n;
};

enum {
	NPm = 64,      /* max copies in a parallel move */
};

static bits regu;      /* registers used */
static Tmp *tmp;       /* function temporaries */
static Mem *mem;       /* function mem references */
static struct {
	Ref src, dst;
	int cls;
} pm[NPm];             /* parallel move constructed */
static int npm;        /* size of pm */
static int loop;       /* current loop level */

static uint stmov;     /* stats: added moves */
static uint stblk;     /* stats: added blocks */

static int *
hint(int t)
{
	return &tmp[phicls(t, tmp)].hint.r;
}

static void
sethint(int t, int r)
{
	Tmp *p;

	p = &tmp[phicls(t, tmp)];
	if (p->hint.r == -1 || p->hint.w < loop) {
		p->hint.r = r;
		p->hint.w = loop;
		tmp[t].visit = -1;
	}
}

/* Block snapshots use the ordered bindings. Only the entry snapshot
 * also needs to query and reserve physical registers during edge moves. */
static void
snapshot(RMap *dst, RMap *src)
{
	memcpy(dst->t, src->t, src->n * sizeof src->t[0]);
	memcpy(dst->r, src->r, src->n * sizeof src->r[0]);
	dst->n = src->n;
}

static int
rfind(RMap *m, int t)
{
	int i;

	for (i=0; i<m->n; i++)
		if (m->t[i] == t)
			return m->r[i];
	return -1;
}

static Ref
rref(RMap *m, int t)
{
	int r, s;

	r = rfind(m, t);
	if (r == -1) {
		s = tmp[t].slot;
		assert(s != -1 && "should have spilled");
		return SLOT(s);
	} else
		return TMP(r);
}

static void
radd(RMap *m, int t, int r)
{
	assert((t >= Tmp0 || t == r) && "invalid temporary");
	assert(((T.gpr0 <= r && r < T.gpr0 + T.ngpr)
		|| (T.fpr0 <= r && r < T.fpr0 + T.nfpr))
		&& "invalid register");
	assert(!bshas(m->b, t) && "temporary has mapping");
	assert(!bshas(m->b, r) && "register already allocated");
	assert(m->n <= T.ngpr+T.nfpr && "too many mappings");
	bsset(m->b, t);
	bsset(m->b, r);
	m->t[m->n] = t;
	m->r[m->n] = r;
	m->n++;
	regu |= BIT(r);
}

static Ref
ralloctry(RMap *m, int t, int try)
{
	bits regs;
	int h, r, r0, r1;

	if (t < Tmp0) {
		assert(bshas(m->b, t));
		return TMP(t);
	}
	if (bshas(m->b, t)) {
		r = rfind(m, t);
		assert(r != -1);
		return TMP(r);
	}
	r = tmp[t].visit;
	if (r == -1 || bshas(m->b, r))
		r = *hint(t);
	if (r == -1 || bshas(m->b, r)) {
		if (try)
			return R;
		regs = tmp[phicls(t, tmp)].hint.m;
		regs |= m->b->t[0];
		if (KBASE(tmp[t].cls) == 0) {
			r0 = T.gpr0;
			r1 = r0 + T.ngpr;
		} else {
			r0 = T.fpr0;
			r1 = r0 + T.nfpr;
		}
		for (r=r0; r<r1; r++)
			if (!(regs & BIT(r)))
				goto Found;
		for (r=r0; r<r1; r++)
			if (!bshas(m->b, r))
				goto Found;
		die("no more regs");
	}
Found:
	radd(m, t, r);
	sethint(t, r);
	tmp[t].visit = r;
	h = *hint(t);
	if (h != -1 && h != r)
		m->w[h] = t;
	return TMP(r);
}

static inline Ref
ralloc(RMap *m, int t)
{
	return ralloctry(m, t, 0);
}

static int
rfree(RMap *m, int t)
{
	int i, r;

	assert(t >= Tmp0 || !(BIT(t) & T.rglob));
	if (!bshas(m->b, t))
		return -1;
	for (i=0; m->t[i] != t; i++)
		assert(i+1 < m->n);
	r = m->r[i];
	bsclr(m->b, t);
	bsclr(m->b, r);
	m->n--;
	memmove(&m->t[i], &m->t[i+1], (m->n-i) * sizeof m->t[0]);
	memmove(&m->r[i], &m->r[i+1], (m->n-i) * sizeof m->r[0]);
	assert(t >= Tmp0 || t == r);
	return r;
}

static void
mdump(RMap *m)
{
	int i;

	for (i=0; i<m->n; i++)
		if (m->t[i] >= Tmp0)
			fprintf(stderr, " (%s, R%d)",
				tmp[m->t[i]].name,
				m->r[i]);
	fprintf(stderr, "\n");
}

static void
pmadd(Ref src, Ref dst, int k)
{
	if (npm == NPm)
		die("no more pm slots");
	pm[npm].src = src;
	pm[npm].dst = dst;
	pm[npm].cls = k;
	npm++;
}

enum PMStat { ToMove, Moving, Moved };

static int
pmrec(enum PMStat *status, int i, int *k)
{
	int j, c;

	/* note, this routine might emit
	 * too many large instructions
	 */
	if (req(pm[i].src, pm[i].dst)) {
		status[i] = Moved;
		return -1;
	}
	assert(KBASE(pm[i].cls) == KBASE(*k));
	assert((Kw|Kl) == Kl && (Ks|Kd) == Kd);
	*k |= pm[i].cls;
	for (j=0; j<npm; j++)
		if (req(pm[j].dst, pm[i].src))
			break;
	switch (j == npm ? Moved : status[j]) {
	case Moving:
		c = j; /* start of cycle */
		emit(Oswap, *k, R, pm[i].src, pm[i].dst);
		break;
	case ToMove:
		status[i] = Moving;
		c = pmrec(status, j, k);
		if (c == i) {
			c = -1; /* end of cycle */
			break;
		}
		if (c != -1) {
			emit(Oswap, *k, R, pm[i].src, pm[i].dst);
			break;
		}
		/* fall through */
	case Moved:
		c = -1;
		emit(Ocopy, pm[i].cls, pm[i].dst, pm[i].src, R);
		break;
	default:
		die("unreachable");
	}
	status[i] = Moved;
	return c;
}

static void
pmgen()
{
	int i;
	enum PMStat status[NPm];

	assert(npm <= NPm);
	memset(status, 0, (size_t)npm * sizeof status[0]);
	assert(!npm || status[npm-1] == ToMove);
	for (i=0; i<npm; i++)
		if (status[i] == ToMove)
			pmrec(status, i, (int[]){pm[i].cls});
}

static void
move(int r, Ref to, RMap *m)
{
	int n, t, r1;

	r1 = req(to, R) ? -1 : rfree(m, to.val);
	if (bshas(m->b, r)) {
		/* r is used and not by to */
		assert(r1 != r);
		for (n=0; m->r[n] != r; n++)
			assert(n+1 < m->n);
		t = m->t[n];
		rfree(m, t);
		bsset(m->b, r);
		ralloc(m, t);
		bsclr(m->b, r);
	}
	t = req(to, R) ? r : to.val;
	radd(m, t, r);
}

static int
regcpy(Ins *i)
{
	return i->op == Ocopy && isreg(i->arg[0]);
}

static Ins *
dopm(Blk *b, Ins *i, RMap *m)
{
	RMap m0;
	int n, r, r1, t, s;
	Ins *i1, *ip;
	bits def;

	m0 = *m; /* okay since we don't use m0.b */
	m0.b->t = 0;
	i1 = ++i;
	do {
		i--;
		move(i->arg[0].val, i->to, m);
	} while (i != b->ins && regcpy(i-1));
	assert(m0.n <= m->n);
	if (i != b->ins && (i-1)->op == Ocall) {
		def = T.retregs((i-1)->arg[1], 0) | T.rglob;
		for (r=0; T.rsave[r]>=0; r++)
			if (!(BIT(T.rsave[r]) & def))
				move(T.rsave[r], R, m);
	}
	for (npm=0, n=0; n<m->n; n++) {
		t = m->t[n];
		s = tmp[t].slot;
		r1 = m->r[n];
		r = rfind(&m0, t);
		if (r != -1)
			pmadd(TMP(r1), TMP(r), tmp[t].cls);
		else if (s != -1)
			pmadd(TMP(r1), SLOT(s), tmp[t].cls);
	}
	for (ip=i; ip<i1; ip++) {
		if (!req(ip->to, R))
			rfree(m, ip->to.val);
		r = ip->arg[0].val;
		if (rfind(m, r) == -1)
			radd(m, r, r);
	}
	pmgen();
	return i;
}

static int
prio1(Ref r1, Ref r2)
{
	/* trivial heuristic to begin with,
	 * later we can use the distance to
	 * the definition instruction
	 */
	(void) r2;
	return *hint(r1.val) != -1;
}

static void
insert(Ref *r, Ref **rs, int p)
{
	int i;

	rs[i = p] = r;
	while (i-- > 0 && prio1(*r, *rs[i])) {
		rs[i+1] = rs[i];
		rs[i] = r;
	}
}

static void
doblk(Blk *b, RMap *cur)
{
	int t, x, r, rf, rt, nr;
	bits rs;
	Ins *i, *i1;
	Mem *m;
	Ref *ra[4];

	if (rtype(b->jmp.arg) == RTmp)
		b->jmp.arg = ralloc(cur, b->jmp.arg.val);
	curi = &insb[NIns];
	for (i1=&b->ins[b->nins]; i1!=b->ins;) {
		emiti(*--i1);
		i = curi;
		rf = -1;
		switch (i->op) {
		case Ocall:
			rs = T.argregs(i->arg[1], 0) | T.rglob;
			for (r=0; T.rsave[r]>=0; r++)
				if (!(BIT(T.rsave[r]) & rs))
					rfree(cur, T.rsave[r]);
			break;
		case Ocopy:
			if (regcpy(i)) {
				curi++;
				i1 = dopm(b, i1, cur);
				stmov += i+1 - curi;
				continue;
			}
			if (isreg(i->to))
			if (rtype(i->arg[0]) == RTmp)
				sethint(i->arg[0].val, i->to.val);
			/* fall through */
		default:
			if (!req(i->to, R)) {
				assert(rtype(i->to) == RTmp);
				r = i->to.val;
				if (r < Tmp0 && (BIT(r) & T.rglob))
					break;
				rf = rfree(cur, r);
				if (rf == -1) {
					assert(!isreg(i->to));
					curi++;
					continue;
				}
				i->to = TMP(rf);
			}
			break;
		}
		for (x=0, nr=0; x<2; x++)
			switch (rtype(i->arg[x])) {
			case RMem:
				m = &mem[i->arg[x].val];
				if (rtype(m->base) == RTmp)
					insert(&m->base, ra, nr++);
				if (rtype(m->index) == RTmp)
					insert(&m->index, ra, nr++);
				break;
			case RTmp:
				insert(&i->arg[x], ra, nr++);
				break;
			}
		for (r=0; r<nr; r++)
			*ra[r] = ralloc(cur, ra[r]->val);
		if (i->op == Ocopy && req(i->to, i->arg[0]))
			curi++;

		/* try to change the register of a hinted
		 * temporary if rf is available */
		if (rf != -1 && (t = cur->w[rf]) != 0)
		if (!bshas(cur->b, rf) && *hint(t) == rf
		&& (rt = rfree(cur, t)) != -1) {
			tmp[t].visit = -1;
			ralloc(cur, t);
			assert(bshas(cur->b, rf));
			emit(Ocopy, tmp[t].cls, TMP(rt), TMP(rf), R);
			stmov += 1;
			cur->w[rf] = 0;
			for (r=0; r<nr; r++)
				if (req(*ra[r], TMP(rt)))
					*ra[r] = TMP(rf);
			/* one could iterate this logic with
			 * the newly freed rt, but in this case
			 * the above loop must be changed */
		}
	}
	idup(b, curi, &insb[NIns]-curi);
}

/* qsort() comparison function to peel
 * loop nests from inside out */
static int
carve(const void *a, const void *b)
{
	Blk *ba, *bb;

	/* todo, evaluate if this order is really
	 * better than the simple postorder */
	ba = *(Blk**)a;
	bb = *(Blk**)b;
	if (ba->loop != bb->loop)
		return ba->loop > bb->loop ? -1 : +1;
	if ((ba->jmp.type == Jjtbl) != (bb->jmp.type == Jjtbl))
		return ba->jmp.type == Jjtbl ? -1 : +1;
	return ba->id > bb->id ? -1 : ba->id < bb->id;
}

/* comparison function to order temporaries
 * for allocation at the end of blocks */
static int
prio2(int t1, int t2)
{
	if ((tmp[t1].visit ^ tmp[t2].visit) < 0)  /* != signs */
		return tmp[t1].visit != -1 ? +1 : -1;
	if ((*hint(t1) ^ *hint(t2)) < 0)
		return *hint(t1) != -1 ? +1 : -1;
	return (tmp[t1].cost > tmp[t2].cost) - (tmp[t1].cost < tmp[t2].cost);
}

/* A jump table can carry the current value in a register to every arm
 * while a minority of those arms also need the private spill home. Move
 * the shadow store onto these edges using the physical end-of-block map.
 * No reload, phi, bounds check or register assignment changes. */
static int
slotref(Ref r, Ref slot, Fn *fn)
{
	return req(r, slot) || (rtype(r) == RMem &&
		(req(fn->mem[r.val].base, slot) || req(fn->mem[r.val].index, slot)));
}

static int
touchslot(Ins *i, Ref slot, Fn *fn)
{
	return slotref(i->arg[0], slot, fn) || slotref(i->arg[1], slot, fn)
		|| slotref(i->to, slot, fn);
}

static int
sinkhome(Fn *fn, Blk *table, Blk *src, Ins *store, Ref reg,
	uchar *needed, Blk **work)
{
	Blk *b, *s, *p;
	Ins *i, *ins;
	uint n, a, top, edges, uses;
	Ref home = store->arg[1];

	memset(needed, 0, fn->nblk);
	top = 0;
	for (b=fn->start; b; b=b->link) {
		for (n=0; n<b->nins; n++) {
			i = &b->ins[n];
			if (i == store || !touchslot(i, home, fn))
				continue;
			/* The home never escapes. Reject a second definition,
			 * address formation, and references crossed by the move. */
			if (i->op == Oaddr || i->op == Oswap || i->op == Oblit0
			|| req(i->to, home)
			|| (isstore(i->op) && req(i->arg[1], home))
			|| (b == src && i > store) || (b == table && src != table))
				return 0;
			needed[b->id] = 1;
		}
		if (req(b->jmp.arg, home)) {
			if (b == src || b == table)
				return 0;
			needed[b->id] = 1;
		}
		if (needed[b->id])
			work[top++] = b;
	}
	/* Backward may-read closure stops at the unique original definition. */
	while (top) {
		b = work[--top];
		for (a=0; a<b->npred; a++) {
			p = b->pred[a];
			if (p != src && !needed[p->id]) {
				needed[p->id] = 1;
				work[top++] = p;
			}
		}
	}
	if (src != table) {
		s = src->s1 == table ? src->s2 : src->s1;
		if (s && needed[s->id])
			return 0;
	}
	uses = edges = 0;
	for (a=0; a<=table->njtbl; a++) {
		s = a ? table->jtbl[a-1] : table->s1;
		edges++;
		if (needed[s->id]) {
			if (s->npred != 1 || s == src || s == table)
				return 0;
			uses++;
		}
	}
	if (uses > edges / 2)
		return 0;
	/* Prepend only once for duplicate table entries. Every selected target
	 * has this table as its sole predecessor. The register still contains
	 * the value when the dispatch finishes, before any edge shuffle. */
	for (a=0; a<=table->njtbl; a++) {
		s = a ? table->jtbl[a-1] : table->s1;
		if (!needed[s->id])
			continue;
		needed[s->id] = 0;
		ins = alloc((s->nins+1) * sizeof *ins);
		ins[0] = *store;
		ins[0].arg[0] = reg;
		icpy(ins+1, s->ins, s->nins);
		s->ins = ins;
		s->nins++;
	}
	*store = (Ins){.op = Onop};
	return 1;
}

static uint
sinktablehomes(Fn *fn, RMap *end)
{
	Blk *b, *src, **work = 0;
	uchar *needed = 0, *examined = 0;
	int j, t, r, s;
	uint n, pass, moved = 0;
	/* Bound whole-CFG walks by the target register count, independently
	 * of the number of tables in a function. */
	uint budget = (uint)(2 * T.ngpr);
	Ins *i;
	for (b=fn->start; b; b=b->link) {
		if (b->jmp.type != Jjtbl || b->loop <= 1)
			continue;
		if (!needed) {
			fillpreds(fn);
			needed = alloc(fn->nblk);
			examined = alloc((size_t)fn->ntmp);
			work = alloc(fn->nblk * sizeof *work);
		}
		for (pass=0; pass<2; pass++) {
			src = b;
			if (pass) {
				if (b->npred != 1)
					continue;
				src = b->pred[0];
				if (src == b || src->jmp.type == Jjtbl)
					continue;
			}
			for (j=0; j<end[b->id].n; j++) {
				t = end[b->id].t[j];
				r = end[b->id].r[j];
				if (t < Tmp0 || examined[t] || tmp[t].ndef != 1 || KBASE(tmp[t].cls)
				|| (T.jtblclob & BIT(r)))
					continue;
				s = tmp[t].slot;
				if (s < fn->firstspill)
					continue;
				for (n=0; n<src->nins; n++) {
					i = &src->ins[n];
					if (i->op == (uint)(Ostorew + tmp[t].cls)
					&& req(i->arg[1], SLOT(s)) && isreg(i->arg[0])) {
						if (!budget)
							return moved;
						budget--;
						/* Examine only the original spill definition.
						 * Never move a store introduced on an edge. */
						examined[t] = 1;
						moved += (uint)sinkhome(fn, b, src, i,
							rref(&end[b->id], t), needed, work);
						break;
					}
				}
			}
		}
	}
	return moved;
}

/* register allocation
 * depends on rpo, phi, cost, (and obviously spill)
 */
void
rega(Fn *fn)
{
	int j, t, r, x, rl[Tmp0];
	Blk *b, *b1, *s, *blist, **blk, **bp;
	RMap *end, *beg, cur, *m;
	bits *entryregs;
	uchar *allocd;
	Ins *i;
	Phi *p;
	uint u, n, sunk;
	Ref src, dst;

	/* 1. setup */
	stmov = 0;
	stblk = 0;
	regu = 0;
	tmp = fn->tmp;
	mem = fn->mem;
	blk = alloc(fn->nblk * sizeof blk[0]);
	end = alloc(fn->nblk * sizeof end[0]);
	beg = alloc(fn->nblk * sizeof beg[0]);
	allocd = alloc(fn->nblk * sizeof allocd[0]);
	entryregs = alloc(fn->nblk * sizeof *entryregs);
	bsinit(cur.b, fn->ntmp);

	loop = 0;
	for (t=0; t<fn->ntmp; t++) {
		tmp[t].hint.r = t < Tmp0 ? t : -1;
		tmp[t].hint.w = loop;
		tmp[t].visit = -1;
	}
	for (bp=blk, b=fn->start; b; b=b->link)
		*bp++ = b;
	qsort(blk, fn->nblk, sizeof blk[0], carve);
	for (b=fn->start, i=b->ins; i<&b->ins[b->nins]; i++)
		if (i->op != Ocopy || !isreg(i->arg[0]))
			break;
		else {
			assert(rtype(i->to) == RTmp);
			sethint(i->to.val, i->arg[0].val);
		}

	/* 2. assign registers */
	for (bp=blk; bp<&blk[fn->nblk]; bp++) {
		b = *bp;
		n = b->id;
		loop = b->loop;
		/* Seed visit registers from the hottest already-allocated
		 * successor so end[b] aligns directly with beg[s].
		 * Priority: higher loop depth > call-free block > fall-through. */
		s = 0;
		if (b->s1 && allocd[b->s1->id])
			s = b->s1;
		if (b->s2 && allocd[b->s2->id]) {
			if (!s
			|| b->s2->loop > s->loop
			|| (b->s2->loop == s->loop && !b->s2->hascall && s->hascall)
			|| (b->s2->loop == s->loop && b->s2->hascall == s->hascall
			    && b->s2 == b->link && s != b->link))
				s = b->s2;
		}
		if (s) {
			for (t=Tmp0; bsiter(b->out, &t); t++) {
				r = rfind(&beg[s->id], t);
				if (r != -1)
					tmp[t].visit = r;
			}
			for (p=s->phi; p; p=p->link) {
				if (rtype(p->to) != RTmp)
					continue;
				r = rfind(&beg[s->id], p->to.val);
				if (r == -1)
					continue;
				for (u=0; u<p->narg; u++)
					if (p->blk[u] == b) {
						if (rtype(p->arg[u]) == RTmp && p->arg[u].val >= Tmp0)
							tmp[p->arg[u].val].visit = r;
						break;
					}
			}
		}
		cur.n = 0;
		bszero(cur.b);
		memset(cur.w, 0, sizeof cur.w);
		for (x=0, t=Tmp0; bsiter(b->out, &t); t++) {
			j = x++;
			rl[j] = t;
			while (j-- > 0 && prio2(t, rl[j]) > 0) {
				rl[j+1] = rl[j];
				rl[j] = t;
			}
		}
		for (r=0; bsiter(b->out, &r) && r<Tmp0; r++)
			radd(&cur, r, r);
		if (b->jmp.type == Jjtbl && T.jtblclob)
			for (r = T.gpr0; r < T.gpr0 + T.ngpr; r++)
				if ((T.jtblclob & BIT(r)) && !bshas(cur.b, r))
					radd(&cur, r, r);
		for (j=0; j<x; j++)
			ralloctry(&cur, rl[j], 1);
		for (j=0; j<x; j++)
			ralloc(&cur, rl[j]);
		if (b->jmp.type == Jjtbl && T.jtblclob)
			for (r = T.gpr0; r < T.gpr0 + T.ngpr; r++)
				if (T.jtblclob & BIT(r))
					rfree(&cur, r);
		snapshot(&end[n], &cur);
		doblk(b, &cur);
		bscopy(b->in, cur.b);
		for (p=b->phi; p; p=p->link)
			if (rtype(p->to) == RTmp)
				bsclr(b->in, p->to.val);
		snapshot(&beg[n], &cur);
		entryregs[n] = cur.b->t[0];
		allocd[n] = 1;
	}

	/* 3. emit copies shared by multiple edges
	 * to the same block */
	for (s=fn->start; s; s=s->link) {
		if (s->npred <= 1)
			continue;
		m = &beg[s->id];

		/* rl maps a register that is live at the
		 * beginning of s to the one used in all
		 * predecessors (if any, -1 otherwise) */
		memset(rl, 0, sizeof rl);

		/* to find the register of a phi in a
		 * predecessor, we have to find the
		 * corresponding argument */
		for (p=s->phi; p; p=p->link) {
			if (rtype(p->to) != RTmp
			|| (r=rfind(m, p->to.val)) == -1)
				continue;
			for (u=0; u<p->narg; u++) {
				b = p->blk[u];
				src = p->arg[u];
				if (rtype(src) != RTmp)
					continue;
				x = rfind(&end[b->id], src.val);
				if (x == -1) /* spilled */
					continue;
				rl[r] = (!rl[r] || rl[r] == x) ? x : -1;
			}
			if (rl[r] == 0)
				rl[r] = -1;
		}

		/* process non-phis temporaries */
		for (j=0; j<m->n; j++) {
			t = m->t[j];
			r = m->r[j];
			if (rl[r] || t < Tmp0 /* todo, remove this */)
				continue;
			for (bp=s->pred; bp<&s->pred[s->npred]; bp++) {
				x = rfind(&end[(*bp)->id], t);
				if (x == -1) /* spilled */
					continue;
				rl[r] = (!rl[r] || rl[r] == x) ? x : -1;
			}
			if (rl[r] == 0)
				rl[r] = -1;
		}

		npm = 0;
		for (j=0; j<m->n; j++) {
			t = m->t[j];
			r = m->r[j];
			x = rl[r];
			assert(x != 0 || t < Tmp0 /* todo, ditto */);
			if (x > 0 && !(entryregs[s->id] & BIT(x))) {
				pmadd(TMP(x), TMP(r), tmp[t].cls);
				m->r[j] = x;
				entryregs[s->id] |= BIT(x);
			}
		}
		curi = &insb[NIns];
		pmgen();
		j = &insb[NIns] - curi;
		if (j == 0)
			continue;
		stmov += j;
		s->nins += j;
		i = alloc(s->nins * sizeof(Ins));
		icpy(icpy(i, curi, j), s->ins, s->nins-j);
		s->ins = i;
	}

	if (debug['R'])  {
		fprintf(stderr, "\n> Register mappings:\n");
		for (n=0; n<fn->nblk; n++) {
			b = fn->rpo[n];
			fprintf(stderr, "\t%-10s beg", b->name);
			mdump(&beg[n]);
			fprintf(stderr, "\t           end");
			mdump(&end[n]);
		}
		fprintf(stderr, "\n");
	}

	/* 4. emit remaining copies in new blocks */
	blist = 0;
	for (b=fn->start;; b=b->link) {
		Blk **e2[2] = {&b->s1, &b->s2};
		uint32_t ne = 2 + (b->jmp.type == Jjtbl ? b->njtbl : 0);
		Blk ***edges = e2;
		Blk **origs = 0;
		Blk **tramps = 0;
		uint32_t ei;
		if (b->jmp.type == Jjtbl) {
			edges = alloc(ne * sizeof edges[0]);
			origs = alloc(ne * sizeof origs[0]);
			tramps = alloc(ne * sizeof tramps[0]);
			edges[0] = &b->s1;
			edges[1] = &b->s2;
			for (ei = 0; ei < b->njtbl; ei++)
				edges[2 + ei] = &b->jtbl[ei];
		}
		for (ei = 0; ei < ne; ei++) {
			s = *edges[ei];
			if (!s)
				continue;
			if (origs) {
				uint32_t ek;
				for (ek = 0; ek < ei; ek++)
					if (origs[ek] == s)
						break;
				if (ek < ei) {
					if (tramps[ek])
						*edges[ei] = tramps[ek];
					continue;
				}
				origs[ei] = s;
				tramps[ei] = 0;
			}
			npm = 0;
			for (p=s->phi; p; p=p->link) {
				dst = p->to;
				assert(rtype(dst)==RSlot || rtype(dst)==RTmp);
				if (rtype(dst) == RTmp) {
					r = rfind(&beg[s->id], dst.val);
					if (r == -1)
						continue;
					dst = TMP(r);
				}
				for (u=0; p->blk[u]!=b; u++)
					assert(u+1 < p->narg);
				src = p->arg[u];
				if (rtype(src) == RTmp)
					src = rref(&end[b->id], src.val);
				pmadd(src, dst, p->cls);
			}
			for (t=Tmp0; bsiter(s->in, &t); t++) {
				src = rref(&end[b->id], t);
				dst = rref(&beg[s->id], t);
				pmadd(src, dst, tmp[t].cls);
			}
			curi = &insb[NIns];
			pmgen();
			if (curi == &insb[NIns])
				continue;
			b1 = newblk();
			b1->istramp = 1;
			b1->loop = (b->loop+s->loop) / 2;
			b1->link = blist;
			blist = b1;
			b1->id = fn->nblk++;
			b1->name = strf(PFn, "%s_%s", b->name, s->name);
			stmov += &insb[NIns]-curi;
			stblk += 1;
			idup(b1, curi, &insb[NIns]-curi);
			b1->jmp.type = Jjmp;
			b1->s1 = s;
			*edges[ei] = b1;
			if (tramps)
				tramps[ei] = b1;
		}
		if (!b->link) {
			b->link = blist;
			break;
		}
	}
	for (b=fn->start; b; b=b->link)
		b->phi = 0;
	fn->reg = regu;
	sunk = sinktablehomes(fn, end);

	if (debug['R']) {
		fprintf(stderr, "\n> Register allocation statistics:\n");
		fprintf(stderr, "\tnew moves:  %d\n", stmov);
		fprintf(stderr, "\tnew blocks: %d\n", stblk);
		fprintf(stderr, "\tsunk homes: %u\n", sunk);
		fprintf(stderr, "\n> After register allocation:\n");
		printfn(fn, stderr);
	}
}
