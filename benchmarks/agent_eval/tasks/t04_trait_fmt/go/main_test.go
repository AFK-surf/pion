package main

import (
	"strings"
	"testing"
)

func TestTweetTruncationBoundary(t *testing.T) {
	if s := (Tweet{"u", "12345678901234567890", 0}).Summary(); s != "@u: 12345678901234567890 [0 likes]" {
		t.Fatal(s)
	}
	if s := (Tweet{"u", "123456789012345678901", 2}).Summary(); s != "@u: 12345678901234567... [2 likes]" {
		t.Fatal(s)
	}
}

func TestRenderAll(t *testing.T) {
	if s := RenderAll([]Metric{}); s != "" {
		t.Fatal(s)
	}
	if !strings.HasPrefix(RenderAll(Mixed()), "1. Article: Agents") {
		t.Fatal("first line")
	}
	if s := Describe(Mixed()[2]); s != "@linus: ok [1 like] | type=tweet;user=linus;likes=1" {
		t.Fatal(s)
	}
}
