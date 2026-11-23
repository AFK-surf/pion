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
     - Primitives (`Int`, `Int64`, `Double`, `Bool`, `Byte`, `Unit`), `String`, the `World` capability (a frozen handle; spawned workers capture it explicitly to do IO/TCP), `Channel[T]` (where `T: Send`), `Mutex[T]` (where `T: Send`, or `T` is a *shareable container*: `Array[E]` or `Map[K, E]` with `K ∈ {String, Int, Int64}` whose `E` is `Send` or itself a shareable container, e.g. `Mutex[Array[Rec]]`, `Mutex[Map[String, Array[String]]]`, `Mutex[Map[Int, String]]`), `AtomicInt`, and immutable `struct`/`enum` (no `mut` fields, all fields `Send`) are `Send`.
     - Any `struct` with `mut` fields, `Array[T]`, `Bytes`, `Map[K, V]` are `!Send` by default (must be wrapped in `Mutex[T]` or explicitly transferred via `move` with single-function linear check). A container placed in a `Mutex` (`Mutex::new` / `set`) is frozen recursively together with its elements, and every object later stored into a frozen container (`pion_map_set`, array push/store, including the inline push fast path) is frozen on insertion, so elements released on any thread keep an atomic RC. Bare `Array` / `Map` outside a `Mutex`, `Ptr` and closures stay `!Send`.
     - Capturing a non-`Send` variable in `spawn` or sending a non-`Send` value over `Channel[T]` is a compile-time error (`E_NOT_SEND`).
4. **Explicit Capability (`World`, Vercel Zero rule)**:
   - Pure functions cannot perform IO, read wall clock, spawn OS processes, or touch the filesystem unless a `World` (or sub-capability) parameter is explicitly in scope.
   - Entry point: `pub fn main(world : World) -> Int` (or `fn main() -> Unit` in pure test mode). Calling IO builtins (`io_println`, `fs_read`, `fs_write`, `clock_now_ms`, `proc_exec`, `env_get`, `args_get`) without a `World` value in scope is a compile-time error (`E_CAPABILITY_MISSING`).
   - Network and time primitives (`tcp_listen`, `tcp_local_port`, `tcp_accept`, `tcp_connect`, `tcp_read`, `tcp_write`, `tcp_close`, `sleep_ms`) take the `World` value as their **explicit first argument**; a `World` merely in scope is not enough (`E_CAPABILITY_MISSING`).
   - Function/method attributes `#no_io` / `#[no_io]` and their alias `#render_thread` / `#[render_thread]` enforce a compile-time zero-`World` boundary (intended for GUI render threads and non-blocking callbacks): annotated functions, `impl` methods, and any nested closures inside them cannot accept a `World` parameter, reference a `World` binding, or call `World` IO builtins / runtime primitives / `scope` (`E_NO_IO_VIOLATION`, with no `world : World` insertion edit). Non-`World` `extern "C"` FFI, `Channel`, `Mutex`, `AtomicInt`, and pure computation remain allowed.
5. **Agent-First Compiler Interface**:
   - `pionc check --json <path>` — compact JSON diagnostics (`file`, `line`, `col`, `code`, `message`, `expected`, `found`, `fixit`, plus machine-applicable `edits` when an exact patch is known), one object per diagnostic inside `{"ok":bool,"diagnostics":[...]}` (§5.1).
   - `pionc query defs|sig|callers|deps --json <path>` — structured symbol table, exported signatures, call graph, and package dependency graph; `<path>` may be a file, a package directory, or a whole `pion.toml` workspace (§5.2).
   - `pionc test --json <workspace>` runs every local package's tests in one report (§5.3); `pionc init <dir>` scaffolds a package that is check/test/run/fmt-clean; `pionc fetch [dir]` resolves git dependencies and writes `pion.lock`; `pionc add` / `pionc update` edit `pion.toml` and re-resolve from paths, git URLs or a git-index registry (§6).
   - `pionc doc [--json] <path>` — the public API (every `pub` struct/enum/trait/extern fn/fn/const and every `impl`) of a file, directory or whole `pion.toml` workspace in one call (§5.4).
   - Contracts: `debug_assert(cond, msg)` — active in dev/test builds, stripped to 0 bytes in `--release`; it is an expression of type `Unit` and may stand in expression position (e.g. a `match` arm body).
6. **Sub-150ms Incremental Compile, Tiny Binaries, Zero `target/`**:
   - Package-level separate compilation via `.pionsig` compact interface files: editing a function body without changing its `pub` signature yields 100% cache hit on downstream packages.
   - **Global Content-Addressed Cache** (`$PION_CACHE_DIR`, default `~/.cache/pion/cas`), LRU-evicted (`$PION_CACHE_MAX_MB`, default 2048). **NEVER writes a `target/` or `_build/` directory inside the source tree.**
   - **Dev backend**: emits per-package **QBE IL** → vendored `qbe --obj` writes the object file directly for `arm64_apple` (Mach-O arm64) and `amd64_sysv` (ELF64 x86-64) with no `as`; all other targets (`amd64_apple`, `amd64_win`, `arm64`, `rv64`, `ios_arm64`, `ios_sim_arm64`, `android_arm64`, `android_x64`) lower via `qbe -t <arch>` → target `cc -c` → `ld`/`cc` + prebuilt `<64 KB` `libpionrt.a`. `--emit-asm` or `PION_NO_DIRECT_OBJ=1` falls back to `qbe` text + assembler.
   - **Multi-target & library outputs**:
     - Host auto-detection (`$PION_TARGET`, else `$OS == Windows_NT`, else `uname -sm`): macOS ARM64 (`arm64_apple`), macOS x86_64 (`amd64_apple`), Linux x86_64 (`amd64_sysv`), Linux ARM64 (`arm64`), Linux RISC-V 64 (`rv64`), Windows x86_64 (`amd64_win`).
     - Cross targets: `--target arm64_apple|amd64_apple|amd64_sysv|amd64_win|arm64|rv64|ios_arm64|ios_sim_arm64|android_arm64|android_x64|wasm32`, with optional `--sysroot <dir>` (`-isysroot` on Apple, `--sysroot=` on ELF; iOS auto-probes `xcrun --sdk iphoneos|iphonesimulator --show-sdk-path`; Android honors `$PION_ANDROID_CC` / `$ANDROID_NDK_HOME`; Windows auto-links `-lws2_32`, links executables with a 16 MB main-thread stack (`-Wl,--stack,16777216`; MinGW defaults to 1 MB), spawns `scope` threads with 8 MB stacks, and omits `-fPIC`/`-rpath`; when `CC` targets Windows MSVC (`PION_WIN_ABI=msvc`, `clang-cl`, or `cc -dumpmachine` containing `msvc`), `pionc` auto-derives `clang++`, translates `-mwindows`/`-mconsole`/`-Wl,--stack,N` to `/SUBSYSTEM:*`/`/STACK:*`, adds `-fuse-ld=lld`, omits `-lm`/`-lpthread`, and auto-compiles `runtime/pion_rt.c` into CAS when `PION_RT_LIB` is unset).
     - **WebAssembly (`--target wasm32`)**: zero-toolchain direct `.wasm` binary emission from QBE SSA (`compiler/src/core/wasm.pion`) requiring no `emcc`/`wasi-sdk`/`wasm-ld`; runs in Browser and Node.js via the zero-dependency ES module `runtime/pion_wasm_rt.mjs` (`pionc run --target wasm32` invokes `node runtime/pion_wasm_rt.mjs` with `$PION_WASM_RT` override) using byte-for-byte identical linear-memory layouts to 64-bit `pion_rt.h`. Optional `--wasm-names` (on `pionc build`/`run`, default off for zero `--release` overhead) appends the standard WebAssembly `name` custom section (subsection `1`, Function Names; preserved via `wasm-opt -g` when `wasm-opt` is active) for CPU profiling and per-function size analysis, and is included in the Wasm32 binary CAS key.
     - Artifact modes: `--emit-obj <out.o>`, `--emit-staticlib <out.a>` (`ar rcs` of package + `c_sources` `.o`), `--emit-cdylib <out.so|.dylib>` (`-dynamiclib` on Apple, `-shared` + `-fPIC` on Linux/Android), `--emit-asm <out.s>` (skips assembly when no link/object artifact is requested).
   - **Native libraries**: `-l <lib>` / `-l<lib>` / `--link <lib>` on `build`/`run`/`test`, plus `[link] libs = [...]` in `pion.toml` (dependencies first, de-duplicated) add `-l<lib>` to the link; the list is part of the binary's cache key.
   - **Release backend** (`--release`): the same embedded QBE pipeline (no LLVM, no separate optimizing toolchain) with release-mode IL, stripping `debug_assert`.

---

## 2. Self-Hosting Architecture (Pure Pion, Zero External Compiler Dependency)

`Pion` is 100% self-hosted in pure `.pion` with zero MoonBit or LLVM dependency:

```
bootstrap/
  pionc-seed.ssa.gz        # Architecture-independent QBE SSA Stage 0 seed (gzip -9 -n)
compiler/
  src/
    core/                  # Pure Pion compiler core & native unit tests (*_test.pion)
      lexer.pion
      ast.pion
      parser.pion
      sig.pion             # .pionsig serializer/deserializer
      types.pion           # Type checker + exhaustive match + Send + World capability + `mut` arguments + ResolvedInfo side tables
      verify.pion          # `#verify` static rules (move / borrow / escape / closure / forbidden types)
      llbc.pion            # Pion-LLBC: desugared verification IR of the `#verify` closure (§3.5)
      lean.pion            # functional lowering + Lean 4 emitter of `pionc extract-lean` (§3.5)
      mutarg.pion          # codegen lowering of `mut self` receivers to in-out places
      qbe.pion             # QBE IL emitter (arm64_apple & amd64_sysv)
      cas.pion             # Global CAS hashing & LRU cache manager
      diag.pion            # JSON diagnostics
      query.pion           # Symbol/signature/call-graph/workspace query engine
      fmt.pion             # Deterministic formatter
      manifest.pion        # pion.toml / pion.lock / registry parser
    cli/                   # Pure Pion native CLI driver (main.pion, World + parallel scope/spawn)
```

- **Stage 0 (`pionc0`)**: Decompress `bootstrap/pionc-seed.ssa.gz` and compile it with the embedded C11 `qbe` + `runtime/libpionrt.a` + system `cc` → `out/pionc0` (requires only a C11 compiler; works natively on macOS ARM64, Linux x86_64, and Linux ARM64).
- **Stage 1 (`pionc1`)**: `pionc0 build` compiles `src/core` + `src/cli/main.pion` → `out/pionc1`.
- **Stage 2 (`pionc2`)**: `pionc1 build` compiles `src/core` + `src/cli/main.pion` → `out/pionc2` (using `Pion`'s own native multithreaded package compilation).
- **Fixed-Point Proof**: QBE IL & assembly emitted by `pionc1` vs `pionc2` for `pionc` itself MUST be **bit-for-bit identical** (SHA-256 match). On Linux x86_64, Stage 3 == Stage 4 is likewise bit-for-bit identical across `.ssa`, `.s`, and direct `qbe --obj` ELF64 `.o` (zero `as`).

---

## 3. Core Language Grammar

### 3.1 Lexical Elements
- Comments: `// line comment` (including `///|` block separators ignored as comments).
- Identifiers: `[a-zA-Z_][a-zA-Z0-9_]*`
- Literals:
  - `Int`: decimal `42`, hex `0xFF`, negative `-1`
  - `Int64`: `42L`, `0xFFL`
  - `UInt`: unsigned 32-bit `42U`, `0xFFFF_FFFFU` (and unsuffixed integer literals when expected type is `UInt`)
  - `UInt64`: unsigned 64-bit `42UL`, `0xFFFF_FFFF_FFFF_FFFFUL` (and unsuffixed integer literals when expected type is `UInt64`)
  - `Double`: `3.14`, scientific notation `1e-9`, `1.5E+3`
  - `Float`: IEEE-754 32-bit single-precision `1.5f`, `0.0f` (unsuffixed floating literals such as `1.0` or `-2.5` infer `Float` directly in `Float` expected-type contexts—`let : Float`, `Float` parameters/fields/returns—emitting 32-bit `s_<lit>` directly; non-literal `Double` values never implicitly convert to `Float` and require explicit `.to_float()`; QBE `s`, C ABI `float`)
  - `Bool`: `true`, `false`
  - `Byte`: `b'a'`, `b'\n'`, `b'\x00'`
  - `Char`: `'a'`, `'\n'`, `'\x41'`, `'\u{0C}'`, `'\u{4E2D}'` (`\u{H...}`: 1–6 hex digits, Unicode scalar `0x0..=0x10FFFF` excluding surrogates `0xD800..=0xDFFF`)
  - `String`: UTF-8 bytes (`length()` / `code_unit_at` count bytes); `"..."` holds any UTF-8 text kept byte-for-byte, with escapes `\n`, `\r`, `\t`, `\\`, `\"`, `\0`, `\xHH`, and `\u{H...}` (1–6 hex digits encoded as standard UTF-8 for Unicode scalars `0x0..=0x10FFFF` excluding surrogates); string interpolation `"...\{expr}..."` supporting `String`, `Int`, `Int64`, `UInt`, `UInt64`, `Double`, `Float`, `Bool`, `Char` (plain strings without `\{` remain zero-allocation `.rodata` immortal strings).
  - Multi-line raw string literals: `#|...` — consecutive lines prefixed with `#|` (separated by `\n` and optional leading spaces/tabs, stripping `\r` in `\r\n`) are joined with `\n` verbatim without escape or interpolation processing (UTF-8 preserved byte-for-byte; `#derive(...)` attributes remain unaffected).
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

[pub] fn name[T1](p1 : Type1, w~ : Type2 = default_expr, opt? : Type3) -> RetType {
  ...
}
// Named & optional default parameters (zero-ABI-overhead, resolved at call sites):
// - `w~ : T` or `w~ : T = def` (labeled parameter, optional default)
// - `opt? : T` (optional parameter, bound as `Option[T]` inside body, defaults to `None`)
// - `p : T = def` (positional parameter with default, also passable by name)
// - Call sites: `f(w=10.0)` / `f(w~)` (punned) / `f(opt=val)` (auto-wrapped in `Some`) / `f(opt?=opt_val)` (Option forwarding) / `x |> f(w=10.0)`

[pub] fn TypeName::method(self : TypeName, p1 : Type1) -> RetType {
  ...
}

[#verify | #verify_opaque] [pub] fn name(mut p1 : Type1, p2 : Type2) -> RetType { ... }
// `mut p : T` (also `mut self : Self`/`mut self : T`): second-class in-out parameter (§3.4);
// call sites pass `mut <place>`: `f(mut x)`, `f(mut s.field)`, `f(mut arr[i])`.

#verify impl Name for TypeName { ... }   // every method #verify unless it is #verify_opaque
#![verify]                               // file-level: lowering of `[verify] enabled = true` (§6)

[pub] extern "C" fn name(p1 : Type1, [..., v1 : VarType1, ...]) -> RetType [= "c_symbol"] [{ ... }]

[pub] trait Name {
  method(self : Self, p1 : Type1) -> RetType
}

impl Name for TypeName {
  fn method(self : TypeName, p1 : Type1) -> RetType { ... }
}

[pub] let CONST_NAME : Type = expr

test "test name" {
  ...
}
```
- Optional trailing commas and optional semicolons (newline-terminated statements, matching MoonBit).
- Attributes `#verify` / `#[verify]` and `#verify_opaque` / `#[verify_opaque]` apply to `fn`s, methods, `impl` methods and (`#verify` only) whole `impl` blocks; they combine with `#no_io` and `#derive(Eq)` (§3.4).
- `pub` marks items exported in `.pionsig` and accessible from downstream packages via `alias::symbol`. Referencing a non-`pub` symbol from an imported package is a compile-time error (`E_PRIVATE_SYMBOL`).
- `val struct` asserts at compile time that the struct has zero `mut` fields and every field is `Send`.
- `test "name" { ... }` blocks are type-checked by `pionc check`, omitted (0 bytes) by `pionc build`, and compiled with active `debug_assert` by `pionc test [--json] [--filter <substr>] <path>`.
- Files named `*_test.pion` (in the package root, `src/`, or `tests/` when `tests/` does not contain its own `pion.toml`) belong to their package only under `pionc test` (the root package of a workspace, or a directory target); `check`, `build` and `run` skip them.
- A struct field may be written `pub name : Type` (MoonBit compatibility); the fields of a `pub struct` are always visible to importers.
- **Trait objects (`dyn Trait`)**: `dyn Trait` / `dyn pkg::Trait` is a type usable anywhere a type is (parameters, returns, locals, struct fields, `Array[dyn T]`, `Option[dyn T]`). A value of any type with an `impl Trait for Type` (structs, enums, `Int`, `String`, ...) converts to `dyn Trait` implicitly where that type is expected (`let d : dyn Describe = Dog::{ ... }`, arguments, returns, array literal elements, `push`, `Some(...)`) or explicitly with `expr as dyn Trait`; a type without the impl is `E_TRAIT_NOT_IMPLEMENTED` (with an `impl` skeleton edit). Method calls on a `dyn Trait` value dispatch dynamically and are type-checked against the trait's signatures.
  - **Object safety**: every method of the trait must take `self : Self` as its first parameter, must not mention `Self` in any other parameter and must not return `Self`; otherwise `dyn Trait` is `E_TYPE_MISMATCH` ("trait `T` is not object-safe ..."). An unknown trait name is `E_UNKNOWN_TRAIT`; a private trait of an imported package is `E_PRIVATE_SYMBOL`.
  - `dyn Trait` is `!Send` (it may hide a non-`Send` value): capturing one in `spawn` or sending it over a `Channel` is `E_NOT_SEND`. `==`/`!=` are not defined on it.

### 3.3 Statements & Expressions
- `let x = expr` / `let x : Type = expr` / `let mut x = expr`
  - An unannotated empty collection (`let xs = []`, `Array::new()`, `Array::with_capacity(cap)`, `let m = Map([])`, `Map()`, `Map::new()`, `Map::with_capacity(cap)`) takes its type, within its own block, from (1) the block's tail expression `xs` (the block's expected type) or a later `return xs` (the enclosing function's return type) when that is `Array[T]` / `FixedArray[T]` / `Map[K, V]`, else (2) the first `xs.push(v)` → `Array[typeof v]`, `m.set(k, v)` / `m[k] = v` → `Map[typeof k, typeof v]` (later uses are checked against it). A rebinding of the same name ends the search. If none applies, it is `E_MISSING_TYPE` ("cannot infer the element type of empty array `xs`" / "... key/value types of empty map `m`") — never a silently untyped collection. Codegen reuses the checker's inferred type, so heap elements are always owned (`pion_arr_new(n, 1)`). `Array::with_capacity(cap)` clamps negative `cap` to `0` and preallocates backing storage (`pion_arr_new`); `Map::with_capacity(cap)` validates `cap : Int` and constructs an empty map.
- Tuple destructuring & element indexing: `let (a, b) = expr` / `let (a, _, c) : (T1, T2, T3) = expr` (`_` ignores an element), and `t.0` / `t.1` tuple element access; tuple literals propagate element expected types (`(n, None)` as `(Node, Option[Node])` uses null-niche `0`)
- Assignment & compound assignment: `x = expr`, `obj.field = expr`, `arr[i] = expr`, and `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=` (receiver/index evaluated once; `+=` also supports `String` concatenation)
- Struct literals: field shorthand `Foo::{ x, y }` and functional update `Foo::{ ..base, x: 1 }` (copies non-overridden fields with RC retention)
- Control flow:
  - `if cond { ... } else if cond2 { ... } else { ... }` (expression when all branches yield same type; `expr is Pattern` in `if`/`while`/`guard` binds pattern variables into the matching branch, `&&` right-hand side, or enclosing block)
  - `guard cond else { diverge_block }` and `guard expr is Pattern else { diverge_block }` (early exit on mismatch; binds pattern variables into the enclosing block for subsequent statements)
  - `while cond { ... }` (including `while expr is Pattern { ... }`)
  - `for i = 0; i < n; i = i + 1 { ... }`, `for i in start..end { ... }` / `for i in start..<end { ... }` (half-open `[start, end)`), `for i in start..=end { ... }` (closed `[start, end]`, overflow-safe), `for x in arr { ... }` and `for i, x in arr { ... }` (`Array[T]` and `FixedArray[T]`)
  - Error propagation: postfix `expr?` on `Result[T, E]` (enclosing function returns `Result[_, E]`) and `Option[T]` (enclosing function returns `Option[_]`)
  - `match scrutinee { Pat [if guard_cond] => expr, ... }` (exhaustive checking required on `enum`, `Bool`, `Option`, `Result`; wildcard `_` allowed; guarded arms do not satisfy exhaustiveness on their own, and failed guards release arm pattern bindings and fall through to subsequent arms)
  - `return [expr]`, `break`, `continue`
- Closures: `fn(x : T) -> R { ... }` (captures immutable variables by value / biased RC; outer `let mut` variables captured by a local non-`spawn` closure are automatically promoted to a shared 1-slot RC heap cell so outer and inner scopes—including nested closures—share live reads and writes with zero manual boxing, while uncaptured `let mut` variables remain zero-overhead stack locals. Inside `spawn(...)`, capturing any outer `let mut` variable—directly or via a nested closure—remains a compile-time error `E_NOT_SEND`, and only `Send` or `move` captures are allowed.)
- Callable struct fields: when `d.f(args...)` is called on a `struct` value `d` and no method `Struct::f` exists, if `d` has a field `f` of function type `(P...) -> R`, the compiler loads and invokes the closure directly (methods still take precedence when both exist).
- Leading-dot enum variant inference (`.Variant` / `.Variant(args...)`):
  - In any expression context with a known expected `enum`, `Option[T]`, or `Result[T, E]` type (function/named/optional parameters including `opt? : E` via `opt=.Variant`, `let x : E = .Variant`, return expressions, struct fields, array/tuple elements, `match` arms, and bidirectional `==`/`!=` comparisons `x == .Variant` or `.Variant == x`), `.Variant` / `.Variant(args...)` resolves the variant from the expected type (same-package or cross-package) with zero runtime overhead. Without a known enum/Option/Result expected type, it reports `E_TYPE_MISMATCH`.
  - Patterns also accept leading-dot syntax `.Variant` / `.Variant(pats...)` in `match` and `is` (resolving against the scrutinee type).
- Pure compile-time desugared Pion-JSX (`<Tag ... />`, `<Tag ...> ... </Tag>`, `<> ... </>`):
  - Zero new keywords, zero framework coupling, zero VDOM: JSX is desugared purely in the parser into ordinary Pion function calls (`ECall`) and blocks (`EBlock`). Because Pion generics use `[T]`, `<` in primary expression position is unambiguous.
  - Tag name: `Tag` (`EIdent`) or `pkg::Tag` (`EPath`).
  - Attribute forms:
    1. `prop="text"` / `prop="text \{expr}"` -> `prop="text"` (string literal or interpolation)
    2. `prop={expr}` -> `prop=expr` (arbitrary Pion expression; outer JSX parent stack is isolated inside attribute expressions)
    3. `prop=>{ stmts }` -> `prop=fn() { stmts }` (zero-argument closure shorthand for reactive getters and event callbacks)
    4. `prop` (bare attribute) -> `prop=true` (boolean flag)
  - Parent injection (`in={parent}`): if `in={expr}` is written, `expr` is passed as the first positional argument (duplicate `in` is `E_PARSE`); otherwise, when nested inside a parent element `<Parent>...</Parent>`, the parent's synthetic child parameter `__jsx_p_N` is injected automatically as the first positional argument (including inside `if`/`for`/`while`/`match`/`{ ... }` blocks in children).
  - Children: non-empty `<Tag ...> children... </Tag>` appends `children=fn(__jsx_p_N) { children... }` as a named argument; self-closing `<Tag ... />` or empty `<Tag></Tag>` omits `children`. Fragments `<> ... </>` desugar to `{ ... }` while preserving the enclosing parent stack. Mismatched closing tags report `E_PARSE`.
  - `pionc fmt` formats Pion-JSX (nested tags, fragments, self-closing tags, multi-line attributes) deterministically and idempotently without disturbing `<` / `>` / `..<` / `=>` / `->` operators.
- Concurrency (Pion native):
  - `scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { ... }) })`
  - `Channel::new(cap)`, `ch.send(v)`, `ch.recv() -> Option[T]`, `ch.close()`
  - `Mutex::new(v)`, `m.with_lock(fn(v : T) -> R { ... })` / `m.lock()` + `m.set(v)` + `m.unlock()`
  - `AtomicInt::new(v)`, `a.load()`, `a.store(v)`, `a.fetch_add(d)`
- Contracts: `debug_assert(cond, "msg"[,])` (statement or expression position, type `Unit`; optional trailing comma)
- Built-in conversions and helpers:
  - Scientific notation `Double` literals (`1e-9`, `1E9`, `1.797e308`, `1.0e+5`) and `\xHH` raw byte escapes in string literals
  - `Int::to_double() -> Double`, `Int::to_float() -> Float`, `Int::to_uint() -> UInt`, `Int::reinterpret_as_uint() -> UInt`, `Int::abs() -> Int`, `Int64::to_double() -> Double`, `Int64::to_uint64() -> UInt64`, `Int64::reinterpret_as_uint64() -> UInt64`, `Int64::abs() -> Int64`, `Double::to_int() -> Int`, `Double::to_int64() -> Int64`, `Double::to_float() -> Float`, `Double::to_bits() -> Int64`, `Double::reinterpret_as_uint64() -> UInt64`, `Double::from_bits(bits : Int64) -> Double`, and `Double` methods `abs()`, `floor()`, `ceil()`, `round()`, `trunc()`, `sqrt()` (all 0-byte runtime)
  - `Float` (IEEE-754 f32, QBE `s`, C ABI `float`, 0-byte runtime): `Float::from_double(Double)`, `Float::from_int(Int)`, `Float::from_bits(Int)`, and methods `to_double()`, `to_int()`, `to_int64()`, `to_bits()`, `reinterpret_as_int()`, `reinterpret_as_uint()`, `abs()`, `sqrt()`, `floor()`, `ceil()`, `round()`, `trunc()`, `to_string()`
  - `UInt` / `UInt64` (unsigned 32/64-bit, QBE `w`/`l` with `udiv`/`urem`/`shr`/`cult*`/`cule*`/`cugt*`/`cuge*`, 0-byte runtime): `UInt` methods `to_int()`, `reinterpret_as_int()`, `to_int64()`, `to_uint64()`, `to_double()`, `to_float()`, `reinterpret_as_float()`, `to_string()`; `UInt64` methods `to_int()`, `to_uint()`, `to_int64()`, `reinterpret_as_int64()`, `to_double()`, `reinterpret_as_double()`, `to_string()`
  - `FixedArray[T]` (fixed-length heap array backed by `PionArray`, distinct from `Array[T]`, 0-byte runtime) & `Array::make(len, init)`: `FixedArray::make(len, init)`, `FixedArray::makei(len, f)`, `FixedArray::from_array(a)`, `[...]` when expected type is `FixedArray[T]`, indexing `a[i]` / `a[i] = v` / compound assign, `length()`, `contains(v)`, `fill(v)`, `copy()`, `blit_to(dst, len~, src_offset~=0, dst_offset~=0)`, `for [i,] x in a`, and `array_data_ptr(a)`
  - `arr.swap(i : Int, j : Int) -> Unit` on `Array[T]` and `FixedArray[T]`: inline bounds checks (`pion_panic_oob`) and an in-place exchange of the two elements' storage — two 64-bit data slots, two bytes for compact `Bool`/`Byte` arrays, or every 8-byte field slot of a flat POD struct element (`elem_stride` 16/24/32); both sides are loaded before either store, so `i == j` is a no-op (element ownership stays in the array: no RC traffic, 0 runtime bytes)
  - `Map::clear() -> Unit` (`pion_map_clear`)
  - `ignore(x : T) -> Unit` (releases non-borrowed heap value, 0-byte runtime)
  - `s.to_int() -> Option[Int]`, `s.to_int64() -> Option[Int64]`, `s.to_double() -> Option[Double]` on `String` (`None` on any malformed or out-of-range input; no exceptions, no partial parses)
  - `o.is_some()`, `o.is_none()`, `o.unwrap_or(default)` on `Option[T]`
  - `r.is_ok()`, `r.is_err()`, `r.unwrap_or(default)` on `Result[T, E]`
- Operators: `+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`, `&`, `|`, `^`, `<<`, `>>`, unary `-`, range `..` / `..<` / `..=`, pipe `|>`, pattern test `is`, compound assign `+=`/`-=`/`*=`/`/=`/`%=`/`&=`/`|=`/`^=`/`<<=`/`>>=`, postfix `?`.
- Equality: `==` / `!=` compare by value and are defined only on `Int`, `Int64`, `UInt`, `UInt64`, `Double`, `Float`, `Bool`, `Byte`, `Char`, `String` (content), `Ptr` (address), `Unit`, generic `T` (checked at every instantiation: a type parameter compared with `==`/`!=` in a generic body, directly or through generic callers, must be instantiated with one of these types, else `E_TYPE_MISMATCH` at the call site; such generics are monomorphized so `String` compares bytes and payload-less enums compare tags), `#derive(Eq)` structs/enums, and payload-less `enum`s (every variant has no fields; compared by variant tag, also across packages). On `Option`, `Result`, non-`#derive(Eq)` `struct`, `Array`, `FixedArray`, `Map`, `Bytes`, tuples and non-`#derive(Eq)` payload-carrying `enum`s they are a compile-time error (`E_TYPE_MISMATCH`, "operator `==` is not supported on `<Ty>` (no implicit pointer-identity comparison)", fix-it "use `match` to inspect `<Ty>` values") — there is no implicit pointer-identity comparison.
- Must-use `Result` & `-> Unit` implicit tail discard: when a function, closure, block, `if`, or `match` arm expects `Unit`, a non-`Result` tail expression is implicitly discarded (with RC release for heap values) so builder chains and side-effect calls do not require `let _ = ...`. An expression statement whose type is `Result[T, E]` and whose value is discarded — any non-tail statement of a block, or the tail statement of a `-> Unit` body, loop, or `test` body — is still a compile-time error (`E_UNHANDLED_RESULT`, fix-it "handle the Result with `match`, `?`, or explicitly discard with `let _ = ...`"). `let _ = expr` discards explicitly; a block's tail value returned to a non-`Unit` function or branch is not discarded.

### 3.4 Second-Class `mut` Parameters & `#verify`

**`mut` parameters (all code).** A parameter written `mut p : T` (top-level `fn`s, methods, trait methods and `impl` methods; `mut self` included) is an in-out parameter:
- It must be a plain positional parameter: `mut p~`, `mut p?`, `mut p : T = d`, `mut` on `extern "C" fn` parameters and on closure parameters are `E_PARSE`.
- Inside the body `p` is a mutable binding: `p = v`, `p.f = v`, `p[i] = v`, and passing `mut p` down are allowed. A closure may not capture a `mut` parameter (`E_TYPE_MISMATCH`; `E_VERIFY_CLOSURE_CAPTURE` in `#verify` code).
- Call sites pass `mut <place>` where a place is `x`, `x.f1.f2`, `a[i]` or a combination, rooted at a `let mut` binding or a `mut` parameter; a field written through it must be a `mut` field; an index must be a simple expression (locals, literals, fields, arithmetic; no calls). A method whose receiver is `mut self` is called as `recv.m(...)` without `mut`, and `recv` must be such a place. Violations are `E_TYPE_MISMATCH`: an immutable root (with the `let` → `let mut` edit), a plain argument for a `mut` parameter (with a `mut ` insertion edit for identifiers), `mut` for a non-`mut` parameter, a non-place, an argument type that is not exactly the parameter type. `mut <place>` anywhere else (an expression, a builtin's argument) is `E_TYPE_MISMATCH` (or `E_PARSE` outside an argument list).
- Aliasing (`E_VERIFY_ALIASING`, all code): within one call (receiver included), the place of a `mut` argument must not equal, contain or be contained in the place of any other argument (`f(mut a, mut a)`, `f(mut s, mut s.x)`, `f(mut s.x, s)`, `f(mut a[i], mut a[j])` are rejected; distinct fields `f(mut s.x, mut s.y)` are fine), and must not be rooted at a local read by another `mut` argument's index (`f(mut a[k], mut k)`).
- A function with `mut` parameters cannot be used as a first-class value (`E_TYPE_MISMATCH`); a trait with `mut` parameters is not object-safe for `dyn` (call it through a generic bound); an `impl` method's `mut` markers must match its trait's (`E_TRAIT_METHOD_SIGNATURE`).
- Evaluation: arguments are evaluated left to right; a `mut` argument's place is read at its position, and after the call returns every `mut` place is assigned the final value in argument order.

**ABI.** A `mut` parameter is passed as `l`: a pointer to a 64-bit value slot (uniform heap-slot encoding: `Int`/`UInt` as sign/zero-extended `l`, `Double` as `d` bits, objects as `PionObj*`). The caller moves the place's current value into a fresh `alloc8 8` slot, passes its address, and after the call assigns the slot's value back to the place (ordinary assignment semantics, so cells, fields and bounds-checked elements behave as `place = v`). The callee copies the slot into an ordinary owned local (retained) and, on every exit path, stores the local back into the slot and releases the slot's previous value. Functions with `mut` parameters are never inlined. The emitted IL is plain QBE (the Wasm32 backend treats the passed slot as escaping); this ABI is part of `PION_COMPILER_ABI_REV` `pionc-v0.17`.

**`#verify`.** A `#verify` function / method (or every method of a `#verify impl`, or every function of a `[verify] enabled = true` package, §6; `#verify_opaque` opts out) is additionally checked by these rules; non-`#verify` code is unaffected. Types are classified as **Forbidden** (`World`, `Ptr`, `Scope`, `Channel`, `Mutex`, `AtomicInt`, `Float`, `dyn Trait`, or anything containing them), **Unique** (`Array`, `FixedArray`, `Bytes`, `StringBuilder`, `Map`, structs with a `mut` field, generic parameters, and anything containing a Unique type) or **Copy** (everything else: integers, `Double` as an opaque 64-bit bit pattern, `Bool`, `Byte`, `Char`, `Unit`, `String`, immutable structs / enums / tuples / `Option` / `Result` of Copy types).
- `E_VERIFY_UNSUPPORTED`: a Forbidden type in a parameter, the return type, a binding or an expression (reported once per type per function), or floating-point `Double` literals / arithmetic / comparisons / non-bit-pattern methods (only `Double::from_bits`, `.to_bits()`, `.reinterpret_as_uint64()`, and `UInt64::reinterpret_as_double()` are allowed on `Double` in `#verify`).
- `E_VERIFY_MOVE`: a Unique local is moved by `let y = x`, `y = x`, storage into a struct / enum / array / tuple literal or a storing builtin (`push`, `set`, `fill`, variant constructors), `return` / tail position; moving a path `x.f` / `x[i]` moves `x`. Reading a moved binding is an error; moves merge across `if` / `match` branches (moved on any non-diverging branch ⇒ moved after), loop bodies are checked for moves carried into the next iteration, and `x = new` revives `x`. `x.copy()` produces an owned copy.
- `E_VERIFY_BORROW_ESCAPE`: a non-`mut` Unique parameter is a read-only borrow (calls with non-`mut` parameters never consume the argument): it may be read, indexed, passed on read-only and `.copy()`ed, but not written (field / element assignment, mutating builtins such as `push` / `pop` / `set` / `swap` / `clear` / `sort` / `fill`) nor moved (bound by `let`, stored, returned). Pattern and `for x in` bindings projected from a borrowed (or any place) Unique value are read-only too.
- `E_VERIFY_MUT_ESCAPE`: a `mut` parameter (or a Unique binding projected from it) cannot be moved out (bound by `let`, stored, returned); use `.copy()`.
- `E_VERIFY_CLOSURE_CAPTURE`: a closure may capture only immutable Copy bindings.
- `E_VERIFY_ALIASING` (borrowed views): while `for x in r` iterates (any element type) or a `match` arm / `is` branch / `guard ... is` binding holds a Unique part of a place rooted at `r`, `r` is pinned: writing through it (field / element assignment, mutating builtins, `mut self` calls), rebinding it, passing it as `mut <place>` or moving it is an error until the loop body / arm / branch / enclosing block ends.
- `E_VERIFY_UNVERIFIED_CALLEE`: `#verify` code may call `#verify` / `#verify_opaque` functions and methods, `extern "C"` functions, builtins, closures and trait-bound methods; calling an unmarked user function is an error (the marks travel in `.pionsig` / `.pionstub`). Instantiating a generic callee's bound `T : Trait` with a concrete type from `#verify` code requires every method of that `impl` to be `#verify` / `#verify_opaque`.
- Runtime arithmetic (only in `#verify` functions, so ordinary code keeps its codegen): integer `/` and `%` panic with `division by zero` when the divisor is 0, and signed `Int` / `Int64` `MIN / -1` and `MIN % -1` panic with `integer overflow in division`; `<<` / `>>` panic with `shift amount out of range` unless `0 <= rhs < 32` (`Int`, `UInt`) / `64` (`Int64`, `UInt64`), comparing the count at its own width (a 64-bit count is never truncated, so `1L << (1L << 32)` panics). Other integer arithmetic wraps (two's complement) in all code.

**ResolvedInfo side tables** (on `TypeChecker`, recorded for expressions and calls inside `#verify` functions, for the Lean extractor): `expr_tys` (`span_key(expr span)` / pattern-binding span → type), `call_targets` (call span → `pkg::fn`, `pkg::Type::method`, `Trait::Type::method`, `builtin::...`, `closure::name`), `call_type_args` (generic instantiation), `call_arg_order` (resolved parameter slot → written argument index, `-1` for defaults / implicit `None`), next to `let_infer`, `closure_infer`, `dot_variant_resolve`; `mut_recv_calls` marks `mut self` calls for codegen.


### 3.5 Lean 4 Extraction (`pionc extract-lean`, Pion-LLBC)

`pionc extract-lean` (§5.5) translates the `#verify` closure of a checked workspace into Lean 4 on top of `Aeneas.Std` and the thin `PionLean` library (`lean/`, Lean `v4.36.0-rc2`, Aeneas `1dc8ad31b1`). Ordinary compilation never runs it and gains no syntax for it.

- **Closure.** Every `#verify` function, method and `impl` method (non-`#verify_opaque`) of the extracted packages, plus everything they reach: called `#verify` functions (any package), `#verify impl` dictionaries passed for trait bounds, the structs / enums / traits / constants they mention, and called `#verify_opaque` / `extern "C"` functions (as axioms only).
- **Pion-LLBC** (`compiler/src/core/llbc.pion`): a structured IR built from the AST and the ResolvedInfo side tables. Pure expression trees (literals, variables, wrapping arithmetic, comparisons, field / tuple reads, constructors) and monadic steps (calls, `/ % << >>`, indexing, `?`, `mut` arguments) are separated in strict left-to-right order (a pure operand is copied when a later operand may write it); `for` (C-style, `..` / `..<` / `..=` without computing `end + 1`, `for [i,] x in arr`), `while`, `guard`, `?`, compound assignment, named / default / optional arguments (`call_arg_order`), leading-dot variants, `..base`, tuple destructuring, `is` / `&&` conditions, literal patterns and match guards (falling through to later arms) are desugared into `if` / `match` / `loop` / `break` / `continue` / `return`. Every binding gets a function-unique name and a type; struct / enum / trait names are globally qualified.
- **Lean output per package `pkg`** (module root `Pkg`, `my_pkg` → `MyPkg`; namespace `pkg`): `Pkg/Types.lean` (structs → `structure`, recursive structs / enums → `inductive` (mutually recursive SCCs in `mutual … end`; a recursive struct gets `Name.f` accessors and `Name.set_f` updates), traits → `structure Trait (Self : Type _)` of methods, `#derive(Eq)` and payload-less enums → `deriving BEq` + `Pion.Eq` instance), `Pkg/Funs.lean` (constants, functions, `impl` dictionaries `Type.Insts.Trait`, in dependency order; (mutually) recursive functions are `partial_fixpoint` in `mutual … end`), `Pkg/FunsExternal_Template.lean` (axioms of the external callees, rewritten on every run; definitions that transitively call one are `noncomputable`, everything else stays executable with `#eval`) and `Pkg/FunsExternal.lean` (a copy of the template, written only when absent or still identical to the previously generated template, so a package builds out of the box and a user-edited file is never overwritten). Upstream packages are imported as `Dep.Types` / `Dep.Funs`. Lean keywords are `«»`-escaped; user items named like names the generated code uses (`ok`, `loop`, `Result`, `Option`, …) get a trailing `_`.
- **Types.** `Int` `Std.I32`, `Int64` `Std.I64`, `UInt` `Std.U32`, `UInt64` `Std.U64`, `Byte` `Std.U8`, `Double` `Pion.Double` (64-bit bit-pattern wrapper), `Bool`, `Char`, `String`, `Unit`, `Option[T]` `Option T`, `Result[T, E]` `Pion.Res T E`, `Array[T]` `Pion.Array T`, `FixedArray[T]` `Pion.FixedArray T`, `Bytes` `Pion.Bytes`, `StringBuilder` `Pion.StringBuilder`, `Map[K, V]` `Pion.Map K V`, tuples `A × B × C`; type parameters stay polymorphic (`{T : Type _}`), each bound `T : Tr` is an explicit dictionary parameter `(inst_T_Tr : Tr T)`, and a type parameter compared with `==` or used as a `Map` key gets `[Pion.Eq T]`.
- **Functions.** `def f (a : A) … : Result R`; with `mut` parameters the result is `R × B × C` (`B × C` when `R = Unit`, a single `B` for one) and every exit returns the final values of the `mut` parameters. Mutable state is threaded functionally with fresh SSA names: `x = e` → `let x1 := e`, `s.f.g = e` → nested `{ s with f := { s.f with g := e } }`, `a[i] = e` → `Pion.Array.set`, and a `mut <place>` argument is read before the call and written back field by field afterwards (`mut s.x, mut s.y` update the same `s` in order). Integer `+ - * & | ^` and unary `-` are the wrapping `Pion.I32.add/sub/mul/band/bor/bxor/neg` (per scalar type); `/ % << >>` are `Pion.I32.div/rem/shl/shr`, failing exactly like the native `#verify` checks (`divisionByZero`; `integerOverflow` for `MIN / -1`, `MIN % -1` and a shift amount outside `[0, bits)`); a shift of a non-`Int` left operand by an `Int` count is the mixed `Pion.I64/U32/U64.shl_i32/shr_i32`; comparisons are `Bool` (`Prop` in `if` conditions); `debug_assert(c, …)` is `Pion.debugAssert c`, unreachable code `Pion.panic`.
- **Control flow.** Each loop becomes `f_loopN.body` (`Result (ControlFlow σ σ)` over the loop-carried variables σ, or `ControlFlow σ (Sum R σ)` when it may `return`) and `f_loopN := loop (fun σ => f_loopN.body …) σ` (`Aeneas.Std.loop`); other free variables are parameters. An `if` / `match` whose other branches diverge, or that contains `break` / `continue`, takes the rest of the block into its branches; one that updates outer variables returns them as a tuple (`Sum R σ` with an early `return`) that the rest of the block destructures; one in tail position ends the function itself. The generated `do` blocks use only the subset of Aeneas' `do` elaborator (no early `return`, every `if` has an `else`).
- **Not extractable** (`E_EXTRACT_UNSUPPORTED`, nothing is written): closures and closure calls, string interpolation, `as`, builtins without a `PionLean` model (e.g. `Array::sort`, `String` methods other than `length`), `Byte` shifts, trait dictionaries inside a recursion cycle. (A loop of a recursive function is emitted as a directly recursive `partial_fixpoint` definition in the function's `mutual` block instead of through `Aeneas.Std.loop`.)

### 3.6 Verified QBE Translation Validation (`tools/qbe_tv`, `tools/qbe_tv_cli`)

`tools/qbe_tv` (`[verify] enabled = true`, extracted to Lean as `QbeTv`) checks that a QBE function after the SSA optimisations refines the function before them; `tools/qbe_tv_cli` (`qbe-tv`) is the untrusted text front end.

- **Subset.** `ir.pion`: integer `w` / `l` values (a `w` value is kept zero-extended), `par`, unary / binary operators with `vendor/qbe/fold.c` semantics (`div` / `udiv` / `rem` / `urem` trap on 0 and on `MIN / -1`), loads / stores of 1 / 2 / 4 / 8 bytes, calls, `alloc`, phis, `jmp` / `jnz` / `ret` / `hlt`. Anything else makes the front end skip the function.
- **Refinement.** Every terminating execution of the source with a result (return value or `hlt`, plus the final world after its loads / stores / calls / allocs) is matched by an execution of the target with the same result. Loads and trapping divisions of the source may be dropped (they do not change the world unless they trap, and a trap is undefined behaviour); every other effect is kept in order with equal operands.
- **Solver vs. checker.** `build_cert` (untrusted) computes a `Cert`: a frozen value graph (`canon.pion`, an append-only hash-consed DAG whose rewrites are exact 32 / 64-bit identities), the symbolic value of every source / target temp, the initialisation certificates (`savail` / `tavail`), the branch facts, the target-to-source block map, and the matched block pairs, each with its replay steps (`MatchEff`, `SkipSrcReadOnly`, `SrcJmp`, `SrcJoin`, `TgtJmp`, `BothJmp`) and its end (`EndRet`, `EndHlt`, `EndJmp`, `EndJnz`, `EndSrcBranch`, `EndTgtBranch`, naming the successor pairs). `verify_cert` re-checks all of it from the two functions alone; `validate_fn(src, tgt) = build_cert` then `verify_cert`.
- **Cost.** No pass is super-linear in the value graph per query: `vg_intern` probes an open-addressing index (`ValGraph.buckets`, rebuilt below load ½; only an accelerator, every hit is compared with `sym_node_eq`), `blk_mentions_table` decides "depends on block b" for every node in one forward sweep (used by `check_avail` once per mapped source block and by `check_facts` once per run of facts of a block), `facts_of` / `fact_in_blk` / `bm_has` binary-search the solver's block-sorted `facts` / `bm_t` (on unsorted input they only find fewer entries), `compute_avail` is one reverse-postorder pass over the dominator tree (Cooper–Harvey–Kennedy), and `compute_facts` keeps at most 16 facts per block (the most recent edge facts first) and prunes until every fact holds on every incoming edge.
- **`qbe-tv --trace <dump>`** validates, for every function of a `qbe -d MG` dump, `After load elimination` directly against `After GCM` (GVN, `simplcfg` and GCM in one step; `Slot coalescing` instead, counted as skipped, when coalescing killed or fused slots). **`qbe-tv --pair <before.ssa> <after.ssa>`** validates the functions of two files by name. Both print `VALIDATED` / `SKIPPED` / `REJECTED <fn>: <reason>` and `validated=N skipped=M rejected=K`; exit 1 when something is rejected, 2 under `--strict` when something is skipped.
- **Gate.** `scripts/test-tv.sh <pionc> <qbe>` (part of `verify-all.sh` [5/6] and `test-linux.sh` [6/6]): the real `qbe -d MG` traces of `tests/tv/opt_suite.pion` and `tests/lean/{codec,algos,captable}` all validate (opt_suite with 0 skipped), the same traces with a `jnz` swapped after GCM are rejected, `tests/tv/good` validate, every `tests/tv/adversarial` miscompilation is rejected, and `tests/tv/qbe_bugs` (reproducers of the `vendor/qbe` bugs B1–B6 that `qbe-tv` + differential fuzzing found: `gvn.c` `dedupjmp` low-32-bit `jnz`, `copy.c` `phicopyref` phi class and `dwl` shift by 32, amd64 `jnz`/`sel` reusing a 64-bit ZF or a shift's ZF, amd64 text-asm shift immediates) give exact results through text assembly and `--obj`, and their trace validates (except B1, whose low-32-bit constant `jnz` fold is beyond `qbe-tv`'s completeness). `scripts/test-lean.sh` extracts `tools/qbe_tv`, builds `QbeTv` and checks the proofs about it: `tests/lean/proofs/QbeTvSem.lean` (exact 32 / 64-bit operator semantics, QBE function semantics, the value-graph denotation, `vg_intern` / `check_vg_dag` / `vid_mentions_blk`), `QbeTvCanon.lean` (soundness of `fits_bits` and of every `canon.pion` rewrite, over any graph `check_vg_dag` accepts) and `QbeTvProofs.lean`.
- **Proof (end to end).** `validate_fn_sound` (and `verify_cert_sound` for any `Cert`) is proved with zero `sorry` / `admit` / `bv_decide` / `native_decide`, and `#print axioms` of it and of every other theorem in `tests/lean/proofs/CheckAxioms.lean` shows only `propext`, `Classical.choice` and `Quot.sound`:
  `validate_fn src tgt = ok true → evalFunc src oracle args w0 fuel = some res → ∃ fuel', evalFunc tgt oracle args w0 fuel' = some res`, for every world type, world oracle, argument list, initial world and fuel. The layers: `QbeTvFacts.lean` (`wf_code`: blocks, an entry block without phis, successors in range and every instruction destination in `[0, ntemps)` (code 16 otherwise); `build_info`, `check_facts`, `check_avail`), `QbeTvReplay.lean` (`check_src_defs` / `check_tgt_defs`, the phi definitions: fold, sole predecessor, select, equal arguments), `QbeTvSim.lean` (the source run against a look-ahead symbolic environment fixed on each block entry), `QbeTvChecks.lean` (views, `match_effect_c`, the skips, `head_ok` / `edge_ok` / `next_ok`, `check_end`, trivial blocks), `QbeTvTgt.lean` (the target invariant and its stability while the source moves inside a pair) and `QbeTvProofs.lean` (one replay step and the replay loop, induction on the source fuel over the pairs, the decomposition of `cert_fail_code = 0`).

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
    uint16_t flags;            // bit 0: FROZEN, bit 1: IMMORTAL, bit 2: SLAB, bit 3: DEEP_FROZEN, bits 4..7: 12-class slab id
    PionDropFn drop_fn;        // Nullable destructor for releasing child pointers
} PionHeader;                  // Total: 24 bytes (clean 8-byte alignment on arm64/x64)
```
Payload immediately follows `PionHeader`: `void* obj = (char*)hdr + sizeof(PionHeader)`.
Header recovery: `PionHeader* hdr = ((PionHeader*)obj) - 1`.

**Immortal static strings** (`.rodata` string literals): `flags = PION_FLAG_IMMORTAL | PION_FLAG_FROZEN`, `owner_tid = 0`. `pion_rc_inc` / `pion_rc_dec` return immediately in 1 branch — **ZERO heap allocation and ZERO `init` code for string literals!**

### 4.1.1 `dyn Trait` Layout (compiler-emitted, no runtime symbols)
- A `dyn Trait` value is one 64-bit pointer (`l`) to a **16-byte fat-pointer box**, an ordinary RC object (`pion_alloc_uninit(16, 4, $pion_drop_dyn)`) whose payload is `{ l data, l vtable }`: `data` is the concrete value in its uniform 64-bit slot (an object pointer, or an `Int`/`Bool`/`Double` bit pattern), `vtable` points to static read-only data.
- One vtable per (trait, concrete type) pair, emitted once per package: `data $pion_vtable_<Trait>__<Type> = align 8 { l is_obj, l freeze_fn, l m0, l m1, ... }` — `is_obj` is `1` when `data` is a heap object, `freeze_fn` the concrete type's recursive freeze routine (or `0`), then one entry per trait method in declaration order. Each entry is a thunk `$pion_dyn_wrap_<Trait>__<Type>__<method>(l %self_raw, ...)` that narrows `self` to the concrete ABI type (`w` / `d` / `l`) and calls the impl method.
- `$pion_drop_dyn(l box)` (box destructor) `pion_rc_dec`s `data` when `is_obj`; `$pion_freeze_dyn(l box)` freezes the box and, through `freeze_fn`, the concrete value, so a `dyn` value stored into a frozen container keeps an atomic RC end to end.
- `Option[dyn Trait]` uses the **null niche**: `None` is the null pointer and `Some(d)` is the box pointer itself (no second allocation, no `$pion_drop_opt_obj` wrapper).
- The dyn ABI is part of `PION_COMPILER_ABI_REV` `pionc-v0.10` (§6), so objects cached by older compilers are never linked against it.

### 4.2 Required Runtime C ABI Functions (`pion_rt.h`)
All symbols use `pion_` prefix and C calling convention (`arm64_apple` / `amd64_sysv`):

**Memory & Biased RC:**
- `void* pion_alloc(uint32_t payload_size, uint16_t type_tag, PionDropFn drop_fn);`
- `void  pion_rc_inc(void *obj);` (no-op if NULL or `PION_FLAG_IMMORTAL`; fast non-atomic if `owner_tid == pion_cur_tid()`, else atomic)
- `void  pion_rc_dec(void *obj);` (no-op if NULL or `PION_FLAG_IMMORTAL`; frees + calls `drop_fn` when total RC hits 0)
- `void  pion_rc_freeze(void *obj);` (promotes `owner_tid` to 0 and moves `local_rc` into `shared_rc` before crossing thread boundary; freezing a `Map` also freezes its keys and object values)
- `void  pion_rc_immortalize(void *obj);` (marks a module-level heap constant and its reachable `Array`/`Map` children `PION_FLAG_FROZEN | PION_FLAG_IMMORTAL` during `init_consts`, making cross-thread reads zero-atomic-overhead and race-free)
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
- `void*   pion_bytes_from_ptr(void *p, int64_t len);` (`bytes_from_ptr(p : Ptr, len : Int) -> Bytes`, allocates `len` bytes and copies from `p`; `len <= 0` returns empty `Bytes`)
- `void    pion_bytes_copy_to_ptr(void *b, int64_t src_off, void *dst, int64_t len);` (`bytes_copy_to_ptr(b : Bytes, src_off : Int, dst : Ptr, len : Int) -> Unit`, bounds-checked `memcpy` from `b[src_off .. src_off + len)` to `dst`)
- `void*   pion_bytes_to_str(void *b);` (`b.to_string() -> String`)

**StringBuilder (`PionStrBuf`):**
- `void* pion_strbuf_new(int64_t cap);` (`StringBuilder()` / `StringBuilder::new()` uses `cap = 32`; `StringBuilder::with_capacity(cap : Int) -> StringBuilder` passes `cap`, clamped to at least 32)
- `void  pion_strbuf_push_str(void *sb, void *s);` (`StringBuilder::write_string(self, s : String) -> Unit`)
- `void  pion_strbuf_push_slice(void *sb, void *s, int64_t start, int64_t end);` (`StringBuilder::write_substring(self, s : String, start : Int, end : Int) -> Unit`; clamps `start` and `end` to `[0, s.length()]` and is a no-op when `start >= end`)
- `void  pion_strbuf_push_byte(void *sb, int32_t b);`
- `void  pion_strbuf_push_char(void *sb, int32_t cp);`
- `void  pion_strbuf_push_int(void *sb, int64_t v);`
- `void  pion_strbuf_reset(void *sb);`
- `void* pion_strbuf_to_str(void *sb);`
- `StringBuilder::length() -> Int` (reads `PionStrBuf.len` at offset 0)

**Array (`PionArray`: `{ int64_t len; int64_t cap; int32_t elem_is_obj; int32_t elem_stride; int64_t *data; }` — `elem_stride` at `+20`: `0`/`8` = 8-byte slots, `1` = compact 1-byte `Bool`/`Byte` slots with `elem_is_obj = 0`, `16`/`24`/`32`/`40`/`48` = flat inline 2..6-field immutable structs with `elem_is_obj` storing the RC object field bitmask where bit `k` is 1 iff slot `k` is an RC object pointer):**
- `void*   pion_arr_new(int64_t cap, int32_t elem_flags);` (`0` = 8B scalar, `1` = 8B RC object, `2` = 1B compact `Bool`/`Byte`, `> 2` = flat inline struct with `elem_stride = elem_flags & 0xFF` in `{16, 24, 32, 40, 48}` and `elem_is_obj = elem_flags >> 8` RC field bitmask)
- `int64_t pion_arr_len(void *a);`
- `void    pion_arr_push(void *a, int64_t val);` (retains if `elem_is_obj`)
- `void*   pion_arr_push_flat_grow(void *a);` (slow-path grow for flat-stride arrays, returning `&data[len * stride]`)
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
- `void*   pion_world_read_line(void *w, int32_t *ok_out);` (`io_read_line(world) -> Option[String]`, strips trailing `\n` / `\r\n`, `None` on immediate EOF)
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
- `void*   pion_world_fs_lstat(void *w, void *path_str, int32_t *ok_out);` (`fs_lstat(world, path) -> Result[String, String]`, POSIX `lstat` formatted as `"<kind>|<size>|<exec01>|<mtime_ms>|<dev>"` where `<kind>` is `file`/`dir`/`link`/`other`, or `Err(strerror(errno))`)
- `void*   pion_world_fs_readlink(void *w, void *path_str, int32_t *ok_out);` (`fs_readlink(world, path) -> Result[String, String]`, dynamically grown POSIX `readlink`)
- `int32_t pion_world_fs_symlink(void *w, void *target_str, void *linkpath_str);` (`fs_symlink(world, target, linkpath) -> Bool`)
- `int32_t pion_world_fs_chmod(void *w, void *path_str, int32_t mode);` (`fs_chmod(world, path, mode : Int) -> Bool`)
- `void*   pion_world_fs_read_range_nofollow(void *w, void *path_str, int64_t offset, int64_t length, int64_t expected_size, int32_t *ok_out);` (`fs_read_range_nofollow(world, path, offset : Int64, length : Int, expected_size : Int64) -> Result[Bytes, String]`; TOCTOU-safe `lstat` + `open(O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)` + `fstat` + `pread` loop, returns `Err("changed")` on any mismatch/symlink/size change)
- `void*   pion_world_env_get(void *w, void *name_str, int32_t *ok_out);`
- `int64_t pion_world_clock_ms(void *w);`
- `int32_t pion_world_exec(void *w, void *argv_arr);` (fork/execvp waitpid, returns exit code)
- `void*   pion_world_exec_capture(void *w, void *argv_arr, int32_t *exit_code_out);` (`proc_exec_capture -> Result[String, String]`; `Ok(stdout)` if exit code == 0, else `Err("exit <code>: <stdout>")`)
- `void*   pion_world_exec_capture_bytes(void *w, void *argv_arr, int32_t *exit_code_out);` (`proc_exec_capture_bytes(world, argv : Array[String]) -> Result[Bytes, String]`; silences child stderr to `/dev/null`, preserves raw stdout bytes including `\0`, `Ok(bytes)` if exit code == 0 else `Err("exit <code>")`)
- `void*   pion_sha256_hex(void *s);` (pure SHA-256 hex digest for CAS cache keys!)

**FFI raw pointers, C callbacks, C variadic calls & zero-copy helpers (no `World`; compiler builtins → direct/inline QBE IR):**
- `extern "C" fn name(fixed_params..., ..., vararg_params...) -> Ret [= "c_sym"]`: native C variadic ABI support. At least one fixed parameter is required before `...` (duplicate or leading `...` is a syntax error); trailing typed vararg parameters stay statically type-checked at call sites (or 0 trailing parameters, e.g. `fn foo(a : Int, ...) -> Int`). Emits QBE variadic calls `call $c_sym(fixed..., ..., varargs...)` with C default argument promotions (`Int`/`Bool`/`Byte` as `w`, `Int64`/`Ptr` as `l`, `Double` as `d`), satisfying Apple Silicon ARM64 Darwin PCS (all variadic args passed on the stack) and Linux x86_64 SysV ABI (register allocation + `%al` XMM count).
- `[pub] extern "C" fn name(p1 : T1, ...) -> Ret [= "c_sym"] { ... }`: exports a Pion function with C ABI under `$c_sym` (non-variadic; `Int`/`Bool`/`Byte`/`Char` as `w`, `Double` as `d`, `Int64`/`Ptr`/`String`/`Bytes`/heap objects as `l`, `Unit` as void). Incoming parameters use borrowed semantics (`is_owned = false`, no RC change on entry/exit); returned heap objects transfer ownership (`RC=1`) to the C caller. `c_fn_ptr(target) -> Ptr` returns the C function pointer (`%t =l copy $<c_sym>`) for any in-scope `extern "C" fn` (or imported `pub extern "C" fn`).
- Zero-copy data pointers (inline QBE IR, 0 runtime bytes): `str_data_ptr(s : String) -> Ptr` (`s + 8`, NUL-terminated UTF-8), `bytes_data_ptr(b : Bytes) -> Ptr` (`*(b + 16)`), `array_data_ptr(a : Array[T]) -> Ptr` (`*(a + 24)`, contiguous 64-bit slots).
- Inline float pointer access (inline QBE IR, 0 runtime bytes): `ptr_read_f64(p : Ptr, off : Int64) -> Double`, `ptr_write_f64(p : Ptr, off : Int64, v : Double) -> Unit`, `ptr_read_f32(p : Ptr, off : Int64) -> Double`, `ptr_write_f32(p : Ptr, off : Int64, v : Double) -> Unit`.
- Direct libm math builtins (inline QBE calls to `$tan`, `$asin`, `$acos`, `$atan`, `$atan2`, `$exp`, `$log`, `$round`, `$trunc`, 0 runtime bytes): `math_tan`, `math_asin`, `math_acos`, `math_atan`, `math_atan2(y, x)`, `math_exp`, `math_log`, `math_round`, `math_trunc`.
- `StringBuilder::write_byte(b : Byte) -> Unit` (calls `$pion_strbuf_push_byte`) and `StringBuilder::write_bytes(bs : Bytes) -> Unit` (inline loop over `bs.data`, 0 runtime bytes).
- `void*   pion_ptr_alloc(int64_t bytes);` (`ptr_alloc(bytes : Int64) -> Ptr`, zeroed)
- `void    pion_ptr_free(void *p);` (`ptr_free(p : Ptr) -> Unit`)
- `void*   pion_ptr_offset(void *p, int64_t off);` (`ptr_offset(p : Ptr, off : Int64) -> Ptr`)
- `void*   pion_ptr_read_ptr(void *p, int64_t off);` / `void pion_ptr_write_ptr(void *p, int64_t off, void *v);` (`ptr_read_ptr` / `ptr_write_ptr`)
- `int32_t pion_ptr_read_u8(void *p, int64_t off);` / `void pion_ptr_write_u8(void *p, int64_t off, int32_t v);` (`ptr_read_u8 -> Int` `0..255` / `ptr_write_u8`)
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
- `edits` (optional, emitted only when non-empty): machine-applicable patches `[{"file","line","col","end_line","end_col","replacement"}]` replacing the 1-based range `[line:col, end_line:end_col)` (end exclusive, columns in bytes; an empty range is an insertion). Edits of one diagnostic never overlap: apply them from the last offset to the first. Each distinct edit is attached once. All 12 agent error classes of `benchmarks/agent_eval` carry one:
  - `E_TYPE_MISMATCH` (return type) — a function body whose type contradicts the declared return type: rewrites the declared return type to the body's type.
  - `E_TYPE_MISMATCH` (arity) — too many arguments: deletes the extra ones; too few: appends a type-default placeholder for each missing parameter (`0`, `""`, `false`, ...).
  - `E_TYPE_MISMATCH` (unknown field) — replaces a misspelt field with the closest declared field when it is unique and within Levenshtein distance 2.
  - `E_NON_EXHAUSTIVE` — inserts the missing `match` arms (`panic`-bodied) before the first arm.
  - `E_PRIVATE_SYMBOL` — inserts `pub ` at the target declaration.
  - `E_TRAIT_NOT_IMPLEMENTED` — appends an `impl Trait for Type { ... }` skeleton (every trait method with its signature, `panic("todo")` bodies) after the type's declaration (generic bounds and `dyn Trait` conversions).
  - `E_TRAIT_METHOD_SIGNATURE` — rewrites the impl method's return type to the trait's.
  - `E_NOT_SEND` — a captured non-`Send` local: wraps its declaration in `Mutex::new(...)` (and its type annotation in `Mutex[...]`), or prefixes the capture with `move` where ownership transfer fits. Uses of the binding inside the closure are left as they are and may need a second step (e.g. `with_lock`).
  - `E_UNHANDLED_RESULT` — prefixes the discarded statement with `let _ = `.
  - `E_CAPABILITY_MISSING` — inserts `world : World` as the first parameter of the enclosing function; its call sites then report the arity and need a second step passing `world`.
  - `E_NO_IO_VIOLATION` — emitted (with no `edits`) when a `#no_io` / `#render_thread` function, `impl` method, or nested closure accepts/references `World` or calls any `World`-gated IO builtin, runtime primitive, or `scope`.
  - `E_MISSING_TYPE` — inserts the inferred return type (`-> T`) (no edit for an uninferable empty `let` collection: the fix-it names the annotation to add).
  - `E_TYPE_MISMATCH` "cannot assign to immutable variable" — `let x` → `let mut x` at the declaration (also for an immutable root passed as `mut <place>`); a plain identifier passed to a `mut` parameter gets a `mut ` insertion.
  - `E_VERIFY_UNSUPPORTED`, `E_VERIFY_MOVE`, `E_VERIFY_BORROW_ESCAPE`, `E_VERIFY_MUT_ESCAPE`, `E_VERIFY_ALIASING`, `E_VERIFY_CLOSURE_CAPTURE`, `E_VERIFY_UNVERIFIED_CALLEE` — `mut` / `#verify` rules of §3.4 (fix-its, no `edits`).

### 5.2 `pionc query <kind> --json <path>`
- `defs`: `{"defs":[{"pkg":"...","name":"...","kind":"fn|struct|enum","pub":true,"file":"...","line":10,"sig":"..."}]}`
- `sig`: compact `.pionsig` export table in JSON
- `callers`: `{"callers":[{"fn":"...","calls":["..."]}]}` (workspace targets add `"pkg"` to every entry)
- `deps`: `{"packages":[{"name":"...","deps":["..."],"sig_hash":"..."}]}`
- `<path>` may be a file, a package directory (its `src/` included) or a `pion.toml` workspace root: `defs`/`sig`/`callers` then cover every package in one call.

### 5.3 `pionc test [--json] [--package <name>] [--filter <substr>] [--jobs <n>] <path>`
- Runs all `test "name" { ... }` blocks in isolated child processes (active `debug_assert`).
- One pass over the workspace: the package graph is loaded, CAS-built and interface-checked once; packages without (matching) tests stop after type checking. Each tested package's test object is cached under `$PION_CACHE_DIR/testbin/` keyed by `sha256(compiler_fp | testobj | target | sha256(test SSA))`, and its linked test binary by that object key plus every linked dependency object (CAS path, size, mtime) and the link libraries — a dependency whose body or upstream interface changed has a new CAS path, so a stale binary is never reused. `testbin/` entries are LRU-tracked in `index.tsv` and evicted with the rest of the CAS.
- Missing test binaries compile and link in parallel and every selected test runs in its own process in parallel, on up to `--jobs <n>` OS threads (default `$PION_JOBS`, else 16); results are reported in package order, then test order, so the JSON is identical for any `--jobs`. `PION_CAS_TRACE=1` prints per-phase `[test]` timings on stderr.
- JSON output: `{"ok":bool,"passed":N,"failed":M,"tests":[{"name":"...","ok":bool}]}`
- Workspace target (a directory with `pion.toml`): one invocation runs the tests of every local package (dependencies first; packages from the git cache are excluded) and reports `{"ok":bool,"total":N,"passed":N,"failed":M,"packages":["..."],"tests":[{"pkg":"...","name":"...","ok":bool}]}`; `--package <name>` restricts it to one package.
- Additional diagnostic codes:
  - `E_PRIVATE_SYMBOL`: accessing a non-`pub` function, struct, enum, method, or constant from an imported package.
  - `E_IMPORT_CYCLE`: cyclic package dependency detected across `pion.toml` manifests.
  - `E_UNKNOWN_PACKAGE`: importing or depending on an undeclared package.

### 5.4 `pionc doc [--json] <path>`
- `{"packages":[{"name":"json","items":[{"kind":"struct|enum|trait|impl|extern_fn|fn|const","name":"...","sig":"...","file":"...","line":3}]}]}` — one entry per package (workspace: dependencies first); `impl` items are always listed, everything else only when `pub`.
- Without `--json`: `package <name>` followed by one indented signature per item.


### 5.5 `pionc extract-lean --out <dir> [--pkg <name>] [--json] [<path>]`
- `<path>`: a file, a package directory or a workspace root (default `.` when it has `pion.toml` / `src/`); `--out` is required (exit 1 otherwise). `--pkg <name>` extracts only the closure of that package (and the items of its dependencies it reaches).
- The sources are fully type-checked, including the `#verify` rules (§3.4); any diagnostic — or an `E_EXTRACT_UNSUPPORTED` construct (§3.5) — is printed (`check --json` format with `--json`, `file:line:col: CODE: message` otherwise), nothing is written, and the exit code is 1.
- Writes `<dir>/<Pkg>/{Types,Funs,FunsExternal_Template}.lean` (and `FunsExternal.lean` when absent or unmodified since the last extraction) for every package with something in the closure, upstream first; build them with a Lake library per package next to `lean/` (`scripts/test-lean.sh`).
- JSON output: `{"ok":true,"out":"<dir>","packages":[{"name":"vlib","lean_mod":"Vlib","files":["Vlib/Types.lean",...],"types":N,"funs":N,"externals":["opaque_len",...]}]}` (`types`: structs + enums + traits; `funs`: functions + constants + trait dictionaries).

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

  mylib = { git = "https://example.com/mylib.git", tag = "v1", version = "1.0.0", registry = "https://example.com/index.git" }
  # written by `pionc add` from a registry: `registry` and the index `version` let `pionc update` re-read it

  [link]
  libs = ["sqlite3"]            # or: lib = "sqlite3" (de-duplicated, first-seen order)
  frameworks = []               # or: framework = "..." (macOS only; ignored on Linux)
  search_paths = ["./lib"]      # or: search_path = "..." (-L<path>, relative to package dir)
  rpaths = ["@executable_path/../lib"] # or: rpath = "..." (-Wl,-rpath,<path>; `/`, `@`, `$` kept verbatim)
  objects = ["vendor/libfoo.a"] # or: object = "..." (precompiled .a/.o/.dylib/.so; relative to package dir)
  flags = []                    # extra linker flags (order-preserving, not de-duplicated)
  c_sources = ["csrc/shim.cc"]  # or: c_source = "..." (compiled to CAS obj/cstub_<key>.o)
  cc_flags = ["-O2", "-Iinc"]   # C/C++/ObjC compiler flags (order-preserving; relative `-I<path>` resolved to package dir)

  [link.macos]                  # merged after [link] when target OS is macOS (`arm64_apple`, `amd64_apple`)
  frameworks = [
    "Cocoa",
    "Metal",
  ]

  [link.linux]                  # merged after [link] when target OS is Linux (`amd64_sysv`, `arm64`, `rv64`)
  libs = ["freetype", "fontconfig"]

  [link.ios]                    # optional; merged after [link] for `ios_arm64`, `ios_sim_arm64`
  frameworks = ["UIKit", "Metal"]

  [link.android]                # optional; merged after [link] for `android_arm64`, `android_x64`
  libs = ["log", "android"]

  [link.windows]                # optional; merged after [link] for `amd64_win`
  libs = ["bcrypt"]
  rc_sources = ["assets/app.rc"] # or: rc_source = "..." (Windows .rc compiled to CAS obj/rc_<key>.res via llvm-rc/windres)

  [link.wasm]                   # optional; placeholder for `wasm32`
  flags = []

  [registry]
  url = "https://example.com/pion-index.git"   # default registry for `pionc add <name>`

  [verify]
  enabled = true                # every fn / method / impl method is #verify unless #verify_opaque (default false)
  ```
  - `[verify]` accepts only `enabled = true|false` (other keys / values are rejected with the line number). The driver lowers `enabled = true` by appending the file-level attribute `#![verify]` after the last line of each of the package's sources (no line / column shift; the switch is thereby part of every source-content CAS key), so the marks also reach `.pionsig` / `.pionstub` and downstream `#verify` callers.
  - **Multi-Package Workspaces (`[workspace]` & `[workspace.dependencies]`)**:
    - A root `pion.toml` may declare `[workspace]` with `members = ["packages/*", "cmd/*"]` (exact paths or single-segment wildcards, multiline arrays and singular `member` supported; unknown keys rejected with line number) and `[workspace.dependencies]` (same `path` / `git`+`tag|rev|branch|subdir` / `registry` syntax; `workspace = true` forbidden inside `[workspace.dependencies]`).
    - Both **virtual roots** (`[workspace]` without `[package]`) and **hybrid roots** (`[package]` + `[workspace]`) are supported; hybrid roots include themselves as a member.
    - Member packages inherit dependencies via `foo = { workspace = true }` in `[dependencies]` (combining `workspace = true` with `path`/`git`/`registry` is an error with line number). `pionc` walks up to 16 parent directories from any member package to discover its enclosing `[workspace]`, rewrites inherited `path` dependencies relative to the workspace root, and shares a single `<ws_root>/pion.lock`.
    - From a workspace root (explicit path or default `"."`), `check [--fix]`, `test [--package|-p <name>]`, `fmt [--check]`, `doc`, `query defs|sig|callers|deps`, and `fetch` operate across all workspace members; `build` and `run` accept `--package <name>` / `-p <name>` (and on a virtual root without `--package`, auto-select the unique member defining `fn main` or report available members).
  - **Multiline arrays**: any `key = [ ... ]` value in `pion.toml` may span multiple lines (with `#` comments and optional trailing commas). Unknown keys in `[link]` / `[link.macos]` / `[link.linux]` / `[link.ios]` / `[link.android]` / `[link.windows]` are rejected with the line number.
  - **C/C++/ObjC stub compilation (`c_sources`)**: each package's active `c_sources` are compiled in topological order (`.cc`/`.cpp`/`.mm` with `$CXX` or `c++`, `.c`/`.m` with `$CC` or `cc`), automatically passing `-I<runtime_dir>` (and `<runtime_dir>/../runtime` when `pion_rt.h` resides there) so stubs can `#include "pion_rt.h"`. Objects are written atomically to `$PION_CACHE_DIR/obj/cstub_<key>.o` (LRU-tracked, zero source-tree pollution) keyed by `sha256("cstub-v1|" + target + "|" + compiler + "|" + cc_flags + "|" + src_path + "|" + sha256(src) + "|" + local_headers_fp)`, where `local_headers_fp` hashes sorted `(path, size, mtime_ms)` of all `.h`/`.hpp` files in the package dir and `src_path`'s dir.
  - **Linker & binary cache key**: when all packages have no `frameworks`, `search_paths`, `rpaths`, `objects`, `flags`, or C++ sources/libs (`has_cxx`), macOS keeps its direct `ld` fast path. Otherwise both macOS and Linux link through `$CXX`/`c++` (when `has_cxx`) or `$CC`/`cc` with argument order `obj_paths` (including `cstub_*.o`) → `libpionrt.a` → `objects` → `-L<search_paths>` → `-Wl,-rpath,<rpaths>` → (macOS: `-framework <fw>`) → `-l<libs>` → `flags` → (Linux: `-lm -lpthread`). Both `pionc build`/`run` and `pionc test` include all resolved link options plus each `objects` file's `(path, size, mtime_ms)` in the binary cache key.
- **Git dependencies & `pion.lock`**: git dependencies resolve into the global shared cache `$PION_CACHE_DIR/git/` (default `~/.cache/pion/git/`): bare mirrors `repos/<sha256(url)>.git` and read-only checkouts `checkouts/<rev>` (no `.git`), created atomically and shared zero-copy by every worktree. `<root>/pion.lock` pins each git dependency to a full commit (`version = 1`, then `[[package]]` tables with `name`, `git`, `ref`, `rev`, `subdir`, sorted, every key written); an entry is reused only while `pion.toml` requests the same name, URL, subdir and ref. A locked dependency whose checkout exists runs no `git` at all; tags and full revs resolve from the mirror, branches and HEAD always fetch. Only `<root>/pion.lock` is ever written, and only when it changes.
- **`pionc fetch [--json] [dir]`**: resolves every git dependency, writes/verifies `pion.lock`, and prints `{"ok":true,"lock":"...","git_cache":"...","packages":[{"name","dir","source":"path|git"}],"git":[{"name","git","ref","rev","subdir"}]}`.
- **Git-index registry**: a registry is any git repository (URL or local path) holding one `index/<name>.toml` per package: `name = "..."` (optional, must match), `version = "..."`, `git = "..."`, at most one of `tag` / `rev` / `branch`, optional `subdir`. Its index is mirrored in `$PION_CACHE_DIR/registry/<sha256(url)>.git` (default `~/.cache/pion/registry`), refreshed on every `add`/`update` that reads it; the package itself resolves like any git dependency.
- **`pionc add [--json] <name> (--path <p> | --git <url> [--tag <t>|--rev <r>|--branch <b>] [--subdir <s>] | [--registry <url_or_path>]) [dir]`**: sets `[dependencies] <name>` in `pion.toml` in place (only that line changes; idempotent), resolves it into the shared cache and `pion.lock`, and prints `{"ok":true,"action":"add","package":"...","source":"path|git|registry","location":"...","version":"...","rev":"...","changed":bool}`. Without `--path`/`--git` the registry is `--registry`, else `[registry] url`, else `$PION_REGISTRY` (none: `no source for ...`). A git source whose `pion.toml` declares another package name, an unknown registry package or a failed fetch print `{"ok":false,"error":"..."}` and restore `pion.toml` and `pion.lock` byte for byte.
- **`pionc check --fix [--json] [path...]`**: runs up to 3 fix rounds, applying non-overlapping `TextEdit` patches per file in descending byte-offset order atomically, then re-checks and prints `{"ok":bool,"fixed":N,"files":[...],"diagnostics":[...]}` (exit `0` when clean, `1` when diagnostics remain).
- **`pionc remove [--json] <name> [dir]`**: removes `<name>` from `[dependencies]` in `pion.toml` (preserving all other comments, formatting, and sections), prunes unreferenced entries from `pion.lock` when present, and prints `{"ok":true,"removed":"<name>","manifest":"..."}`.
- **`pionc doctor [--json]`**: verifies toolchain self-location and host dependencies (`version`, `host_target`, `pionc`, `qbe`, `rt_lib`, `wasm_rt`, `cc`, `cxx`, `win_abi`, `wasm_opt`, `node`, `git`, `cache_dir`, `cache_files`, `cache_bytes`, `cache_max_mb`); exits `0` iff core dependencies (`qbe`, `rt_lib`, `cc`) exist.
- **`pionc cache stats|prune|clear [--all] [--json]` & `pionc clean [--all] [--json]`**: inspects CAS buckets (`obj`, `bin`, `sig`, `git`), runs LRU eviction against `$PION_CACHE_MAX_MB`, or clears build caches (`--all` also clears `git/` and `registry/`).
- **Relocatable Zero-Env Layout & Default Target `"."`**: `pionc` locates itself via `argv[0]` / `$PATH` and resolves `<prefix>/bin/{pionc,qbe}`, `<prefix>/lib/libpionrt.a`, and `<prefix>/share/pion/{pion_wasm_rt.mjs,runtime/pion_rt.{c,h}}` automatically without requiring `PION_*` environment variables (while still honouring explicit env overrides and in-tree `out/`). When `check`, `build`, `run`, `test`, `fmt`, or `doc` is invoked without a path argument and the current directory contains `pion.toml` or `src/`, the target defaults to `"."`. `pionc --help` / `-h` / `help` prints full usage to stdout and exits `0`; `pionc --version` / `-V` / `version` prints `pionc 0.1.0 (<host_target>, self-hosted)` (or `{"version":"0.1.0","target":"..."}` with `--json`).
- **`pionc update [--json] [pkg] [dir]`**: re-reads the registry entry of every registry dependency (or only `pkg`), drops its lock pin, re-resolves every git dependency to its newest target ref, rewrites `pion.lock` and type-checks the workspace; prints `{"ok":true,"action":"update","packages":[{"name","ref","from","to","updated":bool}]}`. Updating a path dependency is an error; a failed resolution or a workspace that no longer checks restores `pion.toml` and `pion.lock` (`"check"` carries the diagnostics).
- **`pionc init [--template cli|service|invar-app] [--json] <dir>`**: scaffolds a package named after the directory (`[a-z0-9_]`) using the chosen template (default `cli`: `pion.toml`, `src/main.pion`, `main_test.pion`; `service`: adds `src/worker.pion` with `scope`/`spawn`/`Channel`; `invar-app`: dual-thread GUI skeleton with `src/protocol.pion`, `src/worker.pion`, `#render_thread`-guarded `src/view.pion`, `src/main.pion`, `main_test.pion`). The result passes `check`, `test`, `run` and `fmt --check` as is; JSON output includes `"template"`. Refuses to overwrite existing files or accept unknown template names.
- **Cross-package traits & generics**: an imported package's `impl Trait for Type` is registered under `pkg::Trait::pkg::Type` (built-in targets such as `Int` stay unqualified), and impl symbols use the package-local trait/type names, so definitions and cross-package calls link. Any package exporting a `pub` generic fn or method (`type_params.length() > 0`) skips `.pionstub` (importers monomorphize from its source) and exports its package-prefixed internal functions and constants at the QBE level so cross-package monomorphized bodies link cleanly while `types.mbt` still enforces `E_PRIVATE_SYMBOL`.
- **Cross-Package Incremental Isolation**: Downstream package CAS keys depend ONLY on upstream packages' `pub` `.pionsig` SHA-256 hashes (never upstream function bodies). Editing an upstream function body without changing its `pub` `.pionsig` yields 100% CAS hit on downstream `.o` files, `pionc check` `.pionsig`/`.pionstub` entries, and multi-package `--target wasm32` `.ssa`/`.wasm` entries.
- **Incremental `pionc check` & Multi-Package `wasm32` CAS**:
  - `pionc check` and `pionc check --fix` cache clean packages' `.pionsig` and `.pionstub` in `$PION_CACHE_DIR/sig/` keyed by `(pkg_sources, upstream_.pionsig_hashes, "check", self_fp)` (using only the running `pionc` binary fingerprint without probing `qbe`/`libpionrt.a`). Packages that emit diagnostics or depend on an errored upstream are never cached.
  - Multi-package `pionc build --target wasm32` caches each package's `.pionsig`/`.pionstub`/`.ssa` in `$PION_CACHE_DIR/{sig,ssa}/` and the final `.wasm` binary (including `wasm-opt` identity when active) in `$PION_CACHE_DIR/bin/wasm_<key>.wasm`, skipping `emit_wasm_from_ssa` and `wasm-opt` on binary CAS hit when `--emit-ssa` is not requested. Setting `PION_TRACE_CAS=1` logs `[cas-check]`, `[cas-wasm]`, and `[cas-wasm-bin]` HIT/MISS lines to stderr.
- **Compiler Fingerprint**: Every CAS key (`cas_compute_key`, `cas_compute_unit_key`) and `.usig` cache prefix includes `compiler_fp = sha256(PION_COMPILER_ABI_REV | qbe_size | libpionrt_size | salt)`, where `salt` = `self:<pionc_size>:<pionc_mtime_ms>|$PION_CACHE_SALT` (the running `pionc` binary from `argv[0]`, when it resolves to a file) and `PION_COMPILER_ABI_REV` is currently `pionc-v0.17` (since Phase 35-A second-class `mut` parameter slot-pointer ABI, `#verify` runtime checks and `#verify` marks in `.pionsig`; `pionc-v0.15` added Phase 27-C1 cross-package monomorphization private lookups, generic closure `%tp_T` capture, native `Map[Int, V]`/`Map[Int64, V]`, and `#derive(Eq)`), ensuring compiler/backend upgrades — including a rebuilt `pionc` whose `qbe` and `libpionrt.a` are unchanged — automatically invalidate stale cache entries. The fingerprint only names cache files: it never changes emitted SSA or objects, so the bootstrap fixed point is unaffected.
- Default directory: `$PION_CACHE_DIR` or `$HOME/.cache/pion/cas`
- Layout:
  - `sig/<sha256>.pionsig`
  - `ssa/<sha256>.ssa`
  - `obj/<sha256>.o`
  - `testbin/<sha256>` (`pionc test` objects and binaries, §5.3)
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
- **`std/tls`**: TLS 1.2/1.3 client and server binding the system OpenSSL (`libssl`/`libcrypto`, 1.1.x or 3.x C ABI) through `extern "C"` declarations only — zero C glue; `[link] libs = ["ssl", "crypto"]`. SNI, certificate verification against OpenSSL's default CA store (`SSL_CERT_FILE`/`SSL_CERT_DIR` honoured) with host-name or IP checking, TLS 1.2 minimum. API: `tls_connect(w, host, port, verify_cert) -> Result[TlsConn, String]`, `tls_write`, `tls_read`, `tls_close`, `tls_protocol`, `tls_cipher`, `tls_version`, and `https_request` on top of `std/http`. Server: `tls_listen(w, host, port, cert_pem, key_pem) -> Result[TlsListener, String]` (one `TLS_server_method` `SSL_CTX` with the PEM certificate chain and private key, checked to match; TLS 1.2 minimum; port 0 = ephemeral, bound port in `listener.port`), `tls_accept(w, listener) -> Result[TlsConn, String]` (accept + handshake; a failed handshake closes only that connection; the client's SNI becomes `conn.host`), `tls_listener_close` and the HTTP helpers `tls_read_http_request(w, conn) -> Result[http::HttpRequest, String]` / `tls_write_http_response(w, conn, status, content_type, body)`. `TlsConn` has a private `owns_ctx`: client connections free their own `SSL_CTX` in `tls_close`, accepted connections borrow the listener's, which `tls_listener_close` frees exactly once. Linux needs the `libssl.so`/`libcrypto.so` link names (Debian/Ubuntu `libssl-dev`); macOS needs Homebrew `openssl@3` and `CC=cc LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib`. `std/tls/e2e/run_e2e.sh <pionc>` performs real loopback TLS 1.3 and 1.2 handshakes against a Python `ssl` server and checks that a wrong host name is refused; `std/tls/e2e/run_server_e2e.sh <pionc>` drives the pure-Pion `examples/https_server` (self-test with 4 concurrent verified clients, key/certificate error paths, Python `ssl` and curl clients at TLS 1.3 and 1.2, a refused wrong host, exact `/stats`).
