package main

import (
	"fmt"
	"os"
)

// loadConfig is a "pure" helper that quietly does file IO.
func loadConfig(path string) string {
	b, _ := os.ReadFile(path)
	return string(b)
}

func main() {
	fmt.Println(len(loadConfig("/etc/hosts")))
}
