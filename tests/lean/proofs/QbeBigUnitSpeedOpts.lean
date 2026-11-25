/-
Invariants behind four byte-identical compile-speed changes for the largest
QBE unit and the package signature sort:

Backend (`vendor/qbe/util.c`, `vendor/qbe/spill.c`, `vendor/qbe/parse.c`).
  1. `zeroGroup`, `skipFour`: `bsiter` skips a group of four words only when
     every word is zero, and the skip adds four to the scanned position.
  2. `leastOnSet`, `zeroLow`, `nibbleTable`: the count-trailing-zeros builtin
     and the portable half-word / nibble fallback give the same least set bit.
  3. `countParts`: a population count splits over concatenated bit lists.
  4. `fitUnion`: when both register classes fit, `limit2` recombines the
     partitioned live set into itself, so `limitregs` may skip it.
  5. `deferredWrites`: setting the recorded preferred temporaries only when
     spilling builds the same preference set as setting them eagerly.
  6. `capacityGuard`: below index 127 the 128-byte token buffer holds the
     written byte and its terminator, so `lex` may skip `vgrow`.
  7. `decimalStep`, `decimalDigit`, `decimalTerminates`, `copyTerminated`:
     `tmpname` writes one decimal digit per step, stops, and `pstrdup` copies
     the terminator.

Schedule (`drv_build_targets` in `compiler/src/cli/main.pion`).
  8. `minLoad`, `firstTie`, `largerFirst`, `stableKey`, `moveFirst`: the batch
     holding the largest source is emitted first; every other batch keeps its
     canonical order.
  9. `reordering`: emission from the same read-only input and a fresh scratch
     (a per-unit checker copy) permutes with the unit order.
 10. `failedPrefix`, `writeBeforeBackend`: the first failed SSA write keeps the
     canonical prefix and is reported before any backend error.

Signature (`sort_sig_entries` in `compiler/src/core/sig.pion`).
 11. `splitStable`, `chooseLeftOnTie`, `insertionAsMerge`, `orderedMerge`:
     the merge takes the left entry on ties, so it is stable and agrees with
     the insertion sort it replaces.
 12. `unreadRight`, `bufferedEnough`: while a buffered left entry remains the
     output cursor stays left of the unread right suffix, and the buffer of
     `n - n / 2` entries holds every left half.

These are local models of the changed code, checked by the Lean kernel; the
full compiler equivalence is covered by the byte-for-byte gates.
-/

namespace PionQbeBigUnitSpeedOpts

namespace Backend

-- A zero group is skipped only when each word contains no eligible bit.
theorem zeroGroup (a b c d : BitVec 64) :
    (a ||| b ||| c ||| d = 0) ↔ a = 0 ∧ b = 0 ∧ c = 0 ∧ d = 0 := by
  simp [and_assoc]

def scan : List Nat → Option Nat
  | [] => none
  | w :: ws => if w = 0 then (scan ws).map (· + 1) else some 0

theorem skipFour (ws : List Nat) :
    scan (0 :: 0 :: 0 :: 0 :: ws) = (scan ws).map (· + 4) := by
  cases h : scan ws <;> simp [scan, h, Nat.add_assoc]

-- Least-set-position and count in a word, expressed via its low-to-high bits.
def least : List Bool → Nat
  | [] => 0
  | b :: bs => if b then 0 else 1 + least bs

theorem leastOnSet (pre suf : List Bool) (h : ∀ b ∈ pre, b = false) :
    least (pre ++ true :: suf) = pre.length := by
  induction pre with
  | nil => simp [least]
  | cons b bs ih =>
    have hb := h b (by simp)
    have ht := ih (fun x hx => h x (by simp [hx]))
    simp [hb, least, ht, Nat.add_comm]

theorem countParts (xs ys : List Bool) :
    (xs ++ ys).count true = xs.count true + ys.count true := by simp
theorem capacityGuard {i cap : Nat} (base : 128 ≤ cap) (fast : i < 127) :
    i + 2 ≤ cap := by omega

-- Digits are filled right-to-left; a quotient step encodes exactly one decimal digit.
theorem decimalStep (n : Nat) : 10 * (n / 10) + n % 10 = n := Nat.div_add_mod n 10
theorem decimalDigit (n : Nat) : n % 10 < 10 := Nat.mod_lt _ (by decide)
theorem decimalTerminates (n : Nat) (h : n > 0) : n / 10 < n := Nat.div_lt_self h (by decide)
theorem copyTerminated (xs : List UInt8) :
    (xs ++ [0]).take (xs.length + 1) = xs ++ [0] := by
  induction xs with
  | nil => rfl
  | cons b bs ih => simpa [List.take, Nat.add_assoc] using ih

-- The masks form a partition. If both limits return their inputs, their
-- recombination is the original live set, including the empty case.
theorem fitUnion (live fp : Bool) :
    (live && !fp || live && fp) = live := by cases live <;> cases fp <;> rfl

def written (ids : List Nat) (i : Nat) := ids.contains i
theorem deferredWrites (ids : List Nat) (i : Nat) :
    ids.foldl (fun already id => already || (decide (id = i))) false = written ids i := by
  unfold written
  suffices h : ∀ start : Bool, ids.foldl (fun seen id => seen || (decide (id = i))) start =
      (start || ids.contains i) by simpa using h false
  induction ids with
  | nil => simp
  | cons x xs ih =>
    intro start
    by_cases he : x = i
    · subst x; simp [List.foldl, ih]
    · have hne : i ≠ x := Ne.symm he
      simp [List.foldl, ih, he, hne]

-- The portable half-word tests successively skip zero low halves.
theorem zeroLow (lo hi : List Bool) (h : ∀ b ∈ lo, b = false) :
    least (lo ++ hi) = lo.length + least hi := by
  induction lo with
  | nil => simp
  | cons b bs ih =>
    have hb := h b (by simp)
    have tail := ih (fun x hx => h x (by simp [hx]))
    simp [hb, least, tail, Nat.add_assoc, Nat.add_left_comm]

-- The final nonzero nibble lookup is checked against the low bit position.
def nibble (v : Nat) := [4,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0][v]?.getD 4
theorem nibbleTable : ∀ i : Fin 16, 0 < i.val →
    nibble i.val = least ((List.range 4).map (fun j => i.val.testBit j)) := by decide

end Backend

namespace Schedule

-- Bin order is canonical. A tie keeps the existing candidate.
def pick (h : Nat × Nat) : List (Nat × Nat) → Nat × Nat
  | [] => h
  | x :: xs => pick (if x.1 < h.1 then x else h) xs

theorem minLoad (h : Nat × Nat) (xs : List (Nat × Nat)) :
    (pick h xs).1 ≤ h.1 ∧ ∀ x ∈ xs, (pick h xs).1 ≤ x.1 := by
  induction xs generalizing h with
  | nil => simp [pick]
  | cons x xs ih =>
    simp only [pick]
    split <;> rename_i hx
    · obtain ⟨ha, hb⟩ := ih x
      exact ⟨by omega, fun y hy => (List.mem_cons.mp hy).elim (fun e => e ▸ ha) (hb y)⟩
    · obtain ⟨ha, hb⟩ := ih h
      exact ⟨ha, fun y hy => (List.mem_cons.mp hy).elim (fun e => e ▸ (by omega)) (hb y)⟩

theorem firstTie (h : Nat × Nat) (xs : List (Nat × Nat))
    (lo : ∀ x ∈ xs, h.1 ≤ x.1) : pick h xs = h := by
  induction xs with
  | nil => rfl
  | cons x xs ih =>
    have hx := lo x (by simp)
    simpa [pick, Nat.not_lt.mpr hx] using ih (fun y hy => lo y (by simp [hy]))

-- Packed integer sort keys: descending size then ascending canonical position.
def key (size pos : Nat) := (2147483647 - size) * 4294967296 + pos
theorem largerFirst {a b i j : Nat} (hab : b < a) (bound : a ≤ 2147483647)
    (idx : i < 4294967296) : key a i < key b j := by unfold key; omega
theorem stableKey (s i j : Nat) (h : i < j) : key s i < key s j := by unfold key; omega

-- The head slot is selected first; every remaining slot appears once in its old order.
theorem moveFirst {α} (left right : List α) (x : α) :
    (x :: (left ++ right)).Perm (left ++ x :: right) := by
  induction left with
  | nil => exact List.Perm.refl _
  | cons a left ih => exact (List.Perm.swap a x _).trans (List.Perm.cons a ih)

-- Scratch writes can depend on the unit. The initial scratch is fresh on each invocation.
def independent (emit : ρ → σ → ι → α × σ) (r : ρ) (empty : σ) (i : ι) :=
  (emit r empty i).1
theorem reordering {xs ys : List ι} (h : xs.Perm ys) (emit : ρ → σ → ι → α × σ)
    (r : ρ) (empty : σ) :
    (xs.map (fun i => (i, independent emit r empty i))).Perm
      (ys.map (fun i => (i, independent emit r empty i))) := h.map _

def commit : List (Except ε α) → List α × Option ε
  | [] => ([], none)
  | .error e :: _ => ([], some e)
  | .ok a :: xs => let r := commit xs; (a :: r.1, r.2)

theorem failedPrefix (prior : List α) (e : ε) (rest : List (Except ε α)) :
    commit (prior.map Except.ok ++ Except.error e :: rest) = (prior, some e) := by
  induction prior with
  | nil => rfl
  | cons x xs ih => simp [commit, ih]

theorem writeBeforeBackend (e : ε) (backend : Option ε) :
    (some e).orElse (fun _ => backend) = some e := rfl

end Schedule

namespace Signature

-- A rank/name key's occurrence list keeps the original order of tied entries.
def project (k : Nat) (xs : List (Nat × α)) :=
  (xs.filter (fun x => x.1 == k)).map Prod.snd

theorem splitStable (k : Nat) (xs ys : List (Nat × α)) :
    project k (xs ++ ys) = project k xs ++ project k ys := by simp [project]

-- The output cursor is left of the first unread right entry while left remains.
theorem unreadRight {lo mid i j out : Nat} (bound : lo ≤ mid) (right : mid ≤ j)
    (pending : i < mid - lo) (cursor : out = lo + i + (j - mid)) : out < j := by omega

theorem chooseLeftOnTie {a b : Nat} (h : a = b) : ¬ b < a := by omega
theorem bufferedEnough {n w : Nat} (inside : w ≤ n) : w / 2 ≤ n - n / 2 := by omega

-- Insertion of a later item scans past equal keys. This is exactly the
-- singleton-right case of the stable merge used for every run.
def appendOne (before : α → α → Bool) (x : α) : List α → List α
  | [] => [x]
  | a :: as => if before a x then a :: appendOne before x as else x :: a :: as

theorem insertionAsMerge (before : α → α → Bool) (x : α) (xs : List α) :
    appendOne before x xs = List.merge xs [x] before := by
  induction xs with
  | nil => simp [appendOne]
  | cons a xs ih =>
    simp only [appendOne, List.merge]
    split <;> simp_all

theorem orderedMerge (before : α → α → Bool)
    (tr : ∀ a b c, before a b → before b c → before a c)
    (total : ∀ a b, before a b || before b a)
    (left right : List α)
    (hl : left.Pairwise (fun a b => before a b = true))
    (hr : right.Pairwise (fun a b => before a b = true)) :
    (List.merge left right before).Pairwise (fun a b => before a b = true) :=
  List.pairwise_merge tr total left right hl hr

end Signature

end PionQbeBigUnitSpeedOpts
