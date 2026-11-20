package main

import (
	"strings"
	"testing"
)

func TestParseUint(t *testing.T) {
	cases := []struct {
		in string
		v  int
		ok bool
	}{{"0", 0, true}, {"120", 120, true}, {"", 0, false}, {"-1", 0, false}, {"1x", 0, false}, {"1234567890", 0, false}}
	for _, c := range cases {
		v, ok := ParseUint(c.in)
		if v != c.v || ok != c.ok {
			t.Fatalf("ParseUint(%q) = %d,%v", c.in, v, ok)
		}
	}
}

func TestCRLFAndHeaderOnly(t *testing.T) {
	r := Aggregate("region,product,qty,price_cents\r\n")
	if len(r.Regions) != 0 || r.Invalid != 0 {
		t.Fatal("header only")
	}
	r2 := Aggregate("region,product,qty,price_cents\r\na,b,2,5\r\na,c,1,1\r\n")
	if len(r2.Regions) != 1 || r2.Regions[0].Qty != 3 || r2.Regions[0].Revenue != 11 {
		t.Fatalf("crlf sums: %+v", r2)
	}
}

func TestSample(t *testing.T) {
	r := Aggregate(Sample)
	if r.Invalid != 3 || len(r.Regions) != 4 {
		t.Fatalf("counts: %+v", r)
	}
	if r.Regions[1].Region != "north" || r.Regions[1].Revenue != 980 {
		t.Fatal("north")
	}
	if !strings.HasSuffix(FormatReport(r), "total_revenue=1550") {
		t.Fatal("total")
	}
}
