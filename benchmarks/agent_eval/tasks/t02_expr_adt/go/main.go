// t02_expr_adt: ADT AST (sealed interface) + recursive eval with error propagation
package main

import (
	"errors"
	"fmt"
	"strconv"
)

// Expr is a closed sum type: only the types below implement isExpr.
type Expr interface{ isExpr() }

type Num struct{ N int }
type Var struct{ Name string }
type Add struct{ L, R Expr }
type Sub struct{ L, R Expr }
type Mul struct{ L, R Expr }
type Div struct{ L, R Expr }
type Neg struct{ E Expr }

func (Num) isExpr() {}
func (Var) isExpr() {}
func (Add) isExpr() {}
func (Sub) isExpr() {}
func (Mul) isExpr() {}
func (Div) isExpr() {}
func (Neg) isExpr() {}

var ErrDivZero = errors.New("division by zero")

func Show(e Expr) string {
	switch e := e.(type) {
	case Num:
		return strconv.Itoa(e.N)
	case Var:
		return e.Name
	case Add:
		return "(" + Show(e.L) + " + " + Show(e.R) + ")"
	case Sub:
		return "(" + Show(e.L) + " - " + Show(e.R) + ")"
	case Mul:
		return "(" + Show(e.L) + " * " + Show(e.R) + ")"
	case Div:
		return "(" + Show(e.L) + " / " + Show(e.R) + ")"
	case Neg:
		return "-" + Show(e.E)
	}
	panic("unreachable: unknown Expr")
}

func evalPair(l, r Expr, env map[string]int) (int, int, error) {
	x, err := Eval(l, env)
	if err != nil {
		return 0, 0, err
	}
	y, err := Eval(r, env)
	if err != nil {
		return 0, 0, err
	}
	return x, y, nil
}

func Eval(e Expr, env map[string]int) (int, error) {
	switch e := e.(type) {
	case Num:
		return e.N, nil
	case Var:
		v, ok := env[e.Name]
		if !ok {
			return 0, fmt.Errorf("unknown variable %s", e.Name)
		}
		return v, nil
	case Add:
		x, y, err := evalPair(e.L, e.R, env)
		return x + y, err
	case Sub:
		x, y, err := evalPair(e.L, e.R, env)
		return x - y, err
	case Mul:
		x, y, err := evalPair(e.L, e.R, env)
		return x * y, err
	case Div:
		x, y, err := evalPair(e.L, e.R, env)
		if err != nil {
			return 0, err
		}
		if y == 0 {
			return 0, ErrDivZero
		}
		return x / y, nil
	case Neg:
		x, err := Eval(e.E, env)
		return -x, err
	}
	panic("unreachable: unknown Expr")
}

func Render(e Expr, env map[string]int) string {
	v, err := Eval(e, env)
	if err != nil {
		return Show(e) + " = error: " + err.Error()
	}
	return Show(e) + " = " + strconv.Itoa(v)
}

func Samples() []Expr {
	return []Expr{
		Mul{Add{Num{1}, Num{2}}, Sub{Num{10}, Num{4}}},
		Div{Num{100}, Sub{Num{5}, Num{5}}},
		Add{Mul{Neg{Num{7}}, Num{3}}, Div{Num{20}, Num{4}}},
		Sub{Mul{Var{"x"}, Var{"y"}}, Num{2}},
		Add{Var{"z"}, Num{1}},
		Div{Neg{Num{9}}, Num{2}},
		Mul{Div{Num{1}, Num{0}}, Var{"q"}},
	}
}

func DefaultEnv() map[string]int { return map[string]int{"x": 6, "y": 7} }

func main() {
	env := DefaultEnv()
	for _, e := range Samples() {
		fmt.Println(Render(e, env))
	}
}
