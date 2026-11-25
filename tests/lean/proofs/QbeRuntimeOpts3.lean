/-
Invariants behind two native runtime optimizations:

Bounded format (`qbe_bounded_format` in `compiler/src/core/qbe.pion`).
In a native hot loop, a string `+` chain of at most 8 parts whose literals
are ASCII of at most 8 bytes and whose other parts are `.to_string()` of
`Int` / `Int64` locals (no trait dispatch) is written into one stack
`PionStrBuf` allocated at function entry. Its capacity is the literal bytes
plus 20 bytes per integer plus 1 trailing byte; one `pion_str_from_cstr`
copies the `len` bytes into the owned result.

  1. `signedWidth`: a signed 64-bit decimal (magnitude at most 2^63) needs at
     most 20 bytes including its sign.
  2. `widen`: `extsw` of an `Int` keeps its value, so the 64-bit formatter
     prints the same number as the heap path.
  3. `appends`: writing the pieces left to right appends exactly their
     concatenation to the buffer.
  4. `capacity`: after any prefix of the chain, the written bytes plus the
     trailing byte fit the reserved capacity, so `pion_strbuf_reserve`
     never grows (frees or reallocates) the stack buffer.
  5. `copyExact`: copying `len` bytes yields exactly the formatted output,
     whatever stale bytes follow it (embedded NUL bytes included).

Grouped conversions (`groupconverts` in `vendor/qbe/gcm.c`). In a loop block
of at most 192 instructions without stores or calls, holding 2..4
`swtof` / `Kd` and only virtual temporaries, the conversions and their
in-block integer (non-comparison) dependencies are stably moved first.

  6. `independent`: two definitions that neither read nor write each other's
     destination commute.
  7. `slide`: an operation commuting with every member of a list may be
     moved past the whole list.
  8. `schedule`: a stable early/late partition keeps the final state when
     every late operation commutes with the early ones after it.
  9. `fitsSignificand`: every 32-bit value fits the 53-bit binary64
     significand, so each conversion is exact.

These are local models: the format proofs take the shared integer formatter
(`pion_fmt_i64_end`) as an abstract `fmt`, and the schedule proofs assume
unique SSA definitions with dependencies closed in the block. The
correspondence with the code is covered by
`tests/e2e/p112_bounded_format_and_swtof_sched`.

No imports and no proof holes; plain kernel checks (compatible with both
standalone `lean -DwarningAsError=true` and `scripts/test-lean.sh`).
-/

namespace PionQbeRuntimeOpts3

namespace BoundedFormat

inductive Piece where
  | literal (bytes : List UInt8)
  | number (value : BitVec 64)

def width (n : Nat) : Nat :=
  if n < 10 then 1 else width (n / 10) + 1
termination_by n
decreasing_by omega

theorem width_le (n k : Nat) (h : n < 10 ^ (k + 1)) : width n ≤ k + 1 := by
  induction k generalizing n with
  | zero => simp at h; simp [width, h]
  | succ k ih =>
    rw [width]
    split
    · omega
    · have bound : n / 10 < 10 ^ (k + 1) := by
        rw [Nat.pow_succ] at h
        omega
      have := ih (n / 10) bound
      omega

theorem signedWidth (n : Nat) (sgn : Bool) (h : n ≤ 2^63) :
    width n + (if sgn then 1 else 0) ≤ 20 := by
  have := width_le n 18 (by omega)
  cases sgn <;> simp <;> omega

theorem widen (v : BitVec 32) : (v.signExtend 64).toInt = v.toInt :=
  BitVec.toInt_signExtend_of_le (by decide)

def emit (fmt : BitVec 64 → List UInt8) : Piece → List UInt8
  | .literal b => b
  | .number v => fmt v

def budget : Piece → Nat
  | .literal b => b.length
  | .number _ => 20

def output (fmt : BitVec 64 → List UInt8) (ps : List Piece) : List UInt8 :=
  ps.flatMap (emit fmt)

def write (fmt : BitVec 64 → List UInt8) : List Piece → List UInt8 → List UInt8
  | [], buf => buf
  | p :: ps, buf => write fmt ps (buf ++ emit fmt p)

theorem appends (fmt : BitVec 64 → List UInt8) (ps : List Piece) (buf : List UInt8) :
    write fmt ps buf = buf ++ output fmt ps := by
  induction ps generalizing buf with
  | nil => simp [write, output]
  | cons p ps ih => simp [write, ih, output, List.append_assoc]

theorem capacity (fmt : BitVec 64 → List UInt8) (limited : ∀ v, (fmt v).length ≤ 20)
    (front rest : List Piece) :
    (output fmt front).length + 1 ≤ ((front ++ rest).map budget).sum + 1 := by
  induction front with
  | nil => simp [output]
  | cons p ps ih =>
    have h : (emit fmt p).length ≤ budget p := by
      cases p with
      | literal b => exact Nat.le_refl _
      | number v => exact limited v
    simp only [output, List.flatMap_cons, List.length_append, List.cons_append,
      List.map_cons, List.sum_cons] at *
    omega

theorem copyExact (fmt : BitVec 64 → List UInt8) (ps : List Piece) (old : List UInt8) :
    ((write fmt ps [] ++ old).take (write fmt ps []).length) = output fmt ps := by
  simp [appends]

end BoundedFormat

namespace ExactSchedule

abbrev Regs := Nat → Nat

structure Def where
  dst : Nat
  src₁ : Nat
  src₂ : Nat
  evalNat : Nat → Nat → Nat

def write (r : Regs) (d v : Nat) : Regs :=
  fun k => if k = d then v else r k

def step (i : Def) (r : Regs) : Regs :=
  write r i.dst (i.evalNat (r i.src₁) (r i.src₂))

theorem independent (a b : Def) (r : Regs) (hd : a.dst ≠ b.dst)
    (ha : a.src₁ ≠ b.dst) (hb : a.src₂ ≠ b.dst)
    (hc : b.src₁ ≠ a.dst) (he : b.src₂ ≠ a.dst) :
    step a (step b r) = step b (step a r) := by
  funext k
  by_cases h : k = a.dst
  · subst k
    simp [step, write, *]
  · by_cases j : k = b.dst
    · subst k
      simp [step, write, *]
    · simp [step, write, *]

variable {σ : Type}
abbrev Op (σ : Type) := σ → σ

def run : List (Op σ) → σ → σ
  | [], state => state
  | f :: fs, state => run fs (f state)

theorem runAppend (xs ys : List (Op σ)) (s : σ) :
    run (xs ++ ys) s = run ys (run xs s) := by
  induction xs generalizing s with
  | nil => rfl
  | cons f fs ih => exact ih (f s)

theorem slide (lateOp : Op σ) (es : List (Op σ)) (s : σ)
    (h : ∀ e ∈ es, ∀ t, e (lateOp t) = lateOp (e t)) :
    run es (lateOp s) = lateOp (run es s) := by
  induction es generalizing s with
  | nil => rfl
  | cons e es ih =>
    change run es (e (lateOp s)) = lateOp (run es (e s))
    rw [h e (by simp) s]
    exact ih (e s) (by intro x hx; exact h x (by simp [hx]))

inductive Item (σ : Type) where
  | early (f : Op σ)
  | late (f : Op σ)

def orig : List (Item σ) → List (Op σ)
  | [] => []
  | .early f :: xs | .late f :: xs => f :: orig xs

def front : List (Item σ) → List (Op σ)
  | [] => []
  | .early f :: xs => f :: front xs
  | .late _ :: xs => front xs

def back : List (Item σ) → List (Op σ)
  | [] => []
  | .early _ :: xs => back xs
  | .late f :: xs => f :: back xs

def closed : List (Item σ) → Prop
  | [] => True
  | .early _ :: xs => closed xs
  | .late f :: xs => (∀ e ∈ front xs, ∀ t, e (f t) = f (e t)) ∧ closed xs

theorem schedule (xs : List (Item σ)) (s : σ) (h : closed xs) :
    run (orig xs) s = run (front xs ++ back xs) s := by
  induction xs generalizing s with
  | nil => rfl
  | cons x xs ih =>
    cases x with
    | early e => exact ih (e s) h
    | late f =>
      change run (orig xs) (f s) = run (front xs ++ f :: back xs) s
      rw [ih (f s) h.2, runAppend, runAppend, slide f (front xs) s h.1]
      rfl

theorem fitsSignificand (v : BitVec 32) : v.toNat < 2^53 := by
  have h := v.isLt
  omega

end ExactSchedule

end PionQbeRuntimeOpts3
