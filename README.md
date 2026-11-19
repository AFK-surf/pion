# `m2`

**An agent-friendly, zero-LLVM, C-speed, memory-safe, natively multithreaded systems programming language with bit-for-bit self-hosting.**

`m2` adopts a clean, strict subset/evolution of MoonBit syntax designed for deterministic machine & human collaboration: explicit function signatures, structured JSON compiler APIs, a tiny QBE native backend, biased reference counting, compile-time data-race-free multithreading, explicit `World` capabilities, and a global content-addressed cache that leaves zero `target/` or `_build/` pollution in source worktrees.

See [`SPEC.md`](SPEC.md) for the authoritative language grammar, runtime ABI, and JSON protocol specification.

---

## Design Pillars

- **Agent-Friendly by Construction**: Zero cross-function type inference (explicit top-level parameter & return types), compact machine-readable JSON diagnostics with fixits (`m2c check --json`), structured symbol/signature/call-graph/dependency queries (`m2c query`), and deterministic formatting (`m2c fmt --check --json`).
- **Zero-LLVM Native Backend**: Emits per-package QBE SSA IL → vendored `qbe` → system assembler & linker + a `<64 KB` C11 runtime (`libm2rt.a`). No LLVM or C-header parsing overhead.
- **C-Level Execution Speed & Tiny Binaries**: Perceus-lite borrow elision & last-use early drop, bounds-check elimination (BCE), loop field hoisting, and immortal `.rodata` string literals. A standalone `hello` binary is ~78.7 KB (72.0 KB stripped).
- **Native Race-Free Multithreading**: OS-thread structured concurrency (`scope` / `spawn`), `Channel[T]`, `Mutex[T]`, and `AtomicInt`, backed by Biased Reference Counting (non-atomic on the owning thread, transparently frozen to atomic when crossing thread boundaries) and compile-time `Send` checking (`E_NOT_SEND`).
- **Explicit `World` Capabilities**: Pure functions cannot perform IO, read wall clocks, touch the filesystem, or spawn processes without a `World` value in scope (`E_CAPABILITY_MISSING`).
- **Zero Worktree Cache Pollution**: All intermediate `.m2sig`, `.ssa`, and `.o` artifacts live in a global LRU-evicted Content-Addressed Cache (`$M2_CACHE_DIR`, default `~/.cache/m2/cas`), keyed by compiler fingerprint and upstream `.m2sig` hashes. `git status --ignored` stays clean.
- **Cross-Platform Self-Hosting**: Fixed-point self-hosting (`m2c0` → `m2c1` → `m2c2`, bit-for-bit identical SSA & assembly SHA-256) on **ARM64 macOS (`arm64_apple`)** and native ELF cross-bootstrap & self-hosting on **x86_64 Linux (`amd64_sysv`)**.

---

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
| `m2c check --json <path>` | Type-check, exhaustiveness, `Send`, `World`, and visibility checks with structured JSON diagnostics & fixits |
| `m2c query defs\|sig\|callers\|deps --json <path>` | Emit symbol definitions, exported `.m2sig` interface, call graph, or package dependency graph in JSON |
| `m2c build [-o <bin>] [--release] [--emit-ssa <f>] [--emit-asm <f>] <path>` | Compile package(s) to a native binary (`--release` strips `debug_assert`) |
| `m2c run <path> [-- args...]` | Build (via global CAS) and execute a package or `.m2` file |
| `m2c test [--json] [--filter <substr>] <path>` | Run `test "name" { ... }` blocks in isolated child processes with active `debug_assert` |
| `m2c fmt [--check] [--json] <path...>` | Deterministic, idempotent, comment-preserving source formatter |

---

## Verification, Self-Hosting & Benchmarks

### One-Command Full Verification

```sh
sh scripts/verify-all.sh
```

This runs all 6 verification gates end-to-end:
1. Stage 0 MoonBit check & unit tests (`moon check && moon test`)
2. Runtime gate (`libm2rt.a` size budget, MT 4-core speedup, TSan, ASan, QBE hardware `fsqrt`/`sqrtsd`/`fsqrt.d` smoke)
3. 9/9 fixed-point self-hosting bootstrap (`scripts/bootstrap.sh`: `m2c0` → `m2c1` → `m2c2`, bit-for-bit identical Stage 1 / Stage 2 SSA & assembly SHA-256, standalone `m2c2` frontend/E2E/CAS/LRU gates)
4. `out/m2c2 fmt --check --json examples/text_stats benchmarks/m2`
5. `out/m2c2 test --json examples/text_stats`
6. `out/m2c2 run examples/text_stats`

### Platform-Specific & Benchmark Commands

```sh
# ARM64 macOS 9/9 fixed-point self-hosting bootstrap
sh scripts/bootstrap.sh

# x86_64 Linux runtime + QBE amd64_sysv + native ELF self-hosting verification
sh scripts/test-linux.sh

# Objective 5-language benchmark suite (C, MoonBit, Zig, Rust, m2)
M2C="$PWD/out/m2c2" sh scripts/bench.sh
```

---

## Objective 5-Language Benchmark Summary

Measured on **Apple M5 Max (18 cores), Darwin 27.0.0 arm64** via `M2C=$PWD/out/m2c2 sh scripts/bench.sh` (1 warmup + 5 timed runs, median wall time in ms, strict bit-for-bit checksum verification across all 5 languages):

- **Toolchains**: Apple clang 21.0.0 (`-O2`), MoonBit `0.1.20261117` (`--target native --release`), Zig `0.17.1` (`-OReleaseFast`), Rust `1.100.0` (`-O` / `--release`), `m2c2 0.1.0` (self-hosted QBE backend).

### 1. Execution Speed (Median Wall Time, ms)

| Benchmark | C (`-O2`) | MoonBit | Zig (`-OReleaseFast`) | Rust (`-O`) | **m2 (`m2c2`)** |
|---|---:|---:|---:|---:|---:|
| `nbody` | 146.01 | 271.93 | 142.61 | 142.41 | **155.68** |
| `binarytrees` | 258.32 | 66.74 | 257.00 | 422.60 | **67.75** |
| `spectralnorm` | 101.08 | 105.94 | 100.72 | 102.74 | **104.46** |
| `fannkuchredux` | 172.21 | 136.61 | 128.04 | 129.10 | **130.66** |
| `mandelbrot_1t` | 532.88 | 531.39 | 509.55 | 533.82 | **467.33** |
| `mandelbrot_4t` | 203.90 | N/A (1T) | 192.76 | 205.03 | **178.95** |
| `hashmap_str` | 39.65 | 43.12 | 18.73 | 39.75 | **31.45** |

### 2. Compile Speed (10,000 LOC / 20 Packages) & Worktree Cache Pollution

| Language | Cold Compile (ms) | 1-Line Body Edit Incr (ms) | Worktree Cache | Global CAS |
|---|---:|---:|---:|---:|
| C (`make -j8`) | 207.60 | 84.81 | 0.28 MB | 0 |
| MoonBit | 717.36 | 542.79 | 3.79 MB | 0 |
| Zig | 1565.69 | 224.15 | 1.20 MB | 0 |
| Rust (`cargo`) | 919.45 | 668.85 | 2.47 MB | 0 |
| **m2 (`m2c2`)** | **64.63** *(5-run median: 66.2 ms)* | **31.19** *(5-run median: 30.7 ms)* | **0.00 MB** | 1.43 MB |

### 3. Binary Artifact Sizes (Default / Stripped)

| Language | `hello` (bytes) | 6-Benchmark Total (bytes) |
|---|---:|---:|
| C | 33,432 / 33,432 | 218,648 / 218,528 |
| Zig | 52,104 / 50,184 | 1,963,576 / 1,750,048 |
| **m2 (`m2c2`)** | **78,744 / 71,976** | **572,712 / 531,024** |
| MoonBit | 283,256 / 241,176 | 1,706,616 / 1,447,216 |
| Rust | 471,736 / 342,920 | 3,023,928 / 2,213,584 |

---

## Repository Layout

- `compiler/src/core/` — Self-hosted compiler core in the strict `m2 ∩ MoonBit` subset (`lexer`, `ast`, `parser`, `sig`, `types`, `qbe`, `cas`, `diag`, `query`, `fmt`, `manifest`)
- `compiler/src/compat_moon/` — Stage 0 MoonBit host adapter
- `compiler/src/compat_m2/` — Stage 1/2 native `m2` CLI driver (parallel multithreaded package compilation)
- `runtime/` — `<64 KB` C11 runtime (`m2_rt.h`, `m2_rt.c`, `test_rt.c`)
- `vendor/qbe/` — Vendored QBE backend (with hardware `sqrt` lowering for `arm64_apple`, `amd64_sysv`, `rv64`)
- `examples/text_stats/` — Multi-package `m2.toml` example with `scope`/`spawn`/`Channel`, `World` IO, and `test` blocks
- `benchmarks/` — Reproducible 5-language benchmark suite and pure-C harness
- `scripts/` — Build, bootstrap, cross-platform Linux, verification, and benchmark scripts
