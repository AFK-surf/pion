# t02_expr_adt — ADT expression AST, recursive evaluation, Result error propagation

Model an arithmetic AST as a sum type: `Num(Int)`, `Var(name)`, `Add`, `Sub`, `Mul`, `Div` (binary) and `Neg` (unary).

- `show(e)`: binary nodes print as `(<l> <op> <r>)`, `Neg(e)` as `-<e>`, numbers in decimal, variables by name.
- `eval(e, env) -> Result[Int, String]`, left operand first; the first error wins:
  - division by zero → `Err("division by zero")`
  - unbound variable `v` → `Err("unknown variable v")`
  - integer division truncates toward zero.
- Use the language's native error propagation: `?` on `Result` in m2 and Rust, early `return err` in Go, checked `raise` effects in MoonBit (current MoonBit has no `?` on `Result`; `eval_result` converts at the boundary).

`main` evaluates seven fixed expressions with env `x=6, y=7` and prints `<show> = <value>` or `<show> = error: <msg>`.
