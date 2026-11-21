---
name: pion
description: Best practices and workflows for writing, checking, testing, and structuring Pion programs and Invar GUI applications (explicit World capabilities, structured concurrency, #render_thread isolation, and zero-allocation hot paths).
---

# Pion Language & Invar App Engineering Guide

Use this skill whenever writing, refactoring, debugging, or scaffolding code in `Pion` (`.pion` files, `pion.toml` packages, or `Invar` GUI apps).

## 1. Compiler-Driven Agent Loop

`pionc` is built for deterministic, structured CLI workflows. Always close every edit with:

```sh
pionc check --json <path>         # diagnostics with stable `code`, `fixit`, and machine-applicable `edits`
pionc query defs --json <path>    # inspect symbols & signatures across a file, package, or workspace
pionc query callers --json <path> # inspect call graph before refactoring
pionc fmt --check <path>          # verify canonical formatting (or `pionc fmt <path>`)
pionc test --json <path>          # run `test "..."` blocks in isolated parallel processes
```

- Every top-level `fn` and method requires explicit parameter types and return type (no cross-function inference).
- Apply `edits` from `pionc check --json` in reverse offset order when fixing mechanical errors (`E_UNHANDLED_RESULT`, `E_NON_EXHAUSTIVE`, `E_PRIVATE_SYMBOL`, etc.).

## 2. Explicit `World` Capability & Structured Concurrency

- **Pure by default**: functions without `world : World` cannot perform filesystem, process, network, clock, or sleep IO (`E_CAPABILITY_MISSING`). Keep pure logic `World`-free so it is trivially testable in `test "..."` blocks.
- **Native OS threads**: use `scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { ... }) })`.
- **Race-free communication**: pass immutable `Send` `struct`/`enum` messages over `Channel[T]`, wrap shared mutable containers (`Array`, `Map`) in `Mutex[T]`, or use `AtomicInt`. Synchronize tests with channels/atomics — never `sleep_ms`.
- Scaffold background services with `pionc init --template service <dir>`.

## 3. GUI / Invar Dual-Thread Hard Invariant (`#render_thread`)

When building any Invar desktop, mobile, or web application, **never run blocking IO, networking, SQLite, or heavy compute on the render thread**:

1. **Scaffold**: start with `pionc init --template invar-app <dir>` (`src/protocol.pion`, `src/worker.pion`, `src/view.pion`, `src/main.pion`, `main_test.pion`, `AGENTS.md`).
2. **Compile-time guardrail**: annotate every view builder and UI event entry point in `src/view.pion` with `#render_thread` (alias `#no_io`).
   - Any `World` parameter, `World` reference, `fs_*`/`tcp_*`/`proc_*`/`sleep_ms`/`io_*`, or `scope` call inside the function or any nested event-handler closure triggers `E_NO_IO_VIOLATION` (with no `world : World` insertion edit).
   - Non-`World` rendering `extern "C"` FFI, `Channel`, `Mutex`, `AtomicInt`, and pure UI state updates remain allowed.
   - **Never bypass `E_NO_IO_VIOLATION`** by removing `#render_thread` or threading `world : World` into the view. Add an `AppCmd` variant, execute it on the worker thread, and emit an `AppEvent`.
3. **Standard Split-Handle Wiring** (`ui::Worker::pair()` + `ui::wake_now()`):

```pion
// src/main.pion — dual-thread wiring with Invar's split-handle Worker API
pub fn main(world : World) -> Int {
  // Split into render-thread handle (`worker`) and Send-safe background context (`ctx`).
  // On wasm32 and deterministic `Tester` runs, swap for `ui::Worker::inline(...)`.
  let (worker, ctx) = ui::Worker::pair()

  // Registers `ui::on_before_frame` to zero-latency batch-drain `Mutex[Array[AppEvent]]`.
  worker.bind(fn(ev : AppEvent) -> Unit {
    apply_event(state, ev)
  })

  scope(world, fn(s : Scope) -> Unit {
    // Background OS thread owns `world`; `emit(ev)` queues into `Mutex[Array[AppEvent]]`
    // and wakes the UI runloop via `ui::wake_now()`.
    spawn(s, fn() -> Unit {
      ctx.run_loop(fn(cmd : AppCmd, emit : (AppEvent) -> Unit) -> Unit {
        match handle_cmd(world, cmd) {
          Some(ev) => emit(ev)
          None => ()
        }
      })
    })

    // Render thread: UI callbacks only call `worker.send(cmd)` and exit with `worker.close()`.
    run_invar_window(worker)
    worker.close()
  })
  0
}
```

## 4. Zero-Allocation Hot Paths & Scalarization

- Use `val struct` for small immutable value records (points, rects, colors, spans) so they stay unboxed without RC traffic.
- Reuse `StringBuilder` and pre-sized `Array` buffers instead of allocating temporary strings inside loops; index bytes directly via `str_code_at` / `code_unit_at`.
- Keep loop accumulators scalarized (`Int`, `Int64`, `Double`, `Float`) and hoist invariant lookups outside inner loops.
- Use `debug_assert(cond, msg)` for invariants — active in `pionc test`, stripped to 0 bytes in `pionc build --release`.
