package inventory

import (
	"strings"
	"testing"

	"t06/shapes"
)

func TestTotals(t *testing.T) {
	ps := []Part{{"a", shapes.Square{S: 1}, 3}, {"b", shapes.Rect{W: 1, H: 2}, 1}}
	if TotalArea2(ps) != 10 {
		t.Fatal("total")
	}
	if got := strings.Join(QtyByKind(ps), "|"); got != "kind rect qty=1|kind square qty=3" {
		t.Fatal(got)
	}
	if n, ok := Largest(ps); !ok || n != "b" {
		t.Fatal("largest")
	}
}
