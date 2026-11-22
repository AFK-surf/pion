/-
`@[step]` specifications of the fallible `PionLean` operations, so proofs over
extracted code can run `step` / `step*` (Aeneas' new name for `progress`).
-/
import PionLean.Basic

open Aeneas Aeneas.Std Result Error WP

namespace Pion

/-! ## Scalars -/

@[step] theorem I32.div_spec {x y : Std.I32} (hnz : y.val ≠ 0)
    (hNoOverflow : ¬ (x.val = -2147483648 ∧ y.val = -1)) :
    I32.div x y ⦃ z => z.val = Int.tdiv x.val y.val ⦄ := by
  unfold I32.div
  exact Std.I32.div_spec hnz (by simpa [Std.I32.min_eq] using hNoOverflow)

@[step] theorem I32.rem_spec {x y : Std.I32} (hnz : y.val ≠ 0)
    (hNoOverflow : ¬ (x.val = -2147483648 ∧ y.val = -1)) :
    I32.rem x y ⦃ z => z.val = Int.tmod x.val y.val ⦄ := by
  unfold I32.rem
  simp only [hNoOverflow, ite_false]
  exact Std.I32.rem_spec x hnz

@[step] theorem I64.div_spec {x y : Std.I64} (hnz : y.val ≠ 0)
    (hNoOverflow : ¬ (x.val = -9223372036854775808 ∧ y.val = -1)) :
    I64.div x y ⦃ z => z.val = Int.tdiv x.val y.val ⦄ := by
  unfold I64.div
  exact Std.I64.div_spec hnz (by simpa [Std.I64.min_eq] using hNoOverflow)

@[step] theorem I64.rem_spec {x y : Std.I64} (hnz : y.val ≠ 0)
    (hNoOverflow : ¬ (x.val = -9223372036854775808 ∧ y.val = -1)) :
    I64.rem x y ⦃ z => z.val = Int.tmod x.val y.val ⦄ := by
  unfold I64.rem
  simp only [hNoOverflow, ite_false]
  exact Std.I64.rem_spec x hnz

@[step] theorem U32.div_spec (x : Std.U32) {y : Std.U32} (hnz : y.val ≠ 0) :
    U32.div x y ⦃ z => z.val = x.val / y.val ⦄ := by
  unfold U32.div
  exact Std.U32.div_spec x hnz

@[step] theorem U32.rem_spec (x : Std.U32) {y : Std.U32} (hnz : y.val ≠ 0) :
    U32.rem x y ⦃ z => z.val = x.val % y.val ⦄ := by
  unfold U32.rem
  exact Std.U32.rem_spec x hnz

@[step] theorem I32.shl_spec (x : Std.I32) {y : Std.I32} (h0 : 0 ≤ y.val) (h1 : y.val < 32) :
    I32.shl x y ⦃ z => z.bv = x.bv <<< y.val.toNat ⦄ := by
  unfold I32.shl
  simp [h0, h1]

@[step] theorem I32.shr_spec (x : Std.I32) {y : Std.I32} (h0 : 0 ≤ y.val) (h1 : y.val < 32) :
    I32.shr x y ⦃ z => z.bv = x.bv.sshiftRight y.val.toNat ⦄ := by
  unfold I32.shr
  simp [h0, h1]

@[step] theorem I64.shl_i32_spec (x : Std.I64) {y : Std.I32} (h0 : 0 ≤ y.val) (h1 : y.val < 64) :
    I64.shl_i32 x y ⦃ z => z.bv = x.bv <<< y.val.toNat ⦄ := by
  unfold I64.shl_i32
  simp [h0, h1]

@[step] theorem I64.shr_i32_spec (x : Std.I64) {y : Std.I32} (h0 : 0 ≤ y.val) (h1 : y.val < 64) :
    I64.shr_i32 x y ⦃ z => z.bv = x.bv.sshiftRight y.val.toNat ⦄ := by
  unfold I64.shr_i32
  simp [h0, h1]

@[step] theorem U32.shl_i32_spec (x : Std.U32) {y : Std.I32} (h0 : 0 ≤ y.val) (h1 : y.val < 32) :
    U32.shl_i32 x y ⦃ z => z.bv = x.bv <<< y.val.toNat ⦄ := by
  unfold U32.shl_i32
  simp [h0, h1]

@[step] theorem U32.shr_i32_spec (x : Std.U32) {y : Std.I32} (h0 : 0 ≤ y.val) (h1 : y.val < 32) :
    U32.shr_i32 x y ⦃ z => z.bv = x.bv >>> y.val.toNat ⦄ := by
  unfold U32.shr_i32
  simp [h0, h1]

@[step] theorem U64.shl_i32_spec (x : Std.U64) {y : Std.I32} (h0 : 0 ≤ y.val) (h1 : y.val < 64) :
    U64.shl_i32 x y ⦃ z => z.bv = x.bv <<< y.val.toNat ⦄ := by
  unfold U64.shl_i32
  simp [h0, h1]

@[step] theorem U64.shr_i32_spec (x : Std.U64) {y : Std.I32} (h0 : 0 ≤ y.val) (h1 : y.val < 64) :
    U64.shr_i32 x y ⦃ z => z.bv = x.bv >>> y.val.toNat ⦄ := by
  unfold U64.shr_i32
  simp [h0, h1]

@[step] theorem I64.shl_spec (x : Std.I64) {y : Std.I64} (h0 : 0 ≤ y.val) (h1 : y.val < 64) :
    I64.shl x y ⦃ z => z.bv = x.bv <<< y.val.toNat ⦄ := by
  unfold I64.shl
  simp [h0, h1]

@[step] theorem I64.shr_spec (x : Std.I64) {y : Std.I64} (h0 : 0 ≤ y.val) (h1 : y.val < 64) :
    I64.shr x y ⦃ z => z.bv = x.bv.sshiftRight y.val.toNat ⦄ := by
  unfold I64.shr
  simp [h0, h1]

@[step] theorem U32.shl_spec (x : Std.U32) {y : Std.U32} (h : y.val < 32) :
    U32.shl x y ⦃ z => z.bv = x.bv <<< y.val ⦄ := by
  unfold U32.shl
  simp [h]

@[step] theorem U32.shr_spec (x : Std.U32) {y : Std.U32} (h : y.val < 32) :
    U32.shr x y ⦃ z => z.bv = x.bv >>> y.val ⦄ := by
  unfold U32.shr
  simp [h]

@[step] theorem U64.shl_spec (x : Std.U64) {y : Std.U64} (h : y.val < 64) :
    U64.shl x y ⦃ z => z.bv = x.bv <<< y.val ⦄ := by
  unfold U64.shl
  simp [h]

@[step] theorem U64.shr_spec (x : Std.U64) {y : Std.U64} (h : y.val < 64) :
    U64.shr x y ⦃ z => z.bv = x.bv >>> y.val ⦄ := by
  unfold U64.shr
  simp [h]

@[step] theorem U64.div_spec (x : Std.U64) {y : Std.U64} (hnz : y.val ≠ 0) :
    U64.div x y ⦃ z => z.val = x.val / y.val ⦄ := by
  unfold U64.div
  exact Std.U64.div_spec x hnz

@[step] theorem U64.rem_spec (x : Std.U64) {y : Std.U64} (hnz : y.val ≠ 0) :
    U64.rem x y ⦃ z => z.val = x.val % y.val ⦄ := by
  unfold U64.rem
  exact Std.U64.rem_spec x hnz

/-! ## Containers -/

@[step] theorem lengthOf_spec (n : Nat) (h : n ≤ 2147483647) :
    lengthOf n ⦃ z => z.val = n ⦄ := by
  unfold lengthOf
  simp [h]

@[step] theorem listGet_spec {α : Type u} (l : List α) (i : Std.I32)
    (h0 : 0 ≤ i.val) (h1 : i.val < l.length) :
    listGet l i ⦃ x => l[i.val.toNat]? = some x ⦄ := by
  unfold listGet
  simp [h0, h1]

@[step] theorem listSet_spec {α : Type u} (l : List α) (i : Std.I32) (x : α)
    (h0 : 0 ≤ i.val) (h1 : i.val < l.length) :
    listSet l i x ⦃ l' => l' = l.set i.val.toNat x ⦄ := by
  unfold listSet
  simp [h0, h1]

@[step] theorem Array.length_spec {α : Type u} (a : Pion.Array α)
    (h : a.val.length ≤ 2147483647) :
    a.length ⦃ n => n.val = a.val.length ⦄ := by
  unfold Array.length
  exact lengthOf_spec _ h

@[step] theorem Array.get_spec {α : Type u} (a : Pion.Array α) (i : Std.I32)
    (h0 : 0 ≤ i.val) (h1 : i.val < a.val.length) :
    a.get i ⦃ x => a.val[i.val.toNat]? = some x ⦄ := by
  unfold Array.get
  exact listGet_spec _ _ h0 h1

@[step] theorem Array.set_spec {α : Type u} (a : Pion.Array α) (i : Std.I32) (x : α)
    (h0 : 0 ≤ i.val) (h1 : i.val < a.val.length) :
    a.set i x ⦃ a' => a'.val = a.val.set i.val.toNat x ⦄ := by
  unfold Array.set listSet
  simp [h0, h1]

@[step] theorem Array.swap_spec {α : Type u} (a : Pion.Array α) (i j : Std.I32)
    (hi0 : 0 ≤ i.val) (hi1 : i.val < a.val.length)
    (hj0 : 0 ≤ j.val) (hj1 : j.val < a.val.length) :
    a.swap i j ⦃ a' => a'.val.length = a.val.length ∧
      a'.val[j.val.toNat]? = a.val[i.val.toNat]? ⦄ := by
  unfold Array.swap listSwap listGet
  simp [hi0, hi1, hj0, hj1]

@[step] theorem FixedArray.length_spec {α : Type u} (a : Pion.FixedArray α)
    (h : a.val.length ≤ 2147483647) :
    a.length ⦃ n => n.val = a.val.length ⦄ := by
  unfold FixedArray.length
  exact lengthOf_spec _ h

@[step] theorem FixedArray.get_spec {α : Type u} (a : Pion.FixedArray α) (i : Std.I32)
    (h0 : 0 ≤ i.val) (h1 : i.val < a.val.length) :
    a.get i ⦃ x => a.val[i.val.toNat]? = some x ⦄ := by
  unfold FixedArray.get
  exact listGet_spec _ _ h0 h1

@[step] theorem FixedArray.set_spec {α : Type u} (a : Pion.FixedArray α) (i : Std.I32) (x : α)
    (h0 : 0 ≤ i.val) (h1 : i.val < a.val.length) :
    a.set i x ⦃ a' => a'.val = a.val.set i.val.toNat x ⦄ := by
  unfold FixedArray.set listSet
  simp [h0, h1]

@[step] theorem debugAssert_spec (b : Bool) (h : b = true) :
    debugAssert b ⦃ _ => True ⦄ := by
  unfold debugAssert
  simp [h]

end Pion
