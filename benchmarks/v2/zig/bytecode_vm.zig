// V2 Benchmark 2: bytecode_vm (Zig 0.17.1)
// Stage A: 200x (Lex -> Recursive-Descent AST -> Bytecode Compile)
// Stage B: Stack VM dispatch (~15M-25M instructions)
const std = @import("std");

extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;

const MINI_SRC: []const u8 =
    \\fn fib(n) {
    \\  if (n <= 1) { return n; }
    \\  return fib(n - 1) + fib(n - 2);
    \\}
    \\fn sieve(limit) {
    \\  let flags = new_arr(limit + 1);
    \\  let i = 2;
    \\  while (i <= limit) {
    \\    flags[i] = 1;
    \\    i = i + 1;
    \\  }
    \\  let p = 2;
    \\  while (p * p <= limit) {
    \\    if (flags[p] == 1) {
    \\      let m = p * p;
    \\      while (m <= limit) {
    \\        flags[m] = 0;
    \\        m = m + p;
    \\      }
    \\    }
    \\    p = p + 1;
    \\  }
    \\  let sum = 0;
    \\  let cnt = 0;
    \\  let k = 2;
    \\  while (k <= limit) {
    \\    if (flags[k] == 1) {
    \\      cnt = cnt + 1;
    \\      sum = (sum * 31 + k) % 1000003;
    \\    }
    \\    k = k + 1;
    \\  }
    \\  return (sum + cnt * 17) % 1000003;
    \\}
    \\fn sort_and_hash(n, seed) {
    \\  let a = new_arr(n);
    \\  let s = seed;
    \\  let i = 0;
    \\  while (i < n) {
    \\    s = (s * 1103 + 12345) % 65536;
    \\    a[i] = s % 10000;
    \\    i = i + 1;
    \\  }
    \\  let j = 1;
    \\  while (j < n) {
    \\    let key = a[j];
    \\    let k = j - 1;
    \\    while (k >= 0 && a[k] > key) {
    \\      a[k + 1] = a[k];
    \\      k = k - 1;
    \\    }
    \\    a[k + 1] = key;
    \\    j = j + 1;
    \\  }
    \\  let h = 0;
    \\  let idx = 0;
    \\  while (idx < n) {
    \\    h = (h * 31 + a[idx]) % 1000003;
    \\    idx = idx + 1;
    \\  }
    \\  return h;
    \\}
    \\fn main() {
    \\  let acc = 0;
    \\  let r = 0;
    \\  while (r < 55) {
    \\    let f = fib(22);
    \\    let sv = sieve(2000);
    \\    let sh = sort_and_hash(120, 42 + r * 7);
    \\    let mix = (f + sv + sh) % 1000003;
    \\    if (r % 2 == 0 || mix < 0) {
    \\      acc = (acc * 3 + mix) % 1000003;
    \\    } else {
    \\      acc = (acc * 5 + mix + 11) % 1000003;
    \\    }
    \\    r = r + 1;
    \\  }
    \\  return acc;
    \\}
;

const TokKind = enum {
    eof, int_lit, ident,
    kw_fn, kw_let, kw_if, kw_else, kw_while, kw_return, kw_newarr,
    lparen, rparen, lbrace, rbrace, lbrack, rbrack,
    comma, semi,
    plus, minus, star, slash, percent,
    eq, eqeq, neq, lt, le, gt, ge,
    andand, oror, bang,
};

const Token = struct {
    kind: TokKind,
    ival: i32 = 0,
    text: []const u8 = "",
};

fn lex(alloc: std.mem.Allocator, src: []const u8) !std.ArrayListUnmanaged(Token) {
    var toks: std.ArrayListUnmanaged(Token) = .empty;
    var i: usize = 0;
    const n = src.len;
    while (i < n) {
        const c = src[i];
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
            i += 1;
            continue;
        }
        if (c >= '0' and c <= '9') {
            var v: i32 = 0;
            while (i < n and src[i] >= '0' and src[i] <= '9') {
                v = v * 10 + @as(i32, src[i] - '0');
                i += 1;
            }
            try toks.append(alloc, .{ .kind = .int_lit, .ival = v });
            continue;
        }
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
            const st = i;
            while (i < n and ((src[i] >= 'a' and src[i] <= 'z') or (src[i] >= 'A' and src[i] <= 'Z') or
                (src[i] >= '0' and src[i] <= '9') or src[i] == '_')) : (i += 1)
            {}
            const txt = src[st..i];
            const k: TokKind = if (std.mem.eql(u8, txt, "fn")) .kw_fn
                else if (std.mem.eql(u8, txt, "let")) .kw_let
                else if (std.mem.eql(u8, txt, "if")) .kw_if
                else if (std.mem.eql(u8, txt, "else")) .kw_else
                else if (std.mem.eql(u8, txt, "while")) .kw_while
                else if (std.mem.eql(u8, txt, "return")) .kw_return
                else if (std.mem.eql(u8, txt, "new_arr")) .kw_newarr
                else .ident;
            try toks.append(alloc, .{ .kind = k, .text = txt });
            continue;
        }
        const c2: u8 = if (i + 1 < n) src[i + 1] else 0;
        if (c == '=' and c2 == '=') { try toks.append(alloc, .{ .kind = .eqeq }); i += 2; continue; }
        if (c == '!' and c2 == '=') { try toks.append(alloc, .{ .kind = .neq }); i += 2; continue; }
        if (c == '<' and c2 == '=') { try toks.append(alloc, .{ .kind = .le }); i += 2; continue; }
        if (c == '>' and c2 == '=') { try toks.append(alloc, .{ .kind = .ge }); i += 2; continue; }
        if (c == '&' and c2 == '&') { try toks.append(alloc, .{ .kind = .andand }); i += 2; continue; }
        if (c == '|' and c2 == '|') { try toks.append(alloc, .{ .kind = .oror }); i += 2; continue; }
        const k: TokKind = switch (c) {
            '(' => .lparen, ')' => .rparen, '{' => .lbrace, '}' => .rbrace,
            '[' => .lbrack, ']' => .rbrack, ',' => .comma, ';' => .semi,
            '+' => .plus, '-' => .minus, '*' => .star, '/' => .slash, '%' => .percent,
            '=' => .eq, '<' => .lt, '>' => .gt, '!' => .bang,
            else => return error.UnexpectedChar,
        };
        try toks.append(alloc, .{ .kind = k });
        i += 1;
    }
    try toks.append(alloc, .{ .kind = .eof });
    return toks;
}

const Expr = union(enum) {
    int_val: i32,
    var_ref: []const u8,
    unary: struct { op: TokKind, inner: *Expr },
    bin: struct { op: TokKind, lhs: *Expr, rhs: *Expr },
    call: struct { name: []const u8, args: std.ArrayListUnmanaged(*Expr) },
    new_arr: *Expr,
    index: struct { arr: *Expr, idx: *Expr },
};

const Stmt = union(enum) {
    let_stmt: struct { name: []const u8, e: *Expr },
    assign: struct { name: []const u8, e: *Expr },
    arr_set: struct { name: []const u8, idx: *Expr, val: *Expr },
    if_stmt: struct { cond: *Expr, body: std.ArrayListUnmanaged(*Stmt), else_body: std.ArrayListUnmanaged(*Stmt) },
    while_stmt: struct { cond: *Expr, body: std.ArrayListUnmanaged(*Stmt) },
    ret_stmt: *Expr,
    expr_stmt: *Expr,
};

const FuncDef = struct {
    name: []const u8,
    params: std.ArrayListUnmanaged([]const u8),
    body: std.ArrayListUnmanaged(*Stmt),
};

const AstParser = struct {
    alloc: std.mem.Allocator,
    toks: []const Token,
    pos: usize,

    fn peek(self: *const AstParser) TokKind { return self.toks[self.pos].kind; }
    fn nextT(self: *AstParser) Token {
        const t = self.toks[self.pos];
        self.pos += 1;
        return t;
    }

    fn parsePrimary(self: *AstParser) anyerror!*Expr {
        const k = self.peek();
        if (k == .int_lit) {
            const e = try self.alloc.create(Expr);
            e.* = .{ .int_val = self.nextT().ival };
            return e;
        }
        if (k == .kw_newarr) {
            _ = self.nextT();
            _ = self.nextT();
            const sz = try self.parseExpr();
            _ = self.nextT();
            const e = try self.alloc.create(Expr);
            e.* = .{ .new_arr = sz };
            return e;
        }
        if (k == .lparen) {
            _ = self.nextT();
            const e = try self.parseExpr();
            _ = self.nextT();
            return e;
        }
        const t = self.nextT();
        if (self.peek() == .lparen) {
            _ = self.nextT();
            var args: std.ArrayListUnmanaged(*Expr) = .empty;
            if (self.peek() != .rparen) {
                while (true) {
                    try args.append(self.alloc, try self.parseExpr());
                    if (self.peek() == .comma) _ = self.nextT() else break;
                }
            }
            _ = self.nextT();
            const e = try self.alloc.create(Expr);
            e.* = .{ .call = .{ .name = t.text, .args = args } };
            return e;
        }
        const base = try self.alloc.create(Expr);
        base.* = .{ .var_ref = t.text };
        if (self.peek() == .lbrack) {
            _ = self.nextT();
            const idx = try self.parseExpr();
            _ = self.nextT();
            const ix = try self.alloc.create(Expr);
            ix.* = .{ .index = .{ .arr = base, .idx = idx } };
            return ix;
        }
        return base;
    }

    fn parseUnary(self: *AstParser) anyerror!*Expr {
        const k = self.peek();
        if (k == .minus or k == .bang) {
            _ = self.nextT();
            const e = try self.alloc.create(Expr);
            e.* = .{ .unary = .{ .op = k, .inner = try self.parseUnary() } };
            return e;
        }
        return self.parsePrimary();
    }

    fn parseMul(self: *AstParser) anyerror!*Expr {
        var l = try self.parseUnary();
        while (self.peek() == .star or self.peek() == .slash or self.peek() == .percent) {
            const op = self.nextT().kind;
            const r = try self.parseUnary();
            const b = try self.alloc.create(Expr);
            b.* = .{ .bin = .{ .op = op, .lhs = l, .rhs = r } };
            l = b;
        }
        return l;
    }

    fn parseAdd(self: *AstParser) anyerror!*Expr {
        var l = try self.parseMul();
        while (self.peek() == .plus or self.peek() == .minus) {
            const op = self.nextT().kind;
            const r = try self.parseMul();
            const b = try self.alloc.create(Expr);
            b.* = .{ .bin = .{ .op = op, .lhs = l, .rhs = r } };
            l = b;
        }
        return l;
    }

    fn parseRel(self: *AstParser) anyerror!*Expr {
        var l = try self.parseAdd();
        while (true) {
            const k = self.peek();
            if (k == .lt or k == .le or k == .gt or k == .ge or k == .eqeq or k == .neq) {
                _ = self.nextT();
                const r = try self.parseAdd();
                const b = try self.alloc.create(Expr);
                b.* = .{ .bin = .{ .op = k, .lhs = l, .rhs = r } };
                l = b;
            } else break;
        }
        return l;
    }

    fn parseAnd(self: *AstParser) anyerror!*Expr {
        var l = try self.parseRel();
        while (self.peek() == .andand) {
            _ = self.nextT();
            const r = try self.parseRel();
            const b = try self.alloc.create(Expr);
            b.* = .{ .bin = .{ .op = .andand, .lhs = l, .rhs = r } };
            l = b;
        }
        return l;
    }

    fn parseExpr(self: *AstParser) anyerror!*Expr {
        var l = try self.parseAnd();
        while (self.peek() == .oror) {
            _ = self.nextT();
            const r = try self.parseAnd();
            const b = try self.alloc.create(Expr);
            b.* = .{ .bin = .{ .op = .oror, .lhs = l, .rhs = r } };
            l = b;
        }
        return l;
    }

    fn parseStmt(self: *AstParser) anyerror!*Stmt {
        const k = self.peek();
        if (k == .kw_let) {
            _ = self.nextT();
            const name = self.nextT().text;
            _ = self.nextT();
            const e = try self.parseExpr();
            _ = self.nextT();
            const s = try self.alloc.create(Stmt);
            s.* = .{ .let_stmt = .{ .name = name, .e = e } };
            return s;
        }
        if (k == .kw_if) {
            _ = self.nextT();
            _ = self.nextT();
            const cond = try self.parseExpr();
            _ = self.nextT();
            const body = try self.parseBlock();
            var else_body: std.ArrayListUnmanaged(*Stmt) = .empty;
            if (self.peek() == .kw_else) {
                _ = self.nextT();
                else_body = try self.parseBlock();
            }
            const s = try self.alloc.create(Stmt);
            s.* = .{ .if_stmt = .{ .cond = cond, .body = body, .else_body = else_body } };
            return s;
        }
        if (k == .kw_while) {
            _ = self.nextT();
            _ = self.nextT();
            const cond = try self.parseExpr();
            _ = self.nextT();
            const body = try self.parseBlock();
            const s = try self.alloc.create(Stmt);
            s.* = .{ .while_stmt = .{ .cond = cond, .body = body } };
            return s;
        }
        if (k == .kw_return) {
            _ = self.nextT();
            const e = try self.parseExpr();
            _ = self.nextT();
            const s = try self.alloc.create(Stmt);
            s.* = .{ .ret_stmt = e };
            return s;
        }
        if (k == .ident and self.toks[self.pos + 1].kind == .eq) {
            const name = self.nextT().text;
            _ = self.nextT();
            const e = try self.parseExpr();
            _ = self.nextT();
            const s = try self.alloc.create(Stmt);
            s.* = .{ .assign = .{ .name = name, .e = e } };
            return s;
        }
        if (k == .ident and self.toks[self.pos + 1].kind == .lbrack) {
            const name = self.nextT().text;
            _ = self.nextT();
            const idx = try self.parseExpr();
            _ = self.nextT();
            _ = self.nextT();
            const val = try self.parseExpr();
            _ = self.nextT();
            const s = try self.alloc.create(Stmt);
            s.* = .{ .arr_set = .{ .name = name, .idx = idx, .val = val } };
            return s;
        }
        const e = try self.parseExpr();
        _ = self.nextT();
        const s = try self.alloc.create(Stmt);
        s.* = .{ .expr_stmt = e };
        return s;
    }

    fn parseBlock(self: *AstParser) anyerror!std.ArrayListUnmanaged(*Stmt) {
        _ = self.nextT();
        var stmts: std.ArrayListUnmanaged(*Stmt) = .empty;
        while (self.peek() != .rbrace and self.peek() != .eof) {
            try stmts.append(self.alloc, try self.parseStmt());
        }
        _ = self.nextT();
        return stmts;
    }

    fn parseProgram(self: *AstParser) !std.ArrayListUnmanaged(FuncDef) {
        var funcs: std.ArrayListUnmanaged(FuncDef) = .empty;
        while (self.peek() == .kw_fn) {
            _ = self.nextT();
            const name = self.nextT().text;
            _ = self.nextT();
            var params: std.ArrayListUnmanaged([]const u8) = .empty;
            if (self.peek() != .rparen) {
                while (true) {
                    try params.append(self.alloc, self.nextT().text);
                    if (self.peek() == .comma) _ = self.nextT() else break;
                }
            }
            _ = self.nextT();
            const body = try self.parseBlock();
            try funcs.append(self.alloc, .{ .name = name, .params = params, .body = body });
        }
        return funcs;
    }
};

const OP_CONST: i32 = 0;
const OP_LOAD: i32 = 1;
const OP_STORE: i32 = 2;
const OP_ADD: i32 = 3;
const OP_SUB: i32 = 4;
const OP_MUL: i32 = 5;
const OP_DIV: i32 = 6;
const OP_MOD: i32 = 7;
const OP_EQ: i32 = 8;
const OP_LT: i32 = 9;
const OP_LE: i32 = 10;
const OP_AND: i32 = 11;
const OP_OR: i32 = 12;
const OP_NOT: i32 = 13;
const OP_NEG: i32 = 14;
const OP_JMP: i32 = 15;
const OP_JMP_FALSE: i32 = 16;
const OP_CALL: i32 = 17;
const OP_RET: i32 = 18;
const OP_POP: i32 = 19;
const OP_ARR_NEW: i32 = 20;
const OP_ARR_GET: i32 = 21;
const OP_ARR_SET: i32 = 22;
const OP_HALT: i32 = 23;

const Instr = struct { op: i32, arg: i32 };
const FuncMeta = struct { entry_pc: usize, nparams: usize, nlocals: usize };
const Bytecode = struct {
    code: std.ArrayListUnmanaged(Instr),
    funcs: std.ArrayListUnmanaged(FuncMeta),
};

const Compiler = struct {
    alloc: std.mem.Allocator,
    code: std.ArrayListUnmanaged(Instr),
    prog: []const FuncDef,
    locals: std.ArrayListUnmanaged([]const u8),

    fn emit(self: *Compiler, op: i32, arg: i32) !usize {
        const idx = self.code.items.len;
        try self.code.append(self.alloc, .{ .op = op, .arg = arg });
        return idx;
    }

    fn findLocal(self: *Compiler, name: []const u8) !i32 {
        for (self.locals.items, 0..) |l, i| {
            if (std.mem.eql(u8, l, name)) return @intCast(i);
        }
        const idx: i32 = @intCast(self.locals.items.len);
        try self.locals.append(self.alloc, name);
        return idx;
    }

    fn findFunc(self: *const Compiler, name: []const u8) i32 {
        for (self.prog, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) return @intCast(i);
        }
        return 0;
    }

    fn compExpr(self: *Compiler, e: *const Expr) anyerror!void {
        switch (e.*) {
            .int_val => |v| _ = try self.emit(OP_CONST, v),
            .var_ref => |name| _ = try self.emit(OP_LOAD, try self.findLocal(name)),
            .new_arr => |sz| {
                try self.compExpr(sz);
                _ = try self.emit(OP_ARR_NEW, 0);
            },
            .index => |ix| {
                try self.compExpr(ix.arr);
                try self.compExpr(ix.idx);
                _ = try self.emit(OP_ARR_GET, 0);
            },
            .unary => |u| {
                try self.compExpr(u.inner);
                _ = try self.emit(if (u.op == .minus) OP_NEG else OP_NOT, 0);
            },
            .call => |cl| {
                for (cl.args.items) |a| try self.compExpr(a);
                _ = try self.emit(OP_CALL, self.findFunc(cl.name));
            },
            .bin => |b| {
                if (b.op == .andand) {
                    try self.compExpr(b.lhs);
                    const j1 = try self.emit(OP_JMP_FALSE, 0);
                    try self.compExpr(b.rhs);
                    _ = try self.emit(OP_CONST, 0);
                    _ = try self.emit(OP_EQ, 0);
                    _ = try self.emit(OP_NOT, 0);
                    const j2 = try self.emit(OP_JMP, 0);
                    self.code.items[j1].arg = @intCast(self.code.items.len);
                    _ = try self.emit(OP_CONST, 0);
                    self.code.items[j2].arg = @intCast(self.code.items.len);
                    return;
                }
                if (b.op == .oror) {
                    try self.compExpr(b.lhs);
                    const j1 = try self.emit(OP_JMP_FALSE, 0);
                    _ = try self.emit(OP_CONST, 1);
                    const j2 = try self.emit(OP_JMP, 0);
                    self.code.items[j1].arg = @intCast(self.code.items.len);
                    try self.compExpr(b.rhs);
                    _ = try self.emit(OP_CONST, 0);
                    _ = try self.emit(OP_EQ, 0);
                    _ = try self.emit(OP_NOT, 0);
                    self.code.items[j2].arg = @intCast(self.code.items.len);
                    return;
                }
                try self.compExpr(b.lhs);
                try self.compExpr(b.rhs);
                switch (b.op) {
                    .plus => _ = try self.emit(OP_ADD, 0),
                    .minus => _ = try self.emit(OP_SUB, 0),
                    .star => _ = try self.emit(OP_MUL, 0),
                    .slash => _ = try self.emit(OP_DIV, 0),
                    .percent => _ = try self.emit(OP_MOD, 0),
                    .eqeq => _ = try self.emit(OP_EQ, 0),
                    .neq => { _ = try self.emit(OP_EQ, 0); _ = try self.emit(OP_NOT, 0); },
                    .lt => _ = try self.emit(OP_LT, 0),
                    .le => _ = try self.emit(OP_LE, 0),
                    .gt => { _ = try self.emit(OP_LE, 0); _ = try self.emit(OP_NOT, 0); },
                    .ge => { _ = try self.emit(OP_LT, 0); _ = try self.emit(OP_NOT, 0); },
                    else => {},
                }
            },
        }
    }

    fn compStmt(self: *Compiler, s: *const Stmt) anyerror!void {
        switch (s.*) {
            .let_stmt => |ls| {
                const slot = try self.findLocal(ls.name);
                try self.compExpr(ls.e);
                _ = try self.emit(OP_STORE, slot);
            },
            .assign => |as| {
                const slot = try self.findLocal(as.name);
                try self.compExpr(as.e);
                _ = try self.emit(OP_STORE, slot);
            },
            .arr_set => |ar| {
                const slot = try self.findLocal(ar.name);
                _ = try self.emit(OP_LOAD, slot);
                try self.compExpr(ar.idx);
                try self.compExpr(ar.val);
                _ = try self.emit(OP_ARR_SET, 0);
            },
            .ret_stmt => |e| {
                try self.compExpr(e);
                _ = try self.emit(OP_RET, 0);
            },
            .expr_stmt => |e| {
                try self.compExpr(e);
                _ = try self.emit(OP_POP, 0);
            },
            .if_stmt => |is| {
                try self.compExpr(is.cond);
                const jf = try self.emit(OP_JMP_FALSE, 0);
                for (is.body.items) |st| try self.compStmt(st);
                if (is.else_body.items.len > 0) {
                    const je = try self.emit(OP_JMP, 0);
                    self.code.items[jf].arg = @intCast(self.code.items.len);
                    for (is.else_body.items) |st| try self.compStmt(st);
                    self.code.items[je].arg = @intCast(self.code.items.len);
                } else {
                    self.code.items[jf].arg = @intCast(self.code.items.len);
                }
            },
            .while_stmt => |ws| {
                const loop_pc: i32 = @intCast(self.code.items.len);
                try self.compExpr(ws.cond);
                const jf = try self.emit(OP_JMP_FALSE, 0);
                for (ws.body.items) |st| try self.compStmt(st);
                _ = try self.emit(OP_JMP, loop_pc);
                self.code.items[jf].arg = @intCast(self.code.items.len);
            },
        }
    }
};

fn compileProgram(alloc: std.mem.Allocator, prog: []const FuncDef) !Bytecode {
    var c = Compiler{ .alloc = alloc, .code = .empty, .prog = prog, .locals = .empty };
    defer c.locals.deinit(alloc);
    const main_idx = c.findFunc("main");
    _ = try c.emit(OP_CALL, main_idx);
    _ = try c.emit(OP_HALT, 0);
    var funcs: std.ArrayListUnmanaged(FuncMeta) = .empty;
    for (prog) |f| {
        c.locals.clearRetainingCapacity();
        const entry_pc = c.code.items.len;
        for (f.params.items) |p| _ = try c.findLocal(p);
        for (f.body.items) |s| try c.compStmt(s);
        _ = try c.emit(OP_CONST, 0);
        _ = try c.emit(OP_RET, 0);
        try funcs.append(alloc, .{
            .entry_pc = entry_pc,
            .nparams = f.params.items.len,
            .nlocals = c.locals.items.len,
        });
    }
    return .{ .code = c.code, .funcs = funcs };
}

fn runVm(alloc: std.mem.Allocator, bc: *const Bytecode) !struct { steps: i64, value: i32 } {
    var stack: [8192]i32 = @splat(0);
    var frame_pc: [512]usize = @splat(0);
    var frame_bp: [512]usize = @splat(0);
    var heap: std.ArrayListUnmanaged([]i32) = .empty;
    defer {
        for (heap.items) |arr| alloc.free(arr);
        heap.deinit(alloc);
    }

    var sp: usize = 0;
    var fp: usize = 0;
    var bp: usize = 0;
    var pc: usize = 0;
    var steps: i64 = 0;
    const code = bc.code.items;
    const funcs = bc.funcs.items;

    while (true) {
        const ins = code[pc];
        pc += 1;
        steps += 1;
        switch (ins.op) {
            OP_CONST => { stack[sp] = ins.arg; sp += 1; },
            OP_LOAD => { stack[sp] = stack[bp + @as(usize, @intCast(ins.arg))]; sp += 1; },
            OP_STORE => { sp -= 1; stack[bp + @as(usize, @intCast(ins.arg))] = stack[sp]; },
            OP_ADD => { sp -= 1; stack[sp - 1] += stack[sp]; },
            OP_SUB => { sp -= 1; stack[sp - 1] -= stack[sp]; },
            OP_MUL => { sp -= 1; stack[sp - 1] *= stack[sp]; },
            OP_DIV => { sp -= 1; stack[sp - 1] = @divTrunc(stack[sp - 1], stack[sp]); },
            OP_MOD => { sp -= 1; stack[sp - 1] = @rem(stack[sp - 1], stack[sp]); },
            OP_EQ => { sp -= 1; stack[sp - 1] = if (stack[sp - 1] == stack[sp]) 1 else 0; },
            OP_LT => { sp -= 1; stack[sp - 1] = if (stack[sp - 1] < stack[sp]) 1 else 0; },
            OP_LE => { sp -= 1; stack[sp - 1] = if (stack[sp - 1] <= stack[sp]) 1 else 0; },
            OP_AND => { sp -= 1; stack[sp - 1] = if (stack[sp - 1] != 0 and stack[sp] != 0) 1 else 0; },
            OP_OR => { sp -= 1; stack[sp - 1] = if (stack[sp - 1] != 0 or stack[sp] != 0) 1 else 0; },
            OP_NOT => { stack[sp - 1] = if (stack[sp - 1] == 0) 1 else 0; },
            OP_NEG => { stack[sp - 1] = -stack[sp - 1]; },
            OP_JMP => { pc = @intCast(ins.arg); },
            OP_JMP_FALSE => {
                sp -= 1;
                if (stack[sp] == 0) pc = @intCast(ins.arg);
            },
            OP_CALL => {
                const fm = funcs[@intCast(ins.arg)];
                frame_pc[fp] = pc;
                frame_bp[fp] = bp;
                fp += 1;
                bp = sp - fm.nparams;
                const extra = fm.nlocals - fm.nparams;
                for (0..extra) |_| {
                    stack[sp] = 0;
                    sp += 1;
                }
                pc = fm.entry_pc;
            },
            OP_RET => {
                sp -= 1;
                const rv = stack[sp];
                sp = bp;
                fp -= 1;
                pc = frame_pc[fp];
                bp = frame_bp[fp];
                stack[sp] = rv;
                sp += 1;
            },
            OP_POP => { sp -= 1; },
            OP_ARR_NEW => {
                sp -= 1;
                const sz: usize = @intCast(stack[sp]);
                const arr = try alloc.alloc(i32, sz);
                @memset(arr, 0);
                const id: i32 = @intCast(heap.items.len);
                try heap.append(alloc, arr);
                stack[sp] = id;
                sp += 1;
            },
            OP_ARR_GET => {
                sp -= 1;
                const idx: usize = @intCast(stack[sp]);
                sp -= 1;
                const h: usize = @intCast(stack[sp]);
                stack[sp] = heap.items[h][idx];
                sp += 1;
            },
            OP_ARR_SET => {
                sp -= 1;
                const val = stack[sp];
                sp -= 1;
                const idx: usize = @intCast(stack[sp]);
                sp -= 1;
                const h: usize = @intCast(stack[sp]);
                heap.items[h][idx] = val;
            },
            else => return .{ .steps = steps, .value = stack[sp - 1] },
        }
    }
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    var compile_hash: u32 = 0;
    var last_bc: Bytecode = .{ .code = .empty, .funcs = .empty };
    defer {
        last_bc.code.deinit(alloc);
        last_bc.funcs.deinit(alloc);
    }

    var iter: usize = 0;
    while (iter < 200) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const toks = try lex(a, MINI_SRC);
        var p = AstParser{ .alloc = a, .toks = toks.items, .pos = 0 };
        const prog = try p.parseProgram();
        var bc = try compileProgram(alloc, prog.items);

        var bh: u32 = 0;
        for (bc.code.items) |ins| {
            const op_u: u32 = @bitCast(ins.op);
            const arg_u: u32 = @bitCast(ins.arg & 0xffff);
            bh = (bh *% 31 +% op_u *% 7 +% arg_u) & 0x3fffffff;
        }
        compile_hash = (compile_hash *% 31 +% @as(u32, @intCast(bc.code.items.len)) +% bh) & 0x3fffffff;
        if (iter == 199) {
            last_bc = bc;
        } else {
            bc.code.deinit(alloc);
            bc.funcs.deinit(alloc);
        }
    }

    const res = try runVm(alloc, &last_bc);
    _ = printf("%d %lld %d\n", @as(i32, @intCast(compile_hash)), @as(c_longlong, res.steps), res.value);
}
