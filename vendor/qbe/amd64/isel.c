#include "all.h"
#include <limits.h>

/* For x86_64, do the following:
 *
 * - check that constants are used only in
 *   places allowed
 * - ensure immediates always fit in 32b
 * - expose machine register contraints
 *   on instructions like division.
 * - implement fast locals (the streak of
 *   constant allocX in the first basic block)
 * - recognize complex addressing modes
 *
 * Invariant: the use counts that are used
 *            in sel() must be sound.  This
 *            is not so trivial, maybe the
 *            dce should be moved out...
 */

typedef struct {
	Num *v;
	int *touched;
	int count;
} AddrNums;

static int amatch(Addr *, AddrNums *, Ref, Fn *);

static int
noimm(Ref r, Fn *fn)
{
	int64_t val;

	if (rtype(r) != RCon)
		return 0;
	switch (fn->con[r.val].type) {
	case CAddr:
		/* we only support the 'small'
		 * code model of the ABI, this
		 * means that we can always
		 * address data with 32bits
		 */
		return 0;
	case CBits:
		val = fn->con[r.val].bits.i;
		return (val < INT32_MIN || val > INT32_MAX);
	default:
		die("invalid constant");
	}
}

static int
rslot(Ref r, Fn *fn)
{
	if (rtype(r) != RTmp)
		return -1;
	return fn->tmp[r.val].slot;
}

static int
hascon(Ref r, Con **pc, Fn *fn)
{
	switch (rtype(r)) {
	case RCon:
		*pc = &fn->con[r.val];
		return 1;
	case RMem:
		*pc = &fn->mem[r.val].offset;
		return 1;
	default:
		return 0;
	}
}

static void
fixarg(Ref *r, int k, Ins *i, Fn *fn)
{
	char buf[32];
	Addr a, *m;
	Con cc, *c;
	Ref r0, r1, r2, r3;
	int s, n, op;

	r1 = r0 = *r;
	s = rslot(r0, fn);
	op = i ? i->op : Ocopy;
	if (KBASE(k) == 1 && rtype(r0) == RCon) {
		/* load floating points from memory
		 * slots, they can't be used as
		 * immediates
		 */
		r1 = MEM(fn->nmem);
		vgrow(&fn->mem, ++fn->nmem);
		memset(&a, 0, sizeof a);
		a.offset.type = CAddr;
		n = stashbits(fn->con[r0.val].bits.i, KWIDE(k) ? 8 : 4);
		/* quote the name so that we do not
		 * add symbol prefixes on the apple
		 * target variant
		 */
		sprintf(buf, "\"%sfp%d\"", T.asloc, n);
		a.offset.sym.id = intern(buf);
		fn->mem[fn->nmem-1] = a;
	}
	else if (op == Ocall && r == &i->arg[0]
	&& rtype(r0) == RCon && fn->con[r0.val].type != CAddr) {
		/* use a temporary register so that we
		 * produce an indirect call
		 */
		r1 = newtmp("isel", Kl, fn);
		emit(Ocopy, Kl, r1, r0, R);
	}
	else if (op != Ocopy && k == Kl && noimm(r0, fn)) {
		/* load constants that do not fit in
		 * a 32bit signed integer into a
		 * long temporary
		 */
		r1 = newtmp("isel", Kl, fn);
		emit(Ocopy, Kl, r1, r0, R);
	}
	else if (s != -1) {
		/* load fast locals' addresses into
		 * temporaries right before the
		 * instruction
		 */
		r1 = newtmp("isel", Kl, fn);
		emit(Oaddr, Kl, r1, SLOT(s), R);
	}
	else if (op != Ocall && hascon(r0, &c, fn)
	&& c->type == CAddr && ((c->sym.type & SExt)
	 || (T.apple && c->sym.type == SThr))) {
		r1 = newtmp("isel", Kl, fn);
		if (c->bits.i) {
			r2 = newtmp("isel", Kl, fn);
			cc = (Con){.type = CBits};
			cc.bits.i = c->bits.i;
			r3 = newcon(&cc, fn);
			emit(Oadd, Kl, r1, r2, r3);
		} else
			r2 = r1;
		if (T.apple && (c->sym.type & SThr)) {
			emit(Ocopy, Kl, r2, TMP(RAX), R);
			r2 = newtmp("isel", Kl, fn);
			r3 = newtmp("isel", Kl, fn);
			emit(Ocall, 0, R, r3, CALL(17));
			emit(Ocopy, Kl, TMP(RDI), r2, R);
			emit(Oload, Kl, r3, r2, R);
		}
		cc = *c;
		cc.bits.i = 0;
		r3 = newcon(&cc, fn);
		emit(Oaddr, Kl, r2, r3, R);
		if (rtype(r0) == RMem) {
			m = &fn->mem[r0.val];
			m->offset.type = CUndef;
			m->base = r1;
			r1 = r0;
		}
	}
	else if (!(isstore(op) && r == &i->arg[1])
	&& !isload(op) && op != Ocall && rtype(r0) == RCon
	&& fn->con[r0.val].type == CAddr) {
		/* turn address operands into
		 * lea/mov instructions
		 */
		r1 = newtmp("isel", Kl, fn);
		emit(Oaddr, Kl, r1, r0, R);
	}
	else if (rtype(r0) == RMem) {
		/* eliminate memory operands of
		 * the form $foo(%rip, ...)
		 */
		m = &fn->mem[r0.val];
		if (req(m->base, R))
		if (m->offset.type == CAddr) {
			r0 = newtmp("isel", Kl, fn);
			emit(Oaddr, Kl, r0, newcon(&m->offset, fn), R);
			m->offset.type = CUndef;
			m->base = r0;
		}
	}
	else if (isxsel(op) && rtype(*r) == RCon) {
		r1 = newtmp("isel", i->cls, fn);
		emit(Ocopy, i->cls, r1, *r, R);
	}
	*r = r1;
}

static void
seladdr(Ref *r, AddrNums *tn, Fn *fn)
{
	Addr a;
	Ref r0;

	r0 = *r;
	if (rtype(r0) == RTmp) {
		memset(&a, 0, sizeof a);
		if (!amatch(&a, tn, r0, fn))
			return;
		if (!req(a.base, R))
		if (a.offset.type == CAddr) {
			/* apple as does not support
			 * $foo(%r0, %r1, M); try to
			 * rewrite it or bail out if
			 * impossible
			 */
			if (!req(a.index, R) || rtype(a.base) != RTmp)
				return;
			else {
				a.index = a.base;
				a.scale = 1;
				a.base = R;
			}
		}
		chuse(r0, -1, fn);
		vgrow(&fn->mem, ++fn->nmem);
		fn->mem[fn->nmem-1] = a;
		chuse(a.base, +1, fn);
		chuse(a.index, +1, fn);
		*r = MEM(fn->nmem-1);
	}
}

static int
cmpswap(Ref arg[2], int op)
{
	switch (op) {
	case NCmpI+Cflt:
	case NCmpI+Cfle:
		return 1;
	case NCmpI+Cfgt:
	case NCmpI+Cfge:
		return 0;
	}
	return rtype(arg[0]) == RCon;
}

static void
selcmp(Ref arg[2], int k, int swap, Fn *fn)
{
	Ref r;
	Ins *icmp;

	if (swap) {
		r = arg[1];
		arg[1] = arg[0];
		arg[0] = r;
	}
	emit(Oxcmp, k, R, arg[1], arg[0]);
	icmp = curi;
	if (rtype(arg[0]) == RCon) {
		assert(k != Kw);
		icmp->arg[1] = newtmp("isel", k, fn);
		emit(Ocopy, k, icmp->arg[1], arg[0], R);
		fixarg(&curi->arg[0], k, curi, fn);
	}
	fixarg(&icmp->arg[0], k, icmp, fn);
	fixarg(&icmp->arg[1], k, icmp, fn);
}

static void
sel(Ins i, AddrNums *tn, Fn *fn)
{
	Ref r0, r1, tmp[7];
	int x, j, k, kc, sh, swap;
	Ins *i0, *i1;

	if (rtype(i.to) == RTmp)
	if (!isreg(i.to) && !isreg(i.arg[0]) && !isreg(i.arg[1]))
	if (fn->tmp[i.to.val].nuse == 0) {
		chuse(i.arg[0], -1, fn);
		chuse(i.arg[1], -1, fn);
		return;
	}
	i0 = curi;
	k = i.cls;
	switch (i.op) {
	case Odiv:
	case Orem:
	case Oudiv:
	case Ourem:
		if (KBASE(k) == 1)
			goto Emit;
		if ((i.op == Odiv || i.op == Orem) && rtype(i.arg[1]) == RCon
		&& fn->con[i.arg[1].val].type == CBits) {
			int W = KWIDE(k) ? 64 : 32;
			int64_t d = KWIDE(k) ? fn->con[i.arg[1].val].bits.i
				: (int64_t)(int32_t)fn->con[i.arg[1].val].bits.i;
			int64_t min_d = KWIDE(k) ? INT64_MIN : (int64_t)INT32_MIN;
			if (d != min_d && (d >= 2 || d <= -2)) {
				uint64_t ad = d < 0 ? (uint64_t)(0ULL - (uint64_t)d) : (uint64_t)d;
				Ref rx = i.arg[0];
				int need_fix_x = (rtype(rx) == RCon || rslot(rx, fn) != -1);
				if (need_fix_x)
					rx = newtmp("div", k, fn);

				if ((ad & (ad - 1ULL)) == 0) {
					int sh = 0;
					while ((1ULL << sh) != ad)
						sh++;
					Ref q, t1, t2;
					if (i.op == Orem) {
						Ref prod = newtmp("div", k, fn);
						q = newtmp("div", k, fn);
						emit(Osub, k, i.to, rx, prod);
						emit(Oshl, k, prod, q, getcon(sh, fn));
					} else if (d < 0) {
						q = newtmp("div", k, fn);
						emit(Oneg, k, i.to, q, R);
					} else {
						q = i.to;
					}
					t2 = newtmp("div", k, fn);
					t1 = newtmp("div", k, fn);
					emit(Osar, k, q, t2, getcon(sh, fn));
					emit(Oadd, k, t2, rx, t1);
					if (sh == 1) {
						emit(Oshr, k, t1, rx, getcon(W - 1, fn));
					} else {
						Ref t0 = newtmp("div", k, fn);
						emit(Oshr, k, t1, t0, getcon(W - sh, fn));
						emit(Osar, k, t0, rx, getcon(W - 1, fn));
					}
				} else {
					MagicS mg = KWIDE(k) ? magic_s64(d) : magic_s32((int32_t)d);
					Ref q, q2, q1, q0, sgn, mreg;
					if (i.op == Orem) {
						Ref prod = newtmp("div", k, fn);
						q = newtmp("div", k, fn);
						emit(Osub, k, i.to, rx, prod);
						emit(Omul, k, prod, q, getcon(d, fn));
						fixarg(&curi->arg[1], k, curi, fn);
					} else {
						q = i.to;
					}
					q2 = newtmp("div", k, fn);
					sgn = newtmp("div", k, fn);
					emit(Oadd, k, q, q2, sgn);
					emit(Oshr, k, sgn, q2, getcon(W - 1, fn));
					if (mg.s > 0) {
						q1 = newtmp("div", k, fn);
						emit(Osar, k, q2, q1, getcon(mg.s, fn));
					} else {
						q1 = q2;
					}
					if (mg.add != 0) {
						q0 = newtmp("div", k, fn);
						emit(mg.add > 0 ? Oadd : Osub, k, q1, q0, rx);
					} else {
						q0 = q1;
					}
					mreg = newtmp("div", k, fn);
					emit(Ocopy, k, q0, TMP(RDX), R);
					emit(Ocopy, k, R, TMP(RAX), R);
					emit(Oximul, k, TMP(RDX), mreg, R);
					emit(Ocopy, k, TMP(RAX), rx, R);
					emit(Ocopy, k, mreg, getcon(mg.m, fn), R);
				}
				if (need_fix_x) {
					emit(Ocopy, k, rx, i.arg[0], R);
					fixarg(&curi->arg[0], k, curi, fn);
				}
				break;
			}
		}
		if (i.op == Odiv || i.op == Oudiv)
			r0 = TMP(RAX), r1 = TMP(RDX);
		else
			r0 = TMP(RDX), r1 = TMP(RAX);
		emit(Ocopy, k, i.to, r0, R);
		emit(Ocopy, k, R, r1, R);
		if (rtype(i.arg[1]) == RCon) {
			/* immediates not allowed for
			 * divisions in x86
			 */
			r0 = newtmp("isel", k, fn);
		} else
			r0 = i.arg[1];
		if (fn->tmp[r0.val].slot != -1)
			err("unlikely argument %%%s in %s",
				fn->tmp[r0.val].name, optab[i.op].name);
		if (i.op == Odiv || i.op == Orem) {
			emit(Oxidiv, k, R, r0, R);
			emit(Osign, k, TMP(RDX), TMP(RAX), R);
		} else {
			emit(Oxdiv, k, R, r0, R);
			emit(Ocopy, k, TMP(RDX), CON_Z, R);
		}
		emit(Ocopy, k, TMP(RAX), i.arg[0], R);
		fixarg(&curi->arg[0], k, curi, fn);
		if (rtype(i.arg[1]) == RCon)
			emit(Ocopy, k, r0, i.arg[1], R);
		break;
	case Osar:
	case Oshr:
	case Oshl:
	case Oror:
		r0 = i.arg[1];
		if (rtype(r0) == RCon)
			goto Emit;
		if (fn->tmp[r0.val].slot != -1)
			err("unlikely argument %%%s in %s",
				fn->tmp[r0.val].name, optab[i.op].name);
		i.arg[1] = TMP(RCX);
		emit(Ocopy, Kw, R, TMP(RCX), R);
		emiti(i);
		i1 = curi;
		emit(Ocopy, Kw, TMP(RCX), r0, R);
		fixarg(&i1->arg[0], argcls(&i, 0), i1, fn);
		break;
	case Ouwtof:
		r0 = newtmp("utof", Kl, fn);
		emit(Osltof, k, i.to, r0, R);
		emit(Oextuw, Kl, r0, i.arg[0], R);
		fixarg(&curi->arg[0], k, curi, fn);
		break;
	case Oultof:
		/* %mask =l and %arg.0, 1
		 * %isbig =l shr %arg.0, 63
		 * %divided =l shr %arg.0, %isbig
		 * %or =l or %mask, %divided
		 * %float =d sltof %or
		 * %cast =l cast %float
		 * %addend =l shl %isbig, 52
		 * %sum =l add %cast, %addend
		 * %result =d cast %sum
		 */
		r0 = newtmp("utof", k, fn);
		if (k == Ks)
			kc = Kw, sh = 23;
		else
			kc = Kl, sh = 52;
		for (j=0; j<4; j++)
			tmp[j] = newtmp("utof", Kl, fn);
		for (; j<7; j++)
			tmp[j] = newtmp("utof", kc, fn);
		emit(Ocast, k, i.to, tmp[6], R);
		emit(Oadd, kc, tmp[6], tmp[4], tmp[5]);
		emit(Oshl, kc, tmp[5], tmp[1], getcon(sh, fn));
		emit(Ocast, kc, tmp[4], r0, R);
		emit(Osltof, k, r0, tmp[3], R);
		emit(Oor, Kl, tmp[3], tmp[0], tmp[2]);
		emit(Oshr, Kl, tmp[2], i.arg[0], tmp[1]);
		sel(*curi++, 0, fn);
		emit(Oshr, Kl, tmp[1], i.arg[0], getcon(63, fn));
		fixarg(&curi->arg[0], Kl, curi, fn);
		emit(Oand, Kl, tmp[0], i.arg[0], getcon(1, fn));
		fixarg(&curi->arg[0], Kl, curi, fn);
		break;
	case Ostoui:
		i.op = Ostosi;
		kc = Ks;
		tmp[4] = getcon(0xdf000000, fn);
		goto Oftoui;
	case Odtoui:
		i.op = Odtosi;
		kc = Kd;
		tmp[4] = getcon(0xc3e0000000000000, fn);
	Oftoui:
		if (k == Kw) {
			r0 = newtmp("ftou", Kl, fn);
			emit(Ocopy, Kw, i.to, r0, R);
			i.cls = Kl;
			i.to = r0;
			goto Emit;
		}
		/* %try0 =l {s,d}tosi %fp
		 * %mask =l sar %try0, 63
		 *
		 *    mask is all ones if the first
		 *    try was oob, all zeroes o.w.
		 *
		 * %fps ={s,d} sub %fp, (1<<63)
		 * %try1 =l {s,d}tosi %fps
		 *
		 * %tmp =l and %mask, %try1
		 * %res =l or %tmp, %try0
		 */
		r0 = newtmp("ftou", kc, fn);
		for (j=0; j<4; j++)
			tmp[j] = newtmp("ftou", Kl, fn);
		emit(Oor, Kl, i.to, tmp[0], tmp[3]);
		emit(Oand, Kl, tmp[3], tmp[2], tmp[1]);
		emit(i.op, Kl, tmp[2], r0, R);
		emit(Oadd, kc, r0, tmp[4], i.arg[0]);
		i1 = curi; /* fixarg() can change curi */
		fixarg(&i1->arg[0], kc, i1, fn);
		fixarg(&i1->arg[1], kc, i1, fn);
		emit(Osar, Kl, tmp[1], tmp[0], getcon(63, fn));
		emit(i.op, Kl, tmp[0], i.arg[0], R);
		fixarg(&curi->arg[0], Kl, curi, fn);
		break;
	case Onop:
		break;
	case Ostored:
	case Ostores:
	case Ostorel:
	case Ostorew:
	case Ostoreh:
	case Ostoreb:
		if (rtype(i.arg[0]) == RCon) {
			if (i.op == Ostored)
				i.op = Ostorel;
			if (i.op == Ostores)
				i.op = Ostorew;
		}
		seladdr(&i.arg[1], tn, fn);
		goto Emit;
	case_Oload:
		seladdr(&i.arg[0], tn, fn);
		goto Emit;
	case Odbgloc:
	case Ocall:
	case Osalloc:
	case Ocopy:
	case Oadd:
	case Osub:
	case Oneg:
	case Omul:
	case Oand:
	case Oor:
	case Oxor:
	case Oxtest:
	case Ostosi:
	case Odtosi:
	case Oswtof:
	case Osltof:
	case Oexts:
	case Otruncd:
	case Osqrt:
	case Ocast:
	case_Oxsel:
	case_Oext:
Emit:
		emiti(i);
		i1 = curi; /* fixarg() can change curi */
		fixarg(&i1->arg[0], argcls(&i, 0), i1, fn);
		fixarg(&i1->arg[1], argcls(&i, 1), i1, fn);
		break;
	case Oalloc4:
	case Oalloc8:
	case Oalloc16:
		salloc(i.to, i.arg[0], fn);
		break;
	default:
		if (isext(i.op))
			goto case_Oext;
		if (isxsel(i.op))
			goto case_Oxsel;
		if (isload(i.op))
			goto case_Oload;
		if (iscmp(i.op, &kc, &x)) {
			switch (x) {
			case NCmpI+Cfeq:
				/* zf is set when operands are
				 * unordered, so we may have to
				 * check pf
				 */
				r0 = newtmp("isel", Kw, fn);
				r1 = newtmp("isel", Kw, fn);
				emit(Oand, Kw, i.to, r0, r1);
				emit(Oflagfo, k, r1, R, R);
				i.to = r0;
				break;
			case NCmpI+Cfne:
				r0 = newtmp("isel", Kw, fn);
				r1 = newtmp("isel", Kw, fn);
				emit(Oor, Kw, i.to, r0, r1);
				emit(Oflagfuo, k, r1, R, R);
				i.to = r0;
				break;
			}
			swap = cmpswap(i.arg, x);
			if (swap)
				x = cmpop(x);
			emit(Oflag+x, k, i.to, R, R);
			selcmp(i.arg, kc, swap, fn);
			break;
		}
		die("unknown instruction %s", optab[i.op].name);
	}

	while (i0>curi && --i0) {
		assert(rslot(i0->arg[0], fn) == -1);
		assert(rslot(i0->arg[1], fn) == -1);
	}
}

static Ins *
flagi(Ins *i0, Ins *i)
{
	while (i>i0) {
		i--;
		if (amd64_op[i->op].zflag)
			return i;
		if (amd64_op[i->op].lflag)
			continue;
		return 0;
	}
	return 0;
}

static Ins*
selsel(Fn *fn, Blk *b, Ins *i, AddrNums *tn)
{
	Ref r, cr[2];
	int c, k, dk, dc, swap, gencmp, gencpy;
	Ins *isel0, *isel1, *fi;
	Tmp *t;

	assert(i->op == Osel1);
	for (isel0=i; b->ins<isel0; isel0--) {
		if (isel0->op == Osel0)
			break;
		assert(isel0->op == Osel1);
	}
	assert(isel0->op == Osel0);
	r = isel0->arg[0];
	assert(rtype(r) == RTmp);
	t = &fn->tmp[r.val];
	fi = flagi(b->ins, isel0);
	cr[0] = cr[1] = R;
	gencmp = gencpy = swap = 0;
	k = Kw;
	c = Cine;
	if (!fi || !req(fi->to, r)
	|| (fi->cls != Kw && !iscmp(fi->op, &dk, &dc))) {
		gencmp = 1;
		cr[0] = r;
		cr[1] = CON_Z;
	}
	else if (iscmp(fi->op, &k, &c)) {
		if (c == NCmpI+Cfeq
		|| c == NCmpI+Cfne) {
			/* these are selected as 'and'
			 * or 'or', so we check their
			 * result with Cine
			 */
			c = Cine;
			goto Other;
		}
		swap = cmpswap(fi->arg, c);
		if (swap)
			c = cmpop(c);
		if (t->nuse == 1) {
			gencmp = 1;
			cr[0] = fi->arg[0];
			cr[1] = fi->arg[1];
			*fi = (Ins){.op = Onop};
		}
	}
	else if (fi->op == Oand && t->nuse == 1
	     && (rtype(fi->arg[0]) == RTmp ||
	         rtype(fi->arg[1]) == RTmp)) {
		fi->op = Oxtest;
		fi->to = R;
		if (rtype(fi->arg[1]) == RCon) {
			r = fi->arg[1];
			fi->arg[1] = fi->arg[0];
			fi->arg[0] = r;
		}
	}
	else {
	Other:
		/* since flags are not tracked in liveness,
		 * the result of the flag-setting instruction
		 * has to be marked as live
		 */
		if (t->nuse == 1)
			gencpy = 1;
	}
	/* generate conditional moves */
	for (isel1=i; isel0<isel1; --isel1) {
		isel1->op = Oxsel+c;
		sel(*isel1, tn, fn);
	}
	assert(!gencmp || !gencpy);
	if (gencmp)
		selcmp(cr, k, swap, fn);
	if (gencpy)
		emit(Ocopy, Kw, R, r, R);
	*isel0 = (Ins){.op = Onop};
	return isel0;
}

static void
seljmp(Blk *b, Fn *fn)
{
	Ref r;
	int c, k, dk, dc, swap;
	Ins *fi;
	Tmp *t;

	if (b->jmp.type == Jret0
	|| b->jmp.type == Jjmp
	|| b->jmp.type == Jhlt)
		return;
	if (b->jmp.type == Jjtbl) {
		if (rtype(b->jmp.arg) != RTmp) {
			r = newtmp("isel", Kw, fn);
			emit(Ocopy, Kw, r, b->jmp.arg, R);
			b->jmp.arg = r;
		}
		return;
	}
	assert(b->jmp.type == Jjnz);
	r = b->jmp.arg;
	t = &fn->tmp[r.val];
	b->jmp.arg = R;
	assert(rtype(r) == RTmp);
	if (b->s1 == b->s2) {
		chuse(r, -1, fn);
		b->jmp.type = Jjmp;
		b->s2 = 0;
		return;
	}
	fi = flagi(b->ins, &b->ins[b->nins]);
	if (!fi || !req(fi->to, r)
	|| (fi->cls != Kw && !iscmp(fi->op, &dk, &dc))) {
		selcmp((Ref[2]){r, CON_Z}, Kw, 0, fn);
		b->jmp.type = Jjf + Cine;
	}
	else if (iscmp(fi->op, &k, &c)
	     && c != NCmpI+Cfeq /* see sel(), selsel() */
	     && c != NCmpI+Cfne) {
		swap = cmpswap(fi->arg, c);
		if (swap)
			c = cmpop(c);
		if (t->nuse == 1) {
			selcmp(fi->arg, k, swap, fn);
			*fi = (Ins){.op = Onop};
		}
		b->jmp.type = Jjf + c;
	}
	else if (fi->op == Oand && t->nuse == 1
	     && (rtype(fi->arg[0]) == RTmp ||
	         rtype(fi->arg[1]) == RTmp)) {
		fi->op = Oxtest;
		fi->to = R;
		b->jmp.type = Jjf + Cine;
		if (rtype(fi->arg[1]) == RCon) {
			r = fi->arg[1];
			fi->arg[1] = fi->arg[0];
			fi->arg[0] = r;
		}
	}
	else {
		/* since flags are not tracked in liveness,
		 * the result of the flag-setting instruction
		 * has to be marked as live
		 */
		if (t->nuse == 1)
			emit(Ocopy, Kw, R, r, R);
		b->jmp.type = Jjf + Cine;
	}
}

enum {
	Pob,
	Pbis,
	Pois,
	Pobis,
	Pbi1,
	Pobi1,
};

/* mgen generated code
 *
 * (with-vars (o b i s)
 *   (patterns
 *     (ob   (add (con o) (tmp b)))
 *     (bis  (add (tmp b) (mul (tmp i) (con s 1 2 4 8))))
 *     (ois  (add (con o) (mul (tmp i) (con s 1 2 4 8))))
 *     (obis (add (con o) (tmp b) (mul (tmp i) (con s 1 2 4 8))))
 *     (bi1  (add (tmp b) (tmp i)))
 *     (obi1 (add (con o) (tmp b) (tmp i)))
 * ))
 */

static int
opn(int op, int l, int r)
{
	static uchar Oaddtbl[91] = {
		2,
		2,2,
		4,4,5,
		6,6,8,8,
		4,4,9,10,9,
		7,7,5,8,9,5,
		4,4,12,10,12,12,12,
		4,4,9,10,9,9,12,9,
		11,11,5,8,9,5,12,9,5,
		7,7,5,8,9,5,12,9,5,5,
		11,11,5,8,9,5,12,9,5,5,5,
		4,4,9,10,9,9,12,9,9,9,9,9,
		7,7,5,8,9,5,12,9,5,5,5,9,5,
	};
	int t;

	if (l < r)
		t = l, l = r, r = t;
	switch (op) {
	case Omul:
		if (2 <= l)
		if (r == 0) {
			return 3;
		}
		return 2;
	case Oadd:
		return Oaddtbl[(l + l*l)/2 + r];
	default:
		return 2;
	}
}

/* Every write to the numbering table first enters here.  Nonzero
 * states distinguish touched slots; state 2 is the default temporary.
 * opn() never returns 0, so a slot is recorded at most once per block
 * and touched[] needs one entry per temporary. */
static Num *
touch(AddrNums *tn, int t)
{
	Num *v = &tn->v[t];

	if (!v->n) {
		tn->touched[tn->count++] = t;
		v->n = 2;
	}
	return v;
}

static int
refn(Ref r, AddrNums *tn, Con *con)
{
	int64_t n;

	switch (rtype(r)) {
	case RTmp:
		return touch(tn, r.val)->n;
	case RCon:
		if (con[r.val].type != CBits)
			return 1;
		n = con[r.val].bits.i;
		if (n == 8 || n == 4 || n == 2 || n == 1)
			return 0;
		return 1;
	default:
		return INT_MIN;
	}
}

static bits match[13] = {
	[4] = BIT(Pob),
	[5] = BIT(Pbi1),
	[6] = BIT(Pob) | BIT(Pois),
	[7] = BIT(Pob) | BIT(Pobi1),
	[8] = BIT(Pbi1) | BIT(Pbis),
	[9] = BIT(Pbi1) | BIT(Pobi1),
	[10] = BIT(Pbi1) | BIT(Pbis) | BIT(Pobi1) | BIT(Pobis),
	[11] = BIT(Pob) | BIT(Pobi1) | BIT(Pobis),
	[12] = BIT(Pbi1) | BIT(Pobi1) | BIT(Pobis),
};

static uchar *matcher[] = {
	[Pbi1] = (uchar[]){
		1,3,1,3,2,0
	},
	[Pbis] = (uchar[]){
		5,1,8,5,27,1,5,1,2,5,13,3,1,1,3,3,3,2,0,1,
		3,3,3,2,3,1,0,1,29
	},
	[Pob] = (uchar[]){
		1,3,0,3,1,0
	},
	[Pobi1] = (uchar[]){
		5,3,9,9,10,33,12,35,45,1,5,3,11,9,7,9,4,9,
		17,1,3,0,3,1,3,2,0,3,1,1,3,0,34,1,37,1,5,2,
		5,7,2,7,8,37,29,1,3,0,1,32
	},
	[Pobis] = (uchar[]){
		5,2,10,7,11,19,49,1,1,3,3,3,2,1,3,0,3,1,0,
		1,3,0,5,1,8,5,25,1,5,1,2,5,13,3,1,1,3,3,3,
		2,0,1,3,3,3,2,26,1,51,1,5,1,6,5,9,1,3,0,51,
		3,1,1,3,0,45
	},
	[Pois] = (uchar[]){
		1,3,0,1,3,3,3,2,0
	},
};

/* end of generated code */

static void
anumber(AddrNums *tn, Blk *b, Fn *fn)
{
	Ins *i;
	Num *n;

	for (i=b->ins; i<&b->ins[b->nins]; i++) {
		if (rtype(i->to) != RTmp)
			continue;
		n = touch(tn, i->to.val);
		if (i->op == Oshl && i->cls == Kl
		&& rtype(i->arg[0]) == RTmp && rtype(i->arg[1]) == RCon) {
			Con *sc = &fn->con[i->arg[1].val];
			if (sc->type == CBits
			&& (sc->bits.i == 1 || sc->bits.i == 2 || sc->bits.i == 3)) {
				Con c = {.type = CBits, .bits.i = 1LL << sc->bits.i};
				n->l = i->arg[0];
				n->r = newcon(&c, fn);
				n->nl = refn(n->l, tn, fn->con);
				n->nr = 0;
				n->n = opn(Omul, n->nl, n->nr);
				continue;
			}
		}
		n->l = i->arg[0];
		n->r = i->arg[1];
		n->nl = refn(n->l, tn, fn->con);
		n->nr = refn(n->r, tn, fn->con);
		n->n = opn(i->op, n->nl, n->nr);
	}
}

static int
addcon_disp32(Con *c0, const Con *c1, int m)
{
	int64_t base, prod, sum;

	if (m != 1 && c1->type == CAddr)
		return 0;
	if (c0->type != CUndef && c0->type == CAddr && c1->type == CAddr)
		return 0;
	if (m < 1 || m > 8)
		return 0;
	if (c1->bits.i < -(INT64_C(1) << 33) || c1->bits.i > (INT64_C(1) << 33))
		return 0;
	base = (c0->type == CUndef) ? 0 : c0->bits.i;
	if (base < INT32_MIN || base > INT32_MAX)
		return 0;
	prod = c1->bits.i * (int64_t)m;
	sum = base + prod;
	if (sum < INT32_MIN || sum > INT32_MAX)
		return 0;
	if (c0->type == CUndef) {
		*c0 = *c1;
		c0->bits.i = sum;
	} else {
		if (c1->type == CAddr) {
			c0->type = CAddr;
			c0->sym = c1->sym;
		}
		c0->bits.i = sum;
	}
	return 1;
}

static uint64_t isel_total_nins;

static int
slot_disp32_ok(const Con *off, int s, const Fn *fn)
{
	uint64_t max_slot_final, max_frame, arg_extra;
	int64_t v;

	if (s < -(1 << 28) || s >= (1 << 28))
		return 0;
	v = (off->type == CUndef) ? 0 : off->bits.i;
	if (v < INT32_MIN || v > INT32_MAX)
		return 0;
	if (isel_total_nins > (UINT64_C(1) << 28) || (uint64_t)fn->ntmp > (UINT64_C(1) << 28))
		return 0;
	max_slot_final = (uint64_t)(fn->slot > 0 ? fn->slot : 0)
		+ 2ULL * ((uint64_t)fn->ntmp + 16ULL * isel_total_nins) + 8ULL;
	arg_extra = (s < 0) ? 4ULL * (uint64_t)(-(int64_t)s) : 0ULL;
	if (max_slot_final > (uint64_t)INT32_MAX / 4ULL)
		return 0;
	max_frame = 176ULL + 128ULL + 4ULL * max_slot_final + arg_extra;
	if (max_frame > (uint64_t)INT32_MAX)
		return 0;
	return v + (int64_t)max_frame <= INT32_MAX && v - (int64_t)max_frame >= INT32_MIN;
}

static Ref
adisp(Con *c, AddrNums *tn, Ref r, Fn *fn, int s)
{
	Ref v[2];
	int n;

	while (!req(r, R)) {
		assert(rtype(r) == RTmp);
		n = refn(r, tn, fn->con);
		if (!(match[n] & BIT(Pob)))
			break;
		runmatch(matcher[Pob], tn->v, r, v);
		assert(rtype(v[0]) == RCon);
		if (!addcon_disp32(c, &fn->con[v[0].val], s))
			break;
		r = v[1];
	}
	return r;
}

static int
amatch(Addr *a, AddrNums *tn, Ref r, Fn *fn)
{
	static int pat[] = {Pobis, Pobi1, Pbis, Pois, Pbi1, -1};
	Ref ro, rb, ri, rs, v[4];
	Con *c, co;
	int s, n, *p;

	if (rtype(r) != RTmp)
		return 0;

	n = refn(r, tn, fn->con);
	memset(v, 0, sizeof v);
	for (p=pat; *p>=0; p++)
		if (match[n] & BIT(*p)) {
			runmatch(matcher[*p], tn->v, r, v);
			break;
		}
	if (*p < 0)
		v[1] = r;

	memset(&co, 0, sizeof co);
	ro = v[0];
	rb = adisp(&co, tn, v[1], fn, 1);
	ri = v[2];
	rs = v[3];
	s = 1;

	if (*p < 0 && co.type != CUndef)
	if (amatch(a, tn, rb, fn)) {
		if (!addcon_disp32(&a->offset, &co, 1))
			return 0;
		if (rtype(a->base) == RSlot && !slot_disp32_ok(&a->offset, rsval(a->base), fn))
			return 0;
		return 1;
	}
	if (!req(ro, R)) {
		assert(rtype(ro) == RCon);
		c = &fn->con[ro.val];
		if (!addcon_disp32(&co, c, 1))
			return 0;
	}
	if (!req(rs, R)) {
		assert(rtype(rs) == RCon);
		c = &fn->con[rs.val];
		assert(c->type == CBits);
		s = c->bits.i;
	}
	ri = adisp(&co, tn, ri, fn, s);
	*a = (Addr){co, rb, ri, s};

	if (rtype(ri) == RTmp)
	if (fn->tmp[ri.val].slot != -1) {
		if (a->scale != 1
		|| fn->tmp[rb.val].slot != -1)
			return 0;
		a->base = ri;
		a->index = rb;
	}
	if (!req(a->base, R)) {
		assert(rtype(a->base) == RTmp);
		s = fn->tmp[a->base.val].slot;
		if (s != -1) {
			if (!slot_disp32_ok(&a->offset, s, fn))
				return 0;
			a->base = SLOT(s);
		}
	}
	return 1;
}

/* instruction selection
 * requires use counts (as given by parsing)
 */
typedef struct {
	Ins *shift;
	uint defs, uses, owner;
	int rewritten;
} IndexInfo;

static void
indexuse(Ref r, Fn *fn, IndexInfo *info)
{
	if (rtype(r) == RTmp)
		info[r.val].uses++;
	else if (rtype(r) == RMem) {
		Addr *a = &fn->mem[r.val];
		if (rtype(a->base) == RTmp)
			info[a->base.val].uses++;
		if (rtype(a->index) == RTmp)
			info[a->index.val].uses++;
	}
}

/* After local address matching, a scaled temporary may still be carried
 * over a block edge only to serve as a scale-one SIB operand. Keep the
 * unscaled SSA value live instead, with no arithmetic at the use. */
static void
rematindex(Fn *fn)
{
	IndexInfo *info = alloc(fn->ntmp * sizeof *info);
	for (Blk *b=fn->start; b; b=b->link) {
		for (Phi *p=b->phi; p; p=p->link)
			info[p->to.val].defs++;
		for (uint n=0; n<b->nins; n++) {
			Ins *i = b->ins+n;
			if (rtype(i->to) != RTmp || i->to.val < Tmp0)
				continue;
			IndexInfo *t = &info[i->to.val];
			t->defs++;
			if (i->op == Oshl && i->cls == Kl && rtype(i->arg[0]) == RTmp
			&& i->arg[0].val >= Tmp0 && rtype(i->arg[1]) == RCon) {
				Con *c = &fn->con[i->arg[1].val];
				if (c->type == CBits && c->bits.i >= 1 && c->bits.i <= 3) {
					t->shift = i;
					t->owner = b->id;
				}
			}
		}
	}
	for (Blk *b=fn->start; b; b=b->link) {
		for (uint n=0; n<b->nins; n++)
		for (int k=0; k<2; k++) {
			Ref r = b->ins[n].arg[k];
			if (rtype(r) != RMem)
				continue;
			Addr *a = &fn->mem[r.val];
			if (a->scale != 1 || rtype(a->base) != RTmp || rtype(a->index) != RTmp
			|| a->base.val < Tmp0 || a->index.val < Tmp0)
				continue;
			for (int swap=0; swap<2; swap++) {
				Ref scaled = swap ? a->base : a->index;
				IndexInfo *t = info+scaled.val;
				if (!t->shift || t->owner == b->id || t->defs != 1)
					continue;
				Ref src = t->shift->arg[0];
				if (info[src.val].defs != 1 || fn->tmp[src.val].slot != -1)
					continue;
				if (swap)
					a->base = a->index;
				a->index = src;
				a->scale = 1 << fn->con[t->shift->arg[1].val].bits.i;
				t->rewritten = 1;
				break;
			}
		}
	}
	for (Blk *b=fn->start; b; b=b->link) {
		for (Phi *p=b->phi; p; p=p->link)
			for (uint j=0; j<p->narg; j++)
				indexuse(p->arg[j], fn, info);
		indexuse(b->jmp.arg, fn, info);
		for (uint j=0; j<b->nins; j++) {
			indexuse(b->ins[j].arg[0], fn, info);
			indexuse(b->ins[j].arg[1], fn, info);
		}
	}
	for (int t=Tmp0; t<fn->ntmp; t++)
		if (info[t].rewritten && info[t].uses == 0)
			*info[t].shift = (Ins){.op=Onop};
}

/* Count uses in the selected IR, including address components and edges. */
static void
countselected(Ref r, Fn *fn, uint *uses)
{
	if (rtype(r) == RTmp)
		uses[r.val]++;
	else if (rtype(r) == RMem) {
		Addr *a = &fn->mem[r.val];
		if (rtype(a->base) == RTmp)
			uses[a->base.val]++;
		if (rtype(a->index) == RTmp)
			uses[a->index.val]++;
	}
}

/* Fold an adjacent single-use Oload of the same class as the sole memory
 * operand of the next instruction. Adjacent ordering guarantees no
 * intervening store, call or alias write; equal class prevents width/sign
 * mismatches.
 *  - integer Oxcmp: either operand (the other a register, or a constant when
 *    the load is the right operand).
 *  - scalar FP Osub / Odiv: only the right operand, the left one a temporary,
 *    so `subs[sd]` / `divs[sd] mem, reg` keeps the written operand order.
 *    Under XMM pressure spill may still leave the left operand of Osub in a
 *    slot (amd64_op[Osub].nmem == 2); the two-address emitters copy it into
 *    the register destination first, so no instruction gets two memory
 *    operands. Odiv (nmem == 0) always reloads it.
 *    The folded instruction computes IEEE-754 `a - [m]` / `a / [m]` exactly
 *    as a direct subs[sd] / divs[sd] (and C) does, bit for bit. When the
 *    unfolded allocation put the load temporary in the result register
 *    (req(to, arg[1])), emit lowered the sub as `neg; add`, which can flip the
 *    sign of a NaN result; the folded memory form has no arg[1] register and
 *    keeps it. IEEE-754 does not specify the sign of a NaN result.
 * Lean: tests/lean/proofs/QbeAmd64FpRhsLoadFold.lean. */
static void
foldoperandloads(Fn *fn)
{
	uint *uses = alloc(fn->ntmp * sizeof *uses);
	for (Blk *b = fn->start; b; b = b->link) {
		for (Phi *p = b->phi; p; p = p->link)
			for (uint j = 0; j < p->narg; j++)
				countselected(p->arg[j], fn, uses);
		countselected(b->jmp.arg, fn, uses);
		for (uint j = 0; j < b->nins; j++) {
			countselected(b->ins[j].arg[0], fn, uses);
			countselected(b->ins[j].arg[1], fn, uses);
		}
	}
	for (Blk *b = fn->start; b; b = b->link) {
		for (uint j = 1; j < b->nins; j++) {
			Ins *cmp = &b->ins[j], *ld = cmp - 1;
			int fp = KBASE(cmp->cls);
			if (fp ? (cmp->op != Osub && cmp->op != Odiv) : cmp->op != Oxcmp)
				continue;
			if (ld->op != Oload
			|| ld->cls != cmp->cls || rtype(ld->to) != RTmp
			|| ld->to.val < Tmp0 || uses[ld->to.val] != 1)
				continue;
			int side = req(cmp->arg[0], ld->to) ? 0 : 1;
			if ((fp && side != 1) || !req(cmp->arg[side], ld->to))
				continue;
			Ref other = cmp->arg[1 - side];
			if (rtype(other) != RTmp && !(!fp && side == 1 && rtype(other) == RCon))
				continue;
			Ref m = ld->arg[0];
			if (rtype(m) == RTmp) {
				Addr a = {.base = m, .scale = 1};
				vgrow(&fn->mem, ++fn->nmem);
				fn->mem[fn->nmem-1] = a;
				m = MEM(fn->nmem-1);
			}
			if (rtype(m) != RMem)
				continue;
			cmp->arg[side] = m;
			*ld = (Ins){.op=Onop};
		}
	}
}
void
amd64_isel(Fn *fn)
{
	static const Num znum;
	Blk *b, **sb;
	Ins *i;
	Phi *p;
	uint a;
	int n, al;
	int64_t sz;
	AddrNums num;

	/* assign slots to fast allocs */
	b = fn->start;
	/* specific to NAlign == 3 */ /* or change n=4 and sz /= 4 below */
	for (al=Oalloc, n=4; al<=Oalloc1; al++, n*=2)
		for (i=b->ins; i<&b->ins[b->nins]; i++)
			if (i->op == al) {
				if (rtype(i->arg[0]) != RCon)
					break;
				sz = fn->con[i->arg[0].val].bits.i;
				if (sz < 0 || sz >= INT_MAX-15)
					err("invalid alloc size %"PRId64, sz);
				sz = (sz + n-1) & -n;
				sz /= 4;
				if (sz > INT_MAX - fn->slot)
					die("alloc too large");
				fn->tmp[i->to.val].slot = fn->slot;
				fn->slot += sz;
				fn->salign = 2 + al - Oalloc;
				*i = (Ins){.op = Onop};
			}

	/* process basic blocks */
	isel_total_nins = 0;
	for (b=fn->start; b; b=b->link) {
		isel_total_nins += b->nins;
		for (p=b->phi; p; p=p->link)
			isel_total_nins += p->narg;
	}
	n = fn->ntmp;
	num.v = emalloc(n * sizeof num.v[0]);
	num.touched = emalloc(n * sizeof num.touched[0]);
	num.count = 0;
	for (b=fn->start; b; b=b->link) {
		curi = &insb[NIns];
		for (sb=(Blk*[3]){b->s1, b->s2, 0}; *sb; sb++)
			for (p=(*sb)->phi; p; p=p->link) {
				for (a=0; p->blk[a] != b; a++)
					assert(a+1 < p->narg);
				fixarg(&p->arg[a], p->cls, 0, fn);
			}
		if (b->jmp.type == Jjtbl) {
			uint32_t jk, jp;
			for (jk = 0; jk < b->njtbl; jk++) {
				Blk *jt = b->jtbl[jk];
				if (jt == b->s1)
					continue;
				for (jp = 0; jp < jk; jp++)
					if (b->jtbl[jp] == jt)
						break;
				if (jp < jk)
					continue;
				for (p=jt->phi; p; p=p->link) {
					for (a=0; p->blk[a] != b; a++)
						assert(a+1 < p->narg);
					fixarg(&p->arg[a], p->cls, 0, fn);
				}
			}
		}
		while (num.count)
			num.v[num.touched[--num.count]] = znum;
		anumber(&num, b, fn);
		seljmp(b, fn);
		for (i=&b->ins[b->nins]; i!=b->ins;) {
			--i;
			assert(i->op != Osel0);
			if (i->op == Osel1)
				i = selsel(fn, b, i, &num);
			else
				sel(*i, &num, fn);
		}
		idup(b, curi, &insb[NIns]-curi);
	}
	free(num.touched);
	free(num.v);
	rematindex(fn);
	foldoperandloads(fn);

	if (debug['I']) {
		fprintf(stderr, "\n> After instruction selection:\n");
		printfn(fn, stderr);
	}
}

void
amd64_hoist_consts(Fn *fn)
{
	Blk *b, *d, *p, **order;
	Ins *i, ins;
	Con *c;
	uint *nhoist;
	uint k, n, j, pos, bestloop;

	if (fn->nblk == 0)
		return;
	nhoist = alloc(fn->nblk * sizeof *nhoist);
	order = alloc(fn->nblk * sizeof *order);
	n = 0;
	for (b = fn->start; b; b = b->link) {
		b->hascall = 0;
		for (k = 0; k < b->nins; k++) {
			if (b->ins[k].op == Ocall) {
				b->hascall = 1;
				break;
			}
		}
		if (b->loop > 1)
			order[n++] = b;
	}
	for (k = 1; k < n; k++) {
		Blk *key = order[k];
		j = k;
		while (j > 0 && order[j - 1]->loop < key->loop) {
			order[j] = order[j - 1];
			j--;
		}
		order[j] = key;
	}
	for (j = 0; j < n; j++) {
		b = order[j];
		if (b->hascall)
			continue;
		for (k = 0; k < b->nins; k++) {
			i = &b->ins[k];
			if (i->op != Ocopy || i->cls != Kl)
				continue;
			if (rtype(i->arg[0]) != RCon)
				continue;
			if (rtype(i->to) != RTmp || isreg(i->to))
				continue;
			if (fn->tmp[i->to.val].slot != -1 || fn->tmp[i->to.val].ndef != 1)
				continue;
			c = &fn->con[i->arg[0].val];
			if (c->type != CBits)
				continue;
			if (c->bits.i >= INT32_MIN && c->bits.i <= INT32_MAX)
				continue;

			d = 0;
			bestloop = (uint)b->loop;
			for (p = b->idom; p; p = p->idom) {
				if ((uint)p->loop < bestloop) {
					bestloop = (uint)p->loop;
					d = p;
					if (bestloop == 1)
						break;
				}
			}
			if (!d || nhoist[d->id] >= 3)
				continue;

			ins = *i;
			pos = d->nins;
			while (pos > 0) {
				int op = d->ins[pos - 1].op;
				if (op == Oxcmp || op == Oxtest
				 || INRANGE(op, Oflag, Oflag1)
				 || isxsel(op))
					pos--;
				else
					break;
			}
			vgrow(&d->ins, d->nins + 1);
			if (pos < d->nins)
				memmove(&d->ins[pos + 1], &d->ins[pos],
					(d->nins - pos) * sizeof(Ins));
			d->ins[pos] = ins;
			d->nins++;
			nhoist[d->id]++;
			fn->tmp[ins.to.val].bid = d->id;
			fn->tmp[ins.to.val].def = &d->ins[pos];
			b->ins[k] = (Ins){.op = Onop};
		}
	}
	for (b = fn->start; b; b = b->link) {
		if (!nhoist[b->id])
			continue;
		for (k = 0; k < b->nins; k++) {
			Ref to = b->ins[k].to;
			if (rtype(to) == RTmp && !isreg(to) && fn->tmp[to.val].ndef == 1)
				fn->tmp[to.val].def = &b->ins[k];
		}
	}
}
