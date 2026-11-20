# t07_parallel_map — multi-threaded map/reduce

For every `n` in `1..=100000` compute the Collatz step count (`steps(1) = 0`; even `n -> n/2`, odd `n -> 3n+1`;
use 64-bit arithmetic: trajectories exceed 2^31). Reduce to the total number of steps and the longest chain
(ties broken by the smallest `n`).

- Split the range into 4 contiguous chunks, map each chunk on its own OS thread, send each partial
  `(sum, best_n, best_steps)` back over a channel and merge them on the main thread.
  Pion: `scope` + `spawn` + `Channel`; Rust: `std::thread::scope` + `mpsc`; Go: goroutines + `chan` + `sync.WaitGroup`.
- **MoonBit has no shared-memory threads**: its version computes the same four chunks sequentially and is a
  single-threaded baseline (recorded as such, not as a parallel implementation).
- Verify the parallel result equals a sequential pass.

`main` prints `n=100000 chunks=4`, `total_steps=<s>`, `longest=<n> steps=<k>`, `parallel_matches_sequential=true`.
