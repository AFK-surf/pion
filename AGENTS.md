# Working on `Pion` (for agents)

Pion is a systems language built for AI agents to write and iterate on at high frequency. Read this before touching anything; `SPEC.md` holds the details.

## 1. Product constitution (non-negotiable)

- **Agent-first, no human developer tools.** Do not build an LSP, IDE/editor plugins, or an interactive DWARF debugger for humans, and never list their absence as a gap or TODO. All tooling effort goes to: fast deterministic CLI, compact structured JSON diagnostics with stable `code`s and fix-its (moving toward machine-applicable `edits`), symbol/call-graph/API queries, and explicit unambiguous contracts — `pionc check|query|doc|fmt|test --json`.
- **Zero LLVM; release build speed is build speed.** LLVM is banned. There is no "fast dev / slow release" split: daily builds and releases use the same pipeline (embedded QBE → native ARM64 Mach-O / Linux x86_64 ELF64 `.o`, linear low-overhead optimizations, parallel global CAS). Release builds must beat mainstream compiled languages on build time.
- **C-speed execution, native multithreading.** Single-core target is C `-O2` speed. Concurrency is native OS threads (`scope`/`spawn`/`Channel`/`Mutex`/`AtomicInt`) with biased RC, compile-time race freedom (`Send`), and explicit `World` capability boundaries for IO.
- **Tiny binaries, zero worktree cache pollution.** Keep artefacts small (`libpionrt.a` < 64 KB, `hello` ~50 KB, a service ~110 KB). Source trees get **0 bytes** of `target/`/`_build/`: outputs live in the global LRU CAS shared zero-copy across agent worktrees. The compiler is 100% self-hosted in pure `Pion` (`bootstrap/pionc-seed.ssa.gz` + `compiler/src/core/` + `compiler/src/cli/`, zero MoonBit/Rust/LLVM dependencies).
- **Objective benchmarks and real dogfooding — no self-congratulation.** Never claim performance or agent-friendliness by feel. Every such change is measured on the same machine against other languages with bit-for-bit identical checksums (`scripts/bench-v2-exec.sh`, `scripts/bench-v2-compile.sh`, `scripts/bench.sh`, `benchmarks/agent_eval/run.sh`) and on real programs in `examples/`. Record weaknesses as honestly as strengths.

## 2. Compiler and repository invariants

- **`SPEC.md` is the single source of truth** for grammar, type system, runtime ABI and JSON protocol. Any change to these updates `SPEC.md` in the same commit.
- **Pure-Pion self-hosting fixed point.** Everything under `compiler/src/core/` and `compiler/src/cli/` is pure `.pion` with zero MoonBit dependency. Bootstrap from `bootstrap/pionc-seed.ssa.gz` must stay bit-for-bit fixed-point: `pionc0 → pionc1 → pionc2` on macOS ARM64, and Stage 3 == Stage 4 on Linux x86_64 (no `as`).
- **Runtime size budget.** `libpionrt.a` must be `< 65,536 B` on all four gated platforms — macOS ARM64, Linux x86_64 (including Ubuntu GCC's default hardening), **Linux ARM64 (hard gate, the tightest: `-Os -mbranch-protection=none -fno-stack-protector`, GCC 14)** and Windows x86_64; aim for `< 56 KB` on Linux x86_64 to keep headroom. Hot paths (`pion_rc_*`, `pion_alloc*`, `pion_map_*`, `pion_arr_push*`, `pion_str_eq`, `pion_str_from_cstr`) must not carry `PION_MINSIZE`; cold paths should. Build with `-fno-asynchronous-unwind-tables`.
- **Runtime layering (`libpionrt.a` vs `libpionrt_cli.a`).** `runtime/pion_rt.c` → `libpionrt.a` holds only what user programs can reach (World IO, RC/alloc, collections, the `pion_fs_cpath` path gate `pion_path_cstr` is built on, …). Helpers only `pionc` itself needs (`pion_fs_mkdir_excl`, `pion_fs_rmdir`, `pion_fs_trylock`, `pion_fs_lock`, `pion_fs_unlock`, `pion_fs_canon_path`, `pion_fs_lstat_kind`, `pion_cli_getpid`, `pion_cli_is_windows`) live in `runtime/pion_cli.c`, archived with `pion_rt.o` into `libpionrt_cli.a` and linked only into `pionc` (bootstrap/self-build via `PION_RT_LIB=…/libpionrt_cli.a`) and `test_rt`. Put new compiler-only native helpers there, never in `pion_rt.c`; before moving anything out of `pion_rt.c`, check that no user-reachable API (or `SPEC.md` contract) depends on it.
- **Deterministic tests.** Concurrency tests synchronize via `scope`/`Channel`/`AtomicInt`/FIFO ordering — **never `sleep`**. Both gates must pass 6/6 before merging: `sh scripts/verify-all.sh` (without `moon` on `PATH`) and `sh scripts/test-linux.sh`.
- **Don't stop without cause.** When you hit a real weakness or an independently fixable compiler/performance/stdlib issue, keep going in priority order and verify each fix; do not pause after every small step waiting to be prompted.

## 3. Build and verification

```sh
sh scripts/verify-all.sh                          # macOS ARM64 gate, 6/6: runtime, pure-Pion seed bootstrap + compiler/src/core tests, fmt, tests, e2e, dogfood
sh scripts/test-linux.sh                          # Linux x86_64 gate, 6/6: runtime size, standalone seed or PION_LINUX_SSA ELF, Stage 3 == Stage 4, compiler/src/core tests
sh scripts/bench-v2-exec.sh [--quick]             # cross-language execution speed (checksums must match)
sh scripts/bench-v2-compile.sh                    # cross-language cold/incremental/multi-worktree build speed
sh scripts/bench.sh                               # archived P8 suite
sh benchmarks/agent_eval/run.sh                   # agent-in-the-loop eval vs MoonBit / Rust / Go
```
