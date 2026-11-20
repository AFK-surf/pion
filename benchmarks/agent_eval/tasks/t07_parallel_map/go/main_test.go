package main

import "testing"

func TestSteps(t *testing.T) {
	for n, want := range map[int64]int{1: 0, 6: 8, 27: 111, 77031: 350} {
		if got := Steps(n); got != want {
			t.Fatalf("Steps(%d)=%d", n, got)
		}
	}
}

func TestMergeTieBreakAndChunking(t *testing.T) {
	a := Partial{10, 9, 19}
	b := Partial{5, 7, 19}
	if Merge(a, b).BestN != 7 || Merge(b, a).BestN != 7 || Merge(a, b).Sum != 15 {
		t.Fatal("merge")
	}
	if Merge(Merge(Chunk(1, 300), Chunk(301, 700)), Chunk(701, 1000)) != Chunk(1, 1000) {
		t.Fatal("chunking")
	}
}

func TestParallelEqualsSequential(t *testing.T) {
	if Parallel(5000, 4) != Chunk(1, 5000) {
		t.Fatal("parallel != sequential")
	}
}
