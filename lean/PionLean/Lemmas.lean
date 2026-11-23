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

/-! ## Double bit-pattern lemmas -/

theorem Double.to_bits_from_bits (b : Std.I64) :
    (Pion.Double.from_bits b).to_bits = b := rfl

theorem Double.from_bits_to_bits (d : Pion.Double) :
    Pion.Double.from_bits d.to_bits = d := rfl

theorem Double.reinterpret_as_uint64_from_bits (b : Std.I64) :
    (Pion.Double.from_bits b).reinterpret_as_uint64.bv = b.bv := rfl

/-! ## StringBuilder lemmas -/

theorem StringBuilder.new_val : Pion.StringBuilder.new.val = [] := rfl

theorem StringBuilder.write_byte_val (sb : Pion.StringBuilder) (b : Std.U8) :
    (sb.write_byte b).val = sb.val ++ [b] := rfl

theorem StringBuilder.write_string_val (sb : Pion.StringBuilder) (s : _root_.String) :
    (sb.write_string s).val = sb.val ++ Pion.StringBuilder.bytesOfString s := rfl

theorem StringBuilder.write_substring_val (sb : Pion.StringBuilder) (s : _root_.String)
    (start end_ : Std.I32) :
    (sb.write_substring s start end_).val =
      let bs := Pion.StringBuilder.bytesOfString s
      let s0 : Nat := if start.val < 0 then 0 else start.val.toNat
      let e0 : Nat := if end_.val < 0 then 0 else min end_.val.toNat bs.length
      if s0 < e0 then sb.val ++ (bs.drop s0).take (e0 - s0) else sb.val := by
  unfold Pion.StringBuilder.write_substring
  dsimp only
  by_cases h : (if start.val < 0 then 0 else start.val.toNat) <
      (if end_.val < 0 then 0 else min end_.val.toNat (Pion.StringBuilder.bytesOfString s).length)
  · simp [h]
  · simp [h]

theorem StringBuilder.clear_val (sb : Pion.StringBuilder) :
    sb.clear.val = [] := rfl

theorem StringBuilder.write_byte_length (sb : Pion.StringBuilder) (b : Std.U8) :
    (sb.write_byte b).val.length = sb.val.length + 1 := by
  simp

@[step] theorem StringBuilder.length_spec (sb : Pion.StringBuilder)
    (h : sb.val.length ≤ 2147483647) :
    sb.length ⦃ n => n.val = sb.val.length ⦄ := by
  unfold StringBuilder.length
  exact lengthOf_spec _ h

theorem StringBuilder.to_string_write_string (s : _root_.String) :
    (Pion.StringBuilder.new.write_string s).to_string = s := by
  unfold Pion.StringBuilder.to_string Pion.StringBuilder.write_string
    Pion.StringBuilder.new Pion.StringBuilder.bytesOfString
  simp only [List.nil_append, List.map_map]
  have hmap : (List.map (Pion.StringBuilder.byteOfU8 ∘ Pion.StringBuilder.u8OfByte) s.toUTF8.data.toList) =
      s.toUTF8.data.toList := List.map_id' _
  rw [hmap]
  have hba : ByteArray.mk s.toUTF8.data.toList.toArray = s.toUTF8 := by
    cases h : s.toUTF8 with
    | mk data => simp
  rw [hba]
  unfold _root_.String.fromUTF8! _root_.String.fromUTF8 _root_.String.toUTF8
  simp [s.isValidUTF8]

/-! ## Map lemmas -/

theorem Map.get_new {κ : Type u} {ν : Type v} [BEq κ] (k : κ) :
    (Pion.Map.new : Pion.Map κ ν).get k = none := rfl

private theorem Map.listGet_listSet_eq {κ : Type u} {ν : Type v} [BEq κ] [LawfulBEq κ]
    (l : List (κ × ν)) (k : κ) (v : ν) :
    Pion.Map.listGet (Pion.Map.listSet l k v) k = some v := by
  induction l with
  | nil => simp [Pion.Map.listSet, Pion.Map.listGet]
  | cons hd tl ih =>
    rcases hd with ⟨k', v'⟩
    simp only [Pion.Map.listSet]
    by_cases h : (k' == k) = true
    · simp [h, Pion.Map.listGet]
    · simp [h, Pion.Map.listGet, ih]

theorem Map.get_set_eq {κ : Type u} {ν : Type v} [BEq κ] [LawfulBEq κ]
    (m : Pion.Map κ ν) (k : κ) (v : ν) :
    (m.set k v).get k = some v :=
  Map.listGet_listSet_eq m.entries k v

private theorem Map.listGet_listSet_ne {κ : Type u} {ν : Type v} [BEq κ] [LawfulBEq κ]
    (l : List (κ × ν)) {k k' : κ} (hne : k ≠ k') (v : ν) :
    Pion.Map.listGet (Pion.Map.listSet l k v) k' = Pion.Map.listGet l k' := by
  induction l with
  | nil =>
    have hfalse : (k == k') = false := beq_false_of_ne hne
    simp [Pion.Map.listSet, Pion.Map.listGet, hfalse]
  | cons hd tl ih =>
    rcases hd with ⟨k0, v0⟩
    simp only [Pion.Map.listSet]
    by_cases h0 : (k0 == k) = true
    · have hk0 : k0 = k := eq_of_beq h0
      subst hk0
      have hfalse : (k0 == k') = false := beq_false_of_ne hne
      simp [Pion.Map.listGet, hfalse]
    · rw [ite_eq_right h0]
      simp only [Pion.Map.listGet]
      by_cases h1 : (k0 == k') = true
      · simp [h1]
      · simp [h1, ih]

theorem Map.get_set_ne {κ : Type u} {ν : Type v} [BEq κ] [LawfulBEq κ]
    (m : Pion.Map κ ν) {k k' : κ} (hne : k ≠ k') (v : ν) :
    (m.set k v).get k' = m.get k' :=
  Map.listGet_listSet_ne m.entries hne v

private theorem Map.listGet_listRemove_eq {κ : Type u} {ν : Type v} [BEq κ] [LawfulBEq κ]
    (l : List (κ × ν)) (k : κ) :
    Pion.Map.listGet (Pion.Map.listRemove l k) k = none := by
  induction l with
  | nil => rfl
  | cons hd tl ih =>
    rcases hd with ⟨k0, v0⟩
    simp only [Pion.Map.listRemove]
    by_cases h : (k0 == k) = true
    · simp [h, ih]
    · simp [h, Pion.Map.listGet, ih]

theorem Map.get_remove_eq {κ : Type u} {ν : Type v} [BEq κ] [LawfulBEq κ]
    (m : Pion.Map κ ν) (k : κ) :
    (m.remove k).get k = none :=
  Map.listGet_listRemove_eq m.entries k

private theorem Map.listGet_listRemove_ne {κ : Type u} {ν : Type v} [BEq κ] [LawfulBEq κ]
    (l : List (κ × ν)) {k k' : κ} (hne : k ≠ k') :
    Pion.Map.listGet (Pion.Map.listRemove l k) k' = Pion.Map.listGet l k' := by
  induction l with
  | nil => rfl
  | cons hd tl ih =>
    rcases hd with ⟨k0, v0⟩
    simp only [Pion.Map.listRemove]
    by_cases h0 : (k0 == k) = true
    · have hk0 : k0 = k := eq_of_beq h0
      subst hk0
      have hfalse : (k0 == k') = false := beq_false_of_ne hne
      simp [Pion.Map.listGet, hfalse, ih]
    · rw [ite_eq_right h0]
      simp only [Pion.Map.listGet]
      by_cases h1 : (k0 == k') = true
      · simp [h1]
      · simp [h1, ih]

theorem Map.get_remove_ne {κ : Type u} {ν : Type v} [BEq κ] [LawfulBEq κ]
    (m : Pion.Map κ ν) {k k' : κ} (hne : k ≠ k') :
    (m.remove k).get k' = m.get k' :=
  Map.listGet_listRemove_ne m.entries hne

theorem Map.contains_eq_isSome {κ : Type u} {ν : Type v} [BEq κ]
    (m : Pion.Map κ ν) (k : κ) :
    m.contains k = (m.get k).isSome := rfl

@[step] theorem Map.length_spec {κ : Type u} {ν : Type v} (m : Pion.Map κ ν)
    (h : m.entries.length ≤ 2147483647) :
    m.length ⦃ n => n.val = m.entries.length ⦄ := by
  unfold Map.length
  exact lengthOf_spec _ h

end Pion
