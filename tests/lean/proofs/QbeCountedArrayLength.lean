/-
Soundness of the counted-fill array length immediate
(`qbe_record_counted_fill` / `qbe_array_length_operand` in
`compiler/src/core/qbe.pion`, regression test
`tests/e2e/p124_counted_array_length`).

For consecutive fresh local integer arrays and a zero-initialised `Int`
counter,

    let a : Array[Int] = []
    let b : Array[Int] = []
    let mut i = 0
    while i < N { a.push(c0); b.push(c1); i = i + 1 }

with an integer literal `0 <= N <= 2147483647`, the front end records `N` on
each array binding whose later statements keep its length stable (no push,
pop, alias, escaping capture, call argument or `mut` argument) and emits the
unsigned bounds checks of the later element reads and writes against the
immediate `N` instead of a load of the array header length. The index, the
element access and the `pion_panic_oob(idx, len)` diagnostic are unchanged.

  1. `counted_fill` / `terminal_length` / `int_counter_safe`: every iteration
     advances the counter and the array length together, so the loop leaves
     both at `N`; the last increment stays inside signed 32-bit `Int`.
  2. `multi_array_fill_independent`: with one push per distinct fresh array per
     iteration, every array ends with exactly `N` elements (its own literal).
  3. `checks_preserved` / `stable_length` / `effect_size` / `trace_equivalence`:
     reads and element writes keep the length, so any later sequence of reads
     and writes has the same read values, final array and first out-of-bounds
     diagnostic `(idx, len)` whether checked against the header or against `N`.
  4. `oob_negative_index_traps`: a negative signed 32-bit index, sign-extended
     to 64 bits, is at least `2^63` and fails the unsigned check against any
     `N <= 2147483647` with the exact `(idx, N)` diagnostic.
  5. `empty_fill_always_traps`: for `N = 0` every 64-bit index fails with
     `(idx, 0)`.

The correspondence between these models and the matched Pion AST is covered by
the compiler unit tests in `compiler/src/core/backend_test.pion` and the p124
end-to-end test; the model does not cover the whole front end, QBE or the
register allocator.
-/
import Std

namespace PionQbeCountedArrayLength

/-! ## 1. Single counted fill -/

/-- `iterations` rounds of `a.push(c); i = i + 1` on (counter, length). -/
def fill (iterations : Nat) (index length : Nat) : Nat × Nat :=
  match iterations with
  | 0 => (index, length)
  | n + 1 => fill n (index + 1) (length + 1)

theorem counted_fill (n i len : Nat) :
    fill n i len = (i + n, len + n) := by
  induction n generalizing i len with
  | zero => simp [fill]
  | succ n ih => simp [fill, ih, Nat.add_comm, Nat.add_left_comm]

/-- From `let a = []` and `let mut i = 0`, the loop exits with `i = N` and
    `a.length() = N`. -/
theorem terminal_length (n : Nat) : fill n 0 0 = (n, n) := by
  simpa using counted_fill n 0 0

/-- Inside the loop `i < N <= 2^31 - 1`, so `i + 1` does not overflow `Int`. -/
theorem int_counter_safe (i n : Nat) (h : i < n) (bound : n ≤ 2147483647) :
    i + 1 ≤ 2147483647 := by omega

/-! ## 2. Several fresh arrays filled by one loop -/

/-- One iteration's pushes: the `k`-th push appends its literal to the `k`-th
    (distinct) array. -/
def pushAll {α : Type} : List (List α) → List α → List (List α)
  | a :: as, v :: vs => (a ++ [v]) :: pushAll as vs
  | as, _ => as

/-- `iterations` rounds of the loop body over all arrays. -/
def fillMany {α : Type} (iterations : Nat) (vs : List α) (arrs : List (List α)) :
    List (List α) :=
  match iterations with
  | 0 => arrs
  | n + 1 => fillMany n vs (pushAll arrs vs)

theorem pushAll_eq {α : Type} (arrs : List (List α)) (vs : List α)
    (h : vs.length = arrs.length) :
    pushAll arrs vs = List.zipWith (fun a v => a ++ [v]) arrs vs := by
  induction arrs generalizing vs with
  | nil => cases vs <;> simp [pushAll]
  | cons a as ih =>
    cases vs with
    | nil => simp at h
    | cons v vs =>
      simp only [List.length_cons, Nat.add_right_cancel_iff] at h
      simp [pushAll, ih vs h]

theorem fillMany_eq {α : Type} (n : Nat) (vs : List α) (arrs : List (List α))
    (h : vs.length = arrs.length) :
    fillMany n vs arrs =
      List.zipWith (fun a v => a ++ List.replicate n v) arrs vs := by
  induction n generalizing arrs with
  | zero =>
    rw [fillMany]
    apply List.ext_getElem
    · simp only [List.length_zipWith]; omega
    · intro j h1 h2
      simp only [List.getElem_zipWith, List.replicate_zero, List.append_nil]
  | succ n ih =>
    have hl : vs.length = (pushAll arrs vs).length := by
      rw [pushAll_eq arrs vs h, List.length_zipWith]; omega
    rw [fillMany, ih (pushAll arrs vs) hl, pushAll_eq arrs vs h]
    apply List.ext_getElem
    · simp only [List.length_zipWith]; omega
    · intro j h1 h2
      simp only [List.getElem_zipWith, List.append_assoc, List.replicate_succ,
        List.singleton_append]

/-- Each of the `k` fresh arrays ends as `N` copies of its own literal, so its
    length is `N` for every array: the pushes on distinct arrays do not
    interfere. -/
theorem multi_array_fill_independent {α : Type} (n : Nat) (vs : List α) :
    fillMany n vs (List.replicate vs.length []) = vs.map (List.replicate n) ∧
    ∀ a ∈ fillMany n vs (List.replicate vs.length []), a.length = n := by
  have h : fillMany n vs (List.replicate vs.length []) = vs.map (List.replicate n) := by
    rw [fillMany_eq n vs _ (by simp)]
    apply List.ext_getElem
    · simp
    · intro j h1 h2
      simp
  refine ⟨h, ?_⟩
  intro a ha
  rw [h, List.mem_map] at ha
  obtain ⟨v, _, rfl⟩ := ha
  simp

/-! ## 3. Later reads and writes against the immediate -/

/-- One checked access: success, or the exact `(idx, len)` diagnostic. The
    signed Pion index has already been sign-extended to 64 bits. -/
def access {α : Type} (idx len : BitVec 64) (success : α) :
    Except (BitVec 64 × BitVec 64) α :=
  if idx < len then .ok success else .error (idx, len)

theorem checks_preserved {α : Type} (n i : Nat) (idx : BitVec 64) (s : α) :
    access idx (BitVec.ofNat 64 (fill n i i).2) s =
    access idx (BitVec.ofNat 64 (i + n)) s := by
  rw [counted_fill]

inductive ElementStep {α : Type} : List α → List α → Prop
  | read (xs : List α) : ElementStep xs xs
  | write (xs : List α) (i : Nat) (x : α) : ElementStep xs (xs.set i x)

theorem stable_length {α : Type} {xs ys : List α} (h : ElementStep xs ys) :
    ys.length = xs.length := by
  cases h <;> simp

inductive Command (α : Type)
  | read (ix : BitVec 64)
  | write (ix : BitVec 64) (v : α)

def Command.idx {α : Type} (cmd : Command α) : BitVec 64 :=
  match cmd with
  | .read i | .write i _ => i

def Command.effect {α : Type} (cmd : Command α) (xs : List α) : List α :=
  match cmd with
  | .read _ => xs
  | .write i v => xs.set i.toNat v

theorem effect_size {α : Type} (cmd : Command α) (xs : List α) :
    (cmd.effect xs).length = xs.length := by
  cases cmd <;> simp [Command.effect]

/-- Run reads and writes in order, collecting the read values; stop with the
    exact diagnostic at the first index failing the unsigned check against
    `bound` (the header length, or the immediate). -/
def eval {α : Type} (bound : List α → BitVec 64) (xs : List α) (ops : List (Command α)) :
    Except (BitVec 64 × BitVec 64) (List (Option α) × List α) :=
  match ops with
  | [] => .ok ([], xs)
  | cmd :: more =>
    if cmd.idx < bound xs then do
      let (reads, finalState) ← eval bound (cmd.effect xs) more
      match cmd with
      | .read i => return (xs[i.toNat]? :: reads, finalState)
      | .write _ _ => return (reads, finalState)
    else .error (cmd.idx, bound xs)

/-- Checking against the header length and against the recorded `N` give the
    same reads, final array and first diagnostic. -/
theorem trace_equivalence {α : Type} (ops : List (Command α)) (xs : List α) (n : Nat)
    (h : xs.length = n) :
    eval (fun ys => BitVec.ofNat 64 ys.length) xs ops =
    eval (fun _ => BitVec.ofNat 64 n) xs ops := by
  induction ops generalizing xs with
  | nil => rfl
  | cons cmd rest ih =>
    simp only [eval, h]
    split
    · rw [ih (cmd.effect xs) ((effect_size cmd xs).trans h)]
    · rfl

/-! ## 4. Out-of-bounds diagnostics with the immediate -/

/-- A negative signed 32-bit index sign-extends to at least `2^63`, which is
    unsigned-above every `N <= 2^31 - 1`: the check fails with `(idx, N)`. -/
theorem oob_negative_index_traps {α : Type} (i : Int) (hlo : -2147483648 ≤ i)
    (hneg : i < 0) (n : Nat) (hn : n ≤ 2147483647) (s : α) :
    2 ^ 63 ≤ (BitVec.ofInt 64 i).toNat ∧
    access (BitVec.ofInt 64 i) (BitVec.ofNat 64 n) s =
      .error (BitVec.ofInt 64 i, BitVec.ofNat 64 n) := by
  have hv : (BitVec.ofInt 64 i).toNat = (i + 18446744073709551616).toNat := by
    rw [BitVec.toNat_ofInt]
    congr 1
    omega
  have hn' : (BitVec.ofNat 64 n).toNat = n := by
    rw [BitVec.toNat_ofNat]; omega
  have hge : 2 ^ 63 ≤ (BitVec.ofInt 64 i).toNat := by rw [hv]; omega
  refine ⟨hge, ?_⟩
  have hnlt : ¬ (BitVec.ofInt 64 i < BitVec.ofNat 64 n) := by
    rw [BitVec.lt_def, hn']; omega
  simp [access, hnlt]

/-- After `while i < 0 { ... }` the immediate is `0`, and every index fails
    with `(idx, 0)`; so does the first command of any non-empty sequence. -/
theorem empty_fill_always_traps {α : Type} (idx : BitVec 64) (s : α) :
    access idx (BitVec.ofNat 64 (fill 0 0 0).2) s = .error (idx, 0) ∧
    ∀ (xs : List α) (cmd : Command α) (rest : List (Command α)),
      eval (fun _ => BitVec.ofNat 64 (fill 0 0 0).2) xs (cmd :: rest) =
        .error (cmd.idx, 0) := by
  have hz : ∀ x : BitVec 64, ¬ (x < BitVec.ofNat 64 0) := by
    intro x; rw [BitVec.lt_def]; simp
  refine ⟨?_, ?_⟩
  · simp [fill, access, hz]
  · intro xs cmd rest
    simp [fill, eval, hz]

end PionQbeCountedArrayLength
