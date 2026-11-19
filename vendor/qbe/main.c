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
		arm64_macho_dat(d);
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
	if (!dbg) {
		if (objmode) {
			arm64_macho_fn(fn);
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
	fprintf(hf, "\t%-18s emit Mach-O .o directly (arm64_apple)\n", "--obj");
	fprintf(hf, "\t%-18s batch emit Mach-O .o pairs <in.ssa> <out.o>...\n", "--obj-batch");
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

	if (objmode && (!T.apple || strcmp(T.name, "arm64_apple") != 0)) {
		fprintf(stderr, "--obj is only supported for target arm64_apple\n");
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
			if (!dbg)
				arm64_macho_begin(macos_ver);
			parse(inf, in_p, dbgfile, data, func);
			fclose(inf);
			if (!dbg)
				arm64_macho_finish(outf);
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

	if (objmode && !dbg)
		arm64_macho_begin(macos_ver);

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
		if (objmode)
			arm64_macho_finish(outf);
		else
			T.emitfin(outf);
	}

	if (outf != stdout)
		fclose(outf);
	free(files);
	exit(0);
}
