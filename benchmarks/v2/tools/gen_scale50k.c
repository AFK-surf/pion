/*
 * Deterministic 50,000-LOC / 50-package 4-layer diamond-dependency project generator
 * for C, MoonBit, Zig, Rust, Go, and m2 V2 compile-speed & multi-worktree benchmarks.
 *
 * Architecture (50 library packages + 1 app entry package ≈ 50,000 LOC):
 *   Layer 0: core00..core04 (5 pkgs)  - no deps; defines Packet, Op, generic wrap_tag
 *   Layer 1: mid00..mid14   (15 pkgs) - each imports 2 core pkgs
 *   Layer 2: svc00..svc19   (20 pkgs) - each imports 2 mid pkgs + 1 core pkg (diamond!)
 *   Layer 3: leaf00..leaf09 (10 pkgs) - each imports 2 svc pkgs
 *   Entry  : app            (1 pkg)   - imports all 10 leaf pkgs, prints 1-line checksum
 *
 * Usage:
 *   gen_scale50k <out_dir> [--mutate-leaf-body | --mutate-core-body | --mutate-core-sig | --branch <0..4>]
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define NUM_CORE 5
#define NUM_MID  15
#define NUM_SVC  20
#define NUM_LEAF 10
#define NUM_PKGS (NUM_CORE + NUM_MID + NUM_SVC + NUM_LEAF) /* 50 */
#define FNS_PER_PKG 31

typedef enum {
    LAYER_CORE = 0,
    LAYER_MID  = 1,
    LAYER_SVC  = 2,
    LAYER_LEAF = 3
} Layer;

typedef struct {
    int id;
    Layer layer;
    int idx;
    char name[16];
    const char *struct_name;
    const char *enum_name;
    int num_deps;
    int deps[3];
} PkgInfo;

typedef struct {
    int leaf09_delta;
    int core00_delta;
    int core00_sig;
    int branch_k; /* -1 for baseline, 0..4 for --branch k */
} MutConfig;

static PkgInfo g_pkgs[NUM_PKGS];

static void init_pkg_graph(void) {
    int id = 0;
    for (int i = 0; i < NUM_CORE; i++, id++) {
        PkgInfo *p = &g_pkgs[id];
        p->id = id;
        p->layer = LAYER_CORE;
        p->idx = i;
        snprintf(p->name, sizeof(p->name), "core%02d", i);
        p->struct_name = "Packet";
        p->enum_name = "Op";
        p->num_deps = 0;
    }
    for (int i = 0; i < NUM_MID; i++, id++) {
        PkgInfo *p = &g_pkgs[id];
        p->id = id;
        p->layer = LAYER_MID;
        p->idx = i;
        snprintf(p->name, sizeof(p->name), "mid%02d", i);
        p->struct_name = "Frame";
        p->enum_name = "State";
        p->num_deps = 2;
        p->deps[0] = i % NUM_CORE;
        p->deps[1] = (i + 1) % NUM_CORE;
    }
    for (int i = 0; i < NUM_SVC; i++, id++) {
        PkgInfo *p = &g_pkgs[id];
        p->id = id;
        p->layer = LAYER_SVC;
        p->idx = i;
        snprintf(p->name, sizeof(p->name), "svc%02d", i);
        p->struct_name = "Record";
        p->enum_name = "Action";
        p->num_deps = 3;
        p->deps[0] = NUM_CORE + (i % NUM_MID);
        p->deps[1] = NUM_CORE + ((i + 5) % NUM_MID);
        p->deps[2] = i % NUM_CORE;
    }
    for (int i = 0; i < NUM_LEAF; i++, id++) {
        PkgInfo *p = &g_pkgs[id];
        p->id = id;
        p->layer = LAYER_LEAF;
        p->idx = i;
        snprintf(p->name, sizeof(p->name), "leaf%02d", i);
        p->struct_name = "Summary";
        p->enum_name = "Outcome";
        p->num_deps = 2;
        p->deps[0] = NUM_CORE + NUM_MID + i * 2;
        p->deps[1] = NUM_CORE + NUM_MID + i * 2 + 1;
    }
}

static int pkg_depends_on_core00(int id) {
    const PkgInfo *p = &g_pkgs[id];
    for (int d = 0; d < p->num_deps; d++) {
        if (p->deps[d] == 0) return 1;
    }
    return 0;
}

static int pkg_fn00_delta(int id, const MutConfig *cfg) {
    if (cfg->branch_k >= 0) {
        if (id == (NUM_CORE + NUM_MID + NUM_SVC + cfg->branch_k)) {
            return 101 + cfg->branch_k * 7;
        }
        if (id == (NUM_CORE + NUM_MID + cfg->branch_k)) {
            return 211 + cfg->branch_k * 11;
        }
        return 1;
    }
    if (id == NUM_PKGS - 1) return cfg->leaf09_delta;
    if (id == 0) return cfg->core00_delta;
    return 1;
}

static void mkdir_p(const char *path) {
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s", path);
    size_t len = strlen(tmp);
    if (len > 0 && tmp[len - 1] == '/') tmp[len - 1] = '\0';
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
}

static FILE *must_open(const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "error: cannot open %s: %s\n", path, strerror(errno));
        exit(1);
    }
    return f;
}

/* =========================================================================
 * 1. C Generator (50 .h/.c + main.c + exact-dep Makefile)
 * ========================================================================= */
static void emit_c_header(const char *dir, int id, const MutConfig *cfg) {
    const PkgInfo *p = &g_pkgs[id];
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.h", dir, p->name);
    FILE *h = must_open(path);
    fprintf(h, "#ifndef M2BENCH_%s_H\n#define M2BENCH_%s_H\n\n", p->name, p->name);
    fprintf(h, "typedef struct { int a; int b; int tag; } %s_%s;\n", p->name, p->struct_name);
    fprintf(h, "typedef struct { int kind; int x; int y; } %s_%s;\n\n", p->name, p->enum_name);
    if (p->layer == LAYER_CORE) {
        fprintf(h, "%s_%s %s_make_packet(int x);\n", p->name, p->struct_name, p->name);
    }
    if (id == 0 && cfg->core00_sig) {
        fprintf(h, "int %s_entry(int x, int salt);\n", p->name);
    } else {
        fprintf(h, "int %s_entry(int x);\n", p->name);
    }
    fprintf(h, "\n#endif\n");
    fclose(h);
}

static void emit_c_source(const char *dir, int id, const MutConfig *cfg) {
    const PkgInfo *p = &g_pkgs[id];
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.c", dir, p->name);
    FILE *f = must_open(path);

    fprintf(f, "#include \"%s.h\"\n", p->name);
    for (int d = 0; d < p->num_deps; d++) {
        fprintf(f, "#include \"%s.h\"\n", g_pkgs[p->deps[d]].name);
    }
    fprintf(f, "\n");

    fprintf(f, "typedef struct { int tag; int val; } wrap_int_t;\n");
    fprintf(f, "typedef struct { int tag; int val; } wrap_bool_t;\n");
    fprintf(f, "typedef struct { int tag; %s_%s val; } wrap_rec_t;\n\n", p->name, p->struct_name);

    fprintf(f, "static wrap_int_t wrap_tag_int(int v, int tag) { wrap_int_t r = { tag, v }; return r; }\n");
    fprintf(f, "static wrap_bool_t wrap_tag_bool(int v, int tag) { wrap_bool_t r = { tag, v }; return r; }\n");
    fprintf(f, "static wrap_rec_t wrap_tag_rec(%s_%s v, int tag) { wrap_rec_t r = { tag, v }; return r; }\n\n",
            p->name, p->struct_name);

    fprintf(f, "static int eval_op(%s_%s op, int seed) {\n", p->name, p->enum_name);
    fprintf(f, "    if (op.kind == 0) {\n");
    fprintf(f, "        return (op.x + seed + 11) & 0x3fffffff;\n");
    fprintf(f, "    } else if (op.kind == 1) {\n");
    fprintf(f, "        return ((op.x ^ op.y) + seed + 19) & 0x3fffffff;\n");
    fprintf(f, "    } else {\n");
    fprintf(f, "        return ((((op.x & 0x0fffffff) * 3) & 0x3fffffff) + seed + 7) & 0x3fffffff;\n");
    fprintf(f, "    }\n");
    fprintf(f, "}\n\n");

    if (p->layer == LAYER_CORE) {
        fprintf(f, "%s_%s %s_make_packet(int x) {\n", p->name, p->struct_name, p->name);
        fprintf(f, "    int a = (x + %d) & 0x3fffffff;\n", id * 13 + 7);
        fprintf(f, "    int b = (((a & 0x0fffffff) * 3) + %d) & 0x3fffffff;\n", id * 5 + 3);
        fprintf(f, "    %s_%s pkt = { a, b, %d };\n", p->name, p->struct_name, id + 1);
        fprintf(f, "    return pkt;\n");
        fprintf(f, "}\n\n");
    }

    for (int i = 0; i < FNS_PER_PKG; i++) {
        int delta = (i == 0) ? pkg_fn00_delta(id, cfg) : 1;
        int c1 = id * 31 + i + 3;
        int k1 = (i % 5) + 3; /* 3..7 */
        int c2 = id * 17 + i * 3 + 5;
        int t1 = (i % 13) + 1;
        int t2 = (i % 11) + 2;
        int t3 = (i % 7) + 3;

        fprintf(f, "static int %s_fn%02d(int x) {\n", p->name, i);
        fprintf(f, "    int a = ((x & 0x3fffffff) + %d) & 0x3fffffff;\n", c1);
        fprintf(f, "    int b = ((((a & 0x0fffffff) * %d) & 0x3fffffff) ^ %d) & 0x3fffffff;\n", k1, c2);
        fprintf(f, "    int d = %d;\n", delta);
        fprintf(f, "    int c = (b + d) & 0x3fffffff;\n");
        fprintf(f, "    int flag = (a & 1) == 0;\n");
        fprintf(f, "    wrap_int_t wt_i = wrap_tag_int(c, %d);\n", t1);
        fprintf(f, "    wrap_bool_t wt_b = wrap_tag_bool(flag, %d);\n", t2);
        fprintf(f, "    %s_%s rec = { a, b, wt_i.tag };\n", p->name, p->struct_name);
        fprintf(f, "    wrap_rec_t wt_r = wrap_tag_rec(rec, %d);\n", t3);
        fprintf(f, "    %s_%s r2 = wt_r.val;\n", p->name, p->struct_name);
        fprintf(f, "    int g_mix;\n");
        fprintf(f, "    if (wt_b.val) {\n");
        fprintf(f, "        g_mix = (((wt_i.val + r2.a) & 0x3fffffff) + wt_r.tag) & 0x3fffffff;\n");
        fprintf(f, "    } else {\n");
        fprintf(f, "        g_mix = (((wt_i.val + r2.b) & 0x3fffffff) + r2.tag) & 0x3fffffff;\n");
        fprintf(f, "    }\n");
        fprintf(f, "    %s_%s op;\n", p->name, p->enum_name);
        fprintf(f, "    if ((g_mix & 3) == 0) {\n");
        fprintf(f, "        op.kind = 0; op.x = g_mix; op.y = 0;\n");
        fprintf(f, "    } else if ((g_mix & 3) == 1) {\n");
        fprintf(f, "        op.kind = 1; op.x = a; op.y = g_mix;\n");
        fprintf(f, "    } else {\n");
        fprintf(f, "        op.kind = 2; op.x = b; op.y = 0;\n");
        fprintf(f, "    }\n");
        fprintf(f, "    int ev = eval_op(op, c);\n");
        fprintf(f, "    c = (c + ev) & 0x3fffffff;\n");
        if (i > 0) {
            fprintf(f, "    int prev = %s_fn%02d(c & 0xffff);\n", p->name, i - 1);
            fprintf(f, "    c = (c + prev) & 0x3fffffff;\n");
        } else if (p->num_deps > 0) {
            for (int d = 0; d < p->num_deps; d++) {
                const PkgInfo *dp = &g_pkgs[p->deps[d]];
                if (dp->id == 0 && cfg->core00_sig) {
                    fprintf(f, "    int dep%d = %s_entry(c & 0xffff, 29);\n", d, dp->name);
                } else {
                    fprintf(f, "    int dep%d = %s_entry(c & 0xffff);\n", d, dp->name);
                }
                fprintf(f, "    c = (c + dep%d) & 0x3fffffff;\n", d);
                if (dp->layer == LAYER_CORE) {
                    fprintf(f, "    %s_%s dp%d = %s_make_packet(c & 0xffff);\n", dp->name, dp->struct_name, d, dp->name);
                    fprintf(f, "    c = (c + ((dp%d.a + dp%d.b + dp%d.tag) & 0x3fffffff)) & 0x3fffffff;\n", d, d, d);
                }
            }
        } else {
            fprintf(f, "    c = (c + (a >> 2)) & 0x3fffffff;\n");
        }
        fprintf(f, "    int e = ((((c & 0x0fffffff) * 5) & 0x3fffffff) + %d) & 0x3fffffff;\n", i + 1);
        fprintf(f, "    return e;\n");
        fprintf(f, "}\n\n");
    }

    if (id == 0 && cfg->core00_sig) {
        fprintf(f, "int %s_entry(int x, int salt) {\n", p->name);
        fprintf(f, "    return (%s_fn%02d(x) + (salt & 0x3fffffff)) & 0x3fffffff;\n", p->name, FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    } else {
        fprintf(f, "int %s_entry(int x) {\n", p->name);
        fprintf(f, "    return %s_fn%02d(x);\n", p->name, FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    }
    fclose(f);
}

static void gen_c_all(const char *root, const MutConfig *cfg) {
    char dir[1024], path[1024];
    snprintf(dir, sizeof(dir), "%s/c", root);
    mkdir_p(dir);

    for (int id = 0; id < NUM_PKGS; id++) {
        emit_c_header(dir, id, cfg);
        emit_c_source(dir, id, cfg);
    }

    snprintf(path, sizeof(path), "%s/main.c", dir);
    FILE *m = must_open(path);
    fprintf(m, "#include <stdio.h>\n");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(m, "#include \"leaf%02d.h\"\n", i);
    }
    fprintf(m, "\nint main(void) {\n");
    fprintf(m, "    int acc = 42;\n");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(m, "    int r%d = leaf%02d_entry((acc + %d) & 0xffff);\n", i, i, i * 17 + 3);
        fprintf(m, "    acc = ((((acc & 0x0fffffff) * 5) & 0x3fffffff) + r%d) & 0x3fffffff;\n", i);
    }
    fprintf(m, "    printf(\"%%d\\n\", acc);\n");
    fprintf(m, "    return 0;\n");
    fprintf(m, "}\n");
    fclose(m);

    /* Exact header-dependency Makefile */
    snprintf(path, sizeof(path), "%s/Makefile", dir);
    FILE *mk = must_open(path);
    fprintf(mk, "CC = clang\nCFLAGS = -O2\nOBJS =");
    for (int id = 0; id < NUM_PKGS; id++) {
        fprintf(mk, " %s.o", g_pkgs[id].name);
    }
    fprintf(mk, " main.o\n\napp: $(OBJS)\n\t$(CC) $(CFLAGS) -o app $(OBJS)\n\n");
    for (int id = 0; id < NUM_PKGS; id++) {
        const PkgInfo *p = &g_pkgs[id];
        fprintf(mk, "%s.o: %s.c %s.h", p->name, p->name, p->name);
        for (int d = 0; d < p->num_deps; d++) {
            fprintf(mk, " %s.h", g_pkgs[p->deps[d]].name);
        }
        fprintf(mk, "\n\t$(CC) $(CFLAGS) -c %s.c -o %s.o\n", p->name, p->name);
    }
    fprintf(mk, "main.o: main.c");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(mk, " leaf%02d.h", i);
    }
    fprintf(mk, "\n\t$(CC) $(CFLAGS) -c main.c -o main.o\n");
    fclose(mk);
}

/* =========================================================================
 * 2. MoonBit Generator (51 moon.pkg + moon.mod)
 * ========================================================================= */
static void emit_moonbit_pkg(const char *dir, int id, const MutConfig *cfg, int write_manifest) {
    const PkgInfo *p = &g_pkgs[id];
    char pdir[1024], path[1024];
    snprintf(pdir, sizeof(pdir), "%s/src/%s", dir, p->name);
    mkdir_p(pdir);

    if (write_manifest) {
        snprintf(path, sizeof(path), "%s/moon.pkg", pdir);
        FILE *pkg = must_open(path);
        fprintf(pkg, "import {\n");
        for (int d = 0; d < p->num_deps; d++) {
            fprintf(pkg, "  \"bench/scale50k/%s\",\n", g_pkgs[p->deps[d]].name);
        }
        fprintf(pkg, "}\n");
        fclose(pkg);
    }

    snprintf(path, sizeof(path), "%s/lib.mbt", pdir);
    FILE *f = must_open(path);
    fprintf(f, "pub(all) struct %s {\n  a : Int\n  b : Int\n  tag : Int\n}\n\n", p->struct_name);
    fprintf(f, "pub enum %s {\n  Add(Int)\n  Mix(Int, Int)\n  Scale(Int)\n}\n\n", p->enum_name);
    fprintf(f, "fn[T] wrap_tag(v : T, tag : Int) -> (Int, T) {\n  (tag, v)\n}\n\n");
    fprintf(f, "fn eval_op(op : %s, seed : Int) -> Int {\n", p->enum_name);
    fprintf(f, "  match op {\n");
    fprintf(f, "    Add(v) => (v + seed + 11) & 0x3fffffff\n");
    fprintf(f, "    Mix(u, v) => ((u ^ v) + seed + 19) & 0x3fffffff\n");
    fprintf(f, "    Scale(s) => ((((s & 0x0fffffff) * 3) & 0x3fffffff) + seed + 7) & 0x3fffffff\n");
    fprintf(f, "  }\n");
    fprintf(f, "}\n\n");

    if (p->layer == LAYER_CORE) {
        fprintf(f, "pub fn make_packet(x : Int) -> %s {\n", p->struct_name);
        fprintf(f, "  let a = (x + %d) & 0x3fffffff\n", id * 13 + 7);
        fprintf(f, "  let b = (((a & 0x0fffffff) * 3) + %d) & 0x3fffffff\n", id * 5 + 3);
        fprintf(f, "  %s::{ a, b, tag: %d }\n", p->struct_name, id + 1);
        fprintf(f, "}\n\n");
    }

    for (int i = 0; i < FNS_PER_PKG; i++) {
        int delta = (i == 0) ? pkg_fn00_delta(id, cfg) : 1;
        int c1 = id * 31 + i + 3;
        int k1 = (i % 5) + 3;
        int c2 = id * 17 + i * 3 + 5;
        int t1 = (i % 13) + 1;
        int t2 = (i % 11) + 2;
        int t3 = (i % 7) + 3;

        fprintf(f, "fn fn%02d(x : Int) -> Int {\n", i);
        fprintf(f, "  let a = ((x & 0x3fffffff) + %d) & 0x3fffffff\n", c1);
        fprintf(f, "  let b = ((((a & 0x0fffffff) * %d) & 0x3fffffff) ^ %d) & 0x3fffffff\n", k1, c2);
        fprintf(f, "  let d = %d\n", delta);
        fprintf(f, "  let mut c = (b + d) & 0x3fffffff\n");
        fprintf(f, "  let flag = (a & 1) == 0\n");
        fprintf(f, "  let wt_i = wrap_tag(c, %d)\n", t1);
        fprintf(f, "  let wt_b = wrap_tag(flag, %d)\n", t2);
        fprintf(f, "  let rec = %s::{ a, b, tag: wt_i.0 }\n", p->struct_name);
        fprintf(f, "  let wt_r = wrap_tag(rec, %d)\n", t3);
        fprintf(f, "  let r2 = wt_r.1\n");
        fprintf(f, "  let g_mix = if wt_b.1 {\n");
        fprintf(f, "    (((wt_i.1 + r2.a) & 0x3fffffff) + wt_r.0) & 0x3fffffff\n");
        fprintf(f, "  } else {\n");
        fprintf(f, "    (((wt_i.1 + r2.b) & 0x3fffffff) + r2.tag) & 0x3fffffff\n");
        fprintf(f, "  }\n");
        fprintf(f, "  let op = if (g_mix & 3) == 0 {\n");
        fprintf(f, "    Add(g_mix)\n");
        fprintf(f, "  } else if (g_mix & 3) == 1 {\n");
        fprintf(f, "    Mix(a, g_mix)\n");
        fprintf(f, "  } else {\n");
        fprintf(f, "    Scale(b)\n");
        fprintf(f, "  }\n");
        fprintf(f, "  let ev = eval_op(op, c)\n");
        fprintf(f, "  c = (c + ev) & 0x3fffffff\n");
        if (i > 0) {
            fprintf(f, "  let prev = fn%02d(c & 0xffff)\n", i - 1);
            fprintf(f, "  c = (c + prev) & 0x3fffffff\n");
        } else if (p->num_deps > 0) {
            for (int d = 0; d < p->num_deps; d++) {
                const PkgInfo *dp = &g_pkgs[p->deps[d]];
                if (dp->id == 0 && cfg->core00_sig) {
                    fprintf(f, "  let dep%d = @%s.entry(c & 0xffff, 29)\n", d, dp->name);
                } else {
                    fprintf(f, "  let dep%d = @%s.entry(c & 0xffff)\n", d, dp->name);
                }
                fprintf(f, "  c = (c + dep%d) & 0x3fffffff\n", d);
                if (dp->layer == LAYER_CORE) {
                    fprintf(f, "  let dp%d = @%s.make_packet(c & 0xffff)\n", d, dp->name);
                    fprintf(f, "  c = (c + ((dp%d.a + dp%d.b + dp%d.tag) & 0x3fffffff)) & 0x3fffffff\n", d, d, d);
                }
            }
        } else {
            fprintf(f, "  c = (c + (a >> 2)) & 0x3fffffff\n");
        }
        fprintf(f, "  let e = ((((c & 0x0fffffff) * 5) & 0x3fffffff) + %d) & 0x3fffffff\n", i + 1);
        fprintf(f, "  e\n");
        fprintf(f, "}\n\n");
    }

    if (id == 0 && cfg->core00_sig) {
        fprintf(f, "pub fn entry(x : Int, salt : Int) -> Int {\n");
        fprintf(f, "  (fn%02d(x) + (salt & 0x3fffffff)) & 0x3fffffff\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    } else {
        fprintf(f, "pub fn entry(x : Int) -> Int {\n");
        fprintf(f, "  fn%02d(x)\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    }
    fclose(f);
}

static void gen_moonbit_all(const char *root, const MutConfig *cfg) {
    char dir[1024], pdir[1024], path[1024];
    snprintf(dir, sizeof(dir), "%s/moonbit", root);
    mkdir_p(dir);

    snprintf(path, sizeof(path), "%s/moon.mod", dir);
    FILE *mod = must_open(path);
    fprintf(mod, "name = \"bench/scale50k\"\n\nversion = \"0.1.0\"\n\nsource = \"src\"\n\npreferred_target = \"native\"\n");
    fclose(mod);

    for (int id = 0; id < NUM_PKGS; id++) {
        emit_moonbit_pkg(dir, id, cfg, 1);
    }

    snprintf(pdir, sizeof(pdir), "%s/src/app", dir);
    mkdir_p(pdir);
    snprintf(path, sizeof(path), "%s/moon.pkg", pdir);
    FILE *apkg = must_open(path);
    fprintf(apkg, "import {\n");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(apkg, "  \"bench/scale50k/leaf%02d\",\n", i);
    }
    fprintf(apkg, "}\n\noptions(\n  \"is-main\": true,\n)\n");
    fclose(apkg);

    snprintf(path, sizeof(path), "%s/main.mbt", pdir);
    FILE *am = must_open(path);
    fprintf(am, "fn main {\n  let mut acc = 42\n");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(am, "  let r%d = @leaf%02d.entry((acc + %d) & 0xffff)\n", i, i, i * 17 + 3);
        fprintf(am, "  acc = ((((acc & 0x0fffffff) * 5) & 0x3fffffff) + r%d) & 0x3fffffff\n", i);
    }
    fprintf(am, "  println(acc.to_string())\n}\n");
    fclose(am);
}

/* =========================================================================
 * 3. Zig Generator (50 .zig modules + main.zig)
 * ========================================================================= */
static void emit_zig_pkg(const char *dir, int id, const MutConfig *cfg) {
    const PkgInfo *p = &g_pkgs[id];
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.zig", dir, p->name);
    FILE *f = must_open(path);

    for (int d = 0; d < p->num_deps; d++) {
        const PkgInfo *dp = &g_pkgs[p->deps[d]];
        fprintf(f, "const dep_%s = @import(\"%s.zig\");\n", dp->name, dp->name);
    }
    if (p->num_deps > 0) fprintf(f, "\n");

    fprintf(f, "pub const %s = struct { a: i32, b: i32, tag: i32 };\n", p->struct_name);
    fprintf(f, "pub const %s = union(enum) {\n", p->enum_name);
    fprintf(f, "    add: i32,\n");
    fprintf(f, "    mix: struct { u: i32, v: i32 },\n");
    fprintf(f, "    scale: i32,\n");
    fprintf(f, "};\n\n");

    fprintf(f, "fn Tagged(comptime T: type) type {\n");
    fprintf(f, "    return struct { tag: i32, val: T };\n");
    fprintf(f, "}\n\n");
    fprintf(f, "fn wrapTag(comptime T: type, v: T, tag: i32) Tagged(T) {\n");
    fprintf(f, "    return .{ .tag = tag, .val = v };\n");
    fprintf(f, "}\n\n");

    fprintf(f, "fn evalOp(op: %s, seed: i32) i32 {\n", p->enum_name);
    fprintf(f, "    return switch (op) {\n");
    fprintf(f, "        .add => |v| (v +%% seed +%% 11) & 0x3fffffff,\n");
    fprintf(f, "        .mix => |m| ((m.u ^ m.v) +%% seed +%% 19) & 0x3fffffff,\n");
    fprintf(f, "        .scale => |s| ((((s & 0x0fffffff) *%% 3) & 0x3fffffff) +%% seed +%% 7) & 0x3fffffff,\n");
    fprintf(f, "    };\n");
    fprintf(f, "}\n\n");

    if (p->layer == LAYER_CORE) {
        fprintf(f, "pub fn makePacket(x: i32) %s {\n", p->struct_name);
        fprintf(f, "    const a: i32 = (x +%% %d) & 0x3fffffff;\n", id * 13 + 7);
        fprintf(f, "    const b: i32 = (((a & 0x0fffffff) *%% 3) +%% %d) & 0x3fffffff;\n", id * 5 + 3);
        fprintf(f, "    return .{ .a = a, .b = b, .tag = %d };\n", id + 1);
        fprintf(f, "}\n\n");
    }

    for (int i = 0; i < FNS_PER_PKG; i++) {
        int delta = (i == 0) ? pkg_fn00_delta(id, cfg) : 1;
        int c1 = id * 31 + i + 3;
        int k1 = (i % 5) + 3;
        int c2 = id * 17 + i * 3 + 5;
        int t1 = (i % 13) + 1;
        int t2 = (i % 11) + 2;
        int t3 = (i % 7) + 3;

        fprintf(f, "fn fn%02d(x: i32) i32 {\n", i);
        fprintf(f, "    const a: i32 = ((x & 0x3fffffff) +%% %d) & 0x3fffffff;\n", c1);
        fprintf(f, "    const b: i32 = ((((a & 0x0fffffff) *%% %d) & 0x3fffffff) ^ %d) & 0x3fffffff;\n", k1, c2);
        fprintf(f, "    const d: i32 = %d;\n", delta);
        fprintf(f, "    var c: i32 = (b +%% d) & 0x3fffffff;\n");
        fprintf(f, "    const flag: bool = (a & 1) == 0;\n");
        fprintf(f, "    const wt_i = wrapTag(i32, c, %d);\n", t1);
        fprintf(f, "    const wt_b = wrapTag(bool, flag, %d);\n", t2);
        fprintf(f, "    const rec: %s = .{ .a = a, .b = b, .tag = wt_i.tag };\n", p->struct_name);
        fprintf(f, "    const wt_r = wrapTag(%s, rec, %d);\n", p->struct_name, t3);
        fprintf(f, "    const r2 = wt_r.val;\n");
        fprintf(f, "    const g_mix: i32 = if (wt_b.val)\n");
        fprintf(f, "        (((wt_i.val +%% r2.a) & 0x3fffffff) +%% wt_r.tag) & 0x3fffffff\n");
        fprintf(f, "    else\n");
        fprintf(f, "        (((wt_i.val +%% r2.b) & 0x3fffffff) +%% r2.tag) & 0x3fffffff;\n");
        fprintf(f, "    const op: %s = if ((g_mix & 3) == 0)\n", p->enum_name);
        fprintf(f, "        .{ .add = g_mix }\n");
        fprintf(f, "    else if ((g_mix & 3) == 1)\n");
        fprintf(f, "        .{ .mix = .{ .u = a, .v = g_mix } }\n");
        fprintf(f, "    else\n");
        fprintf(f, "        .{ .scale = b };\n");
        fprintf(f, "    const ev: i32 = evalOp(op, c);\n");
        fprintf(f, "    c = (c +%% ev) & 0x3fffffff;\n");
        if (i > 0) {
            fprintf(f, "    const prev: i32 = fn%02d(c & 0xffff);\n", i - 1);
            fprintf(f, "    c = (c +%% prev) & 0x3fffffff;\n");
        } else if (p->num_deps > 0) {
            for (int d = 0; d < p->num_deps; d++) {
                const PkgInfo *dp = &g_pkgs[p->deps[d]];
                if (dp->id == 0 && cfg->core00_sig) {
                    fprintf(f, "    const dep%d: i32 = dep_%s.entry(c & 0xffff, 29);\n", d, dp->name);
                } else {
                    fprintf(f, "    const dep%d: i32 = dep_%s.entry(c & 0xffff);\n", d, dp->name);
                }
                fprintf(f, "    c = (c +%% dep%d) & 0x3fffffff;\n", d);
                if (dp->layer == LAYER_CORE) {
                    fprintf(f, "    const dp%d = dep_%s.makePacket(c & 0xffff);\n", d, dp->name);
                    fprintf(f, "    c = (c +%% ((dp%d.a +%% dp%d.b +%% dp%d.tag) & 0x3fffffff)) & 0x3fffffff;\n", d, d, d);
                }
            }
        } else {
            fprintf(f, "    c = (c +%% (a >> 2)) & 0x3fffffff;\n");
        }
        fprintf(f, "    const e: i32 = ((((c & 0x0fffffff) *%% 5) & 0x3fffffff) +%% %d) & 0x3fffffff;\n", i + 1);
        fprintf(f, "    return e;\n");
        fprintf(f, "}\n\n");
    }

    if (id == 0 && cfg->core00_sig) {
        fprintf(f, "pub fn entry(x: i32, salt: i32) i32 {\n");
        fprintf(f, "    return (fn%02d(x) +%% (salt & 0x3fffffff)) & 0x3fffffff;\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    } else {
        fprintf(f, "pub fn entry(x: i32) i32 {\n");
        fprintf(f, "    return fn%02d(x);\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    }
    fclose(f);
}

static void gen_zig_all(const char *root, const MutConfig *cfg) {
    char dir[1024], path[1024];
    snprintf(dir, sizeof(dir), "%s/zig", root);
    mkdir_p(dir);

    for (int id = 0; id < NUM_PKGS; id++) {
        emit_zig_pkg(dir, id, cfg);
    }

    snprintf(path, sizeof(path), "%s/main.zig", dir);
    FILE *m = must_open(path);
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(m, "const leaf%02d = @import(\"leaf%02d.zig\");\n", i, i);
    }
    fprintf(m, "extern \"c\" fn printf(fmt: [*:0]const u8, ...) c_int;\n\n");
    fprintf(m, "pub fn main() void {\n");
    fprintf(m, "    var acc: i32 = 42;\n");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(m, "    const r%d: i32 = leaf%02d.entry((acc +%% %d) & 0xffff);\n", i, i, i * 17 + 3);
        fprintf(m, "    acc = ((((acc & 0x0fffffff) *%% 5) & 0x3fffffff) +%% r%d) & 0x3fffffff;\n", i);
    }
    fprintf(m, "    _ = printf(\"%%d\\n\", acc);\n");
    fprintf(m, "}\n");
    fclose(m);
}

/* =========================================================================
 * 4. Rust Generator (Cargo Workspace: 50 lib crates + app bin crate)
 * ========================================================================= */
static void emit_rust_pkg(const char *dir, int id, const MutConfig *cfg, int write_manifest) {
    const PkgInfo *p = &g_pkgs[id];
    char cdir[1024], path[1024];
    snprintf(cdir, sizeof(cdir), "%s/%s/src", dir, p->name);
    mkdir_p(cdir);

    if (write_manifest) {
        snprintf(path, sizeof(path), "%s/%s/Cargo.toml", dir, p->name);
        FILE *ct = must_open(path);
        fprintf(ct, "[package]\nname = \"%s\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n", p->name);
        for (int d = 0; d < p->num_deps; d++) {
            const PkgInfo *dp = &g_pkgs[p->deps[d]];
            fprintf(ct, "%s = { path = \"../%s\" }\n", dp->name, dp->name);
        }
        fclose(ct);
    }

    snprintf(path, sizeof(path), "%s/lib.rs", cdir);
    FILE *f = must_open(path);
    fprintf(f, "#[derive(Copy, Clone)]\npub struct %s {\n    pub a: i32,\n    pub b: i32,\n    pub tag: i32,\n}\n\n", p->struct_name);
    fprintf(f, "pub enum %s {\n    Add(i32),\n    Mix(i32, i32),\n    Scale(i32),\n}\n\n", p->enum_name);
    fprintf(f, "fn wrap_tag<T>(v: T, tag: i32) -> (i32, T) {\n    (tag, v)\n}\n\n");
    fprintf(f, "fn eval_op(op: %s, seed: i32) -> i32 {\n", p->enum_name);
    fprintf(f, "    match op {\n");
    fprintf(f, "        %s::Add(v) => v.wrapping_add(seed).wrapping_add(11) & 0x3fffffff,\n", p->enum_name);
    fprintf(f, "        %s::Mix(u, v) => (u ^ v).wrapping_add(seed).wrapping_add(19) & 0x3fffffff,\n", p->enum_name);
    fprintf(f, "        %s::Scale(s) => ((s & 0x0fffffff).wrapping_mul(3) & 0x3fffffff).wrapping_add(seed).wrapping_add(7) & 0x3fffffff,\n", p->enum_name);
    fprintf(f, "    }\n");
    fprintf(f, "}\n\n");

    if (p->layer == LAYER_CORE) {
        fprintf(f, "pub fn make_packet(x: i32) -> %s {\n", p->struct_name);
        fprintf(f, "    let a = x.wrapping_add(%d) & 0x3fffffff;\n", id * 13 + 7);
        fprintf(f, "    let b = (a & 0x0fffffff).wrapping_mul(3).wrapping_add(%d) & 0x3fffffff;\n", id * 5 + 3);
        fprintf(f, "    %s { a, b, tag: %d }\n", p->struct_name, id + 1);
        fprintf(f, "}\n\n");
    }

    for (int i = 0; i < FNS_PER_PKG; i++) {
        int delta = (i == 0) ? pkg_fn00_delta(id, cfg) : 1;
        int c1 = id * 31 + i + 3;
        int k1 = (i % 5) + 3;
        int c2 = id * 17 + i * 3 + 5;
        int t1 = (i % 13) + 1;
        int t2 = (i % 11) + 2;
        int t3 = (i % 7) + 3;

        fprintf(f, "fn fn%02d(x: i32) -> i32 {\n", i);
        fprintf(f, "    let a = (x & 0x3fffffff).wrapping_add(%d) & 0x3fffffff;\n", c1);
        fprintf(f, "    let b = (((a & 0x0fffffff).wrapping_mul(%d) & 0x3fffffff) ^ %d) & 0x3fffffff;\n", k1, c2);
        fprintf(f, "    let d = %d;\n", delta);
        fprintf(f, "    let mut c = b.wrapping_add(d) & 0x3fffffff;\n");
        fprintf(f, "    let flag = (a & 1) == 0;\n");
        fprintf(f, "    let wt_i = wrap_tag(c, %d);\n", t1);
        fprintf(f, "    let wt_b = wrap_tag(flag, %d);\n", t2);
        fprintf(f, "    let rec = %s { a, b, tag: wt_i.0 };\n", p->struct_name);
        fprintf(f, "    let wt_r = wrap_tag(rec, %d);\n", t3);
        fprintf(f, "    let r2 = wt_r.1;\n");
        fprintf(f, "    let g_mix = if wt_b.1 {\n");
        fprintf(f, "        (wt_i.1.wrapping_add(r2.a) & 0x3fffffff).wrapping_add(wt_r.0) & 0x3fffffff\n");
        fprintf(f, "    } else {\n");
        fprintf(f, "        (wt_i.1.wrapping_add(r2.b) & 0x3fffffff).wrapping_add(r2.tag) & 0x3fffffff\n");
        fprintf(f, "    };\n");
        fprintf(f, "    let op = if (g_mix & 3) == 0 {\n");
        fprintf(f, "        %s::Add(g_mix)\n", p->enum_name);
        fprintf(f, "    } else if (g_mix & 3) == 1 {\n");
        fprintf(f, "        %s::Mix(a, g_mix)\n", p->enum_name);
        fprintf(f, "    } else {\n");
        fprintf(f, "        %s::Scale(b)\n", p->enum_name);
        fprintf(f, "    };\n");
        fprintf(f, "    let ev = eval_op(op, c);\n");
        fprintf(f, "    c = c.wrapping_add(ev) & 0x3fffffff;\n");
        if (i > 0) {
            fprintf(f, "    let prev = fn%02d(c & 0xffff);\n", i - 1);
            fprintf(f, "    c = c.wrapping_add(prev) & 0x3fffffff;\n");
        } else if (p->num_deps > 0) {
            for (int d = 0; d < p->num_deps; d++) {
                const PkgInfo *dp = &g_pkgs[p->deps[d]];
                if (dp->id == 0 && cfg->core00_sig) {
                    fprintf(f, "    let dep%d = %s::entry(c & 0xffff, 29);\n", d, dp->name);
                } else {
                    fprintf(f, "    let dep%d = %s::entry(c & 0xffff);\n", d, dp->name);
                }
                fprintf(f, "    c = c.wrapping_add(dep%d) & 0x3fffffff;\n", d);
                if (dp->layer == LAYER_CORE) {
                    fprintf(f, "    let dp%d = %s::make_packet(c & 0xffff);\n", d, dp->name);
                    fprintf(f, "    c = c.wrapping_add(dp%d.a.wrapping_add(dp%d.b).wrapping_add(dp%d.tag) & 0x3fffffff) & 0x3fffffff;\n", d, d, d);
                }
            }
        } else {
            fprintf(f, "    c = c.wrapping_add(a >> 2) & 0x3fffffff;\n");
        }
        fprintf(f, "    let e = ((c & 0x0fffffff).wrapping_mul(5) & 0x3fffffff).wrapping_add(%d) & 0x3fffffff;\n", i + 1);
        fprintf(f, "    e\n");
        fprintf(f, "}\n\n");
    }

    if (id == 0 && cfg->core00_sig) {
        fprintf(f, "pub fn entry(x: i32, salt: i32) -> i32 {\n");
        fprintf(f, "    fn%02d(x).wrapping_add(salt & 0x3fffffff) & 0x3fffffff\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    } else {
        fprintf(f, "pub fn entry(x: i32) -> i32 {\n");
        fprintf(f, "    fn%02d(x)\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    }
    fclose(f);
}

static void gen_rust_all(const char *root, const MutConfig *cfg) {
    char dir[1024], cdir[1024], path[1024];
    snprintf(dir, sizeof(dir), "%s/rust", root);
    mkdir_p(dir);

    snprintf(path, sizeof(path), "%s/Cargo.toml", dir);
    FILE *ws = must_open(path);
    fprintf(ws, "[workspace]\nresolver = \"2\"\nmembers = [\n");
    for (int id = 0; id < NUM_PKGS; id++) {
        fprintf(ws, "    \"%s\",\n", g_pkgs[id].name);
    }
    fprintf(ws, "    \"app\",\n]\n");
    fclose(ws);

    for (int id = 0; id < NUM_PKGS; id++) {
        emit_rust_pkg(dir, id, cfg, 1);
    }

    snprintf(cdir, sizeof(cdir), "%s/app/src", dir);
    mkdir_p(cdir);
    snprintf(path, sizeof(path), "%s/app/Cargo.toml", dir);
    FILE *at = must_open(path);
    fprintf(at, "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(at, "leaf%02d = { path = \"../leaf%02d\" }\n", i, i);
    }
    fclose(at);

    snprintf(path, sizeof(path), "%s/main.rs", cdir);
    FILE *am = must_open(path);
    fprintf(am, "fn main() {\n    let mut acc: i32 = 42;\n");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(am, "    let r%d = leaf%02d::entry(acc.wrapping_add(%d) & 0xffff);\n", i, i, i * 17 + 3);
        fprintf(am, "    acc = ((acc & 0x0fffffff).wrapping_mul(5) & 0x3fffffff).wrapping_add(r%d) & 0x3fffffff;\n", i);
    }
    fprintf(am, "    println!(\"{}\", acc);\n}\n");
    fclose(am);
}

/* =========================================================================
 * 5. Go Generator (go.mod + 50 packages + cmd/app/main.go)
 * ========================================================================= */
static void emit_go_pkg(const char *dir, int id, const MutConfig *cfg) {
    const PkgInfo *p = &g_pkgs[id];
    char pdir[1024], path[1024];
    snprintf(pdir, sizeof(pdir), "%s/%s", dir, p->name);
    mkdir_p(pdir);

    snprintf(path, sizeof(path), "%s/%s.go", pdir, p->name);
    FILE *f = must_open(path);
    fprintf(f, "package %s\n\n", p->name);
    if (p->num_deps > 0) {
        fprintf(f, "import (\n");
        for (int d = 0; d < p->num_deps; d++) {
            fprintf(f, "\t\"bench/scale50k/%s\"\n", g_pkgs[p->deps[d]].name);
        }
        fprintf(f, ")\n\n");
    }

    fprintf(f, "type %s struct {\n\tA   int32\n\tB   int32\n\tTag int32\n}\n\n", p->struct_name);
    fprintf(f, "type %s struct {\n\tKind int32\n\tX    int32\n\tY    int32\n}\n\n", p->enum_name);
    fprintf(f, "type tagged[T any] struct {\n\ttag int32\n\tval T\n}\n\n");
    fprintf(f, "func wrapTag[T any](v T, tag int32) tagged[T] {\n\treturn tagged[T]{tag: tag, val: v}\n}\n\n");

    fprintf(f, "func evalOp(op %s, seed int32) int32 {\n", p->enum_name);
    fprintf(f, "\tswitch op.Kind {\n");
    fprintf(f, "\tcase 0:\n\t\treturn (op.X + seed + 11) & 0x3fffffff\n");
    fprintf(f, "\tcase 1:\n\t\treturn ((op.X ^ op.Y) + seed + 19) & 0x3fffffff\n");
    fprintf(f, "\tdefault:\n\t\treturn ((((op.X & 0x0fffffff) * 3) & 0x3fffffff) + seed + 7) & 0x3fffffff\n");
    fprintf(f, "\t}\n}\n\n");

    if (p->layer == LAYER_CORE) {
        fprintf(f, "func MakePacket(x int32) %s {\n", p->struct_name);
        fprintf(f, "\ta := (x + %d) & 0x3fffffff\n", id * 13 + 7);
        fprintf(f, "\tb := (((a & 0x0fffffff) * 3) + %d) & 0x3fffffff\n", id * 5 + 3);
        fprintf(f, "\treturn %s{A: a, B: b, Tag: %d}\n", p->struct_name, id + 1);
        fprintf(f, "}\n\n");
    }

    for (int i = 0; i < FNS_PER_PKG; i++) {
        int delta = (i == 0) ? pkg_fn00_delta(id, cfg) : 1;
        int c1 = id * 31 + i + 3;
        int k1 = (i % 5) + 3;
        int c2 = id * 17 + i * 3 + 5;
        int t1 = (i % 13) + 1;
        int t2 = (i % 11) + 2;
        int t3 = (i % 7) + 3;

        fprintf(f, "func fn%02d(x int32) int32 {\n", i);
        fprintf(f, "\ta := ((x & 0x3fffffff) + %d) & 0x3fffffff\n", c1);
        fprintf(f, "\tb := ((((a & 0x0fffffff) * %d) & 0x3fffffff) ^ %d) & 0x3fffffff\n", k1, c2);
        fprintf(f, "\td := int32(%d)\n", delta);
        fprintf(f, "\tc := (b + d) & 0x3fffffff\n");
        fprintf(f, "\tflag := (a & 1) == 0\n");
        fprintf(f, "\twtI := wrapTag(c, %d)\n", t1);
        fprintf(f, "\twtB := wrapTag(flag, %d)\n", t2);
        fprintf(f, "\trec := %s{A: a, B: b, Tag: wtI.tag}\n", p->struct_name);
        fprintf(f, "\twtR := wrapTag(rec, %d)\n", t3);
        fprintf(f, "\tr2 := wtR.val\n");
        fprintf(f, "\tvar gMix int32\n");
        fprintf(f, "\tif wtB.val {\n");
        fprintf(f, "\t\tgMix = (((wtI.val + r2.A) & 0x3fffffff) + wtR.tag) & 0x3fffffff\n");
        fprintf(f, "\t} else {\n");
        fprintf(f, "\t\tgMix = (((wtI.val + r2.B) & 0x3fffffff) + r2.Tag) & 0x3fffffff\n");
        fprintf(f, "\t}\n");
        fprintf(f, "\tvar op %s\n", p->enum_name);
        fprintf(f, "\tif (gMix & 3) == 0 {\n");
        fprintf(f, "\t\top = %s{Kind: 0, X: gMix, Y: 0}\n", p->enum_name);
        fprintf(f, "\t} else if (gMix & 3) == 1 {\n");
        fprintf(f, "\t\top = %s{Kind: 1, X: a, Y: gMix}\n", p->enum_name);
        fprintf(f, "\t} else {\n");
        fprintf(f, "\t\top = %s{Kind: 2, X: b, Y: 0}\n", p->enum_name);
        fprintf(f, "\t}\n");
        fprintf(f, "\tev := evalOp(op, c)\n");
        fprintf(f, "\tc = (c + ev) & 0x3fffffff\n");
        if (i > 0) {
            fprintf(f, "\tprev := fn%02d(c & 0xffff)\n", i - 1);
            fprintf(f, "\tc = (c + prev) & 0x3fffffff\n");
        } else if (p->num_deps > 0) {
            for (int d = 0; d < p->num_deps; d++) {
                const PkgInfo *dp = &g_pkgs[p->deps[d]];
                if (dp->id == 0 && cfg->core00_sig) {
                    fprintf(f, "\tdep%d := %s.Entry(c & 0xffff, 29)\n", d, dp->name);
                } else {
                    fprintf(f, "\tdep%d := %s.Entry(c & 0xffff)\n", d, dp->name);
                }
                fprintf(f, "\tc = (c + dep%d) & 0x3fffffff\n", d);
                if (dp->layer == LAYER_CORE) {
                    fprintf(f, "\tdp%d := %s.MakePacket(c & 0xffff)\n", d, dp->name);
                    fprintf(f, "\tc = (c + ((dp%d.A + dp%d.B + dp%d.Tag) & 0x3fffffff)) & 0x3fffffff\n", d, d, d);
                }
            }
        } else {
            fprintf(f, "\tc = (c + (a >> 2)) & 0x3fffffff\n");
        }
        fprintf(f, "\te := ((((c & 0x0fffffff) * 5) & 0x3fffffff) + %d) & 0x3fffffff\n", i + 1);
        fprintf(f, "\treturn e\n}\n\n");
    }

    if (id == 0 && cfg->core00_sig) {
        fprintf(f, "func Entry(x int32, salt int32) int32 {\n");
        fprintf(f, "\treturn (fn%02d(x) + (salt & 0x3fffffff)) & 0x3fffffff\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    } else {
        fprintf(f, "func Entry(x int32) int32 {\n");
        fprintf(f, "\treturn fn%02d(x)\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    }
    fclose(f);
}

static void gen_go_all(const char *root, const MutConfig *cfg) {
    char dir[1024], adir[1024], path[1024];
    snprintf(dir, sizeof(dir), "%s/go", root);
    mkdir_p(dir);

    snprintf(path, sizeof(path), "%s/go.mod", dir);
    FILE *gm = must_open(path);
    fprintf(gm, "module bench/scale50k\n\ngo 1.24\n");
    fclose(gm);

    for (int id = 0; id < NUM_PKGS; id++) {
        emit_go_pkg(dir, id, cfg);
    }

    snprintf(adir, sizeof(adir), "%s/cmd/app", dir);
    mkdir_p(adir);
    snprintf(path, sizeof(path), "%s/main.go", adir);
    FILE *am = must_open(path);
    fprintf(am, "package main\n\nimport (\n\t\"fmt\"\n");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(am, "\t\"bench/scale50k/leaf%02d\"\n", i);
    }
    fprintf(am, ")\n\nfunc main() {\n\tvar acc int32 = 42\n");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(am, "\tr%d := leaf%02d.Entry((acc + %d) & 0xffff)\n", i, i, i * 17 + 3);
        fprintf(am, "\tacc = ((((acc & 0x0fffffff) * 5) & 0x3fffffff) + r%d) & 0x3fffffff\n", i);
    }
    fprintf(am, "\tfmt.Println(acc)\n}\n");
    fclose(am);
}

/* =========================================================================
 * 6. m2 Generator (51 real m2.toml packages + import "pkg" as alias)
 * ========================================================================= */
static void emit_m2_pkg(const char *dir, int id, const MutConfig *cfg, int write_manifest) {
    const PkgInfo *p = &g_pkgs[id];
    char pdir[1024], sdir[1024], path[1024];
    snprintf(pdir, sizeof(pdir), "%s/%s", dir, p->name);
    snprintf(sdir, sizeof(sdir), "%s/src", pdir);
    mkdir_p(sdir);

    if (write_manifest) {
        snprintf(path, sizeof(path), "%s/m2.toml", pdir);
        FILE *mf = must_open(path);
        fprintf(mf, "[package]\nname = \"%s\"\nversion = \"0.1.0\"\n", p->name);
        if (p->num_deps > 0) {
            fprintf(mf, "\n[dependencies]\n");
            for (int d = 0; d < p->num_deps; d++) {
                const PkgInfo *dp = &g_pkgs[p->deps[d]];
                fprintf(mf, "%s = { path = \"../%s\" }\n", dp->name, dp->name);
            }
        }
        fclose(mf);
    }

    snprintf(path, sizeof(path), "%s/%s.m2", sdir, p->name);
    FILE *f = must_open(path);
    for (int d = 0; d < p->num_deps; d++) {
        const PkgInfo *dp = &g_pkgs[p->deps[d]];
        fprintf(f, "import \"%s\" as %s\n", dp->name, dp->name);
    }
    if (p->num_deps > 0) fprintf(f, "\n");

    fprintf(f, "pub val struct %s {\n  a : Int\n  b : Int\n  tag : Int\n}\n\n", p->struct_name);
    fprintf(f, "pub enum %s {\n  Add(Int)\n  Mix(Int, Int)\n  Scale(Int)\n}\n\n", p->enum_name);
    fprintf(f, "fn wrap_tag[T](v : T, tag : Int) -> (Int, T) {\n  (tag, v)\n}\n\n");
    fprintf(f, "fn eval_op(op : %s, seed : Int) -> Int {\n", p->enum_name);
    fprintf(f, "  match op {\n");
    fprintf(f, "    Add(v) => (v + seed + 11) & 0x3fffffff\n");
    fprintf(f, "    Mix(u, v) => ((u ^ v) + seed + 19) & 0x3fffffff\n");
    fprintf(f, "    Scale(s) => ((((s & 0x0fffffff) * 3) & 0x3fffffff) + seed + 7) & 0x3fffffff\n");
    fprintf(f, "  }\n");
    fprintf(f, "}\n\n");

    if (p->layer == LAYER_CORE) {
        fprintf(f, "pub fn make_packet(x : Int) -> %s {\n", p->struct_name);
        fprintf(f, "  let a = (x + %d) & 0x3fffffff\n", id * 13 + 7);
        fprintf(f, "  let b = (((a & 0x0fffffff) * 3) + %d) & 0x3fffffff\n", id * 5 + 3);
        fprintf(f, "  %s::{ a: a, b: b, tag: %d }\n", p->struct_name, id + 1);
        fprintf(f, "}\n\n");
    }

    for (int i = 0; i < FNS_PER_PKG; i++) {
        int delta = (i == 0) ? pkg_fn00_delta(id, cfg) : 1;
        int c1 = id * 31 + i + 3;
        int k1 = (i % 5) + 3;
        int c2 = id * 17 + i * 3 + 5;
        int t1 = (i % 13) + 1;
        int t2 = (i % 11) + 2;
        int t3 = (i % 7) + 3;

        fprintf(f, "fn fn%02d(x : Int) -> Int {\n", i);
        fprintf(f, "  let a = ((x & 0x3fffffff) + %d) & 0x3fffffff\n", c1);
        fprintf(f, "  let b = ((((a & 0x0fffffff) * %d) & 0x3fffffff) ^ %d) & 0x3fffffff\n", k1, c2);
        fprintf(f, "  let d = %d\n", delta);
        fprintf(f, "  let mut c = (b + d) & 0x3fffffff\n");
        fprintf(f, "  let flag = (a & 1) == 0\n");
        fprintf(f, "  let wt_i = wrap_tag(c, %d)\n", t1);
        fprintf(f, "  let wt_b = wrap_tag(flag, %d)\n", t2);
        fprintf(f, "  let rec = %s::{ a: a, b: b, tag: wt_i.0 }\n", p->struct_name);
        fprintf(f, "  let wt_r = wrap_tag(rec, %d)\n", t3);
        fprintf(f, "  let r2 = wt_r.1\n");
        fprintf(f, "  let g_mix = if wt_b.1 {\n");
        fprintf(f, "    (((wt_i.1 + r2.a) & 0x3fffffff) + wt_r.0) & 0x3fffffff\n");
        fprintf(f, "  } else {\n");
        fprintf(f, "    (((wt_i.1 + r2.b) & 0x3fffffff) + r2.tag) & 0x3fffffff\n");
        fprintf(f, "  }\n");
        fprintf(f, "  let op = if (g_mix & 3) == 0 {\n");
        fprintf(f, "    Add(g_mix)\n");
        fprintf(f, "  } else if (g_mix & 3) == 1 {\n");
        fprintf(f, "    Mix(a, g_mix)\n");
        fprintf(f, "  } else {\n");
        fprintf(f, "    Scale(b)\n");
        fprintf(f, "  }\n");
        fprintf(f, "  let ev = eval_op(op, c)\n");
        fprintf(f, "  c = (c + ev) & 0x3fffffff\n");
        if (i > 0) {
            fprintf(f, "  let prev = fn%02d(c & 0xffff)\n", i - 1);
            fprintf(f, "  c = (c + prev) & 0x3fffffff\n");
        } else if (p->num_deps > 0) {
            for (int d = 0; d < p->num_deps; d++) {
                const PkgInfo *dp = &g_pkgs[p->deps[d]];
                if (dp->id == 0 && cfg->core00_sig) {
                    fprintf(f, "  let dep%d = %s::entry(c & 0xffff, 29)\n", d, dp->name);
                } else {
                    fprintf(f, "  let dep%d = %s::entry(c & 0xffff)\n", d, dp->name);
                }
                fprintf(f, "  c = (c + dep%d) & 0x3fffffff\n", d);
                if (dp->layer == LAYER_CORE) {
                    fprintf(f, "  let dp%d = %s::make_packet(c & 0xffff)\n", d, dp->name);
                    fprintf(f, "  c = (c + ((dp%d.a + dp%d.b + dp%d.tag) & 0x3fffffff)) & 0x3fffffff\n", d, d, d);
                }
            }
        } else {
            fprintf(f, "  c = (c + (a >> 2)) & 0x3fffffff\n");
        }
        fprintf(f, "  let e = ((((c & 0x0fffffff) * 5) & 0x3fffffff) + %d) & 0x3fffffff\n", i + 1);
        fprintf(f, "  e\n");
        fprintf(f, "}\n\n");
    }

    if (id == 0 && cfg->core00_sig) {
        fprintf(f, "pub fn entry(x : Int, salt : Int) -> Int {\n");
        fprintf(f, "  (fn%02d(x) + (salt & 0x3fffffff)) & 0x3fffffff\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    } else {
        fprintf(f, "pub fn entry(x : Int) -> Int {\n");
        fprintf(f, "  fn%02d(x)\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
    }
    fclose(f);
}

static void gen_m2_all(const char *root, const MutConfig *cfg) {
    char dir[1024], adir[1024], sdir[1024], path[1024];
    snprintf(dir, sizeof(dir), "%s/m2", root);
    mkdir_p(dir);

    for (int id = 0; id < NUM_PKGS; id++) {
        emit_m2_pkg(dir, id, cfg, 1);
    }

    snprintf(adir, sizeof(adir), "%s/app", dir);
    snprintf(sdir, sizeof(sdir), "%s/src", adir);
    mkdir_p(sdir);

    snprintf(path, sizeof(path), "%s/m2.toml", adir);
    FILE *mf = must_open(path);
    fprintf(mf, "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\n");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(mf, "leaf%02d = { path = \"../leaf%02d\" }\n", i, i);
    }
    fclose(mf);

    snprintf(path, sizeof(path), "%s/main.m2", sdir);
    FILE *am = must_open(path);
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(am, "import \"leaf%02d\" as leaf%02d\n", i, i);
    }
    fprintf(am, "\npub fn main(world : World) -> Int {\n");
    fprintf(am, "  let mut acc = 42\n");
    for (int i = 0; i < NUM_LEAF; i++) {
        fprintf(am, "  let r%d = leaf%02d::entry((acc + %d) & 0xffff)\n", i, i, i * 17 + 3);
        fprintf(am, "  acc = ((((acc & 0x0fffffff) * 5) & 0x3fffffff) + r%d) & 0x3fffffff\n", i);
    }
    fprintf(am, "  io_println(world, acc.to_string())\n");
    fprintf(am, "  0\n");
    fprintf(am, "}\n");
    fclose(am);
}

static void gen_all_langs(const char *root, const MutConfig *cfg) {
    mkdir_p(root);
    gen_c_all(root, cfg);
    gen_moonbit_all(root, cfg);
    gen_zig_all(root, cfg);
    gen_rust_all(root, cfg);
    gen_go_all(root, cfg);
    gen_m2_all(root, cfg);
}

static void rewrite_pkg_source_all_langs(const char *root, int id, const MutConfig *cfg, int rewrite_c_header) {
    char dir[1024];
    snprintf(dir, sizeof(dir), "%s/c", root);
    if (rewrite_c_header) emit_c_header(dir, id, cfg);
    emit_c_source(dir, id, cfg);

    snprintf(dir, sizeof(dir), "%s/moonbit", root);
    emit_moonbit_pkg(dir, id, cfg, 0);

    snprintf(dir, sizeof(dir), "%s/zig", root);
    emit_zig_pkg(dir, id, cfg);

    snprintf(dir, sizeof(dir), "%s/rust", root);
    emit_rust_pkg(dir, id, cfg, 0);

    snprintf(dir, sizeof(dir), "%s/go", root);
    emit_go_pkg(dir, id, cfg);

    snprintf(dir, sizeof(dir), "%s/m2", root);
    emit_m2_pkg(dir, id, cfg, 0);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
                "usage: %s <out_dir> [--mutate-leaf-body | --mutate-core-body | --mutate-core-sig | --branch <0..4>]\n",
                argv[0]);
        return 2;
    }
    init_pkg_graph();

    const char *root = argv[1];
    MutConfig cfg = { 1, 1, 0, -1 };

    if (argc == 2) {
        gen_all_langs(root, &cfg);
        return 0;
    }

    if (strcmp(argv[2], "--mutate-leaf-body") == 0) {
        cfg.leaf09_delta = 7;
        rewrite_pkg_source_all_langs(root, NUM_PKGS - 1, &cfg, 0);
        return 0;
    }

    if (strcmp(argv[2], "--mutate-core-body") == 0) {
        cfg.core00_delta = 13;
        rewrite_pkg_source_all_langs(root, 0, &cfg, 0);
        return 0;
    }

    if (strcmp(argv[2], "--mutate-core-sig") == 0) {
        cfg.core00_delta = 13;
        cfg.core00_sig = 1;
        /* Rewrite core00 (including C header) + all direct callers of core00_entry only */
        rewrite_pkg_source_all_langs(root, 0, &cfg, 1);
        for (int id = 1; id < NUM_PKGS; id++) {
            if (pkg_depends_on_core00(id)) {
                rewrite_pkg_source_all_langs(root, id, &cfg, 0);
            }
        }
        return 0;
    }

    if (strcmp(argv[2], "--branch") == 0) {
        if (argc < 4) {
            fprintf(stderr, "error: --branch requires <k> in 0..4\n");
            return 2;
        }
        int k = atoi(argv[3]);
        if (k < 0 || k > 4) {
            fprintf(stderr, "error: --branch k must be 0..4, got %d\n", k);
            return 2;
        }
        cfg.branch_k = k;
        char wt_dir[1024];
        snprintf(wt_dir, sizeof(wt_dir), "%s/wt%d", root, k);
        gen_all_langs(wt_dir, &cfg);
        return 0;
    }

    fprintf(stderr, "error: unknown mode '%s'\n", argv[2]);
    return 2;
}
