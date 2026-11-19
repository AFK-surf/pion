# Working on `m2` (for agents)

- `SPEC.md` is the authoritative architecture, grammar, runtime ABI, and JSON protocol spec. Keep code and `SPEC.md` strictly synchronized.
- **Never run heavy builds or tests on `Office-Host-2`**: run all `moon`, `clang`, `qbe`, `zig`, and test binaries via `station_task` on `tokyo-mac-studio-0` (`PATH="$HOME/.moon/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"`).
- **Zero `target/` or `_build/` inside source tree** for `m2c` outputs (only Stage 0 MoonBit build uses `moon`'s target dir inside the remote mirror, never committed to git).
- **Stage 0 ↔ Stage 1 intersection discipline**: Everything under `compiler/src/core/` MUST stay strictly within the `m2 ∩ MoonBit` subset defined in `SPEC.md` §2–3 so that `m2c0` compiles `compiler/src/core/` directly with zero rewrite.
- **No flaky tests, no sleeps**: Concurrency tests synchronize via `scope`/`Channel`/`AtomicInt`, never wall-clock sleeps.
- **Fast fail**: If a remote build/test command fails unexpectedly or a single step exceeds 10 minutes, stop immediately and return the raw log rather than blindly retrying.
