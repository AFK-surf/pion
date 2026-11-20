///| V2 Benchmark 2: bytecode_vm (MoonBit)
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

const TK_EOF : Int = 0
const TK_INT : Int = 1
const TK_IDENT : Int = 2
const TK_FN : Int = 3
const TK_LET : Int = 4
const TK_IF : Int = 5
const TK_ELSE : Int = 6
const TK_WHILE : Int = 7
const TK_RETURN : Int = 8
const TK_NEWARR : Int = 9
const TK_LPAREN : Int = 10
const TK_RPAREN : Int = 11
const TK_LBRACE : Int = 12
const TK_RBRACE : Int = 13
const TK_LBRACK : Int = 14
const TK_RBRACK : Int = 15
const TK_COMMA : Int = 16
const TK_SEMI : Int = 17
const TK_PLUS : Int = 18
const TK_MINUS : Int = 19
const TK_STAR : Int = 20
const TK_SLASH : Int = 21
const TK_PERCENT : Int = 22
const TK_EQ : Int = 23
const TK_EQEQ : Int = 24
const TK_NEQ : Int = 25
const TK_LT : Int = 26
const TK_LE : Int = 27
const TK_GT : Int = 28
const TK_GE : Int = 29
const TK_ANDAND : Int = 30
const TK_OROR : Int = 31
const TK_BANG : Int = 32

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
    let c = src.code_unit_at(i).to_int()
    if c == 32 || c == 10 || c == 13 || c == 9 {
      i = i + 1
      continue
    }
    if c >= 48 && c <= 57 {
      let mut v = 0
      while i < n {
        let d = src.code_unit_at(i).to_int()
        if d >= 48 && d <= 57 {
          v = v * 10 + (d - 48)
          i = i + 1
        } else {
          break
        }
      }
      toks.push({ kind: TK_INT, ival: v, text: "" })
      continue
    }
    if (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 {
      let st = i
      while i < n {
        let ch = src.code_unit_at(i).to_int()
        if (ch >= 97 && ch <= 122) || (ch >= 65 && ch <= 90) || (ch >= 48 && ch <= 57) || ch == 95 {
          i = i + 1
        } else {
          break
        }
      }
      let txt = src.unsafe_substring(start=st, end=i)
      let k = match txt {
        "fn" => TK_FN
        "let" => TK_LET
        "if" => TK_IF
        "else" => TK_ELSE
        "while" => TK_WHILE
        "return" => TK_RETURN
        "new_arr" => TK_NEWARR
        _ => TK_IDENT
      }
      toks.push({ kind: k, ival: 0, text: txt })
      continue
    }
    let c2 = if i + 1 < n { src.code_unit_at(i + 1).to_int() } else { 0 }
    if c == 61 && c2 == 61 { toks.push({ kind: TK_EQEQ, ival: 0, text: "" }); i = i + 2; continue }
    if c == 33 && c2 == 61 { toks.push({ kind: TK_NEQ, ival: 0, text: "" }); i = i + 2; continue }
    if c == 60 && c2 == 61 { toks.push({ kind: TK_LE, ival: 0, text: "" }); i = i + 2; continue }
    if c == 62 && c2 == 61 { toks.push({ kind: TK_GE, ival: 0, text: "" }); i = i + 2; continue }
    if c == 38 && c2 == 38 { toks.push({ kind: TK_ANDAND, ival: 0, text: "" }); i = i + 2; continue }
    if c == 124 && c2 == 124 { toks.push({ kind: TK_OROR, ival: 0, text: "" }); i = i + 2; continue }
    let sk = match c {
      40 => TK_LPAREN
      41 => TK_RPAREN
      123 => TK_LBRACE
      125 => TK_RBRACE
      91 => TK_LBRACK
      93 => TK_RBRACK
      44 => TK_COMMA
      59 => TK_SEMI
      43 => TK_PLUS
      45 => TK_MINUS
      42 => TK_STAR
      47 => TK_SLASH
      37 => TK_PERCENT
      61 => TK_EQ
      60 => TK_LT
      62 => TK_GT
      _ => TK_BANG
    }
    toks.push({ kind: sk, ival: 0, text: "" })
    i = i + 1
  }
  toks.push({ kind: TK_EOF, ival: 0, text: "" })
  toks
}

enum Expr {
  ExInt(Int)
  ExVar(String)
  ExUnary(Int, Expr)
  ExBin(Int, Expr, Expr)
  ExCall(String, Array[Expr])
  ExNewArr(Expr)
  ExIndex(Expr, Expr)
}

enum Stmt {
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
    return ExInt(next_t(p).ival)
  }
  if k == TK_NEWARR {
    ignore(next_t(p))
    ignore(next_t(p))
    let sz = parse_expr(p)
    ignore(next_t(p))
    return ExNewArr(sz)
  }
  if k == TK_LPAREN {
    ignore(next_t(p))
    let e = parse_expr(p)
    ignore(next_t(p))
    return e
  }
  let t = next_t(p)
  if peek_k(p) == TK_LPAREN {
    ignore(next_t(p))
    let args : Array[Expr] = []
    if peek_k(p) != TK_RPAREN {
      while true {
        args.push(parse_expr(p))
        if peek_k(p) == TK_COMMA {
          ignore(next_t(p))
        } else {
          break
        }
      }
    }
    ignore(next_t(p))
    return ExCall(t.text, args)
  }
  let base = ExVar(t.text)
  if peek_k(p) == TK_LBRACK {
    ignore(next_t(p))
    let idx = parse_expr(p)
    ignore(next_t(p))
    return ExIndex(base, idx)
  }
  base
}

fn parse_unary(p : AstParser) -> Expr {
  let k = peek_k(p)
  if k == TK_MINUS || k == TK_BANG {
    ignore(next_t(p))
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
      ignore(next_t(p))
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
    ignore(next_t(p))
    let r = parse_rel(p)
    l = ExBin(TK_ANDAND, l, r)
  }
  l
}

fn parse_expr(p : AstParser) -> Expr {
  let mut l = parse_and(p)
  while peek_k(p) == TK_OROR {
    ignore(next_t(p))
    let r = parse_and(p)
    l = ExBin(TK_OROR, l, r)
  }
  l
}

fn parse_stmt(p : AstParser) -> Stmt {
  let k = peek_k(p)
  if k == TK_LET {
    ignore(next_t(p))
    let name = next_t(p).text
    ignore(next_t(p))
    let e = parse_expr(p)
    ignore(next_t(p))
    return StLet(name, e)
  }
  if k == TK_IF {
    ignore(next_t(p))
    ignore(next_t(p))
    let cond = parse_expr(p)
    ignore(next_t(p))
    let body = parse_block(p)
    let else_body = if peek_k(p) == TK_ELSE {
      ignore(next_t(p))
      parse_block(p)
    } else {
      []
    }
    return StIf(cond, body, else_body)
  }
  if k == TK_WHILE {
    ignore(next_t(p))
    ignore(next_t(p))
    let cond = parse_expr(p)
    ignore(next_t(p))
    let body = parse_block(p)
    return StWhile(cond, body)
  }
  if k == TK_RETURN {
    ignore(next_t(p))
    let e = parse_expr(p)
    ignore(next_t(p))
    return StReturn(e)
  }
  if k == TK_IDENT && p.toks[p.pos + 1].kind == TK_EQ {
    let name = next_t(p).text
    ignore(next_t(p))
    let e = parse_expr(p)
    ignore(next_t(p))
    return StAssign(name, e)
  }
  if k == TK_IDENT && p.toks[p.pos + 1].kind == TK_LBRACK {
    let name = next_t(p).text
    ignore(next_t(p))
    let idx = parse_expr(p)
    ignore(next_t(p))
    ignore(next_t(p))
    let val = parse_expr(p)
    ignore(next_t(p))
    return StArrSet(name, idx, val)
  }
  let e = parse_expr(p)
  ignore(next_t(p))
  StExpr(e)
}

fn parse_block(p : AstParser) -> Array[Stmt] {
  ignore(next_t(p))
  let stmts : Array[Stmt] = []
  while peek_k(p) != TK_RBRACE && peek_k(p) != TK_EOF {
    stmts.push(parse_stmt(p))
  }
  ignore(next_t(p))
  stmts
}

fn parse_program(toks : Array[Token]) -> Array[FuncDef] {
  let p : AstParser = { toks, pos: 0 }
  let funcs : Array[FuncDef] = []
  while peek_k(p) == TK_FN {
    ignore(next_t(p))
    let name = next_t(p).text
    ignore(next_t(p))
    let params : Array[String] = []
    if peek_k(p) != TK_RPAREN {
      while true {
        params.push(next_t(p).text)
        if peek_k(p) == TK_COMMA {
          ignore(next_t(p))
        } else {
          break
        }
      }
    }
    ignore(next_t(p))
    let body = parse_block(p)
    funcs.push({ name, params, body })
  }
  funcs
}

const OP_CONST : Int = 0
const OP_LOAD : Int = 1
const OP_STORE : Int = 2
const OP_ADD : Int = 3
const OP_SUB : Int = 4
const OP_MUL : Int = 5
const OP_DIV : Int = 6
const OP_MOD : Int = 7
const OP_EQ : Int = 8
const OP_LT : Int = 9
const OP_LE : Int = 10
const OP_AND : Int = 11
const OP_OR : Int = 12
const OP_NOT : Int = 13
const OP_NEG : Int = 14
const OP_JMP : Int = 15
const OP_JMP_FALSE : Int = 16
const OP_CALL : Int = 17
const OP_RET : Int = 18
const OP_POP : Int = 19
const OP_ARR_NEW : Int = 20
const OP_ARR_GET : Int = 21
const OP_ARR_SET : Int = 22
const OP_HALT : Int = 23

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
  for i = 0; i < c.locals.length(); i = i + 1 {
    if c.locals[i] == name {
      return i
    }
  }
  let idx = c.locals.length()
  c.locals.push(name)
  idx
}

fn find_func(prog : Array[FuncDef], name : String) -> Int {
  for i = 0; i < prog.length(); i = i + 1 {
    if prog[i].name == name {
      return i
    }
  }
  0
}

fn comp_expr(c : Compiler, e : Expr) -> Unit {
  match e {
    ExInt(v) => ignore(emit(c, OP_CONST, v))
    ExVar(name) => ignore(emit(c, OP_LOAD, find_local(c, name)))
    ExNewArr(sz) => {
      comp_expr(c, sz)
      ignore(emit(c, OP_ARR_NEW, 0))
    }
    ExIndex(arr, idx) => {
      comp_expr(c, arr)
      comp_expr(c, idx)
      ignore(emit(c, OP_ARR_GET, 0))
    }
    ExUnary(op, inner) => {
      comp_expr(c, inner)
      ignore(emit(c, if op == TK_MINUS { OP_NEG } else { OP_NOT }, 0))
    }
    ExCall(name, args) => {
      for i = 0; i < args.length(); i = i + 1 {
        comp_expr(c, args[i])
      }
      ignore(emit(c, OP_CALL, find_func(c.prog, name)))
    }
    ExBin(op, lhs, rhs) => {
      if op == TK_ANDAND {
        comp_expr(c, lhs)
        let j1 = emit(c, OP_JMP_FALSE, 0)
        comp_expr(c, rhs)
        ignore(emit(c, OP_CONST, 0))
        ignore(emit(c, OP_EQ, 0))
        ignore(emit(c, OP_NOT, 0))
        let j2 = emit(c, OP_JMP, 0)
        c.args[j1] = c.ops.length()
        ignore(emit(c, OP_CONST, 0))
        c.args[j2] = c.ops.length()
        return
      }
      if op == TK_OROR {
        comp_expr(c, lhs)
        let j1 = emit(c, OP_JMP_FALSE, 0)
        ignore(emit(c, OP_CONST, 1))
        let j2 = emit(c, OP_JMP, 0)
        c.args[j1] = c.ops.length()
        comp_expr(c, rhs)
        ignore(emit(c, OP_CONST, 0))
        ignore(emit(c, OP_EQ, 0))
        ignore(emit(c, OP_NOT, 0))
        c.args[j2] = c.ops.length()
        return
      }
      comp_expr(c, lhs)
      comp_expr(c, rhs)
      match op {
        TK_PLUS => ignore(emit(c, OP_ADD, 0))
        TK_MINUS => ignore(emit(c, OP_SUB, 0))
        TK_STAR => ignore(emit(c, OP_MUL, 0))
        TK_SLASH => ignore(emit(c, OP_DIV, 0))
        TK_PERCENT => ignore(emit(c, OP_MOD, 0))
        TK_EQEQ => ignore(emit(c, OP_EQ, 0))
        TK_NEQ => { ignore(emit(c, OP_EQ, 0)); ignore(emit(c, OP_NOT, 0)) }
        TK_LT => ignore(emit(c, OP_LT, 0))
        TK_LE => ignore(emit(c, OP_LE, 0))
        TK_GT => { ignore(emit(c, OP_LE, 0)); ignore(emit(c, OP_NOT, 0)) }
        TK_GE => { ignore(emit(c, OP_LT, 0)); ignore(emit(c, OP_NOT, 0)) }
        _ => ()
      }
    }
  }
}

fn comp_stmt(c : Compiler, s : Stmt) -> Unit {
  match s {
    StLet(name, e) | StAssign(name, e) => {
      let slot = find_local(c, name)
      comp_expr(c, e)
      ignore(emit(c, OP_STORE, slot))
    }
    StArrSet(name, idx, val) => {
      let slot = find_local(c, name)
      ignore(emit(c, OP_LOAD, slot))
      comp_expr(c, idx)
      comp_expr(c, val)
      ignore(emit(c, OP_ARR_SET, 0))
    }
    StReturn(e) => {
      comp_expr(c, e)
      ignore(emit(c, OP_RET, 0))
    }
    StExpr(e) => {
      comp_expr(c, e)
      ignore(emit(c, OP_POP, 0))
    }
    StIf(cond, body, else_body) => {
      comp_expr(c, cond)
      let jf = emit(c, OP_JMP_FALSE, 0)
      for i = 0; i < body.length(); i = i + 1 {
        comp_stmt(c, body[i])
      }
      if else_body.length() > 0 {
        let je = emit(c, OP_JMP, 0)
        c.args[jf] = c.ops.length()
        for j = 0; j < else_body.length(); j = j + 1 {
          comp_stmt(c, else_body[j])
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
      for i = 0; i < body.length(); i = i + 1 {
        comp_stmt(c, body[i])
      }
      ignore(emit(c, OP_JMP, loop_pc))
      c.args[jf] = c.ops.length()
    }
  }
}

fn compile_program(prog : Array[FuncDef]) -> Bytecode {
  let ops : Array[Int] = []
  let args : Array[Int] = []
  let funcs : Array[FuncMeta] = []
  let c : Compiler = { ops, args, prog, locals: [] }
  let main_idx = find_func(prog, "main")
  ignore(emit(c, OP_CALL, main_idx))
  ignore(emit(c, OP_HALT, 0))
  for i = 0; i < prog.length(); i = i + 1 {
    c.locals = []
    let f = prog[i]
    let entry_pc = c.ops.length()
    for p = 0; p < f.params.length(); p = p + 1 {
      ignore(find_local(c, f.params[p]))
    }
    for s = 0; s < f.body.length(); s = s + 1 {
      comp_stmt(c, f.body[s])
    }
    ignore(emit(c, OP_CONST, 0))
    ignore(emit(c, OP_RET, 0))
    funcs.push({ entry_pc, nparams: f.params.length(), nlocals: c.locals.length() })
  }
  { ops, args, funcs }
}

fn run_vm(bc : Bytecode) -> (Int64, Int) {
  let stack = FixedArray::make(8192, 0)
  let frame_pc = FixedArray::make(512, 0)
  let frame_bp = FixedArray::make(512, 0)
  let heap : Array[FixedArray[Int]] = []

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
    match op {
      OP_CONST => { stack[sp] = arg; sp = sp + 1 }
      OP_LOAD => { stack[sp] = stack[bp + arg]; sp = sp + 1 }
      OP_STORE => { sp = sp - 1; stack[bp + arg] = stack[sp] }
      OP_ADD => { sp = sp - 1; stack[sp - 1] = stack[sp - 1] + stack[sp] }
      OP_SUB => { sp = sp - 1; stack[sp - 1] = stack[sp - 1] - stack[sp] }
      OP_MUL => { sp = sp - 1; stack[sp - 1] = stack[sp - 1] * stack[sp] }
      OP_DIV => { sp = sp - 1; stack[sp - 1] = stack[sp - 1] / stack[sp] }
      OP_MOD => { sp = sp - 1; stack[sp - 1] = stack[sp - 1] % stack[sp] }
      OP_EQ => { sp = sp - 1; stack[sp - 1] = if stack[sp - 1] == stack[sp] { 1 } else { 0 } }
      OP_LT => { sp = sp - 1; stack[sp - 1] = if stack[sp - 1] < stack[sp] { 1 } else { 0 } }
      OP_LE => { sp = sp - 1; stack[sp - 1] = if stack[sp - 1] <= stack[sp] { 1 } else { 0 } }
      OP_AND => { sp = sp - 1; stack[sp - 1] = if stack[sp - 1] != 0 && stack[sp] != 0 { 1 } else { 0 } }
      OP_OR => { sp = sp - 1; stack[sp - 1] = if stack[sp - 1] != 0 || stack[sp] != 0 { 1 } else { 0 } }
      OP_NOT => stack[sp - 1] = if stack[sp - 1] == 0 { 1 } else { 0 }
      OP_NEG => stack[sp - 1] = -stack[sp - 1]
      OP_JMP => pc = arg
      OP_JMP_FALSE => {
        sp = sp - 1
        if stack[sp] == 0 { pc = arg }
      }
      OP_CALL => {
        let fm = funcs[arg]
        frame_pc[fp] = pc
        frame_bp[fp] = bp
        fp = fp + 1
        bp = sp - fm.nparams
        let extra = fm.nlocals - fm.nparams
        for _k = 0; _k < extra; _k = _k + 1 {
          stack[sp] = 0
          sp = sp + 1
        }
        pc = fm.entry_pc
      }
      OP_RET => {
        sp = sp - 1
        let rv = stack[sp]
        sp = bp
        fp = fp - 1
        pc = frame_pc[fp]
        bp = frame_bp[fp]
        stack[sp] = rv
        sp = sp + 1
      }
      OP_POP => sp = sp - 1
      OP_ARR_NEW => {
        sp = sp - 1
        let sz = stack[sp]
        let id = heap.length()
        heap.push(FixedArray::make(sz, 0))
        stack[sp] = id
        sp = sp + 1
      }
      OP_ARR_GET => {
        sp = sp - 1
        let idx = stack[sp]
        sp = sp - 1
        let h = stack[sp]
        stack[sp] = heap[h][idx]
        sp = sp + 1
      }
      OP_ARR_SET => {
        sp = sp - 1
        let val = stack[sp]
        sp = sp - 1
        let idx = stack[sp]
        sp = sp - 1
        let h = stack[sp]
        heap[h][idx] = val
      }
      _ => return (steps, stack[sp - 1])
    }
  }
  (steps, 0)
}

fn main {
  let src = mini_src()
  let mut compile_hash = 0
  let mut last_bc : Bytecode = { ops: [], args: [], funcs: [] }
  for iter = 0; iter < 200; iter = iter + 1 {
    let toks = lex(src)
    let prog = parse_program(toks)
    let bc = compile_program(prog)
    let mut bh = 0
    for i = 0; i < bc.ops.length(); i = i + 1 {
      bh = (bh * 31 + bc.ops[i] * 7 + (bc.args[i] & 0xffff)) & 0x3fffffff
    }
    compile_hash = (compile_hash * 31 + bc.ops.length() + bh) & 0x3fffffff
    if iter == 199 {
      last_bc = bc
    }
  }
  let (steps, result) = run_vm(last_bc)
  println(compile_hash.to_string() + " " + steps.to_string() + " " + result.to_string())
}
