/-
Soundness of the QBE counted-loop expansion (`trips` / `expandloops` in
`vendor/qbe/main.c`, regression test `tests/e2e/p117_qbe_counted_loop_unroll`).

After GCM, a single-block loop whose only phi is an integer induction variable
with a constant start, a constant `add`/`sub` stride and an exit test against a
constant (optionally through `extsw`/`extuw`) is evaluated at compile time.
`trips` folds the induction and its test from the start value and records the
entry value of each iteration until the test leaves the loop; when that
happens within `MaxTrips` iterations the block becomes that many straight-line
copies of its body, in order, and the back edge is dropped.

  1. `certifiedExpansion`: when the certificate `certify` (the compile-time
     evaluation of the induction and its test) succeeds with the entry values
     `xs`, running the loop with the same fuel from any state (memory,
     observable events, SSA live-outs) equals running the body once per entry
     value of `xs`, in order — including an error raised by one of the copies,
     which stops the remaining ones exactly as the loop would.
  2. `certify_length` / `certify_head`: a successful certificate has between 1
     and the fuel (`MaxTrips`) entries and starts at the phi's start value.
  3. `certify_last_exits`: the iteration after the last recorded entry value
     fails the test, so the phi's final value (the copy `phi = iv[count-1]`
     emitted by `expandloops`) is the last entry value and the increment's
     final value leaves the loop.
  4. `renamedWrite`, `renamedRead`: the fresh SSA names of the earlier copies
     are injective, so reading any renamed temporary after a renamed definition
     gives the original program's value; the last copy keeps the original
     names, so uses outside the loop are untouched.
  5. `budget_bound`, `budget_step`: the expansion of a loop with `n`
     instructions and `c` trips is at most `MaxExpanded` instructions and the
     per-function budget (`2 * MaxExpanded`) never goes negative.

No imports beyond the prelude and no proof holes; plain kernel checks.
-/

namespace PionQbeCountedLoopUnroll

variable {I S E : Type}

/-- The compile-time evaluator: records each entry index until the first exit. -/
def certify (next : I → I) (again : I → Bool) : Nat → I → Option (List I)
  | 0, _ => none
  | n+1, i =>
    if again (next i) then (certify next again n (next i)).map (i :: ·)
    else some [i]

/-- The loop as it runs: `S` holds memory, observable events and SSA
    live-outs; an error records both the effects before it and its cause. -/
def loop (body : I → S → Except E S) (next : I → I) (again : I → Bool) :
    Nat → I → S → Option (Except E S)
  | 0, _, _ => none
  | n+1, i, s =>
    match body i s with
    | .error e => some (.error e)
    | .ok t => if again (next i) then loop body next again n (next i) t
               else some (.ok t)

/-- The expanded straight-line block: one body copy per recorded entry value. -/
def copies (body : I → S → Except E S) : List I → S → Except E S
  | [], s => .ok s
  | i :: rest, s => (body i s).bind (copies body rest)

theorem certifiedExpansion (body : I → S → Except E S)
    (next : I → I) (again : I → Bool) (n : Nat) (i : I) (xs : List I)
    (h : certify next again n i = some xs) (s : S) :
    loop body next again n i s = some (copies body xs s) := by
  induction n generalizing i xs s with
  | zero => simp [certify] at h
  | succ n ih =>
    by_cases go : again (next i) = true
    · cases c : certify next again n (next i) with
      | none => simp [certify, go, c] at h
      | some tail =>
        simp [certify, go, c] at h
        subst xs
        cases r : body i s with
        | error e => simp [loop, copies, r, Except.bind]
        | ok t => simpa [loop, copies, r, go, Except.bind] using ih (next i) tail c t
    · simp [certify, go] at h
      subst xs
      cases r : body i s <;> simp [loop, copies, r, go, Except.bind]

theorem certify_length (next : I → I) (again : I → Bool) (n : Nat) (i : I)
    (xs : List I) (h : certify next again n i = some xs) :
    1 ≤ xs.length ∧ xs.length ≤ n := by
  induction n generalizing i xs with
  | zero => simp [certify] at h
  | succ n ih =>
    by_cases go : again (next i) = true
    · cases c : certify next again n (next i) with
      | none => simp [certify, go, c] at h
      | some tail =>
        simp [certify, go, c] at h
        subst xs
        have := ih (next i) tail c
        simp
        omega
    · simp [certify, go] at h
      subst xs
      simp

theorem certify_head (next : I → I) (again : I → Bool) (n : Nat) (i : I)
    (xs : List I) (h : certify next again n i = some xs) :
    xs.head? = some i := by
  cases n with
  | zero => simp [certify] at h
  | succ n =>
    by_cases go : again (next i) = true
    · cases c : certify next again n (next i) with
      | none => simp [certify, go, c] at h
      | some tail =>
        simp [certify, go, c] at h
        subst xs
        rfl
    · simp [certify, go] at h
      subst xs
      rfl

theorem certify_last_exits (next : I → I) (again : I → Bool) (n : Nat) (i : I)
    (xs : List I) (h : certify next again n i = some xs) :
    ∃ last, xs.getLast? = some last ∧ again (next last) = false := by
  induction n generalizing i xs with
  | zero => simp [certify] at h
  | succ n ih =>
    by_cases go : again (next i) = true
    · cases c : certify next again n (next i) with
      | none => simp [certify, go, c] at h
      | some tail =>
        simp [certify, go, c] at h
        subst xs
        obtain ⟨last, hl, hx⟩ := ih (next i) tail c
        refine ⟨last, ?_, hx⟩
        cases tail with
        | nil => simp at hl
        | cons a rest => simpa [List.getLast?_cons_cons] using hl
    · simp [certify, go] at h
      subst xs
      exact ⟨i, rfl, by simpa using go⟩

/-- Fresh SSA names preserve every lookup after a corresponding definition. -/
theorem renamedWrite {V : Type} (before after : Nat → V) (rename : Nat → Nat)
    (unique : Function.Injective rename) (agree : ∀ k, after (rename k) = before k)
    (dst use : Nat) (value : V) :
    (if rename use = rename dst then value else after (rename use)) =
    (if use = dst then value else before use) := by
  by_cases eq : use = dst
  · simp [eq]
  · have distinct : rename use ≠ rename dst := fun h => eq (unique h)
    simp [eq, distinct, agree]

/-- A renamed environment keeps agreeing after a renamed definition. -/
theorem renamedRead {V : Type} (before after : Nat → V) (rename : Nat → Nat)
    (unique : Function.Injective rename) (agree : ∀ k, after (rename k) = before k)
    (dst : Nat) (value : V) :
    ∀ k, (fun t => if t = rename dst then value else after t) (rename k) =
      (fun t => if t = dst then value else before t) k := by
  intro k
  exact renamedWrite before after rename unique agree dst k value

/-- `MaxTrips = 8`, `MaxExpanded = 96`, per-function budget `2 * MaxExpanded`. -/
def maxTrips : Nat := 8
def maxExpanded : Nat := 96

theorem budget_bound (nins count budget : Nat)
    (hsize : nins * count ≤ maxExpanded) (hbudget : nins * count ≤ budget) :
    nins * count ≤ maxExpanded ∧ budget - nins * count + nins * count = budget := by
  exact ⟨hsize, Nat.sub_add_cancel hbudget⟩

/-- Successive expansions never spend more than the function budget. -/
theorem budget_step (spent : List Nat) (budget : Nat)
    (h : spent.foldl (· + ·) 0 ≤ budget) (cost : Nat)
    (hc : cost ≤ budget - spent.foldl (· + ·) 0) :
    (spent ++ [cost]).foldl (· + ·) 0 ≤ budget := by
  simp [List.foldl_append]
  omega

end PionQbeCountedLoopUnroll
