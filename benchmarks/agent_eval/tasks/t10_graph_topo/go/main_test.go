package main

import "testing"

func TestDuplicatesAndSelfLoops(t *testing.T) {
	cases := map[string]string{
		"b -> a\nb -> a\nc": "g order: b a c",
		"x -> x\ny":         "g cycle: ordered=y blocked=x",
		"":                  "g order: ",
	}
	for in, want := range cases {
		if got := Describe("g", in); got != want {
			t.Fatalf("%q: %q", in, got)
		}
	}
}

func TestErrors(t *testing.T) {
	if got := Describe("g", "\n -> b"); got != "g error: line 2: malformed edge '-> b'" {
		t.Fatal(got)
	}
}
