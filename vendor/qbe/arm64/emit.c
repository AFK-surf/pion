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
	Kf = -3, /* matches Ks and Kd */
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
	{ Oror,    Ki, "ror %=, %0, %1" },
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
	{ Oxsel+c, Ki, "csel %=, %0, %1, " str }, \
	{ Oxsel+c, Kf, "fcsel %=, %0, %1, " str },
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
			if (c == '0' && rtype(r) == RCon) {
				pc = &e->fn->con[r.val];
				assert(KBASE(k) == 0 && pc->type == CBits && pc->bits.i == 0);
				fputs(k == Kl ? "xzr" : "wzr", e->f);
				break;
			}
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
	if (n >= 0 && n <= 0xffff) {
		fprintf(e->f, "\tmov\t%s, #%"PRIi64"\n", rn, n);
	} else if ((n | 0xffff) == -1) {
		/* Spell movn like macho.c: `mov w, #-65536` may assemble as movz. */
		fprintf(e->f, "\tmovn\t%s, #%u\n", rn, (uint)(~n & 0xffff));
	} else if (arm64_logimm(n, k)) {
		/* A mov alias may assemble as a different move-wide instruction. */
		fprintf(e->f, "\torr\t%s, %s, #0x%"PRIx64"\n", rn,
			w ? "xzr" : "wzr", w ? (uint64_t)n : (uint32_t)n);
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
		if (s > sz * 4095u || s % sz != 0) {
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

	if (i->op==Oload && i->cls==Kv2d)
		i->op=Ovload;
	switch (i->op) {
	case Oswap:
		if (i->cls == Kv2d) {
			uint x = i->arg[0].val - V0, y = i->arg[1].val - V0;
			fprintf(e->f,
				"\tmov\tv31.16b, v%u.16b\n\tmov\tv%u.16b, "
				"v%u.16b\n\tmov\tv%u.16b, v31.16b\n",
				x, x, y, y);
			break;
		}
		goto Table;
	case Ovload:
	case Ovstore: {
		int store = i->op == Ovstore;
		Ref addr = i->arg[store];
		uint r = (store ? i->arg[0] : i->to).val;
		uint reg = r == V31 ? 31 : r - V0;
		fixarg(&addr, 16, IP1, e);
		int64_t off = rtype(addr) == RSlot  ? (int64_t)slot(addr, e)
			      : rtype(addr) == RMem ? e->fn->mem[addr.val].offset.bits.i
						    : 0;
		uint base = rtype(addr) == RSlot  ? FP
			    : rtype(addr) == RMem ? e->fn->mem[addr.val].base.val
						  : addr.val;
		fprintf(e->f, "\t%s\tq%u, [%s, #%" PRId64 "]\n",
			store ? (off % 16 ? "stur" : "str") : (off % 16 ? "ldur" : "ldr"),
			reg, rname(base, Kl), off);
		break;
	}
	case Ovhigh:
		fprintf(e->f, "\tdup\td%u, v%u.d[1]\n", i->to.val - V0, i->arg[0].val - V0);
		break;
	case Otrapmask:
		fputs("\tmrs\tx17, fpcr\n\tmov\tw16, #0x9f00\n\ttst\tw17, w16\n", e->f);
		break;
	case Ovsum:
		fprintf(e->f, "\tfaddp\td%u, v%u.2d\n", i->to.val - V0, i->arg[0].val - V0);
		break;
	case Ovmullane:
		fprintf(e->f, "\tfmul\tv%u.2d, v%u.2d, v%u.d[0]\n", i->to.val - V0,
			i->arg[0].val - V0, i->arg[1].val - V0);
		break;
	case Ovlo:
	case Oordadd:
	case Oordsub:
	case Oordmul: {
		Ins k = *i;
		k.op = i->op == Ovlo	  ? Ocopy
		       : i->op == Oordadd ? Oadd
		       : i->op == Oordsub ? Osub
					  : Omul;
		emitins(&k, e);
		break;
	}
	case Ovzip:
		fprintf(e->f, "\tzip1\tv%u.2d, v%u.2d, v%u.2d\n", i->to.val - V0,
			i->arg[0].val - V0, i->arg[1].val - V0);
		break;
	case Ovsplat:
		fprintf(e->f, "\tdup\tv%u.2d, v%u.d[0]\n", i->to.val - V0,
			i->arg[0].val - V0);
		break;
	case Ovadd:
	case Ovsub:
	case Ovmul:
		fprintf(e->f, "\t%s\tv%u.2d, v%u.2d, v%u.2d\n",
			i->op == Ovadd	 ? "fadd"
			: i->op == Ovsub ? "fsub"
					 : "fmul",
			i->to.val - V0, i->arg[0].val - V0, i->arg[1].val - V0);
		break;
	default:
		if (isload(i->op))
			fixarg(&i->arg[0], loadsz(i), IP1, e);
		if (isstore(i->op)) {
			t = T.apple ? -1 : R18;
			if (fixarg(&i->arg[1], storesz(i), t, e)) {
				if (req(i->arg[0], TMP(IP1))) {
					/* decide width by the store op: Ocopy to
					 * RSlot resets i->cls to Kw before we get
					 * here, so i->cls would truncate storel */
					if (i->op == Ostorel) {
						fprintf(e->f, "\tfmov\td31, x17\n");
						i->op = Ostored;
					} else {
						fprintf(e->f, "\tfmov\ts31, w17\n");
						i->op = Ostores;
					}
					i->arg[0] = TMP(V31);
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
			|| (omap[o].cls == Ki && KBASE(i->cls) == 0)
			|| (omap[o].cls == Kf && KBASE(i->cls) == 1))
				break;
		}
		emitf(omap[o].fmt, i, e);
		break;
	case Onop:
		break;
	case Ocopy:
		if (i->cls == Kv2d) {
			Ins k = *i;
			Ref dst = k.to, src = k.arg[0];
			if (req(dst, src))
				break;
			if (rtype(src) == RSlot) {
				k = (Ins){Ovload,
					  Kv2d,
					  rtype(dst) == RSlot ? TMP(V31) : dst,
					  {src, R}};
				emitins(&k, e);
				src = k.to;
			}
			if (rtype(dst) == RSlot) {
				k = (Ins){Ovstore, Kv2d, R, {src, dst}};
				emitins(&k, e);
			} else if (!req(dst, src)) {
				fprintf(e->f, "\tmov\tv%u.16b, v%u.16b\n", dst.val - V0,
					src.val - V0);
			}
			break;
		}
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

static Ins *
can_fuse_flag_cbz(Blk *b, Ins *cbz_ins, uint64_t live_out)
{
	Ins *p;

	if (!cbz_ins)
		return 0;
	for (p = cbz_ins; p > b->ins;) {
		--p;
		if (p->op == Onop || p->op == Odbgloc)
			continue;
		if (INRANGE(p->op, Oflag, Oflag1)
		&& req(p->to, cbz_ins->arg[0])
		&& (live_out & BIT(p->to.val)) == 0)
			return p;
		return 0;
	}
	return 0;
}

static int
arm64_mem_base_off(Ref r, Fn *fn, int *base_out, int64_t *off_out)
{
	if (rtype(r) == RTmp && isreg(r)) {
		*base_out = r.val;
		*off_out = 0;
		return 1;
	}
	if (rtype(r) == RMem) {
		Mem *m = &fn->mem[r.val];
		if (isreg(m->base) && req(m->index, R) && m->offset.type == CBits && m->offset.bits.i >= 0) {
			*base_out = m->base.val;
			*off_out = m->offset.bits.i;
			return 1;
		}
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
	case Oror:
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

static uint64_t *
arm64_compute_gpr_out(Fn *fn)
{
	uint64_t *in, *out;
	uint64_t call_pres = 0, all_reg = 0;
	int r, changed;
	Blk *b;
	Ins *ins;

	in = alloc(fn->nblk * sizeof *in);
	out = alloc(fn->nblk * sizeof *out);
	for (r = R19; r <= LR; r++)
		call_pres |= BIT(r);
	call_pres |= BIT(SP);
	for (r = V8; r <= V15; r++)
		call_pres |= BIT(r);
	for (r = R0; r <= LR; r++)
		all_reg |= BIT(r);
	all_reg |= BIT(SP);
	for (r = V0; r <= V30; r++)
		all_reg |= BIT(r);

	do {
		changed = 0;
		for (b = fn->start; b; b = b->link) {
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
				uint32_t j;
				if (b->s1)
					live |= in[b->s1->id];
				for (j = 0; j < b->njtbl; j++)
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
			for (ins = &b->ins[b->nins]; ins > b->ins;) {
				int j;
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
				for (j = 0; j < 2; j++) {
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

static int
arm64_reg_dead_after(Fn *fn, Ins *start, Ins *end, Ref reg, uint64_t live_out)
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
	return (live_out & BIT(reg.val)) == 0;
}

static uint64_t
sat_add_u64(uint64_t a, uint64_t b)
{
	return (a > UINT64_MAX - b) ? UINT64_MAX : (a + b);
}

static uint64_t
sat_mul_u64(uint64_t a, uint64_t b)
{
	if (a == 0 || b == 0)
		return 0;
	return (a > UINT64_MAX / b) ? UINT64_MAX : (a * b);
}

static uint64_t
arm64_est_fn_bytes(Fn *fn)
{
	uint64_t est = 512; /* prologue / vararg save / callee-save / epilogue margin */
	Blk *b;
	Ins *i;

	for (b = fn->start; b; b = b->link) {
		est = sat_add_u64(est, 64); /* terminator / epilogue / jtbl overhead */
		est = sat_add_u64(est, sat_mul_u64((uint64_t)b->nins, 40));
		for (i = b->ins; i < &b->ins[b->nins]; i++) {
			if (i->op == Oblit1) {
				int sz = rsval(i->arg[0]);
				if (sz > 0)
					est = sat_add_u64(est, sat_mul_u64((uint64_t)sz, 4));
			}
		}
		if (b->jmp.type == Jjtbl)
			est = sat_add_u64(est, sat_mul_u64((uint64_t)b->njtbl, 4));
	}
	return est;
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
	int s, n, c, lbl, far, *r;
	uint64_t o;
	Blk *b, *s1, *s2, *t;
	Ins *i;
	E *e;

	e = &(E){.f = out, .fn = fn};
	uint64_t *gpr_out = arm64_compute_gpr_out(fn);
	far = (arm64_est_fn_bytes(fn) >= 983040u);
	if (far && T.apple)
		far = arm64_macho_needs_far(fn, gpr_out);
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
	{
		int saved[NCLR], nsaved = 0;
		for (r=arm64_rclob; *r>=0; r++)
			if (e->fn->reg & BIT(*r))
				saved[nsaved++] = *r;
		for (int k = 0; k < nsaved; ) {
			int r0 = saved[k];
			if (k + 1 < nsaved && (r0 >= V0) == (saved[k + 1] >= V0)) {
				int r1 = saved[k + 1];
				int s1 = s - 4;
				uint64_t lo = slot(SLOT(s1), e);
				if ((lo & 7) == 0 && lo <= 504) {
					int cls = r0 >= V0 ? Kd : Kl;
					char rn1[4], rn0[4];
					strcpy(rn1, rname(r1, cls));
					strcpy(rn0, rname(r0, cls));
					fprintf(e->f, "\tstp\t%s, %s, [x29, #%"PRIu64"]\n", rn1, rn0, lo);
					s = s1;
					k += 2;
					continue;
				}
			}
			s -= 2;
			i = &(Ins){.arg = {TMP(r0), SLOT(s)}};
			i->op = r0 >= V0 ? Ostored : Ostorel;
			emitins(i, e);
			k++;
		}
	}

	for (lbl=0, b=e->fn->start; b; b=b->link) {
		uint64_t live_out = gpr_out[b->id];
		Ins *cbz_ins = can_fuse_cbz(b, e->fn);
		Ins *flag_ins = can_fuse_flag_cbz(b, cbz_ins, live_out);
		int last_w32 = -1;
		if (lbl || b->npred > 1)
			fprintf(e->f, "%s%d:\n", T.asloc, id0+b->id);
		for (i=b->ins; i!=&b->ins[b->nins]; i++) {
			if (i == cbz_ins || i == flag_ins) {
				last_w32 = -1;
				continue;
			}
			if (i->op == Oextuw && req(i->to, i->arg[0])
			&& isreg(i->to) && i->to.val == last_w32)
				continue;
			if (i + 1 < &b->ins[b->nins] && i + 1 != cbz_ins && i + 1 != flag_ins
			&& i->op == Omul && KBASE(i->cls) == 0
			&& isreg(i->to) && isreg(i->arg[0]) && isreg(i->arg[1])) {
				Ins *i1 = i + 1;
				if (i1->cls == i->cls && isreg(i1->to)
				&& (req(i1->to, i->to) || arm64_reg_dead_after(fn, i1 + 1, &b->ins[b->nins], i->to, live_out))) {
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
			if (i + 1 < &b->ins[b->nins] && i + 1 != cbz_ins && i + 1 != flag_ins
			&& (i->op == Oshl || i->op == Oshr || i->op == Osar) && KBASE(i->cls) == 0
			&& isreg(i->to) && isreg(i->arg[0]) && i->arg[0].val != SP
			&& rtype(i->arg[1]) == RCon) {
				Con *sc = &fn->con[i->arg[1].val];
				if (sc->type == CBits) {
					uint maxsh = (i->cls == Kl) ? 63u : 31u;
					uint sh = (uint)sc->bits.i & maxsh;
					const char *shname = (i->op == Oshl) ? "lsl"
						: (i->op == Oshr ? "lsr" : "asr");
					Ins *i1 = i + 1;
					if (sh >= 1 && i1->cls == i->cls && isreg(i1->to) && i1->to.val != SP
					&& (req(i1->to, i->to) || arm64_reg_dead_after(fn, i1 + 1, &b->ins[b->nins], i->to, live_out))) {
						if (i1->op == Oadd
						&& ((isreg(i1->arg[0]) && i1->arg[0].val != SP && req(i1->arg[1], i->to) && !req(i1->arg[0], i->to))
						 || (isreg(i1->arg[1]) && i1->arg[1].val != SP && req(i1->arg[0], i->to) && !req(i1->arg[1], i->to)))) {
							Ref ra_ref = req(i1->arg[1], i->to) ? i1->arg[0] : i1->arg[1];
							char rd[4], rbase[4], rsh[4];
							strcpy(rd, rname(i1->to.val, i1->cls));
							strcpy(rbase, rname(ra_ref.val, i->cls));
							strcpy(rsh, rname(i->arg[0].val, i->cls));
							fprintf(e->f, "\tadd\t%s, %s, %s, %s #%u\n", rd, rbase, rsh, shname, sh);
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
							fprintf(e->f, "\tsub\t%s, %s, %s, %s #%u\n", rd, rbase, rsh, shname, sh);
							if (last_w32 == i->to.val)
								last_w32 = -1;
							last_w32 = w32_def_reg(i1, last_w32);
							i++;
							continue;
						}
					}
				}
			}
			ArmSlotPair pair;
			if (i+1 < b->ins+b->nins && i+1 != cbz_ins && i+1 != flag_ins
			&& arm64_slotpair(i, e->padding, fn->firstspill, &pair)) {
				char lo[8], hi[8];
				assert(pair.offset == slot(pair.slot, e));
				strcpy(lo, rname(pair.lo, pair.cls));
				strcpy(hi, rname(pair.hi, pair.cls));
				fprintf(e->f, "\t%s\t%s, %s, [x29, #%u]\n",
					pair.load ? "ldp" : "stp", lo, hi, pair.offset);
				last_w32 = -1;
				i++;
				continue;
			}
			/* Pair adjacent 64-bit or 32-bit loads/stores into ldp/stp */
			if (i + 1 < &b->ins[b->nins] && i + 1 != cbz_ins && i + 1 != flag_ins) {
				Ins *i1 = i + 1;
				int b0, b1;
				int64_t o0, o1;
				if ((i->op == Oload || i->op == Oloaduw) && i1->op == i->op
				&& i->cls == i1->cls
				&& ((i->op == Oload && (i->cls == Kl || i->cls == Kd || i->cls == Kw || i->cls == Ks))
				 || (i->op == Oloaduw && i->cls == Kw))
				&& isreg(i->to) && isreg(i1->to)
				&& i->to.val != SP && i1->to.val != SP
				&& i->to.val != i1->to.val
				&& arm64_mem_base_off(i->arg[0], fn, &b0, &o0)
				&& arm64_mem_base_off(i1->arg[0], fn, &b1, &o1)
				&& b0 == b1 && i->to.val != b0) {
					int64_t step = (i->cls == Kl || i->cls == Kd) ? 8 : 4;
					int64_t mino = (step == 8) ? -512 : -256;
					int64_t maxo = (step == 8) ? 504 : 252;
					if (o1 == o0 + step && (o0 & (step - 1)) == 0
					&& o0 >= mino && o0 <= maxo) {
						char r1[4], r2[4], rb[4];
						strcpy(r1, rname(i->to.val, i->cls));
						strcpy(r2, rname(i1->to.val, i1->cls));
						strcpy(rb, rname(b0, Kl));
						if (o0 == 0)
							fprintf(e->f, "\tldp\t%s, %s, [%s]\n", r1, r2, rb);
						else
							fprintf(e->f, "\tldp\t%s, %s, [%s, #%"PRIi64"]\n", r1, r2, rb, o0);
						if (last_w32 == i->to.val || last_w32 == i1->to.val)
							last_w32 = -1;
						i++;
						continue;
					}
				}
				if ((i->op == Ostorel || i->op == Ostored || i->op == Ostorew || i->op == Ostores)
				&& i1->op == i->op
				&& isreg(i->arg[0]) && isreg(i1->arg[0])
				&& i->arg[0].val != SP && i1->arg[0].val != SP
				&& arm64_mem_base_off(i->arg[1], fn, &b0, &o0)
				&& arm64_mem_base_off(i1->arg[1], fn, &b1, &o1)
				&& b0 == b1) {
					int64_t step = (i->op == Ostorel || i->op == Ostored) ? 8 : 4;
					int64_t mino = (step == 8) ? -512 : -256;
					int64_t maxo = (step == 8) ? 504 : 252;
					if (o1 == o0 + step && (o0 & (step - 1)) == 0
					&& o0 >= mino && o0 <= maxo) {
						int sc = (i->op == Ostored) ? Kd : (i->op == Ostorel ? Kl : (i->op == Ostores ? Ks : Kw));
						char r1[4], r2[4], rb[4];
						strcpy(r1, rname(i->arg[0].val, sc));
						strcpy(r2, rname(i1->arg[0].val, sc));
						strcpy(rb, rname(b0, Kl));
						if (o0 == 0)
							fprintf(e->f, "\tstp\t%s, %s, [%s]\n", r1, r2, rb);
						else
							fprintf(e->f, "\tstp\t%s, %s, [%s, #%"PRIi64"]\n", r1, r2, rb, o0);
						i++;
						continue;
					}
				}
			}
			if (i + 2 < &b->ins[b->nins] && i + 1 != cbz_ins && i + 2 != cbz_ins
			&& i + 1 != flag_ins && i + 2 != flag_ins
			&& i->op == Oadd && KBASE(i->cls) == 0
			&& isreg(i->to) && i->to.val != SP) {
				Ref ra = R;
				int is_inc1 = 0;
				if (isreg(i->arg[0]) && i->arg[0].val != SP && !req(i->arg[0], i->to)
				&& rtype(i->arg[1]) == RCon) {
					Con *ac = &fn->con[i->arg[1].val];
					if (ac->type == CBits && ac->bits.i == 1) {
						ra = i->arg[0];
						is_inc1 = 1;
					}
				} else if (isreg(i->arg[1]) && i->arg[1].val != SP && !req(i->arg[1], i->to)
				&& rtype(i->arg[0]) == RCon) {
					Con *ac = &fn->con[i->arg[0].val];
					if (ac->type == CBits && ac->bits.i == 1) {
						ra = i->arg[1];
						is_inc1 = 1;
					}
				}
				if (is_inc1) {
					Ins *i1 = i + 1;
					Ins *i2 = i + 2;
					if ((i1->op == Oacmp || i1->op == Oacmn || i1->op == Oatst || i1->op == Oafcmp)
					&& !req(i1->arg[0], i->to) && !req(i1->arg[1], i->to)
					&& isxsel(i2->op) && i2->cls == i->cls && req(i2->to, ra)
					&& arm64_reg_dead_after(fn, i2 + 1, &b->ins[b->nins], i->to, live_out)) {
						int inv = -1;
						if (req(i2->arg[0], i->to) && req(i2->arg[1], ra))
							inv = 0;
						else if (req(i2->arg[0], ra) && req(i2->arg[1], i->to))
							inv = 1;
						if (inv >= 0) {
							char rbuf[4];
							int cc_idx = (int)i2->op - Oxsel;
							emitins(i1, e);
							strcpy(rbuf, rname(ra.val, i2->cls));
							fprintf(e->f, "\tcinc\t%s, %s, %s\n", rbuf, rbuf, ctoa[cc_idx][inv]);
							if (last_w32 == i->to.val)
								last_w32 = -1;
							last_w32 = w32_def_reg(i2, last_w32);
							i += 2;
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
			{
				int saved[NCLR], nsaved = 0;
				for (r=arm64_rclob; *r>=0; r++)
					if (e->fn->reg & BIT(*r))
						saved[nsaved++] = *r;
				for (int k = 0; k < nsaved; ) {
					int r0 = saved[k];
					if (k + 1 < nsaved && (r0 >= V0) == (saved[k + 1] >= V0)) {
						int r1 = saved[k + 1];
						int s1 = s - 4;
						uint64_t lo = slot(SLOT(s1), e);
						if ((lo & 7) == 0 && lo <= 504) {
							int cls = r0 >= V0 ? Kd : Kl;
							char rn1[4], rn0[4];
							strcpy(rn1, rname(r1, cls));
							strcpy(rn0, rname(r0, cls));
							fprintf(e->f, "\tldp\t%s, %s, [x29, #%"PRIu64"]\n", rn1, rn0, lo);
							s = s1;
							k += 2;
							continue;
						}
					}
					s -= 2;
					i = &(Ins){Oload, 0, TMP(r0), {SLOT(s)}};
					i->cls = r0 >= V0 ? Kd : Kl;
					emitins(i, e);
					k++;
				}
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
			if (!far) {
				fprintf(e->f,
					"\tbhs\t%s%d\n",
					T.asloc, id0 + b->s1->id);
			} else {
				fprintf(e->f,
					"\tbcc\t1f\n"
					"\tb\t%s%d\n"
					"1:\n",
					T.asloc, id0 + b->s1->id);
			}
			fprintf(e->f,
				"\tadr\tx17, %sjt%d\n"
				"\tldrsw\tx16, [x17, %s, uxtw #2]\n"
				"\tadd\tx17, x17, x16\n"
				"\tbr\tx17\n"
				"%sjt%d:\n",
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
			s1 = b->s1;
			s2 = b->s2;
			if (b->link == s2) {
				t = s1;
				s1 = s2;
				s2 = t;
				n = 0;
			} else
				n = 1;
			if (flag_ins) {
				int fc = flag_ins->op - Oflag;
				int fn_inv = (c == Cieq) ? (n ^ 1) : n;
				if (!far) {
					fprintf(e->f,
						"\tb%s\t%s%d\n",
						ctoa[fc][fn_inv], T.asloc, id0+s2->id
					);
				} else {
					fprintf(e->f,
						"\tb%s\t1f\n"
						"\tb\t%s%d\n"
						"1:\n",
						ctoa[fc][fn_inv ^ 1],
						T.asloc, id0+s2->id
					);
				}
			} else if (cbz_ins) {
				int is_nz = (c == Cine) ^ n;
				if (!far) {
					fprintf(e->f,
						"\t%s\t%s, %s%d\n",
						is_nz ? "cbnz" : "cbz",
						rname(cbz_ins->arg[0].val, cbz_ins->cls),
						T.asloc, id0+s2->id
					);
				} else {
					fprintf(e->f,
						"\t%s\t%s, 1f\n"
						"\tb\t%s%d\n"
						"1:\n",
						is_nz ? "cbz" : "cbnz",
						rname(cbz_ins->arg[0].val, cbz_ins->cls),
						T.asloc, id0+s2->id
					);
				}
			} else {
				if (!far) {
					fprintf(e->f,
						"\tb%s\t%s%d\n",
						ctoa[c][n], T.asloc, id0+s2->id
					);
				} else {
					fprintf(e->f,
						"\tb%s\t1f\n"
						"\tb\t%s%d\n"
						"1:\n",
						ctoa[c][n ^ 1],
						T.asloc, id0+s2->id
					);
				}
			}
			if (s1 != b->link)
				fprintf(e->f,
					"\tb\t%s%d\n",
					T.asloc, id0+s1->id
				);
			else
				lbl = 0;
			break;
		}
	}
	id0 += e->fn->nblk;
	if (!T.apple)
		elf_emitfnfin(fn->name, out);
}
