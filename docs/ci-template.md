# Pion Ecosystem CI Standard Template

Every repository that builds or tests with Pion follows a single-job, fast-feedback CI standard:

- **Hard cap**: `timeout-minutes: 3` on every job.
- **Target**: `<= 60 s` wall clock per job, measured from `JOB_START_EPOCH` in step 1 and checked on `if: always()` in the final step (`::warning title=CI duration > 60s::...`).
- **Cache warming**: every workflow with `pull_request` MUST also trigger on default-branch `push` (e.g. `push: branches: [main]`) so PRs read warm caches instead of cold-bootstrapping on every run.
- **No job splitting or matrix sharding**: **NEVER** split a slow job into multiple jobs or add `strategy.matrix.shard` / `chunk` / `split` / `part` / `batch` to duck under the 3-minute cap. Splitting jobs saturates runner concurrency and causes long queues. Optimize inside the existing single job instead.

Validate any repository's workflows locally or in CI with:

```sh
sh scripts/check-ci-policy.sh
sh scripts/check-ci-policy.sh --self-test
```

---

## Standard Single-Job Workflow Template (Linux, macOS, Windows)

Copy and adapt this template for Pion repositories. Pin action SHAs and set `PION_REV` to the Pion commit/tag your repository builds against.

```yaml
name: ci

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

env:
  PION_REV: "<pinned-pion-sha-or-tag>"

jobs:
  linux:
    name: Linux x86_64
    runs-on: ubuntu-latest
    timeout-minutes: 3
    steps:
      - name: Record job start
        run: echo "JOB_START_EPOCH=$(date +%s)" >> "$GITHUB_ENV"

      - uses: actions/checkout@v4

      # Split restore + save avoids `actions/cache` `!` exclusions and lets us
      # skip checking out and bootstrapping Pion completely on a cache hit.
      - name: Restore Pion toolchain
        id: pion-toolchain
        uses: actions/cache/restore@v4
        with:
          path: ~/.cache/pion-toolchain
          key: pion-toolchain-linux-x86_64-${{ env.PION_REV }}

      - name: Build Pion toolchain (cache miss only)
        if: steps.pion-toolchain.outputs.cache-hit != 'true'
        run: |
          set -eu
          git clone --depth 1 https://github.com/AFK-surf/pion.git /tmp/pion-src
          git -C /tmp/pion-src fetch --depth 1 origin "$PION_REV"
          git -C /tmp/pion-src checkout --detach "$PION_REV"
          (cd /tmp/pion-src && sh scripts/build-release.sh)
          mkdir -p "$HOME/.cache/pion-toolchain/bin" "$HOME/.cache/pion-toolchain/lib"
          cp /tmp/pion-src/out/pionc_release "$HOME/.cache/pion-toolchain/bin/pionc"
          cp /tmp/pion-src/out/qbe "$HOME/.cache/pion-toolchain/bin/qbe"
          cp /tmp/pion-src/out/libpionrt.a "$HOME/.cache/pion-toolchain/lib/libpionrt.a"
          rm -rf /tmp/pion-src

      - name: Save Pion toolchain
        if: steps.pion-toolchain.outputs.cache-hit != 'true'
        uses: actions/cache/save@v4
        with:
          path: ~/.cache/pion-toolchain
          key: pion-toolchain-linux-x86_64-${{ env.PION_REV }}

      # Scope restore-keys strictly to the same PION_REV so stale ABI/SSA objects are never mixed.
      - name: Cache Pion CAS
        uses: actions/cache@v4
        with:
          path: ~/.cache/pion/cas
          key: pion-cas-linux-x86_64-${{ env.PION_REV }}-${{ hashFiles('pion.toml', 'src/**/*.pion') }}
          restore-keys: |
            pion-cas-linux-x86_64-${{ env.PION_REV }}-

      - name: Format, check, and test (single-runner multicore)
        run: |
          set -euo pipefail
          export PATH="$HOME/.cache/pion-toolchain/bin:$PATH"
          export PION_QBE="$HOME/.cache/pion-toolchain/bin/qbe"
          export PION_RT_LIB="$HOME/.cache/pion-toolchain/lib/libpionrt.a"
          export PION_CACHE_DIR="$HOME/.cache/pion/cas"

          # Run independent read-only checks concurrently on the runner's cores.
          # Capture command output before piping to grep so non-zero compiler exit codes are never masked.
          (
            set -euo pipefail
            OUT="$(pionc fmt --check --json)"
            printf '%s' "$OUT" | grep -q '"ok":true'
          ) &
          pid_fmt=$!
          (
            set -euo pipefail
            OUT="$(pionc check --json)"
            printf '%s' "$OUT" | grep -q '"ok":true'
          ) &
          pid_chk=$!

          rc=0
          wait "$pid_fmt" || rc=1
          wait "$pid_chk" || rc=1
          if [ "$rc" -ne 0 ]; then
            exit "$rc"
          fi

          OUT="$(pionc test --json)"
          printf '%s\n' "$OUT"
          printf '%s' "$OUT" | grep -q '"ok":true'
          printf '%s' "$OUT" | grep -q '"failed":0'

      - name: Check 60s duration target
        if: always()
        run: |
          ELAPSED=$(( $(date +%s) - JOB_START_EPOCH ))
          echo "Job linux duration: ${ELAPSED}s"
          if [ "$ELAPSED" -gt 60 ]; then
            echo "::warning title=CI duration > 60s::linux took ${ELAPSED}s (target <= 60s, hard timeout 180s)"
          fi

  macos:
    name: macOS ARM64
    runs-on: macos-15
    timeout-minutes: 3
    steps:
      - name: Record job start
        run: echo "JOB_START_EPOCH=$(date +%s)" >> "$GITHUB_ENV"

      - uses: actions/checkout@v4

      - name: Restore Pion toolchain
        id: pion-toolchain
        uses: actions/cache/restore@v4
        with:
          path: ~/.cache/pion-toolchain
          key: pion-toolchain-darwin-arm64-${{ env.PION_REV }}

      - name: Build Pion toolchain (cache miss only)
        if: steps.pion-toolchain.outputs.cache-hit != 'true'
        run: |
          set -eu
          git clone --depth 1 https://github.com/AFK-surf/pion.git /tmp/pion-src
          git -C /tmp/pion-src fetch --depth 1 origin "$PION_REV"
          git -C /tmp/pion-src checkout --detach "$PION_REV"
          (cd /tmp/pion-src && sh scripts/build-release.sh)
          mkdir -p "$HOME/.cache/pion-toolchain/bin" "$HOME/.cache/pion-toolchain/lib"
          cp /tmp/pion-src/out/pionc_release "$HOME/.cache/pion-toolchain/bin/pionc"
          cp /tmp/pion-src/out/qbe "$HOME/.cache/pion-toolchain/bin/qbe"
          cp /tmp/pion-src/out/libpionrt.a "$HOME/.cache/pion-toolchain/lib/libpionrt.a"
          rm -rf /tmp/pion-src

      - name: Save Pion toolchain
        if: steps.pion-toolchain.outputs.cache-hit != 'true'
        uses: actions/cache/save@v4
        with:
          path: ~/.cache/pion-toolchain
          key: pion-toolchain-darwin-arm64-${{ env.PION_REV }}

      - name: Cache Pion CAS
        uses: actions/cache@v4
        with:
          path: ~/.cache/pion/cas
          key: pion-cas-darwin-arm64-${{ env.PION_REV }}-${{ hashFiles('pion.toml', 'src/**/*.pion') }}
          restore-keys: |
            pion-cas-darwin-arm64-${{ env.PION_REV }}-

      - name: Check and test
        run: |
          set -euo pipefail
          export PATH="$HOME/.cache/pion-toolchain/bin:$PATH"
          export PION_QBE="$HOME/.cache/pion-toolchain/bin/qbe"
          export PION_RT_LIB="$HOME/.cache/pion-toolchain/lib/libpionrt.a"
          export PION_CACHE_DIR="$HOME/.cache/pion/cas"
          CHK="$(pionc check --json)"
          printf '%s' "$CHK" | grep -q '"ok":true'
          OUT="$(pionc test --json)"
          printf '%s\n' "$OUT"
          printf '%s' "$OUT" | grep -q '"ok":true'
          printf '%s' "$OUT" | grep -q '"failed":0'

      - name: Check 60s duration target
        if: always()
        run: |
          ELAPSED=$(( $(date +%s) - JOB_START_EPOCH ))
          echo "Job macos duration: ${ELAPSED}s"
          if [ "$ELAPSED" -gt 60 ]; then
            echo "::warning title=CI duration > 60s::macos took ${ELAPSED}s (target <= 60s, hard timeout 180s)"
          fi

  windows:
    name: Windows x86_64
    runs-on: windows-latest
    timeout-minutes: 3
    defaults:
      run:
        shell: msys2 {0}
    steps:
      - name: Record job start
        shell: pwsh
        run: |
          $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
          "JOB_START_EPOCH=$epoch" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append

      - uses: actions/checkout@v4

      - name: Restore Pion toolchain
        id: pion-toolchain
        uses: actions/cache/restore@v4
        with:
          path: ~/.cache/pion-toolchain
          key: pion-toolchain-windows-x86_64-${{ env.PION_REV }}

      - uses: msys2/setup-msys2@v2
        with:
          msystem: UCRT64
          update: false
          cache: true
          install: >-
            mingw-w64-ucrt-x86_64-gcc
            gzip
            diffutils

      - name: Build Pion toolchain (cache miss only)
        if: steps.pion-toolchain.outputs.cache-hit != 'true'
        run: |
          set -eu
          git clone --depth 1 https://github.com/AFK-surf/pion.git /tmp/pion-src
          git -C /tmp/pion-src fetch --depth 1 origin "$PION_REV"
          git -C /tmp/pion-src checkout --detach "$PION_REV"
          (cd /tmp/pion-src && sh scripts/build-release.sh)
          mkdir -p "$HOME/.cache/pion-toolchain/bin" "$HOME/.cache/pion-toolchain/lib"
          cp /tmp/pion-src/out/pionc_release.exe "$HOME/.cache/pion-toolchain/bin/pionc.exe"
          cp /tmp/pion-src/out/qbe.exe "$HOME/.cache/pion-toolchain/bin/qbe.exe"
          cp /tmp/pion-src/out/libpionrt.a "$HOME/.cache/pion-toolchain/lib/libpionrt.a"
          rm -rf /tmp/pion-src

      - name: Save Pion toolchain
        if: steps.pion-toolchain.outputs.cache-hit != 'true'
        uses: actions/cache/save@v4
        with:
          path: ~/.cache/pion-toolchain
          key: pion-toolchain-windows-x86_64-${{ env.PION_REV }}

      - name: Cache Pion CAS
        uses: actions/cache@v4
        with:
          path: ~/.cache/pion/cas
          key: pion-cas-windows-x86_64-${{ env.PION_REV }}-${{ hashFiles('pion.toml', 'src/**/*.pion') }}
          restore-keys: |
            pion-cas-windows-x86_64-${{ env.PION_REV }}-

      - name: Check and test
        run: |
          set -euo pipefail
          export PATH="$HOME/.cache/pion-toolchain/bin:$PATH"
          export PION_QBE="$HOME/.cache/pion-toolchain/bin/qbe.exe"
          export PION_RT_LIB="$HOME/.cache/pion-toolchain/lib/libpionrt.a"
          export PION_CACHE_DIR="$HOME/.cache/pion/cas"
          CHK="$(pionc.exe check --json)"
          printf '%s' "$CHK" | grep -q '"ok":true'
          OUT="$(pionc.exe test --json)"
          printf '%s\n' "$OUT"
          printf '%s' "$OUT" | grep -q '"ok":true'
          printf '%s' "$OUT" | grep -q '"failed":0'

      - name: Check 60s duration target
        if: always()
        shell: pwsh
        run: |
          $elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$env:JOB_START_EPOCH
          Write-Host "Job windows duration: ${elapsed}s"
          if ($elapsed -gt 60) {
            Write-Host "::warning title=CI duration > 60s::windows took ${elapsed}s (target <= 60s, hard timeout 180s)"
          }
```

---

## Release Exception: External Apple `notarytool` Wait

Only release jobs that wait on external Apple notarization (`xcrun notarytool submit --wait`) may relax the job-level timeout on tag/dispatch runs. Because `scripts/check-ci-policy.sh` enforces integer `timeout-minutes <= 3` on every job by default, explicitly opt in that audited job with `--allow-notarize-timeout <workflow>:<job>`. Even with the allowlist flag, every non-tag/dispatch-gated `run:` step (excluding the first/last timing steps) MUST explicitly set `timeout-minutes: 3`, and at least one `run:` step MUST be gated on tag/`workflow_dispatch`:

```yaml
  macos-release:
    runs-on: macos-15
    timeout-minutes: ${{ (github.event_name == 'workflow_dispatch' || startsWith(github.ref, 'refs/tags/')) && 15 || 3 }}
    steps:
      - name: Record job start
        run: echo "JOB_START_EPOCH=$(date +%s)" >> "$GITHUB_ENV"
      - name: Build and test
        timeout-minutes: 3
        run: sh scripts/build-release.sh
      - name: Notarize (tags only)
        if: startsWith(github.ref, 'refs/tags/')
        run: xcrun notarytool submit ... --wait
      - name: Check 60s duration target
        if: always()
        run: |
          ELAPSED=$(( $(date +%s) - JOB_START_EPOCH ))
          if [ "$ELAPSED" -gt 60 ]; then
            echo "::warning title=CI duration > 60s::macos-release took ${ELAPSED}s"
          fi
```

Validate with:

```sh
sh scripts/check-ci-policy.sh --allow-notarize-timeout release.yml:macos-release
```

---

## Single-Runner Multicore Parallelism Guidelines

- Use bounded parallelism (`min(usable_cpus, 8)`) inside the existing single job instead of splitting jobs.
- Eliminate duplicate work: do not run full-repo `pionc check` / `pionc test` twice, do not rebuild `--release` binaries inside packaging scripts (pass `--prebuilt-dir`), and skip toolchain checkout/bootstrap on cache hit.
- Include `PION_REV`, all transitive dependency/submodule gitlink SHAs, and source content hashes in the `PION_CACHE_DIR` cache key; keep `restore-keys` strictly prefixed by `PION_REV`.

---

## Common Anti-Patterns (Rejected by `scripts/check-ci-policy.sh` or CI Reviews)

| Anti-pattern | Why it breaks | Correct pattern |
|---|---|---|
| Splitting jobs or adding `strategy.matrix.shard` / `chunk` / `split` / `part` / `batch` | Saturates runner concurrency and causes long queues | Optimize inside the single job (CAS cache, split toolchain cache, multicore parallelism) |
| Missing `push: branches: [main]` alongside `pull_request` | `actions/cache` on PRs cannot read caches from other PRs, causing cold bootstraps on every run | Always trigger on default-branch `push` as well as `pull_request` |
| Raising `timeout-minutes` above `3` | Hides regressions instead of fixing them | Keep `timeout-minutes: 3` (only external `notarytool` tag runs may use `${{ ... || 3 }}` with step-level `timeout-minutes: 3`) |
| `actions/cache` `path:` with `!subdir` negation | `!` exclusions fail during `tar` archive creation | List explicit paths, or split into `actions/cache/restore@v4` + `actions/cache/save@v4` |
| `pionc check --json \| grep -q '"ok":true'` without `pipefail` | If `pionc` prints matching JSON and exits non-zero, `grep` still exits `0` and masks the failure | Use `set -euo pipefail` and capture output first: `OUT="$(pionc check --json)"` then `printf '%s' "$OUT" \| grep -q '"ok":true'` |
| `{ cmd1; cmd2; } \|\| rc=1` under `set -e` | Compound commands on the LHS of `\|\|` disable `set -e` for every inner command, silently hiding `cmd1` failures | Run each parallel branch in its own fail-fast subshell `( set -euo pipefail; cmd1; cmd2 ) &` and check `wait "$pid" \|\| rc=1` |
| Ending a `run:` block with `[ -n "$pid" ] && wait "$pid"` | When the `[ ... ]` condition is false, it is the last command and exits with status `1` | Write `if [ -n "$pid" ]; then wait "$pid"; fi` |
| `xargs` worker exiting `1` on failure | `xargs` keeps dispatching remaining tasks after a failure | Exit `255` inside the worker to stop `xargs` immediately |
| Running code generators concurrently with `pionc fmt --check` | Race condition reading/writing the same `.pion` files | Run codegen before `fmt --check`, never in parallel with it |
