//! t02_expr_adt: ADT AST + recursive eval with Result propagation
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub enum Expr {
    Num(i64),
    Var(String),
    Add(Box<Expr>, Box<Expr>),
    Sub(Box<Expr>, Box<Expr>),
    Mul(Box<Expr>, Box<Expr>),
    Div(Box<Expr>, Box<Expr>),
    Neg(Box<Expr>),
}

use Expr::*;

fn num(n: i64) -> Box<Expr> {
    Box::new(Num(n))
}
fn var(v: &str) -> Box<Expr> {
    Box::new(Var(v.to_string()))
}

pub fn show(e: &Expr) -> String {
    match e {
        Num(n) => n.to_string(),
        Var(v) => v.clone(),
        Add(a, b) => format!("({} + {})", show(a), show(b)),
        Sub(a, b) => format!("({} - {})", show(a), show(b)),
        Mul(a, b) => format!("({} * {})", show(a), show(b)),
        Div(a, b) => format!("({} / {})", show(a), show(b)),
        Neg(a) => format!("-{}", show(a)),
    }
}

pub fn eval(e: &Expr, env: &HashMap<String, i64>) -> Result<i64, String> {
    Ok(match e {
        Num(n) => *n,
        Var(v) => *env.get(v).ok_or_else(|| format!("unknown variable {}", v))?,
        Add(a, b) => eval(a, env)? + eval(b, env)?,
        Sub(a, b) => eval(a, env)? - eval(b, env)?,
        Mul(a, b) => eval(a, env)? * eval(b, env)?,
        Div(a, b) => {
            let x = eval(a, env)?;
            let y = eval(b, env)?;
            if y == 0 {
                return Err("division by zero".to_string());
            }
            x / y
        }
        Neg(a) => -eval(a, env)?,
    })
}

pub fn render(e: &Expr, env: &HashMap<String, i64>) -> String {
    match eval(e, env) {
        Ok(v) => format!("{} = {}", show(e), v),
        Err(m) => format!("{} = error: {}", show(e), m),
    }
}

pub fn samples() -> Vec<Expr> {
    vec![
        Mul(Box::new(Add(num(1), num(2))), Box::new(Sub(num(10), num(4)))),
        Div(num(100), Box::new(Sub(num(5), num(5)))),
        Add(Box::new(Mul(Box::new(Neg(num(7))), num(3))), Box::new(Div(num(20), num(4)))),
        Sub(Box::new(Mul(var("x"), var("y"))), num(2)),
        Add(var("z"), num(1)),
        Div(Box::new(Neg(num(9))), num(2)),
        Mul(Box::new(Div(num(1), num(0))), var("q")),
    ]
}

pub fn default_env() -> HashMap<String, i64> {
    HashMap::from([("x".to_string(), 6), ("y".to_string(), 7)])
}

fn main() {
    let env = default_env();
    for e in samples() {
        println!("{}", render(&e, &env));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eval_ok() {
        let env = default_env();
        assert_eq!(eval(&samples()[0], &env), Ok(18));
        assert_eq!(eval(&Div(Box::new(Neg(num(9))), num(2)), &env), Ok(-4));
    }

    #[test]
    fn errors_propagate() {
        let env = default_env();
        assert_eq!(eval(&samples()[6], &env), Err("division by zero".to_string()));
        assert_eq!(eval(&Add(var("z"), num(1)), &env), Err("unknown variable z".to_string()));
    }

    #[test]
    fn show_nested() {
        assert_eq!(show(&samples()[2]), "((-7 * 3) + (20 / 4))");
    }
}
