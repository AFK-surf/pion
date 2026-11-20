// V2 Benchmark 2: bytecode_vm (Rust)
// Stage A: 200x (Lex -> Recursive-Descent AST -> Bytecode Compile)
// Stage B: Stack VM dispatch (~15M-25M instructions)

const MINI_SRC: &str = "\
fn fib(n) {
  if (n <= 1) { return n; }
  return fib(n - 1) + fib(n - 2);
}
fn sieve(limit) {
  let flags = new_arr(limit + 1);
  let i = 2;
  while (i <= limit) {
    flags[i] = 1;
    i = i + 1;
  }
  let p = 2;
  while (p * p <= limit) {
    if (flags[p] == 1) {
      let m = p * p;
      while (m <= limit) {
        flags[m] = 0;
        m = m + p;
      }
    }
    p = p + 1;
  }
  let sum = 0;
  let cnt = 0;
  let k = 2;
  while (k <= limit) {
    if (flags[k] == 1) {
      cnt = cnt + 1;
      sum = (sum * 31 + k) % 1000003;
    }
    k = k + 1;
  }
  return (sum + cnt * 17) % 1000003;
}
fn sort_and_hash(n, seed) {
  let a = new_arr(n);
  let s = seed;
  let i = 0;
  while (i < n) {
    s = (s * 1103 + 12345) % 65536;
    a[i] = s % 10000;
    i = i + 1;
  }
  let j = 1;
  while (j < n) {
    let key = a[j];
    let k = j - 1;
    while (k >= 0 && a[k] > key) {
      a[k + 1] = a[k];
      k = k - 1;
    }
    a[k + 1] = key;
    j = j + 1;
  }
  let h = 0;
  let idx = 0;
  while (idx < n) {
    h = (h * 31 + a[idx]) % 1000003;
    idx = idx + 1;
  }
  return h;
}
fn main() {
  let acc = 0;
  let r = 0;
  while (r < 55) {
    let f = fib(22);
    let sv = sieve(2000);
    let sh = sort_and_hash(120, 42 + r * 7);
    let mix = (f + sv + sh) % 1000003;
    if (r % 2 == 0 || mix < 0) {
      acc = (acc * 3 + mix) % 1000003;
    } else {
      acc = (acc * 5 + mix + 11) % 1000003;
    }
    r = r + 1;
  }
  return acc;
}
";

#[derive(Clone, Copy, PartialEq, Eq)]
enum TokKind {
    Eof, Int, Ident,
    Fn, Let, If, Else, While, Return, NewArr,
    LParen, RParen, LBrace, RBrace, LBrack, RBrack,
    Comma, Semi,
    Plus, Minus, Star, Slash, Percent,
    Eq, EqEq, Neq, Lt, Le, Gt, Ge,
    AndAnd, OrOr, Bang,
}

struct Token {
    kind: TokKind,
    ival: i32,
    text: String,
}

fn lex(src: &str) -> Vec<Token> {
    let b = src.as_bytes();
    let n = b.len();
    let mut i = 0;
    let mut toks = Vec::with_capacity(256);
    while i < n {
        let c = b[i];
        if c == b' ' || c == b'\n' || c == b'\r' || c == b'\t' {
            i += 1;
            continue;
        }
        if c >= b'0' && c <= b'9' {
            let mut v: i32 = 0;
            while i < n && b[i] >= b'0' && b[i] <= b'9' {
                v = v * 10 + (b[i] - b'0') as i32;
                i += 1;
            }
            toks.push(Token { kind: TokKind::Int, ival: v, text: String::new() });
            continue;
        }
        if (c >= b'a' && c <= b'z') || (c >= b'A' && c <= b'Z') || c == b'_' {
            let st = i;
            while i < n
                && ((b[i] >= b'a' && b[i] <= b'z')
                    || (b[i] >= b'A' && b[i] <= b'Z')
                    || (b[i] >= b'0' && b[i] <= b'9')
                    || b[i] == b'_')
            {
                i += 1;
            }
            let txt = &src[st..i];
            let kind = match txt {
                "fn" => TokKind::Fn,
                "let" => TokKind::Let,
                "if" => TokKind::If,
                "else" => TokKind::Else,
                "while" => TokKind::While,
                "return" => TokKind::Return,
                "new_arr" => TokKind::NewArr,
                _ => TokKind::Ident,
            };
            toks.push(Token { kind, ival: 0, text: txt.to_string() });
            continue;
        }
        let c2 = if i + 1 < n { b[i + 1] } else { 0 };
        if c == b'=' && c2 == b'=' { toks.push(Token { kind: TokKind::EqEq, ival: 0, text: String::new() }); i += 2; continue; }
        if c == b'!' && c2 == b'=' { toks.push(Token { kind: TokKind::Neq, ival: 0, text: String::new() }); i += 2; continue; }
        if c == b'<' && c2 == b'=' { toks.push(Token { kind: TokKind::Le, ival: 0, text: String::new() }); i += 2; continue; }
        if c == b'>' && c2 == b'=' { toks.push(Token { kind: TokKind::Ge, ival: 0, text: String::new() }); i += 2; continue; }
        if c == b'&' && c2 == b'&' { toks.push(Token { kind: TokKind::AndAnd, ival: 0, text: String::new() }); i += 2; continue; }
        if c == b'|' && c2 == b'|' { toks.push(Token { kind: TokKind::OrOr, ival: 0, text: String::new() }); i += 2; continue; }
        let kind = match c {
            b'(' => TokKind::LParen,
            b')' => TokKind::RParen,
            b'{' => TokKind::LBrace,
            b'}' => TokKind::RBrace,
            b'[' => TokKind::LBrack,
            b']' => TokKind::RBrack,
            b',' => TokKind::Comma,
            b';' => TokKind::Semi,
            b'+' => TokKind::Plus,
            b'-' => TokKind::Minus,
            b'*' => TokKind::Star,
            b'/' => TokKind::Slash,
            b'%' => TokKind::Percent,
            b'=' => TokKind::Eq,
            b'<' => TokKind::Lt,
            b'>' => TokKind::Gt,
            b'!' => TokKind::Bang,
            _ => panic!("unexpected char"),
        };
        toks.push(Token { kind, ival: 0, text: String::new() });
        i += 1;
    }
    toks.push(Token { kind: TokKind::Eof, ival: 0, text: String::new() });
    toks
}

enum Expr {
    Int(i32),
    Var(String),
    Unary(TokKind, Box<Expr>),
    Bin(TokKind, Box<Expr>, Box<Expr>),
    Call(String, Vec<Expr>),
    NewArr(Box<Expr>),
    Index(Box<Expr>, Box<Expr>),
}

enum Stmt {
    Let(String, Expr),
    Assign(String, Expr),
    ArrSet(String, Expr, Expr),
    If(Expr, Vec<Stmt>, Vec<Stmt>),
    While(Expr, Vec<Stmt>),
    Return(Expr),
    Expr(Expr),
}

struct FuncDef {
    name: String,
    params: Vec<String>,
    body: Vec<Stmt>,
}

struct AstParser<'a> {
    toks: &'a [Token],
    pos: usize,
}

impl<'a> AstParser<'a> {
    fn peek(&self) -> TokKind { self.toks[self.pos].kind }
    fn next_t(&mut self) -> &'a Token {
        let t = &self.toks[self.pos];
        self.pos += 1;
        t
    }

    fn parse_primary(&mut self) -> Expr {
        match self.peek() {
            TokKind::Int => Expr::Int(self.next_t().ival),
            TokKind::NewArr => {
                self.next_t();
                self.next_t(); // (
                let sz = self.parse_expr();
                self.next_t(); // )
                Expr::NewArr(Box::new(sz))
            }
            TokKind::LParen => {
                self.next_t();
                let e = self.parse_expr();
                self.next_t();
                e
            }
            TokKind::Ident => {
                let name = self.next_t().text.clone();
                if self.peek() == TokKind::LParen {
                    self.next_t();
                    let mut args = Vec::new();
                    if self.peek() != TokKind::RParen {
                        loop {
                            args.push(self.parse_expr());
                            if self.peek() == TokKind::Comma {
                                self.next_t();
                            } else {
                                break;
                            }
                        }
                    }
                    self.next_t();
                    return Expr::Call(name, args);
                }
                let base = Expr::Var(name);
                if self.peek() == TokKind::LBrack {
                    self.next_t();
                    let idx = self.parse_expr();
                    self.next_t();
                    return Expr::Index(Box::new(base), Box::new(idx));
                }
                base
            }
            _ => panic!("unexpected primary"),
        }
    }

    fn parse_unary(&mut self) -> Expr {
        let k = self.peek();
        if k == TokKind::Minus || k == TokKind::Bang {
            self.next_t();
            return Expr::Unary(k, Box::new(self.parse_unary()));
        }
        self.parse_primary()
    }

    fn parse_mul(&mut self) -> Expr {
        let mut l = self.parse_unary();
        while matches!(self.peek(), TokKind::Star | TokKind::Slash | TokKind::Percent) {
            let op = self.next_t().kind;
            let r = self.parse_unary();
            l = Expr::Bin(op, Box::new(l), Box::new(r));
        }
        l
    }

    fn parse_add(&mut self) -> Expr {
        let mut l = self.parse_mul();
        while matches!(self.peek(), TokKind::Plus | TokKind::Minus) {
            let op = self.next_t().kind;
            let r = self.parse_mul();
            l = Expr::Bin(op, Box::new(l), Box::new(r));
        }
        l
    }

    fn parse_rel(&mut self) -> Expr {
        let mut l = self.parse_add();
        while matches!(
            self.peek(),
            TokKind::Lt | TokKind::Le | TokKind::Gt | TokKind::Ge | TokKind::EqEq | TokKind::Neq
        ) {
            let op = self.next_t().kind;
            let r = self.parse_add();
            l = Expr::Bin(op, Box::new(l), Box::new(r));
        }
        l
    }

    fn parse_and(&mut self) -> Expr {
        let mut l = self.parse_rel();
        while self.peek() == TokKind::AndAnd {
            self.next_t();
            let r = self.parse_rel();
            l = Expr::Bin(TokKind::AndAnd, Box::new(l), Box::new(r));
        }
        l
    }

    fn parse_expr(&mut self) -> Expr {
        let mut l = self.parse_and();
        while self.peek() == TokKind::OrOr {
            self.next_t();
            let r = self.parse_and();
            l = Expr::Bin(TokKind::OrOr, Box::new(l), Box::new(r));
        }
        l
    }

    fn parse_stmt(&mut self) -> Stmt {
        match self.peek() {
            TokKind::Let => {
                self.next_t();
                let name = self.next_t().text.clone();
                self.next_t(); // =
                let e = self.parse_expr();
                self.next_t(); // ;
                Stmt::Let(name, e)
            }
            TokKind::If => {
                self.next_t();
                self.next_t(); // (
                let cond = self.parse_expr();
                self.next_t(); // )
                let body = self.parse_block();
                let else_body = if self.peek() == TokKind::Else {
                    self.next_t();
                    self.parse_block()
                } else {
                    Vec::new()
                };
                Stmt::If(cond, body, else_body)
            }
            TokKind::While => {
                self.next_t();
                self.next_t(); // (
                let cond = self.parse_expr();
                self.next_t(); // )
                let body = self.parse_block();
                Stmt::While(cond, body)
            }
            TokKind::Return => {
                self.next_t();
                let e = self.parse_expr();
                self.next_t(); // ;
                Stmt::Return(e)
            }
            TokKind::Ident if self.toks[self.pos + 1].kind == TokKind::Eq => {
                let name = self.next_t().text.clone();
                self.next_t(); // =
                let e = self.parse_expr();
                self.next_t(); // ;
                Stmt::Assign(name, e)
            }
            TokKind::Ident if self.toks[self.pos + 1].kind == TokKind::LBrack => {
                let name = self.next_t().text.clone();
                self.next_t(); // [
                let idx = self.parse_expr();
                self.next_t(); // ]
                self.next_t(); // =
                let val = self.parse_expr();
                self.next_t(); // ;
                Stmt::ArrSet(name, idx, val)
            }
            _ => {
                let e = self.parse_expr();
                self.next_t(); // ;
                Stmt::Expr(e)
            }
        }
    }

    fn parse_block(&mut self) -> Vec<Stmt> {
        self.next_t(); // {
        let mut stmts = Vec::new();
        while self.peek() != TokKind::RBrace && self.peek() != TokKind::Eof {
            stmts.push(self.parse_stmt());
        }
        self.next_t(); // }
        stmts
    }

    fn parse_program(&mut self) -> Vec<FuncDef> {
        let mut funcs = Vec::new();
        while self.peek() == TokKind::Fn {
            self.next_t();
            let name = self.next_t().text.clone();
            self.next_t(); // (
            let mut params = Vec::new();
            if self.peek() != TokKind::RParen {
                loop {
                    params.push(self.next_t().text.clone());
                    if self.peek() == TokKind::Comma {
                        self.next_t();
                    } else {
                        break;
                    }
                }
            }
            self.next_t(); // )
            let body = self.parse_block();
            funcs.push(FuncDef { name, params, body });
        }
        funcs
    }
}

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

#[derive(Clone, Copy)]
struct Instr {
    op: i32,
    arg: i32,
}

#[derive(Clone, Copy)]
struct FuncMeta {
    entry_pc: usize,
    nparams: usize,
    nlocals: usize,
}

struct Bytecode {
    code: Vec<Instr>,
    funcs: Vec<FuncMeta>,
}

struct Compiler<'a> {
    code: Vec<Instr>,
    prog: &'a [FuncDef],
    locals: Vec<String>,
}

impl<'a> Compiler<'a> {
    fn emit(&mut self, op: i32, arg: i32) -> usize {
        let idx = self.code.len();
        self.code.push(Instr { op, arg });
        idx
    }

    fn find_local(&mut self, name: &str) -> i32 {
        for (i, l) in self.locals.iter().enumerate() {
            if l == name {
                return i as i32;
            }
        }
        let idx = self.locals.len() as i32;
        self.locals.push(name.to_string());
        idx
    }

    fn find_func(&self, name: &str) -> i32 {
        for (i, f) in self.prog.iter().enumerate() {
            if f.name == name {
                return i as i32;
            }
        }
        panic!("unknown func {}", name);
    }

    fn comp_expr(&mut self, e: &Expr) {
        match e {
            Expr::Int(v) => { self.emit(OP_CONST, *v); }
            Expr::Var(name) => {
                let slot = self.find_local(name);
                self.emit(OP_LOAD, slot);
            }
            Expr::NewArr(sz) => {
                self.comp_expr(sz);
                self.emit(OP_ARR_NEW, 0);
            }
            Expr::Index(arr, idx) => {
                self.comp_expr(arr);
                self.comp_expr(idx);
                self.emit(OP_ARR_GET, 0);
            }
            Expr::Unary(op, inner) => {
                self.comp_expr(inner);
                self.emit(if *op == TokKind::Minus { OP_NEG } else { OP_NOT }, 0);
            }
            Expr::Call(name, args) => {
                for a in args {
                    self.comp_expr(a);
                }
                let fi = self.find_func(name);
                self.emit(OP_CALL, fi);
            }
            Expr::Bin(op, lhs, rhs) => {
                if *op == TokKind::AndAnd {
                    self.comp_expr(lhs);
                    let j1 = self.emit(OP_JMP_FALSE, 0);
                    self.comp_expr(rhs);
                    self.emit(OP_CONST, 0);
                    self.emit(OP_EQ, 0);
                    self.emit(OP_NOT, 0);
                    let j2 = self.emit(OP_JMP, 0);
                    self.code[j1].arg = self.code.len() as i32;
                    self.emit(OP_CONST, 0);
                    self.code[j2].arg = self.code.len() as i32;
                    return;
                }
                if *op == TokKind::OrOr {
                    self.comp_expr(lhs);
                    let j1 = self.emit(OP_JMP_FALSE, 0);
                    self.emit(OP_CONST, 1);
                    let j2 = self.emit(OP_JMP, 0);
                    self.code[j1].arg = self.code.len() as i32;
                    self.comp_expr(rhs);
                    self.emit(OP_CONST, 0);
                    self.emit(OP_EQ, 0);
                    self.emit(OP_NOT, 0);
                    self.code[j2].arg = self.code.len() as i32;
                    return;
                }
                self.comp_expr(lhs);
                self.comp_expr(rhs);
                match op {
                    TokKind::Plus => { self.emit(OP_ADD, 0); }
                    TokKind::Minus => { self.emit(OP_SUB, 0); }
                    TokKind::Star => { self.emit(OP_MUL, 0); }
                    TokKind::Slash => { self.emit(OP_DIV, 0); }
                    TokKind::Percent => { self.emit(OP_MOD, 0); }
                    TokKind::EqEq => { self.emit(OP_EQ, 0); }
                    TokKind::Neq => { self.emit(OP_EQ, 0); self.emit(OP_NOT, 0); }
                    TokKind::Lt => { self.emit(OP_LT, 0); }
                    TokKind::Le => { self.emit(OP_LE, 0); }
                    TokKind::Gt => { self.emit(OP_LE, 0); self.emit(OP_NOT, 0); }
                    TokKind::Ge => { self.emit(OP_LT, 0); self.emit(OP_NOT, 0); }
                    _ => {}
                }
            }
        }
    }

    fn comp_stmt(&mut self, s: &Stmt) {
        match s {
            Stmt::Let(name, e) | Stmt::Assign(name, e) => {
                let slot = self.find_local(name);
                self.comp_expr(e);
                self.emit(OP_STORE, slot);
            }
            Stmt::ArrSet(name, idx, val) => {
                let slot = self.find_local(name);
                self.emit(OP_LOAD, slot);
                self.comp_expr(idx);
                self.comp_expr(val);
                self.emit(OP_ARR_SET, 0);
            }
            Stmt::Return(e) => {
                self.comp_expr(e);
                self.emit(OP_RET, 0);
            }
            Stmt::Expr(e) => {
                self.comp_expr(e);
                self.emit(OP_POP, 0);
            }
            Stmt::If(cond, body, else_body) => {
                self.comp_expr(cond);
                let jf = self.emit(OP_JMP_FALSE, 0);
                for st in body {
                    self.comp_stmt(st);
                }
                if !else_body.is_empty() {
                    let je = self.emit(OP_JMP, 0);
                    self.code[jf].arg = self.code.len() as i32;
                    for st in else_body {
                        self.comp_stmt(st);
                    }
                    self.code[je].arg = self.code.len() as i32;
                } else {
                    self.code[jf].arg = self.code.len() as i32;
                }
            }
            Stmt::While(cond, body) => {
                let loop_pc = self.code.len() as i32;
                self.comp_expr(cond);
                let jf = self.emit(OP_JMP_FALSE, 0);
                for st in body {
                    self.comp_stmt(st);
                }
                self.emit(OP_JMP, loop_pc);
                self.code[jf].arg = self.code.len() as i32;
            }
        }
    }
}

fn compile_program(prog: &[FuncDef]) -> Bytecode {
    let mut c = Compiler {
        code: Vec::with_capacity(256),
        prog,
        locals: Vec::new(),
    };
    let main_idx = c.find_func("main");
    c.emit(OP_CALL, main_idx);
    c.emit(OP_HALT, 0);
    let mut funcs = Vec::with_capacity(prog.len());
    for f in prog {
        c.locals.clear();
        let entry_pc = c.code.len();
        for p in &f.params {
            c.find_local(p);
        }
        for s in &f.body {
            c.comp_stmt(s);
        }
        c.emit(OP_CONST, 0);
        c.emit(OP_RET, 0);
        funcs.push(FuncMeta {
            entry_pc,
            nparams: f.params.len(),
            nlocals: c.locals.len(),
        });
    }
    Bytecode { code: c.code, funcs }
}

fn run_vm(bc: &Bytecode) -> (i64, i32) {
    let mut stack = vec![0i32; 8192];
    let mut frame_pc = [0usize; 512];
    let mut frame_bp = [0usize; 512];
    let mut heap: Vec<Vec<i32>> = Vec::with_capacity(64);

    let mut sp: usize = 0;
    let mut fp: usize = 0;
    let mut bp: usize = 0;
    let mut pc: usize = 0;
    let mut steps: i64 = 0;
    let code = &bc.code;
    let funcs = &bc.funcs;

    loop {
        let ins = code[pc];
        pc += 1;
        steps += 1;
        match ins.op {
            OP_CONST => { stack[sp] = ins.arg; sp += 1; }
            OP_LOAD => { stack[sp] = stack[bp + ins.arg as usize]; sp += 1; }
            OP_STORE => { sp -= 1; stack[bp + ins.arg as usize] = stack[sp]; }
            OP_ADD => { sp -= 1; stack[sp - 1] += stack[sp]; }
            OP_SUB => { sp -= 1; stack[sp - 1] -= stack[sp]; }
            OP_MUL => { sp -= 1; stack[sp - 1] *= stack[sp]; }
            OP_DIV => { sp -= 1; stack[sp - 1] /= stack[sp]; }
            OP_MOD => { sp -= 1; stack[sp - 1] %= stack[sp]; }
            OP_EQ => { sp -= 1; stack[sp - 1] = if stack[sp - 1] == stack[sp] { 1 } else { 0 }; }
            OP_LT => { sp -= 1; stack[sp - 1] = if stack[sp - 1] < stack[sp] { 1 } else { 0 }; }
            OP_LE => { sp -= 1; stack[sp - 1] = if stack[sp - 1] <= stack[sp] { 1 } else { 0 }; }
            OP_AND => { sp -= 1; stack[sp - 1] = if stack[sp - 1] != 0 && stack[sp] != 0 { 1 } else { 0 }; }
            OP_OR => { sp -= 1; stack[sp - 1] = if stack[sp - 1] != 0 || stack[sp] != 0 { 1 } else { 0 }; }
            OP_NOT => { stack[sp - 1] = if stack[sp - 1] == 0 { 1 } else { 0 }; }
            OP_NEG => { stack[sp - 1] = -stack[sp - 1]; }
            OP_JMP => { pc = ins.arg as usize; }
            OP_JMP_FALSE => {
                sp -= 1;
                if stack[sp] == 0 { pc = ins.arg as usize; }
            }
            OP_CALL => {
                let fm = funcs[ins.arg as usize];
                frame_pc[fp] = pc;
                frame_bp[fp] = bp;
                fp += 1;
                bp = sp - fm.nparams;
                let extra = fm.nlocals - fm.nparams;
                for _ in 0..extra {
                    stack[sp] = 0;
                    sp += 1;
                }
                pc = fm.entry_pc;
            }
            OP_RET => {
                sp -= 1;
                let rv = stack[sp];
                sp = bp;
                fp -= 1;
                pc = frame_pc[fp];
                bp = frame_bp[fp];
                stack[sp] = rv;
                sp += 1;
            }
            OP_POP => { sp -= 1; }
            OP_ARR_NEW => {
                sp -= 1;
                let sz = stack[sp] as usize;
                let id = heap.len() as i32;
                heap.push(vec![0i32; sz]);
                stack[sp] = id;
                sp += 1;
            }
            OP_ARR_GET => {
                sp -= 1;
                let idx = stack[sp] as usize;
                sp -= 1;
                let h = stack[sp] as usize;
                stack[sp] = heap[h][idx];
                sp += 1;
            }
            OP_ARR_SET => {
                sp -= 1;
                let val = stack[sp];
                sp -= 1;
                let idx = stack[sp] as usize;
                sp -= 1;
                let h = stack[sp] as usize;
                heap[h][idx] = val;
            }
            _ => return (steps, stack[sp - 1]),
        }
    }
}

fn main() {
    let mut compile_hash: u32 = 0;
    let mut last_bc: Option<Bytecode> = None;
    for iter in 0..200 {
        let toks = lex(MINI_SRC);
        let mut parser = AstParser { toks: &toks, pos: 0 };
        let prog = parser.parse_program();
        let bc = compile_program(&prog);
        let mut bh: u32 = 0;
        for ins in &bc.code {
            bh = (bh
                .wrapping_mul(31)
                .wrapping_add((ins.op as u32).wrapping_mul(7))
                .wrapping_add((ins.arg & 0xffff) as u32))
                & 0x3fffffff;
        }
        compile_hash = (compile_hash
            .wrapping_mul(31)
            .wrapping_add(bc.code.len() as u32)
            .wrapping_add(bh))
            & 0x3fffffff;
        if iter == 199 {
            last_bc = Some(bc);
        }
    }
    let (steps, result) = run_vm(last_bc.as_ref().unwrap());
    println!("{} {} {}", compile_hash as i32, steps, result);
}
