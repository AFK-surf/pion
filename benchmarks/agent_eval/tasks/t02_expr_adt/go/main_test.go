package main

import (
	"errors"
	"testing"
)

func TestEvalOK(t *testing.T) {
	env := DefaultEnv()
	if v, err := Eval(Samples()[0], env); err != nil || v != 18 {
		t.Fatalf("got %d %v", v, err)
	}
	if v, err := Eval(Div{Neg{Num{9}}, Num{2}}, env); err != nil || v != -4 {
		t.Fatalf("truncating division: %d %v", v, err)
	}
}

func TestErrorsPropagate(t *testing.T) {
	env := DefaultEnv()
	if _, err := Eval(Samples()[6], env); !errors.Is(err, ErrDivZero) {
		t.Fatalf("left error wins: %v", err)
	}
	if _, err := Eval(Add{Var{"z"}, Num{1}}, env); err == nil || err.Error() != "unknown variable z" {
		t.Fatalf("unknown var: %v", err)
	}
}

func TestShow(t *testing.T) {
	if s := Show(Samples()[2]); s != "((-7 * 3) + (20 / 4))" {
		t.Fatal(s)
	}
}
