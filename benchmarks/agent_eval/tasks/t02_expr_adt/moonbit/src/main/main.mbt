///| t02_expr_adt: ADT AST + recursive eval with Result propagation

///|
enum Expr {
  Num(Int)
  Var(String)
  Add(Expr, Expr)
  Sub(Expr, Expr)
  Mul(Expr, Expr)
  Div(Expr, Expr)
  Neg(Expr)
}

///|
fn show(e : Expr) -> String {
  match e {
    Num(n) => n.to_string()
    Var(v) => v
    Add(a, b) => "(\{show(a)} + \{show(b)})"
    Sub(a, b) => "(\{show(a)} - \{show(b)})"
    Mul(a, b) => "(\{show(a)} * \{show(b)})"
    Div(a, b) => "(\{show(a)} / \{show(b)})"
    Neg(a) => "-\{show(a)}"
  }
}

///| MoonBit's native error channel: checked `raise` effects (no `?` on Result).
suberror EvalError {
  DivZero
  Unknown(String)
}

///|
fn EvalError::message(self : EvalError) -> String {
  match self {
    DivZero => "division by zero"
    Unknown(v) => "unknown variable \{v}"
  }
}

///|
fn eval(e : Expr, env : Map[String, Int]) -> Int raise EvalError {
  match e {
    Num(n) => n
    Var(v) =>
      match env.get(v) {
        Some(x) => x
        None => raise Unknown(v)
      }
    Add(a, b) => eval(a, env) + eval(b, env)
    Sub(a, b) => eval(a, env) - eval(b, env)
    Mul(a, b) => eval(a, env) * eval(b, env)
    Div(a, b) => {
      let x = eval(a, env)
      let y = eval(b, env)
      if y == 0 {
        raise DivZero
      }
      x / y
    }
    Neg(a) => -eval(a, env)
  }
}

///|
fn eval_result(e : Expr, env : Map[String, Int]) -> Result[Int, String] {
  try eval(e, env) catch {
    err => Err(err.message())
  } noraise {
    v => Ok(v)
  }
}

///|
fn render(e : Expr, env : Map[String, Int]) -> String {
  match eval_result(e, env) {
    Ok(v) => "\{show(e)} = \{v}"
    Err(msg) => "\{show(e)} = error: \{msg}"
  }
}

///|
fn samples() -> Array[Expr] {
  [
    Mul(Add(Num(1), Num(2)), Sub(Num(10), Num(4))),
    Div(Num(100), Sub(Num(5), Num(5))),
    Add(Mul(Neg(Num(7)), Num(3)), Div(Num(20), Num(4))),
    Sub(Mul(Var("x"), Var("y")), Num(2)),
    Add(Var("z"), Num(1)),
    Div(Neg(Num(9)), Num(2)),
    Mul(Div(Num(1), Num(0)), Var("q")),
  ]
}

///|
fn default_env() -> Map[String, Int] {
  { "x": 6, "y": 7 }
}

///|
fn main {
  let env = default_env()
  for e in samples() {
    println(render(e, env))
  }
}

///|
test "eval ok" {
  let env = default_env()
  assert_eq(eval_result(samples()[0], env), Ok(18))
  assert_eq(eval_result(Div(Neg(Num(9)), Num(2)), env), Ok(-4))
}

///|
test "errors propagate" {
  let env = default_env()
  assert_eq(eval_result(samples()[6], env), Err("division by zero"))
  assert_eq(eval_result(Add(Var("z"), Num(1)), env), Err("unknown variable z"))
}

///|
test "show" {
  assert_eq(show(samples()[2]), "((-7 * 3) + (20 / 4))")
}
