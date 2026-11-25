/* Private, target-selected SSA. A scalar allocation supplies SSE's actual
 * two-address operand order. Only bounded functions with potential adjacent lanes are
 * replayed. */
extern signed char *slporder;
enum { MaxSLPBlock = 128 };

static Fn *
slpsnapshot(Fn *f)
{
	uint n, k, ops = 0, stores = 0;
	Blk *b, *d, **map;
	Fn *g;

	if (f->doubleStores < 2 || f->nblk > 128 || f->ntmp > 1536 || f->dynalloc ||
	    (strcmp(T.name, "amd64_sysv") && strcmp(T.name, "arm64_apple")))
		return 0;
	for (b = f->start; b; b = b->link) {
		if (b->nins > MaxSLPBlock || b->jmp.type == Jjtbl)
			return 0;
		for (n = 0; n < b->nins; n++) {
			Ins i = b->ins[n];
			if (i.op == Oswap)
				return 0;
			ops += i.cls == Kd && (i.op == Oadd || i.op == Osub || i.op == Omul);
			stores += i.op == Ostored;
		}
	}
	if (ops < 2 || stores < 2)
		return 0;
	g = alloc(sizeof *g);
	*g = *f;
	g->packed = 1;
	g->tmp = vnew(f->ntmp, sizeof(Tmp), PFn);
	memcpy(g->tmp, f->tmp, f->ntmp * sizeof(Tmp));
	g->mem = vnew(f->nmem, sizeof(Mem), PFn);
	if (f->nmem)
		memcpy(g->mem, f->mem, f->nmem * sizeof(Mem));
	g->rpo = vnew(f->nblk, sizeof(Blk *), PFn);
	map = alloc(f->nblk * sizeof *map);
	for (n = 0; n < f->nblk; n++)
		map[n] = newblk();
	g->start = map[f->start->id];
	for (b = f->start; b; b = b->link) {
		d = map[b->id];
		idup(d, b->ins, b->nins);
		d->name = b->name;
		d->id = b->id;
		g->rpo[d->id] = d;
		vgrow(&d->pred, b->npred);
		d->npred = b->npred;
		for (k = 0; k < b->npred; k++)
			d->pred[k] = map[b->pred[k]->id];
		d->loop = b->loop;
		d->jmp = b->jmp;
		d->s1 = b->s1 ? map[b->s1->id] : 0;
		d->s2 = b->s2 ? map[b->s2->id] : 0;
		d->link = b->link ? map[b->link->id] : 0;
		Phi **tail = &d->phi;
		for (Phi *p = b->phi; p; p = p->link) {
			Phi *r = alloc(sizeof *r);
			*r = *p;
			r->link = 0;
			r->blk = alloc(p->narg * sizeof(Blk *));
			r->arg = alloc(p->narg * sizeof(Ref));
			for (k = 0; k < p->narg; k++) {
				r->blk[k] = map[p->blk[k]->id];
				r->arg[k] = p->arg[k];
			}
			*tail = r;
			tail = &r->link;
		}
	}
	slporder = alloc(f->ntmp * sizeof *slporder);
	return g;
}

typedef struct {
	Ins *i;
	Phi *p;
	int leader, other, region; /* SSA result, or an internal store number */
	Ref packet;
} Lane;

static int
slpaddr(Fn *f, Ref r, Ref *base, int64_t *off)
{
	if (rtype(r) == RTmp) {
		*base = r;
		*off = 0;
	} else if (rtype(r) == RMem) {
		Mem *m = &f->mem[r.val];
		if (rtype(m->base) != RTmp || !req(m->index, R) ||
		    (m->offset.type != CUndef && m->offset.type != CBits))
			return 0;
		*base = m->base;
		*off = m->offset.type == CUndef ? 0 : m->offset.bits.i;
	} else
		return 0;
	return *off >= 0 && *off <= 255;
}

static int
slpadj(Fn *f, Ref l, Ref r)
{
	Ref a, b;
	int64_t x, y;
	return slpaddr(f, l, &a, &x) && slpaddr(f, r, &b, &y) && req(a, b) && x + 8 == y;
}

static void
slppair(Fn *f, Lane *v, int l, int r)
{
	if (l == r || v[l].leader || v[r].leader || v[l].region != v[r].region)
		return;
	Phi *p = v[l].p, *q = v[r].p;
	Ins *a = v[l].i, *b = v[r].i;
	if (p && q) {
		if (p->cls != Kd || q->cls != Kd || p->narg != q->narg)
			return;
		for (uint n = 0; n < p->narg; n++)
			if (p->blk[n] != q->blk[n] || rtype(p->arg[n]) != RTmp ||
			    rtype(q->arg[n]) != RTmp)
				return;
	} else {
		if (!a || !b || a->op != b->op || a->cls != b->cls)
			return;
		switch (a->op) {
		case Oload:
			if (a->cls != Kd || !slpadj(f, a->arg[0], b->arg[0]))
				return;
			break;
		case Ostored:
			if (!slpadj(f, a->arg[1], b->arg[1]))
				return;
			break;
		case Oordadd:
		case Oordsub:
		case Oordmul:
			if (a->cls != Kd)
				return;
			break;
		default:
			return;
		}
	}
	v[l].leader = l;
	v[l].other = r;
	v[r].leader = l;
	v[l].packet = newtmp("slp", Kv2d, f);
	if (p) {
		for (uint n = 0; n < p->narg; n++)
			slppair(f, v, p->arg[n].val, q->arg[n].val);
	} else if (a->op != Oload) {
		for (uint n = 0; n < (a->op == Ostored ? 1u : 2u); n++)
			if (rtype(a->arg[n]) == RTmp && rtype(b->arg[n]) == RTmp)
				slppair(f, v, a->arg[n].val, b->arg[n].val);
	}
}

static int
slpfp(Ins i)
{
	/* Only SSA definitions may move. A selected square root can contain a
	 * folded memory read which has no explicit load node in this graph. */
	if (isreg(i.to) || (i.op == Osqrt && rtype(i.arg[0]) == RMem))
		return 0;
	return i.op == Onop || i.op == Ostored ||
	       (i.cls == Kd && (i.op == Oload || i.op == Oordadd || i.op == Oordsub ||
				i.op == Oordmul || i.op == Odiv || i.op == Osqrt));
}

static int
slpdep(Fn *f, Ins a, Ins b)
{
	uint j;
	if (rtype(a.to) == RTmp)
		for (j = 0; j < 2; j++)
			if (req(a.to, b.arg[j]))
				return 1;
	if ((a.op == Oload || a.op == Ostored) && (b.op == Oload || b.op == Ostored) &&
	    (a.op == Ostored || b.op == Ostored)) {
		Ref x, y;
		int64_t u, v;
		if (!slpaddr(f, a.arg[a.op == Ostored], &x, &u) ||
		    !slpaddr(f, b.arg[b.op == Ostored], &y, &v) || !req(x, y))
			return 1;
		return u < v + 8 && v < u + 8;
	}
	return 0;
}

typedef struct {
	Ins *ins;
	uint count;
} SlpSeq;
static void
slpput(SlpSeq *s, Ins i)
{
	vgrow(&s->ins, s->count + 1);
	s->ins[s->count++] = i;
}

static Ref
slpvector(Fn *f, Lane *v, SlpSeq *s, Ref a, Ref b)
{
	if (rtype(a) == RTmp && rtype(b) == RTmp && v[a.val].other == (int)b.val)
		return v[a.val].packet;
	/* A temporary is immutable. Share broadcasts within the block. */
	if (req(a, b) && rtype(a) == RTmp && a.val >= Tmp0) {
		uint limit = s->count > MaxSLPBlock ? s->count - MaxSLPBlock : 0;
		for (uint j = s->count; j > limit; j--)
			if (s->ins[j - 1].op == Ovsplat && req(s->ins[j - 1].arg[0], a))
				return s->ins[j - 1].to;
	}
	Ref t = newtmp("zip", Kv2d, f);
	slpput(s, (Ins){req(a, b) ? Ovsplat : Ovzip, Kv2d, t, {a, b}});
	return t;
}

static void
slpextract(SlpSeq *s, Lane *v, int l)
{
	int r = v[l].other;
	slpput(s, (Ins){Ovlo, Kd, TMP(l), {v[l].packet, R}});
	slpput(s, (Ins){Ovhigh, Kd, TMP(r), {v[l].packet, R}});
}

static int
slpschedule(Fn *f, Lane *v, SlpSeq *s, Ins *ins, int *ids, uint count)
{
	enum { Max = 2 * MaxSLPBlock + 2 };
	if (count >= Max)
		return 0;
	uint unit[Max], degree[Max] = {0};
	/* Each representative is one scalar instruction or a contracted pair. */
	uchar dep[Max][Max];
	memset(dep, 0, count * sizeof dep[0]);
	for (uint j = 0; j < count; j++) {
		unit[j] = j;
		if (ids[j] && v[ids[j]].leader && v[ids[j]].leader != ids[j]) {
			uint k;
			for (k = 0; k < count && ids[k] != v[ids[j]].leader; k++) {
			}
			if (k == count)
				return 0;
			unit[j] = k;
		}
	}
	for (uint j = 0; j < count; j++)
		for (uint k = j + 1; k < count; k++)
			if (slpdep(f, ins[j], ins[k]) && !dep[unit[j]][unit[k]]) {
				if (unit[j] == unit[k])
					return 0;
				dep[unit[j]][unit[k]] = 1;
				degree[unit[k]]++;
			}
	for (uint j = 0; j < count; j++)
		if (unit[j] == j) {
			uint k;
			for (k = 0; k < count && (unit[k] != k || degree[k]); k++) {
			}
			if (k == count)
				return 0;
			degree[k] = UINT_MAX;
			for (uint t = 0; t < count; t++)
				if (dep[k][t])
					degree[t]--;
			int l = ids[k];
			Ins a = ins[k];
			if (!l || !v[l].other) {
				if (a.op == Oordadd && a.cls == Kd && rtype(a.arg[0]) == RTmp &&
				    rtype(a.arg[1]) == RTmp &&
				    v[a.arg[0].val].other == (int)a.arg[1].val) {
					a.op = Ovsum;
					a.arg[0] = v[a.arg[0].val].packet;
					a.arg[1] = R;
				}
				if (a.op != Onop)
					slpput(s, a);
				continue;
			}
			Ins b = *v[v[l].other].i;
			if (a.op == Oload) {
				slpput(s, (Ins){Ovload, Kv2d, v[l].packet, {a.arg[0], R}});
			} else if (a.op == Ostored) {
				Ref t = slpvector(f, v, s, a.arg[0], b.arg[0]);
				slpput(s, (Ins){Ovstore, Kv2d, R, {t, a.arg[1]}});
				continue;
			} else {
				Ref x = slpvector(f, v, s, a.arg[0], b.arg[0]);
				int lane =
				    T.apple && a.op == Oordmul && req(a.arg[1], b.arg[1]);
				Ref y = lane ? a.arg[1]
					     : slpvector(f, v, s, a.arg[1], b.arg[1]);
				int op = a.op == Oordadd   ? Ovadd
					 : a.op == Oordsub ? Ovsub
							   : Ovmul;
				slpput(s, (Ins){lane ? Ovmullane : op,
						Kv2d,
						v[l].packet,
						{x, y}});
			}
			slpextract(s, v, l);
		}
	return 1;
}

static int
slpbuild(Fn *f, signed char *order)
{
	int x86 = !strcmp(T.name, "amd64_sysv");
	int region = 0, count = 0;
	uint extra = 0;
	Blk *b;
	for (b = f->start; b; b = b->link) {
		SlpSeq s = {vnew(0, sizeof(Ins), PFn), 0};
		for (uint j = 0; j < b->nins; j++) {
			Ins i = b->ins[j];
			/* Every scalar add / sub / mul, Ks included, keeps the operand
			 * order of the scalar allocation: rega(packet) may assign
			 * registers differently, and the x86 two-address form decides
			 * which NaN payload wins. Only Kd ones are packed. */
			if ((i.cls == Kd && (i.op == Oadd || i.op == Osub || i.op == Omul ||
					     i.op == Odiv)) ||
			    (i.cls == Ks && (i.op == Oadd || i.op == Osub || i.op == Omul))) {
				if (i.op != Odiv) {
					if (x86 && (!order[i.to.val] ||
						    (i.op == Osub && order[i.to.val] == 2)))
						return 0;
					if (x86 && order[i.to.val] == 2) {
						Ref tmp = i.arg[0];
						i.arg[0] = i.arg[1];
						i.arg[1] = tmp;
					}
					i.op = i.op == Oadd   ? Oordadd
					       : i.op == Osub ? Oordsub
							      : Oordmul;
				}
				for (uint k = 0; k < 2; k++)
					if (rtype(i.arg[k]) == RMem) {
						Ref t = newtmp("load", i.cls, f);
						slpput(&s,
						       (Ins){Oload, i.cls, t, {i.arg[k], R}});
						i.arg[k] = t;
					} else if (rtype(i.arg[k]) != RTmp)
						return 0;
			}
			slpput(&s, i);
			extra += i.op == Ostored;
		}
		b->ins = s.ins;
		b->nins = s.count;
	}
	int next = f->ntmp;
	Lane *v = alloc((next + extra + 1) * sizeof *v);
	int **ids = alloc(f->nblk * sizeof *ids);
	for (b = f->start; b; b = b->link) {
		++region;
		for (Phi *p = b->phi; p; p = p->link) {
			v[p->to.val].p = p;
			v[p->to.val].region = region;
		}
		++region;
		ids[b->id] = alloc((b->nins + 1) * sizeof(int));
		for (uint j = 0; j < b->nins; j++) {
			Ins *i = b->ins + j;
			if (!slpfp(*i)) {
				region++;
				continue;
			}
			int l = i->op == Ostored       ? next++
				: rtype(i->to) == RTmp ? (int)i->to.val
						       : 0;
			if (l >= Tmp0) {
				if (v[l].p || v[l].i)
					return 0;
				v[l].i = i;
				v[l].region = region;
				ids[b->id][j] = l;
			}
		}
	}
	for (b = f->start; b; b = b->link) {
		int last = 0;
		for (uint j = 0; j < b->nins; j++)
			if (b->ins[j].op == Ostored) {
				int l = ids[b->id][j];
				if (!l)
					return 0;
				if (last)
					slppair(f, v, last, l);
				last = l;
			}
	}
	/* Complete a pair feeding an ordered horizontal sum. Both products
	 * must consume corresponding lanes of an existing packet. */
	for (b = f->start; b; b = b->link)
		for (uint j = 0; j < b->nins; j++) {
			Ins *a = &b->ins[j];
			if (a->op != Oordadd || a->cls != Kd || rtype(a->arg[0]) != RTmp ||
			    rtype(a->arg[1]) != RTmp)
				continue;
			int x = a->arg[0].val, y = a->arg[1].val;
			Ins *l = v[x].i, *r = v[y].i;
			if (l && r && l->op == Oordmul && r->op == Oordmul &&
			    rtype(l->arg[0]) == RTmp && rtype(r->arg[0]) == RTmp &&
			    rtype(l->arg[1]) == RTmp && rtype(r->arg[1]) == RTmp &&
			    v[l->arg[0].val].other == (int)r->arg[0].val &&
			    v[l->arg[1].val].other == (int)r->arg[1].val)
				slppair(f, v, x, y);
		}
	for (int l = Tmp0; l < next; l++)
		if (v[l].other && v[l].i && (v[l].i->op == Oordmul ||
		    v[l].i->op == Oordsub || v[l].i->op == Oordadd))
			count++;
	if (!count)
		return 0;
	/* Phi sources must already be available as a packet on every edge.
	 * A failure discards this private candidate graph. */
	for (b = f->start; b; b = b->link) {
		SlpSeq s = {vnew(0, sizeof(Ins), PFn), 0};
		Phi **tail = &b->phi;
		while (*tail) {
			Phi *p = *tail;
			int l = p->to.val;
			if (!v[l].leader) {
				tail = &p->link;
				continue;
			}
			if (v[l].leader != l) {
				*tail = p->link;
				continue;
			}
			Phi *q = v[v[l].other].p;
			for (uint k = 0; k < p->narg; k++) {
				Ref a = p->arg[k], z = q->arg[k];
				if (v[a.val].other != (int)z.val)
					return 0;
				p->arg[k] = v[a.val].packet;
			}
			p->cls = Kv2d;
			p->to = v[l].packet;
			tail = &p->link;
			slpextract(&s, v, l);
		}
		for (uint j = 0; j < b->nins;) {
			if (!slpfp(b->ins[j])) {
				slpput(&s, b->ins[j++]);
				continue;
			}
			uint end = j + 1;
			while (end < b->nins && slpfp(b->ins[end]))
				end++;
			if (!slpschedule(f, v, &s, b->ins + j, ids[b->id] + j, end - j))
				return 0;
			j = end;
		}
		b->ins = s.ins;
		b->nins = s.count;
	}
	/* Remove dead scalar lane projections before liveness. */
	uchar *used = alloc(f->ntmp);
	for (b = f->start; b; b = b->link) {
		for (Phi *p = b->phi; p; p = p->link)
			for (uint k = 0; k < p->narg; k++)
				if (rtype(p->arg[k]) == RTmp)
					used[p->arg[k].val] = 1;
		for (uint j = 0; j < b->nins; j++)
			for (uint k = 0; k < 2; k++)
				if (rtype(b->ins[j].arg[k]) == RTmp)
					used[b->ins[j].arg[k].val] = 1;
		if (rtype(b->jmp.arg) == RTmp)
			used[b->jmp.arg.val] = 1;
	}
	for (b = f->start; b; b = b->link)
		for (uint j = 0; j < b->nins; j++) {
			Ins *i = b->ins + j;
			if ((i->op == Ovlo || i->op == Ovhigh) && !used[i->to.val])
				*i = (Ins){.op = Onop};
		}
	return 1;
}

/* A call may change exception enables. Keep the scalar allocation if
 * any floating arithmetic can execute later, including through a back edge. */
static int
slpchangesenv(Fn *f)
{
	uchar *incoming = alloc(f->nblk);
	int changed, any = 0;
	for (Blk *b = f->start; b; b = b->link)
		for (uint j = 0; j < b->nins; j++)
			any |= b->ins[j].op == Ocall;
	if (!any)
		return 0;
	do {
		changed = 0;
		for (Blk *b = f->start; b; b = b->link) {
			int seen = incoming[b->id];
			for (uint j = 0; j < b->nins; j++) {
				Ins i = b->ins[j];
				if (seen &&
				    (i.op == Ovadd || i.op == Ovsub || i.op == Ovmul ||
				     i.op == Ovmullane || i.op == Ovsum ||
				     i.op == Oordadd || i.op == Oordsub ||
				     i.op == Oordmul ||
				     (i.cls == Kd && (i.op == Odiv || i.op == Osqrt))))
					return 1;
				seen |= i.op == Ocall;
			}
			if (seen) {
				if (b->s1 && !incoming[b->s1->id]) {
					incoming[b->s1->id] = 1;
					changed = 1;
				}
				if (b->s2 && !incoming[b->s2->id]) {
					incoming[b->s2->id] = 1;
					changed = 1;
				}
			}
		}
	} while (changed);
	return 0;
}

/* Join two fully allocated graphs behind a test of the current FP trap
 * enables. Registers and slots refer to the shared prologue. Address-mode
 * references are function-local and must be rebased for the scalar arm. */
static Fn *
slpversion(Fn *scalar, Fn *packet)
{
	Blk *b, *entry = newblk();
	int first = packet->nmem;
	vgrow(&packet->mem, first + scalar->nmem);
	if (scalar->nmem)
		memcpy(packet->mem + first, scalar->mem, scalar->nmem * sizeof(Mem));
	packet->nmem += scalar->nmem;
	for (b = scalar->start; b; b = b->link) {
		for (uint j = 0; j < b->nins; j++) {
			Ins *i = b->ins + j;
			for (uint k = 0; k < 2; k++)
				if (rtype(i->arg[k]) == RMem)
					i->arg[k].val += first;
		}
		if (rtype(b->jmp.arg) == RMem)
			b->jmp.arg.val += first;
	}
	packet->reg |= scalar->reg;
	if (scalar->salign > packet->salign)
		packet->salign = scalar->salign;
	int slots = scalar->slot > packet->slot ? scalar->slot : packet->slot;
	packet->slot = !T.apple ? (slots + 1 + 3) & -4 : (slots + 3) & -4;
	Ins test = {Otrapmask, Kw, R, {T.apple ? R : SLOT(slots), R}};
	idup(entry, &test, 1);
	entry->name = "fp.mode";
	entry->jmp.type = Jjfieq;
	entry->s1 = packet->start;
	entry->s2 = scalar->start;
	entry->link = packet->start;
	for (b = packet->start; b->link; b = b->link) {
	}
	b->link = scalar->start;
	packet->start = entry;
	return packet;
}
