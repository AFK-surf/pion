/-
Semantics for the proofs over the extracted QBE translation validator
(`tools/qbe_tv`, Lean module `QbeTv`).

1. Exact bit-vector semantics of the integer operators (`evalUn`, `evalBin`)
   and the soundness of the validator's constant evaluator against it
   (`eval_un_const_sound`, `eval_bin_const_sound`).
2. An operational semantics of QBE functions (`evalFunc`) over an abstract
   world (`WorldOracle`).
3. The denotation of the symbolic value graph (`evalSym`) and its basic
   properties: `vg_intern` only appends and keeps the meaning of every old
   node, `check_vg_dag` decides `ValGraphDAG`, `vid_mentions_blk` is a sound
   dependency check.

Value model (`ir.pion`): every value is a 64-bit word; a `W` value is kept
zero-extended (`maskC .W`). An `L` read of a `W` value reads that
zero-extended word (amd64 / arm64), a `W` read of an `L` value its low half.
-/
import QbeTv.Funs
import PionProofs.Common
open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 4000000

namespace PionProofs.QbeTvP

open qbe_tv

/-! ## Results of extracted code -/

theorem bind_eq_ok {α β : Type} {x : Result α} {f : α → Result β} {r : β}
    (h : Aeneas.Std.bind x f = ok r) : ∃ a, x = ok a ∧ f a = ok r := by
  cases x using Result.cases with
  | ret a => exact ⟨a, rfl, by simpa using h⟩
  | vis e k => simp at h
  | div => simp at h

theorem ok_inj' {α : Type} {a b : α} (h : (ok a : Result α) = ok b) : a = b :=
  Result.ok_injective h

/-! ## Values -/

/-- Zero extension of a 32-bit word. -/
def zx32 (x : BitVec 32) : BitVec 64 := x.setWidth 64

/-- Low 32 bits. -/
def lo32 (x : BitVec 64) : BitVec 32 := x.setWidth 32

/-- `mask_cls`: a `W` value keeps its low 32 bits. -/
def maskC : Cls → BitVec 64 → BitVec 64
  | .W, x => zx32 (lo32 x)
  | .L, x => x

/-- The low `k` bits, zero-extended. -/
def extU (k : Nat) (v : BitVec 64) : BitVec 64 := (v.setWidth k).setWidth 64

/-- The low `k` bits, sign-extended. -/
def extS (k : Nat) (v : BitVec 64) : BitVec 64 := (v.setWidth k).signExtend 64

/-- `as_signed`: the signed reading of a value of class `c`. -/
def asS : Cls → BitVec 64 → BitVec 64
  | .W, x => extS 32 x
  | .L, x => x

/-- `shift_amount`: the count is masked to `31` / `63`. -/
def shAmt : Cls → BitVec 64 → Nat
  | .W, b => b.toNat % 32
  | .L, b => b.toNat % 64

def b2v (b : Bool) : BitVec 64 := if b then 1#64 else 0#64

def allOnesC (c : Cls) : BitVec 64 := maskC c (-1#64)

def intMinC : Cls → BitVec 64
  | .W => 2147483648#64
  | .L => 9223372036854775808#64

/-- `true` for `div` / `rem`. -/
def signedDivOp : BinOp → Bool
  | .Div => true
  | .Rem => true
  | _ => false

/-- `is_safe_div_const cls op (some a) b`: the division cannot trap. -/
def safeDiv (cls : Cls) (op : BinOp) (a b : BitVec 64) : Prop :=
  maskC cls b ≠ 0 ∧ (signedDivOp op = true → maskC cls b = allOnesC cls → maskC cls a ≠ intMinC cls)

instance (cls : Cls) (op : BinOp) (a b : BitVec 64) : Decidable (safeDiv cls op a b) := by
  unfold safeDiv; infer_instance

/-- QBE unary operators (`vendor/qbe/fold.c`); the result has class `cls`. -/
def evalUn (cls : Cls) : UnOp → BitVec 64 → BitVec 64
  | .Copy, v => maskC cls v
  | .Neg, v => maskC cls (-v)
  | .ExtSB, v => maskC cls (extS 8 v)
  | .ExtUB, v => maskC cls (extU 8 v)
  | .ExtSH, v => maskC cls (extS 16 v)
  | .ExtUH, v => maskC cls (extU 16 v)
  | .ExtSW, v => maskC cls (extS 32 v)
  | .ExtUW, v => maskC cls (extU 32 v)

/-- QBE binary operators (`vendor/qbe/fold.c`); `none` exactly when the
operation traps (division by zero, signed `MIN / -1`). Operands are read at
class `cls` (comparisons: their own class; shift counts: `31` / `63`). -/
def evalBin (cls : Cls) (op : BinOp) (a0 b0 : BitVec 64) : Option (BitVec 64) :=
  let a := maskC cls a0
  let b := maskC cls b0
  match op with
  | .Add => some (maskC cls (a + b))
  | .Sub => some (maskC cls (a - b))
  | .Mul => some (maskC cls (a * b))
  | .And => some (a &&& b)
  | .Or => some (a ||| b)
  | .Xor => some (a ^^^ b)
  | .Shl => some (maskC cls (a <<< shAmt cls b0))
  | .Shr => some (a >>> shAmt cls b0)
  | .Sar => some (maskC cls ((asS cls a).sshiftRight (shAmt cls b0)))
  | .Ror =>
    let s := shAmt cls b0
    if s = 0 then some a
    else
      let w := match cls with | .W => 32 | .L => 64
      some (maskC cls ((a >>> s) ||| (a <<< (w - s))))
  | .Div => if safeDiv cls .Div a b then some (maskC cls ((asS cls a).sdiv (asS cls b))) else none
  | .Rem => if safeDiv cls .Rem a b then some (maskC cls ((asS cls a).srem (asS cls b))) else none
  | .UDiv => if safeDiv cls .UDiv a b then some (a / b) else none
  | .URem => if safeDiv cls .URem a b then some (a % b) else none
  | .CEq c => some (b2v (decide (maskC c a0 = maskC c b0)))
  | .CNe c => some (b2v (decide (maskC c a0 ≠ maskC c b0)))
  | .CSlt c => some (b2v (decide ((asS c a0).toInt < (asS c b0).toInt)))
  | .CSle c => some (b2v (decide ((asS c a0).toInt ≤ (asS c b0).toInt)))
  | .CSgt c => some (b2v (decide ((asS c a0).toInt > (asS c b0).toInt)))
  | .CSge c => some (b2v (decide ((asS c a0).toInt ≥ (asS c b0).toInt)))
  | .CUlt c => some (b2v (decide ((maskC c a0).toNat < (maskC c b0).toNat)))
  | .CUle c => some (b2v (decide ((maskC c a0).toNat ≤ (maskC c b0).toNat)))
  | .CUgt c => some (b2v (decide ((maskC c a0).toNat > (maskC c b0).toNat)))
  | .CUge c => some (b2v (decide ((maskC c a0).toNat ≥ (maskC c b0).toNat)))

/-! ## Bit-vector facts -/

theorem testBit_low (k i : Nat) : Nat.testBit (2 ^ k - 1) i = decide (i < k) :=
  Nat.testBit_two_pow_sub_one k i

theorem and_low (k : Nat) (v : BitVec 64) :
    v &&& BitVec.ofNat 64 (2 ^ k - 1) = extU k v := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  simp only [extU, BitVec.getLsbD_and, BitVec.getLsbD_ofNat, BitVec.getLsbD_setWidth, testBit_low]
  by_cases h : i < k <;> simp [h, hi]

theorem extU_toNat (k : Nat) (hk : k ≤ 64) (v : BitVec 64) : (extU k v).toNat = v.toNat % 2 ^ k := by
  simp only [extU, BitVec.toNat_setWidth]
  apply Nat.mod_eq_of_lt
  have : v.toNat % 2 ^ k < 2 ^ k := Nat.mod_lt _ (Nat.two_pow_pos k)
  have : 2 ^ k ≤ 2 ^ 64 := Nat.pow_le_pow_right (by norm_num) hk
  omega

/-- The sign-extension pattern of `eval_un_const` / `sext32`. -/
theorem sext_pat (k : Nat) (hk1 : 1 ≤ k) (hk : k < 64) (v : BitVec 64) :
    (if (v &&& BitVec.ofNat 64 (2 ^ k - 1)) &&& BitVec.ofNat 64 (2 ^ (k - 1)) ≠ 0
      then (v &&& BitVec.ofNat 64 (2 ^ k - 1)) ||| ~~~(BitVec.ofNat 64 (2 ^ k - 1))
      else v &&& BitVec.ofNat 64 (2 ^ k - 1)) = extS k v := by
  have hbit : ∀ j, j < 64 → ((v &&& BitVec.ofNat 64 (2 ^ k - 1)) &&& BitVec.ofNat 64 (2 ^ (k - 1))).getLsbD j
      = (v.getLsbD j && decide (j = k - 1)) := by
    intro j hj
    simp only [BitVec.getLsbD_and, BitVec.getLsbD_ofNat, testBit_low, Nat.testBit_two_pow]
    by_cases h1 : j = k - 1
    · subst h1; simp [hj, show k - 1 < k by omega]
    · simp [h1, eq_comm]
  by_cases hb : v.getLsbD (k - 1) = true
  · have hne : (v &&& BitVec.ofNat 64 (2 ^ k - 1)) &&& BitVec.ofNat 64 (2 ^ (k - 1)) ≠ 0 := by
      intro h0
      have := hbit (k - 1) (by omega)
      rw [h0] at this
      simp [hb] at this
    simp only [ne_eq, hne, not_false_eq_true, ↓reduceIte]
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    simp only [extS, BitVec.getLsbD_or, BitVec.getLsbD_and, BitVec.getLsbD_not, BitVec.getLsbD_ofNat,
      testBit_low, BitVec.getLsbD_signExtend, BitVec.getLsbD_setWidth, BitVec.msb_setWidth]
    by_cases h : i < k
    · simp [h, hi]
    · simp [h, hi, hb, show 0 < k by omega]
  · have hb' : v.getLsbD (k - 1) = false := by simpa using hb
    have heq : (v &&& BitVec.ofNat 64 (2 ^ k - 1)) &&& BitVec.ofNat 64 (2 ^ (k - 1)) = 0 := by
      apply BitVec.eq_of_getLsbD_eq
      intro j hj
      rw [hbit j hj]
      by_cases h1 : j = k - 1
      · subst h1; simp [hb']
      · simp [h1]
    simp only [heq, ne_eq, not_true_eq_false, ↓reduceIte]
    rw [and_low]
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    simp only [extS, extU, BitVec.getLsbD_signExtend, BitVec.getLsbD_setWidth, BitVec.msb_setWidth]
    by_cases h : i < k
    · simp [h, hi]
    · simp [h, hi, hb', show 0 < k by omega]

theorem mask32_eq (x : BitVec 64) : x &&& 4294967295#64 = zx32 (lo32 x) := by
  have := and_low 32 x
  simpa [extU, zx32, lo32] using this

theorem maskW_eq (x : BitVec 64) : maskC .W x = extU 32 x := rfl

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

theorem maskW_maskC (c : Cls) (x : BitVec 64) : maskC .W (maskC c x) = maskC .W x := by
  cases c <;> simp [maskC, lo32_zx32]

theorem maskC_maskW (c : Cls) (x : BitVec 64) : maskC c (maskC .W x) = maskC .W x := by
  cases c <;> simp [maskC, lo32_zx32]

theorem maskC_toNat_le (c : Cls) (x : BitVec 64) : (maskC c x).toNat ≤ x.toNat := by
  cases c
  · simp only [maskC, zx32, lo32, BitVec.toNat_setWidth]
    have := x.isLt
    rw [Nat.mod_eq_of_lt (a := x.toNat % 2 ^ 32) (by have := Nat.mod_lt x.toNat (show 0 < 2 ^ 32 by norm_num); omega)]
    exact Nat.mod_le _ _
  · exact le_refl _

theorem maskW_toNat (x : BitVec 64) : (maskC .W x).toNat = x.toNat % 2 ^ 32 := by
  simp only [maskC, zx32, lo32, BitVec.toNat_setWidth]
  rw [Nat.mod_eq_of_lt (a := x.toNat % 2 ^ 32) (by have := Nat.mod_lt x.toNat (show 0 < 2 ^ 32 by norm_num); omega)]

theorem maskW_lt (x : BitVec 64) : (maskC .W x).toNat < 2 ^ 32 := by
  rw [maskW_toNat]; exact Nat.mod_lt _ (by norm_num)

theorem maskW_of_lt (x : BitVec 64) (h : x.toNat < 2 ^ 32) : maskC .W x = x := by
  apply BitVec.eq_of_toNat_eq
  rw [maskW_toNat, Nat.mod_eq_of_lt h]


/-! ## Scalars of the extracted code -/

theorem u64_ext {x y : Std.U64} (h : x.bv = y.bv) : x = y := by
  cases x; cases y; cases h; rfl

theorem u64_ne {x y : Std.U64} : x ≠ y ↔ x.bv ≠ y.bv :=
  ⟨fun h e => h (u64_ext e), fun h e => h (by rw [e])⟩

theorem u64_eq {x y : Std.U64} : x = y ↔ x.bv = y.bv :=
  ⟨fun e => by rw [e], u64_ext⟩

theorem i32_ext' {x y : Std.I32} (h : x.bv = y.bv) : x = y := by
  cases x; cases y; cases h; rfl

@[simp] theorem u64_mk_bv (x : BitVec 64) : (⟨x⟩ : Std.U64).bv = x := rfl
@[simp] theorem band_bv (x y : Std.U64) : (Pion.U64.band x y).bv = x.bv &&& y.bv := rfl
@[simp] theorem bor_bv (x y : Std.U64) : (Pion.U64.bor x y).bv = x.bv ||| y.bv := rfl
@[simp] theorem bxor_bv (x y : Std.U64) : (Pion.U64.bxor x y).bv = x.bv ^^^ y.bv := rfl
@[simp] theorem add_bv (x y : Std.U64) : (Pion.U64.add x y).bv = x.bv + y.bv := by
  simp [Pion.U64.add]
@[simp] theorem sub_bv (x y : Std.U64) : (Pion.U64.sub x y).bv = x.bv - y.bv := by
  simp [Pion.U64.sub]
@[simp] theorem mul_bv (x y : Std.U64) : (Pion.U64.mul x y).bv = x.bv * y.bv := by
  simp [Pion.U64.mul]

theorem bv_255 : (255#u64 : Std.U64).bv = BitVec.ofNat 64 (2 ^ 8 - 1) := rfl
theorem bv_128 : (128#u64 : Std.U64).bv = BitVec.ofNat 64 (2 ^ (8 - 1)) := rfl
theorem bv_ff00 : (18446744073709551360#u64 : Std.U64).bv = ~~~(BitVec.ofNat 64 (2 ^ 8 - 1)) := by decide
theorem bv_65535 : (65535#u64 : Std.U64).bv = BitVec.ofNat 64 (2 ^ 16 - 1) := rfl
theorem bv_32768 : (32768#u64 : Std.U64).bv = BitVec.ofNat 64 (2 ^ (16 - 1)) := rfl
theorem bv_ffff0000 : (18446744073709486080#u64 : Std.U64).bv = ~~~(BitVec.ofNat 64 (2 ^ 16 - 1)) := by decide
theorem bv_m32 : (4294967295#u64 : Std.U64).bv = BitVec.ofNat 64 (2 ^ 32 - 1) := rfl
theorem bv_2p31 : (2147483648#u64 : Std.U64).bv = BitVec.ofNat 64 (2 ^ (32 - 1)) := rfl
theorem bv_hi32 : (18446744069414584320#u64 : Std.U64).bv = ~~~(BitVec.ofNat 64 (2 ^ 32 - 1)) := by decide
theorem bv_zero : (0#u64 : Std.U64).bv = 0 := rfl
theorem bv_ones : (18446744073709551615#u64 : Std.U64).bv = -1#64 := by decide

theorem ite_t {α : Type} {p : Prop} [Decidable p] (h : p) (a b : α) : (if p then a else b) = a := by
  simp [h]

theorem ite_f {α : Type} {p : Prop} [Decidable p] (h : ¬ p) (a b : α) : (if p then a else b) = b := by
  simp [h]

@[simp] theorem u64_val_mk (p : BitVec 64) : (⟨p⟩ : Std.U64).val = p.toNat := rfl
@[simp] theorem i64_val_mk (p : BitVec 64) : (⟨p⟩ : Std.I64).val = p.toInt := rfl

/-- The sign-extension pattern on `Std.U64`. -/
theorem sext_u64 (k : Nat) (hk1 : 1 ≤ k) (hk : k < 64) (v M T H : Std.U64)
    (hM : M.bv = BitVec.ofNat 64 (2 ^ k - 1)) (hT : T.bv = BitVec.ofNat 64 (2 ^ (k - 1)))
    (hH : H.bv = ~~~(BitVec.ofNat 64 (2 ^ k - 1))) :
    (if Pion.U64.band (Pion.U64.band v M) T ≠ 0#u64 then Pion.U64.bor (Pion.U64.band v M) H
      else Pion.U64.band v M) = ⟨extS k v.bv⟩ := by
  have hc : (Pion.U64.band (Pion.U64.band v M) T ≠ 0#u64) ↔
      ((v.bv &&& BitVec.ofNat 64 (2 ^ k - 1)) &&& BitVec.ofNat 64 (2 ^ (k - 1)) ≠ 0) := by
    rw [u64_ne]; simp only [band_bv, hM, hT, bv_zero]
  have hs := sext_pat k hk1 hk v.bv
  by_cases h : (v.bv &&& BitVec.ofNat 64 (2 ^ k - 1)) &&& BitVec.ofNat 64 (2 ^ (k - 1)) ≠ 0
  · have h1 := hc.2 h
    simp only [ne_eq] at h1
    simp only [ne_eq, h1, not_false_eq_true, ↓reduceIte]
    simp only [h, ne_eq, not_false_eq_true, ↓reduceIte] at hs
    apply u64_ext
    simp only [bor_bv, band_bv, hM, hH, u64_mk_bv, hs]
  · have h0 : Pion.U64.band (Pion.U64.band v M) T = 0#u64 := by
      by_contra e; exact h (hc.1 e)
    simp only [h0, ne_eq, not_true_eq_false, ↓reduceIte]
    simp only [h, ↓reduceIte] at hs
    apply u64_ext
    simp only [band_bv, hM, u64_mk_bv, hs]

/-- `sext32`. -/
theorem sext32_spec (v : Std.U64) : sext32 v = ok ⟨extS 32 v.bv⟩ := by
  simp only [sext32, sext_u64 32 (by norm_num) (by norm_num) v _ _ _ bv_m32 bv_2p31 bv_hi32]

/-- `as_signed`. -/
theorem as_signed_spec (c : Cls) (v : Std.U64) : as_signed c v = ok ⟨asS c v.bv⟩ := by
  cases c
  · simp only [as_signed, sext32_spec, Pion.U64.reinterpret_as_int64, UScalar.hcast, asS]
    simp
  · simp only [as_signed, Pion.U64.reinterpret_as_int64, UScalar.hcast, asS]
    simp

/-- The `Int` count of `shift_amount`. -/
def saI (c : Cls) (b : Std.U64) : Std.I32 :=
  match c with
  | .W => Pion.U64.to_int (Pion.U64.band b 31#u64)
  | .L => Pion.U64.to_int (Pion.U64.band b 63#u64)

theorem shift_amount_spec (c : Cls) (b : Std.U64) : shift_amount c b = ok (saI c b) := by
  cases c <;> rfl

theorem shAmt_lt (c : Cls) (b : BitVec 64) : shAmt c b < 64 := by
  cases c <;> simp only [shAmt] <;> omega

theorem saI_val (c : Cls) (b : Std.U64) : (saI c b).val = (shAmt c b.bv : Int) := by
  have h31 : (31#u64 : Std.U64).bv = BitVec.ofNat 64 (2 ^ 5 - 1) := rfl
  have h63 : (63#u64 : Std.U64).bv = BitVec.ofNat 64 (2 ^ 6 - 1) := rfl
  cases c
  · simp only [saI, shAmt, Pion.U64.to_int, Pion.U64.band, UScalar.hcast, IScalar.val, h31, and_low]
    rw [BitVec.toInt_eq_toNat_of_lt]
    · simp only [BitVec.toNat_setWidth, extU_toNat 5 (by norm_num)]
      have : b.bv.toNat % 2 ^ 5 < 2 ^ 5 := Nat.mod_lt _ (by norm_num)
      norm_num
      omega
    · simp only [BitVec.toNat_setWidth, extU_toNat 5 (by norm_num)]
      have : b.bv.toNat % 2 ^ 5 < 2 ^ 5 := Nat.mod_lt _ (by norm_num)
      norm_num
      omega
  · simp only [saI, shAmt, Pion.U64.to_int, Pion.U64.band, UScalar.hcast, IScalar.val, h63, and_low]
    rw [BitVec.toInt_eq_toNat_of_lt]
    · simp only [BitVec.toNat_setWidth, extU_toNat 6 (by norm_num)]
      have : b.bv.toNat % 2 ^ 6 < 2 ^ 6 := Nat.mod_lt _ (by norm_num)
      norm_num
      omega
    · simp only [BitVec.toNat_setWidth, extU_toNat 6 (by norm_num)]
      have : b.bv.toNat % 2 ^ 6 < 2 ^ 6 := Nat.mod_lt _ (by norm_num)
      norm_num
      omega

theorem shl_sa (c : Cls) (a b : Std.U64) :
    Pion.U64.shl_i32 a (saI c b) = ok ⟨a.bv <<< shAmt c b.bv⟩ := by
  have := shAmt_lt c b.bv
  simp only [Pion.U64.shl_i32, saI_val]
  have hc : (0 : Int) ≤ (shAmt c b.bv : Int) ∧ (shAmt c b.bv : Int) < 64 := by omega
  simp only [hc.1, hc.2, and_self, ↓reduceIte]
  rfl

theorem shr_sa (c : Cls) (a b : Std.U64) :
    Pion.U64.shr_i32 a (saI c b) = ok ⟨a.bv >>> shAmt c b.bv⟩ := by
  have := shAmt_lt c b.bv
  simp only [Pion.U64.shr_i32, saI_val]
  have hc : (0 : Int) ≤ (shAmt c b.bv : Int) ∧ (shAmt c b.bv : Int) < 64 := by omega
  simp only [hc.1, hc.2, and_self, ↓reduceIte]
  rfl

theorem sar_sa (c : Cls) (a : Std.I64) (b : Std.U64) :
    Pion.I64.shr_i32 a (saI c b) = ok ⟨a.bv.sshiftRight (shAmt c b.bv)⟩ := by
  have := shAmt_lt c b.bv
  simp only [Pion.I64.shr_i32, saI_val]
  have hc : (0 : Int) ≤ (shAmt c b.bv : Int) ∧ (shAmt c b.bv : Int) < 64 := by omega
  simp only [hc.1, hc.2, and_self, ↓reduceIte]
  rfl

/-! ## The constant evaluator is exact -/

theorem eval_un_const_sound (cls : Cls) (op : UnOp) (v : Std.U64) :
    eval_un_const cls op v = ok ⟨evalUn cls op v.bv⟩ := by
  cases op
  · simp [eval_un_const, evalUn, mask_cls_spec]
  · simp [eval_un_const, evalUn, mask_cls_spec, Std.U64.wrapping_sub_bv_eq]
  · simp only [eval_un_const, evalUn,
      sext_u64 8 (by norm_num) (by norm_num) v _ _ _ bv_255 bv_128 bv_ff00, mask_cls_spec]
    simp
  · simp only [eval_un_const, evalUn, mask_cls_spec, Pion.U64.band, bv_255, and_low]
    simp
  · simp only [eval_un_const, evalUn,
      sext_u64 16 (by norm_num) (by norm_num) v _ _ _ bv_65535 bv_32768 bv_ffff0000, mask_cls_spec]
    simp
  · simp only [eval_un_const, evalUn, mask_cls_spec, Pion.U64.band, bv_65535, and_low]
    simp
  · simp only [eval_un_const, evalUn, sext32_spec, mask_cls_spec]
    simp
  · simp only [eval_un_const, evalUn, mask_cls_spec, Pion.U64.band, bv_m32, and_low]
    simp

theorem bool_u64_spec (b : Bool) : bool_u64 b = ok ⟨b2v b⟩ := by
  cases b <;> rfl

theorem all_ones_spec (c : Cls) : all_ones c = ok ⟨allOnesC c⟩ := by
  simp only [all_ones, mask_cls_spec, allOnesC, bv_ones]
  simp

theorem int_min_of_spec (c : Cls) : int_min_of c = ok ⟨intMinC c⟩ := by
  cases c <;> rfl

theorem is_signed_div_spec (op : BinOp) : is_signed_div op = ok (signedDivOp op) := by
  cases op <;> rfl

theorem allOnesC_ne (c : Cls) : allOnesC c ≠ 0 := by
  cases c <;> decide

theorem is_safe_div_const_spec (c : Cls) (op : BinOp) (l r : Std.U64) :
    is_safe_div_const c op (some l) r = ok (decide (safeDiv c op l.bv r.bv)) := by
  simp only [is_safe_div_const, mask_cls_spec, is_signed_div_spec, all_ones_spec,
    int_min_of_spec, bind_ok]
  by_cases h0 : maskC c r.bv = 0
  · rw [ite_t (u64_ext (by simp [h0, bv_zero]) : (⟨maskC c r.bv⟩ : Std.U64) = 0#u64)]
    simp [safeDiv, h0]
  · rw [ite_f (fun e => h0 (by simpa [bv_zero] using congrArg (·.bv) e) :
      ¬ (⟨maskC c r.bv⟩ : Std.U64) = 0#u64)]
    cases hs : signedDivOp op
    · simp [safeDiv, h0, hs]
      exact h0
    · by_cases h1 : maskC c r.bv = allOnesC c <;> by_cases h2 : maskC c l.bv = intMinC c <;>
        simp [safeDiv, h0, h1, h2, hs, u64_eq, allOnesC_ne] <;>
        first
        | exact h0
        | exact allOnesC_ne c
        | (rw [Bool.eq_iff_iff]; simp [h2, u64_eq, allOnesC_ne]; try exact allOnesC_ne c)

theorem toInt_extS32_lt (x : BitVec 64) : (extS 32 x).toInt < 2 ^ 31 := by
  simp only [extS]
  rw [BitVec.toInt_signExtend_of_le (by norm_num)]
  have := BitVec.toInt_lt (x := x.setWidth 32)
  simpa using this

theorem le_toInt_extS32 (x : BitVec 64) : -2 ^ 31 ≤ (extS 32 x).toInt := by
  simp only [extS]
  rw [BitVec.toInt_signExtend_of_le (by norm_num)]
  have := BitVec.le_toInt (x.setWidth 32)
  simpa using this

theorem extS32_eq_zero (x : BitVec 64) : extS 32 x = 0 ↔ maskC .W x = 0 := by
  constructor
  · intro h
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    have := congrArg (fun y => y.getLsbD i) h
    simp only [extS, BitVec.getLsbD_signExtend, BitVec.getLsbD_setWidth, BitVec.getLsbD_zero] at this
    simp only [maskC, zx32, lo32, BitVec.getLsbD_setWidth, BitVec.getLsbD_zero]
    by_cases h' : i < 32 <;> simp_all
  · intro h
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    have h7 := congrArg (fun y => y.getLsbD 31) h
    simp only [maskC, zx32, lo32, BitVec.getLsbD_setWidth, BitVec.getLsbD_zero] at h7
    have := congrArg (fun y => y.getLsbD i) h
    simp only [maskC, zx32, lo32, BitVec.getLsbD_setWidth, BitVec.getLsbD_zero] at this
    simp only [extS, BitVec.getLsbD_signExtend, BitVec.getLsbD_setWidth, BitVec.getLsbD_zero,
      BitVec.msb_setWidth]
    by_cases h' : i < 32 <;> simp_all

theorem asS_ne_zero (c : Cls) (b : BitVec 64) (h : maskC c b ≠ 0) : asS c b ≠ 0 := by
  cases c
  · simp only [asS]; rw [Ne, extS32_eq_zero]; exact h
  · exact h

theorem i64_val (p : BitVec 64) : (⟨p⟩ : Std.I64).val = p.toInt := rfl

theorem asS_no_ovf (c : Cls) (a b : BitVec 64)
    (h : maskC c b = allOnesC c → maskC c a ≠ intMinC c) :
    ¬ ((asS c a).toInt = -9223372036854775808 ∧ (asS c b).toInt = -1) := by
  cases c
  · intro ⟨h1, _⟩
    have := le_toInt_extS32 a
    simp only [asS] at h1
    omega
  · intro ⟨h1, h2⟩
    simp only [asS] at h1 h2
    have hb : b = -1#64 := by
      apply BitVec.eq_of_toInt_eq; rw [h2]; rfl
    have ha : a = 9223372036854775808#64 := by
      apply BitVec.eq_of_toInt_eq; rw [h1]; rfl
    exact h (by simp [maskC, allOnesC, hb]) (by simp [maskC, intMinC, ha])

theorem i64_div_ok (x y : BitVec 64) (h0 : y ≠ 0)
    (h1 : ¬ (x.toInt = -9223372036854775808 ∧ y.toInt = -1)) :
    Pion.I64.div (⟨x⟩ : Std.I64) (⟨y⟩ : Std.I64) = ok (⟨x.sdiv y⟩ : Std.I64) := by
  have hy : y.toInt ≠ 0 := by
    intro e; apply h0; apply BitVec.eq_of_toInt_eq; rw [e]; rfl
  have hc1 : (((⟨y⟩ : Std.I64).val != 0) = true) := by simp [hy]
  have hc2 : ¬ ((((⟨x⟩ : Std.I64).val = IScalar.min .I64) && ((⟨y⟩ : Std.I64).val = -1)) = true) := by
    simp only [IScalar.min_IScalarTy_I64_eq, I64.min_eq, i64_val_mk, Bool.and_eq_true,
      decide_eq_true_eq]
    exact h1
  show IScalar.div (ty := .I64) ⟨x⟩ ⟨y⟩ = _
  unfold IScalar.div
  rw [ite_t hc1, ite_t hc2]

theorem i64_rem_ok (x y : BitVec 64) (h0 : y ≠ 0)
    (h1 : ¬ (x.toInt = -9223372036854775808 ∧ y.toInt = -1)) :
    Pion.I64.rem (⟨x⟩ : Std.I64) (⟨y⟩ : Std.I64) = ok (⟨x.srem y⟩ : Std.I64) := by
  have hy : y.toInt ≠ 0 := by
    intro e; apply h0; apply BitVec.eq_of_toInt_eq; rw [e]; rfl
  have hc1 : (((⟨y⟩ : Std.I64).val != 0) = true) := by simp [hy]
  unfold Pion.I64.rem
  rw [ite_f (by simpa using h1)]
  show IScalar.rem (ty := .I64) ⟨x⟩ ⟨y⟩ = _
  unfold IScalar.rem
  rw [ite_t hc1]

theorem u64_div_ok (x y : BitVec 64) (h0 : y ≠ 0) :
    Pion.U64.div (⟨x⟩ : Std.U64) (⟨y⟩ : Std.U64) = ok (⟨x / y⟩ : Std.U64) := by
  have hc1 : (((⟨y⟩ : Std.U64).bv != 0) = true) := by
    simp only [bne_iff_ne, ne_eq, u64_mk_bv]; exact h0
  show UScalar.div (ty := .U64) ⟨x⟩ ⟨y⟩ = _
  unfold UScalar.div
  rw [ite_t hc1]
  all_goals rfl

theorem u64_rem_ok (x y : BitVec 64) (h0 : y ≠ 0) :
    Pion.U64.rem (⟨x⟩ : Std.U64) (⟨y⟩ : Std.U64) = ok (⟨x % y⟩ : Std.U64) := by
  have hy : y.toNat ≠ 0 := by
    intro e; apply h0; apply BitVec.eq_of_toNat_eq; rw [e]; rfl
  have hc1 : (((⟨y⟩ : Std.U64).val != 0) = true) := by simp [hy]
  show UScalar.rem (ty := .U64) ⟨x⟩ ⟨y⟩ = _
  unfold UScalar.rem
  rw [ite_t hc1]
  all_goals rfl

theorem i64_reinterpret (p : BitVec 64) : Pion.I64.reinterpret_as_uint64 ⟨p⟩ = ⟨p⟩ := by
  simp [Pion.I64.reinterpret_as_uint64, IScalar.hcast]

private def clsBitsI : Cls → Std.I32
  | .W => 32#i32
  | .L => 64#i32

private def clsBitsN : Cls → Nat
  | .W => 32
  | .L => 64

private theorem cls_bits_spec (c : Cls) : cls_bits c = ok (clsBitsI c) := by
  cases c <;> rfl

private theorem saI_eq_zero_iff (c : Cls) (b : Std.U64) :
    saI c b = 0#i32 ↔ shAmt c b.bv = 0 := by
  constructor
  · intro h
    have hv := congrArg (·.val) h
    rw [saI_val] at hv
    change (shAmt c b.bv : Int) = 0 at hv
    omega
  · intro h
    cases hs : saI c b with
    | mk bv =>
      have hv : bv.toInt = 0 := by
        have h1 := saI_val c b
        rw [hs] at h1
        simpa [IScalar.val, h] using h1
      congr 1
      apply BitVec.eq_of_toInt_eq
      exact hv

private theorem shl_wsub_sa (c : Cls) (a b : Std.U64) (hs : shAmt c b.bv ≠ 0) :
    Pion.U64.shl_i32 a (Pion.I32.sub (clsBitsI c) (saI c b)) =
      ok ⟨a.bv <<< (clsBitsN c - shAmt c b.bv)⟩ := by
  have hval : (Pion.I32.sub (clsBitsI c) (saI c b)).val =
      (clsBitsN c - shAmt c b.bv : Nat) := by
    cases c
    · have hlt : shAmt .W b.bv < 32 := Nat.mod_lt _ (by norm_num)
      have hv := saI_val .W b
      simp only [clsBitsI, clsBitsN, Pion.I32.sub, IScalar.val, Std.I32.wrapping_sub_bv_eq]
      rw [BitVec.toInt_sub]
      have h32 : (32#i32 : Std.I32).bv.toInt = 32 := rfl
      have hsb : (saI .W b).bv.toInt = (shAmt .W b.bv : Int) := hv
      rw [h32, hsb, Int.bmod_eq_of_le (by simp [IScalarTy.numBits]; omega) (by simp [IScalarTy.numBits]; omega)]
      omega
    · have hlt : shAmt .L b.bv < 64 := Nat.mod_lt _ (by norm_num)
      have hv := saI_val .L b
      simp only [clsBitsI, clsBitsN, Pion.I32.sub, IScalar.val, Std.I32.wrapping_sub_bv_eq]
      rw [BitVec.toInt_sub]
      have h64 : (64#i32 : Std.I32).bv.toInt = 64 := rfl
      have hsb : (saI .L b).bv.toInt = (shAmt .L b.bv : Int) := hv
      rw [h64, hsb, Int.bmod_eq_of_le (by simp [IScalarTy.numBits]; omega) (by simp [IScalarTy.numBits]; omega)]
      omega
  simp only [Pion.U64.shl_i32, hval]
  have hlt : clsBitsN c - shAmt c b.bv < 64 := by
    cases c <;> simp only [clsBitsN, shAmt] at hs ⊢ <;> omega
  have hc : (0 : Int) ≤ ((clsBitsN c - shAmt c b.bv : Nat) : Int) ∧
      ((clsBitsN c - shAmt c b.bv : Nat) : Int) < 64 := by omega
  simp only [hc.1, hc.2, and_self, ↓reduceIte, Int.toNat_natCast]

/-- `eval_bin_const` computes `evalBin` (`none` exactly on a trapping division). -/
theorem eval_bin_const_sound (cls : Cls) (op : BinOp) (a b : Std.U64) :
    eval_bin_const cls op a b = ok ((evalBin cls op a.bv b.bv).map (fun x => (⟨x⟩ : Std.U64))) := by
  cases op <;>
    simp only [eval_bin_const, evalBin, mask_cls_spec, bind_ok, Option.map_some,
      shift_amount_spec, as_signed_spec, bool_u64_spec, is_safe_div_const_spec, u64_mk_bv,
      i64_reinterpret]
  case Add | Sub | Mul | And | Or | Xor => simp
  case Shl => rw [shl_sa]; simp
  case Shr => rw [shr_sa]; simp
  case Sar => rw [sar_sa]; simp [i64_reinterpret]
  case Ror =>
    by_cases hs : shAmt cls b.bv = 0
    · have h0 : saI cls b = 0#i32 := (saI_eq_zero_iff cls b).2 hs
      simp only [hs, h0, ↓reduceIte, Option.map_some]
    · have h0 : saI cls b ≠ 0#i32 := fun h => hs ((saI_eq_zero_iff cls b).1 h)
      simp only [hs, h0, ↓reduceIte, shr_sa, cls_bits_spec, bind_ok]
      rw [shl_wsub_sa cls ⟨maskC cls a.bv⟩ b hs]
      cases cls <;> simp only [clsBitsN, bind_ok, Pion.U64.bor, u64_mk_bv, Option.map_some]
  case Div =>
    by_cases hs : safeDiv cls .Div (maskC cls a.bv) (maskC cls b.bv)
    · simp only [hs, decide_true, ↓reduceIte]
      rw [i64_div_ok _ _ (asS_ne_zero cls _ hs.1) (asS_no_ovf cls _ _ (hs.2 rfl))]
      simp [i64_reinterpret]
    · simp only [hs, decide_false, ↓reduceIte]
      rfl
  case Rem =>
    by_cases hs : safeDiv cls .Rem (maskC cls a.bv) (maskC cls b.bv)
    · simp only [hs, decide_true, ↓reduceIte]
      rw [i64_rem_ok _ _ (asS_ne_zero cls _ hs.1) (asS_no_ovf cls _ _ (hs.2 rfl))]
      simp [i64_reinterpret]
    · simp only [hs, decide_false, ↓reduceIte]
      rfl
  case UDiv =>
    by_cases hs : safeDiv cls .UDiv (maskC cls a.bv) (maskC cls b.bv)
    · simp only [hs, decide_true, ↓reduceIte]
      rw [u64_div_ok _ _ (by simpa [maskC_idem] using hs.1)]
      simp
    · simp only [hs, decide_false, ↓reduceIte]
      rfl
  case URem =>
    by_cases hs : safeDiv cls .URem (maskC cls a.bv) (maskC cls b.bv)
    · simp only [hs, decide_true, ↓reduceIte]
      rw [u64_rem_ok _ _ (by simpa [maskC_idem] using hs.1)]
      simp
    · simp only [hs, decide_false, ↓reduceIte]
      rfl
  case CEq c | CNe c =>
    congr 2
  all_goals rfl

/-! ## Lawful `==` on the extracted enums -/

instance : LawfulBEq Cls where
  eq_of_beq {a b} h := by cases a <;> cases b <;> first | rfl | cases h
  rfl {a} := by cases a <;> rfl

instance : LawfulBEq UnOp where
  eq_of_beq {a b} h := by cases a <;> cases b <;> first | rfl | cases h
  rfl {a} := by cases a <;> rfl

instance : LawfulBEq BinOp where
  eq_of_beq {a b} h := by
    cases a <;> cases b <;> (try (rename_i c c'; cases c <;> cases c')) <;> first | rfl | cases h
  rfl {a} := by cases a <;> (try (rename_i c; cases c)) <;> rfl

theorem symnode_eq_of_beq {a b : SymNode} (h : (a == b) = true) : a = b := by
  cases a <;> cases b <;> first
    | cases h
    | (rename_i x x'
       have h' : (x == x') = true := h
       simp only [beq_iff_eq] at h'
       simp only [h'])
    | (rename_i x y x' y'
       have h' : (x == x' && y == y') = true := h
       simp only [Bool.and_eq_true, beq_iff_eq] at h'
       simp only [h'])
    | (rename_i x y z x' y' z'
       have h' : (x == x' && (y == y' && z == z')) = true := h
       simp only [Bool.and_eq_true, beq_iff_eq] at h'
       simp only [h'])
    | (rename_i x y z t x' y' z' t'
       have h' : (x == x' && (y == y' && (z == z' && t == t'))) = true := h
       simp only [Bool.and_eq_true, beq_iff_eq] at h'
       simp only [h'])

theorem symnode_beq_self (a : SymNode) : (a == a) = true := by
  cases a <;> first
    | (rename_i x y z t; exact (show (x == x && (y == y && (z == z && t == t))) = true by simp))
    | (rename_i x y z; exact (show (x == x && (y == y && z == z)) = true by simp))
    | (rename_i x y; exact (show (x == x && y == y) = true by simp))
    | (rename_i x; exact (show (x == x) = true by simp))

instance : LawfulBEq SymNode where
  eq_of_beq := symnode_eq_of_beq
  rfl := symnode_beq_self _

/-- `sym_node_eq` is equality. -/
theorem sym_node_eq_ok {a b : SymNode} {r : Bool} (h : sym_node_eq a b = ok r) :
    r = true ↔ a = b := by
  simp only [sym_node_eq] at h
  rw [← ok_inj' h]
  exact beq_iff_eq

/-! ## The symbolic value graph -/

/-- The source-function values the leaves of a value graph stand for. -/
structure SymEnv where
  paramVal : Cls → Std.I32 → BitVec 64
  phiVal : Cls → Std.I32 → Std.I32 → BitVec 64
  effVal : Cls → Std.I32 → Std.I32 → BitVec 64
  symAddr : Std.I32 → BitVec 64

/-- The class of a node (`vg_cls`). -/
def nodeCls : SymNode → Cls
  | .SConst c _ => c
  | .SSym _ => .L
  | .SParam c _ => c
  | .SPhi c _ _ => c
  | .SEffect c _ _ => c
  | .SUn c _ _ => c
  | .SBin c _ _ _ => c

/-- The value of one node given the values `sub` of its children. A trapping
`SBin` (never built by `vg_canon_bin`) denotes `0`. -/
def evalNode (env : SymEnv) (sub : Std.I32 → BitVec 64) : SymNode → BitVec 64
  | .SConst c x => maskC c x.bv
  | .SSym s => env.symAddr s
  | .SParam c k => maskC c (env.paramVal c k)
  | .SPhi c b k => maskC c (env.phiVal c b k)
  | .SEffect c b i => maskC c (env.effVal c b i)
  | .SUn c op a => evalUn c op (sub a)
  | .SBin c op a b => (evalBin c op (sub a) (sub b)).getD 0

/-- The value of node `i`: children are read only below `i` (others, which
`check_vg_dag` rejects, read as `0`), so this is a total, fuel-free
structural recursion. -/
def evalSym (vg : ValGraph) (env : SymEnv) (i : Nat) : BitVec 64 :=
  match vg.nodes.val[i]? with
  | none => 0
  | some n =>
    evalNode env (fun a => if h : 0 ≤ a.val ∧ a.val.toNat < i then evalSym vg env a.val.toNat else 0) n
termination_by i
decreasing_by omega

/-- The value of the node with id `a`. -/
abbrev evI (vg : ValGraph) (env : SymEnv) (a : Std.I32) : BitVec 64 := evalSym vg env a.val.toNat

def nodeAt (vg : ValGraph) (a : Std.I32) : Option SymNode :=
  if 0 ≤ a.val then vg.nodes.val[a.val.toNat]? else none

def Valid (vg : ValGraph) (a : Std.I32) : Prop :=
  0 ≤ a.val ∧ a.val.toNat < vg.nodes.val.length

/-- `vg_cls`. -/
instance (vg : ValGraph) (a : Std.I32) : Decidable (Valid vg a) := by
  unfold Valid; infer_instance

/-- `vg_cls`. -/
def clsOf (vg : ValGraph) (a : Std.I32) : Cls :=
  match nodeAt vg a with
  | some n => nodeCls n
  | none => .L

/-- `vg_const`: the (masked) constant a node denotes. -/
def constOf (vg : ValGraph) (a : Std.I32) : Option (BitVec 64) :=
  match nodeAt vg a with
  | some (.SConst c x) => some (maskC c x.bv)
  | _ => none

/-- The children of a node sit below index `i`. -/
def childrenBelow (n : SymNode) (i : Nat) : Prop :=
  match n with
  | .SUn _ _ a => 0 ≤ a.val ∧ a.val.toNat < i
  | .SBin _ _ a b => (0 ≤ a.val ∧ a.val.toNat < i) ∧ (0 ≤ b.val ∧ b.val.toNat < i)
  | _ => True

/-- Every child index of node `i` is strictly smaller than `i`. -/
def ValGraphDAG (vg : ValGraph) : Prop :=
  ∀ i n, vg.nodes.val[i]? = some n → childrenBelow n i

/-- `vg'` only appends to `vg`. -/
def vg_extends (vg vg' : ValGraph) : Prop := vg.nodes.val <+: vg'.nodes.val

theorem vg_extends_refl (vg : ValGraph) : vg_extends vg vg := List.prefix_refl _

theorem vg_extends_trans {a b c : ValGraph} (h1 : vg_extends a b) (h2 : vg_extends b c) :
    vg_extends a c := List.IsPrefix.trans h1 h2

theorem prefix_getElem? {α : Type} {l l' : List α} (hp : l <+: l') {i : Nat} (hi : i < l.length) :
    l'[i]? = l[i]? := by
  obtain ⟨t, rfl⟩ := hp
  simp [List.getElem?_append_left hi]

theorem prefix_length {α : Type} {l l' : List α} (hp : l <+: l') : l.length ≤ l'.length :=
  hp.length_le

theorem evalSym_unfold (vg : ValGraph) (env : SymEnv) (i : Nat) :
    evalSym vg env i = match vg.nodes.val[i]? with
      | none => 0
      | some n => evalNode env
          (fun a => if h : 0 ≤ a.val ∧ a.val.toNat < i then evalSym vg env a.val.toNat else 0) n := by
  rw [evalSym]

theorem evalNode_congr (env : SymEnv) (n : SymNode) (sub sub' : Std.I32 → BitVec 64)
    (h : ∀ a, (match n with
      | .SUn _ _ x => a = x
      | .SBin _ _ x y => a = x ∨ a = y
      | _ => False) → sub a = sub' a) :
    evalNode env sub n = evalNode env sub' n := by
  cases n <;> simp only [evalNode] at h ⊢
  · rw [h _ rfl]
  · rw [h _ (Or.inl rfl), h _ (Or.inr rfl)]

/-- Appending nodes keeps the value of every old node. -/
theorem evalSym_extends {vg vg' : ValGraph} (hp : vg_extends vg vg') (env : SymEnv) :
    ∀ i, i < vg.nodes.val.length → evalSym vg' env i = evalSym vg env i := by
  intro i
  induction i using Nat.strong_induction_on with
  | _ i ih =>
    intro hi
    rw [evalSym_unfold vg', evalSym_unfold vg, prefix_getElem? hp hi]
    cases vg.nodes.val[i]? with
    | none => rfl
    | some n =>
      apply evalNode_congr
      intro a _
      by_cases h : 0 ≤ a.val ∧ a.val.toNat < i
      · simp only [h, and_self, ↓reduceDIte]
        exact ih _ h.2 (by omega)
      · simp only [h, ↓reduceDIte]

theorem nodeAt_some {vg : ValGraph} {a : Std.I32} {n : SymNode} (h : nodeAt vg a = some n) :
    0 ≤ a.val ∧ vg.nodes.val[a.val.toNat]? = some n := by
  unfold nodeAt at h
  split at h
  · exact ⟨by assumption, h⟩
  · cases h

theorem nodeAt_valid {vg : ValGraph} {a : Std.I32} {n : SymNode} (h : nodeAt vg a = some n) :
    Valid vg a := by
  obtain ⟨h0, h1⟩ := nodeAt_some h
  refine ⟨h0, ?_⟩
  by_contra hc
  rw [List.getElem?_eq_none (by omega)] at h1
  cases h1

theorem valid_nodeAt {vg : ValGraph} {a : Std.I32} (h : Valid vg a) :
    nodeAt vg a = some (vg.nodes.val[a.val.toNat]'h.2) := by
  simp [nodeAt, h.1, h.2]

/-- The value of a node of a DAG, from the values of its children. -/
theorem evI_node {vg : ValGraph} (hd : ValGraphDAG vg) (env : SymEnv) {a : Std.I32} {n : SymNode}
    (h : nodeAt vg a = some n) : evI vg env a = evalNode env (evI vg env) n := by
  obtain ⟨h0, h1⟩ := nodeAt_some h
  have hc := hd _ _ h1
  simp only [evI]
  rw [evalSym_unfold, h1]
  apply evalNode_congr
  intro x hx
  have hx' : 0 ≤ x.val ∧ x.val.toNat < a.val.toNat := by
    cases n <;> simp only [childrenBelow] at hc hx
    · subst hx; exact hc
    · rcases hx with rfl | rfl
      · exact hc.1
      · exact hc.2
  simp only [hx', and_self, ↓reduceDIte]

theorem extends_valid {vg vg' : ValGraph} (hp : vg_extends vg vg') {a : Std.I32} (h : Valid vg a) :
    Valid vg' a := ⟨h.1, Nat.lt_of_lt_of_le h.2 (prefix_length hp)⟩

theorem extends_nodeAt {vg vg' : ValGraph} (hp : vg_extends vg vg') {a : Std.I32} (h : Valid vg a) :
    nodeAt vg' a = nodeAt vg a := by
  simp only [nodeAt, h.1, ↓reduceIte]
  exact prefix_getElem? hp h.2

theorem extends_clsOf {vg vg' : ValGraph} (hp : vg_extends vg vg') {a : Std.I32} (h : Valid vg a) :
    clsOf vg' a = clsOf vg a := by
  simp only [clsOf, extends_nodeAt hp h]

theorem extends_constOf {vg vg' : ValGraph} (hp : vg_extends vg vg') {a : Std.I32} (h : Valid vg a) :
    constOf vg' a = constOf vg a := by
  simp only [constOf, extends_nodeAt hp h]

theorem extends_evI {vg vg' : ValGraph} (hp : vg_extends vg vg') (env : SymEnv) {a : Std.I32}
    (h : Valid vg a) : evI vg' env a = evI vg env a :=
  evalSym_extends hp env _ h.2

theorem maskW_fix_iff (v : BitVec 64) : maskC .W v = v ↔ v.toNat < 2 ^ 32 := by
  constructor
  · intro h; rw [← h]; exact maskW_lt v
  · exact maskW_of_lt v

theorem b2v_toNat_le (b : Bool) : (b2v b).toNat ≤ 1 := by
  cases b <;> simp [b2v]

/-- Every result of `evalBin cls` is kept at class `cls`. -/
theorem evalBin_masked {c : Cls} {op : BinOp} {x y v : BitVec 64} (h : evalBin c op x y = some v) :
    maskC c v = v := by
  cases c
  · rw [maskW_fix_iff]
    have hx := maskW_lt x
    have hy := maskW_lt y
    cases op <;> simp only [evalBin] at h <;> (try split at h) <;>
      simp only [Option.some.injEq, reduceCtorEq] at h <;> subst h <;>
      first
      | exact maskW_lt _
      | (rw [BitVec.toNat_and]; exact Nat.lt_of_le_of_lt Nat.and_le_left hx)
      | (rw [BitVec.toNat_or]; exact Nat.or_lt_two_pow hx hy)
      | (rw [BitVec.toNat_xor]; exact Nat.xor_lt_two_pow hx hy)
      | (rw [BitVec.toNat_ushiftRight]; exact Nat.lt_of_le_of_lt (Nat.shiftRight_le _ _) hx)
      | (rw [BitVec.toNat_udiv]; exact Nat.lt_of_le_of_lt (Nat.div_le_self _ _) hx)
      | (rw [BitVec.toNat_umod]; exact Nat.lt_of_le_of_lt (Nat.mod_le _ _) hx)
      | exact Nat.lt_of_le_of_lt (b2v_toNat_le _) (by norm_num)
  · rfl

/-- A node's value is kept at its class (`W` values are zero-extended). -/
theorem evalNode_masked (env : SymEnv) (sub : Std.I32 → BitVec 64) (n : SymNode) :
    maskC (nodeCls n) (evalNode env sub n) = evalNode env sub n := by
  cases n <;> simp only [nodeCls, evalNode, maskC_idem]
  · rfl
  · rename_i c op a
    cases op <;> simp only [evalUn, maskC_idem]
  · rename_i c op a b
    cases hv : evalBin c op (sub a) (sub b) with
    | none => cases c <;> rfl
    | some v => simpa using evalBin_masked hv

/-! ## Partial correctness of extracted loops and `partial_fixpoint` functions

`f x = ok r → P x r` is admissible, so `fixpoint_induct` proves it without
any termination argument. -/

open Lean.Order in
unseal Result in
theorem okP_adm {α : Type} (P : α → Prop) :
    admissible (fun m : Result α => ∀ r, m = ok r → P r) := by
  intro c hc hAll r hEq
  exact hAll _ (Aeneas.Data.Coinductive.ITree.csup_ret_mem hc hEq) r rfl

open Lean.Order in
theorem adm1 {A α : Type} (P : A → α → Prop) :
    admissible (fun f : A → Result α => ∀ x r, f x = ok r → P x r) :=
  admissible_pi _ (fun x => admissible_apply (fun x (m : Result α) => ∀ r, m = ok r → P x r) x
    (okP_adm (P x)))

open Lean.Order in
theorem adm2 {A B α : Type} (P : A → B → α → Prop) :
    admissible (fun f : A → B → Result α => ∀ x y r, f x y = ok r → P x y r) :=
  admissible_pi _ (fun x => admissible_apply (fun x (g : B → Result α) => ∀ y r, g y = ok r → P x y r) x
    (adm1 (P x)))

open Lean.Order in
theorem adm3 {A B C α : Type} (P : A → B → C → α → Prop) :
    admissible (fun f : A → B → C → Result α => ∀ x y z r, f x y z = ok r → P x y z r) :=
  admissible_pi _ (fun x => admissible_apply
    (fun x (g : B → C → Result α) => ∀ y z r, g y z = ok r → P x y z r) x (adm2 (P x)))

open Lean.Order in
theorem adm4 {A B C D α : Type} (P : A → B → C → D → α → Prop) :
    admissible (fun f : A → B → C → D → Result α => ∀ x y z t r, f x y z t = ok r → P x y z t r) :=
  admissible_pi _ (fun x => admissible_apply
    (fun x (g : B → C → D → Result α) => ∀ y z t r, g y z t = ok r → P x y z t r) x (adm3 (P x)))

open Lean.Order in
theorem adm5 {A B C D E α : Type} (P : A → B → C → D → E → α → Prop) :
    admissible (fun f : A → B → C → D → E → Result α =>
      ∀ x y z t u r, f x y z t u = ok r → P x y z t u r) :=
  admissible_pi _ (fun x => admissible_apply
    (fun x (g : B → C → D → E → Result α) => ∀ y z t u r, g y z t u = ok r → P x y z t u r) x
    (adm4 (P x)))

/-- Partial correctness of `loop` from an invariant (no termination measure). -/
theorem loop_ok_inv {α β : Type} (body : α → Result (ControlFlow α β)) (Inv : α → Prop)
    (Post : β → Prop)
    (hb : ∀ x c, Inv x → body x = ok c →
      match c with
      | .cont x' => Inv x'
      | .done y => Post y) :
    ∀ x r, loop body x = ok r → Inv x → Post r := by
  apply loop.fixpoint_induct body (motive := fun f => ∀ x r, f x = ok r → Inv x → Post r)
  · exact adm1 (fun x r => Inv x → Post r)
  · intro f ih x r h hx
    obtain ⟨c, hc, h⟩ := bind_eq_ok h
    have hp := hb x c hx hc
    cases c with
    | cont x' => exact ih x' r h hp
    | done y =>
      have := ok_inj' h
      subst this
      exact hp

/-! ## Graph primitives -/

theorem i32_lt_iff (a b : Std.I32) : a < b ↔ a.val < b.val := Iff.rfl
theorem i32_le_iff (a b : Std.I32) : a ≤ b ↔ a.val ≤ b.val := Iff.rfl
@[simp] theorem i32_zero_val : (0#i32 : Std.I32).val = 0 := by decide
@[simp] theorem i32_one_val : (1#i32 : Std.I32).val = 1 := by decide
@[simp] theorem i32_m1_val : ((-1)#i32 : Std.I32).val = -1 := by decide

theorem arr_length_ok {α : Type} {a : Pion.Array α} {n : Std.I32} (h : a.length = ok n) :
    n.val = a.val.length ∧ a.val.length ≤ 2147483647 := by
  unfold Pion.Array.length lengthOf at h
  split at h
  · rename_i hl
    rw [← ok_inj' h]
    exact ⟨by simp, hl⟩
  · simp at h

theorem vg_valid_ok {vg : ValGraph} {v : Std.I32} {b : Bool} (h : vg_valid vg v = ok b) :
    (b = true ↔ Valid vg v) ∧ (b = true → vg.nodes.val.length ≤ 2147483647) := by
  unfold vg_valid at h
  split at h
  · rename_i hv
    obtain ⟨n, hn, h⟩ := bind_eq_ok h
    obtain ⟨hn1, hn2⟩ := arr_length_ok hn
    rw [← ok_inj' h]
    have hv' : 0 ≤ v.val := by simpa [i32_le_iff] using hv
    simp only [decide_eq_true_eq, i32_lt_iff, hn1, Valid, hv', true_and]
    exact ⟨by omega, fun _ => hn2⟩
  · rename_i hv
    rw [← ok_inj' h]
    have hv' : ¬ 0 ≤ v.val := by simpa [i32_le_iff] using hv
    simp [Valid, hv']

theorem vg_valid_eq {vg : ValGraph} (hl : vg.nodes.val.length ≤ 2147483647) (v : Std.I32) :
    vg_valid vg v = ok (decide (Valid vg v)) := by
  obtain ⟨n, hn, he⟩ := arr_len_eq vg.nodes hl
  unfold vg_valid
  split
  · rename_i hv
    have hv' : 0 ≤ v.val := by simpa [i32_le_iff] using hv
    rw [he]
    simp only [bind_ok, i32_lt_iff, hn, Valid, hv', true_and]
    congr 1
    simp only [decide_eq_decide]
    omega
  · rename_i hv
    have hv' : ¬ 0 ≤ v.val := by simpa [i32_le_iff] using hv
    simp [Valid, hv']

theorem nodes_get_ok {vg : ValGraph} {a : Std.I32} {n : SymNode} (h : vg.nodes.get a = ok n) :
    nodeAt vg a = some n := by
  unfold Pion.Array.get listGet at h
  split at h
  · rename_i hb
    simp only [inBounds] at hb
    rw [← ok_inj' h]
    simp [nodeAt, hb.1]
  · simp at h

theorem nodes_get_eq {vg : ValGraph} {a : Std.I32} (h : Valid vg a) :
    vg.nodes.get a = ok (vg.nodes.val[a.val.toNat]'h.2) :=
  arr_get_eq vg.nodes a h.1 (by have := h.2; omega)

theorem vg_cls_eq {vg : ValGraph} (hl : vg.nodes.val.length ≤ 2147483647) (v : Std.I32) :
    vg_cls vg v = ok (clsOf vg v) := by
  unfold vg_cls
  rw [vg_valid_eq hl]
  by_cases hv : Valid vg v
  · simp only [hv, decide_true, Bool.not_true, bind_ok, Bool.false_eq_true, ↓reduceIte,
      nodes_get_eq hv, clsOf, valid_nodeAt hv]
    generalize vg.nodes.val[v.val.toNat]'hv.2 = m
    cases m <;> rfl
  · have : nodeAt vg v = none := by
      cases e : nodeAt vg v with
      | none => rfl
      | some n => exact absurd (nodeAt_valid e) hv
    simp [hv, clsOf, this]

theorem vg_const_eq {vg : ValGraph} (hl : vg.nodes.val.length ≤ 2147483647) (v : Std.I32) :
    vg_const vg v = ok ((constOf vg v).map (fun x => (⟨x⟩ : Std.U64))) := by
  unfold vg_const
  rw [vg_valid_eq hl]
  by_cases hv : Valid vg v
  · simp only [hv, decide_true, Bool.not_true, bind_ok, Bool.false_eq_true, ↓reduceIte,
      nodes_get_eq hv, constOf, valid_nodeAt hv]
    generalize vg.nodes.val[v.val.toNat]'hv.2 = m
    cases m <;> simp [mask_cls_spec]
  · have : nodeAt vg v = none := by
      cases e : nodeAt vg v with
      | none => rfl
      | some n => exact absurd (nodeAt_valid e) hv
    simp [hv, constOf, this]

theorem vg_is_const_eq {vg : ValGraph} (hl : vg.nodes.val.length ≤ 2147483647) (v : Std.I32)
    (x : Std.U64) : vg_is_const vg v x = ok (decide (constOf vg v = some x.bv)) := by
  unfold vg_is_const
  rw [vg_const_eq hl]
  simp only [bind_ok]
  cases constOf vg v with
  | none => simp
  | some y =>
    simp only [Option.map_some]
    congr 1
    by_cases h : y = x.bv
    · subst h; simp
    · have : (⟨y⟩ : Std.U64) ≠ x := fun e => h (by rw [← e])
      simp [this, h]

/-- What `vg_intern vg n` returns: an index of `n` in a graph that extends `vg`,
by at most `n` itself. -/
def InternRes (vg : ValGraph) (n : SymNode) (r : Std.I32) (vg' : ValGraph) : Prop :=
  vg_extends vg vg' ∧ nodeAt vg' r = some n ∧
    (vg'.nodes.val = vg.nodes.val ∨ (vg'.nodes.val = vg.nodes.val ++ [n] ∧ r.val = vg.nodes.val.length))

theorem nodeAt_congr {g g' : ValGraph} (h : g.nodes.val = g'.nodes.val) (a : Std.I32) :
    nodeAt g a = nodeAt g' a := by
  simp only [nodeAt, h]

/-- The probe of `vg_intern`: it returns an index only after comparing its node with `n`, or
appends `n`; the graph it carries is never changed (only its `buckets` on the append). -/
theorem vg_intern_loop_ok (cap h mask : Std.I32) (n : SymNode) (len : Std.I32) (vg : ValGraph) :
    ∀ (x : Std.I32 × ValGraph) r, vg_intern_loop1 cap h mask n len x.1 x.2 = ok r → x.2 = vg →
      match r with
      | .inl (r, vg2) => (vg2.nodes.val = vg.nodes.val ∧ nodeAt vg r = some n) ∨
          (vg2.nodes.val = vg.nodes.val ++ [n] ∧ r = len)
      | .inr (_, vg2) => vg2 = vg := by
  intro x r0 h0 hx
  unfold vg_intern_loop1 at h0
  refine loop_ok_inv (fun (p : Std.I32 × ValGraph) => vg_intern_loop1.body cap h mask n len p.1 p.2)
    (fun p => p.2 = vg)
    (fun r => match r with
      | .inl (r, vg2) => (vg2.nodes.val = vg.nodes.val ∧ nodeAt vg r = some n) ∨
          (vg2.nodes.val = vg.nodes.val ++ [n] ∧ r = len)
      | .inr (_, vg2) => vg2 = vg) ?_ x r0 h0 hx
  rintro ⟨step, g⟩ c hg hc
  simp only at hg hc
  subst hg
  unfold vg_intern_loop1.body at hc
  split at hc
  · obtain ⟨idx, -, hc⟩ := bind_eq_ok hc
    split at hc
    · obtain ⟨b2, -, hc⟩ := bind_eq_ok hc
      rw [← ok_inj' hc]
      exact Or.inr ⟨rfl, rfl⟩
    · obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
      split at hc
      · rename_i htrue
        rw [← ok_inj' hc]
        refine Or.inl ⟨rfl, ?_⟩
        split at ht
        · obtain ⟨m, hm, ht⟩ := bind_eq_ok ht
          obtain ⟨e, he, ht⟩ := bind_eq_ok ht
          have := ok_inj' ht
          subst this
          rw [nodes_get_ok hm, (sym_node_eq_ok he).1 htrue]
        · have := ok_inj' ht
          subst this
          cases htrue
      · rw [← ok_inj' hc]
  · rw [← ok_inj' hc]

theorem vg_intern_ok {vg : ValGraph} {n : SymNode} {r : Std.I32} {vg' : ValGraph}
    (h : vg_intern vg n = ok (r, vg')) : InternRes vg n r vg' := by
  unfold vg_intern at h
  obtain ⟨len, hlen, h⟩ := bind_eq_ok h
  obtain ⟨hl1, -⟩ := arr_length_ok hlen
  obtain ⟨cap0, -, h⟩ := bind_eq_ok h
  obtain ⟨vg1, hvg1, h⟩ := bind_eq_ok h
  have hn1 : vg1.nodes.val = vg.nodes.val := by
    split at hvg1
    · obtain ⟨c1, -, hvg1⟩ := bind_eq_ok hvg1
      obtain ⟨b, -, hvg1⟩ := bind_eq_ok hvg1
      rw [← ok_inj' hvg1]
    · rw [← ok_inj' hvg1]
  obtain ⟨cap1, -, h⟩ := bind_eq_ok h
  obtain ⟨hh, -, h⟩ := bind_eq_ok h
  obtain ⟨s, hs, hk⟩ := bind_eq_ok h
  clear h
  have hloop := vg_intern_loop_ok _ _ _ n len vg1 (0#i32, vg1) s hs rfl
  have happ : ∀ vg2 : ValGraph, vg2.nodes.val = vg.nodes.val ++ [n] →
      InternRes vg n len vg2 := by
    intro vg2 e
    refine ⟨⟨[n], e.symm⟩, ?_, Or.inr ⟨e, hl1⟩⟩
    simp [nodeAt, e, hl1]
  cases s with
  | inl p =>
    obtain ⟨r2, vg2⟩ := p
    have := ok_inj' hk
    simp only [Prod.mk.injEq] at this
    obtain ⟨rfl, rfl⟩ := this
    rcases hloop with ⟨e1, e2⟩ | ⟨e1, rfl⟩
    · have e : vg2.nodes.val = vg.nodes.val := by rw [e1, hn1]
      refine ⟨by show vg.nodes.val <+: vg2.nodes.val; rw [e], ?_, Or.inl e⟩
      rw [nodeAt_congr (e.trans hn1.symm)]
      exact e2
    · exact happ vg2 (by rw [e1, hn1])
  | inr p =>
    obtain ⟨st, vg3⟩ := p
    have hv3 : vg3 = vg1 := hloop
    subst hv3
    have := ok_inj' hk
    simp only [Prod.mk.injEq] at this
    obtain ⟨rfl, rfl⟩ := this
    exact happ _ (by show vg3.nodes.val ++ [n] = _; rw [hn1])

theorem intern_dag {vg : ValGraph} {n : SymNode} {r : Std.I32} {vg' : ValGraph}
    (hd : ValGraphDAG vg) (hc : childrenBelow n vg.nodes.val.length) (h : InternRes vg n r vg') :
    ValGraphDAG vg' := by
  rcases h.2.2 with he | ⟨he, _⟩
  · intro i m hm
    rw [he] at hm
    exact hd i m hm
  · intro i m hm
    rw [he] at hm
    by_cases hi : i < vg.nodes.val.length
    · rw [List.getElem?_append_left hi] at hm
      exact hd i m hm
    · rw [List.getElem?_append_right (by omega)] at hm
      have hi' : i - vg.nodes.val.length = 0 := by
        by_contra hne
        rw [List.getElem?_eq_none (by simp; omega)] at hm
        cases hm
      rw [hi'] at hm
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hm
      subst hm
      have : i = vg.nodes.val.length := by omega
      subst this
      exact hc

theorem intern_valid {vg : ValGraph} {n : SymNode} {r : Std.I32} {vg' : ValGraph}
    (h : InternRes vg n r vg') : Valid vg' r := nodeAt_valid h.2.1

/-- The value of an interned node, from the values of its children in `vg`. -/
theorem intern_evI {vg : ValGraph} {n : SymNode} {r : Std.I32} {vg' : ValGraph}
    (hd : ValGraphDAG vg) (hc : childrenBelow n vg.nodes.val.length) (h : InternRes vg n r vg')
    (env : SymEnv) : evI vg' env r = evalNode env (evI vg env) n := by
  rw [evI_node (intern_dag hd hc h) env h.2.1]
  apply evalNode_congr
  intro a ha
  apply extends_evI h.1
  cases n <;> simp only [childrenBelow] at hc ha
  · subst ha; exact hc
  · rcases ha with rfl | rfl
    · exact hc.1
    · exact hc.2

theorem intern_clsOf {vg : ValGraph} {n : SymNode} {r : Std.I32} {vg' : ValGraph}
    (h : InternRes vg n r vg') : clsOf vg' r = nodeCls n := by
  simp [clsOf, h.2.1]

/-- `vg_intern` only appends, keeps the DAG and the value of every old node,
and returns a node whose value is that of `n`. -/
theorem vg_intern_spec {vg : ValGraph} {n : SymNode} {r : Std.I32} {vg' : ValGraph}
    (h : vg_intern vg n = ok (r, vg')) (hd : ValGraphDAG vg)
    (hc : childrenBelow n vg.nodes.val.length) :
    vg_extends vg vg' ∧ ValGraphDAG vg' ∧ nodeAt vg' r = some n ∧
      (∀ env i, i < vg.nodes.val.length → evalSym vg' env i = evalSym vg env i) ∧
      ∀ env, evI vg' env r = evalNode env (evI vg env) n :=
  have hi := vg_intern_ok h
  ⟨hi.1, intern_dag hd hc hi, hi.2.1, fun env => evalSym_extends hi.1 env, intern_evI hd hc hi⟩

theorem vg_konst_ok {vg : ValGraph} {c : Cls} {x : Std.U64} {r : Std.I32} {vg' : ValGraph}
    (h : vg_konst vg c x = ok (r, vg')) :
    InternRes vg (.SConst c ⟨maskC c x.bv⟩) r vg' := by
  unfold vg_konst at h
  rw [mask_cls_spec] at h
  simp only [bind_ok] at h
  obtain ⟨p, hp, h⟩ := bind_eq_ok h
  obtain ⟨r2, vg2⟩ := p
  have := ok_inj' h
  simp only [Prod.mk.injEq] at this
  obtain ⟨rfl, rfl⟩ := this
  exact vg_intern_ok hp

/-- Everything a fresh constant node satisfies. -/
theorem konst_facts {vg : ValGraph} {c : Cls} {x : Std.U64} {r : Std.I32} {vg' : ValGraph}
    (hd : ValGraphDAG vg) (h : vg_konst vg c x = ok (r, vg')) :
    vg_extends vg vg' ∧ ValGraphDAG vg' ∧ Valid vg' r ∧ clsOf vg' r = c ∧
      constOf vg' r = some (maskC c x.bv) ∧ ∀ env, evI vg' env r = maskC c x.bv := by
  have hi := vg_konst_ok h
  have hc : childrenBelow (.SConst c ⟨maskC c x.bv⟩) vg.nodes.val.length := trivial
  refine ⟨hi.1, intern_dag hd hc hi, intern_valid hi, intern_clsOf hi, ?_, ?_⟩
  · simp [constOf, hi.2.1, maskC_idem]
  · intro env
    rw [intern_evI hd hc hi]
    simp [evalNode, maskC_idem]

/-! ## `check_vg_dag` decides `ValGraphDAG` -/

theorem arr_get_ok {α : Type} {a : Pion.Array α} {i : Std.I32} {x : α} (h : a.get i = ok x) :
    0 ≤ i.val ∧ ∃ hi : i.val.toNat < a.val.length, a.val[i.val.toNat] = x := by
  unfold Pion.Array.get listGet at h
  split at h
  · rename_i hb
    simp only [inBounds] at hb
    rw [← ok_inj' h]
    exact ⟨hb.1, by omega, rfl⟩
  · simp at h

theorem arr_set_ok {α : Type} {a : Pion.Array α} {i : Std.I32} {x : α} {a' : Pion.Array α}
    (h : a.set i x = ok a') : a'.val = a.val.set i.val.toNat x := by
  unfold Pion.Array.set listSet at h
  split at h
  · simp only [bind_ok] at h
    rw [← ok_inj' h]
  · simp at h

theorem check_vg_dag_sound {vg : ValGraph} (h : check_vg_dag vg = ok true) : ValGraphDAG vg := by
  unfold check_vg_dag at h
  obtain ⟨n, hn, h⟩ := bind_eq_ok h
  obtain ⟨hn1, hn2⟩ := arr_length_ok hn
  obtain ⟨s, hs, h⟩ := bind_eq_ok h
  have key := loop_ok_inv (fun i => check_vg_dag_loop0.body n vg i)
    (fun i : Std.I32 => 0 ≤ i.val ∧ i.val ≤ n.val ∧
      ∀ j n', j < i.val.toNat → vg.nodes.val[j]? = some n' → childrenBelow n' j)
    (fun r => match r with
      | .inl b => b = false
      | .inr _ => ∀ j n', vg.nodes.val[j]? = some n' → childrenBelow n' j)
    (by
      intro i c ⟨hi0, hi1, hi2⟩ hc
      unfold check_vg_dag_loop0.body at hc
      split at hc
      · rename_i hlt
        have hlt' : i.val < n.val := hlt
        obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hib, hti⟩ := arr_get_ok ht
        have hnext : ∀ (hcb : childrenBelow t i.val.toNat),
            (0 ≤ (Pion.I32.add i 1#i32).val ∧ (Pion.I32.add i 1#i32).val ≤ n.val ∧
              ∀ j n', j < (Pion.I32.add i 1#i32).val.toNat → vg.nodes.val[j]? = some n' →
                childrenBelow n' j) := by
          intro hcb
          have hmax := n.hmax
          simp only [IScalarTy.numBits] at hmax
          have he := i32_add_val i 1#i32 (by simp; omega) (by simp; omega)
          rw [he]
          simp only [i32_one_val]
          refine ⟨by omega, by omega, ?_⟩
          intro j n' hj hjn
          by_cases hji : j < i.val.toNat
          · exact hi2 j n' hji hjn
          · have : j = i.val.toNat := by omega
            subst this
            rw [List.getElem?_eq_getElem hib, hti] at hjn
            cases hjn
            exact hcb
        cases t with
        | SUn c op a =>
          simp only at hc
          split at hc
          · simp only [bind_ok] at hc; rw [← ok_inj' hc]
          · rename_i hcond
            simp only [bind_ok] at hc
            rw [← ok_inj' hc]
            apply hnext
            simp only [childrenBelow]
            simp only [Bool.or_eq_true, decide_eq_true_eq, not_or, i32_lt_iff, i32_le_iff,
              i32_zero_val, not_lt, not_le] at hcond
            omega
        | SBin c op a b =>
          simp only at hc
          split at hc
          · simp only [bind_ok] at hc; rw [← ok_inj' hc]
          · rename_i hcond
            simp only [bind_ok] at hc
            rw [← ok_inj' hc]
            apply hnext
            simp only [childrenBelow]
            simp only [Bool.or_eq_true, decide_eq_true_eq, not_or, i32_lt_iff, i32_le_iff,
              i32_zero_val, not_lt, not_le] at hcond
            omega
        | SConst c x => simp only [bind_ok] at hc; rw [← ok_inj' hc]; exact hnext trivial
        | SSym x => simp only [bind_ok] at hc; rw [← ok_inj' hc]; exact hnext trivial
        | SParam c x => simp only [bind_ok] at hc; rw [← ok_inj' hc]; exact hnext trivial
        | SPhi c x y => simp only [bind_ok] at hc; rw [← ok_inj' hc]; exact hnext trivial
        | SEffect c x y => simp only [bind_ok] at hc; rw [← ok_inj' hc]; exact hnext trivial
      · rename_i hge
        have hge' : ¬ i.val < n.val := hge
        rw [← ok_inj' hc]
        intro j n' hj
        apply hi2 j n' _ hj
        have : j < vg.nodes.val.length := by
          by_contra hc'
          rw [List.getElem?_eq_none (by omega)] at hj
          cases hj
        omega)
  have hp := key _ s hs ⟨by simp, by simp; omega, fun j n' hj => by simp at hj⟩
  cases s with
  | inl b =>
    have hb : b = false := hp
    subst hb
    simp at h
  | inr _ => exact hp

/-! ## `vid_mentions_blk` is a sound dependency check -/

/-- `env'` may differ from `env` only on the phis and effects of block `blk`. -/
def AgreeExcept (blk : Std.I32) (env env' : SymEnv) : Prop :=
  env'.paramVal = env.paramVal ∧ env'.symAddr = env.symAddr ∧
    (∀ c b k, b ≠ blk → env'.phiVal c b k = env.phiVal c b k) ∧
    (∀ c b k, b ≠ blk → env'.effVal c b k = env.effVal c b k)

/-- The per-node fact the backward sweep of `vid_mentions_blk` establishes for
a marked node `j`. -/
def SweepOK (vg : ValGraph) (blk : Std.I32) (mark : List Bool) (j : Nat) : Prop :=
  match vg.nodes.val[j]? with
  | some (.SPhi _ b _) => b ≠ blk
  | some (.SEffect _ b _) => b ≠ blk
  | some (.SUn _ _ a) => 0 ≤ a.val ∧ a.val.toNat < j → mark[a.val.toNat]? = some true
  | some (.SBin _ _ a c) =>
      (0 ≤ a.val ∧ a.val.toNat < j → mark[a.val.toNat]? = some true) ∧
      (0 ≤ c.val ∧ c.val.toNat < j → mark[c.val.toNat]? = some true)
  | _ => True

theorem mark_set_true {mark : List Bool} {x k : Nat} (h : mark[k]? = some true) :
    (mark.set x true)[k]? = some true := by
  have hk : k < mark.length := by
    by_contra hc
    rw [List.getElem?_eq_none (by omega)] at h
    cases h
  rw [List.getElem?_set]
  split
  · rename_i e; subst e; simp [hk]
  · exact h

/-- `m'` adds marks to `m` only below `i`. -/
def MarkStep (m m' : List Bool) (i : Nat) : Prop :=
  m'.length = m.length ∧ (∀ k : Nat, m[k]? = some true → m'[k]? = some true) ∧
    (∀ k : Nat, m'[k]? = some true → m[k]? = some true ∨ k < i)

theorem markStep_refl (m : List Bool) (i : Nat) : MarkStep m m i :=
  ⟨rfl, fun _ h => h, fun _ h => Or.inl h⟩

theorem markStep_set {m m' : List Bool} {i x : Nat} (h : MarkStep m m' i) (hx : x < i) :
    MarkStep m (m'.set x true) i := by
  obtain ⟨h1, h2, h3⟩ := h
  refine ⟨by simp [h1], fun k hk => mark_set_true (h2 k hk), fun k hk => ?_⟩
  rw [List.getElem?_set] at hk
  split at hk
  · rename_i e; subst e; exact Or.inr hx
  · exact h3 k hk

theorem sweepOK_mono {vg : ValGraph} {blk : Std.I32} {mark mark' : List Bool} {j i : Nat}
    (hm : MarkStep mark mark' i) (h : SweepOK vg blk mark j) : SweepOK vg blk mark' j := by
  have h2 := hm.2.1
  unfold SweepOK at h ⊢
  cases hj : vg.nodes.val[j]? with
  | none => trivial
  | some n =>
    rw [hj] at h
    cases n with
    | SPhi _ _ _ => exact h
    | SEffect _ _ _ => exact h
    | SUn _ _ a => exact fun hc => h2 _ (h hc)
    | SBin _ _ a c => exact ⟨fun hc => h2 _ (h.1 hc), fun hc => h2 _ (h.2 hc)⟩
    | SConst _ _ => trivial
    | SSym _ => trivial
    | SParam _ _ => trivial

/-- After the sweep: every marked node evaluates the same under `env` and `env'`. -/
theorem sweep_eval {vg : ValGraph} {blk : Std.I32} {mark : List Bool} {env env' : SymEnv}
    (ha : AgreeExcept blk env env') (hs : ∀ j, mark[j]? = some true → SweepOK vg blk mark j) :
    ∀ j, mark[j]? = some true → evalSym vg env' j = evalSym vg env j := by
  intro j
  induction j using Nat.strong_induction_on with
  | _ j ih =>
    intro hm
    have hj := hs j hm
    obtain ⟨hp, hsym, hphi, heff⟩ := ha
    rw [evalSym_unfold, evalSym_unfold]
    unfold SweepOK at hj
    cases hn : vg.nodes.val[j]? with
    | none => rfl
    | some n =>
      rw [hn] at hj
      have sub_eq : ∀ a : Std.I32, (0 ≤ a.val ∧ a.val.toNat < j → mark[a.val.toNat]? = some true) →
          (if h : 0 ≤ a.val ∧ a.val.toNat < j then evalSym vg env' a.val.toNat else 0) =
          (if h : 0 ≤ a.val ∧ a.val.toNat < j then evalSym vg env a.val.toNat else 0) := by
        intro a ham
        by_cases hc : 0 ≤ a.val ∧ a.val.toNat < j
        · simp only [hc, and_self, ↓reduceDIte]
          exact ih _ hc.2 (ham hc)
        · simp only [hc, ↓reduceDIte]
      cases n with
      | SConst c x => rfl
      | SSym x => simp only [evalNode, hsym]
      | SParam c k => simp only [evalNode, hp]
      | SPhi c b k => simp only [evalNode, hphi c b k hj]
      | SEffect c b k => simp only [evalNode, heff c b k hj]
      | SUn c op a => simp only [evalNode]; rw [sub_eq a hj]
      | SBin c op a b => simp only [evalNode]; rw [sub_eq a hj.1, sub_eq b hj.2]

theorem vid_mentions_blk_sound {vg : ValGraph} {v blk : Std.I32} {env env' : SymEnv}
    (h : vid_mentions_blk vg v blk = ok false) (hv : 0 ≤ v.val) (ha : AgreeExcept blk env env') :
    evI vg env' v = evI vg env v := by
  unfold vid_mentions_blk at h
  obtain ⟨b, hb, h⟩ := bind_eq_ok h
  obtain ⟨hb1, hb2⟩ := vg_valid_ok hb
  cases b with
  | false =>
    have hnv : ¬ Valid vg v := fun hc => by simpa using hb1.2 hc
    have hge : vg.nodes.val.length ≤ v.val.toNat := by
      simp only [Valid, not_and, not_lt] at hnv
      exact hnv hv
    simp only [evI]
    rw [evalSym_unfold, evalSym_unfold, List.getElem?_eq_none hge]
  | true =>
    have hval := hb1.1 rfl
    have hlen := hb2 rfl
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
    obtain ⟨mark1, hm1, h⟩ := bind_eq_ok h
    obtain ⟨s, hs, h⟩ := bind_eq_ok h
    have hv1 := i32_add_val v 1#i32 (by simp; omega) (by
      have := hval.2; simp only [i32_one_val]; omega)
    simp only [i32_one_val] at hv1
    have hm1' := arr_set_ok hm1
    try simp only [Pion.Array.make, listMake, hv1] at hm1'
    have hlen1 : mark1.val.length = v.val.toNat + 1 := by
      rw [hm1']; simp [hv1]; omega
    have hmv : mark1.val[v.val.toNat]? = some true := by
      rw [hm1', List.getElem?_set]; simp [hv1]; try omega
    have key := loop_ok_inv
      (fun (p : Std.I32 × Pion.Array Bool) => vid_mentions_blk_loop0.body vg blk p.1 p.2)
      (fun p => p.2.val.length = v.val.toNat + 1 ∧ -1 ≤ p.1.val ∧ p.1.val ≤ v.val ∧
        p.2.val[v.val.toNat]? = some true ∧
        ∀ j : Nat, p.1.val < j → p.2.val[j]? = some true → SweepOK vg blk p.2.val j)
      (fun r => match r with
        | .inl b => b = true
        | .inr p => p.2.val[v.val.toNat]? = some true ∧
            ∀ j : Nat, p.2.val[j]? = some true → SweepOK vg blk p.2.val j)
      (by
        rintro ⟨i, mark⟩ c ⟨hl, hi0, hiv, hmv', hsw⟩ hc
        simp only at hl hi0 hiv hmv' hsw hc
        unfold vid_mentions_blk_loop0.body at hc
        split at hc
        · rename_i hge
          have hge' : 0 ≤ i.val := by simpa [i32_le_iff] using hge
          have hi_len : i.val.toNat < vg.nodes.val.length := by have := hval.2; omega
          obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
          obtain ⟨_, hib, hti⟩ := arr_get_ok ht
          have hsub := i32_sub_val i 1#i32 (by simp; omega) (by simp; omega)
          simp only [i32_one_val] at hsub
          -- the next state, given the (possibly updated) marks
          have next : ∀ mark' : Pion.Array Bool, mark'.val.length = v.val.toNat + 1 →
              mark'.val[v.val.toNat]? = some true →
              (∀ j : Nat, i.val < j → mark'.val[j]? = some true → SweepOK vg blk mark'.val j) →
              (mark'.val[i.val.toNat]? = some true → SweepOK vg blk mark'.val i.val.toNat) →
              (mark'.val.length = v.val.toNat + 1 ∧ -1 ≤ (Pion.I32.sub i 1#i32).val ∧
                (Pion.I32.sub i 1#i32).val ≤ v.val ∧ mark'.val[v.val.toNat]? = some true ∧
                ∀ j : Nat, (Pion.I32.sub i 1#i32).val < j → mark'.val[j]? = some true →
                  SweepOK vg blk mark'.val j) := by
            intro mark' h1 h2 h3 h4
            rw [hsub]
            refine ⟨h1, by omega, by omega, h2, ?_⟩
            intro j hj hjm
            by_cases hji : (i.val : Int) < j
            · exact h3 j hji hjm
            · have : j = i.val.toNat := by omega
              subst this
              exact h4 hjm
          obtain ⟨sres, hsres, hc⟩ := bind_eq_ok hc
          have hmi : mark.val[i.val.toNat]? = some t := by
            rw [List.getElem?_eq_getElem hib, hti]
          have hstep : (∀ r, sres = .inl r → r = true) ∧
              (∀ m5 : Pion.Array Bool, sres = .inr m5 → MarkStep mark.val m5.val i.val.toNat ∧
                (m5.val[i.val.toNat]? = some true → SweepOK vg blk m5.val i.val.toNat)) := by
            split at hsres
            · rename_i htt
              obtain ⟨nd, hnd, hsres⟩ := bind_eq_ok hsres
              obtain ⟨_, hib2, hnd2⟩ := arr_get_ok hnd
              have hnode : vg.nodes.val[i.val.toNat]? = some nd := by
                rw [List.getElem?_eq_getElem hib2, hnd2]
              cases nd with
              | SPhi c b k =>
                simp only at hsres
                split at hsres
                · rw [← ok_inj' hsres]
                  exact ⟨fun r e => (by cases e; rfl), fun m5 e => (by cases e)⟩
                · rename_i hne
                  rw [← ok_inj' hsres]
                  refine ⟨fun r e => (by cases e), fun m5 e => ?_⟩
                  cases e
                  exact ⟨markStep_refl _ _, fun _ => by unfold SweepOK; rw [hnode]; exact hne⟩
              | SEffect c b k =>
                simp only at hsres
                split at hsres
                · rw [← ok_inj' hsres]
                  exact ⟨fun r e => (by cases e; rfl), fun m5 e => (by cases e)⟩
                · rename_i hne
                  rw [← ok_inj' hsres]
                  refine ⟨fun r e => (by cases e), fun m5 e => ?_⟩
                  cases e
                  exact ⟨markStep_refl _ _, fun _ => by unfold SweepOK; rw [hnode]; exact hne⟩
              | SUn c op a =>
                simp only at hsres
                split at hsres
                · rename_i hcond
                  simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff,
                    i32_zero_val] at hcond
                  obtain ⟨m1, hm, hsres⟩ := bind_eq_ok hsres
                  have hm' := arr_set_ok hm
                  rw [← ok_inj' hsres]
                  refine ⟨fun r e => (by cases e), fun m5 e => ?_⟩
                  cases e
                  rw [hm']
                  refine ⟨markStep_set (markStep_refl _ _) (by omega), fun _ => ?_⟩
                  unfold SweepOK; rw [hnode]
                  intro _
                  have hai : a.val.toNat < mark.val.length := by rw [hl]; omega
                  simp [List.getElem?_set, hai]
                · rename_i hcond
                  simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff,
                    i32_zero_val] at hcond
                  rw [← ok_inj' hsres]
                  refine ⟨fun r e => (by cases e), fun m5 e => ?_⟩
                  cases e
                  refine ⟨markStep_refl _ _, fun _ => ?_⟩
                  unfold SweepOK; rw [hnode]
                  intro hc'
                  exfalso; apply hcond; constructor <;> omega
              | SBin c op a d =>
                simp only at hsres
                obtain ⟨m2, hm2, hsres⟩ := bind_eq_ok hsres
                have hstep2 : MarkStep mark.val m2.val i.val.toNat ∧
                    (0 ≤ a.val ∧ a.val.toNat < i.val.toNat → m2.val[a.val.toNat]? = some true) := by
                  split at hm2
                  · rename_i hcond
                    simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff,
                      i32_zero_val] at hcond
                    obtain ⟨m3, hm3, hm2⟩ := bind_eq_ok hm2
                    rw [← ok_inj' hm2, arr_set_ok hm3]
                    refine ⟨markStep_set (markStep_refl _ _) (by omega), fun _ => ?_⟩
                    have hai : a.val.toNat < mark.val.length := by rw [hl]; omega
                    simp [List.getElem?_set, hai]
                  · rename_i hcond
                    simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff,
                      i32_zero_val] at hcond
                    rw [← ok_inj' hm2]
                    refine ⟨markStep_refl _ _, fun hc' => ?_⟩
                    exfalso; apply hcond; constructor <;> omega
                split at hsres
                · rename_i hcond
                  simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff,
                    i32_zero_val] at hcond
                  obtain ⟨m4, hm4, hsres⟩ := bind_eq_ok hsres
                  have hm4' := arr_set_ok hm4
                  rw [← ok_inj' hsres]
                  refine ⟨fun r e => (by cases e), fun m5 e => ?_⟩
                  cases e
                  rw [hm4']
                  have hl2 : m2.val.length = mark.val.length := hstep2.1.1
                  refine ⟨markStep_set hstep2.1 (by omega), fun _ => ?_⟩
                  unfold SweepOK; rw [hnode]
                  refine ⟨fun ha' => ?_, fun _ => ?_⟩
                  · exact mark_set_true (hstep2.2 ha')
                  · have hdi : d.val.toNat < m2.val.length := by rw [hl2, hl]; omega
                    simp [List.getElem?_set, hdi]
                · rename_i hcond
                  simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff,
                    i32_zero_val] at hcond
                  rw [← ok_inj' hsres]
                  refine ⟨fun r e => (by cases e), fun m5 e => ?_⟩
                  cases e
                  refine ⟨hstep2.1, fun _ => ?_⟩
                  unfold SweepOK; rw [hnode]
                  refine ⟨hstep2.2, fun hc' => ?_⟩
                  exfalso; apply hcond; constructor <;> omega
              | SConst c x =>
                simp only at hsres
                rw [← ok_inj' hsres]
                exact ⟨fun r e => (by cases e), fun m5 e => (by cases e; exact ⟨markStep_refl _ _, fun _ => (by unfold SweepOK; rw [hnode]; trivial)⟩)⟩
              | SSym x =>
                simp only at hsres
                rw [← ok_inj' hsres]
                exact ⟨fun r e => (by cases e), fun m5 e => (by cases e; exact ⟨markStep_refl _ _, fun _ => (by unfold SweepOK; rw [hnode]; trivial)⟩)⟩
              | SParam c k =>
                simp only at hsres
                rw [← ok_inj' hsres]
                exact ⟨fun r e => (by cases e), fun m5 e => (by cases e; exact ⟨markStep_refl _ _, fun _ => (by unfold SweepOK; rw [hnode]; trivial)⟩)⟩
            · rename_i htf
              rw [← ok_inj' hsres]
              refine ⟨fun r e => (by cases e), fun m5 e => ?_⟩
              cases e
              refine ⟨markStep_refl _ _, fun hm5 => ?_⟩
              rw [hmi] at hm5
              cases hm5
              exact absurd rfl htf
          split at hc
          · rename_i r
            rw [← ok_inj' hc]
            exact hstep.1 r rfl
          · rename_i m5
            rw [← ok_inj' hc]
            obtain ⟨hms, hsw5⟩ := hstep.2 m5 rfl
            apply next m5 (by rw [hms.1, hl]) (hms.2.1 _ hmv') _ hsw5
            intro j hj hjm
            rcases hms.2.2 j hjm with hj' | hj'
            · exact sweepOK_mono hms (hsw j hj hj')
            · omega
        · rename_i hlt
          have hlt' : i.val < 0 := by simpa [i32_le_iff] using hlt
          rw [← ok_inj' hc]
          refine ⟨hmv', fun j hj => hsw j (by omega) hj⟩)
    have hp := key _ s hs ⟨hlen1, by dsimp only; omega, le_refl _, hmv, fun j hj hjm => by
      dsimp only at hj hjm
      exfalso
      have : j < mark1.val.length := by
        by_contra hc
        rw [List.getElem?_eq_none (by omega)] at hjm
        cases hjm
      omega⟩
    cases s with
    | inl b =>
      simp only at hp
      subst hp
      simp at h
    | inr p =>
      obtain ⟨hpv, hpall⟩ := hp
      exact sweep_eval ha hpall _ hpv

/-! ## Operational semantics of QBE functions -/

/-- The outside world: memory, calls and allocation are opaque, partial
operations (`none` is a fault). A load never changes the world. -/
structure WorldOracle (W : Type) where
  symAddr : Std.I32 → BitVec 64
  load : W → MemWidth → Bool → BitVec 64 → Option (BitVec 64)
  store : W → MemWidth → BitVec 64 → BitVec 64 → Option W
  call : W → BitVec 64 → List (Cls × BitVec 64) → Option (W × BitVec 64)
  alloc : W → Std.I32 → Std.I32 → Option (W × BitVec 64)

inductive TermOutcome (W : Type) where
  | ret (v : Option (BitVec 64)) (w : W)
  | hlt (w : W)

/-- The registers (temporaries) and the world of a running function. -/
structure MState (W : Type) where
  regs : Nat → BitVec 64
  world : W

/-- Class at which operand `n` of `cls op a, b` is read (`binop_arg_cls`). -/
def binArgCls (op : BinOp) (cls : Cls) (n : Nat) : Cls :=
  match op with
  | .CEq c | .CNe c | .CSlt c | .CSle c | .CSgt c | .CSge c | .CUlt c | .CUle c | .CUgt c
  | .CUge c => c
  | .Shl | .Shr | .Sar | .Ror => if n = 1 then .W else cls
  | _ => cls

/-- Class at which the operand of `cls op a` is read (`unop_arg_cls`). -/
def unArgCls (op : UnOp) (cls : Cls) : Cls :=
  match op with
  | .Copy | .Neg => cls
  | _ => .W

def setReg (regs : Nat → BitVec 64) (t : Std.I32) (v : BitVec 64) : Nat → BitVec 64 :=
  fun j => if j = t.val.toNat then v else regs j

/-- The raw 64-bit word of an atom. -/
def atomRaw {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) : Atom → BitVec 64
  | .Temp t => regs t.val.toNat
  | .Const v => v.bv
  | .Sym s off => o.symAddr s + off.bv

/-- An atom read at class `c`: a `W` read keeps the low half; an `L` read of
a `W` temporary reads its zero-extended word. -/
def atomVal {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (c : Cls) (a : Atom) :
    BitVec 64 :=
  maskC c (atomRaw o regs a)

/-- Parameter `k` (`0` when absent). -/
def argVal (args : List (BitVec 64)) (k : Std.I32) : BitVec 64 :=
  if 0 ≤ k.val then (args[k.val.toNat]?).getD 0 else 0

/-- The class a store of width `wd` reads its value at (`store_cls`). -/
def storeCls : MemWidth → Cls
  | .B8 => .L
  | _ => .W

/-- The bits a store of width `wd` writes (`storeb` / `storeh` / `storew` /
`storel`), zero-extended. -/
def maskWidth : MemWidth → BitVec 64 → BitVec 64
  | .B1, v => v &&& 0xFF#64
  | .B2, v => v &&& 0xFFFF#64
  | .B4, v => v &&& 0xFFFFFFFF#64
  | .B8, v => v

/-- One instruction; `none` is a trap (division) or a fault of the world. -/
def execInst {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (s : MState W) :
    Inst → Option (MState W)
  | .Par d c k => some { s with regs := setReg s.regs d (maskC c (argVal args k)) }
  | .Un d c op a => some { s with regs := setReg s.regs d (evalUn c op (atomVal o s.regs (unArgCls op c) a)) }
  | .Bin d c op a b =>
    (evalBin c op (atomVal o s.regs (binArgCls op c 0) a) (atomVal o s.regs (binArgCls op c 1) b)).map
      fun v => { s with regs := setReg s.regs d v }
  | .Load d c wd sg addr =>
    (o.load s.world wd sg (atomVal o s.regs .L addr)).map
      fun v => { s with regs := setReg s.regs d (maskC c v) }
  | .Store wd v addr =>
    (o.store s.world wd (maskWidth wd (atomVal o s.regs (storeCls wd) v)) (atomVal o s.regs .L addr)).map
      fun w => { s with world := w }
  | .Call d c hasd callee cargs =>
    (o.call s.world (atomVal o s.regs .L callee)
        (cargs.val.map fun ca => (ca.cls, atomVal o s.regs ca.cls ca.arg))).map
      fun p => { regs := if hasd then setReg s.regs d (maskC c p.2) else s.regs, world := p.1 }
  | .Alloc d al sz =>
    (o.alloc s.world al sz).map fun p => { regs := setReg s.regs d p.2, world := p.1 }

def execInsts {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) :
    List Inst → MState W → Option (MState W)
  | [], s => some s
  | i :: is, s => (execInst o args s i).bind (execInsts o args is)

/-- The argument of phi `p` on the edge from block `prev`. -/
def phiArg (p : Phi) (prev : Int) : Option Atom :=
  (p.arms.val.find? (fun a => decide (a.pred.val = prev))).map (·.value)

/-- All phis of a block entered from `prev`, read in parallel from `regs`. -/
def execPhis {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (prev : Int) :
    List Phi → (Nat → BitVec 64) → Option (Nat → BitVec 64)
  | [], acc => some acc
  | p :: ps, acc =>
    (phiArg p prev).bind fun a => execPhis o regs prev ps (setReg acc p.dst (atomVal o regs p.cls a))

/-- Phis, instructions, then the terminator of block `b` entered from `prev`. -/
def runBlock {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (f : Func) (prev : Int)
    (b : Nat) (s : MState W) : Option (MState W × Term) :=
  match f.blocks.val[b]? with
  | none => none
  | some blk =>
    (execPhis o s.regs prev blk.phis.val s.regs).bind fun regs =>
      (execInsts o args blk.insts.val { s with regs := regs }).map fun s' => (s', blk.term)

/-- The successor block id (`none` for a negative id). -/
def blockId (d : Std.I32) : Option Nat := if 0 ≤ d.val then some d.val.toNat else none

/-- Run from block `b` (entered from `prev`) for at most `fuel` blocks. -/
def evalFrom {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (f : Func) :
    Nat → Int → Nat → MState W → Option (TermOutcome W)
  | 0, _, _, _ => none
  | fuel + 1, prev, b, s =>
    (runBlock o args f prev b s).bind fun (s', t) =>
      match t with
      | .Jmp d => (blockId d).bind fun d' => evalFrom o args f fuel b d' s'
      | .Jnz a d1 d2 =>
        (blockId (if atomVal o s'.regs .W a ≠ 0 then d1 else d2)).bind fun d' =>
          evalFrom o args f fuel b d' s'
      | .Ret has c a => some (.ret (if has then some (atomVal o s'.regs c a) else none) s'.world)
      | .Hlt => some (.hlt s'.world)

/-- `f` called with `args` in world `w0`: entry block `0`, at most `fuel`
blocks; `none` on a trap, a fault, a malformed block or exhausted fuel. -/
def evalFunc {W : Type} (f : Func) (oracle : WorldOracle W) (args : List (BitVec 64)) (w0 : W)
    (fuel : Nat) : Option (TermOutcome W) :=
  evalFrom oracle args f fuel (-1) 0 { regs := fun _ => 0, world := w0 }

/-- Execution is monotone in fuel. -/
theorem evalFrom_fuel {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (f : Func) :
    ∀ n prev b s r, evalFrom o args f n prev b s = some r →
      evalFrom o args f (n + 1) prev b s = some r := by
  intro n
  induction n with
  | zero => intro prev b s r h; simp [evalFrom] at h
  | succ n ih =>
    intro prev b s r h
    rw [evalFrom] at h
    rw [evalFrom]
    cases hr : runBlock o args f prev b s with
    | none => rw [hr] at h; simp at h
    | some p =>
      obtain ⟨s', t⟩ := p
      rw [hr] at h
      simp only [Option.bind_some] at h ⊢
      cases t with
      | Jmp d =>
        simp only at h ⊢
        cases hd : blockId d with
        | none => rw [hd] at h; simp at h
        | some d' =>
          rw [hd] at h
          simp only [Option.bind_some] at h ⊢
          exact ih _ _ _ _ h
      | Jnz a d1 d2 =>
        simp only at h ⊢
        cases hd : blockId (if atomVal o s'.regs .W a ≠ 0 then d1 else d2) with
        | none => rw [hd] at h; simp at h
        | some d' =>
          rw [hd] at h
          simp only [Option.bind_some] at h ⊢
          exact ih _ _ _ _ h
      | Ret has c a => exact h
      | Hlt => exact h

/-! ## `blk_mentions_table`: the dependency check for every node at once -/

/-- Node `j` has the same value under any two environments that differ only on block `blk`. -/
def Indep (vg : ValGraph) (blk : Std.I32) (j : Nat) : Prop :=
  ∀ env env', AgreeExcept blk env env' → evalSym vg env' j = evalSym vg env j

/-- A node whose leaf is of another block and whose in-range children are independent of `blk`
is independent of `blk`. -/
theorem indep_node {vg : ValGraph} {blk : Std.I32} {i : Nat} {t : SymNode}
    (hn : vg.nodes.val[i]? = some t)
    (hleaf : ∀ c b k, (t = .SPhi c b k ∨ t = .SEffect c b k) → b ≠ blk)
    (hch : ∀ a : Std.I32, ((∃ c op, t = .SUn c op a) ∨ (∃ c op x, t = .SBin c op a x ∨ t = .SBin c op x a)) →
      0 ≤ a.val → a.val.toNat < i → Indep vg blk a.val.toNat) :
    Indep vg blk i := by
  intro env env' ha
  obtain ⟨hp, hsym, hphi, heff⟩ := ha
  have sub_eq : ∀ a : Std.I32, (0 ≤ a.val ∧ a.val.toNat < i → Indep vg blk a.val.toNat) →
      (if h : 0 ≤ a.val ∧ a.val.toNat < i then evalSym vg env' a.val.toNat else 0) =
      (if h : 0 ≤ a.val ∧ a.val.toNat < i then evalSym vg env a.val.toNat else 0) := by
    intro a ham
    by_cases hc : 0 ≤ a.val ∧ a.val.toNat < i
    · simp only [hc, and_self, ↓reduceDIte]
      exact ham hc env env' ⟨hp, hsym, hphi, heff⟩
    · simp only [hc, ↓reduceDIte]
  rw [evalSym_unfold, evalSym_unfold, hn]
  cases t with
  | SConst c x => rfl
  | SSym x => simp only [evalNode, hsym]
  | SParam c k => simp only [evalNode, hp]
  | SPhi c b k => simp only [evalNode, hphi c b k (hleaf c b k (Or.inl rfl))]
  | SEffect c b k => simp only [evalNode, heff c b k (hleaf c b k (Or.inr rfl))]
  | SUn c op a =>
    simp only [evalNode]
    rw [sub_eq a (fun h => hch a (Or.inl ⟨c, op, rfl⟩) h.1 h.2)]
  | SBin c op a b =>
    simp only [evalNode]
    rw [sub_eq a (fun h => hch a (Or.inr ⟨c, op, b, Or.inl rfl⟩) h.1 h.2),
      sub_eq b (fun h => hch b (Or.inr ⟨c, op, a, Or.inr rfl⟩) h.1 h.2)]

/-- The guarded mark read `a >= 0 && a < i && m[a]` of `blk_mentions_table` returning `false`. -/
theorem guard_get_false {m : Pion.Array Bool} {a i : Std.I32} {r : Bool}
    (h : (if ((decide (a >= 0#i32)) && (decide (a < i))) then
        (do let x ← Pion.Array.get m a; ok x) else ok false) = ok r)
    (hr : r = false) (ha0 : 0 ≤ a.val) (hai : a.val < i.val) : m.val[a.val.toNat]? = some false := by
  subst hr
  split at h
  · obtain ⟨x, hx, h⟩ := bind_eq_ok h
    obtain ⟨_, hxl, hxv⟩ := arr_get_ok hx
    have := ok_inj' h
    subst this
    rw [List.getElem?_eq_getElem hxl, hxv]
  · rename_i hneg
    exfalso
    apply hneg
    simp only [Bool.and_eq_true, decide_eq_true_eq, ge_iff_le, i32_le_iff, i32_lt_iff, i32_zero_val]
    exact ⟨ha0, hai⟩

/-- `blk_mentions_table vg blk`: one mark per node, and an unmarked node does not depend on
block `blk`. -/
theorem blk_mentions_table_sound {vg : ValGraph} {blk : Std.I32} {m : Pion.Array Bool}
    (h : blk_mentions_table vg blk = ok m) :
    m.val.length = vg.nodes.val.length ∧ ∀ i, m.val[i]? = some false → Indep vg blk i := by
  unfold blk_mentions_table at h
  obtain ⟨n, hn, h⟩ := bind_eq_ok h
  obtain ⟨hn1, hn2⟩ := arr_length_ok hn
  obtain ⟨q, hq, h⟩ := bind_eq_ok h
  obtain ⟨i1, m1⟩ := q
  try simp only [uncurry_apply_pair] at h
  cases ok_inj' h
  unfold blk_mentions_table_loop0 at hq
  refine loop_ok_inv (fun (p : Std.I32 × Pion.Array Bool) => blk_mentions_table_loop0.body n vg blk p.1 p.2)
    (fun p => 0 ≤ p.1.val ∧ p.2.val.length = vg.nodes.val.length ∧
      ∀ j, j < p.1.val.toNat → p.2.val[j]? = some false → Indep vg blk j)
    (fun p => p.2.val.length = vg.nodes.val.length ∧ ∀ j, p.2.val[j]? = some false → Indep vg blk j)
    ?_ _ _ hq ⟨by simp, by simp [Pion.Array.make, listMake]; omega, fun j hj => by simp at hj⟩
  rintro ⟨i, mm⟩ c ⟨hi0, hl, hall⟩ hc
  simp only at hi0 hl hall hc
  unfold blk_mentions_table_loop0.body at hc
  split at hc
  · rename_i hlt
    have hlt' : i.val < vg.nodes.val.length := by simp only [i32_lt_iff] at hlt; omega
    obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
    obtain ⟨_, htl, htv⟩ := arr_get_ok ht
    have htn : vg.nodes.val[i.val.toNat]? = some t := by rw [List.getElem?_eq_getElem htl, htv]
    obtain ⟨hit, hhit, hc⟩ := bind_eq_ok hc
    obtain ⟨m1, hm1, hc⟩ := bind_eq_ok hc
    rw [← ok_inj' hc]
    have his : (Pion.I32.add i 1#i32).val = i.val + 1 := by
      have h2 := i.hmin
      simp only [IScalarTy.numBits] at h2
      exact i32_add_val i 1#i32 (by simp; omega) (by simp; omega)
    have hm1' : m1.val.length = vg.nodes.val.length ∧
        (∀ j, j < i.val.toNat → m1.val[j]? = mm.val[j]?) ∧
        (hit = false → m1.val[i.val.toNat]? = mm.val[i.val.toNat]?) ∧
        (hit = true → m1.val[i.val.toNat]? ≠ some false) := by
      split at hm1
      · rename_i hh
        obtain ⟨m2, hm2, hm1⟩ := bind_eq_ok hm1
        cases ok_inj' hm1
        have hs := arr_set_ok hm2
        refine ⟨?_, ?_, ?_, ?_⟩
        · rw [hs]; simp [hl]
        · intro j hj
          rw [hs, List.getElem?_set_ne (by omega)]
        · intro hf
          rw [hf] at hh
          cases hh
        · intro _
          rw [hs]; simp [List.getElem?_set, hl, hlt']
      · rename_i hh
        cases ok_inj' hm1
        exact ⟨hl, fun _ _ => rfl, fun _ => rfl, fun ht' => absurd ht' hh⟩
    dsimp only
    refine ⟨by rw [his]; omega, hm1'.1, fun j hj hjf => ?_⟩
    rw [his] at hj
    have hj' : j < i.val.toNat + 1 := by omega
    by_cases hji : j < i.val.toNat
    · rw [hm1'.2.1 j hji] at hjf
      exact hall j hji hjf
    · have hje : j = i.val.toNat := by omega
      subst hje
      cases hit with
      | true => exact absurd hjf (hm1'.2.2.2 rfl)
      | false =>
        apply indep_node htn
        · intro c b k hor e
          rcases hor with rfl | rfl
          all_goals
            dsimp only at hhit
            have := ok_inj' hhit
            subst e
            simp at this
        · intro a hor ha0 hai
          rcases hor with ⟨c, op, rfl⟩ | ⟨c, op, x, rfl | rfl⟩
          · dsimp only at hhit
            exact hall _ hai (guard_get_false hhit rfl ha0 (by omega))
          · dsimp only at hhit
            obtain ⟨t6, h6, h'⟩ := bind_eq_ok hhit
            split at h'
            · exact absurd (ok_inj' h') (by decide)
            · rename_i h6f
              exact hall _ hai (guard_get_false h6 (by simpa using h6f) ha0 (by omega))
          · dsimp only at hhit
            obtain ⟨t6, h6, h'⟩ := bind_eq_ok hhit
            split at h'
            · exact absurd (ok_inj' h') (by decide)
            · exact hall _ hai (guard_get_false h' rfl ha0 (by omega))
  · rename_i hge
    rw [← ok_inj' hc]
    dsimp only
    refine ⟨hl, fun j hj => ?_⟩
    have hjl : j < vg.nodes.val.length := by
      by_contra hc'
      rw [List.getElem?_eq_none (by omega)] at hj
      cases hj
    exact hall j (by simp only [i32_lt_iff] at hge; omega) hj

/-- An unmarked node keeps its independence in every graph extending the table's. -/
theorem indep_extends {vg G : ValGraph} (hp : vg_extends vg G) {blk : Std.I32} {j : Nat}
    (hj : j < vg.nodes.val.length) (h : Indep vg blk j) : Indep G blk j := by
  intro env env' ha
  rw [evalSym_extends hp env' j hj, evalSym_extends hp env j hj]
  exact h env env' ha

end PionProofs.QbeTvP
