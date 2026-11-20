package main

import (
	"errors"
	"fmt"
)

func save(x int) error {
	if x < 0 {
		return errors.New("negative")
	}
	return nil
}

func main() {
	save(-1)
	fmt.Println("saved")
}
