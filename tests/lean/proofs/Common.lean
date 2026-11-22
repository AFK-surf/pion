/-
Helpers shared by the proofs over extracted code: bind / `spec` rules and
non-overflowing wrapping `Int` arithmetic.
-/
import PionLean
open Aeneas Aeneas.Std Result Pion WP

namespace PionProofs

theorem b_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← (ok x : Result α); f y) = f x := by simp

theorem spec_bind' {α β : Type} {m : Result α} {k : α → Result β} {P : Post α} {Q : Post β}
    (h : spec m P) (hk : ∀ x, P x → spec (k x) Q) : spec (m >>= k) Q := by
  rw [bind_tc_eq]
  exact spec_bind h hk

theorem i32_add_val (a b : Std.I32) (h0 : -2147483648 ≤ a.val + b.val)
    (h1 : a.val + b.val ≤ 2147483647) : (Pion.I32.add a b).val = a.val + b.val := by
  have e : (Pion.I32.add a b).bv = a.bv + b.bv := by simp
  have e2 : (Pion.I32.add a b).val = (a.bv + b.bv).toInt := by rw [← e]; rfl
  rw [e2, BitVec.toInt_add]
  have ea : a.bv.toInt = a.val := rfl
  have eb : b.bv.toInt = b.val := rfl
  rw [ea, eb]
  exact Int.bmod_eq_of_le_mul_two (by norm_num; omega) (by norm_num; omega)

theorem i32_sub_val (a b : Std.I32) (h0 : -2147483648 ≤ a.val - b.val)
    (h1 : a.val - b.val ≤ 2147483647) : (Pion.I32.sub a b).val = a.val - b.val := by
  have e : (Pion.I32.sub a b).bv = a.bv - b.bv := by simp
  have e2 : (Pion.I32.sub a b).val = (a.bv - b.bv).toInt := by rw [← e]; rfl
  rw [e2, BitVec.toInt_sub]
  have ea : a.bv.toInt = a.val := rfl
  have eb : b.bv.toInt = b.val := rfl
  rw [ea, eb]
  exact Int.bmod_eq_of_le_mul_two (by norm_num; omega) (by norm_num; omega)

theorem i32_ext {a b : Std.I32} (h : a.val = b.val) : a = b := by
  cases a; cases b
  congr
  exact BitVec.eq_of_toInt_eq h

theorem arr_len_eq {α : Type} (a : Pion.Array α) (h : a.val.length ≤ 2147483647) :
    ∃ n : Std.I32, n.val = a.val.length ∧ a.length = ok n := by
  refine ⟨Std.I32.ofIntCore a.val.length
    ⟨by simp [IScalarTy.numBits], by simp [IScalarTy.numBits]; omega⟩, ?_, ?_⟩
  · simp
  · simp [Pion.Array.length, lengthOf, h]

theorem arr_get_eq {α : Type} (a : Pion.Array α) (i : Std.I32) (h0 : 0 ≤ i.val)
    (h1 : i.val < a.val.length) : a.get i = ok (a.val[i.val.toNat]'(by omega)) := by
  simp [Pion.Array.get, listGet, h0, h1]

theorem arr_set_eq {α : Type} (a : Pion.Array α) (i : Std.I32) (x : α) (h0 : 0 ≤ i.val)
    (h1 : i.val < a.val.length) : a.set i x = ok ⟨a.val.set i.val.toNat x⟩ := by
  simp [Pion.Array.set, listSet, h0, h1]

/-- Total element read used by specifications. -/
def nth (l : List Std.I32) (k : Nat) : Std.I32 := (l[k]?).getD 0#i32

theorem nth_of_get {l : List Std.I32} {k : Nat} {x : Std.I32} (h : l[k]? = some x) :
    nth l k = x := by simp [nth, h]

theorem get_of_nth {l : List Std.I32} {k : Nat} (h : k < l.length) : l[k]? = some (nth l k) := by
  simp [nth, h]

theorem nth_set_eq {l : List Std.I32} {k : Nat} (x : Std.I32) (h : k < l.length) :
    nth (l.set k x) k = x := by simp [nth, h]

theorem nth_set_ne {l : List Std.I32} {k m : Nat} (x : Std.I32) (h : m ≠ k) :
    nth (l.set m x) k = nth l k := by
  simp [nth, List.getElem?_set, h]

theorem listGet_eq (l : List Std.I32) (i : Std.I32) (h0 : 0 ≤ i.val) (h1 : i.val < l.length) :
    listGet l i = ok (nth l i.val.toNat) := by
  have hk : i.val.toNat < l.length := by omega
  simp [listGet, h0, h1, nth, hk]

theorem array_get_eq (a : Pion.Array Std.I32) (i : Std.I32) (h0 : 0 ≤ i.val)
    (h1 : i.val < a.val.length) : a.get i = ok (nth a.val i.val.toNat) :=
  listGet_eq _ _ h0 h1

theorem array_swap_eq (a : Pion.Array Std.I32) (i j : Std.I32)
    (hi0 : 0 ≤ i.val) (hi1 : i.val < a.val.length) (hj0 : 0 ≤ j.val) (hj1 : j.val < a.val.length) :
    a.swap i j = ok ⟨(a.val.set i.val.toNat (nth a.val j.val.toNat)).set j.val.toNat
      (nth a.val i.val.toNat)⟩ := by
  simp only [Pion.Array.swap, listSwap, listGet_eq _ _ hi0 hi1, listGet_eq _ _ hj0 hj1, b_ok]

theorem swap_perm (l : List Std.I32) {i j : Nat} (hi : i < l.length) (hj : j < l.length) :
    ((l.set i (nth l j)).set j (nth l i)).Perm l := by
  have e1 : nth l j = l[j] := by simp [nth, hj]
  have e2 : nth l i = l[i] := by simp [nth, hi]
  rw [e1, e2]
  exact List.set_set_perm hi hj

/-- Non-decreasing by value. -/
def Sorted (l : List Std.I32) : Prop := l.Pairwise (fun a b => a.val ≤ b.val)

theorem sorted_nth {l : List Std.I32} (h : Sorted l) {p q : Nat} (hpq : p ≤ q) (hq : q < l.length) :
    (nth l p).val ≤ (nth l q).val := by
  rcases Nat.lt_or_eq_of_le hpq with hlt | rfl
  · have := (List.pairwise_iff_getElem.1 h) p q (by omega) hq hlt
    simpa [nth, hq, show p < l.length by omega] using this
  · exact le_refl _

theorem sorted_of_nth {l : List Std.I32}
    (h : ∀ p q, p < q → q < l.length → (nth l p).val ≤ (nth l q).val) : Sorted l := by
  refine List.pairwise_iff_getElem.2 ?_
  intro p q hp hq hpq
  have := h p q hpq hq
  simpa [nth, hp, hq] using this

end PionProofs
