# `m2` Language & Self-Hosting Compiler Specification (v0.1 Bootstrap)

`m2` is an Agent-friendly, C-speed, fast-compiling, memory-safe, natively multithreaded systems programming language whose core syntax is a clean, strict subset/evolution of MoonBit.

This spec is the **single source of truth** shared by `runtime/`, `vendor/qbe/`, and `compiler/`. Any change to ABI, runtime symbols, grammar, or JSON schema must update this file in the same commit.

---

## 1. Design Pillars

1. **Zero Cross-Function Inference (Gojo rule)**: Every top-level `fn` and method MUST declare explicit parameter types and return type. Local `let` bindings infer types within the function body only. No macros, no `comptime`, no higher-kinded types.
2. **Second-Class References & Biased RC (Gojo + Koka/Lean 4)**:
   - No Rust-style `<'a>` lifetime annotations.
   - Heap objects (strings, bytes, arrays, maps, structs, enums, closures) use **Biased Reference Counting**: non-atomic `local_rc` on the owning thread (zero atomic overhead in single-threaded code), transparently promoted to atomic `shared_rc` when frozen/shared across threads.
   - Borrowed function parameters do not bump RC on entry/exit (Perceus-lite borrow elision).
   - **Perceus-lite last-use early drop**: top-level immutable owned heap locals in a straight-line statement block are released immediately after their last syntactic mention (`m2_rc_dec` + slot zeroing) when not pinned by a borrowed array-element view, reclaiming large temporaries before subsequent allocations.
3. **Compile-Time Data-Race-Free Multithreading**:
   - Native OS threads via structured concurrency (`scope` + `spawn`), `Channel[T]`, `Mutex[T]`, `AtomicInt`.
   - Every type is statically classified as `Send` or `!Send`:
     - Primitives (`Int`, `Int64`, `Double`, `Bool`, `Byte`, `Unit`), `String`, `Channel[T]` (where `T: Send`), `Mutex[T]` (where `T: Send`), `AtomicInt`, and immutable `struct`/`enum` (no `mut` fields, all fields `Send`) are `Send`.
     - Any `struct` with `mut` fields, `Array[T]`, `Bytes`, `Map[K, V]` are `!Send` by default (must be wrapped in `Mutex[T]` or explicitly transferred via `move` with single-function linear check).
     - Capturing a non-`Send` variable in `spawn` or sending a non-`Send` value over `Channel[T]` is a compile-time error (`E_NOT_SEND`).
4. **Explicit Capability (`World`, Vercel Zero rule)**:
   - Pure functions cannot perform IO, read wall clock, spawn OS processes, or touch the filesystem unless a `World` (or sub-capability) parameter is explicitly in scope.
   - Entry point: `pub fn main(world : World) -> Int` (or `fn main() -> Unit` in pure test mode). Calling IO builtins (`io_println`, `fs_read`, `fs_write`, `clock_now_ms`, `proc_exec`, `env_get`, `args_get`) without a `World` value in scope is a compile-time error (`E_CAPABILITY_MISSING`).
5. **Agent-First Compiler Interface**:
   - `m2c check --json <path>` — compact JSON diagnostics (`file`, `line`, `col`, `code`, `message`, `expected`, `found`, `fixit`), one object per diagnostic inside `{"ok":bool,"diagnostics":[...]}`.
   - `m2c query defs|sig|callers|deps --json <path>` — structured symbol table, exported signatures, call graph, and package dependency graph.
   - Contracts: `debug_assert(cond, msg)` — active in dev/test builds, stripped to 0 bytes in `--release`.
6. **Sub-150ms Incremental Compile, Tiny Binaries, Zero `target/`**:
   - Package-level separate compilation via `.m2sig` compact interface files: editing a function body without changing its `pub` signature yields 100% cache hit on downstream packages.
   - **Global Content-Addressed Cache** (`$M2_CACHE_DIR`, default `~/.cache/m2/cas`), LRU-evicted (`$M2_CACHE_MAX_MB`, default 2048). **NEVER writes a `target/` or `_build/` directory inside the source tree.**
   - **Dev backend**: emits per-package **QBE IL** → vendored `qbe` → system `as` + `ld` + prebuilt `<40 KB` `libm2rt.a`. Zero `clang` C-parsing overhead!
   - **Release backend** (`--release`): emits clean per-package C or LLVM IR compiled with `-O2`, stripping `debug_assert`.

---

## 2. Bootstrap Subset (`m2 ∩ MoonBit`) & Self-Hosting Strategy

To achieve **zero-rewrite Stage 0 → Stage 1 → Stage 2 fixed-point self-hosting**:

```
compiler/
  moon.mod                 # Stage 0 MoonBit module definition (moon 0.1.20261117+)
  src/
    core/                  # PURE m2 ∩ MoonBit compiler core (shared by Stage 0 & Stage 1!)
      lexer.mbt
      ast.mbt
      parser.mbt
      sig.mbt              # .m2sig serializer/deserializer
      types.mbt            # Type checker + exhaustive match + Send + World capability
      ir.mbt               # Typed MIR/SSA + Perceus-lite RC insertion
      qbe.mbt              # QBE IL emitter (arm64_apple & amd64_sysv)
      cas.mbt              # Global CAS hashing & LRU cache manager
      diag.mbt             # JSON diagnostics & query engine
      driver.mbt           # Package graph + compile pipeline
    compat_moon/           # Thin Stage 0 adapter (~150 LOC, MoonBit extern "C" host IO)
    compat_m2/             # Thin Stage 1 adapter (~150 LOC, m2 World + parallel scope/spawn)
```

- **Stage 0 (`m2c0`)**: `moon build --target native --release` compiles `src/core` + `src/compat_moon` → `m2c0`.
- **Stage 1 (`m2c1`)**: `m2c0 build` compiles `src/core` + `src/compat_m2` → `m2c1` (native binary backed by `runtime/libm2rt.a` + QBE!).
- **Stage 2 (`m2c2`)**: `m2c1 build` compiles `src/core` + `src/compat_m2` → `m2c2` (using `m2`'s own native multithreaded package compilation!).
- **Fixed-Point Proof**: QBE IL & assembly emitted by `m2c1` vs `m2c2` for `m2c` itself MUST be **bit-for-bit identical** (SHA-256 match).

---

## 3. Core Language Grammar (v0.1 Bootstrap)

Every construct below is valid in BOTH MoonBit (with thin helper aliases where needed) AND `m2`:

### 3.1 Lexical Elements
- Comments: `// line comment` (including `///|` MoonBit block separators ignored as comments).
- Identifiers: `[a-zA-Z_][a-zA-Z0-9_]*`
- Literals:
  - `Int`: decimal `42`, hex `0xFF`, negative `-1`
  - `Int64`: `42L`
  - `Double`: `3.14`
  - `Bool`: `true`, `false`
  - `Byte`: `b'a'`, `b'\n'`, `b'\x00'`
  - `Char`: `'a'`, `'\n'`
  - `String`: `"..."` with escapes `\n`, `\r`, `\t`, `\\`, `\"`, `\0`
- Keywords: `fn`, `pub`, `struct`, `enum`, `let`, `mut`, `if`, `else`, `match`, `while`, `for`, `in`, `break`, `continue`, `return`, `true`, `false`, `as`, `val`, `move`, `scope`, `spawn`, `debug_assert`, `type`, `import` (and contextual top-level `test`).

### 3.2 Top-Level Declarations
```
import "pkg_name" [as alias]

[pub] [val] struct Name[T1, T2] {
  [mut] field1 : Type1
  field2 : Type2
}

[pub] enum Name[T1, T2] {
  Variant0
  Variant1(Type1, Type2)
}

[pub] fn name[T1](p1 : Type1, p2 : Type2) -> RetType {
  ...
}

[pub] fn TypeName::method(self : TypeName, p1 : Type1) -> RetType {
  ...
}

[pub] let CONST_NAME : Type = expr

test "test name" {
  ...
}
```
- Optional trailing commas and optional semicolons (newline-terminated statements, matching MoonBit).
- `pub` marks items exported in `.m2sig` and accessible from downstream packages via `alias::symbol`. Referencing a non-`pub` symbol from an imported package is a compile-time error (`E_PRIVATE_SYMBOL`).
- `val struct` asserts at compile time that the struct has zero `mut` fields and every field is `Send`.
- `test "name" { ... }` blocks are type-checked by `m2c check`, omitted (0 bytes) by `m2c build`, and compiled with active `debug_assert` by `m2c test [--json] [--filter <substr>] <path>`.

### 3.3 Statements & Expressions
- `let x = expr` / `let x : Type = expr` / `let mut x = expr`
- Assignment: `x = expr`, `obj.field = expr`, `arr[i] = expr`
- Control flow:
  - `if cond { ... } else if cond2 { ... } else { ... }` (expression when all branches yield same type)
  - `while cond { ... }`
  - `for i = 0; i < n; i = i + 1 { ... }`
  - `match scrutinee { Pat => expr, ... }` (exhaustive checking required on `enum`, `Bool`, `Option`, `Result`; wildcard `_` allowed)
  - `return [expr]`, `break`, `continue`
- Closures: `fn(x : T) -> R { ... }` (captures by value / biased RC; inside `spawn(...)`, only `Send` or `move` captures allowed)
- Concurrency (m2 native):
  - `scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { ... }) })`
  - `Channel::new(cap)`, `ch.send(v)`, `ch.recv() -> Option[T]`, `ch.close()`
  - `Mutex::new(v)`, `m.with_lock(fn(v : T) -> R { ... })` / `m.lock()` + `m.set(v)` + `m.unlock()`
  - `AtomicInt::new(v)`, `a.load()`, `a.store(v)`, `a.fetch_add(d)`
- Contracts: `debug_assert(cond, "msg")`
- Operators: `+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`, `&`, `|`, `^`, `<<`, `>>`, unary `-`.

---

## 4. Runtime ABI & Memory Layout (`runtime/m2_rt.h` & `runtime/m2_rt.c`)

**All values passed across QBE IL / C ABI use uniform 64-bit slots (`l` in QBE, `int64_t` in C)** for Shape Polymorphism:
- `Int` (`i32`): sign-extended in 64-bit register (or `w` locally, `l` across generic boundaries).
- `Int64`: `int64_t` (`l`).
- `Double`: IEEE-754 bit-cast (`double` / `d`, boxed to `int64_t` bits in generic slots).
- `Bool` / `Byte` / `Char`: zero-extended in 64-bit slot (`0`/`1`, `0..255`, Unicode scalar).
- `Unit`: `0`.
- All heap objects (`String`, `Bytes`, `Array`, `Map`, `struct`, `enum`, `Closure`, `Channel`, `Mutex`, `AtomicInt`): `M2Obj*` (64-bit pointer, `l` in QBE).

### 4.1 Object Header (24 bytes, 8-byte aligned)
```c
typedef void (*M2DropFn)(void *payload);

typedef struct M2Header {
    uint64_t owner_tid;        // Thread ID of creator; 0 = FROZEN/SHARED (atomic mode)
    uint32_t local_rc;         // Non-atomic RC used while owner_tid == current_tid
    _Atomic uint32_t shared_rc;// Atomic RC used once owner_tid == 0 (or cross-thread dec)
    uint16_t type_tag;         // M2Tag (String=1, Bytes=2, Array=3, Struct=4, Enum=5, Closure=6, Map=7, Channel=8, Mutex=9, Atomic=10)
    uint16_t flags;            // bit 0: M2_FLAG_FROZEN, bit 1: M2_FLAG_IMMORTAL (static .rodata literals!)
    uint32_t payload_size;     // Byte size of payload
    M2DropFn drop_fn;          // Nullable destructor for releasing child pointers
} M2Header;                    // Total: 32 bytes (clean 8-byte alignment on arm64/x64)
```
Payload immediately follows `M2Header`: `void* obj = (char*)hdr + sizeof(M2Header)`.
Header recovery: `M2Header* hdr = ((M2Header*)obj) - 1`.

**Immortal static strings** (`.rodata` string literals): `flags = M2_FLAG_IMMORTAL | M2_FLAG_FROZEN`, `owner_tid = 0`. `m2_rc_inc` / `m2_rc_dec` return immediately in 1 branch — **ZERO heap allocation and ZERO `init` code for string literals!**

### 4.2 Required Runtime C ABI Functions (`m2_rt.h`)
All symbols use `m2_` prefix and C calling convention (`arm64_apple` / `amd64_sysv`):

**Memory & Biased RC:**
- `void* m2_alloc(uint32_t payload_size, uint16_t type_tag, M2DropFn drop_fn);`
- `void  m2_rc_inc(void *obj);` (no-op if NULL or `M2_FLAG_IMMORTAL`; fast non-atomic if `owner_tid == m2_cur_tid()`, else atomic)
- `void  m2_rc_dec(void *obj);` (no-op if NULL or `M2_FLAG_IMMORTAL`; frees + calls `drop_fn` when total RC hits 0)
- `void  m2_rc_freeze(void *obj);` (promotes `owner_tid` to 0 and moves `local_rc` into `shared_rc` before crossing thread boundary)
- `void  m2_panic(const char *msg, const char *file, int32_t line);` (prints concise diagnostic to stderr and `abort()`/`_exit(1)`)
- `void  m2_debug_assert(int32_t cond, void *msg_str, const char *file, int32_t line);`

**Math (`Double`):**
- `double  m2_math_sqrt(double x);` (compiler builtin `math_sqrt`)
- `double  m2_math_abs(double x);` (compiler builtin `math_abs`)
- `double  m2_math_floor(double x);` (compiler builtin `math_floor`)
- `double  m2_math_ceil(double x);` (compiler builtin `math_ceil`)
- `double  m2_math_sin(double x);` (compiler builtin `math_sin`)
- `double  m2_math_cos(double x);` (compiler builtin `math_cos`)
- `double  m2_math_pow(double x, double y);` (compiler builtin `math_pow`)

**String (`M2String`: `{ int64_t len; char data[]; }` UTF-8, NUL-terminated):**
- `void*   m2_str_from_cstr(const char *s, int64_t len);`
- `int64_t m2_str_len(void *s);`
- `int32_t m2_str_byte_at(void *s, int64_t idx);`
- `void*   m2_str_concat(void *a, void *b);`
- `int32_t m2_str_eq(void *a, void *b);`
- `int32_t m2_str_cmp(void *a, void *b);`
- `void*   m2_str_slice(void *s, int64_t start, int64_t end);`
- `void*   m2_int_to_str(int64_t v);`
- `int64_t m2_str_to_int(void *s, int32_t *ok_out);`
- `int32_t m2_str_starts_with(void *s, void *prefix);` (`s.starts_with(prefix) -> Bool`)
- `int32_t m2_str_ends_with(void *s, void *suffix);` (`s.ends_with(suffix) -> Bool`)
- `int32_t m2_str_contains(void *s, void *needle);` (`s.contains(needle) -> Bool`)
- `int64_t m2_str_index_of(void *s, void *needle);` (`s.index_of(needle) -> Int`)
- `void*   m2_str_trim(void *s);` (`s.trim() -> String`)
- `void*   m2_str_split(void *s, void *sep);` (`s.split(sep) -> Array[String]`)
- `void*   m2_str_replace(void *s, void *from, void *to);` (`s.replace(from, to) -> String`)
- `void*   m2_str_to_bytes(void *s);` (`s.to_bytes() -> Bytes`)

**Bytes (`M2Bytes`: `{ int64_t len; int64_t cap; uint8_t *data; }` — mutable `!Send` heap byte buffer):**
- `void*   m2_bytes_new(int64_t len);` (`Bytes::new(len) -> Bytes`)
- `int64_t m2_bytes_len(void *b);` (`b.length() -> Int`)
- `int32_t m2_bytes_get(void *b, int64_t idx);` (`b[i] -> Byte`, bounds-checked)
- `void    m2_bytes_set(void *b, int64_t idx, int32_t val);` (`b[i] = val` where `val : Byte`, bounds-checked)
- `void*   m2_bytes_slice(void *b, int64_t start, int64_t end);` (`b.slice(start, end) -> Bytes`)
- `void*   m2_bytes_concat(void *a, void *b);` (`b.concat(other) -> Bytes`)
- `void*   m2_bytes_to_str(void *b);` (`b.to_string() -> String`)

**StringBuilder (`M2StrBuf`):**
- `void* m2_strbuf_new(int64_t cap);`
- `void  m2_strbuf_push_str(void *sb, void *s);`
- `void  m2_strbuf_push_byte(void *sb, int32_t b);`
- `void  m2_strbuf_push_char(void *sb, int32_t cp);`
- `void  m2_strbuf_push_int(void *sb, int64_t v);`
- `void  m2_strbuf_reset(void *sb);`
- `void* m2_strbuf_to_str(void *sb);`

**Array (`M2Array`: `{ int64_t len; int64_t cap; int32_t elem_is_obj; int64_t *data; }` — uniform 64-bit slots!):**
- `void*   m2_arr_new(int64_t cap, int32_t elem_is_obj);`
- `int64_t m2_arr_len(void *a);`
- `void    m2_arr_push(void *a, int64_t val);` (retains if `elem_is_obj`)
- `int64_t m2_arr_get(void *a, int64_t idx);` (bounds-checked!)
- `void    m2_arr_set(void *a, int64_t idx, int64_t val);` (bounds-checked; retains new, releases old if `elem_is_obj`)
- `int64_t m2_arr_pop(void *a);`
- `void*   m2_arr_copy(void *a);`

**String-Keyed Hash Map (`M2Map` — open addressing FNV-1a, 64-bit value slots):**
- `void*   m2_map_new(int32_t val_is_obj);`
- `int64_t m2_map_len(void *m);`
- `void    m2_map_set(void *m, void *key_str, int64_t val);`
- `int32_t m2_map_has(void *m, void *key_str);`
- `int64_t m2_map_get(void *m, void *key_str);` (panics if missing; compiler pairs with `has` or returns Option)
- `void    m2_map_remove(void *m, void *key_str);`
- `void*   m2_map_copy(void *m);`
- `void*   m2_map_keys(void *m);` (returns `M2Array` of `M2String*`)

**Concurrency (`pthread` backed, race-free):**
- `void*   m2_scope_begin(void);`
- `void    m2_scope_spawn(void *scope, void (*fn)(void *env), void *env);` (`env` is frozen & retained before pthread launch, released after `fn` returns)
- `void    m2_scope_end(void *scope);` (joins all spawned threads deterministically before returning!)
- `void*   m2_chan_new(int64_t cap, int32_t elem_is_obj);`
- `int32_t m2_chan_send(void *ch, int64_t val);` (returns 1 if sent, 0 if closed; freezes obj before enqueue)
- `int32_t m2_chan_recv(void *ch, int64_t *out_val);` (returns 1 if received, 0 if closed & empty)
- `void    m2_chan_close(void *ch);`
- `void*   m2_mutex_new(int64_t init_val, int32_t val_is_obj);`
- `int64_t m2_mutex_lock(void *m);`
- `void    m2_mutex_set(void *m, int64_t new_val);`
- `void    m2_mutex_set_and_unlock(void *m, int64_t new_val);`
- `void    m2_mutex_unlock(void *m);`
- `void*   m2_atomic_new(int64_t init_val);`
- `int64_t m2_atomic_load(void *a);`
- `void    m2_atomic_store(void *a, int64_t val);`
- `int64_t m2_atomic_fetch_add(void *a, int64_t delta);`

**World Capabilities (passed via `M2World*`):**
- `void*   m2_world_init(int argc, char **argv);`
- `int64_t m2_world_argc(void *w);`
- `void*   m2_world_argv(void *w, int64_t idx);`
- `void*   m2_world_args(void *w);`
- `void    m2_world_print(void *w, void *s);`
- `void    m2_world_println(void *w, void *s);`
- `void    m2_world_eprintln(void *w, void *s);`
- `void*   m2_world_fs_read(void *w, void *path_str, int32_t *ok_out);` (`fs_read -> Result[String, String]`)
- `int32_t m2_world_fs_write(void *w, void *path_str, void *content_str);` (`fs_write -> Result[Unit, String]`)
- `void*   m2_world_fs_read_bytes(void *w, void *path_str, int32_t *ok_out);` (`fs_read_bytes -> Result[Bytes, String]`)
- `int32_t m2_world_fs_write_bytes(void *w, void *path_str, void *bytes_obj);` (`fs_write_bytes -> Result[Unit, String]`)
- `int32_t m2_world_fs_append(void *w, void *path_str, void *content_str);` (`fs_append -> Result[Unit, String]`)
- `int64_t m2_world_fs_mtime_ms(void *w, void *path_str);` (`fs_mtime_ms -> Int64`, `-1` if missing)
- `int32_t m2_world_fs_exists(void *w, void *path_str);`
- `int32_t m2_world_fs_is_dir(void *w, void *path_str);`
- `int32_t m2_world_fs_mkdir_p(void *w, void *path_str);`
- `void*   m2_world_fs_list_dir(void *w, void *path_str);` (MUST return entries sorted lexicographically for deterministic builds!)
- `int32_t m2_world_fs_remove(void *w, void *path_str);` (for CAS LRU eviction; returns 1 on success)
- `int32_t m2_world_fs_rename(void *w, void *old_path, void *new_path);` (for atomic concurrent CAS writes; returns 1 on success)
- `int64_t m2_world_fs_size(void *w, void *path_str);` (file size in bytes, or -1 if missing)
- `void*   m2_world_env_get(void *w, void *name_str, int32_t *ok_out);`
- `int64_t m2_world_clock_ms(void *w);`
- `int32_t m2_world_exec(void *w, void *argv_arr);` (fork/execvp waitpid, returns exit code)
- `void*   m2_world_exec_capture(void *w, void *argv_arr, int32_t *exit_code_out);` (`proc_exec_capture -> Result[String, String]`; `Ok(stdout)` if exit code == 0, else `Err("exit <code>: <stdout>")`)
- `void*   m2_sha256_hex(void *s);` (pure SHA-256 hex digest for CAS cache keys!)

---

## 5. Agent JSON Protocols

### 5.1 `m2c check --json <path>`
```json
{
  "ok": false,
  "diagnostics": [
    {
      "file": "src/app.m2",
      "line": 12,
      "col": 5,
      "code": "E_NOT_SEND",
      "message": "cannot capture mutable non-Send value `counter` inside `spawn`",
      "expected": "Send",
      "found": "MutBox",
      "fixit": "wrap `counter` in `Mutex::new(...)` or `AtomicInt::new(...)`"
    }
  ]
}
```

### 5.2 `m2c query <kind> --json <path>`
- `defs`: `{"defs":[{"pkg":"...","name":"...","kind":"fn|struct|enum","pub":true,"file":"...","line":10,"sig":"..."}]}`
- `sig`: compact `.m2sig` export table in JSON
- `callers`: `{"callers":[{"fn":"...","calls":["..."]}]}`
- `deps`: `{"packages":[{"name":"...","deps":["..."],"sig_hash":"..."}]}`

### 5.3 `m2c test [--json] [--filter <substr>] <path>`
- Runs all `test "name" { ... }` blocks in isolated child processes (active `debug_assert`, binary stored in `$M2_CACHE_DIR/bin/`).
- JSON output: `{"ok":bool,"passed":N,"failed":M,"tests":[{"name":"...","ok":bool}]}`
- Additional diagnostic codes:
  - `E_PRIVATE_SYMBOL`: accessing a non-`pub` function, struct, enum, method, or constant from an imported package.
  - `E_IMPORT_CYCLE`: cyclic package dependency detected across `m2.toml` manifests.
  - `E_UNKNOWN_PACKAGE`: importing or depending on an undeclared package.

---

## 6. Global Content-Addressed Cache (CAS) & `m2.toml` Contract

- **Package Manifest (`m2.toml`)**:
  ```toml
  [package]
  name = "app"
  version = "0.1.0"

  [dependencies]
  math = { path = "../math" }
  ```
- **Cross-Package Incremental Isolation**: Downstream package CAS keys depend ONLY on upstream packages' `pub` `.m2sig` SHA-256 hashes (never upstream function bodies). Editing an upstream function body without changing its `pub` `.m2sig` yields 100% CAS hit on downstream `.o` files.
- **Compiler Fingerprint**: Every CAS key (`cas_compute_key`, `cas_compute_unit_key`) and `.usig` cache prefix includes `compiler_fp = sha256(M2_COMPILER_ABI_REV | qbe_size | libm2rt_size | M2_CACHE_SALT)`, ensuring compiler/backend upgrades automatically invalidate stale cache entries.
- Default directory: `$M2_CACHE_DIR` or `$HOME/.cache/m2/cas`
- Layout:
  - `sig/<sha256>.m2sig`
  - `ssa/<sha256>.ssa`
  - `obj/<sha256>.o`
  - `index.tsv` (`<key>\t<bytes>\t<last_access_ms>`)
- Eviction: when total bytes exceed `$M2_CACHE_MAX_MB` (default 2048 MB), evict least-recently-used entries until under 80% watermark.
- **Invariant**: Running `m2c check`, `m2c build`, or `m2c test` MUST leave `git status --ignored` completely clean inside the source worktree (except an explicitly requested `-o <out>` output binary path).
