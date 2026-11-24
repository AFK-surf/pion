/-
Soundness of the canonicalisation of the QBE translation validator
(`tools/qbe_tv/src/canon.pion`) against the value-graph semantics of
`QbeTvSem`: `fits_bits` / `is_bool_node` bound the value of a node,
`vg_canon_un` / `vg_canon_bin` / `canon_bin_rconst` / `vg_trunc_w` /
`vg_use` return nodes whose value is the exact 32 / 64-bit result of the
operation they canonicalise, and only ever append to a DAG.

The recursive functions are `partial_fixpoint`s: every theorem is a partial
correctness statement (`f .. = ok r → P r`) proved by `fixpoint_induct`, with
no termination argument. Nothing here assumes more about the value graph than
`ValGraphDAG` (`check_vg_dag`), so the results apply to the untrusted graph
of a certificate as well.
-/
import PionProofs.QbeTvSem
open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 4000000

namespace PionProofs.QbeTvP

open qbe_tv

/-! ## Facts about nodes of a DAG -/

theorem constOf_some {vg : ValGraph} {a : Std.I32} {x : BitVec 64} (h : constOf vg a = some x) :
    ∃ c y, nodeAt vg a = some (.SConst c y) ∧ x = maskC c y.bv := by
  unfold constOf at h
  split at h
  · rename_i c y hn
    exact ⟨c, y, hn, (Option.some.inj h).symm⟩
  · cases h

theorem constOf_evI {vg : ValGraph} (hd : ValGraphDAG vg) (env : SymEnv) {a : Std.I32}
    {x : BitVec 64} (h : constOf vg a = some x) : evI vg env a = x := by
  obtain ⟨c, y, hn, rfl⟩ := constOf_some h
  rw [evI_node hd env hn]
  rfl

theorem constOf_valid {vg : ValGraph} {a : Std.I32} {x : BitVec 64} (h : constOf vg a = some x) :
    Valid vg a := by
  obtain ⟨c, y, hn, _⟩ := constOf_some h
  exact nodeAt_valid hn

theorem constOf_clsOf {vg : ValGraph} {a : Std.I32} {x : BitVec 64} (h : constOf vg a = some x) :
    maskC (clsOf vg a) x = x := by
  obtain ⟨c, y, hn, rfl⟩ := constOf_some h
  simp [clsOf, hn, nodeCls, maskC_idem]

theorem evI_masked {vg : ValGraph} (hd : ValGraphDAG vg) (env : SymEnv) {a : Std.I32}
    (hv : Valid vg a) : maskC (clsOf vg a) (evI vg env a) = evI vg env a := by
  have hn := valid_nodeAt hv
  rw [evI_node hd env hn]
  simp only [clsOf, hn]
  exact evalNode_masked env _ _

theorem evI_maskW {vg : ValGraph} (hd : ValGraphDAG vg) (env : SymEnv) {a : Std.I32}
    (hv : Valid vg a) (hc : clsOf vg a = .W) : maskC .W (evI vg env a) = evI vg env a := by
  have := evI_masked hd env hv
  rwa [hc] at this

theorem evI_ltW {vg : ValGraph} (hd : ValGraphDAG vg) (env : SymEnv) {a : Std.I32}
    (hv : Valid vg a) (hc : clsOf vg a = .W) : (evI vg env a).toNat < 2 ^ 32 := by
  rw [← evI_maskW hd env hv hc]
  exact maskW_lt _

theorem child_un {vg : ValGraph} (hd : ValGraphDAG vg) {a : Std.I32} {c : Cls} {op : UnOp}
    {x : Std.I32} (h : nodeAt vg a = some (.SUn c op x)) : Valid vg x := by
  obtain ⟨h0, h1⟩ := nodeAt_some h
  have hc : childrenBelow _ _ := hd _ _ h1
  simp only [childrenBelow] at hc
  have hv := nodeAt_valid h
  exact ⟨hc.1, by have := hv.2; omega⟩

theorem child_bin {vg : ValGraph} (hd : ValGraphDAG vg) {a : Std.I32} {c : Cls} {op : BinOp}
    {x y : Std.I32} (h : nodeAt vg a = some (.SBin c op x y)) : Valid vg x ∧ Valid vg y := by
  obtain ⟨h0, h1⟩ := nodeAt_some h
  have hc : childrenBelow _ _ := hd _ _ h1
  simp only [childrenBelow] at hc
  have hv := nodeAt_valid h
  exact ⟨⟨hc.1.1, by have := hv.2; omega⟩, ⟨hc.2.1, by have := hv.2; omega⟩⟩

theorem clsOf_node {vg : ValGraph} {a : Std.I32} {n : SymNode} (h : nodeAt vg a = some n) :
    clsOf vg a = nodeCls n := by
  simp [clsOf, h]

@[simp] theorem i32_7_val : (7#i32 : Std.I32).val = 7 := by decide
@[simp] theorem i32_8_val : (8#i32 : Std.I32).val = 8 := by decide
@[simp] theorem i32_15_val : (15#i32 : Std.I32).val = 15 := by decide
@[simp] theorem i32_16_val : (16#i32 : Std.I32).val = 16 := by decide
@[simp] theorem i32_31_val : (31#i32 : Std.I32).val = 31 := by decide
@[simp] theorem i32_32_val : (32#i32 : Std.I32).val = 32 := by decide

theorem bne_W {c : Cls} (h : ¬ (c != Cls.W) = true) : c = .W := by
  cases c <;> simp_all

/-- The `I32` comparisons of extracted code. -/
theorem i32_ge_iff (a b : Std.I32) : a ≥ b ↔ b.val ≤ a.val := Iff.rfl
theorem i32_gt_iff (a b : Std.I32) : a > b ↔ b.val < a.val := Iff.rfl

theorem shr_i32_ok {x : Std.U64} {w : Std.I32} {t : Std.U64} (h : Pion.U64.shr_i32 x w = ok t) :
    0 ≤ w.val ∧ w.val < 64 ∧ t.bv = x.bv >>> w.val.toNat := by
  unfold Pion.U64.shr_i32 at h
  split at h
  · rename_i hw
    rw [← ok_inj' h]
    exact ⟨hw.1, hw.2, rfl⟩
  · simp at h

theorem nat_lt_pow_of_shr {x n : Nat} (h : x >>> n = 0) : x < 2 ^ n := by
  rw [Nat.shiftRight_eq_div_pow] at h
  rcases Nat.lt_or_ge x (2 ^ n) with h' | h'
  · exact h'
  · have := Nat.div_pos h' (Nat.two_pow_pos n)
    omega

theorem shr_lt {x k m : Nat} (h : x < 2 ^ (m + k)) : x >>> k < 2 ^ m := by
  rw [Nat.shiftRight_eq_div_pow]
  apply Nat.div_lt_of_lt_mul
  rw [← Nat.pow_add, Nat.add_comm]; exact h

theorem pow_mono {a b : Nat} (h : a ≤ b) : 2 ^ a ≤ 2 ^ b := Nat.pow_le_pow_right (by norm_num) h

/-- The value of an `SBin` node of class `W` whose operator never traps. -/
theorem evalBin_cmp_le (c : Cls) (op : BinOp) (x y : BitVec 64) (hop : binop_is_cmp op = ok true) :
    ((evalBin c op x y).getD 0).toNat ≤ 1 := by
  cases op <;> simp [binop_is_cmp] at hop <;> simp only [evalBin, Option.getD_some] <;>
    exact b2v_toNat_le _

/-- A `W` value below `2^31` reads the same signed. -/
theorem extS32_of_lt (x : BitVec 64) (h : x.toNat < 2 ^ 31) : extS 32 x = x := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [extS, BitVec.getLsbD_signExtend, BitVec.getLsbD_setWidth, BitVec.msb_setWidth]
  have hb : ∀ j, 31 ≤ j → x.getLsbD j = false := by
    intro j hj
    simp only [BitVec.getLsbD, Nat.testBit]
    have : x.toNat >>> j = 0 := by
      rw [Nat.shiftRight_eq_div_pow]
      apply Nat.div_eq_of_lt
      exact Nat.lt_of_lt_of_le h (pow_mono hj)
    simp [this]
  by_cases h' : i < 32
  · simp [h', hi]
  · have e1 : x.getLsbD 31 = false := hb 31 (by omega)
    have e2 : x.getLsbD i = false := hb i (by omega)
    simp only [BitVec.getLsbD_eq_getElem hi, BitVec.getLsbD_eq_getElem (show 31 < 64 by omega)] at e1 e2
    simp [h', hi, e1, e2]

theorem extS_of_lt (k : Nat) (hk : 1 ≤ k) (hk' : k ≤ 64) (x : BitVec 64) (h : x.toNat < 2 ^ (k - 1)) :
    extS k x = x := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [extS, BitVec.getLsbD_signExtend, BitVec.getLsbD_setWidth, BitVec.msb_setWidth]
  have hb : ∀ j, k - 1 ≤ j → x.getLsbD j = false := by
    intro j hj
    simp only [BitVec.getLsbD, Nat.testBit]
    have : x.toNat >>> j = 0 := by
      rw [Nat.shiftRight_eq_div_pow]
      apply Nat.div_eq_of_lt
      exact Nat.lt_of_lt_of_le h (pow_mono hj)
    simp [this]
  by_cases h' : i < k
  · simp [h', hi]
  · have e1 : x.getLsbD (k - 1) = false := hb (k - 1) (by omega)
    have e2 : x.getLsbD i = false := hb i (by omega)
    have e1' := e1
    simp only [BitVec.getLsbD_eq_getElem hi, BitVec.getLsbD_eq_getElem (show k - 1 < 64 by omega)] at e1' e2
    simp [h', hi, e1, e2, show 0 < k by omega]

theorem extU_of_lt (k : Nat) (hk : k ≤ 64) (x : BitVec 64) (h : x.toNat < 2 ^ k) : extU k x = x := by
  apply BitVec.eq_of_toNat_eq
  rw [extU_toNat k hk, Nat.mod_eq_of_lt h]

theorem extU_toNat_le (k : Nat) (hk : k ≤ 64) (x : BitVec 64) : (extU k x).toNat ≤ x.toNat := by
  rw [extU_toNat k hk]; exact Nat.mod_le _ _

theorem extU_lt (k : Nat) (hk : k ≤ 64) (x : BitVec 64) : (extU k x).toNat < 2 ^ k := by
  rw [extU_toNat k hk]; exact Nat.mod_lt _ (Nat.two_pow_pos k)

theorem sshiftRight_of_lt (x : BitVec 64) (k : Nat) (h : x.toNat < 2 ^ 63) :
    x.sshiftRight k = x >>> k := by
  apply BitVec.sshiftRight_eq_of_msb_false
  rw [BitVec.msb_eq_decide]
  simp; omega

/-! ## `fits_bits`: an upper bound on the value of a `W` node -/

/-- `fits_bits vg v w` proves that `v` is a valid `W` node whose value is below
`2^w` (in every environment). -/
theorem fits_bits_sound (vg : ValGraph) (hd : ValGraphDAG vg) :
    ∀ v w r, fits_bits vg v w = ok r → r = true →
      Valid vg v ∧ clsOf vg v = .W ∧ ∀ env, (evI vg env v).toNat < 2 ^ w.val.toNat := by
  refine fits_bits.fixpoint_induct vg
    (fun f => ∀ v w r, f v w = ok r → r = true →
      Valid vg v ∧ clsOf vg v = .W ∧ ∀ env, (evI vg env v).toNat < 2 ^ w.val.toNat)
    (adm2 _) ?_
  intro f ih v w r h hr
  obtain ⟨b, hb, h⟩ := bind_eq_ok h
  obtain ⟨hb1, hb2⟩ := vg_valid_ok hb
  cases b with
  | false =>
    simp only [Bool.not_false, ↓reduceIte] at h
    rw [← ok_inj' h] at hr; cases hr
  | true =>
  have hv := hb1.1 rfl
  have hl := hb2 rfl
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte, vg_cls_eq hl, bind_ok] at h
  split at h
  · rw [← ok_inj' h] at hr; cases hr
  rename_i hW
  have hW' := bne_W hW
  refine ⟨hv, hW', fun env => ?_⟩
  have hlt := evI_ltW hd env hv hW'
  split at h
  · rename_i hw
    have hw' : 32 ≤ w.val := hw
    exact Nat.lt_of_lt_of_le hlt (pow_mono (by omega))
  rename_i hw32
  have hw32' : w.val < 32 := by simpa [i32_ge_iff] using hw32
  split at h
  · simp only [vg_is_const_eq hl, bind_ok] at h
    rw [← ok_inj' h] at hr
    rw [constOf_evI hd env (of_decide_eq_true hr)]
    simp
  rename_i hw0
  have hw0' : 0 < w.val := by simpa [i32_le_iff] using hw0
  simp only [nodes_get_eq hv, bind_ok] at h
  have hnode := valid_nodeAt hv
  generalize vg.nodes.val[v.val.toNat]'hv.2 = nd at h hnode
  have hev := evI_node hd env hnode
  have hcls := clsOf_node hnode
  rw [hW'] at hcls
  cases nd with
  | SConst c x =>
    obtain ⟨t, ht, h⟩ := bind_eq_ok h
    obtain ⟨_, _, htv⟩ := shr_i32_ok ht
    rw [← ok_inj' h] at hr
    have h0 : x.bv >>> w.val.toNat = 0 := by
      rw [← htv]
      have := (beq_iff_eq).1 hr
      rw [this]; rfl
    have hx : x.bv.toNat < 2 ^ w.val.toNat := by
      apply nat_lt_pow_of_shr
      have := congrArg BitVec.toNat h0
      simpa [BitVec.toNat_ushiftRight] using this
    rw [hev]
    exact Nat.lt_of_le_of_lt (maskC_toNat_le c x.bv) hx
  | SBin c op a b =>
    simp only [nodeCls] at hcls
    subst hcls
    have ⟨hva, hvb⟩ := child_bin hd hnode
    rw [hev]
    simp only [evalNode]
    obtain ⟨ic, hic, h⟩ := bind_eq_ok h
    split at h
    · rename_i hcmp
      subst hcmp
      exact Nat.lt_of_le_of_lt (evalBin_cmp_le _ _ _ _ hic) (Nat.one_lt_two_pow (by omega))
    rename_i hcmp
    have hxa : (maskC .W (evI vg env a)).toNat < 2 ^ 32 := maskW_lt _
    have hne : ∀ r', (ok r' : Result Bool) = ok ic → r' = true → False := by
      intro r' e e'; subst e'; exact hcmp (ok_inj' e).symm
    cases op with
    | CEq _ => exact (hne _ hic rfl).elim
    | CNe _ => exact (hne _ hic rfl).elim
    | CSlt _ => exact (hne _ hic rfl).elim
    | CSle _ => exact (hne _ hic rfl).elim
    | CSgt _ => exact (hne _ hic rfl).elim
    | CSge _ => exact (hne _ hic rfl).elim
    | CUlt _ => exact (hne _ hic rfl).elim
    | CUle _ => exact (hne _ hic rfl).elim
    | CUgt _ => exact (hne _ hic rfl).elim
    | CUge _ => exact (hne _ hic rfl).elim
    | Add => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | Sub => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | Mul => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | Shl => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | Ror => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | Div => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | UDiv => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | Rem => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | URem => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | And =>
      simp only at h
      simp only [evalBin, Option.getD_some, BitVec.toNat_and]
      obtain ⟨t8, h8, h⟩ := bind_eq_ok h
      split at h
      · rename_i ht8
        have := (ih a w t8 h8 ht8).2.2 env
        exact Nat.lt_of_le_of_lt (Nat.le_trans Nat.and_le_left (maskC_toNat_le _ _)) this
      · obtain ⟨t9, h9, h⟩ := bind_eq_ok h
        rw [← ok_inj' h] at hr
        have := (ih b w t9 h9 hr).2.2 env
        exact Nat.lt_of_le_of_lt (Nat.le_trans Nat.and_le_right (maskC_toNat_le _ _)) this
    | Or =>
      simp only at h
      simp only [evalBin, Option.getD_some, BitVec.toNat_or]
      obtain ⟨t8, h8, h⟩ := bind_eq_ok h
      split at h
      · rename_i ht8
        obtain ⟨t9, h9, h⟩ := bind_eq_ok h
        rw [← ok_inj' h] at hr
        have h1 := (ih a w t8 h8 ht8).2.2 env
        have h2 := (ih b w t9 h9 hr).2.2 env
        exact Nat.or_lt_two_pow (Nat.lt_of_le_of_lt (maskC_toNat_le _ _) h1)
          (Nat.lt_of_le_of_lt (maskC_toNat_le _ _) h2)
      · rw [← ok_inj' h] at hr; cases hr
    | Xor =>
      simp only at h
      simp only [evalBin, Option.getD_some, BitVec.toNat_xor]
      obtain ⟨t8, h8, h⟩ := bind_eq_ok h
      split at h
      · rename_i ht8
        obtain ⟨t9, h9, h⟩ := bind_eq_ok h
        rw [← ok_inj' h] at hr
        have h1 := (ih a w t8 h8 ht8).2.2 env
        have h2 := (ih b w t9 h9 hr).2.2 env
        exact Nat.xor_lt_two_pow (Nat.lt_of_le_of_lt (maskC_toNat_le _ _) h1)
          (Nat.lt_of_le_of_lt (maskC_toNat_le _ _) h2)
      · rw [← ok_inj' h] at hr; cases hr
    | Shr =>
      simp only [vg_const_eq hl, bind_ok] at h
      simp only [evalBin, Option.getD_some, BitVec.toNat_ushiftRight]
      cases hk : constOf vg b with
      | none =>
        simp only [hk, Option.map_none] at h
        obtain ⟨t, ht, h⟩ := bind_eq_ok h
        rw [← ok_inj' h] at hr
        have h1 := (ih a w t ht hr).2.2 env
        exact Nat.lt_of_le_of_lt (Nat.le_trans (Nat.shiftRight_le _ _) (maskC_toNat_le _ _)) h1
      | some y =>
        simp only [hk, Option.map_some] at h
        have hy := constOf_evI hd env hk
        have hK : (Pion.U64.to_int (Pion.U64.band (⟨y⟩ : Std.U64) 31#u64)).val = (y.toNat % 32 : Nat) :=
          saI_val .W ⟨y⟩
        have hK32 : y.toNat % 32 < 32 := Nat.mod_lt _ (by norm_num)
        have hwk := i32_add_val w (Pion.U64.to_int (Pion.U64.band (⟨y⟩ : Std.U64) 31#u64))
          (by rw [hK]; omega) (by rw [hK]; omega)
        rw [hK] at hwk
        rw [hy]
        simp only [shAmt]
        split at h
        · rename_i hc
          simp only [Bool.and_eq_true, decide_eq_true_eq, i32_gt_iff, i32_ge_iff, hK, hwk,
            i32_zero_val, i32_32_val] at hc
          apply shr_lt
          exact Nat.lt_of_lt_of_le (maskW_lt _) (pow_mono (by omega))
        · obtain ⟨t, ht, h⟩ := bind_eq_ok h
          rw [← ok_inj' h] at hr
          have h1 := (ih a _ t ht hr).2.2 env
          apply shr_lt
          refine Nat.lt_of_le_of_lt (maskC_toNat_le _ _) (Nat.lt_of_lt_of_le h1 (pow_mono ?_))
          split <;> rename_i hlt <;> simp only [i32_lt_iff, hwk, i32_32_val] at hlt ⊢ <;> omega
    | Sar =>
      simp only [vg_const_eq hl, bind_ok] at h
      simp only [evalBin, Option.getD_some, asS]
      cases hk : constOf vg b with
      | none =>
        simp only [hk, Option.map_none] at h
        obtain ⟨t, ht, h⟩ := bind_eq_ok h
        rw [← ok_inj' h] at hr
        have h1 := (ih a w t ht hr).2.2 env
        have hx : (maskC .W (evI vg env a)).toNat < 2 ^ w.val.toNat :=
          Nat.lt_of_le_of_lt (maskC_toNat_le _ _) h1
        have hx31 : (maskC .W (evI vg env a)).toNat < 2 ^ 31 :=
          Nat.lt_of_lt_of_le hx (pow_mono (by omega))
        rw [extS32_of_lt _ hx31, sshiftRight_of_lt _ _ (by omega), maskW_of_lt _ (by
          rw [BitVec.toNat_ushiftRight]
          exact Nat.lt_of_le_of_lt (Nat.shiftRight_le _ _) (maskW_lt _))]
        rw [BitVec.toNat_ushiftRight]
        exact Nat.lt_of_le_of_lt (Nat.shiftRight_le _ _) hx
      | some y =>
        simp only [hk, Option.map_some] at h
        have hy := constOf_evI hd env hk
        have hK : (Pion.U64.to_int (Pion.U64.band (⟨y⟩ : Std.U64) 31#u64)).val = (y.toNat % 32 : Nat) :=
          saI_val .W ⟨y⟩
        have hK32 : y.toNat % 32 < 32 := Nat.mod_lt _ (by norm_num)
        have hwk := i32_add_val w (Pion.U64.to_int (Pion.U64.band (⟨y⟩ : Std.U64) 31#u64))
          (by rw [hK]; omega) (by rw [hK]; omega)
        rw [hK] at hwk
        obtain ⟨t, ht, h⟩ := bind_eq_ok h
        rw [← ok_inj' h] at hr
        have h1 := (ih a _ t ht hr).2.2 env
        have hm : ∀ z : Std.I32, z = (if Pion.I32.add w (Pion.U64.to_int (Pion.U64.band (⟨y⟩ : Std.U64) 31#u64)) < 31#i32
            then Pion.I32.add w (Pion.U64.to_int (Pion.U64.band (⟨y⟩ : Std.U64) 31#u64)) else 31#i32) →
            z.val.toNat ≤ w.val.toNat + y.toNat % 32 ∧ z.val.toNat ≤ 31 := by
          intro z hz; subst hz
          split <;> rename_i hlt <;> simp only [i32_lt_iff, hwk, i32_31_val] at hlt ⊢ <;> omega
        have hm' := hm _ rfl
        have hx : (maskC .W (evI vg env a)).toNat < 2 ^ (w.val.toNat + y.toNat % 32) :=
          Nat.lt_of_le_of_lt (maskC_toNat_le _ _) (Nat.lt_of_lt_of_le h1 (pow_mono hm'.1))
        have hx31 : (maskC .W (evI vg env a)).toNat < 2 ^ 31 :=
          Nat.lt_of_le_of_lt (maskC_toNat_le _ _) (Nat.lt_of_lt_of_le h1 (pow_mono hm'.2))
        rw [hy]
        simp only [shAmt]
        rw [extS32_of_lt _ hx31, sshiftRight_of_lt _ _ (by omega), maskW_of_lt _ (by
          rw [BitVec.toNat_ushiftRight]
          exact Nat.lt_of_le_of_lt (Nat.shiftRight_le _ _) (maskW_lt _))]
        rw [BitVec.toNat_ushiftRight]
        exact shr_lt hx
  | SUn c op x =>
    simp only [nodeCls] at hcls
    subst hcls
    have hvx := child_un hd hnode
    rw [hev]
    simp only [evalNode]
    cases op with
    | ExtUB =>
      simp only at h
      simp only [evalUn]
      split at h
      · rename_i hw8
        have : 8 ≤ w.val := hw8
        rw [maskW_of_lt _ (Nat.lt_of_lt_of_le (extU_lt 8 (by norm_num) _) (by norm_num))]
        exact Nat.lt_of_lt_of_le (extU_lt 8 (by norm_num) _) (pow_mono (by omega))
      · obtain ⟨t, ht, h⟩ := bind_eq_ok h
        rw [← ok_inj' h] at hr
        have h1 := (ih x w t ht hr).2.2 env
        exact Nat.lt_of_le_of_lt (Nat.le_trans (maskC_toNat_le _ _) (extU_toNat_le 8 (by norm_num) _)) h1
    | ExtUH =>
      simp only at h
      simp only [evalUn]
      split at h
      · rename_i hw8
        have : 16 ≤ w.val := hw8
        rw [maskW_of_lt _ (Nat.lt_of_lt_of_le (extU_lt 16 (by norm_num) _) (by norm_num))]
        exact Nat.lt_of_lt_of_le (extU_lt 16 (by norm_num) _) (pow_mono (by omega))
      · obtain ⟨t, ht, h⟩ := bind_eq_ok h
        rw [← ok_inj' h] at hr
        have h1 := (ih x w t ht hr).2.2 env
        exact Nat.lt_of_le_of_lt (Nat.le_trans (maskC_toNat_le _ _) (extU_toNat_le 16 (by norm_num) _)) h1
    | ExtSB =>
      simp only at h
      simp only [evalUn]
      obtain ⟨t, ht, h⟩ := bind_eq_ok h
      rw [← ok_inj' h] at hr
      have h1 := (ih x _ t ht hr).2.2 env
      have hm : (if w < 7#i32 then w else 7#i32).val.toNat ≤ w.val.toNat ∧
          (if w < 7#i32 then w else 7#i32).val.toNat ≤ 7 := by
        split <;> rename_i hlt <;> simp only [i32_lt_iff, i32_7_val] at hlt ⊢ <;> omega
      have hx : (evI vg env x).toNat < 2 ^ 7 := Nat.lt_of_lt_of_le h1 (pow_mono hm.2)
      rw [extS_of_lt 8 (by norm_num) (by norm_num) _ hx]
      exact Nat.lt_of_le_of_lt (maskC_toNat_le _ _) (Nat.lt_of_lt_of_le h1 (pow_mono hm.1))
    | ExtSH =>
      simp only at h
      simp only [evalUn]
      obtain ⟨t, ht, h⟩ := bind_eq_ok h
      rw [← ok_inj' h] at hr
      have h1 := (ih x _ t ht hr).2.2 env
      have hm : (if w < 15#i32 then w else 15#i32).val.toNat ≤ w.val.toNat ∧
          (if w < 15#i32 then w else 15#i32).val.toNat ≤ 15 := by
        split <;> rename_i hlt <;> simp only [i32_lt_iff, i32_15_val] at hlt ⊢ <;> omega
      have hx : (evI vg env x).toNat < 2 ^ 15 := Nat.lt_of_lt_of_le h1 (pow_mono hm.2)
      rw [extS_of_lt 16 (by norm_num) (by norm_num) _ hx]
      exact Nat.lt_of_le_of_lt (maskC_toNat_le _ _) (Nat.lt_of_lt_of_le h1 (pow_mono hm.1))
    | Copy => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | Neg => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | ExtSW => simp only at h; rw [← ok_inj' h] at hr; cases hr
    | ExtUW => simp only at h; rw [← ok_inj' h] at hr; cases hr
  | SSym _ => simp only at h; rw [← ok_inj' h] at hr; cases hr
  | SParam _ _ => simp only at h; rw [← ok_inj' h] at hr; cases hr
  | SPhi _ _ _ => simp only at h; rw [← ok_inj' h] at hr; cases hr
  | SEffect _ _ _ => simp only at h; rw [← ok_inj' h] at hr; cases hr

theorem is_bool_node_sound {vg : ValGraph} (hd : ValGraphDAG vg) {v : Std.I32}
    (h : is_bool_node vg v = ok true) :
    Valid vg v ∧ clsOf vg v = .W ∧ ∀ env, (evI vg env v).toNat < 2 := by
  unfold is_bool_node at h
  obtain ⟨t, ht, h⟩ := bind_eq_ok h
  have := ok_inj' h
  subst this
  have := fits_bits_sound vg hd v 1#i32 true ht rfl
  simpa using this

/-! ## Results of the canonicalising functions -/

/-- `r` is a valid node of class `cls` of a DAG extending `vg`, with value `val`. -/
def CanonOut (vg vg' : ValGraph) (r : Std.I32) (cls : Cls) (val : SymEnv → BitVec 64) : Prop :=
  vg_extends vg vg' ∧ ValGraphDAG vg' ∧ Valid vg' r ∧ clsOf vg' r = cls ∧
    ∀ env, evI vg' env r = val env

theorem out_refl {vg : ValGraph} (hd : ValGraphDAG vg) {r : Std.I32} {cls : Cls}
    {val : SymEnv → BitVec 64} (hv : Valid vg r) (hc : clsOf vg r = cls)
    (hval : ∀ env, evI vg env r = val env) : CanonOut vg vg r cls val :=
  ⟨vg_extends_refl _, hd, hv, hc, hval⟩

theorem out_konst {vg vg' : ValGraph} (hd : ValGraphDAG vg) {c : Cls} {x : Std.U64} {r : Std.I32}
    {val : SymEnv → BitVec 64} (hq : vg_konst vg c x = ok (r, vg'))
    (hval : ∀ env, maskC c x.bv = val env) : CanonOut vg vg' r c val := by
  obtain ⟨h1, h2, h3, h4, _, h6⟩ := konst_facts hd hq
  exact ⟨h1, h2, h3, h4, fun env => by rw [h6, hval]⟩

theorem out_intern {vg vg' : ValGraph} (hd : ValGraphDAG vg) {n : SymNode} {r : Std.I32}
    {val : SymEnv → BitVec 64} (hq : vg_intern vg n = ok (r, vg'))
    (hc : childrenBelow n vg.nodes.val.length)
    (hval : ∀ env, evalNode env (evI vg env) n = val env) : CanonOut vg vg' r (nodeCls n) val := by
  have hi := vg_intern_ok hq
  exact ⟨hi.1, intern_dag hd hc hi, intern_valid hi, intern_clsOf hi,
    fun env => by rw [intern_evI hd hc hi, hval]⟩

theorem out_weaken {vg0 vg1 vg2 : ValGraph} {r : Std.I32} {cls : Cls}
    {val val0 : SymEnv → BitVec 64} (h : CanonOut vg1 vg2 r cls val) (hp : vg_extends vg0 vg1)
    (hval : ∀ env, val env = val0 env) : CanonOut vg0 vg2 r cls val0 :=
  ⟨vg_extends_trans hp h.1, h.2.1, h.2.2.1, h.2.2.2.1, fun env => by rw [h.2.2.2.2, hval]⟩

theorem childrenBelow_un {vg : ValGraph} {c : Cls} {op : UnOp} {a : Std.I32} (h : Valid vg a) :
    childrenBelow (.SUn c op a) vg.nodes.val.length := h

theorem childrenBelow_bin {vg : ValGraph} {c : Cls} {op : BinOp} {a b : Std.I32} (ha : Valid vg a)
    (hb : Valid vg b) : childrenBelow (.SBin c op a b) vg.nodes.val.length := ⟨ha, hb⟩

/-! ## Unary operators -/

theorem evalUn_masked (cls : Cls) (op : UnOp) (v : BitVec 64) :
    maskC cls (evalUn cls op v) = evalUn cls op v := by
  cases op <;> simp only [evalUn, maskC_idem]

theorem maskC_low (c : Cls) (v : BitVec 64) (i : Nat) (hi : i < 32) :
    (maskC c v).getLsbD i = v.getLsbD i := by
  cases c
  · simp [maskC, zx32, lo32, hi, show i < 64 by omega]
  · rfl

theorem extS_low (k : Nat) (y : BitVec 64) (i : Nat) (hi : i < k) (hk : k ≤ 64) :
    (extS k y).getLsbD i = y.getLsbD i := by
  simp only [extS, BitVec.getLsbD_signExtend, BitVec.getLsbD_setWidth]
  simp [hi, show i < 64 by omega]

theorem extU_low (k : Nat) (y : BitVec 64) (i : Nat) (hi : i < k) (hk : k ≤ 64) :
    (extU k y).getLsbD i = y.getLsbD i := by
  simp [extU, hi, show i < 64 by omega]

/-- The number of low bits an extension reads (`unop_ext_bits`). -/
def extBits : UnOp → Nat
  | .ExtSB | .ExtUB => 8
  | .ExtSH | .ExtUH => 16
  | .ExtSW | .ExtUW => 32
  | _ => 0

theorem unop_ext_bits_spec (op : UnOp) : unop_ext_bits op = ok ⟨BitVec.ofNat 32 (extBits op)⟩ := by
  cases op <;> rfl

theorem setWidth_congr {x y : BitVec 64} {k : Nat} (h : ∀ i < k, x.getLsbD i = y.getLsbD i) :
    x.setWidth k = y.setWidth k := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [BitVec.getLsbD_setWidth, hi, decide_true, Bool.true_and]
  exact h i hi

/-- An extension reads only the low `extBits op` bits of its operand. -/
theorem evalUn_low (cls : Cls) (op : UnOp) (hop : 0 < extBits op) {x y : BitVec 64}
    (h : ∀ i < extBits op, x.getLsbD i = y.getLsbD i) : evalUn cls op x = evalUn cls op y := by
  cases op <;> simp only [extBits] at hop h <;> simp only [evalUn, extS, extU] <;>
    first | omega | rw [setWidth_congr h]

/-- An extension keeps the low `extBits op` bits (below 32) of its operand. -/
theorem evalUn_keeps_low (c : Cls) (op : UnOp) (y : BitVec 64) (i : Nat) (hi : i < extBits op) :
    (evalUn c op y).getLsbD i = y.getLsbD i := by
  cases op <;> simp only [extBits] at hi <;> simp only [evalUn] <;>
    first
    | omega
    | (rw [maskC_low _ _ _ (by omega)]
       first
       | exact extS_low _ _ _ hi (by norm_num)
       | exact extU_low _ _ _ hi (by norm_num))

theorem evalUn_absorb (cls c2 : Cls) (op op2 : UnOp) (hop : 0 < extBits op)
    (hk : extBits op ≤ extBits op2) (y : BitVec 64) :
    evalUn cls op (evalUn c2 op2 y) = evalUn cls op y :=
  evalUn_low cls op hop (fun i hi => evalUn_keeps_low c2 op2 y i (by omega))

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

theorem negneg (c : Cls) (x : BitVec 64) : maskC c (-(maskC c (-x))) = maskC c x := by
  cases c
  · simp only [maskC, lo32_neg, lo32_zx32, neg_neg]
  · simp [maskC]

theorem maskW_extS32 (x : BitVec 64) : maskC .W (extS 32 x) = maskC .W x := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  by_cases h : i < 32
  · rw [maskC_low _ _ _ h, maskC_low _ _ _ h, extS_low _ _ _ h (by norm_num)]
  · simp [maskC, zx32, lo32, BitVec.getLsbD_setWidth, h]

theorem maskW_extU32 (x : BitVec 64) : maskC .W (extU 32 x) = maskC .W x := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  by_cases h : i < 32
  · rw [maskC_low _ _ _ h, maskC_low _ _ _ h, extU_low _ _ _ h (by norm_num)]
  · simp [maskC, zx32, lo32, BitVec.getLsbD_setWidth, h]

/-- What `cls op a` needs of the class of `a`: a `copy`, and a 32-bit extension
to `W` (both return `a` itself), read `a` at class `cls` / `W`. -/
def UnArgOK (vg : ValGraph) (cls : Cls) (op : UnOp) (a : Std.I32) : Prop :=
  (op = .Copy → clsOf vg a = cls) ∧ (cls = .W → (op = .ExtSW ∨ op = .ExtUW) → clsOf vg a = .W)

theorem pair_ok {α β : Type} {m : Result (α × β)} {p : α × β}
    (h : (do let (x, y) ← m; ok (x, y)) = ok p) : m = ok p := by
  obtain ⟨q, hq, h⟩ := bind_eq_ok h
  obtain ⟨q1, q2⟩ := q
  have := ok_inj' h
  rw [hq, ← this]

def extSigned : UnOp → Bool
  | .ExtSB | .ExtSH | .ExtSW => true
  | _ => false

theorem unop_ext_signed_spec (op : UnOp) : unop_ext_signed op = ok (extSigned op) := by
  cases op <;> rfl

theorem ext_pos {op : UnOp} (h1 : op ≠ .Copy) (h2 : op ≠ .Neg) : 0 < extBits op := by
  cases op <;> simp_all [extBits]

theorem extBits_le (op : UnOp) : extBits op ≤ 32 := by
  cases op <;> simp [extBits]

theorem i32_ofNat_val (n : Nat) (h : n < 2 ^ 31) : (⟨BitVec.ofNat 32 n⟩ : Std.I32).val = n := by
  show (BitVec.ofNat 32 n).toInt = n
  rw [BitVec.toInt_eq_toNat_of_lt] <;> simp <;> omega

theorem extBits_val (op : UnOp) : (⟨BitVec.ofNat 32 (extBits op)⟩ : Std.I32).val = extBits op :=
  i32_ofNat_val _ (by have := extBits_le op; omega)

theorem evalUn_ext32W {op : UnOp} (h : extBits op = 32) (y : BitVec 64) :
    evalUn .W op y = maskC .W y := by
  cases op <;> simp [extBits] at h <;> simp only [evalUn, maskW_extS32, maskW_extU32]

theorem ext32_ops {op : UnOp} (h : extBits op = 32) : op = .ExtSW ∨ op = .ExtUW := by
  cases op <;> simp_all [extBits]

/-- `vendor/qbe/copy.c` `defwidthle`: a `W` value that already fits is its own extension. -/
theorem evalUn_fits {op : UnOp} (hop : 0 < extBits op) (hk : extBits op < 32) {y : BitVec 64}
    (hy : y.toNat < 2 ^ (if extSigned op then extBits op - 1 else extBits op))
    (hm : maskC .W y = y) : evalUn .W op y = y := by
  cases op <;> simp [extBits] at hop hk <;> simp only [extSigned, extBits, ↓reduceIte,
    Bool.false_eq_true] at hy <;> simp only [evalUn]
  · rw [extS_of_lt 8 (by norm_num) (by norm_num) _ hy, hm]
  · rw [extU_of_lt 8 (by norm_num) _ hy, hm]
  · rw [extS_of_lt 16 (by norm_num) (by norm_num) _ hy, hm]
  · rw [extU_of_lt 16 (by norm_num) _ hy, hm]

theorem beq_false_of_ne {α : Type} [BEq α] [LawfulBEq α] {a b : α} (h : a ≠ b) : (a == b) = false := by
  simp [h]

/-- `vg_canon_un vg cls op a` is a node with the value of `cls op a`. -/
theorem vg_canon_un_sound (vg : ValGraph) (cls : Cls) (op : UnOp) (hd : ValGraphDAG vg) :
    ∀ a p, vg_canon_un vg cls op a = ok p → Valid vg a → UnArgOK vg cls op a →
      CanonOut vg p.2 p.1 cls (fun env => evalUn cls op (evI vg env a)) := by
  refine vg_canon_un.fixpoint_induct vg cls op
    (fun f => ∀ a p, f a = ok p → Valid vg a → UnArgOK vg cls op a →
      CanonOut vg p.2 p.1 cls (fun env => evalUn cls op (evI vg env a))) (adm1 _) ?_
  intro f ih a p h0 hva hok
  obtain ⟨b, hb, h⟩ := bind_eq_ok h0
  clear h0
  obtain ⟨hb1, hb2⟩ := vg_valid_ok hb
  have hbt : b = true := hb1.2 hva
  subst hbt
  have hl := hb2 rfl
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte, vg_const_eq hl, bind_ok] at h
  cases hk : constOf vg a with
  | some x =>
    simp only [hk, Option.map_some, eval_un_const_sound, bind_ok] at h
    have hq := pair_ok h
    refine out_konst hd hq (fun env => ?_)
    rw [constOf_evI hd env hk]
    exact evalUn_masked cls op x
  | none =>
  simp only [hk, Option.map_none] at h
  have hnode := valid_nodeAt hva
  simp only [nodes_get_eq hva, bind_ok] at h
  generalize vg.nodes.val[a.val.toNat]'hva.2 = nd at h hnode
  have hev := fun env => evI_node hd env hnode
  have hcla := clsOf_node hnode
  by_cases hcp : op = .Copy
  · subst hcp
    simp only [beq_self_eq_true, ↓reduceIte] at h
    have := ok_inj' h; subst this
    refine out_refl hd hva (hok.1 rfl) (fun env => ?_)
    have hm := evI_masked hd env hva
    rw [hok.1 rfl] at hm
    simp only [evalUn, hm]
  have hb1 : (op == UnOp.Copy) = false := beq_false_of_ne hcp
  simp only [hb1, Bool.false_eq_true, ↓reduceIte] at h
  have hint : ∀ q, vg_intern vg (.SUn cls op a) = ok q →
      CanonOut vg q.2 q.1 cls (fun env => evalUn cls op (evI vg env a)) :=
    fun q hq => out_intern hd hq (childrenBelow_un hva) (fun env => rfl)
  by_cases hng : op = .Neg
  · subst hng
    simp only [beq_self_eq_true, ↓reduceIte, vg_cls_eq hl, bind_ok] at h
    obtain ⟨s, hs, h⟩ := bind_eq_ok h
    cases s with
    | inr u => exact hint _ (pair_ok h)
    | inl q =>
      have hq := ok_inj' h
      subst hq
      cases nd with
      | SUn c2 op2 x1 =>
        simp only at hs
        by_cases hc : c2 = cls ∧ op2 = .Neg ∧ clsOf vg x1 = cls
        · obtain ⟨hc1, hc2, hx⟩ := hc
          subst c2
          subst op2
          simp only [beq_self_eq_true, Bool.and_self, ↓reduceIte, bind_ok, hx] at hs
          have := ok_inj' hs
          simp only [Sum.inl.injEq] at this
          subst this
          have hvx := child_un hd hnode
          refine out_refl hd hvx hx (fun env => ?_)
          rw [hev env]
          simp only [evalNode, evalUn, negneg]
          have hm := evI_masked hd env hvx
          rw [hx] at hm
          exact hm.symm
        · exfalso
          split at hs
          · rename_i hc'
            simp only [Bool.and_eq_true, beq_iff_eq] at hc'
            simp only [bind_ok] at hs
            split at hs
            · rename_i hx
              simp only [beq_iff_eq] at hx
              exact hc ⟨hc'.1, hc'.2, hx⟩
            · have := ok_inj' hs; cases this
          · simp only [bind_ok, Bool.false_eq_true, ↓reduceIte] at hs
            have := ok_inj' hs; cases this
      | SConst _ _ => have := ok_inj' hs; cases this
      | SSym _ => have := ok_inj' hs; cases this
      | SParam _ _ => have := ok_inj' hs; cases this
      | SPhi _ _ _ => have := ok_inj' hs; cases this
      | SEffect _ _ _ => have := ok_inj' hs; cases this
      | SBin _ _ _ _ => have := ok_inj' hs; cases this
  have hb2' : (op == UnOp.Neg) = false := beq_false_of_ne hng
  have hop0 := ext_pos hcp hng
  have hopk := extBits_le op
  simp only [hb2', Bool.false_eq_true, ↓reduceIte, unop_ext_bits_spec, bind_ok] at h
  by_cases hk32c : extBits op = 32 ∧ cls = .W
  · obtain ⟨hk32', hcW0⟩ := hk32c
    have hcond : ((⟨BitVec.ofNat 32 (extBits op)⟩ : Std.I32) == 32#i32 && cls == Cls.W) = true := by
      simp only [Bool.and_eq_true, beq_iff_eq, hcW0, and_true]
      apply i32_ext'
      show BitVec.ofNat 32 (extBits op) = BitVec.ofNat 32 32
      rw [hk32']
    rw [ite_t hcond] at h
    have := ok_inj' h; subst this
    have hcW := hok.2 hcW0 (ext32_ops hk32')
    refine out_refl hd hva (by rw [hcW, hcW0]) (fun env => ?_)
    rw [hcW0, evalUn_ext32W hk32', evI_maskW hd env hva hcW]
  have hcond : ¬ ((⟨BitVec.ofNat 32 (extBits op)⟩ : Std.I32) == 32#i32 && cls == Cls.W) = true := by
    intro hc
    apply hk32c
    simp only [Bool.and_eq_true, beq_iff_eq] at hc
    refine ⟨?_, hc.2⟩
    have := congrArg (fun z : Std.I32 => z.val) hc.1
    simp only [extBits_val, i32_32_val] at this
    omega
  rw [ite_f hcond] at h
  obtain ⟨s1, hs1, h⟩ := bind_eq_ok h
  have key : ∀ q, s1 = .inl q →
      CanonOut vg q.2 q.1 cls (fun env => evalUn cls op (evI vg env a)) := by
    intro q hq
    subst hq
    cases nd with
    | SUn c2 op2 x2 =>
      simp only at hs1
      split at hs1
      · rename_i hk2
        have hk2' : extBits op ≤ extBits op2 := by
          have : (⟨BitVec.ofNat 32 (extBits op)⟩ : Std.I32).val ≤
              (⟨BitVec.ofNat 32 (extBits op2)⟩ : Std.I32).val := hk2
          rw [extBits_val, extBits_val] at this
          omega
        simp only [vg_cls_eq hl, bind_ok] at hs1
        split at hs1
        · rename_i hx2
          simp only [beq_iff_eq] at hx2
          have hvx := child_un hd hnode
          split at hs1
          · rename_i heq
            simp only [Bool.and_eq_true, beq_iff_eq] at heq
            obtain ⟨he1, he2⟩ := heq
            subst op2
            subst c2
            have := ok_inj' hs1
            simp only [Sum.inl.injEq] at this
            subst this
            refine out_refl hd hva hcla (fun env => ?_)
            rw [hev env]
            simp only [evalNode]
            exact (evalUn_absorb cls cls op op hop0 (le_refl _) _).symm
          · obtain ⟨q2, hq2, hs1⟩ := bind_eq_ok hs1
            obtain ⟨r3, vg3⟩ := q2
            have := ok_inj' hs1
            simp only [Sum.inl.injEq] at this
            subst this
            have hok2 : UnArgOK vg cls op x2 := ⟨fun e => absurd e hcp, fun _ _ => hx2⟩
            have := ih x2 _ hq2 hvx hok2
            refine out_weaken this (vg_extends_refl _) (fun env => ?_)
            rw [hev env]
            simp only [evalNode]
            exact (evalUn_absorb cls c2 op op2 hop0 hk2' _).symm
        · have := ok_inj' hs1; cases this
      · try simp only [bind_ok, Bool.false_eq_true, ↓reduceIte] at hs1
        have := ok_inj' hs1; cases this
    | SConst _ _ => have := ok_inj' hs1; cases this
    | SSym _ => have := ok_inj' hs1; cases this
    | SParam _ _ => have := ok_inj' hs1; cases this
    | SPhi _ _ _ => have := ok_inj' hs1; cases this
    | SEffect _ _ _ => have := ok_inj' hs1; cases this
    | SBin _ _ _ _ => have := ok_inj' hs1; cases this
  have key2 : ∀ g, s1 = .inr g → g = vg := by
    intro g hg
    subst hg
    cases nd with
    | SUn c2 op2 x2 =>
      simp only at hs1
      split at hs1
      · simp only [vg_cls_eq hl, bind_ok] at hs1
        split at hs1
        · split at hs1
          · have := ok_inj' hs1; cases this
          · obtain ⟨q2, hq2, hs1⟩ := bind_eq_ok hs1
            have := ok_inj' hs1; cases this
        · have := ok_inj' hs1; simp only [Sum.inr.injEq] at this; exact this.symm
      · try simp only [bind_ok, Bool.false_eq_true, ↓reduceIte] at hs1
        have := ok_inj' hs1; simp only [Sum.inr.injEq] at this; exact this.symm
    | SConst _ _ => have := ok_inj' hs1; simp only [Sum.inr.injEq] at this; exact this.symm
    | SSym _ => have := ok_inj' hs1; simp only [Sum.inr.injEq] at this; exact this.symm
    | SParam _ _ => have := ok_inj' hs1; simp only [Sum.inr.injEq] at this; exact this.symm
    | SPhi _ _ _ => have := ok_inj' hs1; simp only [Sum.inr.injEq] at this; exact this.symm
    | SEffect _ _ _ => have := ok_inj' hs1; simp only [Sum.inr.injEq] at this; exact this.symm
    | SBin _ _ _ _ => have := ok_inj' hs1; simp only [Sum.inr.injEq] at this; exact this.symm
  cases s1 with
  | inl q =>
    have := ok_inj' h; subst this
    exact key q rfl
  | inr g =>
    have hg := key2 g rfl
    subst g
    obtain ⟨s2, hs2, h2⟩ := bind_eq_ok h
    clear h
    cases s2 with
    | inr u => exact hint _ (pair_ok h2)
    | inl q =>
      have := ok_inj' h2; subst this
      split at hs2
      · rename_i hW
        try simp only [beq_iff_eq] at hW
        have hlt32 : extBits op < 32 := by
          by_contra hge
          exact hk32c ⟨by omega, hW⟩
        simp only [unop_ext_signed_spec, bind_ok] at hs2
        split at hs2
        · rename_i hsg
          obtain ⟨t, ht, hs2⟩ := bind_eq_ok hs2
          split at hs2
          · rename_i htt
            have := ok_inj' hs2
            simp only [Sum.inl.injEq] at this
            subst this
            have hsub := i32_sub_val ⟨BitVec.ofNat 32 (extBits op)⟩ 1#i32
              (by rw [extBits_val]; simp; omega) (by rw [extBits_val]; simp; omega)
            rw [extBits_val] at hsub
            simp only [i32_one_val] at hsub
            obtain ⟨hv', hc', hbound⟩ := fits_bits_sound vg hd a _ t ht htt
            refine out_refl hd hva (by rw [hc', hW]) (fun env => ?_)
            have hb := hbound env
            rw [hsub] at hb
            have hy : (evI vg env a).toNat <
                2 ^ (if extSigned op then extBits op - 1 else extBits op) := by
              simp only [hsg, ↓reduceIte]
              exact Nat.lt_of_lt_of_le hb (pow_mono (by omega))
            rw [hW]
            exact (evalUn_fits hop0 hlt32 hy (evI_maskW hd env hva hc')).symm
          · have := ok_inj' hs2; cases this
        · rename_i hsg
          obtain ⟨t, ht, hs2⟩ := bind_eq_ok hs2
          split at hs2
          · rename_i htt
            have := ok_inj' hs2
            simp only [Sum.inl.injEq] at this
            subst this
            obtain ⟨hv', hc', hbound⟩ := fits_bits_sound vg hd a _ t ht htt
            refine out_refl hd hva (by rw [hc', hW]) (fun env => ?_)
            have hb := hbound env
            rw [extBits_val] at hb
            have hy : (evI vg env a).toNat <
                2 ^ (if extSigned op then extBits op - 1 else extBits op) := by
              simp only [hsg, Bool.false_eq_true, ↓reduceIte]
              exact Nat.lt_of_lt_of_le hb (pow_mono (by omega))
            rw [hW]
            exact (evalUn_fits hop0 hlt32 hy (evI_maskW hd env hva hc')).symm
          · have := ok_inj' hs2; cases this
      · have := ok_inj' hs2; cases this

/-! ## Binary operators: algebra of `evalBin` -/

theorem lo32_add (a b : BitVec 64) : lo32 (a + b) = lo32 a + lo32 b := by
  apply BitVec.eq_of_toNat_eq
  simp only [lo32, BitVec.toNat_setWidth, BitVec.toNat_add]
  rw [Nat.mod_mod_of_dvd _ (by norm_num : 2 ^ 32 ∣ 2 ^ 64), Nat.add_mod]

theorem lo32_mul (a b : BitVec 64) : lo32 (a * b) = lo32 a * lo32 b := by
  apply BitVec.eq_of_toNat_eq
  simp only [lo32, BitVec.toNat_setWidth, BitVec.toNat_mul]
  rw [Nat.mod_mod_of_dvd _ (by norm_num : 2 ^ 32 ∣ 2 ^ 64), Nat.mul_mod]

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

/-- `add sub mul and or xor`. -/
def isRing : BinOp → Bool
  | .Add | .Sub | .Mul | .And | .Or | .Xor => true
  | _ => false

/-- The operator on `n`-bit words. -/
def ringOp {n : Nat} : BinOp → BitVec n → BitVec n → BitVec n
  | .Add => (· + ·)
  | .Sub => (· - ·)
  | .Mul => (· * ·)
  | .And => (· &&& ·)
  | .Or => (· ||| ·)
  | .Xor => (· ^^^ ·)
  | _ => fun x _ => x

/-- A ring operator at class `cls`: on the low halves for `W`. -/
def liftC (op : BinOp) : Cls → BitVec 64 → BitVec 64 → BitVec 64
  | .W, x, y => zx32 (ringOp op (lo32 x) (lo32 y))
  | .L, x, y => ringOp op x y

theorem evalBin_ring {op : BinOp} (h : isRing op = true) (cls : Cls) (x y : BitVec 64) :
    evalBin cls op x y = some (liftC op cls x y) := by
  cases cls <;> cases op <;> simp [isRing] at h <;>
    simp only [evalBin, liftC, ringOp, maskC, lo32_add, lo32_sub, lo32_mul, lo32_zx32, zx32_and,
      zx32_or, zx32_xor]

theorem liftC_masked (op : BinOp) (cls : Cls) (x y : BitVec 64) :
    maskC cls (liftC op cls x y) = liftC op cls x y := by
  cases cls <;> simp [liftC, maskC, lo32_zx32]

theorem liftC_maskL (op : BinOp) (cls : Cls) (x y : BitVec 64) :
    liftC op cls (maskC cls x) y = liftC op cls x y := by
  cases cls <;> simp [liftC, maskC, lo32_zx32]

theorem liftC_maskR (op : BinOp) (cls : Cls) (x y : BitVec 64) :
    liftC op cls x (maskC cls y) = liftC op cls x y := by
  cases cls <;> simp [liftC, maskC, lo32_zx32]

def isComm : BinOp → Bool
  | .Add | .Mul | .And | .Or | .Xor | .CEq _ | .CNe _ => true
  | _ => false

theorem binop_commutes_spec (op : BinOp) : binop_commutes op = ok (isComm op) := by
  cases op <;> rfl

theorem evalBin_comm {op : BinOp} (h : isComm op = true) (cls : Cls) (x y : BitVec 64) :
    evalBin cls op x y = evalBin cls op y x := by
  cases op <;> simp [isComm] at h
  · rw [evalBin_ring rfl, evalBin_ring rfl]; cases cls <;> simp [liftC, ringOp, BitVec.add_comm]
  · rw [evalBin_ring rfl, evalBin_ring rfl]; cases cls <;> simp [liftC, ringOp, BitVec.mul_comm]
  · rw [evalBin_ring rfl, evalBin_ring rfl]; cases cls <;> simp [liftC, ringOp, BitVec.and_comm]
  · rw [evalBin_ring rfl, evalBin_ring rfl]; cases cls <;> simp [liftC, ringOp, BitVec.or_comm]
  · rw [evalBin_ring rfl, evalBin_ring rfl]; cases cls <;> simp [liftC, ringOp, BitVec.xor_comm]
  · simp only [evalBin]; congr 2; exact decide_eq_decide.2 eq_comm
  · simp only [evalBin]; congr 2; exact decide_eq_decide.2 (by constructor <;> exact Ne.symm)

def isAssoc : BinOp → Bool
  | .Add | .Mul | .And | .Or | .Xor => true
  | _ => false

theorem is_assoc_op_spec (op : BinOp) : is_assoc_op op = ok (isAssoc op) := by
  cases op <;> rfl

theorem isAssoc_ring {op : BinOp} (h : isAssoc op = true) : isRing op = true := by
  cases op <;> simp_all [isAssoc, isRing]

theorem ringOp_assoc {n : Nat} {op : BinOp} (h : isAssoc op = true) (x y z : BitVec n) :
    ringOp op (ringOp op x y) z = ringOp op x (ringOp op y z) := by
  cases op <;> simp [isAssoc] at h <;> simp only [ringOp]
  · exact BitVec.add_assoc x y z
  · exact BitVec.mul_assoc x y z
  · exact BitVec.and_assoc x y z
  · exact BitVec.or_assoc x y z
  · exact BitVec.xor_assoc x y z

theorem liftC_assoc {op : BinOp} (h : isAssoc op = true) (cls : Cls) (x y z : BitVec 64) :
    liftC op cls (liftC op cls x y) z = liftC op cls x (liftC op cls y z) := by
  cases cls
  · simp only [liftC, lo32_zx32]; rw [ringOp_assoc h]
  · simp only [liftC]; rw [ringOp_assoc h]

def isCmp : BinOp → Bool
  | .CEq _ | .CNe _ | .CSlt _ | .CSle _ | .CSgt _ | .CSge _ | .CUlt _ | .CUle _ | .CUgt _
  | .CUge _ => true
  | _ => false

theorem binop_is_cmp_spec (op : BinOp) : binop_is_cmp op = ok (isCmp op) := by
  cases op <;> rfl

def isShift : BinOp → Bool
  | .Shl | .Shr | .Sar | .Ror => true
  | _ => false

def swapCmp : BinOp → Option BinOp
  | .CSgt c => some (.CSlt c)
  | .CSge c => some (.CSle c)
  | .CUgt c => some (.CUlt c)
  | .CUge c => some (.CUle c)
  | _ => none

theorem swap_cmp_spec (op : BinOp) : swap_cmp op = ok (swapCmp op) := by
  cases op <;> rfl

theorem evalBin_swap {op o : BinOp} (h : swapCmp op = some o) (cls : Cls) (x y : BitVec 64) :
    evalBin cls op x y = evalBin cls o y x := by
  cases op <;> simp [swapCmp] at h <;> subst h <;> rfl

theorem swapCmp_cmp {op o : BinOp} (h : swapCmp op = some o) : isCmp o = true := by
  cases op <;> simp [swapCmp] at h <;> subst h <;> rfl

/-- The operand class of `cls op a, b` that `vg_canon_bin` relies on: both
operands of an arithmetic / bitwise operator, and the shifted operand of a
shift, have class `cls`; comparisons need nothing. -/
def BinArgOK (vg : ValGraph) (cls : Cls) (op : BinOp) (a b : Std.I32) : Prop :=
  if isCmp op then True
  else if isShift op then clsOf vg a = cls
  else clsOf vg a = cls ∧ clsOf vg b = cls

/-- `binop_arg_cls op cls 1`: the class at which the right operand is read. -/
def argCls1 (op : BinOp) (cls : Cls) : Cls :=
  match op with
  | .CEq c | .CNe c | .CSlt c | .CSle c | .CSgt c | .CSge c | .CUlt c | .CUle c | .CUgt c
  | .CUge c => c
  | .Shl | .Shr | .Sar | .Ror => .W
  | _ => cls

theorem binop_arg_cls_spec (op : BinOp) (cls : Cls) :
    binop_arg_cls op cls 1#i32 = ok (argCls1 op cls) := by
  cases op <;> simp [binop_arg_cls, binop_is_cmp, binop_cmp_cls, binop_is_shift, argCls1]

theorem binArgOK_comm {vg : ValGraph} {cls : Cls} {op : BinOp} (h : isComm op = true) {a b : Std.I32}
    (hok : BinArgOK vg cls op a b) : BinArgOK vg cls op b a := by
  cases op <;> simp [isComm] at h <;> simp_all [BinArgOK, isCmp, isShift]

theorem binArgOK_swap {vg : ValGraph} {cls : Cls} {op o : BinOp} (h : swapCmp op = some o)
    (a b : Std.I32) : BinArgOK vg cls o b a := by
  simp [BinArgOK, swapCmp_cmp h]

/-! ## `log2_exact` and `low_mask_bits` -/

@[simp] theorem i32_64_val : (64#i32 : Std.I32).val = 64 := by decide

def clsBitsN : Cls → Nat
  | .W => 32
  | .L => 64

theorem cls_bits_spec (c : Cls) : cls_bits c = ok ⟨BitVec.ofNat 32 (clsBitsN c)⟩ := by
  cases c <;> rfl

theorem shl1_ok {k : Std.I32} {t : Std.U64} (h : Pion.U64.shl_i32 1#u64 k = ok t) :
    0 ≤ k.val ∧ k.val < 64 ∧ t.bv = 1#64 <<< k.val.toNat := by
  unfold Pion.U64.shl_i32 at h
  split at h
  · rename_i hk
    rw [← ok_inj' h]
    exact ⟨hk.1, hk.2, rfl⟩
  · simp at h

theorem log2_exact_ok {c : Cls} {y : Std.U64} {k : Std.I32} (h : log2_exact c y = ok k)
    (hk : 0 < k.val) : y.bv = 1#64 <<< k.val.toNat ∧ k.val < clsBitsN c := by
  unfold log2_exact at h
  simp only [cls_bits_spec, bind_ok] at h
  obtain ⟨s, hs, h⟩ := bind_eq_ok h
  have hbits : (⟨BitVec.ofNat 32 (clsBitsN c)⟩ : Std.I32).val = clsBitsN c :=
    i32_ofNat_val _ (by cases c <;> simp [clsBitsN])
  have key := loop_ok_inv (fun k => log2_exact_loop0.body ⟨BitVec.ofNat 32 (clsBitsN c)⟩ y k)
    (fun k : Std.I32 => 1 ≤ k.val)
    (fun r => match r with
      | .inl k => y.bv = 1#64 <<< k.val.toNat ∧ k.val < clsBitsN c
      | .inr _ => True)
    (by
      intro k cf hk1 hc
      unfold log2_exact_loop0.body at hc
      split at hc
      · rename_i hlt
        have hlt' : k.val < clsBitsN c := by
          have : k.val < (⟨BitVec.ofNat 32 (clsBitsN c)⟩ : Std.I32).val := hlt
          rwa [hbits] at this
        obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
        obtain ⟨_, _, htv⟩ := shl1_ok ht
        split at hc
        · rename_i he
          rw [← ok_inj' hc]
          refine ⟨?_, hlt'⟩
          rw [← he, htv]
        · rw [← ok_inj' hc]
          show 1 ≤ (Pion.I32.add k 1#i32).val
          have : clsBitsN c ≤ 64 := by cases c <;> simp [clsBitsN]
          rw [i32_add_val k 1#i32 (by simp; omega) (by simp; omega)]
          simp; omega
      · rw [← ok_inj' hc]; trivial)
  have hp := key _ s hs (by simp)
  cases s with
  | inl k' =>
    have := ok_inj' h
    subst this
    exact hp
  | inr _ =>
    have := ok_inj' h
    subst this
    simp at hk

theorem low_mask_bits_ok {y : Std.U64} {n : Std.I32} (h : low_mask_bits y = ok n) (hn : 0 < n.val) :
    y.bv = (1#64 <<< n.val.toNat) - 1#64 ∧ n.val < 64 := by
  unfold low_mask_bits at h
  obtain ⟨s, hs, h⟩ := bind_eq_ok h
  have key := loop_ok_inv (fun n => low_mask_bits_loop0.body y n)
    (fun n : Std.I32 => 1 ≤ n.val)
    (fun r => match r with
      | .inl n => y.bv = (1#64 <<< n.val.toNat) - 1#64 ∧ n.val < 64
      | .inr _ => True)
    (by
      intro k cf hk1 hc
      unfold low_mask_bits_loop0.body at hc
      split at hc
      · rename_i hlt
        have hlt' : k.val < 64 := by simpa [i32_lt_iff] using hlt
        obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
        obtain ⟨_, _, htv⟩ := shl1_ok ht
        split at hc
        · rename_i he
          rw [← ok_inj' hc]
          refine ⟨?_, hlt'⟩
          rw [← he, sub_bv, htv]
          rfl
        · rw [← ok_inj' hc]
          show 1 ≤ (Pion.I32.add k 1#i32).val
          rw [i32_add_val k 1#i32 (by simp; omega) (by simp; omega)]
          simp; omega
      · rw [← ok_inj' hc]; trivial)
  have hp := key _ s hs (by simp)
  cases s with
  | inl k' =>
    have := ok_inj' h
    subst this
    exact hp
  | inr _ =>
    have := ok_inj' h
    subst this
    simp at hn

/-! ## `vg_canon_bin` / `canon_bin_rconst` -/

/-- What `vg_canon_bin vg cls op a b = ok p` guarantees. -/
def BinOut (vg : ValGraph) (p : Std.I32 × ValGraph) (cls : Cls) (op : BinOp) (a b : Std.I32) : Prop :=
  vg_extends vg p.2 ∧ ValGraphDAG p.2 ∧ Valid p.2 p.1 ∧ clsOf p.2 p.1 = cls ∧
    ∀ env v, evalBin cls op (evI vg env a) (evI vg env b) = some v → evI p.2 env p.1 = v

/-- What `canon_bin_rconst vg cls op a b y0 = ok p` guarantees (`p.1 < 0`: no rewrite). -/
def RconstOut (vg : ValGraph) (p : Std.I32 × ValGraph) (cls : Cls) (op : BinOp) (a b : Std.I32) :
    Prop :=
  vg_extends vg p.2 ∧ ValGraphDAG p.2 ∧
    (0 ≤ p.1.val → Valid p.2 p.1 ∧ clsOf p.2 p.1 = cls ∧
      ∀ env v, evalBin cls op (evI vg env a) (evI vg env b) = some v → evI p.2 env p.1 = v)

def BinMotive1 (cls : Cls) (f : ValGraph → BinOp → Std.I32 → Std.I32 → Result (Std.I32 × ValGraph)) :
    Prop :=
  ∀ vg op a b p, f vg op a b = ok p → ValGraphDAG vg → Valid vg a → Valid vg b →
    BinArgOK vg cls op a b → BinOut vg p cls op a b

def BinMotive2 (cls : Cls)
    (g : ValGraph → BinOp → Std.I32 → Std.I32 → Std.U64 → Result (Std.I32 × ValGraph)) : Prop :=
  ∀ vg op a b y0 p, g vg op a b y0 = ok p → ValGraphDAG vg → Valid vg a → Valid vg b →
    BinArgOK vg cls op a b → constOf vg b = some y0.bv → RconstOut vg p cls op a b

theorem binOut_refl {vg : ValGraph} (hd : ValGraphDAG vg) {r : Std.I32} {cls : Cls} {op : BinOp}
    {a b : Std.I32} (hv : Valid vg r) (hc : clsOf vg r = cls)
    (hval : ∀ env v, evalBin cls op (evI vg env a) (evI vg env b) = some v → evI vg env r = v) :
    BinOut vg (r, vg) cls op a b :=
  ⟨vg_extends_refl _, hd, hv, hc, hval⟩

theorem binOut_konst {vg vg' : ValGraph} (hd : ValGraphDAG vg) {c : Cls} {x : Std.U64}
    {r : Std.I32} {op : BinOp} {a b : Std.I32} (hq : vg_konst vg c x = ok (r, vg'))
    (hval : ∀ env v, evalBin c op (evI vg env a) (evI vg env b) = some v → maskC c x.bv = v) :
    BinOut vg (r, vg') c op a b := by
  obtain ⟨h1, h2, h3, h4, _, h6⟩ := konst_facts hd hq
  exact ⟨h1, h2, h3, h4, fun env v hv => by rw [h6]; exact hval env v hv⟩

/-- Moving a result along `vg ⊑ vg1` and an equation between the operations. -/
theorem binOut_weaken {vg vg1 : ValGraph} {p : Std.I32 × ValGraph} {cls : Cls} {op op' : BinOp}
    {a b a' b' : Std.I32} (h : BinOut vg1 p cls op' a' b') (hp : vg_extends vg vg1)
    (hsem : ∀ env, evalBin cls op (evI vg env a) (evI vg env b) =
      evalBin cls op' (evI vg1 env a') (evI vg1 env b')) : BinOut vg p cls op a b :=
  ⟨vg_extends_trans hp h.1, h.2.1, h.2.2.1, h.2.2.2.1,
    fun env v hv => h.2.2.2.2 env v (by rw [← hsem]; exact hv)⟩

theorem binOut_konst' {vg vg7 vg' : ValGraph} (e7 : vg_extends vg vg7) (hd7 : ValGraphDAG vg7)
    {c : Cls} {x : Std.U64} {r : Std.I32} {op : BinOp} {a b : Std.I32}
    (hq : vg_konst vg7 c x = ok (r, vg'))
    (hval : ∀ env v, evalBin c op (evI vg env a) (evI vg env b) = some v → maskC c x.bv = v) :
    BinOut vg (r, vg') c op a b := by
  obtain ⟨h1, h2, h3, h4, _, h6⟩ := konst_facts hd7 hq
  exact ⟨vg_extends_trans e7 h1, h2, h3, h4, fun env v hv => by rw [h6]; exact hval env v hv⟩

theorem ok_inl_ne_inr {α β : Type} {a : α} {b : β} (h : (ok (Sum.inl a) : Result (α ⊕ β)) = ok (.inr b)) :
    False := by
  have := ok_inj' h; cases this

theorem ok_inr_ne_inl {α β : Type} {a : α} {b : β} (h : (ok (Sum.inr b) : Result (α ⊕ β)) = ok (.inl a)) :
    False := by
  have := ok_inj' h; cases this

/-! ### The rewrites of `canon_bin_rconst` -/

theorem lo32_one : lo32 1#64 = 1#32 := by decide
theorem lo32_zero : lo32 0#64 = 0#32 := by decide

theorem rc_add0 {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = 0) (hx : maskC cls x = x) :
    evalBin cls .Add x y = some x := by
  rw [evalBin_ring rfl, ← liftC_maskR, hy]
  congr 1
  rw [← hx]; cases cls <;> simp [liftC, ringOp, maskC, lo32_zx32, lo32_zero]

theorem rc_xor0 {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = 0) (hx : maskC cls x = x) :
    evalBin cls .Xor x y = some x := by
  rw [evalBin_ring rfl, ← liftC_maskR, hy]
  congr 1
  rw [← hx]; cases cls <;> simp [liftC, ringOp, maskC, lo32_zx32, lo32_zero]

theorem rc_or0 {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = 0) (hx : maskC cls x = x) :
    evalBin cls .Or x y = some x := by
  rw [evalBin_ring rfl, ← liftC_maskR, hy]
  congr 1
  rw [← hx]; cases cls <;> simp [liftC, ringOp, maskC, lo32_zx32, lo32_zero]

theorem rc_mul0 {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = 0) :
    evalBin cls .Mul x y = some 0 := by
  rw [evalBin_ring rfl, ← liftC_maskR, hy]
  cases cls <;> simp [liftC, ringOp, lo32_zero, zx32]

theorem rc_and0 {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = 0) :
    evalBin cls .And x y = some 0 := by
  rw [evalBin_ring rfl, ← liftC_maskR, hy]
  cases cls <;> simp [liftC, ringOp, lo32_zero, zx32]

theorem rc_mul1 {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = 1) (hx : maskC cls x = x) :
    evalBin cls .Mul x y = some x := by
  rw [evalBin_ring rfl, ← liftC_maskR, hy]
  congr 1
  rw [← hx]; cases cls <;> simp [liftC, ringOp, maskC, lo32_zx32, lo32_one]

theorem allOnesW : allOnesC .W = 4294967295#64 := by decide
theorem allOnesL : allOnesC .L = -1#64 := by decide
theorem ones32 : (4294967295#32 : BitVec 32) = BitVec.allOnes 32 := by decide
theorem ones64 : (18446744073709551615#64 : BitVec 64) = BitVec.allOnes 64 := by decide
theorem sdiv_one' (x : BitVec 64) : x.sdiv 1 = x := BitVec.sdiv_one
theorem srem_one' (x : BitVec 64) : x.srem 1 = 0 := BitVec.srem_one
theorem udiv_one' (x : BitVec 64) : x / 1 = x := BitVec.udiv_one
theorem umod_one' (x : BitVec 64) : x % 1 = 0 := BitVec.umod_one
theorem extS32_one' : extS 32 (1 : BitVec 64) = 1 := by decide
theorem lo32_allOnesW : lo32 (allOnesC .W) = BitVec.allOnes 32 := by decide
theorem allOnesL' : allOnesC .L = BitVec.allOnes 64 := by decide
theorem zx32_allOnes : zx32 (BitVec.allOnes 32) = allOnesC .W := by decide

theorem one_ne_allOnes (c : Cls) : (1 : BitVec 64) ≠ allOnesC c := by cases c <;> decide

theorem rc_andOnes {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = allOnesC cls)
    (hx : maskC cls x = x) : evalBin cls .And x y = some x := by
  rw [evalBin_ring rfl, ← liftC_maskR, hy]
  congr 1
  rw [← hx]
  cases cls
  · simp only [liftC, ringOp, maskC, lo32_zx32, lo32_allOnesW, BitVec.and_allOnes]
  · simp only [liftC, ringOp, maskC, allOnesL', BitVec.and_allOnes]

theorem rc_orOnes {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = allOnesC cls) :
    evalBin cls .Or x y = some (allOnesC cls) := by
  rw [evalBin_ring rfl, ← liftC_maskR, hy]
  congr 1
  cases cls
  · simp only [liftC, ringOp, lo32_allOnesW, BitVec.or_allOnes, zx32_allOnes]
  · simp only [liftC, ringOp, allOnesL', BitVec.or_allOnes]

theorem rc_andLow {x y : BitVec 64} {n : Nat} (hy : maskC .W y = (1#64 <<< n) - 1#64)
    (hn : n < 64) (hx : x.toNat < 2 ^ n) (hxm : maskC .W x = x) :
    evalBin .W .And x y = some x := by
  simp only [evalBin, hy, hxm, Option.some.injEq]
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_and]
  have h1 : ((1#64 <<< n) - 1#64).toNat = 2 ^ n - 1 := by
    rw [BitVec.toNat_sub, BitVec.toNat_shiftLeft]
    simp only [BitVec.toNat_ofNat]
    have : 2 ^ n < 2 ^ 64 := Nat.pow_lt_pow_right (by norm_num : 1 < 2) hn
    rw [Nat.shiftLeft_eq, Nat.one_mul, Nat.mod_eq_of_lt this]
    have : 0 < 2 ^ n := Nat.two_pow_pos n
    omega
  rw [h1, Nat.and_two_pow_sub_one_eq_mod, Nat.mod_eq_of_lt hx]

theorem shAmt_maskW (cls : Cls) (v : BitVec 64) : shAmt cls (maskC .W v) = shAmt cls v := by
  cases cls <;> simp only [shAmt, maskW_toNat] <;> omega

theorem rc_shl0 {cls : Cls} {x y : BitVec 64} (hy : shAmt cls y = 0) (hx : maskC cls x = x) :
    evalBin cls .Shl x y = some x := by
  simp [evalBin, hy, hx]

theorem rc_shr0 {cls : Cls} {x y : BitVec 64} (hy : shAmt cls y = 0) (hx : maskC cls x = x) :
    evalBin cls .Shr x y = some x := by
  simp [evalBin, hy, hx]

theorem rc_sar0 {cls : Cls} {x y : BitVec 64} (hy : shAmt cls y = 0) (hx : maskC cls x = x) :
    evalBin cls .Sar x y = some x := by
  simp only [evalBin, hy, hx, BitVec.sshiftRight_zero, Option.some.injEq]
  cases cls
  · rw [asS, maskW_extS32, hx]
  · rfl

theorem rc_ror0 {cls : Cls} {x y : BitVec 64} (hy : shAmt cls y = 0) (hx : maskC cls x = x) :
    evalBin cls .Ror x y = some x := by
  simp [evalBin, hy, hx]

theorem extS32_one : extS 32 1#64 = 1#64 := by decide

theorem rc_div1 {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = 1) (hx : maskC cls x = x) :
    evalBin cls .Div x y = some x := by
  have hs : safeDiv cls .Div (maskC cls x) (maskC cls y) := by
    refine ⟨by rw [maskC_idem, hy]; decide, fun _ h1 => ?_⟩
    rw [maskC_idem, hy] at h1
    exact absurd h1 (one_ne_allOnes cls)
  simp only [evalBin]
  rw [ite_t hs, hy, hx]
  cases cls
  · simp only [asS, extS32_one', sdiv_one', maskW_extS32, hx]
  · simp only [asS, sdiv_one', maskC]

theorem rc_rem1 {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = 1) :
    evalBin cls .Rem x y = some 0 := by
  have hs : safeDiv cls .Rem (maskC cls x) (maskC cls y) := by
    refine ⟨by rw [maskC_idem, hy]; decide, fun _ h1 => ?_⟩
    rw [maskC_idem, hy] at h1
    exact absurd h1 (one_ne_allOnes cls)
  simp only [evalBin]
  rw [ite_t hs, hy]
  cases cls
  · simp only [asS, extS32_one', srem_one']; decide
  · simp only [asS, srem_one', maskC]

theorem rc_udiv1 {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = 1) (hx : maskC cls x = x) :
    evalBin cls .UDiv x y = some x := by
  have hs : safeDiv cls .UDiv (maskC cls x) (maskC cls y) :=
    ⟨by rw [maskC_idem, hy]; decide, fun h => by simp [signedDivOp] at h⟩
  simp only [evalBin]
  rw [ite_t hs, hy, hx, udiv_one']

theorem rc_urem1 {cls : Cls} {x y : BitVec 64} (hy : maskC cls y = 1) :
    evalBin cls .URem x y = some 0 := by
  have hs : safeDiv cls .URem (maskC cls x) (maskC cls y) :=
    ⟨by rw [maskC_idem, hy]; decide, fun h => by simp [signedDivOp] at h⟩
  simp only [evalBin]
  rw [ite_t hs, hy, umod_one']

theorem pow_toNat {k : Nat} (hk : k < 64) : (1#64 <<< k).toNat = 2 ^ k := by
  rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]
  simp only [BitVec.toNat_ofNat]
  rw [show 1 % 2 ^ 64 = 1 from rfl, Nat.one_mul]
  exact Nat.mod_eq_of_lt (Nat.pow_lt_pow_right (by norm_num : 1 < 2) hk)

theorem clsBitsN_le (c : Cls) : clsBitsN c ≤ 64 := by cases c <;> simp [clsBitsN]

theorem shAmt_ofNat {cls : Cls} {k : Nat} (hk : k < clsBitsN cls) :
    shAmt cls (BitVec.ofNat 64 k) = k := by
  have := clsBitsN_le cls
  cases cls <;> simp only [shAmt, clsBitsN] at hk ⊢ <;>
    rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega : k < 2 ^ 64), Nat.mod_eq_of_lt (by omega)]

theorem lo32_pow {k : Nat} : lo32 (1#64 <<< k) = BitVec.twoPow 32 k := by
  rw [BitVec.twoPow_eq]
  show (1#64 <<< k).setWidth 32 = 1#32 <<< k
  rw [BitVec.setWidth_shiftLeft_of_le (by norm_num)]
  rfl

theorem lo32_shl (z : BitVec 64) (k : Nat) : lo32 (z <<< k) = lo32 z <<< k :=
  BitVec.setWidth_shiftLeft_of_le (by norm_num)

theorem rc_mulpow {cls : Cls} {x y : BitVec 64} {k : Nat} (hy : maskC cls y = 1#64 <<< k)
    (hk : k < clsBitsN cls) :
    evalBin cls .Mul x y = evalBin cls .Shl x (BitVec.ofNat 64 k) := by
  rw [evalBin_ring rfl, ← liftC_maskR, hy]
  simp only [evalBin, shAmt_ofNat hk, Option.some.injEq]
  cases cls
  · simp only [liftC, ringOp, maskC]
    rw [lo32_pow, BitVec.mul_twoPow_eq_shiftLeft, lo32_shl, lo32_zx32]
  · simp only [liftC, ringOp, maskC]
    rw [← BitVec.twoPow_eq, BitVec.mul_twoPow_eq_shiftLeft]

theorem rc_udivpow {cls : Cls} {x y : BitVec 64} {k : Nat} (hy : maskC cls y = 1#64 <<< k)
    (hk : k < clsBitsN cls) :
    evalBin cls .UDiv x y = evalBin cls .Shr x (BitVec.ofNat 64 k) := by
  have hk64 := Nat.lt_of_lt_of_le hk (clsBitsN_le cls)
  have hne : (1#64 <<< k) ≠ 0 := by
    intro e; have := congrArg BitVec.toNat e; rw [pow_toNat hk64] at this; simp at this
  have hs : safeDiv cls .UDiv (maskC cls x) (maskC cls y) :=
    ⟨by rw [maskC_idem, hy]; exact hne, fun h => by simp [signedDivOp] at h⟩
  simp only [evalBin]
  rw [ite_t hs, hy, shAmt_ofNat hk, ← BitVec.twoPow_eq, BitVec.udiv_twoPow_eq_of_lt hk64]

theorem rc_urempow {cls : Cls} {x y : BitVec 64} {k : Nat} (hy : maskC cls y = 1#64 <<< k)
    (hk : k < clsBitsN cls) :
    evalBin cls .URem x y = evalBin cls .And x (maskC cls ((1#64 <<< k) - 1#64)) := by
  have hk64 := Nat.lt_of_lt_of_le hk (clsBitsN_le cls)
  have hne : (1#64 <<< k) ≠ 0 := by
    intro e; have := congrArg BitVec.toNat e; rw [pow_toNat hk64] at this; simp at this
  have hs : safeDiv cls .URem (maskC cls x) (maskC cls y) :=
    ⟨by rw [maskC_idem, hy]; exact hne, fun h => by simp [signedDivOp] at h⟩
  simp only [evalBin]
  rw [ite_t hs, hy, maskC_idem, Option.some.injEq]
  have hm : maskC cls ((1#64 <<< k) - 1#64) = (1#64 <<< k) - 1#64 := by
    cases cls
    · apply maskW_of_lt
      rw [BitVec.toNat_sub, pow_toNat hk64]
      simp only [clsBitsN] at hk
      have : 2 ^ k ≤ 2 ^ 31 := pow_mono (by omega)
      have : 0 < 2 ^ k := Nat.two_pow_pos k
      simp; omega
    · rfl
  rw [hm]
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_umod, BitVec.toNat_and, pow_toNat hk64]
  have h1 : ((1#64 <<< k) - 1#64).toNat = 2 ^ k - 1 := by
    rw [BitVec.toNat_sub, pow_toNat hk64]
    have : 0 < 2 ^ k := Nat.two_pow_pos k
    have : 2 ^ k < 2 ^ 64 := Nat.pow_lt_pow_right (by norm_num : 1 < 2) hk64
    simp; omega
  rw [h1, Nat.and_two_pow_sub_one_eq_mod]

theorem rc_ceq1 {x y : BitVec 64} (hy : maskC .W y = 1) (hx : x.toNat < 2) (hxm : maskC .W x = x) :
    evalBin .W (.CEq .W) x y = some x := by
  simp only [evalBin, hy, hxm, Option.some.injEq]
  have : x = 0 ∨ x = 1 := by
    rcases Nat.lt_succ_iff.1 hx |>.lt_or_eq with h | h
    · left; apply BitVec.eq_of_toNat_eq; simp; omega
    · right; apply BitVec.eq_of_toNat_eq; simp; omega
  rcases this with rfl | rfl <;> decide

theorem rc_cne0 {x y : BitVec 64} (hy : maskC .W y = 0) (hx : x.toNat < 2) (hxm : maskC .W x = x) :
    evalBin .W (.CNe .W) x y = some x := by
  simp only [evalBin, hy, hxm, Option.some.injEq]
  have : x = 0 ∨ x = 1 := by
    rcases Nat.lt_succ_iff.1 hx |>.lt_or_eq with h | h
    · left; apply BitVec.eq_of_toNat_eq; simp; omega
    · right; apply BitVec.eq_of_toNat_eq; simp; omega
  rcases this with rfl | rfl <;> decide

theorem kv_bv (k : Std.I32) (h0 : 0 ≤ k.val) (h1 : k.val < 64) :
    (Pion.I64.reinterpret_as_uint64 (Pion.I32.to_int64 k)).bv = BitVec.ofNat 64 k.val.toNat := by
  apply BitVec.eq_of_toInt_eq
  simp only [Pion.I64.reinterpret_as_uint64, Pion.I32.to_int64, IScalar.hcast, IScalar.cast,
    u64_mk_bv, UScalarTy.numBits, IScalarTy.numBits]
  rw [BitVec.toInt_signExtend_of_le (by norm_num), BitVec.toInt_signExtend_of_le (by norm_num)]
  have h1 : k.bv.toInt = k.val := rfl
  have h2 : (BitVec.ofNat 64 k.val.toNat).toNat = k.val.toNat := by
    rw [BitVec.toNat_ofNat]; exact Nat.mod_eq_of_lt (by omega)
  rw [h1, BitVec.toInt_eq_toNat_of_lt (by rw [h2]; omega), h2]
  omega

/-- `vg_canon_bin` and `canon_bin_rconst`, by mutual fixpoint induction. -/
theorem vg_canon_bin_motive (cls : Cls) : BinMotive1 cls (fun vg => vg_canon_bin vg cls) := by
  refine vg_canon_bin.fixpoint_induct cls (BinMotive1 cls) (BinMotive2 cls)
    (by unfold BinMotive1; exact adm4 _) (by unfold BinMotive2; exact adm5 _) ?_ ?_
  · intro f g ih1 ih2 vg op0 a0 b0 p h0 hd hva hvb hok
    obtain ⟨t0, ht0, h1⟩ := bind_eq_ok h0
    clear h0
    obtain ⟨hv1, hv2⟩ := vg_valid_ok ht0
    have ht0' : t0 = true := hv1.2 hva
    subst ht0'
    have hl := hv2 rfl
    have hdb : decide (Valid vg b0) = true := decide_eq_true hvb
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte, vg_valid_eq hl, hdb, bind_ok,
      swap_cmp_spec] at h1
    obtain ⟨t3, ht3, h2⟩ := bind_eq_ok h1
    clear h1
    obtain ⟨op1, a1, b1⟩ := t3
    -- the operands after `swap_cmp`
    have hsw : Valid vg a1 ∧ Valid vg b1 ∧ BinArgOK vg cls op1 a1 b1 ∧
        ∀ env, evalBin cls op0 (evI vg env a0) (evI vg env b0) =
          evalBin cls op1 (evI vg env a1) (evI vg env b1) := by
      cases hs : swapCmp op0 with
      | some o =>
        rw [hs] at ht3
        have := ok_inj' ht3
        simp only [Prod.mk.injEq] at this
        obtain ⟨rfl, rfl, rfl⟩ := this
        exact ⟨hvb, hva, binArgOK_swap hs _ _, fun env => evalBin_swap hs cls _ _⟩
      | none =>
        rw [hs] at ht3
        have := ok_inj' ht3
        simp only [Prod.mk.injEq] at this
        obtain ⟨rfl, rfl, rfl⟩ := this
        exact ⟨hva, hvb, hok, fun env => rfl⟩
    clear ht3
    obtain ⟨hva1, hvb1, hok1, hsem1⟩ := hsw
    simp only [vg_const_eq hl, bind_ok] at h2
    -- 1. constant folding
    obtain ⟨s, hs, h3⟩ := bind_eq_ok h2
    clear h2
    cases s with
    | inl q =>
      have := ok_inj' h3
      subst this
      cases hka : constOf vg a1 with
      | none => simp only [hka, Option.map_none] at hs; exact (ok_inr_ne_inl hs).elim
      | some x =>
      cases hkb : constOf vg b1 with
      | none => simp only [hka, hkb, Option.map_none, Option.map_some] at hs; exact (ok_inr_ne_inl hs).elim
      | some y =>
      simp only [hka, hkb, Option.map_some, eval_bin_const_sound, bind_ok] at hs
      cases hev : evalBin cls op1 x y with
      | none => simp only [hev, Option.map_none] at hs; exact (ok_inr_ne_inl hs).elim
      | some rv =>
      simp only [hev, Option.map_some] at hs
      obtain ⟨q2, hq2, hs⟩ := bind_eq_ok hs
      obtain ⟨r2, vg2⟩ := q2
      have := ok_inj' hs
      simp only [Sum.inl.injEq] at this
      subst this
      refine binOut_konst hd hq2 (fun env v hv => ?_)
      rw [hsem1, constOf_evI hd env hka, constOf_evI hd env hkb, hev] at hv
      simp only [u64_mk_bv, Option.some.injEq] at hv ⊢
      rw [← hv]
      exact evalBin_masked hev
    | inr g2 =>
    have hg2 : g2 = vg := by
      cases hka : constOf vg a1 with
      | none => simp only [hka, Option.map_none] at hs; have := ok_inj' hs; simp at this; exact this.symm
      | some x =>
      cases hkb : constOf vg b1 with
      | none =>
        simp only [hka, hkb, Option.map_none, Option.map_some] at hs
        have := ok_inj' hs; simp at this; exact this.symm
      | some y =>
      simp only [hka, hkb, Option.map_some, eval_bin_const_sound, bind_ok] at hs
      cases hev : evalBin cls op1 x y with
      | none => simp only [hev, Option.map_none] at hs; have := ok_inj' hs; simp at this; exact this.symm
      | some rv =>
      simp only [hev, Option.map_some] at hs
      obtain ⟨q2, hq2, hs⟩ := bind_eq_ok hs
      exact (ok_inl_ne_inr hs).elim
    subst g2
    clear hs
    -- 2. `x - c` is `x + (-c)`
    simp only [vg_const_eq hl, bind_ok] at h3
    obtain ⟨s1, hs1, h4⟩ := bind_eq_ok h3
    clear h3
    cases s1 with
    | inl q =>
      have := ok_inj' h4
      subst this
      split at hs1
      · rename_i hsub
        have hsub' : op1 = .Sub := by simpa using hsub
        subst hsub'
        cases hkb : constOf vg b1 with
        | none => simp only [hkb, Option.map_none] at hs1; exact (ok_inr_ne_inl hs1).elim
        | some y1 =>
        simp only [hkb, Option.map_some] at hs1
        obtain ⟨q1, hq1, hs1⟩ := bind_eq_ok hs1
        obtain ⟨nb, vg3⟩ := q1
        obtain ⟨q2, hq2, hs1⟩ := bind_eq_ok hs1
        obtain ⟨r4, vg4⟩ := q2
        have := ok_inj' hs1
        simp only [Sum.inl.injEq] at this
        subst this
        obtain ⟨e1, d1, vn1, cn1, _, ev1⟩ := konst_facts hd hq1
        have hcls1 : clsOf vg a1 = cls ∧ clsOf vg b1 = cls := by
          simpa [BinArgOK, isCmp, isShift] using hok1
        have hok2 : BinArgOK vg3 cls .Add a1 nb := by
          simp only [BinArgOK, isCmp, isShift, Bool.false_eq_true, ↓reduceIte]
          exact ⟨by rw [extends_clsOf e1 hva1]; exact hcls1.1, cn1⟩
        have hr := ih1 vg3 .Add a1 nb _ hq2 d1 (extends_valid e1 hva1) vn1 hok2
        refine binOut_weaken hr e1 (fun env => ?_)
        rw [hsem1, extends_evI e1 env hva1, ev1, evalBin_ring rfl, evalBin_ring rfl,
          constOf_evI hd env hkb]
        congr 1
        simp only [sub_bv, bv_zero, u64_mk_bv, liftC_maskR]
        cases cls <;> simp [liftC, ringOp, lo32_neg, BitVec.sub_eq_add_neg]
      · exact (ok_inr_ne_inl hs1).elim
    | inr g3 =>
    have hg3 : g3 = vg := by
      split at hs1
      · cases hkb : constOf vg b1 with
        | none =>
          simp only [hkb, Option.map_none] at hs1
          have := ok_inj' hs1; simp at this; exact this.symm
        | some y1 =>
          simp only [hkb, Option.map_some] at hs1
          obtain ⟨q1, hq1, hs1⟩ := bind_eq_ok hs1
          obtain ⟨q2, hq2, hs1⟩ := bind_eq_ok hs1
          exact (ok_inl_ne_inr hs1).elim
      · have := ok_inj' hs1; simp at this; exact this.symm
    subst g3
    clear hs1
    -- 5. commutative operands
    simp only [binop_commutes_spec, bind_ok, vg_const_eq hl] at h4
    obtain ⟨ab, hab, h5⟩ := bind_eq_ok h4
    clear h4
    obtain ⟨a3, b3⟩ := ab
    have hab' : Valid vg a3 ∧ Valid vg b3 ∧ BinArgOK vg cls op1 a3 b3 ∧
        ∀ env, evalBin cls op1 (evI vg env a1) (evI vg env b1) =
          evalBin cls op1 (evI vg env a3) (evI vg env b3) := by
      split at hab
      · rename_i hc
        split at hab
        · have := ok_inj' hab
          simp only [Prod.mk.injEq] at this
          obtain ⟨e1, e2⟩ := this
          subst a3
          subst b3
          exact ⟨hvb1, hva1, binArgOK_comm hc hok1, fun env => evalBin_comm hc cls _ _⟩
        · have := ok_inj' hab
          simp only [Prod.mk.injEq] at this
          obtain ⟨e1, e2⟩ := this
          subst a3
          subst b3
          exact ⟨hva1, hvb1, hok1, fun env => rfl⟩
      · have := ok_inj' hab
        simp only [Prod.mk.injEq] at this
        obtain ⟨e1, e2⟩ := this
        subst a3
        subst b3
        exact ⟨hva1, hvb1, hok1, fun env => rfl⟩
    obtain ⟨hva3, hvb3, hok3, hsem3⟩ := hab'
    clear hab
    -- 6. / 7. / 8. rewrites with a constant right operand
    obtain ⟨s2, hs2, h6⟩ := bind_eq_ok h5
    clear h5
    cases s2 with
    | inl q =>
      have := ok_inj' h6
      subst this
      cases hkb : constOf vg b3 with
      | none => simp only [hkb, Option.map_none] at hs2; exact (ok_inr_ne_inl hs2).elim
      | some y0 =>
      simp only [hkb, Option.map_some] at hs2
      obtain ⟨q1, hq1, hs2⟩ := bind_eq_ok hs2
      obtain ⟨r1, vg6⟩ := q1
      simp only [Aeneas.Std.uncurry_apply_pair] at hs2
      split at hs2
      · rename_i hr1
        have := ok_inj' hs2
        simp only [Sum.inl.injEq] at this
        subst this
        have hro := ih2 vg op1 a3 b3 ⟨y0⟩ _ hq1 hd hva3 hvb3 hok3 (by rw [hkb])
        obtain ⟨e6, d6, hpos⟩ := hro
        obtain ⟨v6, c6, val6⟩ := hpos (by simpa [i32_ge_iff] using hr1)
        exact ⟨e6, d6, v6, c6, fun env v hv => val6 env v (by rw [← hsem3, ← hsem1]; exact hv)⟩
      · exact (ok_inr_ne_inl hs2).elim
    | inr vg7 =>
    have hvg7 : vg_extends vg vg7 ∧ ValGraphDAG vg7 := by
      cases hkb : constOf vg b3 with
      | none =>
        simp only [hkb, Option.map_none] at hs2
        have := ok_inj' hs2; simp at this; subst this; exact ⟨vg_extends_refl _, hd⟩
      | some y0 =>
        simp only [hkb, Option.map_some] at hs2
        obtain ⟨q1, hq1, hs2⟩ := bind_eq_ok hs2
        obtain ⟨r1, vg6⟩ := q1
        have hro := ih2 vg op1 a3 b3 ⟨y0⟩ _ hq1 hd hva3 hvb3 hok3 (by rw [hkb])
        simp only [Aeneas.Std.uncurry_apply_pair] at hs2
        split at hs2
        · exact (ok_inl_ne_inr hs2).elim
        · have := ok_inj' hs2; simp at this; subst this; exact ⟨hro.1, hro.2.1⟩
    obtain ⟨e7, d7⟩ := hvg7
    clear hs2
    have hva7 := extends_valid e7 hva3
    have hvb7 := extends_valid e7 hvb3
    have hsemF : ∀ env, evalBin cls op0 (evI vg env a0) (evI vg env b0) =
        evalBin cls op1 (evI vg7 env a3) (evI vg7 env b3) := fun env => by
      rw [hsem1, hsem3, extends_evI e7 env hva3, extends_evI e7 env hvb3]
    -- 6. identical operands
    obtain ⟨s3, hs3, h7⟩ := bind_eq_ok h6
    clear h6
    cases s3 with
    | inl q =>
      have := ok_inj' h7
      subst this
      split at hs3
      · rename_i hab
        subst hab
        have hm := fun env => evI_masked d7 env hva7
        have hcl7 := extends_clsOf e7 hva3
        cases op1
        case Sub =>
          obtain ⟨q1, hq1, hs3⟩ := bind_eq_ok hs3
          obtain ⟨r8, vg8⟩ := q1
          have := ok_inj' hs3; simp only [Sum.inl.injEq] at this; subst this
          refine binOut_konst' e7 d7 hq1 (fun env v hv => ?_)
          rw [hsemF, evalBin_ring rfl, Option.some.injEq] at hv
          rw [← hv]; cases cls <;> simp [liftC, ringOp, maskC, zx32, lo32]
        case Xor =>
          obtain ⟨q1, hq1, hs3⟩ := bind_eq_ok hs3
          obtain ⟨r8, vg8⟩ := q1
          have := ok_inj' hs3; simp only [Sum.inl.injEq] at this; subst this
          refine binOut_konst' e7 d7 hq1 (fun env v hv => ?_)
          rw [hsemF, evalBin_ring rfl, Option.some.injEq] at hv
          rw [← hv]; cases cls <;> simp [liftC, ringOp, maskC, zx32, lo32]
        case And =>
          have := ok_inj' hs3; simp only [Sum.inl.injEq] at this; subst this
          have hc3 : clsOf vg a3 = cls := by
            simp only [BinArgOK, isCmp, isShift, Bool.false_eq_true, ↓reduceIte] at hok3
            exact hok3.1
          refine ⟨e7, d7, hva7, by rw [hcl7]; exact hc3, fun env v hv => ?_⟩
          rw [hsemF, evalBin_ring rfl, Option.some.injEq] at hv
          rw [← hv]
          have := hm env
          rw [hcl7, hc3] at this
          rw [← this]
          cases cls <;> simp [liftC, ringOp, maskC, lo32_zx32]
        case Or =>
          have := ok_inj' hs3; simp only [Sum.inl.injEq] at this; subst this
          have hc3 : clsOf vg a3 = cls := by
            simp only [BinArgOK, isCmp, isShift, Bool.false_eq_true, ↓reduceIte] at hok3
            exact hok3.1
          refine ⟨e7, d7, hva7, by rw [hcl7]; exact hc3, fun env v hv => ?_⟩
          rw [hsemF, evalBin_ring rfl, Option.some.injEq] at hv
          rw [← hv]
          have := hm env
          rw [hcl7, hc3] at this
          rw [← this]
          cases cls <;> simp [liftC, ringOp, maskC, lo32_zx32]
        all_goals first
          | exact (ok_inr_ne_inl hs3).elim
          | (obtain ⟨q1, hq1, hs3⟩ := bind_eq_ok hs3
             obtain ⟨r8, vg8⟩ := q1
             have := ok_inj' hs3; simp only [Sum.inl.injEq] at this; subst this
             refine binOut_konst' e7 d7 hq1 (fun env v hv => ?_)
             rw [hsemF] at hv
             simp only [evalBin, Option.some.injEq] at hv
             rw [← hv]
             cases cls <;> simp [b2v, maskC, zx32, lo32])
      · exact (ok_inr_ne_inl hs3).elim
    | inr vg16 =>
    have hg16 : vg16 = vg7 := by
      split at hs3
      · cases op1 <;> simp only at hs3 <;>
          first
          | (obtain ⟨q1, hq1, hs3⟩ := bind_eq_ok hs3; exact (ok_inl_ne_inr hs3).elim)
          | exact (ok_inl_ne_inr hs3).elim
          | (have := ok_inj' hs3; simp at this; exact this.symm)
      · have := ok_inj' hs3; simp at this; exact this.symm
    subst vg16
    clear hs3
    have hq := pair_ok h7
    have hi := vg_intern_ok hq
    have hcb : childrenBelow (.SBin cls op1 a3 b3) vg7.nodes.val.length := childrenBelow_bin hva7 hvb7
    refine ⟨vg_extends_trans e7 hi.1, intern_dag d7 hcb hi, intern_valid hi, intern_clsOf hi,
      fun env v hv => ?_⟩
    rw [intern_evI d7 hcb hi, hsemF] at *
    simp only [evalNode, hv, Option.getD_some]
  · intro f ih1 vg op a b y0 p h0 hd hva hvb hok hkb
    have hevb : ∀ env, evI vg env b = y0.bv := fun env => constOf_evI hd env hkb
    have hnoop : ∀ p', p' = ((-1)#i32, vg) → RconstOut vg p' cls op a b := by
      intro p' e; subst e
      exact ⟨vg_extends_refl _, hd, fun h => by simp at h⟩
    have hrefl : ∀ (hc : clsOf vg a = cls),
        (∀ env, evalBin cls op (evI vg env a) (evI vg env b) = some (evI vg env a)) →
        RconstOut vg (a, vg) cls op a b := by
      intro hc hv
      exact ⟨vg_extends_refl _, hd, fun _ => ⟨hva, hc, fun env v h => by
        rw [hv env] at h; exact (Option.some.inj h)⟩⟩
    have hkon : ∀ (c : Cls) (x : Std.U64) (q : Std.I32 × ValGraph), vg_konst vg cls x = ok q →
        (∀ env v, evalBin cls op (evI vg env a) (evI vg env b) = some v → maskC cls x.bv = v) →
        RconstOut vg q cls op a b := by
      intro c x q hq hv
      obtain ⟨q1, q2⟩ := q
      have := binOut_konst hd hq hv
      exact ⟨this.1, this.2.1, fun _ => this.2.2⟩
    simp only [binop_arg_cls_spec, mask_cls_spec, bind_ok] at h0
    obtain ⟨s, hs, h1⟩ := bind_eq_ok h0
    clear h0
    have hcase : s = .inr vg ∨ ∃ q, s = .inl q ∧ RconstOut vg q cls op a b := by
      have hcl2 : isCmp op = false → isShift op = false → clsOf vg a = cls ∧ clsOf vg b = cls := by
        intro h1 h2
        simpa [BinArgOK, h1, h2] using hok
      have hcls : isCmp op = false → isShift op = false → maskC cls y0.bv = y0.bv := by
        intro h1 h2
        have := constOf_clsOf hkb
        rwa [(hcl2 h1 h2).2] at this
      have hxm : isCmp op = false → ∀ env, maskC cls (evI vg env a) = evI vg env a := by
        intro h1 env
        cases hsh : isShift op
        · have := evI_masked hd env hva; rwa [(hcl2 h1 hsh).1] at this
        · have : clsOf vg a = cls := by simpa [BinArgOK, h1, hsh] using hok
          have h2 := evI_masked hd env hva; rwa [this] at h2
      cases op
      case Add =>
        simp only [argCls1] at hs
        by_cases hy : (⟨maskC cls y0.bv⟩ : Std.U64) = 0#u64
        · simp only [hy, ↓reduceIte] at hs
          have hy' : maskC cls y0.bv = 0 := by simpa [bv_zero] using congrArg (·.bv) hy
          refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl (hcl2 rfl rfl).1 (fun env => ?_)⟩
          rw [hevb]; exact rc_add0 hy' (hxm rfl env)
        · simp only [hy, ↓reduceIte] at hs; exact Or.inl (ok_inj' hs).symm
      case Mul =>
        simp only [argCls1] at hs
        have hc := hcl2 rfl rfl
        by_cases hy : (⟨maskC cls y0.bv⟩ : Std.U64) = 0#u64
        · simp only [hy, ↓reduceIte] at hs
          have hy' : maskC cls y0.bv = 0 := by simpa [bv_zero] using congrArg (·.bv) hy
          obtain ⟨q1, hq1, hs⟩ := bind_eq_ok hs
          obtain ⟨r1, vg1⟩ := q1
          refine Or.inr ⟨_, (ok_inj' hs).symm, hkon cls _ _ hq1 (fun env v hv => ?_)⟩
          rw [hevb, rc_mul0 hy'] at hv
          rw [← Option.some.inj hv]
          cases cls <;> decide
        · simp only [hy, ↓reduceIte] at hs
          by_cases hy1 : (⟨maskC cls y0.bv⟩ : Std.U64) = 1#u64
          · simp only [hy1, ↓reduceIte] at hs
            have hy1' : maskC cls y0.bv = 1 := by simpa using congrArg (·.bv) hy1
            refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl hc.1 (fun env => ?_)⟩
            rw [hevb]; exact rc_mul1 hy1' (hxm rfl env)
          · simp only [hy1, ↓reduceIte] at hs
            obtain ⟨k, hk, hs⟩ := bind_eq_ok hs
            split at hs
            · rename_i hkp
              have hkp' : 0 < k.val := by simpa [i32_gt_iff] using hkp
              obtain ⟨hyk, hkb⟩ := log2_exact_ok hk hkp'
              simp only [u64_mk_bv] at hyk
              have hkb64 : k.val < 64 := by have := clsBitsN_le cls; omega
              obtain ⟨q1, hq1, hs⟩ := bind_eq_ok hs
              obtain ⟨kv, vg2⟩ := q1
              obtain ⟨q2, hq2, hs⟩ := bind_eq_ok hs
              obtain ⟨r3, vg3⟩ := q2
              obtain ⟨e2, d2, vk2, ck2, _, evk2⟩ := konst_facts hd hq1
              have hok2 : BinArgOK vg2 cls .Shl a kv := by
                simp only [BinArgOK, isCmp, isShift, Bool.false_eq_true, ↓reduceIte]
                rw [extends_clsOf e2 hva]; exact hc.1
              have hr := ih1 vg2 .Shl a kv _ hq2 d2 (extends_valid e2 hva) vk2 hok2
              refine Or.inr ⟨_, (ok_inj' hs).symm,
                ⟨vg_extends_trans e2 hr.1, hr.2.1, fun _ => ⟨hr.2.2.1, hr.2.2.2.1, fun env v hv => ?_⟩⟩⟩
              apply hr.2.2.2.2 env v
              rw [extends_evI e2 env hva, evk2, kv_bv k (by omega) hkb64,
                maskW_of_lt _ (by simp; omega), ← hv, hevb]
              exact (rc_mulpow hyk (by omega)).symm
            · exact Or.inl (ok_inj' hs).symm
      case And =>
        simp only [argCls1, all_ones_spec, bind_ok] at hs
        have hc := hcl2 rfl rfl
        by_cases hy : (⟨maskC cls y0.bv⟩ : Std.U64) = 0#u64
        · simp only [hy, ↓reduceIte] at hs
          have hy' : maskC cls y0.bv = 0 := by simpa [bv_zero] using congrArg (·.bv) hy
          obtain ⟨q1, hq1, hs⟩ := bind_eq_ok hs
          obtain ⟨r1, vg1⟩ := q1
          refine Or.inr ⟨_, (ok_inj' hs).symm, hkon cls _ _ hq1 (fun env v hv => ?_)⟩
          rw [hevb, rc_and0 hy'] at hv
          rw [← Option.some.inj hv]
          cases cls <;> decide
        · simp only [hy, ↓reduceIte] at hs
          by_cases hy1 : (⟨maskC cls y0.bv⟩ : Std.U64) = ⟨allOnesC cls⟩
          · simp only [hy1, ↓reduceIte] at hs
            have hy1' : maskC cls y0.bv = allOnesC cls := by simpa using congrArg (·.bv) hy1
            refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl hc.1 (fun env => ?_)⟩
            rw [hevb]; exact rc_andOnes hy1' (hxm rfl env)
          · simp only [hy1, ↓reduceIte] at hs
            split at hs
            · rename_i hW
              simp only [beq_iff_eq] at hW
              subst hW
              obtain ⟨n, hn, hs⟩ := bind_eq_ok hs
              obtain ⟨t14, ht14, hs⟩ := bind_eq_ok hs
              split at hs
              · rename_i htt
                split at ht14
                · rename_i hnp
                  have hnp' : 0 < n.val := by simpa [i32_gt_iff] using hnp
                  obtain ⟨t13, ht13, ht14⟩ := bind_eq_ok ht14
                  have := ok_inj' ht14
                  subst this
                  obtain ⟨_, _, hfit⟩ := fits_bits_sound vg hd a n t13 ht13 htt
                  obtain ⟨hyn, hn64⟩ := low_mask_bits_ok hn hnp'
                  simp only [u64_mk_bv] at hyn
                  refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl hc.1 (fun env => ?_)⟩
                  rw [hevb]
                  exact rc_andLow hyn (by omega) (hfit env) (hxm rfl env)
                · have := ok_inj' ht14; subst this; cases htt
              · exact Or.inl (ok_inj' hs).symm
            · exact Or.inl (ok_inj' hs).symm
      case Or =>
        simp only [argCls1, all_ones_spec, bind_ok] at hs
        have hc := hcl2 rfl rfl
        by_cases hy : (⟨maskC cls y0.bv⟩ : Std.U64) = 0#u64
        · simp only [hy, ↓reduceIte] at hs
          have hy' : maskC cls y0.bv = 0 := by simpa [bv_zero] using congrArg (·.bv) hy
          refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl hc.1 (fun env => ?_)⟩
          rw [hevb]; exact rc_or0 hy' (hxm rfl env)
        · simp only [hy, ↓reduceIte] at hs
          by_cases hy1 : (⟨maskC cls y0.bv⟩ : Std.U64) = ⟨allOnesC cls⟩
          · simp only [hy1, ↓reduceIte] at hs
            have hy1' : maskC cls y0.bv = allOnesC cls := by simpa using congrArg (·.bv) hy1
            refine Or.inr ⟨_, (ok_inj' hs).symm, ⟨vg_extends_refl _, hd, fun _ => ⟨hvb, hc.2,
              fun env v hv => ?_⟩⟩⟩
            rw [hevb, rc_orOnes hy1'] at hv
            rw [hevb, ← Option.some.inj hv, ← hy1', hcls rfl rfl]
          · simp only [hy1, ↓reduceIte] at hs
            exact Or.inl (ok_inj' hs).symm
      case Xor =>
        simp only [argCls1] at hs
        have hc := hcl2 rfl rfl
        by_cases hy : (⟨maskC cls y0.bv⟩ : Std.U64) = 0#u64
        · simp only [hy, ↓reduceIte] at hs
          have hy' : maskC cls y0.bv = 0 := by simpa [bv_zero] using congrArg (·.bv) hy
          refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl hc.1 (fun env => ?_)⟩
          rw [hevb]; exact rc_xor0 hy' (hxm rfl env)
        · simp only [hy, ↓reduceIte] at hs; exact Or.inl (ok_inj' hs).symm
      case Shl =>
        simp only [argCls1, shift_amount_spec, bind_ok] at hs
        have hca : clsOf vg a = cls := by simpa [BinArgOK, isCmp, isShift] using hok
        split at hs
        · rename_i h0
          have h0' : shAmt cls y0.bv = 0 := by
            have := congrArg (fun z : Std.I32 => z.val) h0
            simp only [saI_val, u64_mk_bv, shAmt_maskW, i32_zero_val] at this
            omega
          refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl hca (fun env => ?_)⟩
          rw [hevb]; exact rc_shl0 h0' (hxm rfl env)
        · exact Or.inl (ok_inj' hs).symm
      case Shr =>
        simp only [argCls1, shift_amount_spec, bind_ok] at hs
        have hca : clsOf vg a = cls := by simpa [BinArgOK, isCmp, isShift] using hok
        split at hs
        · rename_i h0
          have h0' : shAmt cls y0.bv = 0 := by
            have := congrArg (fun z : Std.I32 => z.val) h0
            simp only [saI_val, u64_mk_bv, shAmt_maskW, i32_zero_val] at this
            omega
          refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl hca (fun env => ?_)⟩
          rw [hevb]; exact rc_shr0 h0' (hxm rfl env)
        · exact Or.inl (ok_inj' hs).symm
      case Sar =>
        simp only [argCls1, shift_amount_spec, bind_ok] at hs
        have hca : clsOf vg a = cls := by simpa [BinArgOK, isCmp, isShift] using hok
        split at hs
        · rename_i h0
          have h0' : shAmt cls y0.bv = 0 := by
            have := congrArg (fun z : Std.I32 => z.val) h0
            simp only [saI_val, u64_mk_bv, shAmt_maskW, i32_zero_val] at this
            omega
          refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl hca (fun env => ?_)⟩
          rw [hevb]; exact rc_sar0 h0' (hxm rfl env)
        · exact Or.inl (ok_inj' hs).symm
      case Ror =>
        simp only [argCls1, shift_amount_spec, bind_ok] at hs
        have hca : clsOf vg a = cls := by simpa [BinArgOK, isCmp, isShift] using hok
        split at hs
        · rename_i h0
          have h0' : shAmt cls y0.bv = 0 := by
            have := congrArg (fun z : Std.I32 => z.val) h0
            simp only [saI_val, u64_mk_bv, shAmt_maskW, i32_zero_val] at this
            omega
          refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl hca (fun env => ?_)⟩
          rw [hevb]; exact rc_ror0 h0' (hxm rfl env)
        · exact Or.inl (ok_inj' hs).symm
      case Div =>
        simp only [argCls1] at hs
        have hc := hcl2 rfl rfl
        by_cases hy1 : (⟨maskC cls y0.bv⟩ : Std.U64) = 1#u64
        · simp only [hy1, ↓reduceIte] at hs
          have hy1' : maskC cls y0.bv = 1 := by simpa using congrArg (·.bv) hy1
          refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl hc.1 (fun env => ?_)⟩
          rw [hevb]; exact rc_div1 hy1' (hxm rfl env)
        · simp only [hy1, ↓reduceIte] at hs; exact Or.inl (ok_inj' hs).symm
      case Rem =>
        simp only [argCls1] at hs
        by_cases hy1 : (⟨maskC cls y0.bv⟩ : Std.U64) = 1#u64
        · simp only [hy1, ↓reduceIte] at hs
          have hy1' : maskC cls y0.bv = 1 := by simpa using congrArg (·.bv) hy1
          obtain ⟨q1, hq1, hs⟩ := bind_eq_ok hs
          obtain ⟨r1, vg1⟩ := q1
          refine Or.inr ⟨_, (ok_inj' hs).symm, hkon cls _ _ hq1 (fun env v hv => ?_)⟩
          rw [hevb, rc_rem1 hy1'] at hv
          rw [← Option.some.inj hv]
          cases cls <;> decide
        · simp only [hy1, ↓reduceIte] at hs; exact Or.inl (ok_inj' hs).symm
      case UDiv =>
        simp only [argCls1] at hs
        have hc := hcl2 rfl rfl
        by_cases hy1 : (⟨maskC cls y0.bv⟩ : Std.U64) = 1#u64
        · simp only [hy1, ↓reduceIte] at hs
          have hy1' : maskC cls y0.bv = 1 := by simpa using congrArg (·.bv) hy1
          refine Or.inr ⟨_, (ok_inj' hs).symm, hrefl hc.1 (fun env => ?_)⟩
          rw [hevb]; exact rc_udiv1 hy1' (hxm rfl env)
        · simp only [hy1, ↓reduceIte] at hs
          obtain ⟨k, hk, hs⟩ := bind_eq_ok hs
          split at hs
          · rename_i hkp
            have hkp' : 0 < k.val := by simpa [i32_gt_iff] using hkp
            obtain ⟨hyk, hkb⟩ := log2_exact_ok hk hkp'
            simp only [u64_mk_bv] at hyk
            have hkb64 : k.val < 64 := by have := clsBitsN_le cls; omega
            obtain ⟨q1, hq1, hs⟩ := bind_eq_ok hs
            obtain ⟨kv, vg2⟩ := q1
            obtain ⟨q2, hq2, hs⟩ := bind_eq_ok hs
            obtain ⟨r3, vg3⟩ := q2
            obtain ⟨e2, d2, vk2, ck2, _, evk2⟩ := konst_facts hd hq1
            have hok2 : BinArgOK vg2 cls .Shr a kv := by
              simp only [BinArgOK, isCmp, isShift, Bool.false_eq_true, ↓reduceIte]
              rw [extends_clsOf e2 hva]; exact hc.1
            have hr := ih1 vg2 .Shr a kv _ hq2 d2 (extends_valid e2 hva) vk2 hok2
            refine Or.inr ⟨_, (ok_inj' hs).symm,
              ⟨vg_extends_trans e2 hr.1, hr.2.1, fun _ => ⟨hr.2.2.1, hr.2.2.2.1, fun env v hv => ?_⟩⟩⟩
            apply hr.2.2.2.2 env v
            rw [extends_evI e2 env hva, evk2, kv_bv k (by omega) hkb64,
              maskW_of_lt _ (by simp; omega), ← hv, hevb]
            exact (rc_udivpow hyk (by omega)).symm
          · exact Or.inl (ok_inj' hs).symm
      case URem =>
        simp only [argCls1] at hs
        have hc := hcl2 rfl rfl
        by_cases hy1 : (⟨maskC cls y0.bv⟩ : Std.U64) = 1#u64
        · simp only [hy1, ↓reduceIte] at hs
          have hy1' : maskC cls y0.bv = 1 := by simpa using congrArg (·.bv) hy1
          obtain ⟨q1, hq1, hs⟩ := bind_eq_ok hs
          obtain ⟨r1, vg1⟩ := q1
          refine Or.inr ⟨_, (ok_inj' hs).symm, hkon cls _ _ hq1 (fun env v hv => ?_)⟩
          rw [hevb, rc_urem1 hy1'] at hv
          rw [← Option.some.inj hv]
          cases cls <;> decide
        · simp only [hy1, ↓reduceIte] at hs
          obtain ⟨k, hk, hs⟩ := bind_eq_ok hs
          split at hs
          · rename_i hkp
            have hkp' : 0 < k.val := by simpa [i32_gt_iff] using hkp
            obtain ⟨hyk, hkb⟩ := log2_exact_ok hk hkp'
            simp only [u64_mk_bv] at hyk
            obtain ⟨q1, hq1, hs⟩ := bind_eq_ok hs
            obtain ⟨mv, vg9⟩ := q1
            obtain ⟨q2, hq2, hs⟩ := bind_eq_ok hs
            obtain ⟨r3, vg3⟩ := q2
            obtain ⟨e2, d2, vk2, ck2, _, evk2⟩ := konst_facts hd hq1
            have hok2 : BinArgOK vg9 cls .And a mv := by
              simp only [BinArgOK, isCmp, isShift, Bool.false_eq_true, ↓reduceIte]
              exact ⟨by rw [extends_clsOf e2 hva]; exact hc.1, ck2⟩
            have hr := ih1 vg9 .And a mv _ hq2 d2 (extends_valid e2 hva) vk2 hok2
            refine Or.inr ⟨_, (ok_inj' hs).symm,
              ⟨vg_extends_trans e2 hr.1, hr.2.1, fun _ => ⟨hr.2.2.1, hr.2.2.2.1, fun env v hv => ?_⟩⟩⟩
            apply hr.2.2.2.2 env v
            rw [extends_evI e2 env hva, evk2, ← hv, hevb]
            simp only [sub_bv, u64_mk_bv, hyk]
            exact (rc_urempow hyk (by omega)).symm
          · exact Or.inl (ok_inj' hs).symm
      case CEq c =>
        simp only [argCls1] at hs
        obtain ⟨t, ht, hs'⟩ := bind_eq_ok hs
        clear hs
        split at hs'
        · rename_i htt
          by_cases hcond : (c == Cls.W && cls == Cls.W && (⟨maskC c y0.bv⟩ : Std.U64) == 1#u64) = true
          · simp only [hcond, ↓reduceIte] at ht
            simp only [Bool.and_eq_true, beq_iff_eq] at hcond
            obtain ⟨⟨hc1, hc2⟩, hc3⟩ := hcond
            subst hc1
            subst hc2
            have hy1' : maskC .W y0.bv = 1 := by simpa using congrArg (·.bv) hc3
            obtain ⟨t3, ht3, ht⟩ := bind_eq_ok ht
            have := ok_inj' ht
            subst this
            subst htt
            obtain ⟨_, hcW, hfit⟩ := is_bool_node_sound hd ht3
            refine Or.inr ⟨_, (ok_inj' hs').symm, hrefl hcW (fun env => ?_)⟩
            rw [hevb]
            exact rc_ceq1 hy1' (by simpa using hfit env) (evI_maskW hd env hva hcW)
          · simp only [hcond, Bool.false_eq_true, ↓reduceIte] at ht
            have := ok_inj' ht
            subst this
            cases htt
        · exact Or.inl (ok_inj' hs').symm
      case CNe c =>
        simp only [argCls1] at hs
        obtain ⟨t, ht, hs'⟩ := bind_eq_ok hs
        clear hs
        split at hs'
        · rename_i htt
          by_cases hcond : (c == Cls.W && cls == Cls.W && (⟨maskC c y0.bv⟩ : Std.U64) == 0#u64) = true
          · simp only [hcond, ↓reduceIte] at ht
            simp only [Bool.and_eq_true, beq_iff_eq] at hcond
            obtain ⟨⟨hc1, hc2⟩, hc3⟩ := hcond
            subst hc1
            subst hc2
            have hy1' : maskC .W y0.bv = 0 := by simpa [bv_zero] using congrArg (·.bv) hc3
            obtain ⟨t3, ht3, ht⟩ := bind_eq_ok ht
            have := ok_inj' ht
            subst this
            subst htt
            obtain ⟨_, hcW, hfit⟩ := is_bool_node_sound hd ht3
            refine Or.inr ⟨_, (ok_inj' hs').symm, hrefl hcW (fun env => ?_)⟩
            rw [hevb]
            exact rc_cne0 hy1' (by simpa using hfit env) (evI_maskW hd env hva hcW)
          · simp only [hcond, Bool.false_eq_true, ↓reduceIte] at ht
            have := ok_inj' ht
            subst this
            cases htt
        · exact Or.inl (ok_inj' hs').symm
      all_goals exact Or.inl (ok_inj' hs).symm
    rcases hcase with rfl | ⟨q, rfl, hq⟩
    · -- 7. `(x op c1) op c2` is `x op (c1 op c2)`
      dsimp only at h1
      simp only [is_assoc_op_spec, bind_ok] at h1
      by_cases hass : isAssoc op = true
      · simp only [hass, ↓reduceIte] at h1
        obtain ⟨tv0, htv0, h1⟩ := bind_eq_ok h1
        obtain ⟨tv, htv, htv0⟩ := bind_eq_ok htv0
        have := ok_inj' htv0
        subst this
        obtain ⟨hv1, hv2⟩ := vg_valid_ok htv
        have htv' : tv = true := hv1.2 hva
        subst htv'
        have hl := hv2 rfl
        simp only [↓reduceIte, bind_ok, nodes_get_eq hva] at h1
        have hnode := valid_nodeAt hva
        generalize vg.nodes.val[a.val.toNat]'hva.2 = nd at h1 hnode
        have hring := isAssoc_ring hass
        have harg : argCls1 op cls = cls := by
          cases op <;> simp_all [isAssoc, argCls1]
        cases nd with
        | SBin c2 op2 x z =>
          simp only [vg_cls_eq hl, bind_ok] at h1
          by_cases hcond : c2 = cls ∧ op2 = op ∧ clsOf vg x = cls
          · obtain ⟨hc1, hc2, hc3⟩ := hcond
            subst c2
            subst op2
            simp only [beq_self_eq_true, Bool.and_self, ↓reduceIte, hc3, bind_ok,
              vg_const_eq hl] at h1
            have ⟨hvx, hvz⟩ := child_bin hd hnode
            cases hz : constOf vg z with
            | none =>
              simp only [hz, Option.map_none] at h1
              exact hnoop _ (ok_inj' h1).symm
            | some zc =>
            simp only [hz, Option.map_some, eval_bin_const_sound, bind_ok, harg] at h1
            simp only [u64_mk_bv] at h1
            cases hev : evalBin cls op zc (maskC cls y0.bv) with
            | none =>
              simp only [hev, Option.map_none] at h1
              exact hnoop _ (ok_inj' h1).symm
            | some r =>
            simp only [hev, Option.map_some] at h1
            obtain ⟨q1, hq1, h1⟩ := bind_eq_ok h1
            obtain ⟨rv, vg12⟩ := q1
            obtain ⟨e12, d12, vr12, cr12, _, evr12⟩ := konst_facts hd hq1
            have hok2 : BinArgOK vg12 cls op x rv := by
              have h1' : isCmp op = false := by cases op <;> simp_all [isAssoc, isCmp]
              have h2' : isShift op = false := by cases op <;> simp_all [isAssoc, isShift]
              simp only [BinArgOK, h1', h2', Bool.false_eq_true, ↓reduceIte]
              exact ⟨by rw [extends_clsOf e12 hvx]; exact hc3, cr12⟩
            have hp := pair_ok h1
            have hr := ih1 vg12 op x rv p hp d12 (extends_valid e12 hvx) vr12 hok2
            refine ⟨vg_extends_trans e12 hr.1, hr.2.1, fun _ => ⟨hr.2.2.1, hr.2.2.2.1,
              fun env v hv => hr.2.2.2.2 env v ?_⟩⟩
            rw [extends_evI e12 env hvx, evr12, ← hv, evI_node hd env hnode, hevb]
            simp only [u64_mk_bv]
            simp only [evalNode]
            rw [constOf_evI hd env hz]
            simp only [evalBin_ring hring, Option.getD_some]
            rw [evalBin_ring hring, Option.some.injEq] at hev
            rw [← hev, liftC_masked, liftC_maskR, liftC_assoc hass]
          · split at h1
            · rename_i hc'
              simp only [Bool.and_eq_true, beq_iff_eq] at hc'
              simp only [bind_ok] at h1
              split at h1
              · rename_i hx
                simp only [beq_iff_eq] at hx
                exact absurd ⟨hc'.1, hc'.2, hx⟩ hcond
              · exact hnoop _ (ok_inj' h1).symm
            · simp only [bind_ok, Bool.false_eq_true, ↓reduceIte] at h1
              exact hnoop _ (ok_inj' h1).symm
        | SConst _ _ => exact hnoop _ (ok_inj' h1).symm
        | SSym _ => exact hnoop _ (ok_inj' h1).symm
        | SParam _ _ => exact hnoop _ (ok_inj' h1).symm
        | SPhi _ _ _ => exact hnoop _ (ok_inj' h1).symm
        | SEffect _ _ _ => exact hnoop _ (ok_inj' h1).symm
        | SUn _ _ _ => exact hnoop _ (ok_inj' h1).symm
      · simp only [hass, Bool.false_eq_true, ↓reduceIte] at h1
        simp only [bind_ok, Bool.false_eq_true, ↓reduceIte] at h1
        exact hnoop _ (ok_inj' h1).symm
    · have := ok_inj' h1
      subst this
      exact hq

/-- `vg_canon_bin vg cls op a b` is a node with the value of `cls op a, b`
(whenever that operation does not trap). -/
theorem vg_canon_bin_sound {vg : ValGraph} {cls : Cls} {op : BinOp} {a b : Std.I32}
    {p : Std.I32 × ValGraph} (h : vg_canon_bin vg cls op a b = ok p) (hd : ValGraphDAG vg)
    (ha : Valid vg a) (hb : Valid vg b) (hok : BinArgOK vg cls op a b) :
    vg_extends vg p.2 ∧ ValGraphDAG p.2 ∧ Valid p.2 p.1 ∧ clsOf p.2 p.1 = cls ∧
      ∀ env v, evalBin cls op (evI vg env a) (evI vg env b) = some v → evI p.2 env p.1 = v :=
  vg_canon_bin_motive cls vg op a b p h hd ha hb hok

/-! ## `vg_trunc_w` and `vg_use` -/

theorem maskW_evalUn (c : Cls) (op : UnOp) (y : BitVec 64) :
    maskC .W (evalUn c op y) = evalUn .W op y := by
  cases op <;> simp only [evalUn, maskW_maskC]

theorem maskW_ext32 {op : UnOp} (h : extBits op = 32 ∨ op = .Copy) (y : BitVec 64) :
    maskC .W (evalUn .W op y) = maskC .W y := by
  rcases h with h | h
  · rw [evalUn_ext32W h, maskC_idem]
  · subst h; simp only [evalUn, maskC_idem]

theorem evalBin_cmp_cls {op : BinOp} (h : isCmp op = true) (c c' : Cls) (x y : BitVec 64) :
    evalBin c op x y = evalBin c' op x y := by
  cases op <;> simp [isCmp] at h <;> rfl

theorem is_ring_op_spec (op : BinOp) : is_ring_op op = ok (isRing op) := by
  cases op <;> rfl

theorem isRing_not_cmp {op : BinOp} (h : isRing op = true) : isCmp op = false := by
  cases op <;> simp_all [isRing, isCmp]

theorem isRing_not_shift {op : BinOp} (h : isRing op = true) : isShift op = false := by
  cases op <;> simp_all [isRing, isShift]

theorem lo32_ringOp {op : BinOp} (h : isRing op = true) (x y : BitVec 64) :
    lo32 (ringOp op x y) = ringOp op (lo32 x) (lo32 y) := by
  cases op <;> simp [isRing] at h <;>
    simp only [ringOp, lo32_add, lo32_sub, lo32_mul, lo32_and, lo32_or, lo32_xor]

theorem maskW_liftC {op : BinOp} (h : isRing op = true) (c : Cls) (x y : BitVec 64) :
    maskC .W (liftC op c x y) = liftC op .W x y := by
  cases c
  · exact liftC_masked op .W x y
  · simp only [liftC, maskC, lo32_ringOp h]

theorem evalUn_neg_maskW (y : BitVec 64) :
    evalUn .W .Neg (maskC .W y) = evalUn .W .Neg y := by
  simp only [evalUn, maskC, lo32_neg, lo32_zx32]

/-- `vg_trunc_w vg v` is a `W` node holding the low half of `v`. -/
theorem vg_trunc_w_sound :
    ∀ vg v p, vg_trunc_w vg v = ok p → ValGraphDAG vg → Valid vg v →
      CanonOut vg p.2 p.1 .W (fun env => maskC .W (evI vg env v)) := by
  refine vg_trunc_w.fixpoint_induct
    (fun f => ∀ vg v p, f vg v = ok p → ValGraphDAG vg → Valid vg v →
      CanonOut vg p.2 p.1 .W (fun env => maskC .W (evI vg env v))) (adm2 _) ?_
  intro f ih vg v p h0 hd hvv
  obtain ⟨b, hb, h⟩ := bind_eq_ok h0
  clear h0
  obtain ⟨hb1, hb2⟩ := vg_valid_ok hb
  have hbt : b = true := hb1.2 hvv
  subst hbt
  have hl := hb2 rfl
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte, nodes_get_eq hvv, bind_ok] at h
  have hnode := valid_nodeAt hvv
  generalize vg.nodes.val[v.val.toNat]'hvv.2 = nd at h hnode
  have hev := fun env => evI_node hd env hnode
  have hcopy : ∀ q, vg_intern vg (.SUn .W .Copy v) = ok q →
      CanonOut vg q.2 q.1 .W (fun env => maskC .W (evI vg env v)) :=
    fun q hq => out_intern hd hq (childrenBelow_un hvv) (fun env => rfl)
  cases nd with
  | SConst c x =>
    refine out_konst hd (pair_ok h) (fun env => ?_)
    rw [hev env]
    simp only [evalNode, maskW_maskC]
  | SUn c op a =>
    have hva := child_un hd hnode
    simp only [unop_ext_bits_spec, bind_ok] at h
    by_cases hc32 : extBits op = 32 ∨ op = .Copy
    · have hcond : ((⟨BitVec.ofNat 32 (extBits op)⟩ : Std.I32) == 32#i32 || op == UnOp.Copy) = true := by
        rcases hc32 with h1 | h1
        · simp only [Bool.or_eq_true, beq_iff_eq]
          left
          apply i32_ext'
          show BitVec.ofNat 32 (extBits op) = BitVec.ofNat 32 32
          rw [h1]
        · simp [h1]
      rw [ite_t hcond] at h
      simp only [vg_cls_eq hl, bind_ok] at h
      split at h
      · rename_i hW
        simp only [beq_iff_eq] at hW
        have := ok_inj' h
        subst this
        refine out_refl hd hva hW (fun env => ?_)
        rw [hev env]
        simp only [evalNode]
        rw [maskW_evalUn, ← evalUn_masked .W op, maskW_ext32 hc32]
        exact (evI_maskW hd env hva hW).symm
      · exact hcopy _ (pair_ok h)
    · have hcond : ¬ ((⟨BitVec.ofNat 32 (extBits op)⟩ : Std.I32) == 32#i32 || op == UnOp.Copy) = true := by
        intro hc
        apply hc32
        simp only [Bool.or_eq_true, beq_iff_eq] at hc
        rcases hc with hc | hc
        · left
          have := congrArg (fun z : Std.I32 => z.val) hc
          simp only [extBits_val, i32_32_val] at this
          omega
        · exact Or.inr hc
      rw [ite_f hcond] at h
      have hcp : op ≠ .Copy := fun e => hc32 (Or.inr e)
      split at h
      · rename_i hk0
        have hk0' : 0 < extBits op := by
          have : (0#i32 : Std.I32).val < (⟨BitVec.ofNat 32 (extBits op)⟩ : Std.I32).val := hk0
          rw [extBits_val] at this
          simp at this
          omega
        have hr := vg_canon_un_sound vg .W op hd a p (pair_ok h) hva
          ⟨fun e => absurd e hcp, fun _ e => absurd (Or.inl (by rcases e with rfl | rfl <;> rfl)) hc32⟩
        refine out_weaken hr (vg_extends_refl _) (fun env => ?_)
        rw [hev env]
        simp only [evalNode, maskW_evalUn]
      · rename_i hk0
        have hng : op = .Neg := by
          have : ¬ (0#i32 : Std.I32).val < (⟨BitVec.ofNat 32 (extBits op)⟩ : Std.I32).val := hk0
          rw [extBits_val] at this
          cases op <;> simp_all [extBits]
        subst hng
        obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
        obtain ⟨ta, vg4⟩ := q1
        have hr1 := ih vg a _ hq1 hd hva
        obtain ⟨e4, d4, vt4, ct4, evt4⟩ := hr1
        have hr2 := vg_canon_un_sound vg4 .W .Neg d4 ta p (pair_ok h) vt4
          ⟨fun e => (by cases e), fun _ e => (by rcases e with e | e <;> cases e)⟩
        refine out_weaken hr2 e4 (fun env => ?_)
        rw [evt4, evalUn_neg_maskW, hev env]
        simp only [evalNode, maskW_evalUn]
  | SBin c op a b =>
    have ⟨hva, hvb⟩ := child_bin hd hnode
    simp only [binop_is_cmp_spec, bind_ok] at h
    split at h
    · rename_i hcmp
      obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
      have := ok_inj' h
      subst this
      have hr := vg_canon_bin_sound hq1 hd hva hvb (by simp [BinArgOK, hcmp])
      refine ⟨hr.1, hr.2.1, hr.2.2.1, hr.2.2.2.1, fun env => ?_⟩
      dsimp only
      rw [hev env]
      simp only [evalNode]
      rw [evalBin_cmp_cls hcmp c .W]
      cases hv : evalBin .W op (evI vg env a) (evI vg env b) with
      | none => cases op <;> simp [isCmp] at hcmp <;> simp [evalBin] at hv
      | some v =>
        simp only [Option.getD_some]
        rw [hr.2.2.2.2 env v hv, evalBin_masked hv]
    · rename_i hcmp
      simp only [is_ring_op_spec, bind_ok] at h
      split at h
      · rename_i hring
        obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
        obtain ⟨ta, vg7⟩ := q1
        obtain ⟨q2, hq2, h⟩ := bind_eq_ok h
        obtain ⟨tb, vg8⟩ := q2
        obtain ⟨e7, d7, vt7, ct7, evt7⟩ := ih vg a _ hq1 hd hva
        obtain ⟨e8, d8, vt8, ct8, evt8⟩ := ih vg7 b _ hq2 d7 (extends_valid e7 hvb)
        dsimp only at evt7 evt8 vt7 vt8 ct7 ct8 e7 e8 d7 d8
        have hr := vg_canon_bin_sound (pair_ok h) d8 (extends_valid e8 vt7) vt8
          (by
            simp only [BinArgOK, isRing_not_cmp hring, isRing_not_shift hring, Bool.false_eq_true,
              ↓reduceIte]
            exact ⟨by rw [extends_clsOf e8 vt7]; exact ct7, ct8⟩)
        refine ⟨vg_extends_trans e7 (vg_extends_trans e8 hr.1), hr.2.1, hr.2.2.1, hr.2.2.2.1,
          fun env => ?_⟩
        dsimp only
        rw [hr.2.2.2.2 env (liftC op .W (evI vg env a) (evI vg env b)) (by
          rw [evalBin_ring hring, extends_evI e8 env vt7, evt7, evt8, extends_evI e7 env hvb,
            liftC_maskL, liftC_maskR])]
        rw [hev env]
        simp only [evalNode]
        rw [evalBin_ring hring, Option.getD_some, maskW_liftC hring]
      · exact hcopy _ (pair_ok h)
  | SSym _ => exact hcopy _ (pair_ok h)
  | SParam _ _ => exact hcopy _ (pair_ok h)
  | SPhi _ _ _ => exact hcopy _ (pair_ok h)
  | SEffect _ _ _ => exact hcopy _ (pair_ok h)

/-- `vg_use vg cls v` reads `v` at class `cls`: the low half of an `L` value, the
(zero-extended) word of a `W` value. -/
theorem vg_use_sound {vg : ValGraph} {cls : Cls} {v : Std.I32} {p : Std.I32 × ValGraph}
    (h : vg_use vg cls v = ok p) (hd : ValGraphDAG vg) (hvv : Valid vg v) :
    CanonOut vg p.2 p.1 cls (fun env => maskC cls (evI vg env v)) := by
  unfold vg_use at h
  obtain ⟨b, hb, h⟩ := bind_eq_ok h
  obtain ⟨hb1, hb2⟩ := vg_valid_ok hb
  have hbt : b = true := hb1.2 hvv
  subst hbt
  have hl := hb2 rfl
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte, vg_cls_eq hl, bind_ok] at h
  split at h
  · rename_i hc
    simp only [beq_iff_eq] at hc
    have := ok_inj' h
    subst this
    refine out_refl hd hvv hc (fun env => ?_)
    have := evI_masked hd env hvv
    rw [hc] at this
    exact this.symm
  · rename_i hc
    simp only [beq_iff_eq] at hc
    cases cls with
    | W => exact vg_trunc_w_sound vg v p (pair_ok h) hd hvv
    | L =>
      have hW : clsOf vg v = .W := by
        cases e : clsOf vg v
        · rfl
        · exact absurd e hc
      obtain ⟨t, ht, h⟩ := bind_eq_ok h
      split at h
      · rename_i htt
        have hr := vg_canon_un_sound vg .L .ExtUW hd v p (pair_ok h) hvv
          ⟨fun e => (by cases e), fun e => (by cases e)⟩
        refine out_weaken hr (vg_extends_refl _) (fun env => ?_)
        simp only [evalUn, maskC, ← maskW_eq]
        exact evI_maskW hd env hvv hW
      · exact out_intern hd (pair_ok h) (childrenBelow_un hvv) (fun env => rfl)

end PionProofs.QbeTvP
