# Pion Best Practices (For AI Agents)

Concise engineering rules for writing fast, race-free, maintainable Pion programs.

## 1. GUI / Invar Dual-Thread Architecture (`#render_thread`)

When building desktop, mobile, or web GUI apps with Invar, **strictly isolate the render thread from business logic and blocking IO**:

- Scaffold new apps with `pionc init --template invar-app <dir>` (produces `src/protocol.pion`, `src/worker.pion`, `src/view.pion`, `src/main.pion`, `main_test.pion`).
- **Render thread (`src/view.pion`)**: annotate every view builder and UI event entry point with `#render_thread` (alias `#no_io`).
  - Allowed: reading UI signals, handling `AppEvent` callbacks delivered via `worker.bind(...)`, constructing immutable `AppCmd`s and dispatching via `worker.send(cmd)` / `Channel::send`, pure layout/formatting, and non-`World` rendering `extern "C"` FFI.
  - Forbidden at compile time (`E_NO_IO_VIOLATION`): accepting or referencing `World`, calling `fs_*`, `tcp_*`, `proc_*`, `sleep_ms`, `io_*`, or `scope` — inside the function or any nested event-handler closure.
  - **Never silence `E_NO_IO_VIOLATION` by removing `#render_thread` or threading `world : World` into the view.** Add an `AppCmd` variant, handle it in `src/worker.pion`, and emit an `AppEvent`.
- **Background worker (`src/worker.pion`) & Invar Split-Handle API**:
  - `let (worker, ctx) = ui::Worker::pair()` splits the bridge into a render-thread handle (`worker`) and a `Send`-safe background context (`ctx`).
  - Spawn the background OS thread with `scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { ctx.run_loop(fn(cmd, emit) -> Unit { ... }) }) })`: `ctx` owns the blocking loop with `world : World` for all filesystem, network, SQLite, and heavy compute, calling `emit(ev)` (which pushes into the `Mutex[Array[Ev]]` queue and calls `ui::wake_now()`).
  - On the render thread, call `worker.bind(fn(ev) -> Unit { ... })` (registers `ui::on_before_frame` under the hood to zero-latency batch-drain `Mutex[Array[Ev]]` before each frame), send commands with `worker.send(cmd)`, and shut down cleanly with `worker.close()`.
  - On `wasm32` and in deterministic `Tester` runs, swap `ui::Worker::pair()` for `ui::Worker::inline(...)` so the exact same `AppCmd`/`AppEvent` protocol runs synchronously without branching view or business logic.

```pion
// Standard Invar dual-thread wiring (render thread + background World worker)
let (worker, ctx) = ui::Worker::pair()
worker.bind(fn(ev : AppEvent) -> Unit {
  apply_event(state, ev)
})
scope(world, fn(s : Scope) -> Unit {
  spawn(s, fn() -> Unit {
    ctx.run_loop(fn(cmd : AppCmd, emit : (AppEvent) -> Unit) -> Unit {
      // All World IO (fs, http, sqlite) lives here; emit wakes the UI via ui::wake_now().
      match handle_cmd(world, cmd) {
        Some(ev) => emit(ev)
        None => ()
      }
    })
  })
  run_invar_app(worker) // view callbacks only call worker.send(cmd); worker.close() on exit
})
```

## 2. Explicit `World` Capability & Structured Concurrency

- Keep pure domain logic free of `World` parameters so it is trivially unit-testable in `test "..." { ... }` blocks and reusable from both workers and tools.
- Use `scope(world, fn(s : Scope) -> Unit { spawn(s, ...) })` for native multithreading; synchronize via `Channel[T]`, `Mutex[T]`, and `AtomicInt` — never `sleep_ms` in tests.
- Prefer immutable `struct`/`enum` messages over `Channel[T]` so values satisfy `Send` without locking; wrap shared mutable containers (`Array`, `Map`) in `Mutex[...]` or transfer ownership with `move`.
- Scaffold background services with `pionc init --template service <dir>`.

## 3. Zero-Allocation Hot Paths & Scalarization

- Avoid allocating temporary `String`s or heap objects inside tight loops: reuse buffers (`StringBuilder`, pre-sized `Array`), index bytes directly with `str_code_at` / `code_unit_at`, and pass slices `(buf, start, end)` instead of substring copies.
- Prefer `val struct` for small value records (2D/3D points, rects, colors, spans) so they stay unboxed in registers/stack without RC traffic.
- Keep `mut` locals scalarized (`Int`, `Int64`, `Double`, `Float`) inside inner loops; lift invariant lookups out of loops.
- Use `debug_assert(cond, msg)` liberally for invariants — active in `pionc test`, stripped to 0 bytes in `pionc build --release`.
- Apply these rules where a profile shows the cost (§6), not speculatively.

## 4. Agent Verification Loop

Always close the loop with structured CLI tools before reporting done:

```sh
pionc check --json <path>        # compact diagnostics with stable `code`, `fixit`, and machine-applicable `edits`
pionc query defs --json <path>   # inspect symbols/signatures across a package or workspace
pionc query callers --json <path># inspect call graph before refactoring
pionc fmt --check <path>         # verify canonical formatting
pionc test --json <path>         # run all tests in isolated parallel processes
pionc extract-lean --out <dir> --json <path> # extract `#verify` closure to Lean 4
```

## 5. Formal Verification with Lean 4 (`#verify` + `pionc extract-lean`)

Pion includes a built-in Aeneas-style Lean 4 extractor (`SPEC.md` §3.4–§3.5 & §5.5), so critical state machines, schedulers, codecs, and protocol parsers can be proven directly on production Pion code without maintaining a separate handwritten model:

- **Annotate pure kernels with `#verify`** (and mark any trusted leaf boundary `#verify_opaque`). The type checker enforces ownership/aliasing rules (`E_VERIFY_MOVE`, `E_VERIFY_BORROW_ESCAPE`, `E_VERIFY_ALIASING`), checked division/shift bounds, and verified-callee closure (`E_VERIFY_UNVERIFIED_CALLEE`).
- **Keep `#verify` APIs data-driven (no closures)**: closures and callback parameters are rejected by extraction (`E_EXTRACT_UNSUPPORTED`). Instead of taking `inspect: (K) -> Item` callbacks, pass plain data arrays (`Array[Input]`) and return explicit effect lists `(State, Array[Effect])` that the outer shell executes.
- **Use `Int64` for logical clocks and counters**: `#verify` forbids `Float` and `Double` arithmetic/comparisons (only `Double` bit-pattern primitives are allowed). Integer millisecond timestamps (`Int64` → `Std.I64`) make ordering, monotonicity, and liveness proofs straightforward in Lean 4.
- **Supported containers & control flow**: `mut` parameters (threaded functionally), `for`/`while` loops (`Aeneas.Std.loop`), recursion (`partial_fixpoint`), `struct`/`enum`/`trait`/`impl`, `Array`, `FixedArray`, `Bytes`, `StringBuilder`, and `Map[K, V]`. Avoid unmodeled builtins (`Array::sort`, string interpolation, `physical_equal`, most `String` methods beyond `.length()`).
- **Close the proof loop**: extract with `pionc extract-lean --out <dir> --json <path>`, prove theorems with zero `sorry`/`admit` and standard axioms only (`#print axioms`), and run `sh scripts/test-lean.sh <pionc>` (which also checks native-vs-Lean differential equivalence).


## 6. Performance Measurement & Optimization Loop (For AI Agents)

Never optimize by feel and never guess where time goes. Pion ships a clean benchmark harness (`pionc bench`, `SPEC.md` §5.8) and a built-in profiler (`--profile`, `pionc profile`, `SPEC.md` §5.9) whose output is structured JSON with threshold-gated `hints[]`. Use them in this order:

### 6.1 Write a benchmark

```pion
bench "parse_small_doc" {
  // setup: runs once, untimed
  let doc = make_fixture_doc(256)
  bench_loop {
    // timed: repeated N times; the last non-Unit value is black_box'ed automatically
    parse(doc).node_count()
  }
  // teardown: runs once, untimed
}

bench "checksum_simple" {
  checksum(black_box(4096)) // simple form: the whole body is timed
}
```

- Put fixtures in setup **inside the `bench` block**, not in top-level `let` constants: top-level constants are immortalized, so RC traffic on them is skipped and the profile no longer reflects real code.
- Keep the timed body free of setup work; use one `bench_loop` per `bench` (`E_BENCH_LOOP_DUPLICATE`), directly at the top level of the block (`E_BENCH_LOOP_CONTEXT`), with no `return` or `break`/`continue` that leaves it (`E_BENCH_LOOP_CONTROL_FLOW`).
- Wrap loop-invariant inputs in `black_box(x)` so they are not constant-folded; `black_box` costs one call, adds no RC operations, and is rejected in `#verify` code.
- `bench` blocks cost 0 bytes in `pionc build`/`run`/`test` output; they are compiled only by `pionc bench`.

### 6.2 The 5-step tuning loop

```sh
# 1. Clean baseline (release build, no profiler). Keep result files outside the source worktree (e.g. /tmp).
pionc bench --json --save /tmp/base.json .
# 2. Structured hot spots for the timed window only (profiler paused during setup/teardown).
pionc bench --profile --json --profile-out /tmp/base.prof.json --filter parse_small_doc .
#    whole-program alternative:  pionc run --profile --json --profile-out /tmp/base.prof.json . -- <args>
# 3. Make ONE targeted change guided by hints[] / top_functions[] / by_type[].
# 4. Confirm the cost moved where you expected.
pionc bench --profile --json --profile-out /tmp/new.prof.json --filter parse_small_doc .
pionc profile diff --json /tmp/base.prof.json /tmp/new.prof.json
# 5. Confirm the real speedup with a clean run (never with --profile numbers).
pionc bench --json --compare /tmp/base.json .
```

The same loop works on Wasm32 by adding `--target wasm32` to every `bench`/`run` command (runs under Node.js; CPU comes from `node --cpu-prof` with full stacks, memory/RC from `pion_wasm_rt.mjs`):

```sh
pionc bench --target wasm32 --json --save /tmp/base.wasm.json .
pionc bench --target wasm32 --profile --json --profile-out /tmp/base.wasm.prof.json .
# ... targeted change ...
pionc bench --target wasm32 --profile --json --profile-out /tmp/new.wasm.prof.json .
pionc profile diff --json /tmp/base.wasm.prof.json /tmp/new.wasm.prof.json
pionc bench --target wasm32 --json --compare /tmp/base.wasm.json .
```

Rules:
- Wall times measured under `--profile` include profiler overhead; report speed only from clean `pionc bench` runs, and only when `--compare` shows `"incomparable": false` (same `machine_fp`) and the benchmark's `comparisons[].status` is `improved` (`delta_pct <= -3.0`), not `noise` (within ±3%). Report regressions and `noise` results as honestly as improvements.
- In CI and tests always use `pionc bench --iters 1 --samples 1` (a smoke run, no timing assertions).
- Always read profile reports from `--profile-out <file.json>`: the report is also printed on stdout, where it would be mixed with anything the profiled program prints itself.
- `--profile` (no value) means `cpu,alloc` and keeps release inline RC, so CPU and allocation reflect production code. Use `--profile=rc` (or `all`) only to investigate RC traffic: it disables inline RC, so its CPU numbers are not representative.
- `--profile` implies `--release`; do not combine it with stripping linker flags (`E_PROFILE_STRIPPED`). Native profiling runs on Linux x86_64/ARM64 and macOS ARM64 (`E_PROFILE_UNSUPPORTED_TARGET` elsewhere).

### 6.3 Reading the profile report

- **Check honesty fields first.** `cpu_stack_mode: "pc_only"` (Native) means only self time is known: `cum_cpu_pct` is `null`, so look at the hottest *leaf* functions and their callers in the source. `rc_partial: true` means RC counts are incomplete (re-run with `--profile=rc`). Non-zero `dropped_samples` or `retained_truncated: true` mean some data was lost. `H_LOW_SAMPLES` means the run was too short for causal hints: lengthen the workload (more iterations) rather than trusting noise.
- **`managed`** — RC objects (strings, arrays, structs, closures, …): `alloc_count`/`alloc_bytes` show churn; `inuse_bytes`/`inuse_count` at exit should be `0` for a leak-free run.
- **`backing`** — raw buffers behind `Array`, `Map`, `String` and `StringBuilder`. A large `backing.alloc_bytes` versus `managed.alloc_bytes` means containers are growing repeatedly.
- **`allocator.peak_reserved_bytes`** — OS memory the allocator held at peak. Compared with live in-use bytes it shows fragmentation or transient spikes (large temporary containers).
- **`rc`** — `inc`/`dec`/`atomic_inc`/`atomic_dec`/`destroy`/`immortal` operation counts. `atomic_*` indicates objects shared across threads; `immortal` operations are on constants and cost nothing.
- **`by_type_tag[]` / `by_type[]`** — who allocates: `by_type[].type_name` names concrete types such as `Struct json::Node`, so you can see which struct or enum dominates.
- **`top_functions[]`** — ranked by self CPU (`pionc profile summary <profile> --sort alloc_bytes|cum_alloc_bytes|alloc_count|inuse_bytes|rc_ops|cum_cpu --top <N>` re-ranks). `category` separates `user` code from `runtime_mem`/`runtime_rc`/`runtime_std`/`external`; with release inline RC, RC cost appears inside the calling `user` function.
- **`--sample-rate`**: per-type and per-domain totals are always exact; the rate only thins **stack** attribution. Use `--sample-rate 1` (Native default) for exact per-function allocation attribution in short runs and small tests; use `--sample-rate 64` (Wasm32 default) for long or allocation-heavy runs where per-event stack capture would slow the program down. Add `--retained` when you need to know *who holds* live memory (`STACK inuse`, exact `inuse_*`).

### 6.4 Hot-spot signal → targeted fix

| Signal (`hints[].code` or field) | Typical cause | Targeted fix |
|---|---|---|
| `H_STRING_ALLOC_STORM` (`String` ≥ 45% of managed allocations) | substring copies, concatenation in loops, `to_string` round trips | slice with `StrView` (`s.view(a, b)`, `subview`, `trim`) instead of copying; build output with one `StringBuilder`; compare/parse on views or `code_unit_at` |
| `H_CONTAINER_GROW_CHURN` (container growth ≥ 30% of backing bytes) | `Array`/`Map`/`StringBuilder` growing from empty in hot code | pre-size with `Array::with_capacity(n)` / `StringBuilder::with_capacity(n)`; reuse a buffer across iterations (clear instead of re-create) |
| `H_HIGH_RC_TRAFFIC` (one function ≥ 25% of ≥ 100k RC ops; `target` names it) | passing/copying heap values through a hot function, small records boxed on the heap | make small immutable records `val struct`; pass values as plain (borrowed, non-`mut`) parameters, which bump no RC, instead of storing or re-wrapping them; hoist repeated field loads out of loops |
| `H_HIGH_ALLOCATOR_OVERHEAD` (`peak_reserved_bytes` ≥ 4 MiB and ≥ 2× live bytes) | large temporary containers, building everything then discarding | stream or process in chunks; reuse one large buffer; drop temporaries early; check with `--retained` who holds the peak |
| `H_HIGH_RUNTIME_MEM_CALLS` (allocator functions ≥ 20% of CPU samples) | allocation-heavy inner loop | re-sort with `pionc profile summary --sort alloc_bytes` and remove the top allocation sites (the rows above) |
| `H_LOW_SAMPLES` | workload too short | raise iterations / input size; do not act on other hints yet |
| `managed.inuse_bytes > 0` at exit | values kept alive in long-lived containers or cycles | re-run with `--retained`, inspect `by_type[]` for the type that stays live |

After each fix, repeat steps 4–5: `pionc profile diff` should show the targeted function in `improved` (and `summary.*.delta` moving the expected way), and the clean `pionc bench --compare` must show a real `improved` result before you claim a speedup.
