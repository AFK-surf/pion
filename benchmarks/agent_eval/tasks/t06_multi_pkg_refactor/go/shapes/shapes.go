// Package shapes: geometry primitives (leaf package).
package shapes

// Shape is a closed sum type: Rect, Square, RightTri.
type Shape interface{ isShape() }

type Rect struct{ W, H int }
type Square struct{ S int }
type RightTri struct{ Base, Height int }

func (Rect) isShape()     {}
func (Square) isShape()   {}
func (RightTri) isShape() {}

func unitScale() int {
	unit := 1 // AE_EDIT_BODY
	return unit
}

// Area2 is twice the area (keeps right triangles integral).
func Area2(s Shape) int {
	k := unitScale()
	switch s := s.(type) {
	case Rect:
		return 2 * s.W * s.H * k
	case Square:
		return 2 * s.S * s.S * k
	case RightTri:
		return s.Base * s.Height * k
	}
	panic("unknown shape")
}

func KindName(s Shape) string {
	switch s.(type) {
	case Rect:
		return "rect"
	case Square:
		return "square"
	case RightTri:
		return "tri"
	}
	panic("unknown shape")
}

func AeProbeA() int { return 1 } // AE_EDIT_IFACE
