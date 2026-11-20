// t07_parallel_map: Collatz map/reduce over goroutines + chan
package main

import (
	"fmt"
	"sync"
)

type Partial struct {
	Sum       int64
	BestN     int64
	BestSteps int
}

func Steps(n int64) int {
	k := 0
	for x := n; x != 1; k++ {
		if x%2 == 0 {
			x /= 2
		} else {
			x = 3*x + 1
		}
	}
	return k
}

// Chunk maps and reduces over the inclusive range [lo, hi].
func Chunk(lo, hi int64) Partial {
	acc := Partial{BestSteps: -1}
	for n := lo; n <= hi; n++ {
		k := Steps(n)
		acc.Sum += int64(k)
		if k > acc.BestSteps {
			acc.BestSteps, acc.BestN = k, n
		}
	}
	return acc
}

func Merge(a, b Partial) Partial {
	best := a
	if b.BestSteps > a.BestSteps || (b.BestSteps == a.BestSteps && b.BestN < a.BestN) {
		best = b
	}
	return Partial{Sum: a.Sum + b.Sum, BestN: best.BestN, BestSteps: best.BestSteps}
}

func Parallel(n, workers int64) Partial {
	ch := make(chan Partial, workers)
	size := n / workers
	var wg sync.WaitGroup
	for w := int64(0); w < workers; w++ {
		lo, hi := w*size+1, (w+1)*size
		if w == workers-1 {
			hi = n
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			ch <- Chunk(lo, hi)
		}()
	}
	wg.Wait()
	close(ch)
	acc := Partial{BestSteps: -1}
	for p := range ch {
		acc = Merge(acc, p)
	}
	return acc
}

func main() {
	const n = 100000
	par := Parallel(n, 4)
	seq := Chunk(1, n)
	fmt.Printf("n=%d chunks=4\n", n)
	fmt.Printf("total_steps=%d\n", par.Sum)
	fmt.Printf("longest=%d steps=%d\n", par.BestN, par.BestSteps)
	fmt.Printf("parallel_matches_sequential=%v\n", par == seq)
}
