package main

import (
	"fmt"
	"testing"
)

// cgo cannot be used in _test.go files; the tests call the cgo wrappers.
func TestFFI(t *testing.T) {
	if CStrlen("") != 0 {
		t.Fatal("empty strlen")
	}
	if CAbs(7) != 7 || CAbs(-2147483647) != 2147483647 {
		t.Fatal("abs")
	}
	if Crc32Of("") != 0 || fmt.Sprintf("%08x", Crc32Of(Fox)) != "414fa339" {
		t.Fatal("crc32")
	}
	if fmt.Sprintf("%08x", 255) != "000000ff" {
		t.Fatal("hex padding")
	}
}
