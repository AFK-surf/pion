package main

import "testing"

func TestReport(t *testing.T) {
	lines := Report(Parts())
	if len(lines) != 9 || lines[4] != "total_area2=204" || lines[5] != "largest=door" {
		t.Fatalf("%q", lines)
	}
}
