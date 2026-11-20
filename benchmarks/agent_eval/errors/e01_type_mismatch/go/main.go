package main

import (
	"fmt"
	"strconv"
)

func label(n int) int {
	return "n=" + strconv.Itoa(n)
}

func main() {
	fmt.Println(label(3))
}
