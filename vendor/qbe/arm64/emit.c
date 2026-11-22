#include "all.h"

typedef struct E E;

struct E {
	FILE *f;
	Fn *fn;
	uint64_t frame;
	uint padding;
};

#define CMP(X) \
	X(Cieq,       "eq", "ne") \
	X(Cine,       "ne", "eq") \
	X(Cisge,      "ge", "lt") \
	X(Cisgt,      "gt", "le") \
	X(Cisle,      "le", "gt") \
	X(Cislt,      "lt", "ge") \
	X(Ciuge,      "cs", "cc") \
	X(Ciugt,      "hi", "ls") \
	X(Ciule,      "ls", "hi") \
	X(Ciult,      "cc", "cs") \
	X(NCmpI+Cfeq, "eq", "ne") \
	X(NCmpI+Cfge, "ge", "lt") \
	X(NCmpI+Cfgt, "gt", "le") \
	X(NCmpI+Cfle, "ls", "hi") \
	X(NCmpI+Cflt, "mi", "pl") \
	X(NCmpI+Cfne, "ne", "eq") \
	X(NCmpI+Cfo,  "vc", "vs") \
	X(NCmpI+Cfuo, "vs", "vc")

enum {
	Ki = -1, /* matches Kw and Kl */
	Ka = -2, /* matches all classes */
};

static struct {
	short op;
	short cls;
	char *fmt;
} omap[] = {
	{ Oadd,    Ki, "add %=, %0, %1" },
	{ Oadd,    Ka, "fadd %=, %0, %1" },
	{ Osub,    Ki, "sub %=, %0, %1" },
	{ Osub,    Ka, "fsub %=, %0, %1" },
	{ Oneg,    Ki, "neg %=, %0" },
	{ Oneg,    Ka, "fneg %=, %0" },
	{ Osqrt,   Ka, "fsqrt %=, %0" },
	{ Oand,    Ki, "and %=, %0, %1" },
	{ Oor,     Ki, "orr %=, %0, %1" },
	{ Oxor,    Ki, "eor %=, %0, %1" },
	{ Osar,    Ki, "asr %=, %0, %1" },
	{ Oshr,    Ki, "lsr %=, %0, %1" },
	{ Oshl,    Ki, "lsl %=, %0, %1" },
	{ Omul,    Ki, "mul %=, %0, %1" },
	{ Omul,    Ka, "fmul %=, %0, %1" },
	{ Osmulh,  Kl, "smulh %=, %0, %1" },
	{ Odiv,    Ki, "sdiv %=, %0, %1" },
	{ Odiv,    Ka, "fdiv %=, %0, %1" },
	{ Oudiv,   Ki, "udiv %=, %0, %1" },
	{ Orem,    Ki, "sdiv %?, %0, %1\n\tmsub\t%=, %?, %1, %0" },
	{ Ourem,   Ki, "udiv %?, %0, %1\n\tmsub\t%=, %?, %1, %0" },
	{ Ocopy,   Ki, "mov %=, %0" },
	{ Ocopy,   Ka, "fmov %=, %0" },
	{ Oswap,   Ki, "mov %?, %0\n\tmov\t%0, %1\n\tmov\t%1, %?" },
	{ Oswap,   Ka, "fmov %?, %0\n\tfmov\t%0, %1\n\tfmov\t%1, %?" },
	{ Ostoreb, Kw, "strb %W0, %M1" },
	{ Ostoreh, Kw, "strh %W0, %M1" },
	{ Ostorew, Kw, "str %W0, %M1" },
	{ Ostorel, Kw, "str %L0, %M1" },
	{ Ostores, Kw, "str %S0, %M1" },
	{ Ostored, Kw, "str %D0, %M1" },
	{ Oloadsb, Ki, "ldrsb %=, %M0" },
	{ Oloadub, Ki, "ldrb %W=, %M0" },
	{ Oloadsh, Ki, "ldrsh %=, %M0" },
	{ Oloaduh, Ki, "ldrh %W=, %M0" },
	{ Oloadsw, Kw, "ldr %=, %M0" },
	{ Oloadsw, Kl, "ldrsw %=, %M0" },
	{ Oloaduw, Ki, "ldr %W=, %M0" },
	{ Oload,   Ka, "ldr %=, %M0" },
	{ Oextsb,  Ki, "sxtb %=, %W0" },
	{ Oextub,  Ki, "uxtb %W=, %W0" },
	{ Oextsh,  Ki, "sxth %=, %W0" },
	{ Oextuh,  Ki, "uxth %W=, %W0" },
	{ Oextsw,  Ki, "sxtw %L=, %W0" },
	{ Oextuw,  Ki, "mov %W=, %W0" },
	{ Oexts,   Kd, "fcvt %=, %S0" },
	{ Otruncd, Ks, "fcvt %=, %D0" },
	{ Ocast,   Kw, "fmov %=, %S0" },
	{ Ocast,   Kl, "fmov %=, %D0" },
	{ Ocast,   Ks, "fmov %=, %W0" },
	{ Ocast,   Kd, "fmov %=, %L0" },
	{ Ostosi,  Ka, "fcvtzs %=, %S0" },
	{ Ostoui,  Ka, "fcvtzu %=, %S0" },
	{ Odtosi,  Ka, "fcvtzs %=, %D0" },
	{ Odtoui,  Ka, "fcvtzu %=, %D0" },
	{ Oswtof,  Ka, "scvtf %=, %W0" },
	{ Ouwtof,  Ka, "ucvtf %=, %W0" },
	{ Osltof,  Ka, "scvtf %=, %L0" },
	{ Oultof,  Ka, "ucvtf %=, %L0" },
	{ Ocall,   Kw, "blr %L0" },

	{ Oacmp,   Ki, "cmp %0, %1" },
	{ Oacmn,   Ki, "cmn %0, %1" },
	{ Oatst,   Ki, "tst %0, %1" },
	{ Oafcmp,  Ka, "fcmpe %0, %1" },

#define X(c, str, _) \
	{ Oflag+c, Ki, "cset %=, " str },
	CMP(X)
#undef X
#define X(c, str, _) \
	{ Oxsel+c, Ki, "csel %=, %0, %1, " str },
	CMP(X)
#undef X
	{ NOp, 0, 0 }
};

enum {
	V31 = 0x1fffffff,  /* local name for V31 */
};

static char *
rname(int r, int k)
{
	static char buf[4];

	if (r == SP) {
		assert(k == Kl);
		sprintf(buf, "sp");
	}
	else if (R0 <= r && r <= LR)
		switch (k) {
		default: die("invalid class");
		case Kw: sprintf(buf, "w%d", r-R0); break;
		case Kx:
		case Kl: sprintf(buf, "x%d", r-R0); break;
		}
	else if (V0 <= r && r <= V30)
		switch (k) {
		default: die("invalid class");
		case Ks: sprintf(buf, "s%d", r-V0); break;
		case Kx:
		case Kd: sprintf(buf, "d%d", r-V0); break;
		}
	else if (r == V31)
		switch (k) {
		default: die("invalid class");
		case Ks: sprintf(buf, "s31"); break;
		case Kd: sprintf(buf, "d31"); break;
		}
	else
		die("invalid register");
	return buf;
}

static uint64_t
slot(Ref r, E *e)
{
	int s;

	s = rsval(r);
	if (s == -1)
		return 16 + e->frame;
	if (s < 0) {
		if (e->fn->vararg && !T.apple)
			return 16 + e->frame + 192 - (s+2);
		else
			return 16 + e->frame - (s+2);
	} else
		return 16 + e->padding + 4 * s;
}

static void
emitf(char *s, Ins *i, E *e)
{
	Ref r;
	int k, c;
	Con *pc;
	uint64_t n;
	uint sp;

	fputc('\t', e->f);

	sp = 0;
	for (;;) {
		k = i->cls;
		while ((c = *s++) != '%')
			if (c == ' ' && !sp) {
				fputc('\t', e->f);
				sp = 1;
			} else if (!c) {
				fputc('\n', e->f);
				return;
			} else
				fputc(c, e->f);
	Switch:
		switch ((c = *s++)) {
		default:
			die("invalid escape");
		case 'W':
			k = Kw;
			goto Switch;
		case 'L':
			k = Kl;
			goto Switch;
		case 'S':
			k = Ks;
			goto Switch;
		case 'D':
			k = Kd;
			goto Switch;
		case '?':
			if (KBASE(k) == 0)
				fputs(rname(IP1, k), e->f);
			else
				fputs(rname(V31, k), e->f);
			break;
		case '=':
		case '0':
			r = c == '=' ? i->to : i->arg[0];
			assert(isreg(r) || req(r, TMP(V31)));
			fputs(rname(r.val, k), e->f);
			break;
		case '1':
			r = i->arg[1];
			switch (rtype(r)) {
			default:
				die("invalid second argument");
			case RTmp:
				assert(isreg(r));
				fputs(rname(r.val, k), e->f);
				break;
			case RCon:
				pc = &e->fn->con[r.val];
				n = pc->bits.i;
				assert(pc->type == CBits);
				if (i->op == Oafcmp) {
					assert(k == Kd ? n == 0 : (uint32_t)n == 0);
					fputs("#0.0", e->f);
				} else if (i->op == Oand || i->op == Oor || i->op == Oxor || i->op == Oatst) {
					if (k == Kw)
						n = (uint32_t)n;
					assert(arm64_logimm(n, k));
					fprintf(e->f, "#0x%"PRIx64, n);
				} else if (n & 0xfff000) {
					assert(!(n & ~0xfff000ull));
					fprintf(e->f, "#%"PRIu64", lsl #12",
						n>>12);
				} else {
					assert(!(n & ~0xfffull));
					fprintf(e->f, "#%"PRIu64, n);
				}
				break;
			}
			break;
		case 'M':
			c = *s++;
			assert(c == '0' || c == '1' || c == '=');
			r = c == '=' ? i->to : i->arg[c - '0'];
			switch (rtype(r)) {
			default:
				die("todo (arm emit): unhandled ref");
			case RTmp:
				assert(isreg(r));
				fprintf(e->f, "[%s]", rname(r.val, Kl));
				break;
			case RSlot:
				fprintf(e->f, "[x29, %"PRIu64"]", slot(r, e));
				break;
			case RMem: {
				Mem *m = &e->fn->mem[r.val];
				assert(isreg(m->base));
				if (req(m->index, R)) {
					if (m->offset.bits.i == 0)
						fprintf(e->f, "[%s]",
							rname(m->base.val, Kl));
					else
						fprintf(e->f, "[%s, #%"PRIi64"]",
							rname(m->base.val, Kl),
							m->offset.bits.i);
				} else {
					int sxtw = m->scale < 0;
					int sc = sxtw ? -m->scale : m->scale;
					int sh = 0;
					assert(isreg(m->index));
					if (sc == 2)
						sh = 1;
					else if (sc == 4)
						sh = 2;
					else if (sc == 8)
						sh = 3;
					else
						assert(sc <= 1);
					fprintf(e->f, "[%s, ",
						rname(m->base.val, Kl));
					if (sxtw) {
						if (sh)
							fprintf(e->f, "%s, sxtw #%d]",
								rname(m->index.val, Kw),
								sh);
						else
							fprintf(e->f, "%s, sxtw]",
								rname(m->index.val, Kw));
					} else if (sh)
						fprintf(e->f, "%s, lsl #%d]",
							rname(m->index.val, Kl),
							sh);
					else
						fprintf(e->f, "%s]",
							rname(m->index.val, Kl));
				}
				break;
			}
			}
			break;
		}
	}
}

static void
loadaddr(Con *c, char *rn, E *e)
{
	char *p, *l, *s;

	switch (c->sym.type) {
	default:
		die("unreachable");
	case SGlo:
		if (T.apple)
			s = "\tadrp\tR, S@pageO\n"
			    "\tadd\tR, R, S@pageoffO\n";
		else
			s = "\tadrp\tR, SO\n"
			    "\tadd\tR, R, #:lo12:SO\n";
		break;
	case SExtThr:
		if (!T.apple)
			die("extern thread unavailable on arm64");
		/* fall through */
	case SThr:
		if (T.apple)
			s = "\tadrp\tR, S@tlvppage\n"
			    "\tldr\tR, [R, S@tlvppageoff]\n";
		else
			s = "\tmrs\tR, tpidr_el0\n"
			    "\tadd\tR, R, #:tprel_hi12:SO, lsl #12\n"
			    "\tadd\tR, R, #:tprel_lo12_nc:SO\n";
		break;
	case SExt:
		if (T.apple)
			s = "\tadrp\tR, S@gotpageO\n"
			    "\tldr\tR, [R, S@gotpageoffO]\n";
		else
			s = "\tadrp\tR, :got:SO\n"
			    "\tldr\tR, [R, #:got_lo12:SO]\n";
		break;
	}

	l = str(c->sym.id);
	p = l[0] == '"' ? "" : T.assym;
	for (; *s; s++)
		switch (*s) {
		default:
			fputc(*s, e->f);
			break;
		case 'R':
			fputs(rn, e->f);
			break;
		case 'S':
			fputs(p, e->f);
			fputs(l, e->f);
			break;
		case 'O':
			if (c->bits.i)
				/* todo, handle large offsets */
				fprintf(e->f, "+%"PRIi64, c->bits.i);
			break;
		}
}

static void
loadcon(Con *c, int r, int k, E *e)
{
	char *rn, buf[64];
	int64_t n;
	int w, sh;

	w = KWIDE(k);
	rn = rname(r, k);
	n = c->bits.i;
	if (c->type == CAddr) {
		rn = rname(r, Kl);
		loadaddr(c, rn, e);
		return;
	}
	assert(c->type == CBits);
	if (KBASE(k) == 1) {
		assert(arm64_fpimm(c, k));
		if (k == Kd) {
			if (n == 0) {
				fprintf(e->f, "\tfmov\t%s, xzr\n", rn);
				return;
			}
			snprintf(buf, sizeof buf, "%.17g", c->bits.d);
		} else {
			if ((uint32_t)n == 0) {
				fprintf(e->f, "\tfmov\t%s, wzr\n", rn);
				return;
			}
			snprintf(buf, sizeof buf, "%.17g", (double)c->bits.s);
		}
		if (!strchr(buf, '.'))
			strcat(buf, ".0");
		fprintf(e->f, "\tfmov\t%s, #%s\n", rn, buf);
		return;
	}
	if (!w)
		n = (int32_t)n;
	if ((n | 0xffff) == -1 || arm64_logimm(n, k)) {
		fprintf(e->f, "\tmov\t%s, #%"PRIi64"\n", rn, n);
	} else {
		fprintf(e->f, "\tmov\t%s, #%d\n",
			rn, (int)(n & 0xffff));
		for (sh=16; n>>=16; sh+=16) {
			if ((!w && sh == 32) || sh == 64)
				break;
			fprintf(e->f, "\tmovk\t%s, #0x%x, lsl #%d\n",
				rn, (uint)(n & 0xffff), sh);
		}
	}
}

static void emitins(Ins *, E *);

static int
fixarg(Ref *pr, int sz, int t, E *e)
{
	Ins *i;
	Ref r;
	uint64_t s;

	r = *pr;
	if (rtype(r) == RSlot) {
		s = slot(r, e);
		if (s > sz * 4095u) {
			if (t < 0)
				return 1;
			i = &(Ins){Oaddr, Kl, TMP(t), {r}};
			emitins(i, e);
			*pr = TMP(t);
		}
	}
	return 0;
}

static void
emitins(Ins *i, E *e)
{
	char *l, *p, *rn;
	uint64_t s;
	int o, t;
	Ref r;
	Con *c;

	switch (i->op) {
	default:
		if (isload(i->op))
			fixarg(&i->arg[0], loadsz(i), IP1, e);
		if (isstore(i->op)) {
			t = T.apple ? -1 : R18;
			if (fixarg(&i->arg[1], storesz(i), t, e)) {
				if (req(i->arg[0], TMP(IP1))) {
					fprintf(e->f,
						"\tfmov\t%c31, %c17\n",
						"ds"[i->cls == Kw],
						"xw"[i->cls == Kw]);
					i->arg[0] = TMP(V31);
					i->op = Ostores + (i->cls-Kw);
				}
				fixarg(&i->arg[1], storesz(i), IP1, e);
			}
		}
	Table:
		/* most instructions are just pulled out of
		 * the table omap[], some special cases are
		 * detailed below */
		for (o=0;; o++) {
			/* this linear search should really be a binary
			 * search */
			if (omap[o].op == NOp)
				die("no match for %s(%c)",
					optab[i->op].name, "wlsd"[i->cls]);
			if (omap[o].op == i->op)
			if (omap[o].cls == i->cls || omap[o].cls == Ka
			|| (omap[o].cls == Ki && KBASE(i->cls) == 0))
				break;
		}
		emitf(omap[o].fmt, i, e);
		break;
	case Onop:
		break;
	case Ocopy:
		if (req(i->to, i->arg[0]))
			break;
		if (rtype(i->to) == RSlot) {
			r = i->to;
			if (!isreg(i->arg[0])) {
				i->to = TMP(KBASE(i->cls) == 0 ? IP1 : V31);
				emitins(i, e);
				i->arg[0] = i->to;
			}
			i->op = Ostorew + i->cls;
			i->cls = Kw;
			i->arg[1] = r;
			emitins(i, e);
			break;
		}
		assert(isreg(i->to) || req(i->to, TMP(V31)));
		switch (rtype(i->arg[0])) {
		case RCon:
			c = &e->fn->con[i->arg[0].val];
			loadcon(c, i->to.val, i->cls, e);
			break;
		case RSlot:
			i->op = Oload;
			emitins(i, e);
			break;
		default:
			assert(i->to.val != IP1);
			goto Table;
		}
		break;
	case Oaddr:
		assert(rtype(i->arg[0]) == RSlot);
		rn = rname(i->to.val, Kl);
		s = slot(i->arg[0], e);
		if (s <= 4095)
			fprintf(e->f, "\tadd\t%s, x29, #%"PRIu64"\n", rn, s);
		else if (s <= 65535)
			fprintf(e->f,
				"\tmov\t%s, #%"PRIu64"\n"
				"\tadd\t%s, x29, %s\n",
				rn, s, rn, rn
			);
		else
			fprintf(e->f,
				"\tmov\t%s, #%"PRIu64"\n"
				"\tmovk\t%s, #%"PRIu64", lsl #16\n"
				"\tadd\t%s, x29, %s\n",
				rn, s & 0xFFFF, rn, s >> 16, rn, rn
			);
		break;
	case Ocall:
		if (rtype(i->arg[0]) != RCon)
			goto Table;
		c = &e->fn->con[i->arg[0].val];
		if (c->type != CAddr
		|| (c->sym.type & SThr)
		|| c->bits.i)
			die("invalid call argument");
		l = str(c->sym.id);
		p = l[0] == '"' ? "" : T.assym;
		fprintf(e->f, "\tbl\t%s%s\n", p, l);
		break;
	case Osalloc:
		emitf("sub sp, sp, %0", i, e);
		if (!req(i->to, R))
			emitf("mov %=, sp", i, e);
		break;
	case Odbgloc:
		emitdbgloc(i->arg[0].val, i->arg[1].val, e->f);
		break;
	}
}

static void
framelayout(E *e)
{
	int *r;
	uint o;
	uint64_t f;

	for (o=0, r=arm64_rclob; *r>=0; r++)
		o += 1 & (e->fn->reg >> *r);
	f = e->fn->slot;
	f = (f + 3) & -4;
	o += o & 1;
	e->padding = 4*(f-e->fn->slot);
	e->frame = 4*f + 8*o;
}

/*

  Stack-frame layout:

  +=============+
  | varargs     |
  |  save area  |
  +-------------+
  | callee-save |  ^
  |  registers  |  |
  +-------------+  |
  |    ...      |  |
  | spill slots |  |
  |    ...      |  | e->frame
  +-------------+  |
  |    ...      |  |
  |   locals    |  |
  |    ...      |  |
  +-------------+  |
  | e->padding  |  v
  +-------------+
  |  saved x29  |
  |  saved x30  |
  +=============+ <- x29

*/

static Ins *
can_fuse_cbz(Blk *b, Fn *fn)
{
	Ins *p;
	Con *c;

	if (b->jmp.type != Jjfieq && b->jmp.type != Jjfine)
		return 0;
	for (p = &b->ins[b->nins]; p > b->ins;) {
		--p;
		if (p->op == Onop || p->op == Odbgloc)
			continue;
		if (p->op == Oacmp && KBASE(p->cls) == 0
		&& isreg(p->arg[0]) && p->arg[0].val != SP
		&& rtype(p->arg[1]) == RCon) {
			c = &fn->con[p->arg[1].val];
			if (c->type == CBits && c->bits.i == 0)
				return p;
		}
		return 0;
	}
	return 0;
}

static int
w32_def_reg(const Ins *i, int cur_reg)
{
	if (i->op == Onop || i->op == Odbgloc)
		return cur_reg;
	if (i->op == Ocopy && req(i->to, i->arg[0]))
		return cur_reg;
	if (!isreg(i->to) || i->to.val == SP || i->to.val < R0 || i->to.val > LR)
		return -1;
	switch (i->op) {
	case Oloadub:
	case Oloaduh:
	case Oloaduw:
	case Oextub:
	case Oextuh:
	case Oextuw:
		return i->to.val;
	case Oadd:
	case Osub:
	case Oneg:
	case Oand:
	case Oor:
	case Oxor:
	case Oshl:
	case Oshr:
	case Osar:
	case Omul:
	case Odiv:
	case Oudiv:
	case Orem:
	case Ourem:
	case Oload:
	case Oloadsw:
	case Ocast:
	case Ostosi:
	case Ostoui:
	case Odtosi:
	case Odtoui:
	case Ocopy:
		return i->cls == Kw ? i->to.val : -1;
	default:
		if (i->cls == Kw && (INRANGE(i->op, Oflag, Oflag1) || isxsel(i->op)))
			return i->to.val;
		return -1;
	}
}

static int
arm64_reg_dead_after(Fn *fn, Ins *start, Ins *end, Ref reg)
{
	Ins *ins;
	int j;

	for (ins = start; ins < end; ins++) {
		if (ins->op == Ocall)
			return 0;
		for (j = 0; j < 2; j++) {
			Ref a = ins->arg[j];
			if (req(a, reg))
				return 0;
			if (rtype(a) == RMem) {
				Mem *m = &fn->mem[a.val];
				if (req(m->base, reg) || req(m->index, reg))
					return 0;
			}
		}
		if (req(ins->to, reg) && ins->op != Osel0 && !isxsel(ins->op))
			return 1;
	}
	return 0;
}

void
arm64_emitfn(Fn *fn, FILE *out)
{
	static char *ctoa[][2] = {
	#define X(c, s, n) [c] = {s, n},
		CMP(X)
	#undef X
	};
	static int id0;
	int s, n, c, lbl, *r;
	uint64_t o;
	Blk *b, *t;
	Ins *i;
	E *e;

	e = &(E){.f = out, .fn = fn};
	if (T.apple)
		e->fn->lnk.align = 4;
	emitfnlnk(e->fn->name, &e->fn->lnk, e->f);
	fputs("\thint\t#34\n", e->f);
	framelayout(e);

	if (e->fn->vararg && !T.apple) {
		for (n=7; n>=0; n--)
			fprintf(e->f, "\tstr\tq%d, [sp, -16]!\n", n);
		for (n=7; n>=0; n-=2)
			fprintf(e->f, "\tstp\tx%d, x%d, [sp, -16]!\n", n-1, n);
	}

	if (e->frame + 16 <= 512)
		fprintf(e->f,
			"\tstp\tx29, x30, [sp, -%"PRIu64"]!\n",
			e->frame + 16
		);
	else if (e->frame <= 4095)
		fprintf(e->f,
			"\tsub\tsp, sp, #%"PRIu64"\n"
			"\tstp\tx29, x30, [sp, -16]!\n",
			e->frame
		);
	else if (e->frame <= 65535)
		fprintf(e->f,
			"\tmov\tx16, #%"PRIu64"\n"
			"\tsub\tsp, sp, x16\n"
			"\tstp\tx29, x30, [sp, -16]!\n",
			e->frame
		);
	else
		fprintf(e->f,
			"\tmov\tx16, #%"PRIu64"\n"
			"\tmovk\tx16, #%"PRIu64", lsl #16\n"
			"\tsub\tsp, sp, x16\n"
			"\tstp\tx29, x30, [sp, -16]!\n",
			e->frame & 0xFFFF, e->frame >> 16
		);
	fputs("\tmov\tx29, sp\n", e->f);
	s = (e->frame - e->padding) / 4;
	for (r=arm64_rclob; *r>=0; r++)
		if (e->fn->reg & BIT(*r)) {
			s -= 2;
			i = &(Ins){.arg = {TMP(*r), SLOT(s)}};
			i->op = *r >= V0 ? Ostored : Ostorel;
			emitins(i, e);
		}

	for (lbl=0, b=e->fn->start; b; b=b->link) {
		Ins *cbz_ins = can_fuse_cbz(b, e->fn);
		int last_w32 = -1;
		if (lbl || b->npred > 1)
			fprintf(e->f, "%s%d:\n", T.asloc, id0+b->id);
		for (i=b->ins; i!=&b->ins[b->nins]; i++) {
			if (i == cbz_ins) {
				last_w32 = -1;
				continue;
			}
			if (i->op == Oextuw && req(i->to, i->arg[0])
			&& isreg(i->to) && i->to.val == last_w32)
				continue;
			if (i + 1 < &b->ins[b->nins] && i + 1 != cbz_ins
			&& i->op == Omul && KBASE(i->cls) == 0
			&& isreg(i->to) && isreg(i->arg[0]) && isreg(i->arg[1])) {
				Ins *i1 = i + 1;
				if (i1->cls == i->cls && isreg(i1->to)
				&& (req(i1->to, i->to) || arm64_reg_dead_after(fn, i1 + 1, &b->ins[b->nins], i->to))) {
					if (i1->op == Osub && isreg(i1->arg[0])
					&& req(i1->arg[1], i->to) && !req(i1->arg[0], i->to)) {
						char rd[4], rn[4], rm[4], ra[4];
						strcpy(rd, rname(i1->to.val, i1->cls));
						strcpy(rn, rname(i->arg[0].val, i->cls));
						strcpy(rm, rname(i->arg[1].val, i->cls));
						strcpy(ra, rname(i1->arg[0].val, i->cls));
						fprintf(e->f, "\tmsub\t%s, %s, %s, %s\n", rd, rn, rm, ra);
						if (last_w32 == i->to.val)
							last_w32 = -1;
						last_w32 = w32_def_reg(i1, last_w32);
						i++;
						continue;
					}
					if (i1->op == Oadd
					&& ((isreg(i1->arg[0]) && req(i1->arg[1], i->to) && !req(i1->arg[0], i->to))
					 || (isreg(i1->arg[1]) && req(i1->arg[0], i->to) && !req(i1->arg[1], i->to)))) {
						Ref ra_ref = req(i1->arg[1], i->to) ? i1->arg[0] : i1->arg[1];
						char rd[4], rn[4], rm[4], ra[4];
						strcpy(rd, rname(i1->to.val, i1->cls));
						strcpy(rn, rname(i->arg[0].val, i->cls));
						strcpy(rm, rname(i->arg[1].val, i->cls));
						strcpy(ra, rname(ra_ref.val, i->cls));
						fprintf(e->f, "\tmadd\t%s, %s, %s, %s\n", rd, rn, rm, ra);
						if (last_w32 == i->to.val)
							last_w32 = -1;
						last_w32 = w32_def_reg(i1, last_w32);
						i++;
						continue;
					}
				}
			}
			if (i + 1 < &b->ins[b->nins] && i + 1 != cbz_ins
			&& i->op == Oshl && KBASE(i->cls) == 0
			&& isreg(i->to) && isreg(i->arg[0]) && i->arg[0].val != SP
			&& rtype(i->arg[1]) == RCon) {
				Con *sc = &fn->con[i->arg[1].val];
				if (sc->type == CBits) {
					uint maxsh = (i->cls == Kl) ? 63u : 31u;
					uint sh = (uint)sc->bits.i & maxsh;
					Ins *i1 = i + 1;
					if (sh >= 1 && i1->cls == i->cls && isreg(i1->to) && i1->to.val != SP
					&& (req(i1->to, i->to) || arm64_reg_dead_after(fn, i1 + 1, &b->ins[b->nins], i->to))) {
						if (i1->op == Oadd
						&& ((isreg(i1->arg[0]) && i1->arg[0].val != SP && req(i1->arg[1], i->to) && !req(i1->arg[0], i->to))
						 || (isreg(i1->arg[1]) && i1->arg[1].val != SP && req(i1->arg[0], i->to) && !req(i1->arg[1], i->to)))) {
							Ref ra_ref = req(i1->arg[1], i->to) ? i1->arg[0] : i1->arg[1];
							char rd[4], rbase[4], rsh[4];
							strcpy(rd, rname(i1->to.val, i1->cls));
							strcpy(rbase, rname(ra_ref.val, i->cls));
							strcpy(rsh, rname(i->arg[0].val, i->cls));
							fprintf(e->f, "\tadd\t%s, %s, %s, lsl #%u\n", rd, rbase, rsh, sh);
							if (last_w32 == i->to.val)
								last_w32 = -1;
							last_w32 = w32_def_reg(i1, last_w32);
							i++;
							continue;
						}
						if (i1->op == Osub && isreg(i1->arg[0]) && i1->arg[0].val != SP
						&& req(i1->arg[1], i->to) && !req(i1->arg[0], i->to)) {
							char rd[4], rbase[4], rsh[4];
							strcpy(rd, rname(i1->to.val, i1->cls));
							strcpy(rbase, rname(i1->arg[0].val, i->cls));
							strcpy(rsh, rname(i->arg[0].val, i->cls));
							fprintf(e->f, "\tsub\t%s, %s, %s, lsl #%u\n", rd, rbase, rsh, sh);
							if (last_w32 == i->to.val)
								last_w32 = -1;
							last_w32 = w32_def_reg(i1, last_w32);
							i++;
							continue;
						}
					}
				}
			}
			int next_w32 = w32_def_reg(i, last_w32);
			emitins(i, e);
			last_w32 = next_w32;
		}
		lbl = 1;
		switch (b->jmp.type) {
		case Jhlt:
			fprintf(e->f, "\tbrk\t#1000\n");
			break;
		case Jret0:
			s = (e->frame - e->padding) / 4;
			for (r=arm64_rclob; *r>=0; r++)
				if (e->fn->reg & BIT(*r)) {
					s -= 2;
					i = &(Ins){Oload, 0, TMP(*r), {SLOT(s)}};
					i->cls = *r >= V0 ? Kd : Kl;
					emitins(i, e);
				}
			if (e->fn->dynalloc)
				fputs("\tmov sp, x29\n", e->f);
			o = e->frame + 16;
			if (e->fn->vararg && !T.apple)
				o += 192;
			if (o <= 504)
				fprintf(e->f,
					"\tldp\tx29, x30, [sp], %"PRIu64"\n",
					o
				);
			else if (o - 16 <= 4095)
				fprintf(e->f,
					"\tldp\tx29, x30, [sp], 16\n"
					"\tadd\tsp, sp, #%"PRIu64"\n",
					o - 16
				);
			else if (o - 16 <= 65535)
				fprintf(e->f,
					"\tldp\tx29, x30, [sp], 16\n"
					"\tmov\tx16, #%"PRIu64"\n"
					"\tadd\tsp, sp, x16\n",
					o - 16
				);
			else
				fprintf(e->f,
					"\tldp\tx29, x30, [sp], 16\n"
					"\tmov\tx16, #%"PRIu64"\n"
					"\tmovk\tx16, #%"PRIu64", lsl #16\n"
					"\tadd\tsp, sp, x16\n",
					(o - 16) & 0xFFFF, (o - 16) >> 16
				);
			fprintf(e->f, "\tret\n");
			break;
		case Jjmp:
		Jmp:
			if (b->s1 != b->link)
				fprintf(e->f,
					"\tb\t%s%d\n",
					T.asloc, id0+b->s1->id
				);
			else
				lbl = 0;
			break;
		case Jjtbl: {
			static int jt0;
			int jtid = jt0++;
			int idx_r;
			uint32_t jk;
			if (rtype(b->jmp.arg) == RSlot) {
				Ins li = {Oload, Kw, TMP(IP0), {b->jmp.arg, R}};
				emitins(&li, e);
				idx_r = IP0;
			} else {
				assert(isreg(b->jmp.arg));
				idx_r = b->jmp.arg.val;
			}
			if (b->njtbl <= 4095) {
				fprintf(e->f, "\tcmp\t%s, #%"PRIu32"\n",
					rname(idx_r, Kw), b->njtbl);
			} else if (b->njtbl <= 65535) {
				fprintf(e->f,
					"\tmov\tw17, #%"PRIu32"\n"
					"\tcmp\t%s, w17\n",
					b->njtbl, rname(idx_r, Kw));
			} else {
				fprintf(e->f,
					"\tmov\tw17, #%"PRIu32"\n"
					"\tmovk\tw17, #%"PRIu32", lsl #16\n"
					"\tcmp\t%s, w17\n",
					b->njtbl & 0xffffu, b->njtbl >> 16,
					rname(idx_r, Kw));
			}
			fprintf(e->f,
				"\tbhs\t%s%d\n"
				"\tadr\tx17, %sjt%d\n"
				"\tldrsw\tx16, [x17, %s, uxtw #2]\n"
				"\tadd\tx17, x17, x16\n"
				"\tbr\tx17\n"
				"%sjt%d:\n",
				T.asloc, id0 + b->s1->id,
				T.asloc, jtid,
				rname(idx_r, Kw),
				T.asloc, jtid);
			for (jk = 0; jk < b->njtbl; jk++)
				fprintf(e->f, "\t.long\t%s%d - %sjt%d\n",
					T.asloc, id0 + b->jtbl[jk]->id,
					T.asloc, jtid);
			break;
		}
		default:
			c = b->jmp.type - Jjf;
			if (c < 0 || c > NCmp)
				die("unhandled jump %d", b->jmp.type);
			if (b->link == b->s2) {
				t = b->s1;
				b->s1 = b->s2;
				b->s2 = t;
				n = 0;
			} else
				n = 1;
			if (cbz_ins) {
				int is_nz = (c == Cine) ^ n;
				fprintf(e->f,
					"\t%s\t%s, %s%d\n",
					is_nz ? "cbnz" : "cbz",
					rname(cbz_ins->arg[0].val, cbz_ins->cls),
					T.asloc, id0+b->s2->id
				);
			} else {
				fprintf(e->f,
					"\tb%s\t%s%d\n",
					ctoa[c][n], T.asloc, id0+b->s2->id
				);
			}
			goto Jmp;
		}
	}
	id0 += e->fn->nblk;
	if (!T.apple)
		elf_emitfnfin(fn->name, out);
}
