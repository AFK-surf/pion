#include "all.h"

enum Imm {
	Iother,
	Iplo12,
	Iphi12,
	Iplo24,
	Inlo12,
	Inhi12,
	Inlo24
};

static enum Imm
imm(Con *c, int k, int64_t *pn)
{
	int64_t n;
	int i;

	if (c->type != CBits)
		return Iother;
	n = c->bits.i;
	if (k == Kw)
		n = (int32_t)n;
	i = Iplo12;
	if (n < 0) {
		i = Inlo12;
		n = -(uint64_t)n;
	}
	*pn = n;
	if ((n & 0x000fff) == n)
		return i;
	if ((n & 0xfff000) == n)
		return i + 1;
	if ((n & 0xffffff) == n)
		return i + 2;
	return Iother;
}

int
arm64_logimm(uint64_t x, int k)
{
	uint64_t n;

	if (k == Kw)
		x = (x & 0xffffffff) | x << 32;
	if (x & 1)
		x = ~x;
	if (x == 0)
		return 0;
	if (x == 0xaaaaaaaaaaaaaaaa)
		return 1;
	n = x & 0xf;
	if (0x1111111111111111 * n == x)
		goto Check;
	n = x & 0xff;
	if (0x0101010101010101 * n == x)
		goto Check;
	n = x & 0xffff;
	if (0x0001000100010001 * n == x)
		goto Check;
	n = x & 0xffffffff;
	if (0x0000000100000001 * n == x)
		goto Check;
	n = x;
Check:
	return (n & (n + (n & -n))) == 0;
}

int
arm64_fpimm(Con *c, int k)
{
	uint64_t b;
	uint exp;

	if (c->type != CBits)
		return 0;
	if (k == Kd) {
		b = (uint64_t)c->bits.i;
		if (b == 0)
			return 1;
		if ((b & 0xffffffffffffULL) != 0)
			return 0;
		exp = (uint)((b >> 52) & 0x7ff);
		return 1020 <= exp && exp <= 1027;
	}
	if (k == Ks) {
		b = (uint32_t)c->bits.i;
		if (b == 0)
			return 1;
		if ((b & 0x7ffffU) != 0)
			return 0;
		exp = (uint)((b >> 23) & 0xff);
		return 124 <= exp && exp <= 131;
	}
	return 0;
}

static void
fixarg(Ref *pr, int k, int phi, Fn *fn)
{
	char buf[32];
	Con *c, cc;
	Ref r0, r1, r2, r3;
	int s, n;

	r0 = *pr;
	switch (rtype(r0)) {
	case RCon:
		c = &fn->con[r0.val];
		if (T.apple
		&& c->type == CAddr
		&& (c->sym.type & SThr)) {
			r1 = newtmp("isel", Kl, fn);
			*pr = r1;
			if (c->bits.i) {
				r2 = newtmp("isel", Kl, fn);
				cc = (Con){.type = CBits};
				cc.bits.i = c->bits.i;
				r3 = newcon(&cc, fn);
				emit(Oadd, Kl, r1, r2, r3);
				r1 = r2;
			}
			emit(Ocopy, Kl, r1, TMP(R0), R);
			r1 = newtmp("isel", Kl, fn);
			r2 = newtmp("isel", Kl, fn);
			emit(Ocall, 0, R, r1, CALL(33));
			emit(Ocopy, Kl, TMP(R0), r2, R);
			emit(Oload, Kl, r1, r2, R);
			cc = *c;
			cc.bits.i = 0;
			r3 = newcon(&cc, fn);
			emit(Ocopy, Kl, r2, r3, R);
			break;
		}
		if (KBASE(k) == 0 && phi)
			return;
		r1 = newtmp("isel", k, fn);
		if (KBASE(k) == 0 || arm64_fpimm(c, k)) {
			emit(Ocopy, k, r1, r0, R);
		} else {
			n = stashbits(c->bits.i, KWIDE(k) ? 8 : 4);
			vgrow(&fn->con, ++fn->ncon);
			c = &fn->con[fn->ncon-1];
			sprintf(buf, "\"%sfp%d\"", T.asloc, n);
			*c = (Con){.type = CAddr};
			c->sym.id = intern(buf);
			r2 = newtmp("isel", Kl, fn);
			emit(Oload, k, r1, r2, R);
			emit(Ocopy, Kl, r2, CON(c-fn->con), R);
		}
		*pr = r1;
		break;
	case RTmp:
		s = fn->tmp[r0.val].slot;
		if (s == -1)
			break;
		r1 = newtmp("isel", Kl, fn);
		emit(Oaddr, Kl, r1, SLOT(s), R);
		*pr = r1;
		break;
	}
}

static int
selcmp(Ref arg[2], int k, Fn *fn)
{
	Ref r, *iarg;
	Con *c;
	int swap, cmp, fix;
	int64_t n;

	if (KBASE(k) == 1) {
		fix = 1;
		if (rtype(arg[1]) == RCon) {
			c = &fn->con[arg[1].val];
			if (c->type == CBits
			&& ((k == Kd && c->bits.i == 0)
			 || (k == Ks && (uint32_t)c->bits.i == 0)))
				fix = 0;
		}
		emit(Oafcmp, k, R, arg[0], arg[1]);
		iarg = curi->arg;
		fixarg(&iarg[0], k, 0, fn);
		if (fix)
			fixarg(&iarg[1], k, 0, fn);
		return 0;
	}
	swap = rtype(arg[0]) == RCon;
	if (swap) {
		r = arg[1];
		arg[1] = arg[0];
		arg[0] = r;
	}
	fix = 1;
	cmp = Oacmp;
	r = arg[1];
	if (rtype(r) == RCon) {
		c = &fn->con[r.val];
		switch (imm(c, k, &n)) {
		default:
			break;
		case Iplo12:
		case Iphi12:
			r = getcon(n, fn);
			fix = 0;
			break;
		case Inlo12:
		case Inhi12:
			cmp = Oacmn;
			r = getcon(n, fn);
			fix = 0;
			break;
		}
	}
	emit(cmp, k, R, arg[0], r);
	iarg = curi->arg;
	fixarg(&iarg[0], k, 0, fn);
	if (fix)
		fixarg(&iarg[1], k, 0, fn);
	return swap;
}

static int
callable(Ref r, Fn *fn)
{
	Con *c;

	if (rtype(r) == RTmp)
		return 1;
	if (rtype(r) == RCon) {
		c = &fn->con[r.val];
		if (c->type == CAddr)
		if (c->bits.i == 0)
			return 1;
	}
	return 0;
}

static Ins *
blkdef(Blk *b, Ins *cur, Ref r, Fn *fn)
{
	Ins *d;

	if (rtype(r) != RTmp || isreg(r))
		return 0;
	if (fn->tmp[r.val].slot != -1)
		return 0;
	if (fn->tmp[r.val].bid != b->id || fn->tmp[r.val].ndef != 1)
		return 0;
	d = fn->tmp[r.val].def;
	if (!d || d < b->ins || d >= cur)
		return 0;
	return d;
}

static int
iskltmp(Ref r, Fn *fn)
{
	return rtype(r) == RTmp
		&& !isreg(r)
		&& fn->tmp[r.val].slot == -1
		&& fn->tmp[r.val].cls == Kl;
}

static int
iskwtmp(Ref r, Fn *fn)
{
	return rtype(r) == RTmp
		&& !isreg(r)
		&& fn->tmp[r.val].slot == -1
		&& fn->tmp[r.val].cls == Kw;
}

static int
seladdr(Ref *pr, int sz, Blk *b, Ins *cur, Fn *fn)
{
	Ref addr, a0, a1, base, rhs, idx;
	Ins *def, *shl, *ext;
	Con *c;
	Mem *m;
	int64_t off, s;
	int side;

	addr = *pr;
	def = blkdef(b, cur, addr, fn);
	if (!def || def->op != Oadd || def->cls != Kl)
		return 0;
	a0 = def->arg[0];
	a1 = def->arg[1];

	/* Mode A: [base, #off] with ARM64 unsigned scaled offset */
	base = R;
	c = 0;
	if (iskltmp(a0, fn) && rtype(a1) == RCon) {
		base = a0;
		c = &fn->con[a1.val];
	} else if (iskltmp(a1, fn) && rtype(a0) == RCon) {
		base = a1;
		c = &fn->con[a0.val];
	}
	if (c && c->type == CBits) {
		off = c->bits.i;
		if (off >= 0 && off <= (int64_t)4095 * sz && (off % sz) == 0) {
			vgrow(&fn->mem, ++fn->nmem);
			m = &fn->mem[fn->nmem - 1];
			memset(m, 0, sizeof *m);
			m->offset.type = CBits;
			m->offset.bits.i = off;
			m->base = base;
			m->index = R;
			m->scale = 0;
			fixarg(&m->base, Kl, 0, fn);
			chuse(addr, -1, fn);
			chuse(m->base, +1, fn);
			if (fn->tmp[addr.val].nuse == 0) {
				chuse(def->arg[0], -1, fn);
				chuse(def->arg[1], -1, fn);
				*def = (Ins){.op = Onop};
			}
			*pr = MEM(fn->nmem - 1);
			return 1;
		}
		return 0;
	}

	/* Mode B: [base, idx, lsl #shift] or [base, idx] */
	if (!iskltmp(a0, fn) || !iskltmp(a1, fn))
		return 0;

	for (side = 0; side < 2; side++) {
		base = side == 0 ? a0 : a1;
		rhs  = side == 0 ? a1 : a0;
		shl = blkdef(b, def, rhs, fn);
		if (!shl || shl->op != Oshl || shl->cls != Kl)
			continue;
		idx = shl->arg[0];
		if (!iskltmp(idx, fn) || rtype(shl->arg[1]) != RCon)
			continue;
		c = &fn->con[shl->arg[1].val];
		if (c->type != CBits)
			continue;
		s = c->bits.i;
		if (s < 0 || s > 3 || (1 << s) != sz)
			continue;
		ext = blkdef(b, shl, idx, fn);
		if (ext && ext->op == Oextsw && iskwtmp(ext->arg[0], fn)) {
			vgrow(&fn->mem, ++fn->nmem);
			m = &fn->mem[fn->nmem - 1];
			memset(m, 0, sizeof *m);
			m->offset.type = CBits;
			m->offset.bits.i = 0;
			m->base = base;
			m->index = ext->arg[0];
			m->scale = -sz;
			fixarg(&m->base, Kl, 0, fn);
			fixarg(&m->index, Kw, 0, fn);
			chuse(addr, -1, fn);
			chuse(m->base, +1, fn);
			chuse(m->index, +1, fn);
			if (fn->tmp[addr.val].nuse == 0) {
				chuse(def->arg[0], -1, fn);
				chuse(def->arg[1], -1, fn);
				*def = (Ins){.op = Onop};
				if (fn->tmp[rhs.val].nuse == 0) {
					chuse(shl->arg[0], -1, fn);
					chuse(shl->arg[1], -1, fn);
					*shl = (Ins){.op = Onop};
					if (fn->tmp[idx.val].nuse == 0) {
						chuse(ext->arg[0], -1, fn);
						*ext = (Ins){.op = Onop};
					}
				}
			}
			*pr = MEM(fn->nmem - 1);
			return 1;
		}
		vgrow(&fn->mem, ++fn->nmem);
		m = &fn->mem[fn->nmem - 1];
		memset(m, 0, sizeof *m);
		m->offset.type = CBits;
		m->offset.bits.i = 0;
		m->base = base;
		m->index = idx;
		m->scale = sz;
		fixarg(&m->base, Kl, 0, fn);
		fixarg(&m->index, Kl, 0, fn);
		chuse(addr, -1, fn);
		chuse(m->base, +1, fn);
		chuse(m->index, +1, fn);
		if (fn->tmp[addr.val].nuse == 0) {
			chuse(def->arg[0], -1, fn);
			chuse(def->arg[1], -1, fn);
			*def = (Ins){.op = Onop};
			if (fn->tmp[rhs.val].nuse == 0) {
				chuse(shl->arg[0], -1, fn);
				chuse(shl->arg[1], -1, fn);
				*shl = (Ins){.op = Onop};
			}
		}
		*pr = MEM(fn->nmem - 1);
		return 1;
	}

	if (fn->tmp[addr.val].nuse == 1) {
		vgrow(&fn->mem, ++fn->nmem);
		m = &fn->mem[fn->nmem - 1];
		memset(m, 0, sizeof *m);
		m->offset.type = CBits;
		m->offset.bits.i = 0;
		m->base = a0;
		m->index = a1;
		m->scale = 1;
		ext = 0;
		idx = R;
		if ((ext = blkdef(b, def, a1, fn)) && ext->op == Oextsw && iskwtmp(ext->arg[0], fn)) {
			m->base = a0;
			m->index = ext->arg[0];
			m->scale = -1;
			idx = a1;
		} else if ((ext = blkdef(b, def, a0, fn)) && ext->op == Oextsw && iskwtmp(ext->arg[0], fn)) {
			m->base = a1;
			m->index = ext->arg[0];
			m->scale = -1;
			idx = a0;
		} else {
			ext = 0;
		}
		fixarg(&m->base, Kl, 0, fn);
		fixarg(&m->index, m->scale < 0 ? Kw : Kl, 0, fn);
		chuse(addr, -1, fn);
		chuse(m->base, +1, fn);
		chuse(m->index, +1, fn);
		chuse(def->arg[0], -1, fn);
		chuse(def->arg[1], -1, fn);
		*def = (Ins){.op = Onop};
		if (ext && fn->tmp[idx.val].nuse == 0) {
			chuse(ext->arg[0], -1, fn);
			*ext = (Ins){.op = Onop};
		}
		*pr = MEM(fn->nmem - 1);
		return 1;
	}
	return 0;
}

static void
sel(Ins i, Blk *b, Ins *cur, Fn *fn)
{
	Ref *iarg, r;
	Ins *i0;
	Con *c;
	int ck, cc, fix1;
	int64_t n;

	if (i.op == Onop)
		return;
	if (INRANGE(i.op, Oalloc, Oalloc1)) {
		i0 = curi - 1;
		salloc(i.to, i.arg[0], fn);
		fixarg(&i0->arg[0], Kl, 0, fn);
		return;
	}
	if (iscmp(i.op, &ck, &cc)) {
		emit(Oflag, i.cls, i.to, R, R);
		i0 = curi;
		if (selcmp(i.arg, ck, fn))
			i0->op += cmpop(cc);
		else
			i0->op += cc;
		return;
	}
	if (i.op == Ocall)
	if (callable(i.arg[0], fn)) {
		emiti(i);
		return;
	}
	if (isload(i.op)) {
		emiti(i);
		iarg = curi->arg;
		if (!seladdr(&iarg[0], loadsz(&i), b, cur, fn))
			fixarg(&iarg[0], argcls(&i, 0), 0, fn);
		return;
	}
	if (isstore(i.op)) {
		emiti(i);
		iarg = curi->arg;
		fixarg(&iarg[0], argcls(&i, 0), 0, fn);
		if (!seladdr(&iarg[1], storesz(&i), b, cur, fn))
			fixarg(&iarg[1], argcls(&i, 1), 0, fn);
		return;
	}
	fix1 = 1;
	if (KBASE(i.cls) == 0) {
		switch (i.op) {
		case Oadd:
			if (rtype(i.arg[0]) == RCon && rtype(i.arg[1]) != RCon) {
				r = i.arg[0];
				i.arg[0] = i.arg[1];
				i.arg[1] = r;
			}
			/* fall through */
		case Osub:
			if (rtype(i.arg[1]) == RCon) {
				c = &fn->con[i.arg[1].val];
				switch (imm(c, i.cls, &n)) {
				case Iplo12:
				case Iphi12:
					i.arg[1] = getcon(n, fn);
					fix1 = 0;
					break;
				case Inlo12:
				case Inhi12:
					i.op = i.op == Oadd ? Osub : Oadd;
					i.arg[1] = getcon(n, fn);
					fix1 = 0;
					break;
				default:
					break;
				}
			}
			break;
		case Oshl:
		case Oshr:
		case Osar:
			if (rtype(i.arg[1]) == RCon) {
				c = &fn->con[i.arg[1].val];
				if (c->type == CBits) {
					n = c->bits.i;
					if (n >= 0 && n < (KWIDE(i.cls) ? 64 : 32)) {
						i.arg[1] = getcon(n, fn);
						fix1 = 0;
					}
				}
			}
			break;
		case Oand:
		case Oor:
		case Oxor:
			if (rtype(i.arg[0]) == RCon && rtype(i.arg[1]) != RCon) {
				r = i.arg[0];
				i.arg[0] = i.arg[1];
				i.arg[1] = r;
			}
			if (rtype(i.arg[1]) == RCon) {
				c = &fn->con[i.arg[1].val];
				if (c->type == CBits && arm64_logimm(c->bits.i, i.cls))
					fix1 = 0;
			}
			break;
		}
	}
	emiti(i);
	iarg = curi->arg; /* fixarg() can change curi */
	fixarg(&iarg[0], argcls(&i, 0), 0, fn);
	if (fix1)
		fixarg(&iarg[1], argcls(&i, 1), 0, fn);
}

static void
seljmp(Blk *b, Fn *fn)
{
	Ref r;
	Ins *i, *ir;
	int ck, cc, use;

	if (b->jmp.type == Jret0
	|| b->jmp.type == Jjmp
	|| b->jmp.type == Jhlt)
		return;
	if (b->jmp.type == Jjtbl) {
		fixarg(&b->jmp.arg, Kw, 0, fn);
		return;
	}
	assert(b->jmp.type == Jjnz);
	r = b->jmp.arg;
	use = -1;
	b->jmp.arg = R;
	ir = 0;
	i = &b->ins[b->nins];
	while (i > b->ins)
		if (req((--i)->to, r)) {
			use = fn->tmp[r.val].nuse;
			ir = i;
			break;
		}
	if (ir && use == 1
	&& iscmp(ir->op, &ck, &cc)) {
		if (selcmp(ir->arg, ck, fn))
			cc = cmpop(cc);
		b->jmp.type = Jjf + cc;
		*ir = (Ins){.op = Onop};
	}
	else {
		selcmp((Ref[]){r, CON_Z}, Kw, fn);
		b->jmp.type = Jjfine;
	}
}

void
arm64_isel(Fn *fn)
{
	Blk *b, **sb;
	Ins *i;
	Phi *p;
	uint n, al;
	int64_t sz;

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
				fn->tmp[i->to.val].slot = fn->slot;
				fn->slot += sz;
				*i = (Ins){.op = Onop};
			}

	for (b=fn->start; b; b=b->link) {
		curi = &insb[NIns];
		for (sb=(Blk*[3]){b->s1, b->s2, 0}; *sb; sb++)
			for (p=(*sb)->phi; p; p=p->link) {
				for (n=0; p->blk[n] != b; n++)
					assert(n+1 < p->narg);
				fixarg(&p->arg[n], p->cls, 1, fn);
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
					for (n=0; p->blk[n] != b; n++)
						assert(n+1 < p->narg);
					fixarg(&p->arg[n], p->cls, 1, fn);
				}
			}
		}
		seljmp(b, fn);
		for (i=&b->ins[b->nins]; i!=b->ins;) {
			--i;
			sel(*i, b, i, fn);
		}
		idup(b, curi, &insb[NIns]-curi);
	}

	if (debug['I']) {
		fprintf(stderr, "\n> After instruction selection:\n");
		printfn(fn, stderr);
	}
}

void
arm64_hoist_consts(Fn *fn)
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
		for (k = 0; k < b->nins; k++) {
			i = &b->ins[k];
			if (i->op != Ocopy || KBASE(i->cls) != 1)
				continue;
			if (rtype(i->arg[0]) != RCon)
				continue;
			if (rtype(i->to) != RTmp || isreg(i->to))
				continue;
			if (fn->tmp[i->to.val].slot != -1 || fn->tmp[i->to.val].ndef != 1)
				continue;
			c = &fn->con[i->arg[0].val];
			if (c->type != CBits || c->bits.i == 0)
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
			if (!d || nhoist[d->id] >= 8)
				continue;

			ins = *i;
			pos = d->nins;
			while (pos > 0) {
				int op = d->ins[pos - 1].op;
				if (op == Oacmp || op == Oacmn || op == Oafcmp
				 || INRANGE(op, Oflag, Oflag1))
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
