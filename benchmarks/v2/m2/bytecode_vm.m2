///| V2 Benchmark 2: bytecode_vm (m2)
///| Stage A: 200x (Lex -> Recursive-Descent AST -> Bytecode Compile)
///| Stage B: Stack VM dispatch (~15M-25M instructions)

fn mini_src() -> String {
  "fn fib(n) {\n" +
  "  if (n <= 1) { return n; }\n" +
  "  return fib(n - 1) + fib(n - 2);\n" +
  "}\n" +
  "fn sieve(limit) {\n" +
  "  let flags = new_arr(limit + 1);\n" +
  "  let i = 2;\n" +
  "  while (i <= limit) {\n" +
  "    flags[i] = 1;\n" +
  "    i = i + 1;\n" +
  "  }\n" +
  "  let p = 2;\n" +
  "  while (p * p <= limit) {\n" +
  "    if (flags[p] == 1) {\n" +
  "      let m = p * p;\n" +
  "      while (m <= limit) {\n" +
  "        flags[m] = 0;\n" +
  "        m = m + p;\n" +
  "      }\n" +
  "    }\n" +
  "    p = p + 1;\n" +
  "  }\n" +
  "  let sum = 0;\n" +
  "  let cnt = 0;\n" +
  "  let k = 2;\n" +
  "  while (k <= limit) {\n" +
  "    if (flags[k] == 1) {\n" +
  "      cnt = cnt + 1;\n" +
  "      sum = (sum * 31 + k) % 1000003;\n" +
  "    }\n" +
  "    k = k + 1;\n" +
  "  }\n" +
  "  return (sum + cnt * 17) % 1000003;\n" +
  "}\n" +
  "fn sort_and_hash(n, seed) {\n" +
  "  let a = new_arr(n);\n" +
  "  let s = seed;\n" +
  "  let i = 0;\n" +
  "  while (i < n) {\n" +
  "    s = (s * 1103 + 12345) % 65536;\n" +
  "    a[i] = s % 10000;\n" +
  "    i = i + 1;\n" +
  "  }\n" +
  "  let j = 1;\n" +
  "  while (j < n) {\n" +
  "    let key = a[j];\n" +
  "    let k = j - 1;\n" +
  "    while (k >= 0 && a[k] > key) {\n" +
  "      a[k + 1] = a[k];\n" +
  "      k = k - 1;\n" +
  "    }\n" +
  "    a[k + 1] = key;\n" +
  "    j = j + 1;\n" +
  "  }\n" +
  "  let h = 0;\n" +
  "  let idx = 0;\n" +
  "  while (idx < n) {\n" +
  "    h = (h * 31 + a[idx]) % 1000003;\n" +
  "    idx = idx + 1;\n" +
  "  }\n" +
  "  return h;\n" +
  "}\n" +
  "fn main() {\n" +
  "  let acc = 0;\n" +
  "  let r = 0;\n" +
  "  while (r < 55) {\n" +
  "    let f = fib(22);\n" +
  "    let sv = sieve(2000);\n" +
  "    let sh = sort_and_hash(120, 42 + r * 7);\n" +
  "    let mix = (f + sv + sh) % 1000003;\n" +
  "    if (r % 2 == 0 || mix < 0) {\n" +
  "      acc = (acc * 3 + mix) % 1000003;\n" +
  "    } else {\n" +
  "      acc = (acc * 5 + mix + 11) % 1000003;\n" +
  "    }\n" +
  "    r = r + 1;\n" +
  "  }\n" +
  "  return acc;\n" +
  "}\n"
}

// Token kinds
let TK_EOF : Int = 0
let TK_INT : Int = 1
let TK_IDENT : Int = 2
let TK_FN : Int = 3
let TK_LET : Int = 4
let TK_IF : Int = 5
let TK_ELSE : Int = 6
let TK_WHILE : Int = 7
let TK_RETURN : Int = 8
let TK_NEWARR : Int = 9
let TK_LPAREN : Int = 10
let TK_RPAREN : Int = 11
let TK_LBRACE : Int = 12
let TK_RBRACE : Int = 13
let TK_LBRACK : Int = 14
let TK_RBRACK : Int = 15
let TK_COMMA : Int = 16
let TK_SEMI : Int = 17
let TK_PLUS : Int = 18
let TK_MINUS : Int = 19
let TK_STAR : Int = 20
let TK_SLASH : Int = 21
let TK_PERCENT : Int = 22
let TK_EQ : Int = 23
let TK_EQEQ : Int = 24
let TK_NEQ : Int = 25
let TK_LT : Int = 26
let TK_LE : Int = 27
let TK_GT : Int = 28
let TK_GE : Int = 29
let TK_ANDAND : Int = 30
let TK_OROR : Int = 31
let TK_BANG : Int = 32

struct Token {
  kind : Int
  ival : Int
  text : String
}

fn lex(src : String) -> Array[Token] {
  let toks : Array[Token] = []
  let n = src.length()
  let mut i = 0
  while i < n {
    let c = src.code_unit_at(i)
    if c == 32 || c == 10 || c == 13 || c == 9 {
      i = i + 1
      continue
    }
    if c >= 48 && c <= 57 {
      let mut v = 0
      while i < n {
        let d = src.code_unit_at(i)
        if d >= 48 && d <= 57 {
          v = v * 10 + (d - 48)
          i = i + 1
        } else {
          break
        }
      }
      toks.push(Token::{ kind: TK_INT, ival: v, text: "" })
      continue
    }
    if (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 {
      let st = i
      while i < n {
        let ch = src.code_unit_at(i)
        if (ch >= 97 && ch <= 122) || (ch >= 65 && ch <= 90) || (ch >= 48 && ch <= 57) || ch == 95 {
          i = i + 1
        } else {
          break
        }
      }
      let txt = src.slice(st, i)
      let k = if txt == "fn" {
        TK_FN
      } else if txt == "let" {
        TK_LET
      } else if txt == "if" {
        TK_IF
      } else if txt == "else" {
        TK_ELSE
      } else if txt == "while" {
        TK_WHILE
      } else if txt == "return" {
        TK_RETURN
      } else if txt == "new_arr" {
        TK_NEWARR
      } else {
        TK_IDENT
      }
      toks.push(Token::{ kind: k, ival: 0, text: txt })
      continue
    }
    let c2 = if i + 1 < n { src.code_unit_at(i + 1) } else { 0 }
    if c == 61 && c2 == 61 {
      toks.push(Token::{ kind: TK_EQEQ, ival: 0, text: "" })
      i = i + 2
      continue
    }
    if c == 33 && c2 == 61 {
      toks.push(Token::{ kind: TK_NEQ, ival: 0, text: "" })
      i = i + 2
      continue
    }
    if c == 60 && c2 == 61 {
      toks.push(Token::{ kind: TK_LE, ival: 0, text: "" })
      i = i + 2
      continue
    }
    if c == 62 && c2 == 61 {
      toks.push(Token::{ kind: TK_GE, ival: 0, text: "" })
      i = i + 2
      continue
    }
    if c == 38 && c2 == 38 {
      toks.push(Token::{ kind: TK_ANDAND, ival: 0, text: "" })
      i = i + 2
      continue
    }
    if c == 124 && c2 == 124 {
      toks.push(Token::{ kind: TK_OROR, ival: 0, text: "" })
      i = i + 2
      continue
    }
    let sk = if c == 40 {
      TK_LPAREN
    } else if c == 41 {
      TK_RPAREN
    } else if c == 123 {
      TK_LBRACE
    } else if c == 125 {
      TK_RBRACE
    } else if c == 91 {
      TK_LBRACK
    } else if c == 93 {
      TK_RBRACK
    } else if c == 44 {
      TK_COMMA
    } else if c == 59 {
      TK_SEMI
    } else if c == 43 {
      TK_PLUS
    } else if c == 45 {
      TK_MINUS
    } else if c == 42 {
      TK_STAR
    } else if c == 47 {
      TK_SLASH
    } else if c == 37 {
      TK_PERCENT
    } else if c == 61 {
      TK_EQ
    } else if c == 60 {
      TK_LT
    } else if c == 62 {
      TK_GT
    } else {
      TK_BANG
    }
    toks.push(Token::{ kind: sk, ival: 0, text: "" })
    i = i + 1
  }
  toks.push(Token::{ kind: TK_EOF, ival: 0, text: "" })
  toks
}

pub enum Expr {
  ExInt(Int)
  ExVar(String)
  ExUnary(Int, Expr)
  ExBin(Int, Expr, Expr)
  ExCall(String, Array[Expr])
  ExNewArr(Expr)
  ExIndex(Expr, Expr)
}

pub enum Stmt {
  StLet(String, Expr)
  StAssign(String, Expr)
  StArrSet(String, Expr, Expr)
  StIf(Expr, Array[Stmt], Array[Stmt])
  StWhile(Expr, Array[Stmt])
  StReturn(Expr)
  StExpr(Expr)
}

struct FuncDef {
  name : String
  params : Array[String]
  body : Array[Stmt]
}

struct AstParser {
  toks : Array[Token]
  mut pos : Int
}

fn peek_k(p : AstParser) -> Int {
  p.toks[p.pos].kind
}

fn next_t(p : AstParser) -> Token {
  let t = p.toks[p.pos]
  p.pos = p.pos + 1
  t
}

fn parse_primary(p : AstParser) -> Expr {
  let k = peek_k(p)
  if k == TK_INT {
    let t = next_t(p)
    return ExInt(t.ival)
  }
  if k == TK_NEWARR {
    let _ = next_t(p)
    let _ = next_t(p)
    let sz = parse_expr(p)
    let _ = next_t(p)
    return ExNewArr(sz)
  }
  if k == TK_LPAREN {
    let _ = next_t(p)
    let e = parse_expr(p)
    let _ = next_t(p)
    return e
  }
  let t = next_t(p)
  if peek_k(p) == TK_LPAREN {
    let _ = next_t(p)
    let args : Array[Expr] = []
    if peek_k(p) != TK_RPAREN {
      while true {
        args.push(parse_expr(p))
        if peek_k(p) == TK_COMMA {
          let _ = next_t(p)
        } else {
          break
        }
      }
    }
    let _ = next_t(p)
    return ExCall(t.text, args)
  }
  let base = ExVar(t.text)
  if peek_k(p) == TK_LBRACK {
    let _ = next_t(p)
    let idx = parse_expr(p)
    let _ = next_t(p)
    return ExIndex(base, idx)
  }
  base
}

fn parse_unary(p : AstParser) -> Expr {
  let k = peek_k(p)
  if k == TK_MINUS || k == TK_BANG {
    let _ = next_t(p)
    return ExUnary(k, parse_unary(p))
  }
  parse_primary(p)
}

fn parse_mul(p : AstParser) -> Expr {
  let mut l = parse_unary(p)
  while peek_k(p) == TK_STAR || peek_k(p) == TK_SLASH || peek_k(p) == TK_PERCENT {
    let op = next_t(p).kind
    let r = parse_unary(p)
    l = ExBin(op, l, r)
  }
  l
}

fn parse_add(p : AstParser) -> Expr {
  let mut l = parse_mul(p)
  while peek_k(p) == TK_PLUS || peek_k(p) == TK_MINUS {
    let op = next_t(p).kind
    let r = parse_mul(p)
    l = ExBin(op, l, r)
  }
  l
}

fn parse_rel(p : AstParser) -> Expr {
  let mut l = parse_add(p)
  while true {
    let k = peek_k(p)
    if k == TK_LT || k == TK_LE || k == TK_GT || k == TK_GE || k == TK_EQEQ || k == TK_NEQ {
      let _ = next_t(p)
      let r = parse_add(p)
      l = ExBin(k, l, r)
    } else {
      break
    }
  }
  l
}

fn parse_and(p : AstParser) -> Expr {
  let mut l = parse_rel(p)
  while peek_k(p) == TK_ANDAND {
    let _ = next_t(p)
    let r = parse_rel(p)
    l = ExBin(TK_ANDAND, l, r)
  }
  l
}

fn parse_expr(p : AstParser) -> Expr {
  let mut l = parse_and(p)
  while peek_k(p) == TK_OROR {
    let _ = next_t(p)
    let r = parse_and(p)
    l = ExBin(TK_OROR, l, r)
  }
  l
}

fn parse_stmt(p : AstParser) -> Stmt {
  let k = peek_k(p)
  if k == TK_LET {
    let _ = next_t(p)
    let name = next_t(p).text
    let _ = next_t(p)
    let e = parse_expr(p)
    let _ = next_t(p)
    return StLet(name, e)
  }
  if k == TK_IF {
    let _ = next_t(p)
    let _ = next_t(p)
    let cond = parse_expr(p)
    let _ = next_t(p)
    let body = parse_block(p)
    let else_body = if peek_k(p) == TK_ELSE {
      let _ = next_t(p)
      parse_block(p)
    } else {
      []
    }
    return StIf(cond, body, else_body)
  }
  if k == TK_WHILE {
    let _ = next_t(p)
    let _ = next_t(p)
    let cond = parse_expr(p)
    let _ = next_t(p)
    let body = parse_block(p)
    return StWhile(cond, body)
  }
  if k == TK_RETURN {
    let _ = next_t(p)
    let e = parse_expr(p)
    let _ = next_t(p)
    return StReturn(e)
  }
  if k == TK_IDENT && p.toks[p.pos + 1].kind == TK_EQ {
    let name = next_t(p).text
    let _ = next_t(p)
    let e = parse_expr(p)
    let _ = next_t(p)
    return StAssign(name, e)
  }
  if k == TK_IDENT && p.toks[p.pos + 1].kind == TK_LBRACK {
    let name = next_t(p).text
    let _ = next_t(p)
    let idx = parse_expr(p)
    let _ = next_t(p)
    let _ = next_t(p)
    let rhs_v = parse_expr(p)
    let _ = next_t(p)
    return StArrSet(name, idx, rhs_v)
  }
  let e = parse_expr(p)
  let _ = next_t(p)
  StExpr(e)
}

fn parse_block(p : AstParser) -> Array[Stmt] {
  let _ = next_t(p)
  let stmts : Array[Stmt] = []
  while peek_k(p) != TK_RBRACE && peek_k(p) != TK_EOF {
    stmts.push(parse_stmt(p))
  }
  let _ = next_t(p)
  stmts
}

fn parse_program(toks : Array[Token]) -> Array[FuncDef] {
  let p = AstParser::{ toks: toks, pos: 0 }
  let funcs : Array[FuncDef] = []
  while peek_k(p) == TK_FN {
    let _ = next_t(p)
    let name = next_t(p).text
    let _ = next_t(p)
    let params : Array[String] = []
    if peek_k(p) != TK_RPAREN {
      while true {
        params.push(next_t(p).text)
        if peek_k(p) == TK_COMMA {
          let _ = next_t(p)
        } else {
          break
        }
      }
    }
    let _ = next_t(p)
    let body = parse_block(p)
    funcs.push(FuncDef::{ name: name, params: params, body: body })
  }
  funcs
}

// Bytecode opcodes
let OP_CONST : Int = 0
let OP_LOAD : Int = 1
let OP_STORE : Int = 2
let OP_ADD : Int = 3
let OP_SUB : Int = 4
let OP_MUL : Int = 5
let OP_DIV : Int = 6
let OP_MOD : Int = 7
let OP_EQ : Int = 8
let OP_LT : Int = 9
let OP_LE : Int = 10
let OP_AND : Int = 11
let OP_OR : Int = 12
let OP_NOT : Int = 13
let OP_NEG : Int = 14
let OP_JMP : Int = 15
let OP_JMP_FALSE : Int = 16
let OP_CALL : Int = 17
let OP_RET : Int = 18
let OP_POP : Int = 19
let OP_ARR_NEW : Int = 20
let OP_ARR_GET : Int = 21
let OP_ARR_SET : Int = 22
let OP_HALT : Int = 23

struct FuncMeta {
  entry_pc : Int
  nparams : Int
  nlocals : Int
}

struct Bytecode {
  ops : Array[Int]
  args : Array[Int]
  funcs : Array[FuncMeta]
}

struct Compiler {
  ops : Array[Int]
  args : Array[Int]
  prog : Array[FuncDef]
  mut locals : Array[String]
}

fn emit(c : Compiler, op : Int, arg : Int) -> Int {
  let idx = c.ops.length()
  c.ops.push(op)
  c.args.push(arg)
  idx
}

fn find_local(c : Compiler, name : String) -> Int {
  let n = c.locals.length()
  let mut i = 0
  while i < n {
    if c.locals[i] == name {
      return i
    }
    i = i + 1
  }
  c.locals.push(name)
  n
}

fn find_func(prog : Array[FuncDef], name : String) -> Int {
  let n = prog.length()
  let mut i = 0
  while i < n {
    if prog[i].name == name {
      return i
    }
    i = i + 1
  }
  0
}

fn comp_expr(c : Compiler, e : Expr) -> Unit {
  match e {
    ExInt(v) => {
      let _ = emit(c, OP_CONST, v)
    }
    ExVar(name) => {
      let _ = emit(c, OP_LOAD, find_local(c, name))
    }
    ExNewArr(sz) => {
      comp_expr(c, sz)
      let _ = emit(c, OP_ARR_NEW, 0)
    }
    ExIndex(arr, idx) => {
      comp_expr(c, arr)
      comp_expr(c, idx)
      let _ = emit(c, OP_ARR_GET, 0)
    }
    ExUnary(op, inner) => {
      comp_expr(c, inner)
      if op == TK_MINUS {
        let _ = emit(c, OP_NEG, 0)
      } else {
        let _ = emit(c, OP_NOT, 0)
      }
    }
    ExCall(name, args) => {
      let mut i = 0
      while i < args.length() {
        comp_expr(c, args[i])
        i = i + 1
      }
      let _ = emit(c, OP_CALL, find_func(c.prog, name))
    }
    ExBin(op, lhs, rhs) => {
      if op == TK_ANDAND {
        comp_expr(c, lhs)
        let j1 = emit(c, OP_JMP_FALSE, 0)
        comp_expr(c, rhs)
        let _ = emit(c, OP_CONST, 0)
        let _ = emit(c, OP_EQ, 0)
        let _ = emit(c, OP_NOT, 0)
        let j2 = emit(c, OP_JMP, 0)
        c.args[j1] = c.ops.length()
        let _ = emit(c, OP_CONST, 0)
        c.args[j2] = c.ops.length()
        return ()
      }
      if op == TK_OROR {
        comp_expr(c, lhs)
        let j1 = emit(c, OP_JMP_FALSE, 0)
        let _ = emit(c, OP_CONST, 1)
        let j2 = emit(c, OP_JMP, 0)
        c.args[j1] = c.ops.length()
        comp_expr(c, rhs)
        let _ = emit(c, OP_CONST, 0)
        let _ = emit(c, OP_EQ, 0)
        let _ = emit(c, OP_NOT, 0)
        c.args[j2] = c.ops.length()
        return ()
      }
      comp_expr(c, lhs)
      comp_expr(c, rhs)
      if op == TK_PLUS {
        let _ = emit(c, OP_ADD, 0)
      } else if op == TK_MINUS {
        let _ = emit(c, OP_SUB, 0)
      } else if op == TK_STAR {
        let _ = emit(c, OP_MUL, 0)
      } else if op == TK_SLASH {
        let _ = emit(c, OP_DIV, 0)
      } else if op == TK_PERCENT {
        let _ = emit(c, OP_MOD, 0)
      } else if op == TK_EQEQ {
        let _ = emit(c, OP_EQ, 0)
      } else if op == TK_NEQ {
        let _ = emit(c, OP_EQ, 0)
        let _ = emit(c, OP_NOT, 0)
      } else if op == TK_LT {
        let _ = emit(c, OP_LT, 0)
      } else if op == TK_LE {
        let _ = emit(c, OP_LE, 0)
      } else if op == TK_GT {
        let _ = emit(c, OP_LE, 0)
        let _ = emit(c, OP_NOT, 0)
      } else if op == TK_GE {
        let _ = emit(c, OP_LT, 0)
        let _ = emit(c, OP_NOT, 0)
      }
    }
  }
}

fn comp_stmt(c : Compiler, s : Stmt) -> Unit {
  match s {
    StLet(name, e) => {
      let slot = find_local(c, name)
      comp_expr(c, e)
      let _ = emit(c, OP_STORE, slot)
    }
    StAssign(name, e) => {
      let slot = find_local(c, name)
      comp_expr(c, e)
      let _ = emit(c, OP_STORE, slot)
    }
    StArrSet(name, idx, rhs_v) => {
      let slot = find_local(c, name)
      let _ = emit(c, OP_LOAD, slot)
      comp_expr(c, idx)
      comp_expr(c, rhs_v)
      let _ = emit(c, OP_ARR_SET, 0)
    }
    StReturn(e) => {
      comp_expr(c, e)
      let _ = emit(c, OP_RET, 0)
    }
    StExpr(e) => {
      comp_expr(c, e)
      let _ = emit(c, OP_POP, 0)
    }
    StIf(cond, body, else_body) => {
      comp_expr(c, cond)
      let jf = emit(c, OP_JMP_FALSE, 0)
      let mut i = 0
      while i < body.length() {
        comp_stmt(c, body[i])
        i = i + 1
      }
      if else_body.length() > 0 {
        let je = emit(c, OP_JMP, 0)
        c.args[jf] = c.ops.length()
        let mut j = 0
        while j < else_body.length() {
          comp_stmt(c, else_body[j])
          j = j + 1
        }
        c.args[je] = c.ops.length()
      } else {
        c.args[jf] = c.ops.length()
      }
    }
    StWhile(cond, body) => {
      let loop_pc = c.ops.length()
      comp_expr(c, cond)
      let jf = emit(c, OP_JMP_FALSE, 0)
      let mut i = 0
      while i < body.length() {
        comp_stmt(c, body[i])
        i = i + 1
      }
      let _ = emit(c, OP_JMP, loop_pc)
      c.args[jf] = c.ops.length()
    }
  }
}

fn compile_program(prog : Array[FuncDef]) -> Bytecode {
  let ops : Array[Int] = []
  let args : Array[Int] = []
  let funcs : Array[FuncMeta] = []
  let c = Compiler::{ ops: ops, args: args, prog: prog, locals: [] }
  let main_idx = find_func(prog, "main")
  let _ = emit(c, OP_CALL, main_idx)
  let _ = emit(c, OP_HALT, 0)
  let mut i = 0
  while i < prog.length() {
    c.locals = []
    let fn_def = prog[i]
    let entry_pc = c.ops.length()
    let mut p = 0
    while p < fn_def.params.length() {
      let _ = find_local(c, fn_def.params[p])
      p = p + 1
    }
    let mut s = 0
    while s < fn_def.body.length() {
      comp_stmt(c, fn_def.body[s])
      s = s + 1
    }
    let _ = emit(c, OP_CONST, 0)
    let _ = emit(c, OP_RET, 0)
    funcs.push(FuncMeta::{
      entry_pc: entry_pc,
      nparams: fn_def.params.length(),
      nlocals: c.locals.length(),
    })
    i = i + 1
  }
  Bytecode::{ ops: ops, args: args, funcs: funcs }
}

struct VmResult {
  steps : Int64
  value : Int
}

fn run_vm(bc : Bytecode) -> VmResult {
  let stack : Array[Int] = []
  let mut si = 0
  while si < 8192 {
    stack.push(0)
    si = si + 1
  }
  let frame_pc : Array[Int] = []
  let frame_bp : Array[Int] = []
  let mut fi = 0
  while fi < 512 {
    frame_pc.push(0)
    frame_bp.push(0)
    fi = fi + 1
  }
  let heap : Array[Array[Int]] = []

  let ops = bc.ops
  let args = bc.args
  let funcs = bc.funcs

  let mut sp = 0
  let mut fp = 0
  let mut bp = 0
  let mut pc = 0
  let mut steps : Int64 = 0L

  while true {
    let op = ops[pc]
    let arg = args[pc]
    pc = pc + 1
    steps = steps + 1L
    if op == OP_CONST {
      stack[sp] = arg
      sp = sp + 1
    } else if op == OP_LOAD {
      stack[sp] = stack[bp + arg]
      sp = sp + 1
    } else if op == OP_STORE {
      sp = sp - 1
      stack[bp + arg] = stack[sp]
    } else if op == OP_ADD {
      sp = sp - 1
      stack[sp - 1] = stack[sp - 1] + stack[sp]
    } else if op == OP_SUB {
      sp = sp - 1
      stack[sp - 1] = stack[sp - 1] - stack[sp]
    } else if op == OP_MUL {
      sp = sp - 1
      stack[sp - 1] = stack[sp - 1] * stack[sp]
    } else if op == OP_DIV {
      sp = sp - 1
      stack[sp - 1] = stack[sp - 1] / stack[sp]
    } else if op == OP_MOD {
      sp = sp - 1
      stack[sp - 1] = stack[sp - 1] % stack[sp]
    } else if op == OP_EQ {
      sp = sp - 1
      stack[sp - 1] = if stack[sp - 1] == stack[sp] { 1 } else { 0 }
    } else if op == OP_LT {
      sp = sp - 1
      stack[sp - 1] = if stack[sp - 1] < stack[sp] { 1 } else { 0 }
    } else if op == OP_LE {
      sp = sp - 1
      stack[sp - 1] = if stack[sp - 1] <= stack[sp] { 1 } else { 0 }
    } else if op == OP_AND {
      sp = sp - 1
      stack[sp - 1] = if stack[sp - 1] != 0 && stack[sp] != 0 { 1 } else { 0 }
    } else if op == OP_OR {
      sp = sp - 1
      stack[sp - 1] = if stack[sp - 1] != 0 || stack[sp] != 0 { 1 } else { 0 }
    } else if op == OP_NOT {
      stack[sp - 1] = if stack[sp - 1] == 0 { 1 } else { 0 }
    } else if op == OP_NEG {
      stack[sp - 1] = 0 - stack[sp - 1]
    } else if op == OP_JMP {
      pc = arg
    } else if op == OP_JMP_FALSE {
      sp = sp - 1
      if stack[sp] == 0 {
        pc = arg
      }
    } else if op == OP_CALL {
      let fm = funcs[arg]
      frame_pc[fp] = pc
      frame_bp[fp] = bp
      fp = fp + 1
      bp = sp - fm.nparams
      let extra = fm.nlocals - fm.nparams
      let mut k = 0
      while k < extra {
        stack[sp] = 0
        sp = sp + 1
        k = k + 1
      }
      pc = fm.entry_pc
    } else if op == OP_RET {
      sp = sp - 1
      let rv = stack[sp]
      sp = bp
      fp = fp - 1
      pc = frame_pc[fp]
      bp = frame_bp[fp]
      stack[sp] = rv
      sp = sp + 1
    } else if op == OP_POP {
      sp = sp - 1
    } else if op == OP_ARR_NEW {
      sp = sp - 1
      let sz = stack[sp]
      let arr : Array[Int] = []
      let mut k = 0
      while k < sz {
        arr.push(0)
        k = k + 1
      }
      let id = heap.length()
      heap.push(arr)
      stack[sp] = id
      sp = sp + 1
    } else if op == OP_ARR_GET {
      sp = sp - 1
      let idx = stack[sp]
      sp = sp - 1
      let h = stack[sp]
      stack[sp] = heap[h][idx]
      sp = sp + 1
    } else if op == OP_ARR_SET {
      sp = sp - 1
      let elem_v = stack[sp]
      sp = sp - 1
      let idx = stack[sp]
      sp = sp - 1
      let h = stack[sp]
      heap[h][idx] = elem_v
    } else {
      return VmResult::{ steps: steps, value: stack[sp - 1] }
    }
  }
  VmResult::{ steps: steps, value: 0 }
}

pub fn main(world : World) -> Int {
  let src = mini_src()
  let mut compile_hash = 0
  let mut last_bc = Bytecode::{ ops: [], args: [], funcs: [] }
  let mut iter = 0
  while iter < 200 {
    let toks = lex(src)
    let prog = parse_program(toks)
    let bc = compile_program(prog)
    let mut bh = 0
    let mut i = 0
    while i < bc.ops.length() {
      bh = (bh * 31 + bc.ops[i] * 7 + (bc.args[i] & 0xffff)) & 0x3fffffff
      i = i + 1
    }
    compile_hash = (compile_hash * 31 + bc.ops.length() + bh) & 0x3fffffff
    if iter == 199 {
      last_bc = bc
    }
    iter = iter + 1
  }
  let res = run_vm(last_bc)
  io_println(
    world,
    compile_hash.to_string() +
    " " +
    res.steps.to_string() +
    " " +
    res.value.to_string(),
  )
  0
}
