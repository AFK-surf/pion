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
			fclose(outf);
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

	if (outf != stdout)
		fclose(outf);
	free(files);
	exit(0);
}
