# `Pion` Language & Self-Hosting Compiler Specification (v0.1 Bootstrap)

`Pion` is an Agent-friendly, C-speed, fast-compiling, memory-safe, natively multithreaded systems programming language whose core syntax is a clean, strict subset/evolution of MoonBit.

This spec is the **single source of truth** shared by `runtime/`, `vendor/qbe/`, and `compiler/`. Any change to ABI, runtime symbols, grammar, or JSON schema must update this file in the same commit.

---

## 1. Design Pillars

1. **Zero Cross-Function Inference (Gojo rule)**: Every top-level `fn` and method MUST declare explicit parameter types and return type. Local `let` bindings infer types within the function body only. No macros, no `comptime`, no higher-kinded types.
2. **Second-Class References & Biased RC (Gojo + Koka/Lean 4)**:
   - No Rust-style `<'a>` lifetime annotations.
   - Heap objects (strings, bytes, arrays, maps, structs, enums, closures) use **Biased Reference Counting**: non-atomic `local_rc` on the owning thread (zero atomic overhead in single-threaded code), transparently promoted to atomic `shared_rc` when frozen/shared across threads.
   - Borrowed function parameters do not bump RC on entry/exit (Perceus-lite borrow elision).
   - **Perceus-lite last-use early drop**: top-level immutable owned heap locals in a straight-line statement block are released immediately after their last syntactic mention (`pion_rc_dec` + slot zeroing) when not pinned by a borrowed array-element view, reclaiming large temporaries before subsequent allocations.
3. **Compile-Time Data-Race-Free Multithreading**:
   - Native OS threads via structured concurrency (`scope` + `spawn`), `Channel[T]`, `Mutex[T]`, `AtomicInt`.
   - Every type is statically classified as `Send` or `!Send`:
     - Primitives (`Int`, `Int64`, `Double`, `Bool`, `Byte`, `Unit`), `String`, the `World` capability (a frozen handle; spawned workers capture it explicitly to do IO/TCP), `Channel[T]` (where `T: Send`), `Mutex[T]` (where `T: Send`, or `T` is a *shareable container*: `Array[E]` or `Map[String, E]` whose `E` is `Send` or itself a shareable container, e.g. `Mutex[Array[Rec]]`, `Mutex[Map[String, Array[String]]]`), `AtomicInt`, and immutable `struct`/`enum` (no `mut` fields, all fields `Send`) are `Send`.
     - Any `struct` with `mut` fields, `Array[T]`, `Bytes`, `Map[K, V]` are `!Send` by default (must be wrapped in `Mutex[T]` or explicitly transferred via `move` with single-function linear check). A container placed in a `Mutex` (`Mutex::new` / `set`) is frozen recursively together with its elements, and every object later stored into a frozen container (`pion_map_set`, array push/store, including the inline push fast path) is frozen on insertion, so elements released on any thread keep an atomic RC. Bare `Array` / `Map` outside a `Mutex`, `Ptr` and closures stay `!Send`.
     - Capturing a non-`Send` variable in `spawn` or sending a non-`Send` value over `Channel[T]` is a compile-time error (`E_NOT_SEND`).
4. **Explicit Capability (`World`, Vercel Zero rule)**:
   - Pure functions cannot perform IO, read wall clock, spawn OS processes, or touch the filesystem unless a `World` (or sub-capability) parameter is explicitly in scope.
   - Entry point: `pub fn main(world : World) -> Int` (or `fn main() -> Unit` in pure test mode). Calling IO builtins (`io_println`, `fs_read`, `fs_write`, `clock_now_ms`, `proc_exec`, `env_get`, `args_get`) without a `World` value in scope is a compile-time error (`E_CAPABILITY_MISSING`).
   - Network and time primitives (`tcp_listen`, `tcp_local_port`, `tcp_accept`, `tcp_connect`, `tcp_read`, `tcp_write`, `tcp_close`, `sleep_ms`) take the `World` value as their **explicit first argument**; a `World` merely in scope is not enough (`E_CAPABILITY_MISSING`).
5. **Agent-First Compiler Interface**:
   - `pionc check --json <path>` — compact JSON diagnostics (`file`, `line`, `col`, `code`, `message`, `expected`, `found`, `fixit`, plus machine-applicable `edits` when an exact patch is known), one object per diagnostic inside `{"ok":bool,"diagnostics":[...]}` (§5.1).
   - `pionc query defs|sig|callers|deps --json <path>` — structured symbol table, exported signatures, call graph, and package dependency graph; `<path>` may be a file, a package directory, or a whole `pion.toml` workspace (§5.2).
   - `pionc test --json <workspace>` runs every local package's tests in one report (§5.3); `pionc init <dir>` scaffolds a package that is check/test/run/fmt-clean; `pionc fetch [dir]` resolves git dependencies and writes `pion.lock` (§6).
   - `pionc doc [--json] <path>` — the public API (every `pub` struct/enum/trait/extern fn/fn/const and every `impl`) of a file, directory or whole `pion.toml` workspace in one call (§5.4).
   - Contracts: `debug_assert(cond, msg)` — active in dev/test builds, stripped to 0 bytes in `--release`; it is an expression of type `Unit` and may stand in expression position (e.g. a `match` arm body).
6. **Sub-150ms Incremental Compile, Tiny Binaries, Zero `target/`**:
   - Package-level separate compilation via `.pionsig` compact interface files: editing a function body without changing its `pub` signature yields 100% cache hit on downstream packages.
   - **Global Content-Addressed Cache** (`$PION_CACHE_DIR`, default `~/.cache/pion/cas`), LRU-evicted (`$PION_CACHE_MAX_MB`, default 2048). **NEVER writes a `target/` or `_build/` directory inside the source tree.**
   - **Dev backend**: emits per-package **QBE IL** → vendored `qbe --obj` writes the object file directly (Mach-O arm64 for `arm64_apple`, ELF64 x86-64 for `amd64_sysv`; no `as`) → `ld`/`cc` + prebuilt `<64 KB` `libpionrt.a`. `--emit-asm` or `PION_NO_DIRECT_OBJ=1` falls back to `qbe` text + `as`.
   - **Cross objects**: `pionc build --target arm64_apple|amd64_sysv --emit-obj <out.o> <input>` writes the single-package object for that target and skips linking (e.g. an ELF64 x86-64 `.o` from macOS with no extra toolchain).
   - **Native libraries**: `-l <lib>` / `-l<lib>` / `--link <lib>` on `build`/`run`/`test`, plus `[link] libs = [...]` in `pion.toml` (dependencies first, de-duplicated) add `-l<lib>` to the link; the list is part of the binary's cache key.
   - **Release backend** (`--release`): the same embedded QBE pipeline (no LLVM, no separate optimizing toolchain) with release-mode IL, stripping `debug_assert`.

---

## 2. Bootstrap Subset (`Pion ∩ MoonBit`) & Self-Hosting Strategy

To achieve **zero-rewrite Stage 0 → Stage 1 → Stage 2 fixed-point self-hosting**:

```
compiler/
  moon.mod                 # Stage 0 MoonBit module definition (moon 0.1.20261117+)
  src/
    core/                  # PURE Pion ∩ MoonBit compiler core (shared by Stage 0 & Stage 1!)
      lexer.mbt
      ast.mbt
      parser.mbt
      sig.mbt              # .pionsig serializer/deserializer
      types.mbt            # Type checker + exhaustive match + Send + World capability
      ir.mbt               # Typed MIR/SSA + Perceus-lite RC insertion
      qbe.mbt              # QBE IL emitter (arm64_apple & amd64_sysv)
      cas.mbt              # Global CAS hashing & LRU cache manager
      diag.mbt             # JSON diagnostics & query engine
      driver.mbt           # Package graph + compile pipeline
    compat_moon/           # Thin Stage 0 adapter (~150 LOC, MoonBit extern "C" host IO)
    compat_pion/           # Thin Stage 1 adapter (~150 LOC, Pion World + parallel scope/spawn)
```

- **Stage 0 (`pionc0`)**: `moon build --target native --release` compiles `src/core` + `src/compat_moon` → `pionc0`.
- **Stage 1 (`pionc1`)**: `pionc0 build` compiles `src/core` + `src/compat_pion` → `pionc1` (native binary backed by `runtime/libpionrt.a` + QBE!).
- **Stage 2 (`pionc2`)**: `pionc1 build` compiles `src/core` + `src/compat_pion` → `pionc2` (using `Pion`'s own native multithreaded package compilation!).
- **Fixed-Point Proof**: QBE IL & assembly emitted by `pionc1` vs `pionc2` for `pionc` itself MUST be **bit-for-bit identical** (SHA-256 match).

---

## 3. Core Language Grammar (v0.1 Bootstrap)

Every construct below is valid in BOTH MoonBit (with thin helper aliases where needed) AND `Pion`:

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
  - `String`: UTF-8 bytes (`length()` / `code_unit_at` count bytes); `"..."` holds any UTF-8 text, kept byte-for-byte by every compiler stage (Stage 0 decodes UTF-16, Stage 1/2 UTF-8 via `str_scalar_at`), with escapes `\n`, `\r`, `\t`, `\\`, `\"`, `\0`; MoonBit-compatible interpolation `"...\{expr}..."` supporting `String`, `Int`, `Int64`, `Double`, `Bool`, `Char` (plain strings without `\{` remain zero-allocation `.rodata` immortal strings)
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
- `pub` marks items exported in `.pionsig` and accessible from downstream packages via `alias::symbol`. Referencing a non-`pub` symbol from an imported package is a compile-time error (`E_PRIVATE_SYMBOL`).
- `val struct` asserts at compile time that the struct has zero `mut` fields and every field is `Send`.
- `test "name" { ... }` blocks are type-checked by `pionc check`, omitted (0 bytes) by `pionc build`, and compiled with active `debug_assert` by `pionc test [--json] [--filter <substr>] <path>`.
- Files named `*_test.pion` belong to their package only under `pionc test` (the root package of a workspace, or a directory target); `check`, `build` and `run` skip them.
- A struct field may be written `pub name : Type` (MoonBit compatibility); the fields of a `pub struct` are always visible to importers.

### 3.3 Statements & Expressions
- `let x = expr` / `let x : Type = expr` / `let mut x = expr`
- Tuple destructuring & element indexing: `let (a, b) = expr` / `let (a, _, c) : (T1, T2, T3) = expr` (`_` ignores an element), and `t.0` / `t.1` tuple element access
- Assignment: `x = expr`, `obj.field = expr`, `arr[i] = expr`
- Control flow:
  - `if cond { ... } else if cond2 { ... } else { ... }` (expression when all branches yield same type)
  - `while cond { ... }`
  - `for i = 0; i < n; i = i + 1 { ... }`, `for i in start..end { ... }` (half-open `[start, end)`), `for x in arr { ... }` (`Array[T]`)
  - Error propagation: postfix `expr?` on `Result[T, E]` (enclosing function returns `Result[_, E]`) and `Option[T]` (enclosing function returns `Option[_]`)
  - `match scrutinee { Pat [if guard_cond] => expr, ... }` (exhaustive checking required on `enum`, `Bool`, `Option`, `Result`; wildcard `_` allowed; guarded arms do not satisfy exhaustiveness on their own, and failed guards release arm pattern bindings and fall through to subsequent arms)
  - `return [expr]`, `break`, `continue`
- Closures: `fn(x : T) -> R { ... }` (captures by value / biased RC; inside `spawn(...)`, only `Send` or `move` captures allowed)
- Concurrency (Pion native):
  - `scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { ... }) })`
  - `Channel::new(cap)`, `ch.send(v)`, `ch.recv() -> Option[T]`, `ch.close()`
  - `Mutex::new(v)`, `m.with_lock(fn(v : T) -> R { ... })` / `m.lock()` + `m.set(v)` + `m.unlock()`
  - `AtomicInt::new(v)`, `a.load()`, `a.store(v)`, `a.fetch_add(d)`
- Contracts: `debug_assert(cond, "msg")` (statement or expression position, type `Unit`)
- Built-in conversions and helpers:
  - `s.to_int() -> Option[Int]`, `s.to_int64() -> Option[Int64]`, `s.to_double() -> Option[Double]` on `String` (`None` on any malformed or out-of-range input; no exceptions, no partial parses)
  - `o.is_some()`, `o.is_none()`, `o.unwrap_or(default)` on `Option[T]`
  - `r.is_ok()`, `r.is_err()`, `r.unwrap_or(default)` on `Result[T, E]`
- Operators: `+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`, `&`, `|`, `^`, `<<`, `>>`, unary `-`, range `..`, postfix `?`.
- Equality: `==` / `!=` compare by value and are defined only on `Int`, `Int64`, `Double`, `Bool`, `Byte`, `Char`, `String` (content), `Ptr` (address), `Unit`, generic `T` (checked at every instantiation: a type parameter compared with `==`/`!=` in a generic body, directly or through generic callers, must be instantiated with one of these types, else `E_TYPE_MISMATCH` at the call site; such generics are monomorphized so `String` compares bytes and payload-less enums compare tags), and payload-less `enum`s (every variant has no fields; compared by variant tag, also across packages). On `Option`, `Result`, `struct`, `Array`, `Map`, `Bytes`, tuples and payload-carrying `enum`s they are a compile-time error (`E_TYPE_MISMATCH`, "operator `==` is not supported on `<Ty>` (no implicit pointer-identity comparison)", fix-it "use `match` to inspect `<Ty>` values") — there is no implicit pointer-identity comparison.
- Must-use `Result`: an expression statement whose type is `Result[T, E]` and whose value is discarded — any non-tail statement of a block, or the tail statement of a loop or `test` body — is a compile-time error (`E_UNHANDLED_RESULT`, fix-it "handle the Result with `match`, `?`, or explicitly discard with `let _ = ...`"). `let _ = expr` discards explicitly; a block's tail value returned to its function or branch is not discarded.

---

## 4. Runtime ABI & Memory Layout (`runtime/pion_rt.h` & `runtime/pion_rt.c`)

**All values passed across QBE IL / C ABI use uniform 64-bit slots (`l` in QBE, `int64_t` in C)** for Shape Polymorphism:
- `Int` (`i32`): sign-extended in 64-bit register (or `w` locally, `l` across generic boundaries).
- `Int64`: `int64_t` (`l`).
- `Double`: IEEE-754 bit-cast (`double` / `d`, boxed to `int64_t` bits in generic slots).
- `Bool` / `Byte` / `Char`: zero-extended in 64-bit slot (`0`/`1`, `0..255`, Unicode scalar).
- `Unit`: `0`.
- All heap objects (`String`, `Bytes`, `Array`, `Map`, `struct`, `enum`, `Closure`, `Channel`, `Mutex`, `AtomicInt`): `PionObj*` (64-bit pointer, `l` in QBE).

### 4.1 Object Header (24 bytes, 8-byte aligned)
```c
typedef void (*PionDropFn)(void *payload);

typedef struct PionHeader {
    uint32_t owner_tid;        // Thread ID of creator; 0 = FROZEN/SHARED (atomic mode)
    uint32_t local_rc;         // Non-atomic RC used while owner_tid == current_tid
    _Atomic uint32_t shared_rc;// Atomic RC used once owner_tid == 0 (or cross-thread dec)
    uint16_t type_tag;         // PionTag (String=1, Bytes=2, Array=3, Struct=4, Enum=5, Closure=6, Map=7, Channel=8, Mutex=9, Atomic=10)
    uint16_t flags;            // bit 0: FROZEN, bit 1: IMMORTAL, bit 2: SLAB, bits 4..7: 12-class slab id
    PionDropFn drop_fn;        // Nullable destructor for releasing child pointers
} PionHeader;                  // Total: 24 bytes (clean 8-byte alignment on arm64/x64)
```
Payload immediately follows `PionHeader`: `void* obj = (char*)hdr + sizeof(PionHeader)`.
Header recovery: `PionHeader* hdr = ((PionHeader*)obj) - 1`.

**Immortal static strings** (`.rodata` string literals): `flags = PION_FLAG_IMMORTAL | PION_FLAG_FROZEN`, `owner_tid = 0`. `pion_rc_inc` / `pion_rc_dec` return immediately in 1 branch — **ZERO heap allocation and ZERO `init` code for string literals!**

### 4.2 Required Runtime C ABI Functions (`pion_rt.h`)
All symbols use `pion_` prefix and C calling convention (`arm64_apple` / `amd64_sysv`):

**Memory & Biased RC:**
- `void* pion_alloc(uint32_t payload_size, uint16_t type_tag, PionDropFn drop_fn);`
- `void  pion_rc_inc(void *obj);` (no-op if NULL or `PION_FLAG_IMMORTAL`; fast non-atomic if `owner_tid == pion_cur_tid()`, else atomic)
- `void  pion_rc_dec(void *obj);` (no-op if NULL or `PION_FLAG_IMMORTAL`; frees + calls `drop_fn` when total RC hits 0)
- `void  pion_rc_freeze(void *obj);` (promotes `owner_tid` to 0 and moves `local_rc` into `shared_rc` before crossing thread boundary; freezing a `Map` also freezes its keys and object values)
- `void  pion_panic(const char *msg, const char *file, int32_t line);` (prints concise diagnostic to stderr and `abort()`/`_exit(1)`)
- `void  pion_debug_assert(int32_t cond, void *msg_str, const char *file, int32_t line);`

**Math (`Double`):**
- `double  pion_math_sqrt(double x);` (compiler builtin `math_sqrt`)
- `double  pion_math_abs(double x);` (compiler builtin `math_abs`)
- `double  pion_math_floor(double x);` (compiler builtin `math_floor`)
- `double  pion_math_ceil(double x);` (compiler builtin `math_ceil`)
- `double  pion_math_sin(double x);` (compiler builtin `math_sin`)
- `double  pion_math_cos(double x);` (compiler builtin `math_cos`)
- `double  pion_math_pow(double x, double y);` (compiler builtin `math_pow`)

**String (`PionString`: `{ int64_t len; char data[]; }` UTF-8, NUL-terminated):**
- `void*   pion_str_from_cstr(const char *s, int64_t len);`
- `int64_t pion_str_len(void *s);`
- `int32_t pion_str_byte_at(void *s, int64_t idx);`
- `void*   pion_str_concat(void *a, void *b);`
- `void*   pion_str_concat_n(int64_t n, void **parts);` (single-allocation N-way string concatenation)
- `int32_t pion_str_eq(void *a, void *b);`
- `int32_t pion_str_cmp(void *a, void *b);`
- `void*   pion_str_slice(void *s, int64_t start, int64_t end);`
- `void*   pion_int_to_str(int64_t v);`
- `void*   pion_double_to_str(double v);` (`d.to_string() -> String`)
- `int64_t pion_str_to_int(void *s, int32_t *ok_out);`
- `int32_t pion_str_starts_with(void *s, void *prefix);` (`s.starts_with(prefix) -> Bool`)
- `int32_t pion_str_ends_with(void *s, void *suffix);` (`s.ends_with(suffix) -> Bool`)
- `int32_t pion_str_contains(void *s, void *needle);` (`s.contains(needle) -> Bool`)
- `int64_t pion_str_index_of(void *s, void *needle);` (`s.index_of(needle) -> Int`)
- `void*   pion_str_trim(void *s);` (`s.trim() -> String`)
- `void*   pion_str_split(void *s, void *sep);` (`s.split(sep) -> Array[String]`)
- `void*   pion_str_replace(void *s, void *from, void *to);` (`s.replace(from, to) -> String`)
- `void*   pion_str_to_bytes(void *s);` (`s.to_bytes() -> Bytes`)

**Bytes (`PionBytes`: `{ int64_t len; int64_t cap; uint8_t *data; }` — mutable `!Send` heap byte buffer):**
- `void*   pion_bytes_new(int64_t len);` (`Bytes::new(len) -> Bytes`)
- `int64_t pion_bytes_len(void *b);` (`b.length() -> Int`)
- `int32_t pion_bytes_get(void *b, int64_t idx);` (`b[i] -> Byte`, bounds-checked)
- `void    pion_bytes_set(void *b, int64_t idx, int32_t val);` (`b[i] = val` where `val : Byte`, bounds-checked)
- `void*   pion_bytes_slice(void *b, int64_t start, int64_t end);` (`b.slice(start, end) -> Bytes`)
- `void*   pion_bytes_concat(void *a, void *b);` (`b.concat(other) -> Bytes`)
- `void*   pion_bytes_to_str(void *b);` (`b.to_string() -> String`)

**StringBuilder (`PionStrBuf`):**
- `void* pion_strbuf_new(int64_t cap);`
- `void  pion_strbuf_push_str(void *sb, void *s);`
- `void  pion_strbuf_push_byte(void *sb, int32_t b);`
- `void  pion_strbuf_push_char(void *sb, int32_t cp);`
- `void  pion_strbuf_push_int(void *sb, int64_t v);`
- `void  pion_strbuf_reset(void *sb);`
- `void* pion_strbuf_to_str(void *sb);`
- `StringBuilder::length() -> Int` (reads `PionStrBuf.len` at offset 0)

**Array (`PionArray`: `{ int64_t len; int64_t cap; int32_t elem_is_obj; int64_t *data; }` — uniform 64-bit slots!):**
- `void*   pion_arr_new(int64_t cap, int32_t elem_is_obj);`
- `int64_t pion_arr_len(void *a);`
- `void    pion_arr_push(void *a, int64_t val);` (retains if `elem_is_obj`)
- `int64_t pion_arr_get(void *a, int64_t idx);` (bounds-checked!)
- `void    pion_arr_set(void *a, int64_t idx, int64_t val);` (bounds-checked; retains new, releases old if `elem_is_obj`)
- `int64_t pion_arr_pop(void *a);`
- `void*   pion_arr_copy(void *a);`
- `void    pion_arr_clear(void *a);` (`arr.clear() -> Unit`; releases elements if `elem_is_obj`)
- `void    pion_arr_reverse(void *a);` (`arr.reverse() -> Unit`; in-place)
- `void*   pion_arr_join(void *a, void *sep);` (`arr.join(sep) -> String` for `Array[String]`)
- `void    pion_arr_sort_int(void *a);` (`arr.sort() -> Unit` for `Array[Int]` / `Array[Int64]`)
- `void    pion_arr_sort_str(void *a);` (`arr.sort() -> Unit` for `Array[String]`)

**String-Keyed Hash Map (`PionMap` — open addressing FNV-1a, 64-bit value slots):**
- `void*   pion_map_new(int32_t val_is_obj);`
- `int64_t pion_map_len(void *m);`
- `void    pion_map_set(void *m, void *key_str, int64_t val);` (freezes the key and object value first when the map itself is frozen)
- `int32_t pion_map_has(void *m, void *key_str);`
- `int64_t pion_map_get(void *m, void *key_str);` (panics if missing; compiler pairs with `has` or returns Option)
- `void    pion_map_remove(void *m, void *key_str);`
- `void*   pion_map_copy(void *m);`
- `void*   pion_map_keys(void *m);` (returns `PionArray` of `PionString*`)

**Concurrency (`pthread` backed, race-free):**
- `void*   pion_scope_begin(void);`
- `void    pion_scope_spawn(void *scope, void (*fn)(void *env), void *env);` (`env` is frozen & retained before pthread launch, released after `fn` returns)
- `void    pion_scope_end(void *scope);` (joins all spawned threads deterministically before returning!)
- `void*   pion_chan_new(int64_t cap, int32_t elem_is_obj);`
- `int32_t pion_chan_send(void *ch, int64_t val);` (returns 1 if sent, 0 if closed; freezes obj before enqueue)
- `int32_t pion_chan_recv(void *ch, int64_t *out_val);` (returns 1 if received, 0 if closed & empty)
- `void    pion_chan_close(void *ch);`
- `void*   pion_mutex_new(int64_t init_val, int32_t val_is_obj);`
- `int64_t pion_mutex_lock(void *m);`
- `void    pion_mutex_set(void *m, int64_t new_val);`
- `void    pion_mutex_set_and_unlock(void *m, int64_t new_val);`
- `void    pion_mutex_unlock(void *m);`
- `void*   pion_atomic_new(int64_t init_val);`
- `int64_t pion_atomic_load(void *a);`
- `void    pion_atomic_store(void *a, int64_t val);`
- `int64_t pion_atomic_fetch_add(void *a, int64_t delta);`

**World Capabilities (passed via `PionWorld*`):**
- `void*   pion_world_init(int argc, char **argv);`
- `int64_t pion_world_argc(void *w);`
- `void*   pion_world_argv(void *w, int64_t idx);`
- `void*   pion_world_args(void *w);`
- `void    pion_world_print(void *w, void *s);`
- `void    pion_world_println(void *w, void *s);`
- `void    pion_world_eprintln(void *w, void *s);`
- `void*   pion_world_fs_read(void *w, void *path_str, int32_t *ok_out);` (`fs_read -> Result[String, String]`)
- `int32_t pion_world_fs_write(void *w, void *path_str, void *content_str);` (`fs_write -> Result[Unit, String]`)
- `void*   pion_world_fs_read_bytes(void *w, void *path_str, int32_t *ok_out);` (`fs_read_bytes -> Result[Bytes, String]`)
- `int32_t pion_world_fs_write_bytes(void *w, void *path_str, void *bytes_obj);` (`fs_write_bytes -> Result[Unit, String]`)
- `int32_t pion_world_fs_append(void *w, void *path_str, void *content_str);` (`fs_append -> Result[Unit, String]`)
- `int64_t pion_world_fs_mtime_ms(void *w, void *path_str);` (`fs_mtime_ms -> Int64`, `-1` if missing)
- `int32_t pion_world_fs_exists(void *w, void *path_str);`
- `int32_t pion_world_fs_is_dir(void *w, void *path_str);`
- `int32_t pion_world_fs_mkdir_p(void *w, void *path_str);`
- `void*   pion_world_fs_list_dir(void *w, void *path_str);` (MUST return entries sorted lexicographically for deterministic builds!)
- `int32_t pion_world_fs_remove(void *w, void *path_str);` (for CAS LRU eviction; returns 1 on success)
- `int32_t pion_world_fs_rename(void *w, void *old_path, void *new_path);` (for atomic concurrent CAS writes; returns 1 on success)
- `int64_t pion_world_fs_size(void *w, void *path_str);` (file size in bytes, or -1 if missing)
- `void*   pion_world_env_get(void *w, void *name_str, int32_t *ok_out);`
- `int64_t pion_world_clock_ms(void *w);`
- `int32_t pion_world_exec(void *w, void *argv_arr);` (fork/execvp waitpid, returns exit code)
- `void*   pion_world_exec_capture(void *w, void *argv_arr, int32_t *exit_code_out);` (`proc_exec_capture -> Result[String, String]`; `Ok(stdout)` if exit code == 0, else `Err("exit <code>: <stdout>")`)
- `void*   pion_sha256_hex(void *s);` (pure SHA-256 hex digest for CAS cache keys!)

**FFI raw pointers & C strings (no `World`; compiler builtins → direct calls):**
- `void*   pion_ptr_alloc(int64_t bytes);` (`ptr_alloc(bytes : Int64) -> Ptr`, zeroed)
- `void    pion_ptr_free(void *p);` (`ptr_free(p : Ptr) -> Unit`)
- `void*   pion_ptr_offset(void *p, int64_t off);` (`ptr_offset(p : Ptr, off : Int64) -> Ptr`)
- `void*   pion_ptr_read_ptr(void *p, int64_t off);` / `void pion_ptr_write_ptr(void *p, int64_t off, void *v);` (`ptr_read_ptr` / `ptr_write_ptr`)
- `int32_t pion_ptr_read_i32(void *p, int64_t off);` / `void pion_ptr_write_i32(void *p, int64_t off, int32_t v);` (`ptr_read_i32 -> Int` / `ptr_write_i32`)
- `int64_t pion_ptr_read_i64(void *p, int64_t off);` / `void pion_ptr_write_i64(void *p, int64_t off, int64_t v);` (`ptr_read_i64 -> Int64` / `ptr_write_i64`)
- `void*   pion_cstr_to_str(void *cstr);` (`cstr_to_str(p : Ptr) -> String`, owned copy; `""` for NULL)

**POSIX TCP & time (explicit `World` first argument; IPv4, `"localhost"` = `127.0.0.1`; `-1` on error with `errno` preserved):**
- `int32_t pion_tcp_listen(void *w, void *host, int32_t port);` (`tcp_listen(w, host : String, port : Int) -> Int`; `""`/`"0.0.0.0"` = any, port 0 = ephemeral)
- `int32_t pion_tcp_local_port(void *w, int32_t fd);` (`tcp_local_port(w, fd : Int) -> Int`)
- `int32_t pion_tcp_accept(void *w, int32_t listen_fd);` (`tcp_accept(w, listen_fd : Int) -> Int`)
- `int32_t pion_tcp_connect(void *w, void *host, int32_t port);` (`tcp_connect(w, host : String, port : Int) -> Int`)
- `void*   pion_tcp_read(void *w, int32_t fd, int32_t max_bytes);` (`tcp_read(w, fd : Int, max_bytes : Int) -> String`; `""` at EOF or error)
- `int32_t pion_tcp_write(void *w, int32_t fd, void *data);` (`tcp_write(w, fd : Int, data : String) -> Int`, bytes written; writes all or returns `-1`)
- `void    pion_tcp_close(void *w, int32_t fd);` (`tcp_close(w, fd : Int) -> Unit`)
- `void    pion_sleep_ms(void *w, int32_t ms);` (`sleep_ms(w, ms : Int) -> Unit`)

**Non-blocking sockets & readiness polling (explicit `World` first argument; kqueue on macOS, epoll on Linux; IO returns `>= 0` bytes/fd, `-2` for `EAGAIN`/`EWOULDBLOCK`, or `-1` on error; `Bool` returns are zero-extended from C `int32_t` 0/1 to 64-bit slots; poll event masks: `1` READ | `2` WRITE | `4` ERR/HUP/EOF; `poll_ctl` ops: `1` ADD, `2` MOD, `3` DEL):**
- `int32_t pion_tcp_listen_reuse(void *w, void *host, int32_t port);` (`tcp_listen_reuse(w, host : String, port : Int) -> Int`; enables `SO_REUSEPORT` for multi-worker accept)
- `int32_t pion_tcp_set_nonblock(void *w, int32_t fd, int32_t enable);` (`tcp_set_nonblock(w, fd : Int, enable : Bool) -> Bool`)
- `int32_t pion_tcp_accept_nb(void *w, int32_t listen_fd);` (`tcp_accept_nb(w, listen_fd : Int) -> Int`; sets `O_NONBLOCK` + `TCP_NODELAY`)
- `int32_t pion_tcp_read_nb(void *w, int32_t fd, void *sb, int32_t max_bytes);` (`tcp_read_nb(w, fd : Int, sb : StringBuilder, max_bytes : Int) -> Int`; appends into `sb`)
- `int32_t pion_tcp_write_nb(void *w, int32_t fd, void *data, int32_t offset);` (`tcp_write_nb(w, fd : Int, data : String, offset : Int) -> Int`)
- `int32_t pion_poll_create(void *w);` (`poll_create(w) -> Int`)
- `int32_t pion_poll_ctl(void *w, int32_t pfd, int32_t op, int32_t fd, int32_t events);` (`poll_ctl(w, pfd : Int, op : Int, fd : Int, events : Int) -> Bool`)
- `int32_t pion_poll_wait(void *w, int32_t pfd, void *out_fds, void *out_events, int32_t max_events, int32_t timeout_ms);` (`poll_wait(w, pfd : Int, out_fds : Array[Int], out_events : Array[Int], max_events : Int, timeout_ms : Int) -> Int`)
- `void    pion_poll_close(void *w, int32_t pfd);` (`poll_close(w, pfd : Int) -> Unit`)

---

## 5. Agent JSON Protocols

### 5.1 `pionc check --json <path>`
```json
{
  "ok": false,
  "diagnostics": [
    {
      "file": "src/app.pion",
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
- `edits` (optional, emitted only when non-empty): machine-applicable patches `[{"file","line","col","end_line","end_col","replacement"}]` replacing the 1-based range `[line:col, end_line:end_col)` (end exclusive; an empty range is an insertion). Applying every edit of a diagnostic verbatim fixes it; each distinct edit is attached once. Covered today:
  - `E_MISSING_TYPE` — inserts the inferred return type (`-> T`).
  - `E_TYPE_MISMATCH` "cannot assign to immutable variable" — `let x` → `let mut x` at the declaration.
  - `E_UNHANDLED_RESULT` — prefixes the discarded statement with `let _ = `.
  - `E_NON_EXHAUSTIVE` — inserts the missing `match` arms (`panic`-bodied) before the first arm.
  - `E_TRAIT_METHOD_SIGNATURE` — rewrites the impl method's return type to the trait's.
  - `E_PRIVATE_SYMBOL` — inserts `pub ` at the target declaration.

### 5.2 `pionc query <kind> --json <path>`
- `defs`: `{"defs":[{"pkg":"...","name":"...","kind":"fn|struct|enum","pub":true,"file":"...","line":10,"sig":"..."}]}`
- `sig`: compact `.pionsig` export table in JSON
- `callers`: `{"callers":[{"fn":"...","calls":["..."]}]}` (workspace targets add `"pkg"` to every entry)
- `deps`: `{"packages":[{"name":"...","deps":["..."],"sig_hash":"..."}]}`
- `<path>` may be a file, a package directory (its `src/` included) or a `pion.toml` workspace root: `defs`/`sig`/`callers` then cover every package in one call.

### 5.3 `pionc test [--json] [--filter <substr>] <path>`
- Runs all `test "name" { ... }` blocks in isolated child processes (active `debug_assert`, binary stored in `$PION_CACHE_DIR/bin/`).
- JSON output: `{"ok":bool,"passed":N,"failed":M,"tests":[{"name":"...","ok":bool}]}`
- Workspace target (a directory with `pion.toml`): one invocation runs the tests of every local package (dependencies first; packages from the git cache are excluded) and reports `{"ok":bool,"total":N,"passed":N,"failed":M,"packages":["..."],"tests":[{"pkg":"...","name":"...","ok":bool}]}`; `--package <name>` restricts it to one package.
- Additional diagnostic codes:
  - `E_PRIVATE_SYMBOL`: accessing a non-`pub` function, struct, enum, method, or constant from an imported package.
  - `E_IMPORT_CYCLE`: cyclic package dependency detected across `pion.toml` manifests.
  - `E_UNKNOWN_PACKAGE`: importing or depending on an undeclared package.

### 5.4 `pionc doc [--json] <path>`
- `{"packages":[{"name":"json","items":[{"kind":"struct|enum|trait|impl|extern_fn|fn|const","name":"...","sig":"...","file":"...","line":3}]}]}` — one entry per package (workspace: dependencies first); `impl` items are always listed, everything else only when `pub`.
- Without `--json`: `package <name>` followed by one indented signature per item.

---

## 6. Global Content-Addressed Cache (CAS) & `pion.toml` Contract

- **Package Manifest (`pion.toml`)**:
  ```toml
  [package]
  name = "app"
  version = "0.1.0"

  [dependencies]
  math = { path = "../math" }
  regex = { git = "https://example.com/pion-std.git", tag = "v0.3.0", subdir = "std/regex" }
  # exactly one of tag = / rev = / branch = (none: the remote HEAD); subdir is optional

  [link]
  libs = ["sqlite3"]   # or: lib = "sqlite3"
  ```
- **Git dependencies & `pion.lock`**: git dependencies resolve into the global shared cache `$PION_CACHE_DIR/git/` (default `~/.cache/pion/git/`): bare mirrors `repos/<sha256(url)>.git` and read-only checkouts `checkouts/<rev>` (no `.git`), created atomically and shared zero-copy by every worktree. `<root>/pion.lock` pins each git dependency to a full commit (`version = 1`, then `[[package]]` tables with `name`, `git`, `ref`, `rev`, `subdir`, sorted, every key written); an entry is reused only while `pion.toml` requests the same name, URL, subdir and ref. A locked dependency whose checkout exists runs no `git` at all; tags and full revs resolve from the mirror, branches and HEAD always fetch. Only `<root>/pion.lock` is ever written, and only when it changes.
- **`pionc fetch [--json] [dir]`**: resolves every git dependency, writes/verifies `pion.lock`, and prints `{"ok":true,"lock":"...","git_cache":"...","packages":[{"name","dir","source":"path|git"}],"git":[{"name","git","ref","rev","subdir"}]}`.
- **`pionc init [--json] <dir>`**: writes `pion.toml`, `src/main.pion` and `main_test.pion` for a package named after the directory (`[a-z0-9_]`); the result passes `check`, `test`, `run` and `fmt --check` as is. Refuses to overwrite existing files.
- **Cross-package traits**: an imported package's `impl Trait for Type` is registered under `pkg::Trait::pkg::Type` (built-in targets such as `Int` stay unqualified), and impl symbols use the package-local trait/type names, so definitions and cross-package calls link. A package exporting a `pub` generic fn with trait bounds has no `.pionstub` (importers monomorphize from its source).
- **Cross-Package Incremental Isolation**: Downstream package CAS keys depend ONLY on upstream packages' `pub` `.pionsig` SHA-256 hashes (never upstream function bodies). Editing an upstream function body without changing its `pub` `.pionsig` yields 100% CAS hit on downstream `.o` files.
- **Compiler Fingerprint**: Every CAS key (`cas_compute_key`, `cas_compute_unit_key`) and `.usig` cache prefix includes `compiler_fp = sha256(PION_COMPILER_ABI_REV | qbe_size | libpionrt_size | salt)`, where `salt` = `self:<pionc_size>:<pionc_mtime_ms>|$PION_CACHE_SALT` (the running `pionc` binary from `argv[0]`, when it resolves to a file) and `PION_COMPILER_ABI_REV` is currently `pionc-v0.9`, ensuring compiler/backend upgrades — including a rebuilt `pionc` whose `qbe` and `libpionrt.a` are unchanged — automatically invalidate stale cache entries. The fingerprint only names cache files: it never changes emitted SSA or objects, so the bootstrap fixed point is unaffected.
- Default directory: `$PION_CACHE_DIR` or `$HOME/.cache/pion/cas`
- Layout:
  - `sig/<sha256>.pionsig`
  - `ssa/<sha256>.ssa`
  - `obj/<sha256>.o`
  - `index.tsv` (`<key>\t<bytes>\t<last_access_ms>`)
- Eviction: when total bytes exceed `$PION_CACHE_MAX_MB` (default 2048 MB), evict least-recently-used entries until under 80% watermark.
- **Invariant**: Running `pionc check`, `pionc build`, or `pionc test` MUST leave `git status --ignored` completely clean inside the source worktree (except an explicitly requested `-o <out>` output binary path).

---

## 7. Standard Library (`std/`)

Plain Pion packages imported through `pion.toml` (`path` or `git` dependencies); each has `*_test.pion` tests and is `pionc fmt --check` clean.

- **`std/json`**: JSON values, parser and serializer.
- **`std/http`**: HTTP/1.1 over `World` TCP — `parse_request`/`parse_response` (with `Transfer-Encoding: chunked` bodies via `decode_chunked`), `parse_query` (`a=1&b=x%20y` → `Map[String, String]`, percent and `+` decoding), framing helpers `request_len`/`response_len`, `read_http_response`, keep-alive (`should_keep_alive`, where HTTP/1.0 defaults to close; `format_response_ka`/`format_request_ka`/`write_http_response_ka`) and `HttpConn` (`new_conn`, `conn_read_request`, `conn_read_response`), which keeps pipelined bytes between requests on one connection. Existing `Connection: close` APIs are unchanged.
- **`std/net`**: non-blocking event-loop poller (`Poller`, `Event`, `EV_READ`/`EV_WRITE`/`EV_ERR`) over `kqueue` (macOS) / `epoll` (Linux) with `SO_REUSEPORT` multi-worker accept helpers.
- **`std/regex`**: pure-Pion Thompson NFA executed by a Pike VM — linear time in the input for every pattern (no backtracking, no ReDoS). Syntax: literals, `.`, `\d \D \w \W \s \S`, classes `[...]`/`[^...]` with ranges, groups, `|`, greedy and lazy `* + ? {n} {n,} {n,m}`, anchors `^ $`; matching is UTF-8 aware. API: `compile(pattern) -> Result[Regex, String]` (errors carry the byte offset), `is_match`, `find`, `find_at`, `find_all -> Array[Match]` (byte offsets), `replace_all`, `escape`, `program_size`.
- **`std/tls`**: TLS 1.2/1.3 client binding the system OpenSSL (`libssl`/`libcrypto`, 1.1.x or 3.x C ABI) through `extern "C"` declarations only — zero C glue; `[link] libs = ["ssl", "crypto"]`. SNI, certificate verification against OpenSSL's default CA store (`SSL_CERT_FILE`/`SSL_CERT_DIR` honoured) with host-name or IP checking, TLS 1.2 minimum. API: `tls_connect(w, host, port, verify_cert) -> Result[TlsConn, String]`, `tls_write`, `tls_read`, `tls_close`, `tls_protocol`, `tls_cipher`, `tls_version`, and `https_request` on top of `std/http`. Linux needs the `libssl.so`/`libcrypto.so` link names (Debian/Ubuntu `libssl-dev`); macOS needs Homebrew `openssl@3` and `CC=cc LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib`. `std/tls/e2e/run_e2e.sh <pionc>` performs real loopback TLS 1.3 and 1.2 handshakes against a Python `ssl` server and checks that a wrong host name is refused.
