/-
Proofs over the extracted QBE translation validator (`tools/qbe_tv`, Lean
module `QbeTv`).

- `QbeTvSem`: the exact bit-vector semantics of QBE operators (`evalUn`,
  `evalBin`), the constant evaluator against it (`eval_un_const_sound`,
  `eval_bin_const_sound`), the operational semantics of QBE functions
  (`evalFunc`), the denotation of the value graph (`evalSym`), `vg_intern`,
  `check_vg_dag` and `vid_mentions_blk`.
- `QbeTvCanon`: `fits_bits`, `vg_canon_un`, `vg_canon_bin` /
  `canon_bin_rconst`, `vg_trunc_w`, `vg_use` produce nodes with exactly the
  value of the operation they canonicalise.

This file keeps the first lemmas of the chain: the 64-bit operations the
validator folds with, once masked, are the 32-bit operations of QBE
(`vendor/qbe/fold.c`) zero-extended for `W`, and the 64-bit ones for `L`.

Scope: `verify_cert_sound` / `validate_fn_sound` are not proved here yet.
-/
import PionProofs.QbeTvCanon
open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000

namespace PionProofs.QbeTvP

open qbe_tv

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
