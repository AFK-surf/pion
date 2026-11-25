/-
Invariants behind two AMD64 scalar floating-point dependency-breaking
optimizations and the text-assembly conversion width fix in
`vendor/qbe/amd64/{all.h,elf.c,emit.c}`.

Register copies (`Ocopy`, also reached from `Oneg` / `Odiv` through
`emitcopy`). A QBE `s` / `d` value lives only in the low 32 / 64 bits of an
XMM register. The amd64_sysv emitters (text and direct ELF) now copy XMM to
XMM with `movaps` (`0f 28 /r`), which writes the whole register instead of
merging the low lane into the old destination value; memory and stack-slot
moves keep `movss` / `movsd`. amd64_win keeps the scalar moves and adds no
`xorps` below: xmm6..xmm15 are callee-saved in all 128 bits there and QBE
does not save them.

  1. `copyEquiv`: a full-register copy and a scalar low-lane merge agree on
     the low lane of every register.

Grouped conversions (`amd64_grouped_cvt` in `amd64/all.h`). In a block with
at least two `swtof` / `sltof`, every such conversion is preceded by
`xorps %xmmD, %xmmD`; isolated conversions are emitted unchanged. The
integer source is a general-purpose register or memory, never the XMM
destination.

  2. `convertEquiv`: zeroing the destination before the same scalar
     conversion keeps every low lane and the final floating-point status.
  3. `guardedEquiv`: the same holds whether the per-block guard is on or off.
  4. `groupedSpec`: the early-exit scan of `amd64_grouped_cvt` returns
     exactly `2 <= #conversions in the block`.
  5. `noneFalse` / `singleFalse`: a block with zero or one conversion is not
     grouped (no `xorps`).
  6. `groupedTrue`: a block with two or more conversions is grouped.
  7. `groupedAppend`: the guard only depends on the conversion count, so it
     is monotone when instructions are appended to a block.

Conversion width (`omap[]` in `amd64/emit.c`). `cvtsi2sd (%rsp), %xmm0`
without a suffix is assembled by GNU `as` as a dword load; the direct ELF
emitter sets REX.W for `sltof`. The text templates now carry an explicit
`l` / `q` suffix.

  8. `explicitWidth`: with the suffix chosen from the QBE operand width, the
     text path reads the same little-endian integer as the object path.
  9. `widthMatters`: for the spilled value 2^32 + 1 a dword read yields 1.

These are local models: the scalar conversion is an abstract function of
the integer source and the floating-point environment, and the observable
state is the low lane of each register (QBE never reads the upper lanes).
The correspondence with the emitted code is covered by
`tests/e2e/p113_amd64_fp_dep_and_cvt_width`.

No imports and no proof holes; plain kernel checks (compatible with both
standalone `lean -DwarningAsError=true` and `scripts/test-lean.sh`).
-/

namespace PionQbeAmd64FpOpts

namespace ScalarLanes

/-- An architectural XMM value split at the QBE scalar width. -/
structure Xmm (n : Nat) where
  low : BitVec n
  high : BitVec (128 - n)

abbrev File (n : Nat) := Fin 16 → Xmm n

def write {n : Nat} (f : File n) (d : Fin 16) (v : Xmm n) : File n :=
  fun r => if r = d then v else f r

/-- `movss` / `movsd` register form: merge the low lane into `d`. -/
def scalarMove {n : Nat} (f : File n) (s d : Fin 16) : File n :=
  write f d ⟨(f s).low, (f d).high⟩

/-- `movaps`: copy the whole register. -/
def packedMove {n : Nat} (f : File n) (s d : Fin 16) : File n :=
  write f d (f s)

def observes {n : Nat} (a b : File n) : Prop := ∀ r, (a r).low = (b r).low

theorem copyEquiv {n : Nat} (f : File n) (s d : Fin 16) :
    observes (scalarMove f s d) (packedMove f s d) := by
  intro r
  by_cases h : r = d <;> simp [scalarMove, packedMove, write, h]

/-- `xorps %xmmD, %xmmD`. -/
def zeroReg {n : Nat} (f : File n) (d : Fin 16) : File n := write f d ⟨0, 0⟩

/-- `cvtsi2ss` / `cvtsi2sd`: the same SSE operation evaluates the integer
source in the floating-point environment `st`, returning the value and the
final status; the upper lanes of `d` are merged. -/
def convert {m n : Nat} {Status : Type} (eval : BitVec m → Status → BitVec n × Status)
    (src : BitVec m) (st : Status) (f : File n) (d : Fin 16) : File n × Status :=
  let (v, st') := eval src st
  (write f d ⟨v, (f d).high⟩, st')

theorem convertEquiv {m n : Nat} {Status : Type}
    (eval : BitVec m → Status → BitVec n × Status)
    (src : BitVec m) (st : Status) (f : File n) (d : Fin 16) :
    let a := convert eval src st f d
    let b := convert eval src st (zeroReg f d) d
    observes a.1 b.1 ∧ a.2 = b.2 := by
  constructor
  · intro r
    by_cases h : r = d <;> simp [convert, zeroReg, write, h]
  · rfl

theorem guardedEquiv {m n : Nat} {Status : Type}
    (enabled : Bool) (eval : BitVec m → Status → BitVec n × Status)
    (src : BitVec m) (st : Status) (f : File n) (d : Fin 16) :
    let a := convert eval src st f d
    let b := convert eval src st (if enabled then zeroReg f d else f) d
    observes a.1 b.1 ∧ a.2 = b.2 := by
  cases enabled with
  | false => exact ⟨fun _ => rfl, rfl⟩
  | true => exact convertEquiv eval src st f d

end ScalarLanes

namespace GroupedCvt

/-- A block instruction as seen by `amd64_grouped_cvt`. -/
inductive Op where
  | swtof
  | sltof
  | other (code : Nat)

def isCvt : Op → Bool
  | .swtof => true
  | .sltof => true
  | .other _ => false

/-- Specification: the number of `swtof` / `sltof` in the block. -/
def count (ins : List Op) : Nat := (ins.filter isCvt).length

/-- The C loop: `if (op is a conversion) if (++count == 2) return 1;`,
then `return 0` after the last instruction. -/
def scan : List Op → Nat → Bool
  | [], _ => false
  | o :: os, c =>
    if isCvt o then
      if c + 1 = 2 then true else scan os (c + 1)
    else scan os c

def grouped (ins : List Op) : Bool := scan ins 0

theorem count_cons (o : Op) (os : List Op) :
    count (o :: os) = (if isCvt o then 1 else 0) + count os := by
  cases o <;> simp [count, isCvt, List.filter_cons] <;> omega

theorem scan_spec (ins : List Op) (c : Nat) (hc : c < 2) :
    scan ins c = decide (2 ≤ c + count ins) := by
  induction ins generalizing c with
  | nil =>
    simp only [scan, count, List.filter_nil, List.length_nil, Nat.add_zero]
    exact (decide_eq_false (by omega)).symm
  | cons o os ih =>
    rw [count_cons]
    cases hcv : isCvt o with
    | false =>
      simp only [scan, hcv, Bool.false_eq_true, ↓reduceIte, Nat.zero_add]
      exact ih c hc
    | true =>
      simp only [scan, hcv, ↓reduceIte]
      by_cases h2 : c + 1 = 2
      · simp only [h2, ↓reduceIte]
        exact (decide_eq_true (by omega)).symm
      · simp only [h2, ↓reduceIte]
        rw [ih (c + 1) (by omega)]
        have e : c + 1 + count os = c + (1 + count os) := by omega
        rw [e]

theorem groupedSpec (ins : List Op) : grouped ins = decide (2 ≤ count ins) := by
  rw [grouped, scan_spec ins 0 (by decide)]
  simp

theorem noneFalse (ins : List Op) (h : count ins = 0) : grouped ins = false := by
  rw [groupedSpec, h]
  decide

theorem singleFalse (ins : List Op) (h : count ins = 1) : grouped ins = false := by
  rw [groupedSpec, h]
  decide

theorem groupedTrue (ins : List Op) (h : 2 ≤ count ins) : grouped ins = true := by
  rw [groupedSpec]
  exact decide_eq_true h

theorem count_append (xs ys : List Op) : count (xs ++ ys) = count xs + count ys := by
  simp [count, List.filter_append]

theorem groupedAppend (xs ys : List Op) (h : grouped xs = true) :
    grouped (xs ++ ys) = true := by
  rw [groupedSpec] at h
  apply groupedTrue
  rw [count_append]
  have := of_decide_eq_true h
  omega

end GroupedCvt

namespace SpillWidth

def loadLE (memory : Nat → Nat) (base bytes : Nat) : Nat :=
  match bytes with
  | 0 => 0
  | n + 1 => loadLE memory base n + (memory (base + n) % 256) * 256 ^ n

inductive Width where
  | word
  | long

def widthBytes : Width → Nat
  | .word => 4
  | .long => 8

/-- Direct ELF: REX.W is set exactly for `sltof`. -/
def objectSource (w : Width) (mem : Nat → Nat) (a : Nat) : Nat :=
  loadLE mem a (widthBytes w)

/-- GNU `as`: the memory operand width comes from the mnemonic suffix. -/
def textSource (rexW : Bool) (mem : Nat → Nat) (a : Nat) : Nat :=
  loadLE mem a (if rexW then 8 else 4)

/-- `cvtsi2%kl` for `swtof`, `cvtsi2%kq` for `sltof`. -/
def suffixQ : Width → Bool
  | .word => false
  | .long => true

theorem explicitWidth (w : Width) (mem : Nat → Nat) (a : Nat) :
    textSource (suffixQ w) mem a = objectSource w mem a := by
  cases w <;> rfl

/-- The little-endian bytes of 2^32 + 1 at a spill slot. -/
def exampleBytes (k : Nat) : Nat :=
  if k = 0 ∨ k = 4 then 1 else 0

theorem widthMatters :
    textSource false exampleBytes 0 = 1 ∧
    objectSource .long exampleBytes 0 = 4294967297 := by decide

end SpillWidth

end PionQbeAmd64FpOpts
