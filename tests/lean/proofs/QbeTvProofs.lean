/-
Proofs over the extracted QBE translation validator (`tools/qbe_tv`, Lean
module `QbeTv`): the constant evaluator of `canon.pion` against exact
`BitVec 32` / `BitVec 64` semantics.

A `W` value is a 64-bit word whose upper half is zero (`mask_cls`); the
theorems below show that the 64-bit operations the validator folds with, once
masked, are the 32-bit operations of QBE (`vendor/qbe/fold.c`) zero-extended,
and the 64-bit ones for `L`.

Scope: these are the first lemmas of the soundness chain. The operational
semantics of QBE functions and `verify_cert_sound` / `validate_fn_sound`
are not proved here yet.
-/
import QbeTv.Funs
open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000

namespace PionProofs.QbeTvP

open qbe_tv

/-! ## Values -/

/-- Zero extension of a 32-bit word. -/
def zx32 (x : BitVec 32) : BitVec 64 := x.setWidth 64

/-- Low 32 bits. -/
def lo32 (x : BitVec 64) : BitVec 32 := x.setWidth 32

/-- `mask_cls`: a `W` value keeps its low 32 bits. -/
def maskC : Cls → BitVec 64 → BitVec 64
  | .W, x => zx32 (lo32 x)
  | .L, x => x

theorem mask32_eq (x : BitVec 64) : x &&& 4294967295#64 = zx32 (lo32 x) := by
  apply BitVec.eq_of_toNat_eq
  have h : (4294967295 : Nat) = 2 ^ 32 - 1 := by norm_num
  simp only [zx32, lo32, BitVec.toNat_and, BitVec.toNat_setWidth, BitVec.toNat_ofNat]
  rw [show (4294967295 : Nat) % 2 ^ 64 = 2 ^ 32 - 1 by norm_num, Nat.and_two_pow_sub_one_eq_mod]
  rw [Nat.mod_eq_of_lt (a := x.toNat % 2 ^ 32) (by have := Nat.mod_lt x.toNat (show 0 < 2 ^ 32 by norm_num); omega)]

theorem mask_cls_spec (c : Cls) (v : Std.U64) : mask_cls c v = ok ⟨maskC c v.bv⟩ := by
  cases c
  · simp only [mask_cls, maskC, Pion.U64.band]
    congr 2
    exact mask32_eq v.bv
  · simp [mask_cls, maskC]

theorem lo32_zx32 (x : BitVec 32) : lo32 (zx32 x) = x := by
  apply BitVec.eq_of_toNat_eq
  simp only [lo32, zx32, BitVec.toNat_setWidth]
  rw [Nat.mod_eq_of_lt (a := x.toNat) (by have := x.isLt; omega)]
  exact Nat.mod_eq_of_lt x.isLt

theorem maskC_idem (c : Cls) (x : BitVec 64) : maskC c (maskC c x) = maskC c x := by
  cases c <;> simp [maskC, lo32_zx32]

/-! ## Exact 32 / 64-bit semantics of the folded operators -/

/-- The operators that never trap, at 32 bits. -/
def ring32 : BinOp → BitVec 32 → BitVec 32 → Option (BitVec 32)
  | .Add, a, b => some (a + b)
  | .Sub, a, b => some (a - b)
  | .Mul, a, b => some (a * b)
  | .And, a, b => some (a &&& b)
  | .Or, a, b => some (a ||| b)
  | .Xor, a, b => some (a ^^^ b)
  | _, _, _ => none

/-- The operators that never trap, at 64 bits. -/
def ring64 : BinOp → BitVec 64 → BitVec 64 → Option (BitVec 64)
  | .Add, a, b => some (a + b)
  | .Sub, a, b => some (a - b)
  | .Mul, a, b => some (a * b)
  | .And, a, b => some (a &&& b)
  | .Or, a, b => some (a ||| b)
  | .Xor, a, b => some (a ^^^ b)
  | _, _, _ => none

theorem lo32_add (a b : BitVec 64) : lo32 (a + b) = lo32 a + lo32 b := by
  apply BitVec.eq_of_toNat_eq
  simp only [lo32, BitVec.toNat_setWidth, BitVec.toNat_add]
  rw [Nat.mod_mod_of_dvd _ (by norm_num : 2 ^ 32 ∣ 2 ^ 64), Nat.add_mod]

theorem lo32_mul (a b : BitVec 64) : lo32 (a * b) = lo32 a * lo32 b := by
  apply BitVec.eq_of_toNat_eq
  simp only [lo32, BitVec.toNat_setWidth, BitVec.toNat_mul]
  rw [Nat.mod_mod_of_dvd _ (by norm_num : 2 ^ 32 ∣ 2 ^ 64), Nat.mul_mod]

theorem lo32_neg (a : BitVec 64) : lo32 (-a) = -lo32 a := by
  apply BitVec.eq_of_toNat_eq
  simp only [lo32, BitVec.toNat_setWidth, BitVec.toNat_neg]
  rw [Nat.mod_mod_of_dvd _ (by norm_num : 2 ^ 32 ∣ 2 ^ 64)]
  have ha := a.isLt
  rcases Nat.eq_zero_or_pos (a.toNat % 2 ^ 32) with h | h
  · rw [h]
    have : (2 ^ 64 - a.toNat) % 2 ^ 32 = 0 := by omega
    simpa using this
  · omega

theorem lo32_sub (a b : BitVec 64) : lo32 (a - b) = lo32 a - lo32 b := by
  rw [BitVec.sub_eq_add_neg, BitVec.sub_eq_add_neg, lo32_add, lo32_neg]

theorem lo32_and (a b : BitVec 64) : lo32 (a &&& b) = lo32 a &&& lo32 b := by
  simp [lo32, BitVec.setWidth_and]

theorem lo32_or (a b : BitVec 64) : lo32 (a ||| b) = lo32 a ||| lo32 b := by
  simp [lo32, BitVec.setWidth_or]

theorem lo32_xor (a b : BitVec 64) : lo32 (a ^^^ b) = lo32 a ^^^ lo32 b := by
  simp [lo32, BitVec.setWidth_xor]

theorem zx32_and (a b : BitVec 32) : zx32 (a &&& b) = zx32 a &&& zx32 b := by
  simp [zx32, BitVec.setWidth_and]

theorem zx32_or (a b : BitVec 32) : zx32 (a ||| b) = zx32 a ||| zx32 b := by
  simp [zx32, BitVec.setWidth_or]

theorem zx32_xor (a b : BitVec 32) : zx32 (a ^^^ b) = zx32 a ^^^ zx32 b := by
  simp [zx32, BitVec.setWidth_xor]

/-- `eval_bin_const` on `add sub mul and or xor`: the 32-bit operation on
the low halves, zero-extended, for `W`; the 64-bit operation for `L`. -/
theorem eval_bin_const_ring_sound (op : BinOp) (a b : Std.U64) (r : BitVec 32)
    (h : ring32 op (lo32 a.bv) (lo32 b.bv) = some r) :
    eval_bin_const .W op a b = ok (some ⟨zx32 r⟩) := by
  cases op <;> simp only [ring32, Option.some.injEq, reduceCtorEq] at h <;> subst h <;>
    simp only [eval_bin_const, mask_cls_spec, maskC, Pion.U64.add, Pion.U64.sub, Pion.U64.mul,
      Pion.U64.band, Pion.U64.bor, Pion.U64.bxor, Std.U64.wrapping_add_bv_eq,
      Std.U64.wrapping_sub_bv_eq, Std.U64.wrapping_mul_bv_eq] <;>
    simp [lo32_add, lo32_sub, lo32_mul, lo32_zx32, zx32_and, zx32_or, zx32_xor]

theorem eval_bin_const_ring64_sound (op : BinOp) (a b : Std.U64) (r : BitVec 64)
    (h : ring64 op a.bv b.bv = some r) :
    eval_bin_const .L op a b = ok (some ⟨r⟩) := by
  cases op <;> simp only [ring64, Option.some.injEq, reduceCtorEq] at h <;> subst h <;>
    simp [eval_bin_const, mask_cls_spec, maskC, Std.U64.wrapping_add_bv_eq,
      Std.U64.wrapping_sub_bv_eq, Std.U64.wrapping_mul_bv_eq]

/-! ## Unary operators -/

/-- `copy`, `neg` and the zero extensions. -/
theorem eval_un_const_copy (cls : Cls) (v : Std.U64) :
    eval_un_const cls .Copy v = ok ⟨maskC cls v.bv⟩ := by
  simp [eval_un_const, mask_cls_spec]

theorem eval_un_const_neg_w (v : Std.U64) :
    eval_un_const .W .Neg v = ok ⟨zx32 (-lo32 v.bv)⟩ := by
  simp [eval_un_const, mask_cls_spec, maskC, Std.U64.wrapping_sub_bv_eq, lo32_neg]

theorem eval_un_const_neg_l (v : Std.U64) :
    eval_un_const .L .Neg v = ok ⟨-v.bv⟩ := by
  simp [eval_un_const, mask_cls_spec, maskC, Std.U64.wrapping_sub_bv_eq]

end PionProofs.QbeTvP
