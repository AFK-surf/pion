# Pion Best Practices (For AI Agents)

Concise engineering rules for writing fast, race-free, maintainable Pion programs.

## 1. GUI / Invar Dual-Thread Architecture (`#render_thread`)

When building desktop, mobile, or web GUI apps with Invar, **strictly isolate the render thread from business logic and blocking IO**:

- Scaffold new apps with `pionc init --template invar-app <dir>` (produces `src/protocol.pion`, `src/worker.pion`, `src/view.pion`, `src/main.pion`, `main_test.pion`, `AGENTS.md`).
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

## 4. Agent Verification Loop

Always close the loop with structured CLI tools before reporting done:

```sh
pionc check --json <path>        # compact diagnostics with stable `code`, `fixit`, and machine-applicable `edits`
pionc query defs --json <path>   # inspect symbols/signatures across a package or workspace
pionc query callers --json <path># inspect call graph before refactoring
pionc fmt --check <path>         # verify canonical formatting
pionc test --json <path>         # run all tests in isolated parallel processes
```
