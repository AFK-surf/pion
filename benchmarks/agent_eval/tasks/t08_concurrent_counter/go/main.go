// t08_concurrent_counter: sync.Mutex + atomic.Int64 across producer goroutines
package main

import (
	"fmt"
	"sync"
	"sync/atomic"
)

type Stats struct {
	Info, Warn, Error, Debug, LatSum int64
}

func (s *Stats) Record(r, lat int64) {
	switch {
	case r <= 5:
		s.Info++
	case r <= 7:
		s.Warn++
	case r == 8:
		s.Error++
	default:
		s.Debug++
	}
	s.LatSum += lat
}

func (s Stats) Total() int64 { return s.Info + s.Warn + s.Error + s.Debug }

func LevelOf(p, j int64) int64   { return (7*j + 3*p) % 10 }
func LatencyOf(p, j int64) int64 { return (1000*p + j) % 97 }

func Sequential(producers, per int64) Stats {
	var s Stats
	for p := int64(0); p < producers; p++ {
		for j := int64(0); j < per; j++ {
			s.Record(LevelOf(p, j), LatencyOf(p, j))
		}
	}
	return s
}

func Concurrent(producers, per int64) (Stats, int64) {
	var (
		mu     sync.Mutex
		shared Stats
		events atomic.Int64
		wg     sync.WaitGroup
	)
	for p := int64(0); p < producers; p++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := int64(0); j < per; j++ {
				mu.Lock()
				shared.Record(LevelOf(p, j), LatencyOf(p, j))
				mu.Unlock()
				events.Add(1)
			}
		}()
	}
	wg.Wait()
	return shared, events.Load()
}

func main() {
	s, n := Concurrent(4, 25000)
	seq := Sequential(4, 25000)
	fmt.Printf("producers=4 events=%d\n", seq.Total())
	fmt.Printf("info=%d warn=%d error=%d debug=%d\n", s.Info, s.Warn, s.Error, s.Debug)
	fmt.Printf("latency_sum=%d\n", s.LatSum)
	fmt.Printf("atomic_total=%d mutex_total=%d\n", n, s.Total())
	fmt.Printf("consistent=%v\n", s == seq && n == seq.Total())
}
