package main

import (
	"slices"
	"testing"
)

func TestChunkingInvariance(t *testing.T) {
	a, b, c := Run(1), Run(5), Run(16)
	if Summary(a) != Summary(b) || Summary(b) != Summary(c) {
		t.Fatal(Summary(a), Summary(b), Summary(c))
	}
	if !slices.Equal(a.Frames, c.Frames) || a.Overflow != 0 || c.Overflow != 0 {
		t.Fatal("frames / overflow")
	}
}

func TestFrameDetails(t *testing.T) {
	p := &FrameParser{}
	p.Feed([]byte{0xAA, 2, 0xFF, 1})
	if len(p.Frames) != 0 || p.Count != 4 {
		t.Fatal("needs checksum byte")
	}
	p.Feed([]byte{0})
	if len(p.Frames) != 1 || p.Frames[0] != "ff01" {
		t.Fatal(p.Frames)
	}
}
