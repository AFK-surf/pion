# t08_concurrent_counter — many producers, shared state, Mutex + Atomic

4 producer threads each emit 25000 events. Event `j` of producer `p` has
level `r = (7j + 3p) % 10` → `info` (r ≤ 5), `warn` (6–7), `error` (8), `debug` (9),
and latency `(1000p + j) % 97`.

- Shared aggregate: per-level counters + latency sum behind **one mutex** (each event: lock, update, unlock);
  plus a lock-free **atomic** event counter incremented per event.
- Join all producers (structured concurrency), then compare against a sequential computation.
- m2: `Mutex[Stats]` over an immutable `val struct` (`lock` / `set` / `unlock`) + `AtomicInt`, threads via `scope`/`spawn`;
  Rust: `Mutex<Stats>` + `AtomicU64` in `thread::scope`; Go: `sync.Mutex` + `atomic.Int64` + `WaitGroup`.
  **MoonBit has no shared-memory threads**: its version runs the four producers one after another (no locks
  needed) and is recorded as a single-threaded baseline.

`main` prints `producers=4 events=100000`, the per-level counts, `latency_sum=<n>`,
`atomic_total=<n> mutex_total=<n>` and `consistent=true`.
