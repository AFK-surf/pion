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

static Ins *blkdef(Blk *, Ins *, Ref, Fn *);

static int
selcmp_ex(Ref arg[2], int k, int eqne, Blk *b, Ins *cur, Fn *fn)
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
	/* Fuse `and t, a, b; cmp t, #0` (eq/ne, single-use t in same block) -> `tst a, b` */
	if (eqne && b && rtype(arg[1]) == RCon) {
		c = &fn->con[arg[1].val];
		if (c->type == CBits && (k == Kw ? (int32_t)c->bits.i == 0 : c->bits.i == 0)) {
			Ins *d = blkdef(b, cur, arg[0], fn);
			if (d && d->op == Oand && d->cls == k && fn->tmp[arg[0].val].nuse == 1) {
				Ref a0 = d->arg[0], a1 = d->arg[1];
				int fix1 = 1;
				if (rtype(a0) == RCon && rtype(a1) != RCon) {
					r = a0;
					a0 = a1;
					a1 = r;
				}
				if (rtype(a1) == RCon) {
					Con *mc = &fn->con[a1.val];
					if (mc->type == CBits && arm64_logimm(mc->bits.i, k))
						fix1 = 0;
				}
				emit(Oatst, k, R, a0, a1);
				iarg = curi->arg;
				fixarg(&iarg[0], k, 0, fn);
				if (fix1)
					fixarg(&iarg[1], k, 0, fn);
				chuse(arg[0], -1, fn);
				*d = (Ins){.op = Onop};
				return 0;
			}
			/* Fuse `rem/urem t, x, +/-2^k; cmp t, #0` (eq/ne, single-use t) -> `tst x, #(2^k - 1)` */
			if (d && (d->op == Orem || d->op == Ourem) && d->cls == k
			&& fn->tmp[arg[0].val].nuse == 1 && rtype(d->arg[1]) == RCon) {
				Con *dc = &fn->con[d->arg[1].val];
				if (dc->type == CBits) {
					int64_t dv = KWIDE(k) ? dc->bits.i : (int64_t)(int32_t)dc->bits.i;
					uint64_t ad = (d->op == Ourem)
						? (KWIDE(k) ? (uint64_t)dc->bits.i : (uint64_t)(uint32_t)dc->bits.i)
						: (dv < 0 ? (uint64_t)(-(dv + 1)) + 1ULL : (uint64_t)dv);
					if (ad >= 2 && (ad & (ad - 1)) == 0) {
						uint64_t mask = ad - 1;
						if (arm64_logimm((int64_t)mask, k)) {
							emit(Oatst, k, R, d->arg[0], getcon((int64_t)mask, fn));
							iarg = curi->arg;
							fixarg(&iarg[0], k, 0, fn);
							chuse(arg[0], -1, fn);
							*d = (Ins){.op = Onop};
							return 0;
						}
					}
				}
			}
		}
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

static Ins *
ssadef(Ref r, Fn *fn)
{
	if (rtype(r) != RTmp || isreg(r))
		return 0;
	if (fn->tmp[r.val].slot != -1)
		return 0;
	if (fn->tmp[r.val].ndef != 1)
		return 0;
	return fn->tmp[r.val].def;
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
	/* A local fixed allocation is already an FP-relative slot. Preserve
	 * that representation for memory operations and avoid an address temp. */
	if (rtype(addr) == RTmp && fn->tmp[addr.val].slot >= 0) {
		*pr = SLOT(fn->tmp[addr.val].slot);
		chuse(addr, -1, fn);
		return 1;
	}
	def = blkdef(b, cur, addr, fn);
	if (!def || (def->op != Oadd && def->op != Osub) || def->cls != Kl)
		return 0;
	a0 = def->arg[0];
	a1 = def->arg[1];

	/* Slot indices are four-byte units. Stay in the local region so the
	 * spill-pair pass cannot mistake a user address for a private spill.
	 * Only slot + displacement folds: slot - k would select the wrong slot. */
	for (side = 0; def->op == Oadd && side < 2; side++) {
		Ref local = def->arg[side], disp = def->arg[1-side];
		if (rtype(local) != RTmp || fn->tmp[local.val].slot < 0 || rtype(disp) != RCon)
			continue;
		int slot = fn->tmp[local.val].slot;
		c = &fn->con[disp.val];
		off = c->bits.i;
		if (c->type != CBits || off < 0 || off % 4 || off / 4 >= fn->slot-slot
		|| off / 4 >= (1 << 28)-slot)
			continue;
		*pr = SLOT(slot + (int)(off/4));
		chuse(addr, -1, fn);
		if (fn->tmp[addr.val].nuse == 0) {
			chuse(local, -1, fn);
			*def = (Ins){.op = Onop};
		}
		return 1;
	}

	/* Mode A: unsigned scaled displacement, or a negative signed imm9. */
	base = R;
	c = 0;
	if (iskltmp(a0, fn) && rtype(a1) == RCon) {
		base = a0;
		c = &fn->con[a1.val];
	} else if (def->op == Oadd && iskltmp(a1, fn) && rtype(a0) == RCon) {
		base = a1;
		c = &fn->con[a0.val];
	}
	if (c && c->type == CBits) {
		off = c->bits.i;
		if (def->op == Osub) {
			if (off < 1 || off > 256)
				return 0;
			off = -off;
		}
		if ((off >= 0 && off <= (int64_t)4095 * sz && off % sz == 0)
		|| (off >= -256 && off < 0 && fn->tmp[addr.val].nuse == 1)) {
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
	if (def->op != Oadd || !iskltmp(a0, fn) || !iskltmp(a1, fn))
		return 0;

	for (side = 0; side < 2; side++) {
		base = side == 0 ? a0 : a1;
		rhs  = side == 0 ? a1 : a0;
		shl = ssadef(rhs, fn);
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
		ext = (fn->tmp[rhs.val].bid == b->id) ? blkdef(b, shl, idx, fn) : 0;
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
		if (selcmp_ex(i.arg, ck, cc == Cieq || cc == Cine, b, cur, fn))
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
		if (!((i.op == Ostoreb || i.op == Ostoreh
		    || i.op == Ostorew || i.op == Ostorel)
		   && rtype(iarg[0]) == RCon
		   && fn->con[iarg[0].val].type == CBits
		   && fn->con[iarg[0].val].bits.i == 0))
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
		case Oror:
			if (rtype(i.arg[1]) == RCon) {
				c = &fn->con[i.arg[1].val];
				if (c->type == CBits) {
					n = c->bits.i & (KWIDE(i.cls) ? 63 : 31);
					i.arg[1] = getcon(n, fn);
					fix1 = 0;
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
		case Odiv:
		case Orem:
			if (rtype(i.arg[1]) == RCon) {
				c = &fn->con[i.arg[1].val];
				if (c->type == CBits) {
					int k = i.cls;
					int W = KWIDE(k) ? 64 : 32;
					int64_t d = KWIDE(k) ? c->bits.i : (int64_t)(int32_t)c->bits.i;
					int64_t min_d = KWIDE(k) ? INT64_MIN : (int64_t)INT32_MIN;
					if (d != min_d && (d >= 2 || d <= -2)) {
						uint64_t ad = d < 0 ? (uint64_t)(0ULL - (uint64_t)d) : (uint64_t)d;
						Ref rx = i.arg[0];
						int need_fix_x = (rtype(rx) == RCon
							|| (rtype(rx) == RTmp && fn->tmp[rx.val].slot != -1));
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
							Ref q, q2, q1, q0, sgn;
							if (i.op == Orem) {
								Ref prod = newtmp("div", k, fn);
								Ref dreg = newtmp("div", k, fn);
								q = newtmp("div", k, fn);
								emit(Osub, k, i.to, rx, prod);
								emit(Omul, k, prod, q, dreg);
								emit(Ocopy, k, dreg, getcon(d, fn), R);
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
							if (KWIDE(k)) {
								Ref mreg = newtmp("div", Kl, fn);
								emit(Osmulh, Kl, q0, rx, mreg);
								emit(Ocopy, Kl, mreg, getcon(mg.m, fn), R);
							} else {
								Ref x64 = newtmp("div", Kl, fn);
								Ref mreg = newtmp("div", Kl, fn);
								Ref p64 = newtmp("div", Kl, fn);
								Ref q64 = newtmp("div", Kl, fn);
								emit(Ocopy, Kw, q0, q64, R);
								emit(Osar, Kl, q64, p64, getcon(32, fn));
								emit(Omul, Kl, p64, x64, mreg);
								emit(Ocopy, Kl, mreg, getcon(mg.m, fn), R);
								emit(Oextsw, Kl, x64, rx, R);
							}
						}
						if (need_fix_x) {
							if (rtype(i.arg[0]) == RCon)
								emit(Ocopy, k, rx, i.arg[0], R);
							else
								emit(Oaddr, Kl, rx, SLOT(fn->tmp[i.arg[0].val].slot), R);
						}
						return;
					}
				}
			}
			break;
		case Omul:
			if (rtype(i.arg[0]) == RCon && rtype(i.arg[1]) != RCon) {
				r = i.arg[0];
				i.arg[0] = i.arg[1];
				i.arg[1] = r;
			}
			if (rtype(i.arg[1]) == RCon) {
				c = &fn->con[i.arg[1].val];
				if (c->type == CBits) {
					uint64_t u = KWIDE(i.cls) ? (uint64_t)c->bits.i : (uint64_t)(uint32_t)c->bits.i;
					int maxsh = KWIDE(i.cls) ? 64 : 32;
					if (u >= 2 && (u & (u - 1)) == 0) {
						int sh = 0;
						while ((1ULL << sh) != u)
							sh++;
						if (sh < maxsh) {
							i.op = Oshl;
							i.arg[1] = getcon(sh, fn);
							fix1 = 0;
						}
					} else if (u >= 3 && ((u - 1) & (u - 2)) == 0) {
						uint64_t p2 = u - 1;
						int sh = 0;
						while ((1ULL << sh) != p2)
							sh++;
						if (sh < maxsh) {
							Ref r1 = newtmp("mul", i.cls, fn);
							Ref x = i.arg[0];
							emit(Oadd, i.cls, i.to, r1, x);
							iarg = curi->arg;
							fixarg(&iarg[1], i.cls, 0, fn);
							emit(Oshl, i.cls, r1, iarg[1], getcon(sh, fn));
							return;
						}
					} else if (u >= 3 && ((u + 1) & u) == 0) {
						uint64_t p2 = u + 1;
						int sh = 0;
						while (sh < maxsh && (1ULL << sh) != p2)
							sh++;
						if (sh < maxsh && (1ULL << sh) == p2) {
							Ref r1 = newtmp("mul", i.cls, fn);
							Ref x = i.arg[0];
							emit(Osub, i.cls, i.to, r1, x);
							iarg = curi->arg;
							fixarg(&iarg[1], i.cls, 0, fn);
							emit(Oshl, i.cls, r1, iarg[1], getcon(sh, fn));
							return;
						}
					}
				}
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

static Ins *
selsel(Fn *fn, Blk *b, Ins *i)
{
	Ref r, cr[2];
	Ins *isel0, *isel1, *ir, *first_sel;
	int ck, cc, nsels, k, swap;

	assert(i->op == Osel1);
	for (isel0 = i; isel0 > b->ins; isel0--) {
		if (isel0->op == Osel0)
			break;
		assert(isel0->op == Osel1);
	}
	assert(isel0->op == Osel0);
	r = isel0->arg[0];
	ir = 0;
	for (Ins *p = isel0; p > b->ins;) {
		--p;
		if (req(p->to, r)) {
			ir = p;
			break;
		}
	}
	if (ir && rtype(r) == RTmp && fn->tmp[r.val].nuse == 1
	&& iscmp(ir->op, &ck, &cc)
	&& !isreg(ir->arg[0]) && !isreg(ir->arg[1])) {
		cr[0] = ir->arg[0];
		cr[1] = ir->arg[1];
		*ir = (Ins){.op = Onop};
	} else {
		cr[0] = r;
		cr[1] = CON_Z;
		ck = Kw;
		cc = Cine;
	}
	nsels = 0;
	for (isel1 = i; isel1 > isel0; --isel1) {
		emit(Oxsel + cc, isel1->cls, isel1->to, isel1->arg[0], isel1->arg[1]);
		nsels++;
	}
	first_sel = curi;
	swap = selcmp_ex(cr, ck, cc == Cieq || cc == Cine, b, isel0, fn);
	if (swap) {
		int swcc = cmpop(cc);
		for (k = 0; k < nsels; k++)
			first_sel[k].op = Oxsel + swcc;
	}
	for (k = 0; k < nsels; k++) {
		fixarg(&first_sel[k].arg[0], first_sel[k].cls, 0, fn);
		fixarg(&first_sel[k].arg[1], first_sel[k].cls, 0, fn);
	}
	*isel0 = (Ins){.op = Onop};
	return isel0;
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
		if (selcmp_ex(ir->arg, ck, cc == Cieq || cc == Cine, b, ir, fn))
			cc = cmpop(cc);
		b->jmp.type = Jjf + cc;
		*ir = (Ins){.op = Onop};
	}
	else {
		selcmp_ex((Ref[]){r, CON_Z}, Kw, 1, b, &b->ins[b->nins], fn);
		b->jmp.type = Jjfine;
	}
}

void
arm64_isel(Fn *fn)
{
	Blk *b, **sb;
	Ins *i;
	Phi *p;
	uint n;
	int al, maxa = 1;
	int64_t sz;

	/* assign slots to fast allocs */
	b = fn->start;
	/* specific to NAlign == 3 */ /* or change n=16 and sz /= 4 below */
	/* Largest alignment first: every size is rounded to its own
	 * alignment, so each slot offset stays a multiple of it (an
	 * alloc16 after an alloc4 used to land 4 bytes off). */
	for (al=Oalloc1, n=16; al>=Oalloc; al--, n/=2)
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
				if ((int)(n / 4) > maxa)
					maxa = (int)(n / 4);
				fn->slot += sz;
				*i = (Ins){.op = Onop};
			}
	/* Frame bases are 16-byte aligned: keep the slot area a multiple
	 * of the largest alloc alignment so offsets from either end stay
	 * aligned (both 0 + 4*s and 4*(f - fn->slot + s)). */
	if (maxa > 1) {
		int rem = fn->slot & (maxa - 1);
		if (rem) {
			int pad = maxa - rem;
			if (pad > INT_MAX - fn->slot)
				die("alloc too large");
			fn->slot += pad;
		}
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
			assert(i->op != Osel0);
			if (i->op == Osel1)
				i = selsel(fn, b, i);
			else
				sel(*i, b, i, fn);
		}
		idup(b, curi, &insb[NIns]-curi);
		for (n=0; n<b->nins; n++) {
			Ref to = b->ins[n].to;
			if (rtype(to) == RTmp && !isreg(to) && fn->tmp[to.val].ndef == 1)
				fn->tmp[to.val].def = &b->ins[n];
		}
	}

	if (debug['I']) {
		fprintf(stderr, "\n> After instruction selection:\n");
		printfn(fn, stderr);
	}
}

static void
arm64_subst_tmp(Fn *fn, Ref oldr, Ref newr)
{
	Blk *b;
	Phi *p;
	uint k;
	int mi;

	for (b = fn->start; b; b = b->link) {
		for (p = b->phi; p; p = p->link)
			for (k = 0; k < p->narg; k++)
				if (req(p->arg[k], oldr)) {
					p->arg[k] = newr;
					chuse(oldr, -1, fn);
					chuse(newr, +1, fn);
				}
		for (k = 0; k < b->nins; k++) {
			if (req(b->ins[k].arg[0], oldr)) {
				b->ins[k].arg[0] = newr;
				chuse(oldr, -1, fn);
				chuse(newr, +1, fn);
			}
			if (req(b->ins[k].arg[1], oldr)) {
				b->ins[k].arg[1] = newr;
				chuse(oldr, -1, fn);
				chuse(newr, +1, fn);
			}
		}
		if (req(b->jmp.arg, oldr)) {
			b->jmp.arg = newr;
			chuse(oldr, -1, fn);
			chuse(newr, +1, fn);
		}
	}
	for (mi = 0; mi < fn->nmem; mi++) {
		if (req(fn->mem[mi].base, oldr)) {
			fn->mem[mi].base = newr;
			chuse(oldr, -1, fn);
			chuse(newr, +1, fn);
		}
		if (req(fn->mem[mi].index, oldr)) {
			fn->mem[mi].index = newr;
			chuse(oldr, -1, fn);
			chuse(newr, +1, fn);
		}
	}
}

static int
arm64_only_used_by_mul(Blk *b, Fn *fn, Ref r)
{
	uint m, nuse = 0;

	if (fn->tmp[r.val].nuse <= 0)
		return 0;
	for (m = 0; m < b->nins; m++) {
		Ins *u = &b->ins[m];
		if (req(u->arg[0], r) || req(u->arg[1], r)) {
			if (u->op != Omul || KBASE(u->cls) != 0)
				return 0;
			if (req(u->arg[0], r))
				nuse++;
			if (req(u->arg[1], r))
				nuse++;
		}
	}
	return nuse == (uint)fn->tmp[r.val].nuse;
}

void
arm64_hoist_consts(Fn *fn)
{
	Blk *b, *d, *p, **order;
	Ins *i, ins;
	Con *c;
	uint *nhoist_fp, *nhoist_int;
	uint k, n, j, pos, bestloop;

	if (fn->nblk == 0)
		return;
	nhoist_fp = alloc(fn->nblk * sizeof *nhoist_fp);
	nhoist_int = alloc(fn->nblk * sizeof *nhoist_int);
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
	for (int pass = 0; pass < 2; pass++)
	for (j = 0; j < n; j++) {
		b = order[j];
		if (pass == 1 && (b->hascall || b->loop < 10))
			continue;
		for (k = 0; k < b->nins; k++) {
			int is_int;
			i = &b->ins[k];
			if (i->op != Ocopy)
				continue;
			is_int = (KBASE(i->cls) == 0);
			if (pass == 1 && !is_int)
				continue;
			if (!is_int && KBASE(i->cls) != 1)
				continue;
			if (rtype(i->arg[0]) != RCon)
				continue;
			if (rtype(i->to) != RTmp || isreg(i->to))
				continue;
			if (fn->tmp[i->to.val].slot != -1 || fn->tmp[i->to.val].ndef != 1)
				continue;
			c = &fn->con[i->arg[0].val];
			/* Hoist read-only FP constant-pool loads: Ocopy addr, CAddr(".LfpN") + Oload dst, addr */
			if (pass == 0 && is_int && i->cls == Kl && c->type == CAddr && c->bits.i == 0
			&& k + 1 < b->nins && b->ins[k + 1].op == Oload
			&& KBASE(b->ins[k + 1].cls) == 1
			&& req(b->ins[k + 1].arg[0], i->to)
			&& rtype(b->ins[k + 1].to) == RTmp && !isreg(b->ins[k + 1].to)
			&& fn->tmp[i->to.val].nuse == 1
			&& fn->tmp[b->ins[k + 1].to.val].slot == -1
			&& fn->tmp[b->ins[k + 1].to.val].ndef == 1) {
				char *sname = str(c->sym.id);
				size_t alen = strlen(T.asloc);
				if (sname[0] == '"' && strncmp(sname + 1, T.asloc, alen) == 0
				&& strncmp(sname + 1 + alen, "fp", 2) == 0) {
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
					if (d) {
						/* Reuse an already-hoisted identical .Lfp load in preheader d */
						Ref existing = R;
						for (uint m = 0; m + 1 < d->nins; m++) {
							Ref cand = d->ins[m + 1].to;
							if (d->ins[m].op == Ocopy && d->ins[m].cls == Kl
							&& rtype(d->ins[m].arg[0]) == RCon
							&& d->ins[m + 1].op == Oload
							&& d->ins[m + 1].cls == b->ins[k + 1].cls
							&& req(d->ins[m + 1].arg[0], d->ins[m].to)
							&& rtype(cand) == RTmp && !isreg(cand)
							&& fn->tmp[cand.val].slot == -1
							&& fn->tmp[cand.val].ndef == 1) {
								Con *ec = &fn->con[d->ins[m].arg[0].val];
								if (ec->type == CAddr && ec->bits.i == 0
								&& symeq(ec->sym, c->sym)) {
									existing = cand;
									break;
								}
							}
						}
						if (!req(existing, R)) {
							Ref oldr = b->ins[k + 1].to;
							b->ins[k] = (Ins){.op = Onop};
							b->ins[k + 1] = (Ins){.op = Onop};
							arm64_subst_tmp(fn, oldr, existing);
							k++;
							continue;
						}
					}
					if (d && nhoist_fp[d->id] < 8) {
						Ins ins0 = *i;
						Ins ins1 = b->ins[k + 1];
						pos = d->nins;
						while (pos > 0) {
							int op = d->ins[pos - 1].op;
							if (op == Oacmp || op == Oacmn || op == Oatst || op == Oafcmp
							 || INRANGE(op, Oflag, Oflag1)
							 || isxsel(op))
								pos--;
							else
								break;
						}
						vgrow(&d->ins, d->nins + 2);
						if (pos < d->nins)
							memmove(&d->ins[pos + 2], &d->ins[pos],
								(d->nins - pos) * sizeof(Ins));
						d->ins[pos] = ins0;
						d->ins[pos + 1] = ins1;
						d->nins += 2;
						nhoist_fp[d->id]++;
						fn->tmp[ins0.to.val].bid = d->id;
						fn->tmp[ins0.to.val].def = &d->ins[pos];
						fn->tmp[ins1.to.val].bid = d->id;
						fn->tmp[ins1.to.val].def = &d->ins[pos + 1];
						b->ins[k] = (Ins){.op = Onop};
						b->ins[k + 1] = (Ins){.op = Onop};
						k++;
						continue;
					}
				}
			}
			if (c->type != CBits || c->bits.i == 0)
				continue;
			if (is_int) {
				int single_insn;
				if (b->hascall)
					continue;
				if (i->cls == Kw) {
					uint32_t u = (uint32_t)c->bits.i;
					int64_t nv = (int32_t)u;
					single_insn = ((u & ~0xffffu) == 0
						|| (nv | 0xffff) == -1
						|| arm64_logimm(u, Kw));
				} else {
					uint64_t u = (uint64_t)c->bits.i;
					int64_t nv = c->bits.i;
					single_insn = ((u & ~0xffffULL) == 0
						|| (nv | 0xffff) == -1
						|| arm64_logimm(u, Kl));
				}
				if (pass == 0) {
					if (single_insn)
						continue;
				} else {
					if (!single_insn || !arm64_only_used_by_mul(b, fn, i->to))
						continue;
				}
			}

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
			if (!d)
				continue;
			/* Reuse an already-hoisted identical CBits constant in preheader d */
			{
				Ref existing = R;
				for (uint m = 0; m < d->nins; m++) {
					Ref cand = d->ins[m].to;
					if (d->ins[m].op == Ocopy && d->ins[m].cls == i->cls
					&& rtype(d->ins[m].arg[0]) == RCon
					&& rtype(cand) == RTmp && !isreg(cand)
					&& fn->tmp[cand.val].slot == -1
					&& fn->tmp[cand.val].ndef == 1) {
						Con *ec = &fn->con[d->ins[m].arg[0].val];
						if (ec->type == CBits && ec->bits.i == c->bits.i) {
							existing = cand;
							break;
						}
					}
				}
				if (!req(existing, R)) {
					Ref oldr = i->to;
					b->ins[k] = (Ins){.op = Onop};
					arm64_subst_tmp(fn, oldr, existing);
					continue;
				}
			}
			if (is_int ? (nhoist_int[d->id] >= (pass == 0 ? 4 : 5)) : (nhoist_fp[d->id] >= 8))
				continue;

			ins = *i;
			pos = d->nins;
			while (pos > 0) {
				int op = d->ins[pos - 1].op;
				if (op == Oacmp || op == Oacmn || op == Oatst || op == Oafcmp
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
			if (is_int)
				nhoist_int[d->id]++;
			else
				nhoist_fp[d->id]++;
			fn->tmp[ins.to.val].bid = d->id;
			fn->tmp[ins.to.val].def = &d->ins[pos];
			b->ins[k] = (Ins){.op = Onop};
		}
	}
	for (b = fn->start; b; b = b->link) {
		if (!nhoist_fp[b->id] && !nhoist_int[b->id])
			continue;
		for (k = 0; k < b->nins; k++) {
			Ref to = b->ins[k].to;
			if (rtype(to) == RTmp && !isreg(to) && fn->tmp[to.val].ndef == 1)
				fn->tmp[to.val].def = &b->ins[k];
		}
	}
}

/* Pair two adjacent spill/reload instructions on compiler-private
 * spill slots into one stp/ldp [x29, #off].
 *
 * Only slots allocated by spill() (rsval >= firstspill) qualify: user
 * allocs, whose address may escape, and incoming stack arguments
 * (negative slots) are never paired.  Both instructions must be of the
 * same kind (two stores or two loads) and the same integer class, so
 * they touch two disjoint, adjacent w-byte cells and read/write only
 * registers (the base x29 is never a transfer register).  Two loads
 * must target distinct registers (ldp Rt1 == Rt2 is CONSTRAINED
 * UNPREDICTABLE).  The low-address cell is always Rt, independent of
 * instruction order.  The offset formula is the s >= 0 case of
 * slot()/me_slot(); it must be w-aligned and fit the scaled imm7
 * (off/w <= 63, positive only), otherwise the caller falls back to
 * two single ldr/str. */
int
arm64_slotpair(Ins *i, uint padding, int firstspill, ArmSlotPair *p)
{
	int kind[2], cls[2], reg[2];
	uint64_t off[2];
	Ref sl[2];
	int j, lo, hi;
	uint w;

	for (j = 0; j < 2; j++) {
		Ins *x = i+j;
		Ref r, s;
		if ((x->op == Oload || x->op == Ocopy) && rtype(x->arg[0]) == RSlot) {
			kind[j] = 1; cls[j] = x->cls; s = x->arg[0]; r = x->to;
		} else if ((x->op == Ostorew || x->op == Ostorel) && rtype(x->arg[1]) == RSlot) {
			kind[j] = 0; cls[j] = x->op == Ostorew ? Kw : Kl; s = x->arg[1]; r = x->arg[0];
		} else if (x->op == Ocopy && rtype(x->to) == RSlot) {
			kind[j] = 0; cls[j] = x->cls; s = x->to; r = x->arg[0];
		} else
			return 0;
		if ((cls[j] != Kw && cls[j] != Kl) || rsval(s) < firstspill
		|| !isreg(r) || r.val < R0 || r.val >= FP)
			return 0;
		reg[j] = r.val;
		sl[j] = s;
		off[j] = 16ULL + padding + 4ULL * (uint64_t)rsval(s);
	}
	if (kind[0] != kind[1] || cls[0] != cls[1])
		return 0;
	if (kind[0] && reg[0] == reg[1])
		return 0;
	lo = off[1] < off[0];
	hi = 1-lo;
	w = cls[0] == Kw ? 4 : 8;
	if (off[hi] != off[lo] + w || off[lo] % w || off[lo] / w > 63)
		return 0;
	*p = (ArmSlotPair){
		.load = kind[0], .cls = cls[0], .lo = reg[lo], .hi = reg[hi],
		.offset = (uint)off[lo], .slot = sl[lo],
	};
	return 1;
}
