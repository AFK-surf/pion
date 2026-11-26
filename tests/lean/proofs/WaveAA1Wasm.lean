/-
Soundness models for Wave AA · Track AA1 Wasm32 backend optimizations
(`compiler/src/core/wasm.pion`):

  1. `ExtAndEqz` — size-aware constant extension folding (`extsw`/`extuw`/
     `extsh`/`extuh`/`extsb`/`extub`), `trunc32(sext32(x)) = x` and
     `trunc32(zext32(x)) = x`, and integer zero-comparison `eqz` identities.
  2. `ExprForward` — AA1-Z1 pure single-use same-block expression tree stack
     forwarding: leaf-dependence, stack-prefix preservation, and semantic
     equivalence under transitive leaf lifetime preservation.
  3. `EmitPeephole` — AA1-Z2 emit-time peepholes: `local.set x; local.get x`
     equals `local.tee x` (preserving promoted-alloc writes), and adjacent
     `i64.extend_i32_{s,u}; i32.wrap_i64` equals nop.
  4. `LocalColorAndReorder` — AA1-Z3 intra-block interval coloring soundness
     under arbitrary CFGs (`br_table`) and non-parameter local-index bijection
     simulation equivalence.
  5. `DisambigFastPath` — AA1-S1 cross-unit collision-free fast path soundness
     (Phase A + Phase B implies zero renames under full disambiguation).
-/
import Std

namespace WaveAA1Wasm

/-! ## 1. Constant extension identities, ext/wrap cancellation, and `eqz` -/

namespace ExtAndEqz

inductive CVal where
  | i32 (v : BitVec 32)
  | i64 (v : BitVec 64)
  deriving DecidableEq

inductive CmpOp where
  | constI32 (v : BitVec 32)
  | constI64 (v : BitVec 64)
  | i32Eq
  | i64Eq
  | i32Ne
  | i64Ne
  | i32Eqz
  | i64Eqz

def boolToI32 (b : Bool) : BitVec 32 := if b then 1#32 else 0#32

def stepCmp (stk : List CVal) : CmpOp → List CVal
  | .constI32 v => .i32 v :: stk
  | .constI64 v => .i64 v :: stk
  | .i32Eq =>
    match stk with
    | .i32 b :: .i32 a :: rest => .i32 (boolToI32 (a == b)) :: rest
    | _ => stk
  | .i64Eq =>
    match stk with
    | .i64 b :: .i64 a :: rest => .i32 (boolToI32 (a == b)) :: rest
    | _ => stk
  | .i32Ne =>
    match stk with
    | .i32 b :: .i32 a :: rest => .i32 (boolToI32 (a != b)) :: rest
    | _ => stk
  | .i64Ne =>
    match stk with
    | .i64 b :: .i64 a :: rest => .i32 (boolToI32 (a != b)) :: rest
    | _ => stk
  | .i32Eqz =>
    match stk with
    | .i32 a :: rest => .i32 (if a.toNat = 0 then 1#32 else 0#32) :: rest
    | _ => stk
  | .i64Eqz =>
    match stk with
    | .i64 a :: rest => .i32 (if a.toNat = 0 then 1#32 else 0#32) :: rest
    | _ => stk

def runCmp (ops : List CmpOp) (stk : List CVal) : List CVal :=
  ops.foldl stepCmp stk

/-- Constant `extsw v` preserves the signed 32-bit integer value when widening to 64 bits. -/
theorem extsw_const_toInt (v : BitVec 64) :
    (BitVec.signExtend 64 (BitVec.truncate 32 v)).toInt =
      (BitVec.truncate 32 v).toInt := by
  rw [BitVec.toInt_signExtend]
  have hlt := (BitVec.truncate 32 v).isLt
  simp [Int.bmod, BitVec.toInt]
  omega

/-- Constant `extsw v` equals constructing the 64-bit two's-complement immediate directly
    from the signed 32-bit value (justifying `i64.const (sext32 v)`). -/
theorem extsw_const (v : BitVec 64) :
    BitVec.signExtend 64 (BitVec.truncate 32 v) =
      BitVec.ofInt 64 (BitVec.truncate 32 v).toInt := by
  apply BitVec.eq_of_toInt_eq
  rw [extsw_const_toInt, BitVec.toInt_ofInt]
  have hlt := (BitVec.truncate 32 v).isLt
  simp [Int.bmod, BitVec.toInt]
  omega

theorem extuw_const (v : BitVec 64) :
    BitVec.zeroExtend 64 (BitVec.truncate 32 v) = v &&& 0xFFFFFFFF#64 := by
  apply BitVec.eq_of_toNat_eq
  have hm : (0xFFFFFFFF#64).toNat = 2 ^ 32 - 1 := by decide
  rw [BitVec.zeroExtend_eq_setWidth, BitVec.truncate_eq_setWidth,
    BitVec.toNat_setWidth, BitVec.toNat_setWidth, BitVec.toNat_and, hm,
    Nat.and_two_pow_sub_one_eq_mod]
  omega

theorem extsh_const (v : BitVec 64) :
    BitVec.signExtend 64 (BitVec.signExtend 32 (BitVec.truncate 16 v)) =
      BitVec.signExtend 64 (BitVec.truncate 16 v) := by
  apply BitVec.eq_of_toInt_eq
  simp [BitVec.toInt_signExtend, Int.bmod]
  omega

/-- Matches `wasm.pion`'s shift-pair constant evaluation `((v32 << 16) >> 16)` for `extsh`. -/
theorem extsh_shift_pair (v32 : BitVec 32) :
    (v32 <<< 16).sshiftRight 16 = BitVec.signExtend 32 (BitVec.truncate 16 v32) := by
  ext i hi
  simp only [BitVec.getElem_sshiftRight, BitVec.getElem_shiftLeft,
    BitVec.getElem_signExtend, BitVec.truncate_eq_setWidth]
  by_cases h : i < 16
  · have h1 : 16 + i < 32 := by omega
    have h2 : ¬ (16 + i < 16) := by omega
    have h3 : 16 + i - 16 = i := by omega
    simp [h, h1, h2, h3, BitVec.getElem_eq_testBit_toNat]
    change v32.toNat.testBit i = (v32.toNat % 2 ^ 16).testBit i
    rw [Nat.testBit_mod_two_pow]
    simp [h]
  · have h1 : ¬ (16 + i < 32) := by omega
    simp [h, h1, BitVec.msb, BitVec.getMsbD]

theorem extuh_const (v : BitVec 64) :
    BitVec.zeroExtend 64 (BitVec.truncate 32 v &&& 0xFFFF#32) =
      BitVec.zeroExtend 64 (BitVec.truncate 16 v) := by
  apply BitVec.eq_of_toNat_eq
  have hm : (0xFFFF#32).toNat = 2 ^ 16 - 1 := by decide
  rw [BitVec.zeroExtend_eq_setWidth, BitVec.zeroExtend_eq_setWidth,
    BitVec.truncate_eq_setWidth, BitVec.truncate_eq_setWidth,
    BitVec.toNat_setWidth, BitVec.toNat_setWidth, BitVec.toNat_and,
    BitVec.toNat_setWidth, BitVec.toNat_setWidth, hm,
    Nat.and_two_pow_sub_one_eq_mod]
  omega

theorem extsb_const (v : BitVec 64) :
    BitVec.signExtend 64 (BitVec.signExtend 32 (BitVec.truncate 8 v)) =
      BitVec.signExtend 64 (BitVec.truncate 8 v) := by
  apply BitVec.eq_of_toInt_eq
  simp [BitVec.toInt_signExtend, Int.bmod]
  omega

/-- Matches `wasm.pion`'s shift-pair constant evaluation `((v32 << 24) >> 24)` for `extsb`. -/
theorem extsb_shift_pair (v32 : BitVec 32) :
    (v32 <<< 24).sshiftRight 24 = BitVec.signExtend 32 (BitVec.truncate 8 v32) := by
  ext i hi
  simp only [BitVec.getElem_sshiftRight, BitVec.getElem_shiftLeft,
    BitVec.getElem_signExtend, BitVec.truncate_eq_setWidth]
  by_cases h : i < 8
  · have h1 : 24 + i < 32 := by omega
    have h2 : ¬ (24 + i < 24) := by omega
    have h3 : 24 + i - 24 = i := by omega
    simp [h, h1, h2, h3, BitVec.getElem_eq_testBit_toNat]
    change v32.toNat.testBit i = (v32.toNat % 2 ^ 8).testBit i
    rw [Nat.testBit_mod_two_pow]
    simp [h]
  · have h1 : ¬ (24 + i < 32) := by omega
    simp [h, h1, BitVec.msb, BitVec.getMsbD]

theorem extub_const (v : BitVec 64) :
    BitVec.zeroExtend 64 (BitVec.truncate 32 v &&& 0xFF#32) =
      BitVec.zeroExtend 64 (BitVec.truncate 8 v) := by
  apply BitVec.eq_of_toNat_eq
  have hm : (0xFF#32).toNat = 2 ^ 8 - 1 := by decide
  rw [BitVec.zeroExtend_eq_setWidth, BitVec.zeroExtend_eq_setWidth,
    BitVec.truncate_eq_setWidth, BitVec.truncate_eq_setWidth,
    BitVec.toNat_setWidth, BitVec.toNat_setWidth, BitVec.toNat_and,
    BitVec.toNat_setWidth, BitVec.toNat_setWidth, hm,
    Nat.and_two_pow_sub_one_eq_mod]
  omega

theorem trunc32_sext32 (x : BitVec 32) :
    BitVec.truncate 32 (BitVec.signExtend 64 x) = x := by
  apply BitVec.eq_of_toNat_eq
  have h := x.isLt
  rw [BitVec.truncate_eq_setWidth, BitVec.toNat_setWidth, BitVec.toNat_signExtend,
    BitVec.toNat_setWidth]
  split <;> omega

theorem trunc32_zext32 (x : BitVec 32) :
    BitVec.truncate 32 (BitVec.zeroExtend 64 x) = x := by
  apply BitVec.eq_of_toNat_eq
  have h := x.isLt
  rw [BitVec.truncate_eq_setWidth, BitVec.zeroExtend_eq_setWidth,
    BitVec.toNat_setWidth, BitVec.toNat_setWidth]
  omega

private theorem bv_eq_zero_iff_toNat {n : Nat} (x : BitVec n) :
    (x == BitVec.ofNat n 0) = decide (x.toNat = 0) := by
  by_cases h : x.toNat = 0
  · have hx : x = BitVec.ofNat n 0 := BitVec.eq_of_toNat_eq (by simpa using h)
    subst hx
    simp
  · have hne : x ≠ BitVec.ofNat n 0 := by
      intro heq
      apply h
      simp [heq]
    simp [beq_eq_false_iff_ne.mpr hne, h]

theorem ceqw_zero_eq_eqz (x : BitVec 32) (stk : List CVal) :
    runCmp [.constI32 0#32, .i32Eq] (.i32 x :: stk) = runCmp [.i32Eqz] (.i32 x :: stk) ∧
    runCmp [.i32Eq] (.i32 x :: .i32 0#32 :: stk) = runCmp [.i32Eqz] (.i32 x :: stk) := by
  have hz : (x == 0#32) = decide (x.toNat = 0) := bv_eq_zero_iff_toNat x
  constructor
  · simp [runCmp, stepCmp, boolToI32, hz]
  · by_cases h : x.toNat = 0
    · have hx : x = 0#32 := BitVec.eq_of_toNat_eq (by simpa using h)
      subst hx
      simp [runCmp, stepCmp, boolToI32]
    · have hne : (0#32 : BitVec 32) ≠ x := by
        intro heq
        apply h
        simp [← heq]
      simp [runCmp, stepCmp, boolToI32, beq_eq_false_iff_ne.mpr hne, h]

theorem ceql_zero_eq_eqz (x : BitVec 64) (stk : List CVal) :
    runCmp [.constI64 0#64, .i64Eq] (.i64 x :: stk) = runCmp [.i64Eqz] (.i64 x :: stk) ∧
    runCmp [.i64Eq] (.i64 x :: .i64 0#64 :: stk) = runCmp [.i64Eqz] (.i64 x :: stk) := by
  have hz : (x == 0#64) = decide (x.toNat = 0) := bv_eq_zero_iff_toNat x
  constructor
  · simp [runCmp, stepCmp, boolToI32, hz]
  · by_cases h : x.toNat = 0
    · have hx : x = 0#64 := BitVec.eq_of_toNat_eq (by simpa using h)
      subst hx
      simp [runCmp, stepCmp, boolToI32]
    · have hne : (0#64 : BitVec 64) ≠ x := by
        intro heq
        apply h
        simp [← heq]
      simp [runCmp, stepCmp, boolToI32, beq_eq_false_iff_ne.mpr hne, h]

theorem cnew_zero_eq_eqz_eqz (x : BitVec 32) (stk : List CVal) :
    runCmp [.constI32 0#32, .i32Ne] (.i32 x :: stk) =
      runCmp [.i32Eqz, .i32Eqz] (.i32 x :: stk) ∧
    runCmp [.i32Ne] (.i32 x :: .i32 0#32 :: stk) =
      runCmp [.i32Eqz, .i32Eqz] (.i32 x :: stk) := by
  by_cases h : x.toNat = 0
  · have hx : x = 0#32 := BitVec.eq_of_toNat_eq (by simpa using h)
    subst hx
    simp [runCmp, stepCmp, boolToI32]
  · have hne1 : x ≠ (0#32 : BitVec 32) := by
      intro heq
      apply h
      simp [heq]
    have hne2 : (0#32 : BitVec 32) ≠ x := hne1.symm
    simp [runCmp, stepCmp, boolToI32, bne, beq_eq_false_iff_ne.mpr hne1,
      beq_eq_false_iff_ne.mpr hne2, h]

theorem cnel_zero_eq_eqz_eqz (x : BitVec 64) (stk : List CVal) :
    runCmp [.constI64 0#64, .i64Ne] (.i64 x :: stk) =
      runCmp [.i64Eqz, .i32Eqz] (.i64 x :: stk) ∧
    runCmp [.i64Ne] (.i64 x :: .i64 0#64 :: stk) =
      runCmp [.i64Eqz, .i32Eqz] (.i64 x :: stk) := by
  by_cases h : x.toNat = 0
  · have hx : x = 0#64 := BitVec.eq_of_toNat_eq (by simpa using h)
    subst hx
    simp [runCmp, stepCmp, boolToI32]
  · have hne1 : x ≠ (0#64 : BitVec 64) := by
      intro heq
      apply h
      simp [heq]
    have hne2 : (0#64 : BitVec 64) ≠ x := hne1.symm
    simp [runCmp, stepCmp, boolToI32, bne, beq_eq_false_iff_ne.mpr hne1,
      beq_eq_false_iff_ne.mpr hne2, h]

end ExtAndEqz

/-! ## 2. AA1-Z1: Pure single-use expression tree stack forwarding -/

namespace ExprForward

inductive PureExpr (Val : Type) where
  | const (v : Val)
  | leaf (id : Nat)
  | un (f : Val → Val) (a : PureExpr Val)
  | bin (f : Val → Val → Val) (a b : PureExpr Val)

def PureExpr.eval {Val : Type} (env : Nat → Val) : PureExpr Val → Val
  | .const v => v
  | .leaf id => env id
  | .un f a => f (a.eval env)
  | .bin f a b => f (a.eval env) (b.eval env)

def PureExpr.leaves {Val : Type} : PureExpr Val → List Nat
  | .const _ => []
  | .leaf id => [id]
  | .un _ a => a.leaves
  | .bin _ a b => a.leaves ++ b.leaves

inductive StackOp (Val : Type) where
  | pushConst (v : Val)
  | getLocal (id : Nat)
  | applyUn (f : Val → Val)
  | applyBin (f : Val → Val → Val)

def execOp {Val : Type} (env : Nat → Val) (stk : List Val) : StackOp Val → List Val
  | .pushConst v => v :: stk
  | .getLocal id => env id :: stk
  | .applyUn f =>
    match stk with
    | a :: rest => f a :: rest
    | [] => []
  | .applyBin f =>
    match stk with
    | b :: a :: rest => f a b :: rest
    | _ => stk

def execOps {Val : Type} (env : Nat → Val) (ops : List (StackOp Val)) (stk : List Val) : List Val :=
  ops.foldl (execOp env) stk

def emitExpr {Val : Type} : PureExpr Val → List (StackOp Val)
  | .const v => [.pushConst v]
  | .leaf id => [.getLocal id]
  | .un f a => emitExpr a ++ [.applyUn f]
  | .bin f a b => emitExpr a ++ emitExpr b ++ [.applyBin f]

theorem evalExpr_depends_only_on_leaves {Val : Type} (e : PureExpr Val)
    (env1 env2 : Nat → Val)
    (hagree : ∀ x, x ∈ e.leaves → env1 x = env2 x) :
    e.eval env1 = e.eval env2 := by
  induction e with
  | const v => rfl
  | leaf id =>
    exact hagree id (by simp [PureExpr.leaves])
  | un f a ih =>
    simp only [PureExpr.eval]
    rw [ih (fun x hx => hagree x (by simpa [PureExpr.leaves] using hx))]
  | bin f a b iha ihb =>
    simp only [PureExpr.eval]
    rw [iha (fun x hx => hagree x (by simp [PureExpr.leaves, hx])),
        ihb (fun x hx => hagree x (by simp [PureExpr.leaves, hx]))]

theorem execOps_append {Val : Type} (env : Nat → Val)
    (xs ys : List (StackOp Val)) (stk : List Val) :
    execOps env (xs ++ ys) stk = execOps env ys (execOps env xs stk) := by
  simp [execOps, List.foldl_append]

theorem emitExpr_stack_prefix {Val : Type} (e : PureExpr Val)
    (env : Nat → Val) (stk : List Val) :
    execOps env (emitExpr e) stk = e.eval env :: stk := by
  induction e generalizing stk with
  | const v => rfl
  | leaf id => rfl
  | un f a ih =>
    rw [emitExpr, execOps_append, ih]
    rfl
  | bin f a b iha ihb =>
    rw [emitExpr, execOps_append, execOps_append, iha, ihb]
    rfl

/-- Model soundness for AA1-Z1 pure expression forwarding: assuming `hlive`
    (no intervening write to any leaf between producer `envP` and consumer `envQ`,
    which the compiler enforces via its same-block intervening-def check in
    `wasm_build_fwd_exprs`), evaluating the forwarded tree at `envQ` pushes the
    exact same value as evaluating at `envP`. -/
theorem forward_single_use_sound {Val : Type} (e : PureExpr Val)
    (envP envQ : Nat → Val) (stk : List Val)
    (hlive : ∀ x, x ∈ e.leaves → envP x = envQ x) :
    execOps envQ (emitExpr e) stk = e.eval envP :: stk := by
  rw [emitExpr_stack_prefix, evalExpr_depends_only_on_leaves e envQ envP (fun x hx => (hlive x hx).symm)]

end ExprForward

/-! ## 3. AA1-Z2: Emit-time `set; get ≡ tee` and `ext; wrap ≡ nop` -/

namespace EmitPeephole

inductive WVal where
  | i32 (v : BitVec 32)
  | i64 (v : BitVec 64)
  deriving DecidableEq

inductive WOp where
  | localGet (idx : Nat)
  | localSet (idx : Nat)
  | localTee (idx : Nat)
  | extI32S
  | extI32U
  | wrapI64

abbrev Env := Nat → WVal
abbrev State := Env × List WVal

def updateEnv (env : Env) (idx : Nat) (v : WVal) : Env :=
  fun k => if k = idx then v else env k

def step (st : State) : WOp → State
  | .localGet idx => (st.1, st.1 idx :: st.2)
  | .localSet idx =>
    match st.2 with
    | v :: rest => (updateEnv st.1 idx v, rest)
    | [] => st
  | .localTee idx =>
    match st.2 with
    | v :: rest => (updateEnv st.1 idx v, v :: rest)
    | [] => st
  | .extI32S =>
    match st.2 with
    | .i32 v :: rest => (st.1, .i64 (BitVec.signExtend 64 v) :: rest)
    | _ => st
  | .extI32U =>
    match st.2 with
    | .i32 v :: rest => (st.1, .i64 (BitVec.zeroExtend 64 v) :: rest)
    | _ => st
  | .wrapI64 =>
    match st.2 with
    | .i64 v :: rest => (st.1, .i32 (BitVec.truncate 32 v) :: rest)
    | _ => st

def run (ops : List WOp) (st : State) : State :=
  ops.foldl step st

theorem set_get_eq_tee (env : Env) (idx : Nat) (v : WVal) (stk : List WVal) :
    run [.localSet idx, .localGet idx] (env, v :: stk) =
      run [.localTee idx] (env, v :: stk) := by
  simp [run, step, updateEnv]

theorem tee_preserves_promoted_write (env : Env) (idx : Nat) (v : WVal) (stk : List WVal) :
    (run [.localTee idx] (env, v :: stk)).1 idx = v ∧
    ∀ k, k ≠ idx → (run [.localTee idx] (env, v :: stk)).1 k = env k := by
  refine ⟨by simp [run, step, updateEnv], fun k hk => by simp [run, step, updateEnv, hk]⟩

theorem ext_s_wrap_nop (env : Env) (v : BitVec 32) (stk : List WVal) :
    run [.extI32S, .wrapI64] (env, .i32 v :: stk) = (env, .i32 v :: stk) := by
  simp [run, step, ExtAndEqz.trunc32_sext32]

theorem ext_u_wrap_nop (env : Env) (v : BitVec 32) (stk : List WVal) :
    run [.extI32U, .wrapI64] (env, .i32 v :: stk) = (env, .i32 v :: stk) := by
  simp [run, step]

end EmitPeephole

/-! ## 4. AA1-Z3: Intra-block interval coloring & non-param local bijection -/

namespace LocalColorAndReorder

/-- Model soundness for AA1-Z3 intra-block interval coloring: given the interval
    disjointness precondition `hdisj` (enforced by the compiler's greedy interval
    colorer in `wasm_assign_intrablock_colored_locals`), two distinct temps sharing
    a physical slot never clobber each other within `[defPos a, lastUse a]`,
    regardless of initial slot contents (arbitrary irreducible CFG / `br_table` entry). -/
theorem intrablock_slot_preserved
    (slotOf : Nat → Nat) (defPos lastUse : Nat → Nat)
    (hwf : ∀ x, defPos x ≤ lastUse x)
    (hdisj : ∀ a b, a ≠ b → slotOf a = slotOf b →
      lastUse a < defPos b ∨ lastUse b < defPos a)
    (a b : Nat) (hab : a ≠ b) (hslot : slotOf a = slotOf b)
    (u : Nat) (hu_hi : u ≤ lastUse a) :
    ¬ (defPos a < defPos b ∧ defPos b ≤ u) := by
  intro ⟨h1, h2⟩
  have hwf_b := hwf b
  rcases hdisj a b hab hslot with h | h <;> omega

/-- Remap local indices of a Wasm operation through a bijection `π`. -/
def remapOp (π : Nat → Nat) : EmitPeephole.WOp → EmitPeephole.WOp
  | .localGet i => .localGet (π i)
  | .localSet i => .localSet (π i)
  | .localTee i => .localTee (π i)
  | .extI32S => .extI32S
  | .extI32U => .extI32U
  | .wrapI64 => .wrapI64

def envRel (π : Nat → Nat) (env1 env2 : EmitPeephole.Env) : Prop :=
  ∀ i, env2 (π i) = env1 i

theorem updateEnv_rel (π : Nat → Nat) (hinj : Function.Injective π)
    (env1 env2 : EmitPeephole.Env) (hrel : envRel π env1 env2)
    (idx : Nat) (v : EmitPeephole.WVal) :
    envRel π (EmitPeephole.updateEnv env1 idx v)
      (EmitPeephole.updateEnv env2 (π idx) v) := by
  intro i
  unfold EmitPeephole.updateEnv
  by_cases h : i = idx
  · subst h
    simp
  · have hne : π i ≠ π idx := fun heq => h (hinj heq)
    simp [h, hne, hrel i]

theorem remapOp_step_equiv (π : Nat → Nat) (hinj : Function.Injective π)
    (op : EmitPeephole.WOp) (env1 env2 : EmitPeephole.Env) (stk : List EmitPeephole.WVal)
    (hrel : envRel π env1 env2) :
    let s1 := EmitPeephole.step (env1, stk) op
    let s2 := EmitPeephole.step (env2, stk) (remapOp π op)
    envRel π s1.1 s2.1 ∧ s1.2 = s2.2 := by
  cases op with
  | localGet i =>
    simp [EmitPeephole.step, remapOp, hrel i, hrel]
  | localSet i =>
    cases stk with
    | nil => simp [EmitPeephole.step, remapOp, hrel]
    | cons v rest =>
      exact ⟨updateEnv_rel π hinj env1 env2 hrel i v, rfl⟩
  | localTee i =>
    cases stk with
    | nil => simp [EmitPeephole.step, remapOp, hrel]
    | cons v rest =>
      exact ⟨updateEnv_rel π hinj env1 env2 hrel i v, rfl⟩
  | extI32S =>
    cases stk with
    | nil => simp [EmitPeephole.step, remapOp, hrel]
    | cons v rest =>
      cases v <;> simp [EmitPeephole.step, remapOp, hrel]
  | extI32U =>
    cases stk with
    | nil => simp [EmitPeephole.step, remapOp, hrel]
    | cons v rest =>
      cases v <;> simp [EmitPeephole.step, remapOp, hrel]
  | wrapI64 =>
    cases stk with
    | nil => simp [EmitPeephole.step, remapOp, hrel]
    | cons v rest =>
      cases v <;> simp [EmitPeephole.step, remapOp, hrel]

theorem local_bijection_run_equiv (π : Nat → Nat) (hinj : Function.Injective π)
    (nParams : Nat) (hparams : ∀ i, i < nParams → π i = i)
    (ops : List EmitPeephole.WOp) (env1 env2 : EmitPeephole.Env)
    (stk : List EmitPeephole.WVal) (hrel : envRel π env1 env2) :
    let s1 := EmitPeephole.run ops (env1, stk)
    let s2 := EmitPeephole.run (ops.map (remapOp π)) (env2, stk)
    envRel π s1.1 s2.1 ∧ s1.2 = s2.2 ∧ (∀ i, i < nParams → s2.1 i = s1.1 i) := by
  induction ops generalizing env1 env2 stk with
  | nil =>
    refine ⟨hrel, rfl, fun i hi => ?_⟩
    simpa [EmitPeephole.run, hparams i hi] using hrel i
  | cons op rest ih =>
    simp only [List.map_cons, EmitPeephole.run, List.foldl_cons]
    have hstep := remapOp_step_equiv π hinj op env1 env2 stk hrel
    rcases h1 : EmitPeephole.step (env1, stk) op with ⟨e1, k1⟩
    rcases h2 : EmitPeephole.step (env2, stk) (remapOp π op) with ⟨e2, k2⟩
    rw [h1, h2] at hstep
    dsimp only at hstep
    rcases hstep with ⟨hrel', hstk'⟩
    subst hstk'
    exact ih e1 e2 k1 hrel'

end LocalColorAndReorder

/-! ## 5. AA1-S1: Cross-unit collision-free fast path soundness -/

namespace DisambigFastPath

structure UnitSyms (Sym : Type) where
  locals : List Sym
  exports : List Sym
  allSyms : List Sym

/-- Symbol `s` is reserved globally if any unit exports `s`, or any unit references `s`
    without defining `s` as a local. -/
def isGlobalReserved {Sym : Type} (units : List (UnitSyms Sym)) (s : Sym) : Prop :=
  ∃ u ∈ units, s ∈ u.exports ∨ (s ∈ u.allSyms ∧ s ∉ u.locals)

/-- Full disambiguation needs a rename for some unit iff some unit `u` has a local `s`
    that is either globally reserved or also a local of another unit `v`. -/
def fullNeedsRename {Sym : Type} (units : List (UnitSyms Sym)) : Prop :=
  ∃ i j, ∃ (hi : i < units.length) (hj : j < units.length) (s : Sym),
    s ∈ (units[i]'hi).locals ∧
      (isGlobalReserved units s ∨ (i ≠ j ∧ s ∈ (units[j]'hj).locals))

/-- Phase A passes: no local symbol collides with any export or any other unit's local. -/
def phaseAOk {Sym : Type} (units : List (UnitSyms Sym)) : Prop :=
  (∀ i j (hi : i < units.length) (hj : j < units.length) s,
    s ∈ (units[i]'hi).locals → s ∉ (units[j]'hj).exports) ∧
  (∀ i j (hi : i < units.length) (hj : j < units.length) s,
    i ≠ j → s ∈ (units[i]'hi).locals → s ∉ (units[j]'hj).locals)

/-- Phase B passes: no unit references a `$sym` that is defined as a local of another unit. -/
def phaseBOk {Sym : Type} (units : List (UnitSyms Sym)) : Prop :=
  ∀ i j (hi : i < units.length) (hj : j < units.length) s,
    i ≠ j → s ∈ (units[i]'hi).locals → s ∉ (units[j]'hj).allSyms

theorem fast_path_sound {Sym : Type} (units : List (UnitSyms Sym))
    (hA : phaseAOk units) (hB : phaseBOk units) :
    ¬ fullNeedsRename units := by
  intro ⟨i, j, hi, hj, s, hs_loc, hcol⟩
  rcases hcol with hres | ⟨hij, hs_j⟩
  · rcases hres with ⟨u, hu_mem, hcase⟩
    rw [List.mem_iff_getElem] at hu_mem
    rcases hu_mem with ⟨k, hk, rfl⟩
    rcases hcase with hexp | ⟨hall, hnotloc⟩
    · exact hA.1 i k hi hk s hs_loc hexp
    · by_cases hik : i = k
      · subst hik
        exact hnotloc hs_loc
      · exact hB i k hi hk s hik hs_loc hall
  · exact hA.2 i j hi hj s hij hs_loc hs_j

end DisambigFastPath

end WaveAA1Wasm
