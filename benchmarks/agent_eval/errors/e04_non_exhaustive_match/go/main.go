package main

import "fmt"

type Color int

const (
	Red Color = iota
	Green
	Blue
)

func hex(c Color) string {
	switch c {
	case Red:
		return "#f00"
	case Green:
		return "#0f0"
	}
	return "" // Blue silently falls through: no exhaustiveness check
}

func main() {
	fmt.Println(hex(Blue))
}
