// Package inventory: parts lists over shapes.
package inventory

import (
	"fmt"
	"sort"

	"t06/shapes"
)

type Part struct {
	Name  string
	Shape shapes.Shape
	Qty   int
}

func TotalArea2(parts []Part) int {
	sum := 0
	for _, p := range parts {
		sum += shapes.Area2(p.Shape) * p.Qty
	}
	return sum
}

// Largest returns the first part with the maximal single-piece area.
func Largest(parts []Part) (string, bool) {
	best, name := -1, ""
	for _, p := range parts {
		if a := shapes.Area2(p.Shape); a > best {
			best, name = a, p.Name
		}
	}
	return name, best >= 0
}

func QtyByKind(parts []Part) []string {
	totals := map[string]int{}
	for _, p := range parts {
		totals[shapes.KindName(p.Shape)] += p.Qty
	}
	kinds := make([]string, 0, len(totals))
	for k := range totals {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	out := make([]string, 0, len(kinds))
	for _, k := range kinds {
		out = append(out, fmt.Sprintf("kind %s qty=%d", k, totals[k]))
	}
	return out
}
