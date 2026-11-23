/-
`PionLean`: the thin Lean 4 model of Pion's runtime used by code that
`pionc extract-lean` generates (SPEC §3.5). Everything here sits on top of
`Aeneas.Std` (`Result`, `ok`/`fail`, `loop`, scalars `Std.I32` ...): the
generated `Funs.lean` files `open Aeneas Aeneas.Std Result ControlFlow Error Pion`.

Semantics follow the native backend (`qbe.pion`) of `#verify` code exactly:
- `+ - *`, unary `-` and bitwise operators wrap (two's complement), pure;
- `/ %` fail with `divisionByZero` on a zero divisor and, for signed types,
  with `integerOverflow` on `MIN / -1` and `MIN % -1`;
- `<< >>` fail with `integerOverflow` unless `0 <= rhs < bits`; signed `>>` is
  arithmetic, unsigned `>>` is logical; `shl_i32` / `shr_i32` are the mixed
  `T << Int` forms (the count is compared at its own width, never truncated);
- conversions are the backend's bit casts / truncations / extensions;
- arrays index with `Std.I32` and fail with `arrayOutOfBounds` outside
  `[0, length)`.
-/
import Aeneas

open Aeneas Aeneas.Std Result Error

namespace Pion

universe u v

/-! ## Pion `Result[T, E]` (named `Res` so it never clashes with `Aeneas.Std.Result`) -/

inductive Res (T : Type u) (E : Type v) where
  | Ok (v : T)
  | Err (e : E)
deriving Repr, BEq, DecidableEq

namespace Res

variable {T : Type u} {E : Type v}

@[simp] def is_ok : Res T E → Bool
  | .Ok _ => true
  | .Err _ => false

@[simp] def is_err : Res T E → Bool
  | .Ok _ => false
  | .Err _ => true

@[simp] def unwrap_or : Res T E → T → T
  | .Ok v, _ => v
  | .Err _, d => d

end Res

/-! ## `Option[T]` helpers -/

namespace Option

variable {T : Type u}

@[simp] def is_some : _root_.Option T → Bool
  | some _ => true
  | none => false

@[simp] def is_none : _root_.Option T → Bool
  | some _ => false
  | none => true

@[simp] def unwrap_or : _root_.Option T → T → T
  | some v, _ => v
  | none, d => d

end Option

/-! ## Equality

`Pion.Eq T` is required by generic functions whose body compares `T` values
with `==` / `!=` (`tc.eq_tparams`); it extends `BEq`, so `a == b` works on
every Pion type that supports `==`. -/

class Eq (α : Type u) extends BEq α

instance : Pion.Eq Std.I32 := { toBEq := inferInstance }
instance : Pion.Eq Std.I64 := { toBEq := inferInstance }
instance : Pion.Eq Std.U32 := { toBEq := inferInstance }
instance : Pion.Eq Std.U64 := { toBEq := inferInstance }
instance : Pion.Eq Std.U8 := { toBEq := inferInstance }
instance : Pion.Eq Bool := { toBEq := inferInstance }
instance : Pion.Eq Char := { toBEq := inferInstance }
instance : Pion.Eq String := { toBEq := inferInstance }
instance : Pion.Eq Unit := { toBEq := inferInstance }

/-! ## Contracts -/

/-- `debug_assert(cond, msg)`: an `assertionFailure` when `cond` is false. -/
def debugAssert (b : Bool) : Result Unit :=
  if b then ok () else fail assertionFailure

/-- `panic(msg)` / unreachable code. -/
def panic {α : Type u} : Result α := fail Error.panic

/-! ## Scalars -/

namespace I32
@[simp] def add (x y : Std.I32) : Std.I32 := Std.I32.wrapping_add x y
@[simp] def sub (x y : Std.I32) : Std.I32 := Std.I32.wrapping_sub x y
@[simp] def mul (x y : Std.I32) : Std.I32 := Std.I32.wrapping_mul x y
@[simp] def neg (x : Std.I32) : Std.I32 := ⟨-x.bv⟩
@[simp] def band (x y : Std.I32) : Std.I32 := ⟨x.bv &&& y.bv⟩
@[simp] def bor (x y : Std.I32) : Std.I32 := ⟨x.bv ||| y.bv⟩
@[simp] def bxor (x y : Std.I32) : Std.I32 := ⟨x.bv ^^^ y.bv⟩
def div (x y : Std.I32) : Result Std.I32 := x / y
def rem (x y : Std.I32) : Result Std.I32 :=
  if x.val = -2147483648 ∧ y.val = -1 then fail integerOverflow else x % y
def shl (x y : Std.I32) : Result Std.I32 :=
  if 0 ≤ y.val ∧ y.val < 32 then ok ⟨x.bv <<< y.val.toNat⟩ else fail integerOverflow
def shr (x y : Std.I32) : Result Std.I32 :=
  if 0 ≤ y.val ∧ y.val < 32 then ok ⟨x.bv.sshiftRight y.val.toNat⟩ else fail integerOverflow
@[simp] def abs (x : Std.I32) : Std.I32 := if x.val < 0 then neg x else x
@[simp] def to_int (x : Std.I32) : Std.I32 := x
@[simp] def to_int64 (x : Std.I32) : Std.I64 := IScalar.cast .I64 x
@[simp] def to_uint (x : Std.I32) : Std.U32 := IScalar.hcast .U32 x
@[simp] def reinterpret_as_uint (x : Std.I32) : Std.U32 := IScalar.hcast .U32 x
@[simp] def to_byte (x : Std.I32) : Std.U8 := IScalar.hcast .U8 x
end I32

namespace I64
@[simp] def add (x y : Std.I64) : Std.I64 := Std.I64.wrapping_add x y
@[simp] def sub (x y : Std.I64) : Std.I64 := Std.I64.wrapping_sub x y
@[simp] def mul (x y : Std.I64) : Std.I64 := Std.I64.wrapping_mul x y
@[simp] def neg (x : Std.I64) : Std.I64 := ⟨-x.bv⟩
@[simp] def band (x y : Std.I64) : Std.I64 := ⟨x.bv &&& y.bv⟩
@[simp] def bor (x y : Std.I64) : Std.I64 := ⟨x.bv ||| y.bv⟩
@[simp] def bxor (x y : Std.I64) : Std.I64 := ⟨x.bv ^^^ y.bv⟩
def div (x y : Std.I64) : Result Std.I64 := x / y
def rem (x y : Std.I64) : Result Std.I64 :=
  if x.val = -9223372036854775808 ∧ y.val = -1 then fail integerOverflow else x % y
def shl (x y : Std.I64) : Result Std.I64 :=
  if 0 ≤ y.val ∧ y.val < 64 then ok ⟨x.bv <<< y.val.toNat⟩ else fail integerOverflow
def shr (x y : Std.I64) : Result Std.I64 :=
  if 0 ≤ y.val ∧ y.val < 64 then ok ⟨x.bv.sshiftRight y.val.toNat⟩ else fail integerOverflow
def shl_i32 (x : Std.I64) (y : Std.I32) : Result Std.I64 :=
  if 0 ≤ y.val ∧ y.val < 64 then ok ⟨x.bv <<< y.val.toNat⟩ else fail integerOverflow
def shr_i32 (x : Std.I64) (y : Std.I32) : Result Std.I64 :=
  if 0 ≤ y.val ∧ y.val < 64 then ok ⟨x.bv.sshiftRight y.val.toNat⟩ else fail integerOverflow
@[simp] def abs (x : Std.I64) : Std.I64 := if x.val < 0 then neg x else x
@[simp] def to_int (x : Std.I64) : Std.I32 := IScalar.cast .I32 x
@[simp] def to_int64 (x : Std.I64) : Std.I64 := x
@[simp] def to_uint64 (x : Std.I64) : Std.U64 := IScalar.hcast .U64 x
@[simp] def reinterpret_as_uint64 (x : Std.I64) : Std.U64 := IScalar.hcast .U64 x
end I64

namespace U32
@[simp] def add (x y : Std.U32) : Std.U32 := Std.U32.wrapping_add x y
@[simp] def sub (x y : Std.U32) : Std.U32 := Std.U32.wrapping_sub x y
@[simp] def mul (x y : Std.U32) : Std.U32 := Std.U32.wrapping_mul x y
@[simp] def neg (x : Std.U32) : Std.U32 := ⟨-x.bv⟩
@[simp] def band (x y : Std.U32) : Std.U32 := ⟨x.bv &&& y.bv⟩
@[simp] def bor (x y : Std.U32) : Std.U32 := ⟨x.bv ||| y.bv⟩
@[simp] def bxor (x y : Std.U32) : Std.U32 := ⟨x.bv ^^^ y.bv⟩
def div (x y : Std.U32) : Result Std.U32 := x / y
def rem (x y : Std.U32) : Result Std.U32 := x % y
def shl (x y : Std.U32) : Result Std.U32 :=
  if y.val < 32 then ok ⟨x.bv <<< y.val⟩ else fail integerOverflow
def shr (x y : Std.U32) : Result Std.U32 :=
  if y.val < 32 then ok ⟨x.bv >>> y.val⟩ else fail integerOverflow
def shl_i32 (x : Std.U32) (y : Std.I32) : Result Std.U32 :=
  if 0 ≤ y.val ∧ y.val < 32 then ok ⟨x.bv <<< y.val.toNat⟩ else fail integerOverflow
def shr_i32 (x : Std.U32) (y : Std.I32) : Result Std.U32 :=
  if 0 ≤ y.val ∧ y.val < 32 then ok ⟨x.bv >>> y.val.toNat⟩ else fail integerOverflow
@[simp] def to_int (x : Std.U32) : Std.I32 := UScalar.hcast .I32 x
@[simp] def reinterpret_as_int (x : Std.U32) : Std.I32 := UScalar.hcast .I32 x
@[simp] def to_uint (x : Std.U32) : Std.U32 := x
@[simp] def to_int64 (x : Std.U32) : Std.I64 := UScalar.hcast .I64 x
@[simp] def to_uint64 (x : Std.U32) : Std.U64 := UScalar.cast .U64 x
end U32

namespace U64
@[simp] def add (x y : Std.U64) : Std.U64 := Std.U64.wrapping_add x y
@[simp] def sub (x y : Std.U64) : Std.U64 := Std.U64.wrapping_sub x y
@[simp] def mul (x y : Std.U64) : Std.U64 := Std.U64.wrapping_mul x y
@[simp] def neg (x : Std.U64) : Std.U64 := ⟨-x.bv⟩
@[simp] def band (x y : Std.U64) : Std.U64 := ⟨x.bv &&& y.bv⟩
@[simp] def bor (x y : Std.U64) : Std.U64 := ⟨x.bv ||| y.bv⟩
@[simp] def bxor (x y : Std.U64) : Std.U64 := ⟨x.bv ^^^ y.bv⟩
def div (x y : Std.U64) : Result Std.U64 := x / y
def rem (x y : Std.U64) : Result Std.U64 := x % y
def shl (x y : Std.U64) : Result Std.U64 :=
  if y.val < 64 then ok ⟨x.bv <<< y.val⟩ else fail integerOverflow
def shr (x y : Std.U64) : Result Std.U64 :=
  if y.val < 64 then ok ⟨x.bv >>> y.val⟩ else fail integerOverflow
def shl_i32 (x : Std.U64) (y : Std.I32) : Result Std.U64 :=
  if 0 ≤ y.val ∧ y.val < 64 then ok ⟨x.bv <<< y.val.toNat⟩ else fail integerOverflow
def shr_i32 (x : Std.U64) (y : Std.I32) : Result Std.U64 :=
  if 0 ≤ y.val ∧ y.val < 64 then ok ⟨x.bv >>> y.val.toNat⟩ else fail integerOverflow
@[simp] def to_int (x : Std.U64) : Std.I32 := UScalar.hcast .I32 x
@[simp] def to_uint (x : Std.U64) : Std.U32 := UScalar.cast .U32 x
@[simp] def to_int64 (x : Std.U64) : Std.I64 := UScalar.hcast .I64 x
@[simp] def reinterpret_as_int64 (x : Std.U64) : Std.I64 := UScalar.hcast .I64 x
@[simp] def to_uint64 (x : Std.U64) : Std.U64 := x
end U64

namespace U8
@[simp] def add (x y : Std.U8) : Std.U8 := Std.U8.wrapping_add x y
@[simp] def sub (x y : Std.U8) : Std.U8 := Std.U8.wrapping_sub x y
@[simp] def mul (x y : Std.U8) : Std.U8 := Std.U8.wrapping_mul x y
@[simp] def band (x y : Std.U8) : Std.U8 := ⟨x.bv &&& y.bv⟩
@[simp] def bor (x y : Std.U8) : Std.U8 := ⟨x.bv ||| y.bv⟩
@[simp] def bxor (x y : Std.U8) : Std.U8 := ⟨x.bv ^^^ y.bv⟩
def div (x y : Std.U8) : Result Std.U8 := x / y
def rem (x y : Std.U8) : Result Std.U8 := x % y
@[simp] def to_int (x : Std.U8) : Std.I32 := UScalar.hcast .I32 x
@[simp] def to_int64 (x : Std.U8) : Std.I64 := UScalar.hcast .I64 x
end U8

/-! ## Arrays

`Array[T]`, `FixedArray[T]` and `Bytes` are values (Pion's `#verify` move /
borrow rules make every array uniquely owned), modelled as thin wrappers over
`List` indexed by `Std.I32`. -/

structure Array (α : Type u) where
  val : List α
deriving Repr, BEq, DecidableEq

structure FixedArray (α : Type u) where
  val : List α
deriving Repr, BEq, DecidableEq

structure Bytes where
  val : List Std.U8
deriving Repr, BEq, DecidableEq

instance {α : Type u} [BEq α] : Pion.Eq (Pion.Array α) := { toBEq := inferInstance }

/-- Index check shared by every container: `0 ≤ i < n`. -/
@[simp] def inBounds (i : Std.I32) (n : Nat) : Prop := 0 ≤ i.val ∧ i.val < n

instance (i : Std.I32) (n : Nat) : Decidable (inBounds i n) := by
  unfold inBounds; infer_instance

/-- `n` as an `Int` length (`integerOverflow` beyond `Int` range). -/
def lengthOf (n : Nat) : Result Std.I32 :=
  if h : n ≤ 2147483647 then
    ok (Std.I32.ofIntCore n ⟨by simp [IScalarTy.numBits], by simp [IScalarTy.numBits]; omega⟩)
  else fail integerOverflow

def listGet {α : Type u} (l : List α) (i : Std.I32) : Result α :=
  if h : inBounds i l.length then ok (l.get ⟨i.val.toNat, by simp at h; omega⟩)
  else fail arrayOutOfBounds

def listSet {α : Type u} (l : List α) (i : Std.I32) (x : α) : Result (List α) :=
  if inBounds i l.length then ok (l.set i.val.toNat x) else fail arrayOutOfBounds

def listSwap {α : Type u} (l : List α) (i j : Std.I32) : Result (List α) := do
  let a ← listGet l i
  let b ← listGet l j
  ok ((l.set i.val.toNat b).set j.val.toNat a)

/-- `max(n, 0)` copies of `x` (`Array::make` / `FixedArray::make` clamp negative lengths). -/
def listMake {α : Type u} (n : Std.I32) (x : α) : List α := List.replicate n.val.toNat x

namespace Array
variable {α : Type u}
@[simp] def new : Pion.Array α := ⟨[]⟩
@[simp] def ofList (l : List α) : Pion.Array α := ⟨l⟩
@[simp] def make (n : Std.I32) (x : α) : Pion.Array α := ⟨listMake n x⟩
def length (a : Pion.Array α) : Result Std.I32 := lengthOf a.val.length
def get (a : Pion.Array α) (i : Std.I32) : Result α := listGet a.val i
def set (a : Pion.Array α) (i : Std.I32) (x : α) : Result (Pion.Array α) := do
  let l ← listSet a.val i x
  ok ⟨l⟩
@[simp] def push (a : Pion.Array α) (x : α) : Pion.Array α := ⟨a.val ++ [x]⟩
@[simp] def pop (a : Pion.Array α) : _root_.Option α × Pion.Array α :=
  (a.val.getLast?, ⟨a.val.dropLast⟩)
def swap (a : Pion.Array α) (i j : Std.I32) : Result (Pion.Array α) := do
  let l ← listSwap a.val i j
  ok ⟨l⟩
@[simp] def copy (a : Pion.Array α) : Pion.Array α := a
@[simp] def clear (_ : Pion.Array α) : Pion.Array α := ⟨[]⟩
@[simp] def reverse (a : Pion.Array α) : Pion.Array α := ⟨a.val.reverse⟩
@[simp] def fill (a : Pion.Array α) (x : α) : Pion.Array α := ⟨a.val.map (fun _ => x)⟩
@[simp] def contains [BEq α] (a : Pion.Array α) (x : α) : Bool := a.val.contains x
end Array

namespace FixedArray
variable {α : Type u}
@[simp] def ofList (l : List α) : Pion.FixedArray α := ⟨l⟩
@[simp] def make (n : Std.I32) (x : α) : Pion.FixedArray α := ⟨listMake n x⟩
@[simp] def from_array (a : Pion.Array α) : Pion.FixedArray α := ⟨a.val⟩
def length (a : Pion.FixedArray α) : Result Std.I32 := lengthOf a.val.length
def get (a : Pion.FixedArray α) (i : Std.I32) : Result α := listGet a.val i
def set (a : Pion.FixedArray α) (i : Std.I32) (x : α) : Result (Pion.FixedArray α) := do
  let l ← listSet a.val i x
  ok ⟨l⟩
def swap (a : Pion.FixedArray α) (i j : Std.I32) : Result (Pion.FixedArray α) := do
  let l ← listSwap a.val i j
  ok ⟨l⟩
@[simp] def copy (a : Pion.FixedArray α) : Pion.FixedArray α := a
@[simp] def reverse (a : Pion.FixedArray α) : Pion.FixedArray α := ⟨a.val.reverse⟩
@[simp] def fill (a : Pion.FixedArray α) (x : α) : Pion.FixedArray α := ⟨a.val.map (fun _ => x)⟩
@[simp] def contains [BEq α] (a : Pion.FixedArray α) (x : α) : Bool := a.val.contains x
end FixedArray

namespace Bytes
/-- `Bytes::new(n)`: `n` zero bytes. -/
@[simp] def new (n : Std.I32) : Pion.Bytes := ⟨listMake n (0#u8)⟩
def length (b : Pion.Bytes) : Result Std.I32 := lengthOf b.val.length
def get (b : Pion.Bytes) (i : Std.I32) : Result Std.U8 := listGet b.val i
def set (b : Pion.Bytes) (i : Std.I32) (x : Std.U8) : Result Pion.Bytes := do
  let l ← listSet b.val i x
  ok ⟨l⟩
@[simp] def copy (b : Pion.Bytes) : Pion.Bytes := b
end Bytes

/-! ## Double (bit-pattern representation) -/

structure Double where
  bits : Std.U64
deriving Repr, BEq, DecidableEq

instance : Pion.Eq Pion.Double := { toBEq := inferInstance }

namespace Double
@[simp] def to_bits (d : Pion.Double) : Std.I64 := ⟨d.bits.bv⟩
@[simp] def reinterpret_as_uint64 (d : Pion.Double) : Std.U64 := d.bits
@[simp] def from_bits (b : Std.I64) : Pion.Double := ⟨⟨b.bv⟩⟩
end Double

@[simp] def I64.reinterpret_as_double (b : Std.I64) : Pion.Double := ⟨⟨b.bv⟩⟩
@[simp] def U64.reinterpret_as_double (b : Std.U64) : Pion.Double := ⟨b⟩

/-! ## StringBuilder -/

structure StringBuilder where
  val : List Std.U8
deriving Repr, BEq, DecidableEq

namespace StringBuilder
@[simp] def u8OfByte (b : UInt8) : Std.U8 := ⟨b.toBitVec⟩
@[simp] def byteOfU8 (b : Std.U8) : UInt8 := UInt8.ofBitVec b.bv

def bytesOfString (s : _root_.String) : List Std.U8 :=
  s.toUTF8.data.toList.map u8OfByte

@[simp] def new : Pion.StringBuilder := ⟨[]⟩
@[simp] def write_byte (sb : Pion.StringBuilder) (b : Std.U8) : Pion.StringBuilder :=
  ⟨sb.val ++ [b]⟩
@[simp] def write_string (sb : Pion.StringBuilder) (s : _root_.String) : Pion.StringBuilder :=
  ⟨sb.val ++ bytesOfString s⟩
@[simp] def write_substring (sb : Pion.StringBuilder) (s : _root_.String)
    (start end_ : Std.I32) : Pion.StringBuilder :=
  let bs := bytesOfString s
  let s0 : Nat := if start.val < 0 then 0 else start.val.toNat
  let e0 : Nat := if end_.val < 0 then 0 else min end_.val.toNat bs.length
  if s0 < e0 then ⟨sb.val ++ (bs.drop s0).take (e0 - s0)⟩ else sb
@[simp] def clear (_ : Pion.StringBuilder) : Pion.StringBuilder := ⟨[]⟩
def length (sb : Pion.StringBuilder) : Result Std.I32 := lengthOf sb.val.length
def to_string (sb : Pion.StringBuilder) : _root_.String :=
  _root_.String.fromUTF8! ⟨(sb.val.map byteOfU8).toArray⟩
end StringBuilder

/-! ## Map -/

structure Map (κ : Type u) (ν : Type v) where
  entries : List (κ × ν)
deriving Repr, BEq, DecidableEq

namespace Map
variable {κ : Type u} {ν : Type v}

def listGet [BEq κ] : List (κ × ν) → κ → _root_.Option ν
  | [], _ => none
  | (k', v') :: rest, k => if k' == k then some v' else listGet rest k

def listSet [BEq κ] : List (κ × ν) → κ → ν → List (κ × ν)
  | [], k, v => [(k, v)]
  | (k', v') :: rest, k, v =>
    if k' == k then (k, v) :: rest else (k', v') :: listSet rest k v

def listRemove [BEq κ] : List (κ × ν) → κ → List (κ × ν)
  | [], _ => []
  | (k', v') :: rest, k =>
    if k' == k then listRemove rest k else (k', v') :: listRemove rest k

@[simp] def new : Pion.Map κ ν := ⟨[]⟩
@[simp] def get [BEq κ] (m : Pion.Map κ ν) (k : κ) : _root_.Option ν := listGet m.entries k
@[simp] def set [BEq κ] (m : Pion.Map κ ν) (k : κ) (v : ν) : Pion.Map κ ν := ⟨listSet m.entries k v⟩
@[simp] def remove [BEq κ] (m : Pion.Map κ ν) (k : κ) : Pion.Map κ ν := ⟨listRemove m.entries k⟩
@[simp] def clear (_ : Pion.Map κ ν) : Pion.Map κ ν := ⟨[]⟩
@[simp] def contains [BEq κ] (m : Pion.Map κ ν) (k : κ) : Bool := (m.get k).isSome
def length (m : Pion.Map κ ν) : Result Std.I32 := lengthOf m.entries.length
@[simp] def copy (m : Pion.Map κ ν) : Pion.Map κ ν := m
end Map

/-! ## String -/

namespace String
/-- `s.length()`: the UTF-8 byte length. -/
def length (s : _root_.String) : Result Std.I32 := lengthOf s.utf8ByteSize
@[simp] def concat (a b : _root_.String) : _root_.String := a ++ b
end String

end Pion
