/*
 * Deterministic 10,000-LOC / 20-package multi-file project generator
 * for C, MoonBit, Zig, Rust, and m2 compile-speed & cache-pollution benchmarks.
 *
 * Usage:
 *   gen_compile_bench <out_dir> [--mutate]
 *
 * Without --mutate: generates all 5 language projects (~10,000 LOC each, 20 pkgs).
 * With --mutate:    edits 1 line inside a function body of pkg05 (no pub signature change).
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define NUM_PKGS 20
#define FNS_PER_PKG 50

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

static void gen_c(const char *root, int delta) {
    char dir[1024], path[1024];
    snprintf(dir, sizeof(dir), "%s/c", root);
    mkdir_p(dir);

    for (int p = 0; p < NUM_PKGS; p++) {
        /* Header */
        snprintf(path, sizeof(path), "%s/pkg%02d.h", dir, p);
        FILE *h = must_open(path);
        fprintf(h, "#ifndef PKG%02d_H\n#define PKG%02d_H\n", p, p);
        for (int i = 0; i < FNS_PER_PKG; i++) {
            fprintf(h, "int pkg%02d_fn%02d(int x);\n", p, i);
        }
        fprintf(h, "int pkg%02d_entry(int x);\n#endif\n", p);
        fclose(h);

        /* Source (~500 LOC) */
        snprintf(path, sizeof(path), "%s/pkg%02d.c", dir, p);
        FILE *c = must_open(path);
        fprintf(c, "#include \"pkg%02d.h\"\n", p);
        if (p > 0) fprintf(c, "#include \"pkg%02d.h\"\n", p - 1);
        fprintf(c, "\n");
        for (int i = 0; i < FNS_PER_PKG; i++) {
            int d = (p == 5 && i == 0) ? delta : 1;
            fprintf(c, "int pkg%02d_fn%02d(int x) {\n", p, i);
            fprintf(c, "    int a = (x + %d) & 0x3fffffff;\n", p * 31 + i + 3);
            fprintf(c, "    int b = ((a * %d) ^ %d) & 0x3fffffff;\n", (i % 7) + 3, p * 17 + i);
            fprintf(c, "    int d = %d;\n", d);
            fprintf(c, "    int c = (b + d) & 0x3fffffff;\n");
            if (i > 0) {
                fprintf(c, "    int prev = pkg%02d_fn%02d(c & 0xffff);\n", p, i - 1);
                fprintf(c, "    c = (c + prev) & 0x3fffffff;\n");
            } else if (p > 0) {
                fprintf(c, "    int prev = pkg%02d_entry(c & 0xffff);\n", p - 1);
                fprintf(c, "    c = (c + prev) & 0x3fffffff;\n");
            } else {
                fprintf(c, "    c = (c + (a >> 2)) & 0x3fffffff;\n");
            }
            fprintf(c, "    int e = ((c * 5) + %d) & 0x3fffffff;\n", i + 1);
            fprintf(c, "    return e;\n");
            fprintf(c, "}\n\n");
        }
        fprintf(c, "int pkg%02d_entry(int x) {\n", p);
        fprintf(c, "    return pkg%02d_fn%02d(x);\n", p, FNS_PER_PKG - 1);
        fprintf(c, "}\n");
        fclose(c);
    }

    snprintf(path, sizeof(path), "%s/main.c", dir);
    FILE *m = must_open(path);
    fprintf(m, "#include <stdio.h>\n#include \"pkg%02d.h\"\n\n", NUM_PKGS - 1);
    fprintf(m, "int main(void) {\n");
    fprintf(m, "    int r = pkg%02d_entry(42);\n", NUM_PKGS - 1);
    fprintf(m, "    printf(\"%%d\\n\", r);\n");
    fprintf(m, "    return 0;\n");
    fprintf(m, "}\n");
    fclose(m);
}

static void gen_moonbit(const char *root, int delta) {
    char dir[1024], pdir[1024], path[1024];
    snprintf(dir, sizeof(dir), "%s/moonbit", root);
    mkdir_p(dir);

    snprintf(path, sizeof(path), "%s/moon.mod", dir);
    FILE *mod = must_open(path);
    fprintf(mod, "name = \"bench/scale10k\"\n\nversion = \"0.1.0\"\n\nsource = \"src\"\n\npreferred_target = \"native\"\n");
    fclose(mod);

    for (int p = 0; p < NUM_PKGS; p++) {
        snprintf(pdir, sizeof(pdir), "%s/src/pkg%02d", dir, p);
        mkdir_p(pdir);

        snprintf(path, sizeof(path), "%s/moon.pkg", pdir);
        FILE *pkg = must_open(path);
        fprintf(pkg, "import {\n");
        if (p > 0) {
            fprintf(pkg, "  \"bench/scale10k/pkg%02d\",\n", p - 1);
        }
        fprintf(pkg, "}\n");
        fclose(pkg);

        snprintf(path, sizeof(path), "%s/lib.mbt", pdir);
        FILE *f = must_open(path);
        for (int i = 0; i < FNS_PER_PKG; i++) {
            int d = (p == 5 && i == 0) ? delta : 1;
            fprintf(f, "pub fn fn%02d(x : Int) -> Int {\n", i);
            fprintf(f, "  let a = (x + %d) & 0x3fffffff\n", p * 31 + i + 3);
            fprintf(f, "  let b = ((a * %d) ^ %d) & 0x3fffffff\n", (i % 7) + 3, p * 17 + i);
            fprintf(f, "  let d = %d\n", d);
            fprintf(f, "  let mut c = (b + d) & 0x3fffffff\n");
            if (i > 0) {
                fprintf(f, "  let prev = fn%02d(c & 0xffff)\n", i - 1);
                fprintf(f, "  c = (c + prev) & 0x3fffffff\n");
            } else if (p > 0) {
                fprintf(f, "  let prev = @pkg%02d.entry(c & 0xffff)\n", p - 1);
                fprintf(f, "  c = (c + prev) & 0x3fffffff\n");
            } else {
                fprintf(f, "  c = (c + (a >> 2)) & 0x3fffffff\n");
            }
            fprintf(f, "  let e = ((c * 5) + %d) & 0x3fffffff\n", i + 1);
            fprintf(f, "  e\n");
            fprintf(f, "}\n\n");
        }
        fprintf(f, "pub fn entry(x : Int) -> Int {\n");
        fprintf(f, "  fn%02d(x)\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
        fclose(f);
    }

    snprintf(pdir, sizeof(pdir), "%s/src/app", dir);
    mkdir_p(pdir);
    snprintf(path, sizeof(path), "%s/moon.pkg", pdir);
    FILE *apkg = must_open(path);
    fprintf(apkg, "import {\n  \"bench/scale10k/pkg%02d\",\n}\n\noptions(\n  \"is-main\": true,\n)\n", NUM_PKGS - 1);
    fclose(apkg);

    snprintf(path, sizeof(path), "%s/main.mbt", pdir);
    FILE *am = must_open(path);
    fprintf(am, "fn main {\n  let r = @pkg%02d.entry(42)\n  println(r.to_string())\n}\n", NUM_PKGS - 1);
    fclose(am);
}

static void gen_zig(const char *root, int delta) {
    char dir[1024], path[1024];
    snprintf(dir, sizeof(dir), "%s/zig", root);
    mkdir_p(dir);

    for (int p = 0; p < NUM_PKGS; p++) {
        snprintf(path, sizeof(path), "%s/pkg%02d.zig", dir, p);
        FILE *f = must_open(path);
        if (p > 0) {
            fprintf(f, "const prev_pkg = @import(\"pkg%02d.zig\");\n\n", p - 1);
        }
        for (int i = 0; i < FNS_PER_PKG; i++) {
            int d = (p == 5 && i == 0) ? delta : 1;
            fprintf(f, "pub fn fn%02d(x: i32) i32 {\n", i);
            fprintf(f, "    const a: i32 = (x +%% %d) & 0x3fffffff;\n", p * 31 + i + 3);
            fprintf(f, "    const b: i32 = ((a *%% %d) ^ %d) & 0x3fffffff;\n", (i % 7) + 3, p * 17 + i);
            fprintf(f, "    const d: i32 = %d;\n", d);
            fprintf(f, "    var c: i32 = (b +%% d) & 0x3fffffff;\n");
            if (i > 0) {
                fprintf(f, "    const prev: i32 = fn%02d(c & 0xffff);\n", i - 1);
                fprintf(f, "    c = (c +%% prev) & 0x3fffffff;\n");
            } else if (p > 0) {
                fprintf(f, "    const prev: i32 = prev_pkg.entry(c & 0xffff);\n");
                fprintf(f, "    c = (c +%% prev) & 0x3fffffff;\n");
            } else {
                fprintf(f, "    c = (c +%% (a >> 2)) & 0x3fffffff;\n");
            }
            fprintf(f, "    const e: i32 = ((c *%% 5) +%% %d) & 0x3fffffff;\n", i + 1);
            fprintf(f, "    return e;\n");
            fprintf(f, "}\n\n");
        }
        fprintf(f, "pub fn entry(x: i32) i32 {\n");
        fprintf(f, "    return fn%02d(x);\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
        fclose(f);
    }

    snprintf(path, sizeof(path), "%s/main.zig", dir);
    FILE *m = must_open(path);
    fprintf(m, "const top = @import(\"pkg%02d.zig\");\n", NUM_PKGS - 1);
    fprintf(m, "extern \"c\" fn printf(fmt: [*:0]const u8, ...) c_int;\n\n");
    fprintf(m, "pub fn main() void {\n");
    fprintf(m, "    const r = top.entry(42);\n");
    fprintf(m, "    _ = printf(\"%%d\\n\", r);\n");
    fprintf(m, "}\n");
    fclose(m);
}

static void gen_rust(const char *root, int delta) {
    char dir[1024], cdir[1024], path[1024];
    snprintf(dir, sizeof(dir), "%s/rust", root);
    mkdir_p(dir);

    snprintf(path, sizeof(path), "%s/Cargo.toml", dir);
    FILE *ws = must_open(path);
    fprintf(ws, "[workspace]\nresolver = \"2\"\nmembers = [\n");
    for (int p = 0; p < NUM_PKGS; p++) {
        fprintf(ws, "    \"pkg%02d\",\n", p);
    }
    fprintf(ws, "    \"app\",\n]\n");
    fclose(ws);

    for (int p = 0; p < NUM_PKGS; p++) {
        snprintf(cdir, sizeof(cdir), "%s/pkg%02d/src", dir, p);
        mkdir_p(cdir);

        snprintf(path, sizeof(path), "%s/pkg%02d/Cargo.toml", dir, p);
        FILE *ct = must_open(path);
        fprintf(ct, "[package]\nname = \"pkg%02d\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n", p);
        if (p > 0) {
            fprintf(ct, "pkg%02d = { path = \"../pkg%02d\" }\n", p - 1, p - 1);
        }
        fclose(ct);

        snprintf(path, sizeof(path), "%s/lib.rs", cdir);
        FILE *f = must_open(path);
        for (int i = 0; i < FNS_PER_PKG; i++) {
            int d = (p == 5 && i == 0) ? delta : 1;
            fprintf(f, "pub fn fn%02d(x: i32) -> i32 {\n", i);
            fprintf(f, "    let a = x.wrapping_add(%d) & 0x3fffffff;\n", p * 31 + i + 3);
            fprintf(f, "    let b = (a.wrapping_mul(%d) ^ %d) & 0x3fffffff;\n", (i % 7) + 3, p * 17 + i);
            fprintf(f, "    let d = %d;\n", d);
            fprintf(f, "    let mut c = b.wrapping_add(d) & 0x3fffffff;\n");
            if (i > 0) {
                fprintf(f, "    let prev = fn%02d(c & 0xffff);\n", i - 1);
                fprintf(f, "    c = c.wrapping_add(prev) & 0x3fffffff;\n");
            } else if (p > 0) {
                fprintf(f, "    let prev = pkg%02d::entry(c & 0xffff);\n", p - 1);
                fprintf(f, "    c = c.wrapping_add(prev) & 0x3fffffff;\n");
            } else {
                fprintf(f, "    c = c.wrapping_add(a >> 2) & 0x3fffffff;\n");
            }
            fprintf(f, "    let e = c.wrapping_mul(5).wrapping_add(%d) & 0x3fffffff;\n", i + 1);
            fprintf(f, "    e\n");
            fprintf(f, "}\n\n");
        }
        fprintf(f, "pub fn entry(x: i32) -> i32 {\n");
        fprintf(f, "    fn%02d(x)\n", FNS_PER_PKG - 1);
        fprintf(f, "}\n");
        fclose(f);
    }

    snprintf(cdir, sizeof(cdir), "%s/app/src", dir);
    mkdir_p(cdir);
    snprintf(path, sizeof(path), "%s/app/Cargo.toml", dir);
    FILE *at = must_open(path);
    fprintf(at, "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\npkg%02d = { path = \"../pkg%02d\" }\n", NUM_PKGS - 1, NUM_PKGS - 1);
    fclose(at);

    snprintf(path, sizeof(path), "%s/main.rs", cdir);
    FILE *am = must_open(path);
    fprintf(am, "fn main() {\n    let r = pkg%02d::entry(42);\n    println!(\"{}\", r);\n}\n", NUM_PKGS - 1);
    fclose(am);
}

static void gen_m2(const char *root, int delta) {
    char dir[1024], path[1024];
    snprintf(dir, sizeof(dir), "%s/m2", root);
    mkdir_p(dir);

    for (int p = 0; p < NUM_PKGS; p++) {
        snprintf(path, sizeof(path), "%s/pkg%02d.m2", dir, p);
        FILE *f = must_open(path);
        fprintf(f, "///| Generated package pkg%02d (500 LOC)\n", p);
        for (int i = 0; i < FNS_PER_PKG; i++) {
            int d = (p == 5 && i == 0) ? delta : 1;
            fprintf(f, "pub fn pkg%02d_fn%02d(x : Int) -> Int {\n", p, i);
            fprintf(f, "  let a = (x + %d) & 0x3fffffff\n", p * 31 + i + 3);
            fprintf(f, "  let b = ((a * %d) ^ %d) & 0x3fffffff\n", (i % 7) + 3, p * 17 + i);
            fprintf(f, "  let d = %d\n", d);
            fprintf(f, "  let mut c = (b + d) & 0x3fffffff\n");
            if (i > 0) {
                fprintf(f, "  let prev = pkg%02d_fn%02d(c & 0xffff)\n", p, i - 1);
                fprintf(f, "  c = (c + prev) & 0x3fffffff\n");
            } else if (p > 0) {
                fprintf(f, "  let prev = pkg%02d_entry(c & 0xffff)\n", p - 1);
                fprintf(f, "  c = (c + prev) & 0x3fffffff\n");
            } else {
                fprintf(f, "  c = (c + (a >> 2)) & 0x3fffffff\n");
            }
            fprintf(f, "  let e = ((c * 5) + %d) & 0x3fffffff\n", i + 1);
            fprintf(f, "  e\n");
            fprintf(f, "}\n\n");
        }
        fprintf(f, "pub fn pkg%02d_entry(x : Int) -> Int {\n", p);
        fprintf(f, "  pkg%02d_fn%02d(x)\n", p, FNS_PER_PKG - 1);
        fprintf(f, "}\n");
        fclose(f);
    }

    snprintf(path, sizeof(path), "%s/main.m2", dir);
    FILE *m = must_open(path);
    fprintf(m, "///| Generated entry point for 10,000-LOC / 20-package m2 benchmark\n");
    fprintf(m, "pub fn main(world : World) -> Int {\n");
    fprintf(m, "  let r = pkg%02d_entry(42)\n", NUM_PKGS - 1);
    fprintf(m, "  io_println(world, r.to_string())\n");
    fprintf(m, "  0\n");
    fprintf(m, "}\n");
    fclose(m);
}

static void mutate_pkg05_only(const char *root) {
    /* Only rewrite pkg05 in each language so mtime of all other 19 packages is untouched! */
    char path[1024];
    int p = 5;
    int delta = 2;

    /* C: rewrite pkg05.c only */
    snprintf(path, sizeof(path), "%s/c/pkg%02d.c", root, p);
    FILE *c = must_open(path);
    fprintf(c, "#include \"pkg%02d.h\"\n#include \"pkg%02d.h\"\n\n", p, p - 1);
    for (int i = 0; i < FNS_PER_PKG; i++) {
        int d = (i == 0) ? delta : 1;
        fprintf(c, "int pkg%02d_fn%02d(int x) {\n", p, i);
        fprintf(c, "    int a = (x + %d) & 0x3fffffff;\n", p * 31 + i + 3);
        fprintf(c, "    int b = ((a * %d) ^ %d) & 0x3fffffff;\n", (i % 7) + 3, p * 17 + i);
        fprintf(c, "    int d = %d;\n", d);
        fprintf(c, "    int c = (b + d) & 0x3fffffff;\n");
        if (i > 0) {
            fprintf(c, "    int prev = pkg%02d_fn%02d(c & 0xffff);\n", p, i - 1);
        } else {
            fprintf(c, "    int prev = pkg%02d_entry(c & 0xffff);\n", p - 1);
        }
        fprintf(c, "    c = (c + prev) & 0x3fffffff;\n");
        fprintf(c, "    int e = ((c * 5) + %d) & 0x3fffffff;\n", i + 1);
        fprintf(c, "    return e;\n}\n\n");
    }
    fprintf(c, "int pkg%02d_entry(int x) {\n    return pkg%02d_fn%02d(x);\n}\n", p, p, FNS_PER_PKG - 1);
    fclose(c);

    /* MoonBit: rewrite src/pkg05/lib.mbt only */
    snprintf(path, sizeof(path), "%s/moonbit/src/pkg%02d/lib.mbt", root, p);
    FILE *mb = must_open(path);
    for (int i = 0; i < FNS_PER_PKG; i++) {
        int d = (i == 0) ? delta : 1;
        fprintf(mb, "pub fn fn%02d(x : Int) -> Int {\n", i);
        fprintf(mb, "  let a = (x + %d) & 0x3fffffff\n", p * 31 + i + 3);
        fprintf(mb, "  let b = ((a * %d) ^ %d) & 0x3fffffff\n", (i % 7) + 3, p * 17 + i);
        fprintf(mb, "  let d = %d\n", d);
        fprintf(mb, "  let mut c = (b + d) & 0x3fffffff\n");
        if (i > 0) {
            fprintf(mb, "  let prev = fn%02d(c & 0xffff)\n", i - 1);
        } else {
            fprintf(mb, "  let prev = @pkg%02d.entry(c & 0xffff)\n", p - 1);
        }
        fprintf(mb, "  c = (c + prev) & 0x3fffffff\n");
        fprintf(mb, "  let e = ((c * 5) + %d) & 0x3fffffff\n", i + 1);
        fprintf(mb, "  e\n}\n\n");
    }
    fprintf(mb, "pub fn entry(x : Int) -> Int {\n  fn%02d(x)\n}\n", FNS_PER_PKG - 1);
    fclose(mb);

    /* Zig: rewrite pkg05.zig only */
    snprintf(path, sizeof(path), "%s/zig/pkg%02d.zig", root, p);
    FILE *z = must_open(path);
    fprintf(z, "const prev_pkg = @import(\"pkg%02d.zig\");\n\n", p - 1);
    for (int i = 0; i < FNS_PER_PKG; i++) {
        int d = (i == 0) ? delta : 1;
        fprintf(z, "pub fn fn%02d(x: i32) i32 {\n", i);
        fprintf(z, "    const a: i32 = (x +%% %d) & 0x3fffffff;\n", p * 31 + i + 3);
        fprintf(z, "    const b: i32 = ((a *%% %d) ^ %d) & 0x3fffffff;\n", (i % 7) + 3, p * 17 + i);
        fprintf(z, "    const d: i32 = %d;\n", d);
        fprintf(z, "    var c: i32 = (b +%% d) & 0x3fffffff;\n");
        if (i > 0) {
            fprintf(z, "    const prev: i32 = fn%02d(c & 0xffff);\n", i - 1);
        } else {
            fprintf(z, "    const prev: i32 = prev_pkg.entry(c & 0xffff);\n");
        }
        fprintf(z, "    c = (c +%% prev) & 0x3fffffff;\n");
        fprintf(z, "    const e: i32 = ((c *%% 5) +%% %d) & 0x3fffffff;\n", i + 1);
        fprintf(z, "    return e;\n}\n\n");
    }
    fprintf(z, "pub fn entry(x: i32) i32 {\n    return fn%02d(x);\n}\n", FNS_PER_PKG - 1);
    fclose(z);

    /* Rust: rewrite pkg05/src/lib.rs only */
    snprintf(path, sizeof(path), "%s/rust/pkg%02d/src/lib.rs", root, p);
    FILE *r = must_open(path);
    for (int i = 0; i < FNS_PER_PKG; i++) {
        int d = (i == 0) ? delta : 1;
        fprintf(r, "pub fn fn%02d(x: i32) -> i32 {\n", i);
        fprintf(r, "    let a = x.wrapping_add(%d) & 0x3fffffff;\n", p * 31 + i + 3);
        fprintf(r, "    let b = (a.wrapping_mul(%d) ^ %d) & 0x3fffffff;\n", (i % 7) + 3, p * 17 + i);
        fprintf(r, "    let d = %d;\n", d);
        fprintf(r, "    let mut c = b.wrapping_add(d) & 0x3fffffff;\n");
        if (i > 0) {
            fprintf(r, "    let prev = fn%02d(c & 0xffff);\n", i - 1);
        } else {
            fprintf(r, "    let prev = pkg%02d::entry(c & 0xffff);\n", p - 1);
        }
        fprintf(r, "    c = c.wrapping_add(prev) & 0x3fffffff;\n");
        fprintf(r, "    let e = c.wrapping_mul(5).wrapping_add(%d) & 0x3fffffff;\n", i + 1);
        fprintf(r, "    e\n}\n\n");
    }
    fprintf(r, "pub fn entry(x: i32) -> i32 {\n    fn%02d(x)\n}\n", FNS_PER_PKG - 1);
    fclose(r);

    /* m2: rewrite pkg05.m2 only */
    snprintf(path, sizeof(path), "%s/m2/pkg%02d.m2", root, p);
    FILE *m2 = must_open(path);
    fprintf(m2, "///| Generated package pkg%02d (500 LOC, mutated 1 line)\n", p);
    for (int i = 0; i < FNS_PER_PKG; i++) {
        int d = (i == 0) ? delta : 1;
        fprintf(m2, "pub fn pkg%02d_fn%02d(x : Int) -> Int {\n", p, i);
        fprintf(m2, "  let a = (x + %d) & 0x3fffffff\n", p * 31 + i + 3);
        fprintf(m2, "  let b = ((a * %d) ^ %d) & 0x3fffffff\n", (i % 7) + 3, p * 17 + i);
        fprintf(m2, "  let d = %d\n", d);
        fprintf(m2, "  let mut c = (b + d) & 0x3fffffff\n");
        if (i > 0) {
            fprintf(m2, "  let prev = pkg%02d_fn%02d(c & 0xffff)\n", p, i - 1);
        } else {
            fprintf(m2, "  let prev = pkg%02d_entry(c & 0xffff)\n", p - 1);
        }
        fprintf(m2, "  c = (c + prev) & 0x3fffffff\n");
        fprintf(m2, "  let e = ((c * 5) + %d) & 0x3fffffff\n", i + 1);
        fprintf(m2, "  e\n}\n\n");
    }
    fprintf(m2, "pub fn pkg%02d_entry(x : Int) -> Int {\n  pkg%02d_fn%02d(x)\n}\n", p, p, FNS_PER_PKG - 1);
    fclose(m2);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <out_dir> [--mutate]\n", argv[0]);
        return 2;
    }
    const char *root = argv[1];
    int mutate = (argc >= 3 && strcmp(argv[2], "--mutate") == 0);
    if (mutate) {
        mutate_pkg05_only(root);
        return 0;
    }
    mkdir_p(root);
    gen_c(root, 1);
    gen_moonbit(root, 1);
    gen_zig(root, 1);
    gen_rust(root, 1);
    gen_m2(root, 1);
    return 0;
}
