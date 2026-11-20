package shapes

import "testing"

func TestArea2(t *testing.T) {
	if Area2(Rect{4, 3}) != 24 || Area2(Square{2}) != 8 || Area2(RightTri{3, 4}) != 12 {
		t.Fatal("area2")
	}
	if KindName(RightTri{1, 1}) != "tri" {
		t.Fatal("kind")
	}
}
