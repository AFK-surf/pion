# `Pion`

**An agent-friendly, zero-LLVM, C-speed, memory-safe, natively multithreaded systems programming language with bit-for-bit self-hosting.**

`Pion` is a strict subset/evolution of MoonBit syntax built for deterministic machine & human collaboration: explicit top-level signatures, structured JSON compiler APIs with fix-its, an embedded QBE backend that writes native objects directly, biased reference counting, compile-time data-race freedom, explicit `World` capabilities, and a global content-addressed cache that leaves zero `target/` or `_build/` in source worktrees.

[`SPEC.md`](SPEC.md) is the authoritative grammar, type system, runtime ABI and JSON protocol specification. See [`BEST_PRACTICES.md`](BEST_PRACTICES.md) for engineering guidelines.

## For AI Agents

- **Read the docs first**: [`SPEC.md`](SPEC.md) defines the language & CLI contract; [`BEST_PRACTICES.md`](BEST_PRACTICES.md) covers `World` capabilities, structured concurrency, zero-allocation patterns, and `#verify` Lean 4 formal verification.
- **Formal verification built in (Lean 4)**: Pion ships an Aeneas-style Pion → Lean 4 extractor (`#verify` + `pionc extract-lean --out <dir>`, [`SPEC.md`](SPEC.md) §3.4–§3.5 & §5.5). Mark pure state machines / algorithms `#verify` (avoiding closures, `World` IO, `Float`/`Double` arithmetic and aliasing), extract them directly to Lean 4 (`Aeneas.Std` + `lean/PionLean`), and prove safety/liveness invariants directly on the production Pion code with zero proof-code drift.
- **GUI / Invar apps**: scaffold with `pionc init --template invar-app <dir>`, keep `#render_thread` on view/event functions, and never pass `World` into the render thread — on `E_NO_IO_VIOLATION`, move blocking IO into the background worker (`ui::Worker::pair()` + `ui::wake_now()`).
- **Reuse ecosystem packages & verify every edit**: search official pure-Pion packages with `pionc search --json <query>`, and close every edit loop with `pionc check --json <path>` (apply `edits` when provided) and `pionc test --json <path>`.

---

## Architecture

- **Agent-friendly by construction**: no cross-function type inference (every top-level parameter and return type is written), one-line JSON diagnostics with a stable `code`, a `fixit` hint and, where the exact patch is known, machine-applicable span `edits` (`pionc check --json`; all 12 agent error classes in `benchmarks/agent_eval` carry an `edits` patch and 9 of them re-check clean after applying it verbatim, rustc: 4 patches, 2 clean), symbol/signature/call-graph/dependency queries over a file, package or whole workspace (`pionc query ... --json`), workspace-wide test reports (`pionc test --json <dir>`), API docs as JSON (`pionc doc --json`), a deterministic formatter (`pionc fmt --check --json`) and JSON package edits (`pionc add` / `pionc update --json`). Agent foot-guns are compile errors: a discarded `Result` (`E_UNHANDLED_RESULT`), `==` on boxed values that would silently compare pointers (`E_TYPE_MISMATCH`), non-exhaustive `match`, IO without a `World`, data races (`E_NOT_SEND`).
- **Zero LLVM**: per-package QBE SSA IL → embedded/vendored QBE 1.3 (native `jtbl` jump tables; ARM64 callee-saved/loop-spill/register-hint fixes, cross-block shift folding, `cbz`/`cbnz`, `tst`, `csel`, fused multiply and `extuw` peepholes) → **native objects written directly** (ARM64 Mach-O and x86_64 Linux ELF64 `.o`, no system assembler) → system linker + a C11 runtime (`libpionrt.a`: 59,616 B on macOS ARM64, 55,782 B on Linux x86_64, with short-string fast paths for compare/hash/concat).
- **Runtime**: Biased Reference Counting (non-atomic on the owning thread, frozen to atomic when a value crosses threads) on a compact 24-byte `PionHeader`, 12-class slab allocator (32–256 B) with batched remote frees, null-niche `Option[Ref]` (`None` = null, `Some(p)` = `p`, no box, also for `Option[dyn Trait]`), `dyn Trait` as a 16-byte RC box `{data, vtable}` with one static vtable per (trait, type), immortal `.rodata` literals and payload-less enum constants, native OS threads, and a non-blocking `kqueue`/`epoll` event loop with `SO_REUSEPORT` multi-worker accept.
- **Global CAS, zero worktree pollution**: `.pionsig`, `.ssa` and `.o` artifacts live in an LRU-evicted content-addressed cache (`$PION_CACHE_DIR`, default `~/.cache/pion/cas`; `pionc test` binaries too, under `testbin/`, keyed by every linked object) keyed by the compiler's self-fingerprint (`pionc-v0.10` ABI revision + the running `pionc` binary + `qbe` + runtime) and upstream `.pionsig` hashes; git dependencies (direct or through a git-index registry) are pinned in `pion.lock` and checked out once into the shared `$PION_CACHE_DIR/git/` cache; `git status --ignored` stays clean and parallel worktrees share work.
- **Self-hosting (zero MoonBit dependency)**: `bootstrap/pionc-seed.ssa.gz` (arch-independent QBE SSA) → `pionc0` (pure C + embedded QBE) → `pionc1` → `pionc2` reaches a bit-for-bit fixed point (identical SSA SHA-256, built through direct Mach-O `.o` emission with no `as`) on ARM64 macOS; on x86_64 Linux the standalone bootstrap rebuilds itself with Stage 3 == Stage 4 bit-for-bit, without ever invoking `as`.

## Language at a Glance

- Pure `Pion` self-hosted compiler (`compiler/src/core/` + `compiler/src/cli/`, zero `.mbt` files and zero external toolchain dependencies beyond a C11 compiler `cc`).
- Data: `struct` / `val struct` (immutable, `Send`), `enum` ADTs, generics, tuples and destructuring, `Array`, `Map`, `Bytes`, `StringBuilder`, `Option` / `Result`.
- Control flow: `match` with guards and exhaustiveness, postfix `?` on `Result` / `Option`, `for i in a..b`, `for x in arr`, string interpolation `"\{x}"`.
- Concurrency: `scope` / `spawn` structured OS threads, `Channel[T]`, `Mutex[T]`, `AtomicInt`, compile-time `Send` checking.
- Capabilities: IO, clocks, processes, TCP and sleeping require the explicit `World` value.
- FFI: `extern "C" fn`, `Ptr` plus pointer/C-string helpers, `-l <lib>` / `pion.toml` `[link]`.
- Traits: `trait` / `impl` with bounded generics, monomorphized (zero-cost static dispatch), plus `dyn Trait` / `dyn pkg::Trait` trait objects for dynamic dispatch (object-safety checked; implicit or `as dyn T` conversion; `Array[dyn T]`, struct fields, niche `Option[dyn T]`; `!Send`).
- Full UTF-8 strings (scalar iteration, byte-exact formatting); `String::to_int/to_int64/to_double -> Option`.
- Standard packages in pure `Pion`: `std/json`; `std/http` (HTTP/1.1 Keep-Alive, chunked bodies, pipelining, query decoding); `std/net` (non-blocking `kqueue`/`epoll` poller, `SO_REUSEPORT`); `std/regex` (Thompson NFA run by a Pike VM: linear time for every pattern, no ReDoS); `std/tls` (TLS 1.2/1.3 client and server over the system OpenSSL 1.1.x/3.x through `extern "C"` only, zero C glue: SNI + certificate/host verification, `tls_listen` / `tls_accept` with PEM certificate chains).
- Packages: `pion.toml` `path` and `git` (`tag`/`rev`/`branch`, optional `subdir`) dependencies, pinned by `pion.lock`; `pionc add` / `pionc update` edit them in place from a path, a git URL or a git-index registry (`index/<pkg>.toml`, `[registry] url` or `$PION_REGISTRY`), restoring `pion.toml` / `pion.lock` on any failure.
- **Formal verification (Lean 4 extraction)**: built-in Aeneas-style `#verify` subset & `pionc extract-lean` (`SPEC.md` §3.4–§3.5) lowering Pion-LLBC into executable Lean 4 (`Aeneas.Std` + `PionLean`) with `mut` parameters, loops, recursion, `Array`/`FixedArray`/`Bytes`/`StringBuilder`/`Map[K, V]` and `Double` bit-pattern primitives — dogfooded by the end-to-end Lean 4-verified QBE SSA translation validator (`tools/qbe_tv`, `SPEC.md` §3.6).
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

Multi-package projects use `pion.toml` with package-level `.pionsig` incremental isolation and visibility enforcement (`pub` vs `E_PRIVATE_SYMBOL`), and monorepos can centralize members and shared dependencies in a root `[workspace]` `pion.toml` (virtual or hybrid) with a shared `pion.lock`:

```toml
# Root pion.toml (virtual workspace)
[workspace]
members = ["packages/*", "cmd/*"]

[workspace.dependencies]
core = { path = "packages/core" }
json = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "json-v0.1.0", subdir = "packages/json" }

# Sub-package cmd/app/pion.toml
[package]
name = "app"
version = "0.1.0"

[dependencies]
core = { workspace = true }
json = { workspace = true }
```

See [`examples/text_stats/`](examples/text_stats/) for a complete multi-package project.

---

## CLI Reference

| Command | Purpose |
|---|---|
| `pionc check [--fix] [--json] [path...]` | Type, exhaustiveness, must-use `Result`, `Send`, `World` and visibility checks; JSON diagnostics with fix-its and machine-applicable `edits` (`--fix` applies edits in up to 3 rounds and re-checks; defaults to `.` when `pion.toml` or `src/` exists) |
| `pionc query defs\|sig\|callers\|deps [--json] [path...]` | Symbol definitions, exported `.pionsig` interface, call graph, package dependency graph; a path may be a file, a package directory or a whole workspace (defaults to `.`) |
| `pionc doc [--json] [path...]` | Public API of each package (dependencies first; defaults to `.`) |
| `pionc extract-lean --out <dir> [--pkg <name>] [--json] [path]` | Extract the `#verify` closure via Pion-LLBC into Lean 4 (`<Pkg>/{Types,Funs,FunsExternal}.lean` on `Aeneas.Std` + `PionLean`; `SPEC.md` §3.5 / §5.5) |
| `pionc emit-sig <path...>` | Print the `.pionsig` export table |
| `pionc build [--package\|-p <name>] [--release] [--target <t>] [--sysroot <dir>] [--emit-obj <f>] [--emit-staticlib <f.a>] [--emit-cdylib <f.so\|.dylib\|.dll>] [--emit-ssa <f>] [--emit-asm <f>] [--jobs <n>] [-l <lib>] [-o <bin>] [path...]` | Native binary, `.o`, C staticlib (`.a`), C cdylib (`.dylib`/`.so`/`.dll`), or zero-toolchain `.wasm` binary via the global CAS across `arm64_apple`, `amd64_apple`, `amd64_sysv`, `amd64_win`, `arm64`, `rv64`, `ios_arm64`, `ios_sim_arm64`, `android_arm64`, `android_x64`, and `wasm32` (`--release` strips `debug_assert`; `--package`/`-p` selects a `[workspace]` member; defaults to `.`) |
| `pionc run [--package\|-p <name>] [--release] [--target <t>] [-l <lib>] [path] [-- args...]` | Build and execute a package, workspace member (`--package`/`-p`, or auto-selected unique `main` member), or `.pion` file (`--target wasm32` runs via `node pion_wasm_rt.mjs`; defaults to `.`) |
| `pionc test [--json] [--package\|-p <name>] [--filter <name>] [--jobs <n>] [-l <lib>] [path]` | Run `test "name" { ... }` blocks in isolated child processes with active `debug_assert`; a workspace directory runs every local package's tests in one pass and one report, with test binaries cached in the CAS (`testbin/`) and built and run in parallel (`--jobs`, `$PION_JOBS`; defaults to `.`) |
| `pionc fmt [--check] [--json] [path...]` | Deterministic, idempotent, comment- and UTF-8-preserving formatter (defaults to `.`) |
| `pionc init [--template cli\|service\|invar-app] [--json] <dir>` | Scaffold a package from a template (`cli` default, `service` background worker, or `invar-app` `#render_thread`-guarded dual-thread GUI skeleton); the result passes `check`, `test`, `run` and `fmt --check` as is |
| `pionc fetch [--json] [dir]` | Resolve `git` dependencies into the global git cache and write/verify `pion.lock` |
| `pionc add [--json] <name> (--path <p> \| --git <url> [--tag\|--rev\|--branch <r>] [--subdir <s>] \| [--registry <url>]) [dir]` | Add or change one dependency in `pion.toml` (in place, idempotent) and lock it; files restored on failure |
| `pionc remove [--json] <name> [dir]` | Remove a dependency from `pion.toml` (preserving comments and formatting) and prune `pion.lock` |
| `pionc update [--json] [pkg] [dir]` | Re-read registry entries, re-resolve git dependencies to their newest target refs, rewrite `pion.lock`, re-check the workspace (restored on failure) |
| `pionc search [--json] [--offline] [--refresh] [--registry <url>] [--category <cat>] [query...]` | Search packages in the official default registry (or custom `--registry`) by keyword or category |
| `pionc doctor [--json]` | Inspect toolchain health (`pionc`, `qbe`, `libpionrt.a`, `pion_wasm_rt.mjs`, `cc`/`cxx`, `node`, `git`, CAS stats) |
| `pionc cache stats\|prune\|clear [--all] [--json]` / `pionc clean [--all] [--json]` | Inspect, LRU-prune, or clear the global CAS (`--all` also clears cached `git/` and `registry/` repos) |
| `pionc --version\|-V\|version [--json]` / `pionc --help\|-h\|help` | Print compiler version + host target (or JSON) / full CLI usage (exit 0) |

---

## Measured Results

Every number below is copied from the combined P20 run of the scripts named in each section (main `a8e1019` + `feat/p20-final`: P20-A `dyn Trait` and 12/12 `edits`, P20-B one-pass parallel CAS `pionc test` and `pionc add`/`update`, P20-C `std/tls` server, P20-D QBE ARM64 peepholes and short-string fast paths), on **Apple M5 Max (18 cores), Darwin 27.0.0 arm64** and an **x86_64 Linux** host. Rerun the scripts to reproduce: checksums are fixed, absolute milliseconds vary with machine load. The macOS host is shared; the 1-minute load average was 34–43 during §1, §2 and §5 and 76 when §4's report was written. Peak RSS and instructions retired (`/usr/bin/time -l`) do not depend on load and are listed next to the wall times.

Toolchains: C Apple clang 21.0.0 `-O2`, MoonBit `0.1.20261117` `--target native --release`, Zig `0.17.1` `-OReleaseFast`, Rust `1.100.0` `-O` / `--release`, Go `1.27.3` `go build`, Pion `pionc2 0.1.0 build --release` (self-hosted, embedded QBE).

### 1. V2 real workloads, 6 languages (`sh scripts/bench-v2-exec.sh`)

Full mode (1 warmup + 5 runs, median); checksums bit-for-bit identical across all six languages and `1T == 4T`.

| Median ms / peak RSS MB / instructions retired (M) | C | MoonBit | Zig | Rust | Go | **Pion (`pionc2`)** |
|---|---:|---:|---:|---:|---:|---:|
| `json_query` (11.6 MB JSON) | 56.24 / 76.7 / 1,046 | 73.55 / 92.8 / 1,371 | 54.28 / 81.5 / 1,006 | 51.13 / 67.4 / 844 | 62.26 / 106.1 / 1,259 | **63.58** / 105.7 / 1,116 |
| `bytecode_vm` | 58.58 / 2.4 / 886 | 60.34 / 2.7 / 1,577 | 47.22 / 2.5 / 794 | 55.64 / 2.7 / 1,202 | 47.62 / 10.2 / 1,155 | **61.96** / 2.9 / 1,507 |
| `mt_log_pipeline_1t` (17.5 MB log) | 70.03 / 18.6 / 773 | 77.33 / 18.9 / 1,426 | 65.71 / 18.6 / 726 | 57.08 / 18.8 / 735 | 43.47 / 39.6 / 613 | **68.94** / 18.6 / 898 |
| `mt_log_pipeline_4t` | 53.40 / 18.7 / 776 | N/A (1T) | 50.94 / 18.7 / 775 | 56.04 / 18.9 / 795 | 34.35 / 42.2 / 688 | **51.00** / 18.8 / 952 |
| 3 binaries, stripped bytes | 103,576 | 757,240 | 505,064 | 1,167,864 | 7,159,144 | **221,848** |

Pion retires more instructions than C, Zig and Rust on all three workloads (1.07–1.90×); its median wall time is 1.24–1.59× that of the fastest language per workload (Rust, Zig or Go), ahead of MoonBit on `json_query` and `mt_log_pipeline` and of Rust and C on `mt_log_pipeline_4t`, but behind MoonBit, C and Rust on `bytecode_vm` in this run.

### 2. V2 compile: 50k LOC, 50 packages, 4-layer diamond DAG (`sh scripts/bench-v2-compile.sh`)

Checksums identical across all six languages for the cold build, all three edits and all five worktrees. "5-WT" = five worktrees built one after another with a shared global cache.

| Lang | Cold (ms) | Leaf body edit (ms) | Core body edit (ms) | Core signature edit (ms) | 5-WT total (ms) | 5-WT in-tree cache | 5-WT global cache |
|---|---:|---:|---:|---:|---:|---:|---:|
| C (`make -j12`) | 1400.19 | 1212.42 | 254.09 | 338.88 | 8161.00 | 1.55 MB | 0 |
| MoonBit | 15881.63 | 114847.20 | 17869.56 | 15846.71 | 91648.77 | 101.40 MB | 0 |
| Zig | 38302.26 | 24764.87 | 27447.28 | 31809.24 | 167319.58 | 44.97 MB | 43.36 MB |
| Rust (`cargo`) | 5234.16 | 746.43 | 743.50 | 730.56 | 6962.33 | 18.34 MB | 0 |
| Go | 5571.80 | 453.15 | 320.91 | 263.82 | 5726.32 | 0 | 80.57 MB |
| **Pion (`pionc2`)** | **1371.41** | **143.59** | **178.96** | **187.34** | **1572.22** | **0** | 13.02 MB |

This run was on a loaded host: the cold builds of Rust, Go, Zig and Pion took 1.6–3.1× their P19 times while C and MoonBit were about as fast as in P19, so compare languages within the table rather than across runs.

### 3. Dogfood applications

| | `examples/http_event_server` | `examples/http_kv_service` | `examples/sqlite_indexer` | `examples/https_server` |
|---|---|---|---|---|
| What | `std/net` event-loop HTTP/1.1 key-value server: 4 `kqueue`/`epoll` workers sharing the port through `SO_REUSEPORT` | multithreaded HTTP + JSON key-value service on `std/http` / `std/json` | pure-`Pion` indexer calling the system `libsqlite3` through `extern "C"` (zero C glue) | HTTPS/1.1 + JSON service on the `std/tls` server API (`tls_listen` / `tls_accept`, system OpenSSL, no C glue): `GET /health`, `POST /echo`, `GET /stats` (`AtomicInt` counters), `POST /quit` |
| Load / work | x86_64 Linux: **C1000** — 1,000 concurrently open keep-alive connections × 40 = 40,000 requests from 4 client threads, 0 errors, exact `/stats` check; per-worker requests 10,361 / 10,400 / 8,800 / 10,440 | x86_64 Linux: 8 clients × 500 = 4,000 requests, 0 errors, exact `/stats`, with and without Keep-Alive | indexes `compiler/src/core` (15 files / 35,397 lines), cross-checked 100% by the `sqlite3` CLI | x86_64 Linux (OpenSSL 3.5.7): self-test with 4 concurrent verified pure-Pion clients (TLS 1.3), Python `ssl` and curl at TLS 1.3 and 1.2, wrong host refused, mismatched key / missing certificate refused, exact final `/stats` |
| Speed | **121,028 QPS**, P50 6.82 ms, P99 18.28 ms (max 26.5 ms), peak RSS 14.83 MB | Keep-Alive **92,452 QPS**, P50 0.061 ms, P99 0.215 ms; connection per request 31,676 QPS, P50 0.193 ms, P99 1.106 ms; peak RSS 14.5 MB | — | functional gate (not benchmarked) |
| Binary | 118,144 B stripped (build 108 ms) | 105,392 B stripped (build 66–94 ms) | 123 KB | 155,136 B (unstripped, Linux) |
| Memory safety | `ASAN=1` mode of `run_bench.sh` (not part of this run) | ASan + LSan: 0 errors, 0 leaks (archived P13 run) | ASan + LSan: 0 errors, 0 leaks (archived P13 run) | optional ASan + LSan self-test (`PION_ASAN_RT`, not part of this run) |

The `http_event_server` C1000 numbers are from the archived P19 run (not rerun here). Reproduce: `sh examples/http_event_server/run_bench.sh <pionc> 1000 40 4`, `sh std/tls/e2e/run_server_e2e.sh <pionc>` (run by `scripts/test-linux.sh`), `sh examples/http_kv_service/run_bench.sh <pionc> 8 500 8` (with and without `KEEP_ALIVE=1`, both run by `scripts/test-linux.sh`) and `scripts/verify-all.sh` gate 6. On C1000 the latency percentiles are those of 1,000 connections queued on 4 workers; the 8-connection KV numbers measure per-request latency.

**Flagship: `examples/pion_station`.** Three packages (`store`, `router`, the app) in pure `Pion`, zero C glue: HTTPS/1.1 on `std/tls`, Server-Sent Events, a SQLite WAL store through `extern "C"` to the system `libsqlite3`, `dyn Handler` routing with `std/regex` path patterns, and a 4-thread `Channel` job pool. SSE subscribers are closed on disconnect or `limit` and pruned from the broadcast list, so long runs keep no per-connection backlog.

| `examples/pion_station` | x86_64 Linux | Apple M5 Max, macOS arm64 |
|---|---|---|
| Tests | 39/39 (`pionc test --json`) | 39/39 |
| Functional e2e | 4 concurrent pure-Pion TLS clients, 40 jobs, SSE stream, wrong host refused; restart recovery cross-checked 100% by the `sqlite3` CLI | same self-test |
| Load (4 threads, HTTPS + SQLite + jobs, 0 errors) | **993–1,017 QPS**, P50 3.53–3.57 ms, P99 10.34–10.66 ms, peak RSS 14.4–14.8 MB | 620–937 QPS, peak RSS 7.6 MB |
| Binary (stripped) | 216,992 B | 245,112 B |
| Release cold build | 185–214 ms | 124–155 ms |
| Incremental: one Handler body edit → `pionc test --json --package router` | 77–101 ms | — |
| Memory / thread safety | ASan + LSan 0 errors, 0 leaks; TSan 0 warnings | — |

Linux numbers span the P21 runs and the v1.0.0 gate run (`scripts/test-linux.sh` on x86_64 Linux); macOS numbers are from the P21 runs (`verify-all.sh` runs the 39 tests, not `run_e2e.sh`). Reproduce: `sh examples/pion_station/run_e2e.sh <pionc>` (cold build, incremental test, self-test, restart + `sqlite3` cross-check, load and peak RSS; run by `scripts/test-linux.sh` where `libsqlite3` and the `sqlite3` CLI exist). QPS here is a full TLS handshake per request plus SQLite writes, not comparable to the plain-TCP services above.

### 4. Agent-in-the-loop evaluation, 4 languages (`sh benchmarks/agent_eval/run.sh`)

Full report: [`benchmarks/agent_eval/SUMMARY.md`](benchmarks/agent_eval/SUMMARY.md) (run of 2026-11-20 on the same Apple M5 Max; load average 76 / 48 / 34 when the report was written, medians of 1 warmup + 5 runs). 12 engineering tasks and 12 error-class probes per language; check commands `pionc2 check --json`, `moon check --output-json`, `cargo check --message-format=json`, `go build -json`. Gates: 48/48 reference implementations pass, 48/48 probes measured with 0 expectation mismatches.

|  | **Pion (`pionc2`)** | MoonBit | Rust | Go |
|---|---:|---:|---:|---:|
| error classes caught before running (of 12) | **12** | 10 | 10 | 8 |
| caught with JSON diagnostics / any fix suggestion | **12/12 / 12** | 10/10 / 0 | 10/10 / 7 | 8/8 / 0 |
| caught with a machine-applicable edit | **12** | 0 | 4 | 0 |
| machine edit applied verbatim → re-check clean (0 errors) | **9** | 0 | 2 | 0 |
| median check latency (ms) | **5.8** | 59.5 | 88.3 | 81.2 |
| median diagnostic size when caught (bytes) | 738.0 | 544.5 | 4840.0 | 343.0 |
| effective LOC, 12 tasks | 1526 | 1393 | 1446 | 1539 |
| first (cold) test run, `t06` (ms) | **243.9** | 1656.0 | 1730.7 | 7301.6 |
| private body edit → tests green (ms) | 276.7 | 840.0 | 979.5 | **234.6** |
| exported-signature edit → tests green (ms) | **251.2** | 826.7 | 1123.8 | 313.1 |
| 5 worktrees check+test concurrently, cold (wall ms) | **372.9** | 3932.4 | 2301.4 | 10867.6 |
| build artefacts inside the 5 worktrees (MB) | **0.0** | 42.1 | 63.8 | 0.0 |

Apply-and-recheck takes the first error diagnostic's machine-applicable patch (every Pion `edits` entry of it, or every `MachineApplicable` span of rustc's first suggestion), applies it verbatim to a scratch copy and runs the same check again. Pion's patch clears the error in one step for type mismatch, arity, unknown field, non-exhaustive `match`, private symbol, missing trait impl, discarded `Result`, missing return type and immutable assignment; three need a second step and are reported as such: `e07` (the impl takes the trait's return type, the body still returns the old one: 1 error), `e08` (the captured array becomes `Mutex[Array[Int]]`, the `push` inside the closure must become a locked access: 2 errors) and `e10` (the helper gains `world : World`, its caller must pass it: 2 errors). rustc's 4 patches clear 2 (`e11`, `e12`). The one-pass parallel CAS `pionc test` (P20-B) cut the `t06` edit → tests-green loop from 644 / 649 ms (P19) to 277 / 251 ms with every dependent test binary still relinked against the new objects (no stale passes); Go's cached body-edit run is still slightly faster.

### 5. V1 classic kernels, 5 languages (`PIONC=$PWD/out/pionc2 sh scripts/bench.sh`)

1 warmup + 5 timed runs, median; strict bit-for-bit checksums across all five languages, including the `scale10k` cold → incremental pair.

#### Execution (median ms / instructions retired, M)

| Benchmark | C (`-O2`) | MoonBit | Zig (`-OReleaseFast`) | Rust (`-O`) | **Pion (`pionc2`)** |
|---|---:|---:|---:|---:|---:|
| `nbody` | 156.62 / 2,314 | 338.06 / 3,519 | 150.73 / 2,007 | 151.42 / 2,012 | **173.93** / 3,405 |
| `binarytrees` | 502.24\* / 6,045 | 69.71 / 1,286 | 441.23\* / 6,192 | 1034.35\* / 7,613 | **79.08** / 1,664 |
| `spectralnorm` | 129.53 / 1,898 | 102.43 / 2,018 | 98.72 / 1,780 | 98.02 / 1,777 | **96.02** / 2,254 |
| `fannkuchredux` | 165.98 / 1,430 | 138.22 / 1,816 | 126.89 / 758 | 139.23 / 1,308 | **141.16** / 1,514 |
| `mandelbrot_1t` | 614.79 / 6,217 | 599.52 / 6,194 | 561.79 / 6,090 | 613.44 / 5,764 | **628.69** / 5,507 |
| `mandelbrot_4t` | 278.68 / 6,224 | N/A (1T) | 239.47 / 6,108 | 253.98 / 5,770 | **215.69** / 5,512 |
| `hashmap_str` | 62.97 / 653 | 61.94 / 581 | 23.76 / 273 | 64.55 / 923 | **39.44** / 428 |

\* Load-distorted: min–max spreads of 406–517 ms (C), 376–466 ms (Zig) and 638–1154 ms (Rust) on `binarytrees` in this run; the archived quiet-host P8 run measured `binarytrees` at 258.32 (C) / 257.00 (Zig) / 422.60 (Rust) vs 67.75 ms (Pion). Compare the instruction counts, which load does not change. Since P19 (P20-D's ARM64 peepholes and short-string fast paths) `hashmap_str` went from 456 M to 428 M instructions and `fannkuchredux` from 1,588 M to 1,514 M.

#### Compile speed (10,000 LOC / 20 packages) & worktree cache pollution

| Language | Cold compile (ms) | 1-line body edit incr (ms) | Worktree cache | Global CAS |
|---|---:|---:|---:|---:|
| C (`make -j8`) | 297.49 | 101.46 | 0.28 MB | 0 |
| MoonBit | 1041.07 | 735.54 | 3.79 MB | 0 |
| Zig | 2324.48 | 230.73 | 1.20 MB | 0 |
| Rust (`cargo`) | 1507.81 | 803.15 | 2.47 MB | 0 |
| **Pion (`pionc2`)** | **167.13** | **38.58** | **0.00 MB** | 1.44 MB |

#### Binary artifact sizes (default / stripped, bytes)

| Language | `hello` | 6-benchmark total |
|---|---:|---:|
| C | 33,432 / 33,432 | 218,648 / 218,528 |
| **Pion (`pionc2`)** | **52,120 / 50,792** | **322,440 / 308,080** |
| Zig | 52,120 / 50,184 | 1,963,592 / 1,750,048 |
| MoonBit | 283,272 / 241,176 | 1,706,680 / 1,447,216 |
| Rust | 471,736 / 342,920 | 3,023,928 / 2,213,584 |

Pion's `hello` fell from 71,976 B to 50,792 B stripped and the six V1 binaries from 531,024 B to 308,080 B since the P8 run.

---

## Known Limitations & Next Steps

- No automatic SIMD vectorization (QBE has no vector IR and LLVM is excluded by design); on `nbody` Pion is 11% behind C `-O2` and ~15% behind Zig/Rust, retiring 1.5–1.7× their instructions (§5). Across the V2 workloads Pion still retires 1.07–1.90× the instructions of C, Zig and Rust (§1).
- Three of the 12 machine-applicable `edits` need a second step after they are applied (`e07`, `e08`, `e10` in §4): the patch fixes the reported spot, and the follow-up error (body type, locked access, caller passing `world`) comes with its own diagnostic.
- `std/tls` binds the system OpenSSL (1.1.x or 3.x): it must be installed (Debian/Ubuntu `libssl-dev`, macOS Homebrew `openssl@3`), and certificates and keys are loaded from PEM files only.
- The package registry is a git index (`index/<pkg>.toml` entries naming a git source and version); there is no version-range solver: each dependency is locked to one tag, rev or branch head.
- Targets: macOS (`arm64_apple`, `amd64_apple`), Linux (`amd64_sysv`, `arm64`, `rv64`), Windows (`amd64_win`), iOS (`ios_arm64`, `ios_sim_arm64`), Android (`android_arm64`, `android_x64`) and Web (`wasm32`, zero-toolchain direct `.wasm` emitter + universal Browser/Node ES module `runtime/pion_wasm_rt.mjs`) are supported via `--target`, `--sysroot`, `--emit-staticlib` and `--emit-cdylib` (CI verifies native self-hosting on `macos-15`, `ubuntu-latest` x86_64, `ubuntu-24.04-arm` aarch64 and `windows-latest` x86_64, plus Wasm32 E2E + V1 benchmarks in Node.js).
- `dyn Trait` values are `!Send` and boxed (one 16-byte RC allocation per conversion); hot paths keep using monomorphized generics.

## Quick Start & Full Reproduction

Only a C11 compiler (`cc`) and `python3` are required — zero MoonBit or LLVM dependencies:

```sh
# One-command relocatable install to ~/.pion (bootstraps if needed, verifies via `pionc doctor`):
sh scripts/install.sh
export PATH="$HOME/.pion/bin:$PATH"
pionc doctor
pionc init demo && cd demo && pionc check && pionc test --json && pionc run

# Build a relocatable release archive (tar.gz / zip + .sha256, with zero-env self-check):
sh scripts/package-release.sh dist
# Exactly what .github/workflows/release.yml does per platform on a `vX.Y.Z` tag
# (seed -> stage 1 -> `--release` pionc, rebuilt by itself to a bit-identical fixed point;
# PION_VERSION's X.Y.Z must equal `pionc --version`):
sh scripts/build-release.sh
PION_VERSION=0.1.0 PIONC="$PWD/out/pionc_release" PION_QBE="$PWD/out/qbe" PION_RT_LIB="$PWD/out/libpionrt.a" \
  sh scripts/package-release.sh dist

# Or bootstrap directly in-tree from bootstrap/pionc-seed.ssa.gz (pure C + QBE, fixed-point verified):
sh scripts/bootstrap.sh
out/pionc2 run examples/text_stats

# Full 6/6 gate on macOS ARM64:
# <64 KB runtime (O2 + TSan + ASan), 9/9 pure-Pion fixed-point bootstrap +
# compiler/src/core unit tests, fmt (UTF-8), std/json/http/net/regex + dogfood app tests,
# pionc init smoke, e2e suites, cross ELF64 .o, dyn_trait, pionc add/update registry e2e,
# examples/https_server + examples/pion_station tests (with Homebrew openssl@3)
sh scripts/verify-all.sh

# Full 6/6 gate on Linux x86_64 (standalone from bootstrap/pionc-seed.ssa.gz, or pass PION_LINUX_SSA):
# zero-`as` ELF64 objects, <56 KB runtime, epoll event loop, Stage 3 == Stage 4,
# compiler/src/core + std/* tests, dyn_trait, pionc add/update e2e, std/tls client +
# server TLS 1.3/1.2 e2e (examples/https_server vs Python ssl and curl), KV service
# 8x500 (with/without Keep-Alive), event-server self-test, examples/pion_station
# tests + run_e2e.sh (with libsqlite3 and the sqlite3 CLI), V1 checksums
sh scripts/test-linux.sh

# Benchmarks
sh scripts/bench-v2-exec.sh            # V2 real workloads, 6 languages
sh examples/http_event_server/run_bench.sh "$PWD/out/pionc2" 1000 40 4   # C1000 keep-alive
sh examples/pion_station/run_e2e.sh "$PWD/out/pionc2"   # flagship: build, e2e, restart, load
sh scripts/bench-v2-compile.sh         # V2 50k LOC / 50 packages compile
PIONC="$PWD/out/pionc2" sh scripts/bench.sh   # V1 classic kernels, 5 languages
sh benchmarks/agent_eval/run.sh        # agent-in-the-loop, 4 languages
```

CI (`.github/workflows/ci.yml`) runs `verify-all.sh` on `macos-15` (zero MoonBit) and then `test-linux.sh` on `ubuntu-latest` with the uploaded `stage2.ssa`.

## Repository Layout

- `bootstrap/pionc-seed.ssa.gz` — architecture-independent QBE SSA Stage 0 bootstrap seed (zero external compiler dependency)
- `compiler/src/core/` — pure `Pion` compiler core (`lexer`, `ast`, `parser`, `sig`, `types`, `llbc`, `lean`, `qbe`, `cas`, `diag`, `query`, `fmt`, `manifest`, plus native `pionc test` suites)
- `compiler/src/cli/` — native `Pion` CLI driver (parallel package compilation, CAS, workspace/package manager, `extract-lean`)
- `lean/` & `tests/lean/` — `PionLean` runtime/lemma library for `pionc extract-lean`, plus extracted proof suites (`AlgosProofs`, `CodecProofs`, `CapTableProofs`, `QbeTvProofs`) and native-vs-Lean differential cases
- `tools/qbe_tv/` — QBE SSA translation validator written in `#verify` Pion with end-to-end Lean 4 soundness proofs (`SPEC.md` §3.6)
- `runtime/` — `<64 KB` C11 runtime (`pion_rt.h`, `pion_rt.c`, `test_rt.c`; BRC, slab allocator, threads, `kqueue`/`epoll` event loop)
- `vendor/qbe/` — vendored QBE with direct Mach-O / ELF64 object emission and hardware `sqrt` lowering
- `std/json`, `std/http`, `std/net`, `std/regex`, `std/tls` — standard packages in pure `Pion`
- `examples/` — `text_stats` (multi-package), `http_loopback`, `http_kv_service`, `http_event_server` (C1000 keep-alive event-loop server), `sqlite_indexer`, `https_server` (pure-Pion HTTPS service on `std/tls`), `pion_station` (flagship: HTTPS + SSE + SQLite WAL + `dyn Handler` + worker pool, 3 packages)
- `benchmarks/` — V1 (`c`, `moonbit`, `zig`, `rust`, `pion`), V2 (`v2/`, + Go) and `agent_eval/`
- `scripts/` — bootstrap, verification, Linux and benchmark scripts

## Bootstrap Seed Provenance

`bootstrap/pionc-seed.ssa.gz` is a compressed, architecture-independent QBE SSA IR snapshot emitted by the pure-Pion compiler itself from `compiler/src/core/` and `compiler/src/cli/`, allowing anyone to bootstrap `pionc` standalone from scratch with only a C11 compiler (`cc`) and `python3`. When the seed lags behind the compiler, every bootstrap needs one extra full self-build stage to reach the fixed point; refresh it from a fixed point with `gzip -n -9 < out/stage2.ssa > bootstrap/pionc-seed.ssa.gz`.

Every bootstrap script verifies that adjacent self-hosting stages converge to a bit-for-bit fixed point (identical SSA; on Linux also identical assembly and object hashes):
- **macOS ARM64 (`sh scripts/bootstrap.sh` / `sh scripts/verify-all.sh`)**: compiles `bootstrap/pionc-seed.ssa.gz` through vendored QBE + C runtime into `pionc0`, then builds `pionc1` and `pionc2`, verifying `Stage 1 == Stage 2` (or advancing to `pionc3` to verify `Stage 2 == Stage 3` when codegen has changed since the seed).
- **Linux x86_64 / ARM64 (`sh scripts/test-linux.sh`) & Windows x86_64 (`sh scripts/test-windows.sh`)**: standalone runs bootstrap directly from `bootstrap/pionc-seed.ssa.gz` and verify adjacent stages converge bit-for-bit (`Stage 3 == Stage 4`, extending up to `Stage 4 == Stage 5` when codegen differs from the seed). In PR CI (`.github/workflows/ci.yml`), every platform bootstraps independently from the seed in parallel, and the `stage-ssa-cross-host-parity` job then checks that the macOS ARM64 `out/stage2.ssa` and the Linux x86_64 `out/linux_stage.ssa` fixed points are byte-for-byte identical. `PION_LINUX_SSA` still lets `test-linux.sh` start from any other SSA.

## License

`Pion` is licensed under the [MIT License](LICENSE).

Third-party attributions and licenses — including the vendored QBE 1.3 backend (`vendor/qbe/LICENSE`, MIT License) — are documented in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and included in release archives.
