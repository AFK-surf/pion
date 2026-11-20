package main

import (
	"strings"
	"testing"
)

func TestUpdatePromotesWithoutEviction(t *testing.T) {
	c := NewLRU(2)
	c.Put("x", 1)
	c.Put("y", 2)
	c.Put("x", 10)
	if old, ok := c.Put("z", 3); !ok || old != "y" {
		t.Fatalf("evicted %q %v", old, ok)
	}
	if v, ok := c.Get("x"); !ok || v != 10 {
		t.Fatal("x updated")
	}
	if o := strings.Join(c.Order(), ","); o != "x,z" {
		t.Fatal(o)
	}
}

func TestCapacityOne(t *testing.T) {
	c := NewLRU(1)
	c.Put("a", 1)
	if old, ok := c.Put("b", 2); !ok || old != "a" {
		t.Fatal("evict a")
	}
	if _, ok := c.Get("a"); ok {
		t.Fatal("a gone")
	}
	if c.Evictions != 1 || c.Misses != 1 {
		t.Fatal("stats")
	}
}

func TestScript(t *testing.T) {
	lines := RunScript()
	if len(lines) != 9 || lines[8] != "order=e,d,c hits=4 misses=2 evictions=2" {
		t.Fatalf("%q", lines)
	}
}
