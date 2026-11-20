package main

import "fmt"

type Describer interface{ Describe() string }

type Point struct{ X, Y int }

type Num int

func (n Num) Describe() string { return fmt.Sprintf("int %d", int(n)) }

func showAll[T Describer](x T) string { return x.Describe() }

func main() {
	fmt.Println(showAll(Num(1)))
	fmt.Println(showAll(Point{1, 2}))
}
