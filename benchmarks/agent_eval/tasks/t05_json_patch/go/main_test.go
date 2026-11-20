package main

import "testing"

func mustParse(t *testing.T, s string) any {
	v, err := Parse(s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestMergePatchSemantics(t *testing.T) {
	tg := mustParse(t, `{"a":{"b":1,"c":2},"d":3}`)
	p := mustParse(t, `{"a":{"b":null,"e":[1]},"d":{"x":true}}`)
	if got := Canonical(MergePatch(tg, p)); got != `{"a":{"c":2,"e":[1]},"d":{"x":true}}` {
		t.Fatal(got)
	}
	if got := Canonical(MergePatch(tg, mustParse(t, "7"))); got != "7" {
		t.Fatal(got)
	}
}

func TestValidationOrder(t *testing.T) {
	base := mustParse(t, Base)
	cases := map[string]string{
		`{"server":{"tls":"yes"}}`: "invalid: server.tls: expected bool",
		`{"log":null}`:             "invalid: log: missing",
		`[1]`:                      "invalid: root: expected object",
		`{"server":{"port":0},"log":{"level":"x"}}`: "invalid: server.port: 0 out of range 1..65535",
	}
	for in, want := range cases {
		if got := ApplyOne(base, in); got != want {
			t.Fatalf("%s: got %q want %q", in, got, want)
		}
	}
}
