// app: report over an inventory
package main

import (
	"fmt"

	"t06/inventory"
	"t06/shapes"
)

func Parts() []inventory.Part {
	return []inventory.Part{
		{Name: "panel", Shape: shapes.Rect{W: 4, H: 3}, Qty: 2},
		{Name: "tile", Shape: shapes.Square{S: 2}, Qty: 10},
		{Name: "brace", Shape: shapes.RightTri{Base: 3, Height: 4}, Qty: 4},
		{Name: "door", Shape: shapes.Rect{W: 2, H: 7}, Qty: 1},
	}
}

func Report(ps []inventory.Part) []string {
	var out []string
	for _, p := range ps {
		out = append(out, fmt.Sprintf("%s %s area2=%d qty=%d", p.Name, shapes.KindName(p.Shape), shapes.Area2(p.Shape), p.Qty))
	}
	out = append(out, fmt.Sprintf("total_area2=%d", inventory.TotalArea2(ps)))
	if n, ok := inventory.Largest(ps); ok {
		out = append(out, "largest="+n)
	} else {
		out = append(out, "largest=none")
	}
	return append(out, inventory.QtyByKind(ps)...)
}

func main() {
	for _, l := range Report(Parts()) {
		fmt.Println(l)
	}
}
