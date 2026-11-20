# `Pion`

**An agent-friendly, zero-LLVM, C-speed, memory-safe, natively multithreaded systems programming language with bit-for-bit self-hosting.**

`Pion` is a strict subset/evolution of MoonBit syntax built for deterministic machine & human collaboration: explicit top-level signatures, structured JSON compiler APIs with fix-its, an embedded QBE backend that writes native objects directly, biased reference counting, compile-time data-race freedom, explicit `World` capabilities, and a global content-addressed cache that leaves zero `target/` or `_build/` in source worktrees.

[`SPEC.md`](SPEC.md) is the authoritative grammar, type system, runtime ABI and JSON protocol specification.

---

## Architecture

- **Agent-friendly by construction**: no cross-function type inference (every top-level parameter and return type is written), one-line JSON diagnostics with a stable `code`, a `fixit` hint and, where the exact patch is known, machine-applicable span `edits` (`pionc check --json`; 6 of the 12 agent error classes in `benchmarks/agent_eval` carry an `edits` patch, rustc 4 of 12), symbol/signature/call-graph/dependency queries over a file, package or whole workspace (`pionc query ... --json`), workspace-wide test reports (`pionc test --json <dir>`), API docs as JSON (`pionc doc --json`) and a deterministic formatter (`pionc fmt --check --json`). Agent foot-guns are compile errors: a discarded `Result` (`E_UNHANDLED_RESULT`), `==` on boxed values that would silently compare pointers (`E_TYPE_MISMATCH`), non-exhaustive `match`, IO without a `World`, data races (`E_NOT_SEND`).
- **Zero LLVM**: per-package QBE SSA IL → embedded/vendored QBE 1.3 (native `jtbl` jump tables; ARM64 callee-saved/loop-spill/register-hint fixes and cross-block shift folding) → **native objects written directly** (ARM64 Mach-O and x86_64 Linux ELF64 `.o`, no system assembler) → system linker + a C11 runtime (`libpionrt.a`: 58,352 B on macOS ARM64, 55,910 B on Linux x86_64).
- **Runtime**: Biased Reference Counting (non-atomic on the owning thread, frozen to atomic when a value crosses threads) on a compact 24-byte `PionHeader`, 12-class slab allocator (32–256 B) with batched remote frees, null-niche `Option[Ref]` (`None` = null, `Some(p)` = `p`, no box), immortal `.rodata` literals and payload-less enum constants, native OS threads, and a non-blocking `kqueue`/`epoll` event loop with `SO_REUSEPORT` multi-worker accept.
- **Global CAS, zero worktree pollution**: `.pionsig`, `.ssa` and `.o` artifacts live in an LRU-evicted content-addressed cache (`$PION_CACHE_DIR`, default `~/.cache/pion/cas`) keyed by the compiler's self-fingerprint (`pionc-v0.9` ABI revision + the running `pionc` binary + `qbe` + runtime) and upstream `.pionsig` hashes; git dependencies are pinned in `pion.lock` and checked out once into the shared `$PION_CACHE_DIR/git/` cache; `git status --ignored` stays clean and parallel worktrees share work.
- **Self-hosting**: `pionc0` (MoonBit host) → `pionc1` → `pionc2` reaches a bit-for-bit fixed point (identical SSA & assembly SHA-256) on ARM64 macOS; on x86_64 Linux the cross-emitted compiler rebuilds itself with Stage 3 == Stage 4 bit-for-bit, without ever invoking `as`.

## Language at a Glance

- `Pion ∩ MoonBit` syntax: the compiler core (`compiler/src/core/`) compiles unchanged with both `moon` and `pionc`.
- Data: `struct` / `val struct` (immutable, `Send`), `enum` ADTs, generics, tuples and destructuring, `Array`, `Map`, `Bytes`, `StringBuilder`, `Option` / `Result`.
- Control flow: `match` with guards and exhaustiveness, postfix `?` on `Result` / `Option`, `for i in a..b`, `for x in arr`, string interpolation `"\{x}"`.
- Concurrency: `scope` / `spawn` structured OS threads, `Channel[T]`, `Mutex[T]`, `AtomicInt`, compile-time `Send` checking.
- Capabilities: IO, clocks, processes, TCP and sleeping require the explicit `World` value.
- FFI: `extern "C" fn`, `Ptr` plus pointer/C-string helpers, `-l <lib>` / `pion.toml` `[link]`.
- Traits: `trait` / `impl` with bounded generics, monomorphized (zero-cost static dispatch).
- Full UTF-8 strings (scalar iteration, byte-exact formatting); `String::to_int/to_int64/to_double -> Option`.
- Standard packages in pure `Pion`: `std/json`; `std/http` (HTTP/1.1 Keep-Alive, chunked bodies, pipelining, query decoding); `std/net` (non-blocking `kqueue`/`epoll` poller, `SO_REUSEPORT`); `std/regex` (Thompson NFA run by a Pike VM: linear time for every pattern, no ReDoS); `std/tls` (TLS 1.2/1.3 client over the system OpenSSL 1.1.x/3.x through `extern "C"` only, zero C glue, SNI + certificate/host verification).
- Packages: `pion.toml` `path` and `git` (`tag`/`rev`/`branch`, optional `subdir`) dependencies, pinned by `pion.lock`.
- Equality is by value only: `==` on scalars, `String`, `Ptr` and payload-less enums; boxed values are inspected with `match` (also enforced when a generic `==` is instantiated with a boxed type).

## Language Tour

```pion
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

  let (label, _, score) : (String, String, Int) = ("pion", "unused", 42)
  let swapped = pair_swap((label, score))
  io_println(world, "label=\{swapped.1} score=\{swapped.0} kind=\{classify(Some("hi!"))}")
  0
}

// Built-in test blocks (compiled only by `pionc test`, 0 bytes in `pionc build`)
test "pair_swap works" {
  let p = pair_swap(("a", 1))
  debug_assert(p.0 == 1 && p.1 == "a", "swap mismatch")
}
```

Multi-package projects use `pion.toml` with package-level `.pionsig` incremental isolation and visibility enforcement (`pub` vs `E_PRIVATE_SYMBOL`):

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
| `pionc check [--json] <path...>` | Type, exhaustiveness, must-use `Result`, `Send`, `World` and visibility checks; JSON diagnostics with fix-its and machine-applicable `edits` (`[{file,line,col,end_line,end_col,replacement}]`) |
| `pionc query defs\|sig\|callers\|deps [--json] <path...>` | Symbol definitions, exported `.pionsig` interface, call graph, package dependency graph; a path may be a file, a package directory or a whole workspace |
| `pionc doc [--json] <path...>` | Public API of each package (dependencies first) |
| `pionc emit-sig <path...>` | Print the `.pionsig` export table |
| `pionc build [--release] [--target arm64_apple\|amd64_sysv] [--emit-obj <f>] [--emit-ssa <f>] [--emit-asm <f>] [--jobs <n>] [-l <lib>] [-o <bin>] <path...>` | Native binary via the global CAS (`--release` strips `debug_assert`; `--target amd64_sysv --emit-obj` cross-emits an ELF64 `.o`) |
| `pionc run [--release] [-l <lib>] <path> [-- args...]` | Build and execute a package or `.pion` file |
| `pionc test [--json] [--package <name>] [--filter <name>] [-l <lib>] <path>` | Run `test "name" { ... }` blocks in isolated child processes with active `debug_assert`; a workspace directory runs every local package's tests in one report |
| `pionc fmt [--check] [--json] <path...>` | Deterministic, idempotent, comment- and UTF-8-preserving formatter |
| `pionc init [--json] <dir>` | Scaffold `pion.toml`, `src/main.pion` and `main_test.pion`; the result passes `check`, `test`, `run` and `fmt --check` as is |
| `pionc fetch [--json] [dir]` | Resolve `git` dependencies into the global git cache and write/verify `pion.lock` |

---

## Measured Results

Every number below is copied from the combined P19 run of the scripts named in each section (main `3365132`: P17-A/B/C + P18 + P19-A + P19-B), on **Apple M5 Max (18 cores), Darwin 27.0.0 arm64** (`tokyo` station) and an x86_64 Linux station (`gt2`, kernel 6.18). Rerun the scripts to reproduce: checksums are fixed, absolute milliseconds vary with machine load. The macOS station is shared; the 1-minute load average was 40–53 during §1, 18–40 during §2 and 18–30 during §5. Peak RSS and instructions retired (`/usr/bin/time -l`) do not depend on load and are listed next to the wall times.

Toolchains: C Apple clang 21.0.0 `-O2`, MoonBit `0.1.20261117` `--target native --release`, Zig `0.17.1` `-OReleaseFast`, Rust `1.100.0` `-O` / `--release`, Go `1.27.3` `go build`, Pion `pionc2 0.1.0 build --release` (self-hosted, embedded QBE).

### 1. V2 real workloads, 6 languages (`sh scripts/bench-v2-exec.sh`)

Full mode (1 warmup + 5 runs, median); checksums bit-for-bit identical across all six languages and `1T == 4T`.

| Median ms / peak RSS MB / instructions retired (M) | C | MoonBit | Zig | Rust | Go | **Pion (`pionc2`)** |
|---|---:|---:|---:|---:|---:|---:|
| `json_query` (11.6 MB JSON) | 62.11 / 76.7 / 1,044 | 81.58 / 92.8 / 1,375 | 57.94 / 81.5 / 1,006 | 54.89 / 67.4 / 841 | 75.91 / 106.2 / 1,256 | **67.45** / 105.6 / 1,141 |
| `bytecode_vm` | 62.95 / 2.4 / 887 | 60.16 / 2.7 / 1,578 | 49.04 / 2.5 / 795 | 55.81 / 2.7 / 1,203 | 45.20 / 9.8 / 1,154 | **50.80** / 2.9 / 1,508 |
| `mt_log_pipeline_1t` (17.5 MB log) | 53.58 / 18.6 / 636 | 81.89 / 18.9 / 1,426 | 60.88 / 18.6 / 698 | 60.96 / 18.8 / 716 | 48.08 / 39.1 / 612 | **63.80** / 18.6 / 820 |
| `mt_log_pipeline_4t` | 56.91 / 18.7 / 777 | N/A (1T) | 50.12 / 18.7 / 783 | 50.67 / 19.0 / 821 | 36.66 / 41.0 / 690 | **51.86** / 18.8 / 924 |
| 3 binaries, stripped bytes | 103,576 | 757,240 | 505,064 | 1,167,864 | 7,159,144 | **221,848** |

Pion's three stripped binaries shrank from 282,360 B to 221,848 B with the 24-byte header and 12-class slab (P19-B). Pion retires more instructions than C, Zig and Rust on all three workloads (1.1–1.9×); its median wall time is 1.12–1.41× that of the fastest language per workload (Rust or Go), ahead of C and Rust on `bytecode_vm` and ahead of MoonBit everywhere.

### 2. V2 compile: 50k LOC, 50 packages, 4-layer diamond DAG (`sh scripts/bench-v2-compile.sh`)

Checksums identical across all six languages for the cold build, all three edits and all five worktrees. "5-WT" = five worktrees built one after another with a shared global cache.

| Lang | Cold (ms) | Leaf body edit (ms) | Core body edit (ms) | Core signature edit (ms) | 5-WT total (ms) | 5-WT in-tree cache | 5-WT global cache |
|---|---:|---:|---:|---:|---:|---:|---:|
| C (`make -j12`) | 1537.27 | 394.36 | 568.85 | 380.15 | 22118.76 | 1.55 MB | 0 |
| MoonBit | 19363.86 | 19962.97 | 20376.79 | 20892.04 | 123713.57 | 101.40 MB | 0 |
| Zig | 24506.32 | 26439.96 | 64656.97 | 19355.26 | 100664.79 | 44.97 MB | 43.36 MB |
| Rust (`cargo`) | 1736.74 | 826.63 | 791.17 | 998.46 | 6391.69 | 18.34 MB | 0 |
| Go | 2190.21 | 350.75 | 472.16 | 370.33 | 3400.20 | 0 | 80.57 MB |
| **Pion (`pionc2`)** | **448.81** | **177.99** | **177.74** | **246.45** | **934.85** | **0** | 13.05 MB |

### 3. Dogfood applications

| | `examples/http_event_server` | `examples/http_kv_service` | `examples/sqlite_indexer` |
|---|---|---|---|
| What | `std/net` event-loop HTTP/1.1 key-value server: 4 `kqueue`/`epoll` workers sharing the port through `SO_REUSEPORT` | multithreaded HTTP + JSON key-value service on `std/http` / `std/json` | pure-`Pion` indexer calling the system `libsqlite3` through `extern "C"` (zero C glue) |
| Load / work | Linux x86_64 (`gt2`): **C1000** — 1,000 concurrently open keep-alive connections × 40 = 40,000 requests from 4 client threads, 0 errors, exact `/stats` check; per-worker requests 10,361 / 10,400 / 8,800 / 10,440 | Linux x86_64 (`gt2`): 8 clients × 500 = 4,000 requests, 0 errors, exact `/stats`, with and without Keep-Alive | indexes `compiler/src/core` (15 files / 33,541 lines), cross-checked 100% by the `sqlite3` CLI |
| Speed | **121,028 QPS**, P50 6.82 ms, P99 18.28 ms (max 26.5 ms), peak RSS 14.83 MB | Keep-Alive **83,274 QPS**, P50 0.066 ms, P99 0.243 ms; connection per request 33,428 QPS, P50 0.219 ms, P99 0.494 ms; peak RSS 14.4 MB | — |
| Binary | 118,144 B stripped (build 108 ms) | 109,488 B stripped (build 75–81 ms) | 123 KB |
| Memory safety | `ASAN=1` mode of `run_bench.sh` (not part of this run) | ASan + LSan: 0 errors, 0 leaks (archived P13 run) | ASan + LSan: 0 errors, 0 leaks (archived P13 run) |

Reproduce: `sh examples/http_event_server/run_bench.sh <pionc> 1000 40 4`, `sh examples/http_kv_service/run_bench.sh <pionc> 8 500 8` (with and without `KEEP_ALIVE=1`, both run by `scripts/test-linux.sh`) and `scripts/verify-all.sh` gate 6. On C1000 the latency percentiles are those of 1,000 connections queued on 4 workers; the 8-connection KV numbers measure per-request latency.

### 4. Agent-in-the-loop evaluation, 4 languages (`sh benchmarks/agent_eval/run.sh`)

Full report: [`benchmarks/agent_eval/SUMMARY.md`](benchmarks/agent_eval/SUMMARY.md) (run of 2026-11-20 on the same Apple M5 Max; load average 89 / 83 / 67 while it ran, medians of 1 warmup + 5 runs). 12 engineering tasks and 12 error-class probes per language; check commands `pionc2 check --json`, `moon check --output-json`, `cargo check --message-format=json`, `go build -json`. Gates: 48/48 reference implementations pass, 48/48 probes measured with 0 expectation mismatches.

|  | **Pion (`pionc2`)** | MoonBit | Rust | Go |
|---|---:|---:|---:|---:|
| error classes caught before running (of 12) | **12** | 10 | 10 | 8 |
| caught with JSON diagnostics / any fix suggestion | **12/12 / 12** | 10/10 / 0 | 10/10 / 7 | 8/8 / 0 |
| caught with a machine-applicable edit | **6** | 0 | 4 | 0 |
| median check latency (ms) | **5.2** | 54.1 | 90.0 | 88.5 |
| median diagnostic size when caught (bytes) | 594.0 | 543.5 | 4833.0 | 343.0 |
| effective LOC, 12 tasks | 1526 | 1393 | 1446 | 1539 |
| first (cold) test run, `t06` (ms) | **718.1** | 1029.3 | 1408.8 | 7952.0 |
| private body edit → tests green (ms) | 643.9 | 494.8 | 1044.8 | 424.5 |
| exported-signature edit → tests green (ms) | 649.3 | 360.6 | 1099.5 | 570.5 |
| 5 worktrees check+test concurrently, cold (wall ms) | **315.8** | 2412.0 | 1844.4 | 8058.8 |
| build artefacts inside the 5 worktrees (MB) | **0.0** | 42.1 | 63.8 | 0.0 |

Pion's `edits` (span + replacement) are emitted for non-exhaustive `match`, private symbols, trait signature mismatches, discarded `Result`, missing return types and assignment to immutable bindings; rustc's `MachineApplicable` suggestions cover 4 of the 12 probes. Pion's edit → tests-green loop is slower than MoonBit's and Go's here, and that is the exact cost: since P17-B every dependent package's test binary is recompiled and relinked against its dependencies' new `.o` files and launched fresh (before, a cached test binary could report a stale pass after a dependency's body edit).

### 5. V1 classic kernels, 5 languages (`PIONC=$PWD/out/pionc2 sh scripts/bench.sh`)

1 warmup + 5 timed runs, median; strict bit-for-bit checksums across all five languages, including the `scale10k` cold → incremental pair.

#### Execution (median ms / instructions retired, M)

| Benchmark | C (`-O2`) | MoonBit | Zig (`-OReleaseFast`) | Rust (`-O`) | **Pion (`pionc2`)** |
|---|---:|---:|---:|---:|---:|
| `nbody` | 160.57 / 2,318 | 290.98 / 3,525 | 147.16 / 2,011 | 146.87 / 2,015 | **165.97** / 3,408 |
| `binarytrees` | 277.59 / 6,051 | 75.75 / 1,288 | 1199.62\* / 6,202 | 1603.55\* / 7,634 | **82.94** / 1,680 |
| `spectralnorm` | 110.88 / 1,896 | 108.39 / 2,019 | 103.07 / 1,780 | 108.91 / 1,779 | **99.16** / 2,256 |
| `fannkuchredux` | 287.24\* / 1,432 | 164.23 / 1,817 | 131.55 / 759 | 157.01 / 1,307 | **146.95** / 1,588 |
| `mandelbrot_1t` | 1148.96\* / 6,227 | 1250.89\* / 6,215 | 1250.61\* / 6,106 | 1567.49\* / 5,767 | **586.22** / 5,486 |
| `mandelbrot_4t` | 243.56 / 6,209 | N/A (1T) | 232.00 / 6,094 | 288.79 / 5,761 | **254.69** / 5,486 |
| `hashmap_str` | 92.60 / 653 | 88.45 / 583 | 28.09 / 273 | 58.13 / 922 | **48.37** / 456 |

\* Load-distorted: min–max spreads of 376–1305 ms (Zig `binarytrees`), 1006–1704 ms (Rust `binarytrees`), 249–334 ms (C `fannkuchredux`) and 931–2115 ms (`mandelbrot_1t` for C, MoonBit, Zig, Rust) in this run; the archived quiet-host P8 run measured `mandelbrot_1t` at 532.88 (C) vs 467.33 ms (Pion) and `binarytrees` at 258.32 (C) / 257.00 (Zig) / 422.60 (Rust) vs 67.75 ms (Pion). Compare the instruction counts, which load does not change.

#### Compile speed (10,000 LOC / 20 packages) & worktree cache pollution

| Language | Cold compile (ms) | 1-line body edit incr (ms) | Worktree cache | Global CAS |
|---|---:|---:|---:|---:|
| C (`make -j8`) | 383.54 | 120.83 | 0.28 MB | 0 |
| MoonBit | 1018.70 | 812.08 | 3.79 MB | 0 |
| Zig | 2790.35 | 473.69 | 1.20 MB | 0 |
| Rust (`cargo`) | 1672.40 | 1174.26 | 2.47 MB | 0 |
| **Pion (`pionc2`)** | **184.37** | 124.93 | **0.00 MB** | 1.44 MB |

#### Binary artifact sizes (default / stripped, bytes)

| Language | `hello` | 6-benchmark total |
|---|---:|---:|
| C | 33,432 / 33,432 | 218,648 / 218,528 |
| **Pion (`pionc2`)** | **52,120 / 50,792** | **322,472 / 308,064** |
| Zig | 52,120 / 50,184 | 1,963,592 / 1,750,048 |
| MoonBit | 283,272 / 241,176 | 1,706,680 / 1,447,216 |
| Rust | 471,736 / 342,920 | 3,023,928 / 2,213,584 |

Pion's `hello` fell from 71,976 B to 50,792 B stripped and the six V1 binaries from 531,024 B to 308,064 B since the P8 run.

---

## Known Limitations & Next Steps

- No dynamic dispatch: traits are monomorphized only, there are no trait objects (heterogeneous collections use a closed `enum`).
- Machine-applicable `edits` cover 6 of the 12 measured error classes; the other 6 (type mismatch, arity, unknown field, missing trait impl, `Send`, missing `World`) carry a natural-language `fixit` only. Whether an applied edit re-checks clean is not yet measured by `agent_eval`.
- No central package registry: dependencies are `path` or `git` entries in `pion.toml`, pinned by `pion.lock`.
- `std/tls` is a client only and depends on the system OpenSSL (1.1.x or 3.x) being installed.
- Targets: ARM64 macOS (Mach-O) and x86_64 Linux (ELF64) are verified; other QBE targets are not.
- No automatic SIMD vectorization (QBE has no vector IR and LLVM is excluded by design); on `nbody` Pion is 3% behind C `-O2` and ~13% behind Zig/Rust, retiring ~1.7× their instructions (§5).
- On the edit → tests-green loop Pion relinks and relaunches every dependent package's test binary after a body edit (exact, no stale passes), which costs more than MoonBit's and Go's incremental test runs on the small `t06` project (§4).

## Quick Start & Full Reproduction

```sh
# Build the toolchain and run all 6 gates on macOS ARM64:
# Stage 0 unit tests, <64 KB runtime (O2 + TSan + ASan), 9/9 fixed-point
# bootstrap, fmt (UTF-8), std/json/http/net/regex + dogfood app tests,
# pionc init smoke, event-server self-test, cross ELF64 .o
sh scripts/verify-all.sh
out/pionc2 run examples/text_stats

# Linux x86_64 with the macOS Stage 2 SSA: zero-`as` ELF64 objects, <56 KB runtime,
# epoll event loop, Stage 3 == Stage 4, std/tls TLS 1.3/1.2 handshakes, KV service
# 8x500 (with/without Keep-Alive), event-server self-test, V1 checksums
PION_LINUX_SSA="$PWD/out/stage2.ssa" sh scripts/test-linux.sh

# Benchmarks
sh scripts/bench-v2-exec.sh            # V2 real workloads, 6 languages
sh examples/http_event_server/run_bench.sh "$PWD/out/pionc2" 1000 40 4   # C1000 keep-alive
sh scripts/bench-v2-compile.sh         # V2 50k LOC / 50 packages compile
PIONC="$PWD/out/pionc2" sh scripts/bench.sh   # V1 classic kernels, 5 languages
sh benchmarks/agent_eval/run.sh        # agent-in-the-loop, 4 languages
```

CI (`.github/workflows/ci.yml`) runs `verify-all.sh` on `macos-15` and then `test-linux.sh` on `ubuntu-latest` with the uploaded `stage2.ssa`.

## Repository Layout

- `compiler/src/core/` — compiler core in the strict `Pion ∩ MoonBit` subset (`lexer`, `ast`, `parser`, `sig`, `types`, `qbe`, `cas`, `diag`, `query`, `fmt`, `manifest`)
- `compiler/src/compat_moon/` — Stage 0 MoonBit host adapter
- `compiler/src/compat_pion/` — Stage 1/2 native `Pion` CLI driver (parallel package compilation)
- `runtime/` — `<64 KB` C11 runtime (`pion_rt.h`, `pion_rt.c`, `test_rt.c`; BRC, slab allocator, threads, `kqueue`/`epoll` event loop)
- `vendor/qbe/` — vendored QBE with direct Mach-O / ELF64 object emission and hardware `sqrt` lowering
- `std/json`, `std/http`, `std/net`, `std/regex`, `std/tls` — standard packages in pure `Pion`
- `examples/` — `text_stats` (multi-package), `http_loopback`, `http_kv_service`, `http_event_server` (C1000 keep-alive event-loop server), `sqlite_indexer`
- `benchmarks/` — V1 (`c`, `moonbit`, `zig`, `rust`, `pion`), V2 (`v2/`, + Go) and `agent_eval/`
- `scripts/` — bootstrap, verification, Linux and benchmark scripts
