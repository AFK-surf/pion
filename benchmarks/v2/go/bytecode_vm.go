// V2 Benchmark 2: bytecode_vm (Go)
// Stage A: 200x (Lex -> Recursive-Descent AST -> Bytecode Compile)
// Stage B: Stack VM dispatch (~15M-25M instructions)
package main

import "fmt"

const miniSrc = `fn fib(n) {
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
`

const (
	tkEOF = iota
	tkInt
	tkIdent
	tkFn
	tkLet
	tkIf
	tkElse
	tkWhile
	tkReturn
	tkNewArr
	tkLParen
	tkRParen
	tkLBrace
	tkRBrace
	tkLBrack
	tkRBrack
	tkComma
	tkSemi
	tkPlus
	tkMinus
	tkStar
	tkSlash
	tkPercent
	tkEq
	tkEqEq
	tkNeq
	tkLt
	tkLe
	tkGt
	tkGe
	tkAndAnd
	tkOrOr
	tkBang
)

type token struct {
	kind int
	ival int32
	text string
}

func lex(src string) []token {
	n := len(src)
	i := 0
	toks := make([]token, 0, 256)
	for i < n {
		c := src[i]
		if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
			i++
			continue
		}
		if c >= '0' && c <= '9' {
			var v int32
			for i < n && src[i] >= '0' && src[i] <= '9' {
				v = v*10 + int32(src[i]-'0')
				i++
			}
			toks = append(toks, token{kind: tkInt, ival: v})
			continue
		}
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' {
			st := i
			for i < n && ((src[i] >= 'a' && src[i] <= 'z') || (src[i] >= 'A' && src[i] <= 'Z') ||
				(src[i] >= '0' && src[i] <= '9') || src[i] == '_') {
				i++
			}
			txt := src[st:i]
			k := tkIdent
			switch txt {
			case "fn":
				k = tkFn
			case "let":
				k = tkLet
			case "if":
				k = tkIf
			case "else":
				k = tkElse
			case "while":
				k = tkWhile
			case "return":
				k = tkReturn
			case "new_arr":
				k = tkNewArr
			}
			toks = append(toks, token{kind: k, text: txt})
			continue
		}
		var c2 byte
		if i+1 < n {
			c2 = src[i+1]
		}
		if c == '=' && c2 == '=' {
			toks = append(toks, token{kind: tkEqEq})
			i += 2
			continue
		}
		if c == '!' && c2 == '=' {
			toks = append(toks, token{kind: tkNeq})
			i += 2
			continue
		}
		if c == '<' && c2 == '=' {
			toks = append(toks, token{kind: tkLe})
			i += 2
			continue
		}
		if c == '>' && c2 == '=' {
			toks = append(toks, token{kind: tkGe})
			i += 2
			continue
		}
		if c == '&' && c2 == '&' {
			toks = append(toks, token{kind: tkAndAnd})
			i += 2
			continue
		}
		if c == '|' && c2 == '|' {
			toks = append(toks, token{kind: tkOrOr})
			i += 2
			continue
		}
		var k int
		switch c {
		case '(':
			k = tkLParen
		case ')':
			k = tkRParen
		case '{':
			k = tkLBrace
		case '}':
			k = tkRBrace
		case '[':
			k = tkLBrack
		case ']':
			k = tkRBrack
		case ',':
			k = tkComma
		case ';':
			k = tkSemi
		case '+':
			k = tkPlus
		case '-':
			k = tkMinus
		case '*':
			k = tkStar
		case '/':
			k = tkSlash
		case '%':
			k = tkPercent
		case '=':
			k = tkEq
		case '<':
			k = tkLt
		case '>':
			k = tkGt
		case '!':
			k = tkBang
		}
		toks = append(toks, token{kind: k})
		i++
	}
	toks = append(toks, token{kind: tkEOF})
	return toks
}

const (
	exInt = iota
	exVar
	exUnary
	exBin
	exCall
	exNewArr
	exIndex
)

type expr struct {
	kind int
	ival int32
	op   int
	name string
	lhs  *expr
	rhs  *expr
	args []*expr
}

const (
	stLet = iota
	stAssign
	stArrSet
	stIf
	stWhile
	stReturn
	stExpr
)

type stmt struct {
	kind     int
	name     string
	e        *expr
	idx      *expr
	body     []*stmt
	elseBody []*stmt
}

type funcDef struct {
	name   string
	params []string
	body   []*stmt
}

type astParser struct {
	toks []token
	pos  int
}

func (p *astParser) peek() int { return p.toks[p.pos].kind }
func (p *astParser) nextT() token {
	t := p.toks[p.pos]
	p.pos++
	return t
}

func (p *astParser) parsePrimary() *expr {
	switch p.peek() {
	case tkInt:
		return &expr{kind: exInt, ival: p.nextT().ival}
	case tkNewArr:
		p.nextT()
		p.nextT()
		sz := p.parseExpr()
		p.nextT()
		return &expr{kind: exNewArr, lhs: sz}
	case tkLParen:
		p.nextT()
		e := p.parseExpr()
		p.nextT()
		return e
	case tkIdent:
		name := p.nextT().text
		if p.peek() == tkLParen {
			p.nextT()
			var args []*expr
			if p.peek() != tkRParen {
				for {
					args = append(args, p.parseExpr())
					if p.peek() == tkComma {
						p.nextT()
					} else {
						break
					}
				}
			}
			p.nextT()
			return &expr{kind: exCall, name: name, args: args}
		}
		base := &expr{kind: exVar, name: name}
		if p.peek() == tkLBrack {
			p.nextT()
			idx := p.parseExpr()
			p.nextT()
			return &expr{kind: exIndex, lhs: base, rhs: idx}
		}
		return base
	}
	panic("unexpected primary")
}

func (p *astParser) parseUnary() *expr {
	k := p.peek()
	if k == tkMinus || k == tkBang {
		p.nextT()
		return &expr{kind: exUnary, op: k, lhs: p.parseUnary()}
	}
	return p.parsePrimary()
}

func (p *astParser) parseMul() *expr {
	l := p.parseUnary()
	for p.peek() == tkStar || p.peek() == tkSlash || p.peek() == tkPercent {
		op := p.nextT().kind
		r := p.parseUnary()
		l = &expr{kind: exBin, op: op, lhs: l, rhs: r}
	}
	return l
}

func (p *astParser) parseAdd() *expr {
	l := p.parseMul()
	for p.peek() == tkPlus || p.peek() == tkMinus {
		op := p.nextT().kind
		r := p.parseMul()
		l = &expr{kind: exBin, op: op, lhs: l, rhs: r}
	}
	return l
}

func (p *astParser) parseRel() *expr {
	l := p.parseAdd()
	for {
		k := p.peek()
		if k == tkLt || k == tkLe || k == tkGt || k == tkGe || k == tkEqEq || k == tkNeq {
			p.nextT()
			r := p.parseAdd()
			l = &expr{kind: exBin, op: k, lhs: l, rhs: r}
		} else {
			break
		}
	}
	return l
}

func (p *astParser) parseAnd() *expr {
	l := p.parseRel()
	for p.peek() == tkAndAnd {
		p.nextT()
		r := p.parseRel()
		l = &expr{kind: exBin, op: tkAndAnd, lhs: l, rhs: r}
	}
	return l
}

func (p *astParser) parseExpr() *expr {
	l := p.parseAnd()
	for p.peek() == tkOrOr {
		p.nextT()
		r := p.parseAnd()
		l = &expr{kind: exBin, op: tkOrOr, lhs: l, rhs: r}
	}
	return l
}

func (p *astParser) parseStmt() *stmt {
	switch p.peek() {
	case tkLet:
		p.nextT()
		name := p.nextT().text
		p.nextT()
		e := p.parseExpr()
		p.nextT()
		return &stmt{kind: stLet, name: name, e: e}
	case tkIf:
		p.nextT()
		p.nextT()
		cond := p.parseExpr()
		p.nextT()
		body := p.parseBlock()
		var elseBody []*stmt
		if p.peek() == tkElse {
			p.nextT()
			elseBody = p.parseBlock()
		}
		return &stmt{kind: stIf, e: cond, body: body, elseBody: elseBody}
	case tkWhile:
		p.nextT()
		p.nextT()
		cond := p.parseExpr()
		p.nextT()
		body := p.parseBlock()
		return &stmt{kind: stWhile, e: cond, body: body}
	case tkReturn:
		p.nextT()
		e := p.parseExpr()
		p.nextT()
		return &stmt{kind: stReturn, e: e}
	case tkIdent:
		if p.toks[p.pos+1].kind == tkEq {
			name := p.nextT().text
			p.nextT()
			e := p.parseExpr()
			p.nextT()
			return &stmt{kind: stAssign, name: name, e: e}
		}
		if p.toks[p.pos+1].kind == tkLBrack {
			name := p.nextT().text
			p.nextT()
			idx := p.parseExpr()
			p.nextT()
			p.nextT()
			val := p.parseExpr()
			p.nextT()
			return &stmt{kind: stArrSet, name: name, idx: idx, e: val}
		}
	}
	e := p.parseExpr()
	p.nextT()
	return &stmt{kind: stExpr, e: e}
}

func (p *astParser) parseBlock() []*stmt {
	p.nextT()
	var stmts []*stmt
	for p.peek() != tkRBrace && p.peek() != tkEOF {
		stmts = append(stmts, p.parseStmt())
	}
	p.nextT()
	return stmts
}

func parseProgram(toks []token) []funcDef {
	p := astParser{toks: toks}
	var funcs []funcDef
	for p.peek() == tkFn {
		p.nextT()
		name := p.nextT().text
		p.nextT()
		var params []string
		if p.peek() != tkRParen {
			for {
				params = append(params, p.nextT().text)
				if p.peek() == tkComma {
					p.nextT()
				} else {
					break
				}
			}
		}
		p.nextT()
		body := p.parseBlock()
		funcs = append(funcs, funcDef{name: name, params: params, body: body})
	}
	return funcs
}

const (
	opConst = iota
	opLoad
	opStore
	opAdd
	opSub
	opMul
	opDiv
	opMod
	opEq
	opLt
	opLe
	opAnd
	opOr
	opNot
	opNeg
	opJmp
	opJmpFalse
	opCall
	opRet
	opPop
	opArrNew
	opArrGet
	opArrSet
	opHalt
)

type instr struct {
	op  int32
	arg int32
}

type funcMeta struct {
	entryPC int
	nparams int
	nlocals int
}

type bytecode struct {
	code  []instr
	funcs []funcMeta
}

type compiler struct {
	code   []instr
	prog   []funcDef
	locals []string
}

func (c *compiler) emit(op, arg int32) int {
	idx := len(c.code)
	c.code = append(c.code, instr{op: op, arg: arg})
	return idx
}

func (c *compiler) findLocal(name string) int32 {
	for i, l := range c.locals {
		if l == name {
			return int32(i)
		}
	}
	idx := int32(len(c.locals))
	c.locals = append(c.locals, name)
	return idx
}

func (c *compiler) findFunc(name string) int32 {
	for i := range c.prog {
		if c.prog[i].name == name {
			return int32(i)
		}
	}
	panic("unknown func")
}

func (c *compiler) compExpr(e *expr) {
	switch e.kind {
	case exInt:
		c.emit(opConst, e.ival)
	case exVar:
		c.emit(opLoad, c.findLocal(e.name))
	case exNewArr:
		c.compExpr(e.lhs)
		c.emit(opArrNew, 0)
	case exIndex:
		c.compExpr(e.lhs)
		c.compExpr(e.rhs)
		c.emit(opArrGet, 0)
	case exUnary:
		c.compExpr(e.lhs)
		if e.op == tkMinus {
			c.emit(opNeg, 0)
		} else {
			c.emit(opNot, 0)
		}
	case exCall:
		for _, a := range e.args {
			c.compExpr(a)
		}
		c.emit(opCall, c.findFunc(e.name))
	case exBin:
		if e.op == tkAndAnd {
			c.compExpr(e.lhs)
			j1 := c.emit(opJmpFalse, 0)
			c.compExpr(e.rhs)
			c.emit(opConst, 0)
			c.emit(opEq, 0)
			c.emit(opNot, 0)
			j2 := c.emit(opJmp, 0)
			c.code[j1].arg = int32(len(c.code))
			c.emit(opConst, 0)
			c.code[j2].arg = int32(len(c.code))
			return
		}
		if e.op == tkOrOr {
			c.compExpr(e.lhs)
			j1 := c.emit(opJmpFalse, 0)
			c.emit(opConst, 1)
			j2 := c.emit(opJmp, 0)
			c.code[j1].arg = int32(len(c.code))
			c.compExpr(e.rhs)
			c.emit(opConst, 0)
			c.emit(opEq, 0)
			c.emit(opNot, 0)
			c.code[j2].arg = int32(len(c.code))
			return
		}
		c.compExpr(e.lhs)
		c.compExpr(e.rhs)
		switch e.op {
		case tkPlus:
			c.emit(opAdd, 0)
		case tkMinus:
			c.emit(opSub, 0)
		case tkStar:
			c.emit(opMul, 0)
		case tkSlash:
			c.emit(opDiv, 0)
		case tkPercent:
			c.emit(opMod, 0)
		case tkEqEq:
			c.emit(opEq, 0)
		case tkNeq:
			c.emit(opEq, 0)
			c.emit(opNot, 0)
		case tkLt:
			c.emit(opLt, 0)
		case tkLe:
			c.emit(opLe, 0)
		case tkGt:
			c.emit(opLe, 0)
			c.emit(opNot, 0)
		case tkGe:
			c.emit(opLt, 0)
			c.emit(opNot, 0)
		}
	}
}

func (c *compiler) compStmt(s *stmt) {
	switch s.kind {
	case stLet, stAssign:
		slot := c.findLocal(s.name)
		c.compExpr(s.e)
		c.emit(opStore, slot)
	case stArrSet:
		slot := c.findLocal(s.name)
		c.emit(opLoad, slot)
		c.compExpr(s.idx)
		c.compExpr(s.e)
		c.emit(opArrSet, 0)
	case stReturn:
		c.compExpr(s.e)
		c.emit(opRet, 0)
	case stExpr:
		c.compExpr(s.e)
		c.emit(opPop, 0)
	case stIf:
		c.compExpr(s.e)
		jf := c.emit(opJmpFalse, 0)
		for _, st := range s.body {
			c.compStmt(st)
		}
		if len(s.elseBody) > 0 {
			je := c.emit(opJmp, 0)
			c.code[jf].arg = int32(len(c.code))
			for _, st := range s.elseBody {
				c.compStmt(st)
			}
			c.code[je].arg = int32(len(c.code))
		} else {
			c.code[jf].arg = int32(len(c.code))
		}
	case stWhile:
		loopPC := int32(len(c.code))
		c.compExpr(s.e)
		jf := c.emit(opJmpFalse, 0)
		for _, st := range s.body {
			c.compStmt(st)
		}
		c.emit(opJmp, loopPC)
		c.code[jf].arg = int32(len(c.code))
	}
}

func compileProgram(prog []funcDef) bytecode {
	c := compiler{code: make([]instr, 0, 256), prog: prog}
	mainIdx := c.findFunc("main")
	c.emit(opCall, mainIdx)
	c.emit(opHalt, 0)
	funcs := make([]funcMeta, len(prog))
	for i := range prog {
		c.locals = c.locals[:0]
		entryPC := len(c.code)
		for _, p := range prog[i].params {
			c.findLocal(p)
		}
		for _, s := range prog[i].body {
			c.compStmt(s)
		}
		c.emit(opConst, 0)
		c.emit(opRet, 0)
		funcs[i] = funcMeta{entryPC: entryPC, nparams: len(prog[i].params), nlocals: len(c.locals)}
	}
	return bytecode{code: c.code, funcs: funcs}
}

func runVM(bc bytecode) (int64, int32) {
	var stack [8192]int32
	var framePC [512]int
	var frameBP [512]int
	heap := make([][]int32, 0, 64)

	sp, fp, bp, pc := 0, 0, 0, 0
	var steps int64
	code := bc.code
	funcs := bc.funcs

	for {
		ins := code[pc]
		pc++
		steps++
		switch ins.op {
		case opConst:
			stack[sp] = ins.arg
			sp++
		case opLoad:
			stack[sp] = stack[bp+int(ins.arg)]
			sp++
		case opStore:
			sp--
			stack[bp+int(ins.arg)] = stack[sp]
		case opAdd:
			sp--
			stack[sp-1] += stack[sp]
		case opSub:
			sp--
			stack[sp-1] -= stack[sp]
		case opMul:
			sp--
			stack[sp-1] *= stack[sp]
		case opDiv:
			sp--
			stack[sp-1] /= stack[sp]
		case opMod:
			sp--
			stack[sp-1] %= stack[sp]
		case opEq:
			sp--
			if stack[sp-1] == stack[sp] {
				stack[sp-1] = 1
			} else {
				stack[sp-1] = 0
			}
		case opLt:
			sp--
			if stack[sp-1] < stack[sp] {
				stack[sp-1] = 1
			} else {
				stack[sp-1] = 0
			}
		case opLe:
			sp--
			if stack[sp-1] <= stack[sp] {
				stack[sp-1] = 1
			} else {
				stack[sp-1] = 0
			}
		case opAnd:
			sp--
			if stack[sp-1] != 0 && stack[sp] != 0 {
				stack[sp-1] = 1
			} else {
				stack[sp-1] = 0
			}
		case opOr:
			sp--
			if stack[sp-1] != 0 || stack[sp] != 0 {
				stack[sp-1] = 1
			} else {
				stack[sp-1] = 0
			}
		case opNot:
			if stack[sp-1] == 0 {
				stack[sp-1] = 1
			} else {
				stack[sp-1] = 0
			}
		case opNeg:
			stack[sp-1] = -stack[sp-1]
		case opJmp:
			pc = int(ins.arg)
		case opJmpFalse:
			sp--
			if stack[sp] == 0 {
				pc = int(ins.arg)
			}
		case opCall:
			fm := funcs[ins.arg]
			framePC[fp] = pc
			frameBP[fp] = bp
			fp++
			bp = sp - fm.nparams
			extra := fm.nlocals - fm.nparams
			for k := 0; k < extra; k++ {
				stack[sp] = 0
				sp++
			}
			pc = fm.entryPC
		case opRet:
			sp--
			rv := stack[sp]
			sp = bp
			fp--
			pc = framePC[fp]
			bp = frameBP[fp]
			stack[sp] = rv
			sp++
		case opPop:
			sp--
		case opArrNew:
			sp--
			sz := int(stack[sp])
			id := int32(len(heap))
			heap = append(heap, make([]int32, sz))
			stack[sp] = id
			sp++
		case opArrGet:
			sp--
			idx := int(stack[sp])
			sp--
			h := int(stack[sp])
			stack[sp] = heap[h][idx]
			sp++
		case opArrSet:
			sp--
			val := stack[sp]
			sp--
			idx := int(stack[sp])
			sp--
			h := int(stack[sp])
			heap[h][idx] = val
		case opHalt:
			return steps, stack[sp-1]
		}
	}
}

func main() {
	var compileHash uint32
	var lastBC bytecode
	for iter := 0; iter < 200; iter++ {
		toks := lex(miniSrc)
		prog := parseProgram(toks)
		bc := compileProgram(prog)
		var bh uint32
		for _, ins := range bc.code {
			bh = (bh*31 + uint32(ins.op)*7 + uint32(ins.arg&0xffff)) & 0x3fffffff
		}
		compileHash = (compileHash*31 + uint32(len(bc.code)) + bh) & 0x3fffffff
		if iter == 199 {
			lastBC = bc
		}
	}
	steps, result := runVM(lastBC)
	fmt.Printf("%d %d %d\n", int32(compileHash), steps, result)
}
