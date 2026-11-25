#include "all.h"


typedef struct E E;

struct E {
	FILE *f;
	Fn *fn;
	int fp;
	uint64_t fsz;
	int nclob;
	int grouped_cvt;
	bits xmm_save; /* amd64_win: nonvolatile xmm6..xmm15 to save */
	int nxmm;
	uint64_t locsz; /* amd64_win: bytes of the local slot area */
	int framed; /* amd64_win: has a prologue (and unwind info) */
};

#define CMP(X) \
	X(Ciule,      "be", "a") \
	X(Ciult,      "b", "ae") \
	X(Cisle,      "le", "g") \
	X(Cislt,      "l", "ge") \
	X(Cisgt,      "g", "le") \
	X(Cisge,      "ge", "l") \
	X(Ciugt,      "a", "be") \
	X(Ciuge,      "ae", "b") \
	X(Cieq,       "z", "nz") \
	X(Cine,       "nz", "z") \
	X(NCmpI+Cfle, "?" , "?") \
	X(NCmpI+Cflt, "?",  "?") \
	X(NCmpI+Cfgt, "a", "be") \
	X(NCmpI+Cfge, "ae", "b") \
	X(NCmpI+Cfo,  "np", "p") \
	X(NCmpI+Cfuo, "p", "np")

enum {
	SLong = 0,
	SWord = 1,
	SShort = 2,
	SByte = 3,

	Ki = -1, /* matches Kw and Kl */
	Ka = -2, /* matches all classes */
};

/* Instruction format strings:
 *
 * if the format string starts with -, the instruction
 * is assumed to be 3-address and is put in 2-address
 * mode using an extra mov if necessary
 *
 * if the format string starts with +, the same as the
 * above applies, but commutativity is also assumed
 *
 * %k  is used to set the class of the instruction,
 *     it'll expand to "l", "q", "ss", "sd", depending
 *     on the instruction class
 * %0  designates the first argument
 * %1  designates the second argument
 * %=  designates the result
 *
 * if %k is not used, a prefix to 0, 1, or = must be
 * added, it can be:
 *   M - memory reference
 *   L - long  (64 bits)
 *   W - word  (32 bits)
 *   H - short (16 bits)
 *   B - byte  (8 bits)
 *   S - single precision float
 *   D - double precision float
 */
static struct {
	short op;
	short cls;
	char *fmt;
} omap[] = {
	{ Oadd,     Ka, "+add%k %1, %=" },
	{ Osub,     Ka, "-sub%k %1, %=" },
	{ Oand,     Ki, "+and%k %1, %=" },
	{ Oor,      Ki, "+or%k %1, %=" },
	{ Oxor,     Ki, "+xor%k %1, %=" },
	{ Osar,     Ki, "-sar%k %B1, %=" },
	{ Oshr,     Ki, "-shr%k %B1, %=" },
	{ Oshl,     Ki, "-shl%k %B1, %=" },
	{ Oror,     Ki, "-ror%k %B1, %=" },
	{ Omul,     Ki, "+imul%k %1, %=" },
	{ Omul,     Ks, "+mulss %1, %=" },
	{ Omul,     Kd, "+mulsd %1, %=" },
	{ Odiv,     Ka, "-div%k %1, %=" },
	{ Ostorel,  Ka, "movq %L0, %M1" },
	{ Ostorew,  Ka, "movl %W0, %M1" },
	{ Ostoreh,  Ka, "movw %H0, %M1" },
	{ Ostoreb,  Ka, "movb %B0, %M1" },
	{ Ostores,  Ka, "movss %S0, %M1" },
	{ Ostored,  Ka, "movsd %D0, %M1" },
	{ Oload,    Ka, "mov%k %M0, %=" },
	{ Oloadsw,  Kl, "movslq %M0, %L=" },
	{ Oloadsw,  Kw, "movl %M0, %W=" },
	{ Oloaduw,  Ki, "movl %M0, %W=" },
	{ Oloadsh,  Ki, "movsw%k %M0, %=" },
	{ Oloaduh,  Ki, "movzw%k %M0, %=" },
	{ Oloadsb,  Ki, "movsb%k %M0, %=" },
	{ Oloadub,  Ki, "movzb%k %M0, %=" },
	{ Oextsw,   Kl, "movslq %W0, %L=" },
	{ Oextuw,   Kl, "movl %W0, %W=" },
	{ Oextsh,   Ki, "movsw%k %H0, %=" },
	{ Oextuh,   Ki, "movzw%k %H0, %=" },
	{ Oextsb,   Ki, "movsb%k %B0, %=" },
	{ Oextub,   Ki, "movzb%k %B0, %=" },

	{ Oexts,    Kd, "cvtss2sd %0, %=" },
	{ Otruncd,  Ks, "cvtsd2ss %0, %=" },
	{ Osqrt,    Ks, "sqrtss %0, %=" },
	{ Osqrt,    Kd, "sqrtsd %0, %=" },
	{ Ostosi,   Ki, "cvttss2si%k %0, %=" },
	{ Odtosi,   Ki, "cvttsd2si%k %0, %=" },
	{ Oswtof,   Ka, "cvtsi2%kl %W0, %=" },
	{ Osltof,   Ka, "cvtsi2%kq %L0, %=" },
	{ Ocast,    Ki, "movq %D0, %L=" },
	{ Ocast,    Ka, "movq %L0, %D=" },

	{ Oaddr,    Ki, "lea%k %M0, %=" },
	{ Oswap,    Ki, "xchg%k %0, %1" },
	{ Osign,    Kl, "cqto" },
	{ Osign,    Kw, "cltd" },
	{ Oxdiv,    Ki, "div%k %0" },
	{ Oxidiv,   Ki, "idiv%k %0" },
	{ Oximul,   Ki, "imul%k %0" },
	{ Oxcmp,    Ks, "ucomiss %S0, %S1" },
	{ Oxcmp,    Kd, "ucomisd %D0, %D1" },
	{ Oxcmp,    Ki, "cmp%k %0, %1" },
	{ Oxtest,   Ki, "test%k %0, %1" },
#define X(c, s, _) \
	{ Oflag+c,  Ki, "set" s " %B=\n\tmovzb%k %B=, %=" },
	CMP(X)
#undef X
	{ Oflagfeq, Ki, "setz %B=\n\tmovzb%k %B=, %=" },
	{ Oflagfne, Ki, "setnz %B=\n\tmovzb%k %B=, %=" },
	{ NOp, 0, 0 }
};

static char cmov[][2][16] = {
#define X(c, s0, s1) \
	[c] = { \
		"cmov" s0 " %0, %=", \
		"cmov" s1 " %1, %=", \
	},
	CMP(X)
#undef X
};

static char *rname[][4] = {
	[RAX] = {"rax", "eax", "ax", "al"},
	[RBX] = {"rbx", "ebx", "bx", "bl"},
	[RCX] = {"rcx", "ecx", "cx", "cl"},
	[RDX] = {"rdx", "edx", "dx", "dl"},
	[RSI] = {"rsi", "esi", "si", "sil"},
	[RDI] = {"rdi", "edi", "di", "dil"},
	[RBP] = {"rbp", "ebp", "bp", "bpl"},
	[RSP] = {"rsp", "esp", "sp", "spl"},
	[R8 ] = {"r8" , "r8d", "r8w", "r8b"},
	[R9 ] = {"r9" , "r9d", "r9w", "r9b"},
	[R10] = {"r10", "r10d", "r10w", "r10b"},
	[R11] = {"r11", "r11d", "r11w", "r11b"},
	[R12] = {"r12", "r12d", "r12w", "r12b"},
	[R13] = {"r13", "r13d", "r13w", "r13b"},
	[R14] = {"r14", "r14d", "r14w", "r14b"},
	[R15] = {"r15", "r15d", "r15w", "r15b"},
};


static int64_t
slot(Ref r, E *e)
{
	int64_t s;

	s = rsval(r);
	assert(s <= e->fn->slot);
	/* specific to NAlign == 3 */
	if (T.windows) {
		/* amd64_win (winabi_framesz): %rbp, when used, equals %rsp
		 * after the prologue; the slots start at 0(fp), and the
		 * caller's area (s < 0, -2 is the return address) is past
		 * the frame, the pushed GPRs and the saved %rbp. */
		if (s < 0)
			return 4LL * -s - 8LL + (int64_t)e->fsz
				+ 8LL * ((int64_t)e->nclob + (e->fp == RBP));
		return 4LL * s;
	}
	if (s < 0) {
		if (e->fp == RSP)
			return 4LL * -s - 8LL + (int64_t)e->fsz + (int64_t)e->nclob * 8LL;
		else
			return 4LL * -s;
	}
	else if (e->fp == RSP)
		return 4LL * s + (int64_t)e->nclob * 8LL;
	else if (e->fn->vararg)
		return -176LL + -4LL * ((int64_t)e->fn->slot - s);
	else
		return -4LL * ((int64_t)e->fn->slot - s);
}

static void
emitcon(Con *con, E *e)
{
	char *p, *l;

	switch (con->type) {
	case CAddr:
		l = str(con->sym.id);
		p = l[0] == '"' ? "" : T.assym;
		if (con->sym.type == SThr) {
			assert(!T.apple);
			fprintf(e->f, "%%fs:%s%s@tpoff", p, l);
		} else {
			assert((con->sym.type & ~SExt) == SGlo);
			fprintf(e->f, "%s%s", p, l);
		}
		if (con->bits.i)
			fprintf(e->f, "%+"PRId64, con->bits.i);
		break;
	case CBits:
		fprintf(e->f, "%"PRId64, con->bits.i);
		break;
	default:
		die("unreachable");
	}
}

static char *
regtoa(int reg, int sz)
{
	static char buf[6];

	assert(reg <= XMM15);
	if (reg >= XMM0) {
		sprintf(buf, "xmm%d", reg-XMM0);
		return buf;
	} else
		return rname[reg][sz];
}

static Ref
getarg(char c, Ins *i)
{
	switch (c) {
	case '0':
		return i->arg[0];
	case '1':
		return i->arg[1];
	case '=':
		return i->to;
	default:
		die("invalid arg letter %c", c);
	}
}

static void emitins(Ins, E *);

static void
emitcopy(Ref r1, Ref r2, int k, E *e)
{
	Ins icp;

	icp.op = Ocopy;
	icp.arg[0] = r2;
	icp.to = r1;
	icp.cls = k;
	emitins(icp, e);
}

static void
emitf(char *s, Ins *i, E *e)
{
	static char clstoa[][3] = {"l", "q", "ss", "sd"};
	char c;
	int sz;
	Ref ref;
	Mem *m;
	Con off;

	switch (*s) {
	case '+':
		if (req(i->arg[1], i->to)) {
			ref = i->arg[0];
			i->arg[0] = i->arg[1];
			i->arg[1] = ref;
		}
		/* fall through */
	case '-':
		assert((!req(i->arg[1], i->to) || req(i->arg[0], i->to)) &&
			"cannot convert to 2-address");
		emitcopy(i->to, i->arg[0], i->cls, e);
		s++;
		break;
	}

	fputc('\t', e->f);
Next:
	while ((c = *s++) != '%')
		if (!c) {
			fputc('\n', e->f);
			return;
		} else
			fputc(c, e->f);
	switch ((c = *s++)) {
	case '%':
		fputc('%', e->f);
		break;
	case 'k':
		fputs(clstoa[i->cls], e->f);
		break;
	case '0':
	case '1':
	case '=':
		sz = KWIDE(i->cls) ? SLong : SWord;
		s--;
		goto Ref;
	case 'D':
	case 'S':
		sz = SLong; /* does not matter for floats */
	Ref:
		c = *s++;
		ref = getarg(c, i);
		switch (rtype(ref)) {
		case RTmp:
			assert(isreg(ref));
			fprintf(e->f, "%%%s", regtoa(ref.val, sz));
			break;
		case RSlot: {
			int64_t so = slot(ref, e);
			if (so < INT32_MIN || so > INT32_MAX)
				die("amd64 emit: stack slot displacement out of disp32 range");
			fprintf(e->f, "%"PRId64"(%%%s)",
				so,
				regtoa(e->fp, SLong)
			);
			break;
		}
		case RMem:
		Mem:
			m = &e->fn->mem[ref.val];
			if (rtype(m->base) == RSlot) {
				int64_t so = slot(m->base, e);
				int64_t cur = (m->offset.type == CUndef) ? 0 : m->offset.bits.i;
				if (so < INT32_MIN || so > INT32_MAX
				|| cur < INT32_MIN || cur > INT32_MAX
				|| cur + so < INT32_MIN || cur + so > INT32_MAX)
					die("amd64 emit: stack displacement out of disp32 range");
				off.type = CBits;
				off.bits.i = so;
				addcon(&m->offset, &off, 1);
				m->base = TMP(e->fp);
			}
			if (m->offset.type != CUndef)
				emitcon(&m->offset, e);
			fputc('(', e->f);
			if (!req(m->base, R))
				fprintf(e->f, "%%%s",
					regtoa(m->base.val, SLong)
				);
			else if (m->offset.type == CAddr)
				fprintf(e->f, "%%rip");
			if (!req(m->index, R))
				fprintf(e->f, ", %%%s, %d",
					regtoa(m->index.val, SLong),
					m->scale
				);
			fputc(')', e->f);
			break;
		case RCon:
			fputc('$', e->f);
			if (sz == SByte
			&& e->fn->con[ref.val].type == CBits)
				/* x86 masks shift counts; match elf.c */
				fprintf(e->f, "%d",
					(int)(e->fn->con[ref.val].bits.i & 0xff));
			else
				emitcon(&e->fn->con[ref.val], e);
			break;
		default:
			die("unreachable");
		}
		break;
	case 'L':
		sz = SLong;
		goto Ref;
	case 'W':
		sz = SWord;
		goto Ref;
	case 'H':
		sz = SShort;
		goto Ref;
	case 'B':
		sz = SByte;
		goto Ref;
	case 'M':
		c = *s++;
		ref = getarg(c, i);
		switch (rtype(ref)) {
		case RMem:
			goto Mem;
		case RSlot: {
			int64_t so = slot(ref, e);
			if (so < INT32_MIN || so > INT32_MAX)
				die("amd64 emit: stack slot displacement out of disp32 range");
			fprintf(e->f, "%"PRId64"(%%%s)",
				so,
				regtoa(e->fp, SLong)
			);
			break;
		}
		case RCon:
			off = e->fn->con[ref.val];
			emitcon(&off, e);
			if (off.type == CAddr)
			if (off.sym.type != SThr)
				fprintf(e->f, "(%%rip)");
			break;
		case RTmp:
			assert(isreg(ref));
			fprintf(e->f, "(%%%s)", regtoa(ref.val, SLong));
			break;
		default:
			die("unreachable");
		}
		break;
	default:
		die("invalid format specifier %%%c", c);
	}
	goto Next;
}

static bits negmask[4] = {
	[Ks] = 0x80000000,
	[Kd] = 0x8000000000000000,
};

static void
emitins(Ins i, E *e)
{
	Ref r;
	int64_t val;
	int o, t0;
	Ins ineg;
	Con *con;
	char *sym;

	if (i.op==Oload && i.cls==Kv2d)
		i.op=Ovload;
	switch (i.op) {
	case Ovload:
		emitf("movupd %D0, %D=", &i, e);
		break;
	case Ovstore:
		emitf("movupd %D0, %D1", &i, e);
		break;
	case Ovhigh:
		emitf("pshufd $238, %D0, %D=", &i, e);
		break;
	case Oxcmp:
		if (e->fn->packed && !KBASE(i.cls) && rtype(i.arg[0]) == RCon &&
		    isreg(i.arg[1])) {
			Con *c = &e->fn->con[i.arg[0].val];
			if (c->type == CBits &&
			    (KWIDE(i.cls) ? c->bits.i == 0 : (uint32_t)c->bits.i == 0)) {
				emitf("test%k %1, %1", &i, e);
				break;
			}
		}
		goto Table;
	case Otrapmask:
		emitf("stmxcsr %D0", &i, e);
		emitf("andl $8064, %D0", &i, e);
		emitf("cmpl $8064, %D0", &i, e);
		break;
	case Ovsum: {
		Ins high = {Ovhigh, Kd, TMP(XMM15), {i.arg[0], R}};
		emitins(high, e);
		emitcopy(i.to, i.arg[0], Kd, e);
		i.arg[1] = TMP(XMM15);
		emitf("addsd %D1, %D=", &i, e);
		break;
	}
	case Ovlo:
		emitcopy(i.to, i.arg[0], Kd, e);
		break;
	case Ovsplat:
		emitf("pshufd $68, %D0, %D=", &i, e);
		break;
	case Ovzip:
		if (req(i.to, i.arg[1])) {
			emitcopy(TMP(XMM15), i.arg[1], Kd, e);
			i.arg[1] = TMP(XMM15);
		}
		emitcopy(i.to, i.arg[0], Kd, e);
		emitf("unpcklpd %D1, %D=", &i, e);
		break;
	case Oordadd:
	case Oordsub:
	case Oordmul:
	case Ovadd:
	case Ovsub:
	case Ovmul:
		if (req(i.to, i.arg[1]) && !req(i.to, i.arg[0])) {
			emitcopy(TMP(XMM15), i.arg[1], i.cls == Ks ? Ks : Kd, e);
			i.arg[1] = TMP(XMM15);
		}
		emitcopy(i.to, i.arg[0], i.cls == Ks ? Ks : Kd, e);
		if (i.cls == Ks)
			emitf(i.op == Oordadd	? "addss %S1, %S="
			      : i.op == Oordsub ? "subss %S1, %S="
						: "mulss %S1, %S=",
			      &i, e);
		else
			emitf(i.op == Oordadd	? "addsd %D1, %D="
			      : i.op == Oordsub ? "subsd %D1, %D="
			      : i.op == Oordmul ? "mulsd %D1, %D="
			      : i.op == Ovadd	? "addpd %D1, %D="
			      : i.op == Ovsub	? "subpd %D1, %D="
						: "mulpd %D1, %D=",
			      &i, e);
		break;
	default:
		if (isxsel(i.op))
			goto case_Oxsel;
	Table:
		/* most instructions are just pulled out of
		 * the table omap[], some special cases are
		 * detailed below */
		for (o=0;; o++) {
			/* this linear search should really be a binary
			 * search */
			if (omap[o].op == NOp)
				die("no match for %s(%c)",
					optab[i.op].name, "wlsd"[i.cls]);
			if (omap[o].op == i.op)
			if (omap[o].cls == i.cls
			|| (omap[o].cls == Ki && KBASE(i.cls) == 0)
			|| (omap[o].cls == Ka))
				break;
		}
		emitf(omap[o].fmt, &i, e);
		break;
	case Onop:
		/* just do nothing for nops, they are inserted
		 * by some passes */
		break;
	case Oswtof:
	case Osltof:
		/* Scalar SSE conversion merges the unused upper lanes
		 * (grouped_cvt is never set by amd64_winabi_emitfn). */
		if (e->grouped_cvt)
			emitf("xorps %=, %=", &i, e);
		goto Table;
	case Omul:
		/* here, we try to use the 3-addresss form
		 * of multiplication when possible */
		if (rtype(i.arg[1]) == RCon) {
			r = i.arg[0];
			i.arg[0] = i.arg[1];
			i.arg[1] = r;
		}
		if (KBASE(i.cls) == 0 /* only available for ints */
		&& rtype(i.arg[0]) == RCon
		&& rtype(i.arg[1]) == RTmp) {
			emitf("imul%k %0, %1, %=", &i, e);
			break;
		}
		goto Table;
	case Osub:
		/* we have to use the negation trick to handle
		 * some 3-address subtractions */
		if (req(i.to, i.arg[1]) && !req(i.arg[0], i.to)) {
			ineg = (Ins){Oneg, i.cls, i.to, {i.to}};
			emitins(ineg, e);
			emitf("add%k %0, %=", &i, e);
			break;
		}
		goto Table;
	case Oneg:
		if (!req(i.to, i.arg[0]))
			emitcopy(i.to, i.arg[0], i.cls, e);
		if (KBASE(i.cls) == 0)
			emitf("neg%k %=", &i, e);
		else
			fprintf(e->f,
				"\txorp%c %sfp%d(%%rip), %%%s\n",
				"xxsd"[i.cls],
				T.asloc,
				stashbits(negmask[i.cls], 16),
				regtoa(i.to.val, SLong)
			);
		break;
	case Odiv:
		/* use xmm15 to adjust the instruction when the
		 * conversion to 2-address in emitf() would fail */
		if (req(i.to, i.arg[1])) {
			i.arg[1] = TMP(XMM0+15);
			emitcopy(i.arg[1], i.to, i.cls, e);
			emitcopy(i.to, i.arg[0], i.cls, e);
			i.arg[0] = i.to;
		}
		goto Table;
	case Ocopy:
		if (i.cls == Kv2d) {
			Ins k = i;
			Ref dst = k.to, src = k.arg[0];
			if (req(dst, src))
				break;
			if (rtype(src) == RSlot) {
				k = (Ins){Ovload,
					  Kv2d,
					  rtype(dst) == RSlot ? TMP(XMM15) : dst,
					  {src, R}};
				emitins(k, e);
				src = k.to;
			}
			if (rtype(dst) == RSlot) {
				k = (Ins){Ovstore, Kv2d, R, {src, dst}};
				emitins(k, e);
			} else if (!req(dst, src)) {
				emitcopy(dst, src, Kd, e);
			}
			break;
		}
		/* copies are used for many things; see my note
		 * to understand how to load big constants:
		 * https://c9x.me/notes/2015-09-19.html */
		assert(rtype(i.to) != RMem);
		if (req(i.to, R) || req(i.arg[0], R))
			break;
		if (req(i.to, i.arg[0]))
			break;
		/* A register copy only has a live scalar low lane. amd64_win
		 * keeps the scalar low-lane move (its prologue saves the
		 * nonvolatile xmm6..xmm15 it writes, all 128 bits). */
		if (!T.windows && KBASE(i.cls) && isreg(i.to) && isreg(i.arg[0])) {
			emitf("movaps %0, %=", &i, e);
			break;
		}
		t0 = rtype(i.arg[0]);
		if (i.cls == Kl
		&& t0 == RCon
		&& e->fn->con[i.arg[0].val].type == CBits) {
			val = e->fn->con[i.arg[0].val].bits.i;
			if (isreg(i.to))
			if (val >= 0 && val <= UINT32_MAX) {
				emitf("movl %W0, %W=", &i, e);
				break;
			}
			if (rtype(i.to) == RSlot)
			if (val < INT32_MIN || val > INT32_MAX) {
				emitf("movl %0, %=", &i, e);
				emitf("movl %0>>32, 4+%=", &i, e);
				break;
			}
		}
		if (isreg(i.to)
		&& t0 == RCon
		&& e->fn->con[i.arg[0].val].type == CAddr) {
			emitf("lea%k %M0, %=", &i, e);
			break;
		}
		if (rtype(i.to) == RSlot
		&& (t0 == RSlot || t0 == RMem)) {
			i.cls = KWIDE(i.cls) ? Kd : Ks;
			i.arg[1] = TMP(XMM0+15);
			emitf("mov%k %0, %1", &i, e);
			emitf("mov%k %1, %=", &i, e);
			break;
		}
		/* conveniently, the assembler knows if it
		 * should use movabsq when reading movq */
		emitf("mov%k %0, %=", &i, e);
		break;
	case Oaddr:
		if (rtype(i.arg[0]) != RCon)
			goto Table;
		con = &e->fn->con[i.arg[0].val];
		assert(isreg(i.to) && con->type == CAddr);
		sym = str(con->sym.id);
		if (T.apple && (con->sym.type & SThr)) {
			fprintf(e->f,
				"\tmovq %s%s@tlvp(%%rip), %%%s\n",
				sym[0] == '"' ? "" : T.assym, sym,
				regtoa(i.to.val, SLong));
			break;
		}
		if (T.windows && con->sym.type != SGlo)
			die("extern/thread unsupported on amd64_win");
		switch (con->sym.type) {
		case SThr:
			/* derive the symbol address from the TCB
			 * address at offset 0 of %fs */
			emitf("movq %%fs:0, %L=", &i, e);
			fprintf(e->f, "\tleaq %s%s@tpoff",
				sym[0] == '"' ? "" : T.assym, sym);
			if (con->bits.i)
				fprintf(e->f, "%+"PRId64,
					con->bits.i);
			fprintf(e->f, "(%%%s), %%%s\n",
				regtoa(i.to.val, SLong),
				regtoa(i.to.val, SLong));
			break;
		case SExtThr:
			/* initial-exec TLS: load offset from
			 * GOT, add to thread-base register */
			assert(!con->bits.i);
			emitf("movq %%fs:0, %L=", &i, e);
			fprintf(e->f,
				"\taddq %s%s@gottpoff(%%rip), %%%s\n",
				sym[0] == '"' ? "" : T.assym, sym,
				regtoa(i.to.val, SLong));
			break;
		case SExt:
			/* load address from the GOT */
			assert(!con->bits.i);
			fprintf(e->f,
				"\tmovq %s%s@gotpcrel(%%rip), %%%s\n",
				sym[0] == '"' ? "" : T.assym, sym,
				regtoa(i.to.val, SLong));
			break;
		default:
			goto Table;
		}
		break;
	case Ocall:
		/* calls simply have a weird syntax in AT&T
		 * assembly... */
		switch (rtype(i.arg[0])) {
		case RCon:
			con = &e->fn->con[i.arg[0].val];
			fprintf(e->f, "\tcallq ");
			emitcon(con, e);
			if (con->type == CAddr
			&& (con->sym.type & SExt)
			&& !T.apple)
				fprintf(e->f, "@plt");
			fprintf(e->f, "\n");
			break;
		case RTmp:
			emitf("callq *%L0", &i, e);
			break;
		default:
			die("invalid call argument");
		}
		break;
	case Osalloc:
		/* there is no good reason why this is here
		 * maybe we should split Osalloc in 2 different
		 * instructions depending on the result
		 */
		assert(e->fp == RBP);
		emitf("subq %L0, %%rsp", &i, e);
		if (!req(i.to, R))
			emitcopy(i.to, TMP(RSP), Kl, e);
		break;
	case Oswap:
		if (i.cls == Kv2d) {
			emitcopy(TMP(XMM15), i.arg[0], Kd, e);
			emitcopy(i.arg[0], i.arg[1], Kd, e);
			emitcopy(i.arg[1], TMP(XMM15), Kd, e);
			break;
		}
		if (KBASE(i.cls) == 0)
			goto Table;
		/* for floats, there is no swap instruction
		 * so we use xmm15 as a temporary
		 */
		emitcopy(TMP(XMM0+15), i.arg[0], i.cls, e);
		emitcopy(i.arg[0], i.arg[1], i.cls, e);
		emitcopy(i.arg[1], TMP(XMM0+15), i.cls, e);
		break;
	case Odbgloc:
		emitdbgloc(i.arg[0].val, i.arg[1].val, e->f);
		break;
	case_Oxsel:
		if (req(i.to, i.arg[1]))
			emitf(cmov[i.op-Oxsel][0], &i, e);
		else {
			if (!req(i.to, i.arg[0]))
				emitf("mov %0, %=", &i, e);
			emitf(cmov[i.op-Oxsel][1], &i, e);
		}
		break;
	}
}

static void
emitjtbl(Blk *b, int id0, E *e)
{
	static int jt0;
	int jtid = jt0++;
	FILE *f = e->f;
	char *idx_reg, *address_index = rname[R10][SLong];
	uint32_t jk;

	if (rtype(b->jmp.arg) == RSlot) {
		Ins li = { .op = Oload, .cls = Kw, .to = TMP(R10), .arg = { b->jmp.arg, R } };
		emitf("movl %M0, %W=", &li, e);
		idx_reg = rname[R10][SWord];
	} else {
		assert(isreg(b->jmp.arg));
		idx_reg = rname[b->jmp.arg.val][SWord];
	}
	fprintf(f, "\tcmpl $%"PRIu32", %%%s\n", b->njtbl, idx_reg);
	fprintf(f, "\tjae %sbb%d\n", T.asloc, id0 + b->s1->id);
	fprintf(f, "\tleaq %sjt%d(%%rip), %%r11\n", T.asloc, jtid);
	if (amd64_table_word(b))
		address_index = rname[b->jmp.arg.val][SLong];
	else if (rtype(b->jmp.arg) != RSlot)
		fprintf(f, "\tmovl %%%s, %%r10d\n", idx_reg);
	fprintf(f, "\tmovslq (%%r11,%%%s,4), %%r10\n", address_index);
	fprintf(f, "\taddq %%r10, %%r11\n");
	fprintf(f, "\tjmpq *%%r11\n");
	if (!T.windows) {
		if (T.apple)
			fprintf(f, ".section __TEXT,__const\n");
		else
			fprintf(f, ".section .rodata\n");
	}
	fprintf(f, ".p2align 2\n");
	fprintf(f, "%sjt%d:\n", T.asloc, jtid);
	for (jk = 0; jk < b->njtbl; jk++)
		fprintf(f, "\t.long %sbb%d - %sjt%d\n",
			T.asloc, id0 + b->jtbl[jk]->id, T.asloc, jtid);
	if (!T.windows)
		fprintf(f, T.apple ? ".text\n" : ".previous\n");
}

static void
sysv_framesz(E *e)
{
	uint64_t i, o, f;

	/* specific to NAlign == 3 */
	o = 0;
	if (!e->fn->leaf) {
		for (i=0, o=0; i<NCLR_SYSV; i++)
			o ^= e->fn->reg >> amd64_sysv_rclob[i];
		o &= 1;
	}
	f = e->fn->slot;
	f = (f + 3) & -4;
	if (f > 0
	&& e->fp == RSP
	&& e->fn->salign == 4)
		f += 2;
	e->fsz = 4*f + 8*o + 176*e->fn->vararg;
}

void
amd64_sysv_emitfn(Fn *fn, FILE *f)
{
	static char *ctoa[][2] = {
	#define X(c, s, n) [c] = {s, n},
		CMP(X)
	#undef X
	};
	static int id0;
	Blk *b, *s;
	Ins *i, itmp;
	int *r, c, o, n, lbl;
	uint p;
	E *e;

	e = &(E){.f = f, .fn = fn};
	emitfnlnk(fn->name, &fn->lnk, f);
	fputs("\tendbr64\n", f);
	if (!fn->leaf || fn->vararg || fn->dynalloc) {
		e->fp = RBP;
		fputs("\tpushq %rbp\n\tmovq %rsp, %rbp\n", f);
	} else
		e->fp = RSP;
	sysv_framesz(e);
	if (e->fsz)
		fprintf(f, "\tsubq $%"PRIu64", %%rsp\n", e->fsz);
	if (fn->vararg) {
		o = -176;
		for (r=amd64_sysv_rsave; r<&amd64_sysv_rsave[6]; r++, o+=8)
			fprintf(f, "\tmovq %%%s, %d(%%rbp)\n", rname[*r][0], o);
		for (n=0; n<8; ++n, o+=16)
			fprintf(f, "\tmovaps %%xmm%d, %d(%%rbp)\n", n, o);
	}
	for (r=amd64_sysv_rclob; r<&amd64_sysv_rclob[NCLR_SYSV]; r++)
		if (fn->reg & BIT(*r)) {
			itmp.arg[0] = TMP(*r);
			emitf("pushq %L0", &itmp, e);
			e->nclob++;
		}

	for (lbl=0, b=fn->start; b; b=b->link) {
		if (lbl || b->npred > 1) {
			for (p=0; p<b->npred; p++)
				if (b->pred[p]->id >= b->id)
					break;
			if (p != b->npred)
				fprintf(f, ".p2align 4\n");
			fprintf(f, "%sbb%d:\n", T.asloc, id0+b->id);
		}
		e->grouped_cvt = amd64_grouped_cvt(b);
		for (i=b->ins; i!=&b->ins[b->nins]; i++)
			emitins(*i, e);
		lbl = 1;
		switch (b->jmp.type) {
		case Jhlt:
			fprintf(f, "\tud2\n");
			break;
		case Jret0:
			if (fn->dynalloc)
				fprintf(f,
					"\tmovq %%rbp, %%rsp\n"
					"\tsubq $%"PRIu64", %%rsp\n",
					e->fsz + e->nclob * 8);
			for (r=&amd64_sysv_rclob[NCLR_SYSV]; r>amd64_sysv_rclob;)
				if (fn->reg & BIT(*--r)) {
					itmp.arg[0] = TMP(*r);
					emitf("popq %L0", &itmp, e);
				}
			if (e->fp == RBP)
				fputs("\tleave\n", f);
			else if (e->fsz)
				fprintf(f,
					"\taddq $%"PRIu64", %%rsp\n",
					e->fsz);
			fputs("\tret\n", f);
			break;
		case Jjmp:
		Jmp:
			if (b->s1 != b->link)
				fprintf(f, "\tjmp %sbb%d\n",
					T.asloc, id0+b->s1->id);
			else
				lbl = 0;
			break;
		case Jjtbl:
			emitjtbl(b, id0, e);
			break;
		default:
			c = b->jmp.type - Jjf;
			if (0 <= c && c <= NCmp) {
				if (b->link == b->s2) {
					s = b->s1;
					b->s1 = b->s2;
					b->s2 = s;
					n = 0;
				} else
					n = 1;
				fprintf(f, "\tj%s %sbb%d\n", ctoa[c][n],
					T.asloc, id0+b->s2->id);
				goto Jmp;
			}
			die("unhandled jump %d", b->jmp.type);
		}
	}
	id0 += fn->nblk;
	if (!T.apple)
		elf_emitfnfin(fn->name, f);
}

/* Does the emitter write the reserved xmm15 scratch in fn? Mirrors
 * every TMP(XMM0+15) write in emitins: Odiv with to == arg[1], a
 * slot-to-slot (or memory-to-slot) copy, and a floating-point Oswap.
 * Any other instruction whose 2-address conversion (emitf '+'/'-')
 * copies a slot or memory operand into a slot destination is counted
 * too, which over-approximates (isel never emits one). */
static int
winabi_uses_xmm15(Fn *fn)
{
	Blk *b;
	Ins *i;
	int t0;

	for (b=fn->start; b; b=b->link)
		for (i=b->ins; i<&b->ins[b->nins]; i++) {
			if (i->op == Odiv && req(i->to, i->arg[1]))
				return 1;
			if (i->op == Oswap && KBASE(i->cls))
				return 1;
			if (req(i->to, R) || req(i->arg[0], R)
			|| req(i->to, i->arg[0]))
				continue;
			t0 = rtype(i->arg[0]);
			if (rtype(i->to) == RSlot
			&& (t0 == RSlot || t0 == RMem))
				return 1;
		}
	return 0;
}

/* Microsoft x64 frame (all offsets from %rsp after the prologue, which
 * %rbp equals when used; 16-byte aligned):
 *   [0, locsz)                    slots (4*fn->slot bytes used)
 *   [locsz, locsz + 16*nxmm)      saved xmm6..xmm15, k-th at locsz+16k
 *   [.., fsz)                     8*o pad
 *   [fsz, fsz + 8*nclob)          pushed amd64_winabi_rclob GPRs
 *   [.., +8)                      saved %rbp (rbp frames)
 *   then the return address and the caller's home / stack area.
 * The order (pushes, allocation, frame register, xmm saves) is the
 * one the Windows unwinder describes with UWOP_PUSH_NONVOL,
 * UWOP_ALLOC_*, UWOP_SET_FPREG (offset 0) and UWOP_SAVE_XMM128. */
static void
winabi_framesz(E *e)
{
	uint64_t f, o, npush;
	int *r;

	/* Nonvolatile xmm6..xmm14 the allocator used, plus the xmm15
	 * scratch when the emitter writes it. */
	e->xmm_save = e->fn->reg & (BIT(XMM15) - BIT(XMM6));
	if (winabi_uses_xmm15(e->fn))
		e->xmm_save |= BIT(XMM15);
	e->nxmm = 0;
	for (r=amd64_winabi_xclob; *r>=0; r++)
		if (e->xmm_save & BIT(*r))
			e->nxmm++;
	e->nclob = 0;
	for (r=amd64_winabi_rclob; *r>=0; r++)
		if (e->fn->reg & BIT(*r))
			e->nclob++;
	/* specific to NAlign == 3 */
	f = ((uint64_t)e->fn->slot + 3) & -4;
	e->locsz = 4*f;
	e->framed = e->fp == RBP || f || e->nclob || e->nxmm;
	/* %rsp is 16-byte aligned after the prologue of every framed
	 * function: entry %rsp = 8 mod 16, npush pushes, then fsz. */
	o = 0;
	npush = (uint64_t)e->nclob + (e->fp == RBP);
	if (e->framed)
		o = (npush + 1) & 1;
	e->fsz = e->locsz + 16*(uint64_t)e->nxmm + 8*o;
	if (e->fsz > INT32_MAX)
		die("stack frame too large");
}

/* `.seh_*` directives only with --seh (pionc passes it for MSVC
 * link / lld-link, which drop .pdata with dead functions; MinGW GNU
 * ld KEEP()s every .pdata). The frame layout is the same either way. */
static void
winabi_sehreg(E *e, char *dir, int reg)
{
	if (win_seh)
		fprintf(e->f, "\t%s %%%s\n", dir, rname[reg][0]);
}

/* Offset of the k-th saved xmm register, from %rsp after the
 * prologue (== %rbp in rbp frames). */
static int64_t
winabi_xmmoff(E *e, int k)
{
	return (int64_t)(e->locsz + 16*(uint64_t)k);
}

static void
winabi_xmmsave(E *e, int restore)
{
	int *r, k;

	for (k=0, r=amd64_winabi_xclob; *r>=0; r++)
		if (e->xmm_save & BIT(*r)) {
			if (restore)
				fprintf(e->f, "\tmovups %"PRId64"(%%%s), %%xmm%d\n",
					winabi_xmmoff(e, k), rname[e->fp][0],
					*r - XMM0);
			else {
				fprintf(e->f, "\tmovups %%xmm%d, %"PRId64"(%%rsp)\n",
					*r - XMM0, winabi_xmmoff(e, k));
				if (win_seh)
					fprintf(e->f, "\t.seh_savexmm %%xmm%d, %"PRId64"\n",
						*r - XMM0, winabi_xmmoff(e, k));
			}
			k++;
		}
}

static void
winabi_prologue(Fn *fn, E *e)
{
	static int chkstk_id;
	FILE *f;
	int *r, cid;

	f = e->f;
	if (e->framed && win_seh)
		fprintf(f, "\t.seh_proc %s\n", fn->name);
	fputs("\tendbr64\n", f);
	if (fn->vararg) {
		fprintf(f, "\tmovq %%rcx, 0x8(%%rsp)\n");
		fprintf(f, "\tmovq %%rdx, 0x10(%%rsp)\n");
		fprintf(f, "\tmovq %%r8, 0x18(%%rsp)\n");
		fprintf(f, "\tmovq %%r9, 0x20(%%rsp)\n");
	}
	if (!e->framed)
		return;
	if (e->fp == RBP) {
		fputs("\tpushq %rbp\n", f);
		winabi_sehreg(e, ".seh_pushreg", RBP);
	}
	for (r=amd64_winabi_rclob; *r>=0; r++)
		if (fn->reg & BIT(*r)) {
			fprintf(f, "\tpushq %%%s\n", rname[*r][0]);
			winabi_sehreg(e, ".seh_pushreg", *r);
		}
	/* Windows commits the stack on demand behind a single 4 KB
	 * guard page: a frame of 4 KB or more must touch every page in
	 * order. Probe below %rsp with the volatile %r10 / %r11 (dead
	 * here, not argument registers) and then allocate with one
	 * subq, so that .seh_stackalloc describes one instruction. */
	if (e->fsz >= 4096) {
		cid = chkstk_id++;
		fprintf(f,
			"\tleaq -%"PRIu64"(%%rsp), %%r10\n"
			"\tmovq %%rsp, %%r11\n"
			"%schkstk%d:\n"
			"\tsubq $4096, %%r11\n"
			"\tcmpq %%r10, %%r11\n"
			"\tjbe %schkstkd%d\n"
			"\torq $0, (%%r11)\n"
			"\tjmp %schkstk%d\n"
			"%schkstkd%d:\n",
			e->fsz, T.asloc, cid, T.asloc, cid, T.asloc, cid,
			T.asloc, cid);
	}
	if (e->fsz) {
		fprintf(f, "\tsubq $%"PRIu64", %%rsp\n", e->fsz);
		if (win_seh)
			fprintf(f, "\t.seh_stackalloc %"PRIu64"\n", e->fsz);
		if (e->fsz >= 4000)
			fputs("\torq $0, (%rsp)\n", f);
	}
	/* UNWIND_CODE: with a frame register, codes taking an offset
	 * come after UWOP_SET_FPREG; FrameOffset 0 makes the frame base
	 * %rbp == %rsp here, so the xmm offsets mean the same either
	 * way, also after a dynalloc moves %rsp. */
	if (e->fp == RBP) {
		fputs("\tmovq %rsp, %rbp\n", f);
		if (win_seh)
			fputs("\t.seh_setframe %rbp, 0\n", f);
	}
	winabi_xmmsave(e, 0);
	if (win_seh)
		fputs("\t.seh_endprologue\n", f);
}

/* Restore everything the prologue saved and return. In rbp frames
 * (dynalloc moves %rsp) the epilogue starts with the `lea` form the
 * Windows unwinder recognizes. */
static void
winabi_epilogue(Fn *fn, E *e)
{
	FILE *f;
	int *r;

	f = e->f;
	winabi_xmmsave(e, 1);
	if (e->fp == RBP) {
		fprintf(f, "\tleaq %"PRIu64"(%%rbp), %%rsp\n", e->fsz);
	} else if (e->fsz)
		fprintf(f, "\taddq $%"PRIu64", %%rsp\n", e->fsz);
	for (r=&amd64_winabi_rclob[NCLR_WIN]; r>amd64_winabi_rclob;)
		if (fn->reg & BIT(*--r))
			fprintf(f, "\tpopq %%%s\n", rname[*r][0]);
	if (e->fp == RBP)
		fputs("\tpopq %rbp\n", f);
	fputs("\tret\n", f);
}

void
amd64_winabi_emitfn(Fn *fn, FILE *f)
{
	static char *ctoa[][2] = {
	#define X(c, s, n) [c] = {s, n},
		CMP(X)
	#undef X
	};
	static int id0;
	Blk *b, *s;
	Ins *i;
	int c, n, lbl;
	E *e;

	e = &(E){.f = f, .fn = fn};
	emitfnlnk(fn->name, &fn->lnk, f);
	e->fp = (!fn->leaf || fn->vararg || fn->dynalloc) ? RBP : RSP;
	winabi_framesz(e);
	winabi_prologue(fn, e);

	for (lbl=0, b=fn->start; b; b=b->link) {
		if (lbl || b->npred > 1)
			fprintf(f, "%sbb%d:\n", T.asloc, id0+b->id);
		/* e->grouped_cvt stays 0: amd64_win keeps its scalar
		 * conversions unchanged. */
		for (i=b->ins; i!=&b->ins[b->nins]; i++)
			emitins(*i, e);
		lbl = 1;
		switch (b->jmp.type) {
		case Jhlt:
			fprintf(f, "\tud2\n");
			break;
		case Jret0:
			winabi_epilogue(fn, e);
			break;
		case Jjmp:
		Jmp:
			if (b->s1 != b->link)
				fprintf(f, "\tjmp %sbb%d\n",
					T.asloc, id0+b->s1->id);
			else
				lbl = 0;
			break;
		case Jjtbl:
			emitjtbl(b, id0, e);
			break;
		default:
			c = b->jmp.type - Jjf;
			if (0 <= c && c <= NCmp) {
				if (b->link == b->s2 || c >= NCmpI) {
					s = b->s1;
					b->s1 = b->s2;
					b->s2 = s;
					n = 0;
				} else
					n = 1;
				fprintf(f, "\tj%s %sbb%d\n", ctoa[c][n],
					T.asloc, id0+b->s2->id);
				goto Jmp;
			}
			die("unhandled jump %d", b->jmp.type);
		}
	}
	id0 += fn->nblk;
	if (e->framed && win_seh)
		fputs("\t.seh_endproc\n", f);
}
