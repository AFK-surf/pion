package main

import (
	"fmt"
	"sync"
)

func main() {
	var hits []int
	var wg sync.WaitGroup
	for w := 0; w < 4; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 1000; i++ {
				hits = append(hits, w)
			}
		}()
	}
	wg.Wait()
	fmt.Println(len(hits))
}
