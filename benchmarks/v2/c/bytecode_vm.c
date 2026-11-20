/*
 * V2 Benchmark 2: bytecode_vm (C reference)
 * Stage A: 200x (Lex -> Recursive-Descent AST -> Bytecode Compile)
 * Stage B: Stack VM dispatch (~15M-25M instructions)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *MINI_SRC =
"fn fib(n) {\n"
"  if (n <= 1) { return n; }\n"
"  return fib(n - 1) + fib(n - 2);\n"
"}\n"
"fn sieve(limit) {\n"
"  let flags = new_arr(limit + 1);\n"
"  let i = 2;\n"
"  while (i <= limit) {\n"
"    flags[i] = 1;\n"
"    i = i + 1;\n"
"  }\n"
"  let p = 2;\n"
"  while (p * p <= limit) {\n"
"    if (flags[p] == 1) {\n"
"      let m = p * p;\n"
"      while (m <= limit) {\n"
"        flags[m] = 0;\n"
"        m = m + p;\n"
"      }\n"
"    }\n"
"    p = p + 1;\n"
"  }\n"
"  let sum = 0;\n"
"  let cnt = 0;\n"
"  let k = 2;\n"
"  while (k <= limit) {\n"
"    if (flags[k] == 1) {\n"
"      cnt = cnt + 1;\n"
"      sum = (sum * 31 + k) % 1000003;\n"
"    }\n"
"    k = k + 1;\n"
"  }\n"
"  return (sum + cnt * 17) % 1000003;\n"
"}\n"
"fn sort_and_hash(n, seed) {\n"
"  let a = new_arr(n);\n"
"  let s = seed;\n"
"  let i = 0;\n"
"  while (i < n) {\n"
"    s = (s * 1103 + 12345) % 65536;\n"
"    a[i] = s % 10000;\n"
"    i = i + 1;\n"
"  }\n"
"  let j = 1;\n"
"  while (j < n) {\n"
"    let key = a[j];\n"
"    let k = j - 1;\n"
"    while (k >= 0 && a[k] > key) {\n"
"      a[k + 1] = a[k];\n"
"      k = k - 1;\n"
"    }\n"
"    a[k + 1] = key;\n"
"    j = j + 1;\n"
"  }\n"
"  let h = 0;\n"
"  let idx = 0;\n"
"  while (idx < n) {\n"
"    h = (h * 31 + a[idx]) % 1000003;\n"
"    idx = idx + 1;\n"
"  }\n"
"  return h;\n"
"}\n"
"fn main() {\n"
"  let acc = 0;\n"
"  let r = 0;\n"
"  while (r < 55) {\n"
"    let f = fib(22);\n"
"    let sv = sieve(2000);\n"
"    let sh = sort_and_hash(120, 42 + r * 7);\n"
"    let mix = (f + sv + sh) % 1000003;\n"
"    if (r % 2 == 0 || mix < 0) {\n"
"      acc = (acc * 3 + mix) % 1000003;\n"
"    } else {\n"
"      acc = (acc * 5 + mix + 11) % 1000003;\n"
"    }\n"
"    r = r + 1;\n"
"  }\n"
"  return acc;\n"
"}\n";

/* ---- Lexer ---- */
typedef enum {
    TK_EOF = 0, TK_INT, TK_IDENT,
    TK_FN, TK_LET, TK_IF, TK_ELSE, TK_WHILE, TK_RETURN, TK_NEWARR,
    TK_LPAREN, TK_RPAREN, TK_LBRACE, TK_RBRACE, TK_LBRACK, TK_RBRACK,
    TK_COMMA, TK_SEMI,
    TK_PLUS, TK_MINUS, TK_STAR, TK_SLASH, TK_PERCENT,
    TK_EQ, TK_EQEQ, TK_NEQ, TK_LT, TK_LE, TK_GT, TK_GE,
    TK_ANDAND, TK_OROR, TK_BANG
} TokKind;

typedef struct {
    TokKind kind;
    int32_t ival;
    char text[32];
} Token;

typedef struct {
    Token *items;
    int len;
    int cap;
} TokList;

static void tl_push(TokList *tl, Token t) {
    if (tl->len == tl->cap) {
        tl->cap = tl->cap ? tl->cap * 2 : 64;
        tl->items = (Token *)realloc(tl->items, (size_t)tl->cap * sizeof(Token));
    }
    tl->items[tl->len++] = t;
}

static TokList lex(const char *src) {
    TokList tl = {0};
    int n = (int)strlen(src);
    int i = 0;
    while (i < n) {
        char c = src[i];
        if (c == ' ' || c == '\n' || c == '\r' || c == '\t') { i++; continue; }
        Token t;
        memset(&t, 0, sizeof(t));
        if (c >= '0' && c <= '9') {
            int32_t v = 0;
            while (i < n && src[i] >= '0' && src[i] <= '9') {
                v = v * 10 + (src[i] - '0');
                i++;
            }
            t.kind = TK_INT; t.ival = v;
            tl_push(&tl, t); continue;
        }
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') {
            int st = i;
            while (i < n && ((src[i] >= 'a' && src[i] <= 'z') || (src[i] >= 'A' && src[i] <= 'Z') ||
                             (src[i] >= '0' && src[i] <= '9') || src[i] == '_')) i++;
            int l = i - st;
            if (l > 31) l = 31;
            memcpy(t.text, src + st, (size_t)l);
            t.text[l] = '\0';
            if (strcmp(t.text, "fn") == 0) t.kind = TK_FN;
            else if (strcmp(t.text, "let") == 0) t.kind = TK_LET;
            else if (strcmp(t.text, "if") == 0) t.kind = TK_IF;
            else if (strcmp(t.text, "else") == 0) t.kind = TK_ELSE;
            else if (strcmp(t.text, "while") == 0) t.kind = TK_WHILE;
            else if (strcmp(t.text, "return") == 0) t.kind = TK_RETURN;
            else if (strcmp(t.text, "new_arr") == 0) t.kind = TK_NEWARR;
            else t.kind = TK_IDENT;
            tl_push(&tl, t); continue;
        }
        if (c == '=' && i + 1 < n && src[i + 1] == '=') { t.kind = TK_EQEQ; i += 2; tl_push(&tl, t); continue; }
        if (c == '!' && i + 1 < n && src[i + 1] == '=') { t.kind = TK_NEQ; i += 2; tl_push(&tl, t); continue; }
        if (c == '<' && i + 1 < n && src[i + 1] == '=') { t.kind = TK_LE; i += 2; tl_push(&tl, t); continue; }
        if (c == '>' && i + 1 < n && src[i + 1] == '=') { t.kind = TK_GE; i += 2; tl_push(&tl, t); continue; }
        if (c == '&' && i + 1 < n && src[i + 1] == '&') { t.kind = TK_ANDAND; i += 2; tl_push(&tl, t); continue; }
        if (c == '|' && i + 1 < n && src[i + 1] == '|') { t.kind = TK_OROR; i += 2; tl_push(&tl, t); continue; }
        switch (c) {
            case '(': t.kind = TK_LPAREN; break;
            case ')': t.kind = TK_RPAREN; break;
            case '{': t.kind = TK_LBRACE; break;
            case '}': t.kind = TK_RBRACE; break;
            case '[': t.kind = TK_LBRACK; break;
            case ']': t.kind = TK_RBRACK; break;
            case ',': t.kind = TK_COMMA; break;
            case ';': t.kind = TK_SEMI; break;
            case '+': t.kind = TK_PLUS; break;
            case '-': t.kind = TK_MINUS; break;
            case '*': t.kind = TK_STAR; break;
            case '/': t.kind = TK_SLASH; break;
            case '%': t.kind = TK_PERCENT; break;
            case '=': t.kind = TK_EQ; break;
            case '<': t.kind = TK_LT; break;
            case '>': t.kind = TK_GT; break;
            case '!': t.kind = TK_BANG; break;
            default: fprintf(stderr, "unexpected char '%c'\n", c); exit(1);
        }
        i++;
        tl_push(&tl, t);
    }
    Token eof;
    memset(&eof, 0, sizeof(eof));
    eof.kind = TK_EOF;
    tl_push(&tl, eof);
    return tl;
}

/* ---- AST ---- */
typedef enum {
    EX_INT, EX_VAR, EX_UNARY, EX_BIN, EX_CALL, EX_NEWARR, EX_INDEX
} ExprKind;

typedef struct Expr Expr;
struct Expr {
    ExprKind kind;
    int32_t ival;
    int op;
    char name[32];
    Expr *lhs;
    Expr *rhs;
    Expr **args;
    int nargs;
};

typedef enum {
    ST_LET, ST_ASSIGN, ST_ARR_SET, ST_IF, ST_WHILE, ST_RETURN, ST_EXPR
} StmtKind;

typedef struct Stmt Stmt;
struct Stmt {
    StmtKind kind;
    char name[32];
    Expr *expr;
    Expr *idx;
    Stmt **body;
    int body_len;
    Stmt **else_body;
    int else_len;
};

typedef struct {
    char name[32];
    char params[8][32];
    int nparams;
    Stmt **body;
    int body_len;
} FuncDef;

typedef struct {
    FuncDef *funcs;
    int nfuncs;
} Program;

static void free_expr(Expr *e) {
    if (!e) return;
    free_expr(e->lhs);
    free_expr(e->rhs);
    for (int i = 0; i < e->nargs; i++) free_expr(e->args[i]);
    free(e->args);
    free(e);
}

static void free_stmt(Stmt *s) {
    if (!s) return;
    free_expr(s->expr);
    free_expr(s->idx);
    for (int i = 0; i < s->body_len; i++) free_stmt(s->body[i]);
    free(s->body);
    for (int i = 0; i < s->else_len; i++) free_stmt(s->else_body[i]);
    free(s->else_body);
    free(s);
}

static void free_program(Program *p) {
    for (int i = 0; i < p->nfuncs; i++) {
        for (int j = 0; j < p->funcs[i].body_len; j++) free_stmt(p->funcs[i].body[j]);
        free(p->funcs[i].body);
    }
    free(p->funcs);
}

typedef struct {
    Token *toks;
    int pos;
} AstParser;

static TokKind peek_k(AstParser *p) { return p->toks[p->pos].kind; }
static Token next_t(AstParser *p) { return p->toks[p->pos++]; }
static void expect_k(AstParser *p, TokKind k) {
    if (peek_k(p) != k) { fprintf(stderr, "parse mismatch at %d\n", p->pos); exit(1); }
    p->pos++;
}

static Expr *parse_expr(AstParser *p);

static Expr *parse_primary(AstParser *p) {
    if (peek_k(p) == TK_INT) {
        Token t = next_t(p);
        Expr *e = (Expr *)calloc(1, sizeof(Expr));
        e->kind = EX_INT; e->ival = t.ival;
        return e;
    }
    if (peek_k(p) == TK_NEWARR) {
        next_t(p);
        expect_k(p, TK_LPAREN);
        Expr *sz = parse_expr(p);
        expect_k(p, TK_RPAREN);
        Expr *e = (Expr *)calloc(1, sizeof(Expr));
        e->kind = EX_NEWARR; e->lhs = sz;
        return e;
    }
    if (peek_k(p) == TK_LPAREN) {
        next_t(p);
        Expr *e = parse_expr(p);
        expect_k(p, TK_RPAREN);
        return e;
    }
    if (peek_k(p) == TK_IDENT) {
        Token t = next_t(p);
        if (peek_k(p) == TK_LPAREN) {
            next_t(p);
            Expr *e = (Expr *)calloc(1, sizeof(Expr));
            e->kind = EX_CALL;
            strcpy(e->name, t.text);
            int cap = 4;
            e->args = (Expr **)malloc((size_t)cap * sizeof(Expr *));
            if (peek_k(p) != TK_RPAREN) {
                for (;;) {
                    if (e->nargs == cap) { cap *= 2; e->args = (Expr **)realloc(e->args, (size_t)cap * sizeof(Expr *)); }
                    e->args[e->nargs++] = parse_expr(p);
                    if (peek_k(p) == TK_COMMA) next_t(p);
                    else break;
                }
            }
            expect_k(p, TK_RPAREN);
            return e;
        }
        Expr *base = (Expr *)calloc(1, sizeof(Expr));
        base->kind = EX_VAR;
        strcpy(base->name, t.text);
        if (peek_k(p) == TK_LBRACK) {
            next_t(p);
            Expr *idx = parse_expr(p);
            expect_k(p, TK_RBRACK);
            Expr *ix = (Expr *)calloc(1, sizeof(Expr));
            ix->kind = EX_INDEX; ix->lhs = base; ix->rhs = idx;
            return ix;
        }
        return base;
    }
    fprintf(stderr, "unexpected primary token %d\n", peek_k(p));
    exit(1);
}

static Expr *parse_unary(AstParser *p) {
    if (peek_k(p) == TK_MINUS || peek_k(p) == TK_BANG) {
        TokKind op = next_t(p).kind;
        Expr *e = (Expr *)calloc(1, sizeof(Expr));
        e->kind = EX_UNARY; e->op = (int)op; e->lhs = parse_unary(p);
        return e;
    }
    return parse_primary(p);
}

static Expr *parse_mul(AstParser *p) {
    Expr *l = parse_unary(p);
    while (peek_k(p) == TK_STAR || peek_k(p) == TK_SLASH || peek_k(p) == TK_PERCENT) {
        TokKind op = next_t(p).kind;
        Expr *r = parse_unary(p);
        Expr *b = (Expr *)calloc(1, sizeof(Expr));
        b->kind = EX_BIN; b->op = (int)op; b->lhs = l; b->rhs = r;
        l = b;
    }
    return l;
}

static Expr *parse_add(AstParser *p) {
    Expr *l = parse_mul(p);
    while (peek_k(p) == TK_PLUS || peek_k(p) == TK_MINUS) {
        TokKind op = next_t(p).kind;
        Expr *r = parse_mul(p);
        Expr *b = (Expr *)calloc(1, sizeof(Expr));
        b->kind = EX_BIN; b->op = (int)op; b->lhs = l; b->rhs = r;
        l = b;
    }
    return l;
}

static Expr *parse_rel(AstParser *p) {
    Expr *l = parse_add(p);
    while (peek_k(p) == TK_LT || peek_k(p) == TK_LE || peek_k(p) == TK_GT || peek_k(p) == TK_GE ||
           peek_k(p) == TK_EQEQ || peek_k(p) == TK_NEQ) {
        TokKind op = next_t(p).kind;
        Expr *r = parse_add(p);
        Expr *b = (Expr *)calloc(1, sizeof(Expr));
        b->kind = EX_BIN; b->op = (int)op; b->lhs = l; b->rhs = r;
        l = b;
    }
    return l;
}

static Expr *parse_and(AstParser *p) {
    Expr *l = parse_rel(p);
    while (peek_k(p) == TK_ANDAND) {
        TokKind op = next_t(p).kind;
        Expr *r = parse_rel(p);
        Expr *b = (Expr *)calloc(1, sizeof(Expr));
        b->kind = EX_BIN; b->op = (int)op; b->lhs = l; b->rhs = r;
        l = b;
    }
    return l;
}

static Expr *parse_expr(AstParser *p) {
    Expr *l = parse_and(p);
    while (peek_k(p) == TK_OROR) {
        TokKind op = next_t(p).kind;
        Expr *r = parse_and(p);
        Expr *b = (Expr *)calloc(1, sizeof(Expr));
        b->kind = EX_BIN; b->op = (int)op; b->lhs = l; b->rhs = r;
        l = b;
    }
    return l;
}

static Stmt **parse_block(AstParser *p, int *out_len);

static Stmt *parse_stmt(AstParser *p) {
    if (peek_k(p) == TK_LET) {
        next_t(p);
        Token name = next_t(p);
        expect_k(p, TK_EQ);
        Expr *e = parse_expr(p);
        expect_k(p, TK_SEMI);
        Stmt *s = (Stmt *)calloc(1, sizeof(Stmt));
        s->kind = ST_LET; strcpy(s->name, name.text); s->expr = e;
        return s;
    }
    if (peek_k(p) == TK_IF) {
        next_t(p);
        expect_k(p, TK_LPAREN);
        Expr *c = parse_expr(p);
        expect_k(p, TK_RPAREN);
        Stmt *s = (Stmt *)calloc(1, sizeof(Stmt));
        s->kind = ST_IF; s->expr = c;
        s->body = parse_block(p, &s->body_len);
        if (peek_k(p) == TK_ELSE) {
            next_t(p);
            s->else_body = parse_block(p, &s->else_len);
        }
        return s;
    }
    if (peek_k(p) == TK_WHILE) {
        next_t(p);
        expect_k(p, TK_LPAREN);
        Expr *c = parse_expr(p);
        expect_k(p, TK_RPAREN);
        Stmt *s = (Stmt *)calloc(1, sizeof(Stmt));
        s->kind = ST_WHILE; s->expr = c;
        s->body = parse_block(p, &s->body_len);
        return s;
    }
    if (peek_k(p) == TK_RETURN) {
        next_t(p);
        Expr *e = parse_expr(p);
        expect_k(p, TK_SEMI);
        Stmt *s = (Stmt *)calloc(1, sizeof(Stmt));
        s->kind = ST_RETURN; s->expr = e;
        return s;
    }
    if (peek_k(p) == TK_IDENT && p->toks[p->pos + 1].kind == TK_EQ) {
        Token name = next_t(p);
        next_t(p);
        Expr *e = parse_expr(p);
        expect_k(p, TK_SEMI);
        Stmt *s = (Stmt *)calloc(1, sizeof(Stmt));
        s->kind = ST_ASSIGN; strcpy(s->name, name.text); s->expr = e;
        return s;
    }
    if (peek_k(p) == TK_IDENT && p->toks[p->pos + 1].kind == TK_LBRACK) {
        Token name = next_t(p);
        next_t(p);
        Expr *idx = parse_expr(p);
        expect_k(p, TK_RBRACK);
        expect_k(p, TK_EQ);
        Expr *val = parse_expr(p);
        expect_k(p, TK_SEMI);
        Stmt *s = (Stmt *)calloc(1, sizeof(Stmt));
        s->kind = ST_ARR_SET; strcpy(s->name, name.text); s->idx = idx; s->expr = val;
        return s;
    }
    Expr *e = parse_expr(p);
    expect_k(p, TK_SEMI);
    Stmt *s = (Stmt *)calloc(1, sizeof(Stmt));
    s->kind = ST_EXPR; s->expr = e;
    return s;
}

static Stmt **parse_block(AstParser *p, int *out_len) {
    expect_k(p, TK_LBRACE);
    int cap = 8, len = 0;
    Stmt **items = (Stmt **)malloc((size_t)cap * sizeof(Stmt *));
    while (peek_k(p) != TK_RBRACE && peek_k(p) != TK_EOF) {
        if (len == cap) { cap *= 2; items = (Stmt **)realloc(items, (size_t)cap * sizeof(Stmt *)); }
        items[len++] = parse_stmt(p);
    }
    expect_k(p, TK_RBRACE);
    *out_len = len;
    return items;
}

static Program parse_program(TokList *tl) {
    AstParser p = { tl->items, 0 };
    Program prog = {0};
    int cap = 8;
    prog.funcs = (FuncDef *)calloc((size_t)cap, sizeof(FuncDef));
    while (peek_k(&p) == TK_FN) {
        next_t(&p);
        if (prog.nfuncs == cap) {
            cap *= 2;
            prog.funcs = (FuncDef *)realloc(prog.funcs, (size_t)cap * sizeof(FuncDef));
        }
        FuncDef *fn = &prog.funcs[prog.nfuncs++];
        memset(fn, 0, sizeof(*fn));
        Token name = next_t(&p);
        strcpy(fn->name, name.text);
        expect_k(&p, TK_LPAREN);
        if (peek_k(&p) != TK_RPAREN) {
            for (;;) {
                Token pn = next_t(&p);
                strcpy(fn->params[fn->nparams++], pn.text);
                if (peek_k(&p) == TK_COMMA) next_t(&p);
                else break;
            }
        }
        expect_k(&p, TK_RPAREN);
        fn->body = parse_block(&p, &fn->body_len);
    }
    return prog;
}

/* ---- Bytecode Compiler ---- */
enum {
    OP_CONST = 0, OP_LOAD, OP_STORE,
    OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD,
    OP_EQ, OP_LT, OP_LE, OP_AND, OP_OR, OP_NOT, OP_NEG,
    OP_JMP, OP_JMP_FALSE, OP_CALL, OP_RET, OP_POP,
    OP_ARR_NEW, OP_ARR_GET, OP_ARR_SET, OP_HALT
};

typedef struct {
    int32_t op;
    int32_t arg;
} Instr;

typedef struct {
    int entry_pc;
    int nparams;
    int nlocals;
} FuncMeta;

typedef struct {
    Instr *code;
    int len;
    int cap;
    FuncMeta funcs[16];
    int nfuncs;
    int main_idx;
} Bytecode;

typedef struct {
    Bytecode *bc;
    Program *prog;
    char locals[64][32];
    int nlocals;
} Compiler;

static int emit(Compiler *c, int32_t op, int32_t arg) {
    if (c->bc->len == c->bc->cap) {
        c->bc->cap = c->bc->cap ? c->bc->cap * 2 : 128;
        c->bc->code = (Instr *)realloc(c->bc->code, (size_t)c->bc->cap * sizeof(Instr));
    }
    int idx = c->bc->len++;
    c->bc->code[idx].op = op;
    c->bc->code[idx].arg = arg;
    return idx;
}

static int find_local(Compiler *c, const char *name) {
    for (int i = 0; i < c->nlocals; i++) {
        if (strcmp(c->locals[i], name) == 0) return i;
    }
    strcpy(c->locals[c->nlocals], name);
    return c->nlocals++;
}

static int find_func(Program *p, const char *name) {
    for (int i = 0; i < p->nfuncs; i++) {
        if (strcmp(p->funcs[i].name, name) == 0) return i;
    }
    fprintf(stderr, "unknown func %s\n", name);
    exit(1);
}

static void comp_expr(Compiler *c, Expr *e) {
    switch (e->kind) {
        case EX_INT: emit(c, OP_CONST, e->ival); break;
        case EX_VAR: emit(c, OP_LOAD, find_local(c, e->name)); break;
        case EX_NEWARR:
            comp_expr(c, e->lhs);
            emit(c, OP_ARR_NEW, 0);
            break;
        case EX_INDEX:
            comp_expr(c, e->lhs);
            comp_expr(c, e->rhs);
            emit(c, OP_ARR_GET, 0);
            break;
        case EX_UNARY:
            comp_expr(c, e->lhs);
            emit(c, e->op == TK_MINUS ? OP_NEG : OP_NOT, 0);
            break;
        case EX_CALL:
            for (int i = 0; i < e->nargs; i++) comp_expr(c, e->args[i]);
            emit(c, OP_CALL, find_func(c->prog, e->name));
            break;
        case EX_BIN:
            if (e->op == TK_ANDAND) {
                comp_expr(c, e->lhs);
                int j1 = emit(c, OP_JMP_FALSE, 0);
                comp_expr(c, e->rhs);
                emit(c, OP_CONST, 0);
                emit(c, OP_EQ, 0);
                emit(c, OP_NOT, 0);
                int j2 = emit(c, OP_JMP, 0);
                c->bc->code[j1].arg = c->bc->len;
                emit(c, OP_CONST, 0);
                c->bc->code[j2].arg = c->bc->len;
                break;
            }
            if (e->op == TK_OROR) {
                comp_expr(c, e->lhs);
                int j1 = emit(c, OP_JMP_FALSE, 0);
                emit(c, OP_CONST, 1);
                int j2 = emit(c, OP_JMP, 0);
                c->bc->code[j1].arg = c->bc->len;
                comp_expr(c, e->rhs);
                emit(c, OP_CONST, 0);
                emit(c, OP_EQ, 0);
                emit(c, OP_NOT, 0);
                c->bc->code[j2].arg = c->bc->len;
                break;
            }
            comp_expr(c, e->lhs);
            comp_expr(c, e->rhs);
            switch (e->op) {
                case TK_PLUS:    emit(c, OP_ADD, 0); break;
                case TK_MINUS:   emit(c, OP_SUB, 0); break;
                case TK_STAR:    emit(c, OP_MUL, 0); break;
                case TK_SLASH:   emit(c, OP_DIV, 0); break;
                case TK_PERCENT: emit(c, OP_MOD, 0); break;
                case TK_EQEQ:    emit(c, OP_EQ, 0);  break;
                case TK_NEQ:     emit(c, OP_EQ, 0); emit(c, OP_NOT, 0); break;
                case TK_LT:      emit(c, OP_LT, 0);  break;
                case TK_LE:      emit(c, OP_LE, 0);  break;
                case TK_GT:      emit(c, OP_LE, 0); emit(c, OP_NOT, 0); break;
                case TK_GE:      emit(c, OP_LT, 0); emit(c, OP_NOT, 0); break;
                default: break;
            }
            break;
    }
}

static void comp_stmt(Compiler *c, Stmt *s) {
    switch (s->kind) {
        case ST_LET:
        case ST_ASSIGN: {
            int slot = find_local(c, s->name);
            comp_expr(c, s->expr);
            emit(c, OP_STORE, slot);
            break;
        }
        case ST_ARR_SET: {
            int slot = find_local(c, s->name);
            emit(c, OP_LOAD, slot);
            comp_expr(c, s->idx);
            comp_expr(c, s->expr);
            emit(c, OP_ARR_SET, 0);
            break;
        }
        case ST_RETURN:
            comp_expr(c, s->expr);
            emit(c, OP_RET, 0);
            break;
        case ST_EXPR:
            comp_expr(c, s->expr);
            emit(c, OP_POP, 0);
            break;
        case ST_IF: {
            comp_expr(c, s->expr);
            int jf = emit(c, OP_JMP_FALSE, 0);
            for (int i = 0; i < s->body_len; i++) comp_stmt(c, s->body[i]);
            if (s->else_len > 0) {
                int je = emit(c, OP_JMP, 0);
                c->bc->code[jf].arg = c->bc->len;
                for (int i = 0; i < s->else_len; i++) comp_stmt(c, s->else_body[i]);
                c->bc->code[je].arg = c->bc->len;
            } else {
                c->bc->code[jf].arg = c->bc->len;
            }
            break;
        }
        case ST_WHILE: {
            int loop_pc = c->bc->len;
            comp_expr(c, s->expr);
            int jf = emit(c, OP_JMP_FALSE, 0);
            for (int i = 0; i < s->body_len; i++) comp_stmt(c, s->body[i]);
            emit(c, OP_JMP, loop_pc);
            c->bc->code[jf].arg = c->bc->len;
            break;
        }
    }
}

static Bytecode compile_program(Program *prog) {
    Bytecode bc;
    memset(&bc, 0, sizeof(bc));
    bc.nfuncs = prog->nfuncs;
    bc.main_idx = find_func(prog, "main");
    Compiler c;
    c.bc = &bc;
    c.prog = prog;
    emit(&c, OP_CALL, bc.main_idx);
    emit(&c, OP_HALT, 0);
    for (int i = 0; i < prog->nfuncs; i++) {
        c.nlocals = 0;
        FuncDef *fn = &prog->funcs[i];
        bc.funcs[i].entry_pc = bc.len;
        bc.funcs[i].nparams = fn->nparams;
        for (int p = 0; p < fn->nparams; p++) find_local(&c, fn->params[p]);
        for (int s = 0; s < fn->body_len; s++) comp_stmt(&c, fn->body[s]);
        emit(&c, OP_CONST, 0);
        emit(&c, OP_RET, 0);
        bc.funcs[i].nlocals = c.nlocals;
    }
    return bc;
}

/* ---- Stack VM ---- */
typedef struct {
    int32_t *data;
    int len;
} VmArr;

typedef struct {
    int ret_pc;
    int bp;
} CallFrame;

static int32_t run_vm(const Bytecode *bc, int64_t *out_steps) {
    int32_t stack[8192];
    CallFrame frames[512];
    VmArr *heap = NULL;
    int heap_len = 0, heap_cap = 0;

    int sp = 0;
    int fp = 0;
    int bp = 0;
    int pc = 0;
    int64_t steps = 0;
    const Instr *code = bc->code;

    for (;;) {
        Instr ins = code[pc++];
        steps++;
        switch (ins.op) {
            case OP_CONST:
                stack[sp++] = ins.arg;
                break;
            case OP_LOAD:
                stack[sp++] = stack[bp + ins.arg];
                break;
            case OP_STORE:
                stack[bp + ins.arg] = stack[--sp];
                break;
            case OP_ADD: { int32_t b = stack[--sp]; stack[sp - 1] += b; break; }
            case OP_SUB: { int32_t b = stack[--sp]; stack[sp - 1] -= b; break; }
            case OP_MUL: { int32_t b = stack[--sp]; stack[sp - 1] *= b; break; }
            case OP_DIV: { int32_t b = stack[--sp]; stack[sp - 1] /= b; break; }
            case OP_MOD: { int32_t b = stack[--sp]; stack[sp - 1] %= b; break; }
            case OP_EQ:  { int32_t b = stack[--sp]; stack[sp - 1] = (stack[sp - 1] == b) ? 1 : 0; break; }
            case OP_LT:  { int32_t b = stack[--sp]; stack[sp - 1] = (stack[sp - 1] < b) ? 1 : 0; break; }
            case OP_LE:  { int32_t b = stack[--sp]; stack[sp - 1] = (stack[sp - 1] <= b) ? 1 : 0; break; }
            case OP_AND: { int32_t b = stack[--sp]; stack[sp - 1] = (stack[sp - 1] != 0 && b != 0) ? 1 : 0; break; }
            case OP_OR:  { int32_t b = stack[--sp]; stack[sp - 1] = (stack[sp - 1] != 0 || b != 0) ? 1 : 0; break; }
            case OP_NOT: stack[sp - 1] = (stack[sp - 1] == 0) ? 1 : 0; break;
            case OP_NEG: stack[sp - 1] = -stack[sp - 1]; break;
            case OP_JMP: pc = ins.arg; break;
            case OP_JMP_FALSE: {
                int32_t c = stack[--sp];
                if (c == 0) pc = ins.arg;
                break;
            }
            case OP_CALL: {
                const FuncMeta *fm = &bc->funcs[ins.arg];
                frames[fp].ret_pc = pc;
                frames[fp].bp = bp;
                fp++;
                bp = sp - fm->nparams;
                int extra = fm->nlocals - fm->nparams;
                for (int k = 0; k < extra; k++) stack[sp++] = 0;
                pc = fm->entry_pc;
                break;
            }
            case OP_RET: {
                int32_t rv = stack[--sp];
                sp = bp;
                fp--;
                pc = frames[fp].ret_pc;
                bp = frames[fp].bp;
                stack[sp++] = rv;
                break;
            }
            case OP_POP: sp--; break;
            case OP_ARR_NEW: {
                int32_t sz = stack[--sp];
                if (heap_len == heap_cap) {
                    heap_cap = heap_cap ? heap_cap * 2 : 64;
                    heap = (VmArr *)realloc(heap, (size_t)heap_cap * sizeof(VmArr));
                }
                int id = heap_len++;
                heap[id].data = (int32_t *)calloc((size_t)sz, sizeof(int32_t));
                heap[id].len = sz;
                stack[sp++] = id;
                break;
            }
            case OP_ARR_GET: {
                int32_t idx = stack[--sp];
                int32_t h = stack[--sp];
                stack[sp++] = heap[h].data[idx];
                break;
            }
            case OP_ARR_SET: {
                int32_t val = stack[--sp];
                int32_t idx = stack[--sp];
                int32_t h = stack[--sp];
                heap[h].data[idx] = val;
                break;
            }
            case OP_HALT: {
                int32_t res = stack[sp - 1];
                for (int i = 0; i < heap_len; i++) free(heap[i].data);
                free(heap);
                *out_steps = steps;
                return res;
            }
        }
    }
}

int main(void) {
    int32_t compile_hash = 0;
    Bytecode last_bc = {0};

    for (int iter = 0; iter < 200; iter++) {
        TokList tl = lex(MINI_SRC);
        Program prog = parse_program(&tl);
        Bytecode bc = compile_program(&prog);
        int32_t bh = 0;
        for (int i = 0; i < bc.len; i++) {
            bh = (int32_t)(((uint32_t)bh * 31U + (uint32_t)bc.code[i].op * 7U + (uint32_t)(bc.code[i].arg & 0xffff)) & 0x3fffffffU);
        }
        compile_hash = (int32_t)(((uint32_t)compile_hash * 31U + (uint32_t)bc.len + (uint32_t)bh) & 0x3fffffffU);
        free_program(&prog);
        free(tl.items);
        if (iter == 199) {
            last_bc = bc;
        } else {
            free(bc.code);
        }
    }

    int64_t vm_steps = 0;
    int32_t result = run_vm(&last_bc, &vm_steps);
    free(last_bc.code);

    printf("%d %lld %d\n", compile_hash, (long long)vm_steps, result);
    return 0;
}
