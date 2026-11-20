package main

import "testing"

func TestLevels(t *testing.T) {
	if LevelOf(0, 0) != 0 || LevelOf(1, 1) != 0 || LevelOf(0, 3) != 1 {
		t.Fatal("level formula")
	}
	var s Stats
	s.Record(9, 5)
	s.Record(6, 7)
	if s.Debug != 1 || s.Warn != 1 || s.LatSum != 12 {
		t.Fatal("record")
	}
}

func TestSequentialDistribution(t *testing.T) {
	s := Sequential(4, 25000)
	if s.Info != 60000 || s.Warn != 20000 || s.Error != 10000 || s.Debug != 10000 || s.Total() != 100000 {
		t.Fatalf("%+v", s)
	}
}

func TestConcurrentMatches(t *testing.T) {
	s, n := Concurrent(4, 2000)
	if s != Sequential(4, 2000) || n != 8000 {
		t.Fatal("concurrent != sequential")
	}
}
