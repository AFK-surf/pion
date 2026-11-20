package main

import "fmt"

func main() {
	const total = 0 // Go locals are always mutable; const is the only immutable binding
	for i := 0; i < 3; i++ {
		total = total + i
	}
	fmt.Println(total)
}
