/-
Invariants behind two byte-identical frontend compile-speed optimizations:
  1. `compiler/src/cli/main.pion` `drv_build_targets`: on the parallel direct
     object path the driver emits each backend batch's SSA, in the original
     unit order, and starts that batch's QBE worker right away instead of
     emitting every unit first. Emitting batch by batch yields the same
     results, and the same first frontend error, as emitting everything up
     front (`batch_order_and_failure`). Workers write private indexed
     destinations, so the order in which they finish does not matter
     (`disjoint_writes`).
  2. `compiler/src/core/lexer.pion`: identifier, number and `@pkg.member`
     ranges are accepted code unit by code unit with ASCII predicates, so
     they are ASCII (`accepted_prefix`), and copying an ASCII range scalar by
     scalar gives back the same code units as a raw slice (`ascii_range`).
     `keyword_or_ident` compares a word only with the keywords of its own
     length; restricting the table to that length keeps the first match and
     the fallback (`length_partition`).

No imports and no proof holes; plain kernel checks (compatible with
both standalone `lean -DwarningAsError=true` and `scripts/test-lean.sh`).
-/

namespace PionQbeFrontendSpeedOpts

section Pipeline

variable {U S O : Type}

/-- The previous producer: every batch's SSA is emitted before any backend. -/
def prepare (emit : U → Except String S) (batches : List (List U)) :
    Except String (List (List S)) :=
  batches.mapM (fun batch => batch.mapM emit)

/-- The pipelined producer: emit one batch, hand it to the backend, go on. -/
def interleaved (emit : U → Except String S) (compile : List S → O) :
    List (List U) → Except String (List O)
  | [] => .ok []
  | b :: bs => do
    let ready ← b.mapM emit
    let temporary := compile ready
    let rest ← interleaved emit compile bs
    pure (temporary :: rest)

theorem batch_order_and_failure (emit : U → Except String S) (compile : List S → O)
    (batches : List (List U)) :
    interleaved emit compile batches =
      (prepare emit batches).map (List.map compile) := by
  induction batches with
  | nil => rfl
  | cons b bs ih =>
    simp only [prepare] at *
    simp only [interleaved, List.mapM_cons, ih]
    cases hb : b.mapM emit with
    | error msg => rfl
    | ok xs =>
      cases ht : List.mapM (fun batch : List U => batch.mapM emit) bs with
      | error msg => rfl
      | ok ys => rfl

/-- A worker publishing its result into its own slot. -/
def put (store : Nat → Option O) (i : Nat) (v : O) (k : Nat) : Option O :=
  if i = k then some v else store k

theorem disjoint_writes (store : Nat → Option O) (i j : Nat) (x y : O) (h : i ≠ j) :
    put (put store i x) j y = put (put store j y) i x := by
  funext k
  by_cases hi : i = k
  · subst k
    simp [put, Ne.symm h]
  · simp [put, hi]

end Pipeline

section Lexer

/-- The previous builder: ASCII units copied as is, others re-encoded. -/
def encodeRange (wide : Nat → List Nat) : List Nat → List Nat
  | [] => []
  | c :: cs => (if c < 128 then [c] else wide c) ++ encodeRange wide cs

theorem ascii_range (wide : Nat → List Nat) (xs : List Nat) (h : ∀ x ∈ xs, x < 128) :
    encodeRange wide xs = xs := by
  induction xs with
  | nil => rfl
  | cons x xs ih =>
    simp [encodeRange, h x (by simp), ih (fun y hy => h y (by simp [hy]))]

/-- A scanner that grows a range while `accept` holds. -/
def scan (accept : Nat → Bool) : List Nat → List Nat
  | [] => []
  | c :: cs => if accept c then c :: scan accept cs else []

theorem accepted_prefix (accept : Nat → Bool) (bounds : ∀ c, accept c = true → c < 128)
    (input : List Nat) : ∀ c ∈ scan accept input, c < 128 := by
  induction input with
  | nil => simp [scan]
  | cons x xs ih =>
    cases h : accept x with
    | false => simp [scan, h]
    | true =>
      intro c hc
      simp [scan, h] at hc
      rcases hc with rfl | hc
      · exact bounds _ h
      · exact ih c hc

/-- First exact match in a keyword table. -/
def first (w : String) (table : List (String × Nat)) : Option Nat :=
  match table with
  | [] => none
  | (k, v) :: ks => if w = k then some v else first w ks

theorem length_partition (w : String) (table : List (String × Nat)) :
    first w (table.filter (fun e => decide (e.1.length = w.length))) = first w table := by
  induction table with
  | nil => rfl
  | cons kv xs ih =>
    obtain ⟨k, v⟩ := kv
    by_cases h : k.length = w.length
    · by_cases e : w = k <;> simp [List.filter, h, first, e, ih]
    · have e : w ≠ k := fun eq => h (congrArg String.length eq.symm)
      simp [List.filter, h, first, e, ih]

end Lexer

end PionQbeFrontendSpeedOpts
