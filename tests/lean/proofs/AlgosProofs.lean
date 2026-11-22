/-
Functional correctness of the extracted `algos.binary_search` and
`algos.insertion_sort`: real loop invariants and termination measures.
-/
import Algos.Funs
import PionProofs.Common
open Aeneas Aeneas.Std Result Pion WP

set_option maxRecDepth 10000

namespace PionProofs.AlgosP

open PionProofs

/-! ## Binary search -/

def BSInv (xs : Pion.Array Std.I32) (target : Std.I32) (p : Std.I32 × Std.I32) : Prop :=
  0 ≤ p.1.val ∧ p.1.val ≤ p.2.val ∧ p.2.val ≤ xs.val.length ∧
    (Sorted xs.val → ∀ k : Nat, xs.val[k]? = some target → p.1.val ≤ k ∧ (k : Int) < p.2.val)

def BSPost (xs : Pion.Array Std.I32) (target : Std.I32) :
    Sum (Option Std.I32) (Std.I32 × Std.I32) → Prop
  | .inl (some m) => 0 ≤ m.val ∧ m.val < xs.val.length ∧ xs.val[m.val.toNat]? = some target
  | .inl none => False
  | .inr _ => Sorted xs.val → ∀ k : Nat, xs.val[k]? ≠ some target

theorem bs_body (xs : Pion.Array Std.I32) (target : Std.I32)
    (hlen : xs.val.length ≤ 2147483647) (p : Std.I32 × Std.I32) (h : BSInv xs target p) :
    algos.binary_search_loop0.body xs target p.1 p.2 ⦃ r =>
      match r with
      | .done y => BSPost xs target y
      | .cont x' => BSInv xs target x' ∧ (x'.2.val - x'.1.val).toNat < (p.2.val - p.1.val).toNat ⦄ := by
  obtain ⟨lo, hi⟩ := p
  obtain ⟨h0, h1, h2, hC⟩ := h
  dsimp only at h0 h1 h2 hC ⊢
  unfold algos.binary_search_loop0.body
  by_cases hlt : lo < hi
  · rw [ite_eq_left hlt]
    have hlt' : lo.val < hi.val := hlt
    have hs := i32_sub_val hi lo (by omega) (by omega)
    refine spec_bind' (Pion.I32.div_spec (x := Pion.I32.sub hi lo) (y := 2#i32) (by simp) (by simp)) ?_
    intro t ht
    have h2v : (2#i32 : Std.I32).val = 2 := by simp
    rw [h2v, hs, Int.tdiv_eq_ediv_of_nonneg (by omega)] at ht
    have hm := i32_add_val lo t (by omega) (by omega)
    dsimp only
    refine spec_bind' (Pion.Array.get_spec xs (Pion.I32.add lo t) (by omega) (by omega)) ?_
    intro v hv
    by_cases hve : v = target
    · rw [ite_eq_left hve, spec_ok]
      subst hve
      exact ⟨by omega, by omega, hv⟩
    · rw [ite_eq_right hve]
      by_cases hvl : v < target
      · rw [ite_eq_left hvl]
        rw [spec_ok]
        have hvl' : v.val < target.val := hvl
        have h1v : (1#i32 : Std.I32).val = 1 := by simp
        have hm1 := i32_add_val (Pion.I32.add lo t) 1#i32 (by rw [h1v]; omega) (by rw [h1v]; omega)
        rw [h1v] at hm1
        refine ⟨⟨by dsimp only; omega, by dsimp only; omega, by dsimp only; omega, ?_⟩, by dsimp only; omega⟩
        intro hS k hk
        have ⟨hk1, hk2⟩ := hC hS k hk
        refine ⟨?_, hk2⟩
        dsimp only
        by_contra hcon
        have hkm : k ≤ (Pion.I32.add lo t).val.toNat := by omega
        have hmlen : (Pion.I32.add lo t).val.toNat < xs.val.length := by omega
        have := sorted_nth hS hkm hmlen
        rw [nth_of_get hk, nth_of_get hv] at this
        omega
      · rw [ite_eq_right hvl]
        rw [spec_ok]
        have hvl' : ¬ v.val < target.val := hvl
        have hne : v.val ≠ target.val := fun e => hve (i32_ext e)
        refine ⟨⟨by dsimp only; omega, by dsimp only; omega, by dsimp only; omega, ?_⟩, by dsimp only; omega⟩
        intro hS k hk
        have ⟨hk1, hk2⟩ := hC hS k hk
        refine ⟨hk1, ?_⟩
        dsimp only
        by_contra hcon
        have hkm : (Pion.I32.add lo t).val.toNat ≤ k := by omega
        have hklen : k < xs.val.length := by omega
        have := sorted_nth hS hkm hklen
        rw [nth_of_get hk, nth_of_get hv] at this
        have hke : k ≠ (Pion.I32.add lo t).val.toNat := by
          intro e
          rw [e, hv] at hk
          exact hve (Option.some.inj hk)
        omega
  · rw [ite_eq_right hlt, spec_ok]
    have hlt' : ¬ lo.val < hi.val := hlt
    intro hS k hk
    have := hC hS k hk
    omega

theorem bs_loop (xs : Pion.Array Std.I32) (target lo hi : Std.I32)
    (hlen : xs.val.length ≤ 2147483647) (h : BSInv xs target (lo, hi)) :
    algos.binary_search_loop0 xs target lo hi ⦃ r => BSPost xs target r ⦄ := by
  unfold algos.binary_search_loop0
  refine loop.spec_decr_nat (fun p => (p.2.val - p.1.val).toNat) (BSInv xs target)
    _ _ _ ?_ h
  rintro ⟨l, h'⟩ hI
  have hb := bs_body xs target hlen (l, h') hI
  dsimp only at hb ⊢
  refine spec_mono hb ?_
  rintro (x | y) hr <;> exact hr

theorem binary_search_spec (xs : Pion.Array Std.I32) (target : Std.I32)
    (hlen : xs.val.length ≤ 2147483647) :
    algos.binary_search xs target ⦃ r =>
      match r with
      | some m => 0 ≤ m.val ∧ m.val < xs.val.length ∧ xs.val[m.val.toNat]? = some target
      | none => Sorted xs.val → ∀ k : Nat, xs.val[k]? ≠ some target ⦄ := by
  unfold algos.binary_search
  dsimp only
  refine spec_bind' (Pion.Array.length_spec xs hlen) ?_
  intro n hn
  refine spec_bind' (bs_loop xs target 0#i32 n hlen ?_) ?_
  · refine ⟨by simp, by simp; omega, by dsimp only; omega, ?_⟩
    intro _ k hk
    have : k < xs.val.length := by
      by_contra hc
      simp [List.getElem?_eq_none (not_lt.1 hc)] at hk
    simp
    omega
  · rintro (r | ⟨a, b⟩) hP
    · cases r with
      | none => exact hP.elim
      | some m => simpa [BSPost] using hP
    · simpa [BSPost] using hP

/-- Any index returned is in range and holds `target`. -/
theorem binary_search_sound (xs : Pion.Array Std.I32) (target : Std.I32)
    (hlen : xs.val.length ≤ 2147483647) :
    algos.binary_search xs target ⦃ r => ∀ idx, r = some idx →
      0 ≤ idx.val ∧ idx.val < xs.val.length ∧ xs.val[idx.val.toNat]? = some target ⦄ := by
  refine spec_mono (binary_search_spec xs target hlen) ?_
  intro r hr idx e
  subst e
  exact hr

/-- On a sorted array, a present `target` is always found. -/
theorem binary_search_complete (xs : Pion.Array Std.I32) (target : Std.I32)
    (hlen : xs.val.length ≤ 2147483647) (hS : Sorted xs.val) (k : Nat)
    (hk : xs.val[k]? = some target) :
    algos.binary_search xs target ⦃ r => ∃ idx, r = some idx ∧
      xs.val[idx.val.toNat]? = some target ⦄ := by
  refine spec_mono (binary_search_spec xs target hlen) ?_
  intro r hr
  cases r with
  | none => exact (hr hS k hk).elim
  | some m => exact ⟨m, rfl, hr.2.2⟩

/-! ## Insertion sort -/

/-- The prefix `[0, i]` is sorted. -/
def SortedTo (l : List Std.I32) (i : Nat) : Prop :=
  ∀ p q, p < q → q ≤ i → (nth l p).val ≤ (nth l q).val

/-- Inner loop: `[0, i]` is sorted except for the element being sunk at `j`,
which is no greater than anything to its right. -/
def InnerInv (l0 : List Std.I32) (i : Nat) (s : Std.I32 × Pion.Array Std.I32) : Prop :=
  0 ≤ s.1.val ∧ s.1.val ≤ i ∧ s.2.val.length = l0.length ∧ s.2.val.Perm l0 ∧
    (∀ p q, p < q → q ≤ i → p ≠ s.1.val.toNat → q ≠ s.1.val.toNat →
      (nth s.2.val p).val ≤ (nth s.2.val q).val) ∧
    (∀ q, s.1.val.toNat < q → q ≤ i → (nth s.2.val s.1.val.toNat).val ≤ (nth s.2.val q).val)

def InnerPost (l0 : List Std.I32) (i : Nat) (r : Std.I32 × Pion.Array Std.I32) : Prop :=
  r.2.val.length = l0.length ∧ r.2.val.Perm l0 ∧ SortedTo r.2.val i

theorem inner_done (l0 : List Std.I32) (i : Nat) (j : Std.I32) (a : Pion.Array Std.I32)
    (h : InnerInv l0 i (j, a))
    (hstop : 0 < j.val → (nth a.val (j.val.toNat - 1)).val ≤ (nth a.val j.val.toNat).val) :
    InnerPost l0 i (j, a) := by
  obtain ⟨h0, h1, hl, hp, hI, hR⟩ := h
  dsimp only at h0 h1 hl hp hI hR
  refine ⟨hl, hp, ?_⟩
  intro p q hpq hq
  dsimp only
  by_cases hpj : p = j.val.toNat
  · subst hpj; exact hR q hpq hq
  by_cases hqj : q = j.val.toNat
  · subst hqj
    have hpos : 0 < j.val := by omega
    have hs := hstop hpos
    by_cases hpe : p = j.val.toNat - 1
    · subst hpe; exact hs
    · exact le_trans (hI p (j.val.toNat - 1) (by omega) (by omega) hpj (by omega)) hs
  · exact hI p q hpq hq hpj hqj

theorem inner_step (l0 : List Std.I32) (i : Nat) (j : Std.I32) (a : Pion.Array Std.I32)
    (hi : i < l0.length) (h : InnerInv l0 i (j, a)) (hpos : 0 < j.val)
    (hgt : (nth a.val j.val.toNat).val < (nth a.val (j.val.toNat - 1)).val)
    (j1 : Std.I32) (hj1 : j1.val = j.val - 1) :
    InnerInv l0 i (j1, ⟨(a.val.set (j.val.toNat - 1) (nth a.val j.val.toNat)).set j.val.toNat
      (nth a.val (j.val.toNat - 1))⟩) := by
  obtain ⟨h0, h1, hl, hp, hI, hR⟩ := h
  dsimp only at h0 h1 hl hp hI hR
  have hjlen : j.val.toNat < a.val.length := by omega
  have hj1len : j.val.toNat - 1 < a.val.length := by omega
  have hne : j.val.toNat - 1 ≠ j.val.toNat := by omega
  have ej1 : j1.val.toNat = j.val.toNat - 1 := by omega
  generalize hl' : (a.val.set (j.val.toNat - 1) (nth a.val j.val.toNat)).set j.val.toNat
    (nth a.val (j.val.toNat - 1)) = l'
  have hlen' : l'.length = a.val.length := by rw [← hl']; simp
  have nj : nth l' j.val.toNat = nth a.val (j.val.toNat - 1) := by
    rw [← hl']; exact nth_set_eq _ (by simpa using hjlen)
  have nj1 : nth l' (j.val.toNat - 1) = nth a.val j.val.toNat := by
    rw [← hl', nth_set_ne _ (Ne.symm hne)]; exact nth_set_eq _ hj1len
  have nk : ∀ k, k ≠ j.val.toNat → k ≠ j.val.toNat - 1 → nth l' k = nth a.val k := by
    intro k h1k h2k
    rw [← hl', nth_set_ne _ (Ne.symm h1k), nth_set_ne _ (Ne.symm h2k)]
  have hperm : l'.Perm l0 := by
    rw [← hl']; exact (swap_perm a.val hj1len hjlen).trans hp
  refine ⟨by dsimp only; omega, by dsimp only; omega, by dsimp only; omega, hperm, ?_, ?_⟩
  · intro p q hpq hq hpj hqj
    dsimp only at hpj hqj ⊢
    rw [ej1] at hpj hqj
    by_cases hqe : q = j.val.toNat
    · subst hqe
      rw [nj, nk p (by omega) hpj]
      exact hI p _ (by omega) (by omega) (by omega) hne
    by_cases hpe : p = j.val.toNat
    · subst hpe
      rw [nj, nk q hqe hqj]
      exact hI _ q (by omega) hq hne hqe
    · rw [nk p hpe hpj, nk q hqe hqj]
      exact hI p q hpq hq hpe hqe
  · intro q hq hqi
    dsimp only at hq ⊢
    rw [ej1] at hq ⊢
    rw [nj1]
    by_cases hqe : q = j.val.toNat
    · subst hqe; rw [nj]; omega
    · rw [nk q hqe (by omega)]
      exact hR q (by omega) hqi

theorem inner_body (l0 : List Std.I32) (i : Nat) (hi : i < l0.length)
    (hlen : l0.length ≤ 2147483647) (s : Std.I32 × Pion.Array Std.I32) (h : InnerInv l0 i s) :
    algos.insertion_sort_loop1.body s.1 s.2 ⦃ r =>
      match r with
      | .done y => InnerPost l0 i y
      | .cont x' => InnerInv l0 i x' ∧ x'.1.val.toNat < s.1.val.toNat ⦄ := by
  obtain ⟨j, a⟩ := s
  have hI := h
  obtain ⟨h0, h1, hl, hp, -, -⟩ := h
  dsimp only at h0 h1 hl hp ⊢
  unfold algos.insertion_sort_loop1.body
  have h0v : (0#i32 : Std.I32).val = 0 := by simp
  have h1v : (1#i32 : Std.I32).val = 1 := by simp
  by_cases hpos : 0 < j.val
  · have hgt0 : j > 0#i32 := by
      show (0#i32 : Std.I32).val < j.val
      omega
    have hs := i32_sub_val j 1#i32 (by rw [h1v]; omega) (by rw [h1v]; omega)
    rw [h1v] at hs
    have hjt : (Pion.I32.sub j 1#i32).val.toNat = j.val.toNat - 1 := by omega
    rw [ite_eq_left hgt0, array_get_eq a (Pion.I32.sub j 1#i32) (by omega) (by omega),
      array_get_eq a j h0 (by omega)]
    simp only [b_ok, hjt]
    by_cases hgt : nth a.val (j.val.toNat - 1) > nth a.val j.val.toNat
    · rw [ite_eq_left (decide_eq_true hgt),
        array_swap_eq a (Pion.I32.sub j 1#i32) j (by omega) (by omega) h0 (by omega)]
      simp only [b_ok, hjt, spec_ok]
      have hgt' : (nth a.val j.val.toNat).val < (nth a.val (j.val.toNat - 1)).val := hgt
      refine ⟨inner_step l0 i j a hi hI hpos hgt' _ hs, ?_⟩
      omega
    · rw [ite_eq_right (fun e => hgt (of_decide_eq_true e)), spec_ok]
      have hgt' : ¬ (nth a.val j.val.toNat).val < (nth a.val (j.val.toNat - 1)).val := hgt
      exact inner_done l0 i j a hI (fun _ => by omega)
  · have hgt0 : ¬ j > 0#i32 := by
      intro e
      have e' : (0#i32 : Std.I32).val < j.val := e
      omega
    rw [ite_eq_right hgt0]
    simp only [b_ok, Bool.false_eq_true, ↓reduceIte, spec_ok]
    exact inner_done l0 i j a hI (fun e => absurd e hpos)

theorem inner_loop (l0 : List Std.I32) (i : Nat) (hi : i < l0.length)
    (hlen : l0.length ≤ 2147483647) (j : Std.I32) (a : Pion.Array Std.I32)
    (h : InnerInv l0 i (j, a)) :
    algos.insertion_sort_loop1 j a ⦃ r => InnerPost l0 i r ⦄ := by
  unfold algos.insertion_sort_loop1
  refine loop.spec_decr_nat (fun s => s.1.val.toNat) (InnerInv l0 i) _ _ _ ?_ h
  rintro ⟨j', a'⟩ hI
  have hb := inner_body l0 i hi hlen (j', a') hI
  dsimp only at hb ⊢
  refine spec_mono hb ?_
  rintro (x | y) hr <;> exact hr

def OuterInv (l0 : List Std.I32) (s : Std.I32 × Pion.Array Std.I32) : Prop :=
  1 ≤ s.1.val ∧ (s.1.val ≤ l0.length ∨ l0.length = 0) ∧ s.2.val.length = l0.length ∧
    s.2.val.Perm l0 ∧ SortedTo s.2.val (s.1.val.toNat - 1)

def OuterPost (l0 : List Std.I32) (r : Std.I32 × Pion.Array Std.I32) : Prop :=
  r.2.val.length = l0.length ∧ r.2.val.Perm l0 ∧ Sorted r.2.val

theorem outer_body (l0 : List Std.I32) (hlen : l0.length ≤ 2147483647) (t : Std.I32)
    (ht : t.val = l0.length) (s : Std.I32 × Pion.Array Std.I32) (h : OuterInv l0 s) :
    algos.insertion_sort_loop0.body t s.1 s.2 ⦃ r =>
      match r with
      | .done y => OuterPost l0 y
      | .cont x' => OuterInv l0 x' ∧ (t.val - x'.1.val).toNat < (t.val - s.1.val).toNat ⦄ := by
  obtain ⟨i, a⟩ := s
  obtain ⟨h1, h2, hl, hp, hS⟩ := h
  dsimp only at h1 h2 hl hp hS ⊢
  unfold algos.insertion_sort_loop0.body
  by_cases hlt : i < t
  · have hlt' : i.val < t.val := hlt
    rw [ite_eq_left hlt]
    have hin : i.val.toNat < l0.length := by omega
    have hInv : InnerInv l0 i.val.toNat (i, a) := by
      unfold InnerInv
      dsimp only
      refine ⟨by omega, by omega, hl, hp, ?_, ?_⟩
      · intro p q hpq hq _ hqj
        exact hS p q hpq (by omega)
      · intro q h3 h4
        omega
    refine spec_bind' (inner_loop l0 i.val.toNat hin hlen i a hInv) ?_
    rintro ⟨j1, a1⟩ ⟨hl1, hp1, hS1⟩
    · dsimp only at hl1 hp1 hS1
      have h1v : (1#i32 : Std.I32).val = 1 := by simp
      have hadd := i32_add_val i 1#i32 (by rw [h1v]; omega) (by rw [h1v]; omega)
      rw [h1v] at hadd
      refine (spec_ok (ControlFlow.cont (Pion.I32.add i 1#i32, a1))).2 ?_
      refine ⟨⟨by dsimp only; omega, by dsimp only; omega, hl1, hp1, ?_⟩, by dsimp only; omega⟩
      dsimp only
      rw [show (Pion.I32.add i 1#i32).val.toNat - 1 = i.val.toNat by omega]
      exact hS1
  · have hlt' : ¬ i.val < t.val := hlt
    rw [ite_eq_right hlt, spec_ok]
    refine ⟨hl, hp, sorted_of_nth ?_⟩
    intro p q hpq hq
    dsimp only at hq ⊢
    exact hS p q hpq (by omega)

theorem outer_loop (l0 : List Std.I32) (hlen : l0.length ≤ 2147483647) (t i : Std.I32)
    (a : Pion.Array Std.I32) (ht : t.val = l0.length) (h : OuterInv l0 (i, a)) :
    algos.insertion_sort_loop0 t i a ⦃ r => OuterPost l0 r ⦄ := by
  unfold algos.insertion_sort_loop0
  refine loop.spec_decr_nat (fun s => (t.val - s.1.val).toNat) (OuterInv l0) _ _ _ ?_ h
  rintro ⟨i', a'⟩ hI
  have hb := outer_body l0 hlen t ht (i', a') hI
  dsimp only at hb ⊢
  refine spec_mono hb ?_
  rintro (x | y) hr <;> exact hr

/-- `insertion_sort` terminates with a sorted permutation of its input. -/
theorem insertion_sort_spec (a : Pion.Array Std.I32) (hlen : a.val.length ≤ 2147483647) :
    algos.insertion_sort a ⦃ a' => a'.val.length = a.val.length ∧ Sorted a'.val ∧
      a'.val.Perm a.val ⦄ := by
  unfold algos.insertion_sort
  refine spec_bind' (Pion.Array.length_spec a hlen) ?_
  intro n hn
  dsimp only
  have h1v : (1#i32 : Std.I32).val = 1 := by simp
  refine spec_bind' (outer_loop a.val hlen n 1#i32 a hn
    ⟨by dsimp only; omega, ?_, rfl, List.Perm.refl _, ?_⟩) ?_
  · dsimp only
    rw [h1v]
    by_cases h0 : a.val.length = 0
    · exact Or.inr h0
    · exact Or.inl (by omega)
  · intro p q hpq hq
    dsimp only at hq
    rw [h1v] at hq
    omega
  · rintro ⟨i1, a1⟩ ⟨hl, hp, hS⟩
    dsimp only at hl hp hS
    refine (spec_ok a1).2 ?_
    exact ⟨hl, hS, hp⟩

end PionProofs.AlgosP
