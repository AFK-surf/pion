///| t02_expr_adt: ADT AST + recursive eval with Result propagation

pub enum Expr {
  Num(Int)
  Var(String)
  Add(Expr, Expr)
  Sub(Expr, Expr)
  Mul(Expr, Expr)
  Div(Expr, Expr)
  Neg(Expr)
}

pub fn show(e : Expr) -> String {
  match e {
    Num(n) => n.to_string()
    Var(v) => v
    Add(a, b) => "(" + show(a) + " + " + show(b) + ")"
    Sub(a, b) => "(" + show(a) + " - " + show(b) + ")"
    Mul(a, b) => "(" + show(a) + " * " + show(b) + ")"
    Div(a, b) => "(" + show(a) + " / " + show(b) + ")"
    Neg(a) => "-" + show(a)
  }
}

pub fn eval(e : Expr, env : Map[String, Int]) -> Result[Int, String] {
  match e {
    Num(n) => Ok(n)
    Var(v) =>
      match env.get(v) {
        Some(x) => Ok(x)
        None => Err("unknown variable " + v)
      }
    Add(a, b) => {
      let x = eval(a, env)?
      let y = eval(b, env)?
      Ok(x + y)
    }
    Sub(a, b) => {
      let x = eval(a, env)?
      let y = eval(b, env)?
      Ok(x - y)
    }
    Mul(a, b) => {
      let x = eval(a, env)?
      let y = eval(b, env)?
      Ok(x * y)
    }
    Div(a, b) => {
      let x = eval(a, env)?
      let y = eval(b, env)?
      if y == 0 {
        return Err("division by zero")
      }
      Ok(x / y)
    }
    Neg(a) => {
      let x = eval(a, env)?
      Ok(-x)
    }
  }
}

pub fn render(e : Expr, env : Map[String, Int]) -> String {
  match eval(e, env) {
    Ok(v) => show(e) + " = " + v.to_string()
    Err(msg) => show(e) + " = error: " + msg
  }
}

pub fn samples() -> Array[Expr] {
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

pub fn default_env() -> Map[String, Int] {
  let env : Map[String, Int] = Map::new()
  env.set("x", 6)
  env.set("y", 7)
  env
}

pub fn main(world : World) -> Int {
  let env = default_env()
  for e in samples() {
    io_println(world, render(e, env))
  }
  0
}

test "eval ok" {
  let env = default_env()
  match eval(Mul(Add(Num(1), Num(2)), Sub(Num(10), Num(4))), env) {
    Ok(v) => { debug_assert(v == 18, "18") }
    Err(_) => { debug_assert(false, "unexpected error") }
  }
  match eval(Div(Neg(Num(9)), Num(2)), env) {
    Ok(v) => { debug_assert(v == -4, "truncating division") }
    Err(_) => { debug_assert(false, "unexpected error") }
  }
}

test "errors propagate" {
  let env = default_env()
  match eval(Mul(Div(Num(1), Num(0)), Var("q")), env) {
    Ok(_) => { debug_assert(false, "expected error") }
    Err(m) => { debug_assert(m == "division by zero", "left error wins") }
  }
  match eval(Add(Var("z"), Num(1)), env) {
    Ok(_) => { debug_assert(false, "expected error") }
    Err(m) => { debug_assert(m == "unknown variable z", "unknown var") }
  }
}

test "show" {
  debug_assert(show(Add(Mul(Neg(Num(7)), Num(3)), Div(Num(20), Num(4)))) == "((-7 * 3) + (20 / 4))", "show")
}
