// V2 Benchmark 3: mt_log_pipeline (Go, goroutines + bounded channels + atomic)
// Usage: mt_log_pipeline <logs.txt> [1|4]
package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

type workerStats struct {
	lines  int32
	errs   int32
	slow   int32
	sumLat int64
	svcSum int64
	msgXor int32
}

func polyHash(s string) int32 {
	var h uint32
	for i := 0; i < len(s); i++ {
		h = (h*31 + uint32(s[i])) & 0x3fffffff
	}
	return int32(h)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "usage: %s <logs.txt> [1|4]\n", os.Args[0])
		os.Exit(2)
	}
	nworkers := 1
	if len(os.Args) >= 3 {
		if n, err := strconv.Atoi(os.Args[2]); err == nil && n >= 1 && n <= 16 {
			nworkers = n
		}
	}
	if nworkers == 1 {
		runtime.GOMAXPROCS(1)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "read error: %v\n", err)
		os.Exit(1)
	}
	src := string(data)

	workCh := make(chan string, 64)
	alertCh := make(chan string, 256)
	statsCh := make(chan workerStats, nworkers)
	var active atomic.Int32
	active.Store(int32(nworkers))

	var wg sync.WaitGroup
	wg.Add(1 + nworkers)

	// Producer
	go func() {
		defer wg.Done()
		n := len(src)
		pos := 0
		for pos < n {
			start := pos
			nl := 0
			for pos < n && nl < 10 {
				if src[pos] == '\n' {
					nl++
				}
				pos++
			}
			// Heap-allocate a standalone copy of the chunk (matching C/Rust/Zig/pion)
			chunk := strings.Clone(src[start:pos])
			workCh <- chunk
		}
		close(workCh)
	}()

	// Workers
	for t := 0; t < nworkers; t++ {
		go func() {
			defer wg.Done()
			svcLat := make(map[string]int64, 16)
			var lines, errs, slow, msgXor int32
			var sumLat int64

			for chunk := range workCh {
				n := len(chunk)
				i := 0
				for i < n {
					lineStart := i
					for i < n && chunk[i] != '\n' {
						i++
					}
					lineEnd := i
					if i < n && chunk[i] == '\n' {
						i++
					}
					if lineEnd <= lineStart {
						continue
					}
					lines++
					p := lineStart
					for p < lineEnd && chunk[p] != ' ' {
						p++
					}
					if p < lineEnd {
						p++
					}
					p += 6 // level=
					lvlS := p
					for p < lineEnd && chunk[p] != ' ' {
						p++
					}
					lvlE := p
					if p < lineEnd {
						p++
					}
					p += 4 // svc=
					svcS := p
					for p < lineEnd && chunk[p] != ' ' {
						p++
					}
					svcE := p
					if p < lineEnd {
						p++
					}
					p += 4 // lat=
					var lat int32
					for p < lineEnd && chunk[p] != ' ' {
						lat = lat*10 + int32(chunk[p]-'0')
						p++
					}
					if p < lineEnd {
						p++
					}
					p += 4 // msg=
					msgS := p

					lat64 := int64(lat)
					sumLat += lat64
					svc := chunk[svcS:svcE]
					svcLat[svc] += lat64
					msgXor ^= polyHash(chunk[msgS:lineEnd])

					isErr := (lvlE-lvlS == 3) && chunk[lvlS] == 'E' && chunk[lvlS+1] == 'R' && chunk[lvlS+2] == 'R'
					isSlow := lat >= 500
					if isErr {
						errs++
					}
					if isSlow {
						slow++
					}
					if isErr || isSlow {
						alert := "ALERT|" + svc + "|" + chunk[lvlS:lvlE] + "|" + strconv.Itoa(int(lat)) + "|" + chunk[msgS:lineEnd]
						alertCh <- alert
					}
				}
			}

			var svcSum int64
			for _, v := range svcLat {
				svcSum += v
			}
			if active.Add(-1) == 0 {
				close(alertCh)
			}
			statsCh <- workerStats{
				lines:  lines,
				errs:   errs,
				slow:   slow,
				sumLat: sumLat,
				svcSum: svcSum,
				msgXor: msgXor,
			}
		}()
	}

	var alertCnt, alertXor int32
	var alertLenSum int64
	for alert := range alertCh {
		alertCnt++
		alertLenSum += int64(len(alert))
		alertXor ^= polyHash(alert)
	}

	wg.Wait()
	close(statsCh)

	var lines, errs, slow, msgXor int32
	var sumLat, svcSum int64
	for st := range statsCh {
		lines += st.lines
		errs += st.errs
		slow += st.slow
		sumLat += st.sumLat
		svcSum += st.svcSum
		msgXor ^= st.msgXor
	}
	if svcSum != sumLat {
		fmt.Fprintf(os.Stderr, "svcSum mismatch: %d vs %d\n", svcSum, sumLat)
		os.Exit(1)
	}

	fmt.Printf("%d %d %d %d %d %d %d %d\n",
		lines, errs, slow, sumLat, msgXor, alertCnt, alertLenSum, alertXor)
}
