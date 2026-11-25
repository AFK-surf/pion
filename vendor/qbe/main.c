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

static int
expandloops(Fn *fn)
{
	Blk *b;
	Ins *dst, op;
	Ref *map = 0, orig, iv[MaxTrips];
	uint n, j, mapcap = 0;
	int t, count, changed = 0, budget = 2 * MaxExpanded;

	for (b=fn->start; b; b=b->link) {
		if (b->nins > MaxExpanded || !(count = trips(fn, b, iv))
		|| b->nins * count > MaxExpanded || b->nins * count > (uint)budget)
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
		budget -= j - 1;
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
	gvn(fn);
	fillcfg(fn);
	simplcfg(fn);
	filluse(fn);
	filldom(fn);
	gcm(fn);
	filluse(fn);
	ssacheck(fn);
	for (int round=0; round<2 && expandloops(fn); round++) {
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
	if (strncmp(T.name, "arm64", 5) == 0) {
		filldom(fn);
		fillloop(fn);
		arm64_hoist_consts(fn);
	} else if (strncmp(T.name, "amd64", 5) == 0) {
		filldom(fn);
		fillloop(fn);
		amd64_hoist_consts(fn);
	}
	filllive(fn);
	fillloop(fn);
	fillcost(fn);
	spill(fn);
	rega(fn);
	fillcfg(fn);
	simpljmp(fn);
	fillcfg(fn);
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
