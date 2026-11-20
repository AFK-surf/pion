package main

import (
	"fmt"
	"strconv"
)

type Area interface{ Area() int }

type Sq struct{ Side int }

func (s Sq) Area() string { return strconv.Itoa(s.Side * s.Side) }

func total[T Area](x T) int { return x.Area() }

func main() {
	fmt.Println(total(Sq{3}))
}
