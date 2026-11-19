# `m2` Multi-Language Objective Benchmark Suite (D5)

Objective, checksum-verified, one-command reproducible benchmark suite comparing **`m2`** against **C (`clang -O2`)**, **MoonBit (`moon build --target native --release`)**, **Zig (`zig build-exe -OReleaseFast`)**, and **Rust (`rustc -O` / `cargo build --release`)**.

## Dimensions Covered

### 1. Classic Execution Speed (6 Benchmarks, 7 Cases)
All programs print a strict deterministic checksum to prevent dead-code elimination (DCE). `scripts/bench.sh` asserts bit-for-bit identical checksums across every language.

| Benchmark | Workload | Verified Checksum |
|---|---|---|
| `nbody` | Benchmarks Game 5-body orbital simulation (`N = 5,000,000`, `dt = 0.01`) | `-0.169075164 -0.169083134` |
| `binarytrees` | Benchmarks Game recursive heap tree alloc/check/free (`max_depth = 16`) | `stretch=262143 long=131071 total=14592688` |
| `spectralnorm` | Benchmarks Game eigenvalue power iteration (`N = 2000`, 10 iters) | `1.274224152` |
| `fannkuchredux` | Benchmarks Game pancake-flip permutations (`N = 10`, `10! = 3,628,800`) | `73196 38` |
| `mandelbrot_1t` | Benchmarks Game Mandelbrot (`4000×4000`, 50 iters, 1 thread) | `6351041 721219984` |
| `mandelbrot_4t` | Same Mandelbrot (`4000×4000`, 4 threads: `m2` `scope`/`spawn`/`Channel`, C `pthread`, Zig `std.Thread`, Rust `std::thread`; MoonBit is single-threaded baseline) | `6351041 721219984` |
| `hashmap_str` | 100,000 string-keyed inserts + 400,000 lookups (200k hit / 200k miss) + `StringBuilder` concat & hash | `200000 208681440 205599 815496841` |

*Note on floating-point determinism*: Apple `clang -O2` enables `-ffp-contract=fast` by default, whereas Rust, Zig, MoonBit, and `m2` use strict IEEE-754 rounding. `scripts/bench.sh` passes `-ffp-contract=off` to `clang -O2` so all languages execute identical IEEE-754 arithmetic.

### 2. Compile Speed (10,000 LOC / 20 Packages)
`benchmarks/tools/gen_compile_bench.c` deterministically generates an equivalent 20-package (~10,000 LOC) layered DAG project for C, MoonBit, Zig, Rust, and `m2`:
- **Cold compile**: end-to-end build from clean state (checksum `796114417`).
- **Incremental compile**: 1-line edit inside a function body in `pkg05` (no `pub` signature change, all other 19 packages untouched) + relink (checksum `688976608`).

### 3. Artifact Size & Worktree Cache Pollution
- Default and `strip`ped binary sizes (bytes) for `hello` and all 6 execution benchmarks.
- In-tree build cache size (`*.o`, `_build/`, `.zig-cache/`, `target/`) vs `m2`'s `0 B` worktree pollution + global CAS (`$M2_CACHE_DIR`).

### 4. Measurement Protocol
- Pure C timing harness (`benchmarks/tools/bench_measure.c`, zero Python).
- Each execution benchmark: **1 warmup + 5 timed runs**, reporting median/min/max `CLOCK_MONOTONIC` wall-clock ms, plus Peak RSS (MB) and `instructions retired` via macOS `/usr/bin/time -l`.
- Outputs structured JSON (`out/bench-results.json`) and Markdown summary (`out/bench-summary.md`).

## Usage

```sh
# 1. Verify all benchmarks/m2/*.m2 + generated 10,000-LOC/20-pkg m2 project pass Stage 0 m2c0 check --json
sh scripts/bench.sh --check-m2

# 2. Run full baseline (C / MoonBit / Zig / Rust)
sh scripts/bench.sh

# 3. Include m2 once Stage 1/2 m2c binary is built
M2C=/path/to/m2c sh scripts/bench.sh
```
