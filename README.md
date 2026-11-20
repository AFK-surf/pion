# `m2`

**An agent-friendly, zero-LLVM, C-speed, memory-safe, natively multithreaded systems programming language with bit-for-bit self-hosting.**

`m2` is a strict subset/evolution of MoonBit syntax built for deterministic machine & human collaboration: explicit top-level signatures, structured JSON compiler APIs with fix-its, an embedded QBE backend that writes native objects directly, biased reference counting, compile-time data-race freedom, explicit `World` capabilities, and a global content-addressed cache that leaves zero `target/` or `_build/` in source worktrees.

[`SPEC.md`](SPEC.md) is the authoritative grammar, type system, runtime ABI and JSON protocol specification.

---

## Architecture

- **Agent-friendly by construction**: no cross-function type inference (every top-level parameter and return type is written), one-line JSON diagnostics with a stable `code` and a `fixit` hint (`m2c check --json`), symbol/signature/call-graph/dependency queries (`m2c query ... --json`), API docs as JSON (`m2c doc --json`) and a deterministic formatter (`m2c fmt --check --json`). Agent foot-guns are compile errors: a discarded `Result` (`E_UNHANDLED_RESULT`), `==` on boxed values that would silently compare pointers (`E_TYPE_MISMATCH`), non-exhaustive `match`, IO without a `World`, data races (`E_NOT_SEND`).
- **Zero LLVM**: per-package QBE SSA IL → embedded/vendored QBE 1.3 → **native objects written directly** (ARM64 Mach-O and x86_64 Linux ELF64 `.o`, no system assembler) → system linker + a `<64 KB` C11 runtime (`libm2rt.a`).
- **Runtime**: Biased Reference Counting (non-atomic on the owning thread, frozen to atomic when a value crosses threads), size-class slab allocator with batched remote frees, immortal `.rodata` literals and payload-less enum constants, native OS threads.
- **Global CAS, zero worktree pollution**: `.m2sig`, `.ssa` and `.o` artifacts live in an LRU-evicted content-addressed cache (`$M2_CACHE_DIR`, default `~/.cache/m2/cas`) keyed by compiler fingerprint and upstream `.m2sig` hashes; `git status --ignored` stays clean and parallel worktrees share work.
- **Self-hosting**: `m2c0` (MoonBit host) → `m2c1` → `m2c2` reaches a bit-for-bit fixed point (identical SSA & assembly SHA-256) on ARM64 macOS; on x86_64 Linux the cross-emitted compiler rebuilds itself with Stage 3 == Stage 4 bit-for-bit, without ever invoking `as`.

## Language at a Glance

- `m2 ∩ MoonBit` syntax: the compiler core (`compiler/src/core/`) compiles unchanged with both `moon` and `m2c`.
- Data: `struct` / `val struct` (immutable, `Send`), `enum` ADTs, generics, tuples and destructuring, `Array`, `Map`, `Bytes`, `StringBuilder`, `Option` / `Result`.
- Control flow: `match` with guards and exhaustiveness, postfix `?` on `Result` / `Option`, `for i in a..b`, `for x in arr`, string interpolation `"\{x}"`.
- Concurrency: `scope` / `spawn` structured OS threads, `Channel[T]`, `Mutex[T]`, `AtomicInt`, compile-time `Send` checking.
- Capabilities: IO, clocks, processes, TCP and sleeping require the explicit `World` value.
- FFI: `extern "C" fn`, `Ptr` plus pointer/C-string helpers, `-l <lib>` / `m2.toml` `[link]`.
- Traits: `trait` / `impl` with bounded generics, monomorphized (zero-cost static dispatch).
- Full UTF-8 strings (scalar iteration, byte-exact formatting); `std/json` and `std/http` written in pure `m2`.
- Equality is by value only: `==` on scalars, `String`, `Ptr` and payload-less enums; boxed values are inspected with `match`.

## Language Tour

```m2
import "analyzer" as az

// Generic function + tuple destructuring + tuple indexing
fn pair_swap[A, B](p : (A, B)) -> (B, A) {
  let (a, b) = p
  (b, a)
}

// Match guards with exhaustiveness checking and fallthrough
fn classify(opt : Option[String]) -> String {
  match opt {
    Some(s) if s.length() > 6 => "long:\{s}"
    Some(s) if s.starts_with("hi") => "greet:\{s}"
    Some(s) => "other:\{s}"
    None => "none"
  }
}

// Postfix `?` error propagation on Result / Option
fn double_if(ok : Bool, v : Int) -> Result[Int, String] {
  let r : Result[Int, String] = if ok { Ok(v) } else { Err("disabled") }
  let x = r?
  Ok(x * 2)
}

// Explicit World capability + structured concurrency
pub fn main(world : World) -> Int {
  let ch : Channel[Int] = Channel::new(4)
  scope(world, fn(s : Scope) -> Unit {
    for i in 0..4 {
      spawn(s, fn() -> Unit {
        let _ = ch.send(i * 10)
      })
    }
  })
  ch.close()

  let (label, _, score) : (String, String, Int) = ("m2", "unused", 42)
  let swapped = pair_swap((label, score))
  io_println(world, "label=\{swapped.1} score=\{swapped.0} kind=\{classify(Some("hi!"))}")
  0
}

// Built-in test blocks (compiled only by `m2c test`, 0 bytes in `m2c build`)
test "pair_swap works" {
  let p = pair_swap(("a", 1))
  debug_assert(p.0 == 1 && p.1 == "a", "swap mismatch")
}
```

Multi-package projects use `m2.toml` with package-level `.m2sig` incremental isolation and visibility enforcement (`pub` vs `E_PRIVATE_SYMBOL`):

```toml
[package]
name = "text_stats"
version = "0.1.0"

[dependencies]
analyzer = { path = "./deps/analyzer" }
```

See [`examples/text_stats/`](examples/text_stats/) for a complete multi-package project.

---

## CLI Reference

| Command | Purpose |
|---|---|
| `m2c check [--json] <path...>` | Type, exhaustiveness, must-use `Result`, `Send`, `World` and visibility checks; JSON diagnostics with fix-its |
| `m2c query defs\|sig\|callers\|deps [--json] <path...>` | Symbol definitions, exported `.m2sig` interface, call graph, package dependency graph |
| `m2c doc [--json] <path...>` | Public API of each package (dependencies first) |
| `m2c emit-sig <path...>` | Print the `.m2sig` export table |
| `m2c build [--release] [--target arm64_apple\|amd64_sysv] [--emit-obj <f>] [--emit-ssa <f>] [--emit-asm <f>] [--jobs <n>] [-l <lib>] [-o <bin>] <path...>` | Native binary via the global CAS (`--release` strips `debug_assert`; `--target amd64_sysv --emit-obj` cross-emits an ELF64 `.o`) |
| `m2c run [--release] [-l <lib>] <path> [-- args...]` | Build and execute a package or `.m2` file |
| `m2c test [--json] [--filter <name>] [-l <lib>] <path>` | Run `test "name" { ... }` blocks in isolated child processes with active `debug_assert` |
| `m2c fmt [--check] [--json] <path...>` | Deterministic, idempotent, comment- and UTF-8-preserving formatter |

---

## Measured Results

Every number below is copied from an archived run of the scripts named in each section; rerun them to reproduce (absolute milliseconds vary with machine load, checksums do not).

### 1. V2 real workloads, 6 languages (`sh scripts/bench-v2-exec.sh`)

Apple M5 Max (18 cores), Darwin 27.0.0 arm64; 1 warmup + 5 runs, median; checksums identical across all six languages. C `clang -O2`, MoonBit `--target native --release`, Zig `-OReleaseFast`, Rust `-O`, Go `go build`, m2 `m2c2 build --release`.

| Median ms (peak RSS MB) | C | MoonBit | Zig | Rust | Go | **m2** |
|---|---:|---:|---:|---:|---:|---:|
| `json_query` (11.6 MB JSON) | 49.96 (76.7) | 66.48 (92.8) | 48.51 (81.5) | 41.55 (67.4) | 47.91 (107.3) | **61.02** (123.4) |
| `bytecode_vm` | 50.17 (2.4) | 54.12 (2.7) | 43.89 (2.5) | 47.52 (2.7) | 39.65 (10.2) | **64.38** (3.0) |
| `mt_log_pipeline_1t` (17.5 MB log) | 44.12 (18.6) | 69.97 (18.9) | 41.08 (18.6) | 44.80 (18.8) | 32.57 (39.5) | **58.42** (18.6) |
| `mt_log_pipeline_4t` | 34.45 (18.6) | N/A (1T) | 34.05 (18.7) | 32.68 (18.9) | 24.52 (41.9) | **38.87** (18.8) |
| 3 binaries, stripped bytes | 103,576 | 757,240 | 505,064 | 1,167,864 | 7,159,144 | **282,360** |

### 2. V2 compile: 50k LOC, 50 packages, 4-layer diamond DAG (`sh scripts/bench-v2-compile.sh`)

Same host; checksums identical across languages for the cold build and all three edits. "5-WT" = five worktrees built one after another with a shared global cache.

| Lang | Cold (ms) | Leaf body edit (ms) | Core body edit (ms) | Core signature edit (ms) | 5-WT total (ms) | 5-WT in-tree cache | 5-WT global cache |
|---|---:|---:|---:|---:|---:|---:|---:|
| C (`make -j12`) | 1182.54 | 229.93 | 257.31 | 282.80 | 5971.52 | 1.55 MB | 0 |
| MoonBit | 12385.33 | 14426.37 | 12487.42 | 12950.61 | 114580.56 | 101.31 MB | 0 |
| Zig | 15623.89 | 18844.81 | 15068.23 | 15303.62 | 124411.48 | 44.97 MB | 43.36 MB |
| Rust (`cargo`) | 855.29 | 763.43 | 1339.28 | 934.21 | 5816.21 | 18.33 MB | 0 |
| Go | 1356.58 | 436.75 | 447.80 | 460.28 | 3610.74 | 0 | 80.57 MB |
| **m2 (`m2c2`)** | **241.13** | **198.75** | **162.77** | **271.03** | **830.99** | **0** | 12.97 MB |

### 3. Dogfood applications

| | `examples/http_kv_service` | `examples/sqlite_indexer` |
|---|---|---|
| What | multithreaded HTTP + JSON key-value service on `std/http` / `std/json` | pure-`m2` indexer calling the system `libsqlite3` through `extern "C"` (zero C glue) |
| Load / work | Linux x86_64, 8 concurrent clients × 500 = 4,000 real TCP requests, 0 errors | indexes `compiler/src/core` (14 files / 29,468 lines), cross-checked 100% by the `sqlite3` CLI |
| Speed | 34,110–37,764 QPS, P50 0.20 ms, P99 0.51–0.62 ms, peak RSS 14.5 MB | compiles in 41–76 ms |
| Binary | 112 KB stripped | 123 KB |
| Memory safety | ASan + LSan: 0 errors, 0 leaks | ASan + LSan: 0 errors, 0 leaks |

Reproduce: `sh examples/http_kv_service/run_bench.sh <m2c> 8 500 8` (run by `scripts/test-linux.sh`) and `scripts/verify-all.sh` gate 6.

### 4. Agent-in-the-loop evaluation, 4 languages (`sh benchmarks/agent_eval/run.sh`)

Full report: [`benchmarks/agent_eval/SUMMARY.md`](benchmarks/agent_eval/SUMMARY.md). 12 engineering tasks and 12 error-class probes per language; check commands `m2c2 check --json`, `moon check --output-json`, `cargo check --message-format=json`, `go build -json`.

Run of 2026-11-20 on Apple M5 Max (shared station; medians of 1 warmup + 5 runs). Gates: 48/48 reference implementations pass, 48/48 probes measured with 0 expectation mismatches.

|  | **m2** | MoonBit | Rust | Go |
|---|---:|---:|---:|---:|
| error classes caught before running (of 12) | **12** | 10 | 10 | 8 |
| caught with JSON diagnostics / any fix suggestion | **12/12 / 12** | 10/10 / 0 | 10/10 / 7 | 8/8 / 0 |
| median check latency (ms) | **3.5** | 49.0 | 61.5 | 57.9 |
| median diagnostic size when caught (bytes) | 436.5 | 538.5 | 4798.0 | 343.0 |
| effective LOC, 12 tasks | 1526 | 1393 | 1446 | 1539 |
| private body edit → tests green (ms) | 220.7 | 458.8 | 898.4 | 155.9 |
| 5 worktrees check+test concurrently, cold (wall ms) | **170.1** | 1611.9 | 1384.7 | 6145.5 |
| build artefacts inside the 5 worktrees (MB) | **0.0** | 42.1 | 63.8 | 0.0 |

m2's two former blind spots found by this suite — a silently discarded `Result` (probe `e09`) and `opt == Some(x)` comparing pointers — are compile errors since P15 (`E_UNHANDLED_RESULT`, `E_TYPE_MISMATCH`). rustc is the only checker emitting machine-applicable edits (4 of 12); m2's fix-its are hints.

### 4. V1 classic kernels (5 languages)

Archived P8 run (`p8-bench-summary.md`) on **Apple M5 Max (18 cores), Darwin 27.0.0 arm64** via `M2C=$PWD/out/m2c2 sh scripts/bench.sh` (1 warmup + 5 timed runs, median wall time in ms, strict bit-for-bit checksum verification across all 5 languages):

- **Toolchains**: Apple clang 21.0.0 (`-O2`), MoonBit `0.1.20261117` (`--target native --release`), Zig `0.17.1` (`-OReleaseFast`), Rust `1.100.0` (`-O` / `--release`), `m2c2 0.1.0` (self-hosted QBE backend).

#### Execution Speed (Median Wall Time, ms)

| Benchmark | C (`-O2`) | MoonBit | Zig (`-OReleaseFast`) | Rust (`-O`) | **m2 (`m2c2`)** |
|---|---:|---:|---:|---:|---:|
| `nbody` | 146.01 | 271.93 | 142.61 | 142.41 | **155.68** |
| `binarytrees` | 258.32 | 66.74 | 257.00 | 422.60 | **67.75** |
| `spectralnorm` | 101.08 | 105.94 | 100.72 | 102.74 | **104.46** |
| `fannkuchredux` | 172.21 | 136.61 | 128.04 | 129.10 | **130.66** |
| `mandelbrot_1t` | 532.88 | 531.39 | 509.55 | 533.82 | **467.33** |
| `mandelbrot_4t` | 203.90 | N/A (1T) | 192.76 | 205.03 | **178.95** |
| `hashmap_str` | 39.65 | 43.12 | 18.73 | 39.75 | **31.45** |

#### Compile Speed (10,000 LOC / 20 Packages) & Worktree Cache Pollution

| Language | Cold Compile (ms) | 1-Line Body Edit Incr (ms) | Worktree Cache | Global CAS |
|---|---:|---:|---:|---:|
| C (`make -j8`) | 207.60 | 84.81 | 0.28 MB | 0 |
| MoonBit | 717.36 | 542.79 | 3.79 MB | 0 |
| Zig | 1565.69 | 224.15 | 1.20 MB | 0 |
| Rust (`cargo`) | 919.45 | 668.85 | 2.47 MB | 0 |
| **m2 (`m2c2`)** | **64.63** *(5-run median: 66.2 ms)* | **31.19** *(5-run median: 30.7 ms)* | **0.00 MB** | 1.43 MB |

#### Binary Artifact Sizes (Default / Stripped)

| Language | `hello` (bytes) | 6-Benchmark Total (bytes) |
|---|---:|---:|
| C | 33,432 / 33,432 | 218,648 / 218,528 |
| Zig | 52,104 / 50,184 | 1,963,576 / 1,750,048 |
| **m2 (`m2c2`)** | **78,744 / 71,976** | **572,712 / 531,024** |
| MoonBit | 283,256 / 241,176 | 1,706,616 / 1,447,216 |
| Rust | 471,736 / 342,920 | 3,023,928 / 2,213,584 |

---

---

## Known Limitations & Next Steps

- No dynamic dispatch: traits are monomorphized only, there are no trait objects (heterogeneous collections use a closed `enum`).
- `fixit` is a natural-language hint, not a span-based machine-applicable patch.
- No package registry: dependencies are `path = ...` entries in `m2.toml`.
- `Send` is structural and conservative: `Mutex[Map[K, V]]` with flat values is `Send`, but nested containers such as `Mutex[Map[K, Array[V]]]` are not yet.
- `==` inside a generic function is admitted for any `T`; instantiating it with a boxed type still compares identity (the non-generic case is a compile error).
- `m2c test <workspace>` runs only the root package's tests; `m2c query defs|callers` needs source files rather than a workspace directory.
- Targets: ARM64 macOS (Mach-O) and x86_64 Linux (ELF64) are verified; other QBE targets are not.

## Quick Start & Full Reproduction

```sh
# Build the toolchain and run all 6 gates on macOS ARM64:
# Stage 0 unit tests, <64 KB runtime (O2 + TSan + ASan), 9/9 fixed-point
# bootstrap, fmt (UTF-8), std/json + std/http + dogfood app tests, cross ELF64 .o
sh scripts/verify-all.sh
out/m2c2 run examples/text_stats

# Linux x86_64 with the macOS Stage 2 SSA: zero-`as` ELF64 objects, runtime,
# 4-client TCP loopback, Stage 3 == Stage 4, KV service 8x500 stress, V1 checksums
M2_LINUX_SSA="$PWD/out/stage2.ssa" sh scripts/test-linux.sh

# Benchmarks
sh scripts/bench-v2-exec.sh            # V2 real workloads, 6 languages
sh scripts/bench-v2-compile.sh         # V2 50k LOC / 50 packages compile
M2C="$PWD/out/m2c2" sh scripts/bench.sh   # V1 classic kernels, 5 languages
sh benchmarks/agent_eval/run.sh        # agent-in-the-loop, 4 languages
```

CI (`.github/workflows/ci.yml`) runs `verify-all.sh` on `macos-15` and then `test-linux.sh` on `ubuntu-latest` with the uploaded `stage2.ssa`.

## Repository Layout

- `compiler/src/core/` — compiler core in the strict `m2 ∩ MoonBit` subset (`lexer`, `ast`, `parser`, `sig`, `types`, `qbe`, `cas`, `diag`, `query`, `fmt`, `manifest`)
- `compiler/src/compat_moon/` — Stage 0 MoonBit host adapter
- `compiler/src/compat_m2/` — Stage 1/2 native `m2` CLI driver (parallel package compilation)
- `runtime/` — `<64 KB` C11 runtime (`m2_rt.h`, `m2_rt.c`, `test_rt.c`)
- `vendor/qbe/` — vendored QBE with direct Mach-O / ELF64 object emission and hardware `sqrt` lowering
- `std/json`, `std/http` — standard packages in pure `m2`
- `examples/` — `text_stats` (multi-package), `http_loopback`, `http_kv_service`, `sqlite_indexer`
- `benchmarks/` — V1 (`c`, `moonbit`, `zig`, `rust`, `m2`), V2 (`v2/`, + Go) and `agent_eval/`
- `scripts/` — bootstrap, verification, Linux and benchmark scripts
