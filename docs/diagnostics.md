# Pion Diagnostics Reference

Every diagnostic emitted by `pionc check --json` carries a stable `code`, a concise `fixit`, and (when a source patch is known) an `edits` array where each edit carries `"applicability": "machine"` (deterministic, safe to apply blindly) or `"applicability": "maybe"` (contains placeholders or needs follow-up edits).

Every `### E_CODE` section below is an **executable test**: `compiler/src/core/diagnostics_doc_test.pion` parses this file and verifies that every `pion before` block triggers that section's `E_CODE` and every `pion after` block checks with 0 diagnostics.

---

## Core Diagnostics

### E_TYPE_MISMATCH

A value's type does not match the expected type (for example, a function body returning a different type than its declared return type, assigning to an immutable `let`, or passing the wrong argument type). Fix the expression or update the declared type.

```pion before
pub fn add(a : Int, b : Int) -> String {
  a + b
}
```

```pion after
pub fn add(a : Int, b : Int) -> Int {
  a + b
}
```

### E_NON_EXHAUSTIVE

A `match` expression does not cover every variant of an `enum` or `Option`/`Result`. Add the missing arms or a wildcard `_ => ...` arm.

```pion before
enum Color {
  Red
  Green
}

pub fn code(c : Color) -> Int {
  match c {
    Red => 1
  }
}
```

```pion after
enum Color {
  Red
  Green
}

pub fn code(c : Color) -> Int {
  match c {
    Red => 1
    Green => 2
  }
}
```

### E_PRIVATE_SYMBOL

A declaration in another package is private and cannot be referenced across package boundaries. Mark the target declaration `pub`.

```pion before
// @pkg dep
fn secret() -> Int {
  42
}

// @pkg app
import "dep"

pub fn main() -> Int {
  dep::secret()
}
```

```pion after
// @pkg dep
pub fn secret() -> Int {
  42
}

// @pkg app
import "dep"

pub fn main() -> Int {
  dep::secret()
}
```

### E_TRAIT_NOT_IMPLEMENTED

A type is used where a trait bound (`[T: Trait]`) or `dyn Trait` is required, but it does not implement that trait. Add an `impl Trait for Type { ... }` block.

```pion before
trait Show {
  fn show(self : Self) -> String
}

struct Item {
  id : Int
}

fn render[T: Show](x : T) -> String {
  x.show()
}

pub fn main() -> String {
  render(Item::{ id: 1 })
}
```

```pion after
trait Show {
  fn show(self : Self) -> String
}

struct Item {
  id : Int
}

impl Show for Item {
  fn show(self : Item) -> String {
    self.id.to_string()
  }
}

fn render[T: Show](x : T) -> String {
  x.show()
}

pub fn main() -> String {
  render(Item::{ id: 1 })
}
```

### E_NOT_SEND

A `spawn` closure captures a mutable or non-`Send` local variable, which would cause a data race across OS threads. Wrap shared state in `Mutex::new(...)` / `AtomicInt::new(...)` or transfer ownership with `move`.

```pion before
pub fn run(world : World) -> Unit {
  let mut count = 0
  scope(world, fn(s) {
    spawn(s, fn() {
      let _ = count
    })
  })
}
```

```pion after
pub fn run(world : World) -> Unit {
  let count = Mutex::new(0)
  scope(world, fn(s) {
    spawn(s, fn() {
      let _ = count.with_lock(fn(v) { v })
    })
  })
}
```

### E_UNHANDLED_RESULT

A `Result[T, E]` value is silently discarded as a statement. Handle it with `match` or `?`, or explicitly discard it with `let _ = ...`.

```pion before
fn parse(s : String) -> Result[Int, String] {
  Ok(s.length())
}

pub fn main() -> Int {
  parse("ok")
  0
}
```

```pion after
fn parse(s : String) -> Result[Int, String] {
  Ok(s.length())
}

pub fn main() -> Int {
  let _ = parse("ok")
  0
}
```

### E_CAPABILITY_MISSING

Calling an IO builtin or `World`-gated function without a `World` capability in scope. Add `world : World` to the enclosing function's parameters and pass it explicitly.

```pion before
pub fn greet() -> Unit {
  io_println("hello")
}
```

```pion after
pub fn greet(world : World) -> Unit {
  io_println(world, "hello")
}
```

### E_NO_IO_VIOLATION

A `#no_io` / `#render_thread` function (or a closure inside it) accepts `World` or calls a `World`-gated IO operation. Keep render-thread functions pure and offload IO to a worker thread via `Channel`.

```pion before
#no_io
pub fn draw(world : World) -> Unit {
  io_println(world, "frame")
}
```

```pion after
#no_io
pub fn draw(width : Int) -> Int {
  width * 2
}
```

### E_MISSING_TYPE

A top-level function omits its return type annotation `-> T` (or an empty collection cannot have its element type inferred). Add the explicit type annotation.

```pion before
fn double(x : Int) {
  x * 2
}

pub fn main() -> Int {
  double(21)
}
```

```pion after
fn double(x : Int) -> Int {
  x * 2
}

pub fn main() -> Int {
  double(21)
}
```

### E_VERIFY_UNSUPPORTED

A `#verify` function uses a type or construct outside the verified subset (such as `World`, `Ptr`, `AtomicInt`, `Float`, or `dyn Trait`). Restrict `#verify` functions to verified value types (`Int`, `Bool`, `String`, structs, enums, arrays).

```pion before
#verify
pub fn bad(p : Ptr) -> Int {
  0
}
```

```pion after
#verify
pub fn ok(x : Int) -> Int {
  x + 1
}
```

### E_VERIFY_MOVE

A `#verify` function reads a `Unique` binding (such as an `Array`) after ownership was moved to another binding. Use `copy()` or avoid reading the moved binding.

```pion before
#verify
pub fn bad() -> Int {
  let a = [1, 2]
  let b = a
  let _ = b
  a.length()
}
```

```pion after
#verify
pub fn ok() -> Int {
  let a = [1, 2]
  let b = a
  b.length()
}
```

### E_VERIFY_BORROW_ESCAPE

A `#verify` function returns or stores a read-only borrowed `Unique` parameter (such as `Array[Int]`), letting the borrow escape. Return a scalar/copy value or construct a fresh owned value instead.

```pion before
#verify
pub fn bad(a : Array[Int]) -> Array[Int] {
  a
}
```

```pion after
#verify
pub fn ok(a : Array[Int]) -> Int {
  a.length()
}
```

### E_VERIFY_MUT_ESCAPE

A `#verify` function returns or stores a `mut` parameter of a `Unique` type, letting a second-class mutable borrow escape. Mutate the parameter in place and return `Unit` or a copied value.

```pion before
#verify
pub fn bad(mut a : Array[Int]) -> Array[Int] {
  a
}
```

```pion after
#verify
pub fn ok(mut a : Array[Int]) -> Unit {
  a.push(1)
}
```

### E_VERIFY_ALIASING

A `#verify` function passes the same root binding to two overlapping `mut` arguments (or mutates a binding while it is pinned by a loop). Pass distinct roots.

```pion before
#verify
pub fn swap(mut a : Int, mut b : Int) -> Unit {
  let t = a
  a = b
  b = t
}

#verify
pub fn bad() -> Int {
  let mut x = 1
  swap(mut x, mut x)
  x
}
```

```pion after
#verify
pub fn swap(mut a : Int, mut b : Int) -> Unit {
  let t = a
  a = b
  b = t
}

#verify
pub fn ok() -> Int {
  let mut x = 1
  let mut y = 2
  swap(mut x, mut y)
  x
}
```

### E_VERIFY_CLOSURE_CAPTURE

A closure inside a `#verify` function captures a `let mut`, `mut` parameter, or `Unique` binding. Capture only immutable `Copy` values.

```pion before
#verify
pub fn bad() -> Int {
  let mut x = 1
  let f = fn() -> Int { x }
  f()
}
```

```pion after
#verify
pub fn ok() -> Int {
  let x = 1
  let f = fn() -> Int { x }
  f()
}
```

### E_VERIFY_UNVERIFIED_CALLEE

A `#verify` function calls a function that is neither `#verify` nor `#verify_opaque`. Mark the callee `#verify` (or `#verify_opaque` if it is a trusted boundary).

```pion before
fn plain(x : Int) -> Int {
  x + 1
}

#verify
pub fn bad(x : Int) -> Int {
  plain(x)
}
```

```pion after
#verify
fn verified(x : Int) -> Int {
  x + 1
}

#verify
pub fn ok(x : Int) -> Int {
  verified(x)
}
```

---

## Cross-Language Agent Habit Diagnostics

### E_HABIT_ANGLE_GENERICS

Pion uses square brackets `[T]` (not angle brackets `<T>`) for generic type parameters and generic type arguments. Replace `<...>` with `[...]`.

```pion before
struct Pair<T> {
  first : T
  second : Option<T>
}

pub fn id<T>(x : T) -> T {
  x
}
```

```pion after
struct Pair[T] {
  first : T
  second : Option[T]
}

pub fn id[T](x : T) -> T {
  x
}
```

### E_HABIT_RUST_REF

Pion has no Rust-style `&T` / `&mut T` reference types or `&x` / `&mut x` borrow expressions. Pass values directly, or use `mut x` for in-out parameters and arguments.

```pion before
fn inc(mut x : Int) -> Unit {
  x = x + 1
}

pub fn main() -> Int {
  let mut n = 1
  inc(&mut n)
  n
}
```

```pion after
fn inc(mut x : Int) -> Unit {
  x = x + 1
}

pub fn main() -> Int {
  let mut n = 1
  inc(mut n)
  n
}
```

### E_HABIT_RUST_ATTR

Pion only supports `#derive(Eq)`, `#no_io`, `#render_thread`, `#verify`, and `#verify_opaque` (and `test "name" { ... }` for tests). Unsupported Rust-style `#[...]` attributes are rejected with a clear hint.

```pion before
#[inline]
pub fn add(a : Int, b : Int) -> Int {
  a + b
}
```

```pion after
pub fn add(a : Int, b : Int) -> Int {
  a + b
}
```

### E_HABIT_JS_CONST

Pion uses `let` (not `const`) for both immutable local bindings and top-level constants. Replace `const` with `let`.

```pion before
const BASE : Int = 10

pub fn main() -> Int {
  const x = BASE + 1
  x
}
```

```pion after
let BASE : Int = 10

pub fn main() -> Int {
  let x = BASE + 1
  x
}
```

### E_HABIT_JS_FUNCTION

Pion uses `fn` (not `function`) to declare functions and closures. Replace `function` with `fn`.

```pion before
pub function add(a : Int, b : Int) -> Int {
  a + b
}
```

```pion after
pub fn add(a : Int, b : Int) -> Int {
  a + b
}
```

### E_HABIT_STRICT_EQ

Pion uses `==` and `!=` (not JavaScript `===` and `!==`) for value equality and inequality. Replace `===` with `==` and `!==` with `!=`.

```pion before
pub fn same(a : Int, b : Int) -> Bool {
  a === b && a !== 0
}
```

```pion after
pub fn same(a : Int, b : Int) -> Bool {
  a == b && a != 0
}
```

### E_HABIT_ARROW_FN

Pion uses `fn(...) { ... }` (not JavaScript `(...) => { ... }`) for closures. Replace arrow functions with `fn(...) { ... }`.

```pion before
pub fn apply(x : Int) -> Int {
  let f = (v : Int) => { v + 1 }
  f(x)
}
```

```pion after
pub fn apply(x : Int) -> Int {
  let f = fn(v : Int) { v + 1 }
  f(x)
}
```

### E_HABIT_MOONBIT_PKG

Pion uses `pkg::name` (not MoonBit `@pkg.name`) for cross-package symbol references. Replace `@pkg.name` with `pkg::name`.

```pion before
// @pkg dep
pub fn add(a : Int, b : Int) -> Int {
  a + b
}

// @pkg app
import "dep"

pub fn main() -> Int {
  @dep.add(1, 2)
}
```

```pion after
// @pkg dep
pub fn add(a : Int, b : Int) -> Int {
  a + b
}

// @pkg app
import "dep"

pub fn main() -> Int {
  dep::add(1, 2)
}
```

### E_GUARD_ELSE_NOT_DIVERGE

The `else` block of `guard cond else { ... }` must diverge on every reachable path (`return`, enclosing-loop `break`/`continue`, `panic`/`abort`, or an infinite `while true` without a reachable `break`).

```pion before
pub fn unwrap_pos(x : Int) -> Int {
  guard x > 0 else {
    let _ = 0
  }
  x
}
```

```pion after
pub fn unwrap_pos(x : Int) -> Int {
  guard x > 0 else {
    return 0
  }
  x
}
```

### E_CONST_CYCLE

Top-level `let` bindings in a package cannot form a cyclic initialization dependency (directly or through same-package direct function calls).

```pion before
let A : Int = get_b()
let B : Int = A + 1

fn get_b() -> Int {
  B
}

pub fn main() -> Int {
  A
}
```

```pion after
let B : Int = 41
let A : Int = get_b()

fn get_b() -> Int {
  B + 1
}

pub fn main() -> Int {
  A
}
```

---

## Built-in Linter Diagnostics (`pionc lint`)

The 7 mandatory `L_*` codes below are checked by `pionc lint` (and verified by `compiler/src/core/diagnostics_doc_test.pion`).

### L_IMPLICIT_IMPORT

A file references an external package alias (`dep::...`) without declaring `import "dep"` in that file, relying on an `import` written in another file of the same package.

```pion before
// @pkg dep
pub fn add(a : Int, b : Int) -> Int {
  a + b
}

// @pkg app
// @file a.pion
import "dep"

pub fn fa() -> Int {
  dep::add(1, 2)
}

// @file b.pion
pub fn fb() -> Int {
  dep::add(3, 4)
}
```

```pion after
// @pkg dep
pub fn add(a : Int, b : Int) -> Int {
  a + b
}

// @pkg app
// @file a.pion
import "dep"

pub fn fa() -> Int {
  dep::add(1, 2)
}

// @file b.pion
import "dep"

pub fn fb() -> Int {
  dep::add(3, 4)
}
```

### L_UNUSED_IMPORT

A file declares an `import` whose alias is never referenced in that file (or duplicates an existing `import` in the same file).

```pion before
// @pkg dep
pub fn add(a : Int, b : Int) -> Int {
  a + b
}

// @pkg app
import "dep"

pub fn main() -> Int {
  42
}
```

```pion after
// @pkg dep
pub fn add(a : Int, b : Int) -> Int {
  a + b
}

// @pkg app
pub fn main() -> Int {
  42
}
```

### L_UNUSED_LOCAL

A local binding (`let`, tuple destructuring, loop variable, or `match`/`is` pattern binding) is never referenced in its scope. Prefix intentionally unused bindings with `_`.

```pion before
pub fn compute(x : Int) -> Int {
  let unused = x + 1
  x * 2
}
```

```pion after
pub fn compute(x : Int) -> Int {
  let _unused = x + 1
  x * 2
}
```

### L_UNUSED_MUT

A local `let mut` binding is never reassigned, passed as `mut <place>`, or used as the receiver of a `mut self` method.

```pion before
pub fn double(x : Int) -> Int {
  let mut y = x * 2
  y
}
```

```pion after
pub fn double(x : Int) -> Int {
  let y = x * 2
  y
}
```

### L_UNREACHABLE_CODE

A statement appears after a statically diverging statement (`return`, `break`, `continue`, a `Never`-returning call such as `panic`/`abort`, or an all-diverging `if`/`match`/block).

```pion before
pub fn f(x : Int) -> Int {
  return x + 1
  0
}
```

```pion after
pub fn f(x : Int) -> Int {
  return x + 1
}
```

### L_SELF_ASSIGN

A plain assignment `lhs = rhs` assigns a pure variable or field chain to itself (`x = x`, `self.pos = self.pos`).

```pion before
pub fn keep(n : Int) -> Int {
  let mut x = n
  x = x
  x
}
```

```pion after
pub fn keep(n : Int) -> Int {
  let x = n
  x
}
```

### L_FILE_TOO_LONG

A single `.pion` source file exceeds `10000` physical lines. Split it into multiple `.pion` files in the same package (same-package files share all symbols automatically).

```pion before
// @pad_lines 10000
pub fn ok() -> Int {
  1
}
```

```pion after
pub fn ok() -> Int {
  1
}
```
