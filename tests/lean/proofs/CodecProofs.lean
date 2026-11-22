/-
Proofs over the extracted 64-bit capability descriptor codec
(`tests/lean/codec`): layout tag 0..3, rights 4..7, badge 8..31, pfn 32..63.
Bit-level reasoning with `BitVec` lemmas.
-/
import Codec.Funs
open Aeneas Aeneas.Std Result Pion WP

set_option maxRecDepth 100000

namespace PionProofs.CodecP

open codec

/-- Every field fits its bit width. -/
def Desc.valid (d : Desc) : Prop :=
  d.tag.val < 2 ^ 4 ∧ d.rights.val < 2 ^ 4 ∧ d.badge.val < 2 ^ 24 ∧ d.pfn.val < 2 ^ 32

theorem bit_hi {x : BitVec 64} {k i : Nat} (h : x.toNat < 2 ^ k) (hi : k ≤ i) :
    x.getLsbD i = false := by
  simp only [BitVec.getLsbD]
  exact Nat.testBit_lt_two_pow (lt_of_lt_of_le h (Nat.pow_le_pow_right (by omega) hi))

theorem lit15 : ∀ i, i < 64 → (15#64).getLsbD i = decide (i < 4) := by decide +kernel
theorem lit24 : ∀ i, i < 64 → (16777215#64).getLsbD i = decide (i < 24) := by decide +kernel
theorem litC : ∀ i, i < 64 →
    (18446744073709551375#64).getLsbD i = !(decide (4 ≤ i) && decide (i < 8)) := by decide +kernel

theorem b_ok {α β : Type} (x : α) (f : α → Result β) :
    (do let y ← (ok x : Result α); f y) = f x := by simp

theorem shr_lit (x k : Std.U64) (h : k.val < 64) : Pion.U64.shr x k = ok ⟨x.bv >>> k.val⟩ := by
  simp [Pion.U64.shr, h]

theorem shl_lit (x k : Std.U64) (h : k.val < 64) : Pion.U64.shl x k = ok ⟨x.bv <<< k.val⟩ := by
  simp [Pion.U64.shl, h]

theorem unpack_eq (raw : Std.U64) :
    unpack raw = ok (Desc.mk ⟨raw.bv &&& 15#64⟩ ⟨(raw.bv >>> 4) &&& 15#64⟩
      ⟨(raw.bv >>> 8) &&& 16777215#64⟩ ⟨raw.bv >>> 32⟩) := by
  unfold unpack
  simp [shr_lit]

theorem u64_ext {a b : Std.U64} (h : a.bv = b.bv) : a = b := by
  cases a; cases b; simp_all

theorem desc_valid_eq (d : Desc) :
    desc_valid d = ok (decide (d.tag.val ≤ 15) && decide (d.rights.val ≤ 15) &&
      decide (d.badge.val ≤ 16777215) && decide (d.pfn.val ≤ 4294967295)) := by
  unfold desc_valid
  have e : ∀ (x y : Std.U64), decide (x ≤ y) = decide (x.val ≤ y.val) :=
    fun x y => decide_eq_decide.mpr Iff.rfl
  simp only [e]
  rfl

theorem desc_valid_true {d : Desc} (h : Desc.valid d) : desc_valid d = ok true := by
  obtain ⟨h1, h2, h3, h4⟩ := h
  rw [desc_valid_eq]
  have a1 : d.tag.val ≤ 15 := by omega
  have a2 : d.rights.val ≤ 15 := by omega
  have a3 : d.badge.val ≤ 16777215 := by omega
  have a4 : d.pfn.val ≤ 4294967295 := by omega
  simp [a1, a2, a3, a4]

theorem desc_valid_false {d : Desc} (h : ¬ Desc.valid d) : desc_valid d = ok false := by
  rw [desc_valid_eq]
  congr 1
  by_contra hc
  apply h
  simp only [Bool.not_eq_false, Bool.and_eq_true, decide_eq_true_eq] at hc
  obtain ⟨⟨⟨a1, a2⟩, a3⟩, a4⟩ := hc
  refine ⟨?_, ?_, ?_, ?_⟩ <;> omega

theorem pack_eq {d : Desc} (h : Desc.valid d) :
    pack d = ok (some ⟨d.tag.bv ||| d.rights.bv <<< 4 ||| d.badge.bv <<< 8 ||| d.pfn.bv <<< 32⟩) := by
  unfold pack
  rw [desc_valid_true h]
  simp only [b_ok, Bool.not_true, Bool.false_eq_true, ↓reduceIte]
  rw [shl_lit d.rights 4#u64 (by simp)]
  simp only [b_ok]
  rw [shl_lit d.badge 8#u64 (by simp)]
  simp only [b_ok]
  rw [shl_lit d.pfn 32#u64 (by simp)]
  simp only [b_ok]
  rfl

section fields
variable {t r b p : BitVec 64}

theorem get_tag (ht : t.toNat < 2 ^ 4) :
    (t ||| r <<< 4 ||| b <<< 8 ||| p <<< 32) &&& 15#64 = t := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_and, BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft, lit15 i hi]
  by_cases h : i < 4
  · have h8 : i < 8 := by omega
    have h32 : i < 32 := by omega
    simp [h, h8, h32]
  · simp [h, bit_hi ht (not_lt.1 h)]

theorem get_rights (ht : t.toNat < 2 ^ 4) (hr : r.toNat < 2 ^ 4) :
    ((t ||| r <<< 4 ||| b <<< 8 ||| p <<< 32) >>> 4) &&& 15#64 = r := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_and, BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft,
    BitVec.getLsbD_ushiftRight, lit15 i hi]
  by_cases h : i < 4
  · have h8 : 4 + i < 8 := by omega
    have h32 : 4 + i < 32 := by omega
    have h64 : 4 + i < 64 := by omega
    rw [bit_hi ht (show 4 ≤ 4 + i by omega)]
    simp [h, h8, h32, h64]
  · simp [h, bit_hi hr (not_lt.1 h)]

theorem get_badge (ht : t.toNat < 2 ^ 4) (hr : r.toNat < 2 ^ 4) (hb : b.toNat < 2 ^ 24) :
    ((t ||| r <<< 4 ||| b <<< 8 ||| p <<< 32) >>> 8) &&& 16777215#64 = b := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_and, BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft,
    BitVec.getLsbD_ushiftRight, lit24 i hi]
  by_cases h : i < 24
  · have h32 : 8 + i < 32 := by omega
    have h64 : 8 + i < 64 := by omega
    have hn4 : ¬ 8 + i < 4 := by omega
    have hn8 : ¬ 8 + i < 8 := by omega
    rw [bit_hi ht (show 4 ≤ 8 + i by omega), bit_hi hr (show 4 ≤ 8 + i - 4 by omega)]
    simp [h, h32, h64, hn4, hn8]
  · simp [h, bit_hi hb (not_lt.1 h)]

theorem get_pfn (ht : t.toNat < 2 ^ 4) (hr : r.toNat < 2 ^ 4) (hb : b.toNat < 2 ^ 24)
    (hp : p.toNat < 2 ^ 32) :
    (t ||| r <<< 4 ||| b <<< 8 ||| p <<< 32) >>> 32 = p := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft, BitVec.getLsbD_ushiftRight]
  by_cases h : i < 32
  · have h64 : 32 + i < 64 := by omega
    have hn4 : ¬ 32 + i < 4 := by omega
    have hn8 : ¬ 32 + i < 8 := by omega
    have hn32 : ¬ 32 + i < 32 := by omega
    rw [bit_hi ht (show 4 ≤ 32 + i by omega), bit_hi hr (show 4 ≤ 32 + i - 4 by omega),
      bit_hi hb (show 24 ≤ 32 + i - 8 by omega)]
    simp [h64, hn4, hn8, hn32]
  · have hge : 64 ≤ 32 + i := by omega
    simp [bit_hi hp (not_lt.1 h), BitVec.getLsbD_of_ge _ _ hge, Nat.not_lt.2 hge]

end fields

/-- Encoding a valid descriptor succeeds and decoding gives it back. -/
theorem pack_unpack_roundtrip (d : Desc) (h : Desc.valid d) :
    ∃ raw, pack d = ok (some raw) ∧ unpack raw = ok d := by
  refine ⟨_, pack_eq h, ?_⟩
  obtain ⟨h1, h2, h3, h4⟩ := id h
  rw [unpack_eq]
  have e1 := get_tag (r := d.rights.bv) (b := d.badge.bv) (p := d.pfn.bv) h1
  have e2 := get_rights (b := d.badge.bv) (p := d.pfn.bv) h1 h2
  have e3 := get_badge (p := d.pfn.bv) h1 h2 h3
  have e4 := get_pfn h1 h2 h3 h4
  cases d
  simp only at e1 e2 e3 e4 ⊢
  simp only [e1, e2, e3, e4]

/-- A descriptor with any out-of-range field is rejected. -/
theorem pack_rejects_invalid (d : Desc) (h : ¬ Desc.valid d) : pack d = ok none := by
  unfold pack
  rw [desc_valid_false h]
  simp only [b_ok, Bool.not_false, ↓reduceIte]

theorem restrict_eq (raw mask : Std.U64) :
    restrict_rights raw mask = ok ⟨(raw.bv &&& 18446744073709551375#64) |||
      (((raw.bv >>> 4) &&& mask.bv &&& 15#64) <<< 4)⟩ := by
  unfold restrict_rights
  rw [shr_lit raw 4#u64 (by simp)]
  simp only [b_ok]
  rw [shl_lit _ 4#u64 (by simp)]
  simp only [b_ok]
  rfl

section restrict
variable (x m : BitVec 64)

private abbrev rr : BitVec 64 :=
  (x &&& 18446744073709551375#64) ||| (((x >>> 4) &&& m &&& 15#64) <<< 4)

theorem rr_tag : rr x m &&& 15#64 = x &&& 15#64 := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [rr, BitVec.getLsbD_and, BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft,
    lit15 i hi, litC i hi]
  by_cases h : i < 4
  · have : ¬ 4 ≤ i := by omega
    simp [h, this]
  · simp [h]

theorem rr_rights : (rr x m >>> 4) &&& 15#64 = ((x >>> 4) &&& 15#64) &&& m := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  by_cases h : i < 4
  · have h64 : 4 + i < 64 := by omega
    have hc := litC (4 + i) h64
    have h8 : 4 + i < 8 := by omega
    simp only [rr, BitVec.getLsbD_and, BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft,
      BitVec.getLsbD_ushiftRight, lit15 i hi, hc, lit15 (4 + i - 4) (by omega)]
    simp [h, h8, h64]
  · simp [BitVec.getLsbD_and, lit15 i hi, h]

theorem rr_badge : (rr x m >>> 8) &&& 16777215#64 = (x >>> 8) &&& 16777215#64 := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  by_cases h : i < 24
  · have h64 : 8 + i < 64 := by omega
    have hc := litC (8 + i) h64
    have hk := lit15 (8 + i - 4) (show 8 + i - 4 < 64 by omega)
    have hk0 : decide (8 + i - 4 < 4) = false := by simp; omega
    simp only [rr, BitVec.getLsbD_and, BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft,
      BitVec.getLsbD_ushiftRight, lit24 i hi, hc, hk, hk0]
    have h8 : ¬ 8 + i < 8 := by omega
    simp [h, h8]
  · simp [BitVec.getLsbD_and, lit24 i hi, h]

theorem rr_pfn : rr x m >>> 32 = x >>> 32 := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  by_cases h : i < 32
  · have h64 : 32 + i < 64 := by omega
    have hc := litC (32 + i) h64
    have hk := lit15 (32 + i - 4) (show 32 + i - 4 < 64 by omega)
    have hk0 : decide (32 + i - 4 < 4) = false := by simp; omega
    simp only [rr, BitVec.getLsbD_and, BitVec.getLsbD_or, BitVec.getLsbD_shiftLeft,
      BitVec.getLsbD_ushiftRight, hc, hk, hk0]
    have h8 : ¬ 32 + i < 8 := by omega
    simp [h8]
  · have hge : 64 ≤ 32 + i := by omega
    simp [BitVec.getLsbD_ushiftRight, BitVec.getLsbD_of_ge _ _ hge]

end restrict

/-- `restrict_rights` intersects the rights with `mask` and keeps every other field. -/
theorem restrict_rights_preserves_other_fields (raw mask : Std.U64) :
    ∃ raw' d d', restrict_rights raw mask = ok raw' ∧ unpack raw = ok d ∧ unpack raw' = ok d' ∧
      d'.tag = d.tag ∧ d'.badge = d.badge ∧ d'.pfn = d.pfn ∧
      d'.rights.bv = d.rights.bv &&& mask.bv ∧ d'.rights.val ≤ d.rights.val := by
  refine ⟨_, _, _, restrict_eq raw mask, unpack_eq raw, unpack_eq _, ?_, ?_, ?_, ?_, ?_⟩
  · exact u64_ext (rr_tag raw.bv mask.bv)
  · exact u64_ext (rr_badge raw.bv mask.bv)
  · exact u64_ext (rr_pfn raw.bv mask.bv)
  · exact rr_rights raw.bv mask.bv
  · show BitVec.toNat _ ≤ BitVec.toNat _
    rw [show ((_ : BitVec 64)) = _ from rr_rights raw.bv mask.bv, BitVec.toNat_and]
    exact Nat.and_le_left

end PionProofs.CodecP
